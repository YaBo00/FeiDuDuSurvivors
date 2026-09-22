extends SceneTree
## 独立验证探针：MetaSave 局外永久强化商店（A2/A6 消费端第二片）。
##
## 被验证的契约：
##   MetaSave.META_UPGRADES（**9 条**，id 唯一 / 等级 / 价格曲线合法 / 文案非空）
##   MetaSave.xp_earned（纯函数折算：kills/20 + wave×3 + 通关 +100）
##   MetaSave.record_run（入账同时折算 meta_xp）
##   MetaSave.purchase（余额不足拒 / 满级拒 / 成功扣费升级并持久化）
##   MetaSave.ledger（空回落 / 坏 JSON 安全回落 / v2 meta_levels 读取）
##   MetaSave.meta_bonus（9 键；等级 → 加成系数映射；0 级全 0）
##   Player.recalc_stats（meta 注入：atk 乘区 / hp 平加 / pickup 乘区 / crit 加法 / aspd 乘区）
##   Player.add_gold / gain_xp（meta 金币 / 经验乘区）
##   Player.reset（启动资金）
##   Player.take_hit（复活契约：每局一次、回 50% 血、长无敌、三套免死计数独立）
##
## 用法: godot --headless --path <项目> --script res://scripts/dev/_ProbeMetaShop.gd
## 退出码 0=PASS 1=FAIL（门禁用 grep -q "RESULT=PASS" 判定）

const PROBE_PATH := "user://probe_meta_shop.json"
## 期望的 9 条 id（顺序即商店显示顺序 —— 顺序变了要同步改这里，UI 直接遍历表）
const EXPECT_IDS := ["meta_atk", "meta_hp", "meta_crit", "meta_aspd", "meta_pickup",
	"meta_gold", "meta_xp", "meta_start_gold", "meta_revive"]
## meta_bonus() 必须返回的 9 个键（键名是 Player/Battle 的消费契约，改名即断线）
const EXPECT_BONUS_KEYS := ["atk_mul", "hp_flat", "pickup_mul", "gold_mul", "xp_mul",
	"crit", "aspd_mul", "start_gold", "revive"]

var battle: Node = null
var armed := false
var finished := false
var checks := 0
var fails: Array[String] = []


func _initialize() -> void:
	print("[PROBE] === MetaSave 局外强化商店验证（消费端第二片）===")
	# ① 重定向存档路径 + 清场：探针绝不读写真实账本
	MetaSave.save_path = PROBE_PATH
	_del_save()
	var packed: PackedScene = load("res://scenes/battle/Battle.tscn")
	if packed == null:
		_finish("Battle.tscn 加载失败")
		return
	battle = packed.instantiate()
	root.add_child(battle)


func _arm() -> void:
	# ---- A. 静态契约 ----
	_check(MetaSave.META_UPGRADES.size() == EXPECT_IDS.size(),
		"META_UPGRADES 共 %d 条（实际 %d）" % [EXPECT_IDS.size(), MetaSave.META_UPGRADES.size()])
	var ids := {}
	var statics_ok := true
	var order_ok := true
	for i in MetaSave.META_UPGRADES.size():
		var u: Dictionary = MetaSave.META_UPGRADES[i]
		var id := String(u["id"])
		if ids.has(id) or int(u["max_level"]) < 1 or float(u["base_cost"]) <= 0.0 \
				or float(u["cost_growth"]) < 1.0 or String(u["name"]) == "" \
				or String(u["desc"]) == "":
			statics_ok = false
		if i < EXPECT_IDS.size() and id != EXPECT_IDS[i]:
			order_ok = false
		ids[id] = true
	# cost_growth 下限放宽到 1.0（2026-09-22）：`meta_revive` 是 max_level=1 的一次性大件，
	# 曲线不参与（1.0 = 唯一价 500）。旧断言写死 `<= 1.0` 会把合法的解锁定为非法。
	_check(statics_ok, "升级表合法（id 唯一 / max_level>=1 / 成本正 / 增长>=1.0 / 名称与文案非空）")
	_check(order_ok, "9 条 id 与顺序符合预期（UI 直接遍历本表，顺序即显示顺序）")
	_check(int(MetaSave.xp_earned(true, 10, 200)) == 140, "xp_earned(true,10,200)==140（kills/20+wave×3+通关100）")
	_check(int(MetaSave.xp_earned(false, 5, 40)) == 17, "xp_earned(false,5,40)==17（无通关奖励）")

	# ---- B. 空回落 ----
	var d0: Dictionary = MetaSave.ledger()
	_check(int(d0["meta_xp"]) == 0 and int(d0["runs"]) == 0 and (d0["meta_levels"] as Dictionary).is_empty(),
		"无档 → 干净账本（meta_xp=0 / meta_levels 空）")

	# ---- C. record_run 入账 + 折算 ----
	MetaSave.record_run(true, 10, 200, 50)
	var d1: Dictionary = MetaSave.ledger()
	_check(int(d1["runs"]) == 1 and int(d1["best_wave"]) == 10, "record_run 后 runs=1 / best_wave=10")
	_check(int(d1["meta_xp"]) == 140, "结算折算 meta_xp=140（实际 %s）" % str(d1["meta_xp"]))

	# ---- D. 购买成功 + 持久化 ----
	# 首级 meta_atk 价 120；当前 140 → 买得起
	var price0 := int(MetaSave.upgrade_cost("meta_atk", 0))
	_check(price0 == 120, "meta_atk 首级价 120（实际 %d）" % price0)
	_check(MetaSave.purchase("meta_atk"), "purchase(meta_atk) 成功（140 ≥ 120）")
	var d2: Dictionary = MetaSave.ledger()
	_check(int(d2["meta_levels"].get("meta_atk", 0)) == 1 and int(d2["meta_xp"]) == 140 - 120,
		"购买后等级=1 / 余额=20（实际 %s）" % str(d2["meta_xp"]))
	# 重读（新进程语义：落盘后 ledger 重读一致）
	var d2b: Dictionary = MetaSave.ledger()
	_check(int(d2b["meta_levels"].get("meta_atk", 0)) == 1, "持久化：重读等级一致")

	# ---- E. 余额不足拒购 ----
	_check(not MetaSave.purchase("meta_atk"), "二级价 240 > 余额 20 → 拒购")

	# ---- F. 满级封顶 ----
	MetaSave.record_run(true, 20, 100000, 0)   # 补足大量 xp（20波+5000杀+100 → 5250+60+100）
	for i in 4:
		MetaSave.purchase("meta_pickup")       # 3 级封顶 → 前 3 次成功
	_check(int(MetaSave.ledger()["meta_levels"].get("meta_pickup", 0)) == 3, "meta_pickup 买满 3 级")
	_check(not MetaSave.purchase("meta_pickup"), "满级后再购 → 拒")

	# ---- G. 坏 JSON 安全回落 ----
	var f := FileAccess.open(PROBE_PATH, FileAccess.WRITE)
	f.store_string("{{{not json")
	f = null
	var d3: Dictionary = MetaSave.ledger()
	_check(int(d3["runs"]) == 0 and (d3["meta_levels"] as Dictionary).is_empty(),
		"坏档 → 安全回落干净账本（并已覆盖写回）")

	# ---- H. meta_bonus 等级 → 加成映射 ----
	var b0: Dictionary = MetaSave.meta_bonus()
	var keys_ok := b0.size() == EXPECT_BONUS_KEYS.size()
	for k in EXPECT_BONUS_KEYS:
		if not b0.has(k):
			keys_ok = false
	_check(keys_ok, "meta_bonus 返回 9 键齐备（%s）" % str(EXPECT_BONUS_KEYS))
	var zero_sum := 0.0
	for k in EXPECT_BONUS_KEYS:
		zero_sum += absf(float(b0[k]))
	_check(_approx(zero_sum, 0.0), "0 级 meta_bonus 全 0（9 键绝对值之和 0）")
	MetaSave.record_run(true, 100, 100000, 0)   # 坏档后余额 0 → 补 5400 xp（5000+300+100）
	# 9 条各买 1 级（合计 120+100+130+120+80+100+110+90+500 = 1350 ≤ 5400）
	var bought_ok := true
	for id in EXPECT_IDS:
		if not MetaSave.purchase(id):
			bought_ok = false
			print("[PROBE]   · 买不动：%s" % id)
	_check(bought_ok, "9 条各买 1 级全部成功（余额充足）")
	var b1: Dictionary = MetaSave.meta_bonus()
	_check(_approx(float(b1["atk_mul"]), 0.03) and _approx(float(b1["hp_flat"]), 20.0) \
		and _approx(float(b1["pickup_mul"]), 0.15),
		"火力/生命/磁力 1 级 → 0.03 / 20 / 0.15")
	_check(_approx(float(b1["gold_mul"]), 0.10) and _approx(float(b1["xp_mul"]), 0.08),
		"财富/智慧 1 级 → gold_mul 0.10 / xp_mul 0.08")
	_check(_approx(float(b1["crit"]), 0.02) and _approx(float(b1["aspd_mul"]), 0.03),
		"致命/急速 1 级 → crit 0.02（加法）/ aspd_mul 0.03（乘区）")
	_check(_approx(float(b1["start_gold"]), 50.0) and int(b1["revive"]) == 1,
		"启动资金 1 级 → 50；复活契约 1 级 → 1（一次性，不叠层）")
	# 价格曲线：base × growth^level（启动资金 growth=1.8 ⇒ 二级价 = round(90×1.8) = 162）
	_check(int(MetaSave.upgrade_cost("meta_start_gold", 1)) == 162,
		"启动资金二级价 162（90×1.8^1，实际 %d）" % int(MetaSave.upgrade_cost("meta_start_gold", 1)))
	# 一次性大件封顶：复活契约 max_level=1 ⇒ 第二次购买必须被拒
	_check(not MetaSave.purchase("meta_revive"), "复活契约 max_level=1 → 二次购买被拒（不可叠）")

	# ---- I. Player 集成（真实 Battle 链路）----
	battle.start_run()
	battle.spawn_remaining = 0
	var pl: Node = battle.player
	pl.autopilot = false
	pl.god_mode = true
	# 守卫验证：探针进程（--script）不被注入，meta_bonus_dict 必须为空
	_check((pl.meta_bonus_dict as Dictionary).is_empty(), "探针进程 start_run 不注入 meta（守卫生效）")
	# 零行为变化：空 meta 下 recalc 前后一致（含新增的 crit/aspd 两键）
	var atk0 := int(pl.atk)
	var hp0 := int(pl.max_hp)
	var pk0 := float(pl.pickup_range)
	var crit0 := float(pl.crit)
	var aspd0 := float(pl.aspd)
	var gold0 := int(pl.gold)
	var base_gold := int(GameStats.character(pl.char_id)["start_gold"])
	_check(gold0 == base_gold, "无 meta ⇒ 开局金币 = 角色初始值（%d）" % base_gold)
	pl.meta_bonus_dict = {"atk_mul": 0.0, "hp_flat": 0.0, "pickup_mul": 0.0, "crit": 0.0, "aspd_mul": 0.0}
	pl.recalc_stats()
	_check(int(pl.atk) == atk0 and int(pl.max_hp) == hp0 and _approx(float(pl.pickup_range), pk0) \
		and _approx(float(pl.crit), crit0) and _approx(float(pl.aspd), aspd0),
		"零 meta：recalc 后 atk/hp/pickup/crit/aspd 逐位不变")
	# 注入加成 → 五属性按预期变化
	pl.meta_bonus_dict = {"atk_mul": 0.03, "hp_flat": 20.0, "pickup_mul": 0.15,
		"crit": 0.02, "aspd_mul": 0.03}
	pl.recalc_stats()
	_check(int(pl.atk) == roundi(float(atk0) * 1.03), "atk %d → %d（×1.03）" % [atk0, int(pl.atk)])
	_check(int(pl.max_hp) == hp0 + 20, "max_hp %d → %d（+20）" % [hp0, int(pl.max_hp)])
	_check(_approx(float(pl.pickup_range), pk0 * 1.15), "pickup_range %.1f → %.1f（×1.15）" % [pk0, float(pl.pickup_range)])
	_check(_approx(float(pl.crit), minf(GameStats.MAX_CRIT, crit0 + 0.02)),
		"crit %.3f → %.3f（+0.02 加法）" % [crit0, float(pl.crit)])
	_check(_approx(float(pl.aspd), clampf(aspd0 * 1.03, 0.05, GameStats.MAX_ASPD)),
		"aspd %.4f → %.4f（×1.03 乘区）" % [aspd0, float(pl.aspd)])
	# 回滚 → 精确还原基线（幂等 recalc）
	pl.meta_bonus_dict = {}
	pl.recalc_stats()
	_check(int(pl.atk) == atk0 and int(pl.max_hp) == hp0 and _approx(float(pl.pickup_range), pk0) \
		and _approx(float(pl.crit), crit0) and _approx(float(pl.aspd), aspd0),
		"清空 meta：recalc 后精确还原基线")

	# ---- J. 金币 / 经验乘区（入账点消费）----
	pl.meta_bonus_dict = {"gold_mul": 0.10}
	var g1 := int(pl.gold)
	pl.add_gold(10)
	_check(int(pl.gold) == g1 + 11, "加 10 金 → +11（×1.10 取整，实际 +%d）" % (int(pl.gold) - g1))
	pl.gold = g1
	pl.add_gold(1)
	_check(int(pl.gold) == g1 + 1, "加 1 金 → +1（取整后仍有下限 1，不会吞成 0）")
	pl.meta_bonus_dict = {"xp_mul": 0.08}
	pl.xp_to_next = 999999   # 防连升干扰（只验入账乘区）
	var xp0 := int(pl.xp)
	pl.gain_xp(100)
	_check(int(pl.xp) == xp0 + 108, "给 100 经验 → +108（×1.08，实际 +%d）" % (int(pl.xp) - xp0))
	pl.meta_bonus_dict = {}
	pl.xp = xp0
	pl.gain_xp(100)
	_check(int(pl.xp) == xp0 + 100, "清空 meta：给 100 经验 → +100（逐位回到基线）")
	pl.xp = xp0
	pl.xp_to_next = roundi(GameStats.START_XP_TO_NEXT)

	# ---- K. 启动资金（开局金币收口点 = Player.reset）----
	pl.meta_bonus_dict = {"start_gold": 100.0, "gold_mul": 0.10}
	pl.reset(Vector2.ZERO)
	_check(int(pl.gold) == base_gold + 100,
		"启动资金 2 级 → 开局金币 %d + 100 = %d（实际 %d）" % [base_gold, base_gold + 100, int(pl.gold)])
	# ↑ 同一条断言同时证明「启动资金没过 add_gold」：若绕了金币乘区会变成 base+110（自乘 bug）
	pl.meta_bonus_dict = {}

	# ---- L. 复活契约（每局一次 / 回 50% 血 / 长无敌 / 与另两套免死独立计数）----
	pl.meta_bonus_dict = {"revive": 1}
	pl.reset(Vector2.ZERO)
	pl.traits_enabled = false      # 隔离「初心」天赋：否则本局第一次致死被它吃掉
	pl.god_mode = false
	pl.invincible_timer = 0.0
	_check(not bool(pl.meta_revive_used), "开局：契约未使用（每局重置）")
	var hp_half := maxi(1, roundi(float(pl.max_hp) * 0.5))
	var r1: Dictionary = pl.take_hit(999999)
	_check(String(r1["result"]) == "hit" and String(r1.get("trait", "")) == "meta_revive",
		"致死被契约救回（result=hit / trait=meta_revive，实际 %s/%s）" % [str(r1["result"]), str(r1.get("trait", ""))])
	_check(int(pl.hp) == hp_half, "复活回 50%% 血（%d，期望 %d）" % [int(pl.hp), hp_half])
	_check(bool(pl.meta_revive_used), "标记「本局已用」（不可二次）")
	_check(float(pl.invincible_timer) > 0.0, "复活后立即进入无敌（%.2fs）" % float(pl.invincible_timer))
	# 二次致死：探针要反复构造致死，先把 died 从 Battle 断开，别真把这一局结算掉
	var linked: bool = pl.died.is_connected(battle._on_player_died)
	if linked:
		pl.died.disconnect(battle._on_player_died)
	pl.invincible_timer = 0.0
	var r2: Dictionary = pl.take_hit(999999)
	if linked:
		pl.died.connect(battle._on_player_died)
	_check(String(r2["result"]) == "dead", "同一局第二次致死 → 不再复活（result=dead）")
	# 三套免死计数独立：复活币是商配件，不该被契约偷吃
	pl.reset(Vector2.ZERO)
	pl.traits_enabled = false
	pl.resurrect_charges = 1
	pl.invincible_timer = 0.0
	var r3: Dictionary = pl.take_hit(999999)
	_check(String(r3.get("trait", "")) == "resurrect" and int(pl.resurrect_charges) == 0,
		"复活币与契约独立计数：先吃复活币（trait=resurrect）")
	_check(not bool(pl.meta_revive_used), "吃了复活币后契约仍未消耗（各自计数）")
	pl.invincible_timer = 0.0
	var r4: Dictionary = pl.take_hit(999999)
	_check(String(r4.get("trait", "")) == "meta_revive", "复活币用完后契约才生效（顺序：初心→复活币→契约）")
	pl.meta_bonus_dict = {}
	pl.reset(Vector2.ZERO)
	pl.god_mode = true

	_del_save()


func _del_save() -> void:
	if FileAccess.file_exists(PROBE_PATH):
		DirAccess.remove_absolute(PROBE_PATH)


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
		armed = true
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
