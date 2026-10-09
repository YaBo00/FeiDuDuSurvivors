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
## 商店券（2026-09-22 精英词缀系统）：精英必掉，拾取后下一家商店全店 8 折。
## 需求 §2.4 允许「图标用现有金色方块即可」⇒ 不新增贴图，走图元占位画法（金色方票）。
const KIND_COUPON := "coupon"
## Boss 宝箱（2026-10-08 玩法增补批次）：Boss 被击杀必掉，拾取后弹三选一奖励面板。
## 美术图未入库 ⇒ 图元占位画法（金箱）；以后美术给了 `drops/chest.png` 并在
## AssetDB.DROPS 登记 "chest"，本文件零改动自动切换。
const KIND_CHEST := "chest"
## 宝箱怪（2026-10-08 局内事件系统）：伪装成宝箱的怪物 —— 外观与 KIND_CHEST 逐像素同款
## （欺骗性就是玩法本体）；「拾取」（走近）时由 CombatResolver.collect 判定现形，
## 交给 Battle 在原位刷一只 Mimic 敌人。本节点只管「长成宝箱的样子」。
const KIND_MIMIC := "mimic"

## 掉落物图标的显示高度（px）。[PLACEHOLDER] 未 playtest。
## 拾取半径只有 6，图标太小会看不见，所以显示得比判定范围大一些。
const DISPLAY_H := 22.0
## 宝箱 / 宝箱怪伪装态的显示高度（2026-10-09 美术入库）：图元占位时代金箱刻意比金币大一圈
## （宽 ≈ radius×5 = 30px），sprite 路径沿用同一体量（贴图内容 51×40，显示 ≈ 28×22）。
const CHEST_DISPLAY_H := 22.0
## 商店券的显示高度（2026-10-09）：图元时代是 radius×1.6≈9.6px 的小方票，
## sprite 路径略放大保可读（贴图内容 60×37，显示 ≈ 19×12）。
const COUPON_DISPLAY_H := 12.5

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
	if p_kind == KIND_CHEST or p_kind == KIND_MIMIC:
		# 宝箱 / 宝箱怪（2026-10-08）：必得奖励（或必咬一口），不能 8 秒凭空过期 ——
		# 用超长寿命兜底（真实流程里宝箱必然在同波波末被 collect_all_pickups 真空回收）。
		life = GameStats.PICKUP_CHEST_LIFE
	else:
		life = GameStats.PICKUP_LIFE * (GameStats.PICKUP_GOLD_LIFE_MULT if p_kind == KIND_GOLD else 1.0)
	_setup_visuals()
	queue_redraw()


## 接上美术图标。kind 与 AssetDB.DROPS 的键同名（gold / xp / hp）。
func _setup_visuals() -> void:
	if sprite == null:
		return
	var t := AssetDB.drop(kind)
	if t == null:
		# 磁铁 / 商店券 / 宝箱 / 宝箱怪（伪装态）的图元占位是【常态】而非缺资源事故（刻意不画图标），
		# 不 push_warning 刷屏。（2026-10-09 补漏：KIND_MIMIC 此前不在豁免名单里，每次生成宝箱怪都刷警告。）
		if kind != KIND_MAGNET and kind != KIND_COUPON and kind != KIND_CHEST \
				and kind != KIND_MIMIC:
			push_warning("Pickup: 类型 '%s' 的美术资源缺失，使用图元占位画法" % kind)
		return
	sprite.texture = t
	# 显示高度按 kind 分档（2026-10-09 美术入库）：宝箱类沿用图元时代的「大一圈」体量，券更小。
	var target_h := DISPLAY_H
	if kind == KIND_CHEST or kind == KIND_MIMIC:
		target_h = CHEST_DISPLAY_H
	elif kind == KIND_COUPON:
		target_h = COUPON_DISPLAY_H
	sprite.scale = AssetDB.drop_fit(target_h)["scale"]
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
	elif kind == KIND_COUPON:
		# 商店券：金色方票 + 白斜杠。方形与金币（圆）/磁铁（马蹄）一眼可分，
		# 「这张不是钱，是打折凭证」靠形状就能读懂。
		var h := radius * 1.6
		var sq := Rect2(Vector2(-h * 0.5, -h * 0.5), Vector2(h, h))
		draw_rect(sq, Color(1.0, 0.78, 0.16, alpha), true)
		draw_rect(sq, Color(1.0, 0.96, 0.72, alpha), false, 1.5)
		draw_line(Vector2(-h * 0.2, h * 0.2), Vector2(h * 0.2, -h * 0.2),
			Color(1, 1, 1, alpha * 0.9), 2.0, true)
	elif kind == KIND_CHEST or kind == KIND_MIMIC:
		# Boss 宝箱 / 宝箱怪伪装态（2026-10-08 建；09 修漏）：金箱 + 亮锁扣 + 柔光垫底。
		# 图元占位是【常态】（与磁铁/商店券同规格），以后美术给了 drops/chest.png 即自动切换。
		# ⚠️ KIND_MIMIC 刻意与 KIND_CHEST 逐像素同款 —— 欺骗性就是玩法本体（头部注释早有此设计，
		# 但 _draw 此前漏了 mimic 分支 ⇒ 伪装态被画成兜底蓝点；2026-10-09 修复为同款金箱）。
		# 尺寸刻意比其他掉落物大一圈 —— 「这是一份大奖」靠体量直接读出来。
		var w := radius * 5.0
		var h := radius * 3.6
		draw_circle(Vector2.ZERO, w * 0.62, Color(1.0, 0.85, 0.3, alpha * 0.18))
		draw_rect(Rect2(-w * 0.5, -h * 0.1, w, h * 0.6), Color(0.72, 0.45, 0.12, alpha), true)
		draw_rect(Rect2(-w * 0.5, -h * 0.5, w, h * 0.42), Color(0.90, 0.62, 0.18, alpha), true)
		draw_line(Vector2(-w * 0.5, -h * 0.08), Vector2(w * 0.5, -h * 0.08),
			Color(0.45, 0.27, 0.06, alpha), 1.5, true)
		draw_rect(Rect2(-w * 0.09, -h * 0.22, w * 0.18, h * 0.34),
			Color(1.0, 0.93, 0.55, alpha), true)
		draw_rect(Rect2(-w * 0.5, -h * 0.5, w, h), Color(1.0, 0.96, 0.74, alpha), false, 1.5)
	else:
		draw_circle(Vector2.ZERO, radius * 0.85, Color(0.0, 0.75, 1.0, alpha))
