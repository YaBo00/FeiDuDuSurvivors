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
## 自检允许的最长【游戏内】时长。
## 2026-09-21 波次节奏改版（30s 投放 + 清场制通关）后重校准：单波时长不再固定 30s，
## 而是 30s 投放 + 清场尾（残局扫描普遍 30~90s，随波数增长）。旧上限 900s 是按
## 「20 波 × 30s = 600s」校准的，清场制下 20 波实测必然跑不满 → 提到 2400s。
const SELFTEST_MAX_GAME_TIME := 2400.0
## 无尽自检（--selftest --endless）跑 ENDLESS_SELFTEST_WAVES（40）波。清场制下
## 波 21+ 每波 240+ 只，清场尾远长于投放期 —— 旧上限 1800s 必然超时。
## 按 40 波 ×（30s 投放 + 60~100s 清场）≈ 3600~5200s 校准到 5400s。
const ENDLESS_SELFTEST_MAX_GAME_TIME := 5400.0

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
## 副武器系统（2026-09-22）：局内可获得/升级的第二、第三把武器。
## 与主角武器独立冷却、独立开火；状态由 Battle 持有 ⇒ 每局 start_run 清空。
var extra: ExtraWeaponSystem = null
## 金手指调试面板（2026-09-22）。**刻意声明为无类型 Node**：
## DebugPanel.gd 反向引用 Battle 类型，这里若再写 DebugPanel 类型就构成双向 class_name
## 依赖（本工程在 WaveDirector/CombatResolver 上刻意用 Node 句柄规避过同一问题）。
## 非 null 仅当 GameStats.DEBUG_PANEL_ENABLED 且非自检/探针进程 —— 正常发版恒为 null。
var debug_panel: Node = null

var state: int = State.FIGHTING
var wave_num: int = 0
var wave_timer: float = 0.0
var kills: int = 0
## 本局每类敌人的击杀数（2026-09-22 敌人图鉴）：{enemy_type_id: 本局击杀数}。
## 由 CombatResolver.cleanup_enemies 经 note_enemy_kill() 逐只累加，结算时交给
## MetaSave.record_kills 入图鉴账本。**自爆的班味炸弹不计**（与 kills 同口径）。
var enemy_kills: Dictionary = {}
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

## 本次商店是否已消费「商店券」（精英掉落，全店 8 折；2026-09-22 词缀系统）。
## 每次开店时按 Player.shop_coupon 重算 —— 不清零的旧值绝不允许跨店残留。
var _coupon_active := false
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
## 清场阶段已等待的秒数（仅测试模式用于观测打印，2026-09-21 新波次节奏）。
var _wave_clear_wait := 0.0
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
## 已放过的台词气泡数（探针断言用；也是台词功能的自证计数）
var taunt_lines_shown: int = 0

## hit-stop 防重入
var _hitstop := false
## hit-stop 回调的代际计数：重开一局后旧回调作废，不再改 time_scale（A7）
var _hitstop_gen := 0

## 倍速调节（2026-09-20 用户需求）：战斗内右上角按钮循环 1.0x → 1.5x → 2.0x → 4.0x。
## 4.0x 于 2026-09-22 追加（用户需求）：纯档位扩充，time_scale 语义不变。
## ⚠️ 4.0x 下引擎单步 delta = 1/60×4 ≈ 0.0667s，玩家弹道单步位移 PROJ_SPEED/15 ≈ 15px
##    （PROJ_SPEED=225），仍小于「弹半径+敌半径」的判定阈值 ⇒ 不引入穿透漏判；
##    但敌方弹道（420px/s → 28px/步）接近阈值，命中偶有擦过，方向上偏向玩家有利。
## Engine.time_scale 的【用户侧唯一权威】—— hit-stop 恢复、start_run 重置都从这取值；
## 实现即引擎全局时标：更新逻辑/动画/物理的 delta 按倍率缩放，暂停/结算不受影响。
## 1.0 = 引擎默认值 ⇒ 与旧版本行为【逐位一致】；自检/探针模式不建按钮（门禁基线零变化），
## 每局开始重置回 1.0x，返回标题强制还原 1.0（时标只允许在战斗内生效）。
var speed_mul := 1.0
const SPEED_STEPS := [1.0, 1.5, 2.0, 4.0]
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
	# `--endless`：无尽模式开关。命令行带 flag 才强制置 true；不带 flag 不碰现值 ——
	# 正常游玩由主菜单「无尽模式」按钮显式设值（Title → CharSelect → Battle 同进程保留）。
	# 进程内初值即 false，独立测试进程（门禁/探针）无残留风险；同进程连跑由 Title 每局重设。
	# 与 --char 一样要在 start_run() 之前（HUD / WaveDirector 在波次里读 GameSession.endless）。
	if _has_flag("--endless"):
		GameSession.endless = true
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
	# `--difficulty <normal|hard>`：命令行指定难度（供无头自检 / 门禁验证困难乘区）。
	# 必须在 start_run() 之前 —— Enemy.setup 经 GameStats.hp_scale 读 GameSession.difficulty。
	# 正常游玩不传此参数：难度由主菜单选择，这里保持 GameSession 现值不动。
	var forced_diff := _arg_value("--difficulty")
	if forced_diff != "" and GameStats.DIFFICULTIES.has(forced_diff):
		GameSession.difficulty = forced_diff
		print("[DIFF] 命令行指定难度：%s" % GameStats.difficulty_name())
	_build_floor_overlays()
	player.battle = self
	player.fired.connect(_on_player_fired)
	player.evolved.connect(_on_player_evolved)
	# 【2026-09-20 全库审查 P0】等级升级入队。此前 leveled_up 只 emit 没人听，
	# _upgrade_queue 从未有 "level" 入队 —— 等级三选一面板自始至终没弹出过
	# （波末升级走 WaveDirector 直调 _open_upgrade("wave")，把这条断点完全掩盖了）。
	# 连升多级 → 多次 emit → 队列多条，_maybe_open_queued_upgrade 逐条弹出。
	player.leveled_up.connect(func(_new_level: int) -> void:
		_upgrade_queue.append("level"))
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
	# 副武器系统（2026-09-22）：与 CombatResolver 同一种组合方式（new + add_child + setup）。
	# 必须在 start_run() 之前建好 —— start_run 里的 extra.reset() 要用到它。
	extra = ExtraWeaponSystem.new()
	add_child(extra)
	extra.setup(self)
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
	# 复活契约（2026-09-22 meta 扩充）：Player 管血量/无敌，**清场与演出归 Battle**。
	player.meta_revived.connect(_on_meta_revived)
	# 商店购买必须走真实 UI 链路：面板点击 → purchased 信号 → 这里校验扣款。
	# 【2026-09-19 修复的严重 bug】这条线此前从未接上——点商品只 emit 没人听，
	# 购买静默无效；而门禁探针直接调 _on_shop_purchased 绕过了断点，所以一直全绿。
	shop_panel.purchased.connect(_on_shop_purchased)
	pause_menu.restart_requested.connect(func():
		start_run()
	)
	pause_menu.to_title_requested.connect(func():
		Engine.time_scale = 1.0   # 倍速只允许在战斗内生效：离开战斗强制还原引擎时标
		get_tree().change_scene_to_file("res://scenes/main/Title.tscn")
	)

	_build_speed_button()
	_build_debug_panel()

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
		print("[BALANCE] 平衡观测模式：自动驾驶 + 真实伤害，%s" %
			("无尽曲线跑到阵亡为止" if GameSession.endless else "最多跑满 %d 波" % GameStats.WAVE_COUNT))
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
	enemy_kills.clear()   # 图鉴：每类击杀数是「本局」口径，重开必须清零
	taunt_lines_shown = 0
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
	extra.reset()     # 副武器每局清空（不继承上一局，也不继承 meta）
	_refresh_hud_extra()   # 同步清空 HUD 副武器栏（否则上一局的图标会留到下一次 HUD 拍）
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
	# 局外永久强化注入（MetaSave 消费端第二片）。守卫三重：
	# ① _testing()：自检/平衡/失败路径要确定性基线，绝不带局外加成；
	# ② 探针进程（--script 模式）：门禁探针的数值断言（DPS/血量端到端等）全部
	#    基于无 meta 基线 —— 用户一旦买了强化就会污染门禁，探针进程一律不注入；
	# ③ ⚠️【注入必须早于 player.reset()】（2026-09-22 meta 扩充修正）：reset() 内部的
	#    recalc + `hp = max_hp` 是开局数值的唯一收口点。旧顺序（先 reset 再注入）
	#    会让买了「生命强化 +20」的玩家每局开局停在【旧上限】的残血（100/120）。
	#    早注入 ⇒ 首次 recalc 就带满 meta 乘区，生命/攻速/暴击/启动资金一次到位。
	if not _testing() and not _probe_process():
		player.meta_bonus_dict = MetaSave.meta_bonus()
	player.reset(GameStats.ARENA_CENTER)
	player.set_physics_process(true)
	spawn_obstacles_via_wave()
	result_panel.hide_panel()
	upgrade_panel.hide_panel()
	# 商店面板同样收起（审查 P2）：异常路径下重开一局（暂停菜单 restart）时，
	# 上一局可能停在 SHOP 状态 —— 面板 visible 残留会盖住新局。close() 幂等安全。
	shop_panel.close()
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
	# 清场等待计时按波归零（2026-09-21）：之前只在 _tick_fighting 里累加从不清零，
	# [WAVE-DBG] 打出的「波 N 清场等待 X 秒」是跨波累计值，取证语义失真（会把
	# 上一波的卡顿时间算进这一波）。
	_wave_clear_wait = 0.0
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
## 震屏开关（2026-09-22 设置菜单）：关掉后所有震屏请求直接跳过 —— 受击/击杀/进化/Boss 狂暴
## 全部不再抖屏。读的是 MetaSave 缓存值，热路径零文件 IO。
func shake(strength: float = GameStats.SHAKE_STRENGTH) -> void:
	if not bool(MetaSave.get_setting("screen_shake")):
		return
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
		# ⚠️【窗口关闭当帧的收尾投放，必须在清场判定之前】：投放走累加器，末帧的
		# 小数余数永远等不到下一帧（窗口已关），不补投就会每波少一只（计划 42 → 实投 41）。
		# 放在这里 = 「本波该出多少只」在进入清场阶段前就已全部落地，之后只减不增。
		wave.flush_pending_spawn()
		# ⚠️【清场判定必须早于 tick_spawn】：窗口关闭与「场上还有怪」可能发生在同一帧
		# （窗口末尾那一帧还会放怪）。若先 tick_spawn 再判定，那只刚放出来的怪要等到
		# 下一帧才被看见 —— 中间夹着的 wave.end_wave() → 升级面板会把整棵树的
		# physics 停掉，判定再也没有机会跑，玩家就卡死在「条 0%、没怪、不推进」。
		# 先判定则末帧放怪后立刻进入清场阶段，逻辑闭合。
		if wave.spawn_window_closed():
			# 投放窗口已结束（本波不再生成敌人）。通关条件（2026-09-21 用户需求）：
			#   · 普通波 —— 清理完场上所有敌人即通过
			#   · Boss 波 —— Boss 死亡即通过（Boss 是场上唯一目标；旧语义保留）
			# 两者都是「清空即可」，故统一判定 _wave_cleared()，不再有「活到 30 秒」这条路。
			if _testing() and not _wave_cleared():
				_wave_clear_wait += delta
				# 每 5 秒打一行（曾用 0.5 秒 → 单次自检日志 1300+ 行，噪音太大）。
				# 这条是「清场是否卡死」的唯一现场证据：数字长时间不变 = 死锁。
				if int(_wave_clear_wait / 5.0) != int((_wave_clear_wait - delta) / 5.0):
					var line: String = "[WAVE-DBG] 波%d 清场等待 %.1fs：场上 %d 只（timer=%.1f）" % [
						wave_num, _wave_clear_wait, enemies.size(), wave_timer]
					# 等待 ≥20s → 疑似卡死，附残敌取证（类型/行为/与玩家距离）——
					# 在真实自检环境里定位「最后几只打不到」的机制（--script 直启
					# Battle 会缺自检链路冻结在波 1，取证只能内嵌在这里）。
					if _wave_clear_wait >= 20.0:
						var det: String = ""
						var k := 0
						for e in enemies:
							if not is_instance_valid(e) or e.is_dead:
								continue
							det += " %s(%s,d%.0f,hp%d)" % [e.type_name, e.behavior,
								player.global_position.distance_to(e.global_position), e.hp]
							k += 1
							if k >= 6:
								break
						line += " 残敌:" + det
						# 玩家侧现场（2026-09-21）：残局打不死 = 「没开火」或「开了火没命中」，
						# 五个数字足以分辨：proj数（弹道是否在生成/回收）、命中表（去重表是否
						# 异常膨胀）、kills（弹道系统整局是否工作过）、攻击冷却、当前射程。
						line += " | 玩家(%.0f,%.0f) proj=%d 表=%d kills=%d atk_t=%.2f rng=%.0f" % [
							player.global_position.x, player.global_position.y,
							projectiles.size(), combat._proj_hits.size(),
							kills, player.attack_timer, player.attack_range]
					print(line)
			if _wave_cleared():
				wave.end_wave()
				return
			# Boss 波测试模式兜底：selftest/balance 的无敌/自动驾驶玩家可能打不死动态血
			# Boss（血量随 hp_scale 涨到波 20 的数万），窗口结束后再观察
			# BOSS_WAVE_TEST_GRACE 秒仍无果就放行，保证流程门禁不卡死。
			# 正常游玩【没有】这条 —— Boss 不死波就不结束。
			if _testing() and _has_alive_boss() \
					and wave_timer <= GameStats.WAVE_DURATION - GameStats.SPAWN_WINDOW \
					- GameStats.BOSS_WAVE_TEST_GRACE:
				print("[%s] Boss 波 #%d 兜底推进（Boss 未被击杀，测试观察期已过）" % [
					_test_tag(), wave_num])
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
	# 副武器推进（2026-09-22）：放在 cleanup_enemies 与网格重建【之后】——
	# ① 本帧已死的敌人不会被飞刃/闪电再打一次；② 击杀侧效统一由 cleanup 结算，
	# 副武器只负责「谁掉血」，不重复实现掉落/飘字规则。
	extra.update(delta)
	feedback.update_floats(delta)
	_tick_enemy_taunts()
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
		_refresh_hud_extra()   # 副武器图标 + 等级点（Hud 内部指纹去重，没变就不动）
	# 清场进度条逐帧刷新（2026-09-21）：它是 HUD 里唯一要求帧级实时的元素 ——
	# 杀一只怪要立刻看到条涨，而 set_data 走的是 HUD_INTERVAL 节拍（会明显滞后一拍）。
	# 读 WaveDirector 的比值而不是自己算，保证与关内判定 _wave_cleared() 同源。
	hud.set_clear_ratio(wave.wave_clear_ratio())
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
	feedback.play_evolution_nova(player.global_position)
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


## 记一只敌人的击杀（2026-09-22 敌人图鉴）。**唯一调用点 = CombatResolver.cleanup_enemies**
## （它也是全局 `kills` 的唯一累加点）—— 两者同源，图鉴的击杀数与战绩面板永远对得上。
func note_enemy_kill(t: String) -> void:
	enemy_kills[t] = int(enemy_kills.get(t, 0)) + 1


## 入场台词（2026-09-20 用户需求）：敌人首次进入玩家视野时头顶冒泡，每只一次。
## 每帧只算一次可视矩形；已说过的用 bool 短路 —— 满场 140 只也只是一次布尔遍历。
## 表里没登记的杂鱼（Slime/Rat 等）查表得空串，直接标 done 不冒泡，防刷屏。
func _tick_enemy_taunts() -> void:
	var vr := visible_world_rect()
	for e in enemies:
		if e.taunt_done or e.is_dead:
			continue
		if not vr.has_point(e.global_position):
			continue
		e.taunt_done = true
		var line := GameStats.enemy_taunt(String(e.type_name), "spawn")
		if line != "":
			taunt_lines_shown += 1
			feedback.spawn_float(e.global_position + Vector2(0.0, -e.radius * 2.6),
				line, Color(0.95, 0.95, 1.0), false)
		# 精英词缀名（2026-09-22 词缀系统）：与入场台词共用这一次可视检测，在台词上方
		# 再冒一个小字标签，颜色 = 词缀色 ⇒ 玩家能把「青色 = 疾风 / 灰 = 钢甲」对上号。
		# 只在有词缀时冒（普通怪 / Boss 恒无），且每只一次（复用 taunt_done 语义）。
		if e.affix != "":
			var an := GameStats.elite_affix_name(e.affix)
			if an != "":
				feedback.spawn_float(
					e.global_position + Vector2(0.0, -e.radius * 2.6 - 20.0),
					an, GameStats.elite_affix_color(e.affix), false)


## 台词气泡（放招/事件喊话）：位置由发射方按头顶偏移算好，这里只管播。
func _on_enemy_line(pos: Vector2, text: String) -> void:
	taunt_lines_shown += 1
	feedback.spawn_float(pos, text, Color(1.0, 0.9, 0.55), true)


## 场上是否还有存活的 Boss 行为怪（Boss 波「Boss 死亡才推进」的判定）。
func _has_alive_boss() -> bool:
	for e in enemies:
		if is_instance_valid(e) and not e.is_dead and e.behavior == "boss":
			return true
	return false


## 本波是否已清空（通关条件，2026-09-21 用户需求）。
## 与 WaveDirector.wave_clear_ratio() 同源：两者读同一组计数（enemies + 本波击杀），
## 所以「进度条走到 100%」与「真的过关」在定义上不可能打架。
## 只有 is_dead 才算死 —— queue_free 是【延迟释放】，清理要等 CombatResolver.cleanup_enemies()
## 在本帧稍后跑，用 is_instance_valid 判会被已标记死亡但尚未释放的怪骗过去。
func _wave_cleared() -> bool:
	for e in enemies:
		if is_instance_valid(e) and not e.is_dead:
			return false
	return true


## Boss 半血狂暴（2026-09-20 需求 §2.3）：震屏 + 屏幕中央大字 + 爆裂 + 低沉音效。
## 身体闪烁由 Enemy 自演（modulate 红色脉冲）；程序化反馈，无新美术。
func _on_boss_rage(pos: Vector2) -> void:
	shake(GameStats.BOSS_RAGE_SHAKE)
	hud.show_center_notice("BOSS 狂暴了！", GameStats.BOSS_RAGE_NOTICE_TIME)
	feedback.spawn_burst(pos, Color(0.95, 0.2, 0.2), true)
	_on_sfx_requested("kill", -2.0, 0.7)


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


## 精英词缀的死亡效果（2026-09-22 词缀系统）。Enemy 只发信号（它不持 player / enemies），
## 实际结算在这里 —— 与 splitter 分裂、Boss 召唤同一分工。
## 不认识的词缀（swift/armored/enraged）在这里无事可做：它们的效果全在生存期。
func _on_affix_death(pos: Vector2, affix: String) -> void:
	var d := GameStats.elite_affix(affix)
	if d.is_empty():
		return
	match affix:
		"exploder":
			_explode_at(pos, d)
		"summoner":
			_summon_on_death(pos, d)


## 爆裂词缀：死亡点爆一个 death_aoe 半径的圈，对圈内玩家造成 death_aoe_dmg 点伤害。
##
## 【可走位躲】伤害在死亡瞬间判一次距离 —— 站圈里就吃，站圈外（或死在远处）不吃。
## 视觉上画出实际半径的红圈 0.3s：玩家据此建立「圈 = 伤害范围」的读感。
##
## 伤害口径：走 Player.take_hit —— 与接触伤害/敌弹完全同一条路（闪避 / 无敌帧 /
## 护盾 / 护甲减免全都照常生效），需求文档 §3 明确要求「吃无敌帧」。
## 难度乘区在此处收口：只有这里不是「模板 dmg × 波次曲线」（那会把 30 点卷到几百点），
## 所以按 DIFFICULTIES.dmg_mul 手工乘一次（普通 ×1.0 = 30，困难 ×1.3 = 39）。
func _explode_at(pos: Vector2, d: Dictionary) -> void:
	var r := float(d.get("death_aoe", 0.0))
	var dmg := maxi(1, roundi(float(d.get("death_aoe_dmg", 0.0))
		* float(GameStats.difficulty_def()["dmg_mul"])))
	var blast := AffixBlast.new()
	world.add_child(blast)
	blast.fire(pos, r, GameStats.elite_affix_color("exploder"))
	_on_sfx_requested("kill", -3.0, 0.55)
	shake(GameStats.SHAKE_STRENGTH * 0.9)
	if player.global_position.distance_to(pos) > r:
		return
	var res: Dictionary = player.take_hit(dmg)
	var result := String(res["result"])
	if result == "hit" or result == "dead":
		feedback.spawn_float(player.global_position + Vector2(0, -44.0),
			"-%d" % int(res["dmg"]), Color(1.0, 0.35, 0.30), false)
	if result == "dead":
		_on_player_died()


## 召唤词缀：死亡时在原地生成 N 只 Slime（默认 2 只、60% 血）。
##
## 与 splitter 分裂同口径：**不占** spawn_remaining 名额（清场进度分母不被撑破），
## 同屏 cap 天然生效（它们确实进了 enemies 数组）；enforce_spawn_dist = false ——
## 生在尸位旁是预期（玩家刚把精英打死就站在旁边）。
func _summon_on_death(pos: Vector2, d: Dictionary) -> void:
	var pair: Array = d.get("summon_on_death", [])
	if pair.size() < 2:
		return
	var t := String(pair[0])
	var n := maxi(1, int(pair[1]))
	var hp_mul := float(d.get("summon_hp_mul", 1.0))
	for i in n:
		var ang := TAU * float(i) / float(n) + 0.6
		var p: Vector2 = pos + Vector2(cos(ang), sin(ang)) * 22.0
		wave.spawn_enemy(t, p, hp_mul, false)


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
			# 5% max_hp，至少 1 点 —— Enemy.hp 是 int，纯小数治疗会被截断吞掉
			var amount := int(maxf(1.0, float(best.max_hp) * GameStats.SUPPORT_HEAL_RATIO))
			best.hp = mini(int(best.max_hp), int(best.hp) + amount)
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


## 复活契约触发（2026-09-22 meta 扩充）：Player 已回满 50% 血 + 1s 无敌，这里补两件事 ——
## ① 清场（需求 §2.2 明确要求）：玩家刚在怪堆里复活，不清场下一帧就再被围死。
## ② 演出：与武器进化同规格的播报（大字 + 震屏 + 双音效），让「契约生效」不可错过。
##
## ⚠️ 清场走 call_deferred —— 本回调是**从 take_hit 内部同步发出的**，触发链可能是
## `contact_damage()` / `process_projectiles()` 的遍历中途；就地 mutate `enemies`/`_grid`
## 会让调用方手里那个 Array 与本回合一帧内的世界不一致。延到本帧末再清，语义不变（无敌 1s 兜底）。
func _on_meta_revived() -> void:
	call_deferred("_free_all_enemies")   # 见上方 ⚠️：延到本帧末再 mutate 敌人数组
	feedback.spawn_float(player.global_position + Vector2(0.0, -70.0),
		"复活契约！", Color(0.62, 0.92, 1.0), true)
	shake()
	feedback.play_evolution_nova(player.global_position)
	_on_sfx_requested("levelup", -3.0, 0.8)
	_on_sfx_requested("coin", -3.0, 0.9)


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
		# 弹道数卡不再因上限过滤（2026-09-20 用户需求：弹道不设上限，可无限叠加）。
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
	# 选项数 = 基础值 + 角色天赋加成（学习嘉豪 +1）+ 预知未来额外选项（2026-09-20 扩充，
	# 与天赋叠加；消费后清零 —— 「下次升级」语义）。
	var extra_cards: int = player.extra_card_pending
	if extra_cards > 0:
		player.extra_card_pending = 0
	var count := GameStats.UPGRADE_OPTIONS \
		+ int(GameStats.character(player.char_id)["upgrade_opt_bonus"]) + extra_cards
	var pick: Array = avail.slice(0, mini(count, avail.size()))
	# ---- 副武器卡（2026-09-22）----
	# 规则（需求文档 §1.3 / §3）：未持有且未满 2 把 → 出「获得」卡；已持有且未满级 →
	# 出「升级」卡；持满 2 把后不再出获得卡；某把满级后它的升级卡消失。
	# 出现率约 EXTRA_WEAPON_CARD_RATE，用【替换】实现：若改成追加进 13 张的池子里再抽 3 张，
	# 单卡命中率只有 ~23%；替换才是稳定的 1/3（与武器精通的 0.34 同一思路）。
	var wcards := _extra_weapon_cards()
	# 副武器卡占用的槽位下标；-1 = 本张没出（质检 P2-3，2026-09-22）：
	# 下面武器精通的补卡若 randi 恰好落在这个槽，会把 cost_tier 3 的稀有卡白顶掉。
	# 修法 = 预筛槽位后从中选——随机数消耗与旧版完全一致（各分支仍是 1 次 randi），
	# 自检随机序列逐位不变，只有「精通落槽分布」不再覆盖副武器卡槽。
	var wslot := -1
	if not wcards.is_empty() and not pick.is_empty() \
			and randf() < GameStats.EXTRA_WEAPON_CARD_RATE:
		wslot = randi() % pick.size()
		pick[wslot] = wcards[randi() % wcards.size()]
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
				# 可落槽位 = 全部槽位 − 副武器卡占的槽（wslot == -1 时即全部，
				# 与旧版 randi() % pick.size() 逐位同分布）。随机数消耗不变。
				var slots: Array[int] = []
				for i in pick.size():
					if i != wslot:
						slots.append(i)
				if slots.is_empty():
					pass   # 防御：只剩副武器卡一个槽时放弃补卡（实际不可能，UPGRADE_OPTIONS≥3）
				elif _current_reason == "wave":
					pick[slots[randi() % slots.size()]] = mastery
				elif _current_reason == "level" and randf() < 0.34:
					pick[slots[randi() % slots.size()]] = mastery
	# 武器精通卡携带进化进度（2026-09-20 用户需求：选卡时看得见叠了几层）。
	# 等级路径的 opt 是 const 表引用 → 必须 duplicate 后再挂键。
	for i in pick.size():
		var o: Dictionary = pick[i]
		if String(o.get("id", "")) != "weapon_mastery":
			continue
		o = o.duplicate()
		o["mastery_progress"] = int(player.weapon_level)
		pick[i] = o
	# 金手指注入（隐藏调试面板「强制出现指定升级卡」）：把指定 id 塞进本组选项，取后即清空。
	# 空串 ⇒ 整段短路，选项集合与随机数消耗逐位不变（面板在自检/门禁进程里根本不实例化）。
	_apply_forced_upgrade(pick, wslot)
	_current_options = pick


## 调试注入的落地点（唯一消费点，见 GameStats.debug_force_upgrade）。
## 落槽位 = 最后一个槽，但避开拓副武器卡的槽；已在选项里则不重复塞。
## 波末路径同样给这张卡挂「敌人代价」，保证卡面与其它卡口径一致（否则玩家看到一张无代价卡
## 会以为是 bug）。
func _apply_forced_upgrade(pick: Array, wslot: int) -> void:
	var forced := String(GameStats.debug_force_upgrade)
	if forced == "" or pick.is_empty():
		return
	GameStats.debug_force_upgrade = ""
	for o in pick:
		if String(o.get("id", "")) == forced:
			return                      # 已在本组选项里（随机正好抽到），无需注入
	var fdef: Dictionary = {}
	for d in GameStats.UPGRADE_POOL:
		if String(d["id"]) == forced:
			fdef = d
			break
	if fdef.is_empty():
		push_warning("[DebugPanel] 未知升级 id：%s（注入忽略）" % forced)
		return
	var fcopy: Dictionary = fdef.duplicate()
	if _current_reason == "wave":
		var fcost: Dictionary = _pick_enemy_cost(int(fdef.get("cost_tier", 1)))
		if not fcost.is_empty():
			fcopy["cost"] = fcost
	var slot := pick.size() - 1
	if slot == wslot and slot > 0:
		slot -= 1                       # 不覆盖副武器卡槽（它会再走一遍自己的生成逻辑）
	pick[slot] = fcopy


## 副武器栏数据（2026-09-22）：把「持有哪几把 + 各几级」喂给 Hud。
## 只在 HUD 节拍 / 拿卡瞬间调用；Hud 侧有内容指纹，重复调用零开销。
func _refresh_hud_extra() -> void:
	if hud == null or extra == null:
		return
	var ids: Array[String] = extra.owned_ids()
	var levels: Dictionary = {}
	for id in ids:
		levels[id] = extra.level_of(id)
	hud.set_extra_weapons(ids, levels)


## 副武器升级卡（2026-09-22）。
## 返回当前【合法】的卡（获得 + 升级两类），空数组 = 一张都出不了。
## 过滤规则：
##   · 未持有 + 未持满 MAX_EXTRA_WEAPONS → 「获得」卡（cost_tier 3，稀有）
##   · 已持有 + 未满级                  → 「升级」卡（cost_tier 2）
##   · 持满 2 把                        → 不再出「获得」卡（升级卡照出）
##   · 某把已满级                        → 该武器的升级卡消失
## 卡面文案走 display 字段（UpgradePanel 优先读它）——「获得」与「升级」的语义
## 与普通属性卡的「+N」完全不同，用通用格式化会显示成「+0」。
func _extra_weapon_cards() -> Array:
	var out: Array = []
	# 上限经 GameStats.extra_weapon_cap() 收口（金手指「解除上限」后出卡规则自动跟着变）。
	var full: bool = extra.owned_count() >= GameStats.extra_weapon_cap()
	for id in GameStats.EXTRA_WEAPON_IDS:
		var wid := String(id)
		var wname := String(GameStats.EXTRA_WEAPON_DEFS[wid]["name"])
		var wdesc := String(GameStats.EXTRA_WEAPON_DEFS[wid]["desc"])
		var lvl := extra.level_of(wid)
		var card: Dictionary = {}
		if lvl <= 0:
			if full:
				continue
			card = {
				"id": "w_%s_gain" % wid, "name": wname, "kind": "new_weapon",
				"weapon_id": wid, "cost_tier": 3, "pct": false,
				"tiers": [0.0, 0.0, 0.0],
				"display": "获得副武器　·　%s" % wdesc,
			}
		elif lvl < GameStats.extra_weapon_max_level(wid):
			card = {
				"id": "w_%s_lvl" % wid, "name": "%s Lv%d" % [wname, lvl + 1],
				"kind": "level_weapon", "weapon_id": wid, "cost_tier": 2, "pct": false,
				"tiers": [0.0, 0.0, 0.0],
				"display": GameStats.extra_weapon_card_text(wid, lvl + 1),
			}
		else:
			continue   # 已满级：升级卡消失（文档 §3）
		# 波末卡同样捆绑「敌人代价」（与普通卡同一套档位分配；纯读叠层，不写状态）
		if _current_reason == "wave":
			var cost: Dictionary = _pick_enemy_cost(int(card["cost_tier"]))
			if not cost.is_empty():
				card["cost"] = cost
		out.append(card)
	return out


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
## 本次商店的实际价格乘区 = 角色/道具折扣（player.shop_discount）× 商店券 8 折。
## 只此一个出口：开店与「刷新道具」重抽都读它 ⇒ 同一家店里所有卡（含重抽上来的）
## 用的是同一个折扣，不会出现「买一张后折扣消失、后面恢复原价」。
func _shop_discount_now() -> float:
	return player.shop_discount * (GameStats.COUPON_DISCOUNT if _coupon_active else 1.0)


func _open_shop() -> void:
	state = State.SHOP
	get_tree().paused = true
	# 精英「商店券」（2026-09-22 词缀系统）：进店消费 1 张 → 本次全店 8 折。
	# 消费点放在【开店这一刻】而不是购买时，理由见 _shop_discount_now。
	if player.shop_coupon > 0:
		player.shop_coupon -= 1
		_coupon_active = true
	else:
		_coupon_active = false
	shop_panel.open(wave_num, player.gold, _shop_discount_now(), _on_shop_closed, _testing(), items_owned,
		player.weapon_level)


## 商店购买请求（由面板 purchased 信号发起）：校验余额 → 扣钱 → 应用 → 锁卡。
## index 用于购买成功后把该卡标记为已售出（防止同一张卡反复购买）。
func _on_shop_purchased(item_id: String, price: int, index: int) -> void:
	if player.gold < price:
		return
	player.gold -= price
	player.apply_item(item_id)
	items_owned.append(item_id)   # A4 前置解锁链：记录已购（下波商店前置判定用）
	# 「刷新」道具（2026-09-20 商店扩充）：整批商品重抽 —— 不锁卡（新商品上来）、
	# 已扣的钱不退；重抽沿用当前折扣与前置链状态。其余道具照旧锁卡防重复购买。
	if item_id == "s_reroll":
		shop_panel.reroll(_shop_discount_now(), items_owned, player.weapon_level)
	else:
		shop_panel.mark_sold(index)
	if audio != null:
		audio.play("buy", -4.0)
	shop_panel.refresh(player.gold)


## 离开商店 → 下一波
func _on_shop_closed() -> void:
	get_tree().paused = false
	start_next_wave()


func _on_upgrade_chosen(opt: Dictionary, _index: int) -> void:
	# 副武器卡（2026-09-22）走自己的入口：它们不改属性，而是「获得 / 升一级」，
	# 由 ExtraWeaponSystem 持有。kind 缺失（普通卡）时落默认分支，行为逐位不变。
	match String(opt.get("kind", "")):
		"new_weapon":
			var wid := String(opt["weapon_id"])
			# 选完立刻给一次战场飘字反馈：副武器是持续生效的，不给反馈的话
			# 玩家只能靠「屏幕上多了个绕圈的东西」才发现自己拿了什么。
			if extra.grant(wid):
				feedback.spawn_float(player.global_position + Vector2(0.0, -58.0),
					"获得副武器：%s" % String(GameStats.EXTRA_WEAPON_DEFS[wid]["name"]),
					Color(1.0, 0.85, 0.35), true)
				_refresh_hud_extra()   # 立刻点亮 HUD 槽（不等下一拍 0.08s）
		"level_weapon":
			var wid2 := String(opt["weapon_id"])
			if extra.level_up(wid2):
				feedback.spawn_float(player.global_position + Vector2(0.0, -58.0),
					"%s Lv%d" % [String(GameStats.EXTRA_WEAPON_DEFS[wid2]["name"]),
						extra.level_of(wid2)],
					Color(1.0, 0.85, 0.35), true)
				_refresh_hud_extra()   # 立刻多亮一格等级点
		_:
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
	# 2026-09-20 无尽体验：无尽局额外更新 best_endless_wave；入账前先读旧纪录，
	# 阵亡时若超过旧纪录 → 结算页标「新纪录」。
	# 守卫：自检与探针进程的战绩不写真实账本（否则门禁跑完用户账本全是测试数据）。
	var endless_best_before := 0
	if GameSession.endless:
		endless_best_before = int(MetaSave.ledger()["best_endless_wave"])
	if not _testing() and not _probe_process():
		MetaSave.record_run(victory, waves_completed, kills, player.gold, GameSession.endless)
		# 敌人图鉴（2026-09-22）：本局每类敌人的击杀数并入图鉴账本（累计 + 解锁）。
		# 与 record_run 同一个守卫 —— 自检/探针进程同样不写图鉴档（保证门禁不污染玩家存档）。
		MetaSave.record_kills(enemy_kills)
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
		"difficulty": GameStats.difficulty_name(),
		# 无尽体验（2026-09-20）：模式标记 + 历史最佳 + 是否破纪录（字段缺省时面板按普通局渲染，
		# 旧调用方/探针零影响）。破纪录只认「真跑」——测试进程不入账，也谈不上破纪录。
		"endless": GameSession.endless,
		"endless_best": maxi(endless_best_before, waves_completed if GameSession.endless else 0),
		"new_record": GameSession.endless and not _testing() and not _probe_process()
			and waves_completed > endless_best_before,
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
	print("[SELFTEST] char=%s weapon=%s trait=%s difficulty=%s" % [
		player.char_id,
		GameStats.weapon_for_char(player.char_id)["name"],
		player.trait_id if player.trait_id != "" else "(none)",
		GameStats.difficulty_name(),
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
	# not is_echo()：长按 R 会连发 echo 事件 —— 旧实现一次长按触发十几次整局重置
	#（审查 P1）。只在首次按下响应，按住不重复。
	elif event is InputEventKey and event.pressed and not event.is_echo() \
			and event.physical_keycode == KEY_R:
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


## 点击循环 1.0x → 1.5x → 2.0x → 4.0x → 1.0x，即时生效。
func _cycle_speed() -> void:
	var idx := SPEED_STEPS.find(speed_mul)
	speed_mul = float(SPEED_STEPS[(idx + 1) % SPEED_STEPS.size()])
	# hit-stop 进行中只更新权威值 speed_mul、不碰 Engine.time_scale（审查 P2）——
	# 否则暴击顿帧里点一下按钮就把时标顶回倍速值，hit-stop 被提前掐掉；
	# 恢复回调本来就读最新 speed_mul，顿帧结束后自然落到新倍速。
	if not _testing() and not _hitstop:
		Engine.time_scale = speed_mul
	_update_speed_button()


func _update_speed_button() -> void:
	if _speed_btn != null:
		_speed_btn.text = "%.1fx" % speed_mul


## 金手指调试面板的挂接点（2026-09-22）。加挂条件三重：
##   ① GameStats.DEBUG_PANEL_ENABLED —— 发版开关，改 false 则**根本不实例化**，
##      连左上角「难度」文字上的隐形热区都不会挂，玩家彻底点不出来；
##   ② not _testing() —— 自检 / 平衡观测要确定性基线，绝不引入任何额外节点；
##   ③ not _probe_process() —— 门禁探针（--script）同样零影响 ⇒ 8 分钟门禁基线不动。
## 用 load() 而不是 preload()：关掉开关后连这个场景资源都不进内存（发版零残留）。
func _build_debug_panel() -> void:
	if not GameStats.DEBUG_PANEL_ENABLED or _testing() or _probe_process():
		return
	var ps: PackedScene = load("res://scenes/debug/DebugPanel.tscn")
	if ps == null:
		push_warning("[Battle] 调试面板场景缺失（res://scenes/debug/DebugPanel.tscn）")
		return
	debug_panel = ps.instantiate()
	add_child(debug_panel)
	# 动态调用：debug_panel 声明为 Node（见字段注释），静态调用 setup 会编译不过。
	debug_panel.call("setup", self)


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
