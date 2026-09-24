extends SceneTree
## 独立验证探针：敌人图鉴（2026-09-22，需求见《敌人图鉴_给代码AI_2026-09-22.md》）。
##
## 被验证的契约：
##   GameStats.CODEX_ORDER —— 13 条、无重复、全在 ENEMY_TEMPLATES / AssetDB.ENEMIES 里
##   GameStats.codex_name / codex_desc / is_codex_enemy —— 文案与「进不进图鉴」判定
##   出场路径可达性：每个图鉴 id 都能在真实玩法里刷出来（波池 / 精英 / Boss），
##     不然图鉴就是个永远填不满的格子
##   MetaSave 图鉴账本（SEEN_KEY / KILLS_KEY）：record_kills 单入口累加 + 去重 + 解锁
##   MetaSave 护栏：坏档（非数组/非字典）、脏项（非法 id / 重复 / 计数 ≤0 / 非数字）一律安全丢弃
##   MetaSave.codex_state —— 与 CODEX_ORDER 同序的批量读
##   Battle 端到端：cleanup_enemies 逐只累加 enemy_kills（自爆炸弹不计），start_run 清零
##
## 隔离：探针把 save_path 重定向到 user://meta_save_codex_probe.json，结束删除，
## 不碰真实存档 user://meta_save.json。
##
## 用法: godot --headless --path <项目> --script res://scripts/dev/_ProbeCodex.gd
## 退出码 0=PASS 1=FAIL（门禁用退出码判定，勿解析 stdout 尾行）

const PROBE_PATH := "user://meta_save_codex_probe.json"

var battle: Node = null
var armed := false
var finished := false
var checks := 0
var fails: Array[String] = []


func _initialize() -> void:
	print("[PROBE] === 敌人图鉴验证（2026-09-22）===")
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
	_t_table()
	_t_ledger()
	_t_guardrails()
	_t_battle_end_to_end()
	if FileAccess.file_exists(PROBE_PATH):
		DirAccess.remove_absolute(PROBE_PATH)


# ---------------------------------------------------------------- A. 静态表契约
func _t_table() -> void:
	var n := GameStats.CODEX_ORDER.size()
	_check(n == 13, "CODEX_ORDER 13 条（实际 %d）" % n)

	# 无重复（重复会让图鉴出现两个同名格子，且 codex_state 的键会互相覆盖）
	var uniq: Dictionary = {}
	for id in GameStats.CODEX_ORDER:
		uniq[String(id)] = true
	_check(uniq.size() == n, "CODEX_ORDER 无重复项（唯一 %d / 总数 %d）" % [uniq.size(), n])

	var tpl_ok := true
	var name_ok := true
	var desc_ok := true
	var sprite_ok := true
	for id in GameStats.CODEX_ORDER:
		var t := String(id)
		if not GameStats.ENEMY_TEMPLATES.has(t):
			tpl_ok = false
		if GameStats.codex_name(t).is_empty():
			name_ok = false
		if GameStats.codex_desc(t).is_empty():
			desc_ok = false
		if AssetDB.enemy_sprite(t) == null:
			sprite_ok = false
	_check(tpl_ok, "每个图鉴 id 都在 ENEMY_TEMPLATES 里")
	_check(name_ok, "每个图鉴 id 都有 codex_name")
	_check(desc_ok, "每个图鉴 id 都有 codex_desc")
	_check(sprite_ok, "每个图鉴 id 都能取到立绘（AssetDB.ENEMIES 已登记）")

	# is_codex_enemy 是对外唯一判定口径：Medium（袋鼠怪数值替身）刻意不进图鉴
	_check(GameStats.is_codex_enemy("Rat"), "is_codex_enemy(Rat) = true")
	_check(not GameStats.is_codex_enemy("Medium"), "is_codex_enemy(Medium) = false（不进图鉴）")
	_check(not GameStats.is_codex_enemy("Nope"), "is_codex_enemy(未知 id) = false")
	# 未知 id 的文案查询必须安静返回空串（never crash），不能把 Slime 的文案串出去
	_check(GameStats.codex_name("Nope").is_empty(), "未知 id 的 codex_name 回落空串")
	_check(GameStats.codex_desc("Nope").is_empty(), "未知 id 的 codex_desc 回落空串")

	# 出场路径可达性：图鉴格子必须是「真能遇到的怪」，否则永远填不满
	var pool: Dictionary = {}
	for t in GameStats.spawn_types(20):
		pool[String(t)] = true
	var missing: Array[String] = []
	for id in GameStats.CODEX_ORDER:
		var t := String(id)
		if pool.has(t):
			continue
		var via_boss: bool = (t == "BossPUA" and GameStats.boss_type_for_wave(10) == "BossPUA") \
			or (t == "Boss" and GameStats.boss_type_for_wave(20) == "Boss")
		var via_elite: bool = t == "Elite" and GameStats.elite_count(20) > 0
		if not (via_boss or via_elite):
			missing.append(t)
	_check(missing.is_empty(), "每个图鉴 id 都有真实出场路径（波池 / 精英 / Boss），缺：%s" % str(missing))


# ---------------------------------------------------------------- B. 账本累加 / 解锁 / 持久化
func _t_ledger() -> void:
	var st: Dictionary = MetaSave.codex_state()
	_check(st.size() == GameStats.CODEX_ORDER.size(),
		"codex_state 条目数 == CODEX_ORDER（%d）" % GameStats.CODEX_ORDER.size())
	var keys_in_order := true
	var idx := 0
	for k in st.keys():
		if String(k) != String(GameStats.CODEX_ORDER[idx]):
			keys_in_order = false
		idx += 1
	_check(keys_in_order, "codex_state 键顺序 == CODEX_ORDER（UI 网格顺序依赖它）")
	var all_locked := true
	for id in st.keys():
		if bool(st[id]["seen"]) or int(st[id]["kills"]) != 0:
			all_locked = false
	_check(all_locked, "空账本：全部未解锁且击杀数为 0")
	_check(not MetaSave.enemy_seen("Rat"), "enemy_seen(Rat) 空账本 = false")
	_check(MetaSave.enemy_kills("Rat") == 0, "enemy_kills(Rat) 空账本 = 0")

	MetaSave.record_kills({"Rat": 3})
	_check(MetaSave.enemy_seen("Rat") and MetaSave.enemy_kills("Rat") == 3,
		"record_kills({Rat:3}) → 解锁 + 累计 3")

	MetaSave.record_kills({"Rat": 2, "Slime": 1})
	_check(MetaSave.enemy_kills("Rat") == 5, "同 id 二次入账累加 3+2=5（实际 %d）" % MetaSave.enemy_kills("Rat"))
	_check(MetaSave.enemy_kills("Slime") == 1, "新 id 同时入账（Slime 1）")
	var raw: Dictionary = MetaSave.ledger()
	_check((raw["seen_enemies"] as Array).size() == 2,
		"seen_enemies 去重（2 项，实际 %d）" % (raw["seen_enemies"] as Array).size())

	# 空字典 = 无事发生（不写盘、不改任何键）
	MetaSave.record_kills({})
	_check(MetaSave.enemy_kills("Rat") == 5 and (MetaSave.ledger()["seen_enemies"] as Array).size() == 2,
		"record_kills({}) 零副作用")

	# 持久化：重新读档（ledger 每次都是「开文件 + JSON.parse」，等价于重开进程）
	var again: Dictionary = MetaSave.codex_state()
	_check(bool(again["Rat"]["seen"]) and int(again["Rat"]["kills"]) == 5, "落盘持久：Rat 解锁且 5 杀")
	_check(bool(again["Slime"]["seen"]) and int(again["Slime"]["kills"]) == 1, "落盘持久：Slime 解锁且 1 杀")
	_check(not bool(again["Ox"]["seen"]), "落盘持久：没杀过的 Ox 仍未解锁")

	# 非法输入：Medium（在模板里但不在图鉴）不该被写进账本
	MetaSave.record_kills({"Medium": 5, "Nope": 9, "Rat": -3, "Slime": 0})
	_check(not MetaSave.enemy_seen("Medium"), "record_kills 丢弃 Medium（不在 CODEX_ORDER，不算解锁）")
	_check(not MetaSave.enemy_seen("Nope"), "record_kills 丢弃未知 id（Nope）")
	_check(MetaSave.enemy_kills("Rat") == 5, "负数计数不计入（Rat 仍 5）")
	_check(MetaSave.enemy_kills("Slime") == 1, "零计数不计入（Slime 仍 1）")


# ---------------------------------------------------------------- C. 坏档 / 脏数据护栏
func _t_guardrails() -> void:
	# C1 类型全错：seen 是字符串、kills 是数组
	_write_raw({"schema_version": 2, "seen_enemies": "not-an-array", "kills_per_enemy": ["x"]})
	var d: Dictionary = MetaSave.ledger()
	_check((d["seen_enemies"] as Array).is_empty(), "坏档：seen_enemies 非数组 → 空表（不崩）")
	_check((d["kills_per_enemy"] as Dictionary).is_empty(), "坏档：kills_per_enemy 非字典 → 空字典（不崩）")

	# C2 合法 JSON 但项级脏：非法 id / 重复 / ≤0 / 非数字
	_write_raw({
		"schema_version": 2,
		"seen_enemies": ["Rat", "Rat", "NotAnEnemy", 123],
		"kills_per_enemy": {"Rat": 7, "NotAnEnemy": 3, "Slime": -2, "Bomber": "abc", "Ox": 0},
	})
	d = MetaSave.ledger()
	var seen: Array = d["seen_enemies"]
	_check(seen.size() == 1 and seen.has("Rat"),
		"脏 seen：非法 id / 数字项 / 重复项被过滤（只剩 Rat，实际 %s）" % str(seen))
	var kpe: Dictionary = d["kills_per_enemy"]
	_check(int(kpe.get("Rat", 0)) == 7, "脏 kills：合法项保留（Rat 7）")
	_check(not kpe.has("NotAnEnemy"), "脏 kills：非法 id 丢弃")
	_check(not kpe.has("Slime"), "脏 kills：负数计数丢弃")
	_check(not kpe.has("Ox"), "脏 kills：0 计数丢弃（与未解锁同义）")
	_check(not kpe.has("Bomber"), "脏 kills：非数字字符串 → 0 → 丢弃")

	# C3 写路径护栏：绕过 record_kills 直接往 ledger() 返回的表里塞脏数据再落盘
	var dl: Dictionary = MetaSave.ledger()
	(dl["seen_enemies"] as Array).append("NotAnEnemy")
	(dl["kills_per_enemy"] as Dictionary)["NotAnEnemy"] = 99
	MetaSave.record_kills({"Ox": 1})     # 用一笔合法入账触发 _save
	var after: Dictionary = MetaSave.ledger()
	_check(not (after["seen_enemies"] as Array).has("NotAnEnemy"),
		"写路径护栏：非法 id 不会因 _save 落盘（seen）")
	_check(not (after["kills_per_enemy"] as Dictionary).has("NotAnEnemy"),
		"写路径护栏：非法 id 不会因 _save 落盘（kills）")
	_check(MetaSave.enemy_kills("Ox") == 1, "写路径护栏：同批合法入账照常生效（Ox 1）")

	# C4 顶层垃圾文件（非 JSON）
	var f := FileAccess.open(PROBE_PATH, FileAccess.WRITE)
	f.store_string("{{{not json")
	f = null
	_check(MetaSave.codex_state().size() == GameStats.CODEX_ORDER.size(),
		"非 JSON 坏档 → 图鉴回落全未解锁且不崩")


# ---------------------------------------------------------------- D. Battle 端到端（真实击杀链路）
func _t_battle_end_to_end() -> void:
	battle.start_run()
	battle.spawn_remaining = 0
	var pl = battle.player
	pl.autopilot = false
	pl.god_mode = true

	_check(battle.enemy_kills.is_empty(), "start_run → 每类击杀数清零")
	var k0: int = battle.kills

	_spawn_dead("Rat")
	_spawn_dead("Rat")
	_spawn_dead("Slime")
	battle.combat.cleanup_enemies()
	_check(int(battle.enemy_kills.get("Rat", 0)) == 2,
		"cleanup_enemies 累加 Rat ×2（实际 %d）" % int(battle.enemy_kills.get("Rat", 0)))
	_check(int(battle.enemy_kills.get("Slime", 0)) == 1, "cleanup_enemies 累加 Slime ×1")
	_check(battle.kills - k0 == 3, "图鉴计数与全局 kills 同源同量（+3）")
	_check(not battle.enemy_kills.has("Medium"), "没死的怪不进统计（Medium 未出现）")

	# 自爆的班味炸弹：kills 不 +1（既有契约），图鉴同样不该解锁它
	_spawn_dead("Bomber", true)
	battle.combat.cleanup_enemies()
	_check(not battle.enemy_kills.has("Bomber"),
		"自爆炸弹不计入图鉴（与 kills 同门槛：died_exploded）")

	# 被打死的炸弹照常计入（对照：同一个 id 的另一种死亡方式）
	_spawn_dead("Bomber", false)
	battle.combat.cleanup_enemies()
	_check(int(battle.enemy_kills.get("Bomber", 0)) == 1, "被打死的炸弹正常计入（Bomber 1）")

	# 重开一局：本局计数清零（图鉴账本由 _end_run 入账，不受影响）
	battle.start_run()
	_check(battle.enemy_kills.is_empty(), "再次 start_run → 本局每类击杀数清零")


## 造一只「已死」的怪（真实入列 + 标 is_dead，再交给 cleanup_enemies 走正规结算路径）。
func _spawn_dead(type_name: String, exploded: bool = false) -> void:
	battle.wave.spawn_enemy(type_name, battle.player.global_position + Vector2(420.0, 0.0))
	var e = battle.enemies[battle.enemies.size() - 1]
	if exploded:
		e.died_exploded = true     # 班味炸弹自爆标记（Enemy._bomber_brain 引爆时打的）
	e.is_dead = true


## 直接往探针存档里写一个 JSON 对象（构造坏档/脏档用）。
func _write_raw(obj: Dictionary) -> void:
	var f := FileAccess.open(PROBE_PATH, FileAccess.WRITE)
	f.store_string(JSON.stringify(obj))
	f = null


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
