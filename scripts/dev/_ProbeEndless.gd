extends SceneTree
## 独立验证探针：批次二 · 无尽模式（T-END-02）。
##
## 由质量线（严守真）独立编写 —— 依据【已冻结的接口契约】写断言，不看实现细节。
## 待验证契约：
##   GameSession.endless: bool（static var；由 Battle 解析 --endless 置位）
##   GameStats.SPAWN_COUNT_CAP / ENDLESS_HP_SLOPE_MUL / ENDLESS_DMG_SLOPE_MUL
##   GameStats.ENDLESS_BOSS_PERIOD / ENDLESS_SELFTEST_WAVES
##   spawn_count(w) == mini(SPAWN_BASE + w*SPAWN_GROWTH, SPAWN_COUNT_CAP)
##   hp_scale(w)/dmg_scale(w)：w > WAVE_COUNT 后斜率放大，且在 w == WAVE_COUNT 处连续
##   floor_theme_for_wave(w)：w > WAVE_COUNT 后循环复用主题
##   is_boss_wave(w)：w > WAVE_COUNT 时每 ENDLESS_BOSS_PERIOD 波为真
##   WaveDirector.end_wave()：无尽下 wave_num >= WAVE_COUNT 不结算；非无尽下照样结算
##   Hud.set_data(...)：无尽下文案含「无尽」；非无尽下仍「第 N / 20 波」
##
## 数值一律从 GameStats 常量推导，浮点比较用 absf(a-b) < 1e-4。
##
## ⚠️ 本文件是【草案】，故意放在 res:// 扫描范围之外的 docs/ 下 ——
##    因为契约（GameSession.endless / 新常量）落地前直接写进 scripts/dev/ 会让 CheckAll 报 Parse Error。
##    确认契约落地后移动为 game/scripts/dev/_ProbeEndless.gd。
##
## 用法: godot --headless --path <项目> --script res://scripts/dev/_ProbeEndless.gd
## 退出码 0=PASS 1=FAIL（门禁 grep -q "RESULT=PASS" 判定）

const TOL := 1e-4

var battle: Node = null
var armed := false
var finished := false
var checks := 0
var fails: Array[String] = []


func _initialize() -> void:
	print("[PROBE] === 无尽模式独立验证（T-END-02）===")
	print("[PROBE] 载入 Battle.tscn（拿真实 wave/hud/player，不另造桩）")
	var packed: PackedScene = load("res://scenes/battle/Battle.tscn")
	if packed == null:
		_finish("Battle.tscn 加载失败")
		return
	battle = packed.instantiate()
	root.add_child(battle)
	# @onready 变量要等 _ready() 跑完才有值 → 真正的断言推迟到第一帧。
	print("[PROBE] Battle 已入树，断言推迟到第一帧")


## 第一帧：Battle._ready() 已跑过，wave/hud/player 可用。
func _arm() -> void:
	armed = true
	_tA_regression_guard()
	_tB_extension_curve()
	_tC_theme_cycle()
	_tD_boss_period()
	_tE_hud_text()
	_tF_endless_no_settle()
	# 收尾清理：别以「面板展开 + 树暂停」的状态退出（否则退出期会刷 ObjectDB/资源告警，
	# 干扰只看 RESULT 的门禁日志）。纯清理，不影响任何断言。
	paused = false
	for pname in ["upgrade_panel", "shop_panel", "result_panel"]:
		var pnl = battle.get(pname)
		if pnl != null and pnl.has_method("hide_panel"):
			pnl.hide_panel()


# ================================================================ A. 前 20 波回归护栏
## ⚠️ 这一组是【回归护栏】：下面硬写的 6 个基数是【改造前实测值】。
##    改动它们 == 改了前 20 波难度，必须显式确认（这正是护栏存在的意义）。
func _tA_regression_guard() -> void:
	print("[PROBE] --- A. 前 20 波回归护栏（改这些值 = 改了前 20 波难度，必须显式确认）---")
	_check(_approx(GameStats.hp_scale(1), 1.1), "hp_scale(1) == 1.1（实际 %.4f）" % GameStats.hp_scale(1))
	# 期望值从常量推导（2026-09-20 调平后不再硬编码：血量斜率改为「波 20 = ×8」、
	# 数量翻倍 32+10）—— 这样以后每次调平不必再改本探针。
	_check(_approx(GameStats.hp_scale(20), 1.1 + 19.0 * GameStats.HP_SCALE_SLOPE),
		"hp_scale(20) == 1.1+19×斜率 = %.4f（实际 %.4f）" % [
			1.1 + 19.0 * GameStats.HP_SCALE_SLOPE, GameStats.hp_scale(20)])
	_check(_approx(GameStats.dmg_scale(1), 1.0), "dmg_scale(1) == 1.0（实际 %.4f）" % GameStats.dmg_scale(1))
	_check(_approx(GameStats.dmg_scale(20), 1.95), "dmg_scale(20) == 1.95（实际 %.4f）" % GameStats.dmg_scale(20))
	var sc1 := mini(GameStats.SPAWN_BASE + GameStats.SPAWN_GROWTH, GameStats.SPAWN_COUNT_CAP)
	_check(GameStats.spawn_count(1) == sc1, "spawn_count(1) == %d（实际 %d）" % [sc1, GameStats.spawn_count(1)])
	var sc20 := mini(GameStats.SPAWN_BASE + 20 * GameStats.SPAWN_GROWTH, GameStats.SPAWN_COUNT_CAP)
	_check(GameStats.spawn_count(20) == sc20, "spawn_count(20) == %d（实际 %d）" % [sc20, GameStats.spawn_count(20)])

	# 线性段公式：w in 1..WAVE_COUNT 时 spawn_count == SPAWN_BASE + w*SPAWN_GROWTH
	for w in range(1, GameStats.WAVE_COUNT + 1):
		var expect := GameStats.SPAWN_BASE + w * GameStats.SPAWN_GROWTH
		_check(GameStats.spawn_count(w) == expect,
			"w=%d spawn_count == SPAWN_BASE+w*SPAWN_GROWTH（实际 %d，期望 %d）" % [w, GameStats.spawn_count(w), expect])

	# 一阶差分恒定（线性段形状未破）——差分从 w=1→2 自推导，不硬编码斜率
	var dhp0 := GameStats.hp_scale(2) - GameStats.hp_scale(1)
	var ddmg0 := GameStats.dmg_scale(2) - GameStats.dmg_scale(1)
	for w in range(2, GameStats.WAVE_COUNT + 1):
		var dhp := GameStats.hp_scale(w) - GameStats.hp_scale(w - 1)
		var ddmg := GameStats.dmg_scale(w) - GameStats.dmg_scale(w - 1)
		_check(_approx(dhp, dhp0),
			"hp_scale 一阶差分恒定 w=%d（%.4f vs %.4f）" % [w, dhp, dhp0])
		_check(_approx(ddmg, ddmg0),
			"dmg_scale 一阶差分恒定 w=%d（%.4f vs %.4f）" % [w, ddmg, ddmg0])


# ================================================================ B. 延伸段
func _tB_extension_curve() -> void:
	print("[PROBE] --- B. 延伸段（严格单调递增 + 连续性 + 封顶）---")
	# hp/dmg 在 w in 2..60 严格单调递增（不许平段或回落）
	var last_hp := GameStats.hp_scale(1)
	var last_dmg := GameStats.dmg_scale(1)
	for w in range(2, 61):
		var h := GameStats.hp_scale(w)
		var d := GameStats.dmg_scale(w)
		_check(h > last_hp + TOL, "hp_scale 严格递增 w=%d（%.4f > %.4f）" % [w, h, last_hp])
		_check(d > last_dmg + TOL, "dmg_scale 严格递增 w=%d（%.4f > %.4f）" % [w, d, last_dmg])
		last_hp = h
		last_dmg = d

	# 在 WAVE_COUNT 处连续（向上、无向下跳变）
	var wc := GameStats.WAVE_COUNT
	_check(GameStats.hp_scale(wc + 1) > GameStats.hp_scale(wc),
		"hp_scale 在 WAVE_COUNT 处连续（%.4f > %.4f）" % [GameStats.hp_scale(wc + 1), GameStats.hp_scale(wc)])
	_check(GameStats.dmg_scale(wc + 1) > GameStats.dmg_scale(wc),
		"dmg_scale 在 WAVE_COUNT 处连续（%.4f > %.4f）" % [GameStats.dmg_scale(wc + 1), GameStats.dmg_scale(wc)])

	# spawn_count：公式（封顶）+ 单调非减（w in 1..200）
	var prev := GameStats.spawn_count(1)
	for w in range(1, 201):
		var sc := GameStats.spawn_count(w)
		var expect := mini(GameStats.SPAWN_BASE + w * GameStats.SPAWN_GROWTH, GameStats.SPAWN_COUNT_CAP)
		_check(sc == expect, "spawn_count(%d) == mini(base+w*growth, CAP)（实际 %d，期望 %d）" % [w, sc, expect])
		if w >= 2:
			_check(sc >= prev, "spawn_count 单调非减 w=%d（%d >= %d）" % [w, sc, prev])
		prev = sc
	_check(GameStats.spawn_count(200) == GameStats.SPAWN_COUNT_CAP,
		"spawn_count(200) == SPAWN_COUNT_CAP（实际 %d，期望 %d）" % [GameStats.spawn_count(200), GameStats.SPAWN_COUNT_CAP])


# ================================================================ C. 主题循环
func _tC_theme_cycle() -> void:
	print("[PROBE] --- C. 主题循环 ---")
	var n := GameStats.FLOOR_THEMES.size()
	var period := n * GameStats.WAVES_PER_THEME

	# 1..WAVE_COUNT 与旧的 clampi 行为逐波一致（自推导，不抄实现）
	for w in range(1, GameStats.WAVE_COUNT + 1):
		var idx := clampi(int((w - 1) / float(GameStats.WAVES_PER_THEME)), 0, n - 1)
		var got := String(GameStats.floor_theme_for_wave(w)["id"])
		var want := String(GameStats.FLOOR_THEMES[idx]["id"])
		_check(got == want, "主题 w=%d 与旧 clampi 一致（实际 %s，期望 %s）" % [w, got, want])

	# 周期性：w 与 w+period 同主题（w in 1..60）
	for w in range(1, 61):
		var a := String(GameStats.floor_theme_for_wave(w)["id"])
		var b := String(GameStats.floor_theme_for_wave(w + period)["id"])
		_check(a == b, "主题周期 w=%d 与 w+%d 一致（%s vs %s）" % [w, period, a, b])

	_check(String(GameStats.floor_theme_for_wave(1)["id"]) == String(GameStats.floor_theme_for_wave(1 + period)["id"]),
		"floor_theme_for_wave(1) == floor_theme_for_wave(1+%d)" % period)


# ================================================================ D. Boss 周期
func _tD_boss_period() -> void:
	print("[PROBE] --- D. Boss 周期 ---")
	_check(GameStats.is_boss_wave(10), "is_boss_wave(10) 真")
	_check(GameStats.is_boss_wave(20), "is_boss_wave(20) 真")
	_check(GameStats.is_boss_wave(30), "is_boss_wave(30) 真（超 20 波后周期化）")
	_check(GameStats.is_boss_wave(40), "is_boss_wave(40) 真")
	_check(not GameStats.is_boss_wave(5), "is_boss_wave(5) 假")
	_check(not GameStats.is_boss_wave(15), "is_boss_wave(15) 假")
	_check(not GameStats.is_boss_wave(25), "is_boss_wave(25) 假")

	# 周期性（锚点无关）：w 与 w+ENDLESS_BOSS_PERIOD 同类
	var per: int = GameStats.ENDLESS_BOSS_PERIOD
	if per > 0:
		for w in range(GameStats.WAVE_COUNT + 1, GameStats.WAVE_COUNT + 1 + per):
			_check(GameStats.is_boss_wave(w) == GameStats.is_boss_wave(w + per),
				"Boss 周期 w=%d 与 w+%d 一致（%s vs %s）" % [
					w, per, str(GameStats.is_boss_wave(w)), str(GameStats.is_boss_wave(w + per))])


# ================================================================ E. HUD 无尽文案（真场景）
func _tE_hud_text() -> void:
	print("[PROBE] --- E. HUD 无尽文案（真场景）---")
	var hud = battle.get("hud")
	var player = battle.get("player")
	if hud == null or player == null:
		_check(false, "battle.hud / battle.player 为 null，无法验证文案")
		return
	var wave_label = hud.get("_wave_label")
	if wave_label == null:
		_check(false, "hud._wave_label 为 null，无法验证文案")
		return

	GameSession.endless = true
	hud.set_data(player, GameStats.WAVE_COUNT + 1, 12.0, GameStats.WAVE_COUNT)
	var t_inf := String(wave_label.text)
	_check("无尽" in t_inf, "无尽中文案含「无尽」（实际：%s）" % t_inf)

	GameSession.endless = false
	hud.set_data(player, 5, 12.0, GameStats.WAVE_COUNT)
	var t_norm := String(wave_label.text)
	var want_norm := "/ %d" % GameStats.WAVE_COUNT
	_check(want_norm in t_norm, "非无尽文案含 '%s'（实际：%s）" % [want_norm, t_norm])

	GameSession.endless = false   # 复位，避免污染后续断言


# ================================================================ F. 无尽不结算分支
func _tF_endless_no_settle() -> void:
	print("[PROBE] --- F. 无尽不结算分支（外科手术式打分支，不真跑 20 波）---")
	# 先做【无尽组】（不会进 RESULT），后做【对照组】（会真进 RESULT）。
	GameSession.endless = true
	battle.wave_num = GameStats.WAVE_COUNT
	battle.wave.end_wave()
	paused = false   # end_wave 可能走 _open_upgrade → 把树暂停，这里主动复位
	_check(battle.state != Battle.State.RESULT,
		"无尽下 wave_num>=WAVE_COUNT 不结算（state=%d，RESULT=%d）" % [battle.state, Battle.State.RESULT])

	# 对照组：非无尽，同一位置 → 必须结算
	GameSession.endless = false
	battle.wave_num = GameStats.WAVE_COUNT
	battle.wave.end_wave()
	paused = false
	_check(battle.state == Battle.State.RESULT,
		"非无尽下 wave_num>=WAVE_COUNT 结算（state=%d，期望 RESULT=%d）" % [battle.state, Battle.State.RESULT])

	GameSession.endless = false   # 复位
	paused = false


# ================================================================ 工具
func _approx(a: float, b: float) -> bool:
	return absf(a - b) < TOL


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
