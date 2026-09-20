class_name ResultPanel
extends CanvasLayer
## 关卡结束（失败 / 通关）结算面板。

var _root: Control
var _title: Label
var _stats: Label
var _hint: Label
var _back: Button


func _ready() -> void:
	visible = false
	_root = Control.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_root)
	UiFont.install(_root, 20)
	UiTheme.apply(_root)

	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.72)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	_root.add_child(dim)

	_title = _make_label(0.0, 220.0, GameStats.VIEW_WIDTH, 70.0, 48)
	_stats = _make_label(0.0, 320.0, GameStats.VIEW_WIDTH, 160.0, 26)
	_hint = _make_label(0.0, 560.0, GameStats.VIEW_WIDTH, 30.0, 18)
	_hint.add_theme_color_override("font_color", Color(0.8, 0.8, 0.9))
	_hint.text = "按 R 重开一局     按 ESC 退出"

	# 返回标题（有主菜单之后必须给一条回主菜单的路）
	_back = Button.new()
	_back.text = "返回标题"
	_back.custom_minimum_size = Vector2(200, 54)
	_back.position = Vector2((GameStats.VIEW_WIDTH - 200.0) * 0.5, 480.0)
	_back.size = Vector2(200, 54)
	_back.add_theme_font_size_override("font_size", 22)
	_back.mouse_filter = Control.MOUSE_FILTER_STOP
	_back.pressed.connect(func(): get_tree().change_scene_to_file("res://scenes/main/Title.tscn"))
	_root.add_child(_back)


func _make_label(x: float, y: float, w: float, h: float, size: int) -> Label:
	var l := Label.new()
	l.position = Vector2(x, y)
	l.size = Vector2(w, h)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	l.add_theme_font_size_override("font_size", size)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(l)
	return l


## stats 约定字段：victory, waves_completed, kills, level, gold, difficulty（可选）
##                 endless / endless_best / new_record（可选，2026-09-20 无尽体验 —— 缺省按普通局渲染）
func show_result(stats: Dictionary) -> void:
	var victory: bool = stats.get("victory", false)
	var endless: bool = stats.get("endless", false)
	if victory:
		_title.text = "通关！"
		_title.add_theme_color_override("font_color", Color("#FFD700"))
	elif endless:
		_title.text = "无尽终局"
		_title.add_theme_color_override("font_color", Color("#ff4444"))
	else:
		_title.text = "失败"
		_title.add_theme_color_override("font_color", Color("#ff4444"))
	# 难度行（2026-09-20 难度系统）：字段缺省时省略 —— 旧调用方/探针零影响
	var diff_name := String(stats.get("difficulty", ""))
	var diff_line := "难度：%s\n" % diff_name if diff_name != "" else ""
	# 无尽行（2026-09-20）：历史最佳常驻；破纪录在标题下加一行高亮提示
	var endless_line := ""
	if endless:
		endless_line = "无尽最佳：%d 波\n" % int(stats.get("endless_best", 0))
		if bool(stats.get("new_record", false)):
			endless_line = "新纪录！\n" + endless_line
	_stats.text = "%s%s%s\n击杀数：%d\n等级：%d\n金币：%d" % [
		diff_line,
		endless_line,
		("抵达波数：%d" if endless else "存活波数：%d") % int(stats.get("waves_completed", 0)),
		stats.get("kills", 0),
		stats.get("level", 1),
		stats.get("gold", 0),
	]
	if bool(stats.get("new_record", false)):
		_title.text += "  ★"
	visible = true


func hide_panel() -> void:
	visible = false


## 结算页 Esc = 退出游戏。提示文案一直写着「按 ESC 退出」，但此前没有任何人接
## —— 纯死键（2026-09-20 全库审查 P1）。语义与 UpgradePanel 的 Esc 一致。
## RESULT 状态树未暂停，本节点默认能收 _unhandled_input；visible 守卫防误触。
func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return
	if event.is_action_pressed("pause"):
		get_tree().quit(0)
