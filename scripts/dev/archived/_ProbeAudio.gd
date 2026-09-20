extends SceneTree
## 门禁：音频接线 —— 11 个 .wav 真的能被引擎加载、真的能出声、BGM 真的循环。
##
## 背景豆包交付的音频放在 assets/audio/（16bit 立体声 40000Hz WAV，SFX 的 data 块
## 长度字段是流式写法的 0xFFFFFFFF）。接线代码（Battle 里 10 个事件 + BGM）早已预埋，
## 本探针回答三个问题：
##   1. 导入链路通不通 —— ResourceLoader 能不能拿到 AudioStreamWAV，时长对不对
##      （data 块长度字段有诈，如果导入器解析错了，时长会露馅）
##   2. play() 之后播放器真的在响（铁律 10：断言盯核心指标，不是「没崩就行」）
##   3. BGM 循环参数真的生效（loop_mode / loop_end）
##   4. 缺文件静默跳过的性质还在（播放不存在的音效不报错、无副作用）
##
## 用法: godot --headless --path <项目> --script res://scripts/dev/_ProbeAudio.gd
## 退出码 0=PASS 1=FAIL

## 各音效的预期时长（秒），来自 .workbuddy/diag/probe_audio.py 的外部实测。
## SFX 是固定 1s/2s 的 AI 生成件，尾部可能带静音，容差放宽到 ±0.4s。
const EXPECT := {
	"bgm": 45.0,
	"buy": 1.0, "coin": 1.0, "dodge": 1.0, "hit": 1.0,
	"hurt": 1.0, "kill": 1.0, "shoot": 1.0, "xp": 1.0,
	"levelup": 2.0, "wave": 2.0,
}
const TOL := 0.4

var failures: Array[String] = []


func _initialize() -> void:
	print("=".repeat(72))
	print(" 门禁：音频（11 个 wav 的加载 / 播放 / BGM 循环 / 缺文件回落）")
	print("=".repeat(72))

	# ---- 1. 导入链路：能加载、类型对、时长对 ----
	for sound in EXPECT:
		var path := "res://assets/audio/%s.wav" % sound
		if not ResourceLoader.exists(path):
			failures.append("%s.wav 未导入（ResourceLoader.exists=false）" % sound)
			print("  %-9s 未导入" % sound)
			continue
		var s: Resource = load(path)
		if s == null:
			failures.append("%s.wav load 返回 null" % sound)
			continue
		var sw := s as AudioStreamWAV
		if sw == null:
			failures.append("%s.wav 不是 AudioStreamWAV（实际是 %s）" % [sound, s.get_class()])
			continue
		var len_s := sw.get_length()
		var want := float(EXPECT[sound])
		if absf(len_s - want) > TOL:
			failures.append("%s.wav 时长 %.2fs 偏离预期 %.0fs(±%.1f) —— 导入器可能解析错了 data 块" % [
				sound, len_s, want, TOL])
		var ch := "立体声" if sw.stereo else "单声道"
		print("  %-9s %6.2fs (期望%.0f)  %5dHz %s" % [sound, len_s, want, sw.mix_rate, ch])

	# ---- 2. 真的能响：play() 之后池子里有播放器处于 playing ----
	var ga := GameAudio.new()
	root.add_child(ga)
	await process_frame   # 等 _ready 建好播放器池（铁律 12：加完子节点别立刻用）
	for sound in EXPECT:
		if sound == "bgm":
			continue
		ga.play(sound, -6.0)
		var busy := _count_playing(ga)
		if busy <= 0:
			failures.append("play('%s') 之后没有任何播放器在响" % sound)
	# 10 个音效全打出去之后，池子（10 个）应该被占满
	var total := _count_playing(ga)
	print("  连发 10 个音效后并发中的播放器：%d / 10" % total)
	if total < 10:
		failures.append("连发 10 个音效后只有 %d 个播放器在响（池子应为 10）" % total)

	# ---- 3. 缺文件回落：不存在的音效静默跳过，无副作用 ----
	var before := _count_playing(ga)
	ga.play("no_such_sound")
	if _count_playing(ga) != before:
		failures.append("播放不存在的音效不应改变任何播放器状态")

	# ---- 4. BGM：挂根节点、在播、循环参数生效、重复调用不重启 ----
	GameAudio.play_bgm(self, -10.0)
	var bgm := root.get_node_or_null("BgmPlayer") as AudioStreamPlayer
	if bgm == null:
		failures.append("play_bgm 之后 BgmPlayer 不存在")
	elif not bgm.playing:
		failures.append("BgmPlayer 存在但没在播")
	else:
		var bs := bgm.stream as AudioStreamWAV
		if bs == null:
			failures.append("BGM 的 stream 不是 AudioStreamWAV")
		elif bs.loop_mode != AudioStreamWAV.LOOP_FORWARD:
			failures.append("BGM 没有设置 LOOP_FORWARD 循环")
		elif bs.loop_end <= 0:
			failures.append("BGM loop_end 未设置（loop=%d）" % bs.loop_end)
		else:
			print("  BGM      %6.2fs  循环 loop[0..%d]  音量 %.0fdB  OK" % [
				bs.get_length(), bs.loop_end, bgm.volume_db])
	var bgm_again := root.get_node_or_null("BgmPlayer") as AudioStreamPlayer
	GameAudio.play_bgm(self, -10.0)
	if bgm_again == null or not bgm_again.playing:
		failures.append("重复调用 play_bgm 后 BGM 状态异常")

	# ---- 结论 ----
	print("-".repeat(72))
	if failures.is_empty():
		print("RESULT=PASS 音频门禁全部通过（11 wav 加载 + 播放 + BGM 循环 + 回落）")
		quit(0)
	else:
		print("RESULT=FAIL 共 %d 项：" % failures.size())
		for f in failures:
			print("   - " + f)
		quit(1)


func _count_playing(ga: Node) -> int:
	var n := 0
	for p in ga.get_children():
		if p is AudioStreamPlayer and (p as AudioStreamPlayer).playing:
			n += 1
	return n
