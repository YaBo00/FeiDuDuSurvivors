class_name ResultPanel
extends CanvasLayer
## 关卡结束（失败 / 通关）结算面板。

## 「再来一局」请求（2026-10-08 旗舰批次）：Battle 接到后走 start_run
##（与暂停菜单的「重开一局」、键盘 R 同一条路径）。
signal restart_requested()

var _root: Control
var _title: Label
var _stats: Label
## 成就解锁行（2026-10-08）：stats["achievements"] 非空时才显示，否则整行隐藏。
var _ach: Label
var _hint: Label
var _back: Button
## 「再来一局」主按钮（2026-10-08 旗舰批次）。
var _again: Button
## 结算背景大图（2026-09-22）与其上的压暗罩。图缺时不显示 _bg，_dim 保持原 0.72。
var _bg: TextureRect
var _dim: ColorRect


func _ready() -> void:
	visible = false
	_root = Control.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_root)
	UiFont.install(_root, 20)
	UiTheme.apply(_root)

	# 结算背景大图（2026-09-22，结算背景_通关/失败）：整个铺满、最底层。
	# 贴图在 show_result 里按胜负选（那时才知道 victory）；这之前保持不可见。
	_bg = TextureRect.new()
	_bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	_bg.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_bg.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_bg.visible = false
	_root.add_child(_bg)

	# 压暗一层：有背景图时只压 0.35 让图透出来；没图时保持原 0.72（纯黑半透罩观感不变）。
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.72)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	_root.add_child(dim)
	_dim = dim

	_title = _make_label(0.0, 220.0, GameStats.VIEW_WIDTH, 70.0, 48)
	_stats = _make_label(0.0, 320.0, GameStats.VIEW_WIDTH, 160.0, 26)
	# 成就解锁行（2026-10-08 玩法增补批次）：本次结算新解锁的成就，金字横排在提示上方。
	_ach = _make_label(0.0, 600.0, GameStats.VIEW_WIDTH, 70.0, 19)
	_ach.add_theme_color_override("font_color", Color("#FFD700"))
	_ach.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_ach.visible = false
	_hint = _make_label(0.0, 560.0, GameStats.VIEW_WIDTH, 30.0, 18)
	_hint.add_theme_color_override("font_color", Color(0.8, 0.8, 0.9))
	_hint.text = "按 R 重开一局     按 ESC 退出"

	# 底部按钮行（2026-10-08 旗舰批次）：主按钮「再来一局」+ 副按钮「返回标题」并排居中。
	# 「再来一局」只发信号 —— 重开动作由 Battle 接（start_run 的完整复位语义都在那边，
	# 结算页自己重载场景会漏掉 time_scale / 暂停态等收尾）。
	const BTN_W := 200.0
	const BTN_GAP := 24.0
	var row_x := (GameStats.VIEW_WIDTH - BTN_W * 2.0 - BTN_GAP) * 0.5

	_again = Button.new()
	_again.text = "再来一局"
	_again.position = Vector2(row_x, 480.0)
	_again.size = Vector2(BTN_W, 54)
	_again.add_theme_font_size_override("font_size", 24)
	_again.add_theme_color_override("font_color", Color("#FFD700"))
	_again.mouse_filter = Control.MOUSE_FILTER_STOP
	_again.pressed.connect(func(): restart_requested.emit())
	_root.add_child(_again)

	# 返回标题（有主菜单之后必须给一条回主菜单的路）
	_back = Button.new()
	_back.text = "返回标题"
	_back.position = Vector2(row_x + BTN_W + BTN_GAP, 480.0)
	_back.size = Vector2(BTN_W, 54)
	_back.add_theme_font_size_override("font_size", 22)
	_back.mouse_filter = Control.MOUSE_FILTER_STOP
	_back.pressed.connect(func(): get_tree().change_scene_to_file("res://scenes/main/Title.tscn"))
	_root.add_child(_back)


func _make_label(x: float, y: float, w: float, h: float, size: int) -> Label:
	var l := Label.new()
	l.position = Vector2(x, y)
	l.size = Vector2(w, h)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	l.add_theme_font_size_override("font_size", size)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(l)
	return l


## 应用结算背景图：有图 → 显示大图并把压暗罩降到 0.35（图当底、文字压上面，看得清）；
## 无图（未导入 / 缺美术）→ 保持原「纯黑半透罩 0.72」观感，旧行为逐位不变。
func _apply_bg(bg_tex: Texture2D) -> void:
	if _bg == null or _dim == null:
		return
	if bg_tex == null:
		_bg.visible = false
		_dim.color = Color(0, 0, 0, 0.72)
		return
	_bg.texture = bg_tex
	_bg.visible = true
	_dim.color = Color(0, 0, 0, 0.35)


## stats 约定字段：victory, waves_completed, kills, level, gold, difficulty（可选）
##                 endless / endless_best / new_record（可选，2026-09-20 无尽体验 —— 缺省按普通局渲染）
func show_result(stats: Dictionary) -> void:
	var victory: bool = stats.get("victory", false)
	var endless: bool = stats.get("endless", false)
	# 结算背景（2026-09-22）：通关用「结算背景_通关」，其余（失败 / 无尽终局）用「结算背景_失败」。
	_apply_bg(AssetDB.bg("result_win" if victory else "result_lose"))
	if victory:
		_title.text = "通关！"
		_title.add_theme_color_override("font_color", Color("#FFD700"))
	elif endless:
		_title.text = "无尽终局"
		_title.add_theme_color_override("font_color", Color("#ff4444"))
	else:
		_title.text = "失败"
		_title.add_theme_color_override("font_color", Color("#ff4444"))
	# 难度行（2026-09-20 难度系统）：字段缺省时省略 —— 旧调用方/探针零影响
	var diff_name := String(stats.get("difficulty", ""))
	var diff_line := "难度：%s\n" % diff_name if diff_name != "" else ""
	# 诅咒行（2026-10-08 第二梯队）：选过诅咒才显示（条数 + 强化点数乘区）——
	# 让玩家看到「这局为什么多拿点数」，是「自虐换成长」闭环的兑现环节。
	var curse_n := int(stats.get("curses", 0))
	var curse_line := ""
	if curse_n > 0:
		curse_line = "诅咒 %d 条 · 强化点数 ×%.2f\n" % [
			curse_n, float(stats.get("curse_xp_mul", 1.0))]
	# 融合行（2026-10-08 第二梯队·武器融合）：本局完成融合才显示 —— 大后期质变的兑现展示。
	var fusion_name := String(stats.get("fusion", ""))
	var fusion_line := "武器融合：%s\n" % fusion_name if fusion_name != "" else ""
	# 每日挑战行（2026-10-09 meta 2.0 第二批）：每日局才显示（当日最佳 + 破纪录高亮）。
	# 字段缺省时整行省略 —— 旧调用方/探针零影响。
	var daily_line := ""
	if bool(stats.get("daily", false)):
		daily_line = "每日挑战 · 当日最佳：%d 波\n" % int(stats.get("daily_best", 0))
		if bool(stats.get("daily_new_record", false)):
			daily_line = "每日挑战 · 新纪录！\n" + daily_line
	# 无尽行（2026-09-20）：历史最佳常驻；破纪录在标题下加一行高亮提示
	var endless_line := ""
	if endless:
		endless_line = "无尽最佳：%d 波\n" % int(stats.get("endless_best", 0))
		if bool(stats.get("new_record", false)):
			endless_line = "新纪录！\n" + endless_line
	_stats.text = "%s%s%s%s%s%s\n击杀数：%d\n等级：%d\n金币：%d" % [
		diff_line,
		curse_line,
		fusion_line,
		daily_line,
		endless_line,
		("抵达波数：%d" if endless else "存活波数：%d") % int(stats.get("waves_completed", 0)),
		stats.get("kills", 0),
		stats.get("level", 1),
		stats.get("gold", 0),
	]
	if bool(stats.get("new_record", false)):
		_title.text += "  ★"
	# 成就解锁行（2026-10-08）：字段缺省 / 空数组 = 不显示（旧调用方/探针零影响）。
	# 最多列 3 条，超出折叠为「等 N 项」—— 行高有限，不让长列表把版面撑破。
	var ach_list: Array = stats.get("achievements", [])
	if _ach != null:
		if ach_list.is_empty():
			_ach.visible = false
		else:
			var parts: Array[String] = []
			for i in mini(ach_list.size(), 3):
				var a: Dictionary = ach_list[i]
				parts.append("%s（+%d XP）" % [String(a.get("name", "")), int(a.get("xp", 0))])
			var line := "成就解锁：" + "　".join(parts)
			if ach_list.size() > 3:
				line += "　…等 %d 项" % ach_list.size()
			_ach.text = line
			_ach.visible = true
	visible = true


func hide_panel() -> void:
	visible = false
	if _ach != null:
		_ach.visible = false


## 结算页 Esc = 退出游戏。提示文案一直写着「按 ESC 退出」，但此前没有任何人接
## —— 纯死键（2026-09-20 全库审查 P1）。语义与 UpgradePanel 的 Esc 一致。
## RESULT 状态树未暂停，本节点默认能收 _unhandled_input；visible 守卫防误触。
func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return
	if event.is_action_pressed("pause"):
		get_tree().quit(0)
