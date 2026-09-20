extends SceneTree
## 独立验证探针：正弦怪潮（B1 迭代）—— spawn_tide_mul 纯函数 + 总量守恒。
##
## 被验证的契约：
##   Stats.SPAWN_TIDE_AMPLITUDE、Stats.spawn_tide_mul(elapsed_in_window)
##   · mul 在窗口起点 == 1.0（从基准速率开始）
##   · mul 全程 ∈ [1-A, 1+A]（有界，永不为负/爆表）
##   · 【核心】对 rate×mul 在整个投放窗口做数值积分 ≈ rate × SPAWN_WINDOW
##     （窗口内恰好两个整正弦周期 ⇒ 总投放量与匀速模式逐只一致 —— 难度总量不变）
##
## 用法: godot --headless --path <项目> --script res://scripts/dev/_ProbeSpawnTide.gd
## 退出码 0=PASS 1=FAIL（门禁用 grep -q "RESULT=PASS" 判定）

const TOL_ABS := 1e-6
const SAMPLES := 20000

var checks := 0
var fails: Array[String] = []


func _initialize() -> void:
	print("[PROBE] === 正弦怪潮验证（B1 迭代）===")
	var sm = load("res://scripts/data/Stats.gd").new()
	var A := float(load("res://scripts/data/Stats.gd").get_script_constant_map()["SPAWN_TIDE_AMPLITUDE"])
	var window := float(sm.SPAWN_WINDOW)
	var rate := 2.0        # 任意基准速率（守恒性与速率无关）

	_check(A > 0.0 and A < 1.0, "SPAWN_TIDE_AMPLITUDE = %.2f ∈ (0,1)（潮起但不翻倍）" % A)

	# 窗口起点：mul == 1（从基准速率开始，开局不突变）
	_check(_approx(float(sm.spawn_tide_mul(0.0)), 1.0), "窗口起点 mul == 1.0")

	# 波峰/波谷
	var period := window / 2.0
	_check(_approx(float(sm.spawn_tide_mul(period * 0.25)), 1.0 + A), "四分之一周期处 == 1 + A（波峰）")
	_check(_approx(float(sm.spawn_tide_mul(period * 0.75)), 1.0 - A), "四分之三周期处 == 1 - A（波谷）")

	# 全程有界
	var lo := INF
	var hi := -INF
	for i in SAMPLES:
		var m := float(sm.spawn_tide_mul(window * float(i) / float(SAMPLES - 1)))
		lo = minf(lo, m)
		hi = maxf(hi, m)
	_check(lo >= 1.0 - A - 1e-9 and hi <= 1.0 + A + 1e-9,
		"全程 mul ∈ [%.4f, %.4f] ⊆ [%.2f, %.2f]" % [lo, hi, 1.0 - A, 1.0 + A])

	# 【核心】总量守恒：∫ rate×mul dt over window == rate × window
	var acc := 0.0
	var dt := window / float(SAMPLES)
	for i in SAMPLES:
		var t := window * float(i) / float(SAMPLES - 1)
		acc += rate * float(sm.spawn_tide_mul(t)) * dt
	var plain := rate * window
	_check(absf(acc - plain) <= maxf(TOL_ABS, 1e-4 * plain),
		"总量守恒：潮汐积分 %.3f == 匀速 %.3f（相对偏差 %.5f%%）" % [
			acc, plain, 100.0 * absf(acc - plain) / plain])

	print("[PROBE] 断言 %d/%d 通过（失败 %d）" % [checks - fails.size(), checks, fails.size()])
	for f in fails:
		print("[PROBE]   - %s" % f)
	print("[PROBE] RESULT=%s" % ("PASS" if fails.is_empty() else "FAIL"))
	quit(0 if fails.is_empty() else 1)


func _approx(a: float, b: float) -> bool:
	return absf(a - b) <= maxf(1e-6, 1e-6 * maxf(absf(a), absf(b)))


func _check(cond: bool, label: String) -> void:
	checks += 1
	if cond:
		print("[PROBE]   OK   %s" % label)
	else:
		fails.append(label)
		print("[PROBE]   FAIL %s" % label)
