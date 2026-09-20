class_name TouchControls
extends CanvasLayer
## 左手浮动静虚拟摇杆（批次四 4a）。
##
## 行为：
##   - 手指按下【屏幕左半边】（x < VIEW_WIDTH * TOUCH_LEFT_HALF_RATIO）→
##     base 中心锚定到按下点并显示；抬起 → knob 回中、隐藏 base、方向清零。
##   - 拖动时 knob 跟随手指，偏移钳制在 TOUCH_MAX_RADIUS 内。
##   - move_dir() 返回归一化方向（长度 ≤ 1）；未触摸时恒为 Vector2.ZERO。
##   - 多点触控只跟踪第一根按下的手指（_touch_index），其余手指不影响方向。
##
## 节点全部代码构建（工程惯例，见 Hud.gd）；纹理缺失时整块自禁用并隐藏
## —— 沿用「没美术也能跑」的回落设计，不 push_warning 刷屏。
##
## 键盘输入完全不经此处：Player 端把 move_dir() 叠加在 Input.get_vector 之后，
## _touch_dir 为零向量时与旧行为逐位一致（回归红线）。

## 由外部（Battle）注入：命令行含 `--touch` 时视为有触摸设备。
## 用 setter 是因为注入发生在 _ready 之后（父节点 _ready 晚于子节点）——
## 注入瞬间要立刻重算可见性，否则 `--touch` 启动的桌面端看不到摇杆。
var has_touch_flag := false:
	set(v):
		has_touch_flag = v
		if is_inside_tree():
			visible = _should_show()

var _base: TextureRect
var _knob: TextureRect
## 纹理齐备才允许工作（回落开关）。
var _ok := false
## 当前是否有一根手指按在左半屏上。
var _active := false
## 只跟踪这根手指（InputEvent 的 index）。
var _touch_index := -1
## base 中心在屏幕（CanvasLayer 坐标）上的位置。
var _base_center := Vector2.ZERO
## 当前输出方向（长度 ≤ 1，未触摸为零）。
var _dir := Vector2.ZERO


func _ready() -> void:
	# 暂停约定：本层是玩法 HUD（同 Hud），不设 WHEN_PAUSED ——
	# 商店/升级暂停树时本层跟着停，松开前的方向冻结但玩家物理也停着，不会漂移。
	_base = TextureRect.new()
	_base.texture = AssetDB.ui("joystick_base")
	_base.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_base.visible = false
	add_child(_base)

	_knob = TextureRect.new()
	_knob.texture = AssetDB.ui("joystick_knob")
	_knob.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_knob.visible = false
	add_child(_knob)

	# 尺寸：base 直径 = 2 × 最大偏移，保证 knob 拉满时仍落在 base 内；
	# knob 按 base 的比例缩小（触摸点即 knob 中心，视觉跟手）。
	_base.size = Vector2.ONE * (GameStats.TOUCH_MAX_RADIUS * 2.0)
	_knob.size = _base.size * 0.35

	# 纹理缺失 → 整块自禁用（不报错不刷屏），游戏保持纯键盘可玩。
	_ok = _base.texture != null and _knob.texture != null
	if not _ok:
		set_process_input(false)
		visible = false
		return
	visible = _should_show()


## 显示条件：设备真有触摸屏，或外部注入了 --touch 旗标（桌面调试）。
func _should_show() -> bool:
	return _ok and (DisplayServer.is_touchscreen_available() or has_touch_flag)


func _input(event: InputEvent) -> void:
	if not _ok or not visible:
		return
	if event is InputEventScreenTouch:
		var t := event as InputEventScreenTouch
		if t.pressed:
			# 已有手指在手，忽略后来者（单指摇杆）
			if _active:
				return
			# 浮动摇杆只在【左半边】首次按下时出现
			if t.position.x >= GameStats.VIEW_WIDTH * GameStats.TOUCH_LEFT_HALF_RATIO:
				return
			_active = true
			_touch_index = t.index
			_base_center = t.position
			_base.position = _base_center - _base.size * 0.5
			_base.visible = true
			_set_knob_offset(Vector2.ZERO)
		else:
			if not _active or t.index != _touch_index:
				return
			_release()
	elif event is InputEventScreenDrag:
		var d := event as InputEventScreenDrag
		if not _active or d.index != _touch_index:
			return
		var offset := d.position - _base_center
		if offset.length() > GameStats.TOUCH_MAX_RADIUS:
			offset = offset.normalized() * GameStats.TOUCH_MAX_RADIUS
		_set_knob_offset(offset)


## knob 回中、隐藏 base、方向清零（含松手与异常释放两条路径）。
func _release() -> void:
	_active = false
	_touch_index = -1
	_base.visible = false
	_knob.visible = false
	_dir = Vector2.ZERO


## 按 knob 中心 = base 中心 + offset 摆位，并同步输出方向。
func _set_knob_offset(offset: Vector2) -> void:
	_knob.position = _base_center + offset - _knob.size * 0.5
	_knob.visible = true
	_dir = offset / GameStats.TOUCH_MAX_RADIUS


## 当前移动方向：长度 ≤ 1；未触摸时为 Vector2.ZERO。签名固定（探针调用）。
func move_dir() -> Vector2:
	return _dir
