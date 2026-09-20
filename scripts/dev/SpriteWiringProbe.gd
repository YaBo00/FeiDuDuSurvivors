extends SceneTree
## 门禁：美术资源【接线】是否正确
##
## AssetProbe 只证明「资源导入且规格正确」；本探针证明「游戏运行时真的用上了它们」。
## 这两件事必须分开验 —— 「导入了但没接上」正是最容易漏掉的失败形态：
## 所有代码都写对了，但精灵节点是空的，游戏照旧显示图元占位，而没人察觉。
##
## 断言：
##   1. 玩家精灵接上且用了待机/跑动两组动画，scale/offset 与 AssetDB 算出的一致
##   2. 每种刷出来的敌人精灵都接上了（没有回落到图元占位）
##   3. 竞技场地面贴图已加载
##   4. 掉落物精灵按 kind 接上了对应图标
##
## 用法: godot --headless --path <项目> --script res://scripts/dev/SpriteWiringProbe.gd
## 退出码 0=PASS 1=FAIL。

var battle: Node = null
var armed := false
var done := false
var _wait_frames := 0
var failures: Array[String] = []


func _initialize() -> void:
	print("=".repeat(72))
	print(" 门禁：美术资源接线（运行时是否真的用上了精灵）")
	print("=".repeat(72))
	var packed: PackedScene = load("res://scenes/battle/Battle.tscn")
	if packed == null:
		print(" FAIL: Battle.tscn 加载失败")
		quit(1)
		return
	battle = packed.instantiate()
	root.add_child(battle)
	# 注意：battle.player 是 @onready，add_child 在这一阶段还没跑 _ready，
	# 直接取会拿到 null。所以 autopilot 的设置推到第一帧（见 _process -> _arm）。
	print("  Battle 已入场，等待第一帧（@onready 要等 _ready 跑完）")


func _arm() -> void:
	battle.player.autopilot = true   # 别让玩家中途死掉，免得场景被拆
	armed = true


func _process(_delta: float) -> bool:
	if done:
		return true
	if not armed:
		_arm()
		# 刷怪改成「波内匀速投放」后，第 1 帧可能还没有敌人 —— 等刷出来再断言。
		print("    等待首次刷怪……")
		return false
	_wait_frames += 1
	if (battle.enemies.size() <= 0 or battle._floor_tex == null) and _wait_frames < 600:
		return false
	_check()
	_report()
	return true


func _check() -> void:
	# ---- 1. 玩家 ----
	var p = battle.player
	var ps: AnimatedSprite2D = p.sprite
	if ps == null:
		failures.append("玩家没有 Sprite 节点")
	else:
		if not p._use_sprite:
			failures.append("玩家未接上精灵（回落到了图元占位画法）")
		var sf := ps.sprite_frames
		if sf == null:
			failures.append("玩家精灵没有 SpriteFrames")
		else:
			var anims := []
			for i in sf.get_animation_names():
				anims.append(i)
			print("  玩家动画组: %s" % str(anims))
			for want in ["idle", "run"]:
				if not sf.has_animation(want):
					failures.append("玩家缺少动画组 '%s'" % want)
				elif sf.get_frame_count(want) <= 0:
					failures.append("玩家动画组 '%s' 没有帧" % want)
			print("  idle 帧数=%d  run 帧数=%d" % [
				sf.get_frame_count("idle") if sf.has_animation("idle") else 0,
				sf.get_frame_count("run") if sf.has_animation("run") else 0,
			])
		var fit := AssetDB.char_fit(String(p.char_id), p.RADIUS)
		if not ps.scale.is_equal_approx(fit["scale"]):
			failures.append("玩家精灵 scale 不符：%s vs %s" % [ps.scale, fit["scale"]])
		if absf(ps.offset.y - float(fit["offset_y"])) > 0.01:
			failures.append("玩家精灵 offset.y 不符：%s vs %s" % [ps.offset.y, fit["offset_y"]])
		print("  玩家 scale=%s offset.y=%.1f（脚底锚定）" % [ps.scale, ps.offset.y])

	# ---- 2. 敌人 ----
	var n: int = battle.enemies.size()
	var bad := 0
	var types := {}
	for e in battle.enemies:
		types[e.type_name] = true
		if not e._use_sprite or e.sprite == null or e.sprite.sprite_frames == null:
			bad += 1
			failures.append("敌人 '%s' 未接上精灵" % e.type_name)
		elif e.sprite.sprite_frames.get_frame_count("idle") <= 0:
			failures.append("敌人 '%s' 的 idle 动画没有帧" % e.type_name)
	if n <= 0:
		failures.append("第 1 帧没有敌人，无法验证接线")
	print("  敌人 %d 只（类型 %s），未接上精灵的 = %d" % [n, str(types.keys()), bad])
	for t in types.keys():
		var e0 = null
		for e in battle.enemies:
			if e.type_name == t:
				e0 = e
				break
		if e0 != null:
			print("    %-8s scale=%.3f offset.y=%.1f 帧数=%d" % [
				t, e0.sprite.scale.x, e0.sprite.offset.y,
				e0.sprite.sprite_frames.get_frame_count("idle"),
			])

	# ---- 3. 竞技场底（2026-09-19 背景重构：波次主题真实贴图，见 Battle._apply_floor_theme）----
	# 地面 = assets/bg/{主题id}.png 整铺（1920x1080）—— 首波 ceramic 必须已挂上
	if battle._floor_tex == null:
		failures.append("地面贴图未接上（AssetDB.floor_bg 返回 null？）")
	else:
		print("  地面贴图: %dx%d" % [
			battle._floor_tex.get_width(), battle._floor_tex.get_height(),
		])
	if battle._floor_glow == null or battle._floor_vignette == null:
		failures.append("柔光/暗角层未构建")

	# ---- 4. 掉落物 ----
	var kinds := ["gold", "xp", "hp"]
	for k in kinds:
		var t := AssetDB.drop(k)
		if t == null:
			failures.append("掉落物 '%s' 的贴图加载不到" % k)
	print("  掉落物贴图: %s" % str(kinds))

	# ---- 5. 升级图标：面板会按 id 取图，缺图的项自动不显示图标框 ----
	var with_icon := 0
	var missing: Array[String] = []
	for def in GameStats.UPGRADE_POOL:
		var id := String(def["id"])
		if AssetDB.upgrade_icon(id) != null:
			with_icon += 1
		else:
			missing.append(id)
	print("  升级图标: %d/%d 项有图（未配: %s）" % [
		with_icon, GameStats.UPGRADE_POOL.size(), str(missing),
	])

	# ---- 6. 道具图标（商店用）----
	var item_missing: Array[String] = []
	for k in AssetDB.ITEMS.keys():
		if AssetDB.item_icon(String(k)) == null:
			item_missing.append(String(k))
	if not item_missing.is_empty():
		failures.append("道具图标缺失: %s" % str(item_missing))
	print("  道具图标: %d/%d 就位" % [
		AssetDB.ITEMS.size() - item_missing.size(), AssetDB.ITEMS.size(),
	])


func _report() -> void:
	done = true
	print("\n" + "=".repeat(72))
	if failures.is_empty():
		print(" RESULT=PASS 美术资源已全部接入运行时")
		quit(0)
	else:
		for m in failures:
			print(" FAIL: %s" % m)
		print(" RESULT=FAIL 失败项=%d" % failures.size())
		quit(1)
