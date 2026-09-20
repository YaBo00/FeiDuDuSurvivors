extends SceneTree
## 临时诊断：量出各美术资源的【不透明内容包围盒】。
## 用途：美术图四周有透明留白，且动画帧是「统一高度 + 脚底对齐」。
##       要把精灵按正确大小放到场上、并让脚底落在节点原点上，必须先知道真实内容范围。
## 用法: godot --headless --path <项目> --script res://scripts/dev/_ProbeContentBox.gd

const SAMPLES := [
	"chars/basic.png",
	"chars/study.png",
	"chars/finance.png",
	"chars/sad.png",
	"anim/basic/idle/idle_0.png",
	"anim/basic/run/run_0.png",
	"anim/basic/run/run_3.png",
	"anim/study/idle/idle_0.png",
	"anim/finance/idle/idle_0.png",
	"anim/sad/idle/idle_0.png",
	"enemies/slime.png",
	"enemies/feidaduo.png",
	"enemies/elite.png",
	"enemies/boss.png",
	"anim/enemies/feidaduo/idle/idle_0.png",
	"anim/enemies/boss/idle/idle_0.png",
	"drops/gold.png",
	"drops/xp.png",
	"drops/hp.png",
	"items/helmet.png",
	"ui/slot_empty.png",
]


func _initialize() -> void:
	print("%-40s %-9s %-22s %-22s %s" % ["资源", "画布", "内容宽高", "内容包围盒(x,y,w,h)", "脚底行"])
	print("-".repeat(112))
	for rel in SAMPLES:
		var t := AssetDB.tex(rel)
		if t == null:
			print("%-40s 加载失败" % rel)
			continue
		var img := t.get_image()
		var box := _alpha_box(img)
		var cw := box.size.x
		var ch := box.size.y
		var foot := box.position.y + box.size.y
		print("%-40s %-9s %-22s %-22s %d" % [
			rel,
			"%dx%d" % [img.get_width(), img.get_height()],
			"%dx%d" % [cw, ch],
			"(%d,%d,%d,%d)" % [box.position.x, box.position.y, cw, ch],
			foot,
		])
	quit(0)


func _alpha_box(img: Image) -> Rect2i:
	var w := img.get_width()
	var h := img.get_height()
	var minx := w
	var miny := h
	var maxx := -1
	var maxy := -1
	for y in h:
		for x in w:
			if img.get_pixel(x, y).a > 0.02:
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
