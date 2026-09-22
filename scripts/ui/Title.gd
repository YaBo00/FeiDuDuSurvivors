extends Control
## 标题画面：游戏入口。
##
## UI 用代码搭，和 Hud / UpgradePanel / ResultPanel 的做法保持一致
## （那些也是代码建节点，本工程没有手写 UI 的 .tscn）。

const BATTLE_SCENE := "res://scenes/battle/Battle.tscn"
const CHARSEL_SCENE := "res://scenes/main/CharSelect.tscn"


func _ready() -> void:
	UiFont.install(self, 20)
	GameAudio.apply_volume_settings()   # 先把存档里的音量应用到总线，再起 BGM（2026-09-22 设置菜单）
	GameAudio.play_bgm.call_deferred(get_tree())
	UiTheme.apply(self)
	# 导出包自检入口：导出的 exe 主场景固定是本界面，且【不支持命令行指定场景】，
	# 而 Battle 的自检逻辑在 Battle 里 —— 检测到自检 flag 就跳转到战斗场景，
	# Battle._ready 会读到同一个 flag 并接管（Battle 进程退出码即测试结果）。
	if _route_selftest():
		return
	_build()


## 检测自检/观测 flag 并转发到战斗场景。命中返回 true（本界面不再构建 UI）。
func _route_selftest() -> bool:
	for flag in ["--selftest", "--selftest-defeat", "--balance"]:
		if flag in OS.get_cmdline_args() or flag in OS.get_cmdline_user_args():
			print("[Title] 检测到 %s → 转发到战斗场景执行" % flag)
			get_tree().change_scene_to_file(BATTLE_SCENE)
			return true
	return false


func _build() -> void:
	# 背景大图（已导入为 1600x900 有损 WebP）
	var bg := TextureRect.new()
	bg.texture = AssetDB.bg("title")
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	bg.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)

	# 压暗一层，保证按钮和文字看得清
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.35)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(dim)

	# 【2026-09-22 修复内容块偏下 / 溢出】旧写法 `box.set_anchors_preset(PRESET_CENTER)`
	# 只把锚点设到 0.5、offset 仍为 0 ⇒ 容器【左上角】落在屏幕中心、内容整体往下铺，
	# 内容一高（新增「设置」行后）「退出」按钮就被屏幕底边裁掉。改用 CenterContainer：
	# 它让子容器保持最小尺寸并真正居中，任何内容高度都不会溢出。
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(center)

	var box := VBoxContainer.new()
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_theme_constant_override("separation", 18)
	center.add_child(box)

	var title := Label.new()
	title.text = "肥嘟嘟幸存者"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 56)
	title.add_theme_color_override("font_color", Color("#FFD700"))
	box.add_child(title)

	# 局外账本展示（MetaSave 消费端第一片）：玩过至少一局才显示战绩行
	var ledger: Dictionary = MetaSave.ledger()
	if int(ledger["runs"]) > 0:
		var stats := Label.new()
		stats.text = "战绩：最佳 %d 波 · 累计 %d 击杀 · 共 %d 局" % [
			int(ledger["best_wave"]), int(ledger["total_kills"]), int(ledger["runs"])]
		stats.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		stats.add_theme_font_size_override("font_size", 16)
		stats.add_theme_color_override("font_color", Color(0.75, 0.78, 0.88))
		box.add_child(stats)
		# 无尽最佳（2026-09-20 无尽体验）：跑过无尽局才显示，不打扰纯普通局玩家
		if int(ledger["best_endless_wave"]) > 0:
			var inf := Label.new()
			inf.text = "无尽最佳：%d 波" % int(ledger["best_endless_wave"])
			inf.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			inf.add_theme_font_size_override("font_size", 16)
			inf.add_theme_color_override("font_color", Color(0.95, 0.80, 0.40))
			box.add_child(inf)

	box.add_child(_spacer(24))

	var start := _make_button("开始游戏", 30)
	start.pressed.connect(_on_start)
	box.add_child(start)

	# 次级入口并排一行：局外强化（MetaSave 消费端第二片）/ 设置（2026-09-22 设置菜单）
	var sub_row := HBoxContainer.new()
	sub_row.alignment = BoxContainer.ALIGNMENT_CENTER
	sub_row.add_theme_constant_override("separation", 16)
	box.add_child(sub_row)

	var meta_btn := _make_button("局外强化", 22)
	meta_btn.custom_minimum_size = Vector2(220, 48)
	meta_btn.pressed.connect(_open_meta_shop)
	sub_row.add_child(meta_btn)

	var settings_btn := _make_button("设置", 22)
	settings_btn.custom_minimum_size = Vector2(220, 48)
	settings_btn.pressed.connect(_open_settings)
	sub_row.add_child(settings_btn)

	var quit := _make_button("退出", 22)
	quit.pressed.connect(func(): get_tree().quit(0))
	box.add_child(quit)

	start.grab_focus()


# ---------------------------------------------------------------- 局外强化商店
## 商店遮罩层（非 null = 开着）。面板内容购买后整体重建（数量小，简单可靠）。
var _shop_layer: ColorRect = null


func _open_meta_shop() -> void:
	if _shop_layer != null:
		return
	_shop_layer = ColorRect.new()
	_shop_layer.color = Color(0, 0, 0, 0.62)
	_shop_layer.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_shop_layer)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	_shop_layer.add_child(center)

	var panel := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.10, 0.11, 0.16, 0.97)
	sb.border_color = Color(0.42, 0.46, 0.68)
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(10)
	sb.content_margin_left = 28.0
	sb.content_margin_right = 28.0
	sb.content_margin_top = 22.0
	sb.content_margin_bottom = 22.0
	panel.add_theme_stylebox_override("panel", sb)
	center.add_child(panel)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 10)
	panel.add_child(box)
	_rebuild_shop(box)


## 重建商店内容：标题 / xp 行 / 【两列网格】每条强化一格 / 关闭。
##
## 【2026-09-22 布局改造：3 条 → 9 条】旧版是单列 9 行 = 头部 60 + 9×50 + 关闭 40 + 内边距 ≈ 620px，
## 在 720 高的窗口里几乎顶满、再窄一点就被裁。改成 GridContainer(2 列)：5 行 ≈ 280px，
## 面板高度砍半且**条目数继续涨也不会溢出**（加到 12 条仍是 6 行）。
## 每格 = 「名称 + 等级进度点 + 效果说明」（左） + 购买按钮（右）。
func _rebuild_shop(box: VBoxContainer) -> void:
	for c in box.get_children():
		box.remove_child(c)
		c.queue_free()
	var d: Dictionary = MetaSave.ledger()

	var title := Label.new()
	title.text = "局外强化"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 30)
	title.add_theme_color_override("font_color", Color("#FFD700"))
	box.add_child(title)

	var xp := Label.new()
	xp.text = "强化点数 %d XP（每局结算自动折算）" % int(d["meta_xp"])
	xp.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	xp.add_theme_font_size_override("font_size", 17)
	xp.add_theme_color_override("font_color", Color(0.78, 0.82, 0.95))
	box.add_child(xp)

	box.add_child(_spacer(4))

	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 20)
	grid.add_theme_constant_override("v_separation", 8)
	box.add_child(grid)
	# 自动遍历 META_UPGRADES 渲染（条数由 MetaSave 表决定，本界面不硬编码任何一条）
	for u in MetaSave.META_UPGRADES:
		grid.add_child(_meta_shop_cell(u, d, box))

	box.add_child(_spacer(4))
	var close := Button.new()
	close.text = "关闭（Esc）"
	close.custom_minimum_size = Vector2(180, 40)
	close.add_theme_font_size_override("font_size", 17)
	close.pressed.connect(_close_meta_shop)
	box.add_child(close)


## 一格强化：左列（名称 + 等级点 + 效果说明） + 右列（购买/已满级按钮）。
## 购买成功后整体重建（`_rebuild_shop(box)`）—— 条目少，重建比逐格刷新简单可靠。
func _meta_shop_cell(u: Dictionary, d: Dictionary, box: VBoxContainer) -> Control:
	var id := String(u["id"])
	var lvl := maxi(0, int(d["meta_levels"].get(id, 0)))
	var maxl := int(u["max_level"])

	var cell := HBoxContainer.new()
	cell.add_theme_constant_override("separation", 10)

	var info := VBoxContainer.new()
	info.add_theme_constant_override("separation", 2)
	info.custom_minimum_size = Vector2(268, 0)
	cell.add_child(info)

	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 8)
	var name_lbl := Label.new()
	name_lbl.text = "%s  Lv.%d/%d" % [String(u["name"]), lvl, maxl]
	name_lbl.add_theme_font_size_override("font_size", 17)
	# 满级 = 金字（已吃满收益），可继续买 = 白字，未解锁 = 常规
	name_lbl.add_theme_color_override("font_color",
		Color("#FFD700") if lvl >= maxl else Color(0.90, 0.92, 0.98))
	head.add_child(name_lbl)
	head.add_child(_level_pips(lvl, maxl))
	info.add_child(head)

	var desc := Label.new()
	desc.text = String(u["desc"])
	desc.add_theme_font_size_override("font_size", 13)
	desc.add_theme_color_override("font_color", Color(0.62, 0.67, 0.80))
	info.add_child(desc)

	var buy := Button.new()
	buy.custom_minimum_size = Vector2(160, 40)
	buy.add_theme_font_size_override("font_size", 15)
	if lvl >= maxl:
		buy.text = "已满级"
		buy.disabled = true
	else:
		var price := MetaSave.upgrade_cost(id, lvl)
		buy.text = "购买 %d XP" % price
		buy.disabled = int(d["meta_xp"]) < price
		buy.pressed.connect(func():
			if MetaSave.purchase(id):
				_rebuild_shop(box))
	cell.add_child(buy)
	return cell


## 等级进度点：每级一个方块，已买 = 金色，未买 = 暗灰。max_level=1 时就是一个点
##（复活契约这类一次性大件），比「Lv.0/1」的文字更直观。
func _level_pips(lvl: int, maxl: int) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 3)
	for i in maxl:
		var pip := ColorRect.new()
		pip.custom_minimum_size = Vector2(9, 13)
		pip.color = Color("#FFD700") if i < lvl else Color(0.26, 0.29, 0.38)
		row.add_child(pip)
	return row


func _close_meta_shop() -> void:
	if _shop_layer != null:
		_shop_layer.queue_free()
		_shop_layer = null


# ---------------------------------------------------------------- 设置菜单（2026-09-22）
## 设置遮罩层（非 null = 开着）。内容复用现有弹窗样式（半透明黑底 + 面板 + 金字标题）。
## 数据全部进出 MetaSave.settings：滑块 change 即写（无需单独的「保存」按钮），
## 音量在本界面【实时】应用（GameAudio.apply_volume_settings）。
var _settings_layer: ColorRect = null


func _open_settings() -> void:
	if _settings_layer != null:
		return
	_settings_layer = ColorRect.new()
	_settings_layer.color = Color(0, 0, 0, 0.62)
	_settings_layer.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_settings_layer)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	_settings_layer.add_child(center)

	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", _panel_stylebox(28.0))
	center.add_child(panel)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 18)
	panel.add_child(box)

	var title := Label.new()
	title.text = "设置"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 32)
	title.add_theme_color_override("font_color", Color("#FFD700"))
	box.add_child(title)

	box.add_child(_spacer(4))
	_audio_setting_row(box, "音乐音量", "music_vol")
	_audio_setting_row(box, "音效音量", "sfx_vol")
	box.add_child(_spacer(4))
	_toggle_setting_row(box, "伤害数字", "show_floats")
	_toggle_setting_row(box, "屏幕震动", "screen_shake")

	box.add_child(_spacer(6))
	var back := Button.new()
	back.text = "返回（Esc）"
	back.custom_minimum_size = Vector2(220, 52)
	back.add_theme_font_size_override("font_size", 18)
	back.pressed.connect(_close_settings)
	box.add_child(back)


## 音量行：名称 + 滑块(0~1) + 百分比。拖动即写档并【实时】应用到音频总线。
func _audio_setting_row(box: VBoxContainer, label_text: String, key: String) -> void:
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

	# 拖动中只更新缓存（质检 P2-4，2026-09-22）：value_changed 每秒触发几十次，
	# 旧版每次都「读档+写档」双 IO；现在拖动中缓存实时生效（音量/百分比照常刷新），
	# 松手（drag_ended）才整档落盘一次。中途闪退最多丢最后一次拖动的值，可接受。
	slider.value_changed.connect(func(v: float) -> void:
		MetaSave.set_setting(key, v, false)    # 只更新缓存，不落盘
		pct.text = "%d%%" % roundi(v * 100.0)
		GameAudio.apply_volume_settings())     # 实时改总线音量（读缓存）
	slider.drag_ended.connect(func(_changed: bool) -> void:
		MetaSave.set_setting(key, slider.value))   # 松手落盘（护栏再过一遍，幂等）
	box.add_child(row)


## 开关行：带文字的 CheckBox，勾选即写档。
func _toggle_setting_row(box: VBoxContainer, label_text: String, key: String) -> void:
	var cb := CheckBox.new()
	cb.text = label_text
	cb.button_pressed = bool(MetaSave.get_setting(key))
	cb.add_theme_font_size_override("font_size", 20)
	cb.toggled.connect(func(on: bool) -> void:
		MetaSave.set_setting(key, on))
	box.add_child(cb)


func _close_settings() -> void:
	if _settings_layer != null:
		_settings_layer.queue_free()
		_settings_layer = null


## 弹窗面板统一样式（局外强化 / 难度选择 / 设置三处同款：半透明深底 + 描边 + 圆角）。
func _panel_stylebox(margin: float = 28.0) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.10, 0.11, 0.16, 0.97)
	sb.border_color = Color(0.42, 0.46, 0.68)
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(10)
	sb.content_margin_left = margin
	sb.content_margin_right = margin
	sb.content_margin_top = 22.0
	sb.content_margin_bottom = 22.0
	return sb


func _spacer(h: int) -> Control:
	var c := Control.new()
	c.custom_minimum_size = Vector2(0, h)
	return c


func _make_button(text: String, size: int) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(300, 62)
	b.add_theme_font_size_override("font_size", size)
	return b


func _on_start() -> void:
	_open_difficulty_select()


# ---------------------------------------------------------------- 难度选择（2026-09-20）
## 难度选择遮罩层（非 null = 开着）。点「开始游戏」先选难度，再进选人。
## 选择写入 GameSession.difficulty（权威数据源），随后走原选人/开局流程。
var _diff_layer: ColorRect = null


func _open_difficulty_select() -> void:
	if _diff_layer != null:
		return
	_diff_layer = ColorRect.new()
	_diff_layer.color = Color(0, 0, 0, 0.66)
	_diff_layer.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_diff_layer)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	_diff_layer.add_child(center)

	var panel := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.10, 0.11, 0.16, 0.97)
	sb.border_color = Color(0.42, 0.46, 0.68)
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(10)
	sb.content_margin_left = 34.0
	sb.content_margin_right = 34.0
	sb.content_margin_top = 24.0
	sb.content_margin_bottom = 24.0
	panel.add_theme_stylebox_override("panel", sb)
	center.add_child(panel)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 14)
	panel.add_child(box)

	var title := Label.new()
	title.text = "选择模式"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 32)
	title.add_theme_color_override("font_color", Color("#FFD700"))
	box.add_child(title)

	# 难度选项：数据来自 GameStats.DIFFICULTIES（改表即生效，这里不硬编码系数）。
	# 2026-09-20 用户要求：按钮【只显示模式名称】——去掉下面的数值介绍副标题。
	for key in ["normal", "hard"]:
		var def: Dictionary = GameStats.DIFFICULTIES[key]
		var b := Button.new()
		b.text = String(def["name"])
		b.custom_minimum_size = Vector2(420, 86)
		b.add_theme_font_size_override("font_size", 20)
		b.pressed.connect(_pick_difficulty.bind(String(key)))
		box.add_child(b)

	# 无尽模式（2026-09-20 无尽体验）：波次不限、曲线持续爬升、跑到阵亡为止。
	# 数值走普通难度乘区。同样只显示模式名（历史最佳纪录改在标题页展示）。
	var endless_btn := Button.new()
	endless_btn.text = "无尽模式"
	endless_btn.custom_minimum_size = Vector2(420, 86)
	endless_btn.add_theme_font_size_override("font_size", 20)
	endless_btn.pressed.connect(_pick_endless)
	box.add_child(endless_btn)

	var cancel := Button.new()
	cancel.text = "取消（Esc）"
	cancel.custom_minimum_size = Vector2(220, 56)
	cancel.add_theme_font_size_override("font_size", 16)
	cancel.pressed.connect(_close_difficulty_select)
	box.add_child(cancel)


func _pick_difficulty(key: String) -> void:
	if not GameStats.DIFFICULTIES.has(key):
		return
	GameSession.difficulty = key
	GameSession.endless = false   # 明确走普通/困难：主菜单路径每局重设，无进程内残留
	_close_difficulty_select()
	get_tree().change_scene_to_file(CHARSEL_SCENE)


func _pick_endless() -> void:
	GameSession.difficulty = "normal"
	GameSession.endless = true
	_close_difficulty_select()
	get_tree().change_scene_to_file(CHARSEL_SCENE)


func _close_difficulty_select() -> void:
	if _diff_layer != null:
		_diff_layer.queue_free()
		_diff_layer = null


## 键盘/手柄也能进（Enter 或空格）。商店/难度层开着时改为关闭对应弹层，杜绝误触开始。
func _unhandled_input(event: InputEvent) -> void:
	if _settings_layer != null:
		if event.is_action_pressed("use_item") or (event is InputEventKey and event.pressed \
				and event.keycode == KEY_ESCAPE):
			_close_settings()
			get_viewport().set_input_as_handled()
		return
	if _shop_layer != null:
		if event.is_action_pressed("use_item") or (event is InputEventKey and event.pressed \
				and (event.keycode == KEY_ENTER or event.keycode == KEY_ESCAPE)):
			_close_meta_shop()
			get_viewport().set_input_as_handled()
		return
	if _diff_layer != null:
		if event.is_action_pressed("pause") or (event is InputEventKey and event.pressed \
				and event.keycode == KEY_ESCAPE):
			_close_difficulty_select()
			get_viewport().set_input_as_handled()
		return
	if event.is_action_pressed("use_item") or (event is InputEventKey and event.pressed and event.keycode == KEY_ENTER):
		_on_start()
		get_viewport().set_input_as_handled()
