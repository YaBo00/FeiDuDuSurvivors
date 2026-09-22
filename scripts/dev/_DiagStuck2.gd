extends SceneTree
## 诊断：清场阶段卡住的敌人到底是什么状态（v2，字段对齐真实 API）。
## 复现 selftest 条件（god_mode + autopilot），跑到目标波清场阶段后 dump 现场。
## 用法：godot --headless --path <project> --script res://scripts/dev/_DiagStuck2.gd

var _battle = null
var _frame := 0
var _dump_count := {}
var _armed := false

const TARGET_WAVE := 9


func _initialize() -> void:
	var packed = load("res://scenes/battle/Battle.tscn")
	_battle = packed.instantiate()
	root.add_child(_battle)
	_battle.selftest = true
	print("[DIAG2] battle added; 目标波=%d" % TARGET_WAVE)


func _process(_delta: float) -> bool:
	_frame += 1
	if _frame < 3 or _battle == null:
		return false
	if _battle.player == null:
		return false
	# @onready 字段在入树后才解析 —— autopilot/god_mode 必须推迟到这里设
	if not _armed:
		_armed = true
		_battle.player.autopilot = true
		_battle.player.god_mode = true
		print("[DIAG2] 已启用 autopilot + god_mode；当前波=%d 场上=%d" % [
			_battle.wave_num, _battle.enemies.size()])
		return false

	var w: int = _battle.wave_num
	if w < TARGET_WAVE:
		if _frame > 30000:
			print("[DIAG2] 超时未到达目标波（当前 %d）" % w)
			quit(1)
			return true
		return false

	var wave = _battle.wave
	if not wave.spawn_window_closed():
		return false
	var n_cur: int = _battle.enemies.size()
	if n_cur <= 0:
		return false

	var n: int = _dump_count.get(w, 0)
	# 场上数目变化时立刻 dump（关键：看卡住的那一刻），外加每 60 帧一次
	if n > 0 and _frame % 60 != 0:
		return false
	if n >= 8:
		return false
	_dump_count[w] = n + 1

	var p = _battle.player
	print("========== [DIAG2] 波%d dump #%d frame=%d ==========" % [w, n + 1, _frame])
	print("  玩家 pos=(%.0f,%.0f) 射程=%.0f spd=%.1f hp=%.0f 速度向量=(%.1f,%.1f) 场上=%d" % [
		p.global_position.x, p.global_position.y, p.attack_range, p.spd,
		p.hp, p.velocity.x, p.velocity.y, n_cur])
	print("  timer=%.1f 窗口关=%s 补投=%s 累计投放=%d 本波击杀=%d 玩家总击杀=%d" % [
		_battle.wave_timer, str(wave.spawn_window_closed()), str(wave.spawn_flushed),
		wave.spawned_count(), wave.killed_count(), _battle.kills])
	var i := 0
	for e in _battle.enemies:
		i += 1
		if i > 15:
			print("  ...(还有 %d 只)" % (n_cur - 15))
			break
		if not is_instance_valid(e):
			print("  [%d] <invalid>" % i)
			continue
		var en: Node2D = e
		var d: float = p.global_position.distance_to(en.global_position)
		var in_range: bool = d <= p.attack_range
		print("  [%d] %s/%s dead=%s pos=(%.0f,%.0f) dist=%.0f 在射程=%s hp=%d/%d spd=%.1f" % [
			i, str(e.type_name), str(e.behavior), str(e.is_dead),
			en.global_position.x, en.global_position.y, d, str(in_range),
			e.hp, e.max_hp, e.speed])

	if n + 1 >= 8:
		quit(0)
		return true
	return false
