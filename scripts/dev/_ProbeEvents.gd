extends SceneTree
## 独立验证探针：局内事件系统（2026-10-08 第二梯队批次）。
##
## 回答四个验收问题：
##   ① 事件实体「走近触发 / 离开保留 / 走开重触发 / 用掉消失」全链路可用
##   ② 四种事件各自的语义正确（祭坛代价与收益 / 黑市稀有池与加价 / 挑战计时与发奖 / 宝箱怪现形）
##   ③ 波末与重开的收尾正确（未消费实体清场、进行中挑战按成绩结算、未踩宝箱怪静默收走）
##   ④ 生成守卫正确（自检/探针进程不自动生成 —— 确定性基线不受事件系统影响）
##
## 被验证的契约：
##   GameStats.EVENT_* / ALTAR_* / CHALLENGE_* / BLACK_MARKET_* / altar_item_roll /
##     black_market_roll / Mimic 模板 + CODEX_ORDER + AssetDB 登记
##   BattleEvent（armed / consume / display_name）
##   Battle._maybe_spawn_event / _spawn_event / _tick_events / _trigger_event / _consume_event /
##     _open_altar / _on_altar_chosen / _open_black_market / _on_black_market_closed /
##     _open_pillar_confirm / _on_pillar_confirm_chosen / _tick_challenge / _end_challenge /
##     _on_mimic_revealed / _free_all_events
##   CombatResolver.collect(KIND_MIMIC) / collect_all_pickups 的宝箱怪例外 /
##     cleanup_enemies 的 Mimic 必掉宝箱
##
## 确定性：Battle 物理关闭 + 玩家站桩缴械；事件全部手动生成 / 手动步进。
##
## 用法: godot --headless --path <项目>/game --script res://scripts/dev/_ProbeEvents.gd
## 退出码 0=PASS 1=FAIL（门禁用 grep -q "RESULT=PASS" 判定）

var battle: Node = null
var armed := false
var finished := false
var checks := 0
var fails: Array[String] = []


func _initialize() -> void:
	print("[PROBE] === 局内事件系统验证（祭坛 / 黑市 / 挑战柱 / 宝箱怪）===")
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
	_sec_b_trigger_loop()
	_sec_c_altar()
	_sec_d_challenge()
	_sec_e_black_market()
	_sec_f_mimic()
	_sec_g_spawn_guard()
	_sec_h_cleanup()


# ================================================================ A. 数据面契约
func _sec_a_contracts() -> void:
	_section("A. 数据面契约（常量 / 模板 / 池子函数）")
	_check(GameStats.EVENT_DEFS.size() == 4, "EVENT_DEFS 4 项（祭坛/黑市/挑战柱/宝箱怪）")
	for k in ["altar", "market", "pillar", "mimic"]:
		_check(GameStats.EVENT_DEFS.has(k), "EVENT_DEFS 含 %s" % k)
	_check(GameStats.EVENT_KINDS.size() == 3 and not GameStats.EVENT_KINDS.has("mimic"),
		"EVENT_KINDS 3 项且不含宝箱怪（它走 Pickup 伪装）")
	_check(int(GameStats.EVENT_MIN_WAVE) >= 2, "EVENT_MIN_WAVE >= 2（新手保护）")
	var chance := float(GameStats.EVENT_SPAWN_CHANCE)
	_check(chance > 0.0 and chance <= 1.0, "EVENT_SPAWN_CHANCE ∈ (0,1]（实际 %.2f）" % chance)
	var mchance := float(GameStats.EVENT_MIMIC_CHANCE)
	_check(mchance > 0.0 and mchance < 1.0, "EVENT_MIMIC_CHANCE ∈ (0,1)（实际 %.2f）" % mchance)
	_check(float(GameStats.ALTAR_HP_COST_RATIO) > 0.0 and float(GameStats.ALTAR_HP_COST_RATIO) < 1.0,
		"ALTAR_HP_COST_RATIO ∈ (0,1)")
	_check(int(GameStats.ALTAR_ITEM_COUNT) >= 1 and int(GameStats.ALTAR_MASTERY_STACKS) >= 1,
		"祭坛奖励件数 / 精通层数 >= 1")
	_check(int(GameStats.CHALLENGE_FULL_KILLS) > int(GameStats.CHALLENGE_HALF_KILLS)
		and int(GameStats.CHALLENGE_HALF_KILLS) > 0, "挑战门槛 FULL > HALF > 0")
	_check(int(GameStats.CHALLENGE_FULL_GOLD) > int(GameStats.CHALLENGE_HALF_GOLD),
		"挑战奖励 FULL > HALF")
	_check(int(GameStats.CHALLENGE_ENEMY_COUNT) > int(GameStats.CHALLENGE_FULL_KILLS),
		"挑战援军数 > 全奖门槛（杀满可达成）")
	_check(float(GameStats.BLACK_MARKET_PRICE_MUL) > 1.0, "黑市价格倍率 > 1（贵）")
	_check(int(GameStats.BLACK_MARKET_SLOTS) >= 1, "黑市槽位 >= 1")

	# Mimic 模板 / 图鉴 / 立绘
	_check(GameStats.ENEMY_TEMPLATES.has("Mimic"), "Mimic 在 ENEMY_TEMPLATES")
	_check(GameStats.is_codex_enemy("Mimic"), "Mimic 在 CODEX_ORDER（图鉴可达）")
	_check(not GameStats.codex_name("Mimic").is_empty() and not GameStats.codex_desc("Mimic").is_empty(),
		"Mimic 有 codex 文案")
	_check(AssetDB.enemy_sprite("Mimic") != null, "Mimic 立绘可加载（mimic.png 已入库）")

	# altar_item_roll：n 件、不重复、不含商店专用道具
	var picks := GameStats.altar_item_roll(2)
	_check(picks.size() == 2, "altar_item_roll(2) 返回 2 件（实际 %d）" % picks.size())
	_check(picks[0] != picks[1], "altar_item_roll 不重复（%s / %s）" % [picks[0], picks[1]])
	var all_picks := GameStats.altar_item_roll(200)
	_check(not all_picks.has("s_reroll"), "altar_item_roll 恒不含 s_reroll（商店专用）")
	_check(all_picks.size() == GameStats.ITEM_DEFS.size() - 1,
		"超额请求返回全池去 s_reroll（%d == %d-1）" % [all_picks.size(), GameStats.ITEM_DEFS.size()])

	# black_market_roll：全 rare+、不重复、数量正确
	var stock := GameStats.black_market_roll(int(GameStats.BLACK_MARKET_SLOTS))
	_check(stock.size() == int(GameStats.BLACK_MARKET_SLOTS),
		"black_market_roll(%d) 返回 %d 件" % [int(GameStats.BLACK_MARKET_SLOTS), stock.size()])
	var rare_ok := true
	for id in stock:
		var rarity := String(GameStats.ITEM_DEFS[id]["rarity"])
		if rarity == "common" or rarity == "uncommon":
			rare_ok = false
	_check(rare_ok, "黑市商品全部 rare 及以上（%s）" % str(stock))
	_check(stock.size() >= 2 and stock[0] != stock[1], "黑市商品不重复")


# ================================================================ B. 触发循环
func _sec_b_trigger_loop() -> void:
	_section("B. 触发循环：走近触发 / 离开保留 / 走开重触发 / 用掉消失")
	_prep()
	battle._spawn_event("altar")
	_check(battle.events.size() == 1, "生成祭坛实体（events=1）")
	var ev: BattleEvent = battle.events[0]
	_check(ev.armed, "新实体默认 armed")
	_check(ev.display_name() == "献祭祭坛", "display_name == 献祭祭坛")
	# 走近触发
	battle.player.global_position = ev.global_position + Vector2(30.0, 0.0)
	battle._tick_events(0.05)
	_check(battle.upgrade_panel.visible, "走近后面板弹出")
	_check(battle.upgrade_panel._title.text == "献祭祭坛", "面板标题 == 献祭祭坛（实际「%s」）" % battle.upgrade_panel._title.text)
	_check(battle.upgrade_panel._skip_btn.visible, "面板有「离开」出口（skip 按钮可见）")
	_check(not ev.armed, "触发后 armed=false（防连环弹）")
	_check(int(battle.state) == int(battle.State.UPGRADE), "触发时 state == UPGRADE")
	# 「离开」：走真实链路（按钮 → 面板自收尾 hide_panel → Battle 回调）。
	# 2026-10-09 批量测修正：旧版直调 battle._on_panel_skip() 跳过了面板自收尾，
	# visible 断言假红（真实链路在 _on_skip_pressed 里先 hide_panel 再回调）。
	battle.upgrade_panel._on_skip_pressed()
	_check(not battle.upgrade_panel.visible, "离开后关闭面板")
	_check(int(battle.state) == int(battle.State.FIGHTING), "离开后 state 回 FIGHTING")
	_check(battle.events.size() == 1 and is_instance_valid(ev), "离开后实体保留（未消费）")
	# 走开 → re-arm → 回来重触发
	battle.player.global_position = ev.global_position + Vector2(400.0, 0.0)
	battle._tick_events(0.05)
	_check(ev.armed, "走远（> TRIGGER×REARM）后重新武装")
	battle.player.global_position = ev.global_position + Vector2(30.0, 0.0)
	battle._tick_events(0.05)
	_check(battle.upgrade_panel.visible, "走回后重新触发弹出")
	battle._on_panel_skip()
	# 用掉消失
	battle._consume_event(ev)
	_check(battle.events.is_empty(), "消费后 events 清空")
	_check(ev._consumed, "消费后实体进入淡出自毁")


# ================================================================ C. 献祭祭坛
func _sec_c_altar() -> void:
	_section("C. 祭坛：血祭 / 金祭代价与收益 / 金币不足过滤")
	_prep()
	# 金币充足：两张交易卡都在
	battle.player.gold = 200
	battle._open_altar()
	_check(battle.upgrade_panel._options.size() == 2, "金币充足时 2 张交易卡（实际 %d）" % battle.upgrade_panel._options.size())
	battle._on_panel_skip()
	# 金币不足：只剩血祭
	battle.player.gold = 10
	battle._open_altar()
	_check(battle.upgrade_panel._options.size() == 1, "金币不足时只剩血祭（实际 %d）" % battle.upgrade_panel._options.size())
	battle._on_panel_skip()
	# 血祭：扣当前生命的 40%、保底不低于 1
	battle.player.gold = 100
	var hp0: float = battle.player.hp
	battle._spawn_event("altar")
	battle._pending_event = battle.events[0]
	battle._on_altar_chosen({"kind": "altar_blood"}, 0)
	var expect_hp := maxf(1.0, hp0 * (1.0 - float(GameStats.ALTAR_HP_COST_RATIO)))
	_check(absf(battle.player.hp - expect_hp) <= 0.5,
		"血祭扣血：%.1f → %.1f（期望 %.1f）" % [hp0, battle.player.hp, expect_hp])
	_check(battle.player.gold == 100, "血祭不动金币")
	_check(battle.events.is_empty(), "成交后祭坛被消费（消失）")
	_check(int(battle.state) == int(battle.State.FIGHTING), "成交后 state 回 FIGHTING")
	# 金祭：扣金币 50%、精通 +2 层
	var lv0: int = int(battle.player.weapon_level)
	battle._spawn_event("altar")
	battle._pending_event = battle.events[0]
	battle._on_altar_chosen({"kind": "altar_gold"}, 0)
	_check(battle.player.gold == 50, "金祭扣当前金币 50%%（100 → %d）" % battle.player.gold)
	_check(int(battle.player.weapon_level) == lv0 + int(GameStats.ALTAR_MASTERY_STACKS),
		"金祭给武器精通 +%d（%d → %d）" % [int(GameStats.ALTAR_MASTERY_STACKS), lv0, int(battle.player.weapon_level)])


# ================================================================ D. 限时挑战
func _sec_d_challenge() -> void:
	_section("D. 挑战柱：援军生成 / 计时 / 全奖 / 半奖 / 失败")
	_prep()
	battle._spawn_event("pillar")
	battle._pending_event = battle.events[0]
	battle._open_pillar_confirm()
	_check(battle.upgrade_panel.visible and battle.upgrade_panel._title.text == "挑战柱",
		"挑战柱确认面板弹出")
	_check(battle.upgrade_panel._skip_btn.visible, "挑战柱有「离开」出口")
	var enemies0: int = battle.enemies.size()
	battle._on_pillar_confirm_chosen({}, 0)
	_check(bool(battle._challenge_active), "确认后挑战激活")
	_check(absf(battle._challenge_left - float(GameStats.CHALLENGE_TIME)) <= 1e-3,
		"计时从 %.0f 秒起（实际 %.2f）" % [float(GameStats.CHALLENGE_TIME), battle._challenge_left])
	_check(battle.enemies.size() == enemies0 + int(GameStats.CHALLENGE_ENEMY_COUNT),
		"环形援军 +%d 只（%d → %d）" % [int(GameStats.CHALLENGE_ENEMY_COUNT), enemies0, battle.enemies.size()])
	_check(battle.events.is_empty(), "挑战柱被消费（消失）")
	# 计时推进 + 击杀进度
	battle._tick_challenge(5.0)
	_check(absf(battle._challenge_left - (float(GameStats.CHALLENGE_TIME) - 5.0)) <= 1e-3,
		"推进 5 秒后剩 %.1f 秒（实际 %.2f）" % [float(GameStats.CHALLENGE_TIME) - 5.0, battle._challenge_left])
	battle.kills += int(GameStats.CHALLENGE_FULL_KILLS)
	battle._tick_challenge(0.1)
	_check(int(battle._challenge_dead) == int(GameStats.CHALLENGE_FULL_KILLS),
		"击杀进度 = kills 差值（%d）" % battle._challenge_dead)
	# 全奖结算
	var gold0: int = battle.player.gold
	battle._end_challenge()
	_check(not bool(battle._challenge_active), "结算后挑战关闭")
	_check(battle.player.gold >= gold0 + int(GameStats.CHALLENGE_FULL_GOLD),
		"全奖 >= %d 金币（%d → %d）" % [int(GameStats.CHALLENGE_FULL_GOLD), gold0, battle.player.gold])
	# 半奖
	_prep()
	battle._challenge_active = true
	battle._challenge_base_kills = battle.kills
	battle._challenge_dead = int(GameStats.CHALLENGE_HALF_KILLS)
	var gold1: int = battle.player.gold
	battle._end_challenge()
	_check(battle.player.gold >= gold1 + int(GameStats.CHALLENGE_HALF_GOLD),
		"半奖 >= %d 金币（%d → %d）" % [int(GameStats.CHALLENGE_HALF_GOLD), gold1, battle.player.gold])
	# 失败（击杀不足半奖线）
	_prep()
	battle._challenge_active = true
	battle._challenge_base_kills = battle.kills
	battle._challenge_dead = int(GameStats.CHALLENGE_HALF_KILLS) - 1
	var gold2: int = battle.player.gold
	battle._end_challenge()
	_check(battle.player.gold == gold2, "击杀不足半奖线：不发金币（%d）" % battle.player.gold)


# ================================================================ E. 黑市
func _sec_e_black_market() -> void:
	_section("E. 黑市：稀有池 / 加价 / 离开回收事件")
	_prep()
	battle.player.gold = 999
	battle._spawn_event("market")
	battle._pending_event = battle.events[0]
	battle._open_black_market()
	var sp: ShopPanel = battle.shop_panel
	_check(sp.visible, "黑市面板弹出（复用 ShopPanel）")
	_check(sp._hint.text.contains("黑市"), "标题换皮为黑市（实际「%s」）" % sp._hint.text)
	_check(sp._leave_btn != null and sp._leave_btn.text == "离开黑市",
		"离开按钮文案 == 离开黑市（实际「%s」）" % (sp._leave_btn.text if sp._leave_btn != null else ""))
	_check(sp._ids.size() == int(GameStats.BLACK_MARKET_SLOTS),
		"货架 %d 件（实际 %d）" % [int(GameStats.BLACK_MARKET_SLOTS), sp._ids.size()])
	var rare_ok := true
	var price_ok := true
	for i in sp._ids.size():
		var rarity := String(GameStats.ITEM_DEFS[sp._ids[i]]["rarity"])
		if rarity == "common" or rarity == "uncommon":
			rare_ok = false
		var expect := maxi(1, roundi(float(GameStats.shop_price(sp._ids[i], 1.0))
			* float(GameStats.BLACK_MARKET_PRICE_MUL)))
		if sp._prices[i] != expect:
			price_ok = false
	_check(rare_ok, "黑市只卖 rare 及以上")
	_check(price_ok, "价格 = 基础价 × %.1f（逐件复算一致）" % float(GameStats.BLACK_MARKET_PRICE_MUL))
	# 关闭走真实链路（_leave → close 自收尾 → Battle 回调）。同祭坛修正（2026-10-09）：
	# 旧版直调 battle._on_black_market_closed() 跳过面板自收尾，visible 断言假红。
	sp._leave()
	_check(not sp.visible, "关闭后黑市面板收起")
	_check(int(battle.state) == int(battle.State.FIGHTING), "关闭后 state 回 FIGHTING")
	_check(battle.events.is_empty(), "黑市关闭即消费事件（一锤子买卖）")


# ================================================================ F. 宝箱怪
func _sec_f_mimic() -> void:
	_section("F. 宝箱怪：伪装生成 / 踩到现形 / 死亡掉真宝箱 / 波末豁免回收")
	_prep()
	battle._spawn_mimic_item()
	_check(battle.pickups.size() == 1 and battle.pickups[0].kind == Pickup.KIND_MIMIC,
		"生成一个 KIND_MIMIC 掉落物")
	var mk: Pickup = battle.pickups[0]
	# 踩到现形（走 collect 真链路）
	var enemies0: int = battle.enemies.size()
	battle.combat.collect(mk)
	_check(battle.enemies.size() == enemies0 + 1, "踩到后场上多一只敌人")
	var mim: Enemy = battle.enemies[battle.enemies.size() - 1]
	_check(String(mim.type_name) == "Mimic", "现形的敌人 type_name == Mimic（实际 %s）" % mim.type_name)
	_check(int(battle.state) == int(battle.State.FIGHTING), "战斗中现形不弹面板")
	# 死亡掉真宝箱
	var chests0 := _count_chest()
	mim.take_damage(mim.hp * 100)
	battle.combat.cleanup_enemies()
	_check(_count_chest() > chests0, "Mimic 死亡必掉宝箱（%d → %d）" % [chests0, _count_chest()])
	# 波末豁免：未踩的宝箱怪静默收走、不现形
	_prep()
	battle._spawn_mimic_item()
	var enemies1: int = battle.enemies.size()
	battle.combat.collect_all_pickups()
	_check(battle.enemies.size() == enemies1, "波末回收【不】让宝箱怪现形（敌人不增加）")
	_check(battle.pickups.is_empty(), "波末回收后掉落物清空（含宝箱怪）")


# ================================================================ G. 生成守卫
func _sec_g_spawn_guard() -> void:
	_section("G. 生成守卫：探针/自检进程不自动生成事件（确定性基线零污染）")
	_prep()
	battle.wave_num = 10               # 远大于 EVENT_MIN_WAVE
	battle.events.clear()
	var trial := 0
	while trial < 20:
		trial += 1
		battle._maybe_spawn_event()
	_check(battle.events.is_empty(), "探针进程 20 次调用不生成事件实体")
	_check(battle.pickups.is_empty(), "探针进程不生成宝箱怪掉落物")


# ================================================================ H. 收尾
func _sec_h_cleanup() -> void:
	_section("H. 波末 / 重开收尾：实体清场 + 挑战按成绩结算")
	_prep()
	battle._spawn_event("altar")
	battle._spawn_event("market")
	_check(battle.events.size() == 2, "先放 2 个实体（多实体的防御场景）")
	battle._free_all_events()
	_check(battle.events.is_empty(), "_free_all_events 清空实体表")
	# 挑战进行中收尾：按成绩发奖（不是静默作废）
	_prep()
	battle._challenge_active = true
	battle._challenge_base_kills = battle.kills
	battle._challenge_dead = int(GameStats.CHALLENGE_FULL_KILLS)
	var gold0: int = battle.player.gold
	battle._free_all_events()
	_check(not bool(battle._challenge_active), "收尾后挑战关闭")
	_check(battle.player.gold >= gold0 + int(GameStats.CHALLENGE_FULL_GOLD),
		"波末收尾按成绩结算（%d → %d）" % [gold0, battle.player.gold])


# ================================================================ 工具
## 清场 + 站桩：关 Battle 物理（探针全程手动驱动）、玩家缴械静止、暴击置 0。
func _prep() -> void:
	battle.start_run()
	battle.set_physics_process(false)
	battle.spawn_remaining = 0
	var pl: Player = battle.player
	pl.set_physics_process(false)
	pl.autopilot = false
	pl.attack_enabled = false
	pl.god_mode = true
	pl.crit = 0.0
	pl.gold_per_kill = 0
	pl.luck = 0.0


func _count_chest() -> int:
	var n := 0
	for pk in battle.pickups:
		if is_instance_valid(pk) and pk.kind == Pickup.KIND_CHEST:
			n += 1
	return n


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
