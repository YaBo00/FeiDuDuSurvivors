class_name SettingRows
extends RefCounted
## 设置项行的构建器（2026-10-08 QoL 批次）。
##
## 背景：这套「音量滑块 / 开关复选」的行构建代码此前只活在 Title.gd 的私有方法里，
## 战斗内暂停菜单要加设置入口时，把行构建抽到这里 —— 标题设置与暂停设置【共用同一套行】。
## 数据读写单一源 = MetaSave.get_setting / set_setting；本文件只有 UI，零状态、零副作用。
##
## 音量行的写档纪律（沿用 Title 旧版，质检 P2-4）：拖动中只更新缓存（flush=false）
## + 实时应用总线音量；松手（drag_ended）才整档落盘一次 —— 防每秒几十次文件 IO。

## 音量行：名称 + 滑块(0~1) + 百分比。
static func audio_row(box: VBoxContainer, label_text: String, key: String) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 16)

	var name_lbl := Label.new()
	name_lbl.text = label_text
	name_lbl.add_theme_font_size_override("font_size", 20)
	name_lbl.custom_minimum_size = Vector2(120, 0)
	row.add_child(name_lbl)

	var slider := HSlider.new()
	slider.min_value = 0.0
	slider.max_value = 1.0
	slider.step = 0.05
	slider.value = float(MetaSave.get_setting(key))
	slider.custom_minimum_size = Vector2(280, 32)
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(slider)

	var pct := Label.new()
	pct.text = "%d%%" % roundi(slider.value * 100.0)
	pct.add_theme_font_size_override("font_size", 18)
	pct.add_theme_color_override("font_color", Color(0.80, 0.84, 0.95))
	pct.custom_minimum_size = Vector2(60, 0)
	pct.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	row.add_child(pct)

	slider.value_changed.connect(func(v: float) -> void:
		MetaSave.set_setting(key, v, false)    # 只更新缓存，不落盘
		pct.text = "%d%%" % roundi(v * 100.0)
		GameAudio.apply_volume_settings())     # 实时改总线音量（读缓存）
	slider.drag_ended.connect(func(_changed: bool) -> void:
		MetaSave.set_setting(key, slider.value))   # 松手落盘（护栏再过一遍，幂等）
	box.add_child(row)


## 开关行：带文字的 CheckBox，勾选即写档。
static func toggle_row(box: VBoxContainer, label_text: String, key: String) -> void:
	var cb := CheckBox.new()
	cb.text = label_text
	cb.button_pressed = bool(MetaSave.get_setting(key))
	cb.add_theme_font_size_override("font_size", 20)
	cb.toggled.connect(func(on: bool) -> void:
		MetaSave.set_setting(key, on))
	box.add_child(cb)
