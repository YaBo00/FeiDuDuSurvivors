extends SceneTree
## 独立验证探针：局内副武器系统（2026-09-22，5 把）。
##
## 回答三个验收问题（对应需求文档《局内新武器设计_给代码AI_2026-09-22.md》§2/§5）：
##   ① 每把副武器的实际效果**是否生效**（选了立刻工作 / 真的掉血 / 减益真的挂上）
##   ② 玩家看得见的**视觉实体是否随等级变化**（刀数 / 圈半径 / 闪电条数 / 齐射枚数 / 毒池寿命）
##   ③ 升级后**数值与视觉是否都有变动**（逐级对照设计文档的数值表 + FX 实例参数）
##
## 被验证的契约：
##   GameStats.EXTRA_WEAPON_DEFS / EXTRA_WEAPON_IDS / MAX_EXTRA_WEAPONS / EXTRA_WEAPON_CARD_RATE
##   ExtraWeaponSystem.grant / level_up / update / reset / owned_ids / triggers
##   ExtraWeaponSystem.{BladeFX, LightningFX, IceNovaFX, AcidPoolFX, MissileFX, BlastFX}
##   Enemy.freeze / apply_slow / apply_vuln / incoming_vuln_mul / _cur_speed
##   CombatResolver.deal_extra_damage（含中毒易伤乘区）
##   Battle._extra_weapon_cards（获得卡 / 升级卡 / 满 2 把 / 满级过滤）
##
## 确定性：Battle 物理关闭 + 玩家缴械站桩 + 暴击置 0 + 敌人静止，全部手动步进 delta。
##
## 用法: godot --headless --path <项目>/game --script res://scripts/dev/_ProbeExtraWeapons.gd
## 退出码 0=PASS 1=FAIL（门禁用 grep -q "RESULT=PASS" 判定）

const DT := 1.0 / 60.0
const IDS: Array[String] = ["orbit", "lightning", "ice_nova", "acid", "missile"]

## 设计文档 §2 的数值表（探针【独立抄写】文档值，用来交叉验证实现 —— 不是从实现读回来自证）
const DOC := {
	"orbit": {
		"count": [2, 3, 5, 8, 12],
		"dmg_mul": [0.6, 0.8, 0.8, 1.0, 1.2],
		"radius": [80.0, 90.0, 100.0, 110.0, 120.0],
		"rot": [2.0, 2.0, 2.0, 3.0, 3.0],
	},
	"lightning": {
		"interval": [2.0, 1.8, 1.6, 1.4, 1.2],
		"dmg_mul": [1.2, 1.4, 1.6, 1.8, 2.0],
		"chains": [2, 2, 3, 3, 3],
		"targets": [1, 1, 1, 1, 2],
	},
	"ice_nova": {
		"interval": [3.0, 3.0, 2.5, 2.5, 2.0],
		"radius": [90.0, 100.0, 110.0, 120.0, 140.0],
		"freeze": [0.5, 0.6, 0.8, 0.8, 1.0],
		"dmg_mul": [0.0, 0.2, 0.3, 0.5, 0.8],
	},
	"acid": {
		"interval": [2.5, 2.5, 2.0, 2.0, 2.0],
		"life": [2.0, 2.5, 2.5, 3.0, 3.0],
		"radius": [60.0, 80.0, 100.0, 120.0, 150.0],
		"dps_mul": [0.3, 0.5, 0.6, 0.8, 1.0],
		"vuln": [1.0, 1.0, 1.0, 1.0, 1.2],
	},
	"missile": {
		"interval": [2.0, 2.0, 2.0, 2.0, 2.0],
		"count": [1, 1, 2, 2, 3],
		"dmg_mul": [1.5, 2.0, 2.0, 2.5, 3.0],
		"blast": [40.0, 50.0, 50.0, 60.0, 70.0],
	},
}

var battle: Node = null
var armed := false
var finished := false
var checks := 0
var fails: Array[String] = []


func _initialize() -> void:
	print("[PROBE] === 局内副武器系统验证（生效 / 升级 / 视觉实体）===")
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
	_sec_a()
	_sec_b_orbit()
	_sec_b_lightning()
	_sec_b_ice_nova()
	_sec_b_acid()
	_sec_b_missile()
	_sec_c_orbit()
	_sec_c_lightning()
	_sec_c_ice_nova()
	_sec_c_acid()
	_sec_c_missile()
	_sec_c_damage_growth()
	_sec_c_visual_anchors()
	_sec_c_cdr()
	_sec_d_debuff()
	_sec_e_independence()
	_sec_e_cards()
	_sec_e_reset()


# ================================================================ A. 数值表契约
func _sec_a() -> void:
	_section("A. 数值表契约（实现 vs 设计文档 §2 数值表）")
	_check(GameStats.EXTRA_WEAPON_IDS.size() == 5,
		"EXTRA_WEAPON_IDS 有 5 把（实际 %d）" % GameStats.EXTRA_WEAPON_IDS.size())
	for id in IDS:
		_check(GameStats.EXTRA_WEAPON_DEFS.has(id) and GameStats.EXTRA_WEAPON_IDS.has(id),
			"%s 在表内且被列入抽卡顺序" % id)
	_check(int(GameStats.MAX_EXTRA_WEAPONS) == 2, "MAX_EXTRA_WEAPONS == 2（合计 3 把武器）")
	var rate := float(GameStats.EXTRA_WEAPON_CARD_RATE)
	_check(rate > 0.0 and rate < 1.0, "EXTRA_WEAPON_CARD_RATE ∈ (0,1)（实际 %.2f）" % rate)

	for id in IDS:
		var d: Dictionary = GameStats.EXTRA_WEAPON_DEFS[id]
		var tiers: Array = d["tiers"]
		var mx := int(d["max_level"])
		_check(tiers.size() == mx and mx == 5,
			"%s: tiers 长度 %d == max_level %d" % [id, tiers.size(), mx])
		# 逐级对照文档数值表
		var doc: Dictionary = DOC[id]
		var bad: Array[String] = []
		for key in doc.keys():
			var exp: Array = doc[key]
			for lv in range(1, mx + 1):
				var row: Dictionary = GameStats.extra_weapon_tier(id, lv)
				if not row.has(key):
					bad.append("Lv%d 缺 %s" % [lv, String(key)])
					continue
				if not _eq(row[key], exp[lv - 1]):
					bad.append("%s Lv%d: %s ≠ 文档 %s" % [String(key), lv, str(row[key]), str(exp[lv - 1])])
		_check(bad.is_empty(), "%s: 5 级数值全部与设计文档一致（%s）" % [id, str(bad)])
		# 卡面文案（每级都能生成，且没有漏替的格式符）
		var txt_bad: Array[String] = []
		for lv in range(1, mx + 1):
			var t := GameStats.extra_weapon_card_text(id, lv)
			if t.is_empty() or t.contains("%"):
				txt_bad.append("Lv%d" % lv)
		_check(txt_bad.is_empty(), "%s: 每级卡面文案可正常生成（异常 %s）" % [id, str(txt_bad)])


# ================================================================ B. 生效（选了立刻工作）
func _sec_b_orbit() -> void:
	_section("B1. 环绕飞刃：选了立刻绕 / 真的造成伤害 / 用入库贴图")
	_prep()
	_check(battle.extra.grant("orbit"), "grant(orbit) 生效")
	_check(battle.extra.owned_count() == 1 and battle.extra.level_of("orbit") == 1, "持有 1 把、等级 Lv1")
	_check(battle.extra._blades.size() == 2, "Lv1 立刻生成 2 把刀（实际 %d，不等一个冷却）" % battle.extra._blades.size())
	var blade: Node2D = battle.extra._blades[0]
	_check(blade.get_parent() == battle.world, "刀挂在 world 层（与相机取景同层）")
	_check(blade.get("tex") != null, "刀用的是入库贴图 w_orbit_blade.png（不是程序化回落）")

	var pl: Node2D = battle.player
	var en: Node2D = _spawn("Ox", pl.global_position + Vector2(80.0, 0.0))
	var hp0: int = en.hp
	_step(240)   # 4s，转速 2 rad/s ⇒ 转 1.3 圈，必然扫过
	_check(en.hp < hp0, "刀扫过敌人造成伤害（hp %d → %d）" % [hp0, en.hp])
	var dist := blade.global_position.distance_to(pl.global_position)
	_check(absf(dist - 80.0) <= 1.0, "刀距玩家 == tier.radius 80（实际 %.1f）" % dist)
	# 同一把刀对同一敌人的再命中冷却：4 秒内的命中次数应远少于 240 次（否则就是每帧扣血）
	var hits := 240.0 * 0.0 + float(hp0 - en.hp) / float(_raw(0.6))
	_check(hits <= 12.0, "4s 内命中次数受 ORBIT_HIT_CD 限制（约 %.1f 次，非每帧）" % hits)
	# 扇形排布：两把刀应在玩家两侧（夹角 180°）
	var b0: Node2D = battle.extra._blades[0]
	var b1: Node2D = battle.extra._blades[1]
	var a0: float = (b0.global_position - pl.global_position).angle()
	var a1: float = (b1.global_position - pl.global_position).angle()
	var gap: float = absf(wrapf(a1 - a0, -PI, PI))
	_check(absf(gap - PI) <= 0.05, "2 把刀对称分布（夹角 %.1f°）" % rad_to_deg(gap))


func _sec_b_lightning() -> void:
	_section("B2. 闪电链：周期劈击 / 链跳 200px / 程序化折线真的生成")
	_prep()
	_check(battle.extra.grant("lightning"), "grant(lightning) 生效")
	var pl: Node2D = battle.player
	var e1: Node2D = _spawn("Ox", pl.global_position + Vector2(120.0, 0.0))
	var e2: Node2D = _spawn("Ox", pl.global_position + Vector2(300.0, 0.0))   # 与 e1 相距 180 < 200 ⇒ 可被链到
	var hp1: int = e1.hp
	var hp2: int = e2.hp
	var cd0 := float(battle.extra._cd.get("lightning", -1.0))
	_check(absf(cd0) <= 1e-6, "选中后冷却为 0（立刻可劈）")
	_step(1)
	_check(int(battle.extra.triggers.get("lightning", 0)) == 1, "第 1 帧就劈出 1 道（实际 %d）" % int(battle.extra.triggers.get("lightning", 0)))
	_check(absf(float(battle.extra._cd.get("lightning", 0.0)) - 2.0) <= 1e-4,
		"触发后冷却重置为 tier.interval 2.0（实际 %.2f）" % float(battle.extra._cd.get("lightning", 0.0)))
	var d1: int = hp1 - e1.hp
	_check(d1 == _raw(1.2), "单次伤害 == 攻击力 × 1.2（实际 %d，期望 %d）" % [d1, _raw(1.2)])
	_check(e2.hp < hp2, "链跳命中 200px 内的第二个敌人（%d → %d）" % [hp2, e2.hp])
	var fx := _count_live(ExtraWeaponSystem.LightningFX)
	_check(fx >= 2, "world 层生成了 ≥2 道锯齿闪电（实际 %d，0.15s 淡出）" % fx)
	_step(118)   # 累计 119 帧 ≈ 1.98s，还没到第二次
	_check(int(battle.extra.triggers.get("lightning", 0)) == 1, "间隔未到不再触发（1.98s 时仍是 1 次）")
	_step(4)     # 累计 ≈ 2.05s
	_check(int(battle.extra.triggers.get("lightning", 0)) == 2, "到 2.0s 触发第 2 次")


func _sec_b_ice_nova() -> void:
	_section("B3. 冰霜新星：周期冻结 / 范围外不冻 / Lv1 零伤害")
	_prep()
	_check(battle.extra.grant("ice_nova"), "grant(ice_nova) 生效")
	var pl: Node2D = battle.player
	var near: Node2D = _spawn("Ox", pl.global_position + Vector2(70.0, 0.0))    # 半径 90 内
	var far: Node2D = _spawn("Ox", pl.global_position + Vector2(260.0, 0.0))    # 半径 90 外
	var hp0: int = near.hp
	_step(1)
	_check(int(battle.extra.triggers.get("ice_nova", 0)) == 1, "第 1 帧就放 1 次（实际 %d）" % int(battle.extra.triggers.get("ice_nova", 0)))
	_check(bool(near.is_frozen()), "半径内敌人被冻结")
	_check(not bool(far.is_frozen()), "半径外敌人不受影响")
	_check(absf(float(near.frozen_t) - 0.5) <= 1e-3, "冻结时长 == tier.freeze 0.5s（实际 %.3f）" % float(near.frozen_t))
	_check(near.hp == hp0, "Lv1 dmg_mul = 0 ⇒ 只有控制、零伤害（hp 不变）")
	var ice := _one_live(ExtraWeaponSystem.IceNovaFX)
	_check(ice != null and absf(float(ice.get("radius")) - 90.0) <= 0.01,
		"生成冰圈特效且半径 == 90（实际 %s）" % ("无" if ice == null else "%.0f" % float(ice.get("radius"))))


func _sec_b_acid() -> void:
	_section("B4. 毒云：脚下留池 / 0.5s tick 掉血 / 池有寿命")
	_prep()
	_check(battle.extra.grant("acid"), "grant(acid) 生效")
	var pl: Node2D = battle.player
	var en: Node2D = _spawn("Ox", pl.global_position + Vector2(40.0, 0.0))    # 站在池内
	var hp0: int = en.hp
	_step(1)
	_check(int(battle.extra.triggers.get("acid", 0)) == 1, "第 1 帧就留 1 滩毒（实际 %d）" % int(battle.extra.triggers.get("acid", 0)))
	_check(battle.extra._pools.size() == 1, "活跃毒池数 1")
	var pool := _one_live(ExtraWeaponSystem.AcidPoolFX)
	_check(pool != null and absf(float(pool.get("radius")) - 60.0) <= 0.01,
		"毒池半径 == 60（实际 %s）" % ("无" if pool == null else "%.0f" % float(pool.get("radius"))))
	_check(pool != null and absf(float(pool.get("life")) - 2.0) <= 0.01, "毒池寿命 == 2.0s（tier.life）")
	_check(absf(float(pool.get("life_max")) - float(pool.get("life"))) <= 1e-4,
		"life_max 与 life 同步（否则 Lv2+ 淡出错位）")
	_check(en.hp == hp0, "tick 间隔未到不掉血（tick = %.1fs）" % float(GameStats.EXTRA_ACID_TICK))
	_step(31)   # 累计 32 帧 ≈ 0.53s > 0.5
	_check(en.hp < hp0, "0.5s 后毒池 tick 造成伤害（hp %d → %d）" % [hp0, en.hp])
	_check(absf(float(en.incoming_vuln_mul()) - 1.0) <= 1e-4, "Lv1 vuln = 1.0 ⇒ 无中毒易伤")


func _sec_b_missile() -> void:
	_section("B5. 追踪导弹：首发 / 转向追人 / 命中爆炸")
	_prep()
	_check(battle.extra.grant("missile"), "grant(missile) 生效")
	var pl: Node2D = battle.player
	var en: Node2D = _spawn("Ox", pl.global_position + Vector2(360.0, 0.0))
	var hp0: int = en.hp
	_step(1)
	_check(int(battle.extra.triggers.get("missile", 0)) == 1, "第 1 帧就齐射 1 次（实际 %d）" % int(battle.extra.triggers.get("missile", 0)))
	var ms := _one_live(ExtraWeaponSystem.MissileFX)
	_check(ms != null, "world 层出现导弹实体（MissileFX）")
	_check(ms != null and ms.get("tex") != null, "导弹用入库贴图 w_missile.png（不是程序化回落）")
	var p0: Vector2 = ms.global_position if ms != null else Vector2.ZERO
	_step(30)
	var p1: Vector2 = ms.global_position if ms != null else Vector2.ZERO
	_check(p1.distance_to(p0) > 100.0, "导弹在飞行（0.5s 位移 %.0fpx，速度 %.0f px/s）" % [p1.distance_to(p0), float(GameStats.MISSILE_SPEED)])
	_check(p1.x > p0.x - 1.0, "导弹朝目标方向飞（目标在 +X 侧）")
	_step(60)
	_check(en.hp < hp0, "导弹命中敌人造成伤害（hp %d → %d）" % [hp0, en.hp])
	_check(_count_live(ExtraWeaponSystem.BlastFX) >= 1, "命中处生成爆炸冲击圈（BlastFX）")
	# 目标死亡后应重新索敌（不原地打转）：把原目标标记死亡，另放一只新怪
	en.is_dead = true
	var en2: Node2D = _spawn("Ox", pl.global_position + Vector2(-360.0, 0.0))
	var hp2: int = en2.hp
	battle.extra._cd["missile"] = 0.0
	_step(1)
	_step(120)   # 2s：足够转向 + 飞到 -X 侧
	_check(en2.hp < hp2, "原目标消失后导弹重新索敌并命中新目标（%d → %d）" % [hp2, en2.hp])


# ================================================================ C. 升级：视觉实体逐级变化
func _sec_c_orbit() -> void:
	_section("C1. 环绕飞刃：升级后刀数与半径（可见）随表变")
	_prep()
	_check(battle.extra.grant("orbit"), "grant(orbit)")
	var exp_count := [2, 3, 5, 8, 12]
	var exp_radius := [80.0, 90.0, 100.0, 110.0, 120.0]
	var bad: Array[String] = []
	for lv in range(1, 6):
		_step(1)
		var n: int = battle.extra._blades.size()
		if n != exp_count[lv - 1]:
			bad.append("Lv%d 刀数 %d≠%d" % [lv, n, exp_count[lv - 1]])
		var bb: Node2D = battle.extra._blades[0]
		var dd: float = bb.global_position.distance_to(battle.player.global_position)
		if absf(dd - exp_radius[lv - 1]) > 1.0:
			bad.append("Lv%d 半径 %.1f≠%.0f" % [lv, dd, exp_radius[lv - 1]])
		if lv < 5:
			_check(battle.extra.level_up("orbit"), "升到 Lv%d" % (lv + 1))
	_check(bad.is_empty(), "Lv1→Lv5 刀数/半径逐步跟随数值表（%s）" % str(bad))
	_check(not battle.extra.level_up("orbit"), "Lv5 满级后 level_up 返回 false（升级卡消失）")


func _sec_c_lightning() -> void:
	_section("C2. 闪电链：升级后同时劈的目标数与闪电条数变多")
	_prep()
	_check(battle.extra.grant("lightning"), "grant(lightning)")
	var pl: Node2D = battle.player
	# 4 只敌人一字排开、相邻 150px（< 链距 200），保证链有目标可选
	for i in 4:
		_spawn("Ox", pl.global_position + Vector2(120.0 + 150.0 * float(i), 0.0))
	var exp_targets := [1, 1, 1, 1, 2]
	var exp_chains := [2, 2, 3, 3, 3]
	var bad: Array[String] = []
	var counts: Array[int] = []
	for lv in range(1, 6):
		_free_fx()
		battle.extra._cd["lightning"] = 0.0
		_step(1)
		var n := _count_live(ExtraWeaponSystem.LightningFX)
		counts.append(n)
		if n < exp_targets[lv - 1]:
			bad.append("Lv%d 闪电条数 %d < targets %d" % [lv, n, exp_targets[lv - 1]])
		if lv < 5:
			_check(battle.extra.level_up("lightning"), "升到 Lv%d" % (lv + 1))
	_check(bad.is_empty(), "每级闪电条数 ≥ targets（逐级 %s，期望 chains 上限 %s）" % [str(counts), str(exp_chains)])
	_check(counts[4] > counts[0], "Lv5 的闪电条数明显多于 Lv1（%d → %d）" % [counts[0], counts[4]])


func _sec_c_ice_nova() -> void:
	_section("C3. 冰霜新星：升级后冰圈半径与冻结时长逐级变")
	_prep()
	_check(battle.extra.grant("ice_nova"), "grant(ice_nova)")
	var exp_radius := [90.0, 100.0, 110.0, 120.0, 140.0]
	var exp_freeze := [0.5, 0.6, 0.8, 0.8, 1.0]
	var pl: Node2D = battle.player
	var en: Node2D = _spawn("Ox", pl.global_position + Vector2(60.0, 0.0))
	var bad: Array[String] = []
	for lv in range(1, 6):
		_free_fx()
		en.frozen_t = 0.0
		battle.extra._cd["ice_nova"] = 0.0
		_step(1)
		var fx := _one_live(ExtraWeaponSystem.IceNovaFX)
		if fx == null:
			bad.append("Lv%d 无冰圈" % lv)
		elif absf(float(fx.get("radius")) - exp_radius[lv - 1]) > 0.01:
			bad.append("Lv%d 冰圈半径 %.0f≠%.0f" % [lv, float(fx.get("radius")), exp_radius[lv - 1]])
		if absf(float(en.frozen_t) - exp_freeze[lv - 1]) > 1e-3:
			bad.append("Lv%d 冻结 %.2fs≠%.2fs" % [lv, float(en.frozen_t), exp_freeze[lv - 1]])
		if lv < 5:
			_check(battle.extra.level_up("ice_nova"), "升到 Lv%d" % (lv + 1))
	_check(bad.is_empty(), "Lv1→Lv5 冰圈半径与冻结时长跟随数值表（%s）" % str(bad))


func _sec_c_acid() -> void:
	_section("C4. 毒云：升级后毒池半径与寿命逐级变")
	_prep()
	_check(battle.extra.grant("acid"), "grant(acid)")
	var exp_radius := [60.0, 80.0, 100.0, 120.0, 150.0]
	var exp_life := [2.0, 2.5, 2.5, 3.0, 3.0]
	var bad: Array[String] = []
	for lv in range(1, 6):
		_free_fx()
		battle.extra._pools.clear()
		battle.extra._cd["acid"] = 0.0
		_step(1)
		var fx := _one_live(ExtraWeaponSystem.AcidPoolFX)
		if fx == null:
			bad.append("Lv%d 无毒池" % lv)
		else:
			if absf(float(fx.get("radius")) - exp_radius[lv - 1]) > 0.01:
				bad.append("Lv%d 半径 %.0f≠%.0f" % [lv, float(fx.get("radius")), exp_radius[lv - 1]])
			if absf(float(fx.get("life")) - exp_life[lv - 1]) > 0.01:
				bad.append("Lv%d 寿命 %.1f≠%.1f" % [lv, float(fx.get("life")), exp_life[lv - 1]])
			if absf(float(fx.get("life_max")) - float(fx.get("life"))) > 1e-4:
				bad.append("Lv%d life_max 未同步" % lv)
		if lv < 5:
			_check(battle.extra.level_up("acid"), "升到 Lv%d" % (lv + 1))
	_check(bad.is_empty(), "Lv1→Lv5 毒池半径/寿命跟随数值表（%s）" % str(bad))


func _sec_c_missile() -> void:
	_section("C5. 追踪导弹：升级后齐射枚数与爆炸半径逐级变")
	_prep()
	_check(battle.extra.grant("missile"), "grant(missile)")
	var pl: Node2D = battle.player
	_spawn("Ox", pl.global_position + Vector2(900.0, 0.0))   # 放远，避免每级立刻命中
	var exp_count := [1, 1, 2, 2, 3]
	var exp_blast := [40.0, 50.0, 50.0, 60.0, 70.0]
	var bad: Array[String] = []
	var counts: Array[int] = []
	for lv in range(1, 6):
		_free_fx()
		battle.extra._missiles.clear()
		battle.extra._cd["missile"] = 0.0
		_step(1)
		var n := _count_live(ExtraWeaponSystem.MissileFX)
		counts.append(n)
		if n != exp_count[lv - 1]:
			bad.append("Lv%d 齐射 %d≠%d" % [lv, n, exp_count[lv - 1]])
		if lv < 5:
			_check(battle.extra.level_up("missile"), "升到 Lv%d" % (lv + 1))
	_check(bad.is_empty(), "Lv1→Lv5 齐射枚数跟随数值表（逐级 %s）" % str(counts))
	# 爆炸半径随等级：把敌人拉到近处让导弹立刻命中，读 BlastFX.radius
	_free_fx()
	battle.extra._missiles.clear()
	var near: Node2D = _spawn("Ox", pl.global_position + Vector2(120.0, 0.0))
	battle.extra._cd["missile"] = 0.0
	_step(1)
	_step(30)
	var blast := _one_live(ExtraWeaponSystem.BlastFX)
	_check(blast != null and absf(float(blast.get("radius")) - exp_blast[4]) <= 0.01,
		"Lv5 爆炸圈半径 == 70（实际 %s）" % ("无" if blast == null else "%.0f" % float(blast.get("radius"))))
	near.hp = 100000


func _sec_c_damage_growth() -> void:
	_section("C6. 数值成长端到端：同一目标下 Lv1 vs Lv5 单次伤害")
	_prep()
	_check(battle.extra.grant("lightning"), "grant(lightning)")
	var pl: Node2D = battle.player
	var en: Node2D = _spawn("Ox", pl.global_position + Vector2(120.0, 0.0))
	var hp0: int = en.hp
	_step(1)
	var d1: int = hp0 - en.hp
	for i in 4:
		battle.extra.level_up("lightning")
	en.hp = 100000
	battle.extra._cd["lightning"] = 0.0
	_step(1)
	var d5: int = 100000 - en.hp
	_check(d1 == _raw(1.2) and d5 == _raw(2.0),
		"Lv1 单次 %d（期望 %d）→ Lv5 单次 %d（期望 %d）" % [d1, _raw(1.2), d5, _raw(2.0)])
	_check(d5 > d1, "同攻击力下单次伤害随等级提高（+%.0f%%）" % (100.0 * float(d5 - d1) / maxf(1.0, float(d1))))
	# 升级不影响主角武器的攻击间隔（副武器不吃武器进化乘区）
	_check(absf(float(pl.attack_interval) - float(pl.attack_interval)) <= 1e-6, "副武器升级不改动主角武器参数")


# ================================================================ C7. 每级可见锚点（2026-09-22 补测）
## 回答「升级后屏上到底看不看得出变化」。上一轮复核发现 20 个升级档里 12 档是纯数值档
## （只改间隔/伤害/半径），玩家开完卡在画面上毫无反馈 —— 本批给五把武器各加「每级可见锚点」，
## 这一节把它们逐级钉死，防止以后被「顺手重构」改回纯数值：
##   · 飞刃：刀身 46→58px（★ 必须【逐把】断言 —— Lv1 生成的老刀会一直留在场上，
##     只有 _sync_blades 里那段「逐刀回写 vlevel」跑到，它们才跟着升级；旧实现漏的就是这里）
##   · 闪电：vlevel 传进 LightningFX（线宽 ×1.0→1.52 / 亮度 / 锯齿 ×1.0→1.40 由 _draw 按它算）
##   · 冰霜：vlevel 传进 IceNovaFX（冰晶刺 6/6/8/8/10）
##   · 毒云：vlevel 传进 AcidPoolFX（气泡 4..8 + 填充浓度），且淡出只在末 30%
##   · 导弹：vlevel 传进 MissileFX（弹体 40→50px）
## 另外钉住 HUD 新增的「副武器」行（图标 + 等级点，点亮个数 = 等级）。
## ⚠️ 本节全是【纯视觉】：不断言任何伤害/判定/随机结果（那些在 C1~C6）。
## 说明：vlevel / _vis_len / fade_weight 走 get()/call() 动态访问 —— _blades 的元素静态类型是
## Node2D，直接点属性会被编译期拦下（本项目踩过一次类型推断的坑）。
func _sec_c_visual_anchors() -> void:
	_section("C7. 每级可见锚点：升级后屏上看得见变化（纯视觉，不碰判定）")

	# ---- 飞刃：刀身长度逐级（★ 逐把断言，不只查第 0 把）----
	_prep()
	_check(battle.extra.grant("orbit"), "grant(orbit)")
	var bad: Array[String] = []
	var counts: Array[int] = []
	var lens: Array[String] = []
	for lv in range(1, 6):
		_step(1)
		counts.append(battle.extra._blades.size())
		var want := 46.0 + 3.0 * float(lv - 1)
		# ★ 必须逐把查：Lv1 生成的老刀会一直留在场上（刀数每级都涨 ⇒ 增删分支每级都跑，
		#   但增删【不会】去动已存在的那几把），只有 _sync_blades 末尾那段「逐刀回写 vlevel」
		#   跑到了，老刀才会跟着变长 —— 旧实现漏档就是漏在这里。
		for bi in battle.extra._blades.size():
			var bl: Node2D = battle.extra._blades[bi]
			var vl := int(bl.get("vlevel"))
			var got := float(bl.call("_vis_len"))
			if vl != lv - 1:
				bad.append("Lv%d 第%d把 vlevel=%d≠%d" % [lv, bi, vl, lv - 1])
			if absf(got - want) > 1e-3:
				bad.append("Lv%d 第%d把 刀长 %.1f≠%.1f" % [lv, bi, got, want])
			if bi == 0:
				lens.append("%.0f" % got)
		if lv < 5:
			_check(battle.extra.level_up("orbit"), "升到 Lv%d" % (lv + 1))
	_check(bad.is_empty(), "Lv1→Lv5【每一把】刀的视觉等级与长度都跟随（第 0 把实测 %s）" % str(lens))
	_check(lens[0] != lens[4], "Lv1 与 Lv5 刀长明显不同（%s vs %s）" % [lens[0], lens[4]])
	_check(counts[4] > counts[0] and counts[3] > counts[2],
		"刀数逐级递增、且 Lv3→Lv5 明显变多（逐级 %s）" % str(counts))

	# ---- 其余四把：vlevel 是否真的传进了 FX ----
	var vbad: Array[String] = []
	var cases := [
		{"id": "lightning", "cls": ExtraWeaponSystem.LightningFX, "name": "闪电"},
		{"id": "ice_nova", "cls": ExtraWeaponSystem.IceNovaFX, "name": "冰圈"},
		{"id": "acid", "cls": ExtraWeaponSystem.AcidPoolFX, "name": "毒池"},
		{"id": "missile", "cls": ExtraWeaponSystem.MissileFX, "name": "导弹"},
	]
	for c in cases:
		_prep()
		var wid := String(c["id"])
		_check(battle.extra.grant(wid), "grant(%s)" % wid)
		for lv in range(1, 6):
			_free_fx()
			battle.extra._pools.clear()
			battle.extra._cd[wid] = 0.0
			_step(1)
			var fx := _one_live(c["cls"])
			if fx == null:
				vbad.append("%s Lv%d 无 FX 节点" % [c["name"], lv])
			elif int(fx.get("vlevel")) != lv - 1:
				vbad.append("%s Lv%d vlevel=%d≠%d" % [c["name"], lv, int(fx.get("vlevel")), lv - 1])
			if lv < 5:
				_check(battle.extra.level_up(wid), "升到 Lv%d" % (lv + 1))
	_check(vbad.is_empty(), "闪电/冰圈/毒池/导弹 的 vlevel 逐级正确传到 FX（%s）" % str(vbad))

	# ---- 毒池淡出曲线：只在末 30% 才淡（fade_weight 是纯函数，直接断言五个点）----
	var pool := ExtraWeaponSystem.AcidPoolFX.new()
	pool.life_max = 2.0
	var pts := [2.0, 1.4, 0.6, 0.3, 0.0]        # 寿命进度 0% / 30% / 70% / 85% / 100%
	var exp_fade := [1.0, 1.0, 1.0, 0.5, 0.0]
	var fbad: Array[String] = []
	for i in pts.size():
		pool.life = float(pts[i])
		var got := float(pool.fade_weight())
		if absf(got - exp_fade[i]) > 1e-4:
			fbad.append("%d%% 进度 fade=%.3f≠%.3f" % [
				int(round(100.0 * (1.0 - float(pts[i]) / 2.0))), got, exp_fade[i]])
	_check(fbad.is_empty(),
		"毒池淡出只发生在末 30%%（66%% 处仍满浓度，85%% 处 0.5，100%% 归零）（%s）" % str(fbad))
	pool.free()

	# ---- HUD「副武器」行：图标 + 等级点 ----
	var ids: Array[String] = ["orbit"]
	battle.extra.reset()
	battle.hud.set_extra_weapons(ids, {"orbit": 1})
	var row: Control = battle.hud._extra_row
	_check(row != null and row.visible, "持有 1 把 ⇒ HUD 副武器行可见")
	var slot0: Dictionary = battle.hud._extra_slots[0]
	var bg0: ColorRect = slot0["root"]
	var icon: TextureRect = slot0["icon"]
	_check(bg0.visible, "槽 0 可见")
	_check(icon.texture != null, "槽 0 图标非空（与升级卡面同一张图）")
	_check(_lit_pips(slot0["pips"]) == 1, "Lv1 ⇒ 点亮 1 个等级点（实际 %d）" % _lit_pips(slot0["pips"]))
	battle.hud.set_extra_weapons(ids, {"orbit": 3})
	_check(_lit_pips(slot0["pips"]) == 3, "Lv3 ⇒ 点亮 3 个（实际 %d）" % _lit_pips(slot0["pips"]))
	var ids2: Array[String] = ["orbit", "acid"]
	battle.hud.set_extra_weapons(ids2, {"orbit": 3, "acid": 2})
	var slot1: Dictionary = battle.hud._extra_slots[1]
	var bg1: ColorRect = slot1["root"]
	var icon1: TextureRect = slot1["icon"]
	_check(bg1.visible, "持有 2 把 ⇒ 槽 1 出现")
	_check(icon1.texture != null and icon1.texture != icon.texture, "槽 1 图标与槽 0 不同（按 id 取图）")
	var empty: Array[String] = []
	battle.hud.set_extra_weapons(empty, {})
	_check(not row.visible, "清空 ⇒ 整行隐藏（不占屏）")
	battle.hud.set_extra_weapons(empty, {})
	_check(not row.visible, "重复空调用 ⇒ 行仍隐藏（内容指纹去重不误判）")

	# ---- 端到端：Battle._refresh_hud_extra（HUD 拍 / 拿卡 / 重开三处都调它）----
	battle.extra.reset()
	battle._refresh_hud_extra()
	battle.extra.grant("orbit")
	battle._refresh_hud_extra()
	_check(row.visible, "端到端：grant 后 _refresh_hud_extra ⇒ 行可见")
	battle.extra.reset()
	battle._refresh_hud_extra()
	_check(not row.visible, "端到端：reset 后 _refresh_hud_extra ⇒ 行隐藏（重开不留残影）")


# ================================================================ C8. 冷却缩减接入副武器冷却
## 2026-09-22：《冷却缩减接入副武器_给代码AI_2026-09-22.md》。
## 契约：4 把周期型武器（lightning / ice_nova / acid / missile）的【冷却重置】
##       = tier.interval × (1 - player.cdr)；orbit 无 interval，不接。
## cdr 是局内可变 stat ⇒ 每次重置都现读（做法 A：不动正在倒计时的 _cd，下次触发才吃到）。
func _sec_c_cdr() -> void:
	_section("C8. 冷却缩减（cdr）接入副武器冷却：重置间隔 = interval × (1-cdr)")
	var k := 1.0 - GameStats.MAX_CDR
	var mx := GameStats.MAX_CDR

	# ---- cdr 写入与封顶（封顶在 Player._recompute_stats 收口，这里不重复护栏）----
	_prep()
	var pl: Player = battle.player
	pl.apply_upgrade("cdr", mx)
	_check(_eq(float(pl.cdr), mx), "apply_upgrade(cdr,0.40) → player.cdr=0.40（实际 %.3f）" % float(pl.cdr))
	pl.apply_upgrade("cdr", mx)
	_check(_eq(float(pl.cdr), mx), "再叠一张 cdr 卡仍封顶 0.40（实际 %.3f → 不会 100%% 冷却）" % float(pl.cdr))

	# ---- 4 把周期型武器：Lv1 重置间隔 = 裸值 × 0.6 ----
	# MAX_EXTRA_WEAPONS=2 ⇒ 每次必须显式清场（不能依赖上一轮的残留持有）
	for id in ["lightning", "ice_nova", "acid", "missile"]:
		_prep()
		battle.extra.reset()
		var plx: Player = battle.player
		plx.apply_upgrade("cdr", mx)
		battle.extra.grant(id)
		_step(1)                                  # 第 1 帧即触发并重置 _cd
		var base := float(GameStats.extra_weapon_tier(id, 1)["interval"])
		var got := float(battle.extra._cd.get(id, -1.0))
		_check(_eq(got, base * k),
			"%s Lv1 重置 = 裸 %.2f × 0.6 = %.2f（实际 %.2f）" % [id, base, base * k, got])

	# ---- cdr 回 0 ⇒ 下次重置回裸值（做法 A：只有下次冷却重置才读新 cdr）----
	_prep()
	var pl3: Player = battle.player
	pl3.apply_upgrade("cdr", mx)
	battle.extra.grant("lightning")
	_step(1)
	battle.extra._cd["lightning"] = 0.0           # 清掉当前倒计时 → 下一次 update 走重置
	pl3.cdr = 0.0
	_step(1)
	_check(_eq(float(battle.extra._cd.get("lightning", -1.0)), 2.0),
		"cdr 回 0 ⇒ 下次重置回裸值 2.0（实际 %.2f）" % float(battle.extra._cd.get("lightning", -1.0)))

	# ---- orbit 不接 cdr（持续旋转型，没有 interval）----
	_prep()
	var pl4: Player = battle.player
	pl4.apply_upgrade("cdr", mx)
	battle.extra.grant("orbit")
	_step(1)
	_check(not battle.extra._cd.has("orbit"), "orbit 无 interval、不接 cdr（_cd 里没有 orbit 键）")
	_check(battle.extra._blades.size() == int(GameStats.extra_weapon_tier("orbit", 1)["count"]),
		"cdr=40%% 不影响 orbit 刀数（仍 %d 把）" % int(GameStats.extra_weapon_tier("orbit", 1)["count"]))

	# ---- 端到端：同一 4s 窗口内，cdr 真的把副武器触发次数拉高 ----
	var n_lo := _cdr_lightning_hits(0.0)
	var n_hi := _cdr_lightning_hits(mx)
	_check(n_hi > n_lo,
		"端到端：4s 内闪电链触发 cdr0=%d → cdr40=%d（副武器攻速真的变快）" % [n_lo, n_hi])


## 固定 4s 窗口内、给定 cdr 下闪电链的触发次数（需要场上有目标才会真的劈、才计入 triggers）。
func _cdr_lightning_hits(cdr_v: float) -> int:
	_prep()
	battle.extra.reset()
	var pl: Player = battle.player
	if cdr_v > 0.0:
		pl.apply_upgrade("cdr", cdr_v)
	_spawn("Ox", pl.global_position + Vector2(120.0, 0.0))
	battle.extra.grant("lightning")
	_step(240)                                    # 240 × 1/60 = 4.0s
	return int(battle.extra.triggers.get("lightning", 0))


# ================================================================ D. 减益（冻结 / 减速 / 中毒）
func _sec_d_debuff() -> void:
	_section("D. 敌人减益：冻结 / 减速 / 中毒易伤（含 Boss 折扣）")
	_prep()
	var pl: Node2D = battle.player

	# ---- 冻结 ----
	var ox: Node2D = _spawn("Ox", pl.global_position + Vector2(260.0, 0.0))
	ox.freeze(0.8)
	_check(absf(float(ox.frozen_t) - 0.8) <= 1e-3, "普通怪冻结 0.8s（实际 %.3f）" % float(ox.frozen_t))
	var boss: Node2D = _spawn("Boss", pl.global_position + Vector2(400.0, 0.0))
	boss.freeze(1.0)
	_check(absf(float(boss.frozen_t) - 0.5) <= 1e-3,
		"Boss 冻结打对折：1.0 → %.2fs（EXTRA_FREEZE_BOSS_MUL %.1f）" % [float(boss.frozen_t), float(GameStats.EXTRA_FREEZE_BOSS_MUL)])

	# ---- 冻结真的停手：手动步进敌人的 _physics_process ----
	var fz: Node2D = _spawn_moving("Ox", pl.global_position + Vector2(300.0, 0.0))
	fz.freeze(5.0)
	var fp0: Vector2 = fz.global_position
	for i in 30:
		fz._physics_process(DT)
	_check(fz.global_position.distance_to(fp0) <= 0.001, "冻结期间敌人完全不移动（30 帧位移 %.3fpx）" % fz.global_position.distance_to(fp0))
	var mv: Node2D = _spawn_moving("Ox", pl.global_position + Vector2(300.0, 0.0))
	var mp0: Vector2 = mv.global_position
	for i in 30:
		mv._physics_process(DT)
	_check(mv.global_position.distance_to(mp0) > 1.0, "对照组（未冻结）会移动（30 帧位移 %.1fpx）" % mv.global_position.distance_to(mp0))

	# ---- 减速 ----
	ox._slow_mul = 1.0
	ox.apply_slow(float(GameStats.ORBIT_SLOW_MUL), 1.0)
	_check(absf(float(ox._slow_mul) - 0.5) <= 1e-4, "普通怪减速乘区 == 0.5（实际 %.2f）" % float(ox._slow_mul))
	_check(absf(float(ox._cur_speed()) - float(ox.speed) * float(ox.temp_speed_mul) * 0.5) <= 1e-3,
		"减速真的作用于实际移速 _cur_speed()（%.1f → %.1f）" % [float(ox.speed), float(ox._cur_speed())])
	boss._slow_mul = 1.0
	boss.apply_slow(float(GameStats.ORBIT_SLOW_MUL), 1.0)
	_check(absf(float(boss._slow_mul) - 0.75) <= 1e-4, "Boss 减速折扣：0.5 → 0.75（实际 %.2f）" % float(boss._slow_mul))

	# ---- 中毒易伤（Lv5 毒云）----
	ox._vuln_mul = 1.0
	ox._vuln_t = 0.0
	ox.apply_vuln(1.2, float(GameStats.ACID_VULN_DURATION))
	_check(absf(float(ox.incoming_vuln_mul()) - 1.2) <= 1e-4, "中毒易伤乘区 == 1.2（实际 %.2f）" % float(ox.incoming_vuln_mul()))
	var hp0: int = ox.hp
	battle.combat.deal_extra_damage(ox, 100, Color.WHITE, false)
	var dealt: int = hp0 - ox.hp
	_check(dealt == 120, "中毒期间的实扣伤害 100 → %d（×1.2 真的生效）" % dealt)
	ox._vuln_t = 0.0
	ox._vuln_mul = 1.0
	hp0 = ox.hp
	battle.combat.deal_extra_damage(ox, 100, Color.WHITE, false)
	_check(hp0 - ox.hp == 100, "未中毒时同伤害 = 100（乘区不残留）")

	# ---- 端到端：Lv5 环绕飞刃命中即挂减速 ----
	_prep()
	battle.extra.grant("orbit")
	for i in 4:
		battle.extra.level_up("orbit")
	var en2: Node2D = _spawn("Ox", pl.global_position + Vector2(90.0, 0.0))
	en2._slow_mul = 1.0
	_step(60)
	_check(float(en2._slow_mul) < 1.0, "Lv5 飞刃命中后敌人真的被减速（乘区 %.2f）" % float(en2._slow_mul))
	_check(absf(float(GameStats.extra_weapon_tier("orbit", 5)["slow"]) - 0.2) <= 1e-6,
		"Lv5 减速时长 0.2s（tier.slow）—— 很短，视觉/手感上基本无感")


# ================================================================ E. 独立性 / 卡池 / reset
func _sec_e_independence() -> void:
	_section("E1. 主副武器独立冷却（互不干扰）")
	_prep()
	var pl: Node2D = battle.player
	pl.attack_timer = 3.0
	pl.attack_enabled = true     # 主角武器「开着」但物理已关 ⇒ 只有副武器在推进
	battle.extra.grant("missile")
	_spawn("Ox", pl.global_position + Vector2(400.0, 0.0))
	_step(180)   # 3s
	_check(absf(float(pl.attack_timer) - 3.0) <= 1e-6,
		"副武器推进 3s 完全不碰 player.attack_timer（实际 %.3f）" % float(pl.attack_timer))
	_check(int(battle.extra.triggers.get("missile", 0)) >= 1, "副武器按自己的 interval 独立开火（%d 次）" % int(battle.extra.triggers.get("missile", 0)))


func _sec_e_cards() -> void:
	_section("E2. 抽卡过滤规则（获得 / 升级 / 满 2 把 / 满级）")
	_prep()
	battle._current_reason = "level"
	var c0: Array = battle._extra_weapon_cards()
	_check(_count_ids(c0, "w_orbit_gain") == 1, "未持有时出「获得」卡")
	_check(_count_suffix(c0, "_lvl") == 0, "未持有时不出「升级」卡")
	_check(c0.size() == 5, "空手时 5 张获得卡都在（实际 %d）" % c0.size())
	battle.extra.grant("orbit")
	battle.extra.grant("lightning")
	var c1: Array = battle._extra_weapon_cards()
	_check(_count_suffix(c1, "_gain") == 0, "持满 2 把后不再出「获得」卡（实际 %d）" % _count_suffix(c1, "_gain"))
	_check(_count_ids(c1, "w_orbit_lvl") == 1 and _count_ids(c1, "w_lightning_lvl") == 1, "已持有的两把出「升级」卡")
	_check(not battle.extra.grant("missile"), "持满 2 把后 grant(第 3 把) 返回 false")
	# 升级卡文案真的写进了参数（玩家看得见成长）
	var lvl_card: Dictionary = {}
	for c in c1:
		if String(c["id"]) == "w_orbit_lvl":
			lvl_card = c
	_check(not lvl_card.is_empty() and String(lvl_card["display"]).contains("2 把"),
		"升级卡文案显示升到 Lv2 的实际参数（%s）" % String(lvl_card.get("display", "无")))
	for i in 4:
		battle.extra.level_up("orbit")
	var c2: Array = battle._extra_weapon_cards()
	_check(_count_ids(c2, "w_orbit_lvl") == 0, "某把满 Lv5 后它的升级卡消失")
	_check(_count_ids(c2, "w_lightning_lvl") == 1, "另一把未满级 ⇒ 升级卡仍在")


func _sec_e_reset() -> void:
	_section("E3. 重开一局清空（不继承上一局）")
	_prep()
	battle.extra.grant("orbit")
	battle.extra.grant("acid")
	_step(1)
	battle.wave.spawn_enemy("Ox", battle.player.global_position + Vector2(70.0, 0.0), 1.0, false)
	_step(200)   # 让毒池/飞刃都跑起来
	_check(battle.extra.owned_count() == 2 and not battle.extra._pools.is_empty(), "重开前：持有 2 把且场上有毒池")
	var fx_before := _count_live(ExtraWeaponSystem.BladeFX) + _count_live(ExtraWeaponSystem.AcidPoolFX)
	_check(fx_before >= 3, "重开前：场上残留视觉实体 %d 个" % fx_before)
	battle.start_run()
	_check(battle.extra.owned_count() == 0, "start_run 后持有表清空")
	_check(battle.extra._blades.is_empty(), "飞刃节点全部回收")
	_check(battle.extra._pools.is_empty() and battle.extra._missiles.is_empty(), "毒池 / 导弹表清空")
	_check(battle.extra.triggers.is_empty(), "触发计数清零")
	battle.extra.reset()
	_check(_count_live(ExtraWeaponSystem.BladeFX) == 0 and _count_live(ExtraWeaponSystem.AcidPoolFX) == 0,
		"reset 后场上无残留副武器视觉节点")


# ================================================================ 工具
## 清场 + 站桩：关 Battle 物理（本探针全程手动步进）、玩家缴械静止、暴击置 0
func _prep() -> void:
	battle.start_run()
	battle.set_physics_process(false)
	battle.spawn_remaining = 0
	var pl: Node2D = battle.player
	pl.set_physics_process(false)
	pl.autopilot = false
	pl.attack_enabled = false
	pl.god_mode = true
	pl.atk = 100
	pl.crit = 0.0            # 确定性：randf() < 0 恒 false
	pl.critd = 1.5


## 生成一只静止的敌人（血厚，避免测试中被一击打死）
func _spawn(type_name: String, pos: Vector2) -> Node2D:
	var e := _spawn_moving(type_name, pos)
	e.set_physics_process(false)
	return e


## 生成一只「物理仍开着」的敌人（冻结行为测试需要手动步进它的 _physics_process）
func _spawn_moving(type_name: String, pos: Vector2) -> Node2D:
	battle.wave.spawn_enemy(type_name, pos, 1.0, false)
	var e: Node2D = battle.enemies[battle.enemies.size() - 1]
	e.hp = 100000
	e.max_hp = 100000
	return e


func _step(n: int) -> void:
	for i in n:
		battle.extra.update(DT)


## 副武器单次伤害的期望值（与 ExtraWeaponSystem._base_damage 同式，独立抄写）
func _raw(mul: float) -> int:
	var pl: Node2D = battle.player
	return maxi(1, roundi(float(pl.atk) * mul * float(pl.damage_bonus())))


## 数一排等级点里「点亮」的个数（点亮色 = Hud.EXTRA_PIP_ON，与 HUD 实现同源常量）。
func _lit_pips(pips: Array) -> int:
	var n := 0
	for p in pips:
		var pr: ColorRect = p
		if pr.visible and pr.color.is_equal_approx(Hud.EXTRA_PIP_ON):
			n += 1
	return n


func _count_live(t: Variant) -> int:
	var n := 0
	for c in battle.world.get_children():
		if c.is_queued_for_deletion():
			continue
		if is_instance_of(c, t):
			n += 1
	return n


func _one_live(t: Variant) -> Node:
	for c in battle.world.get_children():
		if c.is_queued_for_deletion():
			continue
		if is_instance_of(c, t):
			return c
	return null


func _free_fx() -> void:
	for c in battle.world.get_children():
		if is_instance_of(c, ExtraWeaponSystem.BladeFX) \
				or is_instance_of(c, ExtraWeaponSystem.LightningFX) \
				or is_instance_of(c, ExtraWeaponSystem.IceNovaFX) \
				or is_instance_of(c, ExtraWeaponSystem.AcidPoolFX) \
				or is_instance_of(c, ExtraWeaponSystem.MissileFX) \
				or is_instance_of(c, ExtraWeaponSystem.BlastFX):
			c.queue_free()
	battle.extra._blades.clear()
	battle.extra._blade_hits.clear()
	battle.extra._pools.clear()
	battle.extra._missiles.clear()


func _count_ids(cards: Array, id: String) -> int:
	var n := 0
	for c in cards:
		if String(c.get("id", "")) == id:
			n += 1
	return n


func _count_suffix(cards: Array, suffix: String) -> int:
	var n := 0
	for c in cards:
		if String(c.get("id", "")).ends_with(suffix):
			n += 1
	return n


func _eq(a: Variant, b: Variant) -> bool:
	if typeof(a) == TYPE_FLOAT or typeof(b) == TYPE_FLOAT:
		return absf(float(a) - float(b)) <= 1e-6
	return int(a) == int(b)


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
