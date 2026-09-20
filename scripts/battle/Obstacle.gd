class_name Obstacle
extends StaticBody2D
## 竞技场里的建筑物：点缀 + 走位掩体，带【实心碰撞】。
##
## 物理层说明（见 GameStats 的「建筑物」一节）：
##   本节点在 LAYER_OBSTACLE(2)，mask = 0（静态物不需要主动检测谁）。
##   玩家与敌人的 mask 都含 2，所以都会被挡住；
##   但玩家与敌人【彼此之间】不碰撞（玩家 layer=1/mask=2，敌人 layer=0/mask=2）——
##   否则几十只怪会互相顶住堆成一堵墙，反而把玩家围死。

var rect: Rect2 = Rect2()

@onready var _shape: CollisionShape2D = $CollisionShape2D


## p_rect 为世界坐标下的矩形（左上角 + 尺寸）。
func setup(p_rect: Rect2) -> void:
	rect = p_rect
	position = p_rect.get_center()
	# 每个实例都新建一份形状资源 —— 否则会共用 .tscn 里的 SubResource，
	# 改一个的尺寸等于改全部。
	var s := RectangleShape2D.new()
	s.size = p_rect.size
	if _shape != null:
		_shape.shape = s
	queue_redraw()


## 本建筑占用的世界矩形。
func world_rect() -> Rect2:
	return rect


func _draw() -> void:
	var r := Rect2(-rect.size * 0.5, rect.size)
	# 落影：往右下偏一块深色，立刻有「立在地上」的感觉
	draw_rect(Rect2(r.position + Vector2(7.0, 9.0), r.size), Color(0, 0, 0, 0.30), true)
	# 主体
	draw_rect(r, GameStats.OBSTACLE_FILL, true)
	# 顶面受光 / 底部背光
	draw_rect(Rect2(r.position, Vector2(r.size.x, r.size.y * 0.20)), GameStats.OBSTACLE_TOP, true)
	draw_rect(Rect2(Vector2(r.position.x, r.end.y - r.size.y * 0.16),
		Vector2(r.size.x, r.size.y * 0.16)), GameStats.OBSTACLE_SIDE, true)
	# 窗户：按尺寸铺几颗暖色小亮点，看起来才像「建筑」而不是一堆箱子
	var cols := maxi(1, int(r.size.x / 48.0))
	var wrows := maxi(1, int(r.size.y * 0.52 / 38.0))
	var wsize := Vector2(13, 17)
	var gap_x := r.size.x / float(cols)
	var start_y := r.position.y + r.size.y * 0.30
	for gy in wrows:
		for gx in cols:
			var wr := Rect2(
				Vector2(r.position.x + gap_x * (float(gx) + 0.5) - wsize.x * 0.5,
					start_y + float(gy) * 36.0), wsize)
			if wr.end.y > r.end.y - r.size.y * 0.20:
				continue
			draw_rect(wr, GameStats.OBSTACLE_WINDOW, true)
	draw_rect(r, GameStats.OBSTACLE_EDGE, false, 3.0)
