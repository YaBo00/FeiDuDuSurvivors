extends SceneTree
## 独立验证探针：Boss 阶段战 + 波 15 小 Boss（2026-10-08 第二梯队）。
##
## 回答四个验收问题：
##   ① 数据面闭环：阶段表（2/3 阶段、阈值降序）、步进乘区表、小 Boss 常量
##   ② 阶段推进按设计执行（血线触发 / 一次一档不连跳 / 无敌帧吸收与恢复 / 属性乘区实测）
##   ③ 属性消费点生效（出招冷却乘区 / 召唤数加成 / speed·dmg 字段法全覆盖）
##   ④ 波 15 小 Boss 端到端（生成 / 开关禁用 / 真 Boss 不受影响）+ 测试基线开关
##
## 被验证的契约：
##   GameStats.BOSS_PHASES / BOSS_PHASE_STEP / BOSS_PHASE_IFRAME / boss_phases /
##     SUBBOSS_WAVES / SUBBOSS_TYPE / SUBBOSS_HP_MUL / is_sub_boss_wave / sub_boss_hp_mul /
##     boss_phase_enabled（静态开关）
##   Enemy.boss_phase / boss_phase_iframe / boss_interval_mul / boss_summon_bonus /
##     _advance_boss_phase / boss_phase_changed 信号
##   WaveDirector.start_next_wave 的波 15 分支
##
## 确定性：全部手动步进（set_physics_process(false) + call("_physics_process", dt)），
## 不依赖真实帧；概率无关（阶段系统零随机消耗）。
##
## 用法: godot --headless --path <项目>/game --script res://scripts/dev/_ProbeBossPhases.gd
## 退出码 0=PASS 1=FAIL（门禁用 grep -q "RESULT=PASS" 判定）

var battle: Node = null
var armed := false
var finished := false
var checks := 0
var fails: Array[String] = []


func _initialize() -> void:
	print("[PROBE] === Boss 阶段战 + 波 15 小 Boss 验证 ===")
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
	_sec_b_two_phase()
	_sec_c_three_phase()
	_sec_d_consumers()
	_sec_e_sub_boss()
	_sec_f_discipline()


# ================================================================ A. 数据面契约
func _sec_a_contracts() -> void:
	_section("A. 数据面契约（阶段表 / 步进乘区 / 小 Boss 常量）")
	_check(GameStats.BOSS_PHASES.has("BossPUA") and GameStats.BOSS_PHASES.has("Boss"),
		"BossPUA / Boss 都登记了阶段表")
	var p10: Array = GameStats.BOSS_PHASES["BossPUA"]
	var p20: Array = GameStats.BOSS_PHASES["Boss"]
	_check(p10.size() == 2, "BossPUA 2 阶段（实际 %d）" % p10.size())
	_check(p20.size() == 3, "Boss 3 阶段（实际 %d）" % p20.size())
	var desc := true
	for i in range(1, p20.size()):
		if not (float(p20[i]) < float(p20[i - 1]) and float(p20[i]) > 0.0):
			desc = false
	_check(desc and absf(float(p20[0]) - 1.0) <= 1e-6,
		"阈值严格降序且起点 1.0（%s）" % str(p20))
	_check(GameStats.boss_phases("Slime").is_empty(), "非 Boss 类型 → 空表（无阶段行为）")
	_check(GameStats.boss_phases("BossPUA") == p10, "boss_phases 查询命中")
	for k in ["speed", "dmg", "interval", "summon"]:
		_check(GameStats.BOSS_PHASE_STEP.has(k), "步进乘区表含键 %s" % k)
	_check(GameStats.BOSS_PHASE_IFRAME > 0.0 and GameStats.BOSS_PHASE_IFRAME < 2.0,
		"无敌帧 ∈ (0,2)（实际 %.2f）" % GameStats.BOSS_PHASE_IFRAME)
	_check(GameStats.SUBBOSS_WAVES.size() == 1 and int(GameStats.SUBBOSS_WAVES[0]) == 15,
		"小 Boss 波 == [15]")
	_check(GameStats.SUBBOSS_TYPE == "BossPUA", "小 Boss 模板 == BossPUA")
	_check(GameStats.is_sub_boss_wave(15), "is_sub_boss_wave(15) 为真")
	_check(not GameStats.is_sub_boss_wave(14) and not GameStats.is_sub_boss_wave(16)
		and not GameStats.is_sub_boss_wave(25), "14/16/25 非小 Boss 波")
	# sub_boss_hp_mul = 同公式 × SUBBOSS_HP_MUL（手动复算对照）
	var avg: float = GameStats._avg_pool_template_hp(15)
	var d: Dictionary = GameStats.difficulty_def()
	var expect: float = avg * GameStats.BOSS_HP_AVG_MUL * float(d["boss_hp_mul"]) \
		/ (float(GameStats.ENEMY_TEMPLATES["BossPUA"]["hp"]) * float(d["hp_mul"])) \
		* GameStats.SUBBOSS_HP_MUL
	_check(absf(GameStats.sub_boss_hp_mul(15) - expect) <= 1e-6,
		"sub_boss_hp_mul(15) == 公式复算值（%.3f）" % expect)
	# #27 定稿口径：小 Boss 用 BossPUA 分母（弱化 ×0.4），刻意【不】用 boss_wave_hp_mul(15)
	# —— 后者按 boss_type_for_wave(15) 会选成袋鼠王（Boss）分母，不是小 Boss 的参照。
	# 反断言「不等」以防有人把两者「顺手统一」（那会改掉小 Boss 血量语义）。
	# 2026-10-09 批量测修正：旧版断言「相等」，与定稿口径正面冲突（首跑假红）。
	var boss_mul: float = GameStats.boss_wave_hp_mul(15)
	_check(absf(GameStats.sub_boss_hp_mul(15) - boss_mul * GameStats.SUBBOSS_HP_MUL) > 1e-6,
		"小 Boss ≠ 袋鼠王分母 × %.1f（BossPUA 分母为定稿口径）" % GameStats.SUBBOSS_HP_MUL)


# ================================================================ B. 两阶段（BossPUA）
func _sec_b_two_phase() -> void:
	_section("B. 两阶段推进（BossPUA：50% 阈值 / 无敌 / 双信号并存）")
	var e = _make_boss("BossPUA", 10, 1000)
	_check(int(e.boss_phase) == 1, "初始 phase == 1")
	_check(int(e.get("_boss_phase_total")) == 2, "总阶段 == 2")
	_check(float(e.boss_phase_iframe) <= 1e-6, "初始无无敌帧")
	var spd0: float = e.speed
	var dmg0: int = e.dmg
	var rage_n := [0]
	var phase_log := []
	e.connect("rage_requested", func(_pos): rage_n[0] += 1)
	e.connect("boss_phase_changed", func(p, t, _pos): phase_log.append([p, t]))
	# 60%：不过阈值
	e.call("take_damage", 400)
	_check(int(e.boss_phase) == 1, "60% 血：不推阶段（阈值 50%）")
	# 45%：过阈值 → phase 2 + 无敌 + 属性
	e.call("take_damage", 150)
	_check(int(e.boss_phase) == 2, "45% 血：推进到 phase 2")
	_check(absf(float(e.boss_phase_iframe) - GameStats.BOSS_PHASE_IFRAME) <= 1e-6,
		"转阶段无敌 == %.1fs" % GameStats.BOSS_PHASE_IFRAME)
	_check(absf(e.speed - spd0 * float(GameStats.BOSS_PHASE_STEP["speed"])) <= 1e-3,
		"移速字段 ×%.2f（%.1f → %.1f）" % [float(GameStats.BOSS_PHASE_STEP["speed"]), spd0, e.speed])
	_check(e.dmg == maxi(1, roundi(float(dmg0) * float(GameStats.BOSS_PHASE_STEP["dmg"]))),
		"伤害字段 ×%.2f（%d → %d）" % [float(GameStats.BOSS_PHASE_STEP["dmg"]), dmg0, e.dmg])
	_check(absf(float(e.boss_interval_mul) - float(GameStats.BOSS_PHASE_STEP["interval"])) <= 1e-6,
		"出招冷却乘区 == ×%.2f" % float(GameStats.BOSS_PHASE_STEP["interval"]))
	_check(int(e.boss_summon_bonus) == int(GameStats.BOSS_PHASE_STEP["summon"]),
		"召唤加成 == +%d" % int(GameStats.BOSS_PHASE_STEP["summon"]))
	_check(phase_log.size() == 1 and phase_log[0][0] == 2 and phase_log[0][1] == 2,
		"boss_phase_changed 恰 1 次（2/2）")
	_check(rage_n[0] == 1, "50%% 与旧狂暴【并存】：rage_requested 同刻触发（它也是半血）")
	# 无敌吸收
	var hp_before: float = e.hp
	e.call("take_damage", 500)
	_check(absf(e.hp - hp_before) <= 1e-6, "无敌帧内 500 伤害被全额吸收（hp 不变）")
	# 手动步进清无敌
	e.call("_physics_process", GameStats.BOSS_PHASE_IFRAME + 0.1)
	_check(float(e.boss_phase_iframe) <= 1e-6, "步进 %.1fs 后无敌归零" % (GameStats.BOSS_PHASE_IFRAME + 0.1))
	e.call("take_damage", 1)
	_check(e.hp < hp_before, "无敌结束后恢复受伤")
	_check(int(e.boss_phase) == 2 and phase_log.size() == 1, "已是最后阶段：继续挨打不重复推进")
	_check(rage_n[0] == 1, "狂暴仍为一次性：继续挨打不重复")
	_cleanup(e)


# ================================================================ C. 三阶段（袋鼠王）
func _sec_c_three_phase() -> void:
	_section("C. 三阶段 + 不连跳（Boss：66%/33% / 一击跨两档只推一档）")
	var e = _make_boss("Boss", 20, 1000)
	_check(int(e.get("_boss_phase_total")) == 3, "总阶段 == 3")
	var spd_base: float = e.speed
	var phase_log := []
	e.connect("boss_phase_changed", func(p, t, _pos): phase_log.append(p))
	# 一击从 100% 打到 10%（跨 66% 与 33% 两档）：只推一档
	e.call("take_damage", 900)
	_check(int(e.boss_phase) == 2, "一击跨两档：只推进一档（phase 2，不连跳到 3）")
	_check(phase_log.size() == 1, "信号也只发 1 次（不叠演出）")
	# 清无敌后再打 → 推到 phase 3
	e.call("_physics_process", GameStats.BOSS_PHASE_IFRAME + 0.1)
	e.call("take_damage", 1)
	_check(int(e.boss_phase) == 3 and phase_log.size() == 2, "第二击推到 phase 3（信号 2 次）")
	# 属性累积 ×1.15²
	var st := float(GameStats.BOSS_PHASE_STEP["speed"])
	_check(absf(e.speed - spd_base * st * st) <= 1e-3,
		"两段推进后移速 = 初始 × %.2f²（%.1f → %.1f）" % [st, spd_base, e.speed])
	_cleanup(e)


# ================================================================ D. 属性消费点
func _sec_d_consumers() -> void:
	_section("D. 属性消费点（出招冷却乘区 / 召唤数加成）")
	var e = _make_boss("BossPUA", 10, 1000)
	e.call("take_damage", 600)   # → phase 2
	_check(int(e.boss_phase) == 2, "前置：已到 phase 2")
	# 出招冷却：recover【结束】的重置 = BOSS_SKILL_INTERVAL × interval_mul。
	# 2026-10-09 批量测修正：旧版 _finish_active 后直接读 —— 但那一步只「进 recover」，
	# 重置发生在 recover 结束帧（_boss_brain 的 recover 分支）里 → 读到旧的裸值假红。
	e.call("_finish_active")
	e.set("_boss_active_left", 0.0)
	e.call("_boss_brain", 0.05, Vector2(0.0, 1.0), 100.0)
	_check(String(e.get("boss_skill_state")) == "chase", "前置：recover 推完回 chase")
	var expect_cd: float = GameStats.BOSS_SKILL_INTERVAL * float(e.boss_interval_mul)
	_check(absf(float(e.get("_boss_cooldown")) - expect_cd) <= 1e-6,
		"出招冷却重置 = %.1f × %.2f = %.2f（实际 %.2f）" % [
			GameStats.BOSS_SKILL_INTERVAL, float(e.boss_interval_mul),
			expect_cd, float(e.get("_boss_cooldown"))])
	# 召唤数：模板 2（BossPUA）+ 阶段加成 1 = 3
	var got := [0]
	e.connect("summon_requested", func(_pos, _t, cnt): got[0] = cnt)
	e.boss_skill_name = "summon"
	e.call("_start_active", Vector2.RIGHT, 1.0)
	var want_cnt: int = int(GameStats.ENEMY_TEMPLATES["BossPUA"]["summon_count"]) + int(e.boss_summon_bonus)
	_check(got[0] == want_cnt, "召唤数 = 模板 %d + 加成 %d = %d（实际 %d）" % [
		int(GameStats.ENEMY_TEMPLATES["BossPUA"]["summon_count"]),
		int(e.boss_summon_bonus), want_cnt, got[0]])
	_cleanup(e)


# ================================================================ E. 波 15 小 Boss（端到端）
func _sec_e_sub_boss() -> void:
	_section("E. 波 15 小 Boss（生成 / 开关禁用 / 真 Boss 不受影响）")
	GameStats.boss_phase_enabled = true
	battle.start_run()
	battle.set_physics_process(false)
	battle.player.set_physics_process(false)
	# E1：启用态，波 15 生成 1 只小 Boss
	battle.wave_num = 14
	battle.wave.start_next_wave()
	_check(int(battle.wave_num) == 15, "推进到波 15")
	_check(_count_type("BossPUA") == 1, "波 15 生成 1 只小 Boss（BossPUA，实际 %d）" % _count_type("BossPUA"))
	# E2：禁用态（模拟 selftest），波 15 不生成
	GameStats.boss_phase_enabled = false
	battle.wave_num = 13
	battle.wave.start_next_wave()   # → 14
	battle.wave.start_next_wave()   # → 15
	_check(int(battle.wave_num) == 15, "（禁用态）推进到波 15")
	_check(_count_type("BossPUA") == 0, "禁用态：波 15 不生成小 Boss（基线保护）")
	# E3：真 Boss 波不受开关影响
	battle.wave_num = 9
	battle.wave.start_next_wave()   # → 10
	_check(_count_type("BossPUA") == 1, "禁用态：波 10 真 Boss 照常生成（开关只管新特性）")
	GameStats.boss_phase_enabled = true


# ================================================================ F. 纪律
func _sec_f_discipline() -> void:
	_section("F. 纪律（非 Boss 零影响 / 禁用态不推进 / 零随机消耗）")
	# 非 Boss：打血不推阶段、无无敌
	var s = _make_boss("Slime", 10, 1000)
	s.call("take_damage", 800)
	_check(int(s.boss_phase) == 1 and float(s.boss_phase_iframe) <= 1e-6,
		"Slime 打到 20%% 血：无阶段行为（phase 1 / 无无敌）")
	_cleanup(s)
	# 禁用态：Boss 打血不推进（selftest 基线保护的核心断言）
	GameStats.boss_phase_enabled = false
	var e = _make_boss("BossPUA", 10, 1000)
	e.call("take_damage", 600)
	_check(int(e.boss_phase) == 1 and float(e.boss_phase_iframe) <= 1e-6,
		"禁用态：40%% 血也不推阶段（Boss 保持旧行为）")
	_cleanup(e)
	GameStats.boss_phase_enabled = true
	# 零随机消耗：seed 对照（阶段推进不上任何 randf）
	var e2 = _make_boss("BossPUA", 10, 1000)
	seed(99)
	var r1 := randf()
	seed(99)
	e2.call("take_damage", 600)   # 触发转阶段
	var r2 := randf()
	_check(absf(r1 - r2) <= 1e-9, "转阶段零随机消耗（randf 序列一致）")
	_cleanup(e2)


# ================================================================ 工具
## 反射构造一只 Boss（挂 Sprite 子节点 + 手动步进夹具，同 _ProbeDifficulty / _ProbeRangedBoss）。
func _make_boss(type_name: String, wave: int, hp_value: int) -> Node2D:
	var e = Enemy.new()
	var spr := AnimatedSprite2D.new()
	spr.name = "Sprite"
	e.add_child(spr)
	root.add_child(e)
	e.call("setup", type_name, wave, Vector2(400, 0))
	e.set("max_hp", hp_value)
	e.set("hp", float(hp_value))
	e.set_physics_process(false)   # 只允许手动 call("_physics_process", dt)
	return e


func _cleanup(e: Node2D) -> void:
	if is_instance_valid(e):
		e.queue_free()


## 场上某类型的敌人数（小 Boss 生成断言用）。
func _count_type(t: String) -> int:
	var n := 0
	for e in battle.enemies:
		if String(e.type_name) == t:
			n += 1
	return n


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
