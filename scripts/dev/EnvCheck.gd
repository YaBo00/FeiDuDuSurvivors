extends Node2D
## 《肥嘟嘟幸存者》Godot 工程 —— 环境验证场景（开发用，已从 scenes/Main.tscn 迁到此处）。
##
## 本场景唯一的职责：证明「Godot 运行时链路全通」——
## 场景树 / GDScript / 2D 渲染 / 输入映射 / 物理 / Control 布局 / 文件 IO / 退出码。
##
## 正式玩法在 scenes/Battle.tscn；本场景仅供环境排障与 CI 冒烟。
##
## 命令行自检（不需要显示器，可在 CI / 无头环境跑）：
##   godot --headless --path <项目目录> res://scenes/dev/EnvCheck.tscn -- --selftest
## 退出码 0 = PASS，1 = FAIL。

## 自检模式下跑满多少物理帧后判定并退出。
const SELFTEST_FRAMES := 90

@onready var player: CharacterBody2D = $Player
@onready var hud: Label = $HUD/Root/Info

var _selftest := false
var _frames := 0
var _start_pos := Vector2.ZERO
var _failures: PackedStringArray = []


## 候选中文字体族名（按优先级）。Godot 内置默认字体不含 CJK 字形，
## 不做这一步，所有中文 UI 都会渲染成「豆腐块」。
const CJK_FONT_NAMES := [
	"Microsoft YaHei", "微软雅黑", "SimHei", "Noto Sans CJK SC",
	"Source Han Sans SC", "PingFang SC", "sans-serif",
]

## 项目自带字体路径（可选）。放了就用它，保证导出的包在任何机器上中文都正常。
const BUNDLED_FONT := "res://assets/fonts/main_font.ttf"

var _font_report := "未初始化"


func _ready() -> void:
	_selftest = _has_cli_flag("--selftest")
	_start_pos = player.position
	_install_cjk_font()
	_print_environment()
	if _selftest:
		print("[SELFTEST] 无头自检开始，将运行 %d 个物理帧……" % SELFTEST_FRAMES)


## 给 HUD 装一个能显示中文的字体。优先用项目自带字体（assets/fonts/），
## 没有则回落到操作系统字体 —— 正式发布前应把字体随包烘焙进去。
func _install_cjk_font() -> void:
	var font: Font = null
	var source := ""

	if ResourceLoader.exists(BUNDLED_FONT):
		font = load(BUNDLED_FONT) as Font
		source = BUNDLED_FONT

	if font == null:
		var sys := SystemFont.new()
		sys.font_names = PackedStringArray(CJK_FONT_NAMES)
		font = sys
		source = "系统字体「%s」" % CJK_FONT_NAMES[0]

	var theme := Theme.new()
	theme.default_font = font
	theme.default_font_size = 20
	$HUD/Root.theme = theme

	var has_cjk := font.has_char("肥".unicode_at(0))
	_font_report = "%s（含中文字形=%s）" % [source, "是" if has_cjk else "否"]
	if not has_cjk:
		printerr("[WARN] 当前字体不含中文字形，UI 中文会显示为方块。请把字体放到 %s" % BUNDLED_FONT)


func _process(_delta: float) -> void:
	hud.text = _hud_text()


func _physics_process(_delta: float) -> void:
	if not _selftest:
		return
	_frames += 1
	if _frames == 1:
		# 送真实按键事件进 Input 管线（不是绕过映射的 Input.action_press）。
		_send_key(KEY_D, true)
		_send_key(KEY_S, true)
	if _frames >= SELFTEST_FRAMES:
		_finish_selftest()


## 构造真实键盘事件送进 Input 单例。这样验证的是完整链路：
## 物理按键 → InputMap 动作映射 → Input.get_vector → 速度 → move_and_slide → 位移。
func _send_key(physical: Key, pressed: bool) -> void:
	var ev := InputEventKey.new()
	ev.device = 0
	ev.physical_keycode = physical
	ev.pressed = pressed
	Input.parse_input_event(ev)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("pause"):
		get_tree().quit(0)


# ---------------------------------------------------------------- 环境自检

func _finish_selftest() -> void:
	# 先取样，再释放按键 —— 释放后动作状态就查不到了。
	var mapped := Input.is_action_pressed("move_right") and Input.is_action_pressed("move_down")
	var moved := player.position.distance_to(_start_pos)
	var speed := player.velocity.length()

	_send_key(KEY_D, false)
	_send_key(KEY_S, false)

	_check(mapped, "输入映射未生效：物理按键 D / S 没能触发 move_right / move_down 动作")
	_check(moved > 1.0, "玩家未发生位移（物理或渲染链路异常），位移=%.2f px" % moved)
	_check(speed > 0.0, "速度为 0（物理帧未推进）")

	var tex := load("res://icon.svg") as Texture2D
	_check(tex != null, "icon.svg 无法加载为 Texture2D（导入管线异常）")

	_check(_probe_file_io(), "user:// 目录读写校验失败")

	print("[SELFTEST] 输入映射=%s 位移=%.1fpx 速度=%.1f 帧数=%d" % [
		"OK" if mapped else "FAIL", moved, speed, _frames,
	])

	if _failures.is_empty():
		print("[SELFTEST] RESULT=PASS 位移=%.1fpx 帧数=%d fps=%d" % [
			moved, _frames, Engine.get_frames_per_second(),
		])
		get_tree().quit(0)
	else:
		for msg in _failures:
			printerr("[SELFTEST] FAIL: %s" % msg)
		print("[SELFTEST] RESULT=FAIL 失败项=%d" % _failures.size())
		get_tree().quit(1)


## 校验 user:// 可写可读 —— 后续存档（角色解锁 / 跨局金币）依赖它。
func _probe_file_io() -> bool:
	const PROBE := "user://_env_probe.txt"
	var w := FileAccess.open(PROBE, FileAccess.WRITE)
	if w == null:
		return false
	w.store_string("ok")
	w.close()

	var r := FileAccess.open(PROBE, FileAccess.READ)
	if r == null:
		return false
	var content := r.get_as_text()
	r.close()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(PROBE))
	return content == "ok"


func _check(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)


# ---------------------------------------------------------------- 环境信息

func _print_environment() -> void:
	var v := Engine.get_version_info()
	print("==================================================================")
	print(" 《肥嘟嘟幸存者》Godot 运行时启动（环境验证场景）")
	print("------------------------------------------------------------------")
	print("  引擎版本      : Godot %s (%s)" % [v["string"], v["build"]])
	print("  操作系统      : %s" % OS.get_name())
	print("  渲染后端      : %s" % ProjectSettings.get_setting("rendering/renderer/rendering_method"))
	print("  显示后端      : %s" % DisplayServer.get_name())
	print("  物理帧率      : %d Hz" % Engine.physics_ticks_per_second)
	print("  主场景        : %s" % scene_file_path)
	print("  用户数据目录  : %s" % OS.get_user_data_dir())
	print("  视口尺寸      : %s" % get_viewport().get_visible_rect().size)
	print("  中文字体      : %s" % _font_report)
	print("==================================================================")


func _hud_text() -> String:
	var p := player.position
	return "FPS %d\n位置 %s   速度 %s\n\n方向键 / WASD 移动 ｜ ESC 退出" % [
		Engine.get_frames_per_second(),
		Vector2i(p),
		Vector2i(player.velocity),
	]


func _has_cli_flag(flag: String) -> bool:
	return flag in OS.get_cmdline_args() or flag in OS.get_cmdline_user_args()
