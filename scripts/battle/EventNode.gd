class_name BattleEvent
extends Node2D
## 局内事件实体（2026-10-08 第二梯队批次）：献祭祭坛 / 黑市商人 / 限时挑战柱。
##
## 语义：玩家走进 EVENT_TRIGGER_DIST 即触发 —— 判定与分派都住在 Battle
## （本节点不持任何战斗状态，只有 kind / armed / 淡出计时这三个纯表现字段）。
## 「离开」面板后实体保留：Battle 把 armed 置 false，玩家走开 TRIGGER×REARM 之外后
## 重新武装（back-and-forth 不会连续弹面板）。
## 用掉（完成交易 / 开完店 / 开始挑战）⇒ Battle 调 consume() → 淡出自毁。
##
## 视觉 = 图元占位（事件美术未入库）；配色走 GameStats.EVENT_DEFS[kind].color。
## 三种形状刻意差异极大（石台火盆 / 紫篷摊位 / 金柱光球）—— 不给文字也能一眼区分。

## 实体显示高度（px，[PLACEHOLDER] 未 playtest）：按【纹理高度】缩放、底边对齐节点原点。
## 与图元占位同量级（石台高 ~54 / 光晕半径 44~50），72 在竞技场里大小适中。
const DISPLAY_H := 72.0

var kind := "altar"
## 是否可触发（Battle 侧维护：触发时置 false、玩家走远后置 true）。
var armed := true
## 累计运行时间（呼吸动画相位）。
var _t := 0.0
## 淡出进度：1 = 正常；consume() 后向 0 衰减，归零即释放。
var _fade := 1.0
var _consumed := false
## 实体贴图精灵（2026-10-09 美术入库）：有图时实体走 Sprite2D、_draw 只保留呼吸光晕；
## 缺图 → 不建子节点，整节点回落图元占位画法（与旧版逐像素一致，「没美术也能跑」）。
var _sprite: Sprite2D = null


func setup(p_kind: String, pos: Vector2) -> void:
	kind = p_kind
	position = pos
	_setup_sprite()
	queue_redraw()


## 载入事件实体贴图（2026-10-09 美术入库）。缺图 → 什么都不建（_draw 回落图元占位）。
## 贴图【无留白】入库（底边 = 内容底边）⇒ 按纹理高度等比缩放 + 上移半高，底边落在节点原点。
func _setup_sprite() -> void:
	var t := AssetDB.event_sprite(kind)
	if t == null:
		return
	if _sprite == null:
		_sprite = Sprite2D.new()
		add_child(_sprite)
	_sprite.texture = t
	var h := float(t.get_height())
	var s := DISPLAY_H / h
	_sprite.scale = Vector2(s, s)
	_sprite.offset = Vector2(0.0, -h * 0.5)


## 事件主题色（缺 kind 回落白色 —— 与精英词缀色同款「缺键不改色」惯例）。
func color() -> Color:
	return Color(GameStats.EVENT_DEFS.get(kind, {}).get("color", Color(1, 1, 1)))


## 事件名（触发飘字 / 测试打印用）。
func display_name() -> String:
	return String(GameStats.EVENT_DEFS.get(kind, {}).get("name", kind))


## 被消费：淡出后自毁（一次性事件的收尾）。
func consume() -> void:
	_consumed = true


func _process(delta: float) -> void:
	_t += delta
	if _consumed:
		_fade -= delta * 2.5
		if _sprite != null:
			_sprite.modulate.a = clampf(_fade, 0.0, 1.0)   # 贴图与光晕一起淡出
		if _fade <= 0.0:
			queue_free()
			return
	queue_redraw()


func _draw() -> void:
	var a := clampf(_fade, 0.0, 1.0)
	var c := color()
	# 呼吸光晕（三种事件共用的「这里有东西」底光）
	var pulse := 0.5 + 0.5 * sin(_t * 2.2)
	draw_circle(Vector2.ZERO, 44.0 + pulse * 6.0, Color(c.r, c.g, c.b, 0.10 * a))
	draw_circle(Vector2.ZERO, 30.0 + pulse * 4.0, Color(c.r, c.g, c.b, 0.12 * a))
	if _sprite != null:
		return   # 实体本体交给贴图（精灵是子节点、自然盖在光晕之上）
	match kind:
		"altar":
			_draw_altar(a, c, pulse)
		"market":
			_draw_market(a, c, pulse)
		"pillar":
			_draw_pillar(a, c, pulse)


## 献祭祭坛：灰石台 + 红火盆（火苗随呼吸摆动）。
func _draw_altar(a: float, c: Color, pulse: float) -> void:
	draw_rect(Rect2(-26.0, -6.0, 52.0, 26.0), Color(0.42, 0.40, 0.46, a), true)
	draw_rect(Rect2(-20.0, -22.0, 40.0, 18.0), Color(0.50, 0.48, 0.55, a), true)
	draw_rect(Rect2(-14.0, -28.0, 28.0, 8.0), Color(0.30, 0.28, 0.34, a), true)
	var fh := 20.0 + pulse * 7.0
	draw_colored_polygon(PackedVector2Array([
		Vector2(-8.0, -28.0), Vector2(8.0, -28.0), Vector2(0.0, -28.0 - fh)]),
		Color(0.95, 0.35, 0.25, 0.92 * a))
	draw_colored_polygon(PackedVector2Array([
		Vector2(-4.0, -28.0), Vector2(4.0, -28.0), Vector2(0.0, -28.0 - fh * 0.55)]),
		Color(1.0, 0.75, 0.35, 0.95 * a))


## 黑市商人：紫篷摊位 + 台面上的金币堆。
func _draw_market(a: float, c: Color, pulse: float) -> void:
	draw_colored_polygon(PackedVector2Array([
		Vector2(-34.0, -14.0), Vector2(34.0, -14.0), Vector2(0.0, -46.0)]),
		Color(c.r, c.g, c.b, 0.95 * a))
	draw_rect(Rect2(-30.0, -14.0, 60.0, 14.0), Color(0.35, 0.30, 0.42, a), true)
	var g := 3.0 + pulse * 1.0
	draw_circle(Vector2(-12.0, -30.0), g, Color(1.0, 0.84, 0.2, a))
	draw_circle(Vector2(0.0, -33.0), g, Color(1.0, 0.9, 0.4, a))
	draw_circle(Vector2(12.0, -30.0), g, Color(1.0, 0.84, 0.2, a))


## 挑战柱：金柱 + 顶端光球 + 扩散光环。
func _draw_pillar(a: float, c: Color, pulse: float) -> void:
	draw_rect(Rect2(-10.0, -56.0, 20.0, 56.0), Color(0.55, 0.45, 0.20, a), true)
	draw_rect(Rect2(-14.0, -4.0, 28.0, 10.0), Color(0.45, 0.36, 0.16, a), true)
	draw_circle(Vector2(0.0, -64.0), 10.0 + pulse * 2.0, Color(c.r, c.g, c.b, 0.95 * a))
	draw_arc(Vector2(0.0, -64.0), 16.0 + pulse * 4.0, 0.0, TAU, 24,
		Color(c.r, c.g, c.b, 0.38 * a), 2.0, true)
