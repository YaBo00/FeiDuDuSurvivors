extends SceneTree
## 独立验证探针：MetaSave 局外永久强化商店（A2/A6 消费端第二片）。
##
## 被验证的契约：
##   MetaSave.META_UPGRADES（3 条，id 唯一 / 等级 / 价格曲线合法）
##   MetaSave.xp_earned（纯函数折算：kills/20 + wave×3 + 通关 +100）
##   MetaSave.record_run（入账同时折算 meta_xp）
##   MetaSave.purchase（余额不足拒 / 满级拒 / 成功扣费升级并持久化）
##   MetaSave.ledger（空回落 / 坏 JSON 安全回落 / v2 meta_levels 读取）
##   MetaSave.meta_bonus（等级 → 加成系数映射；0 级全 0）
##   Player.recalc_stats（meta 注入：atk 乘区 / hp 平加 / pickup 乘区；零 meta 零行为变化）
##
## 用法: godot --headless --path <项目> --script res://scripts/dev/_ProbeMetaShop.gd
## 退出码 0=PASS 1=FAIL（门禁用 grep -q "RESULT=PASS" 判定）

const PROBE_PATH := "user://probe_meta_shop.json"

var battle: Node = null
var armed := false
var finished := false
var checks := 0
var fails: Array[String] = []


func _initialize() -> void:
	print("[PROBE] === MetaSave 局外强化商店验证（消费端第二片）===")
	# ① 重定向存档路径 + 清场：探针绝不读写真实账本
	MetaSave.save_path = PROBE_PATH
	_del_save()
	var packed: PackedScene = load("res://scenes/battle/Battle.tscn")
	if packed == null:
		_finish("Battle.tscn 加载失败")
		return
	battle = packed.instantiate()
	root.add_child(battle)


func _arm() -> void:
	# ---- A. 静态契约 ----
	_check(MetaSave.META_UPGRADES.size() >= 3, "META_UPGRADES 至少 3 条（实际 %d）" % MetaSave.META_UPGRADES.size())
	var ids := {}
	var statics_ok := true
	for u in MetaSave.META_UPGRADES:
		var id := String(u["id"])
		if ids.has(id) or int(u["max_level"]) < 1 or float(u["base_cost"]) <= 0.0 or float(u["cost_growth"]) <= 1.0:
			statics_ok = false
		ids[id] = true
	_check(statics_ok, "升级表合法（id 唯一 / max_level>=1 / 成本正增长）")
	_check(int(MetaSave.xp_earned(true, 10, 200)) == 140, "xp_earned(true,10,200)==140（kills/20+wave×3+通关100）")
	_check(int(MetaSave.xp_earned(false, 5, 40)) == 17, "xp_earned(false,5,40)==17（无通关奖励）")

	# ---- B. 空回落 ----
	var d0: Dictionary = MetaSave.ledger()
	_check(int(d0["meta_xp"]) == 0 and int(d0["runs"]) == 0 and (d0["meta_levels"] as Dictionary).is_empty(),
		"无档 → 干净账本（meta_xp=0 / meta_levels 空）")

	# ---- C. record_run 入账 + 折算 ----
	MetaSave.record_run(true, 10, 200, 50)
	var d1: Dictionary = MetaSave.ledger()
	_check(int(d1["runs"]) == 1 and int(d1["best_wave"]) == 10, "record_run 后 runs=1 / best_wave=10")
	_check(int(d1["meta_xp"]) == 140, "结算折算 meta_xp=140（实际 %s）" % str(d1["meta_xp"]))

	# ---- D. 购买成功 + 持久化 ----
	# 首级 meta_atk 价 120；当前 140 → 买得起
	var price0 := int(MetaSave.upgrade_cost("meta_atk", 0))
	_check(price0 == 120, "meta_atk 首级价 120（实际 %d）" % price0)
	_check(MetaSave.purchase("meta_atk"), "purchase(meta_atk) 成功（140 ≥ 120）")
	var d2: Dictionary = MetaSave.ledger()
	_check(int(d2["meta_levels"].get("meta_atk", 0)) == 1 and int(d2["meta_xp"]) == 140 - 120,
		"购买后等级=1 / 余额=20（实际 %s）" % str(d2["meta_xp"]))
	# 重读（新进程语义：落盘后 ledger 重读一致）
	var d2b: Dictionary = MetaSave.ledger()
	_check(int(d2b["meta_levels"].get("meta_atk", 0)) == 1, "持久化：重读等级一致")

	# ---- E. 余额不足拒购 ----
	_check(not MetaSave.purchase("meta_atk"), "二级价 240 > 余额 20 → 拒购")

	# ---- F. 满级封顶 ----
	MetaSave.record_run(true, 20, 100000, 0)   # 补足大量 xp（20波+5000杀+100 → 5250+60+100）
	for i in 4:
		MetaSave.purchase("meta_pickup")       # 3 级封顶 → 前 3 次成功
	_check(int(MetaSave.ledger()["meta_levels"].get("meta_pickup", 0)) == 3, "meta_pickup 买满 3 级")
	_check(not MetaSave.purchase("meta_pickup"), "满级后再购 → 拒")

	# ---- G. 坏 JSON 安全回落 ----
	var f := FileAccess.open(PROBE_PATH, FileAccess.WRITE)
	f.store_string("{{{not json")
	f = null
	var d3: Dictionary = MetaSave.ledger()
	_check(int(d3["runs"]) == 0 and (d3["meta_levels"] as Dictionary).is_empty(),
		"坏档 → 安全回落干净账本（并已覆盖写回）")

	# ---- H. meta_bonus 等级 → 加成映射 ----
	var b0: Dictionary = MetaSave.meta_bonus()
	_check(_approx(float(b0["atk_mul"]), 0.0) and _approx(float(b0["hp_flat"]), 0.0) and _approx(float(b0["pickup_mul"]), 0.0),
		"0 级 meta_bonus 全 0")
	MetaSave.record_run(false, 100, 10000, 0)   # 坏档后余额 0 → 补 800 xp（500+300）
	_check(MetaSave.purchase("meta_atk") and MetaSave.purchase("meta_hp") and MetaSave.purchase("meta_pickup"),
		"各买 1 级成功（余额充足）")
	var b1: Dictionary = MetaSave.meta_bonus()
	_check(_approx(float(b1["atk_mul"]), 0.03) and _approx(float(b1["hp_flat"]), 20.0) and _approx(float(b1["pickup_mul"]), 0.15),
		"各 1 级 → 0.03 / 20 / 0.15")

	# ---- I. Player 集成（真实 Battle 链路）----
	battle.start_run()
	battle.spawn_remaining = 0
	var pl: Node = battle.player
	pl.autopilot = false
	pl.god_mode = true
	# 守卫验证：探针进程（--script）不被注入，meta_bonus_dict 必须为空
	_check((pl.meta_bonus_dict as Dictionary).is_empty(), "探针进程 start_run 不注入 meta（守卫生效）")
	# 零行为变化：空 meta 下 recalc 前后一致
	var atk0 := int(pl.atk)
	var hp0 := int(pl.max_hp)
	var pk0 := float(pl.pickup_range)
	pl.meta_bonus_dict = {"atk_mul": 0.0, "hp_flat": 0.0, "pickup_mul": 0.0}
	pl.recalc_stats()
	_check(int(pl.atk) == atk0 and int(pl.max_hp) == hp0 and _approx(float(pl.pickup_range), pk0),
		"零 meta：recalc 后 atk/hp/pickup 逐位不变")
	# 注入加成 → 三属性按预期变化
	pl.meta_bonus_dict = {"atk_mul": 0.03, "hp_flat": 20.0, "pickup_mul": 0.15}
	pl.recalc_stats()
	_check(int(pl.atk) == roundi(float(atk0) * 1.03), "atk %d → %d（×1.03）" % [atk0, int(pl.atk)])
	_check(int(pl.max_hp) == hp0 + 20, "max_hp %d → %d（+20）" % [hp0, int(pl.max_hp)])
	_check(_approx(float(pl.pickup_range), pk0 * 1.15), "pickup_range %.1f → %.1f（×1.15）" % [pk0, float(pl.pickup_range)])
	# 回滚 → 精确还原基线（幂等 recalc）
	pl.meta_bonus_dict = {}
	pl.recalc_stats()
	_check(int(pl.atk) == atk0 and int(pl.max_hp) == hp0 and _approx(float(pl.pickup_range), pk0),
		"清空 meta：recalc 后精确还原基线")

	_del_save()


func _del_save() -> void:
	if FileAccess.file_exists(PROBE_PATH):
		DirAccess.remove_absolute(PROBE_PATH)


func _approx(a: float, b: float) -> bool:
	return absf(a - b) <= maxf(1e-4, 1e-5 * maxf(absf(a), absf(b)))


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
