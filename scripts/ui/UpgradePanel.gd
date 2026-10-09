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
## 重抽按钮（2026-10-08 旗舰批次）：升级三选一整体重摇。默认隐藏，Battle 经 set_reroll 点亮；
## 宝箱复用本面板时不点亮（那里每张都有价值，没有重抽语义）。
var _reroll: Button = null
var _reroll_left := 0
var _on_reroll: Callable = Callable()
## 「离开 / 跳过」按钮（2026-10-08 事件系统）：事件面板（祭坛 / 挑战柱）用它留出口 ——
## 不选任何卡也能走。普通升级与宝箱不点亮（show_options 重置为隐藏）。
var _skip_btn: Button = null
var _on_skip: Callable = Callable()

## 自动选择的延迟（面板自己的秒数）。与 Battle 旧的 UPGRADE_AUTO_DELAY 等价。
const AUTO_SELECT_DELAY := 0.3
## 卡片容量 = 基础张数 + 最大角色天赋加成（学习嘉豪 +1）+ 预知未来额外选项（+1，2026-09-20）。
## 旧版硬编码 3 张按钮：学习嘉豪的第 4 张卡被静默吞掉（2026-09-20 全库审查 P1）。
## show_options 本就按「有卡才显示、没卡就藏」工作，多建按钮零副作用。
const BUTTON_COUNT := GameStats.UPGRADE_OPTIONS + 2

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

	# 重抽按钮（2026-10-08 旗舰批次）：标题行右侧（标题居中文本约到 x≈900，右侧 1040 起不撞）。
	# 默认隐藏 —— 需要它的场景（普通升级）由 Battle 调 set_reroll 点亮。
	_reroll = Button.new()
	_reroll.position = Vector2(GameStats.VIEW_WIDTH - 240.0, 136.0)
	_reroll.size = Vector2(200.0, 44.0)
	_reroll.focus_mode = Control.FOCUS_NONE    # 不抢焦点：数字键/Esc 照常可用
	_reroll.add_theme_font_size_override("font_size", 20)
	_reroll.visible = false
	_reroll.pressed.connect(_on_reroll_pressed)
	_root.add_child(_reroll)

	# 「离开」按钮（2026-10-08 事件系统）：标题行左侧，与右侧重抽对称。
	# 事件面板（祭坛/挑战柱）由 Battle 调 set_skip 点亮；普通升级/宝箱保持隐藏。
	_skip_btn = Button.new()
	_skip_btn.position = Vector2(40.0, 136.0)
	_skip_btn.size = Vector2(200.0, 44.0)
	_skip_btn.focus_mode = Control.FOCUS_NONE
	_skip_btn.add_theme_font_size_override("font_size", 20)
	_skip_btn.visible = false
	_skip_btn.pressed.connect(_on_skip_pressed)
	_root.add_child(_skip_btn)

	# 卡片布局（2026-09-20 修复三连）：
	#   ① 5 张卡时旧式固定 290px 横排需要 1546px > 视口 1280 ⇒ 溢出屏幕。
	#      改为按可用宽度自适应 + 超过每行上限就换行（末行单独居中）。
	#   ② 文字溢出卡片：Label 在容器里的最小宽度会按【整段文本不换行】算
	#      （中文无空格 ⇒ 整行算一个词），autowrap 形同虚设。改为绝对定位 +
	#      【固定宽度】的 Label，autowrap 才真正生效（见卡片内部）。
	const MARGIN := 40.0
	const MIN_CARD_W := 208.0
	const MAX_CARD_W := 290.0
	var gap := 24.0
	var usable := GameStats.VIEW_WIDTH - MARGIN * 2.0
	var per_row := clampi(int((usable + gap) / (MIN_CARD_W + gap)), 1, 4)
	var bw := minf(MAX_CARD_W, (usable - gap * float(per_row - 1)) / float(per_row))
	var bh := 236.0
	var row_gap := 18.0
	# 垂直：按最大容量（BUTTON_COUNT）算总高并整体居中 —— 两行时不会被屏幕底裁掉
	# （2026-09-20 布局验证抓到：旧 top=248 配两行 ⇒ 下缘 738 > 视口 720）。
	var area_top := 214.0
	var area_bottom := GameStats.VIEW_HEIGHT - 12.0
	var max_rows := int(ceil(float(BUTTON_COUNT) / float(per_row)))
	var block_h := bh * float(max_rows) + row_gap * float(max_rows - 1)
	var top := area_top + maxf(0.0, (area_bottom - area_top - block_h) * 0.5)
	for i in BUTTON_COUNT:
		var r: int = i / per_row
		var c: int = i % per_row
		var in_row: int = mini(per_row, BUTTON_COUNT - r * per_row)
		var row_total := bw * float(in_row) + gap * float(in_row - 1)
		var start_x := (GameStats.VIEW_WIDTH - row_total) * 0.5
		var b := Button.new()
		b.position = Vector2(start_x + float(c) * (bw + gap), top + float(r) * (bh + row_gap))
		b.size = Vector2(bw, bh)
		b.clip_contents = true   # 双保险：任何超长文本都被裁在卡内，绝不糊到卡外
		b.add_theme_font_size_override("font_size", 20)
		b.pressed.connect(_on_button_pressed.bind(i))
		_root.add_child(b)
		_buttons.append(b)

		# 卡片内部：图标居中在上、文字在下（竖向排布，宽度全给文字换行用）。
		# 绝对定位 + 固定尺寸 —— 不用容器，避免容器的 min-size 计算破坏 autowrap。
		var icon := TextureRect.new()
		icon.position = Vector2((bw - 64.0) * 0.5, 14.0)
		icon.size = Vector2(64.0, 64.0)
		icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
		b.add_child(icon)
		_icons.append(icon)

		var pad := 12.0
		var label := Label.new()
		label.position = Vector2(pad, 86.0)
		label.size = Vector2(bw - pad * 2.0, 100.0)   # 固定宽度 ⇒ autowrap 真正生效
		label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		label.vertical_alignment = VERTICAL_ALIGNMENT_TOP
		label.add_theme_font_size_override("font_size", 20)
		label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		b.add_child(label)

		# 负面代价行（2026-09-20）：正面 buff 在上，负面代价独立成行、红色小字垫底。
		var cost := Label.new()
		cost.position = Vector2(pad, 192.0)
		cost.size = Vector2(bw - pad * 2.0, 36.0)
		cost.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		cost.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		cost.vertical_alignment = VERTICAL_ALIGNMENT_TOP
		cost.add_theme_font_size_override("font_size", 16)
		cost.add_theme_color_override("font_color", Color(1.0, 0.42, 0.36))
		cost.visible = false
		cost.mouse_filter = Control.MOUSE_FILTER_IGNORE
		b.add_child(cost)

		_labels.append(label)
		_cost_labels.append(cost)


## 显示选项。reason_text 说明本次为何升级。
## title_text（2026-10-08 宝箱批次）：可选标题覆盖 —— 空串 = 旧行为（"升级！选择一项强化"）。
## Boss 宝箱奖励复用本面板，但标题语义不同（不是升级）；探针的 5 参调用零影响。
func show_options(options: Array, wave_num: int, reason_text: String, on_choice: Callable,
		auto_select: bool = false, title_text: String = "") -> void:
	_options = options
	_on_choice = on_choice
	_auto = auto_select
	_auto_timer = AUTO_SELECT_DELAY
	_title.text = title_text if title_text != "" else "升级！选择一项强化"
	# 重抽按钮重置（2026-10-08 旗舰批次）：调用方若要用，随后调 set_reroll 点亮；
	# 在这里先清掉上一个场景（普通升级）的残留 —— 宝箱复用本面板时不调 set_reroll，
	# 靠这一步收口，防止「宝箱面板上挂着升级场景的重抽按钮」。
	_reroll_left = 0
	_on_reroll = Callable()
	if _reroll != null:
		_reroll.visible = false
	# 离开按钮同理（2026-10-08 事件系统）：普通升级与宝箱【必须选一张】是既定语义，
	# 只有事件面板（祭坛/挑战柱）调 set_skip 点亮出口。
	_on_skip = Callable()
	if _skip_btn != null:
		_skip_btn.visible = false
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
			# 副武器卡（2026-09-22）自带 display：它说的是「获得/升到 LvN + 参数」，
			# 不是普通卡那种「+N」格式，用通用格式化会显示成「+0」。
			var display_text: String = String(opt["display"]) if opt.has("display") \
				else GameStats.upgrade_display(opt, wave_num)
			# 武器精通卡携带进化进度（Battle._generate_options 注入，2026-09-20 用户需求）
			if opt.has("mastery_progress"):
				display_text += "　·　进化进度 %d/%d" % [
					int(opt["mastery_progress"]), GameStats.WEAPON_EVOLVE_LEVEL]
			_labels[i].text = "%d. %s\n%s" % [i + 1, opt["name"], display_text]
			var cost_label: Label = _cost_labels[i]
			if opt.has("cost"):
				var c: Dictionary = opt["cost"]
				# 代价文案（2026-10-08 事件系统复用）：数据里自带主语（「敌人生命 +8%」/
				# 「失去当前生命的 40%」），这里不再硬编码「敌人」前缀。
				cost_label.text = "代价：%s" % String(c["name"])
				cost_label.visible = true
			else:
				cost_label.visible = false
			# 图标可能没有（某项还没配图）—— 那就隐藏图标框，布局自动收回
			var tex := AssetDB.upgrade_icon(String(opt["id"]))
			if tex == null and opt.has("weapon_id"):
				# 副武器卡（2026-09-22）：走 extra_weapon_icon —— 它优先取专属 UI 图标
				# （闪电 / 冰霜 / 毒云三张程序化图标），没登记时才回落到本体贴图
				# （飞刃 / 导弹）。⚠️ 之前这里直接读 extra_weapon_tex：那三把按设计
				# 本来就没有实体贴图 ⇒ 卡面恒为空白，三张新图标等于没接上。
				tex = AssetDB.extra_weapon_icon(String(opt["weapon_id"]))
			if tex == null and opt.has("icon_item"):
				# Boss 宝箱奖励卡（2026-10-08）：奖励指向商店道具，图标从 ITEMS 表取
				# （金币袋 / 复活币 / 各种装备图，全是现成资产，零新增美术）。
				tex = AssetDB.item_icon(String(opt["icon_item"]))
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


## 点亮/刷新重抽按钮（2026-10-08 旗舰批次）。left = 剩余次数，≤0 整钮隐藏。
## on_reroll 由 Battle 提供 —— 面板只报「按钮被按了」，实际的重摇（重新生成三选一）
## 在那边执行；重摇后再调一次本函数刷新剩余次数。
func set_reroll(left: int, on_reroll: Callable) -> void:
	_reroll_left = left
	_on_reroll = on_reroll
	if _reroll == null:
		return
	_reroll.visible = left > 0
	_reroll.text = "重抽　×%d" % left


func _on_reroll_pressed() -> void:
	if _reroll_left <= 0 or not _on_reroll.is_valid():
		return
	_on_reroll.call()


## 点亮「离开」按钮（2026-10-08 事件面板）：祭坛 / 挑战柱必须有出口 ——
## 不选任何卡也能走（普通升级/宝箱不调用本函数，保持「必须选一张」语义）。
func set_skip(text: String, on_skip: Callable) -> void:
	_on_skip = on_skip
	if _skip_btn == null:
		return
	_skip_btn.text = text
	_skip_btn.visible = true


## 离开 = 面板自收尾（hide_panel 解除暂停）+ 回调（Battle 把流程状态接回战斗）。
func _on_skip_pressed() -> void:
	if not _on_skip.is_valid():
		return
	var cb := _on_skip
	hide_panel()
	cb.call()


func hide_panel() -> void:
	visible = false
	_auto = false
	get_tree().paused = false


func _on_button_pressed(index: int) -> void:
	select(index)


# ---------------------------------------------------------------- 自动选择 / 暂停期输入
var _auto := false
var _auto_timer := 0.0


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
