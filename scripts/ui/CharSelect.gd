extends Control
## 选角界面（参考永劫无间的英雄选择）：
##   左侧  头像缩略图列表（点击选中，可支持任意数量）
##   中间  选中角色的大立绘 + 名字
##   右侧  天赋说明 + 属性条
##   底部  开始游戏 / 返回
##
## 角色数据全部来自 GameStats.CHARACTERS（数值单一数据源），
## 立绘来自 AssetDB.char_portrait()。界面本身不含任何数值。

const BATTLE_SCENE := "res://scenes/battle/Battle.tscn"
const TITLE_SCENE := "res://scenes/main/Title.tscn"

## 左侧缩略图尺寸与排列
const THUMB := 96.0
const THUMB_COLS := 2
## 属性条的显示量程（把基础属性映射到 0~1 的条长）
const STAT_BARS := [
	{"key": "maxHp", "name": "生命", "max": 150.0, "pct": false},
	{"key": "atk", "name": "攻击", "max": 20.0, "pct": false},
	{"key": "spd", "name": "移速", "max": 200.0, "pct": false},
	{"key": "aspd", "name": "攻速", "max": 1.5, "pct": false},
	{"key": "crit", "name": "暴击", "max": 0.25, "pct": true},
	{"key": "dodge", "name": "闪避", "max": 0.30, "pct": true},
]

var _ids: Array = []
var _selected := ""
var _thumbs: Array[Button] = []
var _thumb_ids: Array[String] = []

var _big: TextureRect
var _name_label: Label
var _talent_label: Label
var _weapon_label: Label
var _desc_label: Label
var _stats_box: VBoxContainer
var _start_btn: Button

# ---- 角色解锁 / 模拟充值（2026-09-20 用户需求）----
## 模拟价格（[PLACEHOLDER]）：解锁一名角色的「展示用」价格。
const UNLOCK_PRICE := 10000
## 充值弹窗层（非 null = 开着）。
var _pay_layer: ColorRect = null


func _ready() -> void:
	UiFont.install(self, 20)
	UiTheme.apply(self)
	GameAudio.play_bgm.call_deferred(get_tree())
	_ids = GameStats.character_ids()
	_selected = GameSession.selected_char if _ids.has(GameSession.selected_char) \
		else (String(_ids[0]) if _ids.size() > 0 else GameStats.DEFAULT_CHAR)
	# 上次游玩的角色可能尚未解锁（解锁体系新上线）：回落到第一个已解锁角色
	if not MetaSave.is_char_unlocked(_selected):
		for id in _ids:
			if MetaSave.is_char_unlocked(String(id)):
				_selected = String(id)
				break
	_build()
	_apply_lock_styles()
	_select(_selected)


func _build() -> void:
	var bg := TextureRect.new()
	bg.texture = AssetDB.bg("charsel")
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	bg.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)

	# 压暗背景：这版布局信息密度高，背景只当舞台氛围
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.62)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(dim)

	# ---------------- 左：头像列表 ----------------
	var left := PanelContainer.new()
	left.position = Vector2(36, 90)
	left.size = Vector2(THUMB_COLS * (THUMB + 14.0) + 30.0, 470.0)
	left.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(left)

	var grid := GridContainer.new()
	grid.columns = THUMB_COLS
	grid.add_theme_constant_override("h_separation", 12)
	grid.add_theme_constant_override("v_separation", 12)
	left.add_child(grid)

	for id in _ids:
		var b := Button.new()
		b.custom_minimum_size = Vector2(THUMB, THUMB)
		b.focus_mode = Control.FOCUS_ALL
		b.pressed.connect(_select.bind(String(id)))
		var pic := TextureRect.new()
		pic.texture = AssetDB.char_portrait(String(id))
		pic.set_anchors_preset(Control.PRESET_FULL_RECT)
		pic.offset_left = 6
		pic.offset_right = -6
		pic.offset_top = 6
		pic.offset_bottom = -6
		pic.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		pic.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		pic.mouse_filter = Control.MOUSE_FILTER_IGNORE
		b.add_child(pic)
		grid.add_child(b)
		_thumbs.append(b)
		_thumb_ids.append(String(id))

	# ---------------- 中：大立绘 + 名字 ----------------
	_big = TextureRect.new()
	_big.position = Vector2(360, 96)
	_big.size = Vector2(400, 420)
	_big.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_big.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_big.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_big)

	_name_label = Label.new()
	_name_label.position = Vector2(360, 520)
	_name_label.size = Vector2(400, 56)
	_name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_name_label.add_theme_font_size_override("font_size", 42)
	_name_label.add_theme_color_override("font_color", Color("#FFD700"))
	_name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_name_label)

	# 当前难度提示（2026-09-20 难度系统）：主菜单已选，这里只读展示
	var diff_label := Label.new()
	diff_label.text = "难度 · %s" % GameStats.difficulty_name()
	diff_label.position = Vector2(360, 580)
	diff_label.size = Vector2(400, 34)
	diff_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	diff_label.add_theme_font_size_override("font_size", 20)
	diff_label.add_theme_color_override("font_color",
		Color("#7CFC8A") if GameStats.difficulty_key() == "normal" else Color("#ff6b6b"))
	diff_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(diff_label)

	# ---------------- 右：天赋 + 属性 ----------------
	var right := VBoxContainer.new()
	right.position = Vector2(800, 96)
	right.size = Vector2(440, 480)
	right.add_theme_constant_override("separation", 12)
	right.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(right)

	_talent_label = Label.new()
	_talent_label.add_theme_font_size_override("font_size", 28)
	_talent_label.add_theme_color_override("font_color", Color("#FFD700"))
	right.add_child(_talent_label)

	# 武器行：数据全部来自 GameStats.WEAPON_DEFS，改表即生效。
	_weapon_label = Label.new()
	_weapon_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_weapon_label.add_theme_font_size_override("font_size", 17)
	_weapon_label.add_theme_color_override("font_color", Color(0.72, 0.86, 1.0))
	right.add_child(_weapon_label)

	_desc_label = Label.new()
	_desc_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_desc_label.add_theme_font_size_override("font_size", 18)
	_desc_label.add_theme_color_override("font_color", Color(0.86, 0.88, 0.95))
	right.add_child(_desc_label)

	right.add_child(_gap(10))
	var stat_title := Label.new()
	stat_title.text = "基础属性"
	stat_title.add_theme_font_size_override("font_size", 20)
	stat_title.add_theme_color_override("font_color", Color(0.75, 0.78, 0.88))
	right.add_child(stat_title)

	_stats_box = VBoxContainer.new()
	_stats_box.add_theme_constant_override("separation", 7)
	right.add_child(_stats_box)

	# ---------------- 底部按钮 ----------------
	var back := Button.new()
	back.text = "返回"
	back.custom_minimum_size = Vector2(180, 54)
	back.position = Vector2(40, 636)
	back.pressed.connect(func(): get_tree().change_scene_to_file(TITLE_SCENE))
	add_child(back)

	_start_btn = Button.new()
	_start_btn.text = "开始游戏"
	_start_btn.custom_minimum_size = Vector2(320, 64)
	_start_btn.position = Vector2((GameStats.VIEW_WIDTH - 320.0) * 0.5, 630)
	_start_btn.add_theme_font_size_override("font_size", 26)
	_start_btn.pressed.connect(_on_start)
	add_child(_start_btn)
	_start_btn.grab_focus()


func _gap(h: int) -> Control:
	var c := Control.new()
	c.custom_minimum_size = Vector2(0, h)
	return c


## 选中某个角色：更新大图 / 文案 / 属性条 / 左侧高亮。
## 未解锁角色：不改变当前选择，弹出模拟充值弹窗。
func _select(id: String) -> void:
	if not GameStats.CHARACTERS.has(id):
		return
	if not MetaSave.is_char_unlocked(id):
		_open_recharge(id)
		return
	_selected = id
	GameSession.begin_run(id)          # 记下选择，开始游戏直接进战斗

	var c := GameStats.character(id)
	var base: Dictionary = c["base"]

	_big.texture = AssetDB.char_portrait(id)
	_name_label.text = String(c["name"])
	_talent_label.text = "天赋 · %s" % String(c["talent"])
	_weapon_label.text = _weapon_line(id)
	_desc_label.text = String(c["desc"])

	# 属性条：先清空再按 STAT_BARS 重建
	for child in _stats_box.get_children():
		child.queue_free()
	for def in STAT_BARS:
		var key := String(def["key"])
		var value := float(base.get(key, 0.0))
		var ratio := clampf(value / float(def["max"]), 0.04, 1.0)
		var shown := ("%d%%" % roundi(value * 100.0)) if bool(def["pct"]) else str(roundi(value))

		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 12)
		var name_label := Label.new()
		name_label.text = String(def["name"])
		name_label.custom_minimum_size = Vector2(64, 0)
		name_label.add_theme_font_size_override("font_size", 17)
		name_label.add_theme_color_override("font_color", Color(0.78, 0.81, 0.90))
		row.add_child(name_label)

		var track := ColorRect.new()
		track.color = Color(1, 1, 1, 0.10)
		track.custom_minimum_size = Vector2(220, 10)
		track.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		row.add_child(track)
		# 条内填充（放进 track 里，按比例缩放）
		var fill := ColorRect.new()
		fill.color = Color(0.95, 0.36, 0.34) if key == "maxHp" else Color("#FFD700")
		fill.set_anchors_preset(Control.PRESET_LEFT_WIDE)
		fill.anchor_right = ratio
		fill.offset_bottom = 0
		fill.offset_top = 0
		track.add_child(fill)

		var val := Label.new()
		val.text = shown
		val.custom_minimum_size = Vector2(70, 0)
		val.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		val.add_theme_font_size_override("font_size", 17)
		val.add_theme_color_override("font_color", Color("#FFE9B0"))
		row.add_child(val)
		_stats_box.add_child(row)

	# 左侧缩略图高亮：选中的全亮，其余压暗（锁定态由 _apply_lock_styles 统一接管）
	for i in _thumbs.size():
		if MetaSave.is_char_unlocked(_thumb_ids[i]):
			_thumbs[i].modulate = Color(1, 1, 1) if _thumb_ids[i] == id else Color(0.55, 0.55, 0.62)


## 锁定态渲染：未解锁 → 半透明压暗 + 「未解锁」角标；解锁后恢复正常并摘除角标。
## 解锁状态变化的唯一重绘入口（充值成功后也调它刷新界面）。
func _apply_lock_styles() -> void:
	for i in _thumbs.size():
		var b := _thumbs[i]
		var existing := b.get_node_or_null("LockTag")
		if MetaSave.is_char_unlocked(_thumb_ids[i]):
			if existing != null:
				existing.queue_free()
				b.remove_child(existing)   # queue_free 延迟释放，立即摘除防止同帧叠两层
			b.modulate = Color(1, 1, 1) if _thumb_ids[i] == _selected else Color(0.55, 0.55, 0.62)
			continue
		if existing == null:
			# 半透明黑底条 + 文字角标（比 emoji 锁形稳：子集字体没有锁字形）
			var bg := ColorRect.new()
			bg.name = "LockTag"
			bg.color = Color(0.05, 0.06, 0.10, 0.72)
			bg.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
			bg.offset_top = -24
			bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
			var tag := Label.new()
			tag.text = "未解锁"
			tag.add_theme_font_size_override("font_size", 14)
			tag.add_theme_color_override("font_color", Color(0.92, 0.93, 0.98))
			tag.set_anchors_preset(Control.PRESET_FULL_RECT)
			tag.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			tag.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
			tag.mouse_filter = Control.MOUSE_FILTER_IGNORE
			bg.add_child(tag)
			b.add_child(bg)
		b.modulate = Color(0.45, 0.45, 0.52)


# ---------------------------------------------------------------- 模拟充值弹窗
## 点击未解锁角色 → 弹出充值提示（纯模拟：无任何真实支付，二维码仅展示用）。
func _open_recharge(id: String) -> void:
	if _pay_layer != null:
		return
	var c := GameStats.character(id)
	var cname := String(c["name"])

	_pay_layer = ColorRect.new()
	_pay_layer.color = Color(0, 0, 0, 0.66)
	_pay_layer.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_pay_layer)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	_pay_layer.add_child(center)

	var panel := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.10, 0.11, 0.16, 0.97)
	sb.border_color = Color(0.42, 0.46, 0.68)
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(10)
	sb.content_margin_left = 30.0
	sb.content_margin_right = 30.0
	sb.content_margin_top = 22.0
	sb.content_margin_bottom = 22.0
	panel.add_theme_stylebox_override("panel", sb)
	center.add_child(panel)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 10)
	panel.add_child(box)

	var title := Label.new()
	title.text = "解锁角色"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 30)
	title.add_theme_color_override("font_color", Color("#FFD700"))
	box.add_child(title)

	var who := Label.new()
	who.text = cname
	who.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	who.add_theme_font_size_override("font_size", 22)
	box.add_child(who)

	var tip := Label.new()
	tip.text = "支付 %d 元即可解锁该角色" % UNLOCK_PRICE
	tip.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	tip.add_theme_font_size_override("font_size", 19)
	tip.add_theme_color_override("font_color", Color(0.88, 0.90, 0.96))
	box.add_child(tip)

	var qr := TextureRect.new()
	qr.texture = AssetDB.ui_tex("fake_qr")
	qr.custom_minimum_size = Vector2(256, 256)
	qr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	qr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	box.add_child(qr)

	var note := Label.new()
	note.text = "（模拟支付 · 二维码仅为展示，不涉及真实收款）"
	note.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	note.add_theme_font_size_override("font_size", 14)
	note.add_theme_color_override("font_color", Color(0.62, 0.65, 0.75))
	box.add_child(note)

	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 18)
	box.add_child(row)

	var cancel := Button.new()
	cancel.text = "取消"
	cancel.custom_minimum_size = Vector2(150, 46)
	cancel.pressed.connect(_close_recharge)
	row.add_child(cancel)

	var ok := Button.new()
	ok.text = "确认支付"
	ok.custom_minimum_size = Vector2(190, 46)
	ok.pressed.connect(_confirm_recharge.bind(id))
	row.add_child(ok)
	ok.grab_focus()


## 确认支付：直接显示「充值成功」→ 解锁 → 刷新选角界面（模拟流程，无真实收款）。
func _confirm_recharge(id: String) -> void:
	if _pay_layer == null:
		return
	# 弹窗内容整体替换为成功提示
	var center := _pay_layer.get_child(0) as CenterContainer
	if center != null and center.get_child_count() > 0:
		var panel := center.get_child(0)
		for child in panel.get_children():
			panel.remove_child(child)
			child.queue_free()
		var box := VBoxContainer.new()
		box.add_theme_constant_override("separation", 8)
		panel.add_child(box)
		var ok_label := Label.new()
		ok_label.text = "充值成功"
		ok_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		ok_label.add_theme_font_size_override("font_size", 40)
		ok_label.add_theme_color_override("font_color", Color("#7CFC8A"))
		box.add_child(ok_label)
		var sub := Label.new()
		sub.text = "%s 已解锁" % String(GameStats.character(id)["name"])
		sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		sub.add_theme_font_size_override("font_size", 20)
		sub.add_theme_color_override("font_color", Color(0.88, 0.90, 0.96))
		box.add_child(sub)
	# 解锁并落盘（幂等）
	MetaSave.unlock_char(id)
	# 短暂停留让玩家看到提示，然后关弹窗 + 刷新界面 + 自动选中该角色
	get_tree().create_timer(1.1).timeout.connect(func():
		_close_recharge()
		_apply_lock_styles()
		if MetaSave.is_char_unlocked(id):
			_select(id))


func _close_recharge() -> void:
	if _pay_layer != null:
		_pay_layer.queue_free()
		_pay_layer = null


func _on_start() -> void:
	GameSession.begin_run(_selected)
	get_tree().change_scene_to_file(BATTLE_SCENE)


## Esc 返回标题。充值弹窗开着时 Esc 只关弹窗。
func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("pause"):
		if _pay_layer != null:
			_close_recharge()
			get_viewport().set_input_as_handled()
			return
		get_tree().change_scene_to_file(TITLE_SCENE)


## 武器摘要行。全部从 GameStats.WEAPON_DEFS 推导 —— 改表即生效，这里不硬编码任何武器。
func _weapon_line(id: String) -> String:
	var w: Dictionary = GameStats.weapon_for_char(id)
	var pierce := int(w["pierce"])
	# pierce 99 是「贯穿全屏」的实现值，直接显示数字会让人以为要穿 99 个
	var pierce_txt := "贯穿" if pierce >= 90 else "%d" % pierce
	var parts: Array[String] = [
		"单次 %d 发" % int(w["base_shots"]),
		"伤害 ×%.2f" % float(w["dmg_mul"]),
		"穿透 %s" % pierce_txt,
	]
	if float(w["lifesteal"]) > 0.0:
		parts.append("吸血 %d%%" % roundi(float(w["lifesteal"]) * 100.0))
	if float(w["gold_on_hit"]) > 0.0:
		parts.append("命中 %d%% 掉金币" % roundi(float(w["gold_on_hit"]) * 100.0))
	return "武器 · %s（%s）" % [String(w["name"]), " · ".join(parts)]
