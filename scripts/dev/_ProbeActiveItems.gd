extends SceneTree
## 独立验证探针：主动道具系统 + 忧郁光环 / 幸运护符 + 升级重抽 + 低血警告（2026-10-08 旗舰批次）。
##
## 回答四个验收问题：
##   ① 三件主动道具【真的生效】（核弹真秒杀 / 冲刺真加速+无敌 / 时停真冻结）
##   ② 边界语义按设计执行（BOSS 不秒杀只吃 25%、核弹击杀不掉落、冷却挡二次发动、cdr 减冷却）
##   ③ HUD 侧状态正确（主动槽空槽隐藏 / 遮罩与秒数 / 就绪金框；低血标志与警示字）
##   ④ 新增数据面闭环（幸运权重纯函数、重抽次数消耗、宝箱不给重抽、商店券结算回收）
##
## 被验证的契约：
##   GameStats.ACTIVE_ITEMS / ACTIVE_IDS / is_active_item / active_cooldown / rarity_weight
##   GameStats.UPGRADE_REROLLS / COUPON_SALVAGE_GOLD / AURA_SLOW_* / LOW_HP_WARN_RATIO
##   Player.equip_active / active_ready / active_cd_ratio / active_start_cooldown /
##     start_active_rush / active_rush_speed_mul
##   Battle._try_use_active / _do_active_nuke / _do_active_speed_boots / _do_active_time_stop /
##     _aura_tick / _on_upgrade_reroll / 商店券回收（_end_run 内）
##   Hud.set_active_state / 低血标志（_low_hp / _danger_label）
##
## 确定性：Battle 物理关闭 + 玩家站桩缴械 + 暴击置 0；主动道具全部手动调 _try_use_active。
##
## 用法: godot --headless --path <项目>/game --script res://scripts/dev/_ProbeActiveItems.gd
## 退出码 0=PASS 1=FAIL（门禁用 grep -q "RESULT=PASS" 判定）

var battle: Node = null
var armed := false
var finished := false
var checks := 0
var fails: Array[String] = []


func _initialize() -> void:
	print("[PROBE] === 主动道具系统验证（核弹/冲刺/时停 + 光环/重抽/回收）===")
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
	_sec_b_equip_cooldown()
	_sec_c_nuke()
	_sec_d_rush()
	_sec_e_time_stop()
	_sec_f_aura()
	_sec_g_hud_active()
	_sec_h_low_hp()
	_sec_i_reroll()
	_sec_j_salvage()


# ================================================================ A. 数据面契约
func _sec_a_contracts() -> void:
	_section("A. 数据面契约（主动道具表 / 幸运权重 / 重抽 / 回收常量）")
	_check(GameStats.ACTIVE_IDS.size() == 3, "ACTIVE_IDS 有 3 件（实际 %d）" % GameStats.ACTIVE_IDS.size())
	for id in GameStats.ACTIVE_IDS:
		var did := String(id)
		_check(GameStats.ACTIVE_ITEMS.has(did) and GameStats.ITEM_DEFS.has(did),
			"%s 同时在 ACTIVE_ITEMS 与 ITEM_DEFS（可上商店）" % did)
		_check(GameStats.is_active_item(did), "%s: is_active_item 为真" % did)
		var d: Dictionary = GameStats.ITEM_DEFS[did]
		_check(d.get("effect", {}).has("active_item"), "%s: effect 带 active_item 标记" % did)
		_check(int(d.get("price", -1)) > 0, "%s: 有固定价 %d" % [did, int(d.get("price", -1))])
	_check(not GameStats.is_active_item("iron_fist"), "普通道具 is_active_item 为假")
	_check(not GameStats.is_active_item(""), "空串 is_active_item 为假")
	_check(absf(GameStats.active_cooldown("active_nuke") - 30.0) <= 1e-6, "核弹冷却 == 30s")
	_check(absf(GameStats.active_cooldown("active_speed_boots") - 20.0) <= 1e-6, "冲刺冷却 == 20s")
	_check(absf(GameStats.active_cooldown("active_time_stop") - 25.0) <= 1e-6, "时停冷却 == 25s")
	_check(GameStats.active_cooldown("iron_fist") == 0.0, "非主动道具冷却 == 0")

	# 幸运权重：纯函数（rarity_luck = 0 时与旧分布逐位一致）
	var l0 := GameStats.rarity_weight("legendary", 0.0)
	var l1 := GameStats.rarity_weight("legendary", 1.0)
	_check(l1 > l0, "幸运 +1：传说权重上升（%.1f → %.1f）" % [l0, l1])
	var c0 := GameStats.rarity_weight("common", 0.0)
	var c1 := GameStats.rarity_weight("common", 1.0)
	_check(c1 < c0, "幸运 +1：普通权重下降（%.1f → %.1f）" % [c0, c1])
	_check(absf(GameStats.rarity_weight("epic", 0.0) - float(GameStats.RARITY_WEIGHTS["epic"])) <= 1e-6,
		"幸运 0：权重 == 基础表值（旧基线不变）")

	_check(GameStats.ITEM_DEFS.has("sadness_aura") and GameStats.ITEM_DEFS.has("lucky_charm"),
		"sadness_aura / lucky_charm 已上架 ITEM_DEFS")
	_check(GameStats.ITEM_DEFS["sadness_aura"]["effect"].has("slow_aura"), "忧郁光环带 slow_aura 效果键")
	_check(GameStats.ITEM_DEFS["lucky_charm"]["effect"].has("rarity_luck"), "幸运护符带 rarity_luck 效果键")
	_check(int(GameStats.UPGRADE_REROLLS) >= 1, "UPGRADE_REROLLS >= 1（实际 %d）" % int(GameStats.UPGRADE_REROLLS))
	_check(int(GameStats.COUPON_SALVAGE_GOLD) > 0,
		"COUPON_SALVAGE_GOLD > 0（实际 %d）" % int(GameStats.COUPON_SALVAGE_GOLD))
	_check(float(GameStats.LOW_HP_WARN_RATIO) > 0.0 and float(GameStats.LOW_HP_WARN_RATIO) < 1.0,
		"LOW_HP_WARN_RATIO ∈ (0,1)（实际 %.2f）" % float(GameStats.LOW_HP_WARN_RATIO))


# ================================================================ B. 装备与冷却
func _sec_b_equip_cooldown() -> void:
	_section("B. 装备与冷却（Player 层，cdr 是唯一消费点）")
	_prep()
	var pl: Player = battle.player
	_check(pl.active_id == "" and not pl.active_ready(), "开局空槽：active_id 空且不可发动")
	pl.equip_active("active_nuke")
	_check(pl.active_id == "active_nuke" and pl.active_ready(), "装备核弹后立刻就绪")
	_check(absf(pl.active_cd_ratio()) <= 1e-6, "就绪时冷却比例 == 0")
	pl.active_start_cooldown()
	_check(not pl.active_ready(), "发动后进入冷却（不可再发动）")
	_check(absf(pl.active_cd_t - 30.0) <= 1e-3, "cdr=0 时冷却 == 基础 30s（实际 %.2f）" % pl.active_cd_t)
	_check(absf(pl.active_cd_ratio() - 1.0) <= 1e-3, "刚发动时冷却比例 ≈ 1")
	# cdr 接入：cd = base × (1 - cdr)
	pl.cdr = 0.5
	pl.active_start_cooldown()
	_check(absf(pl.active_cd_t - 15.0) <= 1e-3, "cdr=0.5 时冷却 = 30×0.5 = 15s（实际 %.2f）" % pl.active_cd_t)
	# 替换语义：换新道具冷却清零
	pl.equip_active("active_time_stop")
	_check(pl.active_id == "active_time_stop" and pl.active_ready(),
		"换新道具：替换槽位且冷却清零（立即可用）")
	pl.active_cd_t = 12.5
	_check(absf(pl.active_cd_ratio() - 0.5) <= 1e-3, "冷却中段比例：12.5/25 == 0.5")
	pl.active_cd_t = 0.0


# ================================================================ C. 核弹
func _sec_c_nuke() -> void:
	_section("C. 核弹：全屏秒杀小怪 / BOSS 只吃 25% / 击杀不掉落 / 冷却挡二次")
	_prep()
	var pl: Player = battle.player
	pl.equip_active("active_nuke")
	# 对照组：普通伤害击杀 → 必掉掉落物（确认「掉落」这条基线本身是活的）
	var ctrl := _spawn("Ox", pl.global_position + Vector2(120.0, 0.0))
	ctrl.take_damage(ctrl.hp * 100)
	var p0: int = battle.pickups.size()
	battle.combat.cleanup_enemies()
	_check(battle.pickups.size() > p0,
		"对照组：普通击杀产生掉落（%d → %d 个掉落物）" % [p0, battle.pickups.size()])
	# 核弹对象：3 只小怪 + 1 只 Boss
	var m1 := _spawn("Ox", pl.global_position + Vector2(80.0, 0.0))
	var m2 := _spawn("Rat", pl.global_position + Vector2(-80.0, 40.0))
	var m3 := _spawn("Student", pl.global_position + Vector2(0.0, 220.0))
	var boss := _spawn("Boss", pl.global_position + Vector2(160.0, 120.0))
	_check(String(boss.behavior) == "boss", "Boss 模板 behavior == boss（核弹分支的判定依据）")
	var kills0: int = battle.kills
	var p1: int = battle.pickups.size()
	battle._try_use_active()
	_check(bool(m1.is_dead) and bool(m2.is_dead) and bool(m3.is_dead), "核弹秒杀全部 3 只小怪")
	_check(bool(m1.no_drop) and bool(m2.no_drop) and bool(m3.no_drop),
		"核弹击杀标记 no_drop（掉落截断依据已就位）")
	_check(not bool(boss.is_dead), "BOSS 不被核弹秒杀")
	_check(absf(float(boss.hp) - 75000.0) <= 1.0,
		"BOSS 吃 max_hp 的 25%%（100000 → %d）" % boss.hp)
	_check(pl.active_cd_t > 0.0, "发动后进入冷却（%.1fs）" % pl.active_cd_t)
	var cd_a: float = pl.active_cd_t
	battle._try_use_active()
	_check(absf(pl.active_cd_t - cd_a) <= 1e-6, "冷却中二次发动被挡（冷却不被重置）")
	var k0: int = battle.kills
	battle.combat.cleanup_enemies()
	_check(battle.pickups.size() == p1,
		"核弹击杀不产生任何掉落（pickups 保持 %d 个）" % p1)
	_check(battle.kills == k0 + 3, "击杀计数照常累加 +3（%d → %d）" % [k0, battle.kills])


# ================================================================ D. 冲刺
func _sec_d_rush() -> void:
	_section("D. 电动车冲刺：移速乘区 / 无敌 / 到期复原")
	_prep()
	var pl: Player = battle.player
	pl.equip_active("active_speed_boots")
	_check(absf(pl.active_rush_speed_mul() - 1.0) <= 1e-6, "未冲刺：移速乘区 == 1.0")
	battle._try_use_active()
	_check(absf(pl.active_rush_t - 3.0) <= 1e-3, "发动后冲刺计时 == 3s（实际 %.2f）" % pl.active_rush_t)
	_check(absf(pl.active_rush_speed_mul() - 2.0) <= 1e-6, "冲刺移速乘区 == 2.0")
	_check(pl.invincible_timer > 0.0, "冲刺附带无敌（%.2fs）" % pl.invincible_timer)
	_check(absf(pl.active_cd_t - 20.0) <= 1e-3, "冷却 == 20s（实际 %.2f）" % pl.active_cd_t)
	pl.active_rush_t = 0.0
	_check(absf(pl.active_rush_speed_mul() - 1.0) <= 1e-6, "到期后移速乘区回 1.0")


# ================================================================ E. 时停
func _sec_e_time_stop() -> void:
	_section("E. 时间静止表：全屏冻结 / BOSS 自动减半")
	_prep()
	var pl: Player = battle.player
	pl.equip_active("active_time_stop")
	var e1 := _spawn("Ox", pl.global_position + Vector2(150.0, 0.0))
	var boss := _spawn("Boss", pl.global_position + Vector2(260.0, 0.0))
	battle._try_use_active()
	_check(bool(e1.is_frozen()), "小怪被冻结")
	_check(absf(float(e1.frozen_t) - 3.0) <= 1e-3, "冻结时长 == 3s（实际 %.2f）" % e1.frozen_t)
	_check(bool(boss.is_frozen()), "BOSS 也被冻结（控制不落空）")
	_check(absf(float(boss.frozen_t) - 1.5) <= 1e-3,
		"BOSS 冻结减半：3 × %.1f == 1.5s（实际 %.2f）" % [GameStats.EXTRA_FREEZE_BOSS_MUL, boss.frozen_t])


# ================================================================ F. 忧郁光环
func _sec_f_aura() -> void:
	_section("F. 忧郁光环：半径内减速 / 半径外不受影响 / 无道具不生效")
	_prep()
	var pl: Player = battle.player
	pl.slow_aura = 0.25
	var near := _spawn("Ox", pl.global_position + Vector2(100.0, 0.0))
	var far := _spawn("Ox", pl.global_position + Vector2(300.0, 0.0))
	battle._aura_t = 0.0
	battle._aura_tick(1.0)
	_check(absf(float(near._slow_mul) - 0.75) <= 1e-4,
		"半径内（100 < %.0f）敌人移速乘区 == 0.75（实际 %.3f）" % [
			GameStats.AURA_SLOW_RADIUS, float(near._slow_mul)])
	_check(absf(float(far._slow_mul) - 1.0) <= 1e-4, "半径外（300）不受影响")
	_check(absf(float(near._slow_t) - float(GameStats.AURA_SLOW_DUR)) <= 1e-4,
		"减速时长为 AURA_SLOW_DUR（刷新式续杯）")
	# 卸掉道具（slow_aura = 0）→ 不再施加
	pl.slow_aura = 0.0
	near._slow_mul = 1.0
	near._slow_t = 0.0
	battle._aura_t = 0.0
	battle._aura_tick(1.0)
	_check(absf(float(near._slow_mul) - 1.0) <= 1e-4, "无光环道具时不施加减速")


# ================================================================ G. HUD 主动槽
func _sec_g_hud_active() -> void:
	_section("G. HUD 主动槽：空槽隐藏 / 图标取库 / 冷却遮罩与秒数 / 就绪金框")
	_prep()
	var pl: Player = battle.player
	var hud: Hud = battle.hud
	# 双槽化（2026-10-09）：HUD 渲染改为 _a_slots 字典数组，[0] = 槽 1（空格）。
	# 本段只验槽 1（旧断言逐条对应）；槽 2 的渲染在 _ProbeMetaUnlocks 里验。
	var s1: Dictionary = hud._a_slots[0]
	hud.set_active_state(pl)
	_check(not (s1["root"] as Control).visible, "空槽：整块隐藏")
	pl.equip_active("active_nuke")
	hud.set_active_state(pl)
	_check((s1["root"] as Control).visible, "装备后整块显示")
	_check((s1["icon"] as TextureRect).texture != null, "图标从 AssetDB.item_icon 取到（active_nuke.png 已入库）")
	_check((s1["frame"] as ColorRect).visible, "就绪：金框点亮")
	_check(not (s1["cd_label"] as Label).visible and (s1["mask"] as ColorRect).size.y <= 1e-3,
		"就绪：无遮罩、无秒数")
	pl.active_cd_t = 15.0
	hud.set_active_state(pl)
	_check(not (s1["frame"] as ColorRect).visible, "冷却中：金框熄灭")
	_check(absf((s1["mask"] as ColorRect).size.y - Hud.ACTIVE_SIZE * 0.5) <= 0.5,
		"冷却遮罩高度 == 50%% （%.1f px，期望 %.1f）" % [(s1["mask"] as ColorRect).size.y, Hud.ACTIVE_SIZE * 0.5])
	_check((s1["cd_label"] as Label).visible and (s1["cd_label"] as Label).text == "15",
		"剩余秒数显示 15（实际「%s」）" % (s1["cd_label"] as Label).text)


# ================================================================ H. 低血警告
func _sec_h_low_hp() -> void:
	_section("H. 低血警告：>25% 不亮 / ≤25% 亮 / 回满复位")
	_prep()
	var pl: Player = battle.player
	var hud: Hud = battle.hud
	pl.hp = float(pl.max_hp) * 0.5
	hud.set_data(pl, battle.wave_num, battle.wave_timer, GameStats.WAVE_COUNT)
	_check(not hud._low_hp and not hud._danger_label.visible, "50% 血量：不进入低血态")
	pl.hp = float(pl.max_hp) * 0.2
	hud.set_data(pl, battle.wave_num, battle.wave_timer, GameStats.WAVE_COUNT)
	_check(hud._low_hp and hud._danger_label.visible,
		"血量 20%%（< %.0f%% 阈值）：低血态 + 警示字显示" % (float(GameStats.LOW_HP_WARN_RATIO) * 100.0))
	pl.hp = float(pl.max_hp)
	hud.set_data(pl, battle.wave_num, battle.wave_timer, GameStats.WAVE_COUNT)
	_check(not hud._low_hp and not hud._danger_label.visible, "回满后退出低血态")
	_check(hud._hp_fill.color.is_equal_approx(Hud.LOW_HP_BASE), "血条颜色复位为常态红")


# ================================================================ I. 升级重抽
func _sec_i_reroll() -> void:
	_section("I. 升级重抽：按钮点亮 / 次数消耗 / 用尽隐藏 / 宝箱不给")
	_prep()
	var pl: Player = battle.player
	var up: UpgradePanel = battle.upgrade_panel
	_check(pl.rerolls_left == int(GameStats.UPGRADE_REROLLS),
		"开局重抽次数 == UPGRADE_REROLLS %d（实际 %d）" % [int(GameStats.UPGRADE_REROLLS), pl.rerolls_left])
	battle._open_upgrade("wave")
	_check(up.visible, "升级面板已开")
	_check(up._reroll.visible, "重抽按钮点亮")
	_check(up._reroll.text.contains("×2"), "按钮文案显示剩余 2 次（实际「%s」）" % up._reroll.text)
	battle._on_upgrade_reroll()
	_check(pl.rerolls_left == 1, "重抽一次后剩 1 次")
	_check(up.visible and up._options.size() > 0,
		"重抽后面板仍开、新选项已生成（%d 张）" % up._options.size())
	_check(up._reroll.text.contains("×1"), "按钮文案更新为 ×1（实际「%s」）" % up._reroll.text)
	battle._on_upgrade_reroll()
	_check(pl.rerolls_left == 0, "再重抽一次后用尽")
	_check(not up._reroll.visible, "用尽后按钮隐藏")
	battle._on_upgrade_reroll()
	_check(pl.rerolls_left == 0, "用尽后再调无效（防御分支不越界扣次数）")
	up.hide_panel()
	# 宝箱面板复用升级面板，但不出现重抽按钮
	battle._chest_pending = 1
	battle._open_chest_reward("fight")
	_check(up.visible and up._title.text.contains("宝箱"),
		"宝箱面板已开（标题：%s）" % up._title.text)
	_check(not up._reroll.visible, "宝箱面板不显示重抽按钮")
	up.hide_panel()
	battle._chest_on_closed()
	_check(int(battle._chest_pending) == 0, "宝箱消费完毕（pending == 0）")


# ================================================================ J. 商店券结算回收
func _sec_j_salvage() -> void:
	_section("J. 商店券结算回收 + 结算按钮存在性")
	_prep()
	var pl: Player = battle.player
	pl.shop_coupon = 2
	pl.gold = 100
	var expect := 100 + int(GameStats.COUPON_SALVAGE_GOLD) * 2
	battle._end_run(true)
	_check(pl.shop_coupon == 0, "结算时商店券清零")
	_check(pl.gold == expect,
		"2 张券折算 %d 金入账（gold 100 → %d，期望 %d）" % [
			int(GameStats.COUPON_SALVAGE_GOLD) * 2, pl.gold, expect])
	_check(battle.result_panel.visible, "结算面板显示")
	_check(battle.result_panel._again != null, "「再来一局」按钮已构建")
	_check(not battle.hud._root.visible, "结算时 HUD 已收起（set_visible_hud(false)）")


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
	pl.crit = 0.0            # 确定性：randf() < 0 恒 false
	pl.gold_per_kill = 0
	pl.luck = 0.0


## 生成一只静止的敌人（血厚，避免测试中被一击打死）。
func _spawn(type_name: String, pos: Vector2) -> Node2D:
	battle.wave.spawn_enemy(type_name, pos, 1.0, false)
	var e: Node2D = battle.enemies[battle.enemies.size() - 1]
	e.hp = 100000
	e.max_hp = 100000
	e.set_physics_process(false)
	return e


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
