class_name DebugPanel
extends CanvasLayer
## 金手指调试面板（隐藏入口，2026-09-22）。
##
## 需求文档：《金手指调试面板_给代码AI_2026-09-22.md》。
##
## ------------------------------------------------------------------ 三条硬约束
## ①【入口 = 看得见的小按钮】左上角「难度 …」文字右侧一颗 73×73 的小按钮，
##    文案两行：「不要」/「点我」。
##    【2026-09-23 改版】此前是「隐形热区」（贴在难度文字上、玩家不可感知），
##    Bo 看到实机后要求改成看得见的按钮，位置/尺寸由他红框标注（见 INFO_BTN_* 常量注释）。
##    挂法不变：挂 Hud 的 _root 下（与 Battle 的倍速按钮同一种挂法）⇒ 继承中文字体，
##    且升级/商店/暂停面板的遮罩天然盖住它。手机端不做（用户已明确移动端暂缓）。
## ②【发版零残留】GameStats.DEBUG_PANEL_ENABLED = false ⇒ Battle._ready 根本不实例化本节点
##    （连热区都不会挂）。要删的东西只有 scripts/debug/ + scenes/debug/ 两个目录。
## ③【不写存档】本面板改的全部是**运行期**状态：金币 / 等级 / 血量 / 副武器 / 无敌 / 秒杀 /
##    速度 / 难度 —— 退出重开一局即回到正常。唯二会落盘的是「Meta 强化加层」与（概念上的）
##    「切难度」，两者都必须过 _confirm() 二次确认（灰字 → 红字「确认？」→ 再点才执行）。
##
## ------------------------------------------------------------------ 暂停语义
## 面板打开时 Battle 把整棵树暂停（与升级/商店面板同一套），所以本节点必须是
## PROCESS_MODE_ALWAYS（不是 WHEN_PAUSED）—— 常驻叠加层（FPS / 对象计数 / Boss 血条 / DPS）
## 在**未暂停**的战斗中也要逐帧刷新。
##
## ------------------------------------------------------------------ 常驻叠加层
## 面板本体关闭时，叠加层独立存活（它是同一个 CanvasLayer 下的另一个 Control，
## 显隐由 _panel_root 控制而不是本节点）。所以「开着 FPS 显示、关掉面板继续打」是成立的。
##
## ------------------------------------------------------------------ 与其他模块的接口
## 只走三个中立位，绝不反向依赖：
##   · GameStats.extra_weapon_cap_override —— 解除副武器持有上限
##   · GameStats.debug_force_upgrade / debug_force_item —— 强制指定卡 / 指定商品
##   · MetaSave.debug_set_level() —— Meta 加层（会写档，故必须二次确认）
## 其余全部是「直接读写 Battle / Player / ExtraWeaponSystem 的现成字段」，不改任何公式。
##
## ------------------------------------------------------------------ 留的扩展位（本次不做）
## 录制 / 回放、一键导出本局状态 JSON、敌人 AI 行为日志 —— 见文档 §四。

# ================================================================ 常量
const PANEL_W := 420.0
const PANEL_H := 600.0
## 居中偏右（视口 1280x720）。
const PANEL_X := 800.0
const PANEL_Y := 56.0

## 截图目录（文档 §E 指定到桌面工程目录下）。
const SCREENSHOT_DIR := "C:/Users/10201/Desktop/Roguelike/screenshots"

## 面板提供的速度档（比战斗内右上角的 1/1.5/2/4 多出 0.5 与 8，供极端观测）。
const SPEED_STEPS: Array[float] = [0.5, 1.0, 1.5, 2.0, 4.0, 8.0]

## 二次确认窗口（秒）：第一次点变红字，窗口内再点才执行。
const CONFIRM_WINDOW := 4.0
## DPS 统计窗口（秒）。
const DPS_WINDOW := 5.0
## 帧时间环形缓冲长度（算 1% low 用）。
const FRAME_SAMPLES := 120
## 压力测试的场上敌人上限（文档 §3.3：≥200 不再加）。
const STRESS_LIMIT := 200

# ================================================================ 入口按钮（左上角小按钮）
## 尺寸与位置**实测自 Bo 的红框截图**（截图就是 1280×720 原生分辨率，无需换算：
## 红框 = x 307..379 / y 8..80 ⇒ 73×73 的正方形）。
## 位置锚在「难度 …」Label 的左上角上（该 Label 在 Hud 里固定 (20,12)）：
##   DX 287 = 文字右边缘 288 − Label 的 x 20 + 19px 间隙
##   DY  -4 = 12 → 8（按钮顶边比文字行略高一点，与红框对齐）
## ⚠️ 按钮位置刻意【不】跟着那行文字的实际宽度走 —— 「金币」涨到 6 位数时文字会变宽
##   （每多一位 ≈ +11px，最坏能顶到 x≈300），若真顶住按钮，把 DX 调大即可。
const INFO_BTN_W := 73.0
const INFO_BTN_H := 73.0
const INFO_BTN_DX := 287.0
const INFO_BTN_DY := -4.0
## 按钮文案：上行「不要」、下行「点我」（\n 由内部 Label 换行，Button.text 是单行）。
const INFO_BTN_TEXT := "不要\n点我"

# ================================================================ 宿主
## 宿主（Battle）。刻意用强类型：本面板是「贴着 Battle 写的一次性工具」，
## 强类型换来的是全部访问点的编译期检查（发版删掉本文件即可，不需要保持松耦合）。
var battle: Battle = null

# ================================================================ 节点
## 总容器（CanvasLayer 本身没有 theme，中文字体必须装在一个 Control 上再向下继承）。
var _root_all: Control = null
## 面板本体容器（整块 show/hide 它，而不是本 CanvasLayer —— 叠加层要独立存活）。
var _panel_root: Control = null
var _panel: Panel = null
var _hint: Label = null
## 常驻叠加层
var _overlay: Control = null
var _overlay_label: Label = null
var _boss_bar_root: Control = null
var _boss_bar_fill: ColorRect = null
var _boss_bar_text: Label = null

## 左上角入口小按钮（可见，2026-09-23 由隐形热区改版而来）
var _entry_btn: Button = null

# ================================================================ 各 Tab 的控件引用
var _wave_input: LineEdit = null
var _enemy_opt: OptionButton = null
var _affix_opt: OptionButton = null
var _gold_input: LineEdit = null
var _god_check: CheckBox = null
var _oneshot_check: CheckBox = null
var _extra_opt: OptionButton = null
var _cap_check: CheckBox = null
var _upgrade_input: LineEdit = null
var _item_input: LineEdit = null
var _meta_opt: OptionButton = null
var _meta_lv_input: LineEdit = null
var _stress_input: LineEdit = null
var _diff_btn: Button = null

## 动态文本（每次叠加层节拍刷新）
var _dyn_player: Label = null
var _dyn_extra: Label = null
var _dyn_stats: Label = null

# ================================================================ 运行期状态
## 本面板自己的开关状态（权威在这里；写入 Player.god_mode / 逐帧压血）
var _god := false
var _oneshot := false
var _show_fps := false
var _show_counts := false
var _show_boss_hp := false
var _show_dps := false

## 叠加层刷新节流
var _overlay_timer := 0.0
const OVERLAY_INTERVAL := 0.1

## 提示行
var _hint_text := "点左上角的「不要／点我」按钮开/关本面板。"
var _hint_timer := 0.0

## 二次确认表 {button_instance_id: {"until": int(ms), "text": String, "cb": Callable}}
var _confirm_arm: Dictionary = {}

## 局边界跟踪（结算 / 重开 ⇒ 关掉本局开关）
var _prev_waves := 0
var _prev_kills := 0
var _prev_wave := 0

## 帧时间环形缓冲
var _frame_us: PackedFloat64Array = PackedFloat64Array()
var _frame_i := 0
var _frame_n := 0
var _last_ticks := 0

## DPS 采样状态
var _dps_events: Array = []          # [{t: float, d: int}]
var _dps_t := 0.0
var _dps_start := 0.0
var _hp_prev: Dictionary = {}        # instance_id -> hp（上一帧采样）
var _dps_wave := -1
var _dps_state := -1


# ================================================================ 生命周期
func _ready() -> void:
	# 本节点恒 visible：显隐由 _panel_root 控制（叠加层要能独立留在屏幕上）。
	visible = true
	layer = 40                                  # 高于 PauseMenu(30)，低于任何全屏弹窗之前
	process_mode = Node.PROCESS_MODE_ALWAYS     # 暂停中也要能点（见文件头「暂停语义」）
	_root_all = Control.new()
	_root_all.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root_all.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_root_all)
	# 中文字体必须装（原生控件默认字体没有中文字形 → 整屏方块）。
	# 装在最外层容器上 ⇒ 面板与叠加层一起继承（CanvasLayer 本身没有 theme 属性）。
	UiFont.install(_root_all, 14)
	_build_overlay()
	_build_panel()
	_panel_root.visible = false


## 由 Battle._build_debug_panel() 调用（动态 call，故不能靠 _ready 传参）。
func setup(b: Battle) -> void:
	battle = b
	_frame_us.resize(FRAME_SAMPLES)
	_install_entry_button()
	_sync_run_trackers()
	_reset_dps()
	print("[DEBUG-PANEL] 金手指面板已挂载（入口：左上角「不要／点我」小按钮）。开关 GameStats.DEBUG_PANEL_ENABLED")


# ================================================================ 入口按钮（可见，左上角）
## 左上角「难度 …」文字右侧的小按钮。尺寸/位置见 INFO_BTN_* 常量（实测自 Bo 的红框截图）。
## 【为什么挂 hud._root 而不是 hud 本身、也不是本 CanvasLayer】
##   ① 与 Battle 的倍速按钮同一种挂法；_root 已被 UiFont.install() 装过中文字体
##      ⇒ 按钮与内部 Label 自动拿到中文字形（挂 hud 本身会拿不到，中文变豆腐块）；
##   ② _root 在场景树里排在升级/商店/暂停面板【之前】⇒ 那些面板的遮罩天然盖住按钮，
##      玩家在那些界面里点不到它（不会出现「面板套面板」）；
##   ③ HUD 收起（hud.set_visible_hud(false)，结算/死亡时）会连按钮一起收，
##      不会在结算页留一颗孤儿按钮。
func _install_entry_button() -> void:
	if battle == null or battle.hud == null or battle.hud._root == null:
		return
	# 「难度 …」Label 在 Hud 里位置写死 (20,12)；取不到就用这个兜底值，别让按钮飘到屏幕外。
	var anchor := Vector2(20.0, 12.0)
	var label: Label = battle.hud._info_label
	if label != null:
		anchor = label.position
	var b := Button.new()
	b.name = "DebugPanelButton"
	b.text = ""                                        # Button.text 是单行，两行文案交给下面的 Label
	b.tooltip_text = ""                                # 刻意留空：不写字数说明，免得鼠标悬停就剧透
	b.focus_mode = Control.FOCUS_NONE                   # 不抢键盘焦点（Enter/Esc 都是功能键）
	b.mouse_filter = Control.MOUSE_FILTER_STOP
	b.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	b.size = Vector2(INFO_BTN_W, INFO_BTN_H)
	b.position = anchor + Vector2(INFO_BTN_DX, INFO_BTN_DY)
	_style_entry_button(b)

	var l := Label.new()
	l.text = INFO_BTN_TEXT
	l.set_anchors_preset(Control.PRESET_FULL_RECT)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE       # 点击穿透到按钮本体
	l.add_theme_font_size_override("font_size", 18)
	l.add_theme_color_override("font_color", Color("#FFE9B0"))
	l.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	l.add_theme_constant_override("outline_size", 5)
	b.add_child(l)

	b.pressed.connect(_on_entry_pressed)
	battle.hud._root.add_child(b)
	_entry_btn = b


## 手写三态皮肤：深色底 + 金描边（沿用调试面板自己的配色）。
## 刻意【不】走 UiTheme —— 它的九宫格边距是给 ≥40px 高的大按钮调的，
## 这颗 73×73 的小按钮要的是确定性外观，不依赖任何贴图资源。
func _style_entry_button(b: Button) -> void:
	b.add_theme_stylebox_override("normal", _entry_sb(Color(0.10, 0.11, 0.16, 0.82), Color(0.85, 0.72, 0.35, 0.95)))
	b.add_theme_stylebox_override("hover", _entry_sb(Color(0.17, 0.19, 0.26, 0.92), Color(1.00, 0.86, 0.45, 1.00)))
	b.add_theme_stylebox_override("pressed", _entry_sb(Color(0.06, 0.07, 0.11, 0.95), Color(0.85, 0.72, 0.35, 1.00)))
	b.add_theme_stylebox_override("focus", _entry_sb(Color(0.10, 0.11, 0.16, 0.82), Color(0.85, 0.72, 0.35, 0.95)))


func _entry_sb(bg: Color, border: Color) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.border_color = border
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(8)
	return sb


## 点入口按钮：面板开着就关，关着就开。开之前两道守卫（避免与其它暂停面板打架）：
##   ① 只在 FIGHTING 状态 —— 升级/商店/结算界面里不响应；
##   ② 树当前没被暂停 —— 暂停菜单开着时不响应（那种情况下的「暂停/恢复」归它管）；
##   （「面板已开着 → 直接关」这条放最前，关闭不受上面两条限制；此时游戏本来就是暂停的。）
func _on_entry_pressed() -> void:
	if _panel_root != null and _panel_root.visible:
		_close_panel()
		return
	if battle == null or battle.state != Battle.State.FIGHTING:
		return
	if get_tree().paused:
		return
	_open_panel()


# ================================================================ 面板骨架
func _build_overlay() -> void:
	_overlay = Control.new()
	_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_overlay)

	# 右上角文本块（倍速按钮在 y=12..50，这里从 y=56 起，不打架）
	_overlay_label = Label.new()
	_overlay_label.position = Vector2(GameStats.VIEW_WIDTH - 392.0, 56.0)
	_overlay_label.size = Vector2(378.0, 96.0)
	_overlay_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_overlay_label.add_theme_font_size_override("font_size", 14)
	_overlay_label.add_theme_color_override("font_color", Color(0.72, 0.95, 0.72))
	_overlay_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	_overlay_label.add_theme_constant_override("outline_size", 4)
	_overlay_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_overlay_label.visible = false
	_overlay.add_child(_overlay_label)

	# 屏幕上方 Boss 血条（波次行 y=12..46 + 清场条 y=48..64 之下 ⇒ 起点 72）
	_boss_bar_root = Control.new()
	_boss_bar_root.position = Vector2((GameStats.VIEW_WIDTH - 420.0) * 0.5, 72.0)
	_boss_bar_root.size = Vector2(420.0, 16.0)
	_boss_bar_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_boss_bar_root.visible = false
	_overlay.add_child(_boss_bar_root)

	var bg := ColorRect.new()
	bg.color = Color(0, 0, 0, 0.65)
	bg.position = Vector2.ZERO
	bg.size = Vector2(420.0, 16.0)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_boss_bar_root.add_child(bg)

	_boss_bar_fill = ColorRect.new()
	_boss_bar_fill.color = Color(1.0, 0.30, 0.32)
	_boss_bar_fill.position = Vector2(2.0, 2.0)
	_boss_bar_fill.size = Vector2(0.0, 12.0)
	_boss_bar_fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_boss_bar_root.add_child(_boss_bar_fill)

	_boss_bar_text = Label.new()
	_boss_bar_text.position = Vector2(0.0, -1.0)
	_boss_bar_text.size = Vector2(420.0, 18.0)
	_boss_bar_text.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_boss_bar_text.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_boss_bar_text.add_theme_font_size_override("font_size", 13)
	_boss_bar_text.add_theme_color_override("font_color", Color(1.0, 0.95, 0.95))
	_boss_bar_text.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	_boss_bar_text.add_theme_constant_override("outline_size", 4)
	_boss_bar_text.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_boss_bar_root.add_child(_boss_bar_text)


func _build_panel() -> void:
	_panel_root = Control.new()
	_panel_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	# IGNORE：面板只占 420x600 那一块，屏幕其余部分照旧（文档：不挡整个屏幕）
	_panel_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root_all.add_child(_panel_root)

	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.04, 0.05, 0.09, 0.90)
	sb.border_color = Color(0.45, 0.62, 0.85, 0.9)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(6)

	_panel = Panel.new()
	_panel.position = Vector2(PANEL_X, PANEL_Y)
	_panel.size = Vector2(PANEL_W, PANEL_H)
	_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	_panel.add_theme_stylebox_override("panel", sb)
	_panel_root.add_child(_panel)

	var col := VBoxContainer.new()
	col.set_anchors_preset(Control.PRESET_FULL_RECT)
	col.offset_left = 10.0
	col.offset_right = -10.0
	col.offset_top = 8.0
	col.offset_bottom = -8.0
	col.add_theme_constant_override("separation", 6)
	_panel.add_child(col)

	# 标题行（文档 §3.4：不做美术，纯原生控件 + 中文字体）
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 6)
	col.add_child(head)
	var title := Label.new()
	title.text = "金手指 · 调试面板"
	title.add_theme_font_size_override("font_size", 16)
	title.add_theme_color_override("font_color", Color(1.0, 0.85, 0.35))
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(title)
	var close_btn := _button(head, "✕ 关闭", _close_panel)
	close_btn.custom_minimum_size = Vector2(70.0, 26.0)

	var tabs := TabContainer.new()
	tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	tabs.add_theme_font_size_override("font_size", 14)
	col.add_child(tabs)

	_build_tab_wave(tabs)
	_build_tab_player(tabs)
	_build_tab_extra(tabs)
	_build_tab_upgrade(tabs)
	_build_tab_perf(tabs)
	_build_tab_diff(tabs)

	_hint = Label.new()
	_hint.text = _hint_text
	_hint.add_theme_font_size_override("font_size", 12)
	_hint.add_theme_color_override("font_color", Color(0.75, 0.80, 0.90))
	_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_hint.custom_minimum_size = Vector2(0.0, 34.0)
	col.add_child(_hint)


# ================================================================ Tab 骨架 / 小工具
func _tab(tabs: TabContainer, title: String) -> VBoxContainer:
	var sc := ScrollContainer.new()
	sc.name = title
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	sc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sc.size_flags_vertical = Control.SIZE_EXPAND_FILL
	tabs.add_child(sc)
	var vb := VBoxContainer.new()
	vb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vb.add_theme_constant_override("separation", 7)
	sc.add_child(vb)
	return vb


func _row(parent: Node, sep := 6) -> HBoxContainer:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", sep)
	h.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	parent.add_child(h)
	return h


func _cap(parent: Node, text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", 12)
	l.add_theme_color_override("font_color", Color(0.58, 0.70, 0.92))
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	parent.add_child(l)
	return l


func _note(parent: Node, text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", 12)
	l.add_theme_color_override("font_color", Color(0.68, 0.70, 0.78))
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	parent.add_child(l)
	return l


func _button(parent: Node, text: String, cb: Callable, min_w := 0.0) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE          # 不抢键盘焦点（WASD 仍归输入框）
	b.add_theme_font_size_override("font_size", 13)
	b.custom_minimum_size = Vector2(min_w, 26.0)
	if cb.is_valid():
		b.pressed.connect(cb)
	parent.add_child(b)
	return b


func _edit(parent: Node, text: String, w: float) -> LineEdit:
	var e := LineEdit.new()
	e.text = text
	e.add_theme_font_size_override("font_size", 13)
	e.custom_minimum_size = Vector2(w, 26.0)
	parent.add_child(e)
	return e


## 下拉框。**暂停兼容处理**：OptionButton 的弹出菜单是独立的 Window 子节点，
## 默认 process_mode = INHERIT；本面板是 ALWAYS ⇒ 弹出层继承 ALWAYS，暂停时也能点。
## 仍然显式设一次（get_popup() 会强制创建它），避免依赖继承链的实现细节。
func _option(parent: Node, pairs: Array, w := 190.0) -> OptionButton:
	var o := OptionButton.new()
	o.focus_mode = Control.FOCUS_NONE
	o.add_theme_font_size_override("font_size", 13)
	o.custom_minimum_size = Vector2(w, 26.0)
	for p in pairs:
		o.add_item(String(p["label"]))
		o.set_item_metadata(o.item_count - 1, String(p["id"]))
	o.get_popup().process_mode = Node.PROCESS_MODE_ALWAYS
	parent.add_child(o)
	return o


func _check(parent: Node, text: String, cb: Callable) -> CheckBox:
	var c := CheckBox.new()
	c.text = text
	c.focus_mode = Control.FOCUS_NONE
	c.add_theme_font_size_override("font_size", 13)
	c.toggled.connect(cb)
	parent.add_child(c)
	return c


func _meta_pairs() -> Array:
	var out: Array = []
	for u in MetaSave.META_UPGRADES:
		out.append({"id": String(u["id"]), "label": "%s（%s）" % [String(u["name"]), String(u["id"])]})
	return out


func _enemy_pairs() -> Array:
	var out: Array = []
	for id in GameStats.ENEMY_TEMPLATES.keys():
		var eid := String(id)
		var cn := GameStats.codex_name(eid)
		out.append({"id": eid, "label": eid if cn == "" else "%s %s" % [eid, cn]})
	return out


func _affix_pairs() -> Array:
	var out: Array = []
	for id in GameStats.ELITE_AFFIXES.keys():
		var aid := String(id)
		out.append({"id": aid, "label": "%s %s" % [String(GameStats.ELITE_AFFIXES[aid]["name"]), aid]})
	return out


func _extra_pairs() -> Array:
	var out: Array = []
	for id in GameStats.EXTRA_WEAPON_IDS:
		var wid := String(id)
		out.append({"id": wid, "label": "%s %s" % [
			String(GameStats.EXTRA_WEAPON_DEFS[wid]["name"]), wid]})
	return out


## 下拉当前选中的 id（无有效项返回空串）。
func _opt_id(o: OptionButton) -> String:
	if o == null or o.selected < 0 or o.selected >= o.item_count:
		return ""
	return String(o.get_item_metadata(o.selected))


## 手写 join：String.join() 的形参是 PackedStringArray，直接喂 Array[String] 有转换风险，
## 这里只做一次 O(n) 拼接，代价可忽略。
func _join(sep: String, parts: Array) -> String:
	var s := ""
	for i in parts.size():
		if i > 0:
			s += sep
		s += String(parts[i])
	return s


# ================================================================ Tab A. 关卡 / 波数
func _build_tab_wave(tabs: TabContainer) -> void:
	var vb := _tab(tabs, "关卡")

	_cap(vb, "波数控制（清场制：跳波会清掉当前敌人并立即开始投放）")
	var r1 := _row(vb)
	_wave_input = _edit(r1, "5", 70.0)
	_wave_input.text_submitted.connect(func(_s: String) -> void: _do_jump_wave())
	_button(r1, "跳到第 X 波", _do_jump_wave, 120.0)
	var r2 := _row(vb)
	_button(r2, "跳到下一波", _do_next_wave, 120.0)
	_button(r2, "强制出 Boss", _do_force_boss, 120.0)

	_cap(vb, "战场操纵")
	var r3 := _row(vb)
	_button(r3, "清屏", _do_clear_field, 100.0)
	_note(r3, "场上敌人直接释放：不掉落、不计击杀")

	var r4 := _row(vb)
	_note(r4, "出一只指定敌人（玩家身边 200px）")
	var r5 := _row(vb)
	_enemy_opt = _option(r5, _enemy_pairs(), 200.0)
	_button(r5, "生成", _do_spawn_enemy, 70.0)

	var r6 := _row(vb)
	_note(r6, "出一只指定精英（Elite 模板 + 词缀）")
	var r7 := _row(vb)
	_affix_opt = _option(r7, _affix_pairs(), 200.0)
	_button(r7, "生成精英", _do_spawn_elite, 90.0)
	_note(vb, "词缀效果：疾风加速 / 钢甲减伤 / 爆裂死亡炸圈 / 召唤死亡掉小怪 / 狂怒残血强化。")
	_note(vb, "「强制出 Boss」按当前波选型（波 10 = PUA 老板，其余 = 袋鼠王），血量走动态公式。")


# ================================================================ Tab B. 玩家资源
func _build_tab_player(tabs: TabContainer) -> void:
	var vb := _tab(tabs, "玩家")

	_cap(vb, "资源")
	var r1 := _row(vb)
	_note(r1, "加 $")
	_gold_input = _edit(r1, "100", 80.0)
	_gold_input.text_submitted.connect(func(_s: String) -> void: _do_add_gold())
	_button(r1, "执行", _do_add_gold, 60.0)
	_note(r1, "（可填负数扣钱；直接改 gold，不吃 meta 金币乘区）")

	var r2 := _row(vb)
	_button(r2, "加满一级经验", _do_level_up, 110.0)
	_button(r2, "回满血", _do_heal, 80.0)
	_button(r2, "死亡测试（打到 1 血）", _do_death_test, 150.0)

	_cap(vb, "作弊开关（仅本局有效，不落盘）")
	_god_check = _check(vb, "无敌（god mode，走位测试用）", _on_god_toggled)
	_oneshot_check = _check(vb, "秒杀（敌人压到 1 血）", _on_oneshot_toggled)
	_note(vb, "秒杀口径：逐帧把场上存活敌人压到 1 血 ⇒ 下一次命中必死（Boss 同理）。"
		+ "伤害飘字/暴击/吸血/金币镖全部照常结算，看到的数字仍是真实伤害 —— 只是没人扛得住第二下。")

	_cap(vb, "当前状态")
	_dyn_player = _note(vb, "")


# ================================================================ Tab C. 副武器
func _build_tab_extra(tabs: TabContainer) -> void:
	var vb := _tab(tabs, "副武器")

	_cap(vb, "持有 / 升级")
	_extra_opt = _option(vb, _extra_pairs())
	var r1 := _row(vb)
	_button(r1, "给一把", _do_grant_extra, 80.0)
	_button(r1, "升一级", _do_level_extra, 80.0)
	_button(r1, "拉到满级", _do_max_extra, 90.0)
	var r2 := _row(vb)
	_button(r2, "清空所有副武器", _do_reset_extra, 150.0)

	_cap(vb, "上限")
	_cap_check = _check(vb, "解除上限（可同时持有 5 把）", _on_cap_toggled)
	_note(vb, "默认上限 2 把（Stats.MAX_EXTRA_WEAPONS）。勾选后经 GameStats.extra_weapon_cap()"
		+ " 临时抬到 5 —— 出卡规则与 HUD 槽位自动跟着变，取消勾选立即回到 2（多出来的不会被收回）。")

	_cap(vb, "当前持有")
	_dyn_extra = _note(vb, "")


# ================================================================ Tab D. 升级 / 商店
func _build_tab_upgrade(tabs: TabContainer) -> void:
	var vb := _tab(tabs, "升级商店")

	_cap(vb, "升级面板")
	_button(vb, "立即触发一次三选一", _do_trigger_upgrade, 160.0)
	_note(vb, "不等升级条满，直接弹升级面板（会先关掉本面板，否则两个暂停面板叠在一起）。")

	var r1 := _row(vb)
	_note(r1, "强制升级卡 id")
	_upgrade_input = _edit(r1, "cdr", 90.0)
	_button(r1, "设定", _do_force_upgrade, 60.0)
	_note(vb, "下次三选一保证出现（一次性）。合法 id：" + _upgrade_id_list())

	var r2 := _row(vb)
	_note(r2, "强制商店道具 id")
	_item_input = _edit(r2, "s_resurrect", 110.0)
	_button(r2, "设定", _do_force_item, 60.0)
	_note(vb, "下次商店保证上架（一次性，绕过前置链与稀有度）。合法 id：" + _item_id_list())

	_cap(vb, "商店")
	_button(vb, "刷新当前商店", _do_shop_reroll, 130.0)
	_note(vb, "仅在商店界面（波末商店）里有效；刷新用的是当前折扣与前置链。"

	)

	_cap(vb, "Meta 局外强化（⚠ 会写存档）")
	var r3 := _row(vb)
	_meta_opt = _option(r3, _meta_pairs(), 190.0)
	_meta_lv_input = _edit(r3, "1", 44.0)
	var add_btn := _button(r3, "加 X 层", Callable(), 70.0)
	add_btn.pressed.connect(func() -> void: _confirm(add_btn, _do_meta_add))
	_note(vb, "层数可填负数（降级）。写入 user://meta_save.json，并立即重新注入 meta_bonus + 重算属性。")


func _upgrade_id_list() -> String:
	var ids: Array[String] = []
	for d in GameStats.UPGRADE_POOL:
		ids.append(String(d["id"]))
	return "、".join(ids)


func _item_id_list() -> String:
	var ids: Array[String] = []
	for id in GameStats.ITEM_DEFS.keys():
		ids.append(String(id))
	return "、".join(ids)


# ================================================================ Tab E. 速度 / 性能
func _build_tab_perf(tabs: TabContainer) -> void:
	var vb := _tab(tabs, "性能")

	_cap(vb, "游戏速度（Engine.time_scale，命中停帧结束会回到这里的值）")
	var r1 := _row(vb, 4)
	for i in SPEED_STEPS.size():
		var s: float = SPEED_STEPS[i]
		_button(r1, "%.1fx" % s, func() -> void: _do_speed(s), 56.0)
	var r1b := _row(vb, 4)
	_button(r1b, "回到 1.0x", func() -> void: _do_speed(1.0), 100.0)

	_cap(vb, "常驻显示（关掉面板也会留在屏幕上）")
	_check(vb, "FPS / 帧时间 / 1% low", _on_fps_toggled)
	_check(vb, "对象计数（敌 / 弹 / 飘字 / 毒池）", _on_counts_toggled)
	_check(vb, "Boss 剩余血量条（屏幕上方）", _on_bosshp_toggled)
	_check(vb, "玩家实际 DPS（5 秒窗口）", _on_dps_toggled)

	_cap(vb, "压力测试")
	var r2 := _row(vb)
	_stress_input = _edit(r2, "100", 60.0)
	_button(r2, "只生成", _do_stress, 80.0)
	_note(vb, "在玩家周围 420px 环形生成指定只数的当前波敌人（分批投放，非一次性全出）。"
		+ "场上已有 ≥200 只时直接跳过（文档 §3.3 上限保护）。")

	_cap(vb, "截图")
	_button(vb, "截图到桌面 screenshots/", _do_screenshot, 190.0)
	_note(vb, "路径：" + SCREENSHOT_DIR + "（文件名带时间戳，含本面板）。")


# ================================================================ Tab F. 难度 / 平衡
func _build_tab_diff(tabs: TabContainer) -> void:
	var vb := _tab(tabs, "难度")

	_cap(vb, "难度（⚠ 影响存档语义，需二次确认）")
	_diff_btn = _button(vb, "切换难度", Callable(), 160.0)
	_diff_btn.pressed.connect(func() -> void: _confirm(_diff_btn, _do_switch_difficulty))
	_note(vb, "切换后**立即**把场上活着的敌人按新难度重刷一遍（血量/伤害乘区写在 Enemy.setup 里，"
		+ "不重刷的话场上这批怪仍是旧难度）；重刷后它们满血。新生成的敌人自然吃新难度。")

	_cap(vb, "玩家全属性（实时）")
	_dyn_stats = _note(vb, "")

	_cap(vb, "数值口径")
	_note(vb, "hp_scale / dmg_scale 已含难度乘区；spawn_count 已含 spawn_mul。")


# ================================================================ 开 / 关
func _open_panel() -> void:
	_refresh_all()
	_panel_root.visible = true
	get_tree().paused = true
	_hint_msg("已暂停。所有修改即时生效（本面板不写存档）。")


func _close_panel() -> void:
	_panel_root.visible = false
	if get_tree() != null:
		get_tree().paused = false


func is_open() -> bool:
	return _panel_root != null and _panel_root.visible


func _refresh_all() -> void:
	if battle == null:
		return
	_god_check.set_pressed_no_signal(battle.player.god_mode)
	_god = battle.player.god_mode
	_oneshot_check.set_pressed_no_signal(_oneshot)
	_cap_check.set_pressed_no_signal(GameStats.extra_weapon_cap_override > 0)
	_diff_btn.text = _difficulty_button_text()
	_refresh_dyn()


func _difficulty_button_text() -> String:
	var other := "困难" if GameStats.difficulty_key() == "normal" else "普通"
	return "切换难度 → %s（当前 %s）" % [other, GameStats.difficulty_name()]


# ================================================================ 主循环
func _process(delta: float) -> void:
	if battle == null:
		return
	if _show_fps:
		_tick_frame_stats()
	var live: bool = battle.state == Battle.State.FIGHTING and not get_tree().paused
	if live:
		_watch_run_boundary()
		if _oneshot:
			_apply_one_shot()
		if _show_dps:
			_sample_dps(delta)
	_overlay_timer -= delta
	if _overlay_timer <= 0.0:
		_overlay_timer = OVERLAY_INTERVAL
		_refresh_overlay()
		if is_open():
			_refresh_dyn()
	_tick_confirm()
	if _hint_timer > 0.0:
		_hint_timer -= delta
		if _hint_timer <= 0.0:
			_hint.text = _hint_text


func _hint_msg(text: String) -> void:
	if _hint == null:
		return
	_hint.text = text
	_hint_timer = 6.0
	print("[DEBUG-PANEL] %s" % text)


# ================================================================ 局边界 / 开关落地点
## 局边界检测：结算 / 重开（R 键、暂停菜单重开）都表现为「本局统计回退」。
## 命中就把本局的作弊开关关掉 —— 满足「无敌 / 秒杀只在当前局有效」。
func _watch_run_boundary() -> void:
	var boundary: bool = battle.state == Battle.State.RESULT \
		or battle.waves_completed < _prev_waves \
		or battle.kills < _prev_kills \
		or battle.wave_num < _prev_wave
	_sync_run_trackers()
	if boundary:
		_reset_run_toggles()


func _sync_run_trackers() -> void:
	_prev_waves = battle.waves_completed
	_prev_kills = battle.kills
	_prev_wave = battle.wave_num


func _reset_run_toggles() -> void:
	battle.player.god_mode = false
	_god = false
	_oneshot = false
	if _god_check != null:
		_god_check.set_pressed_no_signal(false)
	if _oneshot_check != null:
		_oneshot_check.set_pressed_no_signal(false)
	_reset_dps()
	_hint_msg("检测到新一局：无敌 / 秒杀已自动关闭。")


## 秒杀落地点：逐帧把存活敌人压到 1 血。
## 为什么这么实现而不是在伤害公式里加乘区：那条路要动 CombatResolver / Projectile 的
## 核心结算（hot path + 门禁基线），而「敌人只有 1 血」在效果上与「一击必杀」等价，
## 且**飘字/暴击/吸血/掉落/击杀计数全走原链路**，没有任何分支被绕过。
func _apply_one_shot() -> void:
	for e in battle.enemies:
		if e == null or not is_instance_valid(e) or e.is_dead:
			continue
		if e.hp > 1:
			e.hp = 1
			if e.show_health_bar:
				e.queue_redraw()


func _on_god_toggled(on: bool) -> void:
	_god = on
	battle.player.god_mode = on
	_hint_msg("无敌：%s" % ("开" if on else "关"))


func _on_oneshot_toggled(on: bool) -> void:
	_oneshot = on
	_hint_msg("秒杀：%s" % ("开（敌人一律 1 血）" if on else "关"))


func _on_cap_toggled(on: bool) -> void:
	GameStats.extra_weapon_cap_override = GameStats.EXTRA_WEAPON_IDS.size() if on else -1
	_hint_msg("副武器上限：%d 把" % GameStats.extra_weapon_cap())


func _on_fps_toggled(on: bool) -> void:
	_show_fps = on
	_last_ticks = 0
	_frame_i = 0
	_frame_n = 0


func _on_counts_toggled(on: bool) -> void:
	_show_counts = on


func _on_bosshp_toggled(on: bool) -> void:
	_show_boss_hp = on


func _on_dps_toggled(on: bool) -> void:
	_show_dps = on
	if on:
		_reset_dps()


# ================================================================ A. 关卡
func _do_jump_wave() -> void:
	var n: int = _wave_input.text.to_int()
	if n <= 0:
		_hint_msg("波数要 ≥ 1。")
		return
	battle.wave_num = clampi(n, 1, 999) - 1
	battle.start_next_wave()
	_reset_dps()
	_sync_run_trackers()          # 防止「波号回退」被 _watch_run_boundary 误判成重开一局
	_hint_msg("已跳到第 %d 波并开始投放（本波计划 %d 只）。" % [
		battle.wave_num, GameStats.spawn_count(battle.wave_num)])


func _do_next_wave() -> void:
	battle.start_next_wave()
	_reset_dps()
	_sync_run_trackers()
	_hint_msg("已清场并开始第 %d 波。" % battle.wave_num)


func _do_force_boss() -> void:
	var t := GameStats.boss_type_for_wave(battle.wave_num)
	battle.wave.spawn_enemy(t, battle.wave.reserve_pos_around_player(),
		GameStats.boss_wave_hp_mul(battle.wave_num))
	_hint_msg("已强制生成 Boss：%s（波 %d 动态血量）" % [t, battle.wave_num])


func _do_clear_field() -> void:
	var n := battle.enemies.size()
	# 直接走 Battle 的释放入口：queue_free + 清空 enemies + 清空间网格。
	# 【刻意不走 cleanup_enemies】那条路会算击杀、掉金币/经验、放死亡演出 —— 调试清屏不该给奖励。
	battle._free_all_enemies()
	_reset_dps()
	_hint_msg("已清空 %d 只敌人（无掉落、不计击杀）。" % n)


func _do_spawn_enemy() -> void:
	var id := _opt_id(_enemy_opt)
	if id == "":
		return
	# enforce_spawn_dist = false：要的就是「玩家身边 200px」，而不是被挪到 375px 外的备用位。
	battle.wave.spawn_enemy(id, _point_around_player(200.0), 1.0, false)
	_hint_msg("已生成 %s（波 %d 缩放）。" % [id, battle.wave_num])


## 玩家周围 dist 像素处的落点：随机角度、避开建筑物、钳进竞技场。
## 试 12 个角度都落在楼里（几乎不可能）时退回第一个候选点 —— 宁可生歪也不卡死调试流程。
func _point_around_player(dist: float) -> Vector2:
	var p: Vector2 = battle.player.global_position
	var first := Vector2.ZERO
	var has_first := false
	for i in 12:
		var ang := randf() * TAU
		var q := _clamp_arena(p + Vector2(cos(ang), sin(ang)) * dist)
		if not has_first:
			first = q
			has_first = true
		if not battle.wave.inside_obstacle(q):
			return q
	return first


func _clamp_arena(p: Vector2) -> Vector2:
	var r: Rect2 = GameStats.arena_rect().grow(-40.0)
	return Vector2(clampf(p.x, r.position.x, r.end.x), clampf(p.y, r.position.y, r.end.y))


func _do_spawn_elite() -> void:
	var affix := _opt_id(_affix_opt)
	if affix == "":
		return
	battle.wave.spawn_enemy("Elite", _point_around_player(220.0), 1.0, false, affix)
	_hint_msg("已生成精英：%s（%s）" % [String(GameStats.elite_affix_name(affix)), affix])


# ================================================================ B. 玩家
func _do_add_gold() -> void:
	var v: int = _gold_input.text.to_int()
	if v == 0:
		_hint_msg("请输入非 0 的金币数。")
		return
	battle.player.gold = maxi(0, battle.player.gold + v)
	_hint_msg("金币 %+d → 当前 %d。" % [v, battle.player.gold])


func _do_level_up() -> void:
	var p: Player = battle.player
	var need := maxi(1, p.xp_to_next - p.xp)
	# 先关面板：gain_xp 会 emit leveled_up → Battle 把 "level" 入队 → 下一帧弹升级面板。
	# 面板开着的话这棵树一直是暂停的，升级面板永远不会被处理到。
	_close_panel()
	p.gain_xp(need)
	print("[DEBUG-PANEL] 已灌满一级经验（+%d XP）→ 升级面板应弹出" % need)


func _do_heal() -> void:
	battle.player.hp = float(battle.player.max_hp)
	_hint_msg("已回满血：%d。" % battle.player.max_hp)


func _do_death_test() -> void:
	battle.player.hp = 1.0
	_hint_msg("已把血量打到 1 —— 关掉面板后随便挨一下就死（测受伤/死亡/结算流程）。")


# ================================================================ C. 副武器
func _do_grant_extra() -> void:
	var id := _opt_id(_extra_opt)
	if id == "":
		return
	if battle.extra.grant(id):
		battle._refresh_hud_extra()
		_hint_msg("已获得副武器 %s（Lv%d）。" % [id, battle.extra.level_of(id)])
	elif battle.extra.has_weapon(id):
		_hint_msg("%s 已持有（Lv%d）—— 用「升一级」/「拉到满级」。" % [
			id, battle.extra.level_of(id)])
	else:
		_hint_msg("持有数已到上限 %d/%d —— 勾选「解除上限」再给。" % [
			battle.extra.owned_count(), GameStats.extra_weapon_cap()])


func _do_level_extra() -> void:
	var id := _opt_id(_extra_opt)
	if id == "":
		return
	if battle.extra.level_up(id):
		battle._refresh_hud_extra()
		_hint_msg("%s → Lv%d。" % [id, battle.extra.level_of(id)])
	else:
		_hint_msg("%s 未持有或已满级（Lv%d/%d）。" % [
			id, battle.extra.level_of(id), GameStats.extra_weapon_max_level(id)])


func _do_max_extra() -> void:
	var id := _opt_id(_extra_opt)
	if id == "":
		return
	if not battle.extra.has_weapon(id):
		battle.extra.grant(id)
	var guard := 0
	while battle.extra.level_up(id) and guard < 20:
		guard += 1
	battle._refresh_hud_extra()
	_hint_msg("%s → Lv%d（已拉满）。" % [id, battle.extra.level_of(id)])


func _do_reset_extra() -> void:
	battle.extra.reset()          # 顺带清掉场上的刀 / 毒池 / 导弹 FX
	battle._refresh_hud_extra()
	_hint_msg("已清空全部副武器与场上特效。")


# ================================================================ D. 升级 / 商店
func _do_trigger_upgrade() -> void:
	_close_panel()
	battle._open_upgrade("level")
	print("[DEBUG-PANEL] 已强制触发一次等级三选一")


func _do_force_upgrade() -> void:
	var id := _upgrade_input.text.strip_edges()
	if id == "":
		return
	var ok := false
	for d in GameStats.UPGRADE_POOL:
		if String(d["id"]) == id:
			ok = true
			break
	if not ok:
		_hint_msg("未知升级 id：%s（下拉列表见本页提示）" % id)
		return
	GameStats.debug_force_upgrade = id
	_hint_msg("已设定：下次三选一必定出现「%s」（一次性）。" % id)


func _do_force_item() -> void:
	var id := _item_input.text.strip_edges()
	if id == "":
		return
	if not GameStats.ITEM_DEFS.has(id):
		_hint_msg("未知道具 id：%s" % id)
		return
	GameStats.debug_force_item = id
	_hint_msg("已设定：下次商店必定上架「%s」（一次性）。" % id)


func _do_shop_reroll() -> void:
	if battle.state != Battle.State.SHOP:
		_hint_msg("当前不在商店界面（波末才会开商店）。")
		return
	battle.shop_panel.reroll(battle._shop_discount_now(), battle.items_owned,
		battle.player.weapon_level)
	battle.shop_panel.refresh(battle.player.gold)
	_hint_msg("已刷新商店商品。")


func _do_meta_add() -> void:
	var id := _opt_id(_meta_opt)
	if id == "":
		return
	var delta: int = _meta_lv_input.text.to_int()
	if delta == 0:
		_hint_msg("层数填 0 = 不做事（可填负数降级）。")
		return
	var u: Variant = MetaSave.find_upgrade(id)
	if u == null:
		_hint_msg("未知 Meta 强化 id：%s" % id)
		return
	var cur := MetaSave.meta_level(id)
	var maxlv := int(u["max_level"])
	var nxt := clampi(cur + delta, 0, maxlv)
	if not MetaSave.debug_set_level(id, nxt):
		_hint_msg("写入失败：%s" % id)
		return
	# 立即生效：重新注入局外加成并重算（Battle.start_run 里那条注入的同一个出口）
	battle.player.meta_bonus_dict = MetaSave.meta_bonus()
	battle.player.recalc_stats()
	_hint_msg("%s：Lv%d → Lv%d（已写档 + 已重算属性）。" % [id, cur, nxt])


# ================================================================ E. 速度 / 性能
## 改速度：同时更新 Battle.speed_mul（它的权威值 —— 命中停帧结束时按它恢复时标）
## 与 Engine.time_scale。只写 Engine.time_scale 的话，一次暴击就会把 8x 打回战斗倍速。
func _do_speed(s: float) -> void:
	battle.speed_mul = s
	if not battle._testing() and not battle._hitstop:
		Engine.time_scale = s
	battle._update_speed_button()
	_hint_msg("速度 %.1fx（8x/0.5x 是调试档：8x 下单步位移变大，命中判定会偏保守）。" % s)


func _do_stress() -> void:
	var want: int = _stress_input.text.to_int()
	want = clampi(want, 1, 400)
	if battle.enemies.size() >= STRESS_LIMIT:
		_hint_msg("场上已有 %d 只（≥%d），压力测试跳过。" % [battle.enemies.size(), STRESS_LIMIT])
		return
	var types: Array = GameStats.spawn_types(battle.wave_num)
	var t := "Slime"
	if not types.is_empty():
		t = String(types[0])
	var center: Vector2 = battle.player.global_position
	var placed := 0
	for i in want:
		if battle.enemies.size() >= STRESS_LIMIT:
			break
		# 环形投放（半径 420：横向出视野、纵向仍在屏内边缘 —— 一进场就是满屏压力）
		var ang := TAU * float(i) / float(want)
		var q: Vector2 = _clamp_arena(center + Vector2(cos(ang), sin(ang)) * 420.0)
		battle.wave.spawn_enemy(t, q, 1.0, false)
		placed += 1
	_hint_msg("已生成 %d 只 %s（场上共 %d）。" % [placed, t, battle.enemies.size()])


func _do_screenshot() -> void:
	var img := get_viewport().get_texture().get_image()
	if img == null:
		_hint_msg("截图失败：拿不到视口图像（headless / 帧未画出）。")
		return
	DirAccess.make_dir_recursive_absolute(SCREENSHOT_DIR)
	var stamp := Time.get_datetime_string_from_system().replace(":", "-").replace("T", "_")
	var path := "%s/shot_%s.png" % [SCREENSHOT_DIR, stamp]
	var err := img.save_png(path)
	if err == OK:
		_hint_msg("截图已保存：%s" % path)
		return
	# 兜底：某些平台/打包形态下不允许写工程目录外的绝对路径 —— 退到 user:// 也要给玩家一张图。
	var alt := "user://shot_%s.png" % stamp
	var err2 := img.save_png(alt)
	if err2 == OK:
		_hint_msg("桌面目录不可写（错误码 %d），已改存：%s（=%s）" % [
			err, alt, ProjectSettings.globalize_path(alt)])
	else:
		_hint_msg("截图保存失败（%d / %d）：%s" % [err, err2, path])


# ================================================================ F. 难度
func _do_switch_difficulty() -> void:
	var nxt := "hard" if GameStats.difficulty_key() == "normal" else "normal"
	GameSession.difficulty = nxt
	# 立即重算：血量/伤害乘区是在 Enemy.setup 里一次算完的（不读全局难度），
	# 所以场上这批怪必须重刷才会吃到新乘区。affix 与"敌人代价"乘区原样带回去。
	var n := 0
	for e in battle.enemies:
		if e == null or not is_instance_valid(e) or e.is_dead:
			continue
		e.setup(String(e.type_name), battle.wave_num, e.global_position,
			battle.enemy_cost_hp_mult(), battle.enemy_cost_dmg_mult(), String(e.affix))
		n += 1
	_diff_btn.text = _difficulty_button_text()
	_hint_msg("难度 → %s；已按新难度重刷 %d 只场上敌人（满血）。" % [
		GameStats.difficulty_name(), n])


# ================================================================ 二次确认
## 影响存档 / 全局数值的操作：第一次点变红字，CONFIRM_WINDOW 秒内再点才执行。
## 用「同一个按钮点两次」而不是弹窗 —— 不引入新的 Window 节点，暂停态下零兼容问题。
func _confirm(b: Button, cb: Callable) -> void:
	var id := b.get_instance_id()
	var now := Time.get_ticks_msec()
	var armed: Variant = _confirm_arm.get(id)
	if armed != null and now < int(armed["until"]):
		_confirm_arm.erase(id)
		b.text = String(armed["text"])
		b.add_theme_color_override("font_color", Color(1, 1, 1))
		cb.call()
		return
	_confirm_arm[id] = {"until": now + int(CONFIRM_WINDOW * 1000.0), "text": b.text, "cb": cb}
	b.text = "⚠ 确认？再点一次"
	b.add_theme_color_override("font_color", Color(1.0, 0.45, 0.40))
	_hint_msg("「%s」会改写运行期/存档数值 —— %d 秒内再点一次确认。" % [
		String(_confirm_arm[id]["text"]), int(CONFIRM_WINDOW)])


func _tick_confirm() -> void:
	if _confirm_arm.is_empty():
		return
	var now := Time.get_ticks_msec()
	var done: Array = []
	for id in _confirm_arm.keys():
		var rec: Dictionary = _confirm_arm[id]
		if now < int(rec["until"]):
			continue
		done.append(id)
		for child in _all_buttons(_panel_root):
			if child.get_instance_id() == int(id):
				child.text = String(rec["text"])
				child.add_theme_color_override("font_color", Color(1, 1, 1))
				break
	for id in done:
		_confirm_arm.erase(id)


func _all_buttons(root: Node) -> Array[Button]:
	var out: Array[Button] = []
	if root == null:
		return out
	for c in root.get_children():
		if c is Button:
			out.append(c)
		out.append_array(_all_buttons(c))
	return out


# ================================================================ 叠加层
func _tick_frame_stats() -> void:
	var now := Time.get_ticks_usec()
	if _last_ticks <= 0:
		_last_ticks = now
		return
	var dt := float(now - _last_ticks)
	_last_ticks = now
	if dt <= 0.0 or dt > 1000000.0:
		return
	_frame_us[_frame_i] = dt
	_frame_i = (_frame_i + 1) % FRAME_SAMPLES
	_frame_n = mini(_frame_n + 1, FRAME_SAMPLES)


## 1% low（毫秒）：最近 FRAME_SAMPLES 帧里第 99 百分位的最差帧时间。
## 升序排序后取 ceil(n*0.99)-1 号 —— n=120 时即「第 2 差的一帧」。
func _low1_ms() -> float:
	if _frame_n < 8:
		return 0.0
	var arr := _frame_us.slice(0, _frame_n)
	arr.sort()
	var idx := clampi(int(ceil(float(_frame_n) * 0.99)) - 1, 0, _frame_n - 1)
	return arr[idx] / 1000.0


func _refresh_overlay() -> void:
	if battle == null:
		return
	var lines: Array[String] = []
	if _show_fps:
		var cur_ms := 1000.0 / maxf(1.0, float(Engine.get_frames_per_second()))
		lines.append("FPS %d   1%%low %.0f   帧 %.1fms (最差 %.1f)" % [
			Engine.get_frames_per_second(), 1000.0 / maxf(0.001, _low1_ms()),
			cur_ms, _low1_ms()])
	if _show_counts:
		lines.append("敌 %d   弹 %d   飘字 %d   毒池 %d   导弹 %d   爆裂 %d" % [
			battle.enemies.size(), battle.projectiles.size(), _float_count(),
			battle.extra._pools.size(), battle.extra._missiles.size(), _burst_count()])
	if _show_dps:
		lines.append("DPS≈ %.0f   本波清场 %d%%" % [
			_dps_value(), roundi(battle.wave.wave_clear_ratio() * 100.0)])
	_overlay_label.text = _join("\n", lines)
	_overlay_label.visible = lines.size() > 0
	_update_boss_bar()


func _float_count() -> int:
	var n := 0
	if battle.feedback != null:
		for t in battle.feedback._float_life:
			if float(t) > 0.0:
				n += 1
	return n


func _burst_count() -> int:
	var n := 0
	if battle.feedback != null:
		for b in battle.feedback._bursts:
			if is_instance_valid(b):
				n += 1
	return n


func _update_boss_bar() -> void:
	if not _show_boss_hp:
		_boss_bar_root.visible = false
		return
	var boss: Enemy = null
	for e in battle.enemies:
		if e != null and is_instance_valid(e) and not e.is_dead and e.behavior == "boss":
			boss = e
			break
	if boss == null:
		_boss_bar_root.visible = false
		return
	var ratio := clampf(float(boss.hp) / maxf(1.0, float(boss.max_hp)), 0.0, 1.0)
	_boss_bar_root.visible = true
	_boss_bar_fill.size = Vector2(416.0 * ratio, 12.0)
	_boss_bar_text.text = "BOSS %s   %d / %d" % [
		String(boss.type_name), maxi(0, boss.hp), boss.max_hp]


# ================================================================ DPS 采样
## 口径（刻意做成"零侵入"，不碰任何核心脚本）：
##   本帧伤害 = Σ(上一帧 hp − 本帧 hp)（只取正值）
##            + Σ(本帧消失的敌人：上一帧 hp)
## 前者对存活目标逐帧精确；后者把「击杀那一击」按上一帧剩余血量计 ——
##   ⇒ 不吃溢出伤害，所以是**下界**（连续射击时误差只发生在每个击杀点上）。
##   ⇒ 自爆的班味炸弹、被系统清场/换波带走的怪会形成噪声，用「换波 / 状态切换 / 面板清屏」
##      三种边界整窗清零规避（那三种情况下的"消失"不是玩家打死的）。
## 副作用（刻意保留）：DPS 覆盖主角武器 + 副武器 + 溅射，因为都对同一份敌人血量生效。
func _sample_dps(delta: float) -> void:
	if battle.wave_num != _dps_wave or battle.state != _dps_state:
		_dps_wave = battle.wave_num
		_dps_state = battle.state
		_reset_dps()
	var now: Dictionary = {}
	var dmg := 0
	for e in battle.enemies:
		if e == null or not is_instance_valid(e):
			continue
		var id := e.get_instance_id()
		now[id] = e.hp
		var prev: Variant = _hp_prev.get(id)
		if prev != null:
			var d: int = int(prev) - int(e.hp)
			if d > 0:
				dmg += d
	for id in _hp_prev.keys():
		if now.has(id):
			continue
		var rest: int = int(_hp_prev[id])
		if rest > 0:
			dmg += rest
	_hp_prev = now
	_dps_t += delta
	if dmg > 0:
		_dps_events.append({"t": _dps_t, "d": dmg})
	while not _dps_events.is_empty() and _dps_t - float(_dps_events[0]["t"]) > DPS_WINDOW:
		_dps_events.pop_front()


func _dps_value() -> float:
	var span := minf(DPS_WINDOW, maxf(0.5, _dps_t - _dps_start))
	var sum := 0
	for ev in _dps_events:
		sum += int(ev["d"])
	return float(sum) / span


func _reset_dps() -> void:
	_dps_events.clear()
	_hp_prev.clear()
	_dps_t = 0.0
	_dps_start = 0.0


# ================================================================ 动态文本
func _refresh_dyn() -> void:
	if battle == null:
		return
	var p: Player = battle.player
	if _dyn_player != null:
		_dyn_player.text = ("生命 %.0f / %d    护盾 %.0f / %.0f（%d 层）\n"
			+ "金币 %d    等级 %d    经验 %d / %d\n"
			+ "复活币 %d    商店券 %d    无敌 %s    秒杀 %s") % [
			p.hp, p.max_hp, p.shield, p.shield_cap, p.shield_charges_max,
			p.gold, p.level, p.xp, p.xp_to_next,
			p.resurrect_charges, p.shop_coupon,
			"开" if p.god_mode else "关", "开" if _oneshot else "关"]
	if _dyn_extra != null:
		var ids: Array[String] = battle.extra.owned_ids()
		if ids.is_empty():
			_dyn_extra.text = "（尚未持有任何副武器）上限 %d 把" % GameStats.extra_weapon_cap()
		else:
			var parts: Array[String] = []
			for id in ids:
				parts.append("%s Lv%d/%d" % [
					id, battle.extra.level_of(id), GameStats.extra_weapon_max_level(id)])
			_dyn_extra.text = "持有 %d/%d：%s" % [
				ids.size(), GameStats.extra_weapon_cap(), "　".join(parts)]
	if _dyn_stats != null:
		_dyn_stats.text = _player_stats_text()


## 玩家全属性一行行铺开（文档 §F「显示玩家当前全属性」）。
## 用逐行拼装而不是一个大 % 元组：中文字段多，元组错位是这类代码最常见的低级 bug。
func _player_stats_text() -> String:
	var p: Player = battle.player
	var lines: Array[String] = []
	lines.append("攻击 %d    护甲 %d    移速 %.0f    攻速 %.2f/s" % [p.atk, p.defense, p.spd, p.aspd])
	lines.append("弹道 %d    射程 %.0f    出手间隔 %.3fs" % [p.proj, p.attack_range, p.attack_interval])
	lines.append("暴击 %.0f%%    暴伤 %.0f%%    闪避 %.0f%%" % [
		p.crit * 100.0, p.critd * 100.0, p.dodge * 100.0])
	lines.append("吸血 %.0f%%    回血 %.1f/s    cdr %.0f%%    反甲 %.0f%%" % [
		p.lifesteal * 100.0, p.hp_regen, p.cdr * 100.0, p.thorns * 100.0])
	lines.append("拾取 %.0f    弹速 ×%.2f    金币击杀 +%d" % [
		p.pickup_range, p.proj_speed_mul, p.gold_per_kill])
	lines.append("武器精通 %d/%d    已进化 %s" % [
		p.weapon_level, GameStats.WEAPON_EVOLVE_LEVEL, "是" if p.weapon_evolved else "否"])
	lines.append("——— 本波（第 %d 波）———" % battle.wave_num)
	lines.append("敌人血量 ×%.2f    伤害 ×%.2f    计划刷怪 %d 只" % [
		GameStats.hp_scale(battle.wave_num), GameStats.dmg_scale(battle.wave_num),
		GameStats.spawn_count(battle.wave_num)])
	lines.append("敌人代价：血 ×%.2f    伤 ×%.2f" % [
		battle.enemy_cost_hp_mult(), battle.enemy_cost_dmg_mult()])
	lines.append("难度 %s（hp ×%.2f / dmg ×%.2f / spawn ×%.2f）" % [
		GameStats.difficulty_name(), GameStats.difficulty_def()["hp_mul"],
		GameStats.difficulty_def()["dmg_mul"], GameStats.difficulty_def()["spawn_mul"]])
	return _join("\n", lines)
