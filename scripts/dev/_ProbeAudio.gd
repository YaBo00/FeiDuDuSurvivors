extends SceneTree
## 独立验证探针：音频链路（11 个音效 + BGM 循环）。
##
## 为什么值得单独守一道：BGM 从 WAV 换成 OGG 之后，「文件在不在」和
## 「引擎能不能加载成可循环的流」是两件事 —— .import 缺失 / 导入设置不对时
## ResourceLoader.exists() 会说 true，但 load() 回来的是 null。
## 本探针直接调 GameAudio 的真实载入路径，断言拿到的是【真的能播、真的会循环】的流。
##
## 用法: godot --headless --path <项目> --script res://scripts/dev/_ProbeAudio.gd
## 退出码 0=PASS 1=FAIL

const SFX: Array[String] = ["shoot", "hit", "kill", "hurt", "dodge", "coin", "xp",
	"levelup", "wave", "buy"]

var checks := 0
var fails: Array[String] = []
var armed := false


func _initialize() -> void:
	_check_sfx()
	_check_bgm()
	# 播放断言推迟到第一帧：--script 模式下 _initialize 阶段场景树尚未就绪，
	# add_child 后立刻 play() 会报 "Playback can only happen when a node is inside
	# the scene tree" —— 那是探针时序问题，不是产品问题。


func _process(_delta: float) -> bool:
	if armed:
		return true
	armed = true
	_check_playback()
	_finish()
	return true


func _check_sfx() -> void:
	print("[PROBE] --- 音效（%d 个） ---" % SFX.size())
	for name in SFX:
		var path: String = GameAudio.DIR + name + ".wav"
		var ok := ResourceLoader.exists(path)
		_check(ok, "存在 %s" % path)
		if not ok:
			continue
		var s: Resource = load(path)
		_check(s != null and s is AudioStream, "%s 可加载为 AudioStream" % name)
		if s is AudioStreamWAV:
			var w := s as AudioStreamWAV
			_check(w.get_length() > 0.0, "%s 时长 > 0（实际 %.2fs）" % [name, w.get_length()])


func _check_bgm() -> void:
	print("[PROBE] --- BGM（OGG 循环） ---")
	# 走 GameAudio 的真实载入路径，而不是自己 load —— 这条路径才是游戏里跑的
	var stream: AudioStream = GameAudio._load_bgm_stream()
	_check(stream != null, "GameAudio._load_bgm_stream() 返回非 null")
	if stream == null:
		return
	_check(stream is AudioStreamOggVorbis, "载入为 OGG（实际 %s）" % stream.get_class())
	if stream is AudioStreamOggVorbis:
		var ogg := stream as AudioStreamOggVorbis
		_check(ogg.loop, "loop == true（不循环的 BGM 播完就静音了）")
	var length := stream.get_length()
	# 素材是 45 秒循环；给足区间容差（转码不该改变时长）
	_check(length > 30.0 and length < 90.0, "时长合理（实际 %.1fs）" % length)
	# 体积回归护栏：WAV 6.9MB → OGG 应显著更小
	var ogg_path := GameAudio.DIR + "bgm.ogg"
	var size := FileAccess.get_file_as_bytes(ogg_path).size()
	_check(size > 0 and size < 2_000_000,
		"bgm.ogg 体积 < 2MB（实际 %.2f MB）—— 防退回未压缩 WAV" % (float(size) / 1048576.0))


func _check_playback() -> void:
	print("[PROBE] --- 真实播放 ---")
	var stream: AudioStream = GameAudio._load_bgm_stream()
	if stream == null:
		return
	var p := AudioStreamPlayer.new()
	root.add_child(p)
	p.stream = stream
	p.play()
	_check(p.playing, "play() 后播放器处于播放态")


func _check(cond: bool, label: String) -> void:
	checks += 1
	if cond:
		print("[PROBE]   OK   %s" % label)
	else:
		fails.append(label)
		print("[PROBE]   FAIL %s" % label)


func _finish() -> void:
	print("[PROBE] --------------------------------------------------")
	print("[PROBE] 断言 %d 项，失败 %d 项" % [checks, fails.size()])
	for f in fails:
		print("[PROBE]   - %s" % f)
	print("[PROBE] RESULT=%s" % ("PASS" if fails.is_empty() else "FAIL"))
	quit(0 if fails.is_empty() else 1)
