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


## stats 约定字段：victory, waves_completed, kills, level, gold
func show_result(stats: Dictionary) -> void:
	var victory: bool = stats.get("victory", false)
	_title.text = "通关！" if victory else "失败"
	_title.add_theme_color_override("font_color", Color("#FFD700") if victory else Color("#ff4444"))
	_stats.text = "存活波数：%d\n击杀数：%d\n等级：%d\n金币：%d" % [
		stats.get("waves_completed", 0),
		stats.get("kills", 0),
		stats.get("level", 1),
		stats.get("gold", 0),
	]
	visible = true


func hide_panel() -> void:
	visible = false
