class_name MetaSave
extends RefCounted
## 局外元成长（A2/A6 迭代）：跨局持久化账本 + 永久强化消费端。
##
## 设计（记录决策）：
##   · 账本：最佳波次/累计击杀/累计金币/局数/胜场，结算时自动入账。
##   · 消费端（本片）：局内表现折算 meta_xp，在标题画面购买永久强化
##     （META_UPGRADES，2026-09-22 由 3 条扩到 9 条）。折算公式与价格全部 [PLACEHOLDER]，
##     playtest 后调。
##   · 静态类而非 autoload：探针可显式控制读写路径（save_path 可重定向），工程树零接线。
##   · JSON 存储（user:// 下），损坏/缺失一律安全回落干净账本（never crash）。
##   · schema_version=2：v1 存档（无 meta 键）读取时自动补 0，不弹版本错误。
##
## 用法：
##   MetaSave.record_run(true, 20, 850, 640)   # 结算时入账（Battle._end_run 调用）
##   MetaSave.ledger()                          # 读账本（标题画面展示用）
##   MetaSave.purchase("meta_atk")              # 买强化（标题商店用）

const SCHEMA_VERSION := 2
## 每局结束后的结算键（写死，防脏数据）
## best_endless_wave（2026-09-20）：无尽模式最佳抵达波次 —— 仅 endless 局入账。
const KEYS := ["best_wave", "best_endless_wave", "total_kills", "total_gold", "runs", "wins", "meta_xp"]
## 已解锁角色的持久化键（不属于结算 int 键，单独读写）
const UNLOCKED_KEY := "unlocked_chars"
## 默认解锁：只有嘉豪。其余角色走选角界面的「模拟充值」解锁（2026-09-20 用户需求）。
const DEFAULT_UNLOCKED := ["basic"]
## 设置项持久化键（2026-09-22 设置菜单）：与结算 int 键/角色解锁分离，单独一个子字典存。
const SETTINGS_KEY := "settings"
## 敌人图鉴持久化键（2026-09-22 敌人图鉴，需求《敌人图鉴_给代码AI_2026-09-22.md》§2.3）。
## 两个都不是结算 int 键（一个是 Array[String]、一个是 Dictionary）⇒ 和 unlocked_chars 一样
## **不进 KEYS**，在 ledger()/_defaults()/_save() 里单独收口。
##   seen_enemies    = 击杀过（= 图鉴已解锁）的敌人 id 去重列表
##   kills_per_enemy = {enemy_id: 累计击杀数}
## 两者的语义一致性由 record_kills() 单入口保证：解锁与计数永不分家。
const SEEN_KEY := "seen_enemies"
const KILLS_KEY := "kills_per_enemy"
## 设置项默认值 —— 【唯一的默认源】：读写类型护栏的回落值、UI 初值全部从这里取，
## 改这一处即全局生效（music_vol/sfx_vol 是 0~1 线性音量，两个开关是显示类）。
const DEFAULT_SETTINGS := {
	"music_vol": 1.0,
	"sfx_vol": 1.0,
	"show_floats": true,
	"screen_shake": true,
}

## 永久强化表（[PLACEHOLDER] 全部数值待 playtest）。
## cost(n) = 买第 n 级（从 0 计）的花费 = base_cost × cost_growth^level。
## 效果折算见 meta_bonus()：atk/pickup/gold/xp 是乘区，hp/start_gold 是整数平加，
## crit 加法、aspd 是乘区，revive 是「存在即 1」的一次性解锁。
##
## 【2026-09-22 扩充：3 → 9 条】原表只有火力/生命/拾取，很快买满、通关后没追求。
## 追加 6 条覆盖经济（财富/启动资金）/经验（智慧）/生存（复活契约）/输出（致命/急速），
## 给几十局的长线目标。UI 侧自动遍历本表渲染 ⇒ **加条目不用动 UI 代码**。
## 排序 = 商店显示顺序：先输出/生存（前三），再经济/经验，最后一次性大件。
##
## ⚠️ 命名易混：**强化的 id `meta_xp` 与账本的货币键 `meta_xp` 同名但不同层** ——
## 货币在 `ledger()["meta_xp"]`（顶层，买强化花的点数），
## 强化等级在 `ledger()["meta_levels"]["meta_xp"]`（玩家花的货币去买的东西）。
## 两者永不相遇（ledger() 只把「表里登记过的 id」收进 meta_levels）。改代码时别读错层。
const META_UPGRADES := [
	{"id": "meta_atk", "name": "火力强化", "desc": "攻击力 +3%/级", "max_level": 5,
		"base_cost": 120, "cost_growth": 2.0},
	{"id": "meta_hp", "name": "生命强化", "desc": "生命上限 +20/级", "max_level": 5,
		"base_cost": 100, "cost_growth": 2.0},
	{"id": "meta_crit", "name": "致命强化", "desc": "暴击率 +2%/级", "max_level": 5,
		"base_cost": 130, "cost_growth": 2.0},
	{"id": "meta_aspd", "name": "急速强化", "desc": "攻速 +3%/级", "max_level": 5,
		"base_cost": 120, "cost_growth": 2.0},
	{"id": "meta_pickup", "name": "磁力强化", "desc": "拾取范围 +15%/级", "max_level": 3,
		"base_cost": 80, "cost_growth": 2.0},
	{"id": "meta_gold", "name": "财富强化", "desc": "局内金币获取 +10%/级", "max_level": 5,
		"base_cost": 100, "cost_growth": 2.0},
	{"id": "meta_xp", "name": "智慧强化", "desc": "局内经验获取 +8%/级", "max_level": 5,
		"base_cost": 110, "cost_growth": 2.0},
	{"id": "meta_start_gold", "name": "启动资金", "desc": "开局金币 +50/级", "max_level": 3,
		"base_cost": 90, "cost_growth": 1.8},
	# 一次性大件：max_level=1 ⇒ 首级价 500 即唯一价（cost_growth=1.0 不参与曲线）。
	# 500 xp ≈ 打 5~8 局，是全局最贵的一项 —— 强力项刻意不设叠层。
	{"id": "meta_revive", "name": "复活契约", "desc": "每局开局自带 1 次复活（回 50% 血）",
		"max_level": 1, "base_cost": 500, "cost_growth": 1.0},
]

static var save_path := "user://meta_save.json"

## 设置缓存（2026-09-22 设置菜单）：飘字/震屏开关在【战斗热路径】被高频读取
## （每次命中/受击都读一次），若每次都走 ledger() 的「开文件 + JSON.parse」会拖垮帧率。
## 这里缓存解析好的设置，热路径只做一次字典查表；仅在 save_path 变化（探针重定向）
## 或 set_setting 写档时刷新。
static var _settings_cache: Dictionary = {}
## 缓存对应的 save_path —— 探针会重定向 save_path，路径一变缓存即失效重载。
static var _settings_path := ""


## JSON 脏数据护栏（审查 P2）：ledger 直接把存档值喂给 int() —— int(Array/Dictionary)
## 会直接脚本报错炸掉账本读取（never crash 纪律）。这里只放行 int/float/数字字符串，
## 其余（bool/array/dict/null）一律按 0 处理，让坏档安全回落干净账本。
static func _safe_int(v: Variant) -> int:
	if v is int:
		return v
	if v is float:
		return int(v)
	if v is String:
		return v.to_int()
	return 0


## 读账本：缺失/损坏 → 返回全 0 的干净账本（并尝试覆盖坏文件）。
static func ledger() -> Dictionary:
	var d := _defaults()
	if not FileAccess.file_exists(save_path):
		return d
	var f := FileAccess.open(save_path, FileAccess.READ)
	if f == null:
		return d
	var parsed = JSON.parse_string(f.get_as_text())
	if typeof(parsed) != TYPE_DICTIONARY:
		_save(d)                     # 坏文件 → 用干净账本覆盖
		return d
	for k in KEYS:
		d[k] = _safe_int(parsed.get(k, 0))
	var lv = parsed.get("meta_levels", {})
	if typeof(lv) == TYPE_DICTIONARY:
		for id in lv:
			if find_upgrade(String(id)) != null:
				d["meta_levels"][String(id)] = maxi(0, _safe_int(lv[id]))
	var ul = parsed.get(UNLOCKED_KEY, null)
	if typeof(ul) == TYPE_ARRAY:
		for id in ul:
			var cid := String(id)
			if GameStats.CHARACTERS.has(cid) and not (d[UNLOCKED_KEY] as Array).has(cid):
				(d[UNLOCKED_KEY] as Array).append(cid)   # 只收合法角色 id，防脏数据
	# 设置项（2026-09-22）：非字典（字符串/数组/null）= 坏档 → 保留 _defaults 里的默认值；
	# 是字典则逐键过类型护栏（详见 _safe_settings）。
	var st = parsed.get(SETTINGS_KEY, null)
	if typeof(st) == TYPE_DICTIONARY:
		d[SETTINGS_KEY] = _safe_settings(st)
	# 敌人图鉴（2026-09-22）：与 unlocked_chars 同款护栏 —— 只收合法敌人 id、去重、计数钳 ≥0。
	# 坏档（字符串/数字/null）直接保留 _defaults 的空表，never crash。
	var seen = parsed.get(SEEN_KEY, null)
	if typeof(seen) == TYPE_ARRAY:
		for id in seen:
			var eid := String(id)
			if GameStats.ENEMY_TEMPLATES.has(eid) and not (d[SEEN_KEY] as Array).has(eid):
				(d[SEEN_KEY] as Array).append(eid)
	var kpe = parsed.get(KILLS_KEY, null)
	if typeof(kpe) == TYPE_DICTIONARY:
		for id in kpe:
			var kid := String(id)
			var n := _safe_int(kpe[id])
			if GameStats.ENEMY_TEMPLATES.has(kid) and n > 0:
				(d[KILLS_KEY] as Dictionary)[kid] = n
	return d


## 结算入账：把一局结果并入账本（含 meta_xp 折算）并落盘。返回更新后的账本。
## xp 折算公式（[PLACEHOLDER]）：kills/20 + wave×3 + 通关 +100，向下取整。
## 折算放这里是【单入口】决策：所有结算路径自动带 xp，调用方零改动。
## endless（2026-09-20）：无尽局传 true —— 只有无尽局才更新 best_endless_wave；
## 普通局（含默认参数的旧调用方/探针）对该键零影响。
static func record_run(victory: bool, wave: int, kills: int, gold: int, endless: bool = false) -> Dictionary:
	var d := ledger()
	d["runs"] = int(d["runs"]) + 1
	if victory:
		d["wins"] = int(d["wins"]) + 1
	d["best_wave"] = maxi(int(d["best_wave"]), int(wave))
	if endless:
		d["best_endless_wave"] = maxi(int(d["best_endless_wave"]), int(wave))
	d["total_kills"] = int(d["total_kills"]) + maxi(0, int(kills))
	d["total_gold"] = int(d["total_gold"]) + maxi(0, int(gold))
	d["meta_xp"] = int(d["meta_xp"]) + xp_earned(victory, int(wave), int(kills))
	_save(d)
	return d


## 局内表现 → meta_xp 折算（纯函数，[PLACEHOLDER]）。
static func xp_earned(victory: bool, wave: int, kills: int) -> int:
	return int(float(maxi(0, kills)) / 20.0) + maxi(0, wave) * 3 + (100 if victory else 0)


## 按 id 查强化定义（找不到返回 null）。返回类型必须显式 Variant ——
## 无标注时 GDScript 会把返回值推断为 null，调用处下标直接解析报错（铁律第 6 次踩坑）。
static func find_upgrade(id: String) -> Variant:
	for u in META_UPGRADES:
		if String(u["id"]) == id:
			return u
	return null


## 当前等级（未购/未知 id = 0）。
static func meta_level(id: String) -> int:
	return maxi(0, int(ledger()["meta_levels"].get(id, 0)))


## 买第 level 级（从 0 计）的价格。
static func upgrade_cost(id: String, level: int) -> int:
	var u: Variant = find_upgrade(id)
	if u == null:
		return 0
	return int(round(float(u["base_cost"]) * pow(float(u["cost_growth"]), float(level))))


## 购买：xp 够且未满级才成功（原子：先查再扣再落盘）。返回是否成功。
static func purchase(id: String) -> bool:
	var u: Variant = find_upgrade(id)
	if u == null:
		return false
	var d := ledger()
	var lvl := maxi(0, int(d["meta_levels"].get(id, 0)))
	if lvl >= int(u["max_level"]):
		return false
	var price := upgrade_cost(id, lvl)
	if int(d["meta_xp"]) < price:
		return false
	d["meta_xp"] = int(d["meta_xp"]) - price
	d["meta_levels"][id] = lvl + 1
	_save(d)
	return true


## 调试用：直接设定某个强化的等级（金手指面板「给任意 Meta 升级加 X 层」）。
## **会写档** —— 面板侧必须先过二次确认（需求 §3.3）。
## 等级钳进 [0, max_level]；未知 id / 非表内 id 一律拒绝并返回 false（防脏档）。
## 刻意做成唯一一个「绕过 purchase 的写入口」：purchase 要扣 meta_xp（货币），
## 而调试就是不想被货币卡住；两条路径都收口在同一个 _save()，档格式不会分叉。
static func debug_set_level(id: String, level: int) -> bool:
	var u: Variant = find_upgrade(id)
	if u == null:
		return false
	var d := ledger()
	d["meta_levels"][id] = clampi(level, 0, int(u["max_level"]))
	_save(d)
	return true


## 汇总当前等级的玩家加成（Player / Battle 消费；0 级时全 0 = 零行为变化）。
## 返回键（9 个，与 META_UPGRADES 一一对应）：
##   atk_mul      攻击乘区（乘）           hp_flat      生命上限平加
##   pickup_mul   拾取范围乘区（乘）        gold_mul     局内金币获取乘区（乘）
##   xp_mul       局内经验获取乘区（乘）    crit         暴击率（加法）
##   aspd_mul     攻速乘区（乘）           start_gold   开局金币（整数平加）
##   revive       复活契约层数（>0 即每局自带 1 次复活，**不叠**）
##
## ⚠️ 数值是【唯一真源】：UI 的 desc 文案若与之不符，以本函数为准（探针断言的也是这里）。
## get 全带默认值 ⇒ 字段缺失/空字典/旧档都安全（never crash）。
static func meta_bonus() -> Dictionary:
	var lv: Dictionary = ledger()["meta_levels"]
	var n_gold := maxi(0, int(lv.get("meta_gold", 0)))
	var n_xp := maxi(0, int(lv.get("meta_xp", 0)))
	return {
		"atk_mul": 0.03 * float(maxi(0, int(lv.get("meta_atk", 0)))),
		"hp_flat": 20.0 * float(maxi(0, int(lv.get("meta_hp", 0)))),
		"pickup_mul": 0.15 * float(maxi(0, int(lv.get("meta_pickup", 0)))),
		"gold_mul": 0.10 * float(n_gold),
		"xp_mul": 0.08 * float(n_xp),
		"crit": 0.02 * float(maxi(0, int(lv.get("meta_crit", 0)))),
		"aspd_mul": 0.03 * float(maxi(0, int(lv.get("meta_aspd", 0)))),
		"start_gold": 50.0 * float(maxi(0, int(lv.get("meta_start_gold", 0)))),
		# 复活契约：max_level=1 ⇒ 用 [0/1] 而不是层数 —— 消费端只判 > 0，不做乘算。
		"revive": 1 if maxi(0, int(lv.get("meta_revive", 0))) > 0 else 0,
	}


# ---------------------------------------------------------------- 角色解锁（模拟充值消费端）
## 角色是否已解锁。默认只有 basic（DEFAULT_UNLOCKED）；坏档/旧档无此键时同回落。
static func is_char_unlocked(id: String) -> bool:
	return (ledger()[UNLOCKED_KEY] as Array).has(id)


## 解锁角色（模拟充值确认后调用）：幂等，成功落盘返回 true。
static func unlock_char(id: String) -> bool:
	if not GameStats.CHARACTERS.has(id):
		return false
	var d := ledger()
	var arr: Array = d[UNLOCKED_KEY]
	if arr.has(id):
		return true
	arr.append(id)
	_save(d)
	return true


# ---------------------------------------------------------------- 敌人图鉴（2026-09-22）
## 图鉴入账：把一局的「每种敌人击杀数」累加进账本并落盘。**唯一写入入口**。
## 参数 kills = {enemy_type_id: count}（Battle 每局结束后交给这里）。
##   · 只认 ENEMY_TEMPLATES 里的合法 id（防脏数据）；计数 ≤0 的项直接跳过。
##   · 同一 id 同时累加 kills_per_enemy 并追加进 seen_enemies（去重）——
##     「已解锁」与「击杀数 > 0」在数据层同源，不可能出现解锁了却 0 杀的条目。
## 空字典直接返回（不写盘）—— 保证「没杀过怪的局」不产生任何 IO 与副作用。
static func record_kills(kills: Dictionary) -> void:
	if kills.is_empty():
		return
	var d := ledger()
	var seen: Array = d[SEEN_KEY]
	var counts: Dictionary = d[KILLS_KEY]
	var touched := false
	for id in kills.keys():
		var eid := String(id)
		if not GameStats.ENEMY_TEMPLATES.has(eid):
			continue
		var n := maxi(0, _safe_int(kills[id]))
		if n <= 0:
			continue
		counts[eid] = maxi(0, int(counts.get(eid, 0))) + n
		if not seen.has(eid):
			seen.append(eid)
		touched = true
	if touched:
		_save(d)


## 图鉴条目状态（UI 专用批量读）：{enemy_id: {"seen": bool, "kills": int}}。
## 顺序 = GameStats.CODEX_ORDER，13 条只读一次档（图鉴界面别对每格调一次 enemy_kills）。
static func codex_state() -> Dictionary:
	var d := ledger()
	var seen: Array = d[SEEN_KEY]
	var counts: Dictionary = d[KILLS_KEY]
	var out := {}
	for id in GameStats.CODEX_ORDER:
		var t := String(id)
		out[t] = {"seen": seen.has(t), "kills": maxi(0, int(counts.get(t, 0)))}
	return out


## 单个敌人是否已解锁（击杀过）。未知 id 恒 false。
static func enemy_seen(type_name: String) -> bool:
	return (ledger()[SEEN_KEY] as Array).has(type_name)


## 单个敌人累计击杀数（未知 id / 未击杀 = 0）。
static func enemy_kills(type_name: String) -> int:
	return maxi(0, int((ledger()[KILLS_KEY] as Dictionary).get(type_name, 0)))


# ---------------------------------------------------------------- 设置项（2026-09-22 设置菜单）
## 读单项设置。未知键返回 null；已知键缺失/坏档时回落到 DEFAULT_SETTINGS 的对应值。
## 【热路径（每次命中/受击）会调它】—— 走 _settings_cache 字典查表，不做文件 IO。
static func get_setting(key: String) -> Variant:
	_ensure_settings()
	if _settings_cache.has(key):
		return _settings_cache[key]
	return DEFAULT_SETTINGS.get(key)


## 写单项设置：过类型护栏（音量钳 0~1、开关转 bool）→ 更新缓存 → 落盘。
## 未知键直接丢弃（防脏键写档）。value 非法时回落到该键默认值，绝不写入坏类型。
## flush=false（质检 P2-4，2026-09-22）：只更新缓存不落盘 —— 给音量滑块的
## value_changed 用（拖动时每秒触发几十次，旧版每次都是「读档+写档」双 IO）；
## 调用方在 drag_ended 时再以默认 flush=true 落一次盘。开关类低频调用不受影响。
static func set_setting(key: String, value: Variant, flush: bool = true) -> void:
	if not DEFAULT_SETTINGS.has(key):
		return
	_ensure_settings()
	_settings_cache[key] = _guard_value(key, value)
	if not flush:
		return
	var d := ledger()
	d[SETTINGS_KEY] = _settings_cache.duplicate(true)
	_save(d)


## 保证设置缓存已从当前 save_path 载入。save_path 变（探针重定向）即重新载入。
static func _ensure_settings() -> void:
	if _settings_path == save_path and not _settings_cache.is_empty():
		return
	var d := ledger()
	_settings_cache = (d[SETTINGS_KEY] as Dictionary).duplicate(true)
	_settings_path = save_path


## 单项类型的护栏分派（唯一入口：ledger 读 / _save 写 / set_setting 都走它）。
static func _guard_value(key: String, value: Variant) -> Variant:
	match key:
		"music_vol", "sfx_vol":
			return _guard_vol(value, float(DEFAULT_SETTINGS[key]))
		"show_floats", "screen_shake":
			return _guard_bool(value, bool(DEFAULT_SETTINGS[key]))
	return value


## 音量护栏：数字 → 钳到 [0,1]；非数字（字符串/数组/字典/null/bool）→ 回落默认。
static func _guard_vol(v: Variant, fallback: float) -> float:
	if v is float or v is int:
		return clampf(float(v), 0.0, 1.0)
	return fallback


## 开关护栏：bool → 原值；其余类型 → 回落默认。
static func _guard_bool(v: Variant, fallback: bool) -> bool:
	if v is bool:
		return v
	return fallback


## 整个设置字典的护栏：逐键走 _guard_value（键缺失也补默认），保证返回结构恒定 4 键。
static func _safe_settings(raw: Dictionary) -> Dictionary:
	var out := {}
	for k in DEFAULT_SETTINGS.keys():
		out[k] = _guard_value(String(k), raw.get(k, null))
	return out


static func _defaults() -> Dictionary:
	var d := {}
	for k in KEYS:
		d[k] = 0
	d["meta_levels"] = {}
	d[UNLOCKED_KEY] = DEFAULT_UNLOCKED.duplicate()
	d[SETTINGS_KEY] = DEFAULT_SETTINGS.duplicate(true)
	d[SEEN_KEY] = []
	d[KILLS_KEY] = {}
	return d


static func _save(d: Dictionary) -> bool:
	var f := FileAccess.open(save_path, FileAccess.WRITE)
	if f == null:
		push_warning("MetaSave: 无法写入 %s" % save_path)
		return false
	var out := {"schema_version": SCHEMA_VERSION}
	for k in KEYS:
		out[k] = int(d.get(k, 0))
	out["meta_levels"] = d.get("meta_levels", {})
	out[UNLOCKED_KEY] = d.get(UNLOCKED_KEY, DEFAULT_UNLOCKED)
	# 设置项：写前再过一遍护栏，保证落盘的永远是合法类型/范围（防脏数据回写）。
	out[SETTINGS_KEY] = _safe_settings(d.get(SETTINGS_KEY, DEFAULT_SETTINGS))
	# 敌人图鉴：写前同样过滤（防外部直改 ledger 返回的字典把脏数据写回去）。
	out[SEEN_KEY] = _safe_seen(d.get(SEEN_KEY, []))
	out[KILLS_KEY] = _safe_kills(d.get(KILLS_KEY, {}))
	f.store_string(JSON.stringify(out, "  "))
	return true


## 图鉴解锁列表护栏：只留合法敌人 id、去重、保持顺序。非数组一律返回空表。
static func _safe_seen(raw: Variant) -> Array:
	var out: Array = []
	if typeof(raw) != TYPE_ARRAY:
		return out
	for id in raw:
		var eid := String(id)
		if GameStats.ENEMY_TEMPLATES.has(eid) and not out.has(eid):
			out.append(eid)
	return out


## 图鉴击杀数护栏：只留合法敌人 id 且计数 ≥1（0/负数 = 与「未解锁」同义，直接丢弃）。
static func _safe_kills(raw: Variant) -> Dictionary:
	var out := {}
	if typeof(raw) != TYPE_DICTIONARY:
		return out
	for id in raw:
		var eid := String(id)
		var n := _safe_int(raw[id])
		if GameStats.ENEMY_TEMPLATES.has(eid) and n > 0:
			out[eid] = n
	return out
