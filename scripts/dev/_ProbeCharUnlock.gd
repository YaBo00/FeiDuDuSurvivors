extends SceneTree
## 独立验证探针：角色解锁 + 模拟充值流程（2026-09-20 用户需求）。
##
## 被验证的契约：
##   MetaSave.is_char_unlocked / unlock_char（默认仅 basic / 幂等 / 持久化 / 脏 id 拒收）
##   CharSelect：未解锁卡带 LockTag 角标且压暗；已解锁卡无角标
##   点击未解锁卡（_select 真实方法）→ 充值弹窗出现（_pay_layer）
##   _confirm_recharge → 「充值成功」提示 + 解锁落盘 → 定时后弹窗关闭 + 界面刷新 + 自动选中
##
## 用法: godot --headless --path <项目> --script res://scripts/dev/_ProbeCharUnlock.gd
## 退出码 0=PASS 1=FAIL（门禁用 grep -q "RESULT=PASS" 判定）

const PROBE_PATH := "user://probe_char_unlock.json"

var sel: Node = null          # CharSelect 实例
var phase := 0                # 0=静态断言 1=等弹窗自动关闭 2=收尾
var t_wait := 0.0
var finished := false
var checks := 0
var fails: Array[String] = []


func _initialize() -> void:
	print("[PROBE] === 角色解锁 + 模拟充值验证 ===")
	MetaSave.save_path = PROBE_PATH
	_del_save()
	var packed: PackedScene = load("res://scenes/main/CharSelect.tscn")
	if packed == null:
		_finish("CharSelect.tscn 加载失败")
		return
	sel = packed.instantiate()
	root.add_child(sel)


func _arm() -> void:
	# ---- A. MetaSave 静态契约 ----
	_check(MetaSave.is_char_unlocked("basic"), "默认解锁：basic 已解锁")
	var locked_ids: Array[String] = []
	for id in GameStats.character_ids():
		if String(id) != "basic" and not MetaSave.is_char_unlocked(String(id)):
			locked_ids.append(String(id))
	_check(locked_ids.size() == GameStats.character_ids().size() - 1,
		"其余 %d 名角色默认全部未解锁" % locked_ids.size())
	_check(MetaSave.unlock_char("study"), "unlock_char(study) 成功")
	_check(MetaSave.unlock_char("study"), "重复解锁幂等（仍成功）")
	_check(not MetaSave.unlock_char("not_a_char"), "非法角色 id 拒收")
	var d: Dictionary = MetaSave.ledger()
	_check((d["unlocked_chars"] as Array).has("study"), "解锁已落盘（ledger 重读一致）")
	_del_save()
	# 恢复干净档（下面的 UI 流程从未解锁态开始）

	# ---- B. CharSelect 锁定渲染 ----
	var lock_count := 0
	for b in sel._thumbs:
		if b.get_node_or_null("LockTag") != null:
			lock_count += 1
	_check(lock_count == GameStats.character_ids().size() - 1,
		"未解锁卡带「未解锁」角标（%d/%d）" % [lock_count, GameStats.character_ids().size() - 1])

	# ---- C. 点击未解锁卡 → 充值弹窗（走真实 _select 方法链）----
	sel._select("sad")
	_check(sel._pay_layer != null, "点击未解锁角色 → 充值弹窗出现")
	_check(sel._selected != "sad", "弹窗期间选中态不变（仍为 %s）" % str(sel._selected))
	_check(not MetaSave.is_char_unlocked("sad"), "弹窗未确认前角色未解锁")

	# ---- D. 确认支付 → 充值成功提示 + 解锁落盘 ----
	sel._confirm_recharge("sad")
	_check(MetaSave.is_char_unlocked("sad"), "确认后解锁落盘")
	var center = (sel._pay_layer.get_child(0) as CenterContainer).get_child(0)
	var texts := ""
	for child in center.get_children():
		for sub in child.get_children():
			if sub is Label:
				texts += String(sub.text)
	_check(texts.contains("充值成功"), "弹窗显示「充值成功」提示")
	phase = 1
	t_wait = 0.0


func _late() -> void:
	# ---- E. 定时器到点：弹窗关闭 + 界面刷新 + 自动选中 ----
	_check(sel._pay_layer == null, "提示后弹窗自动关闭")
	var lock_count2 := 0
	for b in sel._thumbs:
		if b.get_node_or_null("LockTag") != null:
			lock_count2 += 1
	_check(lock_count2 == GameStats.character_ids().size() - 2,
		"界面已刷新：sad 的角标摘除（剩 %d 张锁定卡）" % lock_count2)
	_check(sel._selected == "sad", "自动选中刚解锁的角色")
	_finish("")


func _del_save() -> void:
	if FileAccess.file_exists(PROBE_PATH):
		DirAccess.remove_absolute(PROBE_PATH)


func _check(cond: bool, label: String) -> void:
	checks += 1
	if cond:
		print("[PROBE]   OK   %s" % label)
	else:
		fails.append(label)
		print("[PROBE]   FAIL %s" % label)


func _process(delta: float) -> bool:
	if finished:
		return true
	if phase == 0:
		_arm()
		return false   # ⚠️ return true = 退出主循环：本探针还有等待阶段，必须继续跑
	if phase == 1:
		t_wait += delta
		if sel._pay_layer == null or t_wait > 3.0:
			phase = 2
			_late()
		return false
	return false


func _finish(msg: String) -> void:
	if finished:
		return
	finished = true
	if msg != "":
		print("[PROBE] 提前终止：%s" % msg)
	_del_save()
	print("[PROBE] 断言 %d/%d 通过（失败 %d）" % [checks - fails.size(), checks, fails.size()])
	for f in fails:
		print("[PROBE]   - %s" % f)
	print("[PROBE] RESULT=%s" % ("PASS" if fails.is_empty() else "FAIL"))
	quit(0 if fails.is_empty() else 1)
