extends SceneTree
## 武器进化·第二形态验证探针（2026-09-20，门禁 [27]）。
##
## 验证 WEAPON_EVOLUTIONS 六把武器的形态特性真的接进了射击链路：
##   A. 形态表：6 角色 / potato 溅射参数 / 未知角色空表
##   B. basic「连珠·二重奏」：弹道数 1 → 2（shots +1）；未进化 form 为空
##   C. study「贯穿书写」：逐弹道 pierce_cap 1 → 3
##   D. finance「贪婪回馈」：gold_on_hit 0.12 → 0.20
##   E. sad「暗影汲取」：弹道吸血 0.08 → 0.14
##   F. kangaroo「残影连拳」：attack_interval 按 rate_mul+0.35 收紧
##   H. weapon_mastery 升级链：第 6 层触发进化（apply_upgrade 集成路径）
##   G. potato「爆裂薯块」：aoe 字段接线 + 溅射只打圈内其他敌人 + 逐弹去重不重复扣血
##   I. 进化弹道视觉（2026-09-20 美术回投）：*_evo 键 + 进化态优先 / 未登记回落 + 新星环
##   J. 弹道数无上限 + 扇面封顶压缩（2026-09-20 用户需求）：5 条旧行为不变 / 8·12 条压缩间隔
##
## 冻结手法（与 _ProbePierce 同源）：start_run() 后把 state 冻在 UPGRADE，
## 玩家/敌人 set_physics_process(false)，弹道只由本探针手动 process_projectiles 驱动；
## crit=0（player_damage 无暴击 ⇒ 伤害确定性）、敌人 def=0（免疫减伤项）。
##
## 用法: godot --headless --path <项目> --script res://scripts/dev/_ProbeWeaponEvolution2.gd
## 退出码 0=PASS 1=FAIL

const DT := 1.0 / 60.0
const ENEMY_HP := 1000.0

var battle: Node = null
var armed := false
var finished := false
var checks := 0
var fails: Array[String] = []


func _initialize() -> void:
	print("[PROBE] 载入 Battle.tscn")
	var packed: PackedScene = load("res://scenes/battle/Battle.tscn")
	if packed == null:
		_finish(false, "Battle.tscn 加载失败")
		return
	battle = packed.instantiate()
	root.add_child(battle)


func _process(_delta: float) -> bool:
	if finished:
		return true
	if not armed:
		armed = true
		_run_all()
		return true   # _run_all 内部已 _finish（quit），直接退主循环
	return true


# ================================================================ 测试主体

func _run_all() -> void:
	battle.start_run()
	battle.spawn_remaining = 0
	# 冻结在 UPGRADE：Battle._physics_process 的 _tick_fighting 分支不再跑
	var st: Dictionary = battle.get("State")
	battle.state = int(st["UPGRADE"]) if st.has("UPGRADE") else 1
	var p: Node2D = battle.player
	p.set_physics_process(false)
	battle.combat.reset()

	_test_table()
	_test_basic_shots(p)
	_test_study_pierce(p)
	_test_finance_gold(p)
	_test_sad_lifesteal(p)
	_test_kangaroo_rate(p)
	_test_upgrade_chain(p)
	_test_potato_splash(p)
	_test_proj_spread(p)
	_test_evo_visuals(p)
	_finish(true, "")


## A. 形态表本体
func _test_table() -> void:
	_check(GameStats.WEAPON_EVOLUTIONS.size() == 6,
		"A1: WEAPON_EVOLUTIONS 表共 6 把武器（实际 %d）" % GameStats.WEAPON_EVOLUTIONS.size())
	var pf: Dictionary = GameStats.weapon_evolution("potato")
	_check(_approx(float(pf.get("aoe_radius", -1.0)), 90.0)
		and _approx(float(pf.get("aoe_pct", -1.0)), 0.40),
		"A2: potato 形态「爆裂薯块」溅射参数 90px / 40%%")
	var bf: Dictionary = GameStats.weapon_evolution("basic")
	_check(int(bf.get("shots", 0)) == 1 and String(bf.get("name", "")) == "连珠·二重奏",
		"A3: basic 形态「连珠·二重奏」shots=1")
	_check(GameStats.weapon_evolution("unknown_char").is_empty(),
		"A4: 未知角色形态查表返回空字典")


## 清空场上弹道（deferred 释放，不在数组里就不会再被结算）
func _clear_projectiles() -> void:
	for pr in battle.projectiles:
		pr.queue_free()
	battle.projectiles.clear()


## B. basic 连珠·二重奏：弹道数 1 → 2
func _test_basic_shots(p: Node2D) -> void:
	p.apply_character("basic")
	p.weapon_level = 0
	p.weapon_evolved = false
	p.recalc_stats()
	_check(p.weapon_form().is_empty(), "B1: 未进化时 weapon_form() 为空字典")
	var c0: int = battle.projectiles.size()
	battle.combat.on_player_fired(p.global_position + Vector2(100.0, 0.0), 1)
	var n0: int = battle.projectiles.size() - c0
	_check(n0 == 1, "B2: 未进化基线 1 发（base_shots 1 + proj 1 − 1，实际 %d 发）" % n0)
	var baseline_ok := true
	for i in range(c0, battle.projectiles.size()):
		var pr: Projectile = battle.projectiles[i]
		if pr.aoe_radius != 0.0 or pr.aoe_pct != 0.0:
			baseline_ok = false
	_check(baseline_ok, "B3: 未进化弹道 aoe 字段全 0（无溅射，旧基线）")
	_clear_projectiles()
	p.weapon_evolved = true
	p.recalc_stats()
	var c1: int = battle.projectiles.size()
	battle.combat.on_player_fired(p.global_position + Vector2(100.0, 0.0), 1)
	var n1: int = battle.projectiles.size() - c1
	_check(n1 == 2, "B4: 连珠·二重奏进化后弹道数 1 → 2（实际 %d 发）" % n1)
	_clear_projectiles()


## C. study 贯穿书写：逐弹道 pierce_cap 1 → 3
func _test_study_pierce(p: Node2D) -> void:
	p.apply_character("study")
	p.weapon_level = 0
	p.weapon_evolved = false
	p.recalc_stats()
	battle.combat.on_player_fired(p.global_position + Vector2(100.0, 0.0), 1)
	var pr0: Projectile = battle.projectiles[battle.projectiles.size() - 1]
	_check(pr0.pierce_cap == 1, "C1: 未进化 pierce_cap = 1（武器表值）")
	_clear_projectiles()
	p.weapon_evolved = true
	p.recalc_stats()
	battle.combat.on_player_fired(p.global_position + Vector2(100.0, 0.0), 1)
	var pr1: Projectile = battle.projectiles[battle.projectiles.size() - 1]
	_check(pr1.pierce_cap == 3, "C2: 贯穿书写 pierce_cap 1 → 3（+2，实际 %d）" % pr1.pierce_cap)
	_clear_projectiles()


## D. finance 贪婪回馈：gold_on_hit 0.12 → 0.20
func _test_finance_gold(p: Node2D) -> void:
	p.apply_character("finance")
	p.weapon_level = 0
	p.weapon_evolved = false
	p.recalc_stats()
	battle.combat.on_player_fired(p.global_position + Vector2(100.0, 0.0), 1)
	var pr0: Projectile = battle.projectiles[battle.projectiles.size() - 1]
	_check(_approx(pr0.gold_on_hit, 0.12), "D1: 未进化 gold_on_hit = 0.12（金币镖）")
	_clear_projectiles()
	p.weapon_evolved = true
	p.recalc_stats()
	battle.combat.on_player_fired(p.global_position + Vector2(100.0, 0.0), 1)
	var pr1: Projectile = battle.projectiles[battle.projectiles.size() - 1]
	_check(_approx(pr1.gold_on_hit, 0.20),
		"D2: 贪婪回馈 gold_on_hit 0.12 → 0.20（实际 %.3f）" % pr1.gold_on_hit)
	_clear_projectiles()


## E. sad 暗影汲取：弹道吸血 0.08 → 0.14
func _test_sad_lifesteal(p: Node2D) -> void:
	p.apply_character("sad")
	p.weapon_level = 0
	p.weapon_evolved = false
	p.recalc_stats()
	battle.combat.on_player_fired(p.global_position + Vector2(100.0, 0.0), 1)
	var pr0: Projectile = battle.projectiles[battle.projectiles.size() - 1]
	_check(_approx(pr0.lifesteal, 0.08), "E1: 未进化弹道吸血 = 0.08（暗影弹自带）")
	_clear_projectiles()
	p.weapon_evolved = true
	p.recalc_stats()
	battle.combat.on_player_fired(p.global_position + Vector2(100.0, 0.0), 1)
	var pr1: Projectile = battle.projectiles[battle.projectiles.size() - 1]
	_check(_approx(pr1.lifesteal, 0.14),
		"E2: 暗影汲取弹道吸血 0.08 → 0.14（实际 %.3f）" % pr1.lifesteal)
	_clear_projectiles()


## F. kangaroo 残影连拳：attack_interval 按 rate_mul + 0.35 收紧
func _test_kangaroo_rate(p: Node2D) -> void:
	p.apply_character("kangaroo")
	p.weapon_level = 0
	p.weapon_evolved = false
	p.recalc_stats()
	var iv0: float = p.attack_interval
	p.weapon_evolved = true
	p.recalc_stats()
	var iv1: float = p.attack_interval
	var aspd_v: float = p.aspd
	var expect: float = clampf(GameStats.ATTACK_BASE_COOLDOWN / aspd_v / (1.5 + 0.35),
		GameStats.ATTACK_INTERVAL_MIN, 999.0)
	_check(_approx(iv1, expect),
		"F1: 残影连拳 attack_interval = BASE/aspd/(1.5+0.35)（%.4f ≈ %.4f）" % [iv1, expect])
	_check(iv1 < iv0, "F2: 进化后攻击间隔严格收紧（%.4f → %.4f）" % [iv0, iv1])


## H. weapon_mastery 升级链：第 6 层触发进化（apply_upgrade 集成路径）
##    + 2026-09-20 每层即时攻击 +3 与选卡进度注入
func _test_upgrade_chain(p: Node2D) -> void:
	p.apply_character("basic")
	p.weapon_level = 0
	p.weapon_evolved = false
	p.recalc_stats()
	var atk0: int = int(p.atk)
	# H0: 选项携带进化进度（波末保底必含武器精通 → 直接生成选项断言）
	battle._current_reason = "wave"
	battle._generate_options()
	var prog_found := false
	var prog_val := -1
	var disp_ok := false
	for o in battle._current_options:
		if String(o.get("id", "")) == "weapon_mastery":
			prog_found = bool(o.has("mastery_progress"))
			prog_val = int(o.get("mastery_progress", -1))
			disp_ok = GameStats.upgrade_display(o, 1) == "+3"
			break
	_check(prog_found and prog_val == 0,
		"H0: 武器精通卡携带进化进度 0/6（实际 %s/%d）" % [str(prog_found), prog_val])
	_check(disp_ok, "H0b: 卡面效果显示 +3（每层即时攻击）")
	for i in 5:
		p.apply_upgrade("weapon_mastery", 0.0)
	_check(p.weapon_level == 5 and not p.weapon_evolved,
		"H1: 5 层未进化（level=%d evolved=%s）" % [p.weapon_level, str(p.weapon_evolved)])
	_check(int(p.atk) == atk0 + 15,
		"H1b: 每层即时攻击 +3（atk %d = %d + 15）" % [int(p.atk), atk0])
	p.apply_upgrade("weapon_mastery", 0.0)
	_check(p.weapon_level == 6 and p.weapon_evolved,
		"H2: 第 6 层触发进化（level=%d evolved=%s）" % [p.weapon_level, str(p.weapon_evolved)])
	_check(int(p.atk) == atk0 + 18,
		"H2b: 6 层累计 +18 攻击（atk %d）" % int(p.atk))
	var form: Dictionary = p.weapon_form()
	_check(String(form.get("name", "")) == "连珠·二重奏" and int(form.get("shots", 0)) == 1,
		"H3: 进化后 weapon_form() 返回连珠·二重奏形态")


## G. potato 爆裂薯块：字段接线 + 溅射 + 去重
func _test_potato_splash(p: Node2D) -> void:
	# ---- G1: 未进化基线 aoe=0
	p.apply_character("potato")
	p.weapon_level = 0
	p.weapon_evolved = false
	p.recalc_stats()
	p.crit = 0.0   # recalc 之后设：player_damage 无暴击 ⇒ 伤害确定性
	battle.combat.on_player_fired(p.global_position + Vector2(100.0, 0.0), 1)
	var pr0: Projectile = battle.projectiles[battle.projectiles.size() - 1]
	_check(pr0.aoe_radius == 0.0 and pr0.aoe_pct == 0.0, "G1: 未进化土豆弹 aoe 字段全 0")
	_clear_projectiles()

	# ---- G2: 进化后 aoe 字段接线
	p.weapon_evolved = true
	p.recalc_stats()
	p.crit = 0.0
	# 期望直接伤害：与 on_player_fired 同式（atk × dmg_mul × BOOST × damage_bonus × evolve_mul）
	var atk_v: int = p.atk
	var w: Dictionary = GameStats.weapon_for_char("potato")
	var wdmg: int = roundi(float(atk_v) * float(w["dmg_mul"])
		* GameStats.PROJ_DMG_BOOST * float(p.damage_bonus())
		* float(p.weapon_damage_mul()))
	var direct: int = int(GameStats.player_damage(wdmg, 0.0, float(p.critd), 0)["dmg"])
	var splash_exp: int = maxi(1, roundi(float(direct) * 0.40))

	# 三只 Slime：e1 命中点；e2 圈内 60px（应溅射）；e3 圈外 92px（半径 90 → 应豁免，
	# 且 ≤ GRID_CELL 96 ⇒ 一定落在 3x3 网格查询里，专测距离过滤而不是网格漏查）
	# 开局已刷的怪【标记死亡】而不是 queue_free —— 延迟释放的节点本帧仍 valid，
	# 会混进重建后的网格吃走直击；is_dead 让 rebuild_grid / nearby_enemies 直接跳过。
	for e in battle.enemies:
		e.is_dead = true
	battle.enemies.clear()
	battle.combat.clear_grid()
	var pc: Vector2 = p.global_position
	battle._spawn_enemy("Slime", pc + Vector2(100.0, 0.0))
	var e1: Node2D = battle.enemies[battle.enemies.size() - 1]
	battle._spawn_enemy("Slime", e1.global_position + Vector2(60.0, 0.0))
	var e2: Node2D = battle.enemies[battle.enemies.size() - 1]
	battle._spawn_enemy("Slime", e1.global_position + Vector2(92.0, 0.0))
	var e3: Node2D = battle.enemies[battle.enemies.size() - 1]
	for e in [e1, e2, e3]:
		e.set_physics_process(false)
		e.max_hp = int(ENEMY_HP)
		e.hp = ENEMY_HP
	_check(int(e1.defense) == 0, "G2: 测试用 Slime def=0（免疫减伤项，伤害可精确断言）")

	battle.combat.rebuild_grid()
	battle.combat.on_player_fired(e1.global_position, 1)
	_check(battle.projectiles.size() == 1,
		"G3: 土豆进化后一发一弹（base_shots 1，场上 %d 颗）" % battle.projectiles.size())
	var proj: Projectile = battle.projectiles[0]
	_check(_approx(proj.aoe_radius, 90.0) and _approx(proj.aoe_pct, 0.40),
		"G4: 爆裂薯块 aoe 字段接线 90px / 40%%")

	# 传送到命中点 → 手动结算一帧：直击 e1 + 溅射 e2、e3 豁免
	proj.global_position = e1.global_position
	battle.combat.process_projectiles(DT)
	_check(_approx(float(e1.hp), ENEMY_HP - float(direct)),
		"G5: 直击 e1 实扣 %d（期望 %d）" % [int(ENEMY_HP - e1.hp), direct])
	_check(_approx(float(e2.hp), ENEMY_HP - float(splash_exp)),
		"G6: 溅射 e2 实扣 %d = 直击×40%%（期望 %d）" % [int(ENEMY_HP - e2.hp), splash_exp])
	_check(_approx(float(e3.hp), ENEMY_HP),
		"G7: 圈外 92px 的 e3 免受溅射（半径 90 距离过滤生效）")

	# 再走一帧：去重 —— 任何敌人不得二次掉血
	var h1: float = e1.hp
	var h2: float = e2.hp
	var h3: float = e3.hp
	battle.combat.process_projectiles(DT)
	_check(_approx(float(e1.hp), h1) and _approx(float(e2.hp), h2) and _approx(float(e3.hp), h3),
		"G8: 第二帧去重生效，同一弹道不重复结算（逐弹已命中表）")

	battle.enemies.clear()
	battle.combat.clear_grid()
	_clear_projectiles()


## I. 进化弹道视觉（2026-09-20 美术回投）：*_evo 键 + 进化态优先 / 未登记回落 + 新星环
func _test_evo_visuals(p: Node2D) -> void:
	# ---- I1: 6 个 _evo 键全部登记且贴图可用
	for cid in ["basic", "study", "finance", "sad", "potato", "kangaroo"]:
		var ev: Dictionary = AssetDB.weapon_bullet(String(cid) + "_evo")
		_check(not ev.is_empty() and ev.get("texture", null) != null,
			"I1: %s_evo 弹道已登记且贴图可用" % cid)
	# ---- I2/I3: 未进化走基础弹、进化走 evo 弹（端到端 on_player_fired）
	p.apply_character("basic")
	p.weapon_level = 0
	p.weapon_evolved = false
	p.recalc_stats()
	battle.combat.on_player_fired(p.global_position + Vector2(100.0, 0.0), 1)
	var pr0: Projectile = battle.projectiles[battle.projectiles.size() - 1]
	var base_expect: Texture2D = AssetDB.weapon_bullet("basic")["texture"]
	_check(pr0.bullet_tex == base_expect, "I2: 未进化弹道贴图 = 基础金珠")
	_clear_projectiles()
	p.weapon_evolved = true
	p.recalc_stats()
	battle.combat.on_player_fired(p.global_position + Vector2(100.0, 0.0), 1)
	var pr1: Projectile = battle.projectiles[battle.projectiles.size() - 1]
	var evo_expect: Texture2D = AssetDB.weapon_bullet("basic_evo")["texture"]
	_check(pr1.bullet_tex == evo_expect, "I3: 进化弹道贴图 = 连珠·二重奏（basic_evo）")
	_clear_projectiles()
	# ---- I4: 未登记 evo 键返回空字典（回落路径可依赖）
	_check(AssetDB.weapon_bullet("nonexistent_evo").is_empty(),
		"I4: 未登记 evo 键返回空字典（回落基础弹）")
	# ---- I5: 新星环特效登记
	_check(AssetDB.fx_tex("evo_nova") != null, "I5: 进化新星环贴图已登记可用")


# ================================================================ J. 弹道数无上限 + 扇面封顶压缩
## 用户需求（2026-09-20）：弹道不设上限（删 MAX_PROJ）；扇面达到 MAX_PROJ_SPREAD 后
## 不再变宽，改为压缩每条弹道之间的间隔角。独立验证：直接读发射出的弹道 velocity 方向。
func _test_proj_spread(p: Node2D) -> void:
	print("[PROBE] --- J. 弹道数无上限 + 扇面封顶压缩 ---")
	var spread := _stat_const("MAX_PROJ_SPREAD", 1.2)
	var per := _stat_const("PROJ_SPREAD", 0.3)
	_check(spread > per, "J0: MAX_PROJ_SPREAD(%.2f) > PROJ_SPREAD(%.2f)" % [spread, per])

	# J1 旧行为逐位不变：5 条 = 每发 0.3、总扇面 1.2
	var ang5 := _fire_and_angles(p, 5)
	_check(ang5.size() == 5, "J1a: proj=5 发射 5 条（实际 %d）" % ang5.size())
	if ang5.size() == 5:
		_check(_approx(ang5[1] - ang5[0], per),
			"J1b: 5 条间隔仍为 PROJ_SPREAD=%.3f（实际 %.4f）" % [per, ang5[1] - ang5[0]])
		_check(_approx(ang5[4] - ang5[0], spread),
			"J1c: 5 条总扇面 = %.2f（旧行为）" % spread)

	# J2 超界压缩：8 条 → 间隔 = MAX_PROJ_SPREAD/7，总扇面仍封顶
	var ang8 := _fire_and_angles(p, 8)
	_check(ang8.size() == 8, "J2a: proj=8 发射 8 条（无上限生效，实际 %d）" % ang8.size())
	if ang8.size() == 8:
		var want8 := spread / 7.0
		_check(_approx(ang8[1] - ang8[0], want8),
			"J2b: 8 条间隔压缩为 %.4f（实际 %.4f）" % [want8, ang8[1] - ang8[0]])
		_check(_approx(ang8[7] - ang8[0], spread),
			"J2c: 8 条总扇面仍封顶 %.2f（未再变宽）" % spread)

	# J3 更多：12 条按 11 份继续压缩
	var ang12 := _fire_and_angles(p, 12)
	_check(ang12.size() == 12, "J3a: proj=12 发射 12 条（实际 %d）" % ang12.size())
	if ang12.size() == 12:
		_check(_approx(ang12[11] - ang12[0], spread),
			"J3b: 12 条总扇面仍 %.2f" % spread)
		_check(_approx(ang12[1] - ang12[0], spread / 11.0),
			"J3c: 12 条间隔 %.4f" % (spread / 11.0))

	# J4 去钳制：旧上限 5 不再是天花板
	var pv = p
	pv._bonus["proj"] = 10.0
	pv.recalc_stats()
	_check(int(pv.proj) >= 11, "J4: 弹道数可超前旧上限 5（加成 +10 → proj=%d）" % int(pv.proj))
	pv._bonus["proj"] = 0.0
	pv.recalc_stats()


## 发射 n 条弹道并回传方向角（升序）。读实际 velocity 方向，不碰内部角度缓存。
## 走真实链路：设 _bonus → recalc → 用 player.proj 当 count 传给 on_player_fired
## （Player.fired 信号传的就是 proj；若 recalc 里还有旧钳制，count 会被卡住 → 断言能捕获）。
func _fire_and_angles(p: Node2D, n: int) -> Array:
	var pv = p
	pv.weapon_evolved = false
	pv.weapon_level = 0
	pv._bonus["proj"] = float(n) - float(pv._base["proj"])
	pv.recalc_stats()
	var cnt: int = int(pv.proj)
	_clear_projectiles()
	battle.combat.on_player_fired(p.global_position + Vector2(100.0, 0.0), cnt)
	var angs: Array = []
	for pr in battle.projectiles:
		angs.append(pr.velocity.angle())
	angs.sort()
	_clear_projectiles()
	pv._bonus["proj"] = 0.0
	pv.recalc_stats()
	return angs


## 读 Stats 脚本常量（契约可能后落地，缺失时用 fallback 不炸）。
func _stat_const(name: String, fallback: float) -> float:
	var s: GDScript = load("res://scripts/data/Stats.gd")
	var m: Dictionary = s.get_script_constant_map()
	return float(m.get(name, fallback))


# ================================================================ 公用

func _approx(a: float, b: float) -> bool:
	return absf(a - b) <= maxf(1e-4, 1e-5 * maxf(absf(a), absf(b)))


func _check(cond: bool, label: String) -> void:
	checks += 1
	if cond:
		print("[PROBE]   OK   %s" % label)
	else:
		fails.append(label)
		print("[PROBE]   FAIL %s" % label)


func _finish(ok: bool, msg: String) -> void:
	finished = true
	if msg != "":
		print("[PROBE] %s" % msg)
	print("[PROBE] 断言 %d/%d 通过" % [checks - fails.size(), checks])
	for f in fails:
		print("[PROBE]   - %s" % f)
	print("[PROBE] RESULT=%s" % ("PASS" if ok and fails.is_empty() else "FAIL"))
	quit(0 if ok and fails.is_empty() else 1)
