class_name EvoNova
extends Node2D
## 武器进化达成的新星环特效（2026-09-20 美术回投）。
## 4 帧金色光环 sheet（AssetDB.FX.evo_nova）随进度扩散淡出，播完自毁。
## 贴图缺失回落程序扩散环画法 —— 没美术也能跑。进化是低频事件，不做对象池。

const DURATION := 0.55
const SHEET_FRAMES := 4
## 起始/结束的画面边长（世界像素）。进化播报另有金字+震屏，光环只做「以玩家为中心扩散」。
const START_PX := 40.0
const END_PX := 150.0

var t := 0.0
var _tex: Texture2D = null


func _ready() -> void:
	_tex = AssetDB.fx_tex("evo_nova")


func _process(delta: float) -> void:
	t += delta
	queue_redraw()
	if t >= DURATION:
		queue_free()


func _draw() -> void:
	var k := clampf(t / DURATION, 0.0, 1.0)
	var a := 1.0 - k * k
	var side := START_PX + (END_PX - START_PX) * k
	if _tex != null:
		var frame := clampi(int(k * float(SHEET_FRAMES)), 0, SHEET_FRAMES - 1)
		var fw := float(AssetDB.FX["evo_nova"]["fw"])
		var fh := float(AssetDB.FX["evo_nova"]["fh"])
		draw_texture_rect_region(_tex,
			Rect2(-side * 0.5, -side * 0.5, side, side),
			Rect2(float(frame) * fw, 0.0, fw, fh),
			Color(1, 1, 1, a))
	else:
		# 回落：程序双环扩散
		draw_arc(Vector2.ZERO, side * 0.5, 0.0, TAU, 40,
			Color(1.0, 0.84, 0.2, a), 4.0, true)
		draw_arc(Vector2.ZERO, side * 0.32, 0.0, TAU, 32,
			Color(1.0, 0.95, 0.6, a * 0.8), 2.5, true)
