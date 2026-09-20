extends SceneTree
## 独立验证探针：波末升级捆绑的「敌人代价」（A1 双向升级投票，用户选 A：只在波末捆绑）。
##
## 被验证的契约：
##   Stats.UPGRADE_ENEMY_COSTS（1/2/3 三档，各含 hp_mul/dmg_mul/max_stacks）
##   Stats.UPGRADE_POOL 每条带 cost_tier ∈ 1..3
##   Battle._generate_options()：波末(reason=="wave")选项挂 cost；等级升级不带
##   Battle._pick_enemy_cost(tier)：本档叠层满则就近换档；全满返回空
##   Battle._apply_enemy_cost(cost)：累积乘区（乘法），封顶后档位不可再取
##   Battle.enemy_cost_hp_mult()/dmg_mult() → WaveDirector.setup 传入 Enemy.setup
##   start_run() 重置全部代价状态
##
## 用法: godot --headless --path <项目> --script res://scripts/dev/_ProbeUpgradeCost.gd
## 退出码 0=PASS 1=FAIL（门禁用 grep -q "RESULT=PASS" 判定）

const TOL_ABS := 1.0
const DT := 1.0 / 60.0

var battle: Node = null
var armed := false
var finished := false
var checks := 0
var fails: Array[String] = []
var _stats_inst = null          # Stats 实例（静态方法经实例 call 调用 —— 照抄 _ProbeFloorTiles 的写法）


func _initialize() -> void:
	print("[PROBE] === 波末升级「敌人代价」验证（A1 双向投票 · 方案 A）===")
	var packed: PackedScene = load("res://scenes/battle/Battle.tscn")
	if packed == null:
		_finish("Battle.tscn 加载失败")
		return
	battle = packed.instantiate()
	root.add_child(battle)
	var s = load("res://scripts/data/Stats.gd")
	if s != null:
		_stats_inst = s.new()


## 反射取 Stats 常量（直接写 GameStats.XXX 在常量缺失时是解析期硬错误 —— 工程已踩过多次）
func _consts() -> Dictionary:
	var s = load("res://scripts/data/Stats.gd")
	return s.get_script_constant_map() if s != null else {}


func _arm() -> void:
	armed = true
	var costs: Dictionary = _consts().get("UPGRADE_ENEMY_COSTS", {})

	# ---- A. 静态契约 ----
	_check(costs.size() == 3, "UPGRADE_ENEMY_COSTS 恰含 3 档（实际 %d）" % costs.size())
	for t in [1, 2, 3]:
		if not costs.has(t):
			_check(false, "缺少代价档位 %d" % t)
			continue
		var c: Dictionary = costs[t]
		_check(String(c.get("name", "")).length() > 0 and float(c.get("hp_mul", -1)) >= 0.0
			and float(c.get("dmg_mul", -1)) >= 0.0 and int(c.get("max_stacks", 0)) >= 1,
			"档位 %d：name/hp_mul/dmg_mul/max_stacks 齐备且合法" % t)
	var pool: Array = _consts().get("UPGRADE_POOL", [])
	var bad_tier := 0
	for def in pool:
		var tier := int(def.get("cost_tier", -1))
		if tier < 1 or tier > 3:
			bad_tier += 1
	_check(bad_tier == 0, "UPGRADE_POOL 全部 %d 条都带 cost_tier ∈ 1..3（非法 %d 条）" % [
		pool.size(), bad_tier])

	# ---- 开局 ----
	battle.start_run()
	battle.spawn_remaining = 0
	var pl: Node2D = battle.player
	pl.autopilot = false
	pl.atk = 0.0
	pl.god_mode = true

	# ---- B. 等级升级保持纯奖励（无 cost 键）----
	battle._current_reason = "level"
	battle._generate_options()
	var leaked := 0
	for opt in battle._current_options:
		if opt.has("cost"):
			leaked += 1
	_check(leaked == 0, "等级升级选项 %d 个全部不带 cost（纯奖励，A 方案核心）" % battle._current_options.size())

	# ---- C. 波末升级全部捆绑 ----
	battle._current_reason = "wave"
	battle._generate_options()
	var missing := 0
	for opt in battle._current_options:
		if not opt.has("cost"):
			missing += 1
	_check(battle._current_options.size() > 0 and missing == 0,
		"波末选项 %d 个全部捆绑代价（缺 %d）" % [battle._current_options.size(), missing])
	# 取代价不改变叠层 —— 叠层只在真正选择时累积
	var stacks_before: Dictionary = battle.get("_cost_stacks").duplicate()
	battle._generate_options()
	var stacks_after: Dictionary = battle.get("_cost_stacks")
	_check(_dicts_equal(stacks_before, stacks_after), "仅生成选项不累积叠层（选了才算）")

	# ---- D. 累积乘区 + 封顶换档 ----
	var c3: Dictionary = battle._pick_enemy_cost(3)
	_check(not c3.is_empty() and int(c3["tier"]) == 3, "首取档位 3 成功")
	battle._apply_enemy_cost(c3)
	var hp1: float = float(battle.enemy_cost_hp_mult())
	_check(_approx(hp1, 1.0 + float(c3["hp_mul"])),
		"取一次后 hp_mult %.4f == 1 + hp_mul %.2f" % [hp1, float(c3["hp_mul"])])
	for i in 2:
		battle._apply_enemy_cost(battle._pick_enemy_cost(3))
	# ⚠️ 乘法累积：n 层 = (1+hp_mul)^n，不是 1 + n×hp_mul（我自己第一次就写成了加法）
	_check(_approx(float(battle.enemy_cost_hp_mult()), pow(1.0 + float(c3["hp_mul"]), 3.0)),
		"取满 3 层后 hp_mult %.4f == (1+hp_mul)^3（乘法累积）" % float(battle.enemy_cost_hp_mult()))
	var c3_again: Dictionary = battle._pick_enemy_cost(3)
	_check(c3_again.is_empty() or int(c3_again["tier"]) != 3,
		"档位 3 封顶后再取会换档（拿到 %s）" % ("空" if c3_again.is_empty() else str(c3_again["tier"])))
	# 全档位打满 → 返回空（纯奖励兜底）
	for t in [1, 2, 3]:
		for i in int(_consts()["UPGRADE_ENEMY_COSTS"][t]["max_stacks"]):
			battle._apply_enemy_cost(battle._pick_enemy_cost(t))
	var none: Dictionary = battle._pick_enemy_cost(1)
	_check(none.is_empty(), "三档全部封顶后 _pick_enemy_cost 返回空（该卡退回纯奖励）")

	# ---- E. 端到端：乘区真的作用到敌人出生数值 ----
	battle._spawn_enemy("Slime", pl.global_position + Vector2(400.0, 0.0))
	var boosted: Node = battle.enemies[battle.enemies.size() - 1]
	var base_hp := float(_consts()["ENEMY_TEMPLATES"]["Slime"]["hp"])
	var wave_now := int(battle.wave_num)
	var expected := roundi(base_hp * float(_consts_call("hp_scale", [wave_now])) * float(battle.enemy_cost_hp_mult()))
	_check(absi(int(boosted.max_hp) - expected) <= TOL_ABS,
		"代价后生成的 Slime max_hp %d == 基础 %.0f × hp_scale × 累积乘区（期望 %d）" % [
			int(boosted.max_hp), base_hp, expected])

	# ---- F. 重开一局归零 ----
	battle.start_run()
	_check(_approx(float(battle.enemy_cost_hp_mult()), 1.0)
		and _approx(float(battle.enemy_cost_dmg_mult()), 1.0)
		and (battle.get("_cost_stacks") as Dictionary).is_empty(),
		"start_run 后代价状态全部归零（乘区 1.0 / 叠层空）")
	battle._spawn_enemy("Slime", pl.global_position + Vector2(400.0, 0.0))
	var clean: Node = battle.enemies[battle.enemies.size() - 1]
	var clean_expected := roundi(base_hp * float(_consts_call("hp_scale", [int(battle.wave_num)])))
	_check(absi(int(clean.max_hp) - clean_expected) <= TOL_ABS,
		"重开后 Slime max_hp %d == 无代价期望 %d（乘区确实回到 1.0）" % [
			int(clean.max_hp), clean_expected])

	_finish("")


func _consts_call(fn: String, args: Array) -> Variant:
	return _stats_inst.callv(fn, args) if _stats_inst != null else null


func _dicts_equal(a: Dictionary, b: Dictionary) -> bool:
	if a.size() != b.size():
		return false
	for k in a.keys():
		if not b.has(k) or int(a[k]) != int(b[k]):
			return false
	return true


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
