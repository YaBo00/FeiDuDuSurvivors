extends SceneTree
## 网格图切分器：把豆包生成的 2×2 网格图切成单张、抠图、归一化，落进 game\assets\。
##
## 流程（每格）：
##   1. 取格子矩形
##   2. 洪水填充抠背景（从格子四边向内；与 _remove_bg.py 同参数 T_LOW=35 / T_HIGH=95）
##   3. 找内容包围盒并裁切
##   4. 等比缩放到目标尺寸、居中贴到透明画布上
##   5. 写出 PNG
##
## 对应关系由下方 MANIFEST 声明（顺序 = 左上 → 右上 → 左下 → 右下，与提示词文档一致）。
## 空格子必须在 manifest 里用空字符串占位 —— 否则视为错误。
##
## 用法: godot --headless --path <项目> --script res://scripts/dev/SplitSheet.gd

const SRC_ROOT := "C:/Users/10201/Desktop/Roguelike/美术资源/_待切分"
const DST_ROOT := "C:/Users/10201/Desktop/Roguelike/game/assets"
const T_LOW := 35.0      # 距背景色小于此 → 全透明（与 _remove_bg.py 一致）
const T_HIGH := 95.0     # 距背景色大于此 → 完全保留

## 图标类的统一目标尺寸
const ICON := Vector2i(128, 128)

## sheet 文件名 → { "grid": Vector2i(cols, rows), "out": [ 相对路径, ... ] }
## out 里的空字符串 = 该格为空（提示词里要求留白的格子）。
## 顺序：左上 → 右上 → 左下 → 右下。
const MANIFEST := {
	"升级图标_第1批.png": {"size": Vector2i(2, 2), "out": [
		"ui/upgrade_atk.png", "ui/upgrade_def.png",
		"ui/upgrade_spd.png", "ui/upgrade_aspd.png",
	]},
	"升级图标_第2批.png": {"size": Vector2i(2, 2), "out": [
		"ui/upgrade_hp.png", "ui/upgrade_hpRegen.png",
		"ui/upgrade_dodge.png", "ui/upgrade_lifesteal.png",
	]},
	"升级图标_第3批.png": {"size": Vector2i(2, 2), "out": [
		"ui/upgrade_crit.png", "ui/upgrade_harvest.png",
		"ui/upgrade_proj.png", "",
	]},
	"被动道具_第1批.png": {"size": Vector2i(2, 2), "out": [
		"items/iron_fist.png", "items/sharp_arrow.png",
		"items/hp_potion.png", "items/gold_bag.png",
	]},
	"被动道具_第2批.png": {"size": Vector2i(2, 2), "out": [
		"items/leather_armor.png", "items/crit_lens.png",
		"items/crit_dmg_up.png", "items/study_lamp.png",
	]},
	"被动道具_第3批.png": {"size": Vector2i(2, 2), "out": [
		"items/harvest_bag.png", "items/mega_hp_potion.png",
		"items/regen_ring.png", "items/piggy_bank.png",
	]},
	"被动道具_第4批.png": {"size": Vector2i(2, 2), "out": [
		"items/multi_arrow.png", "items/vampire_fang.png",
		"items/dodge_boots.png", "items/evade_cloak.png",
	]},
	"被动道具_第5批.png": {"size": Vector2i(2, 2), "out": [
		"items/sadness_aura.png", "items/lucky_charm.png",
		"items/investment_manual.png", "items/finance_glasses.png",
	]},
	"被动道具_第6批.png": {"size": Vector2i(2, 2), "out": [
		"items/iron_armor.png", "items/golden_shield.png",
		"items/brotato_chip.png", "items/endless_money.png",
	]},
	"主动道具_第1批.png": {"size": Vector2i(2, 2), "out": [
		"items/active_nuke.png", "items/active_speed_boots.png",
		"items/active_time_stop.png", "",
	]},
	"UI_第1批.png": {"size": Vector2i(2, 2), "out": [
		"ui/joystick_base.png", "ui/joystick_knob.png",
		"ui/card_frame.png", "ui/card_frame_sel.png",
	]},
	"UI_第2批.png": {"size": Vector2i(2, 2), "out": [
		"ui/gold_plate.png", "ui/spare_a.png", "", "",
	]},
	# 单图：整张就是一个图标（不是网格）
	"升级图标_拾取范围.png": {"mode": "single", "out": [
		"ui/upgrade_pickupRange.png",
	]},
	# 纵向 N 联：整张横向切 N 条（按钮三态 = 普通/悬停/按下）
	"按钮_三态.png": {"mode": "rows", "rows": 3, "out": [
		"ui/button_normal.png", "ui/button_hover.png", "ui/button_pressed.png",
	]},
}

## 每个【输出类别】的目标尺寸。按前缀匹配；没匹配到就用 ICON。
const SIZE_OVERRIDES := {
	"ui/card_frame": Vector2i(224, 288),
	"ui/joystick": Vector2i(128, 128),
	"ui/gold_plate": Vector2i(256, 64),
	"ui/button_": Vector2i(384, 128),
}

var failures: Array[String] = []
var done_rows: Array = []


func _initialize() -> void:
	print("=".repeat(76))
	print(" 网格图切分 → %s" % DST_ROOT)
	print("=".repeat(76))
	for sheet in MANIFEST.keys():
		_process_sheet(String(sheet))
	print("\n" + "-".repeat(76))
	for r in done_rows:
		print("  %-34s %7.1f KB  内容 %.0fx%d" % [r["out"], r["kb"], r["cw"], r["ch"]])
	print("-".repeat(76))
	print(" 共切出 %d 张" % done_rows.size())
	if failures.is_empty():
		print("  RESULT=PASS")
		quit(0)
	else:
		for m in failures:
			print("  FAIL: %s" % m)
		print("  RESULT=FAIL 失败项=%d" % failures.size())
		quit(1)


func _target_size(out_rel: String) -> Vector2i:
	for prefix in SIZE_OVERRIDES.keys():
		if out_rel.begins_with(String(prefix)):
			return SIZE_OVERRIDES[prefix]
	return ICON


func _process_sheet(sheet_name: String) -> void:
	var src := SRC_ROOT.path_join(sheet_name)
	if not FileAccess.file_exists(src):
		failures.append("缺少网格图：%s" % sheet_name)
		return
	var sheet := Image.new()
	if sheet.load(src) != OK:
		failures.append("读取失败：%s" % sheet_name)
		return
	sheet.convert(Image.FORMAT_RGBA8)

	var spec: Dictionary = MANIFEST[sheet_name]
	var outs: Array = spec["out"]
	# mode: grid（默认 2x2）/ single（整张一个）/ rows（横向切 N 条）
	var mode := String(spec.get("mode", "grid"))
	var regions: Array = []

	if mode == "single":
		regions.append([String(outs[0]), Rect2i(Vector2i.ZERO, sheet.get_size())])
	elif mode == "rows":
		var rows := int(spec.get("rows", 1))
		var bh := int(sheet.get_height() / float(rows))
		for i in rows:
			regions.append([String(outs[i]), Rect2i(Vector2i(0, i * bh),
				Vector2i(sheet.get_width(), bh))])
		print("\n%s  纵向 %d 联，每条 %dx%d，应产出 %d 张" % [
			sheet_name, rows, sheet.get_width(), bh, outs.size(),
		])
	else:
		var grid: Vector2i = spec["size"]
		var cw := int(sheet.get_width() / float(grid.x))
		var ch := int(sheet.get_height() / float(grid.y))
		print("\n%s  %dx%d 格，每格 %dx%d，应产出 %d 张" % [
			sheet_name, grid.x, grid.y, cw, ch, outs.size(),
		])
		for i in outs.size():
			var cell := Vector2i(i % grid.x, int(i / grid.x))
			regions.append([String(outs[i]),
				Rect2i(Vector2i(cell.x * cw, cell.y * ch), Vector2i(cw, ch))])

	for entry in regions:
		var out_rel := String(entry[0])
		var rect: Rect2i = entry[1]
		var cell_img := sheet.get_region(rect)
		cell_img.convert(Image.FORMAT_RGBA8)
		_remove_bg(cell_img)

		var box := _alpha_box(cell_img, 32)
		if box.size.x <= 0 or box.size.y <= 0:
			if out_rel.is_empty():
				print("  槽位空（符合预期）")
				continue
			failures.append("%s 某槽位没有内容" % sheet_name)
			continue
		if out_rel.is_empty():
			failures.append("%s 某槽位应为空却有内容（提示词没让留白？）" % sheet_name)
			continue

		var content := cell_img.get_region(box)
		var target := _target_size(out_rel)
		var out_img := _fit_into(content, target)
		var dst := DST_ROOT.path_join(out_rel)
		DirAccess.make_dir_recursive_absolute(dst.get_base_dir())
		var err := out_img.save_png(dst)
		if err != OK:
			failures.append("写出失败(%d)：%s" % [err, dst])
			continue
		done_rows.append({
			"out": out_rel,
			"kb": FileAccess.get_file_as_bytes(dst).size() / 1024.0,
			"cw": content.get_width(),
			"ch": content.get_height(),
		})


## 洪水填充抠背景：与 _remove_bg.py 同算法同参数。
##
## ⚠️ GDScript 里 PackedByteArray / PackedInt32Array 是【按值传递】的 ——
## 把它们传进辅助函数改的是副本，主流程里什么都收不到（实测：背景完全没被抠掉，
## 每格整块 512x512 原样缩放输出）。所以 BFS 必须内联在本函数里，不能抽成小函数。
func _remove_bg(img: Image) -> void:
	img.convert(Image.FORMAT_RGBA8)
	var w := img.get_width()
	var h := img.get_height()
	var data := img.get_data()

	# 四角各采 12x12 求平均作为背景色
	var sr := 0.0
	var sg := 0.0
	var sb := 0.0
	var n := 0
	for cy in 2:
		for cx in 2:
			for y in mini(12, h):
				for x in mini(12, w):
					# cy/cx=0 取左上角，=1 取右下角：行/列都要从对应边【往回数】
					# （之前写成 cy*(h-1)+y，cy=1 时行号直接越界，异常把整个抠图中断了）
					var ry := y if cy == 0 else (h - 1 - y)
					var rx := x if cx == 0 else (w - 1 - x)
					var o := (ry * w + rx) * 4
					sr += data[o]
					sg += data[o + 1]
					sb += data[o + 2]
					n += 1
	var kr := sr / n
	var kg := sg / n
	var kb := sb / n

	var is_bg := PackedByteArray()
	is_bg.resize(w * h)
	is_bg.fill(0)
	var queue := PackedInt32Array()
	var head := 0

	# 从四边播种（内联）
	for x in w:
		for idx: int in [x, (h - 1) * w + x]:
			if is_bg[idx] == 0:
				var o := idx * 4
				var dd := sqrt(pow(data[o] - kr, 2) + pow(data[o + 1] - kg, 2)
					+ pow(data[o + 2] - kb, 2))
				if dd < T_HIGH:
					is_bg[idx] = 1
					queue.append(idx)
	for y in h:
		for idx: int in [y * w, y * w + w - 1]:
			if is_bg[idx] == 0:
				var o := idx * 4
				var dd := sqrt(pow(data[o] - kr, 2) + pow(data[o + 1] - kg, 2)
					+ pow(data[o + 2] - kb, 2))
				if dd < T_HIGH:
					is_bg[idx] = 1
					queue.append(idx)

	# BFS 扩散（内联）
	while head < queue.size():
		var idx := queue[head]
		head += 1
		var x := idx % w
		var y := int(idx / float(w))
		for nb: int in [idx - 1 if x > 0 else -1, idx + 1 if x < w - 1 else -1,
				idx - w if y > 0 else -1, idx + w if y < h - 1 else -1]:
			if nb < 0 or is_bg[nb] != 0:
				continue
			var o := nb * 4
			var dd := sqrt(pow(data[o] - kr, 2) + pow(data[o + 1] - kg, 2)
				+ pow(data[o + 2] - kb, 2))
			if dd < T_HIGH:
				is_bg[nb] = 1
				queue.append(nb)

	# 按到背景色的距离改写 alpha
	for i in w * h:
		if is_bg[i] == 0:
			continue
		var o := i * 4
		var d := sqrt(pow(data[o] - kr, 2) + pow(data[o + 1] - kg, 2) + pow(data[o + 2] - kb, 2))
		var a := 0
		if d >= T_LOW:
			a = int(255.0 * (d - T_LOW) / (T_HIGH - T_LOW))
			if a > 255:
				a = 255
		data[o + 3] = a
	img.set_data(w, h, false, Image.FORMAT_RGBA8, data)


func _alpha_box(img: Image, threshold: int) -> Rect2i:
	var w := img.get_width()
	var h := img.get_height()
	var data := img.get_data()
	var minx := w
	var miny := h
	var maxx := -1
	var maxy := -1
	for y in h:
		for x in w:
			if data[(y * w + x) * 4 + 3] > threshold:
				if x < minx:
					minx = x
				if y < miny:
					miny = y
				if x > maxx:
					maxx = x
				if y > maxy:
					maxy = y
	if maxx < 0:
		return Rect2i(0, 0, 0, 0)
	return Rect2i(minx, miny, maxx - minx + 1, maxy - miny + 1)


## 等比缩放使内容【占满目标短边】，居中贴到透明画布上。
func _fit_into(content: Image, target: Vector2i) -> Image:
	var out := Image.create(target.x, target.y, false, Image.FORMAT_RGBA8)
	out.fill(Color(0, 0, 0, 0))
	var iw := content.get_width()
	var ih := content.get_height()
	var s := minf(float(target.x) / iw, float(target.y) / ih)
	var nw := maxi(1, int(round(iw * s)))
	var nh := maxi(1, int(round(ih * s)))
	var scaled := content.duplicate() as Image
	if nw != iw or nh != ih:
		scaled.resize(nw, nh, Image.INTERPOLATE_LANCZOS)
	var dst := Vector2i(int((target.x - nw) / 2.0), int((target.y - nh) / 2.0))
	out.blend_rect(scaled, Rect2i(Vector2i.ZERO, Vector2i(nw, nh)), dst)
	return out
