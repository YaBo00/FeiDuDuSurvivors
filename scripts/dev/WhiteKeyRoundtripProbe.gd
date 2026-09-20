extends SceneTree
## 验证：「纯白背景 + 洪水填充抠图」这条路到底行不行。
##
## 动机：我在《美术资源补充需求与提示词》里建议用户让 AI 在【纯白背景】上出图，
##       再由脚本抠掉。如果这条路效果不好，用户会生成几十张之后才发现 —— 那时成本已经付了。
##       所以现在就用现有素材做一次【往返测试】验掉这个风险：
##         原图（带 alpha） → 压到纯白底上（模拟 AI 出图） → 洪水填充抠图 → 与原 alpha 对比
##
## 用法: godot --headless --path <项目> --script res://scripts/dev/_ProbeWhiteKeyRoundtrip.gd

## 与 _remove_bg.py 保持一致的阈值，这样结论才对得上用户实际用的脚本
const T_LOW := 35.0
const T_HIGH := 95.0

const SAMPLES := [
	"chars/basic.png",
	"enemies/slime.png",
	"enemies/feidaduo.png",
	"items/helmet.png",
	"items/scooter.png",
	"items/milk.png",
	"items/mj_gloves.png",
	"drops/gold.png",
	"ui/slot_empty.png",
	"anim/basic/idle/idle_0.png",
]


func _initialize() -> void:
	print("=".repeat(96))
	print(" 纯白底 → 洪水填充抠图 往返测试（阈值 T_LOW=%.0f T_HIGH=%.0f，与 _remove_bg.py 一致）" % [T_LOW, T_HIGH])
	print("=".repeat(96))
	print(" %-34s %-8s %-12s %-12s %s" % ["资源", "不透明像素", "漏抠(残留)", "误抠(被吃掉)", "边缘过渡带宽"])
	print("-".repeat(96))

	var worst := 0.0
	for rel in SAMPLES:
		var src := AssetDB.tex(rel)
		if src == null:
			print(" %-34s 加载失败" % rel)
			continue
		var orig := src.get_image()
		orig.convert(Image.FORMAT_RGBA8)

		# ---- 1. 压到纯白底（模拟 AI 出的白底图）----
		var flat := Image.create(orig.get_width(), orig.get_height(), false, Image.FORMAT_RGBA8)
		flat.fill(Color(1, 1, 1, 1))
		flat.blend_rect(orig, Rect2i(Vector2i.ZERO, orig.get_size()), Vector2i.ZERO)

		# ---- 2. 抠图 ----
		_remove_bg(flat)
		flat.convert(Image.FORMAT_RGBA8)

		# ---- 3. 对比二值遮罩 ----
		var w := orig.get_width()
		var h := orig.get_height()
		var data_o := orig.get_data()
		var data_f := flat.get_data()
		var opaque := 0
		var missed := 0      # 原图不透明、抠完却透明了 → 被吃掉
		var leaked := 0      # 原图透明、抠完却不透明 → 残留
		var soft := 0        # 抠完处于中间 alpha → 边缘羽化带
		for i in w * h:
			var ao := data_o[i * 4 + 3]
			var af := data_f[i * 4 + 3]
			if ao > 128:
				opaque += 1
				if af <= 128:
					missed += 1
			else:
				if af > 128:
					leaked += 1
			if af > 10 and af < 245:
				soft += 1
		if opaque == 0:
			print(" %-34s 没有不透明像素，跳过" % rel)
			continue
		var miss_pct := 100.0 * missed / opaque
		var leak_pct := 100.0 * leaked / maxf(1.0, float(w * h - opaque))
		var soft_pct := 100.0 * soft / opaque
		worst = maxf(worst, miss_pct)
		print(" %-34s %-8d %-12s %-12s %.1f%%" % [
			rel, opaque,
			"%d (%.2f%%)" % [missed, miss_pct],
			"%d (%.2f%%)" % [leaked, leak_pct],
			soft_pct,
		])

	print("-".repeat(96))
	print(" 判读：")
	print("   漏抠 / 误抠 = 抠图把该留的吃掉了 / 该去的没去掉。这两个数应该都接近 0。")
	print("   边缘过渡带 = 描边与白底之间的羽化像素占不透明区比例，稍高是正常的（抗锯齿边）。")
	print("   最差漏抠率 = %.2f%%" % worst)
	if worst < 1.0:
		print(" RESULT=PASS：纯白底 + 洪水填充这条路可用，提示词里的『纯白背景』建议成立。")
		quit(0)
	else:
		print(" RESULT=CONCERN：存在明显误抠，需要换背景色或调整阈值 —— 先别让用户批量生成。")
		quit(1)


## 与 _remove_bg.py 同算法：角落采样背景色 + 从四边洪水填充 + 按距离羽化 alpha
func _remove_bg(img: Image) -> void:
	img.convert(Image.FORMAT_RGBA8)
	var w := img.get_width()
	var h := img.get_height()
	var data := img.get_data()

	# 角落 12x12 采样求平均，作为背景色
	var sr := 0
	var sg := 0
	var sb := 0
	var n := 0
	for y in mini(12, h):
		for x in mini(12, w):
			var i := (y * w + x) * 4
			sr += data[i]
			sg += data[i + 1]
			sb += data[i + 2]
			n += 1
	var kr := float(sr) / n
	var kg := float(sg) / n
	var kb := float(sb) / n

	var is_bg := PackedByteArray()
	is_bg.resize(w * h)
	is_bg.fill(0)

	var queue := PackedInt32Array()
	var push := func(idx: int) -> void:
		if is_bg[idx] != 0:
			return
		var o := idx * 4
		var d := sqrt(pow(data[o] - kr, 2) + pow(data[o + 1] - kg, 2) + pow(data[o + 2] - kb, 2))
		if d < T_HIGH:
			is_bg[idx] = 1
			queue.append(idx)

	for x in w:
		push.call(x)
		push.call((h - 1) * w + x)
	for y in h:
		push.call(y * w)
		push.call(y * w + w - 1)

	var head := 0
	while head < queue.size():
		var idx := queue[head]
		head += 1
		var x := idx % w
		var y := idx / w
		if x > 0:
			push.call(idx - 1)
		if x < w - 1:
			push.call(idx + 1)
		if y > 0:
			push.call(idx - w)
		if y < h - 1:
			push.call(idx + w)

	# 按到背景色的距离改写 alpha
	for idx in w * h:
		if is_bg[idx] == 0:
			continue
		var o := idx * 4
		var d := sqrt(pow(data[o] - kr, 2) + pow(data[o + 1] - kg, 2) + pow(data[o + 2] - kb, 2))
		var a := 0
		if d >= T_LOW:
			a = int(255.0 * (d - T_LOW) / (T_HIGH - T_LOW))
			if a > 255:
				a = 255
		data[o + 3] = a
	img.set_data(w, h, false, Image.FORMAT_RGBA8, data)
