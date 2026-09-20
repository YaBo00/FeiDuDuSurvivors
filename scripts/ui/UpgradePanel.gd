class_name UpgradePanel
extends CanvasLayer
## 升级三选一面板。波末 / 升级时弹出，选择一个强化项后回调。
##
## 【暂停】弹出时 Battle 会把整棵树暂停（get_tree().paused = true），
## 否则玩家在选强化的时候还在挨打 —— 弹出即暴毙。
## 所以本节点必须设为 PROCESS_MODE_WHEN_PAUSED：游戏停了，面板还能响应点击与自动选择。
## 恢复也由这里负责（select() 里解除暂停），Battle 不用管。

var _root: Control
var _title: Label
var _hint: Label
var _buttons: Array[Button] = []
var _icons: Array[TextureRect] = []
var _labels: Array[Label] = []
## 负面代价行（A1 双向投票）：独立第二区、红色小字，无代价的卡隐藏。
var _cost_labels: Array[Label] = []

## 自动选择的延迟（面板自己的秒数）。与 Battle 旧的 UPGRADE_AUTO_DELAY 等价。
const AUTO_SELECT_DELAY := 0.3

var _options: Array = []
var _on_choice: Callable = Callable()


func _ready() -> void:
	visible = false
	# 游戏被暂停时仍要能响应（否则选不了强化）
	process_mode = Node.PROCESS_MODE_WHEN_PAUSED
	_root = Control.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_root)
	UiFont.install(_root, 20)
	UiTheme.apply(_root)

	# 半透明遮罩
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.6)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	_root.add_child(dim)

	_title = Label.new()
	_title.position = Vector2(0, 130)
	_title.size = Vector2(GameStats.VIEW_WIDTH, 50)
	_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_title.add_theme_font_size_override("font_size", 34)
	_title.add_theme_color_override("font_color", Color("#FFD700"))
	_title.text = "升级！选择一项强化"
	_title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_title)

	_hint = Label.new()
	_hint.position = Vector2(0, 190)
	_hint.size = Vector2(GameStats.VIEW_WIDTH, 30)
	_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hint.add_theme_font_size_override("font_size", 18)
	_hint.add_theme_color_override("font_color", Color(0.8, 0.8, 0.9))
	_hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_hint)

	var bw := 360.0
	var bh := 220.0
	var gap := 40.0
	var total := bw * 3.0 + gap * 2.0
	var start_x := (GameStats.VIEW_WIDTH - total) * 0.5
	for i in 3:
		var b := Button.new()
		b.position = Vector2(start_x + float(i) * (bw + gap), 270.0)
		b.size = Vector2(bw, bh)
		b.add_theme_font_size_override("font_size", 24)
		b.pressed.connect(_on_button_pressed.bind(i))
		_root.add_child(b)
		_buttons.append(b)

		# 卡片内部：图标 + 文字。Button 自身不放 text，全交给子节点排版。
		var row := HBoxContainer.new()
		row.set_anchors_preset(Control.PRESET_FULL_RECT)
		row.offset_left = 18
		row.offset_right = -18
		row.offset_top = 18
		row.offset_bottom = -18
		row.alignment = BoxContainer.ALIGNMENT_CENTER
		row.add_theme_constant_override("separation", 16)
		row.mouse_filter = Control.MOUSE_FILTER_IGNORE
		b.add_child(row)

		var icon := TextureRect.new()
		icon.custom_minimum_size = Vector2(72, 72)
		icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(icon)
		_icons.append(icon)

		var label := Label.new()
		label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		label.add_theme_font_size_override("font_size", 22)
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		label.mouse_filter = Control.MOUSE_FILTER_IGNORE

		# 负面代价行（2026-09-20 用户要求）：正面 buff（名称+效果）在上，负面代价
		# 独立成行、红色小字垫底 —— 与混排进名字行相比，正负一目了然。
		var text_box := VBoxContainer.new()
		text_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		text_box.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		text_box.add_theme_constant_override("separation", 6)
		text_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
		text_box.add_child(label)
		var cost := Label.new()
		cost.add_theme_font_size_override("font_size", 18)
		cost.add_theme_color_override("font_color", Color(1.0, 0.42, 0.36))
		cost.visible = false
		cost.mouse_filter = Control.MOUSE_FILTER_IGNORE
		text_box.add_child(cost)

		row.add_child(text_box)
		_labels.append(label)
		_cost_labels.append(cost)


## 显示选项。reason_text 说明本次为何升级。
func show_options(options: Array, wave_num: int, reason_text: String, on_choice: Callable,
		auto_select: bool = false) -> void:
	_options = options
	_on_choice = on_choice
	_auto = auto_select
	_auto_timer = AUTO_SELECT_DELAY
	_hint.text = "第 %d 波 · %s" % [wave_num, reason_text]
	for i in _buttons.size():
		var b: Button = _buttons[i]
		if i < options.size():
			var opt: Dictionary = options[i]
			b.visible = true
			b.disabled = false
			b.text = ""
			# 正面 buff（名称 + 效果预览）在上；负面「敌人代价」独立一行、红色（2026-09-20）。
			# 预览同时给出累计效果 —— 取这张卡后敌人累计变强多少，玩家才能做真正的交易判断。
			var display_text := GameStats.upgrade_display(opt, wave_num)
			# 武器精通卡携带进化进度（Battle._generate_options 注入，2026-09-20 用户需求）
			if opt.has("mastery_progress"):
				display_text += "　·　进化进度 %d/%d" % [
					int(opt["mastery_progress"]), GameStats.WEAPON_EVOLVE_LEVEL]
			_labels[i].text = "%d. %s\n%s" % [i + 1, opt["name"], display_text]
			var cost_label: Label = _cost_labels[i]
			if opt.has("cost"):
				var c: Dictionary = opt["cost"]
				cost_label.text = "代价：敌人%s" % String(c["name"])
				cost_label.visible = true
			else:
				cost_label.visible = false
			# 图标可能没有（某项还没配图）—— 那就隐藏图标框，布局自动收回
			var tex := AssetDB.upgrade_icon(String(opt["id"]))
			_icons[i].texture = tex
			_icons[i].visible = tex != null
		else:
			b.visible = false
	visible = true


## 程序化选择（自检使用）。
func select(index: int) -> void:
	if index < 0 or index >= _options.size():
		return
	if not _on_choice.is_valid():
		return
	var cb := _on_choice
	var chosen: Dictionary = _options[index]
	hide_panel()
	# 解除暂停 —— 不然选完强化游戏还是停着的
	get_tree().paused = false
	cb.call(chosen, index)


func hide_panel() -> void:
	visible = false
	_auto = false
	get_tree().paused = false


func _on_button_pressed(index: int) -> void:
	select(index)


# ---------------------------------------------------------------- 自动选择 / 暂停期输入
var _auto := false
var _auto_timer := 0.0


## 自检/观测模式：显示后自动选第 0 项。由 Battle 在打开面板时调用。
func set_auto_select(enabled: bool) -> void:
	_auto = enabled
	_auto_timer = 0.0


func _process(delta: float) -> void:
	if not visible:
		return
	if _auto:
		_auto_timer -= delta
		if _auto_timer <= 0.0:
			_auto = false
			select(0)
		return
	# 人工操作时允许 Esc 退出游戏（此时战斗已暂停，Battle 的输入不会触发）
	if Input.is_action_just_pressed("pause"):
		get_tree().paused = false
		get_tree().quit(0)
