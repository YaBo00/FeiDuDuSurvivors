extends SceneTree
## 独立验证探针：商店道具前置解锁链（A4 迭代）。
##
## 被验证的契约：
##   ITEM_DEFS[...].requires：引用的 id 必须存在于 ITEM_DEFS（防 A4 式死代码）、desc 注明「需：」
##   GameStats.shop_roll(n)：默认不传 owned = 旧行为（全道具进池，既有门禁零破坏）
##   shop_roll(n, owned)：前置未购 → 永不上架；前置已购 → 可上架；链式逐级解锁
##   Battle.items_owned：start_run 清零的生命周期
##
## 用法: godot --headless --path <项目> --script res://scripts/dev/_ProbeShopRequires.gd
## 退出码 0=PASS 1=FAIL（门禁用 grep -q "RESULT=PASS" 判定）

const REQUIRES_IDS := ["crit_dmg_up", "mega_hp_potion", "iron_armor", "golden_shield", "evade_cloak"]

var battle: Node = null
var armed := false
var finished := false
var checks := 0
var fails: Array[String] = []


func _initialize() -> void:
	print("[PROBE] === 商店前置解锁链验证（A4 迭代）===")
	var packed: PackedScene = load("res://scenes/battle/Battle.tscn")
	if packed == null:
		_finish("Battle.tscn 加载失败")
		return
	battle = packed.instantiate()
	root.add_child(battle)


func _arm() -> void:
	var s = load("res://scripts/data/Stats.gd")

	# ---- A. 静态契约：前置引用不悬空 + desc 注明 ----
	var dead := 0
	var no_desc := 0
	for id in REQUIRES_IDS:
		var d: Dictionary = s.ITEM_DEFS[id]
		if not s.ITEM_DEFS.has(String(d["requires"])):
			dead += 1
		if not String(d["desc"]).contains("需："):
			no_desc += 1
	_check(dead == 0, "requires 引用的道具全部存在（无死链）")
	_check(no_desc == 0, "所有前置道具的 desc 均注明「需：XX」")

	# ---- B. 默认参 = 旧行为：大样本下带前置道具也能出现 ----
	var seen_old := {}
	for i in 60:
		for id in s.shop_roll(6):
			seen_old[id] = true
	var old_ok := true
	for id in REQUIRES_IDS:
		if not seen_old.has(id):
			old_ok = false
	_check(old_ok, "shop_roll(n) 默认行为：全部道具（含前置件）可上架")

	# ---- C. 空 owned：前置件全部被过滤 ----
	var seen_locked := {}
	for i in 60:
		var owned: Array[String] = []
		for id in s.shop_roll(6, owned):
			seen_locked[id] = true
	var lock_ok := true
	for id in REQUIRES_IDS:
		if seen_locked.has(id):
			lock_ok = false
	_check(lock_ok, "空 owned：5 件前置件 60 次大样本永不上架")
	# 过滤后池子仍够上架（防「全被滤光开天窗」）
	var free_count := 0
	for id in s.ITEM_DEFS.keys():
		if not (s.ITEM_DEFS[id] as Dictionary).has("requires"):
			free_count += 1
	_check(free_count >= s.SHOP_SLOTS, "无前置道具 %d 件 ≥ SHOP_SLOTS %d（池子永够）" % [free_count, int(s.SHOP_SLOTS)])

	# ---- D. 前置已购 → 解锁；链式逐级 ----
	var owned1: Array[String] = ["crit_lens"]
	var seen1 := {}
	for i in 60:
		for id in s.shop_roll(6, owned1):
			seen1[id] = true
	_check(seen1.has("crit_dmg_up"), "购暴击透镜 → 暴击之牙上架")
	_check(not seen1.has("iron_armor"), "未购皮甲 → 铁甲仍锁定")

	var owned2: Array[String] = ["leather_armor"]
	var seen2 := {}
	for i in 60:
		for id in s.shop_roll(6, owned2):
			seen2[id] = true
	_check(seen2.has("iron_armor") and not seen2.has("golden_shield"), "购皮甲 → 铁甲解锁 / 金盾仍锁定")

	var owned3: Array[String] = ["leather_armor", "iron_armor"]
	var seen3 := {}
	for i in 60:
		for id in s.shop_roll(6, owned3):
			seen3[id] = true
	_check(seen3.has("golden_shield"), "购皮甲+铁甲 → 金盾解锁（链式逐级）")

	# ---- E. Battle.items_owned 生命周期 ----
	battle.start_run()
	battle.spawn_remaining = 0
	_check((battle.items_owned as Array).is_empty(), "start_run 后 items_owned 清零")
	battle.items_owned.append("crit_lens")
	battle.start_run()
	battle.spawn_remaining = 0
	_check((battle.items_owned as Array).is_empty(), "重开后 items_owned 再次清零")

	_finish("")


func _check(cond: bool, label: String) -> void:
	checks += 1
	if cond:
		print("[PROBE]   OK   %s" % label)
	else:
		fails.append(label)
		print("[PROBE]   FAIL %s" % label)


func _process(_delta: float) -> bool:
	if finished:
		return true
	if not armed:
		armed = true
		_arm()
		_finish("")
		return true
	return true


func _finish(msg: String) -> void:
	if finished:
		return
	finished = true
	if msg != "":
		print("[PROBE] 提前终止：%s" % msg)
	print("[PROBE] 断言 %d/%d 通过（失败 %d）" % [checks - fails.size(), checks, fails.size()])
	for f in fails:
		print("[PROBE]   - %s" % f)
	print("[PROBE] RESULT=%s" % ("PASS" if fails.is_empty() else "FAIL"))
	quit(0 if fails.is_empty() else 1)
