class_name Hud
extends CanvasLayer
## 屏幕 HUD：血条 + 经验条 / 波次号 + 清场进度条 / 等级 / 金币。全部用中文显示。

var _root: Control
var _hp_fill: ColorRect
var _hp_text: Label
## 经验条（2026-09-20 用户需求）：血条正下方的细条，展示当前经验/升级所需比例。
var _xp_fill: ColorRect
var _wave_label: Label
## 清场进度条（2026-09-21 用户需求）：取代旧的 30 秒倒计时。位置 = 波次号正下方居中，
## 样式 = 与血量/经验同为进度条，但用【黄色粗线条】。进度 = 已击杀 / (清场时场上 + 已击杀)。
var _clear_bar_bg: ColorRect
var _clear_fill: ColorRect
## 进度条顶部亮金描边（纯装饰，让粗线条边界在浅色地面上也清晰）。
var _clear_edge: ColorRect
var _info_label: Label
var _stats_label: Label
## 武器精通进度（2026-09-20 可达性升级）：进化前显示「武器精通 n/6」，
## 让玩家看得见通往进化还差几步。0 层与已进化时隐藏。
var _mastery_label: Label
## 屏幕中央大字通告（2026-09-20 Boss 狂暴等）：显示 _notice_left 秒后自动隐藏。
var _notice_label: Label
var _notice_left := 0.0

const BAR_W := 320.0
const BAR_H := 22.0
const BAR_X := (GameStats.VIEW_WIDTH - BAR_W) * 0.5
const BAR_Y := GameStats.VIEW_HEIGHT - 56.0
## 经验条几何：与血条同宽居中、贴在血条下方 4px，细条（辅助信息不抢血条的视觉权重）。
const XP_BAR_H := 10.0
const XP_BAR_Y := BAR_Y + BAR_H + 4.0
## 清场进度条几何（2026-09-21 用户需求）：波次号正下方居中。
## 「粗线条」⇒ 比经验条(10)厚；比血条(22)窄，视觉上是一条独立的信息条而非第二根血条。
const CLEAR_BAR_W := 420.0
const CLEAR_BAR_H := 16.0
const CLEAR_BAR_X := (GameStats.VIEW_WIDTH - CLEAR_BAR_W) * 0.5
## 波次号 Label 占 y=12..46 ⇒ 进度条贴在其下沿稍留 2px 呼吸。
const CLEAR_BAR_Y := 48.0
## 填充色 = 金黄色（与顶部波次号 #FFD700 同色系，语义关联："这条代表本波进度"），
## 描边用更亮的金黄让粗线条的边界在浅色地面上也立得住。
const CLEAR_FILL_COLOR := Color("#FFD24A")
const CLEAR_EDGE_COLOR := Color("#FFF0A8")


func _ready() -> void:
	_root = Control.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_root)
	UiFont.install(_root, 20)

	# 波次号（顶部居中）。2026-09-21：倒计时已移除，此行只显示波次。
	_wave_label = _make_label(0.0, 12.0, GameStats.VIEW_WIDTH, 34.0)
	_wave_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_wave_label.add_theme_font_size_override("font_size", 24)
	_wave_label.add_theme_color_override("font_color", Color("#FFD700"))

	# 武器精通进度（顶部居中、波次行下方）：进化前显示 n/6，是通往第二形态的路标
	_mastery_label = _make_label(0.0, 88.0, GameStats.VIEW_WIDTH, 22.0)
	_mastery_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_mastery_label.add_theme_font_size_override("font_size", 15)
	_mastery_label.add_theme_color_override("font_color", Color(0.72, 0.88, 1.0))
	_mastery_label.visible = false

	# 波次清场进度条（2026-09-21 用户需求）：取代旧的 30 秒倒计时，位置 = 波次号正下方居中。
	# 黑底 + 金黄填充，比经验条厚（「粗线条」）—— 玩家一眼看的是「还差多少清完」，
	# 不再是「还剩多少秒」。
	_clear_bar_bg = ColorRect.new()
	_clear_bar_bg.color = Color(0, 0, 0, 0.62)
	_clear_bar_bg.position = Vector2(CLEAR_BAR_X, CLEAR_BAR_Y)
	_clear_bar_bg.size = Vector2(CLEAR_BAR_W, CLEAR_BAR_H)
	_clear_bar_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_clear_bar_bg)

	_clear_fill = ColorRect.new()
	_clear_fill.color = CLEAR_FILL_COLOR
	_clear_fill.position = Vector2(CLEAR_BAR_X + 2.0, CLEAR_BAR_Y + 2.0)
	# 开局进度 0：宽度为 0 的 ColorRect 不画任何像素，正是「一个都没杀 = 0%」
	_clear_fill.size = Vector2(0.0, CLEAR_BAR_H - 4.0)
	_clear_fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_clear_fill)

	# 亮金描边：让整条进度条在任何地面主题上都「立得住」（粗线条的边界感）
	var clear_edge := ColorRect.new()
	clear_edge.color = CLEAR_EDGE_COLOR
	clear_edge.position = Vector2(CLEAR_BAR_X + 2.0, CLEAR_BAR_Y + 2.0)
	clear_edge.size = Vector2(0.0, 2.0)
	clear_edge.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_clear_fill.add_child(clear_edge)
	_clear_edge = clear_edge

	# 屏幕中央大字（Boss 狂暴等突发事件）：默认隐藏，show_center_notice 点亮
	_notice_label = _make_label(0.0, GameStats.VIEW_HEIGHT * 0.30, GameStats.VIEW_WIDTH, 56.0)
	_notice_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_notice_label.add_theme_font_size_override("font_size", 36)
	_notice_label.add_theme_color_override("font_color", Color("#ff5252"))
	_notice_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.75))
	_notice_label.add_theme_constant_override("outline_size", 6)
	_notice_label.visible = false

	# 等级 / 金币（左上）
	_info_label = _make_label(20.0, 12.0, 400.0, 30.0)
	_info_label.add_theme_font_size_override("font_size", 20)
	_info_label.add_theme_color_override("font_color", Color("#e8e8f0"))

	# 血条底
	var bar_bg := ColorRect.new()
	bar_bg.color = Color(0, 0, 0, 0.6)
	bar_bg.position = Vector2(BAR_X, BAR_Y)
	bar_bg.size = Vector2(BAR_W, BAR_H)
	bar_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(bar_bg)

	_hp_fill = ColorRect.new()
	_hp_fill.color = Color("#ff4444")
	_hp_fill.position = Vector2(BAR_X + 2.0, BAR_Y + 2.0)
	_hp_fill.size = Vector2(BAR_W - 4.0, BAR_H - 4.0)
	_hp_fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_hp_fill)

	_hp_text = _make_label(BAR_X, BAR_Y - 2.0, BAR_W, BAR_H + 4.0)
	_hp_text.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hp_text.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_hp_text.add_theme_font_size_override("font_size", 16)

	# 经验条（2026-09-20 用户需求）：血条正下方。黑底 + 柔和亮蓝填充，纯条无字
	# （等级数字在左上信息行，条形本身就是进度语言，不另占文案）。
	var xp_bar_bg := ColorRect.new()
	xp_bar_bg.color = Color(0, 0, 0, 0.55)
	xp_bar_bg.position = Vector2(BAR_X, XP_BAR_Y)
	xp_bar_bg.size = Vector2(BAR_W, XP_BAR_H)
	xp_bar_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(xp_bar_bg)

	_xp_fill = ColorRect.new()
	_xp_fill.color = Color(0.42, 0.75, 1.0)
	_xp_fill.position = Vector2(BAR_X + 2.0, XP_BAR_Y + 2.0)
	_xp_fill.size = Vector2(BAR_W - 4.0, XP_BAR_H - 4.0)
	_xp_fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_xp_fill)

	# 常驻属性面板（左上，等级/金币信息下方）：实时展示主要战斗属性。
	# 半透明底板 + 单个多行 Label；鼠标穿透，不挡操作。
	# 刷新跟随 set_data（HUD_INTERVAL 节拍），升级/购买后属性即时可见。
	# （旧「属性摘要行」_level_label 已删：它创建后从未显示过 —— 每帧 set_data
	#  都只是把它 visible=false，被左上常驻属性面板完全取代。2026-09-20 审查清理）
	var stats_bg := ColorRect.new()
	stats_bg.color = Color(0.04, 0.04, 0.09, 0.55)
	stats_bg.position = Vector2(16.0, 52.0)
	stats_bg.size = Vector2(278.0, 124.0)
	stats_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(stats_bg)
	_stats_label = _make_label(28.0, 58.0, 258.0, 112.0)
	_stats_label.add_theme_font_size_override("font_size", 15)
	_stats_label.add_theme_color_override("font_color", Color(0.88, 0.90, 0.97))


func _make_label(x: float, y: float, w: float, h: float) -> Label:
	var l := Label.new()
	l.position = Vector2(x, y)
	l.size = Vector2(w, h)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(l)
	return l


## 每帧刷新。max_wave 用于显示「当前/总数」（无尽模式忽略它）。签名保持不变。
func set_data(p: Player, wave_num: int, wave_timer: float, max_wave: int) -> void:
	# 2026-09-21 用户需求：不再显示 30 秒倒计时（「剩余 N 秒」整段移除）——
	# 每波 30 秒是【生成敌人的时间】，通关条件是清场而不是熬时间，秒数对玩家没有决策价值。
	# 秒数仍在 wave_timer 里驱动投放窗口，只是不上屏。波次号独占一行、居中。
	if GameStats.is_boss_wave(wave_num):
		if GameSession.endless:
			_wave_label.text = "第 %d 波（无尽）      BOSS" % wave_num
		else:
			_wave_label.text = "第 %d / %d 波      BOSS" % [wave_num, max_wave]
	elif GameSession.endless:
		_wave_label.text = "第 %d 波（无尽）" % wave_num
	else:
		_wave_label.text = "第 %d / %d 波" % [wave_num, max_wave]
	_info_label.text = "难度 %s · 等级 %d · 金币 %d" % [
		GameStats.difficulty_name(), p.level, p.gold]
	# 武器精通进度：进化前常显（0/6 也显示，做路标）；满 6 层进化后隐藏（另有全屏播报）
	if _mastery_label != null:
		if not p.weapon_evolved:
			_mastery_label.text = "武器精通 %d / %d · 每层攻击 +%d，满层进化" % [
				p.weapon_level, GameStats.WEAPON_EVOLVE_LEVEL,
				int(GameStats.WEAPON_MASTERY_STACK_ATK)]
			_mastery_label.visible = true
		else:
			_mastery_label.visible = false
	var ratio := 0.0
	if p.max_hp > 0:
		ratio = clampf(p.hp / float(p.max_hp), 0.0, 1.0)
	_hp_fill.size = Vector2((BAR_W - 4.0) * ratio, BAR_H - 4.0)
	_hp_text.text = "HP %d / %d" % [ceili(p.hp), p.max_hp]
	# 经验条：当前经验 / 升级所需（xp_to_next 恒正，守卫仅防意外 0 除）
	if _xp_fill != null and p.xp_to_next > 0:
		var xp_ratio := clampf(float(p.xp) / float(p.xp_to_next), 0.0, 1.0)
		_xp_fill.size = Vector2((BAR_W - 4.0) * xp_ratio, XP_BAR_H - 4.0)
	# 清场进度条：由调用方（Battle）经 set_clear_ratio 在【每帧】刷新 —— 它是唯一需要
	# 帧级实时的 HUD 元素（清掉一只怪要立刻看到条涨），而本函数只在 HUD_INTERVAL 节拍上跑。
	# 常驻属性面板：四行核心战斗属性（与升级/商店直接对应的项全部展示）
	_stats_label.text = ("攻击 %d    护甲 %d    移速 %d\n"
		+ "攻速 %.2f/s   弹道 %d   射程 %d\n"
		+ "暴击 %d%%（伤害 %d%%）   闪避 %d%%\n"
		+ "吸血 %d%%   回血 %.1f/s   拾取 %d") % [
		p.atk, p.defense, roundi(p.spd),
		p.aspd, p.proj, roundi(p.attack_range),
		roundi(p.crit * 100.0), roundi(p.critd * 100.0), roundi(p.dodge * 100.0),
		roundi(p.lifesteal * 100.0), p.hp_regen, roundi(p.pickup_range),
	]


## 本波清场进度 0..1 → 黄条宽度。每帧由 Battle 调用（见 _tick_fighting）。
## 0 时宽度为 0：一个敌人都没杀就是空的，这正是用户要的语义。
func set_clear_ratio(r: float) -> void:
	if _clear_fill == null:
		return
	var w := (CLEAR_BAR_W - 4.0) * clampf(r, 0.0, 1.0)
	_clear_fill.size = Vector2(w, CLEAR_BAR_H - 4.0)
	if _clear_edge != null:
		_clear_edge.size = Vector2(w, 2.0)


func set_visible_hud(v: bool) -> void:
	_root.visible = v


## 屏幕中央大字通告（2026-09-20 Boss 狂暴）：显示 dur 秒后自动隐藏。
## 重复调用直接覆盖文案并重置计时（同一时刻只有一条通告，后来的优先）。
func show_center_notice(text: String, dur: float) -> void:
	_notice_label.text = text
	_notice_label.visible = true
	_notice_left = dur


func _process(delta: float) -> void:
	if _notice_left > 0.0:
		_notice_left -= delta
		if _notice_left <= 0.0:
			_notice_label.visible = false
