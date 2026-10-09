extends SceneTree
## 独立验证探针：多地图系统（2026-10-09 第二梯队第八批·收尾）。
##
## 「纯视觉地面主题」升级为「地图 = 视觉 + 布局 + 环境机制」三合一的验证：
##   · 布局：5 图各自的障碍物规格（参数化 random / 固定四角柱）
##   · 机制：车间疾走（玩家移速 +10%）/ 回音定位（拾取 +35%）/
##     钢梁重压（敌人移速 -10%）/ 遍地鎏金（金币 +25%）
##   · 重建：换图（每 4 波）时重建障碍 —— 同图不重建、波 1 不重复生成
##
## 回答六个验收问题：
##   A 数据面契约：5 图字段齐全 / 布局规格合法 / 机制名与描述一致性
##   B 守卫 + 图映射：探针进程 map_enabled 默认 false（行为级验证）/ 关闭态回退默认参数 /
##     波 1-20 图映射 / 无尽循环复用
##   C 布局生成：各图障碍数量与尺寸范围 / corners 固定坐标 / 避玩家跳过
##   D 换图重建：start_run 首建登记 / 波 5 自动重建 / 同图不重建 / 波 9 四柱 /
##     新区域中央通知
##   E 机制乘区：gold / pickup / speed 端到端对照 + espd 模板级 + 快照写入链路
##   F 纪律：空字典与键缺失恒 1.0 / 波 1 零拼接 / 复位
##
## 被验证的契约：
##   GameStats.FLOOR_THEMES（layout/effect/effect_name/effect_desc 字段）/
##   map_enabled / MAP_DEFAULT_LAYOUT / MAP_CORNER_OFFSET /
##   map_layout_for_wave / map_effect_name_for_wave / map_effect_desc_for_wave / map_enemy_mul
##   WaveDirector.spawn_obstacles / _spawn_corner_obstacles / _obstacle_map_id /
##   start_next_wave（换图重建 + 新区域通知）
##   Battle._apply_floor_theme（快照写入）/ _build_overview_data（region 行）
##   Player.map_effects / map_mul（speed/pickup/gold 三消费点）
##   Enemy.setup（espd 模板级乘区）
##
## 确定性：全部同步调用；速度端到端用「触摸方向 + 手动步进」不依赖真实帧；
## 探针自己恢复 map_enabled / map_effects / 玩家位置。
##
## 用法: godot --headless --path <项目>/game --script res://scripts/dev/_ProbeMaps.gd
## 退出码 0=PASS 1=FAIL（门禁用 grep -q "RESULT=PASS" 判定）

const DT := 1.0 / 60.0

var battle: Node = null
var armed := false
var finished := false
var checks := 0
var fails: Array[String] = []


func _initialize() -> void:
	print("[PROBE] === 多地图（布局 + 环境机制）验证 ===")
	var packed: PackedScene = load("res://scenes/battle/Battle.tscn")
	if packed == null:
		_finish("Battle.tscn 加载失败")
		return
	battle = packed.instantiate()
	root.add_child(battle)


func _process(_delta: float) -> bool:
	if finished:
		return true
	if not armed:
		_arm()
		_finish("")
		return true
	return true


func _arm() -> void:
	armed = true
	_sec_a_contracts()
	_sec_b_guard_and_mapping()
	_sec_c_layouts()
	_sec_d_rebuild()
	_sec_e_effects()
	_sec_f_discipline()


# ================================================================ A. 数据面契约
func _sec_a_contracts() -> void:
	_section("A. 数据面契约（5 图字段 / 布局规格 / 机制一致性）")
	_check(GameStats.FLOOR_THEMES.size() == 5,
		"FLOOR_THEMES 5 张图（实际 %d）" % GameStats.FLOOR_THEMES.size())
	# 字段齐全：layout / effect / effect_name / effect_desc
	var missing := ""
	for t in GameStats.FLOOR_THEMES:
		for k in ["layout", "effect", "effect_name", "effect_desc"]:
			if not t.has(k):
				missing += "%s.%s " % [String(t.get("id", "?")), k]
	_check(missing == "", "5 图字段齐全（缺失：%s）" % ("无" if missing == "" else missing))
	# effect 键合法性 + 一致性（有机制 ⇔ 有名有名有述）
	var bad_key := ""
	var inconsistent := ""
	for t in GameStats.FLOOR_THEMES:
		var eff: Dictionary = t["effect"]
		for k in eff:
			if not ["speed", "pickup", "gold", "espd"].has(String(k)):
				bad_key += "%s.%s " % [String(t["id"]), String(k)]
		var has_eff: bool = not eff.is_empty()
		var has_nm: bool = String(t["effect_name"]) != ""
		var has_ds: bool = String(t["effect_desc"]) != ""
		if has_eff != has_nm or has_eff != has_ds:
			inconsistent += "%s " % String(t["id"])
	_check(bad_key == "", "effect 键全部合法 ∈ {speed,pickup,gold,espd}（违规：%s）"
		% ("无" if bad_key == "" else bad_key))
	_check(inconsistent == "", "机制名/描述与 effect 一致性（异常：%s）"
		% ("无" if inconsistent == "" else inconsistent))
	# 陶瓷（第 1 图）= 升级前默认参数（逐位）—— selftest 基线的根基
	var cer: Dictionary = GameStats.FLOOR_THEMES[0]["layout"]
	_check(String(cer["mode"]) == "random"
		and int(cer["count"]) == GameStats.OBSTACLE_COUNT
		and Vector2(cer["min"]) == GameStats.OBSTACLE_MIN_SIZE
		and Vector2(cer["max"]) == GameStats.OBSTACLE_MAX_SIZE,
		"陶瓷 layout == 升级前 Obstacle 常量（逐位）")
	# MAP_DEFAULT_LAYOUT 与常量一致
	_check(int(GameStats.MAP_DEFAULT_LAYOUT["count"]) == GameStats.OBSTACLE_COUNT
		and Vector2(GameStats.MAP_DEFAULT_LAYOUT["min"]) == GameStats.OBSTACLE_MIN_SIZE
		and Vector2(GameStats.MAP_DEFAULT_LAYOUT["max"]) == GameStats.OBSTACLE_MAX_SIZE,
		"MAP_DEFAULT_LAYOUT == Obstacle 常量")
	# corners 规格合法（云石）
	var mar: Dictionary = GameStats.FLOOR_THEMES[2]["layout"]
	_check(String(mar["mode"]) == "corners" and Vector2(mar["size"]).x > 0.0,
		"云石 layout.mode == corners（size=%s）" % str(mar["size"]))
	_check(GameStats.MAP_CORNER_OFFSET > 100.0
		and GameStats.MAP_CORNER_OFFSET < GameStats.ARENA_W * 0.5
		and GameStats.MAP_CORNER_OFFSET < GameStats.ARENA_H * 0.5,
		"MAP_CORNER_OFFSET 区间合理（%.0f）" % GameStats.MAP_CORNER_OFFSET)
	# （机制名抽查移到 B 段：`map_effect_name_for_wave` 带 map_enabled 守卫，
	#   探针进程默认关闭态恒返回空串 —— 必须等 B 段显式打开开关后再查。
	#   2026-10-09 批量测修正：旧版在关闭态抽查导致 4 条假红。）


# ================================================================ B. 守卫 + 图映射
func _sec_b_guard_and_mapping() -> void:
	_section("B. 探针进程守卫 + 图映射")
	# 守卫：探针进程（--script）默认关闭（比 boss_phase/endless_rules 更严 ——
	# 障碍重建消耗随机流，探针默认不信任）
	_check(not GameStats.map_enabled, "初始：探针进程 → map_enabled == false（守卫生效）")
	_check(int(GameStats.map_layout_for_wave(5)["count"]) == GameStats.OBSTACLE_COUNT,
		"关闭态：map_layout_for_wave(5) 回落默认参数")
	_check(GameStats.map_effect_name_for_wave(5) == "", "关闭态：机制名恒空")
	_check(GameStats.map_enemy_mul(14, "espd") == 1.0, "关闭态：敌人乘区恒 1.0")
	# 守卫行为级：关闭态真开局 → 障碍 == 默认 2 个（selftest 路径等价）
	battle.start_run()
	_check(battle.wave_num == 1, "关闭态 start_run：波 1")
	_check(battle.obstacle_rects.size() == GameStats.OBSTACLE_COUNT,
		"关闭态：障碍 == 默认 %d 个（实际 %d）" % [GameStats.OBSTACLE_COUNT, battle.obstacle_rects.size()])
	# 打开开关进入测试态
	GameStats.map_enabled = true
	# 图映射：波 1-20 每 4 波一图
	var expect_ids := ["ceramic", "wood", "marble", "metal", "gilded"]
	for i in 5:
		var w := i * GameStats.WAVES_PER_THEME + 1
		_check(String(GameStats.floor_theme_for_wave(w)["id"]) == expect_ids[i],
			"波 %d → %s" % [w, expect_ids[i]])
	# 无尽循环复用：波 21 == 波 1、波 25 == 波 5
	_check(String(GameStats.floor_theme_for_wave(21)["id"]) == "ceramic",
		"波 21（无尽）→ ceramic（循环复用）")
	_check(String(GameStats.floor_theme_for_wave(25)["id"]) == "wood",
		"波 25（无尽）→ wood")
	# 打开态纯函数抽查
	_check(GameStats.map_enemy_mul(14, "espd") > 0.89 and GameStats.map_enemy_mul(14, "espd") < 0.91,
		"打开态：波 14 敌人乘区 ×0.9（实际 %.2f）" % GameStats.map_enemy_mul(14, "espd"))
	_check(GameStats.map_enemy_mul(5, "espd") == 1.0, "波 5（木造）无 espd → 1.0")
	# 机制名抽查（4 图各一，开关已在上面打开）：名字与 FLOOR_THEMES 表一致
	_check(GameStats.map_effect_name_for_wave(5) == "车间疾走", "波 5 机制名 == 车间疾走")
	_check(GameStats.map_effect_name_for_wave(9) == "回音定位", "波 9 机制名 == 回音定位")
	_check(GameStats.map_effect_name_for_wave(13) == "钢梁重压", "波 13 机制名 == 钢梁重压")
	_check(GameStats.map_effect_name_for_wave(17) == "遍地鎏金", "波 17 机制名 == 遍地鎏金")


# ================================================================ C. 布局生成
func _sec_c_layouts() -> void:
	_section("C. 布局生成（参数化 random / corners 固定柱）")
	var pl: Player = battle.player
	var w0: int = battle.wave_num
	# 波 1（陶瓷）：2 个默认尺寸障碍
	battle.wave_num = 1
	battle.wave.spawn_obstacles()
	_check(battle.obstacle_rects.size() == 2, "波 1（陶瓷）：2 个障碍（实际 %d）" % battle.obstacle_rects.size())
	_check(_all_size_in(battle.obstacle_rects, GameStats.OBSTACLE_MIN_SIZE, GameStats.OBSTACLE_MAX_SIZE),
		"波 1：尺寸 ∈ 默认范围 [%.0f, %.0f]" % [GameStats.OBSTACLE_MIN_SIZE.x, GameStats.OBSTACLE_MAX_SIZE.x])
	# 波 5（木造）：≤4 个小障碍
	battle.wave_num = 5
	battle.wave.spawn_obstacles()
	_check(battle.obstacle_rects.size() <= 4 and battle.obstacle_rects.size() >= 2,
		"波 5（木造）：2~4 个小障碍（实际 %d）" % battle.obstacle_rects.size())
	_check(_all_size_in(battle.obstacle_rects, Vector2(56.0, 56.0), Vector2(96.0, 96.0)),
		"波 5：尺寸 ∈ [56, 96]（小障碍）")
	# 波 13（钢铁）：≤2 个大障碍
	battle.wave_num = 13
	battle.wave.spawn_obstacles()
	_check(battle.obstacle_rects.size() <= 2, "波 13（钢铁）：≤2 个大障碍（实际 %d）" % battle.obstacle_rects.size())
	_check(_all_size_in(battle.obstacle_rects, Vector2(130.0, 130.0), Vector2(190.0, 190.0)),
		"波 13：尺寸 ∈ [130, 190]（重型）")
	# 波 17（鎏金）：≤1 个（开阔）
	battle.wave_num = 17
	battle.wave.spawn_obstacles()
	_check(battle.obstacle_rects.size() <= 1, "波 17（鎏金）：≤1 个（开阔，实际 %d）" % battle.obstacle_rects.size())
	# 波 9（云石）：4 固定角柱（坐标逐位）
	battle.wave_num = 9
	battle.wave.spawn_obstacles()
	_check(battle.obstacle_rects.size() == 4, "波 9（云石）：4 根固定柱（实际 %d）" % battle.obstacle_rects.size())
	var exp_pos: Array[Vector2] = [
		Vector2(GameStats.MAP_CORNER_OFFSET, GameStats.MAP_CORNER_OFFSET),
		Vector2(GameStats.ARENA_W - GameStats.MAP_CORNER_OFFSET - 110.0, GameStats.MAP_CORNER_OFFSET),
		Vector2(GameStats.MAP_CORNER_OFFSET, GameStats.ARENA_H - GameStats.MAP_CORNER_OFFSET - 110.0),
		Vector2(GameStats.ARENA_W - GameStats.MAP_CORNER_OFFSET - 110.0,
			GameStats.ARENA_H - GameStats.MAP_CORNER_OFFSET - 110.0),
	]
	var pos_ok := true
	for r in battle.obstacle_rects:
		if not _has_near(exp_pos, r.position) or not r.size.is_equal_approx(Vector2(110.0, 110.0)):
			pos_ok = false
	_check(pos_ok, "波 9：坐标 == 四角锚点 + size 110（对称柱廊）")
	# corners 避玩家：把玩家放到左上柱心 → 该柱被跳过
	var pos_back: Vector2 = pl.global_position
	pl.global_position = Vector2(575.0, 575.0)
	battle.wave.spawn_obstacles()
	_check(battle.obstacle_rects.size() == 3, "corners 避玩家：压住玩家的柱被跳过（4 → 3，实际 %d）"
		% battle.obstacle_rects.size())
	pl.global_position = pos_back
	battle.wave.spawn_obstacles()
	_check(battle.obstacle_rects.size() == 4, "玩家离开：恢复 4 柱")
	# 恢复波号
	battle.wave_num = w0


# ================================================================ D. 换图重建链路
func _sec_d_rebuild() -> void:
	_section("D. 换图重建链路（start_run → start_next_wave）")
	battle.player.global_position = GameStats.ARENA_CENTER
	battle.start_run()
	_check(battle.wave_num == 1, "start_run：波 1")
	_check(String(battle.wave._obstacle_map_id) == "ceramic",
		"首建登记 ceramic（实际 %s）" % battle.wave._obstacle_map_id)
	_check(battle.obstacle_rects.size() == 2, "波 1 障碍 == 2（陶瓷，不重复生成）")
	# 推进到波 5：换图 → wood（重建）
	battle.wave_num = 4
	battle.wave.start_next_wave()
	_check(battle.wave_num == 5, "推进到波 5")
	_check(String(battle.wave._obstacle_map_id) == "wood", "换图重建：id → wood")
	_check(battle.obstacle_rects.size() <= 4, "波 5 障碍已重建（≤4 个小障碍，实际 %d）"
		% battle.obstacle_rects.size())
	# 新区域中央通知（换图首波）
	_check(battle.hud._notice_label.visible
		and String(battle.hud._notice_label.text).contains("新区域 · 木造工坊"),
		"波 5：中央通知「新区域 · 木造工坊」（%s）" % battle.hud._notice_label.text)
	_check(String(battle.hud._notice_label.text).contains("车间疾走"), "通知含机制短名")
	# 同图不重建：波 6 → 矩形容器逐位不变
	var rects5: Array = battle.obstacle_rects.duplicate()
	battle.wave.start_next_wave()
	_check(battle.wave_num == 6, "推进到波 6")
	_check(battle.obstacle_rects == rects5, "同图（wood → wood）：不重建（矩形逐位不变）")
	# 推进到波 9（云石）：重建为 4 柱
	battle.wave.start_next_wave()
	battle.wave.start_next_wave()
	battle.wave.start_next_wave()
	_check(battle.wave_num == 9, "推进到波 9")
	_check(String(battle.wave._obstacle_map_id) == "marble", "波 9：id → marble")
	_check(battle.obstacle_rects.size() == 4, "波 9：重建为 4 固定柱（实际 %d）" % battle.obstacle_rects.size())
	# 结算数据面（构筑一览 region 行）
	var ov: Dictionary = battle._build_overview_data()
	_check(String(ov.get("region", "")).contains("云石回廊")
		and String(ov.get("region", "")).contains("回音定位"),
		"构筑一览 region 行 == 云石回廊 · 回音定位（%s）" % String(ov.get("region", "")))
	battle._free_all_enemies()


# ================================================================ E. 环境机制乘区
func _sec_e_effects() -> void:
	_section("E. 环境机制乘区（gold / pickup / speed / espd / 快照链路）")
	var pl: Player = battle.player
	var combat = battle.combat
	# ---- gold：遍地鎏金 ----
	pl.map_effects = {}
	pl.gold = 0
	pl.add_gold(100)
	_check(pl.gold == 100, "gold 对照：空快照 → +100（实际 %d）" % pl.gold)
	pl.map_effects = {"gold": 0.25}
	pl.gold = 0
	pl.add_gold(100)
	_check(pl.gold == 125, "遍地鎏金：+100 → +125（×1.25，实际 %d）" % pl.gold)
	pl.map_effects = {}
	# ---- pickup：回音定位 ----
	for pk in battle.pickups:
		if is_instance_valid(pk):
			pk.queue_free()
	battle.pickups.clear()
	pl.magnet_all_t = 0.0
	var d_far: float = float(pl.pickup_range) * 1.2
	combat.spawn_pickup(Pickup.KIND_GOLD, 5, pl.global_position + Vector2(d_far, 0.0))
	var pk1: Node = battle.pickups[battle.pickups.size() - 1]
	combat.process_pickups(DT)
	_check(not bool(pk1.magnetized), "pickup 对照：1.2×范围外不吸（range=%.1f）" % pl.pickup_range)
	pl.map_effects = {"pickup": 0.35}
	combat.process_pickups(DT)
	_check(bool(pk1.magnetized), "回音定位：1.2×范围 < 1.35×range → 吸")
	pl.map_effects = {}
	if is_instance_valid(pk1):
		pk1.queue_free()
	battle.pickups.clear()
	# ---- speed：车间疾走（触摸方向 + 手动步进，不依赖真实帧）----
	# autopilot 必须关：否则 _movement_dir 走自动驾驶路径、_touch_dir 被忽略。
	pl.autopilot = false
	pl.set_physics_process(false)
	pl.global_position = GameStats.ARENA_CENTER
	pl.velocity = Vector2.ZERO
	pl._touch_dir = Vector2.RIGHT
	pl.map_effects = {}
	for i in 90:
		pl._physics_process(DT)
	var v_base: float = pl.velocity.length()
	pl.global_position = GameStats.ARENA_CENTER
	pl.velocity = Vector2.ZERO
	pl.map_effects = {"speed": 0.5}
	for i in 90:
		pl._physics_process(DT)
	var v_map: float = pl.velocity.length()
	_check(v_base > 50.0 and absf(v_map / v_base - 1.5) <= 0.03,
		"车间疾走：+50% 快照使实际速度 ×1.5（%.1f → %.1f）" % [v_base, v_map])
	pl._touch_dir = Vector2.ZERO
	pl.velocity = Vector2.ZERO
	pl.map_effects = {}
	pl.set_physics_process(true)
	pl.global_position = GameStats.ARENA_CENTER
	# ---- espd：钢梁重压（模板级）----
	var base_spd: float = GameStats.enemy_speed("Slime")
	battle.wave_num = 5
	battle._free_all_enemies()
	battle.wave.spawn_enemy("Slime", GameStats.ARENA_CENTER + Vector2(120.0, 0.0))
	var e1: Node = battle.enemies[battle.enemies.size() - 1]
	_check(absf(float(e1.speed) - base_spd) <= 0.01,
		"波 5（木造）：敌人速度不吃 espd（%.1f == %.1f）" % [float(e1.speed), base_spd])
	battle._free_all_enemies()
	battle.wave_num = 14
	battle.wave.spawn_enemy("Slime", GameStats.ARENA_CENTER + Vector2(120.0, 0.0))
	var e2: Node = battle.enemies[battle.enemies.size() - 1]
	_check(absf(float(e2.speed) - base_spd * 0.9) <= 0.01,
		"波 14（钢铁）：敌人速度 ×0.9（%.1f vs %.1f）" % [float(e2.speed), base_spd * 0.9])
	battle._free_all_enemies()
	# ---- 快照链路：_apply_floor_theme 写 player.map_effects ----
	pl.map_effects = {}
	battle._apply_floor_theme(GameStats.floor_theme_for_wave(5))
	_check(pl.map_mul("speed") > 1.09 and pl.map_mul("speed") < 1.11,
		"换图钩子：wood 写入 speed 快照（实际 ×%.2f）" % pl.map_mul("speed"))
	pl.map_effects = {}
	battle._apply_floor_theme(GameStats.floor_theme_for_wave(5))
	_check(pl.map_mul("speed") > 1.09, "同图重复调用：early-return 前仍同步快照")
	pl.map_effects = {}


# ================================================================ F. 纪律
func _sec_f_discipline() -> void:
	_section("F. 纪律（键缺失 / 空字典 / 复位）")
	var pl: Player = battle.player
	pl.map_effects = {}
	_check(pl.map_mul("speed") == 1.0 and pl.map_mul("gold") == 1.0 and pl.map_mul("pickup") == 1.0,
		"空字典 → 三乘区全 1.0")
	pl.map_effects = {"speed": 0.10}
	_check(pl.map_mul("gold") == 1.0 and pl.map_mul("espd") == 1.0, "键缺失 → 1.0")
	pl.map_effects = {}
	_check(GameStats.map_effect_name_for_wave(1) == "" and GameStats.map_effect_desc_for_wave(1) == "",
		"波 1（陶瓷）：无名/无描述（横幅与通知零拼接）")
	_check(GameStats.map_enemy_mul(1, "espd") == 1.0, "波 1：敌人乘区 1.0")
	# 复位到生产默认（探针进程退出即弃，保持纪律）
	battle.wave_num = 1
	GameStats.map_enabled = true


# ================================================================ 工具
func _all_size_in(rects: Array, mn: Vector2, mx: Vector2) -> bool:
	for r in rects:
		var s: Vector2 = r.size
		if s.x < mn.x - 0.01 or s.x > mx.x + 0.01 or s.y < mn.y - 0.01 or s.y > mx.y + 0.01:
			return false
	return true


func _has_near(arr: Array, v: Vector2) -> bool:
	for p in arr:
		if (p as Vector2).is_equal_approx(v):
			return true
	return false


func _check(cond: bool, msg: String) -> void:
	checks += 1
	if cond:
		print("  [OK] ", msg)
	else:
		fails.append(msg)
		print("  [FAIL] ", msg)


func _section(title: String) -> void:
	print("\n---- %s ----" % title)


func _finish(err: String) -> void:
	if finished:
		return
	finished = true
	if err != "":
		fails.append(err)
		print("  [FAIL] ", err)
	print("\n[PROBE] checks=%d fails=%d" % [checks, fails.size()])
	if fails.is_empty():
		print("[PROBE] RESULT=PASS")
		quit(0)
	else:
		for f in fails:
			print("[PROBE] FAILED: ", f)
		print("[PROBE] RESULT=FAIL")
		quit(1)
