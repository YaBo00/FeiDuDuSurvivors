extends SceneTree
## 独立验证探针：meta 2.0 解锁网络（2026-10-09 第二梯队第六批）。
##
## 覆盖两个解锁项：
##   · unlock_active_2（双持主动）—— apply_item 选槽 / 冷却独立 / 槽 2 发动 / HUD 双槽 / reset
##   · unlock_extra_3（第三副武器槽）—— extra_weapon_cap() +1（override 优先）
##
## 回答五个验收问题：
##   ① 数据面契约：META_UNLOCKS 表（2 条 / id 唯一 / 名字与描述非空 / cost > 0）
##   ② MetaSave 层：购买原子性（扣点 / 点数不足拒绝 / 重复购买拒绝 / 未知 id 拒绝）+
##      持久化 + 脏档护栏（未知 id 读时过滤）
##   ③ GameSession 快照：has_unlock 读写 + Battle._ready 的探针守卫（干净世界）
##   ④ 双槽战斗行为：未解锁 = 旧行为（买新的替换槽 1）；解锁后 槽 1 → 槽 2 → FIFO 替换槽 1；
##      冷却独立；槽 2 发动核弹端到端；HUD 双槽渲染；reset 清双槽
##   ⑤ 纪律：未解锁快照 = 旧行为逐位（cap 2 / 双槽不可用）+ 零随机消耗
##
## 被验证的契约：
##   MetaSave.META_UNLOCKS / UNLOCKS_META_KEY / find_unlock / is_meta_unlocked /
##     purchase_unlock / active_unlock_map / _safe_unlocks
##   GameSession.meta_unlocks / has_unlock
##   GameStats.extra_weapon_cap（+unlock_extra_3 / override 优先）
##   Player.active_id_2 / active_cd_t_2 / equip_active(slot) / active_ready(slot) /
##     active_cd_ratio(slot) / active_start_cooldown(slot) / apply_item 选槽
##   Battle._try_use_active(slot) / Battle._ready 快照守卫
##   Hud._a_slots / set_active_state（双槽）
##
## 隔离：探针把 MetaSave.save_path 重定向到 user://probe_meta_unlocks.json，
## 结束删除，不碰真实存档 user://meta_save.json。
##
## 确定性：全部同步调用，不依赖真实帧；解锁读取零随机消耗（seed 对照）。
##
## 用法: godot --headless --path <项目>/game --script res://scripts/dev/_ProbeMetaUnlocks.gd
## 退出码 0=PASS 1=FAIL（门禁用 grep -q "RESULT=PASS" 判定）

const PROBE_PATH := "user://probe_meta_unlocks.json"

var battle: Node = null
var armed := false
var finished := false
var checks := 0
var fails: Array[String] = []


func _initialize() -> void:
	print("[PROBE] === meta 2.0 解锁网络（双持主动 / 第三副武器槽）验证 ===")
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
	_sec_b_metasave()
	_sec_c_session_snapshot()
	_sec_d_dual_slots()
	_sec_e_cap()
	_sec_f_discipline()
	# 收尾：清探针档 + 恢复运行时静态状态（不影响其他探针 —— 反正是独立进程）
	GameSession.meta_unlocks = {}
	GameStats.extra_weapon_cap_override = -1
	if FileAccess.file_exists(PROBE_PATH):
		DirAccess.remove_absolute(PROBE_PATH)


# ================================================================ A. 数据面契约
func _sec_a_contracts() -> void:
	_section("A. 数据面契约（解锁表 / 常量）")
	_check(MetaSave.META_UNLOCKS.size() == 4, "解锁表 4 条（实际 %d）" % MetaSave.META_UNLOCKS.size())
	var ids := {}
	var ok := true
	for u in MetaSave.META_UNLOCKS:
		var uid := String(u.get("id", ""))
		ids[uid] = true
		if uid == "" or String(u.get("name", "")) == "" or String(u.get("desc", "")) == "" \
				or int(u.get("cost", 0)) <= 0:
			ok = false
	_check(ids.size() == 4, "id 唯一（4 个）")
	_check(ok, "名字/描述非空 + cost > 0")
	_check(ids.has("unlock_active_2") and ids.has("unlock_extra_3")
		and ids.has("unlock_weapon_free") and ids.has("unlock_daily"),
		"四条 id 齐备：unlock_active_2 / unlock_extra_3 / unlock_weapon_free / unlock_daily")
	_check(MetaSave.find_unlock("unlock_active_2") != null
		and MetaSave.find_unlock("not_a_unlock") == null, "find_unlock 命中 / 未知 id 返回 null")


# ================================================================ B. MetaSave 层（购买 / 护栏）
func _sec_b_metasave() -> void:
	_section("B. MetaSave 层（购买 / 扣点 / 幂等 / 脏档护栏）")
	_check(not MetaSave.is_meta_unlocked("unlock_active_2"), "默认：双持主动未解锁")
	_check(not MetaSave.is_meta_unlocked("unlock_extra_3"), "默认：第三副武器槽未解锁")
	_check(MetaSave.active_unlock_map().is_empty(), "默认：快照为空")
	# 点数不足 → 拒绝
	var d := MetaSave.ledger()
	d["meta_xp"] = 100
	MetaSave._save(d)
	_check(not MetaSave.purchase_unlock("unlock_active_2"), "100 点 < 400：购买被拒")
	_check(int(MetaSave.ledger()["meta_xp"]) == 100, "拒绝后点数不变（100）")
	# 点数够 → 成功扣点
	d = MetaSave.ledger()
	d["meta_xp"] = 1000
	MetaSave._save(d)
	_check(MetaSave.purchase_unlock("unlock_active_2"), "1000 点：购买双持成功")
	d = MetaSave.ledger()
	_check(int(d["meta_xp"]) == 600, "扣 400 后剩 600（实际 %d）" % int(d["meta_xp"]))
	_check(MetaSave.is_meta_unlocked("unlock_active_2"), "已解锁：is_meta_unlocked 真")
	# 重复购买 / 未知 id
	_check(not MetaSave.purchase_unlock("unlock_active_2"), "重复购买拒绝（不二次扣费）")
	_check(int(MetaSave.ledger()["meta_xp"]) == 600, "重复购买后点数仍 600")
	_check(not MetaSave.purchase_unlock("not_a_unlock"), "未知 id 购买拒绝")
	_check(not MetaSave.is_meta_unlocked("not_a_unlock"), "未知 id 恒 false")
	# 快照
	var m := MetaSave.active_unlock_map()
	_check(m.size() == 1 and bool(m.get("unlock_active_2", false)), "快照含 1 条已解锁项")
	# 第二项
	_check(MetaSave.purchase_unlock("unlock_extra_3"), "600 点：购买第三槽（350）成功")
	_check(int(MetaSave.ledger()["meta_xp"]) == 250, "再扣 350 后剩 250")
	# 脏档护栏：未知 id 读时过滤
	var f := FileAccess.open(PROBE_PATH, FileAccess.WRITE)
	f.store_string('{"schema_version": 2, "meta_unlocks": ["unlock_active_2", "hacked_id"]}')
	f = null
	var arr: Array = MetaSave.ledger()["meta_unlocks"]
	_check(arr.has("unlock_active_2") and not arr.has("hacked_id") and arr.size() == 1,
		"脏档护栏：未知 id 被过滤（剩 %d 条）" % arr.size())


# ================================================================ C. GameSession 快照
func _sec_c_session_snapshot() -> void:
	_section("C. GameSession 快照（探针守卫 / has_unlock 读写）")
	_check(GameSession.meta_unlocks.is_empty(),
		"Battle._ready 探针守卫：快照被清空（干净世界 = 不受玩家真实档影响）")
	_check(not GameSession.has_unlock("unlock_active_2"), "空快照：has_unlock 假")
	GameSession.meta_unlocks = {"unlock_active_2": true}
	_check(GameSession.has_unlock("unlock_active_2"), "设快照后 has_unlock 真")
	_check(not GameSession.has_unlock("unlock_extra_3"), "未设的键仍假")
	GameSession.meta_unlocks = {}


# ================================================================ D. 双槽行为
func _sec_d_dual_slots() -> void:
	_section("D. 双槽行为（选槽 / 冷却独立 / 发动 / HUD / reset）")
	battle.start_run()
	battle.set_physics_process(false)
	battle.player.set_physics_process(false)
	var pl: Player = battle.player

	# ---- 未解锁：旧行为（全部进槽 1，买新的替换）----
	GameSession.meta_unlocks = {}
	pl.apply_item("active_nuke")
	_check(pl.active_id == "active_nuke" and pl.active_id_2 == "", "未解锁：第 1 件进槽 1")
	pl.apply_item("active_time_stop")
	_check(pl.active_id == "active_time_stop" and pl.active_id_2 == "",
		"未解锁：第 2 件替换槽 1（旧行为逐位）")

	# ---- 解锁：槽 1 空 → 槽 1；槽 1 有 + 槽 2 空 → 槽 2；两槽满 → 替换槽 1（FIFO）----
	GameSession.meta_unlocks = {"unlock_active_2": true}
	pl.active_id = ""
	pl.active_cd_t = 0.0
	pl.active_id_2 = ""
	pl.active_cd_t_2 = 0.0
	pl.apply_item("active_nuke")
	_check(pl.active_id == "active_nuke" and pl.active_id_2 == "", "解锁：槽 1 空 → 第 1 件仍进槽 1")
	pl.apply_item("active_time_stop")
	_check(pl.active_id == "active_nuke" and pl.active_id_2 == "active_time_stop",
		"解锁：第 2 件进槽 2（槽 1 不动）")
	pl.apply_item("active_speed_boots")
	_check(pl.active_id == "active_speed_boots" and pl.active_id_2 == "active_time_stop",
		"两槽满：买第 3 件替换槽 1（FIFO）")

	# ---- 冷却独立 ----
	pl.active_cd_t = 0.0
	pl.active_cd_t_2 = 0.0
	pl.active_start_cooldown(1)
	_check(pl.active_cd_t > 0.0 and pl.active_cd_t_2 == 0.0, "槽 1 进冷却：槽 2 不受影响")
	var want1 := GameStats.active_cooldown("active_speed_boots") * (1.0 - pl.cdr)
	_check(absf(pl.active_cd_t - want1) <= 1e-4, "槽 1 冷却 == base × (1-cdr)（%.2f）" % pl.active_cd_t)
	pl.active_cd_t = 0.0
	pl.active_start_cooldown(2)
	_check(pl.active_cd_t_2 > 0.0 and pl.active_cd_t == 0.0, "槽 2 进冷却：槽 1 不受影响")
	_check(not pl.active_ready(2), "槽 2 冷却中：ready(2) 假")
	_check(absf(pl.active_cd_ratio(2) - 1.0) <= 1e-3, "槽 2 冷却比例 ≈ 1.0（刚发动）")
	pl.active_cd_t_2 = 0.0
	_check(pl.active_ready(1) and pl.active_ready(2), "双槽归零：均就绪")

	# ---- 槽 2 发动核弹（端到端）----
	pl.active_id_2 = "active_nuke"
	pl.active_cd_t_2 = 0.0
	battle.wave_num = 5
	battle.wave.spawn_enemy("Ox", Vector2(pl.global_position.x + 120.0, pl.global_position.y), 1.0, false)
	var e = _last_enemy("Ox")
	_check(e != null and not bool(e.is_dead), "前置：小怪活着")
	var cd1_before: float = pl.active_cd_t
	battle.call("_try_use_active", 2)
	_check(e != null and bool(e.is_dead), "槽 2 发动核弹：小怪被清")
	_check(pl.active_cd_t_2 > 0.0, "发动后槽 2 进入冷却（%.1fs）" % pl.active_cd_t_2)
	_check(absf(pl.active_cd_t - cd1_before) <= 1e-6, "槽 1 冷却不受槽 2 发动影响")

	# ---- HUD 双槽渲染 ----
	var hud: Hud = battle.hud
	hud.set_active_state(pl)
	var s1: Dictionary = hud._a_slots[0]
	var s2: Dictionary = hud._a_slots[1]
	_check((s1["root"] as Control).visible, "HUD 槽 1 显示（已装备）")
	_check((s2["root"] as Control).visible, "HUD 槽 2 显示（已装备）")
	_check((s2["icon"] as TextureRect).texture != null, "槽 2 图标取库（active_nuke.png）")
	pl.active_id_2 = ""
	hud.set_active_state(pl)
	_check(not (s2["root"] as Control).visible, "槽 2 空 → 整块隐藏")
	_check((s1["root"] as Control).visible, "槽 1 不受槽 2 隐藏影响")

	# ---- reset 清双槽 ----
	pl.active_id = "active_nuke"
	pl.active_id_2 = "active_time_stop"
	pl.reset(Vector2.ZERO)
	_check(pl.active_id == "" and pl.active_id_2 == "" and pl.active_cd_t == 0.0 and pl.active_cd_t_2 == 0.0,
		"reset：双槽与冷却全部清零")


# ================================================================ E. 副武器上限
func _sec_e_cap() -> void:
	_section("E. 副武器上限（第三槽解锁 / override 优先）")
	GameSession.meta_unlocks = {}
	_check(GameStats.extra_weapon_cap() == 2, "未解锁：cap == 2（旧行为）")
	GameSession.meta_unlocks = {"unlock_extra_3": true}
	_check(GameStats.extra_weapon_cap() == 3, "解锁：cap == 3")
	GameStats.extra_weapon_cap_override = 5
	_check(GameStats.extra_weapon_cap() == 5, "金手指 override=5 优先（返回 5）")
	GameStats.extra_weapon_cap_override = 2
	_check(GameStats.extra_weapon_cap() == 2, "override=2 优先（返回 2，覆盖解锁加成）")
	GameStats.extra_weapon_cap_override = -1
	_check(GameStats.extra_weapon_cap() == 3, "恢复默认：解锁态 cap == 3")
	GameSession.meta_unlocks = {}


# ================================================================ F. 纪律
func _sec_f_discipline() -> void:
	_section("F. 纪律（未解锁 = 旧行为 / 零随机）")
	GameSession.meta_unlocks = {}
	_check(not GameSession.has_unlock("unlock_active_2") and GameStats.extra_weapon_cap() == 2,
		"空快照 = 旧行为（双槽不可用 / cap 2）")
	seed(31)
	var r1 := randf()
	seed(31)
	var _u = MetaSave.is_meta_unlocked("unlock_active_2")
	var _m = MetaSave.active_unlock_map()
	var _c = GameStats.extra_weapon_cap()
	var _h = GameSession.has_unlock("unlock_active_2")
	var r2 := randf()
	_check(absf(r1 - r2) <= 1e-9, "解锁读取零随机消耗（randf 序列一致）")


# ================================================================ 工具
func _last_enemy(t: String) -> Node2D:
	for i in range(battle.enemies.size() - 1, -1, -1):
		var e = battle.enemies[i]
		if is_instance_valid(e) and String(e.type_name) == t:
			return e
	return null


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
