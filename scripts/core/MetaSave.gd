class_name MetaSave
extends RefCounted
## 局外元成长（A2/A6 迭代）：跨局持久化账本 + 永久强化消费端。
##
## 设计（记录决策）：
##   · 账本：最佳波次/累计击杀/累计金币/局数/胜场，结算时自动入账。
##   · 消费端（本片）：局内表现折算 meta_xp，在标题画面购买 3 条永久强化
##     （META_UPGRADES）。折算公式与价格全部 [PLACEHOLDER]，playtest 后调。
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
const KEYS := ["best_wave", "total_kills", "total_gold", "runs", "wins", "meta_xp"]
## 已解锁角色的持久化键（不属于结算 int 键，单独读写）
const UNLOCKED_KEY := "unlocked_chars"
## 默认解锁：只有基础嘉豪。其余角色走选角界面的「模拟充值」解锁（2026-09-20 用户需求）。
const DEFAULT_UNLOCKED := ["basic"]

## 永久强化表（[PLACEHOLDER] 全部数值待 playtest）。
## cost(n) = 买第 n 级（从 0 计）的花费 = base_cost × cost_growth^level。
## 效果折算见 meta_bonus()：atk/pickup 是乘区，hp 是整数平加。
const META_UPGRADES := [
	{"id": "meta_atk", "name": "火力强化", "desc": "攻击力 +3%", "max_level": 5,
		"base_cost": 120, "cost_growth": 2.0},
	{"id": "meta_hp", "name": "生命强化", "desc": "生命上限 +20", "max_level": 5,
		"base_cost": 100, "cost_growth": 2.0},
	{"id": "meta_pickup", "name": "磁力强化", "desc": "拾取范围 +15%", "max_level": 3,
		"base_cost": 80, "cost_growth": 2.0},
]

static var save_path := "user://meta_save.json"


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
		d[k] = int(parsed.get(k, 0))
	var lv = parsed.get("meta_levels", {})
	if typeof(lv) == TYPE_DICTIONARY:
		for id in lv:
			if find_upgrade(String(id)) != null:
				d["meta_levels"][String(id)] = maxi(0, int(lv[id]))
	var ul = parsed.get(UNLOCKED_KEY, null)
	if typeof(ul) == TYPE_ARRAY:
		for id in ul:
			var cid := String(id)
			if GameStats.CHARACTERS.has(cid) and not (d[UNLOCKED_KEY] as Array).has(cid):
				(d[UNLOCKED_KEY] as Array).append(cid)   # 只收合法角色 id，防脏数据
	return d


## 结算入账：把一局结果并入账本（含 meta_xp 折算）并落盘。返回更新后的账本。
## xp 折算公式（[PLACEHOLDER]）：kills/20 + wave×3 + 通关 +100，向下取整。
## 折算放这里是【单入口】决策：所有结算路径自动带 xp，调用方零改动。
static func record_run(victory: bool, wave: int, kills: int, gold: int) -> Dictionary:
	var d := ledger()
	d["runs"] = int(d["runs"]) + 1
	if victory:
		d["wins"] = int(d["wins"]) + 1
	d["best_wave"] = maxi(int(d["best_wave"]), int(wave))
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


## 汇总当前等级的玩家加成（Player.recalc_stats 叠加用；0 级时全 0 = 零行为变化）。
## 键：atk_mul（攻击乘区）/ hp_flat（生命平加）/ pickup_mul（拾取乘区）。
static func meta_bonus() -> Dictionary:
	var lv: Dictionary = ledger()["meta_levels"]
	return {
		"atk_mul": 0.03 * float(maxi(0, int(lv.get("meta_atk", 0)))),
		"hp_flat": 20.0 * float(maxi(0, int(lv.get("meta_hp", 0)))),
		"pickup_mul": 0.15 * float(maxi(0, int(lv.get("meta_pickup", 0)))),
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


static func _defaults() -> Dictionary:
	var d := {}
	for k in KEYS:
		d[k] = 0
	d["meta_levels"] = {}
	d[UNLOCKED_KEY] = DEFAULT_UNLOCKED.duplicate()
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
	f.store_string(JSON.stringify(out, "  "))
	return true
