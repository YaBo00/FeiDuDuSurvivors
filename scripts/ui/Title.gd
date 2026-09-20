extends Control
## 标题画面：游戏入口。
##
## UI 用代码搭，和 Hud / UpgradePanel / ResultPanel 的做法保持一致
## （那些也是代码建节点，本工程没有手写 UI 的 .tscn）。

const BATTLE_SCENE := "res://scenes/battle/Battle.tscn"
const CHARSEL_SCENE := "res://scenes/main/CharSelect.tscn"


func _ready() -> void:
	UiFont.install(self, 20)
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

	var box := VBoxContainer.new()
	box.set_anchors_preset(Control.PRESET_CENTER)
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_theme_constant_override("separation", 18)
	add_child(box)

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

	box.add_child(_spacer(24))

	var start := _make_button("开始游戏", 30)
	start.pressed.connect(_on_start)
	box.add_child(start)

	# 局外强化商店（MetaSave 消费端第二片）：永久成长购买入口
	var meta_btn := _make_button("局外强化", 22)
	meta_btn.custom_minimum_size = Vector2(300, 48)
	meta_btn.pressed.connect(_open_meta_shop)
	box.add_child(meta_btn)

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


## 重建商店内容：标题 / xp 行 / 每条强化一行（信息 + 购买）/ 关闭。
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

	box.add_child(_spacer(6))

	for u in MetaSave.META_UPGRADES:
		var id := String(u["id"])
		var lvl := maxi(0, int(d["meta_levels"].get(id, 0)))
		var maxl := int(u["max_level"])
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 14)

		var info := Label.new()
		info.text = "%s（%s）  Lv.%d/%d" % [String(u["name"]), String(u["desc"]), lvl, maxl]
		info.add_theme_font_size_override("font_size", 18)
		info.custom_minimum_size = Vector2(340, 0)
		row.add_child(info)

		var buy := Button.new()
		buy.custom_minimum_size = Vector2(180, 40)
		buy.add_theme_font_size_override("font_size", 16)
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
		row.add_child(buy)
		box.add_child(row)

	box.add_child(_spacer(6))
	var close := Button.new()
	close.text = "关闭（Esc）"
	close.custom_minimum_size = Vector2(180, 40)
	close.add_theme_font_size_override("font_size", 17)
	close.pressed.connect(_close_meta_shop)
	box.add_child(close)


func _close_meta_shop() -> void:
	if _shop_layer != null:
		_shop_layer.queue_free()
		_shop_layer = null


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
	get_tree().change_scene_to_file(CHARSEL_SCENE)


## 键盘/手柄也能进（Enter 或空格）。商店开着时改为关闭商店，杜绝误触开始。
func _unhandled_input(event: InputEvent) -> void:
	if _shop_layer != null:
		if event.is_action_pressed("use_item") or (event is InputEventKey and event.pressed \
				and (event.keycode == KEY_ENTER or event.keycode == KEY_ESCAPE)):
			_close_meta_shop()
			get_viewport().set_input_as_handled()
		return
	if event.is_action_pressed("use_item") or (event is InputEventKey and event.pressed and event.keycode == KEY_ENTER):
		_on_start()
		get_viewport().set_input_as_handled()
