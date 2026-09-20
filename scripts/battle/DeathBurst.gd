class_name DeathBurst
extends Node2D
## 击杀爆裂特效：美术爆花序列帧（4 帧 sheet）+ 扩散环；暴击（big）时叠加星芒。
## 由 Battle 维护对象池。贴图缺失时回落纯程序画法（圆点飞散）——没美术也能跑。

const DOTS := 8
const DURATION := 0.22
## sheet 帧序（AssetDB.FX.hit_burst）：起始 → 扩散环 → 碎屑最大 → 余烟
const SHEET_FRAMES := 4
## 星芒只在 big 时叠画，且在前 70% 时长内出现（尾段交给爆花余烟）
const STAR_PORTION := 0.7

var t := 0.0
var color := Color(1, 1, 1)
var big := false
var active := false
var _burst_tex: Texture2D = null
var _star_tex: Texture2D = null


func fire(pos: Vector2, p_color: Color, p_big: bool) -> void:
	global_position = pos
	color = p_color
	big = p_big
	t = 0.0
	active = true
	visible = true
	# 贴图在 fire 时惰性取一次（首次 fire 后常驻，pool 对象复用不再查表）
	if _burst_tex == null:
		_burst_tex = AssetDB.fx_tex("hit_burst")
	if _star_tex == null:
		_star_tex = AssetDB.fx_tex("crit_star")
	set_process(true)


func _process(delta: float) -> void:
	if not active:
		return
	t += delta
	queue_redraw()
	if t >= DURATION:
		active = false
		visible = false
		set_process(false)


func _draw() -> void:
	var k := clampf(t / DURATION, 0.0, 1.0)
	var a := 1.0 - k
	var scale := 1.5 if big else 1.0
	var rad := (10.0 + 40.0 * k) * scale
	if _burst_tex != null:
		# 美术爆花：按进度取 sheet 帧，画面尺寸随扩散环走（保持与碰撞反馈一致的读感）
		var frame := clampi(int(t / DURATION * float(SHEET_FRAMES)), 0, SHEET_FRAMES - 1)
		var fw := float(AssetDB.FX["hit_burst"]["fw"])
		var fh := float(AssetDB.FX["hit_burst"]["fh"])
		var side := rad * 2.6
		draw_texture_rect_region(_burst_tex,
			Rect2(-side * 0.5, -side * 0.5, side, side),
			Rect2(float(frame) * fw, 0.0, fw, fh),
			Color(1, 1, 1, a))
	else:
		# 回落：圆点飞散
		for i in DOTS:
			var ang := TAU * float(i) / float(DOTS) + k * 1.4
			var p := Vector2(cos(ang), sin(ang)) * rad
			draw_circle(p, 3.2 * (1.0 - k * 0.55) * scale, Color(color, a))
	# 扩散环两种画法都保留（引导"命中范围"的读感）
	draw_arc(Vector2.ZERO, rad * 0.5, 0.0, TAU, 24, Color(color, a * 0.65), 2.0 * scale, true)
	# 暴击星芒：叠画 + 轻微放大淡出
	if big and _star_tex != null and k < STAR_PORTION:
		var sk := k / STAR_PORTION
		var ssize := 70.0 * (1.0 + 0.9 * sk)
		draw_texture_rect_region(_star_tex,
			Rect2(-ssize * 0.5, -ssize * 0.5, ssize, ssize),
			Rect2(0.0, 0.0, 96.0, 96.0),
			Color(1, 1, 1, 1.0 - sk))
