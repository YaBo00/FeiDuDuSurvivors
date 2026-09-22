extends SceneTree
## Diagnostic v3: watch wave 1 closely under selftest-like conditions.
## Usage: godot --headless --path <project> --script res://scripts/dev/_DiagStuck.gd

var _battle = null
var _frame := 0


func _initialize() -> void:
	var packed = load("res://scenes/battle/Battle.tscn")
	_battle = packed.instantiate()
	root.add_child(_battle)
	_battle.selftest = true
	print("[DIAG] battle added")


func _process(_delta: float) -> bool:
	_frame += 1
	if _frame < 5:
		return false
	if _battle == null:
		return false
	if _frame % 180 == 0:
		var wave = _battle.wave
		print("[DIAG] f=%d 波=%d timer=%.1f 剩余=%d 场上=%d 关闭=%s 已补投=%s kills=%d 累计投放=%d state=%d" % [
			_frame, _battle.wave_num, _battle.wave_timer, _battle.spawn_remaining,
			_battle.enemies.size(), str(wave.spawn_window_closed()),
			str(wave.spawn_flushed), _battle.kills, wave.spawned_count(), _battle.state])
	if _frame > 6000:
		var wave = _battle.wave
		print("[DIAG] 上限：波=%d timer=%.1f 剩余=%d 场上=%d 关闭=%s 已补投=%s 累计=%d" % [
			_battle.wave_num, _battle.wave_timer, _battle.spawn_remaining,
			_battle.enemies.size(), str(wave.spawn_window_closed()),
			str(wave.spawn_flushed), wave.spawned_count()])
		quit(1)
		return true
	if _battle.wave_num >= 3:
		print("[DIAG] OK 到波 %d" % _battle.wave_num)
		quit(0)
		return true
	return false
