extends SceneTree
## 独立验证探针：精英词缀系统（2026-09-22，需求见《精英词缀系统_给代码AI_2026-09-22.md》）。
##
## 被验证的契约：
##   GameStats.ELITE_AFFIXES（5 项：名字 + 颜色 + 乘区齐全）+ elite_count 曲线
##   GameStats.roll_elite_affix：只 roll 出表内的键；elite_affix/name/color 查询器
##   WaveDirector.spawn_elites：波 <5 不出、波 ≥5 数量 = 1 + wave/8、**Boss 无词缀**
##   Enemy.setup(affix)：疾风移速 ×1.5 / 钢甲受击 ×0.5 / 狂怒半血切乘区
##   Enemy.take_damage：dmg_taken_mul 在唯一伤害入口收口
##   Battle._on_affix_death：爆裂 AOE（圈内掉血 / 圈外不掉血）、召唤 2 只 60% 血 Slime
##   CombatResolver.cleanup_enemies：精英金币 ×3 + 必掉商店券（普通怪不掉）
##   CombatResolver.collect + Battle._open_shop：券入包 → 进店消费 1 张 → 全店 8 折
##
## 用法: godot --headless --path <项目> --script res://scripts/dev/_ProbeEliteAffix.gd
## 退出码 0=PASS 1=FAIL（门禁用退出码判定，勿解析 stdout 尾行）

const DT := 1.0 / 60.0

var battle: Node = null
var armed := false
var finished := false
var checks := 0
var fails: Array[String] = []


func _initialize() -> void:
	print("[PROBE] === 精英词缀系统验证（2026-09-22）===")
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
	battle.start_run()
	battle.spawn_remaining = 0
	var pl = battle.player
	pl.autopilot = false
	pl.atk = 0.0
	pl.god_mode = true

	_t_static()
	_t_affix_mechanics()
	_t_death_effects()
	_t_drops()
	_t_coupon_shop()
	_t_wave_spawn_path()


# ---------------------------------------------------------------- A. 静态契约
func _t_static() -> void:
	var table: Dictionary = GameStats.ELITE_AFFIXES
	_check(table.size() == 5, "词缀表 5 项（实际 %d）" % table.size())
	for k in ["swift", "armored", "exploder", "summoner", "enraged"]:
		_check(table.has(k), "词缀表含 %s" % k)
	var meta_ok := true
	for k in table.keys():
		var d: Dictionary = table[k]
		if String(d.get("name", "")) == "" or not d.has("color"):
			meta_ok = false
	_check(meta_ok, "每项词缀都有 name + color")
	# 空键是「无词缀」的正常输入（普通怪 / Boss）—— 查询器必须安静返回，不能崩
	_check(GameStats.elite_affix("").is_empty(), "空词缀 id → 空字典（无异常）")
	_check(GameStats.elite_affix("nope").is_empty(), "未知词缀 id → 空字典（无异常）")
	_check(GameStats.elite_affix_name("") == "", "空词缀 id 的名字 = 空串")

	# 数量曲线：1 + wave/8，波 <5 恒 0。期望值从常量推导，不硬编码「1/2/3」
	_check(GameStats.elite_count(4) == 0, "波4 不出精英（实际 %d）" % GameStats.elite_count(4))
	_check(GameStats.elite_count(GameStats.ELITE_FIRST_WAVE) == 1,
		"首个精英波（%d）出 1 只（实际 %d）" % [
			GameStats.ELITE_FIRST_WAVE, GameStats.elite_count(GameStats.ELITE_FIRST_WAVE)])
	var monotone := true
	for w in range(GameStats.ELITE_FIRST_WAVE, 41):
		if GameStats.elite_count(w + 1) < GameStats.elite_count(w):
			monotone = false
	_check(monotone, "精英数量随波次单调非减（5..41）")

	# roll 只出表内的键（等权抽样不应产出表外值）
	var keys := GameStats.ELITE_AFFIXES.keys()
	var roll_ok := true
	var seen: Dictionary = {}
	for i in 400:
		var a := GameStats.roll_elite_affix()
		if not GameStats.ELITE_AFFIXES.has(a):
			roll_ok = false
		seen[a] = true
	_check(roll_ok, "400 次 roll 全部落在表内")
	_check(seen.size() == keys.size(),
		"400 次 roll 覆盖全部 5 个词缀（实际 %d 个）" % seen.size())


# ---------------------------------------------------------------- B. 词缀数值/行为接入
func _t_affix_mechanics() -> void:
	# 疾风：移速 = 模板速度 × spd_mul（模板速度本身含 SPATIAL_SCALE，用 enemy_speed 取）
	var sw = _spawn("Elite", Vector2(2000.0, 2000.0), "swift")
	var exp_sw: float = GameStats.enemy_speed("Elite") \
		* float(GameStats.elite_affix("swift")["spd_mul"])
	_check(_approx(float(sw.speed), exp_sw),
		"疾风移速 = 模板 ×%.1f（期望 %.1f 实际 %.1f）" % [
			float(GameStats.elite_affix("swift")["spd_mul"]), exp_sw, float(sw.speed)])
	_check(_approx(float(sw.dmg_taken_mul), 1.0), "疾风不吃减伤（dmg_taken_mul=1.0）")

	# 钢甲：受击乘区在 take_damage 收口（这里直接灌一笔大血再打固定伤害）
	var ar = _spawn("Elite", Vector2(2000.0, 2000.0), "armored")
	var mul := float(GameStats.elite_affix("armored")["dmg_taken_mul"])
	_check(_approx(float(ar.dmg_taken_mul), mul), "钢甲 dmg_taken_mul = %.2f" % mul)
	ar.max_hp = 100000
	ar.hp = 100000
	var before_hp := int(ar.hp)
	ar.take_damage(100)
	_check(int(before_hp - int(ar.hp)) == maxi(1, roundi(100.0 * mul)),
		"钢甲受 100 伤只掉 %d（实际 %d）" % [maxi(1, roundi(100.0 * mul)),
			before_hp - int(ar.hp)])
	# 对照组：无词缀精英吃满 100
	var plain = _spawn("Elite", Vector2(2000.0, 2000.0), "")
	plain.max_hp = 100000
	plain.hp = 100000
	var pb := int(plain.hp)
	plain.take_damage(100)
	_check(int(pb - int(plain.hp)) == 100, "无词缀对照：吃满 100（实际 %d）" % (pb - int(plain.hp)))
	# 减伤不得把怪变成打不死的：极小伤害仍至少扣 1
	var ar2 = _spawn("Elite", Vector2(2000.0, 2000.0), "armored")
	ar2.max_hp = 1000
	ar2.hp = 1000
	ar2.take_damage(1)
	_check(int(ar2.hp) == 999, "钢甲挨 1 点至少扣 1（不出现「永远打不死」）")

	# 狂怒：半血以上不切乘区 → 掉到阈值以下切一次
	var en = _spawn("Elite", Vector2(2000.0, 2000.0), "enraged")
	var ad: Dictionary = GameStats.elite_affix("enraged")
	var base_spd: float = GameStats.enemy_speed("Elite")
	var base_dmg := int(en.dmg)
	en.max_hp = 1000
	en.hp = int(round(1000.0 * float(ad["enrage_hp_ratio"]))) + 50   # 尚在阈值之上
	en._tick_affix(DT)
	_check(_approx(float(en.speed), base_spd) and int(en.dmg) == base_dmg,
		"狂怒：半血以上乘区不变")
	en.hp = int(round(1000.0 * float(ad["enrage_hp_ratio"]))) - 1     # 跌破阈值
	en._tick_affix(DT)
	_check(_approx(float(en.speed), base_spd * float(ad["enrage_spd_mul"])),
		"狂怒：半血后移速 ×%.1f（期望 %.1f 实际 %.1f）" % [
			float(ad["enrage_spd_mul"]), base_spd * float(ad["enrage_spd_mul"]), float(en.speed)])
	_check(int(en.dmg) == maxi(1, roundi(float(base_dmg) * float(ad["enrage_dmg_mul"]))),
		"狂怒：半血后伤害 ×%.1f（期望 %d 实际 %d）" % [
			float(ad["enrage_dmg_mul"]),
			maxi(1, roundi(float(base_dmg) * float(ad["enrage_dmg_mul"]))), int(en.dmg)])
	# 一次性：重复步进不再叠乘
	en._tick_affix(DT)
	en._tick_affix(DT)
	_check(_approx(float(en.speed), base_spd * float(ad["enrage_spd_mul"])),
		"狂怒只切一次（重复步进不叠乘）")


# ---------------------------------------------------------------- C. 死亡效果
func _t_death_effects() -> void:
	var pl = battle.player
	pl.god_mode = false
	pl.dodge = 0.0
	pl.defense = 0
	pl.max_hp = 100000
	pl.hp = 100000.0

	# 爆裂（圈内）：站在 AOE 半径内 → 掉血
	var r := float(GameStats.elite_affix("exploder")["death_aoe"])
	var ex = _spawn("Elite", pl.global_position + Vector2(r * 0.6, 0.0), "exploder")
	pl.invincible_timer = 0.0
	var hp0 := float(pl.hp)
	_boom(ex)
	_check(float(pl.hp) < hp0, "爆裂：站在 %.0fpx 圈内掉血（%.0f → %.0f）" % [r, hp0, float(pl.hp)])

	# 爆裂（圈外）：站在半径外 → 不掉血（可走位躲）
	var ex2 = _spawn("Elite", pl.global_position + Vector2(r * 2.5, 0.0), "exploder")
	pl.invincible_timer = 0.0
	var hp1 := float(pl.hp)
	_boom(ex2)
	_check(_approx(float(pl.hp), hp1), "爆裂：站在 %.0fpx 圈外不掉血（走位可躲）" % r)

	# 召唤：死亡原位掉 2 只 Slime，血量为模板 ×summon_hp_mul，且不占本波投放名额
	var sr: int = battle.spawn_remaining
	var slimes_before := _count_type("Slime")
	var sm = _spawn("Elite", Vector2(3000.0, 3000.0), "summoner")
	_boom(sm)
	var slimes_after := _count_type("Slime")
	var pair: Array = GameStats.elite_affix("summoner")["summon_on_death"]
	_check(slimes_after - slimes_before == int(pair[1]),
		"召唤：死亡掉 %d 只 %s（实际 %d 只）" % [int(pair[1]), String(pair[0]),
			slimes_after - slimes_before])
	_check(int(battle.spawn_remaining) == sr,
		"召唤物不占本波投放名额（spawn_remaining 不变）")
	var exp_hp := roundi(float(GameStats.ENEMY_TEMPLATES[String(pair[0])]["hp"])
		* GameStats.hp_scale(battle.wave_num) * float(battle.enemy_cost_hp_mult())
		* float(GameStats.elite_affix("summoner")["summon_hp_mul"]))
	var hp_ok := true
	for e in battle.enemies:
		if is_instance_valid(e) and e.type_name == String(pair[0]) and int(e.max_hp) != exp_hp:
			hp_ok = false
	_check(hp_ok, "召唤物血量 = 模板 ×%.1f（期望 %d）" % [
		float(GameStats.elite_affix("summoner")["summon_hp_mul"]), exp_hp])


# ---------------------------------------------------------------- D. 掉落
func _t_drops() -> void:
	var pl = battle.player
	# 先结算上一节留下的「已死未清理」精英 —— 否则它们会在本次 cleanup 里一起掉券，
	# 把「精英必掉 1 张券」的差值断言污染成 +N。
	battle.combat.cleanup_enemies()
	var coupon0 := _count_kind(Pickup.KIND_COUPON)
	var el = _spawn("Elite", Vector2(4000.0, 4000.0), "")
	var exp_gold := roundi(float(GameStats.ENEMY_TEMPLATES["Elite"]["gold"])
		* GameStats.ELITE_GOLD_MUL * float(pl.harvest)) + int(pl.gold_per_kill)
	el.is_dead = true
	battle.combat.cleanup_enemies()
	_check(_count_kind(Pickup.KIND_COUPON) == coupon0 + 1, "精英击杀必掉商店券")
	var gold_ok := false
	for pk in battle.pickups:
		if is_instance_valid(pk) and String(pk.kind) == Pickup.KIND_GOLD and int(pk.value) == exp_gold:
			gold_ok = true
	_check(gold_ok, "精英金币 = 模板 %d ×%.1f（期望面额 %d）" % [
		int(GameStats.ENEMY_TEMPLATES["Elite"]["gold"]), GameStats.ELITE_GOLD_MUL, exp_gold])
	# 对照组：普通怪不掉券
	var coupon1 := _count_kind(Pickup.KIND_COUPON)
	var sl = _spawn("Slime", Vector2(4000.0, 4000.0), "")
	sl.is_dead = true
	battle.combat.cleanup_enemies()
	_check(_count_kind(Pickup.KIND_COUPON) == coupon1, "普通怪击杀不掉商店券（对照）")


# ---------------------------------------------------------------- E. 商店券消费
func _t_coupon_shop() -> void:
	var pl = battle.player
	pl.shop_coupon = 0
	battle.combat.spawn_pickup(Pickup.KIND_COUPON, 0, pl.global_position + Vector2(20.0, 0.0))
	var pk = battle.pickups[battle.pickups.size() - 1]
	battle.combat.collect(pk)
	_check(int(pl.shop_coupon) == 1, "拾取商店券 → 库存 1 张（实际 %d）" % int(pl.shop_coupon))
	var base_disc := float(pl.shop_discount)
	battle._open_shop()
	_check(int(pl.shop_coupon) == 0, "进商店消费 1 张券（实际 %d）" % int(pl.shop_coupon))
	_check(_approx(float(battle._shop_discount_now()), base_disc * float(GameStats.COUPON_DISCOUNT)),
		"本店折扣 = 基础 %.2f × %.2f（实际 %.4f）" % [
			base_disc, float(GameStats.COUPON_DISCOUNT), float(battle._shop_discount_now())])
	# 对照：券已用完 → 恢复基础折扣
	battle._open_shop()
	_check(_approx(float(battle._shop_discount_now()), base_disc),
		"无券时折扣 = 基础折扣（对照 %.4f）" % float(battle._shop_discount_now()))
	battle._coupon_active = false
	battle.shop_panel.close()
	paused = false
	# 商店券不参与 recalc_stats（是「捡到的道具」而不是派生属性）
	pl.shop_coupon = 3
	pl.recalc_stats()
	_check(int(pl.shop_coupon) == 3, "recalc_stats 不会清掉商店券库存")


# ---------------------------------------------------------------- F. 真实开波路径
func _t_wave_spawn_path() -> void:
	battle.start_run()
	battle.spawn_remaining = 0
	battle.wave_num = 4                 # start_next_wave 自增 → 波 5
	battle.start_next_wave()
	_check(_elites().size() == GameStats.elite_count(5),
		"真实开波（波5）：精英 %d 只（实际 %d）" % [GameStats.elite_count(5), _elites().size()])
	battle.spawn_remaining = 0
	battle.wave_num = 7                 # → 波 8
	battle.start_next_wave()
	_check(_elites().size() == GameStats.elite_count(8),
		"真实开波（波8）：精英 %d 只（实际 %d）" % [GameStats.elite_count(8), _elites().size()])
	var affix_ok := true
	for e in _elites():
		if String(e.affix) == "" or not GameStats.ELITE_AFFIXES.has(String(e.affix)):
			affix_ok = false
	_check(affix_ok, "开波生成的精英都带合法词缀")
	# Boss 波（10）：Boss 无词缀、精英照常带词缀
	battle.spawn_remaining = 0
	battle.wave_num = 9                 # → 波 10
	battle.start_next_wave()
	var boss_found := false
	var boss_affix_ok := true
	for e in battle.enemies:
		if is_instance_valid(e) and e.behavior == "boss":
			boss_found = true
			if String(e.affix) != "":
				boss_affix_ok = false
	_check(boss_found, "波10 真实开波：Boss 已生成")
	_check(boss_affix_ok, "Boss 不带词缀（需求 §1/§5 红线）")
	_check(_elites().size() == GameStats.elite_count(10),
		"波10 精英数仍按公式（实际 %d）" % _elites().size())


# ---------------------------------------------------------------- 工具
## 直生成一只带词缀的精英（enforce_spawn_dist=false：探针要精确控制位置）。
func _spawn(type_name: String, pos: Vector2, affix: String) -> Node:
	battle.wave.spawn_enemy(type_name, pos, 1.0, false, affix)
	var e: Node = battle.enemies[battle.enemies.size() - 1]
	e.global_position = pos
	return e


## 打死一只怪（走真实 take_damage 路径 ⇒ 触发词缀死亡信号）。
func _boom(e: Node) -> void:
	e.is_dead = false
	e.take_damage(int(e.hp) + 1)


func _elites() -> Array:
	var out: Array = []
	for e in battle.enemies:
		if is_instance_valid(e) and e.type_name == "Elite":
			out.append(e)
	return out


func _count_type(t: String) -> int:
	var n := 0
	for e in battle.enemies:
		if is_instance_valid(e) and e.type_name == t:
			n += 1
	return n


func _count_kind(kind: String) -> int:
	var n := 0
	for pk in battle.pickups:
		if is_instance_valid(pk) and String(pk.kind) == kind:
			n += 1
	return n


func _check(cond: bool, label: String) -> void:
	checks += 1
	if cond:
		print("[PROBE]   OK   %s" % label)
	else:
		fails.append(label)
		print("[PROBE]   FAIL %s" % label)


func _approx(a: float, b: float) -> bool:
	return absf(a - b) <= maxf(1e-4, 1e-5 * maxf(absf(a), absf(b)))


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
