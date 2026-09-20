extends SceneTree
## 难度系统 + Boss 动态血 + 半血狂暴 探针（2026-09-20 需求文档 §1/§2 验收）。
##
## 断言分组（全部确定性，不靠随机局面）：
##   A. DIFFICULTIES 表结构：normal 全 1.0（selftest 不漂的红线）、hard 系数齐备、
##      boss_has_timer 两档均 false（Boss 波不卡时限）。
##   B. 普通难度逐位：hp_scale / dmg_scale / spawn_count 与【旧手写公式】一致
##      （1.1+(w-1)*0.10 / 1+(w-1)*0.05 / 16+w*5，波 ≤24 不触 CAP）。
##   C. 困难难度：切 GameSession.difficulty="hard" 后三乘区 = 普通 × 系数。
##   D. Boss 动态血：boss_wave_hp_mul 经 Enemy.setup 端到端 == avg × 基准波次曲线 × 27
##      × boss_hp_mul；且明显厚于同波普通怪（≥ 平均血 × hp_scale × 10）；
##      hard Boss == normal 动态值 × 3.0（Boss 难度只由 boss_hp_mul 收口）。
##   E. 半血狂暴：Boss 打到半血 → rage_requested 恰触发 1 次；继续打不重复；
##      满血以上打不触发；对照组 Slime 打到半血不触发。
##   F. 探针还原 GameSession.difficulty="normal"（不污染同进程后续观测）。
##
## 反射纪律（本工程已两次踩坑）：本探针【新增】的符号一律运行期反射取 ——
##   GameStats 新常量 / 新静态方法经 load().get_script_constant_map() + instance.call；
##   GameSession.difficulty 经脚本对象 get/set；
##   Enemy 新字段/新信号经 has_signal / get 检查。既有符号（hp_scale 等）直接调。
##
## 用法: godot --headless --path <项目> --script res://scripts/dev/_ProbeDifficulty.gd
## 退出码 0=PASS 1=FAIL（门禁用 grep -q "RESULT=PASS" 判定）

const TOL := 1e-6

var _stats_script = null        # Stats.gd 脚本（反射新常量/新静态方法）
var _stats = null               # Stats.gd 实例（instance.call 静态方法）
var _consts: Dictionary = {}
var _session_script = null      # GameSession.gd 脚本（反射 difficulty）

var _checks := 0
var _fails: Array[String] = []


func _initialize() -> void:
	print("[PROBE] ===== 难度系统 / Boss 动态血 / 半血狂暴 =====")
	_stats_script = load("res://scripts/data/Stats.gd")
	_session_script = load("res://scripts/app/GameSession.gd")
	if _stats_script == null or _session_script == null:
		_finish(false, "无法加载 Stats.gd / GameSession.gd")
		return
	_consts = _stats_script.get_script_constant_map()
	_stats = _stats_script.new()

	var missing: Array[String] = []
	if not _consts.has("DIFFICULTIES"):
		missing.append("GameStats.DIFFICULTIES")
	for c in ["BOSS_HP_AVG_MUL", "BOSS_RAGE_HP_RATIO", "BOSS_RAGE_FLASH_TIME"]:
		if not _consts.has(c):
			missing.append("GameStats.%s" % c)
	# 静态变量反射：旧代码无该字段时 get 返回 null
	if _session_script.get("difficulty") == null:
		missing.append("GameSession.difficulty")
	var has_bwm := false
	for m in _stats_script.get_script_method_list():
		if String(m["name"]) == "boss_wave_hp_mul":
			has_bwm = true
			break
	if not has_bwm:
		missing.append("GameStats.boss_wave_hp_mul()")
	var pe = Enemy.new()
	if not pe.has_signal("rage_requested"):
		missing.append("Enemy.rage_requested")
	pe.free()
	if not missing.is_empty():
		_finish(false, "契约未就绪：缺少 %s" % str(missing))
		return

	var diff: Dictionary = _consts["DIFFICULTIES"]
	var k := 27.0   # BOSS_HP_AVG_MUL（反射表里也有，这里只作可读性别名）
	k = float(_consts["BOSS_HP_AVG_MUL"])

	# ---------------- A. 表结构 ----------------
	print("[PROBE] --- A. DIFFICULTIES 表结构 ---")
	_check(diff.has("normal") and diff.has("hard"), "DIFFICULTIES 含 normal/hard 两档")
	var n: Dictionary = diff["normal"]
	var h: Dictionary = diff["hard"]
	for f in ["hp_mul", "dmg_mul", "spawn_mul", "boss_hp_mul"]:
		_check(float(n[f]) == 1.0, "normal.%s = 1.0（selftest 逐位不漂红线）" % f)
	_check(String(n["name"]) == "普通", "normal.name = 普通")
	_check(String(h["name"]) == "困难", "hard.name = 困难")
	_check(absf(float(h["hp_mul"]) - 1.5) < TOL, "hard.hp_mul = 1.5")
	_check(absf(float(h["dmg_mul"]) - 1.3) < TOL, "hard.dmg_mul = 1.3")
	_check(absf(float(h["spawn_mul"]) - 1.2) < TOL, "hard.spawn_mul = 1.2")
	_check(absf(float(h["boss_hp_mul"]) - 3.0) < TOL, "hard.boss_hp_mul = 3.0")
	_check(bool(n["boss_has_timer"]) == false and bool(h["boss_has_timer"]) == false,
		"boss_has_timer 两档均 false（Boss 波不卡时限）")

	# ---------------- B. 普通难度逐位 ----------------
	print("[PROBE] --- B. 普通难度逐位（旧公式重算）---")
	_check(String(_session_script.get("difficulty")) == "normal",
		"探针进程 difficulty 默认 normal")
	# 期望值一律从 Stats 常量【推导】，不再硬编码斜率/基数 —— 否则每次调平都要改探针
	# （2026-09-20 用户把血量斜率改成「波 20 = ×8」，硬编码期望全红就是这次的教训）。
	var hp_slope: float = float(_consts.get("HP_SCALE_SLOPE", 0.3631578947368421))
	var hp_mul_e: float = float(_consts.get("ENDLESS_HP_SLOPE_MUL", 1.6))
	var spawn_base: int = int(_consts.get("SPAWN_BASE", 32))
	var spawn_growth: int = int(_consts.get("SPAWN_GROWTH", 10))
	for w in [1, 5, 10, 15, 20, 25]:
		var expect_hp := 1.1 + float(w - 1) * hp_slope
		if w > 20:
			expect_hp = 1.1 + 19.0 * hp_slope + float(w - 20) * hp_slope * hp_mul_e
		# 伤害斜率本轮未调（仍是 0.05），保持字面量并注明
		var expect_dmg := 1.0 + float(w - 1) * 0.05
		if w > 20:
			expect_dmg = 1.0 + 19.0 * 0.05 + float(w - 20) * 0.05 * 1.6
		_check(absf(float(_stats.call("hp_scale", w)) - expect_hp) < 1e-9,
			"normal hp_scale(%d) = %.4f 逐位" % [w, expect_hp])
		_check(absf(float(_stats.call("dmg_scale", w)) - expect_dmg) < 1e-9,
			"normal dmg_scale(%d) = %.4f 逐位" % [w, expect_dmg])
	for w in [1, 5, 10, 20, 24]:
		_check(int(_stats.call("spawn_count", w)) == mini(spawn_base + w * spawn_growth,
				int(_consts.get("SPAWN_COUNT_CAP", 280))),
			"normal spawn_count(%d) = %d 逐位" % [w, mini(spawn_base + w * spawn_growth,
				int(_consts.get("SPAWN_COUNT_CAP", 280)))])

	# ---------------- C. 困难难度三乘区 ----------------
	print("[PROBE] --- C. 困难难度三乘区 ---")
	_session_script.set("difficulty", "hard")
	_check(String(_session_script.get("difficulty")) == "hard", "已切 hard")
	var base10 := 1.1 + 9.0 * hp_slope
	_check(absf(float(_stats.call("hp_scale", 10)) - base10 * 1.5) < 1e-9,
		"hard hp_scale(10) = %.4f×1.5 = %.4f" % [base10, base10 * 1.5])
	_check(absf(float(_stats.call("dmg_scale", 10)) - 1.45 * 1.3) < 1e-9,
		"hard dmg_scale(10) = 1.45×1.3 = %.4f" % (1.45 * 1.3))
	var sc10 := mini(spawn_base + 10 * spawn_growth, int(_consts.get("SPAWN_COUNT_CAP", 280)))
	_check(int(_stats.call("spawn_count", 10)) == roundi(float(sc10) * 1.2),
		"hard spawn_count(10) = roundi(%d×1.2) = %d" % [sc10, roundi(float(sc10) * 1.2)])
	var sc1 := mini(spawn_base + spawn_growth, int(_consts.get("SPAWN_COUNT_CAP", 280)))
	_check(int(_stats.call("spawn_count", 1)) == roundi(float(sc1) * 1.2),
		"hard spawn_count(1) = roundi(%d×1.2) = %d（四舍五入生效）" % [sc1, roundi(float(sc1) * 1.2)])

	# ---------------- D. Boss 动态血（hard 态验证，稍后还原 normal 再验一次）----------------
	print("[PROBE] --- D. Boss 动态血 ---")
	_check_boss_dynamic(10, "BossPUA", 800.0, k)
	_check_boss_dynamic(20, "Boss", 600.0, k)

	# ---------------- E. 半血狂暴 ----------------
	print("[PROBE] --- E. 半血狂暴 ---")
	_check_rage()

	# ---------------- F. 还原 + normal 动态血复验 ----------------
	print("[PROBE] --- F. 还原 normal + 动态血复验 ---")
	_session_script.set("difficulty", "normal")
	_check(String(_session_script.get("difficulty")) == "normal", "已还原 normal")
	_check(absf(float(_stats.call("hp_scale", 10)) - (1.1 + 9.0 * hp_slope)) < 1e-9,
		"还原后 hp_scale(10) = %.4f 逐位" % (1.1 + 9.0 * hp_slope))
	_check_boss_dynamic(10, "BossPUA", 800.0, k)

	print("[PROBE] --------------------------------------------------")
	print("[PROBE] 断言 %d/%d 通过（失败 %d）" % [_checks - _fails.size(), _checks, _fails.size()])
	_finish(_fails.is_empty(), "难度系统 / Boss 动态血 / 半血狂暴 验证完成")


## D 组共用：端到端验证某波 Boss 的动态血。
## 期望 max_hp = avg(池) × 基准波次曲线 × K × boss_hp_mul —— 与难度 hp_mul 无关。
func _check_boss_dynamic(wave_num: int, boss_type: String, boss_base: float, k: float) -> void:
	# 用反射拿 spawn_types + ENEMY_TEMPLATES 重算同波普通怪平均模板血
	var types: Array = _stats.call("spawn_types", wave_num)
	var sum := 0.0
	for t in types:
		sum += float(_consts["ENEMY_TEMPLATES"][String(t)]["hp"])
	var avg := sum / float(types.size())
	var is_hard := String(_session_script.get("difficulty")) == "hard"
	var boss_mul: float = 3.0 if is_hard else 1.0
	var hard_hp_mul: float = 1.5 if is_hard else 1.0
	# 基准波次曲线（无难度）。Boss 血的难度差异【只由 boss_hp_mul 收口】——
	# hard Boss == normal 动态值 × 3.0 精确（接入说明表格：Boss 血「动态 ×3.0」），
	# 不再叠加普通怪的 hp_mul —— 实现与期望都按此口径。
	var slope_base := 1.1 + float(wave_num - 1) * float(_consts.get("HP_SCALE_SLOPE", 0.3631578947368421))
	var expect_hp := roundi(avg * slope_base * k * boss_mul)
	var e = Enemy.new()
	var spr := AnimatedSprite2D.new()
	spr.name = "Sprite"
	e.add_child(spr)
	root.add_child(e)
	# 端到端：与 WaveDirector.start_next_wave 的 Boss 刷怪同参 —— 显式传入
	# boss_wave_hp_mul(wave_num)（Enemy.setup 的 hp_cost 缺省 1.0，那是探针/分裂路径）。
	var wave_mul: float = float(_stats.call("boss_wave_hp_mul", wave_num))
	e.call("setup", boss_type, wave_num, Vector2(9999, 9999), wave_mul)
	var got := int(e.get("max_hp"))
	_check(wave_mul > 0.0, "boss_wave_hp_mul(%d) = %.4f > 0 [%s]" % [
		wave_num, wave_mul, "hard" if is_hard else "normal"])
	_check(got == expect_hp,
		"%s@波%d max_hp=%d == avg(%.1f)×曲线(%.2f)×K(%.0f)×boss_mul(%.1f)=%d [%s]" % [
			boss_type, wave_num, got, avg, slope_base, k, boss_mul, expect_hp,
			"hard" if is_hard else "normal"])
	# Boss 明显厚于同波普通怪（≥ 平均血 × 波次曲线 × 10）
	_check(got >= int(avg * slope_base * hard_hp_mul * 10.0),
		"%s@波%d 血量 %d ≥ 同波普通怪平均血×曲线×10（=%d）—— 明显更厚，非写死值" % [
			boss_type, wave_num, got, int(avg * slope_base * hard_hp_mul * 10.0)])
	e.queue_free()


## E 组：半血狂暴触发语义（反射构造，不依赖场景/波次）。
func _check_rage() -> void:
	var fake := Node2D.new()
	root.add_child(fake)
	fake.global_position = Vector2.ZERO
	# Boss：满血一击不打穿 → 不触发；打到半血 → 恰 1 次；继续打不重复
	var e = Enemy.new()
	var spr := AnimatedSprite2D.new()
	spr.name = "Sprite"
	e.add_child(spr)
	root.add_child(e)
	e.call("setup", "Boss", 10, Vector2(400, 0))
	var rage_count := [0]
	e.connect("rage_requested", func(_pos): rage_count[0] += 1)
	var max_hp := int(e.get("max_hp"))
	var ratio_threshold: float = float(_consts["BOSS_RAGE_HP_RATIO"])
	e.call("take_damage", int(max_hp * 0.3))   # 打到 70%：未过阈值
	_check(rage_count[0] == 0, "血量 70%%（未到 %.0f%%）不触发狂暴" % (ratio_threshold * 100.0))
	e.call("take_damage", int(max_hp * 0.25))  # 打到 45%：过阈值
	_check(rage_count[0] == 1, "血量跌破 %.0f%% 恰触发 1 次 rage_requested" % (ratio_threshold * 100.0))
	e.call("take_damage", 1)
	e.call("take_damage", 1)
	_check(rage_count[0] == 1, "狂暴为一次性：继续挨打不重复触发")
	_check(float(e.get("_rage_flash_t")) > 0.0, "触发后 _rage_flash_t > 0（红色脉冲进行中）")
	e.queue_free()
	# 对照组：普通怪（melee）打到半血不触发
	var s = Enemy.new()
	var spr2 := AnimatedSprite2D.new()
	spr2.name = "Sprite"
	s.add_child(spr2)
	root.add_child(s)
	s.call("setup", "Slime", 10, Vector2(400, 0))
	var s_count := [0]
	s.connect("rage_requested", func(_pos): s_count[0] += 1)
	var s_max := int(s.get("max_hp"))
	s.call("take_damage", int(s_max * 0.6))
	s.call("take_damage", int(s_max * 0.3))   # 累计 90%，远低于半血
	_check(s_count[0] == 0, "对照组 Slime 打到 10% 血也不触发狂暴（仅 boss 行为）")
	s.queue_free()
	fake.queue_free()


func _check(cond: bool, label: String) -> void:
	_checks += 1
	if cond:
		print("[PROBE]   OK   %s" % label)
	else:
		_fails.append(label)
		print("[PROBE]   FAIL %s" % label)


func _finish(ok: bool, msg: String) -> void:
	print("[PROBE] %s" % msg)
	print("[PROBE] RESULT=%s" % ("PASS" if ok else "FAIL"))
	quit(0 if ok else 1)
