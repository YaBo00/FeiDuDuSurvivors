class_name WaveDirector
extends Node
## 波次调度模块：波次开始/结束、刷怪投放、出生点计算、每波观测统计。
##
## 职责边界（2026-09-19 从 Battle.gd 拆出）：
##   - 只管【什么时候、在哪里、刷多少怪】—— 不碰伤害/掉落/拾取/UI
##   - 地面主题的切换通过 `floor_changed` 信号通知 Battle（Battle 负责 _draw 自绘）
##   - 装饰性反馈（横幅/音效）通过 `wave_started` 信号通知 Battle 转交 feedback/audio
##
## 状态归属（关键）：敌人数组 enemies、波次计数 wave_num/wave_timer/spawn_remaining
## 等【共享黑板】仍住在 Battle 上 —— 5 个门禁探针直接读写这些字段（例如
## _ProbeRangedBoss 会写 battle.spawn_remaining、读 battle.enemies）。
## 本模块通过 setup() 注入的 _b 句柄操作同一份数据，语义零变化。
## 这样拆分只搬逻辑、不搬状态，探针与门禁完全不受影响。

## 波次开始：参数 (wave_num, 副标题)。Battle 转交 feedback.show_wave_banner + audio。
signal wave_started(wave_num: int, subtitle: String)
## 地面主题需要切换：参数为主题字典。Battle 负责 _apply_floor_theme。
signal floor_changed(theme: Dictionary)
## 本波投放完成一次（用于逐波观测打印）。参数为统计行字典。
signal wave_logged(row: Dictionary)

const ENEMY_SCENE := preload("res://scenes/entities/Enemy.tscn")
const OBSTACLE_SCENE := preload("res://scenes/entities/Obstacle.tscn")

var _b: Node = null

## 投放累加器：把「每秒多少只」均匀铺成整波的连续出怪。
var spawn_accum := 0.0
## 本波第一次/最后一次投放发生的「波内秒数」。
var wave_spawn_first := -1.0
var wave_spawn_last := -1.0
## 所有波次里投放跨度（last-first）的最大值 —— 用来断言「整波都在出怪」。
var spawn_spread_max := 0.0
## 本波场上存活数的峰值。
var live_max := 0
## 本波【累计投放】的怪数（含被清掉、含召唤物）。波末结算算进度分母用。
## 为什么不用 spawn_count - spawn_remaining：清场阶段 spawn_remaining 已归零，
## 但 Boss 召唤 / 分裂产生的新怪会让场上数目超过计划数 —— 那个差值不再是「已放出去的只数」。
var spawned_total := 0
## 本波是否已经做过「窗口关闭时的收尾投放」（幂等标记，防重复补投）。
var spawn_flushed := false
## 本波玩家【累计击杀】数（取本波开始时的 kills 基准做差）。
var kills_at_wave_start := 0
## 逐波观测表：{wave, planned, spawned, kills, hp, level, live_max, spread}
var wave_log: Array = []


## 注入宿主（Battle）。本模块不反向依赖 Battle 的类型，只按约定读写其字段/方法。
func setup(battle: Node) -> void:
	_b = battle


## 重开一局时复位本模块的全部观测状态。
func reset() -> void:
	spawn_accum = 0.0
	wave_spawn_first = -1.0
	wave_spawn_last = -1.0
	spawn_spread_max = 0.0
	live_max = 0
	spawned_total = 0
	kills_at_wave_start = 0
	spawn_flushed = false
	wave_log.clear()


# ================================================================ 波内阶段 / 清场进度（2026-09-21，二改同日）
# 用户需求：每波 30 秒为【生成敌人的时间】，30 秒结束后不再生成；通关条件改为
# 「倒计时结束后，清理完场上所有敌人即通过」。HUD 不再显示倒计时，改显示清场进度条。
#
# 进度分母（2026-09-21 二改）：首版「窗口未关恒 0 / 窗口后 = 击杀/(击杀+场上)」被用户
# 实测否决 —— 预期是【开始击杀进度就实时增长】，按已击杀占该波敌人总数的百分比。
# 故分母 = spawn_count(wave)（计划总数，波开始即确定；Boss 波 +1），
# 「一个都没杀 = 0%」由 0/planned 自然成立，投放期间进度也只增不减。
# 读取者（Hud）一律经 wave_clear_ratio()，不自行拼这个比值。

## 投放窗口是否已经结束（结束后本波不再生成任何敌人）。
func spawn_window_closed() -> bool:
	return _b.wave_timer <= GameStats.WAVE_DURATION - GameStats.SPAWN_WINDOW


## 本波【实际投放】的怪数（spawn_enemy 逐只累加；召唤物/分裂怪也计入 —— 它们确实是敌人）。
func spawned_count() -> int:
	return spawned_total


## 只复位「清场进度」的两个计数器，不动波次计时/主题/刷怪名额。
## 给探针与换波路径用：探针要在一个波次内反复构造进度场景，而 start_next_wave()
## 会连带重置计时器、换主题、清场，破坏被验证的现场。
func reset_clear_tracking() -> void:
	spawned_total = 0
	kills_at_wave_start = int(_b.kills)
	spawn_flushed = false


## 本波玩家击杀数（含召唤物/分裂怪）。
func killed_count() -> int:
	return maxi(0, int(_b.kills) - kills_at_wave_start)


## 本波通关进度 0..1 = 已击杀 / 本波计划敌人总数（2026-09-21 二改，用户需求）。
##
## 旧版「窗口未关恒 0」被用户实测否决：预期是【只要开始击杀，进度条就随之逐渐增长】，
## 增幅 = 已击杀占该波敌人总数的百分比。分母因此换成 spawn_count(wave) —— 该波计划
## 投放数在波开始时就是确定值（用户最初诉求「每一波的敌人数就可以确定了」），窗口期间
## 分母为常量 → 进度只增不减，天然没有旧版「窗口内分母未定型会被投放稀释/倒退」的问题，
## 当初「窗口未关恒 0」的短路也就不需要了。
##
## Boss 波分母 +1：Boss 不占 spawn_count 名额（start_next_wave 单独刷），把它算作
## 最后一份进度 —— 「清完全部 + Boss 死 = 100% = 过关」，与 Boss 波通关判定对齐。
##
## ⚠️ 分裂怪 / Boss 召唤物不占计划名额 → killed_count 可能 > planned，clampf 封顶
## 1.0；因此「条满」不再严格等价「过关」（过关仍是 _wave_cleared() 场上清空）——
## 这是「按总数百分比」语义的固有边界，探针 D3/D4 分别锁普通波与 Boss 波。
func wave_clear_ratio() -> float:
	var planned: int = GameStats.spawn_count(_b.wave_num)
	if GameStats.is_boss_wave(_b.wave_num):
		planned += 1   # Boss 占最后一份进度
	if planned <= 0:
		return 0.0
	return clampf(float(killed_count()) / float(planned), 0.0, 1.0)


## 开始下一波：推进波号、重置计时器、清场、换主题、Boss 波额外刷一只。
func start_next_wave() -> void:
	_b.wave_num += 1
	_b.wave_timer = GameStats.WAVE_DURATION
	_b.state = _b.State.FIGHTING
	_b._free_all_enemies()
	# 清掉上一波残留的敌方弹道（玩家弹道不打人，留到自然过期即可）
	var keep: Array[Projectile] = []
	for proj in _b.projectiles:
		if proj.from_player:
			keep.append(proj)
		else:
			proj.queue_free()
	_b.projectiles = keep
	# 本波要投放的总数；实际由 tick_spawn 在 SPAWN_WINDOW 内匀速放出
	_b.spawn_remaining = GameStats.spawn_count(_b.wave_num)
	spawn_accum = 0.0
	wave_spawn_first = -1.0
	wave_spawn_last = -1.0
	live_max = 0
	# 清场进度基准：本波投放计数归零、击杀基准取本波开始的累计值（做差得本波击杀）
	spawned_total = 0
	kills_at_wave_start = int(_b.kills)
	spawn_flushed = false
	_b._wave_clear_wait = 0.0
	var theme: Dictionary = GameStats.floor_theme_for_wave(_b.wave_num)
	floor_changed.emit(theme)
	# Boss 波：开波瞬间额外刷一只 Boss（不占 spawn_count 名额、不受 LIVE_CAP 约束），
	# 横幅副标题追加「BOSS 来袭」让玩家有准备
	var banner_sub := String(theme.get("name", ""))
	if GameStats.is_boss_wave(_b.wave_num):
		var boss_pos := get_spawn_pos()
		if boss_pos.distance_to(_b.player.global_position) < GameStats.SPAWN_MIN_DIST * 2.0:
			boss_pos = reserve_pos_around_player()
		# Boss 按波选型（2026-09-20 新敌人批次）：第 10 波 = BossPUA，第 20 波/无尽 = 袋鼠王 Boss
		# Boss 血量动态化（2026-09-20 需求 §2.2）：替换写死的模板 600/800 ——
		# 血量 = 同波普通怪平均模板血 × 27 × 难度 boss_hp_mul，随波次曲线自然成长。
		spawn_enemy(GameStats.boss_type_for_wave(_b.wave_num), boss_pos,
			GameStats.boss_wave_hp_mul(_b.wave_num))
		banner_sub += "  ·  BOSS 来袭"
	# 精英投放（2026-09-22 词缀系统）：波 ≥5 起每波 1 + wave/8 只，出生时随机 roll 一个词缀。
	# ⚠️ 不给 Boss 词缀 —— 走上面的分支（affix 参数缺省为空）。
	spawn_elites()
	wave_started.emit(_b.wave_num, banner_sub)
	_b.hud.set_data(_b.player, _b.wave_num, _b.wave_timer, GameStats.WAVE_COUNT)
	# 新波开波：清场进度归零（0% 起步，用户语义「一个都没杀就是 0」）。
	# start_run 里也会经这里复位 —— 重开一局不必额外清 HUD 残留。
	_b.hud.set_clear_ratio(0.0)


## 波末结算：回收掉落物、累计统计、记录观测行、决定进结算还是进升级。
func end_wave() -> void:
	# 波末回收剩余掉落物（对齐《土豆兄弟》）。
	# 为什么必须有这一步：拾取范围改小之后，玩家「打得远」的代价是掉落物落在远处
	# —— 走过去捡不到，8 秒就过期，金币和经验白白损失，等级完全跟不上敌人成长。
	# 波末统一回收解决这个矛盾：波内仍然要走到跟前才捡得起来（拾取范围依然有意义、
	# 依然值得升级），但不会永久损失。
	_b.combat.collect_all_pickups()

	_b.waves_completed += 1
	# 记录本波的投放跨度：跨度大 = 真的是整波持续出怪，而不是开局一股脑全出。
	var spread := 0.0
	if wave_spawn_first >= 0.0:
		spread = wave_spawn_last - wave_spawn_first
	spawn_spread_max = maxf(spawn_spread_max, spread)
	var row := {
		"wave": _b.wave_num,
		"planned": GameStats.spawn_count(_b.wave_num),
		# 实投 = 本波累计真正放出去的只数（含召唤物/分裂怪，逐只累加）——
		# 旧式「计划 − spawn_remaining」在清场阶段已归零、且被召唤物撑破，不再是实投数。
		"spawned": spawned_total,
		"kills": _b.kills,
		"hp": _b.player.hp,
		"level": _b.player.level,
		"live_max": live_max,
		"spread": spread,
	}
	wave_log.append(row)
	# 逐波即时打印：加速观测时引擎可能跑不满物理帧，长局会被超时切断 ——
	# 即时打印保证「即使没跑完也能读到已经走到的深度与数据」。
	if _b._testing():
		wave_logged.emit(row)
	# 收束：非无尽打满 WAVE_COUNT 即通关结算；无尽真玩时永不结算（跑到阵亡为止），
	# 只在【自检】下用 ENDLESS_SELFTEST_WAVES 收束，否则自检会跑到引擎超时。
	var target: int = GameStats.WAVE_COUNT
	if GameSession.endless:
		target = GameStats.ENDLESS_SELFTEST_WAVES if bool(_b.selftest) else 0
	if target > 0 and _b.wave_num >= target:
		_b._end_run(true)
		return
	_b._open_upgrade("wave")


## 窗口关闭那一刻的「收尾投放」。
##
## 为什么必须存在（2026-09-21 用户把 SPAWN_WINDOW 改成 30 = WAVE_DURATION 后暴露）：
## 投放是【累加器】驱动 —— 每帧累加 rate×tide×delta，攒够 1.0 才吐一只，余数留到下一帧。
## 窗口 = 整波时长时，末帧的余数永远等不到下一帧（窗口已经关了），
## 于是每波都少投最后一只（实测：计划 42 实投 41，连续 4 波都差 1）。
## 修法：窗口一关闭就把「还欠的名额」一次性补完（受 LIVE_CAP 约束），
## 保证「每波敌人数确定」这条用户诉求真的成立。
##
## ⚠️ 幂等仅靠 spawn_flushed 还不够 —— 必须额外要求「本波真的投放过东西」：
## 换波瞬间（start_next_wave 之后、第一帧 tick 之前）wave_timer 尚未被减，
## 若此时误判「窗口已关」就会把整波一次性倾倒在开局。用 spawn_remaining 与
## wave_timer 双向确认：只在「本波已经跑过一段、且确实关了窗口」时补投。
func flush_pending_spawn() -> void:
	if spawn_flushed:
		return
	# 本波还没开始（wave_timer 未被初始化过）→ 不补投
	if not spawn_window_closed():
		return
	if _b.spawn_remaining <= 0:
		spawn_flushed = true          # 名额已放完，没什么可补的，标记消费掉
		return
	spawn_flushed = true
	# 收尾补投受 LIVE_CAP 约束：撞上性能护栏时就【不补】，剩下的名额作废 ——
	# 宁可少几只也不能把同屏数顶穿护栏（护栏存在的意义就是防这一下）。
	if _b._testing():
		print("[WAVE-DBG] 波%d 窗口关闭收尾投放：剩余名额=%d 场上=%d timer=%.2f" % [
			_b.wave_num, _b.spawn_remaining, _b.enemies.size(), _b.wave_timer])
	var guard := 0
	while _b.spawn_remaining > 0 and _b.enemies.size() < GameStats.SPAWN_LIVE_CAP:
		guard += 1
		if guard > GameStats.SPAWN_COUNT_CAP:
			break      # 防御性上限：理论上不会走到，兜住任何意外死循环
		_b.spawn_remaining -= 1
		var t: float = GameStats.WAVE_DURATION - float(_b.wave_timer)
		if wave_spawn_first < 0.0:
			wave_spawn_first = t
		wave_spawn_last = t
		var types: Array = GameStats.spawn_types(int(_b.wave_num))
		spawn_enemy(types[randi() % types.size()], get_spawn_pos())
	spawn_accum = 0.0


## 波次投放：在 SPAWN_WINDOW 秒内【匀速】出怪。
## 2026-09-21：窗口 = WAVE_DURATION(30s)，所以整波都在出怪；窗口一结束就【永不再生成】
## （本函数开头直接 return）。通关条件改为「窗口结束后清理完场上所有敌人」，
## 判定在 Battle._tick_fighting（那里必须【早于】本函数运行，否则窗口末帧的怪逃过判定）。
## 用累加器把「每秒多少只」均匀铺开 —— 不会开局一股脑全出。
func tick_spawn(delta: float) -> void:
	if _b.spawn_remaining <= 0:
		return
	# 投放窗口已结束：本波不再生成任何敌人（用户需求红线）。
	# 收尾补投由 flush_pending_spawn() 负责（Battle 在窗口关闭当帧调用）。
	if spawn_window_closed():
		return
	# 场上存活到达上限：暂停投放，等玩家清掉一些再继续（性能保护）
	if _b.enemies.size() >= GameStats.SPAWN_LIVE_CAP:
		return
	# 正弦怪潮（B1 迭代）：投放速率乘以潮汐因子 —— 窗口内恰好两个整周期 ⇒ 总量精确守恒，
	# 只改变"什么时候出"（涌上来/略喘），不改变"一共出多少"（难度总量不变）。
	var elapsed_in_window: float = GameStats.WAVE_DURATION - _b.wave_timer
	spawn_accum += GameStats.spawn_rate(_b.wave_num) \
		* GameStats.spawn_tide_mul(elapsed_in_window) * delta
	while spawn_accum >= 1.0:
		if _b.spawn_remaining <= 0 or _b.enemies.size() >= GameStats.SPAWN_LIVE_CAP:
			break
		spawn_accum -= 1.0
		_b.spawn_remaining -= 1
		# 记录投放发生在波内的第几秒，用于自检断言「整波都在出怪」
		var t: float = GameStats.WAVE_DURATION - float(_b.wave_timer)
		if wave_spawn_first < 0.0:
			wave_spawn_first = t
		wave_spawn_last = t
		var types: Array = GameStats.spawn_types(int(_b.wave_num))
		spawn_enemy(types[randi() % types.size()], get_spawn_pos())


## 本波精英投放（2026-09-22 词缀系统）：数量 = GameStats.elite_count(wave)，
## 每只在出生点随机 roll 一个词缀（等权，见 GameStats.roll_elite_affix）。
##
## 为什么走 spawn_enemy 而不是"塞进 spawn_types 波池"：
##   ① 精英不占 spawn_count 名额 ⇒ 清场进度条的分母（计划投放数）不被撑破，
##      与 Boss 同口径（Boss 也是开波额外刷、不占名额）；
##   ② 精英带词缀，需要单独传 affix，波池里的普通怪路径（tick_spawn）不传。
## 出生点仍走 get_spawn_pos（可视区外），贴脸则换备用位 —— 与普通怪一致。
func spawn_elites() -> void:
	var n := GameStats.elite_count(int(_b.wave_num))
	for i in n:
		var pos := get_spawn_pos()
		if pos.distance_to(_b.player.global_position) < GameStats.SPAWN_MIN_DIST:
			pos = reserve_pos_around_player()
		spawn_enemy("Elite", pos, 1.0, true, GameStats.roll_elite_affix())
	if n > 0 and _b._testing():
		print("[%s] 波%d 投放 %d 只精英（词缀系统 2026-09-22）" % [
			_b._test_tag(), _b.wave_num, n])


## 生成一只敌人：接线开火信号、注入障碍物、避免贴脸出生，最后入列 enemies。
## hp_mul：血量额外乘区（splitter 分裂的小鼠 = 0.6，普通路径 1.0）。
## enforce_spawn_dist：出生贴脸时是否挪去玩家周围备用位 —— 分裂的小怪生在尸位旁
## 属于预期（玩家就站在旁边），传 false 豁免。
## affix：精英词缀 id（普通怪 / Boss / 召唤物 / 分裂怪一律用默认 ""）。
func spawn_enemy(type_name: String, pos: Vector2, hp_mul := 1.0, enforce_spawn_dist := true,
		affix := "") -> void:
	var e: Enemy = ENEMY_SCENE.instantiate()
	_b.world.add_child(e)
	# 敌人代价乘区（A1 双向投票的"敌人侧"）：波末取的代价累积到这里，作用于之后生成的每只怪
	e.setup(type_name, _b.wave_num, pos, _b.enemy_cost_hp_mult() * hp_mul,
		_b.enemy_cost_dmg_mult(), affix)
	e.target = _b.player
	e.obstacles = _b.obstacle_rects
	# 远程怪开火 → Battle 统一生成敌方弹道（melee 怪从不 emit，连接成本为零）
	e.fired_enemy_proj.connect(_b._on_enemy_fired)
	# Boss 召唤小弟（批次三）：Enemy 不持有 enemies 数组，统一转交 Battle
	e.summon_requested.connect(_b._on_boss_summon)
	# 新敌人批次（2026-09-20）：splitter 分裂 / 班长光环 / 新行为音效 —— 统一转交 Battle
	e.split_requested.connect(_b._on_splitter_death)
	e.support_pulse.connect(_b._on_support_pulse)
	e.global_speed_aura.connect(_b._on_global_speed_aura)
	e.sfx_requested.connect(_b._on_sfx_requested)
	# 台词气泡（放招/事件喊话；入场台词由 Battle 可视检测直接驱动，不经此信号）
	e.line_requested.connect(_b._on_enemy_line)
	# Boss 半血狂暴（2026-09-20）：闪烁由 Enemy 自演，震屏/中央大字交 Battle 转发
	e.rage_requested.connect(_b._on_boss_rage)
	# 精英词缀死亡效果（2026-09-22）：爆裂（AOE 炸玩家）/ 召唤（掉 2 只小怪）交 Battle 落地
	e.affix_death_requested.connect(_b._on_affix_death)
	if e.global_position.distance_to(_b.player.global_position) < GameStats.SPAWN_MIN_DIST \
			and enforce_spawn_dist:
		e.global_position = reserve_pos_around_player()
	_b.enemies.append(e)
	# 清场进度分母的口径来源：本波真正放出去的只数（普通投放 / Boss / 召唤 / 分裂都走这里）
	spawned_total += 1
	# 自检观测：记录本局出现过的敌人类型（自检摘要打印，覆盖接入说明 §6「每类至少一只」）
	_b.note_enemy_type(type_name)


## 出生点离玩家太近时的备用位置：玩家周围一圈随机角度。
## 要避开建筑物 —— 否则敌人会被生成在墙里，move_and_slide 出不来。
func reserve_pos_around_player() -> Vector2:
	for i in 10:
		var ang := randf() * TAU
		var p: Vector2 = _b.player.global_position \
			+ Vector2(cos(ang), sin(ang)) * GameStats.SPAWN_RESERVE_RADIUS
		if not inside_obstacle(p):
			return p
	return _b.player.global_position + Vector2(GameStats.SPAWN_RESERVE_RADIUS, 0.0)


func inside_obstacle(p: Vector2) -> bool:
	for r in _b.obstacle_rects:
		if r.has_point(p):
			return true
	return false


## 随机刷怪点：落在【实际可视区域】之外，并钳回竞技场内。
## 用实际可视区而非设计尺寸 —— 见 GameStats.spawn_pos() 与 SpawnBoundsProbe 门禁。
func get_spawn_pos() -> Vector2:
	# 地图扩到 2 倍后，可见区只占地图一角，所以落点要钳回竞技场内。
	var p: Vector2 = GameStats.spawn_pos(_b.visible_world_rect(), GameStats.SPAWN_MARGIN,
		randi() % 4, randf(), randf())
	var arena: Rect2 = GameStats.arena_rect().grow(-40.0)
	return Vector2(clampf(p.x, arena.position.x, arena.end.x),
		clampf(p.y, arena.position.y, arena.end.y))


## 随机摆放建筑物：避开竞技场边缘、避开玩家出生点周围、彼此不挤在一起。
## 摆不下就少摆几栋（不无限重试）。随机只影响观感与走位路线，不影响难度对数
## —— 敌人数量/类型完全由波次决定，与地形无关。
func spawn_obstacles() -> void:
	for o in _b.obstacles:
		o.queue_free()
	_b.obstacles.clear()
	_b.obstacle_rects.clear()
	var placed: Array[Rect2] = []
	var tries := 0
	var max_tries := GameStats.OBSTACLE_COUNT * GameStats.OBSTACLE_PLACE_TRIES
	while _b.obstacles.size() < GameStats.OBSTACLE_COUNT and tries < max_tries:
		tries += 1
		var size := Vector2(
			randf_range(GameStats.OBSTACLE_MIN_SIZE.x, GameStats.OBSTACLE_MAX_SIZE.x),
			randf_range(GameStats.OBSTACLE_MIN_SIZE.y, GameStats.OBSTACLE_MAX_SIZE.y))
		var m: float = GameStats.OBSTACLE_MARGIN
		var rect := Rect2(
			Vector2(randf_range(m, GameStats.ARENA_W - m - size.x),
				randf_range(m, GameStats.ARENA_H - m - size.y)), size)
		# 别把玩家开局就关在墙角里
		if rect.get_center().distance_to(GameStats.ARENA_CENTER) < GameStats.OBSTACLE_CLEAR_RADIUS:
			continue
		var ok := true
		for p in placed:
			if p.intersects(rect.grow(GameStats.OBSTACLE_GAP)):
				ok = false
				break
		if not ok:
			continue
		placed.append(rect)
		_b.obstacle_rects.append(rect)
		var ob: Obstacle = OBSTACLE_SCENE.instantiate()
		_b.world.add_child(ob)
		ob.setup(rect)
		_b.obstacles.append(ob)
