class_name PauseMenu
extends CanvasLayer
## 战斗内暂停菜单。Esc 打开（只在 FIGHTING 状态）；Esc 再按一次继续。
##
## 【不做嵌套暂停】升级/商店面板本来就暂停了整棵树，那种状态下不响应暂停菜单 ——
## 否则「暂停里再暂停」的状态恢复会变成一锅粥。

signal resumed
signal restart_requested
signal to_title_requested

var _root: Control


func _ready() -> void:
	visible = false
	process_mode = Node.PROCESS_MODE_WHEN_PAUSED
	layer = 30
	_root = Control.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_root)
	UiFont.install(_root, 20)
	UiTheme.apply(_root)

	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.7)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	_root.add_child(dim)

	var box := VBoxContainer.new()
	box.set_anchors_preset(Control.PRESET_CENTER)
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_theme_constant_override("separation", 16)
	_root.add_child(box)

	var title := Label.new()
	title.text = "暂停"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 44)
	title.add_theme_color_override("font_color", Color("#FFD700"))
	box.add_child(title)

	box.add_child(_button("继续", func():
		close()
		resumed.emit()))
	box.add_child(_button("重开一局", func():
		close()
		restart_requested.emit()))
	box.add_child(_button("回主菜单", func():
		close()
		to_title_requested.emit()))
	box.add_child(_button("退出游戏", func():
		close()
		get_tree().quit(0)))


func _button(text: String, action: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(280, 58)
	b.add_theme_font_size_override("font_size", 22)
	b.pressed.connect(action)
	return b


func open() -> void:
	visible = true
	get_tree().paused = true


func close() -> void:
	visible = false
	get_tree().paused = false


func is_open() -> bool:
	return visible
