extends SceneTree
## 临时验证：升级面板的布局回归（2026-09-20 用户报「卡跑到屏幕外 + 文字溢出卡外」）。
##   A. 3 张 / 5 张两种规模，每张卡都要完整落在 1280×720 视口内
##   B. 卡片宽度自适应：5 张时自动换行（两行），不是把卡推出屏幕
##   C. 文字标签宽度被卡片约束（固定宽度 + autowrap 开启）——防"字跑出框"
## 用法: godot --headless --path <项目> --script res://scripts/dev/_ProbeUpgradeLayout.gd

var panel = null
var frame := 0
var checks := 0
var fails: Array[String] = []


func _initialize() -> void:
	var s: GDScript = load("res://scripts/ui/UpgradePanel.gd")
	if s == null:
		print("[PROBE] 载入 UpgradePanel.gd 失败")
		quit(1)
		return
	panel = s.new()
	root.add_child(panel)


func _process(_delta: float) -> bool:
	frame += 1
	if frame == 2:
		_run()
		return true
	if frame > 2:
		return true
	return false


func _opts(n: int) -> Array:
	var out := []
	for i in n:
		out.append({
			"id": "critDmg", "name": "暴击伤害",
			"tiers": [0.30, 0.45, 0.60], "pct": true, "cost_tier": 3, "value": 0.30,
			"cost": {"name": "敌人生命 +8%"},
		})
	return out


func _run() -> void:
	for n in [3, 5]:
		_check_layout(_opts(n), n)
	print("[PROBE] 断言 %d/%d 通过（失败 %d）" % [checks - fails.size(), checks, fails.size()])
	for f in fails:
		print("[PROBE]   - %s" % f)
	print("[PROBE] RESULT=%s" % ("PASS" if fails.is_empty() else "FAIL"))
	quit(0 if fails.is_empty() else 1)


func _check_layout(opts: Array, n: int) -> void:
	panel.show_options(opts, 10, "第 10 波结束 · 测试", func(_a, _b) -> void: pass, false)
	var rows := {}
	var visible := 0
	for i in panel._buttons.size():
		var b: Button = panel._buttons[i]
		if not b.visible:
			continue
		visible += 1
		rows[int(round(b.position.y))] = true
		_check(b.position.x >= -0.5 and b.position.x + b.size.x <= GameStats.VIEW_WIDTH + 0.5,
			"%d 张：卡 %d 水平在屏内（x=%.0f w=%.0f 右缘=%.0f ≤ %.0f）" % [
				n, i, b.position.x, b.size.x, b.position.x + b.size.x, GameStats.VIEW_WIDTH])
		_check(b.position.y + b.size.y <= GameStats.VIEW_HEIGHT + 0.5,
			"%d 张：卡 %d 垂直在屏内（y=%.0f h=%.0f 下缘=%.0f ≤ %.0f）" % [
				n, i, b.position.y, b.size.y, b.position.y + b.size.y, GameStats.VIEW_HEIGHT])
	_check(visible == n, "%d 张：全部卡片可见（实际 %d）" % [n, visible])
	_check(rows.size() == (2 if n >= 5 else 1),
		"%d 张：排布为 %d 行（实际 %d）" % [n, 2 if n >= 5 else 1, rows.size()])
	# 文字：固定宽度 + autowrap（宽度必须小于卡片宽度，否则仍会溢出）
	var label: Label = panel._labels[0]
	var b0: Button = panel._buttons[0]
	_check(label.autowrap_mode != TextServer.AUTOWRAP_OFF, "%d 张：文字标签开启自动换行" % n)
	_check(label.size.x > 0.0 and label.size.x + label.position.x <= b0.size.x + 0.5,
		"%d 张：文字宽度被卡片约束（label 右缘 %.0f ≤ 卡宽 %.0f）" % [
			n, label.position.x + label.size.x, b0.size.x])
	var cost: Label = panel._cost_labels[0]
	_check(cost.autowrap_mode != TextServer.AUTOWRAP_OFF and cost.position.x + cost.size.x <= b0.size.x + 0.5,
		"%d 张：代价行同样受约束且自动换行" % n)
	_check(b0.clip_contents, "%d 张：卡片开启裁剪（超长文本不会糊到卡外）" % n)
	# 长文本实测换行：塞超长文本后行数 > 1
	label.text = "超长文本测试" + "很长的强化说明文字".repeat(6)
	var lc: int = label.get_line_count()
	_check(lc >= 2, "%d 张：超长文本实际换行（行数 %d ≥ 2）" % [n, lc])


func _check(cond: bool, label: String) -> void:
	checks += 1
	if cond:
		print("[PROBE]   OK   %s" % label)
	else:
		fails.append(label)
		print("[PROBE]   FAIL %s" % label)
