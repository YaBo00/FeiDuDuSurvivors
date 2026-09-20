extends SceneTree
## 独立验证探针：接触伤害「同帧求和 + 封顶」（A8 迭代）。
##
## 背景：旧实现逐怪 take_hit，但玩家无敌帧吞掉第一击之后的全部伤害 ⇒
## 被围 10 只和被 1 只贴身一样痛（且吃哪只取决于遍历顺序）。新语义：
##   总伤 = Σ接触中各怪伤害，封顶 = 单只最痛 × GameStats.CONTACT_DMG_CAP_MULT，
##   然后【一次】take_hit —— 一次闪避判定、一个无敌帧窗口、一条飘字/一次震屏。
##
## 手法（自校准，不依赖 take_hit 内部公式）：
##   先放 1 只贴身 Slime 测出单只基线 L1，再验证 2 只 = 2×L1、5 只 = 3×L1（封顶）、
##   无敌帧内重复调用不掉血。闪避用 _bonus["dodge"] 负值压死，保证确定。
##
## 用法: godot --headless --path <项目> --script res://scripts/dev/_ProbeContactDamage.gd
## 退出码 0=PASS 1=FAIL（门禁用 grep -q "RESULT=PASS" 判定）

const TOL := 0.5          # hp 是 float，取整误差放行到半点

var battle: Node = null
var armed := false
var finished := false
var checks := 0
var fails: Array[String] = []


func _initialize() -> void:
	print("[PROBE] === 接触伤害「同帧求和+封顶」验证（A8 迭代）===")
	var packed: PackedScene = load("res://scenes/battle/Battle.tscn")
	if packed == null:
		_finish("Battle.tscn 加载失败")
		return
	battle = packed.instantiate()
	root.add_child(battle)


func _arm() -> void:
	armed = true
	var cap := float(load("res://scripts/data/Stats.gd").get_script_constant_map()["CONTACT_DMG_CAP_MULT"])
	_check(cap >= 1.0, "CONTACT_DMG_CAP_MULT = %.1f >= 1.0" % cap)

	battle.start_run()
	battle.spawn_remaining = 0
	var pl: Node2D = battle.player
	pl.autopilot = false
	pl.atk = 0.0
	# 压死闪避（基础 0 + 负加成）→ 接触判定确定命中，不掷骰
	pl._bonus["dodge"] = -0.5
	pl.recalc_stats()
	var combat = battle.combat

	# 放 n 只贴身 Slime（出生后手动挪到接触距离内；避开 spawn_enemy 的离玩家重定位）
	var put := func(n: int) -> void:
		for i in n:
			battle._spawn_enemy("Slime", pl.global_position + Vector2(400.0, 0.0))
			var e: Node2D = battle.enemies[battle.enemies.size() - 1]
			e.global_position = pl.global_position + Vector2(5.0, 0.0)
		combat.rebuild_grid()

	# ---- 基线：1 只 ----
	put.call(1)
	pl.invincible_timer = 0.0
	var hp_before := float(pl.hp)
	combat.contact_damage()
	var l1 := hp_before - float(pl.hp)
	_check(l1 > 0.0, "基线：1 只贴身 Slime 掉血 %.1f" % l1)

	# ---- 2 只：求和（2 ≤ 封顶 3）----
	put.call(1)
	pl.invincible_timer = 0.0
	hp_before = float(pl.hp)
	combat.contact_damage()
	var l2 := hp_before - float(pl.hp)
	_check(_approx(l2, 2.0 * l1), "2 只贴身：掉血 %.1f == 2 × 基线 %.1f（求和生效）" % [l2, l1])

	# ---- 5 只：封顶（5 > 3 ⇒ 取 3 × 基线）----
	for i in 3:
		put.call(1)
	pl.invincible_timer = 0.0
	hp_before = float(pl.hp)
	combat.contact_damage()
	var l5 := hp_before - float(pl.hp)
	_check(_approx(l5, cap * l1), "5 只贴身：掉血 %.1f == 封顶 %.1f × 基线（有界秒杀防护）" % [l5, cap])

	# ---- 无敌帧：窗口内重复调用不掉血 ----
	pl.invincible_timer = 0.0
	combat.contact_damage()
	var hp_after := float(pl.hp)
	combat.contact_damage()
	_check(_approx(float(pl.hp), hp_after), "无敌帧窗口内重复结算不掉血（单次闪避/单窗语义保留）")

	# ---- 对照：没有接触中的敌人时零伤害 ----
	for e in battle.enemies:
		if is_instance_valid(e):
			e.global_position = pl.global_position + Vector2(400.0, 0.0)
	combat.rebuild_grid()
	var hp_far := float(pl.hp)
	pl.invincible_timer = 0.0
	combat.contact_damage()
	_check(_approx(float(pl.hp), hp_far), "无接触敌人时零伤害（不误伤）")

	_finish("")


func _approx(a: float, b: float) -> bool:
	return absf(a - b) <= TOL


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
