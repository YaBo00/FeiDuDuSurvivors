extends SceneTree
## 独立验证探针：远程怪开火 + 敌方弹道命中玩家 + Boss 配置与可击杀
##              +（T-BOSS-02 扩展）Boss 特殊技能状态机（扇形 / 冲锋 / 召唤）。
##
## 铁律 #11：无法从输出观察的修复，写独立探针做不可争议的证明。
## 本探针证明（全部确定性断言，不靠随机局面）：
##   A. 远程怪（behavior="ranged"）在保持距离时会开火（5 秒内 fired_enemy_proj ≥ 1）
##   B. 开火产生了敌方弹道（from_player == false）—— Battle._on_enemy_fired 接线生效
##   C. 近战怪（behavior="melee"）从不开火，且持续追击（距离单调下降）
##   D. 敌方弹道能命中静止玩家（dodge=0 的土豆 + 点射 + 无干扰 → hp 必降）
##      以及 Boss：behavior="boss"、厚血、头顶血条开启、take_damage 可正常击杀（无 NaN）
##
## 【T-BOSS-02 扩展：Boss 特殊技能（批次三）】依据冻结契约逐条验证：
##   Stats.gd 新常量：
##     BOSS_SKILL_ORDER: Array[String]（= ["fan","charge","summon"]，固定顺序、无随机）
##     BOSS_SKILL_WINDUP: Dictionary（每招前摇秒数，全部 > 0 —— 公平性底线）
##     BOSS_SKILL_RECOVER / BOSS_SKILL_INTERVAL
##     BOSS_FAN_COUNT(>=2) / BOSS_FAN_SPREAD_DEG(>0)
##     BOSS_CHARGE_SPEED / BOSS_CHARGE_DURATION(>0)
##     BOSS_SUMMON_TYPE / BOSS_SUMMON_COUNT(>=1)
##   Enemy.gd 新字段（探针直读）：
##     boss_skill_state("chase"/"windup"/"active"/"recover")、boss_skill_index(int)、
##     boss_skill_name(String)、boss_skill_used(Dictionary)、
##     boss_windup_left(float)、boss_charge_dir(Vector2，冲锋开始锁定、途中不变)
##   Enemy.gd 新信号：summon_requested(pos: Vector2, type_name: String, count: int)
##   可测性接缝：状态机推进只依赖传入 delta ⇒ set_physics_process(false) 之后
##     手动调用 _physics_process(dt) 做确定性驱动（不靠真实帧等待，见 B~E 组）。
##
## 断言分组（扩展段）：
##   A. 前摇合法性（静态，数值全部从常量推导，不硬编码）
##   B. 三招都会被触发 + 出招顺序严格按 BOSS_SKILL_ORDER 循环 + windup 单调递减
##      + boss_skill_index 按 size 取模递增
##   C. 扇形弹幕：某次 fan 的 active 恰好发射 BOSS_FAN_COUNT 发，
##      每发相对「Boss→目标」中轴的偏差 <= BOSS_FAN_SPREAD_DEG / 2
##   D. 冲锋：active 期间 boss_charge_dir 不被重写；单帧位移/dt ≈ BOSS_CHARGE_SPEED
##      （相对容差，见 _approx_rel —— 纯绝对容差在浮点累放下会误红）且 > 常规追击速度
##   E. 召唤：恰好 1 次 summon_requested，count == BOSS_SUMMON_COUNT、type == BOSS_SUMMON_TYPE
##   F. 对照组：同一驱动方式跑一只非 Boss（Slime）—— 状态恒不进 windup/active/recover、
##      boss_skill_used 为空、零 summon_requested、且仍朝目标移动（melee 行为未被破坏）。
##   G. 端到端（--selftest 波 10/20 遭遇 Boss）由门禁覆盖，本探针不重复跑 20 波（太慢）。
##
## ⚠️ 反射纪律（本工程已两次踩坑）：
##   · 新 GameStats 常量经 load().get_script_constant_map() 取 —— 静态引用未知常量
##     是解析期硬错误，会把本文件连同门禁一起拖成不可读的红。
##   · 新 Enemy 字段经【无类型句柄】e.get()/e.set() 取 —— 静态类型下缺失属性同样是解析期错误。
##   · 不用 GameStats.has_method("静态方法") 探测（同一解析错误）。
##   契约未落地时优雅打印「契约未就绪」并 RESULT=FAIL；一落地即可直接跑。
##
## 手法：直接调 battle._spawn_enemy()（与 _tick_spawn 同一条路径），
##       把怪放在 600px 外（> SPAWN_MIN_DIST=225，不会被重生挪位）。
##       点射测试前：关 autopilot（玩家静止）、杀光怪、清空敌方弹道、
##       静置 2 秒（> IFRAME_DURATION，无敌帧必过期）→ 排除一切歧义。
##       Boss 技能段：反射构造独立 Enemy（不挂 Battle，免波次干扰）+ 假目标 Node2D。
##
## 用法: godot --headless --path <项目> --script res://scripts/dev/_ProbeRangedBoss.gd
## 退出码 0=PASS 1=FAIL（门禁用 grep -q "RESULT=PASS" 判定）

const FAR_OFFSET := Vector2(600.0, 0.0)
const PHASE1_SECONDS := 5.0     # 远程怪首射窗口：1.5~2.5s，5s 足够宽
const QUIET_SECONDS := 2.0      # 静置等无敌帧过期
const HIT_WINDOW_SECONDS := 2.0 # 点射弹 60px / 420px/s ≈ 0.14s，2s 极宽

# ---- T-BOSS-02 扩展常量 ----
const TOL := 1e-4               # 浮点比较的绝对容差下限
const SKILL_DT := 1.0 / 60.0    # 确定性驱动的固定步长
const MAX_SKILL_SECONDS := 90.0 # Boss 技能观测硬上限（充足余量，足够跑完 4 次出招）
const CONTROL_SECONDS := 3.0    # 对照组 Slime 的驱动时长
const CHARGE_SPEED_REL := 0.05  # 冲锋速度的相对容差（5%，见 _approx_rel 注释）

var battle: Node = null
var armed := false
var finished := false
var phase := 0
var t_phase := 0.0

var ranged: Node = null
var slime: Node = null
var boss: Node = null

var ranged_fires := 0
var slime_fires := 0
var saw_enemy_proj := false
var slime_dist0 := -1.0
var hp_before_hit := -1.0
var _watch_next := 1.0
var _t_total := 0.0

# ---- T-BOSS-02 反射句柄与断言计数 ----
var _stats_script = null          # load("res://scripts/data/Stats.gd")，保持无类型走动态反射
var _stats = null                 # GameStats 实例（instance.call 静态方法，参照 _ProbeFloorTiles）
var _consts: Dictionary = {}      # GameStats 常量表（BOSS_SKILL_ORDER / BOSS_FAN_COUNT ...）

var _checks := 0                  # 扩展段断言计数（照 _ProbeFloorTiles 风格汇总）
var _fails: Array[String] = []

var _obs_exec := -1               # 回调挂到当前观察的出招序号（-1 = 尚未开始任何一招）
var _fired_events: Array = []     # {"exec", "pos", "dir", "dmg"}
var _summon_events: Array = []    # {"exec", "pos", "type", "count"}


func _initialize() -> void:
	print("[PROBE] ===== 远程怪 / 敌弹 / Boss 配置 / Boss 特殊技能（T-BOSS-02）=====")
	# --- 契约就绪守卫：全部走运行期反射，绝不静态引用未落地符号 ---
	_stats_script = load("res://scripts/data/Stats.gd")
	if _stats_script == null:
		_finish(false, "无法加载 res://scripts/data/Stats.gd")
		return
	_consts = _stats_script.get_script_constant_map()
	_stats = _stats_script.new()
	var missing := _contract_missing()
	if not missing.is_empty():
		_finish(false, "契约未就绪：缺少 %s（工程线未落地或被回退，探针按纪律优雅退出）" % str(missing))
		return
	print("[PROBE] 契约就绪：BOSS_SKILL_ORDER=%s，Enemy 技能字段 / summon_requested 信号齐全" % str(_consts["BOSS_SKILL_ORDER"]))

	print("[PROBE] 载入 Battle.tscn")
	var packed: PackedScene = load("res://scenes/battle/Battle.tscn")
	if packed == null:
		_finish(false, "Battle.tscn 加载失败")
		return
	battle = packed.instantiate()
	root.add_child(battle)
	print("[PROBE] Battle 已加入场景树，布置推迟到第一帧")


## 用运行期反射盘点契约符号（GameStats 常量 + Enemy 字段/信号）。返回缺失清单。
func _contract_missing() -> Array:
	var missing: Array = []
	for c in ["BOSS_SKILL_ORDER", "BOSS_SKILL_WINDUP", "BOSS_SKILL_RECOVER", "BOSS_SKILL_INTERVAL",
			"BOSS_FAN_COUNT", "BOSS_FAN_SPREAD_DEG", "BOSS_CHARGE_SPEED", "BOSS_CHARGE_DURATION",
			"BOSS_SUMMON_TYPE", "BOSS_SUMMON_COUNT"]:
		if not _consts.has(c):
			missing.append("GameStats.%s" % c)
	var pe = Enemy.new()   # 临时实例，只为读属性表；不入树
	for f in ["boss_skill_state", "boss_skill_index", "boss_skill_name", "boss_skill_used",
			"boss_windup_left", "boss_charge_dir"]:
		if not _has_prop(pe, f):
			missing.append("Enemy.%s" % f)
	if not pe.has_signal("summon_requested"):
		missing.append("Enemy.summon_requested")
	pe.free()
	return missing


func _arm() -> void:
	armed = true
	# 必须走正规开局：裸加载的 Battle wave_timer=0，第一帧就会触发波末
	# （无头模式升级面板自动跳过 → _start_next_wave → _free_all_enemies 清场）。
	battle.start_run()
	# 关闭波次刷怪：本探针只观测自己生成的怪，排除波内小怪干扰
	battle.spawn_remaining = 0
	var player: Node2D = battle.player
	# 站桩 + 缴械：autopilot 会追击并打死测试怪（实测 t=2 slime 即被杀）。
	# atk=0 后自动攻击照常开火，但 take_damage 对 <=0 直接忽略 → 测试怪必然存活到观测窗结束。
	player.autopilot = false
	player.atk = 0.0
	# 与 _tick_spawn 完全相同的生成路径
	battle._spawn_enemy("Ranged", player.global_position + FAR_OFFSET)
	battle._spawn_enemy("Slime", player.global_position + Vector2(FAR_OFFSET.x, -40.0))
	ranged = battle.enemies[battle.enemies.size() - 2]
	slime = battle.enemies[battle.enemies.size() - 1]
	ranged.fired_enemy_proj.connect(_on_ranged_fired)
	slime.fired_enemy_proj.connect(_on_slime_fired)
	slime_dist0 = slime.global_position.distance_to(player.global_position)
	print("[PROBE] 已生成 Ranged（behavior=%s）与 Slime（behavior=%s），距玩家 %.0fpx" % [
		String(ranged.behavior), String(slime.behavior), slime_dist0])
	if String(ranged.behavior) != "ranged":
		_finish(false, "Ranged 模板的 behavior 不是 ranged，行为路由不可能生效")
		return
	if not bool(ranged.show_health_bar):
		_finish(false, "Ranged 怪没开头顶血条")
		return
	if is_nan(float(ranged.hp)) or is_nan(float(slime.hp)):
		_finish(false, "敌人 hp 出现 NaN —— 触碰了 H5 缺陷红线")
		return


func _on_ranged_fired(_pos: Vector2, _dir: float, _dmg: int) -> void:
	ranged_fires += 1


func _on_slime_fired(_pos: Vector2, _dir: float, _dmg: int) -> void:
	slime_fires += 1


# ---- T-BOSS-02 观测回调：把信号归到当时的出招序号 ----
## 关键：fan/summon 的 active 是【同帧原子招式】（_start_active 内发完立即收招），
## 步后采样永远看不到 "active" 态。但回调触发时 _start_active 已把状态置为 active、
## 还没收招 —— 所以在这里用绑定的源对象读一次 boss_skill_state，
## 就是「windup 确实转入了 active」的不可争议的观测点。
func _on_obs_fired(pos: Vector2, dir: float, dmg: int, src: Object) -> void:
	_fired_events.append({"exec": _obs_exec, "pos": pos, "dir": dir, "dmg": dmg,
		"state": String(src.get("boss_skill_state"))})


func _on_obs_summon(pos: Vector2, type_name: String, count: int, src: Object) -> void:
	_summon_events.append({"exec": _obs_exec, "pos": pos, "type": type_name, "count": count,
		"state": String(src.get("boss_skill_state"))})


func _process(delta: float) -> bool:
	if finished:
		return true
	if not armed:
		_arm()
		if finished:
			return true
		return false

	t_phase += delta
	_t_total += delta
	# 看门狗：逐秒打印状态，定位「谁被释放」的时刻
	if _t_total >= _watch_next:
		_watch_next += 1.0
		var pl: Node2D = battle.player
		var n_alive := 0
		for e in battle.enemies:
			if is_instance_valid(e) and not bool(e.is_dead):
				n_alive += 1
		print("[WATCH] t=%.0f state=%s player_valid=%s hp=%.0f enemies_alive=%d ranged_valid=%s slime_valid=%s projs=%d" % [
			_t_total, str(battle.state), str(is_instance_valid(pl)),
			(float(pl.hp) if is_instance_valid(pl) else -1.0),
			n_alive, str(is_instance_valid(ranged)), str(is_instance_valid(slime)),
			battle.projectiles.size()])
	match phase:
		0:
			_tick_phase1()
		1:
			_tick_phase2_quiet()
		2:
			_tick_phase3_wait_hit()
		3:
			_tick_phase4_boss()
	return false


## 阶段 1：远程怪开火观测（5 秒）
func _tick_phase1() -> void:
	for proj in battle.projectiles:
		if not proj.from_player:
			saw_enemy_proj = true
			break
	if t_phase >= PHASE1_SECONDS:
		if not is_instance_valid(ranged) or not is_instance_valid(slime):
			_finish(false, "测试怪在观测窗内被外力清掉（应为玩家误伤，检查缴械是否生效）")
			return
		if ranged_fires < 1:
			_finish(false, "远程怪 %.0f 秒内从未开火（fired_enemy_proj 未触发）" % PHASE1_SECONDS)
			return
		if not saw_enemy_proj:
			_finish(false, "远程怪开了火但 battle.projectiles 里没有敌方弹道 → _on_enemy_fired 接线失效")
			return
		if slime_fires != 0:
			_finish(false, "近战怪不该开火（Slime 发射了 %d 次）" % slime_fires)
			return
		var d_now: float = slime.global_position.distance_to(battle.player.global_position)
		if d_now >= slime_dist0:
			_finish(false, "近战怪没有追击玩家（%.0f → %.0f）" % [slime_dist0, d_now])
			return
		print("[PROBE] A/B/C ✓ 远程怪开火 %d 次、敌方弹道已入列、近战 0 开火且距离 %.0f→%.0f" % [
			ranged_fires, slime_dist0, d_now])
		# 进入静置阶段：杀光怪（走 is_dead 正规路径）、关 autopilot、清敌方弹道
		ranged.is_dead = true
		slime.is_dead = true
		battle.player.autopilot = false
		var keep: Array[Projectile] = []
		for proj in battle.projectiles:
			if proj.from_player:
				keep.append(proj)
			else:
				proj.queue_free()
		battle.projectiles = keep
		phase = 1
		t_phase = 0.0


## 阶段 2：静置 2 秒（无敌帧过期、尸体被 _cleanup_enemies 回收、场上无任何伤害源）
func _tick_phase2_quiet() -> void:
	if t_phase >= QUIET_SECONDS:
		hp_before_hit = float(battle.player.hp)
		# 点射：在玩家右侧 60px 朝玩家打一发 5 伤敌弹。
		# 玩家静止 + dodge=0（土豆基础值）+ 场上无其它伤害源 → 必然命中。
		battle._on_enemy_fired(battle.player.global_position + Vector2(60.0, 0.0), PI, 5)
		print("[PROBE] 已点射（hp0=%.0f），等待命中" % hp_before_hit)
		phase = 2
		t_phase = 0.0


## 阶段 3：等点射命中（hp 必须下降）
func _tick_phase3_wait_hit() -> void:
	if float(battle.player.hp) < hp_before_hit:
		print("[PROBE] D ✓ 敌方弹道命中玩家：hp %.0f → %.0f" % [hp_before_hit, float(battle.player.hp)])
		phase = 3
		t_phase = 0.0
	elif t_phase >= HIT_WINDOW_SECONDS:
		_finish(false, "点射 %.0f 秒仍未命中静止玩家（dodge=0）→ 敌弹命中判定失效" % HIT_WINDOW_SECONDS)


## 阶段 4：Boss 配置与可击杀（原有断言）→ 接着跑 T-BOSS-02 技能套件
func _tick_phase4_boss() -> void:
	if not GameStats.is_boss_wave(10) or not GameStats.is_boss_wave(20):
		_finish(false, "is_boss_wave 没把 10/20 认成 Boss 波")
		return
	if GameStats.is_boss_wave(9) or GameStats.is_boss_wave(21):
		_finish(false, "is_boss_wave 误报非 Boss 波")
		return
	battle._spawn_enemy("Boss", battle.player.global_position + Vector2(FAR_OFFSET.x, 120.0))
	boss = battle.enemies[battle.enemies.size() - 1]
	if String(boss.behavior) != "boss":
		_finish(false, "Boss 的 behavior 不是 boss")
		return
	if boss.max_hp < 500:
		_finish(false, "Boss 血量异常（%d < 500）" % int(boss.max_hp))
		return
	if not bool(boss.show_health_bar):
		_finish(false, "Boss 没开头顶血条")
		return
	var lethal: bool = boss.take_damage(999999)
	if not lethal or not bool(boss.is_dead) or is_nan(float(boss.hp)):
		_finish(false, "Boss 无法被击杀或 hp 异常 → 触碰「敌人打不死」红线")
		return
	print("[PROBE] E ✓ Boss 波路由正确、Boss behavior/血量/血条就绪、take_damage 可击杀（无 NaN）")
	_run_boss_skill_suite()


# ================================================================
# T-BOSS-02：Boss 特殊技能确定性套件（A~F）
# ================================================================
func _run_boss_skill_suite() -> void:
	print("[PROBE] === T-BOSS-02：Boss 特殊技能（A~F，确定性驱动）===")
	var order: Array = _consts["BOSS_SKILL_ORDER"]
	var osize := order.size()

	# ---------------- A. 前摇合法性（纯静态，数值全部从常量推导）----------------
	print("[PROBE] --- A. 前摇合法性（静态）---")
	_check(order.size() == 3, "BOSS_SKILL_ORDER 恰含 3 招（实际 %d）" % order.size())
	var uniq := {}
	for n in order:
		uniq[String(n)] = true
	_check(uniq.size() == order.size(), "BOSS_SKILL_ORDER 无重复（唯一 %d 个 / 共 %d 个）" % [uniq.size(), order.size()])
	for need in ["fan", "charge", "summon"]:
		_check(order.has(need), "BOSS_SKILL_ORDER 含 '%s'" % need)
	var windup: Dictionary = _consts["BOSS_SKILL_WINDUP"]
	for n in order:
		var key := String(n)
		_check(windup.has(key), "BOSS_SKILL_WINDUP 覆盖 '%s'" % key)
		if windup.has(key):
			_check(float(windup[key]) > 0.0, "前摇 windup['%s'] = %.3f > 0（公平性底线）" % [key, float(windup[key])])
	_check(int(_consts["BOSS_FAN_COUNT"]) >= 2, "BOSS_FAN_COUNT = %d >= 2" % int(_consts["BOSS_FAN_COUNT"]))
	_check(float(_consts["BOSS_FAN_SPREAD_DEG"]) > 0.0, "BOSS_FAN_SPREAD_DEG = %.2f > 0" % float(_consts["BOSS_FAN_SPREAD_DEG"]))
	_check(int(_consts["BOSS_SUMMON_COUNT"]) >= 1, "BOSS_SUMMON_COUNT = %d >= 1" % int(_consts["BOSS_SUMMON_COUNT"]))
	_check(float(_consts["BOSS_CHARGE_DURATION"]) > 0.0, "BOSS_CHARGE_DURATION = %.3f > 0" % float(_consts["BOSS_CHARGE_DURATION"]))

	# ---------------- B~E. 确定性驱动一只独立 Boss ----------------
	print("[PROBE] --- B~E. 确定性驱动 Boss（手推 _physics_process，dt=1/60，不靠真实帧）---")
	var dt := SKILL_DT
	var fake := Node2D.new()
	root.add_child(fake)
	fake.global_position = Vector2.ZERO
	var e := _make_reflect_enemy("Boss", Vector2(400.0, 0.0), fake)
	_check(not bool(e.get("is_dead")), "反射构造的独立 Boss 已就绪（behavior=%s hp=%d）" % [
		String(e.get("behavior")), int(e.get("hp"))])

	_fired_events.clear()
	_summon_events.clear()
	if e.has_signal("fired_enemy_proj"):
		e.connect("fired_enemy_proj", Callable(self, "_on_obs_fired").bind(e))
	if e.has_signal("summon_requested"):
		e.connect("summon_requested", Callable(self, "_on_obs_summon").bind(e))

	# 每次出招的观测记录：进入 windup 即开一条
	var execs: Array = []
	var cur_i := -1
	var max_steps := int(MAX_SKILL_SECONDS / dt)
	var charge_dir := Vector2.ZERO
	var charge_frames := 0
	var charge_stable := true
	var charge_speeds: Array = []
	var step := 0
	while step < max_steps:
		var st_before := String(e.get("boss_skill_state"))
		var pos_before: Vector2 = e.get("global_position")
		_obs_exec = cur_i
		e.call("_physics_process", dt)
		step += 1
		var st_after := String(e.get("boss_skill_state"))
		var skill_after := String(e.get("boss_skill_name"))
		var pos_after: Vector2 = e.get("global_position")

		# 检测「进入 windup」= 新的一次出招开始（任何非 windup 态 → windup 都算）
		if st_before != "windup" and st_after == "windup":
			cur_i += 1
			execs.append({
				"name": skill_after,
				"index": int(e.get("boss_skill_index")),
				"windups": [],
				"saw_active": false,
				"left_to": "",
				"charge_frames": 0,
				"charge_stable": true,
				"charge_speeds": [],
			})
			charge_dir = Vector2.ZERO
			charge_frames = 0
			charge_stable = true
			charge_speeds = []

		if st_after == "windup" and cur_i >= 0:
			var wl: Array = execs[cur_i]["windups"]
			wl.append(float(e.get("boss_windup_left")))

		# 离开 windup 的去向：charge 落在 active（占时间），原子招式当步直达 recover
		if st_before == "windup" and st_after != "windup" and cur_i >= 0:
			execs[cur_i]["left_to"] = st_after

		if st_after == "active" and cur_i >= 0:
			execs[cur_i]["saw_active"] = true
			if skill_after == "charge":
				var cd: Vector2 = e.get("boss_charge_dir")
				if charge_frames == 0:
					charge_dir = cd        # 进入 charge active 的那一刻锁定基准方向
				elif not cd.is_equal_approx(charge_dir):
					charge_stable = false  # 途中被重写 → 违约
				charge_frames += 1
				if st_before == "active":
					# 纯冲锋帧（前后都在 active）：位移/dt 即实际速度
					charge_speeds.append((pos_after - pos_before).length() / dt)
			execs[cur_i]["charge_frames"] = charge_frames
			execs[cur_i]["charge_stable"] = charge_stable
			execs[cur_i]["charge_speeds"] = charge_speeds

		# 观察到 4 次出招（3 招 + 1 次循环回绕）即可收工；前 3 招完整、第 4 招只验名字/序号
		if execs.size() >= osize + 1:
			break

	# ---------------- B. 三招触发 / 顺序 / 前摇推进 ----------------
	print("[PROBE] --- B. 三招触发 / 顺序 / 前摇推进 ---")
	_check(execs.size() >= osize, "观察到 >= %d 次出招（实际 %d，观测窗 %.0fs）" % [osize, execs.size(), MAX_SKILL_SECONDS])
	# 原子招式（fan/summon）的 active 只存在于步内：以【效果回调触发瞬间】读到的
	# boss_skill_state == "active" 作为「windup → active」的观测证据。
	for i in execs.size():
		var eff_active := false
		for f in _fired_events:
			if int(f["exec"]) == i and String(f.get("state", "")) == "active":
				eff_active = true
		for sm2 in _summon_events:
			if int(sm2["exec"]) == i and String(sm2.get("state", "")) == "active":
				eff_active = true
		if eff_active:
			execs[i]["saw_active"] = true
	for i in execs.size():
		var ex: Dictionary = execs[i]
		var nm := String(ex["name"])
		var want := String(order[i % osize])
		_check(nm == want, "第 %d 次出招严格按 BOSS_SKILL_ORDER 循环：'%s'（期望 '%s'）" % [i, nm, want])
		_check(int(ex["index"]) == i % osize, "第 %d 次出招 boss_skill_index=%d == i%%size=%d（按 size 取模递增）" % [
			i, int(ex["index"]), i % osize])
		if i < osize:
			var ws: Array = ex["windups"]
			_check(ws.size() >= 1, "第 %d 招（%s）windup 期有采样" % [i, nm])
			if ws.size() >= 1:
				_check(float(ws[0]) > 0.0, "第 %d 招 windup 初值 %.4f > 0" % [i, float(ws[0])])
				_check(float(ws[ws.size() - 1]) > 0.0, "第 %d 招 windup 末值 %.4f > 0（退出前恒为正）" % [i, float(ws[ws.size() - 1])])
				var mono := true
				for k in range(1, ws.size()):
					if float(ws[k]) > float(ws[k - 1]) + 1e-6:
						mono = false
						break
				_check(mono, "第 %d 招 boss_windup_left 单调递减（%d 帧采样）" % [i, ws.size()])
			var left_to := String(ex["left_to"])
			_check(left_to == "active" or left_to == "recover",
				"第 %d 招（%s）windup 结束后去向 '%s' ∈ {active, recover}（绝不回 chase/windup）" % [i, nm, left_to])
			_check(bool(ex["saw_active"]), "第 %d 招（%s）确实进入过 active 态（采样或效果回调内观测）" % [i, nm])
	var used: Dictionary = e.get("boss_skill_used")
	for need in ["fan", "charge", "summon"]:
		_check(used.has(need) and int(used[need]) >= 1, "boss_skill_used['%s'] >= 1（实际 %s）" % [need, str(used.get(need, "缺失"))])

	# ---------------- C. 扇形弹幕 ----------------
	print("[PROBE] --- C. 扇形弹幕 ---")
	var fan_i := _exec_index_of(execs, "fan")
	_check(fan_i >= 0, "已观察到 fan 出招")
	var fan_shots: Array = []
	if fan_i >= 0:
		for f in _fired_events:
			if int(f["exec"]) == fan_i:
				fan_shots.append(f)
	_check(fan_shots.size() == int(_consts["BOSS_FAN_COUNT"]),
		"某次 fan 的 active 阶段发射 %d 发 == BOSS_FAN_COUNT %d" % [fan_shots.size(), int(_consts["BOSS_FAN_COUNT"])])
	var half := deg_to_rad(float(_consts["BOSS_FAN_SPREAD_DEG"])) * 0.5
	var worst := 0.0
	for f in fan_shots:
		# 中轴 = 发射瞬间 Boss 位置 → 目标 的方向（信号携带的 pos 即出膛点）
		var axis := (fake.global_position - (f["pos"] as Vector2)).angle()
		var devc := absf(angle_difference(axis, float(f["dir"])))
		worst = maxf(worst, devc)
		_check(devc <= half + TOL, "扇形弹偏角 %.2f° <= 半张角 %.2f°（BOSS_FAN_SPREAD_DEG/2）" % [
			rad_to_deg(devc), rad_to_deg(half)])
	if not fan_shots.is_empty():
		print("[PROBE]   扇形最大偏角 %.2f°（半张角 %.2f°，%d 发）" % [rad_to_deg(worst), rad_to_deg(half), fan_shots.size()])

	# ---------------- D. 冲锋 ----------------
	print("[PROBE] --- D. 冲锋 ---")
	var charge_i := _exec_index_of(execs, "charge")
	_check(charge_i >= 0, "已观察到 charge 出招")
	if charge_i >= 0:
		_check(bool(execs[charge_i]["charge_stable"]), "冲锋期间 boss_charge_dir 不被重写（全程方向不变）")
		var cs: Array = execs[charge_i]["charge_speeds"]
		_check(cs.size() >= 1, "冲锋 active 期有单帧速度采样（%d 帧）" % cs.size())
		var expect_spd := float(_consts["BOSS_CHARGE_SPEED"])
		var base_spd := float(_stats.call("enemy_speed", "Boss"))
		_check(expect_spd > base_spd, "BOSS_CHARGE_SPEED %.1f > Boss 常规追击速度 %.1f" % [expect_spd, base_spd])
		var all_spd_ok := cs.size() >= 1
		for v in cs:
			if not _approx_rel(float(v), expect_spd, CHARGE_SPEED_REL):
				all_spd_ok = false
		_check(all_spd_ok, "冲锋单帧位移/dt ≈ BOSS_CHARGE_SPEED %.1f（相对容差 %.0f%%，%d 采样）" % [
			expect_spd, CHARGE_SPEED_REL * 100.0, cs.size()])

	# ---------------- E. 召唤 ----------------
	print("[PROBE] --- E. 召唤 ---")
	var summon_i := _exec_index_of(execs, "summon")
	_check(summon_i >= 0, "已观察到 summon 出招")
	var sm: Array = []
	if summon_i >= 0:
		for s in _summon_events:
			if int(s["exec"]) == summon_i:
				sm.append(s)
	_check(sm.size() == 1, "summon 恰好发出 1 次 summon_requested（实际 %d）" % sm.size())
	if sm.size() >= 1:
		_check(int(sm[0]["count"]) == int(_consts["BOSS_SUMMON_COUNT"]),
			"summon count=%d == BOSS_SUMMON_COUNT %d" % [int(sm[0]["count"]), int(_consts["BOSS_SUMMON_COUNT"])])
		_check(String(sm[0]["type"]) == String(_consts["BOSS_SUMMON_TYPE"]),
			"summon type_name='%s' == BOSS_SUMMON_TYPE '%s'" % [String(sm[0]["type"]), String(_consts["BOSS_SUMMON_TYPE"])])

	# ---------------- F. 对照组（证明上面的断言不是空转）----------------
	print("[PROBE] --- F. 对照组（非 Boss，同套驱动）---")
	var s := _make_reflect_enemy("Slime", Vector2(400.0, 0.0), fake)
	_fired_events.clear()
	_summon_events.clear()
	_obs_exec = -1
	if s.has_signal("fired_enemy_proj"):
		s.connect("fired_enemy_proj", Callable(self, "_on_obs_fired").bind(s))
	if s.has_signal("summon_requested"):
		s.connect("summon_requested", Callable(self, "_on_obs_summon").bind(s))
	var d0 := (s.get("global_position") as Vector2).distance_to(fake.global_position)
	var casting := false
	var last_state := ""
	var c_steps := int(CONTROL_SECONDS / dt)
	for _i in c_steps:
		s.call("_physics_process", dt)
		last_state = String(s.get("boss_skill_state"))
		if last_state == "windup" or last_state == "active" or last_state == "recover":
			casting = true
	var d1 := (s.get("global_position") as Vector2).distance_to(fake.global_position)
	var used_s: Dictionary = s.get("boss_skill_used")
	_check(not casting, "对照组从未进入 windup/active/recover（末态 '%s'）" % last_state)
	_check(used_s.is_empty(), "对照组 boss_skill_used 为空（实际 %s）" % str(used_s))
	_check(_summon_events.is_empty(), "对照组未发出 summon_requested（实际 %d 次）" % _summon_events.size())
	_check(d1 < d0, "对照组仍朝目标移动（melee 原行为未被破坏）：%.1f -> %.1f" % [d0, d1])

	# ---------------- 汇总 ----------------
	# 清理反射测试节点（避免退出时 ObjectDB 泄漏警告污染门禁输出）
	e.queue_free()
	s.queue_free()
	fake.queue_free()
	print("[PROBE] --------------------------------------------------")
	print("[PROBE] T-BOSS-02 断言 %d/%d 通过（失败 %d）" % [_checks - _fails.size(), _checks, _fails.size()])
	for f in _fails:
		print("[PROBE]   - %s" % f)
	_finish(_fails.is_empty(), "Boss 特殊技能（扇形 / 冲锋 / 召唤）确定性验证完成")


# ================================================================ 工具
## 反射构造一只独立测试怪：喂一个占位 Sprite 子节点（@onready $Sprite 不再报
## "Node not found"），挂到树、setup、指目标、关引擎调度改手推。
func _make_reflect_enemy(p_type: String, pos: Vector2, tgt: Node2D) -> Node:
	var e = Enemy.new()
	var spr := AnimatedSprite2D.new()
	spr.name = "Sprite"
	e.add_child(spr)
	root.add_child(e)
	e.call("setup", p_type, 10, pos)
	e.set("target", tgt)
	# 可测性接缝：关掉引擎调度，改为探针手动步进（状态机只依赖传入 delta）
	e.call("set_physics_process", false)
	return e


## 判断对象是否拥有某属性（运行期反射，避开解析期硬错误）
func _has_prop(obj: Object, pname: String) -> bool:
	for p in obj.get_property_list():
		if String(p["name"]) == pname:
			return true
	return false


func _exec_index_of(execs: Array, nm: String) -> int:
	for i in execs.size():
		if String(execs[i]["name"]) == nm:
			return i
	return -1


## 浮点比较：绝对容差下限 + 相对项。
## 为什么必须带相对项：冲锋速度 / 弹道角这类量，纯绝对容差在不同量纲下
## 要么过松漏掉真实偏差、要么过紧被 float32 舍入误红（_ProbeFloorTiles._approx 同款教训）。
func _approx_rel(a: float, b: float, rel: float) -> bool:
	return absf(a - b) <= maxf(TOL, rel * maxf(absf(a), absf(b)))


func _check(cond: bool, label: String) -> void:
	_checks += 1
	if cond:
		print("[PROBE]   OK   %s" % label)
	else:
		_fails.append(label)
		print("[PROBE]   FAIL %s" % label)


func _finish(ok: bool, msg: String) -> void:
	finished = true
	print("[PROBE] %s" % msg)
	print("[PROBE] RESULT=%s" % ("PASS" if ok else "FAIL"))
	quit(0 if ok else 1)
