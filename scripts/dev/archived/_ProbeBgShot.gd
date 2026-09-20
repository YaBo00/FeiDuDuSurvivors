extends SceneTree
## 截图探针：把 5 个波次主题的地面贴图逐个切上，各截一帧存盘。
##
## 目的：背景重构（程序化花纹 → assets/bg/*.png 整铺）后，让「看不见画面」的
## 一方能直接看到每个主题的真实观感（亮度 / 对比 / 与精灵的兼容性）。
##
## 用法（必须【非 headless】，headless 没有渲染截出来是黑的）:
##   godot --path <项目> --script res://scripts/dev/_ProbeBgShot.gd
## 输出: .workbuddy/bg_shots/{ceramic,wood,marble,metal,gilded}.png
## 退出码 0=截完 1=失败

const OUT_DIR := "C:/Users/10201/Desktop/Roguelike/.workbuddy/bg_shots"
const WARMUP_FRAMES := 45  # 窗口/swapchain 就绪前截图会有白屏伪影，先热身
const SETTLE_FRAMES := 6   # 切主题后等几帧再截，确保 redraw 已提交

var battle: Node = null
var frame := 0
var idx := -1              # 当前主题下标（-1 = 还没开始）
var settle := 0
var done := 0


func _initialize() -> void:
	var packed: PackedScene = load("res://scenes/battle/Battle.tscn")
	if packed == null:
		print("[PROBE] Battle.tscn 加载失败")
		quit(1)
		return
	battle = packed.instantiate()
	root.add_child(battle)
	DirAccess.make_dir_recursive_absolute(OUT_DIR)
	print("[PROBE] Battle 已入树，等待第一帧布置")


func _arm() -> void:
	battle.player.autopilot = true
	battle.player.god_mode = true
	Engine.max_fps = 30
	# 隔离实验开关：置空氛围层，验证外圈白环来源（OUTPUTS 到日志，用完恢复）
	if OS.get_environment("BGSHOT_NO_OVERLAY") == "1":
		battle._floor_glow = null
		battle._floor_vignette = null
		print("[PROBE] 隔离模式：glow/vignette 已禁用")
	elif OS.get_environment("BGSHOT_ONLY_GLOW") == "1":
		battle._floor_vignette = null
		print("[PROBE] 隔离模式：只画 glow")
	_dump_state()


func _dump_state() -> void:
	var g = battle._floor_glow
	var v = battle._floor_vignette
	print("[PROBE] tex=%s glow=%s vignette=%s" % [
		"有" if battle._floor_tex != null else "无",
		"有" if g != null else "无",
		"有" if v != null else "无"])
	if g != null:
		var grad: Gradient = g.gradient
		for i in grad.get_point_count():
			print("[PROBE]   glow点%d offset=%.2f color=%s" % [i, grad.get_offset(i), grad.get_color(i)])
	if v != null:
		var grad: Gradient = v.gradient
		for i in grad.get_point_count():
			print("[PROBE]   vig点%d offset=%.2f color=%s" % [i, grad.get_offset(i), grad.get_color(i)])
	print("[PROBE] 开始逐主题截图 → %s" % OUT_DIR)


func _process(_delta: float) -> bool:
	if battle == null:
		return false
	frame += 1
	if frame == 2:
		_arm()
		return false
	if frame < WARMUP_FRAMES:
		return false
	if idx < 0:
		_next_theme()
		return false

	settle += 1
	if settle < SETTLE_FRAMES:
		return false
	settle = 0

	var img: Image = root.get_texture().get_image()
	var path := "%s/%s.png" % [OUT_DIR, String(GameStats.FLOOR_THEMES[idx]["id"])]
	var err := img.save_png(path)
	if err != OK:
		print("[PROBE] 截图失败 %s（err=%d）" % [path, err])
		quit(1)
		return true
	print("[PROBE] 已截 %s（%dx%d）" % [path, img.get_width(), img.get_height()])
	done += 1
	if done >= GameStats.FLOOR_THEMES.size():
		print("[PROBE] RESULT=PASS 共 %d 张" % done)
		quit(0)
		return true
	_next_theme()
	return false


func _next_theme() -> void:
	idx += 1
	battle._apply_floor_theme(GameStats.FLOOR_THEMES[idx])
	print("[PROBE] 切主题 → %s（%s）" % [
		String(GameStats.FLOOR_THEMES[idx]["id"]), String(GameStats.FLOOR_THEMES[idx]["name"])])
