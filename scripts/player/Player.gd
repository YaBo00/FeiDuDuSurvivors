class_name Player
extends CharacterBody2D
## 玩家（土豆 / Potato）控制器。
##
## 职责：走位（玩家输入或自检自动驾驶）、属性重算、自动攻击（锁定最近敌人、按攻速发射）、
##       受击与无敌帧、经验/升级、金币。
##
## 【属性重算的关键设计】所有属性都由「基础值 + 加成累加器」重新计算，
##   绝不就地修改当前值。这样可以保证 recalc_stats() 幂等、反复调用不产生指数膨胀，
##   从根上避免 H5 里 aspd / maxHp 反复 recalc 被反复相乘的「双倍计算」bug。
##
## 子弹的实际生成交给 Battle（监听 fired 信号），玩家不依赖 Projectile 场景。

signal fired(aim_pos: Vector2, count: int)
signal died
signal leveled_up(new_level: int)
signal stats_changed
## 武器进化瞬间发出（2026-09-20 可达性升级）：参数 = 形态名（如「连珠·二重奏」）。
## Battle 监听它做全屏播报（大号金字 + 震屏 + 音效）—— 进化是本作核心成长节点，必须有演出感。
signal evolved(form_name: String)

## 自检模式下的自动驾驶开关（由 Battle 打开）。
var autopilot := false

## 局外永久强化加成（MetaSave 消费端第二片）。默认空字典 = 全 0 = 零行为变化。
## 由 Battle.start_run 在【非自检/非探针进程】注入（MetaSave.meta_bonus()），
## 探针可直接改写本字段做注入测试 —— 与 _bonus 分离，局外加成绝不混进局内升级。
var meta_bonus_dict: Dictionary = {}


## 虚拟摇杆方向（批次四 4b）。由 Battle 每帧注入（TouchControls.move_dir()），
## 长度 ≤ 1；未触摸时恒为零 —— 叠加进 _movement_dir() 后与纯键盘行为逐位一致。
var _touch_dir := Vector2.ZERO

## 全场磁吸剩余时间（秒）。拾取「磁铁掉落」后获得（参考 C3 掉落三件套）：
## 期间场上所有掉落物无视拾取范围飞向玩家（由 CombatResolver.process_pickups 判定）。
var magnet_all_t := 0.0

## 武器精通层数（B2 迭代·本期切片）：升级池新增「武器精通」，可重复取，
## 满 WEAPON_EVOLVE_LEVEL 层 → 武器进化（出膛伤害 ×WEAPON_EVOLVE_DMG_MUL）。
var weapon_level := 0
var weapon_evolved := false


## 武器进化后的出膛伤害乘区（未进化恒 1.0 —— 挂在 on_player_fired 的伤害公式尾）。
func weapon_damage_mul() -> float:
	return GameStats.WEAPON_EVOLVE_DMG_MUL if weapon_evolved else 1.0


## 武器第二形态定义（2026-09-20）：进化后返回形态特性表，未进化返回空字典
## —— 消费方全部用 form.get(key, 默认值) 读，空字典 = 与旧基线逐位一致。
func weapon_form() -> Dictionary:
	if not weapon_evolved:
		return {}
	return GameStats.weapon_evolution(char_id)

## 观测模式：不受任何伤害。**只用于平衡观测（`--balance`），正常游玩永远为 false。**
## 目的：让自动驾驶跑满 20 波，好把后半段的压力曲线看全 —— 否则死在第 5 波，
## 后面 15 波调了什么、有没有失控，根本无从观察。
var god_mode := false

## Battle 引用，用于查询最近敌人 / 竞技场边界。
var battle: Node = null

## 自动攻击开关。默认开启；失败路径自检会关闭它——
## 否则贴身敌人会被当场打死，接触伤害变成断续的，玩家可能苟活通关（测试 flaky）。
var attack_enabled := true

# ---------------------------------------------------------------- 基础与加成
var _base := {}      # 当前角色 GameStats.CHARACTERS[id].base 的副本
var _bonus := {      # 加成累加器（由升级/道具写入）
	"atk": 0.0, "def": 0.0, "spd": 0.0, "aspd": 0.0, "hp": 0.0,
	"hpRegen": 0.0, "dodge": 0.0, "lifesteal": 0.0, "crit": 0.0,
	"critd": 0.0, "harvest": 0.0, "luck": 0.0, "proj": 0.0, "pickupRange": 0.0, "all": 0.0,
	# 攻击距离百分比加成（参数化预留：将来「可调射程」升级/道具往这里加值）
	"attackRange": 0.0,
}

# ---------------------------------------------------------------- 派生属性（每帧使用）
var max_hp: int = 100
var hp: float = 100.0
var atk: int = 10
var defense: int = 0
var spd: float = 0.0
var aspd: float = 1.0
var proj: int = 1
var crit: float = 0.0
var critd: float = 1.5
var hp_regen: float = 0.0
var dodge: float = 0.0
var lifesteal: float = 0.0
var harvest: float = 1.0
var luck: float = 0.0
var attack_interval: float = GameStats.ATTACK_BASE_COOLDOWN
## 攻击距离（玩家中心 → 目标中心）。超出射程的敌人不会被锁定开火。
var attack_range: float = GameStats.ATTACK_RANGE_BASE
## 拾取范围（玩家中心 → 掉落物的距离）。小基准 + 可升级，见 GameStats。
var pickup_range: float = GameStats.PICKUP_RANGE_BASE

# ---------------------------------------------------------------- 进度
var level: int = GameStats.START_LEVEL
var xp: int = GameStats.START_XP
var xp_to_next: int = GameStats.START_XP_TO_NEXT
## 初始金币由角色决定（金融豪 80），见 reset()
var gold: int = 20
## 每次击杀额外金币（存钱罐）
var gold_per_kill := 0
## 商店价格折扣（投资手册；1.0 = 原价）
var shop_discount := 1.0

# ---------------------------------------------------------------- 运行时
var invincible_timer: float = 0.0
var attack_timer: float = 0.0
var facing := Vector2.RIGHT

var _autopilot_dir := Vector2.RIGHT
var _blink := 0.0

## 逐帧动画速度。[PLACEHOLDER] 未 playtest。
const IDLE_FPS := 6.0
const RUN_FPS := 12.0

@onready var sprite: AnimatedSprite2D = $Sprite

## 是否成功用上了美术精灵。失败则回落到 _draw() 里的图元占位画法。
var _use_sprite := false
var _current_anim := ""

const RADIUS := GameStats.PLAYER_RADIUS
const BODY_COLOR := Color("#ff7a45")
const CORE_COLOR := Color("#ffe8d6")
const FACING_COLOR := Color("#2b1a12")


func _ready() -> void:
	apply_character(GameSession.selected_char)
	_setup_visuals()
	queue_redraw()


## 接上美术精灵：待机 / 跑动两组序列帧。
## 资源缺失时不报错，只是回落到图元占位画法 —— 保证「没美术也能跑」。
var char_id: String = GameStats.DEFAULT_CHAR
## 升级所需经验的倍率（角色天赋，学习豪 0.77 = 升级更快）。
var _xp_mul := 1.0

# ---- 角色特性（见 GameStats.CHARACTERS[].trait_id 与 docs/design/人物设计_嘉豪四人组）----
## 当前角色特性 id（beginner_save / levelup_aspd / money_rush / low_hp_fury）。
var trait_id: String = ""
## 角色特性总开关。**`--selftest-defeat` 会置 false** —— 初心的免死会吞掉
## 那个模式赖以断言的「确定性致死」，两者天生冲突（见设计文档差异裁决 D4）。
var traits_enabled := true
## 当前角色的武器定义缓存（GameStats.weapon_for_char 的结果，随 apply_character 刷新）。
var _weapon: Dictionary = {}
## 「新手保护·初心」本局是否已用掉（每局一次，reset() 清零）。
var _beginner_save_used := false
## 「见钱眼开」当前加速层数 / 剩余时长（运行时 buff，**绝不写进 _bonus**）。
var _money_stacks := 0
var _money_t := 0.0

# ---- 越挫越勇（potato / armor_stack，T-CHAR-02）：与 _money_stacks 同构的运行时叠层 ----
## 当前护甲层数（每层 +TRAIT_ARMOR_STEP 点有效护甲）。
var _armor_stacks := 0
## 距下次清零的倒计时（不受击时递减；暂停期不消耗）。
var _armor_t := 0.0

# ---- 停不下来（kangaroo / move_stacks）：移动时长叠层，停下清零 ----
## 当前层数（每层 +2% 移速 +3% 攻速，运行时乘区）。
var _kanga_stacks := 0
## 持续移动累计计时（满 TRAIT_KANGA_STACK_TIME 叠 1 层并扣回）。
var _kanga_move_t := 0.0
## 停止移动累计计时（满 TRAIT_KANGA_STOP_CLEAR 清零层数）。
var _kanga_stop_t := 0.0


## 应用角色：基础属性 + 天赋带来的附加字段（初始金币 / 经验倍率 / 特性 / 武器表）。
## 由 Battle 在开局时调用；reset() 里也会再调一次，保证换角色后重启也生效。
func apply_character(id: String) -> void:
	char_id = id if GameStats.CHARACTERS.has(id) else GameStats.DEFAULT_CHAR
	var c := GameStats.character(char_id)
	_base = (c["base"] as Dictionary).duplicate()
	_xp_mul = float(c["xp_mul"])
	trait_id = GameStats.trait_id_for_char(char_id)
	_weapon = GameStats.weapon_for_char(char_id)
	# 见钱眼开：商店永久 9 折（与「投资手册 0.82」乘法叠加 → 0.738）。其余角色 1.0。
	shop_discount = GameStats.TRAIT_SHOP_DISCOUNT_FINANCE \
		if trait_id == "money_rush" else 1.0
	recalc_stats()
	hp = float(max_hp)
	queue_redraw()


## 接上美术精灵：待机 / 跑动两组序列帧。
## 资源缺失时不报错，只是回落到图元占位画法 —— 保证「没美术也能跑」。
func _setup_visuals() -> void:
	if sprite == null:
		return
	var idle_frames := AssetDB.char_frames(char_id, "idle")
	var run_frames := AssetDB.char_frames(char_id, "run")
	var sf := Anim2D.build([
		["idle", idle_frames, IDLE_FPS],
		["run", run_frames, RUN_FPS],
	])
	if sf == null:
		push_warning("Player: 角色 '%s' 的动画帧缺失，使用图元占位画法" % char_id)
		_use_sprite = false
		return

	sprite.sprite_frames = sf
	# 按实测内容包围盒定尺寸与脚底锚点（见 AssetDB 的「美术实测数据」）
	var f := AssetDB.char_fit(char_id, RADIUS)
	sprite.scale = f["scale"]
	sprite.offset.y = f["offset_y"]
	sprite.play("idle")
	_current_anim = "idle"
	_use_sprite = true


## 重开一局：按当前角色重设基础属性，清空加成、恢复初始进度与满血，并移动到指定位置。
func reset(pos: Vector2) -> void:
	apply_character(GameSession.selected_char)
	_setup_visuals()
	for k in _bonus.keys():
		_bonus[k] = 0.0
	# 特性状态每局清零：初心重新可用、见钱眼开加速清空
	_beginner_save_used = false
	_money_stacks = 0
	_money_t = 0.0
	# 新角色特性运行时状态清零（T-CHAR-02）
	_armor_stacks = 0
	_armor_t = 0.0
	_kanga_stacks = 0
	_kanga_move_t = 0.0
	_kanga_stop_t = 0.0
	# 全场磁吸计时清零（磁铁掉落，参考 C3 掉落三件套）
	magnet_all_t = 0.0
	# 武器进化状态清零（B2 迭代：weapon_mastery 层数与进化标记每局重置）
	weapon_level = 0
	weapon_evolved = false
	level = GameStats.START_LEVEL
	xp = GameStats.START_XP
	xp_to_next = roundi(GameStats.START_XP_TO_NEXT * _xp_mul)
	gold = int(GameStats.character(char_id)["start_gold"])
	invincible_timer = 0.0
	attack_timer = 0.0
	recalc_stats()
	hp = float(max_hp)
	global_position = pos
	velocity = Vector2.ZERO
	queue_redraw()


## ------------------------------------------------------------------ 属性重算
## 由「基础值 + 加成」重新计算全部派生属性。幂等。
func recalc_stats() -> void:
	var all: float = _bonus["all"]   # 「全属性+X%」乘区（土豆芯片）
	# 局外永久强化（MetaSave 消费端）。get 全带默认值 0 —— 字段缺失/空字典都安全。
	var m_atk: float = float(meta_bonus_dict.get("atk_mul", 0.0))
	var m_hp: float = float(meta_bonus_dict.get("hp_flat", 0.0))
	var m_pick: float = float(meta_bonus_dict.get("pickup_mul", 0.0))
	atk = roundi(float(_base["atk"]) * (1.0 + all) + _bonus["atk"])
	if m_atk > 0.0:
		atk = roundi(float(atk) * (1.0 + m_atk))
	defense = roundi(float(_base["def"]) * (1.0 + all) + _bonus["def"])
	spd = roundi(float(_base["spd"]) * GameStats.SPATIAL_SCALE * (1.0 + _bonus["spd"]) * (1.0 + all))
	aspd = clampf(float(_base["aspd"]) * (1.0 + _bonus["aspd"]) * (1.0 + all), 0.05, GameStats.MAX_ASPD)
	proj = mini(GameStats.MAX_PROJ, int(_base["proj"]) + int(_bonus["proj"]))
	crit = minf(GameStats.MAX_CRIT, float(_base["crit"]) + _bonus["crit"])
	critd = float(_base["critd"]) + _bonus["critd"]
	max_hp = roundi(float(_base["maxHp"]) * (1.0 + all) + _bonus["hp"])
	if m_hp > 0.0:
		max_hp += int(m_hp)
	hp_regen = float(_base["hpRegen"]) + _bonus["hpRegen"]
	dodge = minf(GameStats.MAX_DODGE, float(_base["dodge"]) + _bonus["dodge"])
	lifesteal = minf(GameStats.MAX_LIFESTEAL, float(_base["lifesteal"]) + _bonus["lifesteal"])
	harvest = float(_base["harvest"]) + _bonus["harvest"]
	luck = float(_base["luck"]) + _bonus["luck"]
	# 拾取范围：从固定大值改成了「小基准 + 可成长」，见 GameStats 的「掉落 / 拾取」
	pickup_range = maxf(8.0, float(_base["pickupRange"]) + _bonus["pickupRange"])
	if m_pick > 0.0:
		pickup_range = maxf(8.0, pickup_range * (1.0 + m_pick))
	# 攻击间隔 = BASE / aspd / 武器 rate_mul，夹在 [ATTACK_INTERVAL_MIN, 999]。
	# 下限护栏防止 aspd + 题海精进 + 粉笔连射三者叠加把间隔打到接近 0（见设计文档 D2）。
	# 第二形态 rate_add（残影连拳等）：加在 rate_mul 上；未进化 form 为空 → 逐位不变。
	var form: Dictionary = weapon_form()
	var rate_mul: float = (float(_weapon.get("rate_mul", 1.0)) if not _weapon.is_empty() else 1.0) \
		+ float(form.get("rate_add", 0.0))
	attack_interval = clampf(GameStats.ATTACK_BASE_COOLDOWN / aspd / rate_mul,
		GameStats.ATTACK_INTERVAL_MIN, 999.0)
	# 攻击距离：基础值 ×（1 + 百分比加成），下限 80 防止被负加成废掉
	attack_range = maxf(80.0, GameStats.ATTACK_RANGE_BASE * (1.0 + _bonus["attackRange"]))
	if hp > float(max_hp):
		hp = float(max_hp)
	stats_changed.emit()


## 应用一次升级（id 来自 GameStats.UPGRADE_POOL）。
func apply_upgrade(id: String, value: float) -> void:
	match id:
		"atk", "def", "hp", "hpRegen", "pickupRange":
			_bonus[id] += value
		"spd", "aspd", "dodge", "lifesteal", "crit", "harvest":
			_bonus[id] += value
		"proj":
			_bonus["proj"] += 1.0
		"weapon_mastery":
			# 武器进化·本期切片（B2 迭代）：武器精通不走 _bonus（它是层数计数不是属性加成），
			# 满 WEAPON_EVOLVE_LEVEL 层 → evolved ⇒ 出膛伤害 × WEAPON_EVOLVE_DMG_MUL，
			# 并解锁第二形态（WEAPON_EVOLUTIONS 形态特性，2026-09-20）。
			weapon_level += 1
			if weapon_level >= GameStats.WEAPON_EVOLVE_LEVEL and not weapon_evolved:
				weapon_evolved = true
				recalc_stats()   # 形态特性可能带 rate_add（攻速倍率）→ 立刻刷新攻击间隔
				# 进化播报（2026-09-20）：Battle 监听后做全屏演出
				evolved.emit(String(GameStats.weapon_evolution(char_id).get("name", "")))
				return
		_:
			push_warning("未知升级 id：%s" % id)
			return
	recalc_stats()


## ------------------------------------------------------------------ 受击 / 无敌帧
## 返回 {result: "dodge"/"iframe"/"hit"/"dead", dmg: int}。
func take_hit(raw_dmg: int) -> Dictionary:
	# 观测模式：不掉血，但仍走无敌帧与闪烁，保持行为一致
	if god_mode:
		invincible_timer = GameStats.IFRAME_DURATION
		return {"result": "iframe", "dmg": 0}
	if dodge > 0.0 and randf() < dodge:
		return {"result": "dodge", "dmg": 0}
	if invincible_timer > 0.0:
		return {"result": "iframe", "dmg": 0}
	# 【越挫越勇】有效护甲 = 基础 + 当前层数 × 步进（仅 potato；用【结算前】已有的层数
	# —— 本击不享受即将叠上的新层，防连续受击滚雪球，见设计文档 §3.2 第 3 条）。
	var eff_def := defense
	if traits_enabled and trait_id == "armor_stack":
		eff_def = defense + int(float(_armor_stacks) * GameStats.TRAIT_ARMOR_STEP)
	var d := GameStats.incoming_damage(raw_dmg, eff_def)
	hp -= float(d)
	invincible_timer = GameStats.IFRAME_DURATION
	stats_changed.emit()
	# 【越挫越勇】真实扣血（"hit" / "dead"）才叠层 —— 闪避 / 无敌帧 / 观测模式命中不算受击。
	# 层在扣血结算【之后】叠，本击已按旧层计算（见上）。被初心类机制救回时层数保留（挨打就长壳）。
	if traits_enabled and trait_id == "armor_stack":
		_armor_stacks = mini(GameStats.TRAIT_ARMOR_MAX, _armor_stacks + 1)
		_armor_t = GameStats.TRAIT_ARMOR_DECAY_TIME
	if hp <= 0.0:
		# 【新手保护·初心】每局第一次致死：免死，回 1 血 + 独立长无敌，按普通受击返回。
		# 位置刻意在闪避 / 无敌帧 / god_mode 判定【之后】—— 只覆盖「伤害致死」这一种死因。
		# traits_enabled 关掉时（--selftest-defeat）不生效，见设计文档差异裁决 D4。
		if traits_enabled and not _beginner_save_used and trait_id == "beginner_save":
			_beginner_save_used = true
			hp = 1.0
			invincible_timer = GameStats.TRAIT_SAVE_IFRAME
			stats_changed.emit()
			return {"result": "hit", "dmg": d, "trait": "beginner_save"}
		hp = 0.0
		died.emit()
		return {"result": "dead", "dmg": d}
	return {"result": "hit", "dmg": d}


## 出膛伤害乘区（仅忧郁豪「背水一战」非 1.0；其余角色恒返 1.0）。
## 乘在 `atk × dmg_mul × PROJ_DMG_BOOST` 之后、暴击判定之前（见设计文档 §0.3）。
## 出膛时实时结算 —— 弹道飞行途中掉血不追溯已发出的那一发。
func damage_bonus() -> float:
	if not traits_enabled or trait_id != "low_hp_fury":
		return 1.0
	var ratio := hp / maxf(1.0, float(max_hp))
	if ratio < GameStats.TRAIT_FURY_T2_HP:
		# 二档：一档 + 二档相加 = +40%
		return 1.0 + GameStats.TRAIT_FURY_T1_BONUS + GameStats.TRAIT_FURY_T2_BONUS
	if ratio < GameStats.TRAIT_FURY_T1_HP:
		return 1.0 + GameStats.TRAIT_FURY_T1_BONUS
	return 1.0


## 见钱眼开：当前移速乘区（仅金融豪可能 ≠ 1.0）。
## 刻意做成**运行时乘区**而不是写进 _bonus —— _bonus 是幂等 recalc 的输入，
## 塞进临时 buff 会让 recalc 反复叠加（幂等纪律）。
func money_speed_mul() -> float:
	if not traits_enabled or trait_id != "money_rush" or _money_stacks <= 0:
		return 1.0
	return 1.0 + GameStats.TRAIT_MONEY_BOOST_STEP * float(_money_stacks)


## 停不下来：当前移速乘区（仅袋鼠怪可能 ≠ 1.0）。与 money_speed_mul 同构的运行时乘区。
func kanga_speed_mul() -> float:
	if not traits_enabled or trait_id != "move_stacks" or _kanga_stacks <= 0:
		return 1.0
	return 1.0 + GameStats.TRAIT_KANGA_SPD_STEP * float(_kanga_stacks)


## 停不下来：当前攻速乘区（仅袋鼠怪可能 ≠ 1.0）。
## 作用在 attack_timer 上而非 recalc 的 aspd —— 不碰幂等 recalc，
## 极端叠加也不会突破 ATTACK_INTERVAL_MIN 护栏（间隔已 clamp，见设计文档 §5）。
func kanga_aspd_mul() -> float:
	if not traits_enabled or trait_id != "move_stacks" or _kanga_stacks <= 0:
		return 1.0
	return 1.0 + GameStats.TRAIT_KANGA_ASPD_STEP * float(_kanga_stacks)


## 停不下来：按输入方向（_movement_dir 非零）判定移动中/静止，更新叠层。
## 移动中：停止计时清零、移动计时累加，每满 TRAIT_KANGA_STACK_TIME 叠 1 层并扣回；
## 静止中：移动计时清零、停止计时累加，满 TRAIT_KANGA_STOP_CLEAR 清零层数。
## traits_enabled=false（--selftest-defeat）或非袋鼠怪时完全不跑。
func _tick_move_stacks(delta: float, dir: Vector2) -> void:
	if not traits_enabled or trait_id != "move_stacks":
		return
	if dir.length_squared() > 0.0:
		_kanga_stop_t = 0.0
		_kanga_move_t += delta
		if _kanga_move_t >= GameStats.TRAIT_KANGA_STACK_TIME:
			_kanga_move_t -= GameStats.TRAIT_KANGA_STACK_TIME
			_kanga_stacks = mini(GameStats.TRAIT_KANGA_MAX, _kanga_stacks + 1)
	else:
		_kanga_move_t = 0.0
		_kanga_stop_t += delta
		if _kanga_stop_t >= GameStats.TRAIT_KANGA_STOP_CLEAR:
			_kanga_stacks = 0
			_kanga_stop_t = 0.0


func is_alive() -> bool:
	return hp > 0.0


## ------------------------------------------------------------------ 经验 / 金币
## 返回本次获得的等级数（可能 >1 连升）。
## 应用一件商店物品的效果（含特殊键：立刻金币 / 击杀加钱 / 商店折扣 / 经验倍率）。
func apply_item(item_id: String) -> void:
	if not GameStats.ITEM_DEFS.has(item_id):
		push_warning("未知物品：%s" % item_id)
		return
	var d: Dictionary = GameStats.ITEM_DEFS[item_id]
	var eff: Dictionary = d["effect"]
	for k in eff.keys():
		var key := String(k)
		var v := float(eff[k])
		match key:
			"gold":
				add_gold(int(v))
			"gold_per_kill":
				gold_per_kill += int(v)
			"shop_discount":
				shop_discount *= v
			"xp_mul":
				_xp_mul *= v
			"proj":
				_bonus["proj"] += v
			"weapon_mastery":
				# 商店「武器精通手册」（2026-09-20 可达性升级）：与升级卡同一入口，
				# 层数累计 / 第 6 层进化判定 / 进化播报全在 apply_upgrade 里，不重复实现。
				apply_upgrade("weapon_mastery", v)
			_:
				_bonus[key] += v
	recalc_stats()
	stats_changed.emit()


## 回血（吸血等来源调用）。封装在 Player 里，将来加「受击回血」「治疗上限」只改这里。
func heal(amount: float) -> void:
	if amount <= 0.0 or not is_alive():
		return
	hp = minf(float(max_hp), hp + amount)
	stats_changed.emit()


func gain_xp(amount: int) -> int:
	if amount <= 0:
		return 0
	xp += amount
	var gained := 0
	while xp >= xp_to_next:
		xp -= xp_to_next
		level += 1
		xp_to_next = roundi(float(xp_to_next) * GameStats.XP_GROWTH)
		gained += 1
		# 【题海精进】每升一级永久 +3% 攻速。加法区，可无限叠加，由 MAX_ASPD 兜底。
		# 连升多次就多次 recalc —— 幂等，量级可忽略（设计文档 §2.2）。
		if traits_enabled and trait_id == "levelup_aspd":
			_bonus["aspd"] += GameStats.TRAIT_ASPD_PER_LEVEL
			recalc_stats()
		leveled_up.emit(level)
	stats_changed.emit()
	return gained


func add_gold(amount: int) -> void:
	if amount <= 0:
		return
	gold += amount
	# 【见钱眼开】每次进账 +1 层（封顶 3 层），并刷新持续时长。
	# 捡第 4 枚只刷新时长、不再加层。波末自动回收是逐枚 _collect → 逐枚触发，
	# 语义对齐「每拾取一枚」；商店「钱袋」一次性 +40 只算 1 次（可接受的噪声）。
	if traits_enabled and trait_id == "money_rush":
		_money_stacks = mini(GameStats.TRAIT_MONEY_BOOST_MAX, _money_stacks + 1)
		_money_t = GameStats.TRAIT_MONEY_BOOST_TIME
	stats_changed.emit()


## ------------------------------------------------------------------ 主循环
func _physics_process(delta: float) -> void:
	if invincible_timer > 0.0:
		invincible_timer = maxf(0.0, invincible_timer - delta)
		_blink += delta
	if hp_regen > 0.0 and hp < float(max_hp):
		hp = minf(float(max_hp), hp + hp_regen * delta)
	# 【见钱眼开】加速衰减：到期清零层数（树暂停时不跑，暂停期不消耗）
	if _money_t > 0.0:
		_money_t = maxf(0.0, _money_t - delta)
		if _money_t <= 0.0:
			_money_stacks = 0
	# 【越挫越勇】护甲层倒计时：不受击满 3 秒清零（与 _money_t 衰减同构）
	if _armor_t > 0.0:
		_armor_t = maxf(0.0, _armor_t - delta)
		if _armor_t <= 0.0:
			_armor_stacks = 0
	# 全场磁吸倒计时（磁铁掉落）：归零后掉落物回到拾取范围驱动的普通磁吸
	if magnet_all_t > 0.0:
		magnet_all_t = maxf(0.0, magnet_all_t - delta)

	var dir := _movement_dir()
	if dir.length_squared() > 0.0:
		facing = dir.normalized()
	# 【停不下来】按输入方向判定移动/静止并更新叠层（贴墙也算移动，见设计文档 §5）
	_tick_move_stacks(delta, dir)
	# 加速度：朝目标速度指数趋近（帧率无关）。松手减速更快，跟手但不生硬。
	# money_speed_mul() / kanga_speed_mul() 是运行时乘区（见钱眼开 / 停不下来），
	# 对非对应角色恒为 1.0。
	var target := dir * spd * money_speed_mul() * kanga_speed_mul()
	var rate := GameStats.PLAYER_ACCEL if dir.length_squared() > 0.0 else GameStats.PLAYER_DECEL
	velocity = velocity.lerp(target, 1.0 - exp(-rate * delta))
	move_and_slide()
	_clamp_to_arena()
	_update_visual_state(dir)

	if is_alive():
		_handle_attack(delta)
	if not _use_sprite:
		queue_redraw()


## 有位移就播跑动，否则播待机。
func _update_visual_state(dir: Vector2) -> void:
	if not _use_sprite:
		return
	var want := "run" if dir.length_squared() > 0.0 else "idle"
	if want != _current_anim:
		_current_anim = want
		sprite.play(want)
	# 受击无敌帧闪烁（H5 用 globalAlpha 0.5 交替）
	var a := 1.0
	if invincible_timer > 0.0 and int(invincible_timer * 10.0) % 2 == 0:
		a = 0.5
	sprite.modulate.a = a


func _movement_dir() -> Vector2:
	if autopilot and battle != null:
		_autopilot_dir = _compute_autopilot_dir()
		return _autopilot_dir
	# 触摸与键盘并存（批次四 4b）：先取键盘向量（Input.get_vector 自带死区与归一，
	# 长度恒 ≤ 1），再叠加摇杆方向；合成超过 1 才归一 —— _touch_dir 为零时
	# 走到这里与旧实现逐位一致（键盘回归红线）。
	var dir := Input.get_vector("move_left", "move_right", "move_up", "move_down") + _touch_dir
	if dir.length() > 1.0:
		dir = dir.normalized()
	return dir


## 注入虚拟摇杆方向（由 Battle 每帧调用；键盘路径不经过此函数）。
func set_touch_dir(v: Vector2) -> void:
	_touch_dir = v


## 自检自动驾驶：远离最近敌人 + 顺路捡掉落物 + 太偏了回拉中心。
##
## 为什么要「顺路捡东西」：拾取范围改成小值之后，只顾逃跑的话掉落物几乎收不到，
## 玩家等级跟不上敌人成长 —— 自检就会测出一条失真的难度曲线（假难）。
## 真人玩家是边躲边捡的，自动驾驶必须做同样的事，测出来的数据才有意义。
const LOOT_SEEK_DIST := 250.0   # 最近敌人距此以外，才敢绕路捡东西
const LOOT_PULL_DIST := 170.0   # 掉落物距此以内才值得绕路
const LOOT_WEIGHT := 0.45       # 捡东西只做「偏航」，主方向仍然是躲避
const AVOID_OBSTACLE_DIST := 150.0   # 距建筑物小于此距离就开始绕开

func _compute_autopilot_dir() -> Vector2:
	var enemy: Node2D = battle.get_nearest_enemy(global_position)
	var flee := Vector2.ZERO
	var enemy_dist := INF
	if enemy != null:
		enemy_dist = global_position.distance_to(enemy.global_position)
		flee = (global_position - enemy.global_position).normalized()

	var dir := flee

	# 危险不大时，朝最近的掉落物偏一点
	if enemy_dist > LOOT_SEEK_DIST:
		var loot: Node2D = battle.get_nearest_pickup(global_position)
		if loot != null and global_position.distance_to(loot.global_position) < LOOT_PULL_DIST:
			var to_loot := (loot.global_position - global_position).normalized()
			dir = (dir * (1.0 - LOOT_WEIGHT) + to_loot * LOOT_WEIGHT).normalized()

	var to_center := GameStats.ARENA_CENTER - global_position
	if to_center.length() > 360.0:
		dir = (dir + to_center.normalized() * 1.4).normalized()

	# 避障：远离附近的建筑物。
	# 没有这一步，自动驾驶会被堵在墙角反复挨打 —— 观测到的存活波次会变成
	# 「有多少概率被卡住」的随机数，而不是难度本身（实测 4~9 波，方差太大）。
	# 注意：battle 声明为 Node，取 .obstacles 得到的是 Variant ——
	# 必须先落到显式类型的局部变量，否则 "从 Variant 推断类型" 会直接报 Parse Error。
	for o in battle.obstacles:
		var opos: Vector2 = o.global_position
		var d: float = global_position.distance_to(opos)
		if d < AVOID_OBSTACLE_DIST and d > 0.001:
			var away: Vector2 = (global_position - opos).normalized()
			dir = (dir + away * (1.0 - d / AVOID_OBSTACLE_DIST) * 1.8).normalized()

	if dir.length_squared() < 0.0001:
		dir = Vector2.RIGHT
	return dir


func _clamp_to_arena() -> void:
	global_position.x = clampf(global_position.x, RADIUS, GameStats.ARENA_W - RADIUS)
	global_position.y = clampf(global_position.y, RADIUS, GameStats.ARENA_H - RADIUS)


func _handle_attack(delta: float) -> void:
	if not attack_enabled:
		return
	if attack_timer > 0.0:
		attack_timer -= delta
	if attack_timer > 0.0:
		return
	if battle == null or not battle.is_fighting():
		return
	var enemy: Node2D = battle.get_nearest_enemy(global_position)
	if enemy == null:
		return
	# 攻击距离门：目标在射程内才开火；射程外不开火、也不消耗攻击冷却
	# —— 否则怪一进射程会立刻白吃一发热枪。下一帧会重新索敌。
	if global_position.distance_to(enemy.global_position) > attack_range:
		return
	attack_timer = attack_interval / kanga_aspd_mul()   # 【停不下来】攻速乘区（运行时，非 recalc）
	fired.emit(enemy.global_position, proj)


## ------------------------------------------------------------------ 绘制
## 只在【没接上美术精灵】时才画图元占位；正常情况下精灵由 $Sprite 负责渲染。
func _draw() -> void:
	if _use_sprite:
		return
	# 受击无敌帧：闪烁提示（H5 用 globalAlpha=0.5 交替）。
	var alpha := 1.0
	if invincible_timer > 0.0 and int(invincible_timer * 10.0) % 2 == 0:
		alpha = 0.5
	draw_circle(Vector2.ZERO, RADIUS, Color(BODY_COLOR, alpha))
	draw_circle(Vector2.ZERO, RADIUS * 0.45, Color(CORE_COLOR, alpha))
	draw_line(Vector2.ZERO, facing * RADIUS * 1.7, Color(FACING_COLOR, alpha), 6.0)
	draw_arc(Vector2.ZERO, RADIUS + 3.0, 0.0, TAU, 32, Color(1, 0.84, 0, alpha), 2.0, true)
