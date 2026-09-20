class_name UiTheme
extends RefCounted
## 统一 UI 皮肤：用美术给的「按钮三态」图，给所有 Button 做九宫格贴图。
##
## 用法：界面建好节点后调一次 `UiTheme.apply(root)` 即可 —— root 下所有 Button
## （含以后新加的）自动继承，不用每个按钮单独设置。
##
## 素材缺失时静默退回 Godot 默认按钮 ——「没美术也能跑」这条性质在这里同样成立。

## 九宫格边距（对应 384x128 的原图；圆角大致占高的 1/3）
const BTN_MARGIN := 42.0


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
	# 按钮底是深棕木质 + 金描边 → 文字用亮金才看得清
	theme.set_color("font_color", "Button", Color("#FFE9B0"))
	theme.set_color("font_hover_color", "Button", Color("#FFFFFF"))
	theme.set_color("font_pressed_color", "Button", Color("#F0C860"))
	theme.set_color("font_focus_color", "Button", Color("#FFE9B0"))
	theme.set_color("font_disabled_color", "Button", Color(1, 1, 1, 0.35))


static func _stylebox(rel: String) -> StyleBoxTexture:
	var t := AssetDB.tex(rel)
	if t == null:
		return null
	var sb := StyleBoxTexture.new()
	sb.texture = t
	# Godot 4 里九宫格边距叫 texture_margin_*（不是 margin_*）
	sb.texture_margin_left = BTN_MARGIN
	sb.texture_margin_right = BTN_MARGIN
	sb.texture_margin_top = BTN_MARGIN
	sb.texture_margin_bottom = BTN_MARGIN
	# 内容边距：让按钮里的文字/图标离边远一点
	sb.content_margin_left = 26
	sb.content_margin_right = 26
	sb.content_margin_top = 10
	sb.content_margin_bottom = 10
	return sb
