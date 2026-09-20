extends SceneTree
## 采样导入后纹理的真实像素（headless 可跑）：
## 验证 ceramic.png 导入产物是否数据正常（应为蓝色系瓷砖，中央亮蓝）。

func _initialize() -> void:
	var tex: Texture2D = load("res://assets/bg/ceramic.png")
	if tex == null:
		print("[PROBE] load 失败")
		quit(1)
		return
	print("[PROBE] tex=%s %dx%d class=%s" % [tex.resource_path, tex.get_width(), tex.get_height(), tex.get_class()])
	var img: Image = tex.get_image()
	print("[PROBE] format=%s has_mipmaps=%s" % [img.get_format(), img.has_mipmaps()])
	for p in [Vector2i(960, 540), Vector2i(100, 100), Vector2i(1800, 900), Vector2i(960, 100), Vector2i(960, 1000)]:
		print("[PROBE] pixel %s = %s" % [p, img.get_pixelv(p)])
	quit(0)
