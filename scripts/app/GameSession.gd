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

## 上一局的结算快照（供结算界面与后续统计用）。
static var last_result: Dictionary = {}

## 无尽模式开关（由 Battle 解析 `--endless` 置位）。false = 现行 20 波通关。
## ⚠️ 由【命令行】决定，begin_run() 刻意不碰它 —— 换角色重开一局不应改变模式。
static var endless: bool = false


## 开局前调用：记录角色并清掉上一局的结算快照。
## 注意：不重置 endless（模式由命令行决定，见上）。
static func begin_run(char_id: String) -> void:
	selected_char = char_id if GameStats.CHARACTERS.has(char_id) else GameStats.DEFAULT_CHAR
	last_result = {}


## 结算时调用。
static func finish_run(result: Dictionary) -> void:
	last_result = result
