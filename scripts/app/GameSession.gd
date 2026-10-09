class_name GameSession
extends RefCounted
## 跨场景会话状态。
##
## 为什么不用 autoload：autoload 单例在 `godot --script ...`（自定义 MainLoop）模式下
## **不会注册成全局标识符**，任何引用它的脚本都会编译失败 —— 而本工程有一批探针/门禁
## 正是用 `--script` 跑的，会把它们全部弄坏（实测确认）。
## 改成 `static var` 后：全局可访问、不依赖 autoload 注册、`--script` 模式下照常工作。
##
## 纪律：只放【必须跨场景传递的少量状态】，不放游戏逻辑 ——
## 数值归 GameStats，资源路径归 AssetDB，玩法归 Battle/Player。

## 选中的角色 id（对应 GameStats.CHARACTERS 的键）。
static var selected_char: String = "basic"

## 无尽模式开关（由 Battle 解析 `--endless` 置位）。false = 现行 20 波通关。
## ⚠️ 由【命令行】决定，begin_run() 刻意不碰它 —— 换角色重开一局不应改变模式。
static var endless: bool = false

## 当前难度（2026-09-20 难度系统）："normal" / "hard"，数值收口在 GameStats.DIFFICULTIES。
## 由【主菜单难度选择】决定（Battle 另解析 `--difficulty` 供无头自检覆盖）；
## ⚠️ 与 endless 同理：begin_run() 刻意不碰它 —— 换角色重开一局不应改变难度。
static var difficulty: String = "normal"

## 开局诅咒（2026-10-08 第二梯队）：本次选择的自选难度诅咒 id 列表（0~GameStats.CURSE_MAX 条），
## 数值收口在 GameStats.CURSES。由【主菜单难度选择】的诅咒子层维护；
## ⚠️ 与 difficulty 同理：begin_run() 刻意不碰它，战斗重开/换角色不丢。
static var curses: Array[String] = []

## meta 2.0 解锁网络快照（2026-10-09）：{unlock_id: true}（定义在 MetaSave.META_UNLOCKS）。
## Battle._ready 在【正常游玩进程】从 MetaSave 刷新；自检 / 平衡 / 探针进程保持空字典
## （干净世界 = 全部未解锁，旧行为逐位不变）—— 探针要测解锁效果时手动赋值本字段。
## 为什么快照而不是实时读档：战斗热路径（apply_item / cap 读取）不做文件 IO；
## 且保证「探针不受玩家真实存档影响」这条确定性纪律。
static var meta_unlocks: Dictionary = {}

## 「武器自由」起始武器选择（2026-10-09 meta 2.0 第二批）：空 = 角色本命武器；
## 非空 = 覆盖武器 id（须在 GameStats.WEAPON_DEFS 内，非法值由 Player.weapon_id() 过滤）。
## 由【主菜单模式选择的「起始武器」子层】维护（仅解锁 unlock_weapon_free 后出现）。
## ⚠️ 与 difficulty 同理：begin_run() 刻意不碰它 —— 换角色/重开一局不丢选择。
static var weapon_pick: String = ""

## 每日种子局开关（2026-10-09 meta 2.0 第二批）：true = 本局用当日固定种子
## （GameStats.daily_seed_value，应用点 Battle.start_run → _apply_daily_seed）。
## 由主菜单「每日挑战」按钮设置；普通/无尽路径显式置 false（入口保证互斥）。
## ⚠️ 同 difficulty：begin_run() 不碰它；探针/自检进程恒 false = 随机流零影响。
static var daily_mode: bool = false


## 某解锁是否生效（战斗侧唯一读取口 —— 与 MetaSave 读档解耦，探针可手动构造）。
static func has_unlock(id: String) -> bool:
	return meta_unlocks.has(id)


## 开局前调用：记录角色。
## （旧 finish_run/last_result 已删：结算快照写进后从无人读 —— 结算展示走
##  Battle._end_run 直填 ResultPanel，战绩持久化走 MetaSave.record_run。审查清理）
static func begin_run(char_id: String) -> void:
	selected_char = char_id if GameStats.CHARACTERS.has(char_id) else GameStats.DEFAULT_CHAR
