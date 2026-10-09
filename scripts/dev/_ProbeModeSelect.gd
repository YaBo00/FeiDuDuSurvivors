extends SceneTree
## 临时验证：标题页「选择模式」弹窗（2026-09-20 用户报两处）——
##   A. 按钮只显示模式名（不再有数值介绍副标题 ⇒ text 不含换行）
##   B. 每个按钮的高度 ≥ 2×它的九宫格边距（否则 StyleBoxTexture 上下角块重叠、
##      背景只画一半 —— 「取消」按钮 180×42 配 margin=42 正是这个崩坏）
## 用法: godot --headless --path <项目> --script res://scripts/dev/_ProbeModeSelect.gd

var title: Node = null
var frame := 0
var checks := 0
var fails: Array[String] = []


func _initialize() -> void:
	var packed: PackedScene = load("res://scenes/main/Title.tscn")
	if packed == null:
		print("[PROBE] 载入 Title.tscn 失败")
		quit(1)
		return
	title = packed.instantiate()
	root.add_child(title)


func _process(_delta: float) -> bool:
	frame += 1
	if frame == 2:
		_run()
		return true   # 返回 true = 结束主循环（_run 内已 quit）
	return false      # 第 1 帧继续（Title._ready 已完成，等布局算好）


func _run() -> void:
	title.call("_open_difficulty_select")
	var layer = title.get("_diff_layer")
	if layer == null:
		_check(false, "模式弹窗已打开")
		_finish()
		return
	_check(true, "模式弹窗已打开")
	var btns: Array = []
	_collect_buttons(layer, btns)
	# 弹窗构成（2026-10-09 批量测口径更新）：
	#   核心 4 = 普通 / 困难 / 无尽模式 / 取消（2026-09-20 版）
	#   +1 诅咒入口（2026-10-08 第二梯队，常驻）
	#   +1 起始武器入口（2026-10-09 meta 2.0b，仅 unlock_weapon_free 解锁后出现 ——
	#      期望总数必须跟随 MetaSave 状态推导，不能写死）
	var got_lab: Array[String] = []
	for b in btns:
		got_lab.append(String(b.text))
	var missing: Array[String] = []
	for w in ["普通", "困难", "无尽模式", "取消（Esc）"]:
		if not got_lab.has(String(w)):
			missing.append(String(w))
	var want_n := 5 + (1 if MetaSave.is_meta_unlocked("unlock_weapon_free") else 0)
	_check(btns.size() == want_n and missing.is_empty(),
		"弹窗按钮构成齐全（核心 4 + 诅咒入口 + 可选武器入口）：期望 %d 个 / 实际 %d 个，缺失 %s" % [
			want_n, btns.size(), str(missing)])
	for b in btns:
		var txt := String(b.text)
		_check(not txt.contains("\n"),
			"按钮「%s」无副标题（text 不含换行）" % txt.substr(0, mini(12, txt.length())))
		var sb: StyleBox = b.get_theme_stylebox("normal")
		var m := 0.0
		if sb is StyleBoxTexture:
			m = maxf(sb.texture_margin_top, sb.texture_margin_bottom)
		_check(b.custom_minimum_size.y >= 2.0 * m - 0.5,
			"按钮「%s」高 %.0f ≥ 2×九宫格边距 %.0f" % [txt.substr(0, mini(12, txt.length())),
				b.custom_minimum_size.y, m])
	_finish()


func _collect_buttons(node: Node, out: Array) -> void:
	for c in node.get_children():
		if c is Button:
			out.append(c)
		_collect_buttons(c, out)


func _finish() -> void:
	print("[PROBE] 断言 %d/%d 通过（失败 %d）" % [checks - fails.size(), checks, fails.size()])
	for f in fails:
		print("[PROBE]   - %s" % f)
	print("[PROBE] RESULT=%s" % ("PASS" if fails.is_empty() else "FAIL"))
	quit(0 if fails.is_empty() else 1)


func _check(cond: bool, label: String) -> void:
	checks += 1
	if cond:
		print("[PROBE]   OK   %s" % label)
	else:
		fails.append(label)
		print("[PROBE]   FAIL %s" % label)
