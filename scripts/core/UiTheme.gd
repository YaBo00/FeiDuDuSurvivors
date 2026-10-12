class_name UiTheme
extends RefCounted
## 统一 UI 皮肤：用美术给的「按钮三态」图，给所有 Button 做九宫格贴图。
##
## 用法：界面建好节点后调一次 `UiTheme.apply(root)` 即可 —— root 下所有 Button
## （含以后新加的）自动继承，不用每个按钮单独设置。
##
## 素材缺失时静默退回 Godot 默认按钮 ——「没美术也能跑」这条性质在这里同样成立。
##
## 【2026-09-22 重做皮肤】旧贴图圆角 42px + 边框贴外沿，配 BTN_MARGIN=42 时：
##   ① 高度 < 84 的按钮上下角块重叠 → 背景只画一半（用户报「背景贴图显示不完整」）；
##   ② 圆角太大、边框太靠外 → 描边压住按钮文字（用户报「边框遮挡文字」）。
## 新皮肤（docs/review/make_button_skin.py 生成）改为【小圆角 + 8px 描边 1:1 不缩放】，
## 配 BTN_MARGIN=16 ⇒ 只要按钮高 ≥ 32 就完整渲染；边框厚度恒定 8px 且远离文字。
## 这样【一个边距覆盖全部按钮尺寸】，不再需要「小号皮肤」特例。

## 九宫格边距（对应 384×128 的新贴图：圆角 12px + 描边 8px，取 16 留 4px 余量）。
## 安全条件：按钮高/宽 ≥ 2×16 = 32（现有最小按钮 180×40，安全）。
const BTN_MARGIN := 16.0

## 面板九宫格边距（对应 256×256 panel.png：圆角 16 + 金边 5，取 24 留余量）。
## 安全条件：面板高/宽 ≥ 2×24 = 48。
const PANEL_MARGIN := 24.0

## 卡片框九宫格边距（对应 224×288 card_frame*.png：圆角 16 + 描边 8，取 20）。
const CARD_MARGIN := 20.0

## 主题色（供各界面统一引用，避免散落硬编码）。
const COLOR_GOLD := Color("#FFD700")        # 标题金
const COLOR_TEXT := Color("#FFE9B0")        # 按钮常规文字
const COLOR_TEXT_HOVER := Color("#FFFFFF")
const COLOR_TEXT_PRESSED := Color("#F0C860")
const COLOR_DIM := Color(0.80, 0.82, 0.90)  # 次要说明文字


## 给 root 的主题补上 Button 的三态贴图。root 已有主题就直接复用。
static func apply(root: Control) -> void:
	var theme := root.theme
	if theme == null:
		theme = UiFont.install(root, 20)
	_apply_buttons(theme)
	_apply_panels(theme)
	_apply_checks(theme)
	_apply_sliders(theme)


## 按钮：四态贴图 + 四态文字色。
static func _apply_buttons(theme: Theme) -> void:
	var normal := _stylebox("ui/button_normal.png")
	var hover := _stylebox("ui/button_hover.png")
	var pressed := _stylebox("ui/button_pressed.png")
	var disabled := _stylebox("ui/button_disabled.png")
	if normal == null or hover == null or pressed == null:
		push_warning("UiTheme: 按钮三态贴图不全，退回默认按钮皮肤")
		return
	theme.set_stylebox("normal", "Button", normal)
	theme.set_stylebox("hover", "Button", hover)
	theme.set_stylebox("pressed", "Button", pressed)
	theme.set_stylebox("focus", "Button", hover)
	# disabled：2026-10-12 起改用专门的灰化贴图（此前复用 normal，与常态不可区分）
	theme.set_stylebox("disabled", "Button", disabled if disabled != null else normal)
	# 按钮底是暖棕木质 + 奶油金描边 → 文字用亮金才看得清
	theme.set_color("font_color", "Button", COLOR_TEXT)
	theme.set_color("font_hover_color", "Button", COLOR_TEXT_HOVER)
	theme.set_color("font_pressed_color", "Button", COLOR_TEXT_PRESSED)
	theme.set_color("font_focus_color", "Button", COLOR_TEXT)
	theme.set_color("font_disabled_color", "Button", Color(1, 1, 1, 0.35))


## 面板：PanelContainer 统一皮肤（弹窗 / 卡片容器 / 设置面板）。
## ⚠️ 本函数是面板皮肤的【唯一收口】—— 各界面不要再自己 new StyleBoxFlat。
static func _apply_panels(theme: Theme) -> void:
	var sb := panel_stylebox()
	if sb == null:
		return
	theme.set_stylebox("panel", "PanelContainer", sb)
	theme.set_stylebox("panel", "Panel", sb)


## 面板皮肤变体 → 贴图路径。
const PANEL_SKINS := {
	"default": "ui/panel.png",
	"curse": "ui/panel_curse.png",      # 红调边框：诅咒（自虐换成长）
	"weapon": "ui/panel_weapon.png",    # 蓝调边框：武器 / 装备
}


## 面板皮肤（供 PanelContainer / Panel 使用，也供各界面直接取用）。
## variant: "default" / "curse" / "weapon" —— 语义化变体（贴图级区分，九宫格不破）。
## 贴图缺失时回退到 StyleBoxFlat（保证「没美术也能跑」）。
static func panel_stylebox(variant: String = "default") -> StyleBox:
	var rel: String = PANEL_SKINS.get(variant, PANEL_SKINS["default"])
	var sb := _stylebox(rel, PANEL_MARGIN)
	if sb != null:
		return sb
	# 回退：与旧硬编码同款（半透明深底 + 描边 + 圆角）
	var fb := StyleBoxFlat.new()
	fb.bg_color = Color(0.10, 0.11, 0.16, 0.97)
	fb.border_color = Color(0.42, 0.46, 0.68)
	fb.set_border_width_all(2)
	fb.set_corner_radius_all(10)
	fb.content_margin_left = 28.0
	fb.content_margin_right = 28.0
	fb.content_margin_top = 22.0
	fb.content_margin_bottom = 22.0
	return fb


## 给一个 PanelContainer 装上面板皮肤。
## 这是各界面统一入口 —— 不要再自己 new StyleBoxFlat。
static func apply_panel(panel: PanelContainer, variant: String = "default") -> void:
	if panel == null:
		return
	panel.add_theme_stylebox_override("panel", panel_stylebox(variant))


## 勾选框 / 勾选按钮：勾选图标走 icons 通道（不是 stylebox！）。
## ⚠️ 2026-10-12 踩坑：CheckBox 的 normal/hover stylebox 是【整块背景】，
##    把 check_on.png 设进去会被拉成长条糊住文字（实拍已复现）。正确做法：
##    - stylebox 留空（背景透明）
##    - 勾选图标用 set_icon("checked"/"unchecked"/"checked_disabled"/"unchecked_disabled")
static func _apply_checks(theme: Theme) -> void:
	var on := _tex("ui/check_on.png")
	var off := _tex("ui/check_off.png")
	if on == null or off == null:
		return
	var empty := StyleBoxEmpty.new()
	for cls in ["CheckBox", "CheckButton"]:
		# 背景全透明（让面板底色透出来）
		for st in ["normal", "hover", "pressed", "disabled", "focus"]:
			theme.set_stylebox(st, cls, empty)
		theme.set_icon("checked", cls, on)
		theme.set_icon("unchecked", cls, off)
		theme.set_icon("checked_disabled", cls, on)
		theme.set_icon("unchecked_disabled", cls, off)
		theme.set_icon("radio_checked", cls, on)
		theme.set_icon("radio_unchecked", cls, off)
		theme.set_color("font_color", cls, COLOR_TEXT)
		theme.set_color("font_hover_color", cls, COLOR_TEXT_HOVER)
		theme.set_color("font_pressed_color", cls, COLOR_TEXT_PRESSED)


## 滑块：轨道 + 把手贴图。Godot 4 的 HSlider 用 "slider"/"grabber" stylebox。
static func _apply_sliders(theme: Theme) -> void:
	var bg := _stylebox("ui/slider_bg.png", 12.0)
	var grabber := _texture_stylebox("ui/slider_grabber.png", 0.0, 0.0, 0.0, 0.0)
	if bg == null:
		return
	theme.set_stylebox("slider", "HSlider", bg)
	theme.set_stylebox("focus", "HSlider", StyleBoxEmpty.new())
	if grabber != null:
		theme.set_stylebox("grabber_area", "HSlider", StyleBoxEmpty.new())
		theme.set_stylebox("grabber_area_highlight", "HSlider", StyleBoxEmpty.new())
		theme.set_icon("grabber", "HSlider", _tex("ui/slider_grabber.png"))
		theme.set_icon("grabber_highlight", "HSlider", _tex("ui/slider_grabber.png"))


static func _tex(rel: String) -> Texture2D:
	return AssetDB.tex(rel)


static func _stylebox(rel: String, margin: float = BTN_MARGIN) -> StyleBoxTexture:
	var t := AssetDB.tex(rel)
	if t == null:
		return null
	var sb := StyleBoxTexture.new()
	sb.texture = t
	# Godot 4 里九宫格边距叫 texture_margin_*（不是 margin_*）
	sb.texture_margin_left = margin
	sb.texture_margin_right = margin
	sb.texture_margin_top = margin
	sb.texture_margin_bottom = margin
	# 内容边距：边框厚 8px，留 22/6 让文字离描边有余量、又不挤小按钮
	# （带 40px 高按钮内文字区仍有 28px，16px 字号足够）。
	sb.content_margin_left = 22
	sb.content_margin_right = 22
	sb.content_margin_top = 6
	sb.content_margin_bottom = 6
	return sb


## 纯贴图 StyleBox（不做九宫格，整图绘制；用于勾选/把手等方形小件）。
static func _texture_stylebox(rel: String, cl: float, cr: float,
		ct: float, cb: float) -> StyleBoxTexture:
	var t := AssetDB.tex(rel)
	if t == null:
		return null
	var sb := StyleBoxTexture.new()
	sb.texture = t
	sb.content_margin_left = cl
	sb.content_margin_right = cr
	sb.content_margin_top = ct
	sb.content_margin_bottom = cb
	return sb
