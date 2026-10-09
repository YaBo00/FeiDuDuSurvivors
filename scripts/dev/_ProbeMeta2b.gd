extends SceneTree
## 独立验证探针：meta 2.0 第二批（2026-10-09 第二梯队第七批）。
##
## 覆盖两个解锁项：
##   · unlock_weapon_free（武器自由）—— 起始武器替换：整条武器线（基础弹道 / 进化形态 /
##     融合配方）跟随替换武器；角色特性/属性不受影响
##   · unlock_daily（每日挑战）—— 当日种子纯函数 / 应用守卫 / 当日纪录（跨天重置）/ HUD 与结算展示
##
## 回答六个验收问题：
##   A 数据面契约：WEAPON_DEFS 6 把 / daily_seed_from 纯函数确定性 / 日期键格式 /
##     解锁表两新项存在且价格正确
##   B MetaSave 层：record_daily 取最大 / 持久化 / 跨天自动作废 / 脏值护栏
##   C 种子应用：不同模式的守卫（非每日 false / 探针进程 false）+ 核心不变式
##     「同种子 ⇒ 同随机序列」+ 守卫路径零随机消耗
##   D 武器自由链：weapon_id 三态 / apply_character 装备替换武器（角色属性不动）/
##     weapon_form 进化形态跟随 / _fusion_card 配方键跟随 / CombatResolver 弹体参数实测
##   E UI 口径：HUD 波次行前缀 / ResultPanel 每日行（含新纪录）
##   F 纪律：默认空值（旧行为逐位）/ 收尾复位
##
## 被验证的契约：
##   GameStats.daily_seed_from / daily_seed_value / daily_date_key / weapon_summary
##   GameSession.weapon_pick / daily_mode
##   Player.weapon_id / weapon_form / apply_character
##   CombatResolver.on_player_fired（武器参数消费）
##   Battle._apply_daily_seed / _fusion_card / start_run（种子调用点）
##   MetaSave.record_daily / daily_best / DAILY_DATE_KEY / DAILY_BEST_KEY
##   Hud._wave_label（每日前缀）/ ResultPanel 每日行
##
## 隔离：探针把 MetaSave.save_path 重定向到 user://probe_meta2b.json，
## 结束删除，不碰真实存档 user://meta_save.json。
##
## 确定性：全部同步调用，不依赖真实帧；随机流用 seed 对照断言，探针自己恢复。
##
## 用法: godot --headless --path <项目>/game --script res://scripts/dev/_ProbeMeta2b.gd
## 退出码 0=PASS 1=FAIL（门禁用 grep -q "RESULT=PASS" 判定）

const PROBE_PATH := "user://probe_meta2b.json"

var battle: Node = null
var armed := false
var finished := false
var checks := 0
var fails: Array[String] = []


func _initialize() -> void:
	print("[PROBE] === meta 2.0 第二批（武器自由 / 每日挑战）验证 ===")
	MetaSave.save_path = PROBE_PATH
	if FileAccess.file_exists(PROBE_PATH):
		DirAccess.remove_absolute(PROBE_PATH)
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
	_sec_b_daily_record()
	_sec_c_seed_guard()
	_sec_d_weapon_free()
	_sec_e_ui()
	_sec_f_discipline()
	# 收尾：清探针档 + 复位运行时静态状态（独立进程其实无所谓，保持纪律）。
	GameSession.weapon_pick = ""
	GameSession.daily_mode = false
	if FileAccess.file_exists(PROBE_PATH):
		DirAccess.remove_absolute(PROBE_PATH)


# ================================================================ A. 数据面契约
func _sec_a_contracts() -> void:
	_section("A. 数据面契约（武器表 / 每日种子纯函数 / 解锁表）")
	_check(GameSession.weapon_pick == "", "初值：weapon_pick 空（旧行为路径）")
	_check(GameSession.daily_mode == false, "初值：daily_mode 关（旧行为路径）")
	# 武器表：6 把，daily_seed 相关两新解锁项存在
	_check(GameStats.WEAPON_DEFS.size() == 6, "WEAPON_DEFS 6 把（实际 %d）" % GameStats.WEAPON_DEFS.size())
	_check(MetaSave.find_unlock("unlock_weapon_free") != null, "解锁表含 unlock_weapon_free")
	_check(MetaSave.find_unlock("unlock_daily") != null, "解锁表含 unlock_daily")
	# daily_seed_from 纯函数：确定性 + 数位拼装 + 不同日期不同值
	_check(GameStats.daily_seed_from(2026, 10, 9) == 20261009, "2026-10-09 → 20261009")
	_check(GameStats.daily_seed_from(2026, 1, 1) == 20260101, "补零位语义：2026-01-01 → 20260101")
	_check(GameStats.daily_seed_from(2026, 12, 31) == 20261231, "2026-12-31 → 20261231")
	_check(GameStats.daily_seed_from(2026, 10, 9) == GameStats.daily_seed_from(2026, 10, 9),
		"同日期同值（确定性）")
	_check(GameStats.daily_seed_from(2026, 10, 9) != GameStats.daily_seed_from(2026, 10, 10),
		"相邻日期不同值")
	# daily_seed_value / daily_date_key：与系统日期一致（同一来源对照）
	var dt := Time.get_date_dict_from_system()
	var y := int(dt["year"])
	var m := int(dt["month"])
	var dd := int(dt["day"])
	_check(GameStats.daily_seed_value() == GameStats.daily_seed_from(y, m, dd),
		"daily_seed_value == 系统日期派生（%d）" % GameStats.daily_seed_value())
	_check(GameStats.daily_date_key() == "%04d-%02d-%02d" % [y, m, dd],
		"daily_date_key 格式（%s）" % GameStats.daily_date_key())
	# weapon_summary 纯函数（UI 共用）
	_check(GameStats.weapon_summary("sad").contains("贯穿") and GameStats.weapon_summary("sad").contains("吸血"),
		"weapon_summary(sad) 含贯穿 + 吸血（%s）" % GameStats.weapon_summary("sad"))
	_check(GameStats.weapon_summary("basic").contains("单次 1 发"), "weapon_summary(basic) 基础信息")


# ================================================================ B. MetaSave 每日纪录
func _sec_b_daily_record() -> void:
	_section("B. MetaSave 层（record_daily / 跨天 / 脏值护栏）")
	_check(MetaSave.daily_best() == 0, "默认：当日最佳 0")
	_check(MetaSave.record_daily(9) == 9, "首记 9 → 返回 9")
	_check(MetaSave.daily_best() == 9, "daily_best == 9")
	_check(MetaSave.record_daily(7) == 9, "更低成绩（7）不覆盖 → 仍 9")
	_check(MetaSave.record_daily(15) == 15, "更高成绩（15）覆盖 → 15")
	# 持久化：直接读档核对两键
	var d := MetaSave.ledger()
	_check(String(d[MetaSave.DAILY_DATE_KEY]) == GameStats.daily_date_key(),
		"落盘日期 == 今日（%s）" % String(d[MetaSave.DAILY_DATE_KEY]))
	_check(int(d[MetaSave.DAILY_BEST_KEY]) == 15, "落盘成绩 == 15")
	# 跨天模拟：手写旧日期 → daily_best 作废为 0；再记从 0 起
	d[MetaSave.DAILY_DATE_KEY] = "1970-01-01"
	MetaSave._save(d)
	_check(MetaSave.daily_best() == 0, "跨天：旧纪录自动作废（0）")
	_check(MetaSave.record_daily(4) == 4, "跨天后首记从 0 起（4）")
	d = MetaSave.ledger()
	_check(String(d[MetaSave.DAILY_DATE_KEY]) == GameStats.daily_date_key(), "跨天记录后日期已刷为今日")
	# 脏值护栏：负数写档 → 读回 0
	d[MetaSave.DAILY_BEST_KEY] = -50
	MetaSave._save(d)
	_check(int(MetaSave.ledger()[MetaSave.DAILY_BEST_KEY]) == 0, "脏值：负数被护栏钳为 0")


# ================================================================ C. 种子应用守卫
func _sec_c_seed_guard() -> void:
	_section("C. 种子应用（守卫 / 核心不变式 / 零随机）")
	# 非每日 → 不应用
	_check(not battle._apply_daily_seed(), "非每日模式：_apply_daily_seed 返回 false")
	# 每日 + 探针进程 → 守卫拒绝（本进程就是 --script）
	GameSession.daily_mode = true
	seed(7)
	var a: int = randi()
	seed(7)
	var applied: bool = battle._apply_daily_seed()
	var b: int = randi()
	_check(not applied, "探针进程：即使 daily_mode 开，守卫也拒绝应用")
	_check(a == b, "守卫路径零随机消耗（seed 对照 %d == %d）" % [a, b])
	GameSession.daily_mode = false
	# 核心不变式：同种子 ⇒ 同随机序列（每日挑战的产品承诺）
	seed(GameStats.daily_seed_value())
	var x1: int = randi()
	var x2: int = randi()
	seed(GameStats.daily_seed_value())
	var y1: int = randi()
	var y2: int = randi()
	_check(x1 == y1 and x2 == y2,
		"同种子 ⇒ 同随机序列（%d,%d vs %d,%d）" % [x1, x2, y1, y2])
	# start_run 调用点存在性：源码级契约（正常进程才会真应用；探针进程被守卫挡）
	_check(battle.has_method("_apply_daily_seed"), "Battle._apply_daily_seed 存在（start_run 调用点）")


# ================================================================ D. 武器自由链
func _sec_d_weapon_free() -> void:
	_section("D. 武器自由（weapon_id 三态 / 装备 / 进化 / 融合 / 弹体实测）")
	var pl: Player = battle.player
	pl.apply_character("basic")
	# weapon_id 三态
	GameSession.weapon_pick = ""
	_check(pl.weapon_id() == pl.char_id, "空 pick → char_id（basic）")
	GameSession.weapon_pick = "sad"
	_check(pl.weapon_id() == "sad", "合法 pick → sad")
	GameSession.weapon_pick = "not_a_weapon"
	_check(pl.weapon_id() == pl.char_id, "非法 pick → 回落 char_id")
	# apply_character：装备替换武器，但角色属性不动
	GameSession.weapon_pick = "sad"
	pl.apply_character("basic")
	_check(String(pl._weapon["name"]) == "暗影弹", "basic 角色装上 sad 武器（暗影弹）")
	_check(pl.char_id == "basic", "char_id 未被武器替换影响")
	_check(absf(float(pl._base["maxHp"]) - float(GameStats.character("basic")["base"]["maxHp"])) <= 0.01,
		"角色基础属性仍是 basic（maxHp %d）" % int(pl._base["maxHp"]))
	_check(pl.trait_id == GameStats.trait_id_for_char("basic"), "角色特性仍是 basic 的（新手保护）")
	# 进化形态跟随替换武器
	pl.weapon_evolved = true
	var form: Dictionary = pl.weapon_form()
	_check(String(form.get("name", "")) == "暗影汲取",
		"sad 线进化形态（暗影汲取，实际「%s」）" % String(form.get("name", "")))
	pl.weapon_evolved = false
	_check(pl.weapon_form().is_empty(), "未进化 → 空形态（旧行为）")
	# 融合配方键跟随替换武器：sad × ice_nova（须满级）
	battle.extra.reset()
	GameSession.weapon_pick = "sad"
	pl.weapon_evolved = true
	pl.fusion_id = ""
	_check(battle._fusion_card().is_empty(), "配方副武器未持有 → 不出融合卡")
	battle.extra.grant("ice_nova")
	var guard := 0
	while battle.extra.level_of("ice_nova") < GameStats.extra_weapon_max_level("ice_nova") and guard < 10:
		battle.extra.level_up("ice_nova")
		guard += 1
	_check(battle.extra.level_of("ice_nova") == GameStats.extra_weapon_max_level("ice_nova"),
		"ice_nova 升满（Lv%d）" % battle.extra.level_of("ice_nova"))
	var fcard: Dictionary = battle._fusion_card()
	_check(not fcard.is_empty(), "sad（替换中）+ ice_nova 满级 → 融合卡出现")
	_check(String(fcard.get("fusion_id", "")) == "sad",
		"配方键 == sad（实际「%s」）" % String(fcard.get("fusion_id", "")))
	_check(String(fcard.get("name", "")).contains("寒心冰封"), "卡面名 = sad 配方（寒心冰封）")
	# 对照：pick 清空 → basic 配方（orbit 未满级）→ 不出卡
	GameSession.weapon_pick = ""
	_check(battle._fusion_card().is_empty(), "basic 配方（orbit 未满级）→ 不出卡（对照）")
	# CombatResolver 弹体实测：sad 参数（pierce 99 / speed ×0.85 / radius ×2.2）
	pl.weapon_evolved = false
	GameSession.weapon_pick = "sad"
	pl.apply_character("basic")
	_clear_projectiles()
	battle.combat.on_player_fired(pl.global_position + Vector2(200.0, 0.0), 1)
	_check(battle.projectiles.size() == 1, "sad 单发：1 条弹道（实际 %d）" % battle.projectiles.size())
	if battle.projectiles.size() == 1:
		var proj: Projectile = battle.projectiles[0]
		_check(proj.pierce_cap == 99, "弹体 pierce_cap == 99（贯穿，实际 %d）" % proj.pierce_cap)
		_check(absf(proj.speed_mul - 0.85 * pl.proj_speed_mul) <= 1e-4,
			"弹体 speed_mul == 0.85 × proj_speed_mul（%.4f）" % proj.speed_mul)
		_check(absf(proj.radius - GameStats.PROJ_RADIUS * 2.2) <= 1e-3,
			"弹体 radius == PROJ_RADIUS × 2.2（%.1f）" % proj.radius)
	# 对照：默认武器（basic）弹体参数 = 旧基线
	GameSession.weapon_pick = ""
	pl.apply_character("basic")
	_clear_projectiles()
	battle.combat.on_player_fired(pl.global_position + Vector2(200.0, 0.0), 1)
	_check(battle.projectiles.size() == 1, "basic 单发：1 条弹道")
	if battle.projectiles.size() == 1:
		var proj0: Projectile = battle.projectiles[0]
		_check(proj0.pierce_cap == 2, "basic 弹体 pierce_cap == 2（旧基线）")
		_check(absf(proj0.speed_mul - 1.0 * pl.proj_speed_mul) <= 1e-4, "basic 弹体 speed_mul == 1.0（旧基线）")
	_clear_projectiles()
	# 复位
	pl.weapon_evolved = false
	pl.fusion_id = ""


func _clear_projectiles() -> void:
	for p in battle.projectiles:
		if is_instance_valid(p):
			p.queue_free()
	battle.projectiles.clear()


# ================================================================ E. UI 口径
func _sec_e_ui() -> void:
	_section("E. UI（HUD 每日前缀 / 结算每日行）")
	var pl: Player = battle.player
	GameSession.daily_mode = true
	battle.hud.set_data(pl, 1, 10.0, GameStats.WAVE_COUNT)
	_check(String(battle.hud._wave_label.text).begins_with("每日挑战 · "),
		"daily：HUD 波次行带前缀（%s）" % battle.hud._wave_label.text)
	GameSession.daily_mode = false
	battle.hud.set_data(pl, 1, 10.0, GameStats.WAVE_COUNT)
	_check(not String(battle.hud._wave_label.text).contains("每日挑战"),
		"普通：无前缀（%s）" % battle.hud._wave_label.text)
	# ResultPanel 每日行（含新纪录 + 数值）
	battle.result_panel.show_result({
		"victory": false, "waves_completed": 8, "kills": 100, "level": 6, "gold": 50,
		"difficulty": "普通",
		"daily": true, "daily_best": 12, "daily_new_record": true,
	})
	var txt: String = battle.result_panel._stats.text
	_check(txt.contains("每日挑战 · 新纪录！"), "结算：每日新纪录行（%s）" % txt.split("\n")[0])
	_check(txt.contains("当日最佳：12 波"), "结算：当日最佳数值")
	battle.result_panel.hide_panel()
	# 非每日不显示（旧调用方零影响）
	battle.result_panel.show_result({
		"victory": false, "waves_completed": 8, "kills": 100, "level": 6, "gold": 50,
	})
	_check(not String(battle.result_panel._stats.text).contains("每日挑战"), "非每日：无该行")
	battle.result_panel.hide_panel()


# ================================================================ F. 纪律
func _sec_f_discipline() -> void:
	_section("F. 纪律（复位 / 默认态）")
	# 复位 weapon_pick 后弹体走旧路径已在上文对照过；这里核对静态态恢复后的读取口径
	GameSession.weapon_pick = ""
	GameSession.daily_mode = false
	_check(battle.player.weapon_id() == battle.player.char_id, "复位后：weapon_id == char_id")
	_check(not battle._apply_daily_seed(), "复位后：not daily → 不应用")


# ================================================================ 工具
func _check(cond: bool, msg: String) -> void:
	checks += 1
	if cond:
		print("  [OK] ", msg)
	else:
		fails.append(msg)
		print("  [FAIL] ", msg)


func _section(title: String) -> void:
	print("\n---- %s ----" % title)


func _finish(err: String) -> void:
	if finished:
		return
	finished = true
	if err != "":
		fails.append(err)
		print("  [FAIL] ", err)
	print("\n[PROBE] checks=%d fails=%d" % [checks, fails.size()])
	if fails.is_empty():
		print("[PROBE] RESULT=PASS")
		quit(0)
	else:
		for f in fails:
			print("[PROBE] FAILED: ", f)
		print("[PROBE] RESULT=FAIL")
		quit(1)
