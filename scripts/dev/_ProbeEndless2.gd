extends SceneTree
## 独立验证探针：无尽 2.0 —— 战场规则 + 里程碑（2026-10-08 第二梯队第五批）。
##
## 与 `_ProbeEndless.gd`（T-END-02，旧无尽语义：前 20 波护栏 / 曲线延伸 / HUD 文案 /
## 不结算分支）【并存分工】：旧探针是回归点、本探针只管新层 —— 规则 + 里程碑。
##
## 回答五个验收问题：
##   ① 数据面契约：规则表 5 条（id 唯一 / 名字与描述非空 / 键位白名单）、纪元与里程碑常量
##   ② 纯函数：endless_era 边界与轮换、endless_rule 取模循环、乘区/增量读取口缺省值
##   ③ 乘区实测（走 spawn_enemy 完整链）：spawn（planned_count）/ hp / dmg / spd / loot（含 xp 连带）
##   ④ 里程碑端到端：金币入账（复算 add_gold 链）/ 每 10 波道具宝箱 / 非里程碑与非无尽不发
##   ⑤ 纪律：波 ≤20 全零影响、开关禁用态、零随机消耗、HUD 波次行与新纪元通知
##
## 被验证的契约：
##   GameStats.ENDLESS_RULES / ENDLESS_ERA_LEN / ENDLESS_FIRST_ERA_WAVE / ENDLESS_MILESTONE_* /
##     endless_era / endless_rule / endless_rule_mul / endless_rule_add /
##     is_endless_milestone / endless_milestone_gold / endless_milestone_has_chest /
##     endless_rules_enabled（静态开关）
##   WaveDirector.planned_count / spawn_enemy（hp/dmg 乘区链）/ spawn_elites（elite_add）/
##     start_next_wave（横幅与纪元通知）
##   Enemy.setup（spd / loot 模板级乘区，含 xp 连带）
##   Battle._grant_endless_milestone（入账 / 宝箱排队 / 开关）
##   Hud.set_data（波次行规则名）/ show_center_notice（纪元切换）
##
## 确定性：全部同步调用 + 手动步进，不依赖真实帧；规则读取零随机消耗（seed 对照）。
##
## 用法: godot --headless --path <项目>/game --script res://scripts/dev/_ProbeEndless2.gd
## 退出码 0=PASS 1=FAIL（门禁用 grep -q "RESULT=PASS" 判定）

var battle: Node = null
var armed := false
var finished := false
var checks := 0
var fails: Array[String] = []


func _initialize() -> void:
	print("[PROBE] === 无尽 2.0（战场规则 + 里程碑）验证 ===")
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
		_arm()
		_finish("")
		return true
	return true


func _arm() -> void:
	armed = true
	_sec_a_contracts()
	_sec_b_pure_functions()
	_sec_c_rule_lookup()
	_sec_d_multipliers()
	_sec_e_milestone()
	_sec_f_discipline()
	# 收尾：恢复静态状态（GameSession.endless / 开关），避免污染同进程后续逻辑
	GameSession.endless = false
	GameStats.endless_rules_enabled = true
	paused = false


# ================================================================ A. 数据面契约
func _sec_a_contracts() -> void:
	_section("A. 数据面契约（规则表 / 纪元 / 里程碑常量）")
	_check(GameStats.ENDLESS_RULES.size() == 5, "规则表 5 条（实际 %d）" % GameStats.ENDLESS_RULES.size())
	_check(GameStats.ENDLESS_ERA_LEN == 10, "纪元长度 == 10 波")
	_check(GameStats.ENDLESS_FIRST_ERA_WAVE == 21, "首纪元起始波 == 21")
	var ids := {}
	var names := ""
	var keys_ok := true
	var allowed := ["id", "name", "desc", "spawn_mul", "hp_mul", "dmg_mul", "spd_mul", "loot_mul", "elite_add"]
	for r in GameStats.ENDLESS_RULES:
		var rid := String(r.get("id", ""))
		ids[rid] = true
		names += String(r.get("name", "")) + "/"
		if rid == "" or String(r.get("name", "")) == "" or String(r.get("desc", "")) == "":
			keys_ok = false
		for k in r.keys():
			if not allowed.has(String(k)):
				keys_ok = false
	_check(ids.size() == 5, "id 唯一（5 个）")
	_check(keys_ok, "名字/描述非空 + 键位全在白名单内")
	_check(names == "狂潮/铁壁/疾行军/血月/猎场/", "规则名按序：%s" % names)
	_check(GameStats.ENDLESS_MILESTONE_STEP == 5, "里程碑步进 == 5 波")
	_check(GameStats.ENDLESS_MILESTONE_CHEST_EVERY == 10, "道具箱周期 == 10 波")


# ================================================================ B. 纯函数（纪元边界）
func _sec_b_pure_functions() -> void:
	_section("B. 纯函数（endless_era 边界）")
	_check(GameStats.endless_era(1) == -1, "波 1 → 未进纪元（-1）")
	_check(GameStats.endless_era(20) == -1, "波 20 → 未进纪元（-1）")
	_check(GameStats.endless_era(21) == 0, "波 21 → 第 1 纪元（0）")
	_check(GameStats.endless_era(30) == 0, "波 30 → 仍为第 1 纪元（0）")
	_check(GameStats.endless_era(31) == 1, "波 31 → 第 2 纪元（1）")
	_check(GameStats.endless_era(40) == 1, "波 40 → 仍为第 2 纪元（1）")
	_check(GameStats.endless_era(41) == 2, "波 41 → 第 3 纪元（2）")
	_check(GameStats.endless_era(51) == 3, "波 51 → 第 4 纪元（3）")
	_check(GameStats.endless_era(61) == 4, "波 61 → 第 5 纪元（4）")
	_check(GameStats.endless_era(71) == 5, "波 71 → 纪元 5（表循环前的序号）")


# ================================================================ C. 规则取值（轮换 / 开关）
func _sec_c_rule_lookup() -> void:
	_section("C. 规则取值（21+ 轮换 / ≤20 空 / 开关禁用）")
	_check(GameStats.endless_rule(20).is_empty(), "波 20 → 空字典（无规则）")
	_check(String(GameStats.endless_rule(21).get("id", "")) == "horde", "波 21-30 → 狂潮")
	_check(String(GameStats.endless_rule(30).get("id", "")) == "horde", "波 30 → 仍为狂潮")
	_check(String(GameStats.endless_rule(31).get("id", "")) == "fortress", "波 31-40 → 铁壁")
	_check(String(GameStats.endless_rule(41).get("id", "")) == "swift", "波 41-50 → 疾行军")
	_check(String(GameStats.endless_rule(51).get("id", "")) == "blood_moon", "波 51-60 → 血月")
	_check(String(GameStats.endless_rule(61).get("id", "")) == "hunt", "波 61-70 → 猎场")
	_check(String(GameStats.endless_rule(71).get("id", "")) == "horde", "波 71 → 表循环回狂潮（5 % 5）")
	_check(GameStats.endless_rule_mul(20, "spawn_mul") == 1.0, "波 20 乘区读取 = 1.0")
	_check(GameStats.endless_rule_mul(21, "spd_mul") == 1.0, "狂潮无 spd 键 → 缺省 1.0")
	_check(GameStats.endless_rule_mul(21, "spawn_mul") == 1.35, "狂潮 spawn_mul == 1.35")
	_check(GameStats.endless_rule_add(20, "elite_add") == 0, "波 20 增量读取 = 0")
	_check(GameStats.endless_rule_add(21, "elite_add") == 0, "狂潮无 elite 键 → 缺省 0")
	_check(GameStats.endless_rule_add(61, "elite_add") == 2, "猎场 elite_add == 2")
	GameStats.endless_rules_enabled = false
	_check(GameStats.endless_rule(21).is_empty(), "开关禁用：波 21 也返回空")
	_check(GameStats.endless_rule_mul(21, "spawn_mul") == 1.0, "开关禁用：乘区恒 1.0")
	_check(GameStats.endless_rule_add(61, "elite_add") == 0, "开关禁用：增量恒 0")
	GameStats.endless_rules_enabled = true


# ================================================================ D. 乘区实测（spawn_enemy 完整链）
func _sec_d_multipliers() -> void:
	_section("D. 乘区实测（planned_count / hp / dmg / spd / loot / elite）")
	battle.start_run()
	battle.set_physics_process(false)
	battle.player.set_physics_process(false)

	# D1：planned_count —— 狂潮 ×1.35 / 铁壁 ×0.85 / 波 20 无规则
	battle.wave_num = 20
	_check(battle.wave.planned_count() == GameStats.spawn_count(20), "波 20：计划投放 == 原生曲线")
	battle.wave_num = 21
	var base21 := GameStats.spawn_count(21)
	var want21 := int(roundf(float(base21) * 1.35))
	_check(battle.wave.planned_count() == want21,
		"波 21 狂潮：计划 %d → %d（原生 ×1.35）" % [base21, want21])
	battle.wave_num = 31
	var base31 := GameStats.spawn_count(31)
	var want31 := int(roundf(float(base31) * 0.85))
	_check(battle.wave.planned_count() == want31,
		"波 31 铁壁：计划 %d → %d（原生 ×0.85）" % [base31, want31])

	# D2：hp 乘区（走完整 spawn_enemy 链；对照开关禁用态的基线怪）
	_clear_battle_enemies()
	battle.wave_num = 21
	battle.wave.spawn_enemy("Slime", Vector2(400.0, -400.0), 1.0, false)
	var e_horde = _last_enemy("Slime")
	GameStats.endless_rules_enabled = false
	battle.wave.spawn_enemy("Slime", Vector2(400.0, -400.0), 1.0, false)
	var e_base = _last_enemy("Slime")
	GameStats.endless_rules_enabled = true
	var hp_ratio := float(e_horde.max_hp) / float(e_base.max_hp)
	_check(absf(hp_ratio - 0.88) <= 0.02,
		"波 21 狂潮：hp %d → %d（比值 %.3f ≈ 0.88）" % [e_base.max_hp, e_horde.max_hp, hp_ratio])
	_clear_battle_enemies()
	battle.wave_num = 31
	battle.wave.spawn_enemy("Slime", Vector2(400.0, -400.0), 1.0, false)
	var e_fort = _last_enemy("Slime")
	GameStats.endless_rules_enabled = false
	battle.wave.spawn_enemy("Slime", Vector2(400.0, -400.0), 1.0, false)
	var e_base2 = _last_enemy("Slime")
	GameStats.endless_rules_enabled = true
	var hp_ratio2 := float(e_fort.max_hp) / float(e_base2.max_hp)
	_check(absf(hp_ratio2 - 1.25) <= 0.02,
		"波 31 铁壁：hp %d → %d（比值 %.3f ≈ 1.25）" % [e_base2.max_hp, e_fort.max_hp, hp_ratio2])

	# D3：dmg 乘区（血月 ×1.35）
	_clear_battle_enemies()
	battle.wave_num = 51
	battle.wave.spawn_enemy("Slime", Vector2(400.0, -400.0), 1.0, false)
	var e_moon = _last_enemy("Slime")
	GameStats.endless_rules_enabled = false
	battle.wave.spawn_enemy("Slime", Vector2(400.0, -400.0), 1.0, false)
	var e_base3 = _last_enemy("Slime")
	GameStats.endless_rules_enabled = true
	var dmg_ratio := float(e_moon.dmg) / float(e_base3.dmg)
	_check(absf(dmg_ratio - 1.35) <= 0.03,
		"波 51 血月：dmg %d → %d（比值 %.3f ≈ 1.35）" % [e_base3.dmg, e_moon.dmg, dmg_ratio])

	# D4：spd 乘区（疾行军 ×1.28，模板级 —— setup 直调也能测）
	var slime = _make_enemy("Slime", 41)
	var spd_expect: float = GameStats.enemy_speed("Slime") * 1.28
	_check(absf(slime.speed - spd_expect) <= 0.01,
		"波 41 疾行军：spd %.1f → %.1f（= 原生 %.1f ×1.28）" % [
			GameStats.enemy_speed("Slime"), slime.speed, GameStats.enemy_speed("Slime")])
	var slime20 = _make_enemy("Slime", 20)
	_check(absf(slime20.speed - GameStats.enemy_speed("Slime")) <= 0.01, "波 20 移速无规则加成")
	_cleanup(slime)
	_cleanup(slime20)

	# D5：loot 乘区（血月 ×1.3，含 xp 连带）
	# 样本独立于 D3（2026-10-09 批量测修正）：旧版借用 Slime —— Slime gold=1，
	# 1×1.3 取整后仍为 1 ⇒ 前置「可区分」天然不成立（整条测试永远无效）。
	# 换 gold=3 的 Ranged：roundi(3×1.3)=4 ≠ 3，乘区生效与否可观测。
	_clear_battle_enemies()
	battle.wave_num = 51
	battle.wave.spawn_enemy("Ranged", Vector2(400.0, -400.0), 1.0, false)
	var e_loot_moon = _last_enemy("Ranged")
	GameStats.endless_rules_enabled = false
	battle.wave.spawn_enemy("Ranged", Vector2(400.0, -400.0), 1.0, false)
	var e_loot_base = _last_enemy("Ranged")
	GameStats.endless_rules_enabled = true
	var gold_base := int(GameStats.ENEMY_TEMPLATES["Ranged"]["gold"])
	var gold_want := maxi(1, roundi(float(gold_base) * 1.3))
	_check(gold_want != gold_base, "（前置）Ranged gold=%d 的 ×1.3 取整后可区分" % gold_base)
	_check(e_loot_moon.gold == gold_want,
		"波 51 血月：gold %d → %d（×1.3 四舍五入）" % [gold_base, e_loot_moon.gold])
	_check(e_loot_moon.xp_value == e_loot_moon.gold * int(GameStats.XP_PER_GOLD),
		"xp_value 随 gold 连带（%d = %d × %d）" % [
			e_loot_moon.xp_value, e_loot_moon.gold, int(GameStats.XP_PER_GOLD)])
	_check(e_loot_base.gold == gold_base, "对照基线怪 gold 不变（%d）" % gold_base)
	_cleanup(e_loot_moon)
	_cleanup(e_loot_base)

	# D6：elite_add（猎场 +2 只/波）
	_clear_battle_enemies()
	battle.wave_num = 61
	battle.wave.spawn_elites()
	var want_elite := GameStats.elite_count(61) + 2
	_check(_count_type("Elite") == want_elite,
		"波 61 猎场：精英 %d → %d（原生 +2）" % [GameStats.elite_count(61), want_elite])
	_clear_battle_enemies()


# ================================================================ E. 里程碑（端到端）
func _sec_e_milestone() -> void:
	_section("E. 里程碑（金币入账 / 道具箱 / 非里程碑与非无尽）")
	_check(not GameStats.is_endless_milestone(20), "波 20 非里程碑")
	_check(not GameStats.is_endless_milestone(24), "波 24 非里程碑")
	_check(GameStats.is_endless_milestone(25), "波 25 里程碑")
	_check(GameStats.is_endless_milestone(30), "波 30 里程碑")
	_check(not GameStats.is_endless_milestone(31), "波 31 非里程碑")
	_check(GameStats.endless_milestone_gold(25) == 160, "波 25 金币 160（实际 %d）" % GameStats.endless_milestone_gold(25))
	_check(GameStats.endless_milestone_gold(30) == 200, "波 30 金币 200（实际 %d）" % GameStats.endless_milestone_gold(30))
	_check(GameStats.endless_milestone_gold(50) == 360, "波 50 金币 360（实际 %d）" % GameStats.endless_milestone_gold(50))
	_check(not GameStats.endless_milestone_has_chest(25), "波 25 无道具箱")
	_check(GameStats.endless_milestone_has_chest(30), "波 30 有道具箱")
	_check(GameStats.endless_milestone_has_chest(40), "波 40 有道具箱")

	GameSession.endless = true
	battle.wave_num = 24
	var p = battle.player
	var g0 := int(p.gold)
	battle.call("_grant_endless_milestone", 24)
	_check(int(p.gold) == g0, "波 24（非里程碑）：不发补给（gold %d → %d）" % [g0, int(p.gold)])
	_check(int(battle._chest_pending) == 0, "波 24：无道具箱（_chest_pending == 0）")

	var amount25 := GameStats.endless_milestone_gold(25)
	var exp25 := _gold_after_chain(amount25)
	battle.call("_grant_endless_milestone", 25)
	_check(int(p.gold) - g0 == exp25,
		"波 25：入账 %d（期望 %d，gold → %d）" % [int(p.gold) - g0, exp25, int(p.gold)])
	_check(int(battle._chest_pending) == 0, "波 25：只发金币不排箱（_chest_pending == 0）")

	var g1 := int(p.gold)
	var amount30 := GameStats.endless_milestone_gold(30)
	var exp30 := _gold_after_chain(amount30)
	battle.call("_grant_endless_milestone", 30)
	_check(int(p.gold) - g1 == exp30, "波 30：入账 %d（期望 %d）" % [int(p.gold) - g1, exp30])
	_check(int(battle._chest_pending) == 1, "波 30：道具箱 +1（_chest_pending=%d）" % int(battle._chest_pending))

	# 非无尽不发
	GameSession.endless = false
	var g2 := int(p.gold)
	var chests2 := int(battle._chest_pending)
	battle.call("_grant_endless_milestone", 35)
	_check(int(p.gold) == g2 and int(battle._chest_pending) == chests2, "非无尽模式：不发补给")
	# 开关禁用不发
	GameSession.endless = true
	GameStats.endless_rules_enabled = false
	battle.call("_grant_endless_milestone", 35)
	_check(int(p.gold) == g2, "开关禁用：不发补给")
	GameStats.endless_rules_enabled = true
	GameSession.endless = false
	battle._chest_pending = 0   # 复位（E 段排的箱子别拖进 F 段）


# ================================================================ F. 纪律
func _sec_f_discipline() -> void:
	_section("F. 纪律（波 ≤20 零影响 / 零随机 / HUD 与通知）")
	# F1：零随机消耗（规则读取不进随机流）
	seed(7)
	var r1 := randf()
	seed(7)
	var _r = GameStats.endless_rule(61)
	var _m = GameStats.endless_rule_mul(61, "loot_mul")
	var _a = GameStats.endless_rule_add(61, "elite_add")
	var _e := GameStats.endless_era(61)
	var r2 := randf()
	_check(absf(r1 - r2) <= 1e-9, "规则读取零随机消耗（randf 序列一致）")

	# F2：波 ≤20 全零影响
	for w in [1, 10, 20]:
		_check(GameStats.endless_rule(w).is_empty()
			and GameStats.endless_rule_mul(w, "hp_mul") == 1.0
			and GameStats.endless_rule_add(w, "elite_add") == 0,
			"波 %d：空规则 / 乘区 1.0 / 增量 0（旧行为逐位）" % w)

	# F3：HUD 波次行 —— 波 20 无规则、波 21 含规则名
	GameSession.endless = true
	battle.hud.set_data(battle.player, 20, 30.0, GameStats.WAVE_COUNT)
	_check(not ("狂潮" in battle.hud._wave_label.text) and ("第 20 波" in battle.hud._wave_label.text),
		"波 20 波次行无规则名（%s）" % battle.hud._wave_label.text)
	battle.wave_num = 20
	battle.wave.start_next_wave()   # → 21
	_check(int(battle.wave_num) == 21, "推进到波 21")
	_check("狂潮" in battle.hud._wave_label.text,
		"波 21 波次行含规则名（%s）" % battle.hud._wave_label.text)

	# F4：新纪元首波 → 中央通知（波 20 → 21 纪元 0 ≠ -1）
	_check("第 1 纪元" in battle.hud._notice_label.text and "狂潮" in battle.hud._notice_label.text,
		"新纪元中央通知（%s）" % battle.hud._notice_label.text)

	# F5：纪元中段推进（波 21 → 22 不重复通知）
	battle.hud.show_center_notice("占位", 2.5)
	battle.wave.start_next_wave()   # → 22（同纪元 0 == 0）
	_check(battle.hud._notice_label.text == "占位", "波 22（同纪元）：不再发纪元通知")

	# F6：跨纪元推进（波 30 → 31 纪元 1 ≠ 0）
	_clear_battle_enemies()
	battle.wave_num = 30
	battle.wave.start_next_wave()   # → 31
	_check("第 2 纪元" in battle.hud._notice_label.text and "铁壁" in battle.hud._notice_label.text,
		"跨纪元通知（%s）" % battle.hud._notice_label.text)
	_check("铁壁" in battle.hud._wave_label.text,
		"波 31 波次行切到新规则（%s）" % battle.hud._wave_label.text)


# ================================================================ 工具
## 复算 add_gold 的入账链（meta 财富强化 → 诅咒萧条）—— 与 Player.add_gold 同式。
func _gold_after_chain(base: int) -> int:
	var amount := base
	var m_gold := float(battle.player.meta_bonus_dict.get("gold_mul", 0.0))
	if m_gold > 0.0:
		amount = maxi(1, roundi(float(amount) * (1.0 + m_gold)))
	var c_gold := GameStats.curse_bonus("gold_mul")
	if c_gold != 0.0:
		amount = maxi(1, roundi(float(amount) * (1.0 + c_gold)))
	return amount


## 反射构造一只敌人（挂 Sprite 子节点 + 手动步进夹具，同 _ProbeBossPhases._make_boss）。
func _make_enemy(type_name: String, wave: int) -> Node2D:
	var e = Enemy.new()
	var spr := AnimatedSprite2D.new()
	spr.name = "Sprite"
	e.add_child(spr)
	root.add_child(e)
	e.call("setup", type_name, wave, Vector2(400.0, 0.0))
	e.set_physics_process(false)
	return e


func _cleanup(e: Node2D) -> void:
	if is_instance_valid(e):
		e.queue_free()


## 走 spawn_enemy 之后取最后入列的一只指定类型敌人。
func _last_enemy(t: String) -> Node2D:
	for i in range(battle.enemies.size() - 1, -1, -1):
		var e = battle.enemies[i]
		if is_instance_valid(e) and String(e.type_name) == t:
			return e
	return null


func _count_type(t: String) -> int:
	var n := 0
	for e in battle.enemies:
		if is_instance_valid(e) and String(e.type_name) == t:
			n += 1
	return n


func _clear_battle_enemies() -> void:
	for e in battle.enemies:
		if is_instance_valid(e):
			e.queue_free()
	battle.enemies.clear()


func _section(title: String) -> void:
	print("[PROBE] --- %s" % title)


func _check(cond: bool, label: String) -> void:
	checks += 1
	if cond:
		print("[PROBE]   OK   %s" % label)
	else:
		fails.append(label)
		print("[PROBE]   FAIL %s" % label)


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
