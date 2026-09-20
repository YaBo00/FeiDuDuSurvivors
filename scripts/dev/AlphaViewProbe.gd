extends SceneTree
## 把 alpha 通道渲染成 ASCII 图，直接「看」动画帧是不是被抠空了。
## 用法: godot --headless --path <项目> --script res://scripts/dev/_ProbeAlphaAscii.gd
##
## 图例:  ' '=完全透明   '.'=alpha 1~63（发虚）   '+'=64~199（半透明）   '#'=>=200（实心）

const SAMPLES := [
	"anim/basic/idle/idle_0.png",     # 可疑：黑描边+黑卫衣
	"anim/basic/run/run_0.png",       # 可疑
	"anim/study/idle/idle_0.png",     # 对照：颜色多
	"anim/enemies/feidaduo/idle/idle_0.png",  # 对照：明黄
]

const COLS := 56   # ASCII 宽度


func _initialize() -> void:
	for rel in SAMPLES:
		var t := AssetDB.tex(rel)
		if t == null:
			print("%s 加载失败" % rel)
			continue
		var img := t.get_image()
		img.convert(Image.FORMAT_RGBA8)
		var w := img.get_width()
		var h := img.get_height()
		var rows := int(round(float(h) / w * COLS * 0.5))   # 字符高宽比约 2:1
		print("\n" + "=".repeat(COLS + 20))
		print(" %s   (%dx%d)" % [rel, w, h])
		print("=".repeat(COLS + 20))
		for ry in rows:
			var line := ""
			for rx in COLS:
				var maxa := 0
				var x0 := int(float(rx) * w / COLS)
				var x1 := maxi(x0 + 1, int(float(rx + 1) * w / COLS))
				var y0 := int(float(ry) * h / rows)
				var y1 := maxi(y0 + 1, int(float(ry + 1) * h / rows))
				for y in range(y0, mini(y1, h)):
					for x in range(x0, mini(x1, w)):
						maxa = maxi(maxa, img.get_pixel(x, y).a8)
				if maxa == 0:
					line += " "
				elif maxa < 64:
					line += "."
				elif maxa < 200:
					line += "+"
				else:
					line += "#"
			print(" " + line)
	quit(0)
