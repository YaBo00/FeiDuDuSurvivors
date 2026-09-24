class_name ExtraWeaponSystem
extends Node
## 局内副武器系统（2026-09-22）。
## 需求文档：局内新武器设计_给代码AI_2026-09-22.md §1 / §2。
##
## 职责：持有表与逐武器冷却、四把副武器的行为推进（orbit / lightning / ice_nova / acid）、
##       以及它们的程序化视觉特效。
##
## 伤害一律经 CombatResolver.deal_extra_damage 结算 —— 暴击 / 护甲 / 毒 buff / 飘字
## 与主角武器【走同一条路径】，副武器不会自成一套数值。
##
## 【为什么是独立模块，而不是按文档塞进 Player】
##   副武器实体必须挂在【世界层】(Battle.world) 才与相机取景一致，而 Player 是
##   CharacterBody2D —— 让它生成世界实体就得反向持有 world 引用（违反本工程
##   "模块不反向依赖宿主"的依赖方向）。所以状态与推进都放这里，由 Battle 在
##   _tick_fighting 里按固定顺序调用 update()：
##     · 天然跟随 FIGHTING 状态 —— 暂停 / 结算 / 死亡自动停，不需要各自判状态；
##     · 与主角武器独立冷却、独立开火（绝不碰 player.attack_timer）。
##
## 【冷却与 cdr】周期型副武器（lightning / ice_nova / acid / missile）的冷却重置 =
##   tier.interval × (1 - player.cdr)。「冷却缩减」升级卡从此对副武器流真实生效；
##   orbit 是持续旋转型、无 interval，不接 cdr。
##
## 【确定性】只依赖 update(delta) 传入的 delta，不自己读 Time / 帧计数 ——
## 探针可以 set_physics_process(false) 后手动步进（与 Boss 状态机同一套可测性接缝）。

## 宿主
var _b: Node = null
## 持有表 {weapon_id: level}
var _levels: Dictionary = {}
## 冷却表 {weapon_id: 剩余秒}
var _cd: Dictionary = {}
## orbit：刀节点（每把刀一个 Node2D）+ 每把刀的「对同一敌人的再命中冷却表」+ 当前相位
var _blades: Array[Node2D] = []
var _blade_hits: Array[Dictionary] = []
var _orbit_phase := 0.0
## acid：活跃毒池。每项 = {node, radius, dps, vuln, left, tick_t}
var _pools: Array[Dictionary] = []
## missile：活跃导弹。每项 = {node, pos, vel, target, dmg, blast, left}
var _missiles: Array[Dictionary] = []
## 触发次数统计 {weapon_id: int}（自检 / 探针观测用；也是「副武器真的在工作」的自证）
var triggers: Dictionary = {}


func setup(battle: Node) -> void:
	_b = battle


# ================================================================ 持有 / 升级
## 获得一把副武器（level = 1）。已持有则等价于升级。
## 返回是否真的生效（满 2 把 / 已满级 / 未知 id → false）。
func grant(id: String) -> bool:
	if not GameStats.EXTRA_WEAPON_DEFS.has(id):
		push_warning("ExtraWeaponSystem: 未知副武器 id '%s'" % id)
		return false
	if _levels.has(id):
		return level_up(id)
	# 上限经 GameStats.extra_weapon_cap() 收口（默认 = MAX_EXTRA_WEAPONS）。
	# 金手指面板「解除副武器上限」只改那个静态覆盖位，本函数零分支。
	if owned_count() >= GameStats.extra_weapon_cap():
		return false
	_levels[id] = 1
	_cd[id] = 0.0     # 立刻开始工作（验收：选了「获得」后立刻生效，不等一个冷却）
	_sync_blades()
	return true


## 升级一把已持有的副武器。未持有 / 已满级 → false。
func level_up(id: String) -> bool:
	if not _levels.has(id):
		return false
	var mx := GameStats.extra_weapon_max_level(id)
	if mx <= 0 or int(_levels[id]) >= mx:
		return false
	_levels[id] = int(_levels[id]) + 1
	_sync_blades()
	return true


func has_weapon(id: String) -> bool:
	return _levels.has(id)


func level_of(id: String) -> int:
	return int(_levels.get(id, 0))


func owned_count() -> int:
	return _levels.size()


## 已持有的副武器 id（固定顺序，便于 UI / 探针稳定输出）。
func owned_ids() -> Array[String]:
	var out: Array[String] = []
	for id in GameStats.EXTRA_WEAPON_IDS:
		if _levels.has(id):
			out.append(String(id))
	return out


## 重开一局 / 换角色：清空全部副武器与场上实体（验收：死了重开不继承）。
func reset() -> void:
	_levels.clear()
	_cd.clear()
	triggers.clear()
	_orbit_phase = 0.0
	for n in _blades:
		if is_instance_valid(n):
			n.queue_free()
	_blades.clear()
	_blade_hits.clear()
	for p in _pools:
		var pn: Node2D = p["node"]
		if is_instance_valid(pn):
			pn.queue_free()
	_pools.clear()
	for m in _missiles:
		var mn: Node2D = m["node"]
		if is_instance_valid(mn):
			mn.queue_free()
	_missiles.clear()


# ================================================================ 主推进
## 由 Battle._tick_fighting 每帧调用（FIGHTING 状态内）。delta = 物理帧步长。
func update(delta: float) -> void:
	if _b == null or _b.player == null:
		return
	var p: Player = _b.player
	if not p.is_alive():
		return   # 玩家已死：副武器停手（与主角武器一致 —— 死后不再输出）
	for id in _levels.keys():
		_cd[id] = maxf(0.0, float(_cd.get(id, 0.0)) - delta)
	_tick_orbit(delta)
	for id in _levels.keys():
		var wid := String(id)
		if wid == "orbit":
			continue
		var t := GameStats.extra_weapon_tier(wid, int(_levels[wid]))
		if t.is_empty() or float(_cd.get(wid, 0.0)) > 0.0:
			continue
		# 冷却重置 = tier 裸间隔 × 冷却缩减（2026-09-22 接线）。
		# cdr 是【局内可变】stat（选卡 / 换角色后重算），所以每次重置都现读 p.cdr，
		# 绝不在 grant 时算一次存起来 —— 做法 A：升级 cdr 后不动正在倒计时的 _cd，
		# 下一次触发时自动吃到新间隔（1~2s 内有感知，不突兀）。
		# 封顶由 Player._recompute_stats 的 clampf(..., MAX_CDR=0.40) 收口，
		# 这里不重复护栏（否则公式会有两处、日后改一处必漂）。
		# orbit 是持续旋转型、无 interval，不在本分支内，不接 cdr。
		match String(GameStats.EXTRA_WEAPON_DEFS[wid]["behavior"]):
			"lightning":
				_cd[wid] = float(t["interval"]) * (1.0 - p.cdr)
				_cast_lightning(p, t)
			"ice_nova":
				_cd[wid] = float(t["interval"]) * (1.0 - p.cdr)
				_cast_ice_nova(p, t)
			"acid":
				_cd[wid] = float(t["interval"]) * (1.0 - p.cdr)
				_cast_acid(p, t)
			"missile":
				_cd[wid] = float(t["interval"]) * (1.0 - p.cdr)
				_cast_missile(p, t)
	_tick_pools(delta)
	_tick_missiles(delta)


# ================================================================ 环绕飞刃（持续型）
## 每帧：推进相位 → 逐刀更新位置与旋转 → 对重叠敌人结算伤害（同一把刀对同一敌人
## 有 ORBIT_HIT_CD 冷却，见 Stats 的说明）。
func _tick_orbit(delta: float) -> void:
	if not _levels.has("orbit"):
		return
	var t := GameStats.extra_weapon_tier("orbit", int(_levels["orbit"]))
	if t.is_empty():
		return
	var p: Player = _b.player
	var count := int(t["count"])
	var radius := float(t["radius"])
	_sync_blades()
	if _blades.size() != count:
		return   # 防御：点数与节点数不一致（不该发生），本帧跳过而不是崩
	_orbit_phase = fposmod(_orbit_phase + float(t["rot"]) * delta, TAU)
	var base_dmg := _base_damage(float(t["dmg_mul"]))
	var slow := float(t["slow"])
	var tint: Color = GameStats.EXTRA_WEAPON_DEFS["orbit"]["color"]
	# 存活敌人快照取【一次】给所有刀共用（质检冗余项 R2，2026-09-22）：
	# 旧版每把刀都调一次 _alive_enemies() = 每帧 N 刀 × 全量遍历 + 数组分配。
	# 本帧内刀不会真的新增击杀之外的差异 —— 已死目标由 _hit / apply_slow 的
	# is_dead 守卫兜住，语义与逐刀重取完全一致。
	var enemies := _alive_enemies()
	for i in _blades.size():
		var ang := _orbit_phase + TAU * float(i) / float(count)
		var pos: Vector2 = p.global_position + Vector2(cos(ang), sin(ang)) * radius
		var blade: Node2D = _blades[i]
		blade.global_position = pos
		# 刀身朝切线方向（+PI/2 让「刀尖」顺着旋转方向）—— 纯视觉
		blade.rotation = ang + PI * 0.5
		var hits: Dictionary = _blade_hits[i]
		if not hits.is_empty():
			for k in hits.keys():
				var left := float(hits[k]) - delta
				if left <= 0.0:
					hits.erase(k)
				else:
					hits[k] = left
		for e in enemies:
			var en: Enemy = e
			if hits.has(en.get_instance_id()):
				continue
			if pos.distance_to(en.global_position) > en.radius + GameStats.ORBIT_BLADE_RADIUS:
				continue
			hits[en.get_instance_id()] = GameStats.ORBIT_HIT_CD
			var dealt := _hit(en, base_dmg, tint, false)
			if dealt > 0 and slow > 0.0:
				# Boss 折扣在 Enemy.apply_slow 内部收口（见 Stats.EXTRA_SLOW_BOSS_MUL）
				en.apply_slow(GameStats.ORBIT_SLOW_MUL, slow)


# ================================================================ 闪电链（周期型）
## 取最近 targets 个敌人各劈一道，每道再链到 LIGHTNING_CHAIN_RANGE 内最近的敌人，
## 直到链数用尽。同一个敌人同一轮只被劈一次（used 去重）。
func _cast_lightning(p: Player, t: Dictionary) -> void:
	var targets := _nearest_enemies(p.global_position, int(t["targets"]), {})
	if targets.is_empty():
		return   # 场上没怪：冷却照扣（下次 interval 后再试），不攒次数
	triggers["lightning"] = int(triggers.get("lightning", 0)) + 1
	var dmg := _base_damage(float(t["dmg_mul"]))
	var tint: Color = GameStats.EXTRA_WEAPON_DEFS["lightning"]["color"]
	var used: Dictionary = {}
	var vlevel := int(_levels["lightning"]) - 1   # 0 基视觉等级
	for tt in targets:
		var start: Enemy = tt
		used[start.get_instance_id()] = true
		_strike_lightning(start, dmg, tint, vlevel)
		var cur := start
		for _c in maxi(0, int(t["chains"]) - 1):
			var nx := _nearest_enemy_of(cur.global_position, GameStats.LIGHTNING_CHAIN_RANGE, used)
			if nx == null:
				break
			used[nx.get_instance_id()] = true
			_strike_lightning(nx, dmg, tint, vlevel)
			cur = nx


## 劈一击：伤害 + 天上劈到目标头顶的锯齿闪电（程序化，无贴图）。
## vlevel = 0 基视觉等级（见 Stats.LIGHTNING_VIS_*）：只改折线粗细/亮度/锯齿，不改判定。
func _strike_lightning(e: Enemy, dmg: int, tint: Color, vlevel: int) -> void:
	var fx := LightningFX.new()
	fx.life = GameStats.LIGHTNING_FX_TIME
	fx.life_max = fx.life   # 质检 P1-1：寿命与淡出基准必须同步（旧版靠常量数值巧合对齐）
	fx.vlevel = vlevel
	fx.from_pt = e.global_position + Vector2(0.0, -GameStats.LIGHTNING_FX_HEIGHT)
	fx.to_pt = e.global_position
	fx.tint = tint
	_add_fx(fx, Vector2.ZERO, false)   # 折线两端都用世界坐标，节点本身放原点
	_hit(e, dmg, tint, false)


# ================================================================ 冰霜新星（周期型）
## 以玩家为圆心，半径内敌人：冻结（Boss 打对折）+ 附加伤害（Lv2 起）。
func _cast_ice_nova(p: Player, t: Dictionary) -> void:
	triggers["ice_nova"] = int(triggers.get("ice_nova", 0)) + 1
	var radius := float(t["radius"])
	var tint: Color = GameStats.EXTRA_WEAPON_DEFS["ice_nova"]["color"]
	var fx := IceNovaFX.new()
	fx.radius = radius
	fx.life = GameStats.ICE_FX_TIME
	fx.life_max = fx.life   # 质检 P1-1：寿命与淡出基准必须同步
	fx.tint = tint
	fx.vlevel = int(_levels["ice_nova"]) - 1   # 每级可见锚点：冰晶刺 6→8→10
	_add_fx(fx, p.global_position)
	var dmg := _base_damage(float(t["dmg_mul"])) if float(t["dmg_mul"]) > 0.0 else 0
	for e in _alive_enemies():
		var en: Enemy = e
		if en.global_position.distance_to(p.global_position) > radius + en.radius:
			continue
		if dmg > 0:
			_hit(en, dmg, tint, false)
		# Boss 折扣在 Enemy.freeze 内部收口（见 Stats.EXTRA_FREEZE_BOSS_MUL）
		en.freeze(float(t["freeze"]))


# ================================================================ 毒云（周期型）
## 在玩家脚下留一滩毒（场上最多 MAX_ACID_POOLS 滩，超出顶掉最旧的一滩）。
func _cast_acid(p: Player, t: Dictionary) -> void:
	triggers["acid"] = int(triggers.get("acid", 0)) + 1
	if _pools.size() >= GameStats.MAX_ACID_POOLS:
		var old: Dictionary = _pools.pop_front()
		var on: Node2D = old["node"]
		if is_instance_valid(on):
			on.queue_free()
	var fx := AcidPoolFX.new()
	fx.radius = float(t["radius"])
	fx.life = float(t["life"])
	fx.life_max = fx.life   # 质检 P1-1：毒池逐级寿命 2.0/2.5/3.0，不同步会让 Lv2+ 全程不透明、末 2s 才淡出
	fx.tint = GameStats.EXTRA_WEAPON_DEFS["acid"]["color"]
	fx.vlevel = int(_levels["acid"]) - 1   # 每级可见锚点：气泡数 + 浓度
	_add_fx(fx, p.global_position)
	_pools.append({
		"node": fx, "radius": float(t["radius"]), "dps": float(t["dps_mul"]),
		"vuln": float(t["vuln"]), "left": float(t["life"]), "tick_t": GameStats.EXTRA_ACID_TICK,
	})


## 毒池推进：寿命到 → 回收；每 EXTRA_ACID_TICK 对池内敌人 tick 一次伤害。
## ⚠️ 用 while 补 tick（而不是 if）—— 自检的 delta 很大（time_scale=6），
## 用 if 会让高倍速下 tick 变稀、毒云 DPS 随倍速漂移。
func _tick_pools(delta: float) -> void:
	if _pools.is_empty():
		return
	var tint: Color = GameStats.EXTRA_WEAPON_DEFS["acid"]["color"]
	var remain: Array[Dictionary] = []
	for pd in _pools:
		var node: Node2D = pd["node"]
		pd["left"] = float(pd["left"]) - delta
		if float(pd["left"]) <= 0.0 or not is_instance_valid(node):
			if is_instance_valid(node):
				node.queue_free()
			continue
		var tick := float(pd["tick_t"]) - delta
		var center: Vector2 = node.global_position
		var radius := float(pd["radius"])
		var vuln := float(pd["vuln"])
		var dmg := _base_damage(float(pd["dps"]) * GameStats.EXTRA_ACID_TICK)
		while tick <= 0.0:
			tick += GameStats.EXTRA_ACID_TICK
			for e in _alive_enemies():
				var en: Enemy = e
				if en.global_position.distance_to(center) > radius + en.radius:
					continue
				_hit(en, dmg, tint, false)
				if vuln > 1.0:
					en.apply_vuln(vuln, GameStats.ACID_VULN_DURATION)
		pd["tick_t"] = tick
		remain.append(pd)
	_pools = remain


# ================================================================ 追踪导弹（周期型 + 飞行实体）
## 一次齐射 count 枚，按 MISSILE_SPREAD_DEG 扇形散开 —— 不加张角的话几枚会叠在一起
## 追同一个目标，视觉上像 1 枚、实际也只有 1 枚的伤害真正生效。
func _cast_missile(p: Player, t: Dictionary) -> void:
	var n := int(t["count"])
	if _missiles.size() + n > GameStats.MAX_MISSILES:
		n = maxi(0, GameStats.MAX_MISSILES - _missiles.size())
	if n <= 0:
		return   # 场上导弹已满：本次齐射放弃（CD 照扣，不积压）
	triggers["missile"] = int(triggers.get("missile", 0)) + 1
	var dmg := _base_damage(float(t["dmg_mul"]))
	var blast := float(t["blast"])
	var target := _nearest_enemy_of(p.global_position, 1e9, {})
	var base_ang := 0.0
	if target != null:
		base_ang = (target.global_position - p.global_position).angle()
	for i in n:
		var off := 0.0
		if n > 1:
			off = deg_to_rad(GameStats.MISSILE_SPREAD_DEG) * (float(i) - float(n - 1) * 0.5)
		var ang := base_ang + off
		var node := MissileFX.new()
		node.tex = AssetDB.extra_weapon_tex("missile")
		node.tint = GameStats.EXTRA_WEAPON_DEFS["missile"]["color"]
		node.vlevel = int(_levels["missile"]) - 1   # 每级可见锚点：弹体尺寸
		_add_fx(node, p.global_position)
		node.rotation = ang + PI * 0.5
		_missiles.append({
			"node": node, "pos": p.global_position,
			"vel": Vector2(cos(ang), sin(ang)) * GameStats.MISSILE_SPEED,
			"target": target, "dmg": dmg, "blast": blast, "left": GameStats.MISSILE_LIFE,
		})


## 导弹推进：转向限速追目标 → 撞到任意敌人 / 寿命到期即爆。
## 目标死了会重新索敌（导弹不会因目标消失而原地打转）。
func _tick_missiles(delta: float) -> void:
	if _missiles.is_empty():
		return
	var tint: Color = GameStats.EXTRA_WEAPON_DEFS["missile"]["color"]
	var remain: Array[Dictionary] = []
	for md in _missiles:
		var node: Node2D = md["node"]
		if not is_instance_valid(node):
			continue
		var pos: Vector2 = md["pos"]
		var vel: Vector2 = md["vel"]
		var tgt: Enemy = md["target"]
		if tgt == null or not is_instance_valid(tgt) or tgt.is_dead:
			tgt = _nearest_enemy_of(pos, 1e9, {})
			md["target"] = tgt
		if tgt != null:
			var want := (tgt.global_position - pos).normalized()
			# 转向限速（rad/s）：不是瞬间掉头，而是「拐个弯追过去」——观感全靠这条
			var step := GameStats.MISSILE_TURN * delta
			var ang := vel.angle() + clampf(wrapf(want.angle() - vel.angle(), -PI, PI), -step, step)
			vel = Vector2(cos(ang), sin(ang)) * GameStats.MISSILE_SPEED
		pos += vel * delta
		node.global_position = pos
		node.rotation = vel.angle() + PI * 0.5   # 贴图头朝上 ⇒ 旋转对准飞行方向
		md["pos"] = pos
		md["vel"] = vel
		md["left"] = float(md["left"]) - delta
		# 命中判定：撞到【任意】敌人即爆（追偏了撞到别的怪也该炸）
		var hit := false
		for e in _alive_enemies():
			var en: Enemy = e
			if pos.distance_to(en.global_position) <= en.radius + GameStats.MISSILE_RADIUS:
				hit = true
				break
		if hit or float(md["left"]) <= 0.0:
			_explode(pos, float(md["blast"]), int(md["dmg"]), tint)
			if is_instance_valid(node):
				node.queue_free()
			continue
		remain.append(md)
	_missiles = remain


## 爆炸：落点为圆心，blast 半径内全部敌人吃【全额】伤害。
## 刻意不做距离衰减：文档 §2.5 只给了爆炸半径，不衰减让这颗弹的收益一眼可算
## （也避免「同一发弹对不同怪伤害不同」这种难以向玩家解释的规则）。
func _explode(pos: Vector2, blast: float, dmg: int, tint: Color) -> void:
	var fx := BlastFX.new()
	fx.radius = blast
	fx.life = GameStats.MISSILE_BLAST_FX
	fx.life_max = fx.life   # 质检 P1-1：寿命与淡出基准必须同步
	fx.tint = tint
	_add_fx(fx, pos)
	if dmg <= 0:
		return
	for e in _alive_enemies():
		var en: Enemy = e
		if en.global_position.distance_to(pos) <= blast + en.radius:
			_hit(en, dmg, tint, false)


# ================================================================ 工具
## 副武器出膛伤害基数 = 玩家攻击力 × 该级伤害倍率 × 特性乘区（背水一战，仅忧郁嘉豪 ≠1）。
## 【不吃】武器进化乘区 —— 那是主角武器专属（文档 §6 不做）。
## 暴击 / 护甲 / 毒 buff 由 CombatResolver.deal_extra_damage 统一结算。
func _base_damage(dmg_mul: float) -> int:
	var p: Player = _b.player
	if dmg_mul <= 0.0:
		return 0
	return maxi(1, roundi(float(p.atk) * dmg_mul * p.damage_bonus()))


## 一次副武器伤害（统一走 CombatResolver）。返回实扣伤害，0 = 目标已死/无效。
func _hit(e: Enemy, dmg: int, tint: Color, big: bool) -> int:
	if dmg <= 0 or not is_instance_valid(e) or e.is_dead:
		return 0
	var cb: CombatResolver = _b.combat
	if cb == null:
		return 0
	return cb.deal_extra_damage(e, dmg, tint, big)


## 场上存活敌人（过滤 is_dead / 已释放）。副武器全部索敌都走它 ——
## 不做网格查询：这些触发都是低频的（最快 1.2s 一次），全量遍历成本可忽略，
## 而网格的 3x3 cell 在半径 140px 这类判定上有边界漏判风险（GRID_CELL=96）。
func _alive_enemies() -> Array:
	var out := []
	if _b == null:
		return out
	for e in _b.enemies:
		if e != null and is_instance_valid(e) and not e.is_dead:
			out.append(e)
	return out


## 距 pos 最近的 n 个敌人（排除 exclude）。
func _nearest_enemies(pos: Vector2, n: int, exclude: Dictionary) -> Array:
	var cand: Array = []
	for e in _alive_enemies():
		var en: Enemy = e
		if exclude.has(en.get_instance_id()):
			continue
		cand.append(e)
	cand.sort_custom(func(a, b) -> bool:
		return (a as Node2D).global_position.distance_squared_to(pos) \
			< (b as Node2D).global_position.distance_squared_to(pos))
	var out: Array = []
	for i in mini(n, cand.size()):
		out.append(cand[i])
	return out


## 距 pos 在 radius 内、且不在 exclude 里的最近敌人（链跳用）。没有 → null。
func _nearest_enemy_of(pos: Vector2, radius: float, exclude: Dictionary) -> Enemy:
	var best: Enemy = null
	var best_d := radius
	for e in _alive_enemies():
		var en: Enemy = e
		if exclude.has(en.get_instance_id()):
			continue
		var d: float = en.global_position.distance_to(pos)
		if d < best_d:
			best_d = d
			best = en
	return best


## 把特效节点挂到世界层。world_pos = Vector2.ZERO 时节点留在原点（折线自带世界坐标）。
func _add_fx(n: Node2D, world_pos: Vector2, place := true) -> void:
	if _b == null or _b.world == null:
		n.queue_free()
		return
	_b.world.add_child(n)
	if place:
		n.global_position = world_pos


## 刀节点与当前刀数对齐（增删）。只在等级变化后真正做事。
func _sync_blades() -> void:
	var want := 0
	var vlevel := 0
	if _levels.has("orbit"):
		var lv := int(_levels["orbit"])
		vlevel = lv - 1   # 0 基视觉等级（只影响观感，不参与判定）
		var t := GameStats.extra_weapon_tier("orbit", lv)
		if not t.is_empty():
			want = int(t["count"])
	while _blades.size() > want:
		var n: Node2D = _blades.pop_back()
		if is_instance_valid(n):
			n.queue_free()
		_blade_hits.pop_back()
	while _blades.size() < want:
		var b := BladeFX.new()
		b.tint = GameStats.EXTRA_WEAPON_DEFS["orbit"]["color"]
		b.tex = AssetDB.extra_weapon_tex("orbit")
		b.vlevel = vlevel
		if _b != null and _b.world != null:
			_b.world.add_child(b)
		_blades.append(b)
		_blade_hits.append({})
	# 每级可见锚点：Lv1→Lv2（count 2→2）、Lv4 等刀数不变的升级里，
	# 上面的增删分支不会跑 —— 必须在这里逐刀回写视觉等级，
	# 否则「升级了但刀没变长」。改 vlevel 只是数据变化，必须主动 queue_redraw
	# （Node2D 会缓存绘制指令，改 position/rotation 不会触发 _draw）。
	for i in _blades.size():
		var bn: Node2D = _blades[i]
		if bn is BladeFX:
			var bf: BladeFX = bn
			if bf.vlevel != vlevel:
				bf.vlevel = vlevel
				bf.queue_redraw()


# ================================================================ 程序化特效（无贴图）
## 环绕飞刃的刀。有贴图用贴图（刀尖朝 +X），否则画一把程序化短刀。
## 节点 rotation 由系统设为切线方向，所以这里只需要把刀画在 +X 方向。
class BladeFX extends Node2D:
	var tint := Color(1.0, 0.62, 0.22)
	var tex: Texture2D = null
	## 视觉等级（0 基）：只影响刀身长度，不参与任何判定（每级可见锚点）。
	var vlevel: int = 0

	func _vis_len() -> float:
		return GameStats.BLADE_VIS_LEN_BASE \
			+ GameStats.BLADE_VIS_LEN_PER_LV * float(vlevel)

	func _draw() -> void:
		var want := _vis_len()
		if tex != null:
			var tw := float(tex.get_width())
			var th := float(tex.get_height())
			if tw > 0.0 and th > 0.0:
				# 视觉长度随等级加长（Lv1 = 基准 46px，与旧版逐像素一致），
				# 按贴图原比例缩放，中心对齐节点原点
				var s := want / tw
				draw_texture_rect(tex, Rect2(Vector2(-tw, -th) * 0.5 * s, Vector2(tw, th) * s), false)
				return
		# 程序化短刀：细长刀身（+X 为刀尖）+ 护手 + 柄。
		# 几何按 46px 基准写死、整体缩放 k —— 调基准值不必逐个改点。
		var k := want / 46.0
		draw_set_transform(Vector2.ZERO, 0.0, Vector2(k, k))
		var blade := PackedVector2Array([
			Vector2(26.0, 0.0), Vector2(6.0, -5.0), Vector2(-4.0, -4.0),
			Vector2(-4.0, 4.0), Vector2(6.0, 5.0),
		])
		draw_colored_polygon(blade, tint)
		draw_polyline(PackedVector2Array([
			Vector2(26.0, 0.0), Vector2(6.0, -5.0), Vector2(-4.0, -4.0),
		]), Color(1, 1, 1, 0.75), 1.4, true)
		draw_rect(Rect2(Vector2(-8.0, -7.0), Vector2(4.0, 14.0)), Color(0.35, 0.24, 0.18))
		draw_rect(Rect2(Vector2(-18.0, -3.0), Vector2(10.0, 6.0)), Color(0.55, 0.38, 0.24))
		draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


## 闪电链的锯齿折线：0.15s 内淡出。两端点都是【世界坐标】（节点留在原点）。
## 每级可见锚点：vlevel 越大 → 折线越粗、越亮、锯齿越剧烈（Lv5 粗细 ×1.52 / 锯齿 ×1.40）。
## 全部只影响 draw_* 的线宽与振幅，判定用的 LIGHTNING_FX_* 原样不动。
class LightningFX extends Node2D:
	var tint := Color(0.75, 0.9, 1.0)
	var from_pt := Vector2.ZERO
	var to_pt := Vector2.ZERO
	var life := 0.15
	var life_max := 0.15
	## 0 基视觉等级（Lv1 = 0）
	var vlevel: int = 0

	func _process(delta: float) -> void:
		life -= delta
		if life <= 0.0:
			queue_free()
			return
		queue_redraw()

	func _draw() -> void:
		var wmul := 1.0 + GameStats.LIGHTNING_VIS_WIDTH_MUL_PER_LV * float(vlevel)
		var jmul := 1.0 + GameStats.LIGHTNING_VIS_JAG_MUL_PER_LV * float(vlevel)
		var k := clampf(life / maxf(0.001, life_max), 0.0, 1.0)
		# 亮度随级拉满（clamp 到 1.0：Lv5 时前半段几乎实心白亮）
		var a := clampf((0.30 + 0.70 * k) * wmul, 0.0, 1.0)
		var jag := GameStats.LIGHTNING_FX_JAG * jmul
		var segs := maxi(2, GameStats.LIGHTNING_FX_SEGS)
		var n := to_pt - from_pt
		var perp := Vector2(-n.y, n.x).normalized()
		var pts := PackedVector2Array()
		for i in segs + 1:
			var t := float(i) / float(segs)
			var pt := from_pt.lerp(to_pt, t)
			if i > 0 and i < segs:
				pt += perp * randf_range(-jag, jag)
			pts.append(pt)
		draw_polyline(pts, Color(tint.r, tint.g, tint.b, a * 0.55), 7.0 * wmul, true)
		draw_polyline(pts, Color(tint.r, tint.g, tint.b, a), 3.0 * wmul, true)
		draw_polyline(pts, Color(1, 1, 1, a * 0.9), 1.2 * wmul, true)


## 冰霜新星的蓝圈：从玩家位置扩散到目标半径，0.3s 淡出。
## 每级可见锚点：冰晶刺数 6→8→10（Stats.ICE_VIS_SPIKES，Lv3/Lv5 各跳一档），
## 另外半径本身逐级 90→100→110→120→140（tier 表），所以五级都看得出变化。
class IceNovaFX extends Node2D:
	var tint := Color(0.55, 0.85, 1.0)
	var radius := 90.0
	var life := 0.3
	var life_max := 0.3
	## 0 基视觉等级（Lv1 = 0）
	var vlevel: int = 0

	func _process(delta: float) -> void:
		life -= delta
		if life <= 0.0:
			queue_free()
			return
		queue_redraw()

	func _draw() -> void:
		var k := 1.0 - clampf(life / maxf(0.001, life_max), 0.0, 1.0)
		var r := radius * (0.35 + 0.65 * k)
		var a := 0.60 * (1.0 - k)
		# 表长 5 = max_level，clamp 只是防御（等级异常时不要越界崩）
		var spikes := GameStats.ICE_VIS_SPIKES[clampi(vlevel, 0, GameStats.ICE_VIS_SPIKES.size() - 1)]
		draw_circle(Vector2.ZERO, r, Color(tint.r, tint.g, tint.b, a * 0.25))
		draw_arc(Vector2.ZERO, r, 0.0, TAU, 48, Color(tint.r, tint.g, tint.b, a), 3.0, true)
		# 内圈冰晶感：等级越高刺越多（6 / 8 / 10）
		var n := maxi(1, spikes)
		for i in n:
			var ang := TAU * float(i) / float(n)
			var d := Vector2(cos(ang), sin(ang))
			draw_line(d * r * 0.62, d * r * 0.92, Color(0.85, 0.96, 1.0, a * 0.8), 2.0, true)


## 毒云：绿色半透明圆 + 边缘冒泡（程序动画），末段淡出。
## 每级可见锚点：边缘气泡数 4→8（Stats.ACID_VIS_BUBBLES）、填充浓度逐级加深。
class AcidPoolFX extends Node2D:
	var tint := Color(0.45, 0.85, 0.35)
	var radius := 60.0
	var life := 2.0
	var life_max := 2.0
	## 0 基视觉等级（Lv1 = 0）
	var vlevel: int = 0
	var _t := 0.0

	func _process(delta: float) -> void:
		_t += delta
		life -= delta
		if life <= 0.0:
			queue_free()
			return
		queue_redraw()

	## 淡出权重 1.0 → 0.0（单一源：_draw 与探针都读它，避免公式两处各写一遍）。
	## 规则 = 只淡【末 30%】寿命（Stats.ACID_POOL_FADE_TAIL）：
	## 旧版 fade = life/life_max 是全程线性变淡，寿命过半就只剩一半浓度，
	## 玩家会以为毒池提前消失了（实际还在掉血）—— 画面与伤害窗口对不上。
	## 现在前 70% 保持满浓度，最后一小段才收掉。
	func fade_weight() -> float:
		var tail := GameStats.ACID_POOL_FADE_TAIL
		var prog := 1.0 - clampf(life / maxf(0.001, life_max), 0.0, 1.0)   # 0=刚生成 1=即将消失
		if prog <= 1.0 - tail:
			return 1.0
		return clampf((1.0 - prog) / maxf(0.001, tail), 0.0, 1.0)

	func _draw() -> void:
		var fade := fade_weight()
		var fill := GameStats.ACID_VIS_FILL_ALPHA \
			+ GameStats.ACID_VIS_FILL_ALPHA_PER_LV * float(vlevel)
		var bubbles := GameStats.ACID_VIS_BUBBLES[
			clampi(vlevel, 0, GameStats.ACID_VIS_BUBBLES.size() - 1)]
		draw_circle(Vector2.ZERO, radius, Color(tint.r, tint.g, tint.b, fill * fade))
		draw_arc(Vector2.ZERO, radius, 0.0, TAU, 40, Color(tint.r, tint.g, tint.b, 0.55 * fade), 2.0, true)
		var n := maxi(1, bubbles)
		for i in n:
			var ang := TAU * float(i) / float(n) + _t * 0.9
			var rr := radius * (0.5 + 0.42 * fposmod(_t * 0.55 + float(i) * 0.29, 1.0))
			draw_circle(Vector2(cos(ang), sin(ang)) * rr, 3.2,
				Color(0.72, 1.0, 0.62, 0.5 * fade))


## 追踪导弹本体：贴图（头朝上）+ 程序化火焰尾迹。
## 位置与 rotation 由 ExtraWeaponSystem 每帧驱动，这里只负责画。
## 每级可见锚点：弹体尺寸 40→50px（Stats.MISSILE_VIS_SIZE_*），
## 整块绘制（含尾焰）统一走 draw_set_transform 缩放 —— 只改观感，命中半径仍是 MISSILE_RADIUS。
class MissileFX extends Node2D:
	var tint := Color(0.86, 0.95, 0.78)
	var tex: Texture2D = null
	## 0 基视觉等级（Lv1 = 0）
	var vlevel: int = 0
	var _t := 0.0

	func _vis_size() -> float:
		return GameStats.MISSILE_VIS_SIZE_BASE \
			+ GameStats.MISSILE_VIS_SIZE_PER_LV * float(vlevel)

	func _process(delta: float) -> void:
		_t += delta
		queue_redraw()   # 尾焰抖动需要每帧重绘

	func _draw() -> void:
		# 几何仍按 40px 基准写死，整体缩放 k —— 调基准值不必逐个改点
		var k := _vis_size() / GameStats.MISSILE_VIS_SIZE_BASE
		draw_set_transform(Vector2.ZERO, 0.0, Vector2(k, k))
		# 局部 +Y = 机尾（节点 rotation 已把贴图「头朝上」转到飞行方向）
		var tail := 15.0 + 6.0 * sin(_t * 28.0)
		draw_colored_polygon(PackedVector2Array([
			Vector2(-5.0, 17.0), Vector2(5.0, 17.0), Vector2(0.0, 17.0 + tail),
		]), Color(1.0, 0.72, 0.25, 0.9))
		draw_circle(Vector2(0.0, 17.0 + tail * 0.45), 4.5, Color(1.0, 0.38, 0.20, 0.5))
		var drew := false
		if tex != null:
			var tw := float(tex.get_width())
			var th := float(tex.get_height())
			if tw > 0.0 and th > 0.0:
				# 按高度缩放到基准 40px（源图是竖向的 148×256），中心对齐节点原点；
				# 外层的 k 再把它拉到本等级的目标尺寸
				var s := GameStats.MISSILE_VIS_SIZE_BASE / th
				draw_texture_rect(tex, Rect2(Vector2(-tw, -th) * 0.5 * s, Vector2(tw, th) * s), false)
				drew = true
		if not drew:
			draw_circle(Vector2.ZERO, 9.0, tint)
			draw_circle(Vector2.ZERO, 4.0, Color(1, 1, 1, 0.85))
		draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


## 导弹爆炸：橙色冲击圈扩散 + 淡出。
class BlastFX extends Node2D:
	var tint := Color(1.0, 0.72, 0.35)
	var radius := 50.0
	var life := 0.28
	var life_max := 0.28

	func _process(delta: float) -> void:
		life -= delta
		if life <= 0.0:
			queue_free()
			return
		queue_redraw()

	func _draw() -> void:
		var k := 1.0 - clampf(life / maxf(0.001, life_max), 0.0, 1.0)
		var r := radius * (0.35 + 0.65 * k)
		var a := 0.8 * (1.0 - k)
		draw_circle(Vector2.ZERO, r, Color(1.0, 0.62, 0.24, a * 0.40))
		draw_arc(Vector2.ZERO, r, 0.0, TAU, 40, Color(1.0, 0.86, 0.5, a), 3.0, true)
		draw_arc(Vector2.ZERO, r * 0.62, 0.0, TAU, 32, Color(1.0, 1.0, 0.85, a * 0.7), 1.6, true)
