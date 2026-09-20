extends SceneTree
## 门禁：出生点必须在「实际可视区域」之外，且竞技场在可视区中居中。
##
## 为什么需要这道门禁：
##   刷怪/玩家边界原先硬编码设计尺寸 1280x720，但可视区域随窗口宽高比变化。
##   实测（stretch=canvas_items + aspect=expand，从场景内节点取 get_visible_rect）：
##       --resolution 1280x720  → 可视 1280x720
##       --resolution 1600x720  → 可视 1600x720
##       --resolution 1024x768  → 可视 1280x960
##   于是 20:9 手机上敌人会刷在 x = 1280+45 = 1325，而屏幕能显示到 1600
##   ⇒ 敌人当着玩家的面凭空出现，而不是从屏幕外走进来。
##
## 两部分：
##   A. 纯函数扫描：对多种宽高比断言 GameStats.spawn_pos() 的结果一定在可视区之外。
##      （这是唯一能在无头模式下覆盖宽屏场景的办法 —— 无头没有真实窗口。）
##   B. 端到端接线：实例化 Battle.tscn，断言【真正刷出来的敌人】都在可视区之外。
##      建议配合 --resolution 1600x720 跑，这样 B 部分才有宽屏意义。
##
## 用法:
##   godot --headless --path <项目> --script res://scripts/dev/SpawnBoundsProbe.gd
##   godot --resolution 1600x720 --path <项目> --script res://scripts/dev/SpawnBoundsProbe.gd
## 退出码 0=PASS 1=FAIL

## 待验证的窗口尺寸（覆盖手机 20:9、桌面 16:9、平板 4:3、超宽）
const WINDOWS := [
	Vector2(1280, 720),    # 16:9 设计基准
	Vector2(1600, 720),    # 20:9 手机横屏
	Vector2(2400, 1080),   # 20:9 手机（1080p）
	Vector2(2340, 1080),   # 19.5:9 手机
	Vector2(2560, 1080),   # 21:9 超宽
	Vector2(1024, 768),    # 4:3 平板
	Vector2(1280, 1024),   # 5:4 平板
]

## 抽取的随机参数（不含真随机，保证可复现）
const SAMPLES := [0.0, 0.25, 0.5, 0.75, 0.999]

var failures: Array[String] = []
var battle: Node = null
var armed := false
var done := false
var _wait_frames := 0


func _initialize() -> void:
	print("=".repeat(68))
	print(" 门禁：出生点必须落在实际可视区域之外")
	print("=".repeat(68))

	# ---------- A. 纯函数扫描 ----------
	print("\n[A] 纯函数扫描：对每种窗口尺寸，检查 4 条边 × 5 个采样点的出生点")
	print("    窗口尺寸        可视世界尺寸     竞技场居中   出生点越界")
	for win in WINDOWS:
		var visible := GameStats.visible_size_for_window(win)
		var rect := Rect2(GameStats.ARENA_CENTER - visible * 0.5, visible)

		# 相机固定对准竞技场中心 ⇒ 可视区中心必须与竞技场中心重合
		var centered: bool = rect.get_center().is_equal_approx(GameStats.ARENA_CENTER)
		if not centered:
			failures.append("窗口 %s 下竞技场未居中（可视区中心 %s ≠ 竞技场中心 %s）" % [
				win, rect.get_center(), GameStats.ARENA_CENTER,
			])

		var total := 0
		var outside := 0
		var old_inside := 0
		for side in 4:
			for r1 in SAMPLES:
				for r2 in SAMPLES:
					total += 1
					var p := GameStats.spawn_pos(rect, GameStats.SPAWN_MARGIN, side, r1, r2)
					if not rect.has_point(p):
						outside += 1
					else:
						failures.append("窗口 %s 边 %d 采样(%.3f,%.3f) 出生点 %s 落在可视区内" % [
							win, side, r1, r2, p,
						])
			# 对照：若沿用旧的「按设计尺寸 1280x720 刷怪」，有多少会落在可视区内
			var old_rect := Rect2(Vector2.ZERO, Vector2(GameStats.VIEW_WIDTH, GameStats.VIEW_HEIGHT))
			for r1 in SAMPLES:
				var op := GameStats.spawn_pos(old_rect, GameStats.SPAWN_MARGIN, side, r1, 0.5)
				if rect.has_point(op):
					old_inside += 1

		var mark_c := "OK  " if centered else "FAIL"
		var mark_o := "OK  " if outside == total else "FAIL"
		print("    %-14s  %-15s  %s         %s (%d/%d)%s" % [
			"%dx%d" % [int(win.x), int(win.y)],
			"%dx%d" % [int(visible.x), int(visible.y)],
			mark_c, mark_o, outside, total,
			"" if old_inside == 0 else "   ← 旧逻辑会有 %d 个落在屏内" % old_inside,
		])

	# ---------- B. 端到端接线 ----------
	print("\n[B] 端到端：实例化 Battle.tscn，检查【真正刷出来的敌人】位置")
	var packed: PackedScene = load("res://scenes/battle/Battle.tscn")
	if packed == null:
		failures.append("Battle.tscn 加载失败")
		_report_and_quit()
		return
	battle = packed.instantiate()
	root.add_child(battle)
	print("    Battle 已加入场景树，等待第一帧（@onready 需等 _ready 跑完）")


func _process(_delta: float) -> bool:
	if done:
		return true
	if not armed:
		armed = true
		# 刷怪改成「波内匀速投放」之后，第 1 帧可能一只都还没出 ——
		# 不能像以前那样立刻断言，要等真正刷出敌人再检查。
		print("    等待首次刷怪……")
		return false
	_wait_frames += 1
	# 等待条件用【游戏时间】而不是帧数：窗口渲染帧率不定（无垂直同步时可能几百 fps），
	# 按帧数等会在高帧率窗口下提前超时（实测 1600x720 真窗口下 600 帧不到 2 秒）。
	# 首只在 accum>=1 时出现：波1 投放速率 0.538/s → 2 个游戏秒必定至少 1 只。
	if battle.enemies.size() <= 0 and battle._game_time < 3.0 and _wait_frames < 4000:
		return false
	_check_battle()
	_report_and_quit()
	return true


func _check_battle() -> void:
	var rect: Rect2 = battle.visible_world_rect()
	var size: Vector2 = battle.visible_world_size()
	print("    本次实际可视世界尺寸 = %dx%d   显示后端 = %s" % [
		int(size.x), int(size.y), DisplayServer.get_name(),
	])
	print("    可视世界矩形 = %s（中心 %s）" % [rect, rect.get_center()])

	if not rect.get_center().is_equal_approx(GameStats.ARENA_CENTER):
		failures.append("Battle 的可视区未以竞技场为中心")

	var n: int = battle.enemies.size()
	if n <= 0:
		failures.append("第 1 帧没有刷出敌人，无法验证（n=%d）" % n)
		return
	var bad := 0
	for e in battle.enemies:
		if rect.has_point(e.global_position):
			bad += 1
			failures.append("敌人刷在可视区内：%s（类型 %s）" % [e.global_position, e.type_name])
	print("    已刷出敌人 %d 只，其中落在可视区内的 = %d" % [n, bad])


func _report_and_quit() -> void:
	done = true
	print("\n" + "=".repeat(68))
	if failures.is_empty():
		print(" RESULT=PASS  出生点全部在可视区之外，竞技场居中")
		quit(0)
	else:
		for msg in failures.slice(0, 10):
			print(" FAIL: %s" % msg)
		if failures.size() > 10:
			print(" …… 另有 %d 条未列出" % (failures.size() - 10))
		print(" RESULT=FAIL  失败项=%d" % failures.size())
		quit(1)
