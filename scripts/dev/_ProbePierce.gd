extends SceneTree
## 独立验证探针：弹道穿透语义（T-CHAR-04，工程线落）。
##
## 被验证的契约（CombatResolver.process_projectiles）：
##   1. pierce_cap 的语义 = 「单颗弹道最多穿透【多少个不同的敌人】」；
##      同一颗弹道对同一个敌人【至多结算一次】。
##      （修复前：慢速大弹在重叠区停留多帧，同一目标被反复扣血 —— 土豆 pierce=3
##        的重弹曾对一只 hp22 的 Slime 打出 2×15=30，即质量线疑点的根因。）
##   2. 「同一个敌人被多颗【不同】弹道各命中一次」是合法的独立命中 ——
##      承伤 = 各弹伤害之和（这不是 bug，本探针将其作为对照组锁进断言）。
##   3. 弹道在 pierced >= pierce_cap 时立刻回收（消耗语义不回退）。
##
## 手法（全部确定性单步，不靠随机场面）：
##   - 真 Battle.tscn 宿主；start_run() 后把 state 冻结在 UPGRADE ——
##     Battle._physics_process 的 _tick_fighting 分支不再跑，弹道只由本探针手动驱动；
##   - 玩家/敌人 set_physics_process(false)，crit=0（伤害确定性）、gold_on_hit=0、
##     lifesteal=0 —— 排除暴击随机 / 掉币 / 吸血等一切歧义源；
##   - 敌人 hp 手动设为 999（绝不致死），用「掉血量 = 命中次数 × 单发伤害」计数命中；
##   - 每组之间 combat.reset() + 清弹清怪，组间零污染。
##
## 用法: godot --headless --path <项目> --script res://scripts/dev/_ProbePierce.gd
## 退出码 0=PASS 1=FAIL（门禁用 grep -q "RESULT=PASS" 判定）

const DT := 1.0 / 60.0        # 确定性单步步长（与真实物理帧一致）
const STEPS := 140            # 每组单步帧数：PROJ_SPEED=450px/s × 140 帧 ≈ 1050px，足够完整穿越
const DMG_A := 15             # A 组单发伤害
const DMG_B := 10             # B 组单发伤害
const DMG_C := 12             # C 组单发伤害
const DMG_D := 8              # D 组单发伤害
const START_X := 560.0        # 弹道起点 x（玩家在 ARENA_CENTER=(1280,720)，起点距玩家 720px）
const ROW_Y := 720.0          # 弹道与敌人共同的 y（穿过玩家左侧区域，距玩家 ≥ 360px）
const ENEMY_HP := 999

var battle: Node = null
var proj_scene: PackedScene = null
var armed := false
var finished := false
var checks := 0
var fails: Array[String] = []


func _initialize() -> void:
	print("[PROBE] ===== 弹道穿透语义独立验证（T-CHAR-04）=====")
	proj_scene = load("res://scenes/entities/Projectile.tscn")
	if proj_scene == null:
		_finish("Projectile.tscn 加载失败")
		return
	print("[PROBE] 载入 Battle.tscn（真实结算链路）")
	var packed: PackedScene = load("res://scenes/battle/Battle.tscn")
	if packed == null:
		_finish("Battle.tscn 加载失败")
		return
	battle = packed.instantiate()
	root.add_child(battle)
	print("[PROBE] Battle 已入树，布置推迟到第一帧")


func _arm() -> void:
	armed = true
	# 必须走正规开局（裸加载的 Battle wave_timer=0，第一帧就会触发波末清场）
	battle.start_run()
	battle.spawn_remaining = 0
	# 冻结状态机：state=UPGRADE → _tick_fighting 不跑，弹道只由本探针手动驱动。
	# 枚举走反射取（不硬编码 0/1）；取不到时回退（FIGHTING=0, UPGRADE=1）。
	var st: Dictionary = battle.get("State")
	battle.state = int(st["UPGRADE"]) if st.has("UPGRADE") else 1
	# 玩家定桩：不移动、不攻击、不掉血（接触伤害也在 _tick_fighting 里，已随状态冻结）
	var player: Node2D = battle.player
	player.set_physics_process(false)
	# 清掉开局已刷的怪，探针只观测自己生成的怪
	_clear_enemies()
	battle.combat.reset()


## 生成一只冻结的 Slime（不移动、hp 拉高到绝不致死），返回它。
func _frozen_slime(pos: Vector2) -> Node2D:
	battle._spawn_enemy("Slime", pos)
	var e: Node2D = battle.enemies[battle.enemies.size() - 1]
	e.set_physics_process(false)
	e.hp = ENEMY_HP
	return e


## 生成一颗玩家弹道（crit=0 / 不吸血 / 不掉币 → 伤害完全确定）。
func _proj(pos: Vector2, dmg: int, pierce_cap: int) -> Node2D:
	var p: Node2D = proj_scene.instantiate()
	battle.world.add_child(p)
	# setup(p_pos, p_dir, p_damage, p_crit, p_critd, p_lifesteal, speed_mul, radius, pierce_cap, gold_on_hit)
	p.setup(pos, 0.0, dmg, 0.0, 1.5, 0.0, 1.0, float(GameStats.PROJ_RADIUS), pierce_cap, 0.0)
	battle.projectiles.append(p)
	return p


## 手动单步 n 帧（每帧调一次真实的 process_projectiles）。
func _step(n: int) -> void:
	for i in n:
		battle.combat.process_projectiles(DT)


func _clear_enemies() -> void:
	for e in battle.enemies:
		e.queue_free()
	battle.enemies.clear()
	battle.combat.clear_grid()


## 组间清理：弹 + 怪 + 命中表 + 网格全部归零（组间零污染）。
func _between_groups() -> void:
	for p in battle.projectiles:
		p.queue_free()
	battle.projectiles.clear()
	_clear_enemies()
	battle.combat.reset()


## 掉血量 = 命中次数 × 单发伤害（crit=0 且 def=0 ⇒ 每次恰扣 dmg）。
func _hits(e: Node2D, dmg: int) -> int:
	return int(round(float(ENEMY_HP - int(e.hp)) / float(dmg)))


# ================================================================ 第一帧：布置 + 断言
func _arm_and_run() -> void:
	_arm()

	# ============================================================ A. 单弹单敌：恰好命中 1 次
	print("[PROBE] --- A. 单弹(pierce_cap=2) + 单敌：完全穿越后恰命中 1 次 ---")
	var ea := _frozen_slime(Vector2(680.0, ROW_Y))
	battle.combat.rebuild_grid()
	_proj(Vector2(START_X, ROW_Y), DMG_A, 2)
	_step(STEPS)
	_check(_hits(ea, DMG_A) == 1,
		"A: 敌人恰被命中 1 次（掉血 %d = 1×%d；修复前会被连扣到 %d×%d）" % [
			ENEMY_HP - int(ea.hp), DMG_A, 2, DMG_A])

	_between_groups()

	# ============================================================ B. 单弹穿一排 5 敌：各恰 1 次
	print("[PROBE] --- B. 单弹(pierce_cap=99) + 一排 5 敌：每个敌人恰 1 次 ---")
	var row: Array = []
	for i in 5:
		row.append(_frozen_slime(Vector2(680.0 + 60.0 * i, ROW_Y)))
	battle.combat.rebuild_grid()
	var pb: Node2D = _proj(Vector2(START_X, ROW_Y), DMG_B, 99)
	_step(STEPS)
	var per_ok := true
	for i in row.size():
		if _hits(row[i], DMG_B) != 1:
			per_ok = false
	_check(per_ok, "B: 一排 5 敌每个恰好被命中 1 次（各掉血 1×%d）" % DMG_B)
	var total_hits := 0
	for e in row:
		total_hits += _hits(e, DMG_B)
	_check(total_hits == 5, "B: 总命中事件 == 5（实际 %d，重复命中会变大）" % total_hits)
	_check(int(pb.pierced) == 5, "B: proj.pierced == 5（cap=99 不提前消耗，实际 %d）" % int(pb.pierced))

	_between_groups()

	# ============================================================ C. cap=2 + 两敌：到上限即消耗
	print("[PROBE] --- C. 单弹(pierce_cap=2) + 两敌：两敌各 1 次、弹到上限即回收 ---")
	var c1 := _frozen_slime(Vector2(680.0, ROW_Y))
	var c2 := _frozen_slime(Vector2(740.0, ROW_Y))
	battle.combat.rebuild_grid()
	_proj(Vector2(START_X, ROW_Y), DMG_C, 2)
	_step(STEPS)
	_check(_hits(c1, DMG_C) == 1 and _hits(c2, DMG_C) == 1,
		"C: 两敌各恰命中 1 次（掉血 %d / %d）" % [ENEMY_HP - int(c1.hp), ENEMY_HP - int(c2.hp)])
	_check(battle.projectiles.is_empty(),
		"C: pierce 上限到达后弹道已回收（场上剩余弹道 %d）" % battle.projectiles.size())

	_between_groups()

	# ============================================================ D. 两颗不同弹同帧打同一敌（合法路径对照）
	print("[PROBE] --- D. 两颗【不同】弹(pierce_cap=1)同帧打同一敌：2 次独立命中之和 ---")
	var ed := _frozen_slime(Vector2(680.0, ROW_Y))
	battle.combat.rebuild_grid()
	_proj(Vector2(START_X, ROW_Y), DMG_D, 1)
	_proj(Vector2(START_X, ROW_Y), DMG_D, 1)
	_step(STEPS)
	_check(_hits(ed, DMG_D) == 2,
		"D: 承伤 == 2 次独立命中之和（掉血 %d = 2×%d；多弹同打一敌是合法路径）" % [
			ENEMY_HP - int(ed.hp), DMG_D])
	_check(battle.projectiles.is_empty(),
		"D: 两颗 cap=1 的弹各自命中一次后都被回收（场上剩余 %d）" % battle.projectiles.size())

	_finish("")


# ================================================================ 工具
func _check(cond: bool, label: String) -> void:
	checks += 1
	if cond:
		print("[PROBE]   OK   %s" % label)
	else:
		fails.append(label)
		print("[PROBE]   FAIL %s" % label)


func _finish(early_msg: String) -> void:
	if finished:
		return
	finished = true
	print("[PROBE] --------------------------------------------------")
	if early_msg != "":
		print("[PROBE] 提前终止：%s" % early_msg)
		print("[PROBE] RESULT=FAIL")
		quit(1)
		return
	print("[PROBE] 断言 %d/%d 通过（失败 %d）" % [checks - fails.size(), checks, fails.size()])
	for f in fails:
		print("[PROBE]   - %s" % f)
	print("[PROBE] RESULT=%s" % ("PASS" if fails.is_empty() else "FAIL"))
	quit(0 if fails.is_empty() else 1)


func _process(_delta: float) -> bool:
	if finished:
		return true
	if not armed:
		_arm_and_run()
		return true
	return true
