extends SceneTree
## 独立验证探针：磁铁掉落 + 限时全场磁吸（参考 C3 掉落三件套）。
##
## 被验证的契约：
##   Stats.MAGNET_DROP_CHANCE / MAGNET_ALL_DURATION
##   Pickup.KIND_MAGNET（图元占位常态，无 push_warning 刷屏）
##   CombatResolver.collect(magnet) → player.magnet_all_t = MAGNET_ALL_DURATION
##   CombatResolver.process_pickups：magnet_all_t > 0 时全场掉落物无视拾取范围被磁吸
##   CombatResolver.cleanup_enemies：Elite/Boss 击杀必掉磁铁（普通怪按 MAGNET_DROP_CHANCE 概率）
##   Player：magnet_all_t 随时间衰减、reset() 归零
##
## 用法: godot --headless --path <项目> --script res://scripts/dev/_ProbeMagnet.gd
## 退出码 0=PASS 1=FAIL（门禁用 grep -q "RESULT=PASS" 判定）

const DT := 1.0 / 60.0
const FAR := Vector2(600.0, 0.0)     # 远超拾取范围（pickupRange 基准 36）

var battle: Node = null
var armed := false
var finished := false
var checks := 0
var fails: Array[String] = []


func _initialize() -> void:
	print("[PROBE] === 磁铁掉落 + 全场磁吸验证（C3 掉落三件套）===")
	var packed: PackedScene = load("res://scenes/battle/Battle.tscn")
	if packed == null:
		_finish("Battle.tscn 加载失败")
		return
	battle = packed.instantiate()
	root.add_child(battle)
	var s = load("res://scripts/data/Stats.gd")
	if s != null:
		_stats_inst = s.new()


var _stats_inst = null


func _arm() -> void:
	armed = true
	var stats_inst = _stats_inst

	# ---- A. 静态契约 ----
	_check(float(_stats_inst.MAGNET_ALL_DURATION) > 0.0, "MAGNET_ALL_DURATION > 0（实际 %s）" % str(_stats_inst.MAGNET_ALL_DURATION))
	var chance := float(_stats_inst.MAGNET_DROP_CHANCE)
	_check(chance > 0.0 and chance < 1.0, "MAGNET_DROP_CHANCE ∈ (0,1)（实际 %s）" % str(chance))

	battle.start_run()
	battle.spawn_remaining = 0
	var pl: Node2D = battle.player
	pl.autopilot = false
	pl.atk = 0.0
	pl.god_mode = true

	# ---- B. 对照组：无磁吸状态，远处掉落物不被磁吸 ----
	var combat = battle.combat
	combat.spawn_pickup(Pickup.KIND_GOLD, 5, pl.global_position + FAR)
	var far_pk: Node = battle.pickups[battle.pickups.size() - 1]
	var d0: float = far_pk.global_position.distance_to(pl.global_position)
	for i in 30:
		combat.process_pickups(DT)
	var d1: float = far_pk.global_position.distance_to(pl.global_position)
	_check(not bool(far_pk.magnetized) and absf(d1 - d0) <= 0.001,
		"对照组：无磁吸时远处掉落物不动（%.1f → %.1f）" % [d0, d1])

	# ---- C. 拾取磁铁 → 获得全场磁吸时长 ----
	combat.spawn_pickup(Pickup.KIND_MAGNET, 0, pl.global_position + Vector2(40.0, 0.0))
	var mag_pk: Node = battle.pickups[battle.pickups.size() - 1]
	_check(String(mag_pk.kind) == "magnet", "磁铁掉落物 kind == magnet")
	combat.collect(mag_pk)
	_check(_approx(float(pl.magnet_all_t), float(_stats_inst.MAGNET_ALL_DURATION)),
		"拾取磁铁后 magnet_all_t %.2f == MAGNET_ALL_DURATION" % float(pl.magnet_all_t))

	# ---- D. 端到端：磁吸期间，拾取范围外的掉落物也被吸走 ----
	combat.spawn_pickup(Pickup.KIND_GOLD, 5, pl.global_position + FAR)
	var far2: Node = battle.pickups[battle.pickups.size() - 1]
	var d2: float = far2.global_position.distance_to(pl.global_position)
	for i in 30:
		combat.process_pickups(DT)
	var d3: float = far2.global_position.distance_to(pl.global_position)
	_check(bool(far2.magnetized) and d3 < d2,
		"全场磁吸生效：范围外掉落物被磁吸（%.1f → %.1f）" % [d2, d3])

	# ---- E. 计时衰减（手动步进 Player，与真实帧率无关）----
	pl.set_physics_process(false)
	var before := float(pl.magnet_all_t)
	for i in 60:
		pl._physics_process(DT)
	_check(float(pl.magnet_all_t) < before and float(pl.magnet_all_t) > before - 1.5,
		"磁吸计时随时间衰减（%.2f → %.2f，60 帧 ≈ 1 秒）" % [before, float(pl.magnet_all_t)])
	pl.set_physics_process(true)

	# ---- F. 精英击杀必掉磁铁（确定性：直接走 cleanup_enemies 结算路径）----
	battle._spawn_enemy("Elite", pl.global_position + Vector2(500.0, 0.0))
	var elite: Node = battle.enemies[battle.enemies.size() - 1]
	elite.is_dead = true
	var magnets_before := _count_magnets()
	combat.cleanup_enemies()
	_check(_count_magnets() > magnets_before, "精英击杀必掉磁铁（cleanup_enemies 结算路径）")

	# ---- G. start_run 归零 ----
	battle.start_run()
	battle.spawn_remaining = 0
	_check(_approx(float(battle.player.magnet_all_t), 0.0), "start_run 后磁吸计时归零")


func _count_magnets() -> int:
	var n := 0
	for pk in battle.pickups:
		if is_instance_valid(pk) and String(pk.kind) == "magnet":
			n += 1
	return n


func _approx(a: float, b: float) -> bool:
	return absf(a - b) <= maxf(1e-4, 1e-5 * maxf(absf(a), absf(b)))


func _check(cond: bool, label: String) -> void:
	checks += 1
	if cond:
		print("[PROBE]   OK   %s" % label)
	else:
		fails.append(label)
		print("[PROBE]   FAIL %s" % label)


func _process(_delta: float) -> bool:
	if finished:
		return true
	if not armed:
		_arm()
		_finish("")
		return true
	return true


func _finish(msg: String) -> void:
	if finished:
		return
	finished = true
	if msg != "":
		print("[PROBE] 提前终止：%s" % msg)
	print("[PROBE] 断言 %d/%d 通过（失败 %d）" % [checks - fails.size(), checks, fails.size()])
	for f in fails:
		print("[PROBE]   - %s" % f)
	print("[PROBE] RESULT=%s" % ("PASS" if fails.is_empty() else "FAIL"))
	quit(0 if fails.is_empty() else 1)
