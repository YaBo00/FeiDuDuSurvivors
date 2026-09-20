class_name BattleFeedback
extends CanvasLayer
## 战斗反馈层：伤害飘字对象池 + 击杀爆裂对象池 + 波次横幅。
##
## 职责边界：
##   - 本节点只管【视觉反馈】，不参与任何游戏逻辑
##   - 飘字/爆裂是【世界空间】元素（挂到 world 下，随相机移动）
##   - 波次横幅是【屏幕空间】元素（挂到本 CanvasLayer 下，固定在屏幕上）
##
## Battle 调用本节点的公开方法来触发反馈，本节点管理所有池和生命周期。
## Battle 不需要知道池的实现细节。

const FLOAT_POOL := 28
const FLOAT_LIFE := 0.55
const BURST_POOL := 16

var _world: Node2D = null
var _floats: Array[Label] = []
var _float_life: Array[float] = []
var _bursts: Array[DeathBurst] = []
var _wave_banner: Label = null


## 初始化：创建所有池对象。world 用来挂世界空间的飘字和爆裂。
func setup(world: Node2D) -> void:
	_world = world
	# 飘字池（世界空间的 Label）
	for i in FLOAT_POOL:
		var l := Label.new()
		l.visible = false
		l.size = Vector2(120, 28)
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		l.add_theme_font_size_override("font_size", 18)
		l.z_index = 40
		l.mouse_filter = Control.MOUSE_FILTER_IGNORE
		UiFont.install(l, 18)
		world.add_child(l)
		_floats.append(l)
		_float_life.append(0.0)
	# 爆裂池（世界空间的 Node2D 自绘）
	for i in BURST_POOL:
		var b := DeathBurst.new()
		b.visible = false
		b.z_index = 30
		world.add_child(b)
		_bursts.append(b)
	# 波次横幅（屏幕空间，挂在本 CanvasLayer 下）
	_wave_banner = Label.new()
	_wave_banner.visible = false
	_wave_banner.size = Vector2(1280, 90)
	_wave_banner.position = Vector2(0, 210)
	_wave_banner.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_wave_banner.add_theme_font_size_override("font_size", 52)
	_wave_banner.add_theme_color_override("font_color", Color("#FFD700"))
	_wave_banner.z_index = 45
	_wave_banner.mouse_filter = Control.MOUSE_FILTER_IGNORE
	UiFont.install(_wave_banner, 52)
	add_child(_wave_banner)


## 重开一局时复位所有池（隐藏残留的飘字和爆裂）
func reset() -> void:
	for i in _floats.size():
		_floats[i].visible = false
		_float_life[i] = 0.0
	for b in _bursts:
		b.active = false
		b.visible = false
		b.set_process(false)


## 伤害飘字。big=true 时字号更大（暴击），持续更久。
func spawn_float(pos: Vector2, text: String, color: Color, big: bool) -> void:
	var idx := -1
	for i in _floats.size():
		if not _floats[i].visible:
			idx = i
			break
	if idx < 0:
		idx = 0    # 池满就复用最旧的一个
	var l := _floats[idx]
	l.text = text
	l.add_theme_color_override("font_color", color)
	l.add_theme_font_size_override("font_size", 24 if big else 17)
	l.position = pos + Vector2(-60.0, -26.0) + Vector2(randf_range(-22.0, 22.0), -14.0)
	l.scale = Vector2.ONE * (1.3 if big else 1.0)
	l.modulate = Color(1, 1, 1, 1)
	l.visible = true
	_float_life[idx] = FLOAT_LIFE + (0.2 if big else 0.0)


## 每物理帧更新飘字（上飘 + 淡出）。由 Battle 的 _tick_fighting 调用。
func update_floats(delta: float) -> void:
	for i in _floats.size():
		var l := _floats[i]
		if not l.visible:
			continue
		_float_life[i] -= delta
		l.position.y -= 52.0 * delta
		l.modulate.a = clampf(_float_life[i] / FLOAT_LIFE, 0.0, 1.0)
		if _float_life[i] <= 0.0:
			l.visible = false


## 击杀爆裂特效。
func spawn_burst(pos: Vector2, color: Color, big: bool) -> void:
	for b in _bursts:
		if not b.active:
			b.fire(pos, color, big)
			return


## 波次开始横幅：淡入 → 停留 → 淡出。
func show_wave_banner(wave_num: int, theme_name: String) -> void:
	_wave_banner.text = "第 %d 波 · %s" % [wave_num, theme_name]
	_wave_banner.modulate = Color(1, 1, 1, 0)
	_wave_banner.visible = true
	var tw := create_tween()
	tw.tween_property(_wave_banner, "modulate:a", 1.0, 0.18)
	tw.tween_interval(0.55)
	tw.tween_property(_wave_banner, "modulate:a", 0.0, 0.35)
	tw.tween_callback(func(): _wave_banner.visible = false)
