extends SceneTree
## 独立验证探针：MetaSave 局外账本（A2/A6 迭代 · 账本版）。
##
## 被验证的契约：
##   MetaSave.ledger() —— 缺失/损坏一律回落全 0 干净账本
##   MetaSave.record_run(victory, wave, kills, gold) —— 累计入账并落盘（负值钳 0）
##   持久化：重开进程语义 = 重新 ledger() 仍读到累积值
##   best_wave 只升不降；runs/wins 单调；损坏文件被安全覆盖
##
## 隔离：探针把 save_path 重定向到 user://meta_save_probe.json，结束删除，
## 不碰真实存档 user://meta_save.json。
##
## 用法: godot --headless --path <项目> --script res://scripts/dev/_ProbeMetaSave.gd
## 退出码 0=PASS 1=FAIL

const PROBE_PATH := "user://meta_save_probe.json"

var checks := 0
var fails: Array[String] = []
var finished := false


func _initialize() -> void:
	print("[PROBE] === MetaSave 局外账本验证（A2/A6 迭代）===")
	MetaSave.save_path = PROBE_PATH
	if FileAccess.file_exists(PROBE_PATH):
		DirAccess.remove_absolute(PROBE_PATH)

	# ---- A. 空账本 ----
	MetaSave.save_path = PROBE_PATH
	if FileAccess.file_exists(PROBE_PATH):
		DirAccess.remove_absolute(PROBE_PATH)
	var d: Dictionary = MetaSave.ledger()
	_check(int(d["runs"]) == 0 and int(d["best_wave"]) == 0 and int(d["total_kills"]) == 0,
		"空账本：全 0（实际 %s）" % str(d))

	# ---- B. 首局入账 ----
	var d1: Dictionary = MetaSave.record_run(true, 20, 100, 500)
	_check(int(d1["runs"]) == 1 and int(d1["wins"]) == 1 and int(d1["best_wave"]) == 20
		and int(d1["total_kills"]) == 100 and int(d1["total_gold"]) == 500,
		"首局（胜/20 波/100 杀/$500）入账正确：%s" % str(d1))

	# ---- C. 累积 + best_wave 只升不降 ----
	var d2: Dictionary = MetaSave.record_run(false, 7, 30, 80)
	_check(int(d2["runs"]) == 2 and int(d2["wins"]) == 1 and int(d2["best_wave"]) == 20
		and int(d2["total_kills"]) == 130 and int(d2["total_gold"]) == 580,
		"第二局（负/7 波/30 杀/$80）累积正确：%s" % str(d2))

	# ---- D. 持久化（新读取 = 磁盘上的账本）----
	var d3: Dictionary = MetaSave.ledger()
	_check(int(d3["runs"]) == 2 and int(d3["total_kills"]) == 130, "落盘持久：重新读取一致")

	# ---- E. 负值钳 0 ----
	var d4: Dictionary = MetaSave.record_run(false, -3, -5, -9)
	_check(int(d4["best_wave"]) == 20 and int(d4["total_kills"]) == 130
		and int(d4["total_gold"]) == 580 and int(d4["runs"]) == 3,
		"负值输入被钳 0（best_wave/totals 不回退）：%s" % str(d4))

	# ---- F. 损坏文件安全回落 ----
	var f := FileAccess.open(PROBE_PATH, FileAccess.WRITE)
	f.store_string("{{{not json at all")
	f = null
	var d5: Dictionary = MetaSave.ledger()
	_check(int(d5["runs"]) == 0, "损坏文件 → 安全回落全 0 干净账本（并覆盖坏文件）")
	var d6: Dictionary = MetaSave.record_run(true, 5, 10, 20)
	_check(int(d6["runs"]) == 1 and int(d6["best_wave"]) == 5, "回落后再入账正常")

	# ---- 清理 ----
	if FileAccess.file_exists(PROBE_PATH):
		DirAccess.remove_absolute(PROBE_PATH)
	_finish("")


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
