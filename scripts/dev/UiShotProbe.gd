extends SceneTree
## 截图探针：标题画面 + 各弹窗逐个截图存盘（按钮皮肤 / 布局改动的肉眼验收用）。
##
## 目的（2026-09-22 用户报「按钮背景显示不完整 + 边框压字」）：UI 皮肤重做后，
## 让「看不见画面」的一方直接看到真实渲染 —— 标题页 / 设置弹窗 / 局外强化 /
## 成就与战绩（2026-10-08 新增）/ 模式选择 / 敌人图鉴（含点击详情态，
## 图鉴那两张用重定向的假存档造「部分解锁」状态）。
## 2026-10-08 旗舰批次扩展：截完标题侧后进战斗场景，再截 4 张战斗内 UI ——
## HUD 主动道具槽（冷却态）/ 低血警告 / 升级面板（重抽按钮）/ 结算（再来一局按钮）。
## 2026-10-08 第二梯队扩展：难度层后追加诅咒子层 1 张（03b_curse_select）；
## 战斗内追加「融合卡」 1 张（09b_upgrade_fusion，造「已进化 + 副武器满级」态），共 13 张。
## 2026-10-09 meta 2.0 第二批：难度层追加「起始武器」子层 1 张（03c_weapon_select，共 14 张）。
##
## 用法（必须【非 headless】，headless 没有渲染截出来是黑的）:
##   godot --path <项目> --script res://scripts/dev/UiShotProbe.gd
## 输出: C:/Users/10201/Desktop/Roguelike/.workbuddy/ui_shots/*.png
## 退出码 0=截完 1=失败

const OUT_DIR := "C:/Users/10201/Desktop/Roguelike/.workbuddy/ui_shots"
const WARMUP_FRAMES := 30   # 窗口/swapchain 就绪前截图会有白屏伪影，先热身
const SETTLE_FRAMES := 5    # 开弹窗后等几帧再截，确保 redraw 已提交

var title: Node = null
var battle: Node = null
var frame := 0
var step := 0
var settle := 0


func _initialize() -> void:
	var packed: PackedScene = load("res://scenes/main/Title.tscn")
	if packed == null:
		print("[PROBE] Title.tscn 加载失败")
		quit(1)
		return
	title = packed.instantiate()
	root.add_child(title)
	DirAccess.make_dir_recursive_absolute(OUT_DIR)
	print("[PROBE] Title 已入树 → %s" % OUT_DIR)


func _process(_delta: float) -> bool:
	if title == null and battle == null:
		return false
	frame += 1
	if frame < WARMUP_FRAMES:
		return false
	# 状态机：0=标题 / 1=设置 / 2=局外强化 / 6=成就 / 3=模式选择 / 20=诅咒子层（2026-10-08 第二梯队）
	#         / 4=图鉴 / 5=图鉴详情 → 进战斗 → 7=HUD主动槽 / 8=HUD低血 / 9=升级重抽
	#         / 11=升级面板·融合卡（第二梯队） / 10=结算按钮
	if step == 0:
		if not _shot("00_title"):
			return true
		title.call("_open_settings")
		step = 1
		settle = 0
		return false
	if settle < SETTLE_FRAMES:
		settle += 1
		return false
	settle = 0
	if step == 1:
		if not _shot("01_settings"):
			return true
		title.call("_close_settings")
		title.call("_open_meta_shop")
		step = 2
		return false
	if step == 2:
		if not _shot("02_meta_shop"):
			return true
		title.call("_close_meta_shop")
		# 成就 / 战绩页（2026-10-08）插在重定向 save_path 之前截 —— 此时读的是真实账本。
		title.call("_open_achievements")
		step = 6
		return false
	if step == 6:
		if not _shot("02b_achievements"):
			return true
		title.call("_close_achievements")
		title.call("_open_difficulty_select")
		step = 3
		return false
	if step == 3:
		if not _shot("03_mode_select"):
			return true
		# 诅咒子层（2026-10-08 第二梯队）：难度层里点「诅咒」进入 —— 先截难度层（带入口按钮），
		# 再开诅咒层截图，然后一起关掉去截图鉴。
		title.call("_open_curse_select")
		step = 20
		return false
	if step == 20:
		if not _shot("03b_curse_select"):
			return true
		title.call("_close_curse_select")
		title.call("_close_difficulty_select")
		_codex_fixture()          # 造一份「部分解锁」的假存档（已重定向路径，不碰真实档）
		# 武器自由（2026-10-09 meta 2.0 第二批）：fixture 已解锁 ⇒ 重开难度层可见
		# 「起始武器」入口 —— 顺路截一张子层（默认 + 6 把武器的单选面板）。
		title.call("_open_difficulty_select")
		title.call("_open_weapon_select")
		step = 21
		return false
	if step == 21:
		if not _shot("03c_weapon_select"):
			return true
		title.call("_close_weapon_select")
		title.call("_close_difficulty_select")
		title.call("_open_codex")
		step = 4
		return false
	if step == 4:
		if not _shot("04_codex"):
			return true
		title.call("_show_codex_detail", "Rat")   # 点一只已解锁的怪 → 详情区
		step = 5
		return false
	if step == 5:
		if not _shot("05_codex_detail"):
			return true
		# 图鉴假档用完即清；随后进战斗场景截第二批（2026-10-08 旗舰批次 UI）。
		var p := "user://ui_shot_codex_meta.json"
		if FileAccess.file_exists(p):
			DirAccess.remove_absolute(p)
		_enter_battle()
		return false
	# ---- 战斗内（2026-10-08 旗舰批次）----
	if step == 7:
		if not _shot("06_hud_active_cool"):
			return true
		# 压低血量到低血线以下（18% < LOW_HP_WARN_RATIO 25%）+ 强制刷一次 HUD，
		# 低血态在下一次 set_data 立即生效（_danger_label 显示 + 血条开始脉动）。
		var pl: Player = battle.player
		pl.hp = maxf(1.0, float(pl.max_hp) * 0.18)
		var hud: Hud = battle.hud
		hud.set_data(pl, int(battle.wave_num), float(battle.wave_timer), GameStats.WAVE_COUNT)
		step = 8
		return false
	if step == 8:
		if not _shot("07_hud_lowhp"):
			return true
		# 开升级面板：_open_upgrade("wave") 会生成三选一并点亮重抽按钮（次数 2）。
		battle.call("_open_upgrade", "wave")
		step = 9
		return false
	if step == 9:
		if not _shot("08_upgrade_reroll"):
			return true
		# 关掉重抽面板 → 造「武器融合可用」状态再开一次面板：
		# 主武器已进化 + 配方副武器满级（basic 配方 = orbit）→ 末槽出现融合金卡（2026-10-08 第二梯队）。
		var up: UpgradePanel = battle.upgrade_panel
		up.hide_panel()
		var pl2: Player = battle.player
		pl2.weapon_evolved = true
		battle.extra.grant("orbit")
		for i in 4:
			battle.extra.level_up("orbit")
		battle.call("_open_upgrade", "wave")
		step = 11
		return false
	if step == 11:
		if not _shot("09b_upgrade_fusion"):
			return true
		# 关面板（解除暂停）→ 直接结算：验证底部按钮行（再来一局 + 返回标题）。
		var up2: UpgradePanel = battle.upgrade_panel
		up2.hide_panel()
		battle.call("_end_run", true)
		step = 10
		return false
	if step == 10:
		if not _shot("09_result_restart"):
			return true
		print("[PROBE] RESULT=PASS 共 14 张")
		quit(0)
		return true
	return false


## 进战斗场景（2026-10-08 旗舰批次扩展）：释放 Title，加载 Battle.tscn。
## Battle 的 _ready 末尾会 start_run()（真实开局），探针进程（--script）不会写
## 真实账本（_end_run 有 _probe_process 守卫），战局数据只活在本次截图进程里。
func _enter_battle() -> void:
	title.free()
	title = null
	var packed: PackedScene = load("res://scenes/battle/Battle.tscn")
	if packed == null:
		print("[PROBE] Battle.tscn 加载失败")
		quit(1)
		return
	battle = packed.instantiate()
	root.add_child(battle)
	# 进战斗后重等热身帧（新场景首帧重、换场景后 swapchain 也要稳定下来）。
	frame = 0
	# 先把主动道具装好、拨到冷却中段（30s 冷却的 40%）：遮罩 + 剩余秒数都会出现在图上。
	# 顺序说明：add_child 时 Battle._ready → start_run() → player.reset() 已跑完，
	# 这里的 equip 不会被 reset 冲掉。
	var pl: Player = battle.player
	pl.equip_active("active_nuke")
	pl.active_cd_t = 12.0
	battle.call("_refresh_hud_active")
	step = 7
	print("[PROBE] Battle 已入树（主动道具=active_nuke，冷却中）")


## 图鉴截图前造「部分解锁」状态（5 只已解锁 / 8 只 ???），让一张图同时验收两种格子样式。
## 2026-10-09 meta 2.0 第二批：顺带解锁「武器自由」——03c 子层截图需要难度层入口可见。
## ⚠️ **必须先重定向 save_path** —— 否则测试数据会写进玩家真实存档 user://meta_save.json。
## 前 3 张图（设置/局外强化）截完才调用，所以不受重定向影响。
func _codex_fixture() -> void:
	var p := "user://ui_shot_codex_meta.json"
	MetaSave.save_path = p
	if FileAccess.file_exists(p):
		DirAccess.remove_absolute(p)
	MetaSave.record_kills({"Slime": 128, "Rat": 96, "Student": 41, "Charger": 12, "Ox": 3})
	var d := MetaSave.ledger()
	(d[MetaSave.UNLOCKS_META_KEY] as Array).append("unlock_weapon_free")
	MetaSave._save(d)


func _shot(name: String) -> bool:
	var img: Image = root.get_texture().get_image()
	var path := "%s/%s.png" % [OUT_DIR, name]
	var err := img.save_png(path)
	if err != OK:
		print("[PROBE] 截图失败 %s（err=%d）" % [path, err])
		quit(1)
		return false
	print("[PROBE] 已截 %s（%dx%d）" % [path, img.get_width(), img.get_height()])
	return true
