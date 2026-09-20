extends SceneTree
## 独立验证探针：竞技场地面「瓦片拼接」改造（T-MAP-02；三调补充 src 等比组）。
##
## 由质量线（严守真）独立编写 —— 依据【已冻结的接口契约】写断言，不看实现细节。
## 被验证的契约：
##   GameStats.FLOOR_TILE_COLS / FLOOR_TILE_ROWS
##   GameStats.floor_tile_rects(cols=COLS, rows=ROWS) -> Array[Rect2]
##     · 返回行优先（row-major）的 cols*rows 个【世界空间】矩形
##     · 并集精确等于 GameStats.arena_rect()
##     · 支持任意 cols/rows >= 1；floor_tile_rects(1,1) == [arena_rect()]
##   Battle.floor_tile_rects() -> Array[Rect2]   （本帧实际绘制的瓦片矩形）
##   GameStats.floor_tile_src_rect(tex_size, cols=COLS, rows=ROWS) -> Rect2
##     · 每块瓦片取自贴图的【源区域】，按瓦片格宽高比从贴图【居中】裁最大内接矩形
##     · 贴图本身同比例时返回整张贴图（向后兼容旧 1920x1080 素材）
##   Battle.floor_tile_src_rect() -> Rect2      （真实绘制链路用的源区域）
##   （2026-09-19 三调补充：素材换成 2048x2048 方图后，E 组专门盯「缩放必须等比」——
##     方图直接塞进 16:9 的格子会把菱形地砖横向拉扁。）
##   （2026-09-19 四调补充：用户反馈「线条太复杂、头晕」后新增 F 组 —— 每套主题的
##     压场数据 grade（平均亮度归一）/ veil（柔化纱）必须存在、数值合理、且被绘制链路读到。
##     观感本身靠实拍截图验证，不在这里测。）
##
## 为什么用「反射」而非直接静态调用：
##   GDScript 4 对【未知静态成员】是【解析期】硬错误（"Cannot call non-static function
##   on the class directly"）。
##   若直接写 `GameStats.floor_tile_rects(...)`，一旦接口尚未落地/被回退，本探针连编译都过不了，
##   无法给出「契约未就绪」的可读诊断；`GameStats.has_method(...)` 本身也是同一个解析错误。
##   因此这里 load() 出脚本资源后，用「实例 + get_script_constant_map() + has_method/call/callv」
##   做运行期反射 —— 接口缺失时优雅打印诊断并 RESULT=FAIL，接口一落地即可直接跑。
##
## 断言值全部从 GameStats / AssetDB 派生，不硬编码 2560/1440/640/360/16 等魔数；
## 浮点比较用「绝对下限 + 相对项」（见 _approx —— 网格除不尽时绝对容差会误红）。
##
## 用法: godot --headless --path <项目> --script res://scripts/dev/_ProbeFloorTiles.gd
## 退出码 0=PASS 1=FAIL（门禁用 grep -q "RESULT=PASS" 判定）

const TOL := 1e-4                 # 绝对容差下限
const TOL_REL := 1e-5             # 相对容差（见 _approx：浮点比较必须带相对项）

var _stats_script = null          # load("res://scripts/data/Stats.gd") —— 保持无类型，走动态反射
var _stats = null                 # 上述脚本的一个实例（用于 has_method / call / callv 静态方法）
var _consts: Dictionary = {}      # 脚本常量表（FLOOR_TILE_COLS / ARENA_W / FLOOR_THEMES ...）

var battle: Node = null
var armed := false
var finished := false
var checks := 0
var fails: Array[String] = []


func _initialize() -> void:
	print("[PROBE] === 地面瓦片拼接独立验证（T-MAP-02）===")
	_stats_script = load("res://scripts/data/Stats.gd")
	if _stats_script == null:
		_finish("无法加载 res://scripts/data/Stats.gd")
		return
	_consts = _stats_script.get_script_constant_map()
	_stats = _stats_script.new()

	# --- 契约就绪守卫（接口未落地时给出可读诊断，而不是一堆解析错误）---
	var missing: Array[String] = []
	if not _consts.has("FLOOR_TILE_COLS"):
		missing.append("FLOOR_TILE_COLS")
	if not _consts.has("FLOOR_TILE_ROWS"):
		missing.append("FLOOR_TILE_ROWS")
	if not _stats.has_method("floor_tile_rects"):
		missing.append("floor_tile_rects()")
	if not _stats.has_method("floor_tile_src_rect"):
		missing.append("floor_tile_src_rect()")
	if not _stats.has_method("arena_rect"):
		missing.append("arena_rect()")
	if not missing.is_empty():
		_finish("契约未就绪：GameStats 缺少 %s" % str(missing))
		return
	print("[PROBE] 契约就绪：FLOOR_TILE_COLS=%d FLOOR_TILE_ROWS=%d" % [
		int(_consts["FLOOR_TILE_COLS"]), int(_consts["FLOOR_TILE_ROWS"])])

	print("[PROBE] 载入 Battle.tscn（真实绘制链路）")
	var packed: PackedScene = load("res://scenes/battle/Battle.tscn")
	if packed == null:
		_finish("Battle.tscn 加载失败")
		return
	battle = packed.instantiate()
	root.add_child(battle)
	# @onready 变量（camera / _floor_tex ...）要等 _ready() 跑完才有值，
	# 而 add_child 在 _initialize 阶段是延迟 _ready 的 → 真正的断言推迟到第一帧。
	print("[PROBE] Battle 已入树，断言推迟到第一帧")


## 第一帧：此时 Battle._ready() 已跑过，camera / 地面贴图可用。
func _arm() -> void:
	armed = true

	var cols := int(_consts["FLOOR_TILE_COLS"])
	var rows := int(_consts["FLOOR_TILE_ROWS"])
	var arena: Rect2 = _stats.call("arena_rect")

	# ============================================================ A. 网格算术（纯静态）
	print("[PROBE] --- A. 网格算术（纯静态，来自 GameStats 常量）---")
	var rects: Array = _stats.call("floor_tile_rects")
	_assert_layout(rects, cols, rows, arena, "默认(%d×%d)" % [cols, rows])

	# ============================================================ A7. 参数化回退
	print("[PROBE] --- A7. 参数化回退（证明实现不是写死 4×4）---")
	var r11: Array = _stats.callv("floor_tile_rects", [1, 1])
	_check(r11.size() == 1, "(1,1) 恰好返回 1 块（实际 %d）" % r11.size())
	if r11.size() == 1:
		_check(_rect_approx(r11[0], arena),
			"(1,1) 唯一块 %s == arena_rect() %s" % [str(r11[0]), str(arena)])
	var r23: Array = _stats.callv("floor_tile_rects", [2, 3])
	_assert_layout(r23, 2, 3, arena, "(2×3)")

	# ============================================================ B. 真实绘制链路
	print("[PROBE] --- B. 真实绘制链路（跑真场景）---")
	var tex = battle.get("_floor_tex")
	if tex == null:
		# 兜底：探针只等到 _ready()；若波次尚未触发换地渲染，_floor_tex 可能为空。
		# 主动走工程既有的主题应用入口（不启动波次），只为把地面贴图装上。
		var theme = _stats.call("floor_theme_for_wave", 1)
		battle.call("_apply_floor_theme", theme)
		tex = battle.get("_floor_tex")
		print("[PROBE]   （_floor_tex 为空 → 已主动调用 _apply_floor_theme(第1波主题) 兜底）")
	_check(tex != null, "Battle._floor_tex != null（地面主题已应用，实际 %s）" % str(tex))

	if not battle.has_method("floor_tile_rects"):
		_check(false, "Battle.floor_tile_rects() 不存在（契约未落地）")
	else:
		var btr: Array = battle.call("floor_tile_rects")
		_check(btr.size() == rects.size(),
			"Battle.floor_tile_rects 数量 == GameStats（%d vs %d）" % [btr.size(), rects.size()])
		var n := mini(btr.size(), rects.size())
		for i in n:
			var a: Rect2 = btr[i]
			var b: Rect2 = rects[i]
			_check(_rect_approx(a, b),
				"Battle 瓦片[%d] %s == GameStats %s" % [i, str(a), str(b)])

	_check(battle.get("_floor_glow") != null, "Battle._floor_glow != null（氛围柔光层存在，未被切碎/丢层）")
	_check(battle.get("_floor_vignette") != null, "Battle._floor_vignette != null（氛围暗角层存在，未被切碎/丢层）")

	# ============================================================ C. 相机无关性（核心风险：坐标须为世界空间）
	print("[PROBE] --- C. 相机无关性（瓦片布局不得随相机缩放/平移变化）---")
	var cam = battle.get("camera")
	if cam == null:
		_check(false, "Battle.camera 为 null，无法验证相机无关性")
	elif battle.has_method("floor_tile_rects"):
		var before: Array = battle.call("floor_tile_rects")
		cam.zoom = Vector2(3.0, 3.0)
		cam.global_position = Vector2(1234.5, 678.25)
		var after: Array = battle.call("floor_tile_rects")
		_check(before.size() == after.size(),
			"相机变更后瓦片数不变（%d vs %d）" % [before.size(), after.size()])
		var nn := mini(before.size(), after.size())
		var all_same := true
		var first_bad := -1
		for i in nn:
			if not _rect_approx(before[i], after[i]):
				all_same = false
				if first_bad < 0:
					first_bad = i
		var detail := ""
		if first_bad >= 0:
			detail = "（首个不同 瓦片[%d]: %s vs %s）" % [
				first_bad, str(before[first_bad]), str(after[first_bad])]
		_check(all_same, "瓦片布局不随相机缩放/平移变化%s" % detail)
		_check(_union_equals(after, arena), "相机变更后并集仍 == arena_rect()")

	# ============================================================ D. 素材与主题
	print("[PROBE] --- D. 素材与主题 ---")
	var themes: Array = _consts.get("FLOOR_THEMES", [])
	_check(not themes.is_empty(), "GameStats.FLOOR_THEMES 非空（实际 %d 项）" % themes.size())
	for t in themes:
		var id := String(t.get("id", ""))
		var ft = AssetDB.floor_bg(id)
		_check(ft != null, "AssetDB.floor_bg('%s') 非空" % id)
		if ft == null:
			continue
		# 期望尺寸从 AssetDB.EXPECT 取（由贴图自身 resource_path 派生 key，不写死 "bg/xxx.png"）
		var rel: String = String(ft.resource_path)
		if rel.begins_with(AssetDB.ROOT):
			rel = rel.substr(AssetDB.ROOT.length())
		var exp = AssetDB.EXPECT.get(rel, {})
		if exp.is_empty():
			_check(false, "AssetDB.EXPECT 缺少 '%s' 的期望尺寸条目" % rel)
			continue
		var esz: Vector2i = exp["size"]
		var asz: Vector2 = ft.get_size()
		_check(_vapprox(asz, Vector2(esz)),
			"贴图 %s 尺寸 %s == EXPECT %s" % [rel, str(asz), str(esz)])

	# ============================================================ E. 每块瓦片的取图区域（等比不变形）
	# 2026-09-19 三调：素材由 1920x1080 整图换成 2048x2048 方图。若把方图直接塞进
	# 16:9 的瓦片格，菱形地砖会被横向拉扁 —— 本组专门盯「缩放必须是等比的」。
	print("[PROBE] --- E. 瓦片取图区域 src（等比不变形 / 居中裁切）---")
	var cols_f := float(cols)
	var rows_f := float(rows)
	var cell_w := arena.size.x / cols_f
	var cell_h := arena.size.y / rows_f
	var cell_aspect := cell_w / cell_h
	var tile_w := cell_w
	var tile_h := cell_h

	# E1. 方形素材（当前真实情况）：上下居中裁切
	var sq := Vector2(2048.0, 2048.0)
	var src_sq: Rect2 = _stats.callv("floor_tile_src_rect", [sq, cols, rows])
	var exp_h := sq.x / cell_aspect
	var exp_sq := Rect2(0.0, (sq.y - exp_h) * 0.5, sq.x, exp_h)
	_check(_rect_approx(src_sq, exp_sq),
		"src(2048²) == 居中裁上下 %s（实际 %s）" % [str(exp_sq), str(src_sq)])
	_check(_approx(src_sq.size.x / src_sq.size.y, cell_aspect),
		"src(2048²) 宽高比 %.6f == 瓦片格宽高比 %.6f" % [
			src_sq.size.x / src_sq.size.y, cell_aspect])
	_check(_approx((sq.y - src_sq.size.y) * 0.5, src_sq.position.y)
		and _approx(src_sq.position.x, 0.0),
		"src(2048²) 居中（上下留边相等、左右不裁）pos=%s" % str(src_sq.position))
	_check(src_sq.position.x >= -TOL and src_sq.position.y >= -TOL
		and src_sq.end.x <= sq.x + TOL and src_sq.end.y <= sq.y + TOL,
		"src(2048²) 落在贴图范围内 %s" % str(src_sq))

	# E2. 【核心】等比不变形：横向缩放 == 纵向缩放
	var sx := tile_w / src_sq.size.x
	var sy := tile_h / src_sq.size.y
	_check(_approx(sx, sy),
		"2048² 素材：横向缩放 %.6f == 纵向缩放 %.6f（非等比压扁会在这里红）" % [sx, sy])

	# E3. 向后兼容：贴图本来同比例（1920x1080 的 16:9）→ 取整张贴图，行为与改造前一致
	var wide := Vector2(1920.0, 1080.0)
	var src_wide: Rect2 = _stats.callv("floor_tile_src_rect", [wide, cols, rows])
	_check(_rect_approx(src_wide, Rect2(Vector2.ZERO, wide)),
		"src(1920x1080 同比例) == 整张贴图（实际 %s）" % str(src_wide))

	# E4. 反向：贴图比格子更宽 → 裁左右且居中
	var wide2 := Vector2(3000.0, 1000.0)
	var src_w2: Rect2 = _stats.callv("floor_tile_src_rect", [wide2, cols, rows])
	_check(_approx(src_w2.size.y, wide2.y) and _approx(src_w2.size.x / src_w2.size.y, cell_aspect),
		"src(3000x1000 太宽) 按比例裁左右 %s" % str(src_w2))
	_check(_approx((wide2.x - src_w2.size.x) * 0.5, src_w2.position.x) and _approx(src_w2.position.y, 0.0),
		"src(3000x1000) 居中 pos=%s" % str(src_w2))

	# E5. 退化输入不炸：尺寸为 0 → 空矩形
	var src_zero: Rect2 = _stats.callv("floor_tile_src_rect", [Vector2.ZERO, cols, rows])
	_check(src_zero.size.x * src_zero.size.y < TOL, "src(0x0) 返回空矩形（实际 %s）" % str(src_zero))

	# E6. (1,1) 回退时格子比例 == 竞技场比例，src 仍等比
	var src_11: Rect2 = _stats.callv("floor_tile_src_rect", [sq, 1, 1])
	_check(_approx(src_11.size.x / src_11.size.y, arena.size.x / arena.size.y),
		"(1,1) src 宽高比 == 竞技场宽高比（实际 %.6f vs %.6f）" % [
			src_11.size.x / src_11.size.y, arena.size.x / arena.size.y])

	# E7. 真实素材全量：5 套主题逐个验证「等比不变形」+「居中裁切」
	if tex != null:
		if not battle.has_method("floor_tile_src_rect"):
			_check(false, "Battle.floor_tile_src_rect() 不存在（契约未落地）")
		else:
			var bsrc: Rect2 = battle.call("floor_tile_src_rect")
			var gsrc: Rect2 = _stats.callv("floor_tile_src_rect", [tex.get_size(), cols, rows])
			_check(_rect_approx(bsrc, gsrc),
				"Battle.floor_tile_src_rect() %s == GameStats %s" % [str(bsrc), str(gsrc)])
	for t2 in themes:
		var id2 := String(t2.get("id", ""))
		var ft2 = AssetDB.floor_bg(id2)
		if ft2 == null:
			continue
		var sz2: Vector2 = ft2.get_size()
		var s2: Rect2 = _stats.callv("floor_tile_src_rect", [sz2, cols, rows])
		var kx := tile_w / s2.size.x
		var ky := tile_h / s2.size.y
		_check(_approx(kx, ky),
			"主题 %s：等比缩放 kx %.6f == ky %.6f（素材 %s）" % [id2, kx, ky, str(sz2)])
		_check(_approx((sz2.x - s2.size.x) * 0.5, s2.position.x)
			and _approx((sz2.y - s2.size.y) * 0.5, s2.position.y),
			"主题 %s：src 在素材中居中 pos=%s（素材 %s）" % [id2, str(s2.position), str(sz2)])

	# ============================================================ F. 地面压场（缓解眩晕）
	# 2026-09-19 用户反馈「地面线条太复杂、头晕」后新增：每套主题必须带
	#   grade —— 把平均亮度归一到同一档（乘法调色）
	#   veil  —— 向主题自身平均色混合的柔化纱（只压对比、不动色调）
	# 本组只锁"契约存在 + 数值合理 + 真的被绘制链路读到"，不重复测美术观感（那靠实拍截图）。
	print("[PROBE] --- F. 地面压场 grade / veil（眩晕缓解数据）---")
	for t3 in themes:
		var id3 := String(t3.get("id", ""))
		if not t3.has("grade"):
			_check(false, "主题 %s 缺少 grade（平均亮度归一字段）" % id3)
		else:
			var g: Color = t3["grade"]
			_check(g.r > 0.0 and g.r <= 1.0 and g.g > 0.0 and g.g <= 1.0
				and g.b > 0.0 and g.b <= 1.0,
				"主题 %s：grade %s 三个分量都在 (0,1]（只压不抬）" % [id3, str(g)])
		if not t3.has("veil"):
			_check(false, "主题 %s 缺少 veil（柔化纱颜色）" % id3)
		else:
			var v: Color = t3["veil"]
			_check(v.a > 0.0 and v.a < 1.0,
				"主题 %s：veil alpha=%.2f 落在 (0,1)（既不能全透明也没意义到全遮）" % [id3, v.a])
	# 真实链路：Battle 取到的压场数据必须 == 它【当前主题】里登记的那份
	var cur: Dictionary = battle.get("_floor_theme")
	if cur.is_empty():
		_check(false, "Battle._floor_theme 为空，无法校验压场数据的真实链路")
	else:
		var idc := String(cur.get("id", ""))
		# 兜底值走 _consts（反射），避免直接静态引用 —— 保持"契约缺失也能给出可读诊断"的本意
		var def_g: Color = _consts.get("FLOOR_GRADE_DEFAULT", Color(1, 1, 1, 1))
		var def_v: Color = _consts.get("FLOOR_VEIL_DEFAULT", Color(0, 0, 0, 0))
		if battle.has_method("floor_grade"):
			var gc: Color = battle.call("floor_grade")
			var ge: Color = cur.get("grade", def_g)
			_check(_color_approx(gc, ge),
				"Battle.floor_grade() %s == 当前主题(%s).grade %s" % [str(gc), idc, str(ge)])
		else:
			_check(false, "Battle.floor_grade() 不存在（压场数据未接入绘制链路）")
		if battle.has_method("floor_veil"):
			var vc: Color = battle.call("floor_veil")
			var ve: Color = cur.get("veil", def_v)
			_check(_color_approx(vc, ve),
				"Battle.floor_veil() %s == 当前主题(%s).veil %s" % [str(vc), idc, str(ve)])
		else:
			_check(false, "Battle.floor_veil() 不存在（压场数据未接入绘制链路）")


# ================================================================ 布局断言（可复用于任意 cols/rows）
## 逐项验证 rects 构成 cols×rows 的无缝、无叠、并集=竞技场、行优先网格。
func _assert_layout(rects: Array, cols: int, rows: int, arena: Rect2, tag: String) -> void:
	var expect_n := cols * rows
	_check(rects.size() == expect_n, "%s: 瓦片数 == FLOOR_TILE_COLS*ROWS == %d（实际 %d）" % [tag, expect_n, rects.size()])
	var tw := arena.size.x / float(cols)
	var th := arena.size.y / float(rows)

	# 每块尺寸 + 起点（世界空间）
	for r in rows:
		for c in cols:
			var i := r * cols + c
			if i >= rects.size():
				continue
			var rc: Rect2 = rects[i]
			_check(_approx(rc.size.x, tw) and _approx(rc.size.y, th),
				"%s: 瓦片[%d,%d] 尺寸 == (%.4f, %.4f)（实际 (%.4f, %.4f)）" % [
					tag, c, r, tw, th, rc.size.x, rc.size.y])
			var epx := arena.position.x + float(c) * tw
			var epy := arena.position.y + float(r) * th
			_check(_approx(rc.position.x, epx) and _approx(rc.position.y, epy),
				"%s: 瓦片[%d,%d] 起点 == (%.4f, %.4f)（实际 (%.4f, %.4f)）" % [
					tag, c, r, epx, epy, rc.position.x, rc.position.y])

	# 无缝：横向（第 c 列右边界 == 第 c+1 列左边界）
	for r in rows:
		for c in range(cols - 1):
			var a: Rect2 = rects[r * cols + c]
			var b: Rect2 = rects[r * cols + c + 1]
			_check(_approx(a.end.x, b.position.x),
				"%s: 无缝(横) 行%d 列%d→%d: left.end.x %.4f == right.pos.x %.4f" % [
					tag, r, c, c + 1, a.end.x, b.position.x])

	# 无缝：纵向（第 r 行下边界 == 第 r+1 行上边界）
	for c in cols:
		for r in range(rows - 1):
			var a: Rect2 = rects[r * cols + c]
			var b: Rect2 = rects[(r + 1) * cols + c]
			_check(_approx(a.end.y, b.position.y),
				"%s: 无缝(纵) 列%d 行%d→%d: top.end.y %.4f == bottom.pos.y %.4f" % [
					tag, c, r, r + 1, a.end.y, b.position.y])

	# 无重叠（两两交集面积 < 1e-4）
	for i in rects.size():
		for j in range(i + 1, rects.size()):
			var inter: Rect2 = rects[i].intersection(rects[j])
			var ia := maxf(0.0, inter.size.x) * maxf(0.0, inter.size.y)
			_check(ia < TOL, "%s: 无重叠 瓦片[%d]×[%d] 交集面积 %.8f" % [tag, i, j, ia])

	# 并集 == 竞技场
	var sum_area := 0.0
	var minp := Vector2(INF, INF)
	var maxe := Vector2(-INF, -INF)
	for rc in rects:
		sum_area += rc.size.x * rc.size.y
		minp = minp.min(rc.position)
		maxe = maxe.max(rc.end)
	_check(_approx(sum_area, arena.size.x * arena.size.y),
		"%s: 面积和 %.4f == 竞技场面积 %.4f" % [tag, sum_area, arena.size.x * arena.size.y])
	_check(_vapprox(minp, arena.position), "%s: 最小 position %s == %s" % [tag, str(minp), str(arena.position)])
	_check(_vapprox(maxe, arena.end), "%s: 最大 end %s == %s" % [tag, str(maxe), str(arena.end)])

	# 行优先顺序（cols>1 且 rows>1 才有意义）
	if cols > 1 and rows > 1:
		_check(rects[1].position.x > rects[0].position.x,
			"%s: 行优先 rects[1].x(%.3f) > rects[0].x(%.3f)" % [tag, rects[1].position.x, rects[0].position.x])
		_check(rects[cols].position.y > rects[0].position.y,
			"%s: 行优先 rects[cols].y(%.3f) > rects[0].y(%.3f)" % [tag, rects[cols].position.y, rects[0].position.y])


# ================================================================ 工具
func _union_equals(rects: Array, arena: Rect2) -> bool:
	if rects.is_empty():
		return false
	var sum := 0.0
	var minp := Vector2(INF, INF)
	var maxe := Vector2(-INF, -INF)
	for rc in rects:
		sum += rc.size.x * rc.size.y
		minp = minp.min(rc.position)
		maxe = maxe.max(rc.end)
	return _approx(sum, arena.size.x * arena.size.y) \
		and _vapprox(minp, arena.position) and _vapprox(maxe, arena.end)


## 浮点比较：绝对容差下限 + 相对容差。
##
## 为什么不能只用绝对容差：瓦片边长是 ARENA_W/cols。cols=4 时是 640（可精确表示），
## 但 cols=3 时是 853.3333…（除不尽），而 Godot 的 Rect2 分量是 float32 ——
## 9 块面积相加会攒出约 0.09 的舍入残差，远超 1e-4 绝对容差。这纯粹是浮点表示问题，
## 与「拼接是否无缝」毫无关系，用绝对容差判它必然误红（2026-09-19 实测踩到）。
##
## 相对项的量级要选得既能吸收 float32 舍入、又不放过真实缝隙：
##   · float32 epsilon ≈ 1.2e-7 相对 → 1e-5 相对留了约 100 倍余量，足够；
##   · 在 1706 量级上 1e-5 相对 = 0.017 世界单位，而一个像素 = 0.5 世界单位、
##     3×3 时一个纹素 ≈ 0.42 世界单位 —— 真实的缝隙/重叠至少是这个量级，依然会被抓住。
func _approx(a: float, b: float) -> bool:
	return absf(a - b) <= maxf(TOL, TOL_REL * maxf(absf(a), absf(b)))


func _vapprox(a: Vector2, b: Vector2) -> bool:
	return _approx(a.x, b.x) and _approx(a.y, b.y)


func _rect_approx(a: Rect2, b: Rect2) -> bool:
	return _vapprox(a.position, b.position) and _vapprox(a.size, b.size)


func _color_approx(a: Color, b: Color) -> bool:
	return _approx(a.r, b.r) and _approx(a.g, b.g) and _approx(a.b, b.b) and _approx(a.a, b.a)


func _check(cond: bool, label: String) -> void:
	checks += 1
	if cond:
		print("[PROBE]   OK   %s" % label)
	else:
		fails.append(label)
		print("[PROBE]   FAIL %s" % label)


func _process(_delta: float) -> bool:
	if finished:
		return true
	if not armed:
		_arm()
		_finish("")
		return true
	return true


func _finish(early_msg: String) -> void:
	if finished:
		return
	finished = true
	print("[PROBE] --------------------------------------------------")
	if early_msg != "":
		print("[PROBE] 提前终止：%s" % early_msg)
		print("[PROBE] RESULT=FAIL")
		quit(1)
		return
	print("[PROBE] 断言 %d/%d 通过（失败 %d）" % [checks - fails.size(), checks, fails.size()])
	for f in fails:
		print("[PROBE]   - %s" % f)
	print("[PROBE] RESULT=%s" % ("PASS" if fails.is_empty() else "FAIL"))
	quit(0 if fails.is_empty() else 1)
