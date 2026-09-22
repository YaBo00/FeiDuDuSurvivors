class_name GameAudio
extends Node
## 极简音效播放器（对象池）。哪个界面要用，就在那个界面挂一个。
##
## 素材是程序化生成的复古风格短音效（assets/audio/*.wav，合计约 66KB）。
## 缺某个音效时静默跳过 —— 「没美术也能跑」这条性质在声音上同样成立。
##
## 【PROCESS_MODE_ALWAYS】商店/升级面板弹出时整棵树被暂停，
## 但「买东西的叮当声」恰恰要在暂停期间播出来，所以本节点不受暂停影响。

const DIR := "res://assets/audio/"
const POOL := 10
## 音频总线名（2026-09-22 设置菜单）：Master 下挂两条子总线，设置里的两个滑块分别控它们。
## 运行时按需创建（AudioServer.add_bus）—— 无需 .tres 总线布局与编辑器接线，
## 「没编辑器也能跑」这条性质同样适用于音频路由。
const BUS_MUSIC := "Music"
const BUS_SFX := "SFX"

var _players: Array[AudioStreamPlayer] = []
var _streams := {}


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_ensure_bus(BUS_MUSIC)
	_ensure_bus(BUS_SFX)
	for i in POOL:
		var p := AudioStreamPlayer.new()
		p.bus = BUS_SFX        # 所有音效走 SFX 总线（音量由设置控制）
		add_child(p)
		_players.append(p)


## 播放一个音效。pitch_jitter 给一点随机音高，避免连续播放时的机械感。
func play(sound: String, volume_db := 0.0, pitch_jitter := 0.05) -> void:
	if not _streams.has(sound):
		var path := DIR + sound + ".wav"
		if not ResourceLoader.exists(path):
			return
		_streams[sound] = load(path)
	var stream: AudioStream = _streams[sound]
	if stream == null:
		return
	for p in _players:
		if not p.playing:
			p.stream = stream
			p.volume_db = volume_db
			p.pitch_scale = 1.0 + randf_range(-pitch_jitter, pitch_jitter)
			p.play()
			return


## BGM：播放器挂在 SceneTree.root 上 —— 切场景不会中断。
## 反复调用是安全的（已在播就不再触发）。文件缺失时静默跳过。
##
## 【为什么优先 OGG】BGM 是一段 45 秒循环，WAV 要 6.9MB 而 OGG(Vorbis) 只要 0.74MB
## —— 打包体积直接省掉 6.4MB。两种格式都保留支持：有 .ogg 用 .ogg，否则回落 .wav，
## 保证「素材缺失/只放了一种格式也能跑」这条性质不破。
static func play_bgm(tree: SceneTree, volume_db := -10.0) -> void:
	_ensure_bus(BUS_MUSIC)
	var existing := tree.root.get_node_or_null("BgmPlayer") as AudioStreamPlayer
	if existing != null:
		if not existing.playing:
			existing.play()
		return
	var stream := _load_bgm_stream()
	if stream == null:
		return
	var p := AudioStreamPlayer.new()
	p.name = "BgmPlayer"
	p.stream = stream
	p.bus = BUS_MUSIC          # BGM 走 Music 总线（音量由设置控制）
	p.volume_db = volume_db
	p.process_mode = Node.PROCESS_MODE_ALWAYS
	tree.root.add_child(p)
	p.play()


# ---------------------------------------------------------------- 音频总线 + 音量设置（2026-09-22）
## 取总线下标；不存在则新建一条挂在 Master 下的子总线并返回其下标。
## 幂等：重复调用不会建重复总线。
static func _ensure_bus(bus_name: String) -> int:
	var idx := AudioServer.get_bus_index(bus_name)
	if idx != -1:
		return idx
	AudioServer.add_bus()
	idx = AudioServer.get_bus_count() - 1
	AudioServer.set_bus_name(idx, bus_name)
	AudioServer.set_bus_send(idx, "Master")
	return idx


## 把 MetaSave 里存的两个音量值应用到总线。启动时 + 滑块每次变化时调用。
## 值域 [0,1] 线性 → db；v ≤ 0 时改用 mute（避免 linear_to_db(0) = -inf 的脏值）。
static func apply_volume_settings() -> void:
	_apply_bus_volume(BUS_MUSIC, float(MetaSave.get_setting("music_vol")))
	_apply_bus_volume(BUS_SFX, float(MetaSave.get_setting("sfx_vol")))


static func _apply_bus_volume(bus_name: String, v: float) -> void:
	var idx := _ensure_bus(bus_name)
	var lin := clampf(v, 0.0, 1.0)
	if lin <= 0.0:
		AudioServer.set_bus_mute(idx, true)
	else:
		AudioServer.set_bus_mute(idx, false)
		AudioServer.set_bus_volume_db(idx, linear_to_db(lin))


## 载入 BGM 并打开循环。优先 .ogg，回落 .wav。两者都没有则返回 null（静默）。
static func _load_bgm_stream() -> AudioStream:
	var ogg_path := DIR + "bgm.ogg"
	if ResourceLoader.exists(ogg_path):
		var ogg := load(ogg_path)
		if ogg is AudioStreamOggVorbis:
			# OggVorbis 的循环是资源上的一个 bool，比 WAV 的帧区间简单
			(ogg as AudioStreamOggVorbis).loop = true
			return ogg
	var wav_path := DIR + "bgm.wav"
	if ResourceLoader.exists(wav_path):
		var wav := load(wav_path) as AudioStreamWAV
		if wav != null:
			# 循环播放（AudioStreamWAV 的 loop_end 单位是「帧」= 声道样本数）
			wav.loop_mode = AudioStreamWAV.LOOP_FORWARD
			wav.loop_begin = 0
			wav.loop_end = int(wav.get_length() * float(wav.mix_rate))
			return wav
	push_warning("GameAudio: bgm.ogg / bgm.wav 均未找到，BGM 静默跳过")
	return null
