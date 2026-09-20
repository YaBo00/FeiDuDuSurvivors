extends SceneTree
## 新敌人批次验证探针（2026-09-20，门禁候选）。
##
## 覆盖接入说明 §3/§4/§6 的确定性断言：
##   A. 数据契约：9 新模板存在 / def 全 0 / behavior 正确；spawn_types 波次表；
##      boss_type_for_wave(10)=BossPUA、(20)=Boss
##   B. charger（卷王）：接近触发 → windup 锁向 → dash（沿锁定方向、吃 sfx）→ recover → approach
##   C. splitter（精神内耗）：致死 → 原位分裂 2 只 Rat（60% 血、不占波次名额、melee 不套娃）
##   D. bomber（班味炸弹）：80px 进引信（sfx）→ 2s 后对 90px 内玩家结算 dmg 并自灭；
##      引信中拉开到 160px 外取消
##   E. support（班长）：提速脉冲只作用 150px 内；治疗打给血量占比最低的友军
##   F. BossPUA：summon 出 2 只 Rat + 全场提速光环（1.3 / 3s）；temp_speed 取 max 不叠乘、到期回 1.0
##
## 冻结手法（与 _ProbePierce 同源）：state 锁 UPGRADE、玩家/敌人 set_physics_process(false)、
## 敌人由探针手动 _physics_process(DT) 步进；玩家 dodge=0 / iframe=0 保伤害确定性。
##
## 用法: godot --headless --path <项目> --script res://scripts/dev/_ProbeNewEnemies.gd
## 退出码 0=PASS 1=FAIL

const DT := 1.0 / 60.0

var battle: Node = null
var armed := false
var finished := false
var checks := 0
var fails: Array[String] = []
var sfx_events: Array = []          # 记录敌人发出的 sfx_requested
var aura_events: Array = []         # 记录 global_speed_aura
var summon_events: Array = []       # 记录 summon_requested


func _initialize() -> void:
	print("[PROBE] 载入 Battle.tscn")
	var packed: PackedScene = load("res://scenes/battle/Battle.tscn")
	if packed == null:
		_finish("Battle.tscn 加载失败")
		return
	battle = packed.instantiate()
	root.add_child(battle)


func _process(_delta: float) -> bool:
	if finished:
		return true
	if not armed:
		armed = true
		_run_all()
		return true
	return true


func _run_all() -> void:
	battle.start_run()
	battle.spawn_remaining = 0
	var st: Dictionary = battle.get("State")
	battle.state = int(st["UPGRADE"]) if st.has("UPGRADE") else 1
	var p: Node2D = battle.player
	p.set_physics_process(false)
	p.dodge = 0.0            # 伤害确定性
	p.invincible_timer = 0.0
	# 行为测试区清空建筑物（dash/位移断言不做撞墙分支 —— 墙检出另有实现但不在此测）
	battle.obstacle_rects.clear()
	# 开局已刷的怪标记死亡并清空（queue_free 延迟释放会污染网格，见 _ProbePierce）
	for e in battle.enemies:
		e.is_dead = true
	battle.enemies.clear()
	battle.combat.clear_grid()

	_test_templates()
	_test_charger(p)
	_test_splitter(p)
	_test_bomber(p)
	_test_support(p)
	_test_boss_pua(p)
	_test_temp_speed()
	_finish("")


# ================================================================ A. 数据契约
func _test_templates() -> void:
	var types := {
		"Rat": "melee", "Student": "melee", "Charger": "charger", "Ox": "melee",
		"Splitter": "splitter", "Bomber": "bomber", "Slacker": "ranged",
		"Monitor": "support", "BossPUA": "boss",
	}
	var bad := 0
	for t in types.keys():
		var d: Dictionary = GameStats.enemy_template(String(t))
		if String(d.get("behavior", "")) != String(types[t]):
			bad += 1
		if int(d.get("def", -1)) != 0:
			bad += 1
	_check(bad == 0, "A1: 9 个新模板 behavior 正确且 def 全 0（非法 %d）" % bad)
	_check(GameStats.spawn_types(1).has("Rat") and not GameStats.spawn_types(1).has("Student"),
		"A2: 第 1 波池含 Rat、不含 Student")
	_check(GameStats.spawn_types(3).has("Student"), "A3: 第 3 波池含 Student")
	_check(GameStats.spawn_types(5).has("Charger"), "A4: 第 5 波池含 Charger")
	_check(GameStats.spawn_types(6).has("Ox"), "A5: 第 6 波池含 Ox")
	_check(GameStats.spawn_types(7).has("Bomber"), "A6: 第 7 波池含 Bomber")
	_check(GameStats.spawn_types(8).has("Splitter"), "A7: 第 8 波池含 Splitter")
	_check(GameStats.spawn_types(9).has("Slacker"), "A8: 第 9 波池含 Slacker")
	_check(GameStats.spawn_types(10).has("Monitor"), "A9: 第 10 波池含 Monitor")
	_check(not GameStats.spawn_types(9).has("BossPUA"), "A10: 刷怪池不含 Boss（Boss 走独立波）")
	_check(GameStats.boss_type_for_wave(10) == "BossPUA"
		and GameStats.boss_type_for_wave(20) == "Boss",
		"A11: 第 10 波 Boss=BossPUA、第 20 波 Boss=袋鼠王")


# ================================================================ B. charger
func _test_charger(p: Node2D) -> void:
	var e := _make_frozen("Charger", p.global_position + Vector2(500.0, 0.0))
	_check(String(e.charger_state) == "approach", "B1: 初始状态 approach")
	_step(e, 2)   # 500px > 250px 触发距离 → 仍在接近
	_check(String(e.charger_state) == "approach", "B2: 500px 外保持 approach")
	_step(e, 2)   # 接近中（每帧 ~1.6px，仍在触发距离外）
	e.global_position = p.global_position + Vector2(240.0, 0.0)   # 进入触发距离
	_step(e, 1)
	_check(String(e.charger_state) == "windup", "B3: 240px 进入 windup")
	var locked: Vector2 = e._charger_dir
	_check(locked.length() > 0.9, "B4: windup 瞬间已锁定冲锋方向")
	# 前摇期间玩家横向跳走 —— 锁定方向不得改变
	p.global_position += Vector2(0.0, 120.0)
	_step_sec(e, GameStats.CHARGER_WINDUP_TIME)
	_check(String(e.charger_state) == "dash", "B5: 前摇结束进入 dash")
	_check(sfx_events.has("charger_dash"), "B6: dash 瞬间发出 charger_dash 音效")
	var dash_dir: Vector2 = e._charger_dir
	_check(dash_dir.distance_to(locked) < 0.001, "B7: 冲锋方向 = windup 锁定方向（不被玩家移动改写）")
	var pos_before: Vector2 = e.global_position
	_step_sec(e, GameStats.CHARGER_DASH_TIME)
	var moved: Vector2 = e.global_position - pos_before
	_check(moved.length() > 100.0, "B8: dash 实际位移显著（%.0fpx）" % moved.length())
	_check(String(e.charger_state) == "recover", "B9: dash 结束进入 recover")
	_step_sec(e, GameStats.CHARGER_RECOVER_TIME + DT)
	_check(String(e.charger_state) == "approach", "B10: 硬直结束回到 approach")
	_free_enemy(e)


# ================================================================ C. splitter
func _test_splitter(p: Node2D) -> void:
	var before: int = battle.enemies.size()
	var expect_hp: int = roundi(12.0 * GameStats.hp_scale(1) * GameStats.SPLITTER_CHILD_HP_MUL)
	var death_pos: Vector2 = p.global_position + Vector2(60.0, 0.0)
	battle._on_splitter_death(death_pos)
	var rats: Array = []
	for e in battle.enemies:
		if String(e.type_name) == "Rat":
			rats.append(e)
	_check(battle.enemies.size() == before + 2, "C1: 分裂恰好 +2 只敌人")
	_check(rats.size() == 2, "C2: 新增的 2 只都是 Rat")
	if rats.size() == 2:
		var ok_hp := true
		var ok_beh := true
		for r in rats:
			if int(r.max_hp) != expect_hp:
				ok_hp = false
			if String(r.behavior) != "melee":
				ok_beh = false
		_check(ok_hp, "C3: 小鼠 max_hp=%d == Rat 模板 × 波次曲线 × 0.6（期望 %d）" % [int(rats[0].max_hp), expect_hp])
		_check(ok_beh, "C4: 小鼠是普通 melee（不会分裂→再分裂）")
	# 小鼠再被打死 → 不再分裂（melee 无 split 信号路径）
	var n0: int = battle.enemies.size()
	for r in rats:
		r.take_damage(99999)
	_check(battle.enemies.size() == n0, "C5: 小鼠致死不再触发分裂（无套娃）")
	_cleanup_test_enemies()


# ================================================================ D. bomber
func _test_bomber(p: Node2D) -> void:
	sfx_events.clear()
	var hp0: float = float(p.hp)
	var e := _make_frozen("Bomber", p.global_position + Vector2(60.0, 0.0))
	_step(e, 1)
	_check(String(e.bomber_state) == "fuse", "D1: 60px 进入引信 fuse")
	_check(sfx_events.has("bomber_fuse"), "D2: 进引信发出 bomber_fuse 音效")
	_step_sec(e, GameStats.BOMBER_FUSE_TIME)
	_check(bool(e.is_dead), "D3: 引信结束自爆自灭（is_dead）")
	_check(float(p.hp) < hp0, "D4: 90px 内玩家被结算自爆伤害（%.0f → %.0f）" % [hp0, float(p.hp)])
	var took: int = int(hp0 - float(p.hp))
	_check(took == int(e.dmg), "D5: 自爆伤害 = 模板 dmg %d（实际 %d）" % [int(e.dmg), took])
	_cleanup_test_enemies()
	p.invincible_timer = 0.0   # 清掉上一炸的无敌帧，保证下一组确定性
	# 取消路径：进引信后玩家拉开到 200px
	var e2 := _make_frozen("Bomber", p.global_position + Vector2(60.0, 0.0))
	_step(e2, 1)
	_check(String(e2.bomber_state) == "fuse", "D6: 第二只同样进引信")
	e2.global_position = p.global_position + Vector2(200.0, 0.0)
	_step(e2, 1)
	_check(String(e2.bomber_state) == "chase", "D7: 玩家拉开到 200px → 引信取消回到追击")
	_step_sec(e2, GameStats.BOMBER_FUSE_TIME + DT)
	_check(not bool(e2.is_dead), "D8: 取消后不引爆")
	_cleanup_test_enemies()


# ================================================================ E. support
func _test_support(p: Node2D) -> void:
	var mon := _make_frozen("Monitor", p.global_position + Vector2(300.0, 0.0))
	var near1 := _make_frozen("Slime", mon.global_position + Vector2(100.0, 0.0))
	var near2 := _make_frozen("Slime", mon.global_position + Vector2(120.0, 40.0))
	var far := _make_frozen("Slime", mon.global_position + Vector2(300.0, 0.0))
	# 提速脉冲：只作用 150px 内
	battle._on_support_pulse(mon.global_position, false)
	_check(_f(float(near1.temp_speed_mul)) == 1.25 and _f(float(near2.temp_speed_mul)) == 1.25,
		"E1: 150px 内两只 Slime 获得 +25% 移速")
	_check(_f(float(far.temp_speed_mul)) == 1.0, "E2: 300px 外的 Slime 不受光环")
	# 多来源取 max 不叠乘
	near1.apply_temp_speed(1.25, 2.0)
	near1.apply_temp_speed(1.25, 2.0)
	_check(_f(float(near1.temp_speed_mul)) == 1.25, "E3: 重复施加取 max 不叠乘")
	_step_sec(near1, GameStats.SUPPORT_SPEED_DUR + DT)
	_check(_f(float(near1.temp_speed_mul)) == 1.0, "E4: 时效结束回 1.0")
	# 治疗脉冲：打给血量占比最低者（near1 打到 20%，near2 满血）
	near1.hp = float(near1.max_hp) * 0.2
	var hp_before: float = float(near1.hp)
	var expect: float = minf(float(near1.max_hp),
		hp_before + float(near1.max_hp) * GameStats.SUPPORT_HEAL_RATIO)
	battle._on_support_pulse(mon.global_position, true)
	_check(_f(float(near1.hp)) == _f(expect), "E5: 治疗打给占比最低者（+max_hp 5%）")
	_check(_f(float(near2.hp)) == _f(float(near2.max_hp)), "E6: 满血友军不溢出治疗")
	_check(_f(float(far.hp)) == _f(float(far.max_hp)), "E7: 范围外不治疗")
	_cleanup_test_enemies()


# ================================================================ F. BossPUA + 临时加速
func _test_boss_pua(p: Node2D) -> void:
	var t := GameStats.enemy_template("BossPUA")
	_check(String(t.get("summon_type", "")) == "Rat" and int(t.get("summon_count", 0)) == 2,
		"F1: BossPUA 模板召唤 2 只 Rat")
	_check(bool(t.has("summon_aura")), "F2: BossPUA 模板带群体加速光环")
	var before: int = battle.enemies.size()
	battle._on_boss_summon(p.global_position + Vector2(80.0, 0.0), "Rat", 2)
	_check(battle.enemies.size() == before + 2, "F3: 召唤落 2 只 Rat")
	var witness := _make_frozen("Slime", p.global_position + Vector2(-200.0, 0.0))
	var got := []
	witness.global_speed_aura.connect(func(mul: float, dur: float) -> void:
		got.append([mul, dur]))
	battle._on_global_speed_aura(1.3, 3.0)
	_check(_f(float(witness.temp_speed_mul)) == 1.3, "F4: 全场光环 +30% 移速已生效")
	_check(got.size() == 1 and _f(float(got[0][0])) == 1.3 and _f(float(got[0][1])) == 3.0,
		"F5: global_speed_aura 信号可被监听（1.3 / 3s）")
	_step_sec(witness, 3.0 + DT)
	_check(_f(float(witness.temp_speed_mul)) == 1.0, "F6: 3s 后光环到期回 1.0")
	_cleanup_test_enemies()


func _test_temp_speed() -> void:
	var e := _make_frozen("Slime", Vector2(300.0, 300.0))
	e.apply_temp_speed(1.25, 2.0)
	e.apply_temp_speed(1.3, 1.0)   # 更高倍率 + 更短时长
	_check(_f(float(e.temp_speed_mul)) == 1.3 and _f(float(e._temp_speed_t)) == _f(2.0),
		"G1: 双来源取 max 倍率 / max 时长")
	_step_sec(e, 2.0 + DT)
	_check(_f(float(e.temp_speed_mul)) == 1.0, "G2: 全部到期后回 1.0")
	_cleanup_test_enemies()


# ================================================================ 公用
## 生成一只冻结敌人（物理帧关掉，探针手动步进），并把它的信号接进观测记录。
func _make_frozen(type_name: String, pos: Vector2) -> Node2D:
	battle._spawn_enemy(type_name, pos)
	var e: Node2D = battle.enemies[battle.enemies.size() - 1]
	e.set_physics_process(false)
	if e.has_signal("sfx_requested"):
		e.sfx_requested.connect(func(n: String, _db: float, _p: float) -> void:
			sfx_events.append(n))
	if e.has_signal("global_speed_aura"):
		e.global_speed_aura.connect(func(m: float, d: float) -> void:
			aura_events.append([m, d]))
	if e.has_signal("summon_requested"):
		e.summon_requested.connect(func(pos: Vector2, t: String, c: int) -> void:
			summon_events.append([pos, t, c]))
	return e


func _free_enemy(e: Node2D) -> void:
	e.is_dead = true
	for i in range(battle.enemies.size() - 1, -1, -1):
		if battle.enemies[i] == e:
			battle.enemies.remove_at(i)
			break
	battle.combat.clear_grid()


## 测试组收尾：清空本组生成的敌人（标 is_dead + 清数组 + 清网格 + 还原玩家状态）
func _cleanup_test_enemies() -> void:
	for e in battle.enemies:
		e.is_dead = true
	battle.enemies.clear()
	battle.combat.clear_grid()
	var p: Node2D = battle.player
	p.invincible_timer = 0.0


## 手动步进 n 个物理帧
func _step(e: Node2D, n: int) -> void:
	for i in n:
		e._physics_process(DT)


## 手动步进 sec 秒（按 DT 折算帧数）
func _step_sec(e: Node2D, sec: float) -> void:
	_step(e, int(ceil(sec / DT)))


func _f(x: float) -> float:
	return snappedf(x, 0.001)


func _check(cond: bool, label: String) -> void:
	checks += 1
	if cond:
		print("[PROBE]   OK   %s" % label)
	else:
		fails.append(label)
		print("[PROBE]   FAIL %s" % label)


func _finish(msg: String) -> void:
	finished = true
	if msg != "":
		print("[PROBE] %s" % msg)
	print("[PROBE] 断言 %d/%d 通过" % [checks - fails.size(), checks])
	for f in fails:
		print("[PROBE]   - %s" % f)
	print("[PROBE] RESULT=%s" % ("PASS" if fails.is_empty() else "FAIL"))
	quit(0 if fails.is_empty() else 1)
