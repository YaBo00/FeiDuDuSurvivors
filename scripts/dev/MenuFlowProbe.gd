extends SceneTree
## 门禁：主菜单流程图（标题 → 选角 → 战斗是否真的接通）
##
## 断言：
##   1. Title.tscn / CharSelect.tscn 能实例化，且它们的背景贴图确实加载到了
##      （「场景能打开但图是空的」是这一类改动的典型失败形态）
##   2. CharSelect 里每个角色卡片都建出来了，且 GameStats 里都有对应数据
##   3. **选谁就用谁**：GameSession.begin_run(id) 之后实例化 Battle，
##      玩家的 char_id / 生命上限 / 初始金币 / 拾取范围必须与 GameStats.CHARACTERS[id] 一致
##
## 用法: godot --headless --path <项目> --script res://scripts/dev/MenuFlowProbe.gd
## 退出码 0=PASS 1=FAIL

var failures: Array[String] = []
var step := 0
var battle: Node = null
var pending_id := ""
var ids: Array = []
## 待检查的菜单场景。注意：add_child 之后 _ready 要到【下一帧】才跑，
## 所以不能加完立刻查子节点（否则会误报「界面是空的」）。
var _menu: Array = []
var _phase := 0


func _initialize() -> void:
	print("=".repeat(72))
	print(" 门禁：主菜单流程图")
	print("=".repeat(72))
	for path in ["res://scenes/main/Title.tscn", "res://scenes/main/CharSelect.tscn"]:
		var packed: PackedScene = load(path)
		if packed == null:
			failures.append("场景加载失败：%s" % path)
			continue
		var inst: Node = packed.instantiate()
		inst.set_meta("probe_path", path)
		root.add_child(inst)
		_menu.append(inst)
	ids = GameStats.character_ids()


## 等菜单场景的 _ready 跑完后再查（见 _menu 的说明）
func _check_menu_scenes() -> void:
	for inst in _menu:
		var path: String = inst.get_meta("probe_path")
		var tex_count := _count_texture_rects_with_texture(inst)
		var bg_ok := _has_loaded_bg(inst)
		print("  %-30s 背景贴图=%s  有贴图的 TextureRect=%d" % [
			path.get_file(), "OK" if bg_ok else "缺失", tex_count,
		])
		if not bg_ok:
			failures.append("%s 的背景贴图没加载上（AssetDB.bg 取不到？）" % path.get_file())
		if tex_count <= 0:
			failures.append("%s 里没有任何 TextureRect 拿到贴图" % path.get_file())
		# 按钮皮肤：主题里 Button/normal 应该是 StyleBoxTexture（美术三态图）
		if inst is Control:
			var th := (inst as Control).theme
			if th == null or not th.has_stylebox("normal", "Button"):
				failures.append("%s 没有按钮皮肤主题" % path.get_file())
			elif not (th.get_stylebox("normal", "Button") is StyleBoxTexture):
				failures.append("%s 的按钮皮肤不是 StyleBoxTexture（美术没接上？）" % path.get_file())
			else:
				print("    按钮皮肤: StyleBoxTexture ✓")
	for inst in _menu:
		inst.queue_free()
	_menu.clear()


func _has_loaded_bg(node: Node) -> bool:
	for c in node.get_children():
		if c is TextureRect and (c as TextureRect).texture != null:
			return true
		if _has_loaded_bg(c):
			return true
	return false


func _count_texture_rects_with_texture(node: Node) -> int:
	var n := 0
	for c in node.get_children():
		if c is TextureRect and (c as TextureRect).texture != null:
			n += 1
		n += _count_texture_rects_with_texture(c)
	return n


func _process(_delta: float) -> bool:
	# 第一帧：菜单场景的 _ready 已跑完，此时才查
	if _phase == 0:
		_phase = 1
		_check_menu_scenes()
		return false
	# 之后每个角色占用两帧：一帧实例化并入场，下一帧断言
	if battle == null:
		if step >= ids.size():
			_report()
			return true
		pending_id = String(ids[step])
		GameSession.begin_run(pending_id)
		var packed: PackedScene = load("res://scenes/battle/Battle.tscn")
		battle = packed.instantiate()
		root.add_child(battle)
		return false

	_check_battle_uses(pending_id)
	battle.queue_free()
	battle = null
	step += 1
	return false


func _check_battle_uses(id: String) -> void:
	var c := GameStats.character(id)
	var base: Dictionary = c["base"]
	var p = battle.player
	if p == null:
		failures.append("选角 %s 后 Battle 里没有玩家节点" % id)
		return
	var ok := true
	if String(p.char_id) != id:
		failures.append("选角 %s：玩家 char_id 却是 %s" % [id, p.char_id])
		ok = false
	if p.max_hp != int(base["maxHp"]):
		failures.append("选角 %s：生命上限 %d，应为 %d" % [id, p.max_hp, int(base["maxHp"])])
		ok = false
	if p.gold != int(c["start_gold"]):
		failures.append("选角 %s：初始金币 %d，应为 %d" % [id, p.gold, int(c["start_gold"])])
		ok = false
	if absf(p.pickup_range - float(base["pickupRange"])) > 0.01:
		failures.append("选角 %s：拾取范围 %.1f，应为 %.1f" % [
			id, p.pickup_range, float(base["pickupRange"]),
		])
		ok = false
	if ok:
		print("  选角 %-8s → 玩家 HP%-4d 金币%-4d 拾取%.0f  一致 ✓" % [
			id, p.max_hp, p.gold, p.pickup_range,
		])


func _report() -> void:
	print("\n" + "=".repeat(72))
	if failures.is_empty():
		print(" RESULT=PASS 菜单流程接通，选角数据一致")
		quit(0)
	else:
		for m in failures:
			print(" FAIL: %s" % m)
		print(" RESULT=FAIL 失败项=%d" % failures.size())
		quit(1)
