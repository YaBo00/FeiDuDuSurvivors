extends SceneTree
## 独立验证探针：角色特性与武器表（4 人）+ 土豆/袋鼠怪（T-CHAR-03，第 5、6 人）。
##
## 依据 docs/design/人物设计_嘉豪四人组_2026-09-19.md §8.2 的 7 条确定性断言（1~7 组），
## 以及 docs/角色设计_土豆与袋鼠怪_2026-09-19.md（8~13 组，T-CHAR-03 扩展）：
##   8. A 表完整性：CHARACTERS 新增 potato/kangaroo（顶层字段 + base 14 字段一个不落）、
##      WEAPON_DEFS 各 9 字段、trait_id = armor_stack / move_stacks、六键一一对应。
##   9. B 六人交叉对照：非 potato 受击永不叠甲；非 kangaroo 移动时 kanga 双乘区恒 1.0。
##  10. C 土豆 armor_stack：真实扣血（hit/dead）叠 1 层 → 等效防御 +TRAIT_ARMOR_STEP；
##      本击不享受新层；封顶 TRAIT_ARMOR_MAX；闪避/无敌帧/god_mode 不叠；
##      TRAIT_ARMOR_DECAY_TIME 不受击清零；reset() 清零；traits_enabled=false 全程不叠。
##  11. D 袋鼠怪 move_stacks：以 _movement_dir() 非零为移动判定（贴墙也算，§5.1）→
##      每满 TRAIT_KANGA_STACK_TIME 叠 1 层 → kanga_speed_mul()/kanga_aspd_mul() 线性抬升；
##      攻速乘区作用在 attack_timer 上（recalc 的 aspd 与 _bonus 不被改写 —— 幂等红线）；
##      静止满 TRAIT_KANGA_STOP_CLEAR 清零；封顶 TRAIT_KANGA_MAX；traits_enabled=false 恒 1.0。
##  12. E DPS 预算回归护栏：dmg_mul×base_shots×rate_mul 与设计文档 §4 六人表逐人一致
##      （写死自文档 —— 改它 = 改了主线平衡，必须先过设计线评审）。
##  13. F 端到端说明：`--selftest --char potato` / `--char kangaroo` 由门禁 [2][3] 覆盖。
##
## 与实现分属不同作者思路：这里的阈值全部从 GameStats 常量推导，不硬编码魔数。
##
## ⚠️ 反射纪律（同 _ProbeRangedBoss 的 Boss 技能探针）：T-CHAR-03 的新常量/新字段/新方法
##   尚在工程线并行落码 —— 新 GameStats 常量经 get_script_constant_map()、新 Player 字段经
##   get()/get_property_list()、新方法经 has_method()+call() 运行期反射访问；
##   契约未落地时优雅打印「契约未就绪」并 RESULT=FAIL，绝不因解析期硬错误拖红 CheckAll。
##
## 确定性驱动：Player 的钩子推进只依赖传入 delta ⇒ set_physics_process(false) 后手动
##   _physics_process(dt) 步进；移动输入经 set_touch_dir() 注入虚拟摇杆（键盘路径在
##   无头模式下恒为零）；受击用真实 take_hit() 调用（god_mode/无敌帧/dodge 三个短路项
##   在 _reset_to 已归零，需要时显式打开）。
##
## 用法: godot --headless --path <项目> --script res://scripts/dev/_ProbeCharTraits.gd
## 退出码 0=PASS 1=FAIL

const SKILL_DT := 1.0 / 60.0   # 确定性驱动步长
const RAW_HIT := 25            # 受击用例的标准敌方伤害（对 potato 150 血绝不会一击致死）
const WEAPON_FIELDS := ["name", "base_shots", "dmg_mul", "rate_mul", "pierce",
	"speed_mul", "radius_mul", "lifesteal", "gold_on_hit"]   # 武器条目必备 9 字段

var battle: Node = null
var player: Player = null
var armed := false
var finished := false
var checks := 0
var fails: Array[String] = []

# ---- T-CHAR-03 反射句柄与观测计数 ----
var _stats_script = null          # load("res://scripts/data/Stats.gd")，无类型走动态反射
var _consts: Dictionary = {}      # GameStats 常量表（TRAIT_ARMOR_* / TRAIT_KANGA_*）
var fired_count := 0              # player.fired 信号计数（攻速乘区用例）


func _initialize() -> void:
	print("[PROBE] ===== 角色特性（4 人）+ 土豆/袋鼠怪（T-CHAR-03）=====")
	# --- T-CHAR-03 契约就绪守卫（运行期反射，绝不静态引用未落地符号）---
	_stats_script = load("res://scripts/data/Stats.gd")
	if _stats_script == null:
		_finish("无法加载 res://scripts/data/Stats.gd")
		return
	_consts = _stats_script.get_script_constant_map()
	var missing := _tchar03_contract_missing()
	if not missing.is_empty():
		_finish("契约未就绪：缺少 %s（工程线未落地或被回退，探针按纪律优雅退出）" % str(missing))
		return
	print("[PROBE] T-CHAR-03 契约就绪：TRAIT_ARMOR_* / TRAIT_KANGA_* 常量与 Player 钩子齐全")
	print("[PROBE] 载入 Battle.tscn（拿真实 player + combat，不另造桩）")
	var packed: PackedScene = load("res://scenes/battle/Battle.tscn")
	if packed == null:
		_finish("Battle.tscn 加载失败")
		return
	battle = packed.instantiate()
	root.add_child(battle)
	# @onready 变量与 _ready() 要等第一帧才就绪 → 真正的断言推迟到 _process。
	print("[PROBE] Battle 已入树，断言推迟到第一帧")


## 第一帧：冻结战场，让断言完全确定（不刷怪、不自动开火、不跑物理）。
func _arm() -> void:
	armed = true
	player = battle.player
	# ⚠️ 断开 died → Battle._on_player_died：本探针要【反复构造致死】来验初心，
	# 而 _end_run(false) 会清场（释放我的木桩、清空 projectiles），把后续断言全毁掉。
	if player.died.is_connected(battle._on_player_died):
		player.died.disconnect(battle._on_player_died)
	# 停掉波次与刷怪
	battle.spawn_remaining = 0
	battle.wave_timer = 1.0e9
	battle.set_physics_process(false)
	# 停掉玩家自身物理（攻击/移动/金币衰减都在里面，会干扰断言）
	player.set_physics_process(false)
	player.autopilot = false
	player.attack_enabled = false
	# 清空波次可能已经产生的敌人
	battle._free_all_enemies()
	battle.enemies.clear()
	battle.projectiles.clear()
	player.fired.connect(_on_player_fired)

	_t1_weapon_table()
	_t2_beginner_save()
	_t3_levelup_aspd()
	_t4_money_rush()
	_t5_low_hp_fury()
	_t6_shop_discount()
	_t7_per_projectile_pierce()
	_t8_new_char_tables()
	_t9_cross_control()
	_t10_armor_stack()
	_t11_move_stacks()
	_t12_dps_budget()
	_t13_endtoend_note()


# ---------------------------------------------------------------- 断言 1
## 武器表完整性：4 个角色都有武器条目，9 个字段齐全且取值合法。
func _t1_weapon_table() -> void:
	print("[PROBE] --- 1. 武器表完整性 ---")
	const NEEDED := ["name", "base_shots", "dmg_mul", "rate_mul", "pierce",
		"speed_mul", "radius_mul", "lifesteal", "gold_on_hit"]
	for cid in GameStats.CHARACTERS.keys():
		var id := String(cid)
		if not GameStats.WEAPON_DEFS.has(id):
			_check(false, "角色 %s 缺少武器条目" % id)
			continue
		var w: Dictionary = GameStats.weapon_for_char(id)
		var missing: Array[String] = []
		for k in NEEDED:
			if not w.has(k):
				missing.append(k)
		_check(missing.is_empty(), "%s 武器字段齐全（缺：%s）" % [id, str(missing)])
		_check(int(w["pierce"]) >= 1, "%s pierce >= 1（实际 %d）" % [id, int(w["pierce"])])
		_check(float(w["dmg_mul"]) > 0.0, "%s dmg_mul > 0" % id)
		_check(float(w["rate_mul"]) > 0.0, "%s rate_mul > 0" % id)
		_check(int(w["base_shots"]) >= 1, "%s base_shots >= 1" % id)
	# 未知 id 必须回落 basic，绝不返回空字典
	var fallback: Dictionary = GameStats.weapon_for_char("__no_such_char__")
	_check(fallback.has("name") and String(fallback["name"]) == GameStats.WEAPON_DEFS["basic"]["name"],
		"未知 char_id 回落 basic 武器")


# ---------------------------------------------------------------- 断言 2
## 初心：满血吃致死一击 → hp==1 + 独立无敌时长 + 返回 hit；再来一次 → dead。
func _t2_beginner_save() -> void:
	print("[PROBE] --- 2. 初心（beginner_save） ---")
	_reset_to("basic")
	player.traits_enabled = true
	player.hp = float(player.max_hp)
	_check(player.trait_id == "beginner_save", "basic 的 trait_id == beginner_save")

	var r1: Dictionary = player.take_hit(999999)
	_check(String(r1["result"]) == "hit", "第一次致死返回 hit（实际 %s）" % r1["result"])
	_check(is_equal_approx(player.hp, 1.0), "免死后 hp == 1（实际 %.2f）" % player.hp)
	_check(is_equal_approx(player.invincible_timer, GameStats.TRAIT_SAVE_IFRAME),
		"免死后无敌 = TRAIT_SAVE_IFRAME(%.1fs)，实际 %.2fs" % [
			GameStats.TRAIT_SAVE_IFRAME, player.invincible_timer])
	_check(player._beginner_save_used, "免死标记已置位")

	# 第二次致死：无敌帧必须先清掉，否则会走 iframe 分支而不是 dead
	player.invincible_timer = 0.0
	var r2: Dictionary = player.take_hit(999999)
	_check(String(r2["result"]) == "dead", "第二次致死真的死（实际 %s）" % r2["result"])

	# 非 basic 角色不该有免死
	_reset_to("study")
	player.hp = float(player.max_hp)
	var r3: Dictionary = player.take_hit(999999)
	_check(String(r3["result"]) == "dead", "study 无免死，满血致死直接 dead（实际 %s）" % r3["result"])

	# traits_enabled=false（--selftest-defeat 路径）时初心必须失效
	_reset_to("basic")
	player.traits_enabled = false
	player.hp = float(player.max_hp)
	var r4: Dictionary = player.take_hit(999999)
	_check(String(r4["result"]) == "dead",
		"traits_enabled=false 时初心失效，确定性致死保住（实际 %s）" % r4["result"])
	player.traits_enabled = true


# ---------------------------------------------------------------- 断言 3
## 题海精进：连升 3 级 → _bonus["aspd"] 精确 = 3 × TRAIT_ASPD_PER_LEVEL。
func _t3_levelup_aspd() -> void:
	print("[PROBE] --- 3. 题海精进（levelup_aspd） ---")
	_reset_to("study")
	player.traits_enabled = true
	_check(player.trait_id == "levelup_aspd", "study 的 trait_id == levelup_aspd")
	var before: float = float(player._bonus["aspd"])

	# 按引擎自己的 xp_to_next 递推，凑出「正好 3 级」所需经验（不硬编码 61）
	var need := 0
	var sim_next: int = player.xp_to_next
	for i in 3:
		need += sim_next
		sim_next = roundi(float(sim_next) * GameStats.XP_GROWTH)
	var gained: int = player.gain_xp(need)
	_check(gained == 3, "gain_xp(%d) 恰好升 3 级（实际 %d）" % [need, gained])

	var delta: float = float(player._bonus["aspd"]) - before
	var expect: float = GameStats.TRAIT_ASPD_PER_LEVEL * 3.0
	_check(is_equal_approx(delta, expect),
		"3 级累计攻速加成 = %.2f（期望 %.2f）" % [delta, expect])

	# 对照：非学习豪升级不该动 aspd
	_reset_to("basic")
	var b0: float = float(player._bonus["aspd"])
	player.gain_xp(need)
	_check(is_equal_approx(float(player._bonus["aspd"]), b0),
		"basic 升级不改 aspd（对照）")


# ---------------------------------------------------------------- 断言 4
## 见钱眼开：连捡 5 枚 → 封顶 3 层 / 乘区 1.15；超时后归零。
func _t4_money_rush() -> void:
	print("[PROBE] --- 4. 见钱眼开（money_rush） ---")
	_reset_to("finance")
	player.traits_enabled = true
	_check(player.trait_id == "money_rush", "finance 的 trait_id == money_rush")

	for i in 5:
		player.add_gold(1)
	_check(player._money_stacks == GameStats.TRAIT_MONEY_BOOST_MAX,
		"连捡 5 枚封顶 %d 层（实际 %d）" % [GameStats.TRAIT_MONEY_BOOST_MAX, player._money_stacks])
	var expect_mul := 1.0 + GameStats.TRAIT_MONEY_BOOST_STEP * float(GameStats.TRAIT_MONEY_BOOST_MAX)
	_check(is_equal_approx(player.money_speed_mul(), expect_mul),
		"移速乘区 = %.2f（实际 %.2f）" % [expect_mul, player.money_speed_mul()])

	# 手动推进一小段物理时间 → 衰减到 0
	player._money_t = 0.001
	player._physics_process(0.01)
	_check(player._money_stacks == 0, "超时后层数归零（实际 %d）" % player._money_stacks)
	_check(is_equal_approx(player.money_speed_mul(), 1.0), "超时后移速乘区回到 1.0")

	# 对照：非金融豪捡钱不加层
	_reset_to("basic")
	player.add_gold(1)
	_check(player._money_stacks == 0 and is_equal_approx(player.money_speed_mul(), 1.0),
		"basic 捡钱不加层（对照）")


# ---------------------------------------------------------------- 断言 5
## 背水一战：hp 占比 100% / 49% / 24% → 1.0 / 1.25 / 1.40。
func _t5_low_hp_fury() -> void:
	print("[PROBE] --- 5. 背水一战（low_hp_fury） ---")
	_reset_to("sad")
	player.traits_enabled = true
	_check(player.trait_id == "low_hp_fury", "sad 的 trait_id == low_hp_fury")
	var mx := float(player.max_hp)

	player.hp = mx
	var b_full: float = player.damage_bonus()
	player.hp = mx * 0.49
	var b_t1: float = player.damage_bonus()
	player.hp = mx * 0.24
	var b_t2: float = player.damage_bonus()

	_check(is_equal_approx(b_full, 1.0), "满血 1.0（实际 %.3f）" % b_full)
	_check(is_equal_approx(b_t1, 1.0 + GameStats.TRAIT_FURY_T1_BONUS),
		"49%% 血 +%.0f%%（实际 %.3f）" % [GameStats.TRAIT_FURY_T1_BONUS * 100.0, b_t1])
	_check(is_equal_approx(b_t2,
			1.0 + GameStats.TRAIT_FURY_T1_BONUS + GameStats.TRAIT_FURY_T2_BONUS),
		"24%% 血 合计 +%.0f%%（实际 %.3f）" % [
			(GameStats.TRAIT_FURY_T1_BONUS + GameStats.TRAIT_FURY_T2_BONUS) * 100.0, b_t2])

	# 对照：basic 残血不加伤
	_reset_to("basic")
	player.hp = 1.0
	_check(is_equal_approx(player.damage_bonus(), 1.0), "basic 残血不加伤（对照）")


# ---------------------------------------------------------------- 断言 6
## 商店折扣：finance 永久 9 折；叠投资手册 0.82 → 0.738。
func _t6_shop_discount() -> void:
	print("[PROBE] --- 6. 商店折扣 ---")
	_reset_to("finance")
	_check(is_equal_approx(player.shop_discount, GameStats.TRAIT_SHOP_DISCOUNT_FINANCE),
		"finance 初始折扣 = %.2f（实际 %.3f）" % [
			GameStats.TRAIT_SHOP_DISCOUNT_FINANCE, player.shop_discount])

	player.apply_item("investment_manual")
	var manual: float = float(GameStats.ITEM_DEFS["investment_manual"]["effect"]["shop_discount"])
	var expect := GameStats.TRAIT_SHOP_DISCOUNT_FINANCE * manual
	_check(is_equal_approx(player.shop_discount, expect),
		"叠投资手册后 = %.3f（实际 %.3f）" % [expect, player.shop_discount])

	# 对照：basic 无折扣
	_reset_to("basic")
	_check(is_equal_approx(player.shop_discount, 1.0), "basic 无折扣（对照）")


# ---------------------------------------------------------------- 断言 7
## 逐弹道穿透：pierce_cap=99 的弹道连穿 3+ 个敌人仍不被回收（旧实现读全局常量会失败）。
func _t7_per_projectile_pierce() -> void:
	print("[PROBE] --- 7. 逐弹道穿透 ---")
	var pos := Vector2(1000.0, 700.0)
	var n := 4
	_place_fodder(pos, n)
	battle.combat.rebuild_grid()

	# A) pierce_cap = 99 → 必须活下来
	var alive: Projectile = _make_proj(pos, 99)
	battle.combat.process_projectiles(0.0)
	var a_ok := _still_listed(alive)
	_check(a_ok, "pierce_cap=99 连穿 %d 怪后仍存活（旧实现读全局 PROJ_PIERCE 会在此失败）" % n)
	_check(_hurt_count() >= n, "至少 %d 只敌人真的吃到伤害（实际 %d）" % [n, _hurt_count()])

	# B) 对照：pierce_cap = 2（= 全局 PROJ_PIERCE）→ 必须被回收
	_place_fodder(pos, n)
	battle.combat.rebuild_grid()
	var consumed: Projectile = _make_proj(pos, GameStats.PROJ_PIERCE)
	battle.combat.process_projectiles(0.0)
	_check(not _still_listed(consumed),
		"对照 pierce_cap=%d 连穿 %d 怪后被回收（证明读的是逐弹道值）" % [GameStats.PROJ_PIERCE, n])


# ================================================================ T-CHAR-03 扩展
## 契约就绪守卫：盘点 T-CHAR-03 需要的新常量 / 新 Player 字段 / 新方法。返回缺失清单。
func _tchar03_contract_missing() -> Array:
	var missing: Array = []
	for c in ["TRAIT_ARMOR_STEP", "TRAIT_ARMOR_MAX", "TRAIT_ARMOR_DECAY_TIME",
			"TRAIT_KANGA_STACK_TIME", "TRAIT_KANGA_SPD_STEP", "TRAIT_KANGA_ASPD_STEP",
			"TRAIT_KANGA_MAX", "TRAIT_KANGA_STOP_CLEAR"]:
		if not _consts.has(c):
			missing.append("GameStats.%s" % c)
	for k in ["potato", "kangaroo"]:
		if not GameStats.CHARACTERS.has(k):
			missing.append("GameStats.CHARACTERS['%s']" % k)
	var p = Player.new()   # 临时实例读属性表；不入树（@onready 不触发，无副作用）
	for f in ["_armor_stacks", "_armor_t", "_kanga_stacks", "_kanga_move_t", "_kanga_stop_t"]:
		if not _has_prop(p, f):
			missing.append("Player.%s" % f)
	for m in ["kanga_speed_mul", "kanga_aspd_mul"]:
		if not p.has_method(m):
			missing.append("Player.%s()" % m)
	p.free()
	return missing


# ---------------------------------------------------------------- 断言 8（A）
## 表完整性：potato/kangaroo 顶层字段 + base 14 字段 + 武器 9 字段 + 六键一一对应。
func _t8_new_char_tables() -> void:
	print("[PROBE] --- 8.（A）土豆/袋鼠怪 表完整性 ---")
	var base_fields := ["maxHp", "atk", "def", "spd", "aspd", "proj", "crit", "critd",
		"hpRegen", "dodge", "lifesteal", "harvest", "luck", "pickupRange"]
	var top_fields := ["name", "portrait", "talent", "desc", "trait_id",
		"start_gold", "xp_mul", "upgrade_opt_bonus"]
	var want_trait := {"potato": "armor_stack", "kangaroo": "move_stacks"}
	for id in ["potato", "kangaroo"]:
		var c: Dictionary = GameStats.CHARACTERS.get(id, {})
		_check(not c.is_empty(), "CHARACTERS 新增 '%s' 条目" % id)
		if c.is_empty():
			continue
		var miss_top: Array[String] = []
		for k in top_fields:
			if not c.has(k):
				miss_top.append(k)
		_check(miss_top.is_empty(), "%s 顶层字段齐全（缺：%s）" % [id, str(miss_top)])
		var base: Dictionary = c.get("base", {})
		var miss_base: Array[String] = []
		for k in base_fields:
			if not base.has(k):
				miss_base.append(k)
		_check(miss_base.is_empty(), "%s base 14 字段一个不落（缺：%s）" % [id, str(miss_base)])
		_check(String(c.get("trait_id", "")) == String(want_trait[id]),
			"%s trait_id == %s（实际 %s）" % [id, want_trait[id], c.get("trait_id", "缺")])
		var w: Dictionary = GameStats.WEAPON_DEFS.get(id, {})
		var miss_w: Array[String] = []
		for k in WEAPON_FIELDS:
			if not w.has(k):
				miss_w.append(k)
		_check(miss_w.is_empty(), "%s 武器 9 字段齐全（缺：%s）" % [id, str(miss_w)])
		if w.has("name"):
			_check(String(GameStats.weapon_for_char(id)["name"]) == String(w["name"]),
				"%s weapon 键与 char_id 一一对应（weapon_for_char 命中本条）" % id)
	var miss_wk: Array[String] = []
	for id2 in ["basic", "study", "finance", "sad", "potato", "kangaroo"]:
		if not GameStats.WEAPON_DEFS.has(id2):
			miss_wk.append(id2)
	_check(miss_wk.is_empty(), "WEAPON_DEFS 六个 char_id 键全在（缺：%s）" % str(miss_wk))


# ---------------------------------------------------------------- 断言 9（B）
## 六人交叉对照：非本角色，新特性状态恒为默认值（证明断言不是空转）。
func _t9_cross_control() -> void:
	print("[PROBE] --- 9.（B）六人交叉对照（非本角色恒为默认） ---")
	for cid in ["basic", "study", "finance", "sad", "potato", "kangaroo"]:
		var id := String(cid)
		if id != "potato":
			# armor 对照：非 potato 受击（真实扣血）永不叠甲
			_reset_to(id)
			player.traits_enabled = true
			player.hp = float(player.max_hp)
			var r: Dictionary = player.take_hit(RAW_HIT)
			_check(String(r["result"]) == "hit", "%s 对照受击确实发生（实际 %s）" % [id, r["result"]])
			_check(int(player.get("_armor_stacks")) == 0, "%s 受击后 _armor_stacks 恒 0（实际 %d）" % [
				id, int(player.get("_armor_stacks"))])
			_check(float(player.get("_armor_t")) == 0.0, "%s 受击后 _armor_t 恒 0" % id)
		if id != "kangaroo":
			# kanga 对照：非 kangaroo 持续移动也不叠层、双乘区恒 1.0
			_reset_to(id)
			player.traits_enabled = true
			player.set_touch_dir(Vector2.RIGHT)
			_step_seconds(float(_consts["TRAIT_KANGA_STACK_TIME"]) * 1.5 + 2.0 * SKILL_DT)
			_check(int(player.get("_kanga_stacks")) == 0, "%s 持续移动后 _kanga_stacks 恒 0（实际 %d）" % [
				id, int(player.get("_kanga_stacks"))])
			_check(is_equal_approx(float(player.call("kanga_speed_mul")), 1.0)
				and is_equal_approx(float(player.call("kanga_aspd_mul")), 1.0),
				"%s kanga_speed_mul/aspd_mul 恒 1.0" % id)
	player.set_touch_dir(Vector2.ZERO)


# ---------------------------------------------------------------- 断言 10（C）
## 土豆 armor_stack：真实扣血叠层 / 本击不享受新层 / 封顶 / 短路项 / 衰减 / reset / 开关。
func _t10_armor_stack() -> void:
	print("[PROBE] --- 10.（C）土豆 armor_stack（确定性驱动） ---")
	var step := _cst("TRAIT_ARMOR_STEP")
	var amax := int(_cst("TRAIT_ARMOR_MAX"))
	var decay := _cst("TRAIT_ARMOR_DECAY_TIME")
	var raw := RAW_HIT

	# C0. 致死受击也叠层（层在结算后叠；died 信号已与 Battle 断开，安全）
	_reset_to("potato")
	player.traits_enabled = true
	_check(player.trait_id == "armor_stack", "potato 的 trait_id == armor_stack")
	_check(int(player.get("_armor_stacks")) == 0 and float(player.get("_armor_t")) == 0.0,
		"初始甲层 / 计时为 0")
	player.hp = 1.0
	var rd: Dictionary = player.take_hit(999999)
	_check(String(rd["result"]) == "dead", "致死受击返回 dead（实际 %s）" % rd["result"])
	_check(int(player.get("_armor_stacks")) == 1,
		"致死（真实扣血）结算后叠 1 层（实际 %d）" % int(player.get("_armor_stacks")))

	# C1. 主序列：本击不享受新层（伤害按叠层前的层数算），逐层叠到封顶
	_reset_to("potato")
	player.traits_enabled = true
	var defense0: int = player.defense
	for i in amax:
		player.invincible_timer = 0.0
		var expect: int = GameStats.incoming_damage(raw, defense0 + i * step)  # 本击用【叠层前】层数
		var r: Dictionary = player.take_hit(raw)
		_check(String(r["result"]) == "hit", "第 %d 次受击真实扣血（实际 %s）" % [i, r["result"]])
		_check(int(r["dmg"]) == expect,
			"第 %d 次受击伤害 %d == incoming(raw, def+%d×STEP)=%d（本击不享受新层）" % [
				i, int(r["dmg"]), i, expect])
		_check(int(player.get("_armor_stacks")) == mini(amax, i + 1),
			"第 %d 次受击后甲层 = %d（实际 %d）" % [i, mini(amax, i + 1), int(player.get("_armor_stacks"))])
		_check(is_equal_approx(float(player.get("_armor_t")), decay),
			"受击后 _armor_t 刷新为 DECAY_TIME(%.1fs)" % decay)
	for j in 2:
		player.invincible_timer = 0.0
		var expect_cap: int = GameStats.incoming_damage(raw, defense0 + amax * step)
		var rc: Dictionary = player.take_hit(raw)
		_check(int(player.get("_armor_stacks")) == amax,
			"超上限甲层封顶 %d（实际 %d）" % [amax, int(player.get("_armor_stacks"))])
		_check(int(rc["dmg"]) == expect_cap,
			"封顶期伤害按满层 %d 计算（实际 %d）" % [expect_cap, int(rc["dmg"])])
	_check(defense0 + amax * step > defense0,
		"满层等效防御 %d > 基础防御 %d（防御等效 +TRAIT_ARMOR_STEP×层数）" % [defense0 + amax * step, defense0])

	# C2. 闪避 / 无敌帧 / god_mode 三个短路项都不算「受击」、不叠层（设计文档 §5.3）
	var st_keep := int(player.get("_armor_stacks"))
	player.dodge = 1.0
	player.invincible_timer = 0.0
	var rdd: Dictionary = player.take_hit(raw)
	_check(String(rdd["result"]) == "dodge", "强制闪避命中 dodge 分支（实际 %s）" % rdd["result"])
	_check(int(player.get("_armor_stacks")) == st_keep, "闪避不叠层（实际 %d）" % int(player.get("_armor_stacks")))
	player.dodge = 0.0
	player.invincible_timer = GameStats.IFRAME_DURATION
	var rdi: Dictionary = player.take_hit(raw)
	_check(String(rdi["result"]) == "iframe", "无敌帧命中 iframe 分支（实际 %s）" % rdi["result"])
	_check(int(player.get("_armor_stacks")) == st_keep, "无敌帧命中不叠层（实际 %d）" % int(player.get("_armor_stacks")))
	player.invincible_timer = 0.0
	player.god_mode = true
	var rdg: Dictionary = player.take_hit(raw)
	_check(String(rdg["result"]) == "iframe", "god_mode 命中观测分支（实际 %s）" % rdg["result"])
	_check(int(player.get("_armor_stacks")) == st_keep, "god_mode 不叠层（实际 %d）" % int(player.get("_armor_stacks")))
	player.god_mode = false

	# C3. reset() 清零
	_check(int(player.get("_armor_stacks")) > 0, "reset 前甲层 > 0（前置自检）")
	player.reset(Vector2(1000.0, 700.0))
	player.set_physics_process(false)
	_check(int(player.get("_armor_stacks")) == 0 and float(player.get("_armor_t")) == 0.0,
		"reset() 清零甲层与计时（实际 %d / %.2f）" % [int(player.get("_armor_stacks")), float(player.get("_armor_t"))])

	# C4. 不受击 DECAY_TIME 后清零（半程不早清）
	_reset_to("potato")
	player.traits_enabled = true
	player.invincible_timer = 0.0
	player.take_hit(raw)
	_check(int(player.get("_armor_stacks")) == 1, "衰减用例：先叠 1 层（实际 %d）" % int(player.get("_armor_stacks")))
	_step_seconds(decay * 0.5)
	_check(int(player.get("_armor_stacks")) == 1, "半程（%.1fs）不早清（实际 %d）" % [decay * 0.5, int(player.get("_armor_stacks"))])
	_step_seconds(decay)
	_check(int(player.get("_armor_stacks")) == 0,
		"不受击 %.1fs（累计）后清零（实际 %d）" % [decay * 1.5, int(player.get("_armor_stacks"))])

	# C5. traits_enabled=false（--selftest-defeat 语义）全程不叠、无等效防御
	_reset_to("potato")
	player.traits_enabled = false
	for k in 2:
		player.invincible_timer = 0.0
		var expect0: int = GameStats.incoming_damage(raw, player.defense)
		var r0: Dictionary = player.take_hit(raw)
		_check(int(player.get("_armor_stacks")) == 0,
			"traits_enabled=false 第 %d 次受击不叠层（实际 %d）" % [k, int(player.get("_armor_stacks"))])
		_check(int(r0["dmg"]) == expect0,
			"traits_enabled=false 第 %d 次受击无等效防御加成（%d == %d）" % [k, int(r0["dmg"]), expect0])
	player.traits_enabled = true


# ---------------------------------------------------------------- 断言 11（D）
## 袋鼠怪 move_stacks：移动叠层 / 贴墙也算 / 攻速乘区走 attack_timer / 静止清零 / 封顶 / 开关。
func _t11_move_stacks() -> void:
	print("[PROBE] --- 11.（D）袋鼠怪 move_stacks（确定性驱动） ---")
	var stack_t := _cst("TRAIT_KANGA_STACK_TIME")
	var spd_step := _cst("TRAIT_KANGA_SPD_STEP")
	var aspd_step := _cst("TRAIT_KANGA_ASPD_STEP")
	var kmax := int(_cst("TRAIT_KANGA_MAX"))
	var stop_clear := _cst("TRAIT_KANGA_STOP_CLEAR")
	var dt := SKILL_DT

	_reset_to("kangaroo")
	player.traits_enabled = true
	_check(player.trait_id == "move_stacks", "kangaroo 的 trait_id == move_stacks")
	_check(int(player.get("_kanga_stacks")) == 0, "初始层数 0")

	# D1. 攻速乘区基线（0 层）：attack_timer == attack_interval，且真的开火了
	player.attack_enabled = true
	player.attack_timer = 0.0
	_place_fodder(player.global_position + Vector2(100.0, 0.0), 1)
	var f0 := fired_count
	player._physics_process(dt)
	_check(fired_count - f0 == 1, "0 层基线：本帧确实开火 1 次（实际 %d）" % (fired_count - f0))
	_check(is_equal_approx(player.attack_timer, player.attack_interval),
		"0 层 attack_timer == attack_interval（乘区 1.0，实际 %.4f vs %.4f）" % [
			player.attack_timer, player.attack_interval])
	player.attack_enabled = false

	# D2. 移动叠层（以 _movement_dir() 非零判定）+ 贴墙也算（设计文档 §5.1，刻意选择）
	var wall_x := GameStats.ARENA_W - GameStats.PLAYER_RADIUS
	player.global_position = Vector2(wall_x, 700.0)
	player.set_touch_dir(Vector2.RIGHT)
	_step_seconds(stack_t + 2.0 * dt)
	_check(int(player.get("_kanga_stacks")) == 1,
		"持续移动 %.2fs 后叠 1 层（实际 %d）" % [stack_t, int(player.get("_kanga_stacks"))])
	_check(is_equal_approx(float(player.call("kanga_speed_mul")), 1.0 + spd_step),
		"1 层 kanga_speed_mul == %.3f（实际 %.3f）" % [1.0 + spd_step, float(player.call("kanga_speed_mul"))])
	_check(is_equal_approx(float(player.call("kanga_aspd_mul")), 1.0 + aspd_step),
		"1 层 kanga_aspd_mul == %.3f（实际 %.3f）" % [1.0 + aspd_step, float(player.call("kanga_aspd_mul"))])
	_step_seconds(stack_t)
	_check(int(player.get("_kanga_stacks")) == 2,
		"累计 %.2fs 后 2 层（实际 %d）" % [stack_t * 2.0, int(player.get("_kanga_stacks"))])
	_check(player.global_position.x <= wall_x + 1.0,
		"整段移动贴在竞技场墙沿（x=%.1f ≤ %.1f）—— 输入持续、位移被墙挡（贴墙也算的证据）" % [
			player.global_position.x, wall_x])

	# D3. 攻速乘区作用在 attack_timer 上（recalc 的 aspd 字段必须不被改写 —— 幂等红线）
	var mul2 := float(player.call("kanga_aspd_mul"))
	player.attack_enabled = true
	player.attack_timer = 0.0
	# 现摆一只【活】木桩在射程内。不能复用 enemies[0]：第 7 组穿透用例的旧木桩
	# 有的已被弹道打死（get_nearest_enemy 跳过 is_dead，挪尸体=最近活敌仍在射程外）。
	_place_fodder(player.global_position + Vector2(100.0, 0.0), 1)
	var nearest_dbg: Node2D = battle.get_nearest_enemy(player.global_position)
	var ndist_dbg := -1.0
	if nearest_dbg != null:
		ndist_dbg = player.global_position.distance_to(nearest_dbg.global_position)
	print("[PROBE]   [DIAG] is_fighting=%s attack_range=%.1f nearest_dist=%.1f（须 <= 射程才开火）" % [
		str(battle.is_fighting()), player.attack_range, ndist_dbg])
	var f1 := fired_count
	player._physics_process(dt)
	_check(fired_count - f1 == 1, "2 层时本帧确实开火 1 次（实际 %d）" % (fired_count - f1))
	_check(is_equal_approx(player.attack_timer, player.attack_interval / mul2),
		"attack_timer == attack_interval / kanga_aspd_mul()（%.4f vs %.4f）" % [
			player.attack_timer, player.attack_interval / mul2])
	_check(player.attack_timer < player.attack_interval - 1e-6,
		"2 层攻速乘区确实缩短了攻击间隔（%.4f < %.4f）" % [player.attack_timer, player.attack_interval])
	player.attack_enabled = false
	player.set_touch_dir(Vector2.ZERO)

	# D4. 幂等红线：recalc 前后 _bonus / aspd 不变，且运行时层数不被 recalc 吞掉
	var bonus_before := {}
	for k in player._bonus.keys():
		bonus_before[k] = player._bonus[k]
	var aspd_before: float = player.aspd
	player.recalc_stats()
	var same := true
	for k in bonus_before.keys():
		if not is_equal_approx(float(bonus_before[k]), float(player._bonus[k])):
			same = false
	_check(same, "recalc 前后 _bonus 逐键不变（运行时层数绝不写进 _bonus）")
	_check(is_equal_approx(player.aspd, aspd_before), "recalc 前后 aspd 字段不变（未被层数改写）")
	_check(is_equal_approx(float(player.call("kanga_speed_mul")), 1.0 + 2.0 * spd_step)
		and is_equal_approx(float(player.call("kanga_aspd_mul")), 1.0 + 2.0 * aspd_step),
		"recalc 不吞运行时层数（双乘区仍为 2 层值）")

	# D5. 静止满 STOP_CLEAR 清零
	_step_seconds(stop_clear + 2.0 * dt)
	_check(int(player.get("_kanga_stacks")) == 0,
		"静止 %.2fs 后清零（实际 %d）" % [stop_clear, int(player.get("_kanga_stacks"))])
	_check(is_equal_approx(float(player.call("kanga_speed_mul")), 1.0)
		and is_equal_approx(float(player.call("kanga_aspd_mul")), 1.0), "清零后双乘区回到 1.0")

	# D6. 封顶 TRAIT_KANGA_MAX
	player.set_touch_dir(Vector2.RIGHT)
	_step_seconds(float(kmax + 1) * stack_t + 2.0 * dt)
	_check(int(player.get("_kanga_stacks")) == kmax,
		"持续移动 %.2fs 封顶 %d 层（实际 %d）" % [float(kmax + 1) * stack_t, kmax, int(player.get("_kanga_stacks"))])
	_check(is_equal_approx(float(player.call("kanga_speed_mul")), 1.0 + spd_step * float(kmax)),
		"满层 kanga_speed_mul == %.3f（实际 %.3f）" % [1.0 + spd_step * float(kmax), float(player.call("kanga_speed_mul"))])
	_check(is_equal_approx(float(player.call("kanga_aspd_mul")), 1.0 + aspd_step * float(kmax)),
		"满层 kanga_aspd_mul == %.3f（实际 %.3f）" % [1.0 + aspd_step * float(kmax), float(player.call("kanga_aspd_mul"))])
	player.set_touch_dir(Vector2.ZERO)

	# D7. traits_enabled=false（--selftest-defeat 语义）恒 1.0
	_reset_to("kangaroo")
	player.traits_enabled = false
	player.set_touch_dir(Vector2.RIGHT)
	_step_seconds(stack_t * 2.0 + 2.0 * dt)
	_check(int(player.get("_kanga_stacks")) == 0,
		"traits_enabled=false 不叠层（实际 %d）" % int(player.get("_kanga_stacks")))
	_check(is_equal_approx(float(player.call("kanga_speed_mul")), 1.0)
		and is_equal_approx(float(player.call("kanga_aspd_mul")), 1.0),
		"traits_enabled=false 双乘区恒 1.0")
	player.set_touch_dir(Vector2.ZERO)
	player.traits_enabled = true


# ---------------------------------------------------------------- 断言 12（E）
## DPS 预算回归护栏：dmg_mul×base_shots×rate_mul 与设计文档 §4 六人表逐人一致。
func _t12_dps_budget() -> void:
	print("[PROBE] --- 12.（E）DPS 预算回归护栏 ---")
	# ⚠️ 下表【写死自设计文档 §4】（docs/角色设计_土豆与袋鼠怪_2026-09-19.md）：
	#     改这里任何一个三元组 = 改了主线平衡，必须先过设计线评审再动。
	#     格式：[base_shots, dmg_mul, rate_mul]
	var budget := {
		"basic": [1, 1.0, 1.0],      # DPS 1.00 —— 无短板基准线
		"study": [2, 0.55, 1.35],    # DPS 1.485（文档记 1.49，前期弱后期滚雪球）
		"finance": [1, 0.9, 0.8],    # DPS 0.72 —— 经济补偿
		"sad": [1, 1.8, 0.6],        # DPS 1.08（低血满档 1.51 走 damage_bonus，不在本表）
		"potato": [1, 1.4, 0.65],    # DPS 0.91 —— 全队最低档，坦度补差价
		"kangaroo": [1, 0.7, 1.5],   # DPS 1.05 —— 满层天赋 ×1.15 ≈ 1.21（操作收益）
	}
	for cid in budget.keys():
		var id := String(cid)
		var w: Dictionary = GameStats.weapon_for_char(id)
		var want: Array = budget[cid]
		_check(int(w.get("base_shots", -1)) == int(want[0])
			and is_equal_approx(float(w.get("dmg_mul", -1.0)), float(want[1]))
			and is_equal_approx(float(w.get("rate_mul", -1.0)), float(want[2])),
			"%s 武器三元组 == 文档 §4（shots/dmg/rate = %s，实际 %s）" % [id, str(want),
				str([int(w.get("base_shots", -1)), float(w.get("dmg_mul", -1.0)), float(w.get("rate_mul", -1.0))])])
		var dps := float(w.get("dmg_mul", 0.0)) * float(w.get("base_shots", 0)) * float(w.get("rate_mul", 0.0))
		var want_dps := float(want[1]) * float(want[0]) * float(want[2])
		_check(absf(dps - want_dps) <= 1e-6, "%s DPS 预算 %.4f == 文档 %.4f" % [id, dps, want_dps])


# ---------------------------------------------------------------- 断言 13（F）
## 端到端说明：真 20 波开局由门禁覆盖，不在此重复（太慢）。
func _t13_endtoend_note() -> void:
	print("[PROBE] --- 13.（F）端到端说明 ---")
	print("[PROBE]   F 组不在此重复跑 20 波：`--selftest --char potato` / `--char kangaroo`")
	print("[PROBE]   完整开局与 Boss 遭遇由门禁 [2][3] 的同款命令覆盖。")


# ---------------------------------------------------------------- 工具
## 从反射常量表取浮点常量（守卫已确保存在）。
func _cst(name: String) -> float:
	return float(_consts.get(name, 0.0))


## 确定性驱动：手动步进 player._physics_process 共 sec 秒（不靠真实帧等待）。
func _step_seconds(sec: float) -> void:
	var n := maxi(1, int(round(sec / SKILL_DT)))
	for i in n:
		player._physics_process(SKILL_DT)


func _on_player_fired(_aim: Vector2, _count: int) -> void:
	fired_count += 1


## 判断对象是否拥有某属性（运行期反射，避开解析期硬错误）。
func _has_prop(obj: Object, pname: String) -> bool:
	for p in obj.get_property_list():
		if String(p["name"]) == pname:
			return true
	return false


func _reset_to(id: String) -> void:
	GameSession.begin_run(id)
	player.reset(Vector2(1000.0, 700.0))
	player.set_physics_process(false)
	# ⚠️ 两个必须归零的短路项，否则致死断言会 flaky / 恒假：
	#   god_mode → take_hit 第一行就 return "iframe"，永远打不到死亡分支；
	#   dodge    → 学习豪自带 5%，有 1/20 概率命中闪避分支返回 "dodge"。
	player.god_mode = false
	player.dodge = 0.0


## 在 pos 周围摆 n 只高血量木桩（target=null → 不会移动）。
func _place_fodder(pos: Vector2, n: int) -> void:
	var packed: PackedScene = load("res://scenes/entities/Enemy.tscn")
	for i in n:
		var e: Enemy = packed.instantiate()
		battle.world.add_child(e)
		# 稍微错开位置，避免完全重叠带来的语义歧义（半径 12，仍落在同一 3x3 网格内）
		e.setup("Slime", 1, pos + Vector2(float(i) * 2.0, 0.0))
		e.target = null
		e.speed = 0.0
		battle.enemies.append(e)


func _make_proj(pos: Vector2, pierce_cap: int) -> Projectile:
	var packed: PackedScene = load("res://scenes/entities/Projectile.tscn")
	var p: Projectile = packed.instantiate()
	battle.world.add_child(p)
	# setup(pos, dir, dmg, crit, critd, lifesteal, speed_mul, radius, pierce_cap, gold_on_hit)
	p.setup(pos, 0.0, 10, 0.0, 1.5, 0.0, 1.0, GameStats.PROJ_RADIUS, pierce_cap, 0.0)
	battle.projectiles.append(p)
	return p


func _still_listed(p: Projectile) -> bool:
	for x in battle.projectiles:
		if x == p:
			return true
	return false


## 统计本关木桩的受伤数量（hp < max_hp）。
func _hurt_count() -> int:
	var c := 0
	for e in battle.enemies:
		if e.hp < e.max_hp:
			c += 1
	return c


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
		_arm()
		_finish("")
		return true
	return true


func _finish(early_msg: String) -> void:
	if finished:
		return
	finished = true
	print("[PROBE] --------------------------------------------------")
	if early_msg != "":
		print("[PROBE] 提前终止：%s" % early_msg)
		print("[PROBE] RESULT=FAIL")
		quit(1)
		return
	print("[PROBE] 断言 %d 项，失败 %d 项" % [checks, fails.size()])
	for f in fails:
		print("[PROBE]   - %s" % f)
	print("[PROBE] RESULT=%s" % ("PASS" if fails.is_empty() else "FAIL"))
	quit(0 if fails.is_empty() else 1)
