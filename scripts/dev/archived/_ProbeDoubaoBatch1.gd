extends SceneTree
## 评估豆包生成的第一轮图（升级图标网格）：不需要真的「看见」图片也能判断合不合格。
##
## 检查四件事：
##   1. 背景是否为【纯白且均匀】（角落采样 + 方差）—— 抠图能否干净的前提
##   2. 布局是否是 2×2 四个独立物体（四象限的内容占比 + ASCII 渲染）
##   3. 有没有物体越界/连成一片
##   4. 配色是否与现有素材一致（主色对比）
##
## 用法: godot --headless --path <项目> --script res://scripts/dev/_ProbeDoubaoBatch1.gd

const SHEETS := [
	"C:/Users/10201/Desktop/Roguelike/美术资源/_待切分/升级图标_第1批.png",
	"C:/Users/10201/Desktop/Roguelike/美术资源/_待切分/升级图标_第2批.png",
	"C:/Users/10201/Desktop/Roguelike/美术资源/_待切分/升级图标_第3批.png",
]
const COLS := 60


func _initialize() -> void:
	for path in SHEETS:
		_analyze(path)
	# 对照组：现有 4 个道具图标的主色
	print("\n" + "-".repeat(78))
	print(" 对照：现有素材的主色（新图应落在同一色系）")
	for rel in ["items/helmet.png", "items/milk.png", "items/mj_gloves.png", "items/scooter.png"]:
		var t := AssetDB.tex(rel)
		if t == null:
			continue
		print("  %-22s %s" % [rel.get_file(), _top_colors(t.get_image(), 5)])
	quit(0)


func _analyze(path: String) -> void:
	var img := Image.new()
	if img.load(path) != OK:
		print("  %s  读取失败" % path.get_file())
		return
	var w := img.get_width()
	var h := img.get_height()
	print("\n" + "=".repeat(78))
	print(" %s  (%dx%d)" % [path.get_file(), w, h])
	print("=".repeat(78))

	# ---- 1. 背景色采样：四角各 24x24，看均值与方差 ----
	var corner_zone := mini(24, w / 8)
	var rs := 0
	var gs := 0
	var bs := 0
	var n := 0
	var vals := []
	for cy in 2:
		for cx in 2:
			for y in corner_zone:
				for x in corner_zone:
					var px := Vector2i(
						cx * (w - corner_zone) + x,
						cy * (h - corner_zone) + y)
					var c := img.get_pixel(px.x, px.y)
					rs += int(c.r * 255)
					gs += int(c.g * 255)
					bs += int(c.b * 255)
					vals.append(Vector3(c.r * 255.0, c.g * 255.0, c.b * 255.0))
					n += 1
	var key := Vector3(rs / float(n), gs / float(n), bs / float(n))
	var varsum := 0.0
	for v in vals:
		varsum += (v - key).length_squared()
	var stddev := sqrt(varsum / maxf(1.0, float(vals.size())))
	print("  背景均值 RGB=(%.0f,%.0f,%.0f)  角落标准差=%.1f（<8 才算均匀纯色）" % [
		key.x * 255.0, key.y * 255.0, key.z * 255.0, stddev,
	])

	# ---- 2. 内容掩码 + ASCII ----
	var rows := int(round(float(h) / w * COLS * 0.5))
	var grid := []
	var content_total := 0
	for ry in rows:
		var line := ""
		var row_cells := []
		for rx in COLS:
			var maxd := 0.0
			var x0 := int(float(rx) * w / COLS)
			var x1 := maxi(x0 + 1, int(float(rx + 1) * w / COLS))
			var y0 := int(float(ry) * h / rows)
			var y1 := maxi(y0 + 1, int(float(ry + 1) * h / rows))
			for y in range(y0, mini(y1, h)):
				for x in range(x0, mini(x1, w)):
					var c := img.get_pixel(x, y)
					var d := Vector3(
						c.r * 255.0 - key.x,
						c.g * 255.0 - key.y,
						c.b * 255.0 - key.z).length()
					maxd = maxf(maxd, d)
			var is_content := maxd > 95.0
			row_cells.append(is_content)
			grid.append(is_content)
			if is_content:
				content_total += 1
			line += "#" if is_content else "."
		print("  " + line)
	print("  内容占比 %.1f%%（2x2 四个图标，合理区间约 25~45%%）" % [
		100.0 * content_total / float(grid.size()),
	])

	# ---- 3. 四象限内容占比（判断是不是 2x2 四个独立物体）----
	var half_r := int(rows / 2.0)
	var half_c := int(COLS / 2.0)
	for qy in 2:
		var line := ""
		for qx in 2:
			var cnt := 0
			var tot := 0
			for ry in range(qy * half_r, (qy + 1) * half_r):
				for rx in range(qx * half_c, (qx + 1) * half_c):
					tot += 1
					if grid[ry * COLS + rx]:
						cnt += 1
			line += "  象限(%d,%d) 内容 %.1f%%" % [qy, qx, 100.0 * cnt / maxf(1.0, float(tot))]
		print(" " + line)

	# ---- 4. 主色 ----
	print("  主色: %s" % _top_colors(img, 6))


func _top_colors(img: Image, count: int) -> String:
	var counts := {}
	var w := img.get_width()
	var h := img.get_height()
	var opaque := 0
	for y in range(0, h, 2):
		for x in range(0, w, 2):
			var c := img.get_pixel(x, y)
			if c.a < 0.5:
				continue
			# 跳过接近白色的像素：网格图背景是纯白不透明，
			# 不跳过的话「主色」会被背景吃掉，没法和透明底的旧素材对比
			if c.r > 0.86 and c.g > 0.86 and c.b > 0.86:
				continue
			opaque += 1
			var k := "%02X%02X%02X" % [int(c.r * 31) * 8, int(c.g * 31) * 8, int(c.b * 31) * 8]
			counts[k] = counts.get(k, 0) + 1
	var arr := []
	for k in counts.keys():
		arr.append([k, counts[k]])
	arr.sort_custom(func(a, b): return a[1] > b[1])
	var out := []
	for i in mini(count, arr.size()):
		var pct := 100.0 * float(arr[i][1]) / maxf(1.0, float(opaque))
		if pct < 3.0:
			continue
		out.append("#%s(%.0f%%)" % [arr[i][0], pct])
	return " ".join(out)
