class_name UiFont
extends RefCounted
## 中文字体助手（单一数据源）。
##
## Godot 内置默认字体不含 CJK 字形，不装字体中文会渲染成「豆腐块」。
## 优先使用项目自带字体（res://assets/fonts/main_font.ttf），没有则回落到系统字体。

const CJK_FONT_NAMES := [
	"Microsoft YaHei", "微软雅黑", "SimHei", "Noto Sans CJK SC",
	"Source Han Sans SC", "PingFang SC", "sans-serif",
]

const BUNDLED_FONT := "res://assets/fonts/main_font.ttf"


## 构造一个带中文字体的 Theme；base_size 为默认字号。
static func make_theme(base_size: int = 20) -> Theme:
	var font: Font = null
	if ResourceLoader.exists(BUNDLED_FONT):
		font = load(BUNDLED_FONT) as Font
	if font == null:
		var sys := SystemFont.new()
		sys.font_names = PackedStringArray(CJK_FONT_NAMES)
		font = sys
	var theme := Theme.new()
	theme.default_font = font
	theme.default_font_size = base_size
	return theme


## 给任意 Control（含其全部子节点）装中文字体。
static func install(control: Control, base_size: int = 20) -> Theme:
	var theme := make_theme(base_size)
	control.theme = theme
	var font := theme.default_font
	if font != null and not font.has_char("肥".unicode_at(0)):
		printerr("[WARN] 当前字体不含中文字形，UI 中文可能显示为方块。请把字体放到 %s" % BUNDLED_FONT)
	return theme
