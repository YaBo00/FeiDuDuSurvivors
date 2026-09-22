class_name AffixBlast
extends Node2D
## 精英「爆裂」词缀的死亡爆炸视觉（2026-09-22）。
##
## 与 DeathBurst 的分工：DeathBurst 只表达「这只怪死了」（爆花 + 小扩散环），
## 本节点必须表达「**这里有一个 90px 的伤害圈**」—— 玩家靠它学会「站圈里掉血、走开不掉血」。
## 所以外圈半径是【固定值】（= 实际判定半径），不随进度扩散；只有内圈在扩散做动感。
##
## 纯程序画法，不消耗新贴图（需求 §2.3/§5：不需要新美术）。低频事件（精英死亡），不做对象池。

## 存在时长（秒）。需求 §2.2「画个 90px 红圈 0.3s」。
const DURATION := 0.3

var t := 0.0
## 实际伤害半径（世界像素）。由调用方从词缀表读入，保证「画出来的圈 = 真正的判定圈」。
var radius := 90.0
var color := Color(1.0, 0.5, 0.3)


func fire(pos: Vector2, p_radius: float, p_color: Color) -> void:
	global_position = pos
	radius = p_radius
	color = p_color
	t = 0.0


func _process(delta: float) -> void:
	t += delta
	queue_redraw()
	if t >= DURATION:
		queue_free()


func _draw() -> void:
	var k := clampf(t / DURATION, 0.0, 1.0)
	var a := 1.0 - k
	# 判定圈：固定半径 + 半透明填充（「圈内是要吃伤害的」）
	draw_circle(Vector2.ZERO, radius * 0.94, Color(color, 0.20 * a))
	draw_arc(Vector2.ZERO, radius, 0.0, TAU, 48, Color(color, a), 3.0, true)
	# 内圈向外扩散：纯动感，不承载任何判定语义
	draw_arc(Vector2.ZERO, radius * (0.22 + 0.78 * k), 0.0, TAU, 40,
		Color(1.0, 0.88, 0.62, a * 0.85), 2.0, true)
