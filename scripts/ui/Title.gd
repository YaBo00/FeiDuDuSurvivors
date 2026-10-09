extends Control
## 标题画面：游戏入口。
##
## UI 用代码搭，和 Hud / UpgradePanel / ResultPanel 的做法保持一致
## （那些也是代码建节点，本工程没有手写 UI 的 .tscn）。

const BATTLE_SCENE := "res://scenes/battle/Battle.tscn"
const CHARSEL_SCENE := "res://scenes/main/CharSelect.tscn"


func _ready() -> void:
	UiFont.install(self, 20)
	GameAudio.apply_volume_settings()   # 先把存档里的音量应用到总线，再起 BGM（2026-09-22 设置菜单）
	GameAudio.play_bgm.call_deferred(get_tree())
	UiTheme.apply(self)
	# 导出包自检入口：导出的 exe 主场景固定是本界面，且【不支持命令行指定场景】，
	# 而 Battle 的自检逻辑在 Battle 里 —— 检测到自检 flag 就跳转到战斗场景，
	# Battle._ready 会读到同一个 flag 并接管（Battle 进程退出码即测试结果）。
	if _route_selftest():
		return
	_build()


## 检测自检/观测 flag 并转发到战斗场景。命中返回 true（本界面不再构建 UI）。
func _route_selftest() -> bool:
	for flag in ["--selftest", "--selftest-defeat", "--balance"]:
		if flag in OS.get_cmdline_args() or flag in OS.get_cmdline_user_args():
			print("[Title] 检测到 %s → 转发到战斗场景执行" % flag)
			get_tree().change_scene_to_file(BATTLE_SCENE)
			return true
	return false


func _build() -> void:
	# 背景：三层视差动态背景（2026-09-22 方案 B，见 docs/标题视差背景接入说明_2026-09-22.md）。
	# 三张贴图缺失 / 未导入时自动回落到原静态背景，保证「没美术也能跑」。
	if not _build_parallax():
		_build_static_bg()

	# 压暗一层，保证按钮和文字看得清
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.35)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(dim)

	# 【2026-09-22 修复内容块偏下 / 溢出】旧写法 `box.set_anchors_preset(PRESET_CENTER)`
	# 只把锚点设到 0.5、offset 仍为 0 ⇒ 容器【左上角】落在屏幕中心、内容整体往下铺，
	# 内容一高（新增「设置」行后）「退出」按钮就被屏幕底边裁掉。改用 CenterContainer：
	# 它让子容器保持最小尺寸并真正居中，任何内容高度都不会溢出。
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(center)

	var box := VBoxContainer.new()
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_theme_constant_override("separation", 18)
	center.add_child(box)

	var title := Label.new()
	title.text = "肥嘟嘟幸存者"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 56)
	title.add_theme_color_override("font_color", Color("#FFD700"))
	box.add_child(title)

	# 局外账本展示（MetaSave 消费端第一片）：玩过至少一局才显示战绩行
	var ledger: Dictionary = MetaSave.ledger()
	if int(ledger["runs"]) > 0:
		var stats := Label.new()
		stats.text = "战绩：最佳 %d 波 · 累计 %d 击杀 · 共 %d 局" % [
			int(ledger["best_wave"]), int(ledger["total_kills"]), int(ledger["runs"])]
		stats.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		stats.add_theme_font_size_override("font_size", 16)
		stats.add_theme_color_override("font_color", Color(0.75, 0.78, 0.88))
		box.add_child(stats)
		# 无尽最佳（2026-09-20 无尽体验）：跑过无尽局才显示，不打扰纯普通局玩家
		if int(ledger["best_endless_wave"]) > 0:
			var inf := Label.new()
			inf.text = "无尽最佳：%d 波" % int(ledger["best_endless_wave"])
			inf.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			inf.add_theme_font_size_override("font_size", 16)
			inf.add_theme_color_override("font_color", Color(0.95, 0.80, 0.40))
			box.add_child(inf)

	box.add_child(_spacer(24))

	var start := _make_button("开始游戏", 30)
	start.pressed.connect(_on_start)
	box.add_child(start)

	# 每日挑战（2026-10-09 meta 2.0 第二批）：解锁 unlock_daily 后可用 ——
	# 每天固定随机种子 + 普通难度，直接进选人（跳过难度层），冲击当日最佳。
	# 未解锁时按钮灰化（自解释：去局外强化的解锁网络购买）。
	var daily_btn := _make_button("每日挑战", 22)
	if MetaSave.is_meta_unlocked("unlock_daily"):
		var db := MetaSave.daily_best()
		if db > 0:
			daily_btn.text = "每日挑战（当日最佳 %d 波）" % db
		daily_btn.pressed.connect(_pick_daily)
	else:
		daily_btn.disabled = true
		daily_btn.text = "每日挑战（未解锁）"
	box.add_child(daily_btn)

	# 次级入口并排一行：局外强化（MetaSave 消费端第二片）/ 成就（2026-10-08）/ 图鉴（2026-09-22）
	# / 设置（2026-09-22）。四个按钮 220 宽 + 3×16 间距 = 928px，在 1280 宽的窗口里仍居中留白充足。
	var sub_row := HBoxContainer.new()
	sub_row.alignment = BoxContainer.ALIGNMENT_CENTER
	sub_row.add_theme_constant_override("separation", 16)
	box.add_child(sub_row)

	var meta_btn := _make_button("局外强化", 22)
	meta_btn.custom_minimum_size = Vector2(220, 48)
	meta_btn.pressed.connect(_open_meta_shop)
	sub_row.add_child(meta_btn)

	# 成就 / 战绩（2026-10-08）：只读展示局外账本推导的成就解锁状态 + 全局战绩，不消耗资源。
	var ach_btn := _make_button("成就", 22)
	ach_btn.custom_minimum_size = Vector2(220, 48)
	ach_btn.pressed.connect(_open_achievements)
	sub_row.add_child(ach_btn)

	# 敌人图鉴（2026-09-22，需求《敌人图鉴_给代码AI_2026-09-22.md》）：
	# 只读展示局外账本里的「击杀过哪些怪 / 各杀了多少」，不消耗任何资源。
	var codex_btn := _make_button("图鉴", 22)
	codex_btn.custom_minimum_size = Vector2(220, 48)
	codex_btn.pressed.connect(_open_codex)
	sub_row.add_child(codex_btn)

	var settings_btn := _make_button("设置", 22)
	settings_btn.custom_minimum_size = Vector2(220, 48)
	settings_btn.pressed.connect(_open_settings)
	sub_row.add_child(settings_btn)

	var quit := _make_button("退出", 22)
	quit.pressed.connect(func(): get_tree().quit(0))
	box.add_child(quit)

	start.grab_focus()


# ------------------------------------------------- 标题三层视差背景（2026-09-22 方案 B）
## 天空 / 袋鼠群横向滚动（速度不同），嘉豪 + 草地前景固定并做轻微「呼吸」缩放。
## 设计文档：docs/标题视差背景接入说明_2026-09-22.md。
##
## 落地时对文档给的「示意值」做了三处修正（文档的假设与 Godot 实际语义不同）：
##   ① motion_mirroring 取【子 Sprite2D 的显示宽度】而非固定的 1920：
##      Godot 的 ParallaxLayer 是「重复」而非「镜像翻折」—— 官方文档原话
##      "the texture will not be mirrored, it will simply be repeated"。
##      源图 3840 = 1920 原图 + 1920 镜像，本身是关于 3840 的周期图元，
##      故重复周期必须取整幅纹理的显示宽度（3840 × 覆盖缩放）才无缝。
##   ② 呼吸缩放作用在【FrontLayer 的子 Sprite2D】，不是 FrontLayer 本身：
##      ParallaxLayer 入树后其 position/scale 每帧被引擎覆盖（官方文档
##      "changes to this node's position and scale made after it enters the scene
##      will be ignored"），直接缩放图层无效。
##   ③ 背景 CanvasLayer 的 layer 设为 -1：ParallaxBackground 是 CanvasLayer，
##      默认 layer=1 会盖在标题 UI（默认画布 layer 0）之上 ⇒ 必须压到 UI 之下。
##
## 缩放：按当前画布做「覆盖式（cover）」，等价静态背景的 KEEP_ASPECT_COVERED ——
## canvas_items/expand 下画布会随窗口比例变宽变高，覆盖式保证任何比例都铺满不露底。
var _parallax_root: ParallaxBackground = null
var _sky_sprite: Sprite2D = null
var _mid_sprite: Sprite2D = null
var _front_sprite: Sprite2D = null
var _sky_layer: ParallaxLayer = null
var _mid_layer: ParallaxLayer = null
## 三层配置：[图层名, AssetDB.PARALLAX 键, 滚动速度系数(=文档 motion_scale), 是否横向重复]
const PARALLAX_LAYERS := [
	["SkyLayer", "sky", 0.3, true],
	["MidLayer", "mid", 0.6, true],
	["FrontLayer", "front", 0.0, false],
]
## 单幅画面尺寸：纹理宽 = 它的 2 倍（右半是左半的水平镜像）。源图 3840×1080。
const PARALLAX_ART := Vector2(1920.0, 1080.0)
## scroll_offset 递增速度（px/s）：sky 实际 = ×0.3、mid 实际 = ×0.6。文档 §四，可调。
const PARALLAX_SCROLL_SPEED := 100.0
## 前景呼吸：周期 4s（与无缝循环节奏一致）、幅度 ±1.5%。文档 §四。
const PARALLAX_BREATH_PERIOD := 4.0
const PARALLAX_BREATH_AMPLITUDE := 0.015
## 当前覆盖缩放（_layout_parallax 算出，呼吸缩放复用）。
var _parallax_scale := 1.0
var _breath_t := 0.0
## 上一次布局用的画布尺寸；_process 里发现变化就重排（首帧尺寸才定下来 / 窗口拉伸）。
var _last_canvas := Vector2.ZERO


## 构建三层视差背景。任一贴图缺失（未导入）返回 false —— 调用方回落静态图。
func _build_parallax() -> bool:
	var texs := {
		"sky": AssetDB.parallax_bg("sky"),
		"mid": AssetDB.parallax_bg("mid"),
		"front": AssetDB.parallax_bg("front"),
	}
	for k in texs:
		if texs[k] == null:
			return false

	var pb := ParallaxBackground.new()
	pb.name = "TitleParallax"
	pb.layer = -1        # 见函数头 ③：压到标题 UI 之下
	add_child(pb)
	_parallax_root = pb

	for cfg in PARALLAX_LAYERS:
		var layer := ParallaxLayer.new()
		layer.name = String(cfg[0])
		layer.motion_scale = Vector2(float(cfg[2]), 0.0)
		pb.add_child(layer)

		var spr := Sprite2D.new()
		spr.name = "Sprite2D"
		spr.texture = texs[cfg[1]]
		spr.centered = false
		if bool(cfg[3]):
			spr.texture_repeat = CanvasItem.TEXTURE_REPEAT_ENABLED
		else:
			spr.texture_repeat = CanvasItem.TEXTURE_REPEAT_DISABLED
		layer.add_child(spr)

		match String(cfg[1]):
			"sky":
				_sky_layer = layer
				_sky_sprite = spr
			"mid":
				_mid_layer = layer
				_mid_sprite = spr
			"front":
				_front_sprite = spr

	_layout_parallax()
	return true


## 回落：原静态背景大图（1920×1080 有损 WebP，COVERED 铺满）。
func _build_static_bg() -> void:
	var bg := TextureRect.new()
	bg.texture = AssetDB.bg("title")
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	bg.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)


## 按当前画布尺寸重算「覆盖式」缩放、居中位移与无缝重复周期。
## 画布 = 本 Control 的矩形（canvas_items/expand 下随窗口比例变化）。
func _layout_parallax() -> void:
	if _parallax_root == null:
		return
	var canvas := size
	if canvas.x <= 0.0 or canvas.y <= 0.0:
		return
	# cover：取较大比例，保证 1920×1080 画面铺满画布（等价 KEEP_ASPECT_COVERED）
	_parallax_scale = maxf(canvas.x / PARALLAX_ART.x, canvas.y / PARALLAX_ART.y)
	var s := _parallax_scale
	var tile := PARALLAX_ART.x * 2.0 * s      # 整幅纹理显示宽 = 无缝重复周期
	var y_off := (canvas.y - PARALLAX_ART.y * s) * 0.5
	# sky / mid：x 与重复画布左缘(0)对齐，横向靠 repeat 无限铺满；纵向居中。
	if _sky_sprite != null:
		_sky_sprite.scale = Vector2(s, s)
		_sky_sprite.position = Vector2(0.0, y_off)
	if _mid_sprite != null:
		_mid_sprite.scale = Vector2(s, s)
		_mid_sprite.position = Vector2(0.0, y_off)
	if _sky_layer != null:
		_sky_layer.motion_mirroring = Vector2(tile, 0.0)
	if _mid_layer != null:
		_mid_layer.motion_mirroring = Vector2(tile, 0.0)
	_apply_breath()
	_last_canvas = canvas


## 前景「呼吸」：以原图中心为基准做 ±1.5% 缩放（不位移、不穿帮）。
## 改 Sprite2D 的 scale 并同步补偿 position —— 见函数头 ②（缩放图层本身会被引擎忽略）。
func _apply_breath() -> void:
	if _front_sprite == null:
		return
	var sc := _parallax_scale * (1.0 + PARALLAX_BREATH_AMPLITUDE \
		* sin(TAU * _breath_t / PARALLAX_BREATH_PERIOD))
	_front_sprite.scale = Vector2(sc, sc)
	# centered=false ⇒ position 是纹理左上角；让「原图中心」恒落在画布中心。
	_front_sprite.position = Vector2(
		size.x * 0.5 - PARALLAX_ART.x * 0.5 * sc,
		size.y * 0.5 - PARALLAX_ART.y * 0.5 * sc)


## 驱动滚动 + 呼吸（并在画布尺寸变化时重排）。
## Godot 的 ParallaxBackground 只在相机移动时产生视差，标题场景相机静止
## ⇒ 必须手动递增 scroll_offset（文档 §四）。
func _process(delta: float) -> void:
	if _parallax_root == null:
		return
	if size != _last_canvas:      # 首帧画布尺寸才定下来 / 窗口拉伸
		_layout_parallax()
	_parallax_root.scroll_offset.x += PARALLAX_SCROLL_SPEED * delta
	_breath_t += delta
	_apply_breath()


# ---------------------------------------------------------------- 局外强化商店
## 商店遮罩层（非 null = 开着）。面板内容购买后整体重建（数量小，简单可靠）。
var _shop_layer: ColorRect = null


func _open_meta_shop() -> void:
	if _shop_layer != null:
		return
	_shop_layer = ColorRect.new()
	_shop_layer.color = Color(0, 0, 0, 0.62)
	_shop_layer.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_shop_layer)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	_shop_layer.add_child(center)

	var panel := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.10, 0.11, 0.16, 0.97)
	sb.border_color = Color(0.42, 0.46, 0.68)
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(10)
	sb.content_margin_left = 28.0
	sb.content_margin_right = 28.0
	sb.content_margin_top = 22.0
	sb.content_margin_bottom = 22.0
	panel.add_theme_stylebox_override("panel", sb)
	center.add_child(panel)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 10)
	panel.add_child(box)
	_rebuild_shop(box)


## 重建商店内容：标题 / xp 行 / 【两列网格】每条强化一格 / 关闭。
##
## 【2026-09-22 布局改造：3 条 → 9 条】旧版是单列 9 行 = 头部 60 + 9×50 + 关闭 40 + 内边距 ≈ 620px，
## 在 720 高的窗口里几乎顶满、再窄一点就被裁。改成 GridContainer(2 列)：5 行 ≈ 280px，
## 面板高度砍半且**条目数继续涨也不会溢出**（加到 12 条仍是 6 行）。
## 每格 = 「名称 + 等级进度点 + 效果说明」（左） + 购买按钮（右）。
func _rebuild_shop(box: VBoxContainer) -> void:
	for c in box.get_children():
		box.remove_child(c)
		c.queue_free()
	var d: Dictionary = MetaSave.ledger()

	var title := Label.new()
	title.text = "局外强化"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 30)
	title.add_theme_color_override("font_color", Color("#FFD700"))
	box.add_child(title)

	var xp := Label.new()
	xp.text = "强化点数 %d XP（每局结算自动折算）" % int(d["meta_xp"])
	xp.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	xp.add_theme_font_size_override("font_size", 17)
	xp.add_theme_color_override("font_color", Color(0.78, 0.82, 0.95))
	box.add_child(xp)

	box.add_child(_spacer(4))

	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 20)
	grid.add_theme_constant_override("v_separation", 8)
	box.add_child(grid)
	# 自动遍历 META_UPGRADES 渲染（条数由 MetaSave 表决定，本界面不硬编码任何一条）
	for u in MetaSave.META_UPGRADES:
		grid.add_child(_meta_shop_cell(u, d, box))

	# 解锁网络（2026-10-09 meta 2.0）：一次性购买的「功能解锁」区 —— 与强化同货币、
	# 同款自动遍历渲染（加解锁条目不用动 UI 代码）。买一次永久生效、不设叠层。
	box.add_child(_spacer(6))
	var unl_title := Label.new()
	unl_title.text = "解锁网络"
	unl_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	unl_title.add_theme_font_size_override("font_size", 22)
	unl_title.add_theme_color_override("font_color", Color(0.80, 0.64, 0.98))
	box.add_child(unl_title)

	var ugrid := GridContainer.new()
	ugrid.columns = 2
	ugrid.add_theme_constant_override("h_separation", 20)
	ugrid.add_theme_constant_override("v_separation", 8)
	box.add_child(ugrid)
	for u in MetaSave.META_UNLOCKS:
		ugrid.add_child(_meta_unlock_cell(u, d, box))

	box.add_child(_spacer(4))
	var close := Button.new()
	close.text = "关闭（Esc）"
	close.custom_minimum_size = Vector2(180, 40)
	close.add_theme_font_size_override("font_size", 17)
	close.pressed.connect(_close_meta_shop)
	box.add_child(close)


## 一格强化：左列（名称 + 等级点 + 效果说明） + 右列（购买/已满级按钮）。
## 购买成功后整体重建（`_rebuild_shop(box)`）—— 条目少，重建比逐格刷新简单可靠。
func _meta_shop_cell(u: Dictionary, d: Dictionary, box: VBoxContainer) -> Control:
	var id := String(u["id"])
	var lvl := maxi(0, int(d["meta_levels"].get(id, 0)))
	var maxl := int(u["max_level"])

	var cell := HBoxContainer.new()
	cell.add_theme_constant_override("separation", 10)

	var info := VBoxContainer.new()
	info.add_theme_constant_override("separation", 2)
	info.custom_minimum_size = Vector2(268, 0)
	cell.add_child(info)

	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 8)
	var name_lbl := Label.new()
	name_lbl.text = "%s  Lv.%d/%d" % [String(u["name"]), lvl, maxl]
	name_lbl.add_theme_font_size_override("font_size", 17)
	# 满级 = 金字（已吃满收益），可继续买 = 白字，未解锁 = 常规
	name_lbl.add_theme_color_override("font_color",
		Color("#FFD700") if lvl >= maxl else Color(0.90, 0.92, 0.98))
	head.add_child(name_lbl)
	head.add_child(_level_pips(lvl, maxl))
	info.add_child(head)

	var desc := Label.new()
	desc.text = String(u["desc"])
	desc.add_theme_font_size_override("font_size", 13)
	desc.add_theme_color_override("font_color", Color(0.62, 0.67, 0.80))
	info.add_child(desc)

	var buy := Button.new()
	buy.custom_minimum_size = Vector2(160, 40)
	buy.add_theme_font_size_override("font_size", 15)
	if lvl >= maxl:
		buy.text = "已满级"
		buy.disabled = true
	else:
		var price := MetaSave.upgrade_cost(id, lvl)
		buy.text = "购买 %d XP" % price
		buy.disabled = int(d["meta_xp"]) < price
		buy.pressed.connect(func():
			if MetaSave.purchase(id):
				_rebuild_shop(box))
	cell.add_child(buy)
	return cell


## 等级进度点：每级一个方块，已买 = 金色，未买 = 暗灰。max_level=1 时就是一个点
##（复活契约这类一次性大件），比「Lv.0/1」的文字更直观。
func _level_pips(lvl: int, maxl: int) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 3)
	for i in maxl:
		var pip := ColorRect.new()
		pip.custom_minimum_size = Vector2(9, 13)
		pip.color = Color("#FFD700") if i < lvl else Color(0.26, 0.29, 0.38)
		row.add_child(pip)
	return row


## 一格解锁（2026-10-09 meta 2.0）：名称 + 效果说明 + 解锁按钮 / 「已解锁」状态。
## 样式与 _meta_shop_cell 同构（左信息右按钮），购买成功同样整体重建。
func _meta_unlock_cell(u: Dictionary, d: Dictionary, box: VBoxContainer) -> Control:
	var id := String(u["id"])
	var unlocked := (d[MetaSave.UNLOCKS_META_KEY] as Array).has(id)

	var cell := HBoxContainer.new()
	cell.add_theme_constant_override("separation", 10)

	# 图标（2026-10-09 美术入库）：48px；缺图自动跳过、不占位（绝不画白块）。
	var ic_tex := AssetDB.unlock_icon(id)
	if ic_tex != null:
		var ic := TextureRect.new()
		ic.texture = ic_tex
		ic.custom_minimum_size = Vector2(48, 48)
		ic.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		ic.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		ic.mouse_filter = Control.MOUSE_FILTER_IGNORE
		cell.add_child(ic)

	var info := VBoxContainer.new()
	info.add_theme_constant_override("separation", 2)
	info.custom_minimum_size = Vector2(268, 0)
	cell.add_child(info)

	var name_lbl := Label.new()
	name_lbl.text = String(u["name"])
	name_lbl.add_theme_font_size_override("font_size", 17)
	# 已解锁 = 金字（与满级强化同款「已到手」色）
	name_lbl.add_theme_color_override("font_color",
		Color("#FFD700") if unlocked else Color(0.90, 0.92, 0.98))
	info.add_child(name_lbl)

	var desc := Label.new()
	desc.text = String(u["desc"])
	desc.add_theme_font_size_override("font_size", 13)
	desc.add_theme_color_override("font_color", Color(0.62, 0.67, 0.80))
	info.add_child(desc)

	var buy := Button.new()
	buy.custom_minimum_size = Vector2(160, 40)
	buy.add_theme_font_size_override("font_size", 15)
	if unlocked:
		buy.text = "已解锁"
		buy.disabled = true
	else:
		var price := int(u["cost"])
		buy.text = "解锁 %d XP" % price
		buy.disabled = int(d["meta_xp"]) < price
		buy.pressed.connect(func():
			if MetaSave.purchase_unlock(id):
				_rebuild_shop(box))
	cell.add_child(buy)
	return cell


func _close_meta_shop() -> void:
	if _shop_layer != null:
		_shop_layer.queue_free()
		_shop_layer = null


# ---------------------------------------------------------------- 设置菜单（2026-09-22）
## 设置遮罩层（非 null = 开着）。内容复用现有弹窗样式（半透明黑底 + 面板 + 金字标题）。
## 数据全部进出 MetaSave.settings：滑块 change 即写（无需单独的「保存」按钮），
## 音量在本界面【实时】应用（GameAudio.apply_volume_settings）。
var _settings_layer: ColorRect = null


func _open_settings() -> void:
	if _settings_layer != null:
		return
	_settings_layer = ColorRect.new()
	_settings_layer.color = Color(0, 0, 0, 0.62)
	_settings_layer.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_settings_layer)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	_settings_layer.add_child(center)

	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", _panel_stylebox(28.0))
	center.add_child(panel)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 18)
	panel.add_child(box)

	var title := Label.new()
	title.text = "设置"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 32)
	title.add_theme_color_override("font_color", Color("#FFD700"))
	box.add_child(title)

	box.add_child(_spacer(4))
	_audio_setting_row(box, "音乐音量", "music_vol")
	_audio_setting_row(box, "音效音量", "sfx_vol")
	box.add_child(_spacer(4))
	_toggle_setting_row(box, "伤害数字", "show_floats")
	_toggle_setting_row(box, "屏幕震动", "screen_shake")

	box.add_child(_spacer(6))
	var back := Button.new()
	back.text = "返回（Esc）"
	back.custom_minimum_size = Vector2(220, 52)
	back.add_theme_font_size_override("font_size", 18)
	back.pressed.connect(_close_settings)
	box.add_child(back)


## 音量行：名称 + 滑块(0~1) + 百分比。拖动即写档并【实时】应用到音频总线。
## 2026-10-08：行构建抽到 SettingRows（与战斗内暂停设置共用），此处只做转发。
func _audio_setting_row(box: VBoxContainer, label_text: String, key: String) -> void:
	SettingRows.audio_row(box, label_text, key)


## 开关行：带文字的 CheckBox，勾选即写档。2026-10-08：转发到 SettingRows（同暂停设置共用）。
func _toggle_setting_row(box: VBoxContainer, label_text: String, key: String) -> void:
	SettingRows.toggle_row(box, label_text, key)


func _close_settings() -> void:
	if _settings_layer != null:
		_settings_layer.queue_free()
		_settings_layer = null


# ---------------------------------------------------------------- 敌人图鉴（2026-09-22）
## 图鉴遮罩层（非 null = 开着）。数据全部来自 MetaSave.codex_state()（跨局持久化），
## 本界面【只读】—— 标题画面杀不了怪，开着的期间数据不可能变，所以状态缓存一次即可。
var _codex_layer: ColorRect = null
## 详情区容器（PanelContainer）。点击已解锁格子时整体重建内容。
var _codex_detail: PanelContainer = null
## 本次打开时读到的图鉴状态 {id: {"seen": bool, "kills": int}}（13 条只读一次档）。
var _codex_states: Dictionary = {}
## 图鉴网格列数：14 只怪 = 4 列 × 4 行（末行 2 只），一屏放下，不需要滚动。
const CODEX_COLUMNS := 4
## 格子里的图标显示边长（素材画布是 256×256，等比缩到 64 ⇒ 内容高度约 42~64px）。
const CODEX_ICON_PX := 64


func _open_codex() -> void:
	if _codex_layer != null:
		return
	_codex_states = MetaSave.codex_state()

	_codex_layer = ColorRect.new()
	_codex_layer.color = Color(0, 0, 0, 0.66)
	_codex_layer.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_codex_layer)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	_codex_layer.add_child(center)

	var panel := PanelContainer.new()
	# 上下内边距单独收紧到 14（默认 22）：图鉴是 4 行网格，是标题页里最高的弹窗，
	# 省下的 16px 正好把它压在 720 高的窗口内（详见下方布局高度账）。
	var sb := _panel_stylebox(26.0)
	sb.content_margin_top = 14.0
	sb.content_margin_bottom = 14.0
	panel.add_theme_stylebox_override("panel", sb)
	center.add_child(panel)

	# 【高度账】标题 40 + 网格 426 + 详情 112 + 返回 44 + 子项间距 3×8 + 面板内边距 28 ≈ 674px
	# （窗口 720）。任何一个数字变大都要重新算这笔账，否则「返回」按钮会被屏幕裁掉。
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	panel.add_child(box)

	var title := Label.new()
	title.text = "敌人图鉴"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 28)
	title.add_theme_color_override("font_color", Color("#FFD700"))
	box.add_child(title)

	var grid := GridContainer.new()
	grid.columns = CODEX_COLUMNS
	grid.add_theme_constant_override("h_separation", 8)
	grid.add_theme_constant_override("v_separation", 6)
	box.add_child(grid)
	# 顺序 = GameStats.CODEX_ORDER（= 玩家应该遇到的顺序），界面不硬编码任何敌人 id
	for id in GameStats.CODEX_ORDER:
		grid.add_child(_codex_cell(String(id)))

	# 详情区固定高度（未选中时显示操作提示）——不做滚动、不弹二级面板
	_codex_detail = PanelContainer.new()
	_codex_detail.custom_minimum_size = Vector2(0, 112)
	_codex_detail.add_theme_stylebox_override("panel", _codex_detail_stylebox())
	box.add_child(_codex_detail)
	_show_codex_detail("")     # 初始态：提示文字

	var back := Button.new()
	back.text = "返回（Esc）"
	back.custom_minimum_size = Vector2(220, 44)
	back.add_theme_font_size_override("font_size", 17)
	back.pressed.connect(_close_codex)
	box.add_child(back)


## 一个图鉴格子：图标 + 名字 + 击杀数；已解锁可点（看详情），未解锁整格禁用 + 灰显。
## 用 Button 当卡片底板（自带 hover/pressed/disabled 三态皮肤），内部 VBox 设 IGNORE
## 让点击穿透到按钮本身。
func _codex_cell(id: String) -> Control:
	var st: Dictionary = _codex_states.get(id, {})
	var seen := bool(st.get("seen", false))

	var btn := Button.new()
	btn.text = ""
	btn.custom_minimum_size = Vector2(104, 102)
	btn.disabled = not seen          # 没见过的格子点不动（需求 §3 只要求已见格子弹详情）
	if seen:
		btn.pressed.connect(_show_codex_detail.bind(id))

	var v := VBoxContainer.new()
	v.set_anchors_preset(Control.PRESET_FULL_RECT)
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.alignment = BoxContainer.ALIGNMENT_CENTER
	v.add_theme_constant_override("separation", 2)
	btn.add_child(v)

	var icon := TextureRect.new()
	icon.texture = AssetDB.enemy_sprite(id)
	icon.custom_minimum_size = Vector2(CODEX_ICON_PX, CODEX_ICON_PX)
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if not seen:
		# 灰色剪影：只调 modulate，不换贴图（需求 §1「不需要新美术」）
		icon.modulate = Color(0.3, 0.3, 0.3, 1.0)
	v.add_child(icon)

	var name_lbl := Label.new()
	name_lbl.text = GameStats.codex_name(id) if seen else "???"
	name_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_lbl.add_theme_font_size_override("font_size", 13)
	name_lbl.add_theme_color_override("font_color",
		Color(0.92, 0.94, 0.99) if seen else Color(0.55, 0.58, 0.66))
	v.add_child(name_lbl)

	var kills_lbl := Label.new()
	if seen:
		kills_lbl.text = "×%d" % int(st.get("kills", 0))
	else:
		kills_lbl.text = ""
	kills_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	kills_lbl.add_theme_font_size_override("font_size", 12)
	kills_lbl.add_theme_color_override("font_color", Color(0.95, 0.80, 0.40))
	v.add_child(kills_lbl)
	return btn


## 重建详情区。空 id 或未解锁 → 显示操作提示（不会出现「??? 的详情」这种半成品）。
func _show_codex_detail(id: String) -> void:
	if _codex_detail == null:
		return
	for c in _codex_detail.get_children():
		_codex_detail.remove_child(c)
		c.queue_free()

	var st: Dictionary = _codex_states.get(id, {})
	var seen := id != "" and bool(st.get("seen", false))
	if not seen:
		var tip := Label.new()
		tip.text = "点击已解锁的敌人查看详情"
		tip.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		tip.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		tip.add_theme_font_size_override("font_size", 15)
		tip.add_theme_color_override("font_color", Color(0.58, 0.62, 0.74))
		_codex_detail.add_child(tip)
		return

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 16)
	_codex_detail.add_child(row)

	var big := TextureRect.new()
	big.texture = AssetDB.enemy_sprite(id)
	big.custom_minimum_size = Vector2(88, 88)
	big.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	big.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	row.add_child(big)

	var info := VBoxContainer.new()
	info.add_theme_constant_override("separation", 4)
	info.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(info)

	var name_lbl := Label.new()
	name_lbl.text = GameStats.codex_name(id)
	name_lbl.add_theme_font_size_override("font_size", 20)
	name_lbl.add_theme_color_override("font_color", Color("#FFD700"))
	info.add_child(name_lbl)

	# 描述必须定宽：Label 在 HBox 里若不限宽会按最长行撑开面板（中文长句尤其明显）
	var desc := Label.new()
	desc.text = GameStats.codex_desc(id)
	desc.custom_minimum_size = Vector2(300, 0)
	desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	desc.add_theme_font_size_override("font_size", 14)
	desc.add_theme_color_override("font_color", Color(0.80, 0.84, 0.95))
	info.add_child(desc)

	var kills_lbl := Label.new()
	kills_lbl.text = "累计击杀 %d" % int(st.get("kills", 0))
	kills_lbl.add_theme_font_size_override("font_size", 14)
	kills_lbl.add_theme_color_override("font_color", Color(0.95, 0.80, 0.40))
	info.add_child(kills_lbl)


## 详情区内层样式：比主面板再暗一档、无描边的「凹槽」观感（与主面板区分层级）。
func _codex_detail_stylebox() -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.06, 0.07, 0.11, 0.85)
	sb.set_corner_radius_all(8)
	sb.content_margin_left = 16.0
	sb.content_margin_right = 16.0
	sb.content_margin_top = 12.0
	sb.content_margin_bottom = 12.0
	return sb


func _close_codex() -> void:
	if _codex_layer != null:
		_codex_layer.queue_free()
		_codex_layer = null
	_codex_detail = null
	_codex_states.clear()


# ---------------------------------------------------------------- 成就 / 战绩（2026-10-08 玩法增补批次）
## 成就遮罩层（非 null = 开着）。数据 = MetaSave 账本 + 成就表（只读）——
## 打开期间数据不可能变（标题画面杀不了怪），一次读档缓存到局部即可。
var _ach_layer: ColorRect = null
## 成就网格列数：11 条 = 2 列 × 6 行（高度账：标题 40 + 战绩行 22 + 网格 6×52 + 返回 44
## + 间距/内边距 ≈ 480px，720 高窗口放得下，不需要滚动）。
const ACH_COLUMNS := 2


func _open_achievements() -> void:
	if _ach_layer != null:
		return
	# 一次读档（achievement_unlocked 每次都走 ledger() 文件 IO —— 11 条 × N 次太浪费）。
	var d: Dictionary = MetaSave.ledger()
	var unlocked_arr: Array = d["achievements"]
	var unlocked := 0
	for a in MetaSave.ACHIEVEMENTS:
		if unlocked_arr.has(String(a["id"])):
			unlocked += 1

	_ach_layer = ColorRect.new()
	_ach_layer.color = Color(0, 0, 0, 0.66)
	_ach_layer.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_ach_layer)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	_ach_layer.add_child(center)

	var panel := PanelContainer.new()
	var sb := _panel_stylebox(26.0)
	sb.content_margin_top = 14.0
	sb.content_margin_bottom = 14.0
	panel.add_theme_stylebox_override("panel", sb)
	center.add_child(panel)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	panel.add_child(box)

	var title := Label.new()
	title.text = "成就 · %d/%d" % [unlocked, MetaSave.ACHIEVEMENTS.size()]
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 28)
	title.add_theme_color_override("font_color", Color("#FFD700"))
	box.add_child(title)

	# 战绩行：与标题页战绩行同源（同一本账），这里给全量（含胜场/无尽/强化点数）。
	var stats := Label.new()
	stats.text = "共 %d 局 · 胜 %d · 累计击杀 %d · 累计金币 %d · 最佳 %d 波 · 无尽最佳 %d 波 · 强化点数 %d" % [
		int(d["runs"]), int(d["wins"]), int(d["total_kills"]), int(d["total_gold"]),
		int(d["best_wave"]), int(d["best_endless_wave"]), int(d["meta_xp"])]
	stats.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	stats.add_theme_font_size_override("font_size", 15)
	stats.add_theme_color_override("font_color", Color(0.75, 0.78, 0.88))
	box.add_child(stats)

	var grid := GridContainer.new()
	grid.columns = ACH_COLUMNS
	grid.add_theme_constant_override("h_separation", 14)
	grid.add_theme_constant_override("v_separation", 6)
	box.add_child(grid)
	for a in MetaSave.ACHIEVEMENTS:
		grid.add_child(_ach_cell(a, unlocked_arr.has(String(a["id"]))))

	var back := Button.new()
	back.text = "返回（Esc）"
	back.custom_minimum_size = Vector2(220, 44)
	back.add_theme_font_size_override("font_size", 17)
	back.pressed.connect(_close_achievements)
	box.add_child(back)


## 一格成就：名称 + 奖励 XP（已解锁金字/未解锁灰字）+ 描述。done 由调用方传入
## （批读取档，格内不再碰 MetaSave —— 防 11 次文件 IO）。
func _ach_cell(a: Dictionary, done: bool) -> Control:
	var cell := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.15, 0.13, 0.06, 0.9) if done else Color(0.08, 0.09, 0.13, 0.8)
	sb.set_corner_radius_all(8)
	sb.content_margin_left = 12.0
	sb.content_margin_right = 12.0
	sb.content_margin_top = 8.0
	sb.content_margin_bottom = 8.0
	cell.add_theme_stylebox_override("panel", sb)

	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 2)
	cell.add_child(v)

	var head := Label.new()
	head.text = "%s　+%d XP" % [String(a["name"]), int(a["xp"])]
	head.add_theme_font_size_override("font_size", 17)
	head.add_theme_color_override("font_color",
		Color("#FFD700") if done else Color(0.55, 0.58, 0.68))
	v.add_child(head)

	var desc := Label.new()
	desc.text = String(a["desc"])
	desc.add_theme_font_size_override("font_size", 13)
	desc.add_theme_color_override("font_color",
		Color(0.82, 0.84, 0.92) if done else Color(0.45, 0.48, 0.56))
	v.add_child(desc)
	return cell


func _close_achievements() -> void:
	if _ach_layer != null:
		_ach_layer.queue_free()
		_ach_layer = null


## 弹窗面板统一样式（局外强化 / 难度选择 / 设置三处同款：半透明深底 + 描边 + 圆角）。
func _panel_stylebox(margin: float = 28.0) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.10, 0.11, 0.16, 0.97)
	sb.border_color = Color(0.42, 0.46, 0.68)
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(10)
	sb.content_margin_left = margin
	sb.content_margin_right = margin
	sb.content_margin_top = 22.0
	sb.content_margin_bottom = 22.0
	return sb


func _spacer(h: int) -> Control:
	var c := Control.new()
	c.custom_minimum_size = Vector2(0, h)
	return c


func _make_button(text: String, size: int) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(300, 62)
	b.add_theme_font_size_override("font_size", size)
	return b


func _on_start() -> void:
	_open_difficulty_select()


# ---------------------------------------------------------------- 难度选择（2026-09-20）
## 难度选择遮罩层（非 null = 开着）。点「开始游戏」先选难度，再进选人。
## 选择写入 GameSession.difficulty（权威数据源），随后走原选人/开局流程。
var _diff_layer: ColorRect = null
## 诅咒选择子层（2026-10-08 第二梯队；由难度层进入；非 null = 开着）。
var _curse_layer: ColorRect = null
## 难度层上的「诅咒」入口按钮（文案随勾选实时刷新）。
var _curse_entry_btn: Button = null
## 诅咒子层的按钮表（与 _curse_ids 平行；刷新选中/禁用态用）。
var _curse_btns: Array[Button] = []
var _curse_ids: Array[String] = []
## 起始武器子层（2026-10-09 meta 2.0 第二批·武器自由；仅解锁后入口可见）。
## _weapon_btns[0] = 「默认」，其余与 GameStats.WEAPON_DEFS.keys() 顺序一一对应。
var _weapon_layer: ColorRect = null
var _weapon_entry_btn: Button = null
var _weapon_btns: Array[Button] = []


func _open_difficulty_select() -> void:
	if _diff_layer != null:
		return
	_diff_layer = ColorRect.new()
	_diff_layer.color = Color(0, 0, 0, 0.66)
	_diff_layer.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_diff_layer)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	_diff_layer.add_child(center)

	var panel := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.10, 0.11, 0.16, 0.97)
	sb.border_color = Color(0.42, 0.46, 0.68)
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(10)
	sb.content_margin_left = 34.0
	sb.content_margin_right = 34.0
	sb.content_margin_top = 24.0
	sb.content_margin_bottom = 24.0
	panel.add_theme_stylebox_override("panel", sb)
	center.add_child(panel)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 14)
	panel.add_child(box)

	var title := Label.new()
	title.text = "选择模式"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 32)
	title.add_theme_color_override("font_color", Color("#FFD700"))
	box.add_child(title)

	# 难度选项：数据来自 GameStats.DIFFICULTIES（改表即生效，这里不硬编码系数）。
	# 2026-09-20 用户要求：按钮【只显示模式名称】——去掉下面的数值介绍副标题。
	for key in ["normal", "hard"]:
		var def: Dictionary = GameStats.DIFFICULTIES[key]
		var b := Button.new()
		b.text = String(def["name"])
		b.custom_minimum_size = Vector2(420, 86)
		b.add_theme_font_size_override("font_size", 20)
		b.pressed.connect(_pick_difficulty.bind(String(key)))
		box.add_child(b)

	# 无尽模式（2026-09-20 无尽体验）：波次不限、曲线持续爬升、跑到阵亡为止。
	# 数值走普通难度乘区。同样只显示模式名（历史最佳纪录改在标题页展示）。
	var endless_btn := Button.new()
	endless_btn.text = "无尽模式"
	endless_btn.custom_minimum_size = Vector2(420, 86)
	endless_btn.add_theme_font_size_override("font_size", 20)
	endless_btn.pressed.connect(_pick_endless)
	box.add_child(endless_btn)

	# 诅咒入口（2026-10-08 第二梯队）：自选难度换成长加速 —— 点开子层勾选，
	# 选择实时存 GameSession.curses（本层不关闭，返回后文案同步刷新）。
	_curse_entry_btn = Button.new()
	_curse_entry_btn.text = _curse_entry_text()
	_curse_entry_btn.custom_minimum_size = Vector2(420, 62)
	_curse_entry_btn.add_theme_font_size_override("font_size", 16)
	_curse_entry_btn.pressed.connect(_open_curse_select)
	box.add_child(_curse_entry_btn)

	# 起始武器入口（2026-10-09 meta 2.0 第二批·武器自由）：仅解锁后出现 ——
	# 点开子层单选「默认（角色本命武器）/ 6 把武器任选」，写 GameSession.weapon_pick。
	if MetaSave.is_meta_unlocked("unlock_weapon_free"):
		_weapon_entry_btn = Button.new()
		_weapon_entry_btn.text = _weapon_entry_text()
		_weapon_entry_btn.custom_minimum_size = Vector2(420, 62)
		_weapon_entry_btn.add_theme_font_size_override("font_size", 16)
		_weapon_entry_btn.pressed.connect(_open_weapon_select)
		box.add_child(_weapon_entry_btn)

	var cancel := Button.new()
	cancel.text = "取消（Esc）"
	cancel.custom_minimum_size = Vector2(220, 56)
	cancel.add_theme_font_size_override("font_size", 16)
	cancel.pressed.connect(_close_difficulty_select)
	box.add_child(cancel)


func _pick_difficulty(key: String) -> void:
	if not GameStats.DIFFICULTIES.has(key):
		return
	GameSession.difficulty = key
	GameSession.endless = false   # 明确走普通/困难：主菜单路径每局重设，无进程内残留
	GameSession.daily_mode = false   # 每日挑战标记同理：普通路径显式清掉（入口保证互斥）
	_close_difficulty_select()
	get_tree().change_scene_to_file(CHARSEL_SCENE)


func _pick_endless() -> void:
	GameSession.difficulty = "normal"
	GameSession.endless = true
	GameSession.daily_mode = false   # 无尽与每日互斥（每日 = 20 波固定种子）
	_close_difficulty_select()
	get_tree().change_scene_to_file(CHARSEL_SCENE)


## 每日挑战（2026-10-09 meta 2.0 第二批）：固定普通难度 + 当日种子，直接进选人。
## 种子应用点不在标题侧 —— Battle.start_run → _apply_daily_seed 读 daily_mode 生效，
## 这里只负责设置模式标记（跨场景保留，begin_run 不碰）。
func _pick_daily() -> void:
	GameSession.daily_mode = true
	GameSession.endless = false
	GameSession.difficulty = "normal"
	get_tree().change_scene_to_file(CHARSEL_SCENE)


func _close_difficulty_select() -> void:
	# 防御：诅咒 / 起始武器子层若还开着（异常路径），随难度层一起收掉，避免孤儿遮罩盖住标题。
	_close_curse_select()
	_close_weapon_select()
	_curse_entry_btn = null
	_weapon_entry_btn = null
	if _diff_layer != null:
		_diff_layer.queue_free()
		_diff_layer = null


# ---------------------------------------------------------------- 开局诅咒（2026-10-08 第二梯队）
## 诅咒选择子层：勾选实时写 GameSession.curses，「完成 / Esc」关闭回难度层。
## 上限 GameStats.CURSE_MAX 条 —— 满员时未选中的条目自动禁用（刷新函数维护）。
## 注：不做「通关解锁」门槛 —— 诅咒本身已是自选难度，先让玩家自由使用；
##     将来要加门槛，在 _open_curse_select 入口处加一个判定即可。


## 难度面板上「诅咒」入口按钮的文案：无诅咒时提示可点，有诅咒时列条数与名字。
func _curse_entry_text() -> String:
	var n := GameSession.curses.size()
	if n == 0:
		return "诅咒：无（自选难度 · 每条强化点数 +%d%%）" % roundi(float(GameStats.CURSE_XP_BONUS) * 100.0)
	var names: Array[String] = []
	for id in GameSession.curses:
		names.append(GameStats.curse_name(String(id)))
	return "诅咒（%d/%d）：%s" % [n, int(GameStats.CURSE_MAX), " + ".join(names)]


func _open_curse_select() -> void:
	if _curse_layer != null:
		return
	_curse_layer = ColorRect.new()
	_curse_layer.color = Color(0, 0, 0, 0.72)
	_curse_layer.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_curse_layer)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	_curse_layer.add_child(center)

	var panel := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.10, 0.11, 0.16, 0.97)
	sb.border_color = Color(0.60, 0.36, 0.42)     # 红调边框：与「自虐换成长」语义呼应
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(10)
	sb.content_margin_left = 34.0
	sb.content_margin_right = 34.0
	sb.content_margin_top = 24.0
	sb.content_margin_bottom = 24.0
	panel.add_theme_stylebox_override("panel", sb)
	center.add_child(panel)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 10)
	panel.add_child(box)

	var title := Label.new()
	title.text = "诅咒（最多 %d 条）" % int(GameStats.CURSE_MAX)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 30)
	title.add_theme_color_override("font_color", Color("#ff8a80"))
	box.add_child(title)

	var sub := Label.new()
	sub.text = "每条：结算强化点数 +%d%%　·　敌人更强，成长更快" % roundi(float(GameStats.CURSE_XP_BONUS) * 100.0)
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	sub.add_theme_font_size_override("font_size", 15)
	sub.add_theme_color_override("font_color", Color(0.8, 0.8, 0.9))
	box.add_child(sub)

	_curse_btns.clear()
	_curse_ids.clear()
	for id in GameStats.CURSES.keys():
		var cid := String(id)
		var b := Button.new()
		b.custom_minimum_size = Vector2(460, 54)
		b.add_theme_font_size_override("font_size", 18)
		# 图标（2026-10-09 美术入库）：左侧 40px 小图标；缺图自动为空、不影响文字与点击。
		# ⚠️ icon_max_width 是 Button 的【theme 常量】不是属性（直接赋值会运行时错误），
		# 必须走 add_theme_constant_override。
		var ic := AssetDB.curse_icon(cid)
		if ic != null:
			b.icon = ic
			b.add_theme_constant_override("icon_max_width", 40)
		b.pressed.connect(_toggle_curse.bind(cid))
		box.add_child(b)
		_curse_btns.append(b)
		_curse_ids.append(cid)

	var done := Button.new()
	done.text = "完成（Esc）"
	done.custom_minimum_size = Vector2(220, 54)
	done.add_theme_font_size_override("font_size", 16)
	done.pressed.connect(_close_curse_select)
	box.add_child(done)

	_refresh_curse_btns()


## 勾选 / 取消一条诅咒（满员时只能取消，不能再选 —— 禁用态由刷新函数维护）。
func _toggle_curse(id: String) -> void:
	if GameSession.curses.has(id):
		GameSession.curses.erase(id)
	elif GameSession.curses.size() < int(GameStats.CURSE_MAX):
		GameSession.curses.append(id)
	_refresh_curse_btns()


## 刷新诅咒按钮的选中态（金色 + ✓）与禁用态（满员且未选中）。
func _refresh_curse_btns() -> void:
	for i in _curse_btns.size():
		var b := _curse_btns[i]
		var id := _curse_ids[i]
		var on: bool = GameSession.curses.has(id)
		var d: Dictionary = GameStats.CURSES[id]
		b.text = ("✓ " if on else "　") + "%s：%s" % [String(d["name"]), String(d["desc"])]
		b.add_theme_color_override("font_color",
			Color("#FFD24A") if on else Color("#FFE9B0"))
		b.disabled = (not on) and GameSession.curses.size() >= int(GameStats.CURSE_MAX)


func _close_curse_select() -> void:
	if _curse_layer != null:
		_curse_layer.queue_free()
		_curse_layer = null
	# 难度层的入口按钮文案跟着刷新（它是「上一级」）
	if _curse_entry_btn != null and is_instance_valid(_curse_entry_btn):
		_curse_entry_btn.text = _curse_entry_text()


# ---------------------------------------------------------------- 起始武器（2026-10-09 meta 2.0 第二批）
## 武器自由：给任意角色替换起始武器。整条武器线随替换 —— 基础弹道 / 进化形态 /
## 融合配方全部按替换武器走（数值收口在 Player.weapon_id()，角色特性/属性不受影响）。
## 入口仅解锁 unlock_weapon_free 后出现在难度层；选择存 GameSession.weapon_pick（跨场景保留）。


## 难度层入口按钮文案：默认 = 角色本命武器；已选 = 显示替换武器名。
func _weapon_entry_text() -> String:
	var pick := GameSession.weapon_pick
	if pick == "" or not GameStats.WEAPON_DEFS.has(pick):
		return "起始武器：默认（角色本命武器）"
	return "起始武器：%s" % String(GameStats.WEAPON_DEFS[pick]["name"])


func _open_weapon_select() -> void:
	if _weapon_layer != null:
		return
	_weapon_layer = ColorRect.new()
	_weapon_layer.color = Color(0, 0, 0, 0.72)
	_weapon_layer.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_weapon_layer)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	_weapon_layer.add_child(center)

	var panel := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.10, 0.11, 0.16, 0.97)
	sb.border_color = Color(0.42, 0.56, 0.72)     # 蓝调边框：与「武器 / 装备」语义呼应
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(10)
	sb.content_margin_left = 34.0
	sb.content_margin_right = 34.0
	sb.content_margin_top = 24.0
	sb.content_margin_bottom = 24.0
	panel.add_theme_stylebox_override("panel", sb)
	center.add_child(panel)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	panel.add_child(box)

	var title := Label.new()
	title.text = "起始武器（武器自由）"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 30)
	title.add_theme_color_override("font_color", Color("#8ecbff"))
	box.add_child(title)

	var sub := Label.new()
	sub.text = "任意角色可用任意武器 —— 进化形态与融合配方跟随替换武器"
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	sub.add_theme_font_size_override("font_size", 15)
	sub.add_theme_color_override("font_color", Color(0.8, 0.8, 0.9))
	box.add_child(sub)

	_weapon_btns.clear()
	var def_btn := Button.new()
	def_btn.custom_minimum_size = Vector2(560, 48)
	def_btn.add_theme_font_size_override("font_size", 16)
	def_btn.pressed.connect(_pick_weapon.bind(""))
	box.add_child(def_btn)
	_weapon_btns.append(def_btn)
	for id in GameStats.WEAPON_DEFS.keys():
		var wid := String(id)
		var b := Button.new()
		b.custom_minimum_size = Vector2(560, 48)
		b.add_theme_font_size_override("font_size", 16)
		b.pressed.connect(_pick_weapon.bind(wid))
		box.add_child(b)
		_weapon_btns.append(b)

	var done := Button.new()
	done.text = "完成（Esc）"
	done.custom_minimum_size = Vector2(220, 54)
	done.add_theme_font_size_override("font_size", 16)
	done.pressed.connect(_close_weapon_select)
	box.add_child(done)

	_refresh_weapon_btns()


## 单选：空串 = 恢复默认（角色本命武器）。
func _pick_weapon(id: String) -> void:
	GameSession.weapon_pick = id if GameStats.WEAPON_DEFS.has(id) else ""
	_refresh_weapon_btns()


## 刷新选中态（金色 + ✓）。单选语义 —— 无禁用态。
func _refresh_weapon_btns() -> void:
	var pick := GameSession.weapon_pick
	if not GameStats.WEAPON_DEFS.has(pick):
		pick = ""
	var ids: Array = GameStats.WEAPON_DEFS.keys()
	for i in _weapon_btns.size():
		var b := _weapon_btns[i]
		var on: bool
		if i == 0:
			on = pick == ""
			b.text = ("✓ " if on else "　") + "默认 · 角色本命武器"
		else:
			var wid := String(ids[i - 1])
			on = wid == pick
			b.text = ("✓ " if on else "　") + "%s　（%s）" % [
				String(GameStats.WEAPON_DEFS[wid]["name"]), GameStats.weapon_summary(wid)]
		b.add_theme_color_override("font_color",
			Color("#FFD24A") if on else Color("#DCE6F5"))


func _close_weapon_select() -> void:
	if _weapon_layer != null:
		_weapon_layer.queue_free()
		_weapon_layer = null
	# 难度层的入口按钮文案跟着刷新（它是「上一级」）
	if _weapon_entry_btn != null and is_instance_valid(_weapon_entry_btn):
		_weapon_entry_btn.text = _weapon_entry_text()


## 键盘/手柄也能进（Enter 或空格）。商店/难度层开着时改为关闭对应弹层，杜绝误触开始。
func _unhandled_input(event: InputEvent) -> void:
	if _settings_layer != null:
		if event.is_action_pressed("use_item") or (event is InputEventKey and event.pressed \
				and event.keycode == KEY_ESCAPE):
			_close_settings()
			get_viewport().set_input_as_handled()
		return
	if _shop_layer != null:
		if event.is_action_pressed("use_item") or (event is InputEventKey and event.pressed \
				and (event.keycode == KEY_ENTER or event.keycode == KEY_ESCAPE)):
			_close_meta_shop()
			get_viewport().set_input_as_handled()
		return
	# 图鉴（2026-09-22）：Esc 关闭。不放行 Enter —— 格子全禁用时 Enter 没有别的语义，
	# 但和商店一致地只认 Esc，避免「按 Enter 顺手把图鉴关掉又开了难度选择」。
	if _codex_layer != null:
		if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
			_close_codex()
			get_viewport().set_input_as_handled()
		return
	# 成就 / 战绩（2026-10-08）：与图鉴同款 —— 只认 Esc。
	if _ach_layer != null:
		if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
			_close_achievements()
			get_viewport().set_input_as_handled()
		return
	# 诅咒子层（2026-10-08 第二梯队）：优先于难度层关闭（它是难度层的子层）。
	if _curse_layer != null:
		if event.is_action_pressed("pause") or (event is InputEventKey and event.pressed \
				and event.keycode == KEY_ESCAPE):
			_close_curse_select()
			get_viewport().set_input_as_handled()
		return
	# 起始武器子层（2026-10-09 meta 2.0 第二批）：与诅咒子层同层级。
	if _weapon_layer != null:
		if event.is_action_pressed("pause") or (event is InputEventKey and event.pressed \
				and event.keycode == KEY_ESCAPE):
			_close_weapon_select()
			get_viewport().set_input_as_handled()
		return
	if _diff_layer != null:
		if event.is_action_pressed("pause") or (event is InputEventKey and event.pressed \
				and event.keycode == KEY_ESCAPE):
			_close_difficulty_select()
			get_viewport().set_input_as_handled()
		return
	if event.is_action_pressed("use_item") or (event is InputEventKey and event.pressed and event.keycode == KEY_ENTER):
		_on_start()
		get_viewport().set_input_as_handled()
