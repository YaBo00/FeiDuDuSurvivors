extends SceneTree
## 独立验证探针（主理人复验用，非工程负责人代码）。
##
## 验证三件事：
##   1. Battle 的 process_pickups 真的调用了 Pickup.advance() —— 用经验掉落物（寿命不变 8s）
##      放在玩家永不可达的场外，等待窗口（12s）内必须消失；
##   2. 金币寿命 ×PICKUP_GOLD_LIFE_MULT（2026-09-20 用户需求）—— 初始 life 必须是
##      PICKUP_LIFE × 2，且窗口结束时仍在场上（12s < 16s 寿命）；
##   3. 回合结束金币回收 —— _end_run 时场上未拾取金币按 GOLD_SALVAGE_RATIO 折半入账
##      （期望值按测试时场上金币总值动态计算，自校准）。
##
## ⚠️ 玩家必须缴械（attack_enabled=false）：不击杀 ⇒ 无掉落、无磁铁掉落（C3 全场磁吸会把
##     场外观测品无视距离吸走收掉）、无升级暂停 —— 窗口时序完全确定。回收断言靠场外观测金币自校准。
##
## 用法: godot --headless --path <项目> --script res://scripts/dev/_ProbePickupExpiry.gd
## 退出码 0=PASS 1=FAIL

const OUTSIDE := Vector2(-500.0, -500.0)
## 等待窗口 12s（2026-09-20 加固）：xp 需 8s【战斗时间】过期、金币寿命 16s 需大于窗口。
## 旧值 9s 只留 1s 余量 —— 全量门禁高负载下（升级暂停吃掉战斗时间）偶尔抖红，放宽到 4s 余量。
const WAIT_SECONDS := 12.0

var battle: Node = null
var probe: Node = null        # xp 掉落物（寿命测试主体）
var gold_probe: Node = null   # 金币掉落物（寿命翻倍断言）
var elapsed := 0.0
var sampled: Array = []
var next_sample := 0.5
var finished := false
var armed := false
var judged := false          # ⚠️ _process 在判定后必须停止工作：否则每帧重入 _judge 刷爆输出
var checks := 0
var fails: Array[String] = []


func _initialize() -> void:
	print("[PROBE] 载入 Battle.tscn")
	var packed: PackedScene = load("res://scenes/battle/Battle.tscn")
	if packed == null:
		_finish(false, "Battle.tscn 加载失败")
		return
	battle = packed.instantiate()
	root.add_child(battle)


## 第一帧才执行：此时 Battle._ready() 已跑过，player 可用。
func _arm() -> void:
	armed = true
	battle.player.autopilot = true
	battle.player.attack_enabled = false   # 缴械：不击杀 ⇒ 无磁铁掉落/无全场磁吸/无升级暂停（观测确定性）
	battle.player.god_mode = true   # 无敌：杜绝窗口内玩家死亡触发 _end_run 清场，干扰寿命观测
	battle._spawn_pickup("xp", 5, OUTSIDE)
	probe = battle.pickups[battle.pickups.size() - 1]
	battle._spawn_pickup("gold", 7, OUTSIDE)
	gold_probe = battle.pickups[battle.pickups.size() - 1]
	_check(_approx(float(gold_probe.life), GameStats.PICKUP_LIFE * GameStats.PICKUP_GOLD_LIFE_MULT),
		"金币初始寿命 %.1f == PICKUP_LIFE %.1f × %.1f" % [
			float(gold_probe.life), GameStats.PICKUP_LIFE, GameStats.PICKUP_GOLD_LIFE_MULT])
	_check(_approx(float(probe.life), GameStats.PICKUP_LIFE),
		"非金币掉落物寿命不变（%.1f）" % float(probe.life))


func _process(delta: float) -> bool:
	if finished or judged:
		return true
	if not armed:
		_arm()
		if finished:
			return true
		return false

	elapsed += delta

	if elapsed >= next_sample and next_sample <= 5.0:
		next_sample += 0.5
		if is_instance_valid(probe):
			sampled.append("%.1fs life=%.2f" % [elapsed, probe.life])

	if elapsed >= WAIT_SECONDS:
		judged = true
		_judge()
	return false   # ⚠️ return true = 退出主循环；只有 finished/judged 才允许退出


func _judge() -> void:
	var still_listed := false
	for pk in battle.pickups:
		if pk == probe:
			still_listed = true
			break
	_check(not still_listed, "经验掉落物 8 秒寿命耗尽后已从场上移除 → advance() 被调用")

	var gold_alive := is_instance_valid(gold_probe)
	_check(gold_alive, "金币 %d 秒时仍在场上（寿命翻倍生效，16s > %ds，未被全场磁吸卷走）" % [int(WAIT_SECONDS), int(WAIT_SECONDS)])
	_test_salvage()


## 回合结束金币回收：动态统计场上金币总值 → _end_run → gold 增量必须等于 总值 × 比例（向下取整）。
func _test_salvage() -> void:
	var gold_total := 0
	for pk in battle.pickups:
		if is_instance_valid(pk) and pk.kind == "gold":
			gold_total += pk.value
	var expect := int(float(gold_total) * GameStats.GOLD_SALVAGE_RATIO)
	var gold_before := int(battle.player.gold)
	battle._end_run(false)
	_check(int(battle.player.gold) == gold_before + expect,
		"回合结束回收：场上金币 %d → 入账 +%d（gold %d → %d）" % [
			gold_total, expect, gold_before, int(battle.player.gold)])
	# 回收后清场：场上不应再有金币掉落物
	var gold_left := 0
	for pk in battle.pickups:
		if is_instance_valid(pk) and pk.kind == "gold":
			gold_left += 1
	_check(gold_left == 0, "结算清场后场上无残留金币")


func _approx(a: float, b: float) -> bool:
	return absf(a - b) <= maxf(1e-4, 1e-5 * maxf(absf(a), absf(b)))


func _check(cond: bool, label: String) -> void:
	checks += 1
	if cond:
		print("[PROBE]   OK   %s" % label)
	else:
		fails.append(label)
		print("[PROBE]   FAIL %s" % label)


func _finish(ok: bool, msg: String) -> void:
	finished = true
	if msg != "":
		print("[PROBE] %s" % msg)
	print("[PROBE] 断言 %d/%d 通过" % [checks - fails.size(), checks])
	for f in fails:
		print("[PROBE]   - %s" % f)
	print("[PROBE] RESULT=%s" % ("PASS" if fails.is_empty() else "FAIL"))
	quit(0 if ok and fails.is_empty() else 1)
