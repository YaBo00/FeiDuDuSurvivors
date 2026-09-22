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


## 给 root 的主题补上 Button 的三态贴图。root 已有主题就直接复用。
static func apply(root: Control) -> void:
	var theme := root.theme
	if theme == null:
		theme = UiFont.install(root, 20)
	var normal := _stylebox("ui/button_normal.png")
	var hover := _stylebox("ui/button_hover.png")
	var pressed := _stylebox("ui/button_pressed.png")
	if normal == null or hover == null or pressed == null:
		push_warning("UiTheme: 按钮三态贴图不全，退回默认按钮皮肤")
		return
	theme.set_stylebox("normal", "Button", normal)
	theme.set_stylebox("hover", "Button", hover)
	theme.set_stylebox("pressed", "Button", pressed)
	theme.set_stylebox("focus", "Button", hover)
	# disabled：用 normal 底图（而不是留白），让「已满级 / 买不起」也像一颗按钮
	theme.set_stylebox("disabled", "Button", normal)
	# 按钮底是暖棕木质 + 奶油金描边 → 文字用亮金才看得清
	theme.set_color("font_color", "Button", Color("#FFE9B0"))
	theme.set_color("font_hover_color", "Button", Color("#FFFFFF"))
	theme.set_color("font_pressed_color", "Button", Color("#F0C860"))
	theme.set_color("font_focus_color", "Button", Color("#FFE9B0"))
	theme.set_color("font_disabled_color", "Button", Color(1, 1, 1, 0.35))


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
