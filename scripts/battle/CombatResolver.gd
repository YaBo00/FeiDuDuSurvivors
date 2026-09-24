class_name CombatResolver
extends Node
## 战斗结算模块：接触伤害/无敌帧、弹道推进与穿透暴击结算、敌人死亡清理与掉落、
## 空间网格与分离力、掉落物磁吸与收集。
##
## 职责边界（2026-09-19 从 Battle.gd 拆出）：
##   - 管【打中了谁、扣多少血、死了给什么】—— 不管什么时候刷怪（WaveDirector）
##   - 反馈（飘字/爆裂/震屏/音效/hit-stop）通过挂在本模块上的信号发出，
##     由 Battle 转交给 feedback / audio / camera —— 本模块不直接持有它们
##
## 状态归属（关键）：enemies / projectiles / pickups / kills 等【共享黑板】仍住在
## Battle 上 —— 5 个门禁探针直接读写这些字段（_ProbeRangedBoss 会写
## battle.projectiles、读 battle.enemies；_ProbePickupExpiry 读 battle.pickups）。
## 本模块通过 setup() 注入的 _b 句柄操作同一份数据，语义零变化。

## 伤害飘字请求：(位置, 文本, 颜色, 是否放大)
signal float_requested(pos: Vector2, text: String, color: Color, big: bool)
## 击杀爆裂请求：(位置, 颜色, 是否放大)
signal burst_requested(pos: Vector2, color: Color, big: bool)
## 音效请求：(音效名, 音量dB, 音调微调)
signal sfx_requested(name: String, volume_db: float, pitch: float)
## 震屏请求（无参数，Battle 用默认强度）
signal shake_requested()
## 请求短暂 hit-stop（暴击击杀）
signal hitstop_requested()
## 玩家死亡（由接触伤害或敌方弹道触发）→ Battle 走失败结算
signal player_died()

## 空间网格：cell -> 敌人引用数组。分离力与弹道碰撞共用（P0-1 / P1-20）。
var _grid: Dictionary = {}
## 飘字节流：同类飘字间隔（秒），避免怪堆里刷屏把池子打满。
## 与 Battle.FLOAT_THROTTLE 同值（跨文件 const 引用在双向 class_name 下不稳，故本地复刻）。
const FLOAT_THROTTLE := 0.25
## 分离力的执行频率与配对预算：
## 本工程物理跑 360 帧/秒（自检加速），预算只有 ~2.8ms/tick；
## 密集怪群下两两配对是 O(n²)，实测一次就把物理帧顶到 405ms。
## 所以：每 3 个物理帧做一次（视觉上足够顺滑），且每次最多 SEP_BUDGET 次配对检查。
const SEP_EVERY := 3
const SEP_BUDGET := 2400
var _sep_tick := 0
## 闪避/受击飘字的节流时间戳（秒）
var _last_dodge_float := -10.0
var _last_hurt_float := -10.0

## 【穿透语义修复 T-CHAR-04】逐弹道已命中敌人表：
##   键 = 弹道 instance_id，值 = 该弹已命中敌人的 instance_id 集合。
##
## 为什么需要：pierce_cap 的设计语义是「单颗弹道最多穿透【多少个不同的敌人】」，
## 但旧实现只做命中事件计数（pierced += 1），没有逐敌人去重 ——
## 弹速 ~360-675 px/s ≈ 6-11 px/帧，而重叠区直径（敌半径+弹半径）≈ 30-50px，
## 同一颗弹会在同一只怪身上停留 3~8 帧，把 pierce_cap 全部烧在同一只怪上反复扣血
## （实测：土豆 pierce=3 的重弹对一只 hp22 的 Slime 打出 2×15=30 —— 质量线疑点根因）。
##
## 状态放本模块而不是 Projectile：文件所有权限定只改本文件，且弹道在别处
## （Battle._clear_all / _end_run / life 到期）也可能被释放 —— 每帧开头
## _prune_proj_hits() 兜底清扫失效键，不泄漏不悬挂。
var _proj_hits: Dictionary = {}

var _b: Node = null


## 注入宿主（Battle）。本模块不反向依赖 Battle 的类型，只按约定读写其字段/方法。
func setup(battle: Node) -> void:
	_b = battle


## 重开一局时复位本模块的状态（飘字节流 + 分离计数 + 网格 + 弹道命中表）。
func reset() -> void:
	_last_dodge_float = -10.0
	_last_hurt_float = -10.0
	_sep_tick = 0
	_grid.clear()
	_proj_hits.clear()


## 飘字统一出口（2026-09-22 设置菜单）：所有战斗飘字都经这里发出。
## 「伤害数字」开关关掉时直接吞掉，不再 emit —— 池子不产生任何飘字。
## 设置值走 MetaSave 的缓存（非文件 IO），在每次命中/受击的热路径上调用也无压力。
func _float(pos: Vector2, text: String, color: Color, big: bool) -> void:
	if not bool(MetaSave.get_setting("show_floats")):
		return
	float_requested.emit(pos, text, color, big)


## 清扫 _proj_hits 里弹道已释放的条目（防跨帧悬挂键累积）。
## 对象释放路径有三处：本函数内 advance 到期 / 消耗回收，以及 Battle._clear_all /
## _end_run 的批量 queue_free —— 这里统一兜底，无需每条路径都记得擦表。
func _prune_proj_hits() -> void:
	for k in _proj_hits.keys():
		var obj: Object = instance_from_id(int(k))
		if obj == null or not is_instance_valid(obj):
			_proj_hits.erase(k)


## 【已删除 tick()（质检 P2-1，2026-09-22）】本函数曾是「战斗主 tick 的战斗部分」的
## 一站式封装，但全工程没有任何调用方 —— Battle._tick_fighting 手写了同一序列。
## 且其内部写 `_b.live_max`，而 Battle 上并无该字段（真身在 WaveDirector，
## Battle 用的是 `wave.live_max`）—— 一旦被调用就是运行时报错的「接口漂移」死代码。
## 删除后主战斗序列只剩 Battle._tick_fighting 一条真路径（顺序敏感，勿在那边乱动）。


## 重建空间网格 + 按预算节奏执行分离力（与弹道碰撞共用同一次网格重建）。
func space_and_separate() -> void:
	rebuild_grid()
	_sep_tick += 1
	if _sep_tick % SEP_EVERY == 0:
		separate_enemies()


## 敌人接触伤害（H5 原式：dodge → i-frame → max(1, dmg - def*0.5)）。
func contact_damage() -> void:
	# 用空间网格查邻近敌人（A5），不再全表扫描。
	# 注意：这里跑在 rebuild_grid() 之前，用的是上一帧的网格 —— 对接触判定无影响。
	#
	# 【A8 迭代】接触伤害 = 「同帧求和 + 封顶」。旧实现逐怪 take_hit，但玩家无敌帧会吞掉
	# 第一击之后的全部伤害 ⇒ 被围 10 只和被 1 只贴身一样痛（且吃哪只取决于遍历顺序，非确定）。
	# 新语义：先收集所有接触中的敌人，总伤 = Σ各怪伤害，封顶 = 单只最痛 × CONTACT_DMG_CAP_MULT；
	# 然后【一次】take_hit —— 一次闪避判定、一个无敌帧窗口、一条飘字/一次震屏，行为可预期。
	var sum := 0
	var worst := 0
	var touched := false
	var contacted: Array = []
	for e in nearby_enemies(_b.player.global_position):
		if e.is_dead:
			continue
		if e.global_position.distance_to(_b.player.global_position) < e.radius + Player.RADIUS:
			touched = true
			contacted.append(e)
			sum += int(e.dmg)
			worst = maxi(worst, int(e.dmg))
	if not touched:
		return
	if worst > 0:
		sum = mini(sum, worst * GameStats.CONTACT_DMG_CAP_MULT)
	var r: Dictionary = _b.player.take_hit(sum)
	var res := String(r["result"])
	# 反甲（2026-09-20 升级/商店扩充）：真实受击（hit/dead）时按各接触怪【自身伤害】比例反弹。
	# 闪避 / 无敌帧不触发 —— 没真挨打就没有反伤。击杀入账仍由 cleanup_enemies 统一处理
	# （这里只调 take_damage，不重复走击杀侧效应）。
	if _b.player.thorns > 0.0 and (res == "hit" or res == "dead"):
		for e in contacted:
			if e.is_dead:
				continue
			var back := maxi(1, roundi(float(e.dmg) * _b.player.thorns))
			e.take_damage(back)
			e.last_hit_crit = false
			_float(e.global_position + Vector2(0, -e.radius * 0.6),
				str(back), Color(0.55, 1.0, 0.58), false)
	# A1：闪避/受击飘字都做节流。站在怪堆里时 60 帧/秒会疯狂触发，
	# 28 个飘字池瞬间被打满、互相覆盖，什么都看不清。
	if res == "dodge" and _b._game_time - _last_dodge_float >= FLOAT_THROTTLE:
		_last_dodge_float = _b._game_time
		_float(_b.player.global_position + Vector2(0, -34.0), "闪避",
			Color(0.68, 0.90, 1.0), false)
		sfx_requested.emit("dodge", -6.0, 1.0)
	if res == "hit" or res == "dead":
		shake_requested.emit()
		# A6：玩家受击也飘红色数字（和敌人飘字对称）
		if _b._game_time - _last_hurt_float >= FLOAT_THROTTLE:
			_last_hurt_float = _b._game_time
			_float(_b.player.global_position + Vector2(0, -44.0),
				"-%d" % int(r["dmg"]), Color(1.0, 0.35, 0.30), false)
			sfx_requested.emit("hurt", -4.0, 1.0)
	if res == "dead":
		player_died.emit()


## 弹道推进与命中结算：敌方弹道只判玩家命中，玩家弹道走暴击/穿透/吸血。
func process_projectiles(delta: float) -> void:
	_prune_proj_hits()
	var remaining: Array[Projectile] = []
	for proj in _b.projectiles:
		if not proj.advance(delta):
			_proj_hits.erase(proj.get_instance_id())
			proj.queue_free()
			continue
		# ---- 敌方弹道（远程怪/Boss）：只判玩家命中，绝不参与敌我伤害 ----
		if not proj.from_player:
			if proj.position.distance_to(_b.player.global_position) < Player.RADIUS + proj.radius:
				var r: Dictionary = _b.player.take_hit(proj.damage)
				var res := String(r["result"])
				# 反馈与接触伤害完全一致（闪避蓝字 / 受击红字都走节流）
				if res == "dodge" and _b._game_time - _last_dodge_float >= FLOAT_THROTTLE:
					_last_dodge_float = _b._game_time
					_float(_b.player.global_position + Vector2(0, -34.0), "闪避",
						Color(0.68, 0.90, 1.0), false)
				if res == "hit" or res == "dead":
					shake_requested.emit()
					if _b._game_time - _last_hurt_float >= FLOAT_THROTTLE:
						_last_hurt_float = _b._game_time
						_float(_b.player.global_position + Vector2(0, -44.0),
							"-%d" % int(r["dmg"]), Color(1.0, 0.35, 0.30), false)
						sfx_requested.emit("hurt", -4.0, 1.0)
				proj.queue_free()
				if res == "dead":
					player_died.emit()
					return
				continue
			remaining.append(proj)
			continue
		var consumed := false
		# 本弹的已命中集合（首次命中时惰性建表）。proj 来自无类型数组 → Variant，
		# get_instance_id() 的返回必须显式标注 int（Variant 推断坑）。
		var pid: int = proj.get_instance_id()
		if not _proj_hits.has(pid):
			_proj_hits[pid] = {}
		var hits: Dictionary = _proj_hits[pid]
		for e in nearby_enemies(proj.position):
			if e.is_dead:
				continue
			# 【穿透语义修复 T-CHAR-04】同一颗弹道对同一个敌人只结算一次：
			# 慢速大弹会在重叠区里停留多帧，不去重就会对同一目标反复扣血。
			if hits.has(e.get_instance_id()):
				continue
			if proj.position.distance_to(e.global_position) < e.radius + proj.radius:
				var res: Dictionary = GameStats.player_damage(proj.damage, proj.crit, proj.critd, e.defense)
				# 中毒易伤（毒云 Lv5）在这条路径一并生效 —— 无中毒时原样返回，
				# 既有伤害数值逐位不变（回归红线）。
				var dmg: int = _vuln_adjust(int(res["dmg"]), e as Enemy)
				e.take_damage(dmg)
				e.last_hit_crit = bool(res["is_crit"])
				sfx_requested.emit("hit", -8.0, 1.0)
				# 伤害飘字：暴击橙色放大，普通白色
				_float(e.global_position + Vector2(0, -e.radius * 0.6),
					str(dmg),
					Color(1.0, 0.62, 0.18) if res["is_crit"] else Color(1, 1, 1),
					bool(res["is_crit"]))
				if proj.lifesteal > 0.0:
					_b.player.heal(float(dmg) * proj.lifesteal)
				# 【金币镖】命中时按概率在命中位置掉一枚金币。
				# 面额 = WEAPON_GOLD_ON_HIT_VALUE × harvest 取整，最少 1（金融嘉豪 harvest 1.5 → 2 元）。
				if proj.gold_on_hit > 0.0 and randf() < proj.gold_on_hit:
					spawn_pickup(Pickup.KIND_GOLD,
						maxi(1, roundi(float(GameStats.WEAPON_GOLD_ON_HIT_VALUE)
							* float(_b.player.harvest))),
						e.global_position)
				proj.pierced += 1
				hits[e.get_instance_id()] = true
				# 【爆裂薯块】命中溅射（potato 第二形态）：以命中点为圆心，对 aoe_radius
				# 内【其他】敌人结算 直接伤害 × aoe_pct。
				# 溅射不吃暴击/吸血/金币镖、不消耗 pierce；目标记入本弹已命中集合 ——
				# 慢速大弹在重叠区停留多帧也不会对同一目标重复溅射（与穿透去重同表）。
				# GRID_CELL=96 ≥ 最大溅射半径 90，nearby_enemies 的 3x3 查询保证全覆盖。
				if proj.aoe_radius > 0.0 and proj.aoe_pct > 0.0:
					# 溅射基数用【实扣伤害 dmg】（已含中毒易伤），与直接命中同口径
					var splash := maxi(1, roundi(float(dmg) * proj.aoe_pct))
					for oe in nearby_enemies(e.global_position):
						if oe.is_dead or oe == e:
							continue
						if hits.has(oe.get_instance_id()):
							continue
						if oe.global_position.distance_to(e.global_position) > proj.aoe_radius:
							continue
						hits[oe.get_instance_id()] = true
						oe.take_damage(splash)
						oe.last_hit_crit = false
						_float(oe.global_position + Vector2(0, -oe.radius * 0.6),
							str(splash), Color(1.0, 0.84, 0.35), false)
				# 穿透判定读【逐弹道】pierce_cap，不是全局 PROJ_PIERCE ——
				# 忧郁嘉豪暗影弹 pierce=99（贯穿全屏）就是靠这条生效。
				if proj.pierced >= proj.pierce_cap:
					consumed = true
					break
		if consumed:
			_proj_hits.erase(pid)
			proj.queue_free()
		else:
			remaining.append(proj)
	_b.projectiles = remaining


## 非弹道来源的伤害统一入口（副武器：环绕飞刃 / 闪电链 / 冰霜新星 / 毒云，2026-09-22）。
##
## 与弹道命中走【同一套】结算：暴击判定 → 护甲减免 → 中毒易伤 → 飘字 → 命中音效。
## 这样副武器自动吃到玩家的 atk / crit / critd 与敌人的护甲，不会自成一套数值。
## 刻意【不做】吸血与金币镖：那是主角武器/道具的词条（文档 §6「不要动主角武器」）。
##
## 返回实扣伤害（0 = 目标无效 / 已死）；击杀侧效仍由 cleanup_enemies 统一处理。
func deal_extra_damage(e: Enemy, raw: int, tint: Color, big: bool = false) -> int:
	if e == null or not is_instance_valid(e) or e.is_dead or raw <= 0:
		return 0
	var p: Player = _b.player
	var res: Dictionary = GameStats.player_damage(raw, p.crit, p.critd, e.defense)
	var dmg := _vuln_adjust(int(res["dmg"]), e)
	e.take_damage(dmg)
	e.last_hit_crit = bool(res["is_crit"])
	sfx_requested.emit("hit", -10.0, 1.0)
	# 飘字用武器自己的底色 —— 玩家一眼能分辨「这刀是副武器打的」还是主角武器打的
	_float(e.global_position + Vector2(0, -e.radius * 0.6), str(dmg),
		Color(1.0, 0.62, 0.18) if res["is_crit"] else tint,
		bool(res["is_crit"]) or big)
	return dmg


## 中毒易伤（毒云 Lv5）：受击伤害 × Enemy.incoming_vuln_mul()。
## 无中毒恒 ×1.0，且这里【提前返回】—— 既有伤害路径一个浮点乘法都不增加，
## 数值逐位不变（回归红线）。
func _vuln_adjust(dmg: int, e: Enemy) -> int:
	var m := e.incoming_vuln_mul()
	if m <= 1.0:
		return dmg
	return maxi(1, roundi(float(dmg) * m))


## 远程怪 / Boss 开火回调（Enemy.fired_enemy_proj）。
## 生成敌方弹道：慢、粗、红（见 Stats.ENEMY_PROJ_*），命中判定在 process_projectiles。
func on_enemy_fired(pos: Vector2, dir: float, dmg: int) -> void:
	var proj: Projectile = _b.PROJECTILE_SCENE.instantiate()
	_b.world.add_child(proj)
	proj.setup_enemy(pos, dir, dmg)
	_b.projectiles.append(proj)
	# 复用 shoot 音效但更轻更低（缺文件时 play() 静默跳过，不炸）
	sfx_requested.emit("shoot", -14.0, 0.15)


## 玩家开火回调（Player.fired，`count` = player.proj）。
## 按角色武器表（GameStats.WEAPON_DEFS）生成玩家弹道，含扇形散射。
func on_player_fired(aim_pos: Vector2, count: int) -> void:
	sfx_requested.emit("shoot", -12.0, 1.0)
	# _b 是无类型 Node → 属性访问返回 Variant，必须显式标注（Variant 推断坑）
	var player_pos: Vector2 = _b.player.global_position
	var base_ang: float = (aim_pos - player_pos).angle()
	var wid: String = String(_b.player.char_id)
	var w: Dictionary = GameStats.weapon_for_char(wid)
	# 出膛伤害 = atk × 武器 dmg_mul × 全局乘区 × 特性乘区（背水一战）× 武器进化乘区（B2 迭代）。
	# damage_bonus() 夹在暴击判定【之前】，见设计文档 §0.3。
	var dmg: int = roundi(float(_b.player.atk) * float(w["dmg_mul"]) \
		* GameStats.PROJ_DMG_BOOST * float(_b.player.damage_bonus()) \
		* float(_b.player.weapon_damage_mul()))
	# 武器进化·第二形态（2026-09-20）：进化后 weapon_form() 返回形态特性表；
	# 未进化 / 未登记角色返回空字典，下面所有 form.get(...) 全部落默认值
	# ⇒ 未进化角色的出膛参数与旧基线【逐位一致】。
	var form: Dictionary = _b.player.weapon_form()
	# 弹道数公式（四人通用）：shots = base_shots + 形态加成 + player.proj − 1（设计文档 §0.4）。
	# 连珠·二重奏（basic 第二形态）+1。
	var shots: int = int(w["base_shots"]) + int(form.get("shots", 0)) + count - 1
	var radius: float = GameStats.PROJ_RADIUS * float(w["radius_mul"])
	# 穿透：武器表 + 形态加成（贯穿书写 +2）。仍是【逐弹道】pierce_cap 语义。
	var pierce: int = int(w["pierce"]) + int(form.get("pierce", 0))
	# 武器自带吸血 + 玩家吸血 + 形态吸血（暗影汲取 +0.06）【加法合并】，
	# 并同样受 MAX_LIFESTEAL 封顶。只在出膛时相加、绝不进 recalc —— 否则幂等性被破坏。
	var ls: float = minf(GameStats.MAX_LIFESTEAL,
		float(_b.player.lifesteal) + float(w["lifesteal"])
		+ float(form.get("lifesteal", 0.0)))
	# 金币镖概率：武器表 + 形态（贪婪回馈 +0.08），概率自然封顶 1。
	var gold_hit: float = minf(1.0,
		float(w["gold_on_hit"]) + float(form.get("gold_on_hit", 0.0)))
	# 爆裂薯块（potato 第二形态）：命中溅射的半径与比例（0 = 无溅射）。
	var aoe_r: float = float(form.get("aoe_radius", 0.0))
	var aoe_p: float = float(form.get("aoe_pct", 0.0))
	# 进化态优先用第二形态专属弹道（<wid>_evo）；未配置/贴图缺失回落基础弹（没美术也能跑）。
	var visual: Dictionary = {}
	if not form.is_empty():
		visual = AssetDB.weapon_bullet(wid + "_evo")
	if visual.is_empty():
		visual = AssetDB.weapon_bullet(wid)
	# 多弹道间隔角（2026-09-20 用户需求）：默认每发 PROJ_SPREAD；弹道数多到总扇面触顶
	# MAX_PROJ_SPREAD 后，扇面不再变宽，改为压缩每条之间的间隔角。
	# 【中央弹道恒定 2026-09-21 二改（用户拍板）】：中心弹道永远 off=0 不动，新增弹道
	# 成对向左右展开（+s,-s,+2s,-2s,…）—— 任何弹道数量下中心方向始终有一条弹道覆盖，
	# 消除中心盲区。旧版对称散射在偶数 shots 时无中央弹道（最近两条偏 ±step/2），
	# 索敌目标躺在瞄准线上时永远打不中（实测 shots=6 @d314 横偏 ±37.6px > 命中门
	# 19px，残局零命中死锁）。偶数 shots 时最后一条落单，单侧最大 k = shots/2 →
	# 总扇面 = shots×step，封顶分母用 shots（保持总宽 ≤ MAX_PROJ_SPREAD）；
	# 奇数 shots 单侧最大 k = (shots-1)/2，总宽 = (shots-1)×step 与旧版一致 ——
	# 奇数 shots 的弹道角度集合与旧版逐位相同（仅生成顺序不同，同帧无差）。
	var step := GameStats.PROJ_SPREAD
	if shots > 1:
		var slots := float(shots) if shots % 2 == 0 else float(shots - 1)
		step = minf(step, GameStats.MAX_PROJ_SPREAD / slots)
	for i in shots:
		var off := 0.0
		if i > 0:
			# 新增弹道交替落位：k=(i+1)/2（int 整除）→ 1,1,2,2,3,3…；side 右,左,右,左…
			var k: int = (i + 1) / 2
			var side: float = 1.0 if i % 2 == 1 else -1.0
			off = float(k) * step * side
		var proj: Projectile = _b.PROJECTILE_SCENE.instantiate()
		_b.world.add_child(proj)
		proj.setup(player_pos, base_ang + off, dmg,
			_b.player.crit, _b.player.critd, ls,
			float(w["speed_mul"]) * _b.player.proj_speed_mul, radius, pierce, gold_hit, aoe_r, aoe_p)
		# 武器弹道美术（视觉层）：贴图缺失时 Projectile 内部自动回落图元。
		# apply_visual 命中时会用贴图 fallback 覆盖 body_color；没有贴图才用武器表色。
		proj.apply_visual(visual)
		if visual.is_empty():
			proj.body_color = GameStats.weapon_color(wid)
		_b.projectiles.append(proj)


## 清理死亡敌人：计击杀、按 harvest/gold_per_kill 掉金币与经验、爆裂、暴击 hit-stop。
func cleanup_enemies() -> void:
	var remaining: Array[Enemy] = []
	for e in _b.enemies:
		if e.is_dead:
			# 班味炸弹【自爆】不算被击杀（审查 P2）：died_exploded 是 Enemy 在
			# _bomber_brain 引爆时打的标记 —— 战绩里不该出现「玩家没打它也 +1」。
			# 金币/经验掉落照常（掉落语义归 cleanup，与击杀计数解耦）。
			if not e.died_exploded:
				_b.kills += 1
				# 图鉴（2026-09-22）：与 kills 同一个门槛累加每类击杀数（自爆同样不算）。
				_b.note_enemy_kill(String(e.type_name))
			# 精英金币 ×ELITE_GOLD_MUL（2026-09-22 词缀系统，需求 §2.4「在现有 4 金基础上 ×3」）。
			# 乘区放在 harvest 之前：收益/存钱罐等既有加成照常作用在这份更高的基础面额上。
			var gmul: float = GameStats.ELITE_GOLD_MUL if e.type_name == "Elite" else 1.0
			var gv: int = roundi(float(e.gold) * gmul * float(_b.player.harvest)) \
				+ int(_b.player.gold_per_kill)
			spawn_pickup(Pickup.KIND_GOLD, gv, e.global_position)
			# 幸运（2026-09-20 扩充）：把死属性接入掉落 —— 按 luck 概率【额外】掉一枚同面额金币。
			# luck 由「幸运」升级卡提供（10/15/20%）；探针可用 luck=1.0 做确定性断言。
			if _b.player.luck > 0.0 and randf() < _b.player.luck:
				spawn_pickup(Pickup.KIND_GOLD, gv,
					e.global_position + Vector2(randf_range(-12, 12), randf_range(-12, 12)))
			spawn_pickup(Pickup.KIND_XP, e.xp_value,
				e.global_position + Vector2(randf_range(-10, 10), randf_range(-10, 10)))
			# 磁铁掉落（C3 掉落三件套）：精英/Boss 必掉，普通怪小概率 —— 拾取后 8 秒全场磁吸
			if e.type_name == "Elite" or e.type_name == "Boss" \
					or randf() < GameStats.MAGNET_DROP_CHANCE:
				spawn_pickup(Pickup.KIND_MAGNET, 0,
					e.global_position + Vector2(randf_range(-14, 14), randf_range(-14, 14)))
			# 商店券（2026-09-22 词缀系统，需求 §2.4）：精英【必掉】，拾取后下一家商店 8 折。
			# 与磁铁同一次落点抖动，但独立判定 —— 精英身上会同时掉两件，是刻意的「精英奖励感」。
			if e.type_name == "Elite":
				spawn_pickup(Pickup.KIND_COUPON, 0,
					e.global_position + Vector2(randf_range(-16, 16), randf_range(-16, 16)))
			# 死亡爆裂：精英/大怪更大更亮；暴击收掉的最后一下给个短暂 hit-stop
			burst_requested.emit(e.global_position, e.body_color, e.type_name != "Slime")
			sfx_requested.emit("kill", -6.0, 1.0)
			# 击杀台词（2026-09-20）：有身份的敌人被击杀时冒泡告别。
			# 班味炸弹【自爆】死亡不算被击杀（died_exploded），不喊「……没炸成」。
			if not e.died_exploded:
				var death_line := GameStats.enemy_taunt(String(e.type_name), "death")
				if death_line != "":
					_float(e.global_position + Vector2(0.0, -e.radius * 2.4),
						death_line, Color(1.0, 0.55, 0.45), false)
			if e.last_hit_crit:
				hitstop_requested.emit()
			e.queue_free()
		else:
			remaining.append(e)
	_b.enemies = remaining


func spawn_pickup(kind: String, value: int, pos: Vector2) -> void:
	var pk: Pickup = _b.PICKUP_SCENE.instantiate()
	_b.world.add_child(pk)
	pk.setup(kind, value, pos)
	_b.pickups.append(pk)


## 收走一枚掉落物：金币走 add_gold，经验走 gain_xp，各自配音效。
func collect(pk: Pickup) -> void:
	if pk.kind == Pickup.KIND_MAGNET:
		# 磁铁掉落（C3 掉落三件套）：拾取后获得限时全场磁吸
		_b.player.magnet_all_t = GameStats.MAGNET_ALL_DURATION
		_float(_b.player.global_position + Vector2(0, -30.0),
			"全场磁吸!", Color(1.0, 0.35, 0.3), true)
		sfx_requested.emit("coin", -6.0, 1.3)
	elif pk.kind == Pickup.KIND_GOLD:
		_b.player.add_gold(pk.value)
		sfx_requested.emit("coin", -8.0, 1.0)
	elif pk.kind == Pickup.KIND_COUPON:
		# 商店券（2026-09-22 词缀系统）：进下一家商店时由 Battle._open_shop 消费 1 张
		_b.player.shop_coupon += 1
		_float(_b.player.global_position + Vector2(0, -34.0),
			"商店券! 下一家商店 8 折", Color(1.0, 0.85, 0.35), true)
		sfx_requested.emit("coin", -6.0, 1.2)
	else:
		_b.player.gain_xp(pk.value)
		sfx_requested.emit("xp", -12.0, 1.0)
	pk.queue_free()


## 回收场上全部掉落物（波末调用）。与 process_pickups 里的结算逻辑保持一致。
func collect_all_pickups() -> void:
	for pk in _b.pickups:
		collect(pk)
	_b.pickups.clear()


## 重建敌人空间网格（cell -> 敌人引用）。分离力与弹道碰撞共用。
## 存引用而不是下标 —— 清理掉敌人后引用仍然有效（用时再查 is_dead）。
func rebuild_grid() -> void:
	_grid.clear()
	for e in _b.enemies:
		# is_instance_valid 兜底：换波清场等路径会用 queue_free 批量释放敌人，
		# 若网格没同步清空，这里就会踩到已释放对象（见 clear_grid 的说明）。
		if not is_instance_valid(e) or e.is_dead:
			continue
		var cell := Vector2i(int(e.global_position.x / GameStats.GRID_CELL),
			int(e.global_position.y / GameStats.GRID_CELL))
		if not _grid.has(cell):
			_grid[cell] = []
		_grid[cell].append(e)


## 清空空间网格。**敌人大批释放后必须调用**（换波清场 / 重开一局）。
##
## 为什么必须有这个 API：grid 存的是 Enemy 的裸引用，而 `queue_free()` 是延迟释放 ——
## 调用方以为「释放完了」，节点却要到帧末才真的消失。此间网格若还留着这些引用，
## 下一帧 `nearby_enemies()` 一读 `e.is_dead` 就报
## "Invalid access to property 'is_dead' on a base object of type 'previously freed'"。
## 忧郁嘉豪暗影弹 pierce=99，玩家弹道会跨波存活，把这条路径从「偶尔踩到」变成「每波必踩」。
func clear_grid() -> void:
	_grid.clear()


## 查某点附近（3x3 格）的活着的敌人。
func nearby_enemies(pos: Vector2) -> Array:
	var out := []
	var cell := Vector2i(int(pos.x / GameStats.GRID_CELL),
		int(pos.y / GameStats.GRID_CELL))
	for dy in [-1, 0, 1]:
		for dx in [-1, 0, 1]:
			var key := cell + Vector2i(dx, dy)
			if not _grid.has(key):
				continue
			for e in _grid[key]:
				if not is_instance_valid(e):
					continue
				if not e.is_dead:
					out.append(e)
	return out


## 轻量分离力：只推位置、不改移动方向，让怪群「摊开」成有体积的一团。
## 每对只处理一次（按实例 id 排序），推一半给彼此。
func separate_enemies() -> void:
	var budget := SEP_BUDGET
	for e in _b.enemies:
		if not is_instance_valid(e) or e.is_dead:
			continue
		if budget <= 0:
			return
		var cell := Vector2i(int(e.global_position.x / GameStats.GRID_CELL),
			int(e.global_position.y / GameStats.GRID_CELL))
		for dy in [-1, 0, 1]:
			for dx in [-1, 0, 1]:
				var key := cell + Vector2i(dx, dy)
				if not _grid.has(key):
					continue
				for other in _grid[key]:
					budget -= 1
					if budget <= 0:
						return
					if not is_instance_valid(other):
						continue
					if other == e or other.is_dead:
						continue
					if other.get_instance_id() <= e.get_instance_id():
						continue
					# other 来自无类型数组 → 一律显式类型（Variant 推断坑第 5 次）
					var opos: Vector2 = other.global_position
					var orad: float = other.radius
					var d: float = e.global_position.distance_to(opos)
					var min_d: float = (e.radius + orad) * 0.9
					if d >= min_d or d <= 0.001:
						continue
					var push: Vector2 = (e.global_position - opos) / d * (min_d - d) * 0.5
					e.global_position += push
					other.global_position -= push


## 掉落物驱动：磁吸加速飞向玩家，到位结算；未磁吸的靠近拾取范围后开始磁吸。
func process_pickups(delta: float) -> void:
	var remaining: Array[Pickup] = []
	# 全场磁吸（磁铁掉落，参考 C3 掉落三件套）：计时期间无视拾取范围，全场掉落物飞向玩家
	var magnet_all: bool = _b.player.magnet_all_t > 0.0
	for pk in _b.pickups:
		var d: float = pk.global_position.distance_to(_b.player.global_position)
		# 磁吸中：加速飞向玩家，到位才结算 —— 「吸进来的满足感」比瞬间消失好太多
		if pk.magnetized:
			pk.magnet_speed = minf(pk.magnet_speed + GameStats.MAGNET_ACCEL * delta,
				GameStats.MAGNET_SPEED)
			if d > 0.001:
				pk.global_position += (_b.player.global_position - pk.global_position).normalized() \
					* pk.magnet_speed * delta
			if d <= GameStats.MAGNET_COLLECT:
				collect(pk)
			elif pk.advance(delta):
				remaining.append(pk)
			else:
				pk.queue_free()
			continue
		# 拾取范围是【玩家属性】（基准很小，可被升级提升），不是固定常量。
		# 之前用固定 150px，玩家还没走到就隔着老远自动吸走了。
		# 全场磁吸期间：距离判定直接放行（再远的掉落物也吸）。
		if magnet_all or d < _b.player.pickup_range:
			pk.magnetized = true
			pk.magnet_speed = 120.0
			remaining.append(pk)
		elif not pk.advance(delta):
			pk.queue_free()
		else:
			remaining.append(pk)
	_b.pickups = remaining


## 运行期校验：敌人 def 必须为 0，血量不得为 NaN（H5 缺陷红线）。
## 发现异常时置位 Battle 上的观测标志，由自检读取。
func scan_enemies() -> void:
	for e in _b.enemies:
		if e.defense != 0:
			_b._def_seen_bad = true
		if is_nan(float(e.hp)):
			_b._nan_seen = true
