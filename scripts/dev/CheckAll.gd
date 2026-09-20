extends SceneTree
## 秒级语法门：编译工程里【所有】GDScript 与场景文件，不运行任何游戏逻辑。
##
## 为什么需要它：
##   `godot --import` 只导资源、【不编译脚本】，语法错误完全不会暴露（实测踩过多次）；
##   完整自检要跑好几十秒。本工具介于两者之间：把所有 .gd / .tscn 都 load 一遍
##   （load 会强制编译），整个过程几秒钟 —— 这就是「IDE 级立刻报错」的替代品。
##
## 用法（二选一）:
##   godot_console --headless --path <项目> --script res://scripts/dev/CheckAll.gd
##   双击 check.cmd（或 bash check.sh）
## 退出码 0=全部可编译 1=有错误
##
## 注意：本脚本只查【能否编译】，不查逻辑正确性 —— 那是 run_gates 的职责。

const EXCLUDE := ["res://addons/"]

## reload() 判定不适用于这两个特例：
##   - 本脚本自身：运行中无法重载自己（reload 必返回非 OK，属误报）
##   - mcp_interaction_server.gd：它是 autoload 且实例正活着，同样无法重载（误报）
const RELOAD_EXCLUDE := [
	"res://scripts/dev/CheckAll.gd",
	"res://scripts/dev/mcp_interaction_server.gd",
]


func _initialize() -> void:
	var files: Array[String] = []
	_collect(files, "res://scripts", ".gd")
	_collect(files, "res://scenes", ".tscn")
	_collect(files, "res://scripts/dev", ".gd")

	print("=".repeat(72))
	print(" 语法检查：共 %d 个文件（scripts + scenes，含 dev 工具）" % files.size())
	print("=".repeat(72))

	var bad: Array[String] = []
	for f in files:
		# load() 会强制编译；但【编译失败的脚本 load() 仍返回资源】（不返回 null），
		# 所以不能只判 null —— 要用 GDScript.reload() 的返回码判定。
		var res := load(f)
		if res == null:
			bad.append(f)
			printerr("  [COMPILE FAIL] %s（资源加载失败）" % f)
			continue
		if res is GDScript and _needs_reload_check(f):
			var gd: GDScript = res
			var err: int = gd.reload()
			if err != OK:
				bad.append(f)
				printerr("  [COMPILE FAIL] %s（reload 错误码 %d）" % [f, err])

	print("-".repeat(72))
	if bad.is_empty():
		print("  CHECK PASS：%d 个文件全部可编译" % files.size())
		quit(0)
	else:
		print("  CHECK FAIL：%d 个文件编译失败" % bad.size())
		quit(1)


func _collect(out: Array[String], dir_path: String, ext: String) -> void:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return
	dir.list_dir_begin()
	var name := dir.get_next()
	while name != "":
		var full := dir_path + "/" + name
		if dir.current_is_dir():
			if not name.begins_with("."):
				_collect(out, full, ext)
		elif name.ends_with(ext):
			var skip := false
			for e in EXCLUDE:
				if full.begins_with(e):
					skip = true
					break
			if not skip:
				out.append(full)
		name = dir.get_next()
	dir.list_dir_end()


func _needs_reload_check(f: String) -> bool:
	return not RELOAD_EXCLUDE.has(f)
