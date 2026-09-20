class_name Enemy
extends Node2D
## 敌人。追踪玩家（直线移动），被弹道命中掉血，血 <= 0 由 Battle 结算击杀。
##
## 【本次迁移的关键修正】def 是【显式声明的 int 字段】，且初始化时一定取到模板里的
## 有定义值（模板全部为 0）。H5 原型里 def 是 undefined → NaN → 敌人永远杀不死。
## 这里从类型和初始化两条路径同时杜绝 NaN。
##
## 【为什么不用 CharacterBody2D】建筑物确实要能挡住敌人，但把它们做成物理体后
## 实测出严重性能问题：场上 60~80 只 CharacterBody2D 在 360 物理帧/秒下把引擎拖垮，
## 游戏时间推进比真实时间还慢（一次观测跑了 480 秒都没结束）。
## 移动端更不能这么干。
## 现在改用【纯数学的圆-矩形推出】（见 _resolve_obstacles）：7 个矩形 × N 只怪，
## 每帧几百次算术，成本可以忽略。顺带也天然满足「敌我之间不碰撞」——
## 几十只怪不会互相顶住堆成一堵墙。

var type_name: String = "Slime"
var hp: int = 0
var max_hp: int = 0
var defense: int = 0          # 显式 int；命名避开 GDScript 保留位，对外语义同 H5 的 e.def
var dmg: int = 0
var speed: float = 0.0
var radius: float = 12.0
var gold: int = 1
var xp_value: int = 2
var body_color: Color = Color("#ff6b6b")

## 追踪目标（玩家）。由 Battle 注入。
var target: Node2D = null
var is_dead: bool = false
## 最后一次命中的伤害是否为暴击（死亡时用于 hit-stop / 更大的爆裂）
var last_hit_crit := false
## 头顶血条（精英/Boss 用）。普通小怪不开 —— 满地血条反而看不清
var show_health_bar := false
## 行为类型："melee"（近战追击）/ "ranged"（保持距离 + 射击）/ "boss"
var behavior := "melee"
## 远程怪射击计时器
var _fire_timer := 0.0
## 远程怪发射敌方弹道时的回调（由 Battle 连接）
signal fired_enemy_proj(pos: Vector2, dir: float, dmg: int)
## Boss 请求召唤小弟。Enemy 不持有 enemies 数组，由 Battle 转交 WaveDirector.spawn_enemy。
signal summon_requested(pos: Vector2, type_name: String, count: int)
## Splitter（精神内耗）致死时请求分裂：Battle 听到后在原位生成 2 只 60% 血的 Rat
signal split_requested(pos: Vector2)
## 全场提速光环（BossPUA 召唤瞬间）：Battle 听到后给所有存活敌人临时加速
signal global_speed_aura(mul: float, dur: float)
## 新行为音效（charger 冲锋 / bomber 引信 / splitter 裂开）：Battle 转发 audio.play
signal sfx_requested(name: String, volume_db: float, pitch: float)
## 班长（support）光环脉冲：每 2s 发一次提速（heal=false）、每 4s 发一次治疗（heal=true）。
## 范围过滤与目标选择在 Battle 侧做 —— Enemy 不持有 enemies 数组。
signal support_pulse(pos: Vector2, heal: bool)
## 台词气泡（2026-09-20）：放招/事件喊话。位置由发射方算好（头顶偏移），
## 文案来自 GameStats.ENEMY_TAUNTS；入场台词由 Battle 的可视检测直接驱动（不经本信号）。
signal line_requested(pos: Vector2, text: String)
## Boss 半血狂暴（2026-09-20）：身体闪烁由本节点自演（modulate 脉冲），
## 震屏 / 屏幕中央大字 / 音效属战场反馈，走信号交 Battle 转发（模块不持 camera/feedback）。
signal rage_requested(pos: Vector2)

# ---- Boss 特殊技能状态机（2026-09-19 批次三）----
## 状态：chase（慢速追击，攒冷却）→ windup（前摇：站住 + 视觉预警）→
##       active（招式生效）→ recover（硬直）→ chase …
## 只有 behavior == "boss" 会走到这套；melee / ranged 逐字保持原行为（对照组）。
var boss_skill_state := "chase"
## 下一次要出的招在 GameStats.BOSS_SKILL_ORDER 里的下标（出招后循环递增）。
var boss_skill_index := 0
## 本次出招名（windup/active/recover 期间有效，chase 期间为 ""）。
var boss_skill_name := ""
## 各招已触发次数 name -> int（探针断言「三招都触发过」）。
var boss_skill_used: Dictionary = {}
## 前摇剩余秒数（windup 期间 > 0 且单调递减）。
var boss_windup_left := 0.0
## 冲锋方向。**在 windup 开始的瞬间锁定**（那时玩家还有整整一个前摇的时间躲），
## 冲锋途中不得改变 —— 这是公平性核心，也是门禁要断言的点。
var boss_charge_dir := Vector2.ZERO
## chase 状态下攒的出招冷却（秒）。
var _boss_cooldown := 0.0
## active 阶段剩余秒数（只有 charge 真正用到）。
var _boss_active_left := 0.0
## 前摇总时长（本招），用于预警进度的归一化。
var _boss_windup_total := 0.0

# ---- 新敌人行为状态（2026-09-20）----
## charger（卷王）：approach → windup（站住闪红锁定方向）→ dash → recover → approach
var charger_state := "approach"
var _charger_t := 0.0
var _charger_dir := Vector2.ZERO
## bomber（班味炸弹）：chase → fuse（站住闪红倒计时）→ 自爆或取消
var bomber_state := "chase"
var _bomber_t := 0.0
## 班长（support）光环计时器
var _support_pulse_t := 0.0
var _support_heal_t := 0.0
## 临时移速乘区（班长光环 / BossPUA 群体 PUA）。**运行时 buff，绝不写进模板/Stats**；
## 多来源取 max 不叠加，到期回 1.0。
var temp_speed_mul := 1.0
var _temp_speed_t := 0.0
## 台词状态（2026-09-20）：taunt_done = 入场气泡已放过（每只一次）；
## died_exploded = 班味炸弹【自爆】死亡（不算被击杀，压制击杀台词）；
## _monitor_line_done = 班长首次光环喊话已放过（防 2s 一句刷屏）。
var taunt_done := false
var died_exploded := false
var _monitor_line_done := false
## Boss 半血狂暴（2026-09-20）：_rage_triggered = 本场已触发过（一次性）；
## _rage_flash_t = 红色脉冲剩余秒数（>0 期间 modulate 周期闪烁）。
var _rage_triggered := false
var _rage_flash_t := 0.0

## 逐帧动画速度。[PLACEHOLDER] 未 playtest。
const IDLE_FPS := 6.0

@onready var sprite: AnimatedSprite2D = $Sprite
## 建筑物矩形（由 Battle 注入，指向同一批数据）。
## 敌人不碰玩家、不碰彼此，只被建筑物挡住。
var obstacles: Array[Rect2] = []

## 是否成功用上了美术精灵。失败则回落到 _draw() 里的图元占位画法。
var _use_sprite := false

var _hit_flash := 0.0


## 按波次缩放初始化。pos 为出生点。
## hp_cost / dmg_cost：波末升级捆绑的「敌人代价」累积乘区（A1 双向投票的敌人侧，
## 由 WaveDirector 从 Battle 传入；默认 1.0 = 无代价 —— 探针直调 setup 的旧路径零影响）。
func setup(p_type: String, wave_num: int, pos: Vector2, hp_cost := 1.0, dmg_cost := 1.0) -> void:
	type_name = p_type
	var t := GameStats.enemy_template(p_type)
	max_hp = roundi(float(t["hp"]) * GameStats.hp_scale(wave_num) * hp_cost)
	hp = max_hp
	defense = int(t["def"])                       # ← 显式赋值为 0，杜绝 NaN
	dmg = roundi(float(t["dmg"]) * GameStats.dmg_scale(wave_num) * dmg_cost)
	speed = GameStats.enemy_speed(p_type)
	radius = float(t["radius"])
	gold = int(t["gold"])
	# 经验 = 金币 × 3（原本 ×2）。实测 20 波只升到 8 级，成长感太弱 ——
	# 在商店做出来之前，升级是玩家唯一的成长途径，必须给够。
	xp_value = gold * GameStats.XP_PER_GOLD
	body_color = _color_for(p_type)
	# A8：精英/Boss 才有头顶血条
	show_health_bar = p_type in ["Elite", "Boss", "Ranged", "BossPUA"]
	# 行为类型（melee / ranged / boss），从模板读
	behavior = String(t.get("behavior", "melee"))
	# Boss 技能状态机复位（复用实例/重复 setup 都不会把旧状态带进来）。
	# 首招等一个完整间隔 —— 行为可预期，玩家进场先热身。
	_boss_cooldown = GameStats.BOSS_SKILL_INTERVAL
	boss_skill_state = "chase"
	boss_skill_index = 0
	boss_skill_name = ""
	boss_skill_used.clear()
	boss_windup_left = 0.0
	_boss_active_left = 0.0
	boss_charge_dir = Vector2.ZERO
	# 新敌人行为状态复位（复用实例/重复 setup 都不会把旧状态带进来）
	charger_state = "approach"
	_charger_t = 0.0
	_charger_dir = Vector2.ZERO
	bomber_state = "chase"
	_bomber_t = 0.0
	_support_pulse_t = GameStats.SUPPORT_PULSE_INTERVAL
	_support_heal_t = GameStats.SUPPORT_HEAL_INTERVAL
	temp_speed_mul = 1.0
	_temp_speed_t = 0.0
	taunt_done = false
	died_exploded = false
	_monitor_line_done = false
	# Boss 半血狂暴复位（复用实例/重复 setup 不带旧状态）
	_rage_triggered = false
	_rage_flash_t = 0.0
	# 复用实例/重复 setup 的复位收尾（审查 P2）：last_hit_crit 残留 true 会让
	# 下一只复用实例的死亡误触发暴击 hit-stop；_hit_flash 残留会让新怪凭空闪白。
	last_hit_crit = false
	_hit_flash = 0.0
	# 远程怪射击计时器
	_fire_timer = GameStats.RANGED_FIRE_INTERVAL * randf_range(0.6, 1.0)
	position = pos
	is_dead = false
	_setup_visuals()
	queue_redraw()


## 接上美术精灵。有序列帧就逐帧播，没有就把静态立绘包成单帧动画
## —— 这样播放入口对 Player / Enemy 完全一致。资源缺失则回落到图元占位画法。
func _setup_visuals() -> void:
	if sprite == null:
		return
	var frames := AssetDB.enemy_idle_frames(type_name)
	var sf: SpriteFrames = null
	if not frames.is_empty():
		sf = Anim2D.build([["idle", frames, IDLE_FPS]])
	else:
		sf = Anim2D.single("idle", AssetDB.enemy_sprite(type_name))
	if sf == null:
		push_warning("Enemy: 类型 '%s' 的美术资源缺失，使用图元占位画法" % type_name)
		return
	sprite.sprite_frames = sf
	# 按实测内容包围盒定尺寸与脚底锚点（见 AssetDB 的「美术实测数据」）
	var f := AssetDB.enemy_fit(type_name, radius)
	sprite.scale = f["scale"]
	sprite.offset.y = f["offset_y"]
	sprite.play("idle")
	_use_sprite = true


func _color_for(p_type: String) -> Color:
	match p_type:
		"Medium":
			return Color("#ff9f43")
		"Rat":
			return Color("#b0b0b8")
		"Student":
			return Color("#7ec8ff")
		"Charger":
			return Color("#ff4d4d")
		"Ox":
			return Color("#8d6e63")
		"Splitter":
			return Color("#b39ddb")
		"Bomber":
			return Color("#ffb300")
		"Slacker":
			return Color("#80cbc4")
		"Monitor":
			return Color("#aed581")
		"BossPUA":
			return Color("#5d4037")
		_:
			return Color("#ff6b6b")


func _physics_process(delta: float) -> void:
	if _hit_flash > 0.0:
		_hit_flash = maxf(0.0, _hit_flash - delta * 4.0)
		if _use_sprite:
			# 精灵接上后，受击闪白走 modulate（改颜色不需要重绘）
			sprite.modulate = Color(1, 1, 1).lerp(Color(2.2, 2.2, 2.2), _hit_flash)
		else:
			queue_redraw()
	elif _rage_flash_t > 0.0:
		# Boss 狂暴红色脉冲（2026-09-20）：正弦明暗闪烁，到期恢复原色。
		# 与受击闪白共用 modulate 通道 → hit_flash 优先（狂暴期间挨打瞬间闪白）。
		_rage_flash_t = maxf(0.0, _rage_flash_t - delta)
		var pulse := 0.5 + 0.5 * sin(_rage_flash_t * 14.0)
		if _use_sprite:
			sprite.modulate = Color(1, 1, 1).lerp(Color(1.9, 0.4, 0.4), pulse)
			if _rage_flash_t <= 0.0:
				sprite.modulate = Color(1, 1, 1)
		else:
			queue_redraw()
	# 临时移速衰减（班长光环 / BossPUA 群体 PUA）：到期回 1.0
	if _temp_speed_t > 0.0:
		_temp_speed_t = maxf(0.0, _temp_speed_t - delta)
		if _temp_speed_t <= 0.0:
			temp_speed_mul = 1.0
	if target == null or is_dead:
		return
	var to_target := target.global_position - global_position
	var d := to_target.length()
	if d <= 0.001:
		return

	match behavior:
		"ranged":
			# 远程怪：保持距离区间，不贴脸
			var move_dir := Vector2.ZERO
			if d < GameStats.RANGED_KEEP_MIN:
				move_dir = -to_target / d   # 太近了 → 后退
			elif d > GameStats.RANGED_KEEP_MAX:
				move_dir = to_target / d    # 太远了 → 靠近
			# 距离合适 → 原地站立射击（不移动）
			global_position += move_dir * _cur_speed() * delta
			_fire_timer -= delta
			if _fire_timer <= 0.0 and d > 0.001:
				_fire_timer = GameStats.RANGED_FIRE_INTERVAL
				fired_enemy_proj.emit(global_position, to_target.angle(), dmg)
		"boss":
			# Boss：技能状态机（chase 追击攒冷却 → windup 前摇 → active 招式 → recover 硬直）
			_boss_brain(delta, to_target, d)
		"charger":
			# 卷王：approach → windup → dash → recover（2026-09-20）
			_charger_brain(delta, to_target, d)
		"bomber":
			# 班味炸弹：追击 → 引信 → 自爆/取消（2026-09-20）
			_bomber_brain(delta, to_target, d)
		"support":
			# 班长：保持距离游荡 + 光环脉冲（2026-09-20）
			_support_brain(delta, to_target, d)
		_:
			# 近战（含 splitter 精神内耗）：直线追击
			global_position += to_target / d * _cur_speed() * delta
	global_position = _resolve_obstacles(global_position)


## 当前实际移速 = 模板速度 × 临时加速乘区（光环/群体 PUA）。
func _cur_speed() -> float:
	return speed * temp_speed_mul


# ================================================================ Boss 技能状态机
## Boss 的行为推进。**只依赖传入的 delta** —— 绝不在 _physics_process 之外取
## Time/帧计数，这样探针可以 set_physics_process(false) 后手动调 _physics_process(dt)
## 做确定性驱动（可测性接缝，见 _ProbeRangedBoss 阶段 5）。
func _boss_brain(delta: float, to_target: Vector2, d: float) -> void:
	match boss_skill_state:
		"chase":
			# 慢速追击（与旧实现逐字一致，移速吃临时加速乘区），攒冷却
			global_position += to_target / d * _cur_speed() * delta
			_boss_cooldown -= delta
			if _boss_cooldown <= 0.0:
				_start_windup(to_target, d)
		"windup":
			# 前摇：站住不动，给玩家反应窗口
			boss_windup_left = maxf(0.0, boss_windup_left - delta)
			if _use_sprite:
				# 预警色：越接近出招越红（只用 delta 推进，保持确定性）
				var k := 1.0 - boss_windup_left / maxf(0.001, _boss_windup_total)
				sprite.modulate = Color(1, 1, 1).lerp(Color(1.7, 0.75, 0.7), 0.35 + 0.45 * k)
			queue_redraw()
			if boss_windup_left <= 0.0:
				_start_active(to_target, d)
		"active":
			_boss_active(delta)
		"recover":
			_boss_active_left = maxf(0.0, _boss_active_left - delta)
			if _use_sprite:
				sprite.modulate = Color(1, 1, 1)
			if _boss_active_left <= 0.0:
				boss_skill_state = "chase"
				boss_skill_name = ""
				_boss_cooldown = GameStats.BOSS_SKILL_INTERVAL
				queue_redraw()


## 进入前摇。charge 在这一刻锁定方向 —— 玩家还有整整一个前摇的时间躲。
func _start_windup(to_target: Vector2, d: float) -> void:
	var order: Array = GameStats.BOSS_SKILL_ORDER
	boss_skill_name = String(order[clampi(boss_skill_index, 0, order.size() - 1)])
	boss_skill_state = "windup"
	_boss_windup_total = float(GameStats.BOSS_SKILL_WINDUP.get(boss_skill_name, 0.0))
	boss_windup_left = _boss_windup_total
	if boss_skill_name == "charge":
		boss_charge_dir = to_target / maxf(d, 0.001)
	# 放招喊话（2026-09-20）：头顶冒出台词气泡（表无登记则静默）
	var line := GameStats.enemy_skill_taunt(type_name, boss_skill_name)
	if line != "":
		line_requested.emit(global_position + Vector2(0.0, -radius * 2.6), line)
	queue_redraw()


## 前摇结束 → 招式生效。
func _start_active(to_target: Vector2, d: float) -> void:
	boss_skill_state = "active"
	boss_skill_used[boss_skill_name] = int(boss_skill_used.get(boss_skill_name, 0)) + 1
	match boss_skill_name:
		"fan":
			# 一次发出 N 发，复用既有 fired_enemy_proj 接线（Battle 每发建一颗敌弹）；
			# 以「此刻朝玩家方向」为中轴、按总张角均分。
			var n := maxi(2, int(GameStats.BOSS_FAN_COUNT))
			var spread := deg_to_rad(GameStats.BOSS_FAN_SPREAD_DEG)
			var base := to_target.angle()
			for i in n:
				var ang := base - spread * 0.5 + spread * float(i) / float(n - 1)
				fired_enemy_proj.emit(global_position, ang, dmg)
			_finish_active()
		"charge":
			_boss_active_left = float(GameStats.BOSS_CHARGE_DURATION)
		"summon":
			# 召唤类型/数量可被模板覆盖（BossPUA：2 只 Rat + 全场提速光环）；
			# 未覆盖时回落全局 BOSS_SUMMON_TYPE/COUNT —— 第 20 波袋鼠王行为逐位不变。
			var t := GameStats.enemy_template(type_name)
			var st := String(t.get("summon_type", String(GameStats.BOSS_SUMMON_TYPE)))
			var sc := int(t.get("summon_count", int(GameStats.BOSS_SUMMON_COUNT)))
			summon_requested.emit(global_position, st, sc)
			if t.has("summon_aura"):
				var a: Array = t["summon_aura"]
				global_speed_aura.emit(float(a[0]), float(a[1]))
			_finish_active()
		_:
			# 未知招名：直接收招，别把状态机卡死
			_finish_active()


## active 阶段推进（只有 charge 真正占时间）。
func _boss_active(delta: float) -> void:
	match boss_skill_name:
		"charge":
			# 沿锁定方向冲锋；仍会走 _resolve_obstacles（不许穿墙）。
			global_position += boss_charge_dir * float(GameStats.BOSS_CHARGE_SPEED) * delta
			_boss_active_left = maxf(0.0, _boss_active_left - delta)
			if _boss_active_left <= 0.0:
				_finish_active()
		_:
			_finish_active()


## 收招：记次数、推进循环下标、进硬直。
func _finish_active() -> void:
	boss_skill_state = "recover"
	_boss_active_left = float(GameStats.BOSS_SKILL_RECOVER)
	boss_skill_index = (boss_skill_index + 1) % maxi(1, GameStats.BOSS_SKILL_ORDER.size())
	queue_redraw()


# ================================================================ 新敌人行为（2026-09-20）
## 卷王（charger）：approach（<250px 触发）→ windup（站 0.6s 闪红、瞬间锁定冲锋方向）
## → dash（沿锁定方向 spd×3.5 冲 0.5s）→ recover（硬直 0.8s）→ approach。
## 与 Boss 状态机同一可测性接缝：只依赖传入的 delta，探针可手动步进。
func _charger_brain(delta: float, to_target: Vector2, d: float) -> void:
	match charger_state:
		"approach":
			global_position += to_target / d * _cur_speed() * delta
			if d <= GameStats.CHARGER_TRIGGER_DIST:
				charger_state = "windup"
				_charger_t = GameStats.CHARGER_WINDUP_TIME
				# 方向在进入前摇的瞬间锁定 —— 玩家有一整个前摇的时间躲
				_charger_dir = to_target / maxf(d, 0.001)
				var line := GameStats.enemy_skill_taunt(type_name, "windup")
				if line != "":
					line_requested.emit(global_position + Vector2(0.0, -radius * 2.6), line)
		"windup":
			_charger_t = maxf(0.0, _charger_t - delta)
			if _use_sprite:
				var k := 1.0 - _charger_t / maxf(0.001, GameStats.CHARGER_WINDUP_TIME)
				sprite.modulate = Color(1, 1, 1).lerp(Color(1.8, 0.5, 0.45), k)
			queue_redraw()
			if _charger_t <= 0.0:
				charger_state = "dash"
				_charger_t = GameStats.CHARGER_DASH_TIME
				sfx_requested.emit("charger_dash", -6.0, 1.0)
		"dash":
			var step := speed * GameStats.CHARGER_DASH_SPEED_MUL * delta
			var intended: Vector2 = global_position + _charger_dir * step
			# 撞墙检测：预演一次建筑推出，比较【被推出的位移量】与本次步长（审查 P2）。
			# 旧实现用 Vector2 精确相等 —— 擦过建筑角被推出 0.001px 也判撞墙，
			# 贴角冲锋会莫名收势。阈值取步长一半：正面撞墙整步被吃掉必超阈，
			# 亚像素剐蹭不触发；阈值随 delta 缩放，帧率无关。
			var resolved := _resolve_obstacles(intended)
			global_position = resolved
			if resolved.distance_to(intended) > step * 0.5:
				charger_state = "recover"
				_charger_t = GameStats.CHARGER_RECOVER_TIME
				return
			_charger_t = maxf(0.0, _charger_t - delta)
			# 撞到玩家（接触伤害由统一接触系统结算）也立即收势
			if d <= radius + Player.RADIUS + 4.0 or _charger_t <= 0.0:
				charger_state = "recover"
				_charger_t = GameStats.CHARGER_RECOVER_TIME
		"recover":
			_charger_t = maxf(0.0, _charger_t - delta)
			if _use_sprite:
				sprite.modulate = Color(1, 1, 1)
			if _charger_t <= 0.0:
				charger_state = "approach"


## 班味炸弹（bomber）：追击 → 距玩家 80px 进引信（站住闪红 2s，与新音效时长对齐）
## → 引爆：对 90px 内玩家结算自身 dmg（走 take_hit，闪避/无敌帧照常）→ 自身死亡
## （is_dead → cleanup 正常掉金币，不分裂不掉额外东西）。引信中玩家拉开到 160px 外取消。
func _bomber_brain(delta: float, to_target: Vector2, d: float) -> void:
	match bomber_state:
		"chase":
			global_position += to_target / d * _cur_speed() * delta
			if d <= GameStats.BOMBER_FUSE_DIST:
				bomber_state = "fuse"
				_bomber_t = GameStats.BOMBER_FUSE_TIME
				sfx_requested.emit("bomber_fuse", -8.0, 1.0)
				var line := GameStats.enemy_skill_taunt(type_name, "fuse")
				if line != "":
					line_requested.emit(global_position + Vector2(0.0, -radius * 2.6), line)
		"fuse":
			_bomber_t = maxf(0.0, _bomber_t - delta)
			if d > GameStats.BOMBER_CANCEL_DIST:
				# 玩家果断拉开 → 取消自爆，回到追击
				bomber_state = "chase"
				if _use_sprite:
					sprite.modulate = Color(1, 1, 1)
				return
			if _use_sprite:
				# 倒计时闪红：4Hz 方波（只由 delta 推进，确定性）
				var on := int(_bomber_t * 8.0) % 2 == 0
				sprite.modulate = Color(1.6, 0.45, 0.4) if on else Color(1, 1, 1)
			queue_redraw()
			if _bomber_t <= 0.0:
				if target != null \
						and target.global_position.distance_to(global_position) <= GameStats.BOMBER_AOE_DIST:
					target.take_hit(dmg)   # 玩家死亡由 Player.died 信号走既有失败结算
				sfx_requested.emit("kill", -6.0, 0.7)
				died_exploded = true   # 自爆不算被击杀：压制击杀台词「……没炸成」
				is_dead = true


## 班长（support）：不追玩家，与玩家保持 250~350px 距离缓慢游荡；每 2s / 4s 发出
## 提速 / 治疗脉冲（半径过滤、目标选择、实际施加都在 Battle 侧）。
func _support_brain(delta: float, to_target: Vector2, d: float) -> void:
	var move_dir := Vector2.ZERO
	if d < GameStats.SUPPORT_WANDER_MIN:
		move_dir = -to_target / d
	elif d > GameStats.SUPPORT_WANDER_MAX:
		move_dir = to_target / d
	else:
		move_dir = to_target.orthogonal() / d * 0.4   # 距离合适 → 切向缓慢游荡
	global_position += move_dir * _cur_speed() * delta
	_support_pulse_t = maxf(0.0, _support_pulse_t - delta)
	if _support_pulse_t <= 0.0:
		_support_pulse_t = GameStats.SUPPORT_PULSE_INTERVAL
		support_pulse.emit(global_position, false)
		# 首次提速喊一句（每只一次，防 2s 一句刷屏）
		if not _monitor_line_done:
			_monitor_line_done = true
			var line := GameStats.enemy_skill_taunt(type_name, "pulse")
			if line != "":
				line_requested.emit(global_position + Vector2(0.0, -radius * 2.6), line)
	_support_heal_t = maxf(0.0, _support_heal_t - delta)
	if _support_heal_t <= 0.0:
		_support_heal_t = GameStats.SUPPORT_HEAL_INTERVAL
		support_pulse.emit(global_position, true)


## 临时移速加成（班长光环 / BossPUA 群体 PUA）。可刷新：每次施加都重置时长；
## 多来源取 max 不叠乘 —— 辅助怪堆叠不会把小怪变成光速。
func apply_temp_speed(mul: float, dur: float) -> void:
	temp_speed_mul = maxf(temp_speed_mul, mul)
	_temp_speed_t = maxf(_temp_speed_t, dur)


## 把位置推出建筑物（圆-矩形）。
## 圆心在矩形外但与矩形距离小于半径 → 沿最近点方向推到贴边；
## 圆心已经在矩形内部（例如出生点被摆进去）→ 沿最近的一条边推出去。
func _resolve_obstacles(pos: Vector2) -> Vector2:
	for r in obstacles:
		if not r.grow(radius).has_point(pos):
			continue
		var closest := Vector2(
			clampf(pos.x, r.position.x, r.end.x),
			clampf(pos.y, r.position.y, r.end.y))
		var off := pos - closest
		var dist := off.length()
		if dist > 0.0001:
			if dist < radius:
				pos = closest + off / dist * radius
		else:
			# 圆心在矩形内部
			var left := pos.x - r.position.x
			var right := r.end.x - pos.x
			var top := pos.y - r.position.y
			var bottom := r.end.y - pos.y
			var m := minf(minf(left, right), minf(top, bottom))
			if m == left:
				pos = Vector2(r.position.x - radius, pos.y)
			elif m == right:
				pos = Vector2(r.end.x + radius, pos.y)
			elif m == top:
				pos = Vector2(pos.x, r.position.y - radius)
			else:
				pos = Vector2(pos.x, r.end.y + radius)
	return pos


## 承受一次伤害。返回是否致死。传入的 dmg 一定是已算好的正整数。
func take_damage(amount: int) -> bool:
	# amount 由 GameStats.player_damage 产出，一定是 >=1 的 int。
	# 这里再兜一层：非法（<=0）输入直接忽略，绝不写入 hp，从根部杜绝 NaN 血条。
	if amount <= 0:
		return false
	hp -= amount
	_hit_flash = 1.0
	# Boss 半血狂暴（2026-09-20）：一次性触发。hp > 0 保证濒死一击不触发
	#（都死了就谈不上狂暴）；闪烁在本节点自演，战场反馈走信号交 Battle。
	if behavior == "boss" and not _rage_triggered and hp > 0 \
			and hp_ratio() <= GameStats.BOSS_RAGE_HP_RATIO:
		_rage_triggered = true
		_rage_flash_t = GameStats.BOSS_RAGE_FLASH_TIME
		rage_requested.emit(global_position)
	# 精灵态时 _draw 第一行就 return，重绘是纯浪费（对照 Player / Pickup 的守卫）
	# 有头顶血条的（精英/Boss）即使走精灵渲染也要重绘，血条才会动
	if not _use_sprite or show_health_bar:
		queue_redraw()
	if hp <= 0:
		is_dead = true
		# 精神内耗（splitter）致死 → 请求分裂（Battle 在原位生成 2 只 60% 血的 Rat；
		# Rat 本身是 melee，天然不会「分裂→再分裂」套娃）
		if behavior == "splitter":
			split_requested.emit(global_position)
		return true
	return false


func hp_ratio() -> float:
	if max_hp <= 0:
		return 0.0
	return clampf(float(hp) / float(max_hp), 0.0, 1.0)


## 只在【没接上美术精灵】时才画图元占位。
func _draw() -> void:
	# A8：精英/Boss 头顶血条。只在掉血后出现，满血时不画（减少视觉噪音）
	if show_health_bar and hp < max_hp:
		var w := radius * 2.4
		var top := -radius * 3.4 - 10.0
		var bar := Rect2(Vector2(-w * 0.5, top), Vector2(w, 5.0))
		draw_rect(bar, Color(0, 0, 0, 0.55), true)
		draw_rect(Rect2(bar.position, Vector2(w * hp_ratio(), 5.0)),
			Color(0.95, 0.26, 0.24), true)
		draw_rect(bar, Color(1, 1, 1, 0.4), false, 1.0)
	# Boss 前摇预警：让玩家「看得见要来了 / 往哪个方向」。
	# ⚠️ 必须放在 _use_sprite 提前 return 之前 —— Boss 走精灵渲染，预警画在这才显示得出来。
	if behavior == "boss" and boss_skill_state == "windup":
		_draw_boss_telegraph()
	if _use_sprite:
		return
	draw_circle(Vector2.ZERO, radius, body_color)
	draw_arc(Vector2.ZERO, radius, 0.0, TAU, 24, Color(1, 1, 1, 0.5), 1.0, true)
	if _hit_flash > 0.0:
		draw_circle(Vector2.ZERO, radius * 1.1, Color(1, 1, 1, 0.35 * _hit_flash))
	elif _rage_flash_t > 0.0:
		# 图元占位态的狂暴视觉：红色脉冲圈（精灵态走 modulate，见 _physics_process）
		var pulse := 0.5 + 0.5 * sin(_rage_flash_t * 14.0)
		draw_circle(Vector2.ZERO, radius * (1.25 + 0.15 * pulse),
			Color(0.95, 0.2, 0.2, 0.22 + 0.3 * pulse))


## Boss 前摇预警：圆形收拢弧 +（冲锋时）指向锁定方向的指示条与远端落点圈。
## 颜色/半径只由 boss_windup_left 推进（确定性），越接近出招越亮、越贴身。
func _draw_boss_telegraph() -> void:
	var w := float(GameStats.BOSS_SKILL_WINDUP.get(boss_skill_name, 1.0))
	var t := clampf(1.0 - boss_windup_left / maxf(0.001, w), 0.0, 1.0)
	var col := Color(1.0, 0.42, 0.30, 0.30 + 0.50 * t)
	# 收拢弧：半径从外圈向 Boss 收，提示「快了」
	var r := radius * (3.0 - 1.6 * t)
	draw_arc(Vector2.ZERO, r, 0.0, TAU, 40, col, 3.0, true)
	if boss_skill_name == "charge":
		# 冲锋必须画出方向：一条指向锁定方向的长条 + 远端落点圈
		var dir := boss_charge_dir
		if dir == Vector2.ZERO and target != null:
			dir = (target.global_position - global_position).normalized()
		var far := dir * (radius * 7.0
			+ float(GameStats.BOSS_CHARGE_SPEED) * float(GameStats.BOSS_CHARGE_DURATION))
		draw_line(Vector2.ZERO, far, Color(1.0, 0.32, 0.22, 0.22 + 0.45 * t), 5.0, true)
		draw_circle(far, radius * 0.9, Color(1.0, 0.32, 0.22, 0.15 + 0.35 * t))
