class_name ShopPanel
extends CanvasLayer
## 波末商店：花金币买道具。
##
## 【暂停】与 UpgradePanel 相同：弹出时 Battle 暂停整棵树，
## 本节点设 PROCESS_MODE_WHEN_PAUSED，暂停时照样能点击；解除也由这里负责。
##
## 金币由 Battle 掌管：本面板只负责展示与发起购买请求（purchased 信号），
## Battle 校验余额并扣钱，然后调 refresh(gold) 让面板刷新可买状态。

## index = 商品卡下标（Battle 扣款成功后回 mark_sold(index) 锁卡）。
signal purchased(item_id: String, price: int, index: int)

const CARD_W := 250.0
const CARD_H := 340.0
const ICON := 88.0

## 自检模式自动离开的延迟（秒）
const AUTO_CLOSE_DELAY := 0.3

var _root: Control
var _gold_label: Label
var _hint: Label
var _cards: Array[Button] = []
var _card_icons: Array[TextureRect] = []
var _card_names: Array[Label] = []
var _card_descs: Array[Label] = []
var _card_prices: Array[Label] = []
var _ids: Array[String] = []
var _prices: Array[int] = []
var _sold: Array[bool] = []
var _on_close: Callable = Callable()
var _gold := 0

## 自检/观测模式：显示后自动离开商店
var _auto := false
var _auto_timer := 0.0


func _ready() -> void:
	visible = false
	process_mode = Node.PROCESS_MODE_WHEN_PAUSED
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

	_hint = _make_label(120.0, 30.0, Color(0.85, 0.87, 0.95))
	_hint.text = "商店"
	_gold_label = _make_label(165.0, 40.0, Color("#FFD700"))
	_gold_label.text = "$ 0"

	var row := HBoxContainer.new()
	row.set_anchors_preset(Control.PRESET_CENTER_TOP)
	row.offset_left = -1.0 * (CARD_W * 4.0 + 24.0 * 3.0) * 0.5
	row.offset_right = 1.0 * (CARD_W * 4.0 + 24.0 * 3.0) * 0.5
	row.offset_top = 230.0
	row.add_theme_constant_override("separation", 24)
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	_root.add_child(row)

	for i in GameStats.SHOP_SLOTS:
		var card := _make_card()
		row.add_child(card)
		_cards.append(card)

	var leave := Button.new()
	leave.text = "离开商店"
	leave.custom_minimum_size = Vector2(240, 60)
	leave.add_theme_font_size_override("font_size", 24)
	leave.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	leave.offset_top = -120.0
	leave.offset_bottom = -60.0
	leave.offset_left = -120.0
	leave.offset_right = 120.0
	leave.pressed.connect(_leave)
	_root.add_child(leave)


func _make_label(y: float, size: float, color: Color) -> Label:
	var l := Label.new()
	l.position = Vector2(0, y)
	l.size = Vector2(GameStats.VIEW_WIDTH, size + 14.0)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.add_theme_font_size_override("font_size", int(size))
	l.add_theme_color_override("font_color", color)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(l)
	return l


func _make_card() -> Button:
	var card := Button.new()
	card.custom_minimum_size = Vector2(CARD_W, CARD_H)
	card.pressed.connect(_on_card_pressed.bind(_cards.size()))

	var col := VBoxContainer.new()
	col.set_anchors_preset(Control.PRESET_FULL_RECT)
	col.offset_left = 12
	col.offset_right = -12
	col.offset_top = 14
	col.offset_bottom = -12
	col.add_theme_constant_override("separation", 8)
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	card.add_child(col)

	var icon := TextureRect.new()
	icon.custom_minimum_size = Vector2(0, ICON)
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(icon)
	_card_icons.append(icon)

	var name_label := Label.new()
	name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_label.add_theme_font_size_override("font_size", 22)
	name_label.add_theme_color_override("font_color", Color("#FFE9B0"))
	name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(name_label)
	_card_names.append(name_label)

	var desc := Label.new()
	desc.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	desc.add_theme_font_size_override("font_size", 15)
	desc.add_theme_color_override("font_color", Color(0.82, 0.84, 0.90))
	desc.size_flags_vertical = Control.SIZE_EXPAND_FILL
	desc.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(desc)
	_card_descs.append(desc)

	var price := Label.new()
	price.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	price.add_theme_font_size_override("font_size", 24)
	price.add_theme_color_override("font_color", Color("#FFD700"))
	price.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(price)
	_card_prices.append(price)
	return card


## 打开商店。会随机抽 SHOP_SLOTS 件商品。
## owned：本局已购道具（A4 前置解锁链）——默认 null = 不启用前置过滤（旧行为）。
func open(wave_num: int, gold: int, discount: float, on_close: Callable,
		auto_close: bool = false, owned: Variant = null, mastery_level: int = -1) -> void:
	_ids = GameStats.shop_roll(GameStats.SHOP_SLOTS, owned, mastery_level)
	_prices.clear()
	_sold.clear()
	for id in _ids:
		_prices.append(GameStats.shop_price(id, discount))
		_sold.append(false)
	_on_close = on_close
	_auto = auto_close
	_auto_timer = AUTO_CLOSE_DELAY
	_hint.text = "第 %d 波结束 · 买点装备再上路（%d 件商品）" % [wave_num, _ids.size()]
	refresh(gold)
	visible = true


## 刷新商品（「刷新」道具，2026-09-20 商店扩充）：整批重抽 SHOP_SLOTS 件、
## 重置售出状态与价格（沿用当前折扣与前置链）。已扣的钱不退；金币显示由调用方随后 refresh。
func reroll(discount: float, owned: Variant = null, mastery_level: int = -1) -> void:
	_ids = GameStats.shop_roll(GameStats.SHOP_SLOTS, owned, mastery_level)
	_prices.clear()
	_sold.clear()
	for id in _ids:
		_prices.append(GameStats.shop_price(id, discount))
		_sold.append(false)
	_hint.text = "已刷新 · 新上一批商品（%d 件）" % _ids.size()
	refresh(_gold)


## 刷新金币显示与每张卡的可买状态。
func refresh(gold: int) -> void:
	_gold = gold
	_gold_label.text = "$ %d" % gold
	for i in _cards.size():
		var b := _cards[i]
		if i >= _ids.size():
			b.visible = false
			continue
		b.visible = true
		var d: Dictionary = GameStats.ITEM_DEFS[_ids[i]]
		_card_icons[i].texture = AssetDB.item_icon(_ids[i])
		_card_names[i].text = String(d["name"])
		_card_descs[i].text = String(d["desc"])
		_card_prices[i].text = "已售出" if _sold[i] else "$ %d" % _prices[i]
		_card_prices[i].add_theme_color_override("font_color",
			Color(0.6, 0.62, 0.68) if _sold[i] else Color("#FFD700"))
		b.disabled = _sold[i] or _gold < _prices[i]


func close() -> void:
	visible = false
	_auto = false
	get_tree().paused = false


func _leave() -> void:
	close()
	if _on_close.is_valid():
		_on_close.call()


func _on_card_pressed(index: int) -> void:
	if index >= _ids.size() or _sold[index]:
		return
	purchased.emit(_ids[index], _prices[index], index)


## 标记某张卡已售出。由 Battle 在【扣款成功】后调用——只有真正扣到钱才锁卡，
## 「点了但钱不够被拒」的卡保持可点。锁卡同时刷新该卡为「已售出」状态。
func mark_sold(index: int) -> void:
	if index < 0 or index >= _sold.size():
		return
	_sold[index] = true
	refresh(_gold)


func _process(delta: float) -> void:
	if not visible:
		return
	if _auto:
		_auto_timer -= delta
		if _auto_timer <= 0.0:
			_auto = false
			_leave()
