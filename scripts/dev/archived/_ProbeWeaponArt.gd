extends SceneTree
## 门禁：武器弹道美术接线（2026-09-19 weapons 批次）
##
## AssetProbe 只证明「贴图导入且规格正确」；本探针证明「弹道真的用上了它们」：
##   1. 四个角色都有弹道配置，且贴图真实加载
##   2. sheet 切帧参数自洽：纹理宽 == (frames-1)*step + fw
##      （金币 3*108+96=420，暗影 3*144+128=560，与 美术资源\weapons\导入流程.md 一致）
##   3. Projectile.apply_visual 后字段正确；advance 按 fps 推进帧序号并循环
##   4. 未登记角色 → weapon_bullet 返回空 → Projectile 保持图元回落（bullet_tex 为 null）
##
## 用法: godot --headless --path <项目> --script res://scripts/dev/_ProbeWeaponArt.gd
## 退出码 0=PASS 1=FAIL。

var _fails: Array[String] = []


func _initialize() -> void:
	print("=".repeat(72))
	print(" 门禁：武器弹道美术接线")
	print("=".repeat(72))

	# ---- 1/2：逐角色配置与切帧自洽 ----
	for id in GameStats.character_ids():
		var cid := String(id)
		var cfg := AssetDB.weapon_bullet(cid)
		if cfg.is_empty():
			_fails.append("角色 %s 没有可用的弹道配置（未登记或贴图缺失）" % cid)
			continue
		var frames := int(cfg["frames"])
		var fw := int(cfg["fw"])
		var fh := int(cfg["fh"])
		var step := int(cfg["step"])
		var t: Texture2D = cfg["texture"]
		var expect_w: int = (frames - 1) * step + fw
		if t.get_width() != expect_w or t.get_height() != fh:
			_fails.append("%s 贴图 %dx%d 与切帧参数不符（期望 %dx%d）" % [
				cid, t.get_width(), t.get_height(), expect_w, fh])
		print("  %-8s %-30s %dx%d frames=%d step=%-4d fps=%.1f cell=%.0f" % [
			cid, cfg["tex"], t.get_width(), t.get_height(), frames, step,
			float(cfg["fps"]), float(cfg["cell_px"])])

	# ---- 3：Projectile 行为（金币旋转：4 帧 @10fps，step=108）----
	var p := Projectile.new()
	p.apply_visual(AssetDB.weapon_bullet("finance"))
	if p.bullet_tex == null or p.frames != 4 or p.frame_step != 108 or p.frame_w != 96:
		_fails.append("finance 弹道未接上金币旋转贴图（tex=%s frames=%d step=%d fw=%d）" % [
			p.bullet_tex != null, p.frames, p.frame_step, p.frame_w])
	for i in 37:
		p.advance(1.0 / 10.0)   # 3.7 秒 @10fps → 帧序号应在 0..3 循环
	if p._frame_idx < 0 or p._frame_idx > 3:
		_fails.append("帧序号越界：%d" % p._frame_idx)
	if p.frame_h != 96 or p.cell_px != 42.0:
		_fails.append("finance 显示参数未生效（fh=%d cell_px=%.1f）" % [p.frame_h, p.cell_px])
	p.free()

	# 单帧图的内容中心对齐（粉笔弹实测内容包围盒 Rect2(23,0,39,35) → 中心 (42.5,17.5)，
	# 而画布中心是 (32,32) —— 不按内容中心对齐就会偏 10px+）
	var c := Projectile.new()
	c.apply_visual(AssetDB.weapon_bullet("study"))
	if c.bullet_tex == null or c.content_center != Vector2(42.5, 17.5):
		_fails.append("study 内容中心未按实测对齐（center=%s）" % c.content_center)
	c.free()

	# ---- 4：未登记角色必须保持图元回落 ----
	var q := Projectile.new()
	q.apply_visual(AssetDB.weapon_bullet("nonexistent"))
	if q.bullet_tex != null:
		_fails.append("空配置不应设置贴图（回落机制被破坏）")
	q.free()

	if _fails.is_empty():
		print("  RESULT=PASS")
		quit(0)
	else:
		for m in _fails:
			printerr("  FAIL: %s" % m)
		print("  RESULT=FAIL 失败项=%d" % _fails.size())
		quit(1)
