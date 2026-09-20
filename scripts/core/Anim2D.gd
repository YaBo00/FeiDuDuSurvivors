class_name Anim2D
extends RefCounted
## 用代码把一组 Texture2D 拼成 SpriteFrames。
## 集中在这里，避免 Player / Enemy / 后续任何需要逐帧动画的节点各写一遍。

## 造一个空的 SpriteFrames（去掉 Godot 自动加的 "default" 动画，避免留一个没用的空动画）。
static func make() -> SpriteFrames:
	var sf := SpriteFrames.new()
	if sf.has_animation("default"):
		sf.remove_animation("default")
	return sf


## 往 SpriteFrames 里加一条动画。帧为空则不加，返回 false。
static func add(sf: SpriteFrames, anim_name: String, frames: Array[Texture2D],
		fps: float = 8.0, loop: bool = true) -> bool:
	if sf == null or frames.is_empty():
		return false
	sf.add_animation(anim_name)
	sf.set_animation_speed(anim_name, fps)
	sf.set_animation_loop(anim_name, loop)
	for t in frames:
		sf.add_frame(anim_name, t)
	return true


## 便捷入口：把 [("idle", frames, fps), ...] 一次性建成 SpriteFrames。
## 全部帧都为空时返回 null —— 调用方据此回落到占位画法。
static func build(specs: Array) -> SpriteFrames:
	var sf := make()
	var any := false
	for spec in specs:
		var ok: bool = add(sf, spec[0], spec[1], spec[2] if spec.size() > 2 else 8.0)
		any = any or ok
	return sf if any else null


## 把某一帧单独包装成一条动画（给「没有序列帧、只有一张静态图」的敌人用，
## 这样 Player / Enemy 的播放入口可以完全一致）。
static func single(anim_name: String, tex: Texture2D) -> SpriteFrames:
	if tex == null:
		return null
	var sf := make()
	var one: Array[Texture2D] = [tex]
	add(sf, anim_name, one, 1.0, false)
	return sf
