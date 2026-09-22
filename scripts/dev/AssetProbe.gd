extends SceneTree
## 门禁：美术资源完整性
##
## 断言 AssetDB 里登记的【每一个】资源：
##   1. 能加载成 Texture2D
##   2. 尺寸与 AssetDB.EXPECT 声明的一致
##   3. alpha 通道符合预期（sprite 要有、不透明背景要没有）
##   4. 已经生成 mipmap（sprite 缩小到屏幕上约 1/6，没有 mipmap 会锯齿+抖动）
## 并顺便估算显存占用。
##
## 用法: godot --headless --path <项目> --script res://scripts/dev/AssetProbe.gd
## 退出码 0=PASS 1=FAIL。

var _failures: Array[String] = []
var _rows: Array = []
var _gpu_bytes := 0


func _initialize() -> void:
	print("=".repeat(76))
	print(" 门禁：美术资源完整性（AssetDB 登记项）")
	print("=".repeat(76))

	var paths := AssetDB.all_paths()
	print("  登记资源数 = %d" % paths.size())

	for rel in paths:
		_check_one(rel)

	print("\n 明细（按类别）")
	print("  %-42s %-11s %-9s %s" % ["资源", "尺寸", "mipmap", "alpha"])
	print("  " + "-".repeat(72))
	for r in _rows:
		print("  %-42s %-11s %-9s %s" % [r["rel"], r["size"], r["mip"], r["alpha"]])

	print("\n" + "=".repeat(76))
	print(" 汇总")
	print("=".repeat(76))
	print("  文件数        : %d" % _rows.size())
	print("  估算显存      : %.1f MB（按 RGBA8/RGB8 解码后 + mipmap 链约 +33%%）" % [
		_gpu_bytes * 1.333 / 1048576.0,
	])

	if _failures.is_empty():
		print("  RESULT=PASS")
		quit(0)
	else:
		for m in _failures:
			print("  FAIL: %s" % m)
		print("  RESULT=FAIL 失败项=%d" % _failures.size())
		quit(1)


func _expect_for(rel: String) -> Dictionary:
	if AssetDB.EXPECT.has(rel):
		return AssetDB.EXPECT[rel]
	for prefix in AssetDB.EXPECT.keys():
		if rel.begins_with(prefix):
			return AssetDB.EXPECT[prefix]
	return {}


## 挡「深色被误抠成半透明」这个真实踩过的坑。
##
## 成因：上游抠图脚本从【左上角】采样背景色，若图送来时左上角已是全透明（RGBA=0,0,0,0），
##       采到的背景色就是【纯黑】，于是人物身上的黑色（粗描边 / 黑衣服）与背景同色被判成背景抠掉。
##       实测「嘉豪」的 10 帧整帧变成近乎透明的幽灵（低 alpha 像素 3200+ 而高 alpha 只有 356）。
##
## 判定：低 alpha（1~63）像素数 > 高 alpha（>=200）像素数。健康素材该比值实测 0.05~0.11，
##       损坏时是 9 —— 差两个数量级，不会误报。
func _check_alpha_health(rel: String, img: Image) -> void:
	img.convert(Image.FORMAT_RGBA8)
	var data := img.get_data()
	var n := img.get_width() * img.get_height()
	var low := 0
	var high := 0
	for i in n:
		var a := data[i * 4 + 3]
		if a > 0 and a < 64:
			low += 1
		elif a >= 200:
			high += 1
	if high <= 0:
		_failures.append("整张图没有不透明像素（可能被抠空了）：%s" % rel)
		return
	if low > high:
		_failures.append(
			"疑似「深色被误抠成半透明」：%s 低alpha=%d 高alpha=%d（比值 %.1f，正常应 <0.2）" % [
				rel, low, high, float(low) / float(high),
			])


func _check_one(rel: String) -> void:
	var p := AssetDB.path_of(rel)
	if not ResourceLoader.exists(p):
		_failures.append("资源不存在：%s" % p)
		return
	var res := load(p)
	if not (res is Texture2D):
		_failures.append("不是 Texture2D：%s" % p)
		return
	var tex: Texture2D = res
	var w := tex.get_width()
	var h := tex.get_height()

	var exp := _expect_for(rel)
	var mip := "?"
	var has_alpha := "?"

	# 用解码后的 Image 检查实际像素格式与 mipmap
	var img := tex.get_image()
	if img == null:
		_failures.append("取不到 Image（可能未导入）：%s" % p)
	else:
		has_alpha = "有" if img.detect_alpha() else "无"
		mip = "有" if img.has_mipmaps() else "无"
		var bpp := 4 if img.detect_alpha() else 3
		_gpu_bytes += w * h * bpp
		if not img.has_mipmaps():
			_failures.append("缺 mipmap：%s（缩小显示会出现锯齿/抖动）" % rel)
		if not exp.is_empty():
			if exp["alpha"] and not img.detect_alpha():
				_failures.append("应为带 alpha，实际没有：%s" % rel)
			if not exp["alpha"] and img.detect_alpha():
				_failures.append("应为不透明，实际带 alpha：%s" % rel)
		if img.detect_alpha():
			_check_alpha_health(rel, img)

	if not exp.is_empty():
		var want: Vector2i = exp["size"]
		if w != want.x or h != want.y:
			_failures.append("尺寸不符：%s 期望 %dx%d 实际 %dx%d" % [rel, want.x, want.y, w, h])

	_rows.append({"rel": rel, "size": "%dx%d" % [w, h], "mip": mip, "alpha": has_alpha})
