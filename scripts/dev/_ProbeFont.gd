extends SceneTree
## 字体探针（批次四 4c）：断言打包字体覆盖游戏源码里用到的【每一个】非 ASCII 字形。
##
## 为什么要做：main_font.ttf 是【子集字体】（docs/review/make_font_subset.py 生成），
## 只保留"扫描那一刻"源码里出现的字形。以后往 UI/文案里加了新的中文/全角字符，
## 若不重跑子集脚本，新字符就会渲染成豆腐块 —— 本探针把这件事变成门禁红线。
##
## 手法：遍历 res://scripts 与 res://scenes 下所有 .gd/.tscn，收集非 ASCII 字符，
## 逐个问 Font.has_char()。⚠️ 源码在导出包里不存在，但本探针只在开发期跑（godot --script），
## 所以可以直接读源码。
##
## 用法: godot --headless --path <项目> --script res://scripts/dev/_ProbeFont.gd
## 退出码 0=PASS 1=FAIL（门禁 grep "RESULT=PASS"）

const FONT_PATH := "res://assets/fonts/main_font.ttf"
const SCAN_DIRS := ["res://scripts", "res://scenes"]

var _chars := {}
var _files := 0


func _initialize() -> void:
	print("[PROBE] === 打包字体字形覆盖验证（批次四 4c）===")
	var font = load(FONT_PATH)
	if font == null:
		_finish(false, "字体未找到或未导入：%s（先跑一次 --import；仍缺就重跑 docs/review/make_font_subset.py）" % FONT_PATH)
		return
	for dir in SCAN_DIRS:
		_scan(dir)
	if _chars.is_empty():
		_finish(false, "没扫描到任何非 ASCII 字符（扫描路径配置错了）")
		return
	var missing: Array = []
	for code in _chars.keys():
		if not font.has_char(int(code)):
			missing.append(String.chr(int(code)))
	if not missing.is_empty():
		_finish(false, "字体缺 %d 个字形：%s …（重跑 docs/review/make_font_subset.py 再 --import）" % [
			missing.size(), "".join(missing.slice(0, 40))])
		return
	print("[PROBE] 扫描文件 %d 个，非 ASCII 字符 %d 个，全部有字形" % [_files, _chars.size()])
	_finish(true, "打包字体完整覆盖游戏源码用字（无豆腐块风险）")


## 递归收集目录下 .gd/.tscn 里的非 ASCII 字符（去重）。
func _scan(path: String) -> void:
	var dir := DirAccess.open(path)
	if dir == null:
		return
	dir.list_dir_begin()
	var name := dir.get_next()
	while name != "":
		var full := path + "/" + name
		if dir.current_is_dir():
			if not name.begins_with("."):
				_scan(full)
		elif name.ends_with(".gd") or name.ends_with(".tscn"):
			_files += 1
			var f := FileAccess.open(full, FileAccess.READ)
			if f != null:
				var text := f.get_as_text()
				for ch in text:
					var code := ch.unicode_at(0)
					if code > 0x7F and not _is_invisible(code):
						_chars[code] = true
		name = dir.get_next()


## 不可见修饰符不要求字体有字形（缺了也不会渲染成豆腐块）：
## U+FE00~FE0F 变体选择符、U+200B~200F 零宽字符/方向标记。
func _is_invisible(code: int) -> bool:
	return (code >= 0xFE00 and code <= 0xFE0F) \
		or (code >= 0x200B and code <= 0x200F)


func _finish(ok: bool, msg: String) -> void:
	print("[PROBE] %s" % msg)
	print("[PROBE] RESULT=%s" % ("PASS" if ok else "FAIL"))
	quit(0 if ok else 1)
