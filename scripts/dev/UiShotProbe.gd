extends SceneTree
## 截图探针：标题画面 + 各弹窗逐个截图存盘（按钮皮肤 / 布局改动的肉眼验收用）。
##
## 目的（2026-09-22 用户报「按钮背景显示不完整 + 边框压字」）：UI 皮肤重做后，
## 让「看不见画面」的一方直接看到真实渲染 —— 标题页 / 设置弹窗 / 局外强化 / 模式选择 /
## 敌人图鉴（含点击详情态，图鉴那两张用重定向的假存档造「部分解锁」状态）。
##
## 用法（必须【非 headless】，headless 没有渲染截出来是黑的）:
##   godot --path <项目> --script res://scripts/dev/UiShotProbe.gd
## 输出: C:/Users/10201/Desktop/Roguelike/.workbuddy/ui_shots/*.png
## 退出码 0=截完 1=失败

const OUT_DIR := "C:/Users/10201/Desktop/Roguelike/.workbuddy/ui_shots"
const WARMUP_FRAMES := 30   # 窗口/swapchain 就绪前截图会有白屏伪影，先热身
const SETTLE_FRAMES := 5    # 开弹窗后等几帧再截，确保 redraw 已提交

var title: Node = null
var frame := 0
var step := 0
var settle := 0


func _initialize() -> void:
	var packed: PackedScene = load("res://scenes/main/Title.tscn")
	if packed == null:
		print("[PROBE] Title.tscn 加载失败")
		quit(1)
		return
	title = packed.instantiate()
	root.add_child(title)
	DirAccess.make_dir_recursive_absolute(OUT_DIR)
	print("[PROBE] Title 已入树 → %s" % OUT_DIR)


func _process(_delta: float) -> bool:
	if title == null:
		return false
	frame += 1
	if frame < WARMUP_FRAMES:
		return false
	# 状态机：0=标题 / 1=设置 / 2=局外强化 / 3=模式选择 / 4=图鉴 / 5=图鉴详情
	if step == 0:
		if not _shot("00_title"):
			return true
		title.call("_open_settings")
		step = 1
		settle = 0
		return false
	if settle < SETTLE_FRAMES:
		settle += 1
		return false
	settle = 0
	if step == 1:
		if not _shot("01_settings"):
			return true
		title.call("_close_settings")
		title.call("_open_meta_shop")
		step = 2
		return false
	if step == 2:
		if not _shot("02_meta_shop"):
			return true
		title.call("_close_meta_shop")
		title.call("_open_difficulty_select")
		step = 3
		return false
	if step == 3:
		if not _shot("03_mode_select"):
			return true
		title.call("_close_difficulty_select")
		_codex_fixture()          # 造一份「部分解锁」的假存档（已重定向路径，不碰真实档）
		title.call("_open_codex")
		step = 4
		return false
	if step == 4:
		if not _shot("04_codex"):
			return true
		title.call("_show_codex_detail", "Rat")   # 点一只已解锁的怪 → 详情区
		step = 5
		return false
	if step == 5:
		if not _shot("05_codex_detail"):
			return true
		var p := "user://ui_shot_codex_meta.json"
		if FileAccess.file_exists(p):
			DirAccess.remove_absolute(p)
		print("[PROBE] RESULT=PASS 共 6 张")
		quit(0)
		return true
	return false


## 图鉴截图前造「部分解锁」状态（5 只已解锁 / 8 只 ???），让一张图同时验收两种格子样式。
## ⚠️ **必须先重定向 save_path** —— 否则测试数据会写进玩家真实存档 user://meta_save.json。
## 前 3 张图（设置/局外强化）截完才调用，所以不受重定向影响。
func _codex_fixture() -> void:
	var p := "user://ui_shot_codex_meta.json"
	MetaSave.save_path = p
	if FileAccess.file_exists(p):
		DirAccess.remove_absolute(p)
	MetaSave.record_kills({"Slime": 128, "Rat": 96, "Student": 41, "Charger": 12, "Ox": 3})


func _shot(name: String) -> bool:
	var img: Image = root.get_texture().get_image()
	var path := "%s/%s.png" % [OUT_DIR, name]
	var err := img.save_png(path)
	if err != OK:
		print("[PROBE] 截图失败 %s（err=%d）" % [path, err])
		quit(1)
		return false
	print("[PROBE] 已截 %s（%dx%d）" % [path, img.get_width(), img.get_height()])
	return true
