class_name Pickup
extends Node2D
## 掉落物：金币 / 经验。玩家进入拾取范围后自动吸取（由 Battle 处理）。
## 8 秒后自动消失（H5 PICKUP life=8）。

const KIND_GOLD := "gold"
const KIND_XP := "xp"
## 磁铁掉落（参考 C3 掉落三件套）：拾取后获得限时「全场磁吸」，无视拾取范围吸走全场掉落物。
## 图标暂用图元占位（红白马蹄形，与金币/经验圆点一眼可分）；美术图到位后在 AssetDB.DROPS 加
## "magnet" 键即可自动切换，本文件不用改。
const KIND_MAGNET := "magnet"

## 掉落物图标的显示高度（px）。[PLACEHOLDER] 未 playtest。
## 拾取半径只有 6，图标太小会看不见，所以显示得比判定范围大一些。
const DISPLAY_H := 22.0

var kind: String = KIND_GOLD
var value: int = 0
var life: float = GameStats.PICKUP_LIFE
var radius: float = GameStats.PICKUP_RADIUS

@onready var sprite: Sprite2D = $Sprite

## 是否成功用上了美术精灵。失败则回落到 _draw() 里的图元占位画法。
var _use_sprite := false
## 磁吸中：进入拾取范围后飞向玩家（由 Battle 驱动），到位才结算。
var magnetized := false
var magnet_speed := 0.0


func setup(p_kind: String, p_value: int, p_pos: Vector2) -> void:
	kind = p_kind
	value = p_value
	position = p_pos
	# 金币寿命 ×PICKUP_GOLD_LIFE_MULT（2026-09-20 用户需求：金币没捡到太亏）；其他掉落物不变
	life = GameStats.PICKUP_LIFE * (GameStats.PICKUP_GOLD_LIFE_MULT if p_kind == KIND_GOLD else 1.0)
	_setup_visuals()
	queue_redraw()


## 接上美术图标。kind 与 AssetDB.DROPS 的键同名（gold / xp / hp）。
func _setup_visuals() -> void:
	if sprite == null:
		return
	var t := AssetDB.drop(kind)
	if t == null:
		# 磁铁的图元占位是【常态】而非缺资源事故（图标还没画），不 push_warning 刷屏
		if kind != KIND_MAGNET:
			push_warning("Pickup: 类型 '%s' 的美术资源缺失，使用图元占位画法" % kind)
		return
	sprite.texture = t
	sprite.scale = AssetDB.drop_fit(DISPLAY_H)["scale"]
	_use_sprite = true


## 返回 false 表示寿命耗尽，应被回收。
func advance(delta: float) -> bool:
	life -= delta
	if life <= 0.0:
		return false
	if _use_sprite and sprite != null:
		# 临近消失时淡出（对齐 H5 的 alpha = min(1, life)）。
		# 改 modulate 不需要 queue_redraw —— 用精灵渲染时 _draw 里什么都没有，
		# 每帧重录一次绘制命令纯属浪费（几十个掉落物 = 每帧几十次无意义重绘）。
		sprite.modulate.a = clampf(life, 0.0, 1.0)
		return true
	queue_redraw()
	return true


## 只在【没接上美术精灵】时才画图元占位。
func _draw() -> void:
	if _use_sprite:
		return
	# 临近消失时淡出（对齐 H5 的 alpha = min(1, life)）。
	var alpha := clampf(life, 0.0, 1.0)
	if kind == KIND_GOLD:
		draw_circle(Vector2.ZERO, radius, Color(1, 0.84, 0.0, alpha))
		draw_arc(Vector2.ZERO, radius, 0.0, TAU, 20, Color(1, 1, 1, alpha), 1.0, true)
	elif kind == KIND_MAGNET:
		# 红白马蹄形磁铁示意：两段粗红弧 + 白色端头，与金币/经验的实心圆一眼可分
		draw_arc(Vector2.ZERO, radius * 0.85, PI * 0.25, PI * 0.75, 12,
			Color(0.9, 0.2, 0.2, alpha), radius * 0.55, true)
		draw_arc(Vector2.ZERO, radius * 0.85, PI * 1.25, PI * 1.75, 12,
			Color(0.9, 0.2, 0.2, alpha), radius * 0.55, true)
		draw_circle(Vector2.ZERO, radius * 0.35, Color(1, 1, 1, alpha))
	else:
		draw_circle(Vector2.ZERO, radius * 0.85, Color(0.0, 0.75, 1.0, alpha))
