extends SceneTree
## 独立验证探针：武器融合进化（2026-10-08 第二梯队）。
##
## 回答四个验收问题：
##   ① 数据面闭环：6 配方齐备、extra 均为合法副武器、名字唯一
##   ② 卡生成条件按设计执行（未进化 / 副武器未满级 / 已融合 → 不出；全满足 → 必出末槽）
##   ③ 六个融合效果【真的生效】（环刃连奏 / 旋风连拳 / 落笔惊雷 / 寒心冰封 / 钞能导弹 / 剧毒薯泥）
##   ④ 边界与纪律（未融合零随机消耗零副作用、重开清空、护栏有效）
##
## 被验证的契约：
##   GameStats.WEAPON_FUSIONS / weapon_fusion / FUSION_* 常量
##   Player.fusion_id（reset 清空）
##   Battle._fusion_card / _generate_options 融合卡插入 / _on_upgrade_chosen "fusion" 分支
##   ExtraWeaponSystem.fusion_on_fired / fusion_on_hit / fusion_on_kill / fusion_on_splash /
##     _tick_fusion_blades / _launch_fusion_missile / _spawn_acid_pool_at
##
## 确定性：Battle 物理关闭 + 玩家站桩缴械 + 暴击置 0；概率类效果用 seed() 固定
## （结果对同一构建可复现），区间断言留足容差。
##
## 用法: godot --headless --path <项目>/game --script res://scripts/dev/_ProbeFusions.gd
## 退出码 0=PASS 1=FAIL（门禁用 grep -q "RESULT=PASS" 判定）

var battle: Node = null
var armed := false
var finished := false
var checks := 0
var fails: Array[String] = []


func _initialize() -> void:
	print("[PROBE] === 武器融合进化验证（6 配方 + 卡生成 + 效果实测）===")
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
	_sec_b_card_generation()
	_sec_c_apply()
	_sec_d_blade_combo()
	_sec_e_whirl()
	_sec_f_thunder()
	_sec_g_freeze()
	_sec_h_missile()
	_sec_i_pool()
	_sec_j_discipline()


# ================================================================ A. 数据面契约
func _sec_a_contracts() -> void:
	_section("A. 数据面契约（6 配方 / 合法 extra / 名字唯一）")
	_check(GameStats.WEAPON_FUSIONS.size() == 6,
		"WEAPON_FUSIONS 有 6 条（实际 %d）" % GameStats.WEAPON_FUSIONS.size())
	var names: Dictionary = {}
	for cid in GameStats.WEAPON_FUSIONS.keys():
		var c := String(cid)
		var f: Dictionary = GameStats.WEAPON_FUSIONS[cid]
		_check(GameStats.WEAPON_DEFS.has(c), "%s: 是合法主武器（WEAPON_DEFS 有登记）" % c)
		var eid := String(f["extra"])
		_check(GameStats.EXTRA_WEAPON_IDS.has(eid), "%s: extra=%s 是合法副武器" % [c, eid])
		var nm := String(f["name"])
		_check(nm != "" and not names.has(nm), "%s: 融合名非空且唯一（%s）" % [c, nm])
		names[nm] = true
		_check(String(f["desc"]) != "", "%s: desc 非空" % c)
		_check(not GameStats.weapon_fusion(c).is_empty(), "%s: weapon_fusion 查询命中" % c)
	_check(GameStats.weapon_fusion("nonexistent").is_empty(), "未知角色查询 → 空字典")
	# 常量与 desc 的同口径抽查（调常量忘改 desc 时这里会红）
	_check(GameStats.FUSION_THUNDER_CHANCE == 0.25, "落笔惊雷概率 == 0.25")
	_check(absf(GameStats.FUSION_SLOW_MUL - 0.55) <= 1e-6, "寒心冰封减速 == 0.55")
	_check(String(GameStats.WEAPON_FUSIONS["sad"]["desc"]).contains("0.55"),
		"寒心冰封 desc 与 FUSION_SLOW_MUL 同口径（含 0.55）")


# ================================================================ B. 卡生成条件
func _sec_b_card_generation() -> void:
	_section("B. 融合卡生成条件（必出末槽 / 三条件否定）")
	_prep()
	# B1 未进化：不出
	battle._current_reason = "level"
	battle._generate_options()
	_check(_find_fusion(battle._current_options) < 0, "未进化：不出融合卡")
	# B2 已进化 + 副武器未满级：不出
	var pl: Player = battle.player
	pl.weapon_evolved = true
	battle.extra.grant("orbit")
	battle._generate_options()
	_check(_find_fusion(battle._current_options) < 0, "已进化 + orbit Lv1：不出（材料未满）")
	# B3 已进化 + orbit 满级：必出（末槽）
	for i in 4:
		battle.extra.level_up("orbit")
	_check(battle.extra.level_of("orbit") == GameStats.extra_weapon_max_level("orbit"),
		"orbit 已升满 Lv%d" % battle.extra.level_of("orbit"))
	battle._generate_options()
	var idx := _find_fusion(battle._current_options)
	_check(idx >= 0, "已进化 + orbit 满级：融合卡必出")
	if idx >= 0:
		var card: Dictionary = battle._current_options[idx]
		# 落槽规则：末槽；若副武器卡恰好占末槽则前移一位（避让护栏）。
		# 两处都 > 0 ⇒ select(0) 的自检行为永不受融合卡影响。
		var last: int = battle._current_options.size() - 1
		_check(idx == last or idx == last - 1,
			"融合卡落末槽区（last=%d，实际 %d；避副武器卡槽时前移一位）" % [last, idx])
		_check(idx > 0, "融合卡绝不占 slot 0（自检 select(0) 行为不漂）")
		_check(String(card["kind"]) == "fusion", "卡 kind == fusion")
		_check(String(card["fusion_id"]) == "basic", "卡 fusion_id == basic（嘉豪）")
		_check(String(card["weapon_id"]) == "orbit", "卡 weapon_id == orbit（图标沿用副武器）")
		_check(String(card["name"]).contains("环刃连奏"), "卡名含融合名（环刃连奏）")
		_check(int(card["cost_tier"]) == 3, "cost_tier == 3（最高稀有档）")


# ================================================================ C. 应用与清空
func _sec_c_apply() -> void:
	_section("C. 应用融合卡（状态落地 / 副武器保留 / 已融合不再出 / 重开清空）")
	var pl: Player = battle.player
	battle._generate_options()
	var idx := _find_fusion(battle._current_options)
	if idx < 0:
		_check(false, "前置失败：融合卡未生成，跳过应用测试")
		return
	battle._on_upgrade_chosen(battle._current_options[idx], idx)
	_check(pl.fusion_id == "basic", "应用后 fusion_id == basic（实际 '%s'）" % pl.fusion_id)
	_check(battle.extra.level_of("orbit") == 5, "副武器保留（orbit 仍 Lv5，融合不消耗）")
	_check(not pl.weapon_form().is_empty(), "第二形态仍在（融合与二形态叠加）")
	# 已融合：不再出
	battle._generate_options()
	_check(_find_fusion(battle._current_options) < 0, "已融合：本局不再出融合卡")
	# 重开清空
	battle.start_run()
	_check(battle.player.fusion_id == "", "重开一局：fusion_id 清空")
	_check(battle.extra.owned_count() == 0, "重开一局：副武器清空（对照项）")


# ================================================================ D. 环刃连奏
func _sec_d_blade_combo() -> void:
	_section("D. 环刃连奏（basic × orbit）：甩 2 片 / 节流 / 命中 / 护栏")
	_prep()
	var pl: Player = battle.player
	pl.weapon_evolved = true
	pl.fusion_id = "basic"
	var aim: Vector2 = pl.global_position + Vector2(100.0, 0.0)
	battle.extra.fusion_on_fired(aim)
	_check(battle.extra._fusion_blades.size() == 2, "开火甩出 2 片飞刃（实际 %d）" % battle.extra._fusion_blades.size())
	# 节流：0.6s 内第二次不甩
	battle.extra.fusion_on_fired(aim)
	_check(battle.extra._fusion_blades.size() == 2, "0.6s 内第二次开火被节流挡下")
	# 偏角：±25°
	if battle.extra._fusion_blades.size() == 2:
		var v0: Vector2 = battle.extra._fusion_blades[0]["vel"]
		var v1: Vector2 = battle.extra._fusion_blades[1]["vel"]
		var sep := rad_to_deg(absf(wrapf(v0.angle() - v1.angle(), -PI, PI)))
		_check(absf(sep - 50.0) <= 0.5, "两片偏角差 ≈ 50°（实际 %.1f）" % sep)
	# 冷却推进后恢复
	battle.extra._fusion_blade_cd = 0.0
	battle.extra.fusion_on_fired(aim)
	_check(battle.extra._fusion_blades.size() == 4, "冷却走完后再开火恢复甩刃（+2 → 4）")
	# 命中伤害：正前方放一只血牛，步进飞刃
	# 2026-10-09 批量测修正：旧版瞄准方向 == 目标方向 ⇒ 两片 ±SIDE(25°) 在 120px 处
	# 横移 ≈51px，双双超出判定窗口（Ox 24 + 刃 14 = 38px），打不中（首跑假红）。
	# 改为「瞄准方向 = 目标方向 + SIDE」⇒ base−SIDE 那片正好直飞目标（正对命中）。
	_clear_blades()
	var ox_pos: Vector2 = pl.global_position + Vector2(120.0, 0.0)
	var e := _spawn("Ox", ox_pos)
	var hp0: float = e.hp
	battle.extra._fusion_blade_cd = 0.0
	var side := deg_to_rad(GameStats.FUSION_BLADE_SIDE_DEG)
	battle.extra.fusion_on_fired(pl.global_position + (ox_pos - pl.global_position).rotated(side))
	_step_blades(0.5, 25)
	_check(e.hp < hp0, "飞刃命中造成伤害（%.0f → %.0f）" % [hp0, e.hp])
	# 护栏：满 12 片后不再甩
	_clear_blades()
	for i in 10:
		battle.extra._fusion_blade_cd = 0.0
		battle.extra.fusion_on_fired(aim)
	_check(battle.extra._fusion_blades.size() == GameStats.MAX_FUSION_BLADES,
		"场上飞刃封顶 MAX_FUSION_BLADES=%d（实际 %d）" % [
			GameStats.MAX_FUSION_BLADES, battle.extra._fusion_blades.size()])
	battle.extra._fusion_blade_cd = 0.0
	battle.extra.fusion_on_fired(aim)
	_check(battle.extra._fusion_blades.size() == GameStats.MAX_FUSION_BLADES, "满员时再甩被静默放弃")


# ================================================================ E. 旋风连拳
func _sec_e_whirl() -> void:
	_section("E. 旋风连拳（kangaroo × orbit）：每 5 次开火甩一圈 4 片")
	_prep()
	var pl: Player = battle.player
	pl.fusion_id = "kangaroo"
	var aim: Vector2 = pl.global_position + Vector2(100.0, 0.0)
	for i in 4:
		battle.extra.fusion_on_fired(aim)
	_check(battle.extra._fusion_blades.size() == 0,
		"前 4 次开火不甩（实际 %d 片）" % battle.extra._fusion_blades.size())
	battle.extra.fusion_on_fired(aim)
	_check(battle.extra._fusion_blades.size() == 4, "第 5 次开火甩一圈 4 片（实际 %d）" % battle.extra._fusion_blades.size())
	# 环形均分：相邻间隔 90°（2026-10-09 批量测修正：旧版用 absf(wrapf(...)) 求「第 k 片
	# 与第 0 片夹角」—— 该式值域只有 [0,180°]，k=3 期望的 270° 永远表达不出来（首跑假红）。
	# 改为「角度归一化到 [0,360) 排序 → 逐对相邻间隔」判定。
	if battle.extra._fusion_blades.size() == 4:
		var angs: Array[float] = []
		for b in battle.extra._fusion_blades:
			angs.append(fposmod((b["vel"] as Vector2).angle(), TAU))
		angs.sort()
		var ok := true
		for k in 4:
			var step: float = angs[0] + TAU - angs[3]
			if k < 3:
				step = angs[k + 1] - angs[k]
			if absf(rad_to_deg(step) - 90.0) > 0.5:
				ok = false
		_check(ok, "4 片环形均分（间隔 90°）")


# ================================================================ F. 落笔惊雷
func _sec_f_thunder() -> void:
	_section("F. 落笔惊雷（study × lightning）：25% 概率劈雷")
	_prep()
	var pl: Player = battle.player
	pl.fusion_id = "study"
	var e := _spawn("Ox", pl.global_position + Vector2(120.0, 0.0))
	seed(7)
	var hits := 0
	for i in 200:
		var before: float = e.hp
		battle.extra.fusion_on_hit(e)
		if e.hp < before:
			hits += 1
	_check(hits >= 20 and hits <= 80,
		"200 次命中 → 劈雷 %d 次（25%% 期望 50，seed 固定可复现）" % hits)
	# 非 study 融合不出雷（换成 sad 再打 50 次零雷）
	pl.fusion_id = "sad"
	seed(7)
	var no_thunder := true
	for i in 50:
		var before2: float = e.hp
		battle.extra.fusion_on_hit(e)
		if e.hp < before2:
			no_thunder = false
	_check(no_thunder, "sad 融合（非 study）：命中钩子不劈雷")


# ================================================================ G. 寒心冰封
func _sec_g_freeze() -> void:
	_section("G. 寒心冰封（sad × ice_nova）：100% 减速 / Boss 折扣 / 刷新式")
	_prep()
	var pl: Player = battle.player
	pl.fusion_id = "sad"
	var e := _spawn("Ox", pl.global_position + Vector2(120.0, 0.0))
	battle.extra.fusion_on_hit(e)
	_check(absf(e._slow_mul - GameStats.FUSION_SLOW_MUL) <= 1e-6,
		"普通怪减速乘区 == %.2f（实际 %.3f）" % [GameStats.FUSION_SLOW_MUL, e._slow_mul])
	_check(absf(e._slow_t - GameStats.FUSION_SLOW_DUR) <= 1e-6,
		"减速持续 == %.1fs（实际 %.2f）" % [GameStats.FUSION_SLOW_DUR, e._slow_t])
	# 刷新式：二次命中不叠加（时长取 max、乘区取 min）
	e._slow_t = 0.5
	battle.extra.fusion_on_hit(e)
	_check(absf(e._slow_t - GameStats.FUSION_SLOW_DUR) <= 1e-6, "二次命中刷新时长（0.5 → 3.0）")
	_check(absf(e._slow_mul - GameStats.FUSION_SLOW_MUL) <= 1e-6, "乘区不叠加（仍为单次值）")
	# Boss 折扣：lerp(0.55, 1.0, 0.5) = 0.775
	var boss := _spawn("Boss", pl.global_position + Vector2(240.0, 0.0))
	battle.extra.fusion_on_hit(boss)
	var expect := lerpf(GameStats.FUSION_SLOW_MUL, 1.0, 1.0 - GameStats.EXTRA_SLOW_BOSS_MUL)
	_check(absf(boss._slow_mul - expect) <= 1e-6,
		"Boss 折扣减速 == %.3f（实际 %.3f，EXTRA_SLOW_BOSS_MUL=%.1f）" % [
			expect, boss._slow_mul, GameStats.EXTRA_SLOW_BOSS_MUL])


# ================================================================ H. 钞能导弹
func _sec_h_missile() -> void:
	_section("H. 钞能导弹（finance × missile）：20% 击杀触发 / 护栏")
	_prep()
	var pl: Player = battle.player
	pl.fusion_id = "finance"
	var e := _spawn("Ox", pl.global_position + Vector2(120.0, 0.0))
	_clear_extra_fx()
	seed(11)
	var pos: Vector2 = pl.global_position + Vector2(60.0, 0.0)
	for i in 100:
		battle.extra.fusion_on_kill(pos)
	# 100 次击杀 × 20% ≈ 20 枚 > MAX_MISSILES(12) ⇒ 预期【顶满】——
	# 这一条同时证明「真的在生成」与「护栏生效」（导弹不自行消失，探针未步进 tick）。
	var added: int = battle.extra._missiles.size()
	_check(added >= 8 and added <= GameStats.MAX_MISSILES,
		"100 次击杀 → 导弹 %d 枚（20%%；命中充足时顶满 %d，seed 固定可复现）" % [
			added, GameStats.MAX_MISSILES])
	# 导弹参数：伤害基数 = atk × 1.4、爆炸半径 = 60
	if added > 0:
		var md: Dictionary = battle.extra._missiles[0]
		_check(absf(float(md["blast"]) - GameStats.FUSION_MISSILE_BLAST) <= 1e-6,
			"导弹爆炸半径 == %.0f" % float(md["blast"]))
		_check(int(md["dmg"]) == roundi(float(pl.atk) * GameStats.FUSION_MISSILE_DMG_MUL),
			"导弹伤害基数 == atk × %.1f（%d）" % [GameStats.FUSION_MISSILE_DMG_MUL, int(md["dmg"])])
	# 满员护栏：再 30 次击杀数量恒 ≤ 12（新弹满员被拒，旧弹保留 —— 与毒池「顶掉最旧」不同口径）
	for i in 30:
		battle.extra.fusion_on_kill(pos)
	_check(battle.extra._missiles.size() <= GameStats.MAX_MISSILES,
		"再击杀 30 次：导弹数恒 ≤ MAX_MISSILES=%d（实际 %d）" % [
			GameStats.MAX_MISSILES, battle.extra._missiles.size()])
	# 非 finance 不触发
	pl.fusion_id = "study"
	var before_other: int = battle.extra._missiles.size()
	seed(11)
	for i in 30:
		battle.extra.fusion_on_kill(pos)
	_check(battle.extra._missiles.size() == before_other,
		"study 融合：击杀钩子不射导弹（%d → %d）" % [before_other, battle.extra._missiles.size()])


# ================================================================ I. 剧毒薯泥
func _sec_i_pool() -> void:
	_section("I. 剧毒薯泥（potato × acid）：35% 溅射留池 / 参数 / 护栏")
	_prep()
	var pl: Player = battle.player
	pl.fusion_id = "potato"
	_clear_extra_fx()
	var pos: Vector2 = pl.global_position + Vector2(80.0, 0.0)
	seed(13)
	for i in 100:
		battle.extra.fusion_on_splash(pos)
	_check(battle.extra._pools.size() == GameStats.MAX_ACID_POOLS,
		"100 次溅射 → 池数顶满 MAX_ACID_POOLS=%d（实际 %d，35%% 远超额）" % [
			GameStats.MAX_ACID_POOLS, battle.extra._pools.size()])
	if battle.extra._pools.size() > 0:
		var pd: Dictionary = battle.extra._pools[0]
		_check(absf(float(pd["radius"]) - GameStats.FUSION_POOL_RADIUS) <= 1e-6,
			"池半径 == %.0f" % float(pd["radius"]))
		_check(absf(float(pd["dps"]) - GameStats.FUSION_POOL_DPS_MUL) <= 1e-6,
			"池伤害基数 == %.1f" % float(pd["dps"]))
		_check(absf(float(pd["vuln"]) - 1.0) <= 1e-6, "池不带中毒易伤（vuln == 1.0）")
	# 非 potato 不留池
	_clear_extra_fx()
	pl.fusion_id = "sad"
	seed(13)
	for i in 30:
		battle.extra.fusion_on_splash(pos)
	_check(battle.extra._pools.size() == 0, "sad 融合：溅射钩子不留毒池")


# ================================================================ J. 纪律
func _sec_j_discipline() -> void:
	_section("J. 纪律（未融合零随机消耗零副作用 / 重开清空）")
	_prep()
	var pl: Player = battle.player
	var e := _spawn("Ox", pl.global_position + Vector2(120.0, 0.0))
	var aim: Vector2 = pl.global_position + Vector2(100.0, 0.0)
	var pos: Vector2 = pl.global_position + Vector2(60.0, 0.0)
	# 未融合：钩子零消费 —— seed 后先记 r1，再 seed 调四个钩子，r2 必须逐位相同
	seed(99)
	var r1 := randf()
	seed(99)
	battle.extra.fusion_on_fired(aim)
	battle.extra.fusion_on_hit(e)
	battle.extra.fusion_on_kill(pos)
	battle.extra.fusion_on_splash(pos)
	var r2 := randf()
	_check(absf(r1 - r2) <= 1e-9,
		"未融合：四个钩子零随机消耗（randf 序列一致 %.9f == %.9f）" % [r1, r2])
	_check(battle.extra._fusion_blades.size() == 0, "未融合：不产生飞刃")
	_check(battle.extra._missiles.size() == 0, "未融合：不产生导弹")
	_check(battle.extra._pools.size() == 0, "未融合：不产生毒池")
	_check(battle.extra._fusion_fired == 0, "未融合：旋风计数不涨")
	# 全链路对照：走 combat.on_player_fired 也触发（basic）
	pl.weapon_evolved = true
	pl.fusion_id = "basic"
	battle.extra._fusion_blade_cd = 0.0
	battle.combat.on_player_fired(aim, 1)
	_check(battle.extra._fusion_blades.size() == 2, "端到端：combat.on_player_fired → 甩刃 2 片")
	# 重开清空飞刃与节流
	battle.start_run()
	_check(battle.extra._fusion_blades.size() == 0 and battle.extra._fusion_blade_cd == 0.0
		and battle.extra._fusion_fired == 0, "重开一局：飞刃/节流/计数全部清空")


# ================================================================ 工具
## 重新开局并停物理/缴械（与 _ProbeActiveItems 同一套确定性夹具）。
func _prep() -> void:
	battle.start_run()
	battle.set_physics_process(false)
	battle.spawn_remaining = 0
	var pl: Player = battle.player
	pl.set_physics_process(false)
	pl.autopilot = false
	pl.attack_enabled = false
	pl.god_mode = true
	pl.crit = 0.0            # 确定性：randf() < 0 恒 false
	pl.gold_per_kill = 0
	pl.luck = 0.0


## 在 _current_options 里找融合卡（返回下标；-1 = 没有）。
func _find_fusion(options: Array) -> int:
	for i in options.size():
		if String((options[i] as Dictionary).get("kind", "")) == "fusion":
			return i
	return -1


## 生成一只静止的敌人（血厚，避免测试中被一击打死）。
func _spawn(type_name: String, pos: Vector2) -> Node2D:
	battle.wave.spawn_enemy(type_name, pos, 1.0, false)
	var e: Node2D = battle.enemies[battle.enemies.size() - 1]
	e.hp = 100000
	e.max_hp = 100000
	e.set_physics_process(false)
	return e


## 手动步进融合飞刃（deterministic：不依赖物理帧）。
func _step_blades(sec: float, steps: int) -> void:
	var dt := sec / float(steps)
	for i in steps:
		battle.extra._tick_fusion_blades(dt)


## 清空融合飞刃（节点同步释放）。
func _clear_blades() -> void:
	for bd in battle.extra._fusion_blades:
		var n: Node2D = bd["node"]
		if is_instance_valid(n):
			n.queue_free()
	battle.extra._fusion_blades.clear()


## 清空飞刃 + 导弹 + 毒池（跨段隔离用）。
func _clear_extra_fx() -> void:
	_clear_blades()
	for m in battle.extra._missiles:
		var mn: Node2D = m["node"]
		if is_instance_valid(mn):
			mn.queue_free()
	battle.extra._missiles.clear()
	for pd in battle.extra._pools:
		var pn: Node2D = pd["node"]
		if is_instance_valid(pn):
			pn.queue_free()
	battle.extra._pools.clear()


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
