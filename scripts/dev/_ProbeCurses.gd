extends SceneTree
## 独立验证探针：开局诅咒（2026-10-08 第二梯队批次）。
##
## 回答四个验收问题：
##   ① 数据面契约（5 条诅咒 / 效果键合法 / 上限与 XP 步长 / 查询安全）
##   ② curse_bonus / curse_xp_mul 纯函数语义（空 / 单条 / 多条 / 同键叠加 / 未知 id 忽略）
##   ③ 五个注入点全部生效（铁壁=生命 / 利齿=伤害 / 疾风=移速 / 压境=投放量 / 萧条=金币）
##   ④ 结算 XP 加成闭环（record_run 的 xp_mul 参数 + curse_xp_mul 实算）
##
## 被验证的契约：
##   GameStats.CURSES / CURSE_MAX / CURSE_XP_BONUS / curse_bonus / curse_xp_mul / curse_name
##   GameSession.curses（跨局静态状态）
##   WaveDirector.planned_count / spawn_enemy 的诅咒乘区 / start_next_wave 的投放量
##   Enemy.setup 的「疾风」模板级移速乘区
##   Player.add_gold 的「萧条」入账乘区
##   MetaSave.record_run 的 xp_mul 参数
##
## 确定性：Battle 物理关闭 + 玩家站桩；每节显式设置并清理 GameSession.curses。
##
## 用法: godot --headless --path <项目>/game --script res://scripts/dev/_ProbeCurses.gd
## 退出码 0=PASS 1=FAIL（门禁用 grep -q "RESULT=PASS" 判定）

const PROBE_PATH := "user://probe_curses_meta.json"

var battle: Node = null
var armed := false
var finished := false
var checks := 0
var fails: Array[String] = []


func _initialize() -> void:
	print("[PROBE] === 开局诅咒验证（数据面 / 五乘区 / 结算 XP 加成）===")
	MetaSave.save_path = PROBE_PATH
	if FileAccess.file_exists(PROBE_PATH):
		DirAccess.remove_absolute(PROBE_PATH)
	var packed: PackedScene = load("res://scenes/battle/Battle.tscn")
	if packed == null:
		_finish("Battle.tscn 加载失败")
		return
	battle = packed.instantiate()
	root.add_child(battle)


func _process(_delta: float) -> bool:
	if finished:
		return true
	if not armed:
		_arm()
		_finish("")
		return true
	return true


func _arm() -> void:
	armed = true
	_sec_a_contracts()
	_sec_b_bonus_pure()
	_sec_c_combat_muls()
	_sec_d_spawn_count()
	_sec_e_gold()
	_sec_f_xp()
	# 收尾复位（探针进程独立、退出即清零；这里是纪律性保险）
	GameSession.curses = []


# ================================================================ A. 数据面契约
func _sec_a_contracts() -> void:
	_section("A. 数据面契约（CURSES 表 / 上限 / XP 步长 / 查询）")
	_check(GameStats.CURSES.size() == 5, "CURSES 5 条（实际 %d）" % GameStats.CURSES.size())
	var allowed := ["hp_mul", "dmg_mul", "spd_mul", "spawn_mul", "gold_mul"]
	for id in GameStats.CURSES.keys():
		var cid := String(id)
		var d: Dictionary = GameStats.CURSES[cid]
		var effect_ok := false
		for k in allowed:
			if d.has(k):
				effect_ok = true
		_check(effect_ok, "%s 至少带一个合法效果键（%s）" % [cid, str(d.keys())])
		_check(not String(d.get("name", "")).is_empty() and not String(d.get("desc", "")).is_empty(),
			"%s 有名字与描述" % cid)
	_check(int(GameStats.CURSE_MAX) >= 1 and int(GameStats.CURSE_MAX) <= GameStats.CURSES.size(),
		"CURSE_MAX ∈ [1, 条数]（实际 %d）" % int(GameStats.CURSE_MAX))
	_check(float(GameStats.CURSE_XP_BONUS) > 0.0,
		"CURSE_XP_BONUS > 0（实际 %.2f）" % float(GameStats.CURSE_XP_BONUS))
	_check(GameStats.curse_name("curse_hp") == "铁壁", "curse_name(curse_hp) == 铁壁")
	_check(GameStats.curse_name("nope") == "nope", "curse_name 未知 id 回落 id 本身")
	# 萧条是负增量（收益减成）；其余四个非负（敌人增强）
	for id in ["curse_hp", "curse_dmg", "curse_speed", "curse_horde"]:
		var vals: Dictionary = GameStats.CURSES[id]
		var neg := false
		for k in vals.keys():
			if k.ends_with("_mul") and float(vals[k]) < 0.0:
				neg = true
		_check(not neg, "%s 的效果键全为非负增量" % id)
	_check(float(GameStats.CURSES["curse_greed"]["gold_mul"]) < 0.0, "萧条带负 gold_mul（收益减成）")


# ================================================================ B. 纯函数
func _sec_b_bonus_pure() -> void:
	_section("B. curse_bonus / curse_xp_mul 纯函数")
	GameSession.curses = []
	_check(absf(GameStats.curse_bonus("hp_mul")) <= 1e-9, "空诅咒：hp_mul bonus == 0")
	_check(absf(GameStats.curse_xp_mul() - 1.0) <= 1e-9, "空诅咒：xp_mul == 1.0（逐位不变）")
	GameSession.curses = ["curse_hp"]
	_check(absf(GameStats.curse_bonus("hp_mul") - 0.25) <= 1e-9, "单条铁壁：hp_mul += 0.25")
	_check(absf(GameStats.curse_bonus("dmg_mul")) <= 1e-9, "单条铁壁不影响 dmg_mul")
	GameSession.curses = ["curse_hp", "curse_dmg"]
	_check(absf(GameStats.curse_bonus("hp_mul") - 0.25) <= 1e-9
		and absf(GameStats.curse_bonus("dmg_mul") - 0.25) <= 1e-9,
		"两条不同诅咒：各键分别生效")
	_check(absf(GameStats.curse_xp_mul() - (1.0 + 2.0 * float(GameStats.CURSE_XP_BONUS))) <= 1e-9,
		"两条诅咒：xp_mul == 1 + 2×%.2f（实际 %.3f）" % [
			float(GameStats.CURSE_XP_BONUS), GameStats.curse_xp_mul()])
	GameSession.curses = ["curse_hp", "curse_hp"]
	_check(absf(GameStats.curse_bonus("hp_mul") - 0.5) <= 1e-9,
		"同键两条：增量相加（0.5 —— 防御语义，正常 UI 不会产生）")
	GameSession.curses = ["nope", "curse_hp"]
	_check(absf(GameStats.curse_bonus("hp_mul") - 0.25) <= 1e-9, "未知 id 静默忽略")
	_check(absf(GameStats.curse_bonus("gold_mul")) <= 1e-9, "未知 id 不污染其它键")
	GameSession.curses = ["curse_greed"]
	_check(absf(GameStats.curse_bonus("gold_mul") + 0.30) <= 1e-9,
		"萧条：gold_mul == -0.30（负增量）")
	GameSession.curses = []


# ================================================================ C. 战斗乘区
func _sec_c_combat_muls() -> void:
	_section("C. 战斗乘区：铁壁（生命）/ 利齿（伤害）/ 疾风（移速）")
	_prep()
	GameSession.curses = []
	var base_e := _spawn("Slime", battle.player.global_position + Vector2(200.0, 0.0))
	var hp0: int = base_e.max_hp
	var dmg0: int = base_e.dmg
	var spd0: float = base_e.speed
	GameSession.curses = ["curse_hp", "curse_dmg", "curse_speed"]
	var e1 := _spawn("Slime", battle.player.global_position + Vector2(260.0, 0.0))
	_check(absi(e1.max_hp - roundi(float(hp0) * 1.25)) <= 1,
		"铁壁：生命 ~×1.25（%d → %d，期望 ~%d）" % [hp0, e1.max_hp, roundi(float(hp0) * 1.25)])
	_check(absi(e1.dmg - roundi(float(dmg0) * 1.25)) <= 1,
		"利齿：伤害 ~×1.25（%d → %d）" % [dmg0, e1.dmg])
	_check(absf(e1.speed - spd0 * 1.15) <= 0.01,
		"疾风：移速 ×1.15（%.1f → %.1f）" % [spd0, e1.speed])
	# 无诅咒基线对照：第二只与第一只同值（同波同型 = 模板相同）
	var e2 := _spawn("Slime", battle.player.global_position + Vector2(320.0, 0.0))
	_check(e2.max_hp == e1.max_hp, "同条件下两只怪数值一致（对照确定性）")
	GameSession.curses = []
	_prep()


# ================================================================ D. 投放量
func _sec_d_spawn_count() -> void:
	_section("D. 压境：投放量与清场进度分母同源（planned_count）")
	_prep()
	battle.wave_num = 6
	GameSession.curses = []
	var base: int = battle.wave.planned_count()
	_check(base == GameStats.spawn_count(6), "空诅咒：planned_count == spawn_count(6) == %d" % base)
	GameSession.curses = ["curse_horde"]
	var cursed: int = battle.wave.planned_count()
	_check(cursed == int(roundf(float(base) * 1.2)),
		"压境：plan == round(%d × 1.2) == %d（实际 %d）" % [base, int(roundf(float(base) * 1.2)), cursed])
	_check(cursed > base, "压境确实放大了投放计划")
	var ratio0: float = battle.wave.wave_clear_ratio()
	_check(absf(ratio0) <= 1e-9, "清场进度分母同源（0 击杀 == 0%%，不因诅咒虚满）")
	battle.start_next_wave()
	_check(int(battle.spawn_remaining) == battle.wave.planned_count(),
		"开波投放量 == planned_count（spawn_remaining=%d）" % int(battle.spawn_remaining))
	GameSession.curses = []
	_prep()


# ================================================================ E. 金币
func _sec_e_gold() -> void:
	_section("E. 萧条：金币收益 -30%（add_gold 入账乘区）")
	_prep()
	var pl: Player = battle.player
	GameSession.curses = []
	pl.gold = 500
	pl.add_gold(100)
	_check(pl.gold == 600, "空诅咒：add_gold(100) 全额（500 → %d）" % pl.gold)
	GameSession.curses = ["curse_greed"]
	pl.add_gold(100)
	_check(pl.gold == 670, "萧条：add_gold(100) → +70（600 → %d）" % pl.gold)
	pl.add_gold(1)
	_check(pl.gold == 671, "小额入账保底 +1（maxi(1,…) 不出现 0）")
	GameSession.curses = []


# ================================================================ F. 结算 XP
func _sec_f_xp() -> void:
	_section("F. 结算 XP 加成：record_run 的 xp_mul 参数 + curse_xp_mul 实算")
	if FileAccess.file_exists(PROBE_PATH):
		DirAccess.remove_absolute(PROBE_PATH)
	var d0: Dictionary = MetaSave.record_run(false, 0, 200, 0, false, "", "", 0, 1.0)
	_check(int(d0["meta_xp"]) == 10, "xp_mul=1.0：200 杀 → 10 点（实际 %d）" % int(d0["meta_xp"]))
	var d1: Dictionary = MetaSave.record_run(false, 0, 200, 0, false, "", "", 0, 2.0)
	_check(int(d1["meta_xp"]) == 30, "xp_mul=2.0：再入账 20 点（10 → %d）" % int(d1["meta_xp"]))
	# 三条诅咒实算：1 + 3×0.25 = 1.75
	GameSession.curses = ["curse_hp", "curse_dmg", "curse_speed"]
	var m: float = GameStats.curse_xp_mul()
	_check(absf(m - 1.75) <= 1e-6, "三条诅咒：xp_mul == 1.75（实际 %.3f）" % m)
	var before: int = int(d1["meta_xp"])
	var d2: Dictionary = MetaSave.record_run(false, 0, 200, 0, false, "", "", 0, m)
	_check(int(d2["meta_xp"]) == before + int(roundf(10.0 * m)),
		"诅咒局入账 10×%.2f = %d 点（%d → %d）" % [m, int(roundf(10.0 * m)), before, int(d2["meta_xp"])])
	GameSession.curses = []
	if FileAccess.file_exists(PROBE_PATH):
		DirAccess.remove_absolute(PROBE_PATH)


# ================================================================ 工具
## 清场 + 站桩：关 Battle 物理（探针全程手动驱动）、玩家缴械静止、暴击置 0。
## ⚠️ 刻意不动 GameSession.curses —— 各节显式设置与清理（探针自己维护状态）。
func _prep() -> void:
	battle.start_run()
	battle.set_physics_process(false)
	battle.spawn_remaining = 0
	var pl: Player = battle.player
	pl.set_physics_process(false)
	pl.autopilot = false
	pl.attack_enabled = false
	pl.god_mode = true
	pl.crit = 0.0
	pl.gold_per_kill = 0
	pl.luck = 0.0


## 生成一只静止的敌人（不改 hp/dmg —— 本节要读它们的模板数值做乘区对照）。
func _spawn(type_name: String, pos: Vector2) -> Node2D:
	battle.wave.spawn_enemy(type_name, pos, 1.0, false)
	var e: Node2D = battle.enemies[battle.enemies.size() - 1]
	e.set_physics_process(false)
	return e


func _section(title: String) -> void:
	print("[PROBE] --- %s" % title)


func _check(cond: bool, label: String) -> void:
	checks += 1
	if cond:
		print("[PROBE]   OK   %s" % label)
	else:
		fails.append(label)
		print("[PROBE]   FAIL %s" % label)


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
