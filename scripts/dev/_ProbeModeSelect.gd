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
	_check(btns.size() == 4, "弹窗含 4 个按钮：普通/困难/无尽/取消（实际 %d）" % btns.size())
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
