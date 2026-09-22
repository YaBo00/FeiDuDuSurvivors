extends SceneTree
## 门禁：波次清场节奏（2026-09-21 用户需求改造的验收探针）。
##
## 被验证的契约（需求原文）：
##   「每一波 30s 为生成敌人的时间，30s 倒计时结束后不再生成敌人，这一波的通关条件为：
##     30s 倒计时结束后，清理完场上所有敌人即通过。……屏幕上就不再显示 30s 倒计时，
##     而是在相应位置显示跟血量、经验值类似的进度条，用黄色粗线条展示。」
##   用户补充：进度条按【击杀百分比】走 —— 30s 结束时一个没杀 = 0%。
##
## 断言分组：
##   A. 常量口径：SPAWN_WINDOW == WAVE_DURATION（整波都在投放，投放期 == 整波）
##   B. 投放闸门：窗口结束（wave_timer ≤ 0）后 tick_spawn 一帧都不再放怪
##   C. 清场判定：窗口结束后「场上有活怪 → 不推进 / 清空 → 推进」
##   D. 进度比值（2026-09-21 二改）：窗口内也实时增长 = 击杀/计划总数(planned)；
##      杀满 planned = 1.0；超额 clamp 仍 1.0；零击杀 = 0.0；Boss 波分母 +1
##   E. HUD：倒计时文案已移除（「剩余 … 秒」不得再出现）+ 黄条几何/配色
##   F. 波次号仍在原位置居中（用户明确要求「在原来的地方居中」）
##
## 用法: godot --headless --path <项目> --script res://scripts/dev/_ProbeWaveClear.gd
## 退出码 0=PASS 1=FAIL（门禁用退出码判定）

var _battle = null
var _frame := 0
var _checks := 0
var _fails: Array[String] = []


func _initialize() -> void:
	print("[PROBE] ===== 波次清场节奏（2026-09-21 用户需求）=====")
	var packed = load("res://scenes/battle/Battle.tscn")
	if packed == null:
		_finish(false, "载入 Battle.tscn 失败")
		return
	_battle = packed.instantiate()
	root.add_child(_battle)
	print("[PROBE] Battle 已入树，断言推迟到第一帧")


func _process(_delta: float) -> bool:
	_frame += 1
	if _frame < 2:
		return false
	_run()
	return true


func _run() -> void:
	var gs = load("res://scripts/data/Stats.gd")
	var consts: Dictionary = gs.get_script_constant_map()
	if not consts.has("SPAWN_WINDOW") or not consts.has("WAVE_DURATION"):
		_finish(false, "GameStats 缺 SPAWN_WINDOW / WAVE_DURATION")
		return

	_tA_window_equals_duration(consts)
	_tB_spawn_gate_closed()
	_tC_clear_gate(consts)
	_tD_ratio()
	_tE_hud()
	_tF_wave_label_centered()
	_finish(true, "")


# ================================================================ A. 常量口径
func _tA_window_equals_duration(consts: Dictionary) -> void:
	print("[PROBE] --- A. 投放窗口 == 整波时长 ---")
	var win := float(consts["SPAWN_WINDOW"])
	var dur := float(consts["WAVE_DURATION"])
	_check(win == dur,
		"SPAWN_WINDOW(%.1f) == WAVE_DURATION(%.1f)：整波 30 秒全程投放，两者必须取齐" % [win, dur])
	_check(win == 30.0, "SPAWN_WINDOW == 30.0（用户指定 26 → 30，实际 %.1f）" % win)


# ================================================================ B. 投放闸门
## 窗口结束后即使还有 spawn_remaining、即使场上空着，也一只都不许再放。
func _tB_spawn_gate_closed() -> void:
	print("[PROBE] --- B. 投放窗口结束后一帧都不再放怪 ---")
	_battle.set_physics_process(false)          # 冻结 Battle 主循环，自己手工驱动
	_battle.wave.set_physics_process(false)
	var wave = _battle.wave

	# 造一个「窗口刚关闭 + 还有一大堆没放 + 场上空着」的最恶劣状态：
	# 旧实现（elif wave_timer <= 0 → 先 end_wave）与「窗口未闸门」实现都会在这里翻车。
	_battle.spawn_remaining = 50
	_battle.wave_timer = 0.0
	_battle.wave.reset_clear_tracking()
	var before: int = int(_battle.enemies.size())
	for i in 30:
		wave.tick_spawn(0.5)                    # 30 × 0.5s = 15 秒的模拟投放
	var after: int = int(_battle.enemies.size())
	_check(before == 0, "前置：场上清零（实际 %d）" % before)
	_check(after == before,
		"窗口结束后 tick_spawn 不再放怪（模拟 15s，场上 %d → %d）" % [before, after])
	_check(wave.spawned_count() == 0,
		"窗口结束后本波累计投放数仍为 0（实际 %d）" % wave.spawned_count())
	_check(int(_battle.spawn_remaining) == 50,
		"未投放的名额原地保留、不被静默消费（spawn_remaining=%d）" % _battle.spawn_remaining)

	# 对照组：窗口【开启】时必须真的会放 —— 否则上面的断言可能是「永远不放」的假通过
	_battle.spawn_remaining = 50
	_battle.wave_timer = float(load("res://scripts/data/Stats.gd").WAVE_DURATION)
	for i in 30:
		wave.tick_spawn(0.5)
	var live_after_open: int = int(_battle.enemies.size())
	_check(live_after_open > 0,
		"对照组：窗口开启时确实会放怪（模拟 15s，场上 %d 只）" % live_after_open)
	_battle._free_all_enemies()


# ================================================================ C. 清场判定
func _tC_clear_gate(consts: Dictionary) -> void:
	print("[PROBE] --- C. 清场判定：窗口后「清空才推进」---")
	_check(_battle._wave_cleared(), "场上无怪 → _wave_cleared() == true")

	# 放一只活怪 → 不许推进
	_battle.wave.spawn_enemy("Slime", _battle.player.global_position + Vector2(300.0, 0.0))
	_check(not _battle._wave_cleared(),
		"场上有一只活怪 → _wave_cleared() == false（实际 false）")

	# 标记死亡但【尚未 queue_free 释放】→ 也必须算清空
	# （queue_free 是延迟释放，用 is_instance_valid 判会被骗过去 —— 这是本探针要锁的坑）
	var e = _battle.enemies[0]
	e.is_dead = true
	_check(_battle._wave_cleared(),
		"怪物已 is_dead（queue_free 尚未生效）→ 也算清空（不清空会卡死换波）")
	_battle._free_all_enemies()

	# 窗口未结束时：清场判定【不该】被当作推进依据（B 组已证明此时还在投放）
	# ⚠️ 判据用「窗口内 spawn 会生效」而不是「ratio == 0」：B 组证明了 tick_spawn 在
	# wave_timer=0 时确实不放怪，而 ratio 在窗口内另有语义（见 D 组），两者别混。
	_check(not _battle.wave.spawn_window_closed() or float(consts["WAVE_DURATION"]) == 0.0,
		"wave_timer 复位到 WAVE_DURATION 后窗口重新开启")


# ================================================================ D. 进度比值
func _tD_ratio() -> void:
	print("[PROBE] --- D. 进度 = 击杀 / 本波计划总数(planned)，窗口内也实时增长 ---")
	var wave = _battle.wave
	var gs = load("res://scripts/data/Stats.gd")
	# 分母从常量/函数推导（铁律：探针期望不硬编码）。探针 Battle 未开波 → wave_num=0。
	var planned: int = int(gs.spawn_count(int(_battle.wave_num)))
	_check(planned > 0,
		"D 前置：planned = spawn_count(%d) = %d > 0" % [int(_battle.wave_num), planned])

	# D0 窗口内实时增长（2026-09-21 二改的核心回归锁）：旧版窗口未关恒返 0，
	# 用户实测否决 —— 「只要开始击杀敌人，进度条就应随之逐渐增长」。
	_battle.wave_timer = float(gs.WAVE_DURATION)      # 窗口【开启】
	_battle._free_all_enemies()
	_battle.kills = 0
	_battle.wave.reset_clear_tracking()
	for i in 4:
		wave.spawn_enemy("Slime", _battle.player.global_position + Vector2(400.0 + i * 40.0, 0.0))
	_battle.enemies[0].is_dead = true
	_battle.kills += 1
	var r0: float = wave.wave_clear_ratio()
	_check(absf(r0 - 1.0 / float(planned)) <= 1e-6,
		"D0 窗口内杀 1 只 → 进度 = 1/planned = %.4f（实际 %.4f，旧版此处恒 0）" % [
			1.0 / float(planned), r0])

	# D1 零击杀：一个都没杀 = 0（用户原话：「30s 结束一个敌人没杀，进度条就是 0」）
	# ⚠️ 基准必须在【放怪之前】取，而且要把 kills 拉到基准值本身 ——
	# reset_clear_tracking() 把 kills_at_wave_start 记成当前 kills，所以先把 kills 归零。
	_battle.wave_timer = 0.0                          # 锁死「窗口已关闭」
	_battle._free_all_enemies()
	_battle.kills = 0
	_battle.wave.reset_clear_tracking()
	for i in 4:
		wave.spawn_enemy("Slime", _battle.player.global_position + Vector2(400.0 + i * 40.0, 0.0))
	_check(wave.killed_count() == 0, "D1 前置：本波击杀 = 0（实际 %d）" % wave.killed_count())
	_check(wave.spawned_count() == 4, "D1 前置：场上投放 4 只（实际 %d）" % wave.spawned_count())
	_check(wave.wave_clear_ratio() == 0.0,
		"D1 零击杀 → 进度 0.00（实际 %.3f）" % wave.wave_clear_ratio())

	# D2 部分击杀：4 只在场杀 2 只 → 2/planned（分母是计划总数，不再是「场上+击杀」）
	_battle.enemies[0].is_dead = true
	_battle.enemies[1].is_dead = true
	_battle.kills += 2
	var r2: float = wave.wave_clear_ratio()
	_check(absf(r2 - 2.0 / float(planned)) <= 1e-6,
		"D2 杀 2 只 → 进度 = 2/planned = %.4f（实际 %.4f）" % [2.0 / float(planned), r2])

	# D3 杀满 planned → 1.0；超额（分裂/召唤产物不占名额）clamp 仍 1.0
	_battle._free_all_enemies()
	_battle.kills = planned
	var r3: float = wave.wave_clear_ratio()
	_check(absf(r3 - 1.0) <= 1e-6,
		"D3 杀满 planned(%d) → 进度 1.00（实际 %.3f）" % [planned, r3])
	_battle.kills = planned + 5
	var r3b: float = wave.wave_clear_ratio()
	_check(absf(r3b - 1.0) <= 1e-6,
		"D3b 击杀超投 5 只 → clamp 仍 1.00（实际 %.3f）" % r3b)

	# D4 Boss 波：Boss 不占 spawn_count 名额 → 分母 = planned + 1（占最后一份进度）。
	# 波号从 BOSS_WAVES 常量取（Array[int]），不硬编码。
	var boss_wave: int = int(gs.get_script_constant_map()["BOSS_WAVES"][0])
	_battle.wave_num = boss_wave
	_battle.kills = 0
	_battle.wave.reset_clear_tracking()
	var planned_boss: int = int(gs.spawn_count(boss_wave)) + 1
	_battle.kills = int(gs.spawn_count(boss_wave))
	var r4: float = wave.wave_clear_ratio()
	_check(absf(r4 - float(int(gs.spawn_count(boss_wave))) / float(planned_boss)) <= 1e-6,
		"D4 Boss 波杀满普通名额（Boss 未死）→ %.4f（实际 %.4f）" % [
			float(int(gs.spawn_count(boss_wave))) / float(planned_boss), r4])
	_battle.kills = planned_boss
	var r4b: float = wave.wave_clear_ratio()
	_check(absf(r4b - 1.0) <= 1e-6,
		"D4b Boss 也击杀 → 进度 1.00（实际 %.3f）" % r4b)

	# 复位：波号 / 击杀 / 计数基准 / 场面 / 计时器，不污染 E/F 组
	_battle.wave_num = 0
	_battle.kills = 0
	_battle.wave.reset_clear_tracking()
	_battle._free_all_enemies()
	_battle.wave_timer = float(gs.WAVE_DURATION)


# ================================================================ E. HUD
func _tE_hud() -> void:
	print("[PROBE] --- E. HUD：倒计时移除 + 黄色粗条 ---")
	var hud = _battle.hud
	var player = _battle.player
	if hud == null or player == null:
		_check(false, "battle.hud / battle.player 为 null")
		return
	var wave_label = hud.get("_wave_label")
	_check(wave_label != null, "hud._wave_label 存在")
	if wave_label == null:
		return

	# E1 倒计时文案必须消失（普通波 / 无尽波 / Boss 波三种分支都不得含「剩余」）
	var cases := [
		{"num": 5, "timer": 12.0, "endless": false},
		{"num": GameStats.WAVE_COUNT + 1, "timer": 12.0, "endless": true},
		{"num": 10, "timer": 12.0, "endless": false},
	]
	for c in cases:
		GameSession.endless = bool(c["endless"])
		hud.set_data(player, int(c["num"]), float(c["timer"]), GameStats.WAVE_COUNT)
		var t := String(wave_label.text)
		_check(not ("剩余" in t),
			"波 %d（无尽=%s）文案不含「剩余」倒计时（实际：%s）" % [int(c["num"]), str(c["endless"]), t])
		_check(not ("秒" in t),
			"波 %d 文案不含「秒」（实际：%s）" % [int(c["num"]), t])
	GameSession.endless = false

	# E2 黄条存在、位置在波次号正下方、水平居中
	var fill = hud.get("_clear_fill")
	var bg = hud.get("_clear_bar_bg")
	_check(fill != null and bg != null, "hud 黄条（bg/fill）已创建")
	if fill == null or bg == null:
		return
	var bg_y: float = bg.position.y
	var label_bottom: float = wave_label.position.y + wave_label.size.y
	_check(bg_y >= label_bottom,
		"黄条在波次号【下方】（条 y=%.0f ≥ 波次号下缘 %.0f）" % [bg_y, label_bottom])
	# 居中：条中心 x ≈ 视口中心
	var center: float = bg.position.x + bg.size.x * 0.5
	_check(absf(center - GameStats.VIEW_WIDTH * 0.5) <= 1.0,
		"黄条水平居中（中心 x=%.1f，视口中心 %.1f）" % [center, GameStats.VIEW_WIDTH * 0.5])
	# 粗线条：比经验条(10px)厚
	var xp_h: float = float(hud.XP_BAR_H)
	_check(bg.size.y > xp_h,
		"黄条是【粗】线条：高 %.0f > 经验条高 %.0f" % [bg.size.y, xp_h])
	# 黄色：R 与 G 都显著高于 B
	var col: Color = fill.color
	_check(col.r > 0.85 and col.g > 0.65 and col.b < 0.55,
		"填充色是黄色系（r=%.2f g=%.2f b=%.2f）" % [col.r, col.g, col.b])

	# E3 进度刷新：0 → 满
	hud.set_clear_ratio(0.0)
	var w0: float = fill.size.x
	hud.set_clear_ratio(0.5)
	var w1: float = fill.size.x
	hud.set_clear_ratio(1.0)
	var w2: float = fill.size.x
	_check(w0 == 0.0, "进度 0%% → 条宽 0（实际 %.1f）" % w0)
	_check(w1 > w0 and w2 > w1, "进度 0 → 50%% → 100%% 条宽递增（%.0f / %.0f / %.0f）" % [w0, w1, w2])
	_check(w2 <= bg.size.x + 0.5,
		"满进度不超过底槽宽度（%.1f ≤ %.1f）" % [w2, bg.size.x])
	# 越界钳制：>1 与 <0 不得画出屏幕
	hud.set_clear_ratio(3.0)
	_check(fill.size.x <= bg.size.x + 0.5, "进度 >1 被钳制（实际宽 %.1f）" % fill.size.x)
	hud.set_clear_ratio(-2.0)
	_check(fill.size.x == 0.0, "进度 <0 被钳制为 0（实际宽 %.1f）" % fill.size.x)


# ================================================================ F. 波次号居中
func _tF_wave_label_centered() -> void:
	print("[PROBE] --- F. 波次号仍在原位置居中 ---")
	var hud = _battle.hud
	var wave_label = hud.get("_wave_label")
	if wave_label == null:
		return
	_check(wave_label.horizontal_alignment == HORIZONTAL_ALIGNMENT_CENTER,
		"波次号 Label 水平居中（alignment=%d）" % wave_label.horizontal_alignment)
	var cx: float = wave_label.position.x + wave_label.size.x * 0.5
	_check(absf(cx - GameStats.VIEW_WIDTH * 0.5) <= 1.0,
		"波次号居中于视口（中心 x=%.1f）" % cx)
	_check(wave_label.position.y == 12.0,
		"波次号 y == 12（用户要求「在原来的地方」，实际 %.0f）" % wave_label.position.y)


# ================================================================ 工具
func _check(cond: bool, label: String) -> void:
	_checks += 1
	if cond:
		print("[PROBE]   OK   %s" % label)
	else:
		_fails.append(label)
		print("[PROBE]   FAIL %s" % label)


func _finish(ok: bool, early: String) -> void:
	if not early.is_empty():
		_fails.append(early)
	print("[PROBE] 断言 %d/%d 通过（失败 %d）" % [_checks - _fails.size(), _checks, _fails.size()])
	for f in _fails:
		print("[PROBE]   - %s" % f)
	var passed := ok and _fails.is_empty()
	print("[PROBE] RESULT=%s" % ("PASS" if passed else "FAIL"))
	quit(0 if passed else 1)
