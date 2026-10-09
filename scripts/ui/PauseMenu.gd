class_name PauseMenu
extends CanvasLayer
## 战斗内暂停菜单。Esc 打开（只在 FIGHTING 状态）；Esc 再按一次继续（2026-10-08 补齐）。
##
## 【不做嵌套暂停】升级/商店面板本来就暂停了整棵树，那种状态下不响应暂停菜单 ——
## 否则「暂停里再暂停」的状态恢复会变成一锅粥。
##
## 2026-10-08 QoL 批次新增两个子面板（覆盖式弹层，Esc / 返回按钮逐级关闭）：
##   · 设置 —— 音量 / 伤害数字 / 屏幕震动。数据与标题设置同一套（MetaSave.settings），
##     行构建器共用 SettingRows —— 战斗内改设置不再需要退回标题。
##   · 本局构筑 —— 属性 / 已购道具 / 副武器 / 武器进化进度。数据由 Battle 注入的
##     build_provider（Callable）按调用时现场生成 —— 本类不做任何数值口径判断。

signal resumed
signal restart_requested
signal to_title_requested

var _root: Control
## 主按钮列容器（子面板打开时整体隐藏，避免视觉上叠两层）。
var _main_box: VBoxContainer
## 当前打开的子面板遮罩（null = 无）。同一时刻只允许一个子面板。
var _sub_layer: Control = null

## 本局构筑数据提供者（Battle 在 _ready 注入：Callable() -> Dictionary）。
## 未注入时按钮显示「数据不可用」兜底，不崩。
var build_provider: Callable = Callable()


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

	# 【2026-10-08 布局修正】旧写法 `box.set_anchors_preset(PRESET_CENTER)` 只把锚点
	# 设到 0.5、offset 仍为 0 ⇒ 容器【左上角】落在屏幕中心、内容整体往下铺 ——
	# 4 个按钮时勉强不出屏，加到 6 个按钮后「退出游戏」必然被底边裁掉。
	# 改用 CenterContainer（同 Title 的修复）：内容真正居中，任何按钮数都不溢出。
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.add_child(center)

	_main_box = VBoxContainer.new()
	_main_box.alignment = BoxContainer.ALIGNMENT_CENTER
	_main_box.add_theme_constant_override("separation", 14)
	center.add_child(_main_box)

	var title := Label.new()
	title.text = "暂停"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 44)
	title.add_theme_color_override("font_color", Color("#FFD700"))
	_main_box.add_child(title)

	_main_box.add_child(_button("继续", func():
		close()
		resumed.emit()))
	_main_box.add_child(_button("本局构筑", _open_build))
	_main_box.add_child(_button("设置", _open_settings))
	_main_box.add_child(_button("重开一局", func():
		close()
		restart_requested.emit()))
	_main_box.add_child(_button("回主菜单", func():
		close()
		to_title_requested.emit()))
	_main_box.add_child(_button("退出游戏", func():
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
	_close_sub()          # 连子面板一起收（防残留盖住下一局；_close_sub 幂等）
	visible = false
	get_tree().paused = false


func is_open() -> bool:
	return visible


## Esc 逐级关闭（2026-10-08）：有子面板先关子面板，否则继续游戏 ——
## 与类文档承诺的「Esc 再按一次继续」对齐。打开菜单的那次 Esc 由 Battle 消费
## （set_input_as_handled），不会落到这里；本节点 WHEN_PAUSED，暂停时照常收事件。
func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return
	if event.is_action_pressed("pause"):
		if _sub_layer != null:
			_close_sub()
		else:
			close()
			resumed.emit()
		get_viewport().set_input_as_handled()


# ---------------------------------------------------------------- 子面板（2026-10-08 QoL）
## 通用子面板外框：全屏暗罩 + 居中面板 + 金字标题 + 内容容器 + 返回按钮。
## 返回内容容器（调用方往里面塞行）；子面板挂在 _root 上（压在主按钮列之上），
## 打开期间主按钮列隐藏 —— 视觉上就是「走进下一级菜单」。
func _open_sub(title_text: String, margin: float = 28.0) -> VBoxContainer:
	_close_sub()
	_sub_layer = Control.new()
	_sub_layer.set_anchors_preset(Control.PRESET_FULL_RECT)
	_sub_layer.mouse_filter = Control.MOUSE_FILTER_STOP
	_root.add_child(_sub_layer)
	_main_box.visible = false

	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.72)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	_sub_layer.add_child(dim)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	_sub_layer.add_child(center)

	var panel := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.10, 0.11, 0.16, 0.97)
	sb.border_color = Color(0.42, 0.46, 0.68)
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(10)
	sb.content_margin_left = margin
	sb.content_margin_right = margin
	sb.content_margin_top = 20.0
	sb.content_margin_bottom = 20.0
	panel.add_theme_stylebox_override("panel", sb)
	center.add_child(panel)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 12)
	panel.add_child(box)

	var title := Label.new()
	title.text = title_text
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 30)
	title.add_theme_color_override("font_color", Color("#FFD700"))
	box.add_child(title)

	var content := VBoxContainer.new()
	content.add_theme_constant_override("separation", 12)
	box.add_child(content)

	var back := Button.new()
	back.text = "返回（Esc）"
	back.custom_minimum_size = Vector2(220, 46)
	back.add_theme_font_size_override("font_size", 17)
	back.pressed.connect(_close_sub)
	box.add_child(back)
	return content


func _close_sub() -> void:
	if _sub_layer != null:
		_sub_layer.queue_free()
		_sub_layer = null
	if _main_box != null:
		_main_box.visible = true


## 设置子面板：与标题设置共用 SettingRows（数据源 = MetaSave.settings，实时生效）。
func _open_settings() -> void:
	var content := _open_sub("设置")
	SettingRows.audio_row(content, "音乐音量", "music_vol")
	SettingRows.audio_row(content, "音效音量", "sfx_vol")
	SettingRows.toggle_row(content, "伤害数字", "show_floats")
	SettingRows.toggle_row(content, "屏幕震动", "screen_shake")


## 本局构筑子面板：全量读 build_provider 返回的字典并渲染（口径见 Battle._build_overview_data）。
func _open_build() -> void:
	var content := _open_sub("本局构筑", 24.0)
	if not build_provider.is_valid():
		var tip := Label.new()
		tip.text = "构筑数据不可用"
		tip.add_theme_font_size_override("font_size", 16)
		tip.add_theme_color_override("font_color", Color(0.7, 0.72, 0.8))
		content.add_child(tip)
		return
	var d: Dictionary = build_provider.call()

	# 武器 / 进化进度 / 金币 / 波次
	var head := Label.new()
	head.text = "武器：%s　·　%s　　金币 %d　·　第 %d 波" % [
		String(d.get("weapon", "")), String(d.get("mastery", "")),
		int(d.get("gold", 0)), int(d.get("wave", 0))]
	head.add_theme_font_size_override("font_size", 17)
	head.add_theme_color_override("font_color", Color(0.95, 0.85, 0.45))
	content.add_child(head)

	# 无尽战场规则（2026-10-08 第二梯队·无尽 2.0）：无尽 + 进过纪元才显示（空串隐藏）。
	# 区域行（2026-10-09 第二梯队·多地图）：当前地图 + 环境机制（常驻）。
	var region := String(d.get("region", ""))
	if region != "":
		var rg_lbl := Label.new()
		rg_lbl.text = "区域：%s" % region
		rg_lbl.add_theme_font_size_override("font_size", 15)
		rg_lbl.add_theme_color_override("font_color", Color(0.65, 0.88, 0.72))
		content.add_child(rg_lbl)

	# 无尽规则行（2026-10-08 第二梯队·无尽 2.0）：只在无尽 + 进过纪元时由数据提供者填。
	var er := String(d.get("endless_rule", ""))
	if er != "":
		var er_lbl := Label.new()
		er_lbl.text = "无尽规则：%s" % er
		er_lbl.add_theme_font_size_override("font_size", 15)
		er_lbl.add_theme_color_override("font_color", Color(0.86, 0.62, 0.95))
		content.add_child(er_lbl)

	# 属性网格（2 列：名 值）
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 32)
	grid.add_theme_constant_override("v_separation", 2)
	content.add_child(grid)
	for pair in d.get("stats", []):
		var name_lbl := Label.new()
		name_lbl.text = String(pair[0])
		name_lbl.add_theme_font_size_override("font_size", 15)
		name_lbl.add_theme_color_override("font_color", Color(0.66, 0.70, 0.82))
		grid.add_child(name_lbl)
		var val_lbl := Label.new()
		val_lbl.text = String(pair[1])
		val_lbl.add_theme_font_size_override("font_size", 15)
		val_lbl.add_theme_color_override("font_color", Color(0.94, 0.95, 0.99))
		grid.add_child(val_lbl)

	# 副武器行
	var ex_parts: Array[String] = []
	for e in d.get("extras", []):
		ex_parts.append("%s Lv%d/%d" % [String(e["name"]), int(e["level"]), int(e["max"])])
	var ex_lbl := Label.new()
	ex_lbl.text = "副武器：%s" % ("无" if ex_parts.is_empty() else "　".join(ex_parts))
	ex_lbl.add_theme_font_size_override("font_size", 15)
	ex_lbl.add_theme_color_override("font_color", Color(0.66, 0.70, 0.82))
	content.add_child(ex_lbl)

	# 道具墙：图标 + 计数（tooltip 显示名字）；超过 18 件折叠为「还有 N 件」
	var items: Array = d.get("items", [])
	if items.is_empty():
		var none := Label.new()
		none.text = "道具：本局还没有买过道具"
		none.add_theme_font_size_override("font_size", 15)
		none.add_theme_color_override("font_color", Color(0.66, 0.70, 0.82))
		content.add_child(none)
	else:
		var cap := 18
		var flow := HFlowContainer.new()
		flow.add_theme_constant_override("h_separation", 6)
		flow.add_theme_constant_override("v_separation", 6)
		content.add_child(flow)
		for i in mini(items.size(), cap):
			var it: Dictionary = items[i]
			var cell := VBoxContainer.new()
			cell.add_theme_constant_override("separation", 1)
			var icon := TextureRect.new()
			icon.texture = AssetDB.item_icon(String(it["id"]))
			icon.custom_minimum_size = Vector2(40.0, 40.0)
			icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
			icon.tooltip_text = String(it["name"])
			cell.add_child(icon)
			var cnt := int(it["count"])
			if cnt > 1:
				var cl := Label.new()
				cl.text = "×%d" % cnt
				cl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
				cl.add_theme_font_size_override("font_size", 12)
				cl.add_theme_color_override("font_color", Color(0.95, 0.85, 0.45))
				cell.add_child(cl)
			flow.add_child(cell)
		if items.size() > cap:
			var more := Label.new()
			more.text = "…… 还有 %d 件" % (items.size() - cap)
			more.add_theme_font_size_override("font_size", 14)
			more.add_theme_color_override("font_color", Color(0.66, 0.70, 0.82))
			content.add_child(more)
