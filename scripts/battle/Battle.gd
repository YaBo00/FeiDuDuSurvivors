class_name Battle
extends Node2D
## 战斗主控：编排 WaveDirector（波次调度）与 CombatResolver（战斗结算）。
##
## 状态机：FIGHTING →（波末 或 升级）→ UPGRADE →（选完）→ FIGHTING / 下一波 → RESULT
## 共 GameStats.WAVE_COUNT（20）波（--endless 时不限波，自检到 ENDLESS_SELFTEST_WAVES 收束）。
##
## 刷怪模型：每波在 SPAWN_WINDOW 秒内【匀速投放】固定数量的敌人（不是开局一次性全出），
## 最后几秒留给玩家清场。数量与类型随波次递增，见 GameStats.spawn_rate / spawn_types。
##
## 无头/窗口自检：-- --selftest 时自动驱动战斗场景（自动驾驶走位 + 自动选择升级），
## 结束打印结构化指标并以退出码 0(PASS)/1(FAIL) 退出。
##
## ---------------------------------------------------------------- 模块划分（2026-09-19）
## 本脚本 1238 行 → 拆成三个文件：
##   - Battle.gd        编排 + 状态机 + 相机/取景 + 地面自绘 + UI/商店桥接 + 自检
##   - WaveDirector.gd  波次倒计时/开始/结束、投放、出生点、障碍物摆放、逐波统计
##   - CombatResolver.gd 接触伤害、弹道结算、死亡掉落、空间网格、分离力、拾取驱动
##
## 【状态归属】enemies / projectiles / pickups / obstacles / spawn_remaining / wave_num /
## wave_timer / kills 等【共享黑板】刻意留在本脚本上，而不是移到模块里 ——
## 因为 5 个门禁探针（SpawnBoundsProbe / SpriteWiringProbe / ShopFlowProbe /
## _ProbePickupExpiry / _ProbeRangedBoss）直接读写这些字段（其中 _ProbeRangedBoss 会
## 【写】spawn_remaining 与 projectiles）。拆逻辑不拆状态 ⇒ 探针与门禁零改动。
##
## 方向：Battle 持有两个模块的强类型引用并调用其公开方法；
## 模块只通过 setup() 注入的句柄操作共享状态，绝不在字段上反向持有 Battle 类型。
## 反馈（飘字/爆裂/音效/震屏/hit-stop）由模块发信号 → Battle 转交 feedback/audio。

enum State { FIGHTING, UPGRADE, SHOP, RESULT }

# ---------------------------------------------------------------- 自检参数
const SELFTEST_TIME_SCALE := 6.0
const SELFTEST_TICKS := 360          # 与 time_scale 配合，保持单步 delta ≈ 1/60
## 自检允许的最长【游戏内】时长。20 波 × 30s = 600s，留出余量。
const SELFTEST_MAX_GAME_TIME := 900.0
## 无尽自检（--selftest --endless）跑 ENDLESS_SELFTEST_WAVES（40）波 ≈ 1200s，
## 900s 会误判「自检超时」→ 单独给一个更宽的上限。
const ENDLESS_SELFTEST_MAX_GAME_TIME := 1800.0

const ENEMY_SCENE := preload("res://scenes/entities/Enemy.tscn")
const PROJECTILE_SCENE := preload("res://scenes/entities/Projectile.tscn")
const PICKUP_SCENE := preload("res://scenes/entities/Pickup.tscn")
const OBSTACLE_SCENE := preload("res://scenes/entities/Obstacle.tscn")

## 飘字节流：同类飘字间隔（秒），避免怪堆里刷屏把池子打满（CombatResolver 读取）。
## 这两组常量刻意与 CombatResolver 内的同名常量【同值】，因为跨文件 const 引用
## 在双向 class_name 依赖下容易踩到解析顺序问题 —— 用小额重复换取零风险。
const FLOAT_THROTTLE := 0.25
## 分离力的执行频率与配对预算（CombatResolver 读取）
const SEP_EVERY := 3
const SEP_BUDGET := 2400

@onready var world: Node2D = $World
@onready var player: Player = $World/Player
@onready var camera: Camera2D = $Camera2D
@onready var hud: Hud = $Hud
@onready var upgrade_panel: UpgradePanel = $UpgradePanel
@onready var result_panel: ResultPanel = $ResultPanel
@onready var shop_panel: ShopPanel = $ShopPanel
@onready var pause_menu: PauseMenu = $PauseMenu
## 虚拟摇杆（批次四 4a）。场景里没有该节点时为 null，触摸链路整体跳过（键盘不受影响）。
@onready var touch: TouchControls = get_node_or_null("TouchControls") as TouchControls
## 音效播放器（对象池）。
var audio: GameAudio = null
## 反馈层（伤害飘字/击杀爆裂/波次横幅）
var feedback: BattleFeedback = null
## 波次调度模块
var wave: WaveDirector = null
## 战斗结算模块
var combat: CombatResolver = null

var state: int = State.FIGHTING
var wave_num: int = 0
var wave_timer: float = 0.0
var kills: int = 0
var waves_completed: int = 0
var upgrade_taken_count: int = 0

# ---- 波末升级捆绑的「敌人代价」状态（参考 A1 双向升级投票，用户选 A）----
## 已取的各档代价叠层数（tier -> int），封顶后该档不再出现在波末选项里。
var _cost_stacks: Dictionary = {}
## 敌人生命/伤害的累积乘区（1.0 = 无代价）。乘法累积、每档有叠层上限 ⇒ 总量有界。
## 只影响【之后】生成的敌人 —— 取代价那波已经刷出的怪不变。
var _cost_hp_mult := 1.0
var _cost_dmg_mult := 1.0

## 本波还没投放出去的怪数。
var spawn_remaining: int = 0

var enemies: Array[Enemy] = []
var projectiles: Array[Projectile] = []
var pickups: Array[Pickup] = []
var obstacles: Array[Obstacle] = []
## 本局已购商店道具（A4 前置解锁链）：进阶道具只在前置已购时上架。
## 探针可直读直写（Battle 黑板惯例）；start_run 清零。
var items_owned: Array[String] = []
## 建筑物矩形缓存。敌人不用物理体，靠这批矩形做数学推出（见 Enemy._resolve_obstacles）。
var obstacle_rects: Array[Rect2] = []

var selftest := false
var selftest_defeat := false
## 平衡观测模式（--balance）：玩家无敌 + 自动驾驶，跑满 20 波只为看压力曲线。
## **不是玩法模式**，正常游玩永远不会打开。
var balance := false
var _current_options: Array = []
var _current_reason := ""
var _upgrade_queue: Array[String] = []
var _game_time := 0.0
var _def_probe_ok := false
var _nan_seen := false
var _def_seen_bad := false
var _delta_logged := false
var _shake_time := 0.0
var _shake_strength := 0.0
## 竞技场底：波次主题的**真实贴图**（assets/bg/{主题id}.png，2048x2048 居中徽章地砖）。
## 2026-09-19 背景重构二调：不再「单张整铺」，改为【同一张贴图复制成
## FLOOR_TILE_COLS×FLOOR_TILE_ROWS 份、按网格拼接铺满竞技场】（矩形见
## GameStats.floor_tile_rects）—— 屏幕纹素密度成倍提高。
## 同日三调：素材从 1920x1080 换成 2048x2048 方图后，每块瓦片的取图区域改由
## GameStats.floor_tile_src_rect 按格子比例【居中裁切】给出，避免菱形地砖被横向拉扁。
## 更早的「渐变 + 程序化花纹烘贴图」整条链路随贴图接入一起退役。
var _floor_tex: Texture2D = null
## 当前地面主题（随波次更换，见 GameStats.FLOOR_THEMES）
var _floor_theme: Dictionary = {}
## 本局出现过的地面主题 id（自检用来断言「换关真的换材质了」）
var _themes_seen: Array[String] = []
## 本局出现过的敌人类型（自检观测：接入说明 §6 要求每类新敌人至少刷出一只）
var enemy_types_seen: Dictionary = {}

## hit-stop 防重入
var _hitstop := false
## hit-stop 回调的代际计数：重开一局后旧回调作废，不再改 time_scale（A7）
var _hitstop_gen := 0

## 倍速调节（2026-09-20 用户需求）：战斗内右上角按钮循环 1.0x → 1.5x → 2.0x。
## Engine.time_scale 的【用户侧唯一权威】—— hit-stop 恢复、start_run 重置都从这取值；
## 实现即引擎全局时标：更新逻辑/动画/物理的 delta 按倍率缩放，暂停/结算不受影响。
## 1.0 = 引擎默认值 ⇒ 与旧版本行为【逐位一致】；自检/探针模式不建按钮（门禁基线零变化），
## 每局开始重置回 1.0x，返回标题强制还原 1.0（时标只允许在战斗内生效）。
var speed_mul := 1.0
const SPEED_STEPS := [1.0, 1.5, 2.0]
var _speed_btn: Button = null
## 中央柔光（让场地中心比四周亮一点，视线自然落在玩家身上）
var _floor_glow: GradientTexture2D = null
## 边缘压暗（vignette）
var _floor_vignette: GradientTexture2D = null
## HUD 更新节流计时。
## 物理帧最多 360/s，而 HUD 每帧重建一次中文 Label 文本会触发文字排版 ——
## 实测这是加速观测跑不动的元凶（引擎只跑到约 120 物理帧/秒）。
## 正常游玩 60 帧/秒时也是纯浪费，所以限流到 ~12 次/秒，视觉上完全够用。
var _hud_timer := 0.0
const HUD_INTERVAL := 0.08
var _last_victory := false
var _defeat_checked := false

# ---------------------------------------------------------------- 观测数据（自检用）
## 性能计量：全流程见过的最大「脚本每帧耗时」（毫秒）。 headless 下没有渲染，
## 但这个数能直接反映我们脚本的每帧成本 —— 卡顿排查就看它。
var _max_phys_ms := 0.0
var _max_proc_ms := 0.0
var _max_phys_at := -1.0
var _max_proc_at := -1.0
var _phys_sum := 0.0
var _phys_ticks := 0


# ================================================================ 探针兼容层
# 【为什么需要这一层】5 个门禁探针直接访问本脚本的成员，其中 _ProbeRangedBoss 会
# 【写】spawn_remaining 与 projectiles。拆逻辑不拆状态 ⇒ 只有真正被探针触及的字段
# 需要留在这里；其余纯内部状态已整体搬进模块，不在此处冗余转发。

## 本波投放跨度峰值（真身在 WaveDirector；自检断言「整波都在出怪」用）。
var _spawn_spread_max: float:
	get: return wave.spawn_spread_max if wave != null else 0.0
	set(v): if wave != null: wave.spawn_spread_max = v


func _ready() -> void:
	selftest_defeat = _has_flag("--selftest-defeat")
	balance = _has_flag("--balance")
	selftest = _has_flag("--selftest") and not selftest_defeat and not balance
	# `--touch`：桌面端强制显示虚拟摇杆（真机有触摸屏会自动显示，无需此旗标）。
	# 注入发生在子节点 _ready 之后 —— TouchControls 的 setter 会立刻重算可见性。
	if touch != null:
		touch.has_touch_flag = _has_flag("--touch")
	# `--endless`：无尽模式开关。必须【无条件赋值】—— 普通运行自动复位为 false；
	# 与 --char 一样要在 start_run() 之前（HUD / WaveDirector 在波次里读 GameSession.endless）。
	GameSession.endless = _has_flag("--endless")
	print("[ENDLESS] 无尽模式=%s" % ("开" if GameSession.endless else "关"))
	# `--char <id>`：命令行指定角色（供四角色自检 / 平衡观测四连跑）。
	# 必须在 start_run() 之前 —— start_run() → player.reset() → apply_character() 会读
	# GameSession.selected_char，而 Player 是子节点、_ready 先于 Battle 跑完。
	var forced_char := _arg_value("--char")
	if forced_char != "":
		GameSession.begin_run(forced_char)
		print("[CHAR] 命令行指定角色：%s（武器：%s）" % [
			GameSession.selected_char,
			GameStats.weapon_for_char(GameSession.selected_char)["name"]])
	_build_floor_overlays()
	player.battle = self
	player.fired.connect(_on_player_fired)
	player.evolved.connect(_on_player_evolved)
	feedback = BattleFeedback.new()
	add_child(feedback)
	feedback.setup(world)
	# 两个功能模块：沿用 BattleFeedback 的组合范式（宿主 new + add_child + setup 注入）
	wave = WaveDirector.new()
	add_child(wave)
	wave.setup(self)
	wave.wave_started.connect(_on_wave_started)
	wave.floor_changed.connect(_apply_floor_theme)
	wave.wave_logged.connect(_print_wave_row)
	combat = CombatResolver.new()
	add_child(combat)
	combat.setup(self)
	combat.float_requested.connect(_on_float_requested)
	combat.burst_requested.connect(_on_burst_requested)
	combat.sfx_requested.connect(_on_sfx_requested)
	combat.shake_requested.connect(shake)
	combat.hitstop_requested.connect(_hitstop_brief)
	combat.player_died.connect(_on_player_died)
	# 相机：拉近（视角缩到一半）+ 限制在地图内。
	# 跟随玩家在 _physics_process 里做；limit_* 让镜头到地图边缘自动停住。
	camera.zoom = Vector2(GameStats.CAMERA_ZOOM, GameStats.CAMERA_ZOOM)
	camera.limit_left = 0
	camera.limit_top = 0
	camera.limit_right = int(GameStats.ARENA_W)
	camera.limit_bottom = int(GameStats.ARENA_H)
	camera.position_smoothing_enabled = false
	audio = GameAudio.new()
	add_child(audio)
	GameAudio.play_bgm.call_deferred(get_tree())
	player.died.connect(_on_player_died)
	# 商店购买必须走真实 UI 链路：面板点击 → purchased 信号 → 这里校验扣款。
	# 【2026-09-19 修复的严重 bug】这条线此前从未接上——点商品只 emit 没人听，
	# 购买静默无效；而门禁探针直接调 _on_shop_purchased 绕过了断点，所以一直全绿。
	shop_panel.purchased.connect(_on_shop_purchased)
	pause_menu.resumed.connect(func(): pass)
	pause_menu.restart_requested.connect(func():
		start_run()
	)
	pause_menu.to_title_requested.connect(func():
		Engine.time_scale = 1.0   # 倍速只允许在战斗内生效：离开战斗强制还原引擎时标
		get_tree().change_scene_to_file("res://scenes/main/Title.tscn")
	)

	_build_speed_button()

	if _testing():
		Engine.time_scale = SELFTEST_TIME_SCALE
		Engine.physics_ticks_per_second = SELFTEST_TICKS

	if selftest:
		# 自检用【无敌】跑满全部 20 波：这样它是**确定性的流程门禁**
		# （20 波 × 30s = 600 游戏秒，靠自动驾驶真打，中途必死 → 断言会随机红）。
		# 死亡路径另有 --selftest-defeat 专测；难度不在这里判，由 --balance 出数据。
		player.autopilot = true
		player.god_mode = true
		_def_probe_ok = _probe_enemy_killable()
		print("[SELFTEST] 战斗场景自检启动（自动驾驶 + 无敌 + 自动升级，跑满 %d 波）" % _selftest_target_waves())
		print("[SELFTEST] def 修复探针：%s（敌人 def=0 且可被击杀）" % ("OK" if _def_probe_ok else "FAIL"))

	if balance:
		# 平衡观测：带真实伤害，只看压力曲线与存活深度 —— 死不等于失败。
		player.autopilot = true
		player.god_mode = false
		_def_probe_ok = true
		print("[BALANCE] 平衡观测模式：自动驾驶 + 真实伤害，最多跑满 %d 波" % GameStats.WAVE_COUNT)
		print("[BALANCE] 只看压力曲线（投放量 / 同屏峰值 / 击杀速度 / 存活深度），不看生死")

	if selftest_defeat:
		# 失败结算路径自检：构造【确定性】致死场景（仍走真实链路，不作弊）。
		# 1) 原地不动（autopilot=false），2) 关闭自动攻击 → 贴身敌人不会被清掉，
		#    接触伤害变为持续 ~20dps，5 秒内必然致死；3) 冻结波次计时 → 从定义上
		#    排除「苟过 3 波变通关」的 flaky 路径。死亡仍由「接触→take_hit→died→_end_run(false)」产生。
		player.autopilot = false
		player.attack_enabled = false
		# ⚠️ 初心免死会吞掉本模式赖以断言的「确定性致死」（第一次致死被改成 hp=1），
		# 两者天生冲突 → 关掉特性总开关（设计文档差异裁决 D4）。
		# traits_enabled 不是「每局状态」，reset()/apply_character() 都不碰它，不会被冲掉。
		player.traits_enabled = false
		print("[SELFTEST-DEFEAT] 失败路径自检启动（原地不动 + 关闭攻击 + 冻结波次计时；靠接触伤害确定性致死）")
		print("[SELFTEST-DEFEAT] 角色特性已关闭（traits_enabled=false），保证确定性致死不被初心吞掉")

	start_run()


# ================================================================ 开局 / 波次
#region 开局 / 波次编排
func start_run() -> void:
	_clear_all()
	wave_num = 0
	wave_timer = 0.0
	kills = 0
	waves_completed = 0
	upgrade_taken_count = 0
	_cost_stacks = {}
	_cost_hp_mult = 1.0
	_cost_dmg_mult = 1.0
	items_owned.clear()
	spawn_remaining = 0
	_game_time = 0.0
	_upgrade_queue.clear()
	enemy_types_seen.clear()
	get_tree().paused = false
	# 倍速每局重置回 1.0x（引擎默认值）—— 上一局的 1.5x/2.0x 不允许带进新局
	speed_mul = 1.0
	if not _testing():
		Engine.time_scale = 1.0
	_update_speed_button()
	if _speed_btn != null:
		_speed_btn.visible = true
	wave.reset()
	combat.reset()
	_themes_seen.clear()
	feedback.reset()
	_hitstop_gen += 1
	_hitstop = false
	_max_phys_ms = 0.0
	_max_proc_ms = 0.0
	_max_phys_at = -1.0
	_max_proc_at = -1.0
	_phys_sum = 0.0
	_phys_ticks = 0
	player.reset(GameStats.ARENA_CENTER)
	# 局外永久强化注入（MetaSave 消费端第二片）。守卫三重：
	# ① _testing()：自检/平衡/失败路径要确定性基线，绝不带局外加成；
	# ② 探针进程（--script 模式）：门禁探针的数值断言（DPS/血量端到端等）全部
	#    基于无 meta 基线 —— 用户一旦买了强化就会污染门禁，探针进程一律不注入；
	# ③ 注入后强制 recalc（幂等）：确保 meta 乘区真的进到本次战斗数值里。
	if not _testing() and not _probe_process():
		player.meta_bonus_dict = MetaSave.meta_bonus()
		player.recalc_stats()
	player.set_physics_process(true)
	spawn_obstacles_via_wave()
	result_panel.hide_panel()
	upgrade_panel.hide_panel()
	hud.set_visible_hud(true)
	start_next_wave()


## 开始下一波（转发到 WaveDirector）。
func start_next_wave() -> void:
	wave.start_next_wave()


## 生成一只敌人（转发到 WaveDirector）。探针 _ProbeRangedBoss 直接调用 —— 必须保留。
func _spawn_enemy(type_name: String, pos: Vector2) -> void:
	wave.spawn_enemy(type_name, pos)


## 摆放建筑物（转发到 WaveDirector）。保留 `_spawn_obstacles` 旧名以免破坏外部约定。
func spawn_obstacles_via_wave() -> void:
	wave.spawn_obstacles()


## 波次开始后的反馈（横幅 + 音效）—— 由 WaveDirector.wave_started 信号触发。
func _on_wave_started(wave_no: int, subtitle: String) -> void:
	feedback.show_wave_banner(wave_no, subtitle)
	if audio != null:
		audio.play("wave", -6.0)


# ================================================================ 地面自绘
#region 地面主题 / 取景
## 氛围叠层：中央柔光（视线聚焦玩家）+ 边缘压暗（突出角色）。
## 主题地面本体是贴图（见 _apply_floor_theme），这两层只做轻微统一调色。
func _build_floor_overlays() -> void:
	# 中央柔光：径向，中心微亮向外消失
	var lg := Gradient.new()
	lg.set_color(0, GameStats.FLOOR_GLOW)
	lg.set_color(1, Color(GameStats.FLOOR_GLOW.r, GameStats.FLOOR_GLOW.g,
		GameStats.FLOOR_GLOW.b, 0.0))
	var lt := GradientTexture2D.new()
	lt.gradient = lg
	lt.width = 256
	lt.height = 256
	lt.fill = GradientTexture2D.FILL_RADIAL
	lt.fill_from = Vector2(0.5, 0.5)
	lt.fill_to = Vector2(0.5, 0.0)
	_floor_glow = lt

	# 边缘压暗：中心透明 → 四周变暗（对比拉出来，角色更突出）
	# ⚠️ 三点显式赋值。旧写法 set_color(1,...) 在 add_point 之后索引移位，
	# 默认 Gradient 的【白色终点】从未被覆盖 → 椭圆外 clamp 到纯白不透明，
	# 在画面四周刷出一圈白雾（真实贴图接入后显形，2026-09-19 修复）。
	var vg := Gradient.new()
	vg.offsets = PackedFloat32Array([0.0, 0.55, 1.0])
	vg.colors = PackedColorArray([
		Color(0, 0, 0, 0),
		Color(0, 0, 0, GameStats.FLOOR_VIGNETTE * 0.25),
		Color(0, 0, 0, GameStats.FLOOR_VIGNETTE),
	])
	var vt := GradientTexture2D.new()
	vt.gradient = vg
	vt.width = 256
	vt.height = 256
	vt.fill = GradientTexture2D.FILL_RADIAL
	vt.fill_from = Vector2(0.5, 0.5)
	vt.fill_to = Vector2(0.5, 0.0)
	_floor_vignette = vt


## 应用地面主题：换关时由 WaveDirector.floor_changed 信号触发。贴图是共享资源，
## 切换只是换引用（零 GPU 成本），可以在波次开始的同帧同步完成。
func _apply_floor_theme(t: Dictionary) -> void:
	if String(t.get("id", "")) == String(_floor_theme.get("id", "")):
		return
	_floor_theme = t
	_floor_tex = AssetDB.floor_bg(String(t["id"]))
	if _floor_tex == null:
		# 贴图缺失不致命：退回 Background 的兜底底色，别让画面出现破洞
		push_warning("[Battle] 主题 '%s' 的地面贴图缺失（AssetDB.floor_bg 返回 null）" % String(t["id"]))
	if not _themes_seen.has(String(t["id"])):
		_themes_seen.append(String(t["id"]))
	if _testing():
		print("[%s] 地面主题切换 → %s（%s）" % [_test_tag(), String(t["id"]), String(t["name"])])
	queue_redraw()


## 当前主题的边框颜色（跟主题走，一眼能看出换关了）。
func _floor_border_color() -> Color:
	if _floor_theme.is_empty():
		return GameStats.ARENA_BORDER_COLOR
	return _floor_theme["border"]


## 相机可见的世界矩形。相机跟随玩家，可视区 = 相机位置 ± 可视尺寸/2。
func visible_world_rect() -> Rect2:
	var size := visible_world_size()
	return Rect2(camera.global_position - size * 0.5, size)


func visible_world_size() -> Vector2:
	# headless 没有真实窗口，get_visible_rect() 会退化（实测为 1280x1280），
	# 会让无头自检的几何与真机不一致 → 回落到设计尺寸。
	# 可见【世界】尺寸 = 视口尺寸 ÷ 相机缩放（zoom=1.6667 → 世界里看 768x432；原 zoom=2 时 640x360）。
	if DisplayServer.get_name() == "headless":
		return Vector2(GameStats.VIEW_WIDTH, GameStats.VIEW_HEIGHT) / GameStats.CAMERA_ZOOM
	var s := get_viewport().get_visible_rect().size
	if s.x <= 1.0 or s.y <= 1.0:
		return Vector2(GameStats.VIEW_WIDTH, GameStats.VIEW_HEIGHT) / GameStats.CAMERA_ZOOM
	return s / GameStats.CAMERA_ZOOM


## 受击反馈震屏（Camera2D.offset 抖动）。纯视觉，不参与任何判定。
func shake(strength: float = GameStats.SHAKE_STRENGTH) -> void:
	_shake_strength = strength
	_shake_time = GameStats.SHAKE_DURATION


func _update_camera_shake(delta: float) -> void:
	if camera == null:
		return
	if _shake_time <= 0.0:
		if camera.offset != Vector2.ZERO:
			camera.offset = Vector2.ZERO
		return
	_shake_time = maxf(0.0, _shake_time - delta)
	var k := 0.0
	if GameStats.SHAKE_DURATION > 0.0:
		k = _shake_time / GameStats.SHAKE_DURATION
	var s := _shake_strength * k
	camera.offset = Vector2(randf_range(-s, s), randf_range(-s, s))


# ================================================================ 主循环
func _physics_process(delta: float) -> void:
	_update_camera_shake(delta)
	# 虚拟摇杆（批次四 4a）：每帧把触摸方向喂给玩家。未启用/未触摸时是零向量，
	# Player 端叠加后与纯键盘行为逐位一致（回归红线）。
	if touch != null and player != null:
		player.set_touch_dir(touch.move_dir())
	# 镜头跟随玩家（Camera2D.limit_* 会自动把它钳在地图内 —— 到边缘就不再居中）
	if is_instance_valid(player) and state != State.RESULT:
		camera.global_position = player.global_position

	if _testing() and not _delta_logged:
		_delta_logged = true
		print("[%s] 物理步长 delta=%.5f  time_scale=%.1f  ticks=%d" % [
			_test_tag(), delta, Engine.time_scale, Engine.physics_ticks_per_second,
		])

	if _testing():
		_game_time += delta
		if _game_time > _selftest_max_game_time() and state != State.RESULT:
			_fail_test("自检超时（游戏内 %.0fs 仍未结束）" % _game_time)
			return

	match state:
		State.FIGHTING:
			_tick_fighting(delta)
		State.UPGRADE, State.SHOP:
			# 升级/商店面板各自是 WHEN_PAUSED，暂停时它们自己处理；
			# Battle 这里是停着的，什么都不做
			pass
		State.RESULT:
			if selftest or balance:
				_finish_selftest()
			elif selftest_defeat:
				_finish_defeat_selftest()


## 战斗主 tick —— 纯粹的编排：波次 → 战斗 → 反馈 → 观测 → HUD → 升级队列。
## ⚠️ 各步骤的【相对顺序】不得改变（拆分前是 41 行流水线，此处保持同样次序）。
func _tick_fighting(delta: float) -> void:
	# 失败路径自检冻结波次计时：杜绝「苟活到波末→升级→通关」这条非确定性路径。
	if not selftest_defeat:
		wave_timer -= delta
		if wave_timer <= 0.0:
			wave.end_wave()
			return

	wave.tick_spawn(delta)

	# 战斗部分（接触伤害 → 弹道 → 清理 → 网格 → 分离力）整块交给 CombatResolver。
	# 唯一需要在此处保留的判定：接触伤害可能致死并跳出 FIGHTING，须立刻停手。
	combat.contact_damage()
	if state != State.FIGHTING:
		return
	combat.process_projectiles(delta)
	combat.cleanup_enemies()
	wave.live_max = maxi(wave.live_max, enemies.size())
	combat.space_and_separate()
	feedback.update_floats(delta)
	# 记录脚本每帧成本的峰值（毫秒）
	var phys := Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
	var proc := Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
	if phys > _max_phys_ms:
		_max_phys_ms = phys
		_max_phys_at = _game_time
	if proc > _max_proc_ms:
		_max_proc_ms = proc
		_max_proc_at = _game_time
	_phys_sum += phys
	_phys_ticks += 1
	combat.process_pickups(delta)
	combat.scan_enemies()

	_hud_timer -= delta
	if _hud_timer <= 0.0:
		_hud_timer = HUD_INTERVAL
		hud.set_data(player, wave_num, wave_timer, GameStats.WAVE_COUNT)
	_maybe_open_queued_upgrade()


# ================================================================ 反馈桥接
#region 反馈桥接（模块信号 → feedback / audio）
func _on_float_requested(pos: Vector2, text: String, color: Color, big: bool) -> void:
	feedback.spawn_float(pos, text, color, big)


func _on_burst_requested(pos: Vector2, color: Color, big: bool) -> void:
	feedback.spawn_burst(pos, color, big)


func _on_sfx_requested(name: String, volume_db: float, pitch: float) -> void:
	if audio != null:
		audio.play(name, volume_db, pitch)


## 武器进化播报（2026-09-20 可达性升级）：大号金字飘屏 + 震屏 + 双音效 ——
## 进化是核心成长节点，必须有「发生了大事」的演出感，否则玩家无感。
func _on_player_evolved(form_name: String) -> void:
	var label := "武器进化！%s" % form_name if form_name != "" else "武器进化！"
	feedback.spawn_float(player.global_position + Vector2(0.0, -64.0),
		label, Color(1.0, 0.84, 0.0), true)
	shake()
	_on_sfx_requested("coin", -2.0, 1.3)
	_on_sfx_requested("kill", -2.0, 0.8)


# ================================================================ 战斗转发（探针入口）
# 只保留两个被门禁探针直接调用的包装；其余战斗逻辑一律经 combat.xxx 直达，不再套壳。
## 生成掉落物（转发到 CombatResolver）。探针 _ProbePickupExpiry 直接调用 —— 必须保留。
func _spawn_pickup(kind: String, value: int, pos: Vector2) -> void:
	combat.spawn_pickup(kind, value, pos)


## 敌方开火回调（转发到 CombatResolver）。探针 _ProbeRangedBoss 直接调用 —— 必须保留。
func _on_enemy_fired(pos: Vector2, dir: float, dmg: int) -> void:
	combat.on_enemy_fired(pos, dir, dmg)


## Boss 召唤小弟（批次三）：Enemy 不持有 enemies 数组，统一由 Battle 转交。
## 走 wave.spawn_enemy —— 它内部已有「离玩家太近就换位 + 入列 enemies」的逻辑，
## 而且召唤物是技能产物，【不占】本波投放量 spawn_remaining。
## 自检观测：记录出现过的敌人类型（由 WaveDirector.spawn_enemy 调用）。
func note_enemy_type(t: String) -> void:
	enemy_types_seen[t] = true


func _on_boss_summon(pos: Vector2, type_name: String, count: int) -> void:
	var n := maxi(1, int(count))
	for i in n:
		var ang := TAU * float(i) / float(n)
		var p: Vector2 = pos + Vector2(cos(ang), sin(ang)) * GameStats.BOSS_SUMMON_RADIUS
		wave.spawn_enemy(String(type_name), p)
	if _testing():
		print("[%s] Boss 召唤 %d 只 %s（pos=%s）" % [
			_test_tag(), n, String(type_name), str(pos)])


## 精神内耗（splitter）死亡分裂（2026-09-20）：原位生成 SPLITTER_CHILD_COUNT 只 Rat，
## 每只血量 = Rat 模板 × SPLITTER_CHILD_HP_MUL(0.6)（仍吃波次曲线与敌人代价乘区）。
## 小鼠是普通 melee，天然不会「分裂→再分裂」；也不占用 spawn_remaining 名额。
func _on_splitter_death(pos: Vector2) -> void:
	_on_sfx_requested("split", -6.0, 1.0)
	for i in GameStats.SPLITTER_CHILD_COUNT:
		var ang := TAU * float(i) / float(GameStats.SPLITTER_CHILD_COUNT) + 0.6
		var p: Vector2 = pos + Vector2(cos(ang), sin(ang)) * 18.0
		wave.spawn_enemy("Rat", p, GameStats.SPLITTER_CHILD_HP_MUL, false)


## 班长（support）光环脉冲（2026-09-20）：heal=false → 给 150px 内友军临时提速
## （+25%，持续 2s，可刷新，多来源取 max 不叠乘）；heal=true → 给半径内血量占比
## 最低的友军回其 max_hp 的 5%。范围过滤与目标选择都在这一侧（Enemy 不持数组）。
func _on_support_pulse(pos: Vector2, heal: bool) -> void:
	if heal:
		var best: Enemy = null
		var best_ratio := 1.001
		for e in enemies:
			if not is_instance_valid(e) or e.is_dead \
					or e.global_position.distance_to(pos) > GameStats.SUPPORT_AURA_DIST:
				continue
			var r: float = e.hp_ratio()
			if r < best_ratio:
				best_ratio = r
				best = e
		if best != null and best_ratio < 1.0:
			best.hp = minf(float(best.max_hp),
				best.hp + float(best.max_hp) * GameStats.SUPPORT_HEAL_RATIO)
			if best.show_health_bar:
				best.queue_redraw()
	else:
		for e in enemies:
			if is_instance_valid(e) and not e.is_dead \
					and e.global_position.distance_to(pos) <= GameStats.SUPPORT_AURA_DIST:
				e.apply_temp_speed(GameStats.SUPPORT_SPEED_MUL, GameStats.SUPPORT_SPEED_DUR)


## 全场提速光环（BossPUA 召唤瞬间，2026-09-20）：所有存活敌人临时加速（取 max 不叠乘）。
func _on_global_speed_aura(mul: float, dur: float) -> void:
	for e in enemies:
		if is_instance_valid(e) and not e.is_dead:
			e.apply_temp_speed(mul, dur)


# ================================================================ 玩家事件
func _on_player_fired(aim_pos: Vector2, count: int) -> void:
	combat.on_player_fired(aim_pos, count)


func _on_player_died() -> void:
	if state == State.FIGHTING:
		_end_run(false)


# ================================================================ 升级 / 商店
func _maybe_open_queued_upgrade() -> void:
	if state == State.FIGHTING and not _upgrade_queue.is_empty():
		var reason: String = _upgrade_queue.pop_front()
		_open_upgrade(reason)


func _open_upgrade(reason: String) -> void:
	state = State.UPGRADE
	_current_reason = reason
	_generate_options()
	var text := "升级强化" if reason == "level" else "本波结束，选择强化后进入下一波"
	# 暂停整棵树：否则玩家在选强化的时候还在挨打（弹出即暴毙）。
	# 面板自己设了 PROCESS_MODE_WHEN_PAUSED，暂停时它照样能响应；
	# 解除暂停也由面板负责（select / hide_panel 里），这里不用管。
	get_tree().paused = true
	if audio != null and reason == "level":
		audio.play("levelup", -4.0)
	upgrade_panel.show_options(_current_options, wave_num, text, _on_upgrade_chosen, _testing())


func _generate_options() -> void:
	var avail: Array = []
	for def in GameStats.UPGRADE_POOL:
		if def["id"] == "proj" and player.proj >= GameStats.MAX_PROJ:
			continue
		# C2 迭代：带 max 上限的属性（闪避/暴击/吸血）到顶后不再出现 —— 无效卡是负反馈
		if def.has("max") and float(player.get(String(def["stat"]))) >= float(def["max"]):
			continue
		var opt: Dictionary = def
		# 波末升级捆绑「敌人代价」（A1 双向投票，用户选 A：只在波末捆绑）。
		# 等级升级保持纯奖励。注意 UPGRADE_POOL 是 const 只读表 ⇒ 必须在副本上挂 cost。
		if _current_reason == "wave":
			opt = def.duplicate()
			var cost: Dictionary = _pick_enemy_cost(int(def.get("cost_tier", 1)))
			if not cost.is_empty():
				opt["cost"] = cost
		avail.append(opt)
	avail.shuffle()
	# 选项数 = 基础值 + 角色天赋加成（学习豪 +1）
	var count := GameStats.UPGRADE_OPTIONS + int(GameStats.character(player.char_id)["upgrade_opt_bonus"])
	var pick: Array = avail.slice(0, mini(count, avail.size()))
	# 武器进化可达性升级（2026-09-20，用户拍板全选四方案之二）：
	# 卡池 12 条均匀抽 3，武器精通单次出现率仅 25%，实测多数局凑不满 6 层 —— 进化形同虚设。
	#   A. 波末保底：未进化时每波波末必含一张武器精通（选不选仍由玩家决定）；
	#   C. 升级时加权：1/3 概率把武器精通补进选项（0.25 + 1/3×0.75 ≈ 50%，约 2 倍权重）。
	if not bool(player.weapon_evolved):
		var mastery: Dictionary = {}
		for o in avail:
			if String(o["id"]) == "weapon_mastery":
				mastery = o
				break
		if not mastery.is_empty() and not pick.is_empty():
			var in_pick := false
			for o in pick:
				if String(o["id"]) == "weapon_mastery":
					in_pick = true
					break
			if not in_pick:
				if _current_reason == "wave":
					pick[randi() % pick.size()] = mastery
				elif _current_reason == "level" and randf() < 0.34:
					pick[randi() % pick.size()] = mastery
	_current_options = pick


## 按升级条目的档位取一个可用代价：本档叠层满则就近降/升档找，
## 全部取满返回空字典（该卡退回纯奖励 —— 玩家白赚，属正常状态）。
func _pick_enemy_cost(tier: int) -> Dictionary:
	var order: Array = [tier, tier - 1, tier + 1, tier - 2, tier + 2]
	for t in order:
		var tt := int(t)
		if tt < 1 or tt > 3 or not GameStats.UPGRADE_ENEMY_COSTS.has(tt):
			continue
		if int(_cost_stacks.get(tt, 0)) >= int(GameStats.UPGRADE_ENEMY_COSTS[tt]["max_stacks"]):
			continue
		var cost: Dictionary = GameStats.enemy_cost_for_tier(tt)
		cost["tier"] = tt
		return cost
	return {}


## 应用「敌人代价」侧：累积乘区 + 记叠层（由 _on_upgrade_chosen 在玩家侧应用后调用）。
func _apply_enemy_cost(cost: Dictionary) -> void:
	if cost.is_empty():
		return
	var tier := int(cost.get("tier", 0))
	_cost_stacks[tier] = int(_cost_stacks.get(tier, 0)) + 1
	_cost_hp_mult *= (1.0 + float(cost.get("hp_mul", 0.0)))
	_cost_dmg_mult *= (1.0 + float(cost.get("dmg_mul", 0.0)))


## 敌人生成的生命乘区（WaveDirector 在 setup 时传入；1.0 = 无代价）。
func enemy_cost_hp_mult() -> float:
	return _cost_hp_mult


## 敌人生成的伤害乘区。
func enemy_cost_dmg_mult() -> float:
	return _cost_dmg_mult


## 波末商店：暂停游戏，玩家花金币买道具；离开后进下一波。
func _open_shop() -> void:
	state = State.SHOP
	get_tree().paused = true
	shop_panel.open(wave_num, player.gold, player.shop_discount, _on_shop_closed, _testing(), items_owned,
		player.weapon_level)


## 商店购买请求（由面板 purchased 信号发起）：校验余额 → 扣钱 → 应用 → 锁卡。
## index 用于购买成功后把该卡标记为已售出（防止同一张卡反复购买）。
func _on_shop_purchased(item_id: String, price: int, index: int) -> void:
	if player.gold < price:
		return
	player.gold -= price
	player.apply_item(item_id)
	items_owned.append(item_id)   # A4 前置解锁链：记录已购（下波商店前置判定用）
	shop_panel.mark_sold(index)
	if audio != null:
		audio.play("buy", -4.0)
	shop_panel.refresh(player.gold)


## 离开商店 → 下一波
func _on_shop_closed() -> void:
	get_tree().paused = false
	start_next_wave()


func _on_upgrade_chosen(opt: Dictionary, _index: int) -> void:
	player.apply_upgrade(opt["id"], GameStats.upgrade_value(opt, wave_num))
	upgrade_taken_count += 1
	# 「敌人代价」侧（A1 双向投票）：玩家拿增益的同时敌人也成长（只在波末捆绑，见 _generate_options）
	if opt.has("cost"):
		_apply_enemy_cost(opt["cost"])
	if _current_reason == "wave":
		_open_shop()
	else:
		state = State.FIGHTING
	_maybe_open_queued_upgrade()


# ================================================================ 结算
func _end_run(victory: bool) -> void:
	if state == State.RESULT:
		return
	_last_victory = victory
	get_tree().paused = false
	state = State.RESULT
	# 回合结束金币回收（2026-09-20 用户需求）：场上未拾取的金币按 GOLD_SALVAGE_RATIO
	# 折半计入玩家金币（向下取整）——打完一局不该「一只金币都拿不回」。
	# 必须在 record_run 之前：账本入账用的就是回收后的 gold。
	var gold_on_floor := 0
	for pk in pickups:
		if is_instance_valid(pk) and pk.kind == Pickup.KIND_GOLD:
			gold_on_floor += pk.value
	var salvage := int(float(gold_on_floor) * GameStats.GOLD_SALVAGE_RATIO)
	if salvage > 0:
		player.gold += salvage
		feedback.spawn_float(player.global_position + Vector2(0.0, -64.0),
			"回收 +%d" % salvage, Color(1.0, 0.84, 0.0), false)
	# 局外账本入账（A2/A6 迭代）：最佳波次 / 累计击杀 / 累计金币，跨局持久化。
	# 守卫：自检与探针进程的战绩不写真实账本（否则门禁跑完用户账本全是测试数据）。
	if not _testing() and not _probe_process():
		MetaSave.record_run(victory, waves_completed, kills, player.gold)
	player.set_physics_process(false)
	# 结算前清场：不然面板盖上来后，背景还站着一群静止的怪
	_free_all_enemies()
	for pr in projectiles:
		pr.queue_free()
	for pk in pickups:
		pk.queue_free()
	projectiles.clear()
	pickups.clear()
	result_panel.show_result({
		"victory": victory,
		"waves_completed": waves_completed,
		"kills": kills,
		"level": player.level,
		"gold": player.gold,
	})
	hud.set_visible_hud(false)
	# 结算即战斗结束：①作废挂起的 hit-stop 回调（否则它可能在结算后才触发，
	# 把时标改回倍速值泄漏到结算页/标题页）；②引擎时标还原默认 —— 倍速只在战斗进行中有效。
	_hitstop_gen += 1
	_hitstop = false
	if not _testing():
		Engine.time_scale = 1.0
	if _speed_btn != null:
		_speed_btn.visible = false   # 结算界面不给倍速按钮（start_run 会重新显示并重置回 1.0x）


# ================================================================ 自检 / 观测模式
#region 自检 / 观测模式
## 独立的结构化探针：不依赖主循环，直接验证「敌人可被击杀」。
func _probe_enemy_killable() -> bool:
	var e := Enemy.new()
	e.setup("Slime", 1, Vector2(9999, 9999))
	var ok := true
	if e.defense != 0:
		ok = false
	# 血量从「模板 × 波次缩放」推导，不硬编码 —— 数值调参不应碰坏这条门禁
	var expected_hp := roundi(float(GameStats.enemy_template("Slime")["hp"]) * GameStats.hp_scale(1))
	if e.hp != expected_hp:
		ok = false
	var res := GameStats.player_damage(10, 0.0, 1.5, e.defense)   # crit=0 → 必为普通伤害
	if res["is_crit"]:
		ok = false
	if expected_hp > int(res["dmg"]) and e.take_damage(int(res["dmg"])):
		ok = false   # 10 伤害不应击杀（除非缩放后血量已 <= 10）
	if e.hp != expected_hp - int(res["dmg"]):
		ok = false
	if is_nan(float(e.hp)):
		ok = false
	if not e.take_damage(1000):
		ok = false   # 现在必须可击杀
	e.free()
	return ok


func _finish_selftest() -> void:
	var failures: Array[String] = []
	if not _def_probe_ok:
		failures.append("def 修复探针失败：敌人无法被击杀")
	if kills <= 0:
		failures.append("kills 必须 > 0，当前 %d（def 缺陷未修复或弹道未命中）" % kills)
	# 流程完整性：自检用无敌跑，所以「必须打满全部波次」是确定性的断言，不会 flaky。
	# 观测模式（--balance）不在此列 —— 它就是要看真实生死，死在第 N 波是数据，不是失败。
	var target := _selftest_target_waves()
	if selftest and waves_completed < target:
		failures.append("自检未跑满 %d 波（当前 %d）—— 流程卡住或刷怪中断" % [
			target, waves_completed,
		])
	if upgrade_taken_count < 1:
		failures.append("upgrades_taken 必须 >= 1，当前 %d" % upgrade_taken_count)
	if _nan_seen:
		failures.append("检测到敌人血量出现 NaN")
	if _def_seen_bad:
		failures.append("检测到敌人 def != 0")
	# 「整波持续出怪」的断言：投放跨度必须覆盖大部分投放窗口。
	# 旧实现是开局一次性全出，这个跨度会接近 0。
	# 换关必须真的换地面材质（20 波 / 4 波一换 = 应有 5 种；给点余量）
	if selftest and _themes_seen.size() < 3:
		failures.append("地面主题只出现 %d 种（应 >= 3）—— 换关换材质没生效？" % _themes_seen.size())
	if wave.spawn_spread_max < GameStats.SPAWN_WINDOW * 0.6:
		failures.append("刷怪没有铺满整波：最大投放跨度仅 %.1fs（应 ≥ %.1fs）—— 又变回「开局一次全出」了吗？" % [
			wave.spawn_spread_max, GameStats.SPAWN_WINDOW * 0.6,
		])

	print("[SELFTEST] --------------------------------------------------")
	print("[SELFTEST] char=%s weapon=%s trait=%s" % [
		player.char_id,
		GameStats.weapon_for_char(player.char_id)["name"],
		player.trait_id if player.trait_id != "" else "(none)",
	])
	print("[SELFTEST] kills=%d" % kills)
	print("[SELFTEST] waves_completed=%d / %d" % [waves_completed, _selftest_target_waves()])
	print("[SELFTEST] 结局=%s" % ("通关" if _last_victory else "阵亡"))
	print("[SELFTEST] upgrades_taken=%d" % upgrade_taken_count)
	print("[SELFTEST] level=%d" % player.level)
	print("[SELFTEST] gold=%d" % player.gold)
	print("[SELFTEST] hp=%d" % ceili(player.hp))
	print("[SELFTEST] def_fix_probe=%s  nan_seen=%s  def_ok=%s" % [
		"OK" if _def_probe_ok else "FAIL",
		"no" if not _nan_seen else "YES",
		"OK" if not _def_seen_bad else "BAD",
	])
	print("[SELFTEST] 投放跨度峰值=%.1fs（投放窗口 %.1fs）" % [
		wave.spawn_spread_max, GameStats.SPAWN_WINDOW,
	])
	print("[SELFTEST] 出现过的地面主题 = %s" % str(_themes_seen))
	print("[SELFTEST] 出现过的敌人类型 = %s" % str(enemy_types_seen.keys()))
	# 接入说明 §6：每个新敌人类型至少要在整局自检里刷出过一只
	var new_types := ["Rat", "Student", "Charger", "Ox", "Splitter", "Bomber", "Slacker", "Monitor", "BossPUA"]
	var missing_types: Array[String] = []
	for t in new_types:
		if not enemy_types_seen.has(t):
			missing_types.append(t)
	if not missing_types.is_empty():
		print("[SELFTEST] ⚠ 未观测到的敌人类型: %s（波次池/刷怪率可能有问题）" % str(missing_types))
	print("[SELFTEST] 脚本每帧耗时：物理峰值 %.2fms（@%.0fs）/ 帧处理峰值 %.2fms（@%.0fs）" % [
		_max_phys_ms, _max_phys_at, _max_proc_ms, _max_proc_at,
	])
	print("[SELFTEST] 物理帧均摊 %.2fms（预算 %.2fms/tick @%d 帧/秒）" % [
		_phys_sum / maxi(1, _phys_ticks), 1000.0 / float(SELFTEST_TICKS), SELFTEST_TICKS,
	])
	print("[SELFTEST] 游戏内用时 %.1fs" % _game_time)
	_print_wave_table()

	if failures.is_empty():
		print("[SELFTEST] RESULT=PASS")
		Engine.time_scale = 1.0
		get_tree().quit(0)
	else:
		for msg in failures:
			printerr("[SELFTEST] FAIL: %s" % msg)
		print("[SELFTEST] RESULT=FAIL 失败项=%d" % failures.size())
		Engine.time_scale = 1.0
		get_tree().quit(1)


## 逐波观测表 —— 难度曲线的原始数据，调平衡就看它。
func _print_wave_row(row: Dictionary) -> void:
	var tag := _test_tag()
	print("[%s] 波%-3d 计划%-4d 实投%-4d 累计击杀%-5d 等级%-3d 波末HP%-5.0f 场上峰%-4d 跨度%.1f" % [
		tag, int(row["wave"]), int(row["planned"]), int(row["spawned"]),
		int(row["kills"]), int(row["level"]), float(row["hp"]),
		int(row["live_max"]), float(row["spread"]),
	])


func _print_wave_table() -> void:
	if wave.wave_log.is_empty():
		return
	print("[SELFTEST] ---- 逐波观测（计划/实投=应投与实投怪数，场上峰=同屏存活峰值，跨度=投放跨越秒数）----")
	for row in wave.wave_log:
		_print_wave_row(row)


## 失败结算路径自检：断言玩家确实死亡、结算面板确实显示、结局确实是失败。
func _finish_defeat_selftest() -> void:
	if _defeat_checked:
		return
	_defeat_checked = true
	var failures: Array[String] = []
	if _last_victory:
		failures.append("结局应为失败，但 _last_victory=true")
	if player.hp > 0.0:
		failures.append("玩家 hp 应 <= 0，当前 %.1f" % player.hp)
	if not result_panel.visible:
		failures.append("结算面板未显示（result_panel.visible=false）")

	print("[SELFTEST-DEFEAT] victory=%s hp=%d kills=%d waves_completed=%d result_visible=%s" % [
		"true" if _last_victory else "false",
		ceili(player.hp),
		kills,
		waves_completed,
		"yes" if result_panel.visible else "no",
	])
	print("[SELFTEST-DEFEAT] 游戏内用时 %.1fs" % _game_time)

	if failures.is_empty():
		print("[SELFTEST-DEFEAT] RESULT=PASS")
		Engine.time_scale = 1.0
		get_tree().quit(0)
	else:
		for msg in failures:
			printerr("[SELFTEST-DEFEAT] FAIL: %s" % msg)
		print("[SELFTEST-DEFEAT] RESULT=FAIL 失败项=%d" % failures.size())
		Engine.time_scale = 1.0
		get_tree().quit(1)


func _fail_test(reason: String) -> void:
	var tag := _test_tag()
	printerr("[%s] FAIL: %s" % [tag, reason])
	print("[%s] RESULT=FAIL" % tag)
	Engine.time_scale = 1.0
	get_tree().quit(1)


# ================================================================ 工具
## 是否处于任一自检模式（PASS 或 失败路径）。
func _testing() -> bool:
	return selftest or selftest_defeat or balance


## 当前进程是否是门禁探针（--script 模式）。正常游玩（编辑器 F5 / 导出 exe）
## 的命令行里没有 --script。用于隔离「会污染确定性基线或用户账本」的行为。
func _probe_process() -> bool:
	return OS.get_cmdline_args().has("--script")


func _test_tag() -> String:
	if selftest_defeat:
		return "SELFTEST-DEFEAT"
	if balance:
		return "BALANCE"
	return "SELFTEST"


## 自检的目标波数：非无尽 = WAVE_COUNT（20）；无尽 = ENDLESS_SELFTEST_WAVES（40）。
## 供启动打印、跑满断言的判定与文案统一取值，避免两处口径不一致。
func _selftest_target_waves() -> int:
	if GameSession.endless:
		return GameStats.ENDLESS_SELFTEST_WAVES
	return GameStats.WAVE_COUNT


## 自检允许的最长游戏内时长（秒）——按模式取，否则无尽 40 波会被 900s 误判超时。
func _selftest_max_game_time() -> float:
	if GameSession.endless:
		return ENDLESS_SELFTEST_MAX_GAME_TIME
	return SELFTEST_MAX_GAME_TIME


func is_fighting() -> bool:
	return state == State.FIGHTING


func get_nearest_enemy(from: Vector2) -> Node2D:
	var nearest: Node2D = null
	var best := INF
	for e in enemies:
		if e.is_dead:
			continue
		var d := e.global_position.distance_to(from)
		if d < best:
			best = d
			nearest = e
	return nearest


## 最近的掉落物（供自动驾驶「顺路捡东西」用）。
func get_nearest_pickup(from: Vector2) -> Node2D:
	var nearest: Node2D = null
	var best := INF
	for pk in pickups:
		var d := pk.global_position.distance_to(from)
		if d < best:
			best = d
			nearest = pk
	return nearest


#region 清理 / 输入 / 工具
func _free_all_enemies() -> void:
	for e in enemies:
		e.queue_free()
	enemies.clear()
	# ⚠️ 网格必须同步清空。queue_free 是【延迟释放】，节点要到帧末才真的消失，
	# 而 _grid 存的是 Enemy 裸引用 —— 不清的话，下一帧 contact_damage /
	# process_projectiles 读网格就会踩到已释放对象：
	#   "Invalid access to property 'is_dead' on 'previously freed'"
	# 触发点：WaveDirector.start_next_wave() 换波清场（每波开头都会走这条）。
	if combat != null:
		combat.clear_grid()


func _clear_all() -> void:
	for e in enemies:
		e.queue_free()
	for p in projectiles:
		p.queue_free()
	for pk in pickups:
		pk.queue_free()
	enemies.clear()
	projectiles.clear()
	pickups.clear()


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("pause"):
		# 只在战斗进行中响应；升级/商店面板本来就暂停了整棵树，不做嵌套暂停
		if state == State.FIGHTING and not get_tree().paused:
			pause_menu.open()
			get_viewport().set_input_as_handled()
	elif event is InputEventKey and event.pressed and event.physical_keycode == KEY_R:
		Engine.time_scale = 1.0
		pause_menu.close()
		start_run()


func _has_flag(flag: String) -> bool:
	return flag in OS.get_cmdline_args() or flag in OS.get_cmdline_user_args()


## 读取 `--name value` 形式的命令行参数值。用户参数（`--` 之后）优先，其次引擎参数。
## 没找到返回空串。与 _has_flag 同一套来源，避免两处口径不一致。
func _arg_value(name: String) -> String:
	var user := OS.get_cmdline_user_args()
	for i in range(user.size() - 1):
		if user[i] == name:
			return String(user[i + 1])
	var full := OS.get_cmdline_args()
	for i in range(full.size() - 1):
		if full[i] == name:
			return String(full[i + 1])
	return ""


func _hitstop_brief() -> void:
	if _testing() or _hitstop:
		return
	_hitstop = true
	Engine.time_scale = GameStats.HITSTOP_SCALE
	_hitstop_gen += 1
	var my_gen := _hitstop_gen
	var t := get_tree().create_timer(GameStats.HITSTOP_TIME, true, false, true)
	t.timeout.connect(func():
		# 局已重开（代际变了）→ 这次回调作废，不去碰 time_scale
		if my_gen != _hitstop_gen:
			return
		_hitstop = false
		# 恢复到【用户选择的倍速】而不是硬编码 1.0 —— 否则 2.0x 局里一个暴击就把倍速打回原速
		Engine.time_scale = SELFTEST_TIME_SCALE if _testing() else speed_mul)


## 右上角半透明倍速按钮（2026-09-20 用户需求）。自检/探针不创建 —— 门禁基线零变化。
func _build_speed_button() -> void:
	if _testing() or hud == null:
		return
	var b := Button.new()
	b.text = "1.0x"
	b.tooltip_text = "Game Speed"
	b.focus_mode = Control.FOCUS_NONE          # 不抢键盘焦点（Enter/Esc 都是功能键）
	b.mouse_filter = Control.MOUSE_FILTER_STOP # 只吃按钮自身的点击，不挡其余画面
	b.modulate = Color(1.0, 1.0, 1.0, 0.62)    # 半透明悬浮，不遮挡游戏画面
	b.add_theme_font_size_override("font_size", 17)
	b.size = Vector2(92.0, 38.0)
	b.position = Vector2(GameStats.VIEW_WIDTH - 92.0 - 14.0, 12.0)
	b.pressed.connect(_cycle_speed)
	hud.add_child(b)
	_speed_btn = b


## 点击循环 1.0x → 1.5x → 2.0x → 1.0x，即时生效。
func _cycle_speed() -> void:
	var idx := SPEED_STEPS.find(speed_mul)
	speed_mul = float(SPEED_STEPS[(idx + 1) % SPEED_STEPS.size()])
	if not _testing():
		Engine.time_scale = speed_mul
	_update_speed_button()


func _update_speed_button() -> void:
	if _speed_btn != null:
		_speed_btn.text = "%.1fx" % speed_mul


## 本帧实际要绘制的竞技场地面瓦片矩形（行优先）。内部即 GameStats.floor_tile_rects()。
## _draw() 直接用它循环绘制 —— 保证「真实绘制路径」与「数据源」是同一个函数：
## 探针调用本函数，就等于在验证真实绘制用的是这批矩形，而不是另写一套。
func floor_tile_rects() -> Array[Rect2]:
	return GameStats.floor_tile_rects()


## 每块瓦片取自贴图的源区域（纹素）。内部即 GameStats.floor_tile_src_rect()。
## 贴图缺失时用竞技场尺寸兜底（只为让探针能拿到一个可校验的值；_draw() 此时根本不画地面）。
func floor_tile_src_rect() -> Rect2:
	var sz: Vector2 = _floor_tex.get_size() if _floor_tex != null else GameStats.arena_rect().size
	return GameStats.floor_tile_src_rect(sz)


## 当前主题的地面调色（把平均亮度归一到同一档，见 GameStats「地面压场」）。
## 主题数据缺失时兜底为「不调色」。
func floor_grade() -> Color:
	var c: Color = _floor_theme.get("grade", GameStats.FLOOR_GRADE_DEFAULT)
	return c


## 当前主题的柔化纱（向主题自身平均色混合，只压对比不动色调）；缺失时全透明。
func floor_veil() -> Color:
	var c: Color = _floor_theme.get("veil", GameStats.FLOOR_VEIL_DEFAULT)
	return c


## 竞技场底：主题贴图 3×3 瓦片拼接 + 柔化纱 + 柔光 + 暗角 + 边框（跟主题走）。
func _draw() -> void:
	# 竞技场底 = 波次主题的真实贴图【复制成 FLOOR_TILE_COLS×FLOOR_TILE_ROWS 份】拼接
	# （见 _apply_floor_theme）。每一块都画完整贴图、缩放进 640×360 的世界矩形，
	# 16 块精确相邻铺满竞技场 —— 屏幕纹素密度成倍提高（不是把原图切成 16 个碎片）。
	# 源区域由 floor_tile_src_rect() 给出：贴图与格子同比例时就是整张贴图，
	# 不同比例（例如 2048×2048 方图）则从中心裁出格子比例的内接矩形 ⇒ 永不非等比变形。
	# 矩形一律由 GameStats.arena_rect() 在世界空间推导，不碰 camera / get_viewport() /
	# 可视区尺寸 ⇒ 相机缩放(CAMERA_ZOOM)与平移时位置与层级自动正确。
	# 贴图缺失(_floor_tex == null)时地面一块都不画，透出 BackgroundLayer 的兜底色。
	if _floor_tex != null:
		var tiles: Array[Rect2] = floor_tile_rects()
		var src: Rect2 = floor_tile_src_rect()
		var grade: Color = floor_grade()
		for i in tiles.size():
			draw_texture_rect_region(_floor_tex, tiles[i], src, grade)

	# 柔化纱 + 氛围层，都是整块 arena_rect()（不参与瓦片切分）。
	var r := GameStats.arena_rect()
	# 柔化纱：向主题自身平均色混合 ⇒ 压掉每块砖自带的高光/暗角起伏，
	# 削弱「重复起伏被读成地面在起伏」的错觉（2026-09-19 用户反馈头晕后加，
	# 见 GameStats「地面压场」段落的实测依据）。
	draw_rect(r, floor_veil())

	# 柔光（视线聚焦玩家）+ 暗角（边缘压暗）
	if _floor_glow != null:
		draw_texture_rect(_floor_glow, r, false)
	if _floor_vignette != null:
		draw_texture_rect(_floor_vignette, r, false)

	# 边框：颜色跟主题走（一眼能看出换关了）；先宽而淡的发光，再细而实的
	draw_rect(r.grow(2.0), Color(_floor_border_color().r, _floor_border_color().g,
		_floor_border_color().b, 0.12), false, 8.0)
	draw_rect(r, _floor_border_color(), false, GameStats.ARENA_BORDER_WIDTH)
