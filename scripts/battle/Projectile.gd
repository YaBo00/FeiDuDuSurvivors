class_name Projectile
extends Node2D
## 弹道。移动与命中判定由 Battle 主循环驱动（保证结算顺序确定、可测）。
##
## 生命周期：life <= 0 或飞出屏幕 → 由 Battle 回收。
## 穿透：每命中一个敌人 pierced += 1，pierced >= pierce_cap 即回收。
##   ⚠️ 判定用的是【逐弹道】`pierce_cap`（武器表 pierce），不是全局 PROJ_PIERCE ——
##   忧郁嘉豪的暗影弹 pierce=99 靠的就是这条，用全局常量会让它永远打穿 2 个就回收。

var velocity: Vector2 = Vector2.ZERO
var radius: float = GameStats.PROJ_RADIUS
var damage: int = 1
var crit: float = 0.0
var critd: float = 1.5
var lifesteal: float = 0.0
var life: float = GameStats.PROJ_LIFE
var pierced: int = 0
var from_player: bool = true
var body_color: Color = Color("#FFD700")
# ---- 逐弹道武器参数（由 Battle/CombatResolver 按 WEAPON_DEFS 写入）----
## 弹速乘区（乘以 PROJ_SPEED）。嘉豪 = 1.0。
var speed_mul: float = 1.0
## 穿透上限（**逐弹道**，不是全局 PROJ_PIERCE）。pierced >= pierce_cap 即回收。
## 忧郁嘉豪用 99 实现「直线贯穿全屏」—— 所以判定必须读这里，不能读全局常量。
var pierce_cap: int = GameStats.PROJ_PIERCE
## 命中时掉金币的概率（0 = 不掉）。金融嘉豪金币镖 = 0.12。
var gold_on_hit: float = 0.0
## 命中溅射半径（px，0 = 无溅射）。土豆第二形态「爆裂薯块」= 90。
## 溅射在 CombatResolver.process_projectiles 结算：圈内【其他】敌人受直接伤害 × aoe_pct。
var aoe_radius: float = 0.0
## 溅射伤害比例（乘在本次直接命中的实扣伤害上）。爆裂薯块 = 0.40。
var aoe_pct: float = 0.0

# ---- 武器弹道美术（由 Battle 调 apply_visual 按 AssetDB.weapon_bullet 接线）----
## 贴图缺失时保持 null → _draw 回落图元画法（「没美术也能跑」）。
var bullet_tex: Texture2D = null
var frames := 1
var frame_w := 0
var frame_h := 0
var frame_step := 0
var anim_fps := 0.0
## 整个帧格缩放后的显示边长（px，AssetDB.cell_px）。
var cell_px := 0.0
## 帧格内「视觉中心」的像素坐标：单帧图用实测内容中心，sheet 用帧格中心。
## 画的时候把这个点对准节点原点（= 碰撞圆心），视觉才不会偏离判定。
var content_center := Vector2.ZERO
var _anim_t := 0.0
var _frame_idx := 0


## 玩家弹道。`p_speed_mul` 之后的参数全部带默认值 —— 既有 10 参调用【完全兼容】。
## 武器参数由 Battle/CombatResolver 从 GameStats.weapon_for_char(char_id) 取出后传入。
## 第二形态追加：p_aoe_radius / p_aoe_pct（未进化恒 0 = 无溅射，旧基线逐位一致）。
func setup(p_pos: Vector2, p_dir: float, p_damage: int, p_crit: float, p_critd: float,
		p_lifesteal: float, p_speed_mul: float = 1.0,
		p_radius: float = GameStats.PROJ_RADIUS,
		p_pierce_cap: int = GameStats.PROJ_PIERCE,
		p_gold_on_hit: float = 0.0,
		p_aoe_radius: float = 0.0, p_aoe_pct: float = 0.0) -> void:
	position = p_pos
	velocity = Vector2(cos(p_dir), sin(p_dir)) * GameStats.PROJ_SPEED * p_speed_mul
	damage = p_damage
	crit = p_crit
	critd = p_critd
	lifesteal = p_lifesteal
	speed_mul = p_speed_mul
	radius = p_radius
	pierce_cap = p_pierce_cap
	gold_on_hit = p_gold_on_hit
	aoe_radius = p_aoe_radius
	aoe_pct = p_aoe_pct
	life = GameStats.PROJ_LIFE
	pierced = 0
	from_player = true
	body_color = Color("#FFD700")
	queue_redraw()


## 敌方弹道（远程怪 / Boss 弹幕）。比玩家弹慢、粗、红。
func setup_enemy(p_pos: Vector2, p_dir: float, p_damage: int) -> void:
	position = p_pos
	velocity = Vector2(cos(p_dir), sin(p_dir)) * GameStats.ENEMY_PROJ_SPEED
	damage = p_damage
	life = GameStats.ENEMY_PROJ_LIFE
	from_player = false
	body_color = GameStats.ENEMY_PROJ_COLOR
	radius = GameStats.ENEMY_PROJ_RADIUS
	# 敌方弹道走「命中即回收」路径（见 CombatResolver.process_projectiles），
	# 这里显式复位武器参数，避免任何复用路径下残留玩家武器的值。
	speed_mul = 1.0
	pierce_cap = GameStats.PROJ_PIERCE
	gold_on_hit = 0.0
	aoe_radius = 0.0
	aoe_pct = 0.0
	queue_redraw()


## 接上武器弹道美术。cfg 来自 AssetDB.weapon_bullet(char_id)；
## 空字典（未登记/贴图缺失）→ 什么都不做，保持图元回落。
func apply_visual(cfg: Dictionary) -> void:
	if cfg.is_empty():
		return
	bullet_tex = cfg["texture"]
	frames = int(cfg["frames"])
	frame_w = int(cfg["fw"])
	frame_h = int(cfg["fh"])
	frame_step = int(cfg["step"])
	anim_fps = float(cfg["fps"])
	cell_px = float(cfg["cell_px"])
	var content: Rect2 = cfg["content"]
	content_center = content.get_center() if content.size.x > 0.0 \
		else Vector2(frame_w, frame_h) * 0.5
	body_color = cfg["fallback"]
	queue_redraw()


## 推进一步。返回 false 表示已失效（应被回收）。
func advance(delta: float) -> bool:
	position += velocity * delta
	life -= delta
	# 帧动画推进（金币旋转 / 暗影脉冲）。只在帧序号变化时重绘，省绘制调用。
	if frames > 1 and anim_fps > 0.0:
		_anim_t += delta
		var idx := int(_anim_t * anim_fps) % frames
		if idx != _frame_idx:
			_frame_idx = idx
			queue_redraw()
	if life <= 0.0:
		return false
	if position.x < -50.0 or position.x > GameStats.ARENA_W + 50.0:
		return false
	if position.y < -50.0 or position.y > GameStats.ARENA_H + 50.0:
		return false
	return true


func _draw() -> void:
	# 有贴图：按切帧参数画当前帧，把【内容中心】对准节点原点（= 碰撞圆心）。
	if bullet_tex != null and frame_w > 0 and cell_px > 0.0:
		var s := cell_px / float(frame_w)
		var src := Rect2(float(_frame_idx * frame_step), 0.0, float(frame_w), float(frame_h))
		var dst := Rect2(-content_center * s, Vector2(frame_w, frame_h) * s)
		draw_texture_rect_region(bullet_tex, dst, src)
		return
	# 回落：图元占位（没美术也能跑）
	draw_circle(Vector2.ZERO, radius, body_color)
	draw_circle(Vector2.ZERO, radius * 0.4, Color(1, 1, 0.9, 0.9))
