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
	if owned_count() >= GameStats.MAX_EXTRA_WEAPONS:
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
		match String(GameStats.EXTRA_WEAPON_DEFS[wid]["behavior"]):
			"lightning":
				_cd[wid] = float(t["interval"])
				_cast_lightning(p, t)
			"ice_nova":
				_cd[wid] = float(t["interval"])
				_cast_ice_nova(p, t)
			"acid":
				_cd[wid] = float(t["interval"])
				_cast_acid(p, t)
			"missile":
				_cd[wid] = float(t["interval"])
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
	for tt in targets:
		var start: Enemy = tt
		used[start.get_instance_id()] = true
		_strike_lightning(start, dmg, tint)
		var cur := start
		for _c in maxi(0, int(t["chains"]) - 1):
			var nx := _nearest_enemy_of(cur.global_position, GameStats.LIGHTNING_CHAIN_RANGE, used)
			if nx == null:
				break
			used[nx.get_instance_id()] = true
			_strike_lightning(nx, dmg, tint)
			cur = nx


## 劈一击：伤害 + 天上劈到目标头顶的锯齿闪电（程序化，无贴图）。
func _strike_lightning(e: Enemy, dmg: int, tint: Color) -> void:
	var fx := LightningFX.new()
	fx.life = GameStats.LIGHTNING_FX_TIME
	fx.life_max = fx.life   # 质检 P1-1：寿命与淡出基准必须同步（旧版靠常量数值巧合对齐）
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
	if _levels.has("orbit"):
		var t := GameStats.extra_weapon_tier("orbit", int(_levels["orbit"]))
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
		if _b != null and _b.world != null:
			_b.world.add_child(b)
		_blades.append(b)
		_blade_hits.append({})


# ================================================================ 程序化特效（无贴图）
## 环绕飞刃的刀。有贴图用贴图（刀尖朝 +X），否则画一把程序化短刀。
## 节点 rotation 由系统设为切线方向，所以这里只需要把刀画在 +X 方向。
class BladeFX extends Node2D:
	var tint := Color(1.0, 0.62, 0.22)
	var tex: Texture2D = null

	func _draw() -> void:
		if tex != null:
			var tw := float(tex.get_width())
			var th := float(tex.get_height())
			if tw > 0.0 and th > 0.0:
				# 目标视觉长度 46px，按贴图原比例缩放，中心对齐节点原点
				var s := 46.0 / tw
				draw_texture_rect(tex, Rect2(Vector2(-tw, -th) * 0.5 * s, Vector2(tw, th) * s), false)
				return
		# 程序化短刀：细长刀身（+X 为刀尖）+ 护手 + 柄
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


## 闪电链的锯齿折线：0.15s 内淡出。两端点都是【世界坐标】（节点留在原点）。
class LightningFX extends Node2D:
	var tint := Color(0.75, 0.9, 1.0)
	var from_pt := Vector2.ZERO
	var to_pt := Vector2.ZERO
	var life := 0.15
	var life_max := 0.15

	func _process(delta: float) -> void:
		life -= delta
		if life <= 0.0:
			queue_free()
			return
		queue_redraw()

	func _draw() -> void:
		var k := clampf(life / maxf(0.001, life_max), 0.0, 1.0)
		var a := 0.30 + 0.70 * k
		var segs := maxi(2, GameStats.LIGHTNING_FX_SEGS)
		var n := to_pt - from_pt
		var perp := Vector2(-n.y, n.x).normalized()
		var pts := PackedVector2Array()
		for i in segs + 1:
			var t := float(i) / float(segs)
			var pt := from_pt.lerp(to_pt, t)
			if i > 0 and i < segs:
				pt += perp * randf_range(-GameStats.LIGHTNING_FX_JAG, GameStats.LIGHTNING_FX_JAG)
			pts.append(pt)
		draw_polyline(pts, Color(tint.r, tint.g, tint.b, a * 0.55), 7.0, true)
		draw_polyline(pts, Color(tint.r, tint.g, tint.b, a), 3.0, true)
		draw_polyline(pts, Color(1, 1, 1, a * 0.9), 1.2, true)


## 冰霜新星的蓝圈：从玩家位置扩散到目标半径，0.3s 淡出。
class IceNovaFX extends Node2D:
	var tint := Color(0.55, 0.85, 1.0)
	var radius := 90.0
	var life := 0.3
	var life_max := 0.3

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
		draw_circle(Vector2.ZERO, r, Color(tint.r, tint.g, tint.b, a * 0.25))
		draw_arc(Vector2.ZERO, r, 0.0, TAU, 48, Color(tint.r, tint.g, tint.b, a), 3.0, true)
		# 内圈冰晶感：六个短刺
		for i in 6:
			var ang := TAU * float(i) / 6.0
			var d := Vector2(cos(ang), sin(ang))
			draw_line(d * r * 0.62, d * r * 0.92, Color(0.85, 0.96, 1.0, a * 0.8), 2.0, true)


## 毒云：绿色半透明圆 + 边缘冒泡（程序动画），按寿命淡出。
class AcidPoolFX extends Node2D:
	var tint := Color(0.45, 0.85, 0.35)
	var radius := 60.0
	var life := 2.0
	var life_max := 2.0
	var _t := 0.0

	func _process(delta: float) -> void:
		_t += delta
		life -= delta
		if life <= 0.0:
			queue_free()
			return
		queue_redraw()

	func _draw() -> void:
		var fade := clampf(life / maxf(0.001, life_max), 0.0, 1.0)
		draw_circle(Vector2.ZERO, radius, Color(tint.r, tint.g, tint.b, 0.26 * fade))
		draw_arc(Vector2.ZERO, radius, 0.0, TAU, 40, Color(tint.r, tint.g, tint.b, 0.55 * fade), 2.0, true)
		for i in 6:
			var ang := TAU * float(i) / 6.0 + _t * 0.9
			var rr := radius * (0.5 + 0.42 * fposmod(_t * 0.55 + float(i) * 0.29, 1.0))
			draw_circle(Vector2(cos(ang), sin(ang)) * rr, 3.2,
				Color(0.72, 1.0, 0.62, 0.5 * fade))


## 追踪导弹本体：贴图（头朝上）+ 程序化火焰尾迹。
## 位置与 rotation 由 ExtraWeaponSystem 每帧驱动，这里只负责画。
class MissileFX extends Node2D:
	var tint := Color(0.86, 0.95, 0.78)
	var tex: Texture2D = null
	var _t := 0.0

	func _process(delta: float) -> void:
		_t += delta
		queue_redraw()   # 尾焰抖动需要每帧重绘

	func _draw() -> void:
		# 局部 +Y = 机尾（节点 rotation 已把贴图「头朝上」转到飞行方向）
		var tail := 15.0 + 6.0 * sin(_t * 28.0)
		draw_colored_polygon(PackedVector2Array([
			Vector2(-5.0, 17.0), Vector2(5.0, 17.0), Vector2(0.0, 17.0 + tail),
		]), Color(1.0, 0.72, 0.25, 0.9))
		draw_circle(Vector2(0.0, 17.0 + tail * 0.45), 4.5, Color(1.0, 0.38, 0.20, 0.5))
		if tex != null:
			var tw := float(tex.get_width())
			var th := float(tex.get_height())
			if tw > 0.0 and th > 0.0:
				# 按高度缩放到 40px（源图是竖向的 148×256），中心对齐节点原点
				var s := 40.0 / th
				draw_texture_rect(tex, Rect2(Vector2(-tw, -th) * 0.5 * s, Vector2(tw, th) * s), false)
				return
		draw_circle(Vector2.ZERO, 9.0, tint)
		draw_circle(Vector2.ZERO, 4.0, Color(1, 1, 1, 0.85))


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
