class_name AssetDB
extends RefCounted
## 美术资源注册表 —— **资源路径的单一数据源**。
##
## 约定：
##   1. 所有资源路径只在这里出现一次。任何脚本都不得自己拼资源路径字符串。
##      （理由同 GameStats：散落各处的路径一旦改名就会漏改。）
##   2. 本文件不持有运行期状态（无 var），只有 const + static func。
##   3. 目录由 `scripts/dev/ImportArt.gd` 从 `美术资源\` 生成；
##      命名对齐 H5 版 `qclaw\art`，两边可对照。
##
## 目录结构：
##   chars\    角色立绘（256x256，带 alpha）
##   enemies\  敌人精灵（256x256，带 alpha）
##   anim\     序列帧（128x128，带 alpha，已统一脚底对齐）
##   drops\    掉落物（64x64）
##   items\    道具图标（128x128）
##   ui\       UI 元件（128x128）
##   bg\       背景（title/charsel 为 1600x900 有损 WebP；
##             floor_* 为 2048x2048 波次主题地面方图 —— 居中徽章式地砖，按瓦片格比例
##             居中裁切后 4x4 拼接，每块等比零变形，见 GameStats.floor_tile_src_rect）

const ROOT := "res://assets/"

# ================================================================ 角色
## 立绘 + 动画帧数。美术只有 4 个角色（嘉豪 / 学习嘉豪 / 金融嘉豪 / 忧郁嘉豪）。
## ⚠️ GDD 里写的是「土豆 + 肥嘟嘟袋鼠怪 + 嘉豪×3」共 5 个可玩角色，
##    但美术资源里没有「土豆」立绘，且「肥嘟嘟袋鼠怪」只作为【敌人】出现。
##    这里是按美术资源实际情况登记的；GDD 与美术的角色表需要对齐（见交付说明）。
##
## content_h / foot_y = 2026-09-20 清晰度升级后（256×256 帧画布）逐角色实测
## 【不透明内容包围盒】。两组体型差异明显（嘉豪组高大 / 土豆袋鼠组矮小），
## 统一常量会让一组悬空、一组下沉 —— 所以 char_fit 按角色取这里的数据。
const CHARS := {
	"basic": {"portrait": "chars/basic.png", "anim": "anim/basic", "idle": 4, "run": 6,
		"content_h": 225, "foot_y": 240},
	"study": {"portrait": "chars/study.png", "anim": "anim/study", "idle": 4, "run": 6,
		"content_h": 225, "foot_y": 240},
	"finance": {"portrait": "chars/finance.png", "anim": "anim/finance", "idle": 4, "run": 6,
		"content_h": 225, "foot_y": 240},
	"sad": {"portrait": "chars/sad.png", "anim": "anim/sad", "idle": 4, "run": 6,
		"content_h": 225, "foot_y": 240},
	# 批次新增（T-CHAR-02，见 docs/角色设计_土豆与袋鼠怪_2026-09-19.md）。
	# 立绘已由主理人用图像抠图处理成透明底（原白底图备份在 美术资源\角色\_原图备份\）。
	"potato": {"portrait": "chars/potato.png", "anim": "anim/potato", "idle": 4, "run": 6,
		"content_h": 165, "foot_y": 250},
	"kangaroo": {"portrait": "chars/kangaroo.png", "anim": "anim/kangaroo", "idle": 4, "run": 6,
		"content_h": 165, "foot_y": 250},
}

# ================================================================ 敌人
## `anim` 为空 = 该类型没有序列帧，用静态立绘。
## ⚠️ 垂直切片的两种敌人是 Slime / Medium，而美术里没有叫 Medium 的怪。
##    这里把 Medium 映射到「肥嘟嘟袋鼠怪」—— 说明.txt 描述它「中血高伤」，
##    正好对上 Medium（50 血 / 10 伤，高于 Slime 的 20/5）；而且它是本作的招牌梗怪。
##    这条映射是【提议】，要改只改这一行。
## content_h / foot_y = 实测内容高度与脚底行（见下方「美术实测数据」说明）。
const ENEMIES := {
	"Slime": {"sprite": "enemies/slime.png", "anim": "", "idle": 0, "content_h": 170, "foot_y": 213},
	"Medium": {"sprite": "enemies/feidaduo.png", "anim": "anim/enemies/feidaduo", "idle": 4, "content_h": 184, "foot_y": 220},
	"Elite": {"sprite": "enemies/elite.png", "anim": "", "idle": 0, "content_h": 231, "foot_y": 244},
	"Ranged": {"sprite": "enemies/elite.png", "anim": "", "idle": 0, "content_h": 231, "foot_y": 244},
	"Boss": {"sprite": "enemies/boss.png", "anim": "anim/enemies/boss", "idle": 4, "content_h": 209, "foot_y": 232},
	# ---- 2026-09-20 新敌人批次（源图 256×256 直通；content_h/foot_y 为 PIL 实测）----
	"Rat": {"sprite": "enemies/rat.png", "anim": "", "idle": 0, "content_h": 250, "foot_y": 253},
	"Student": {"sprite": "enemies/student.png", "anim": "", "idle": 0, "content_h": 250, "foot_y": 253},
	"Charger": {"sprite": "enemies/charger.png", "anim": "", "idle": 0, "content_h": 252, "foot_y": 254},
	"Ox": {"sprite": "enemies/ox.png", "anim": "", "idle": 0, "content_h": 243, "foot_y": 249},
	"Splitter": {"sprite": "enemies/splitter.png", "anim": "", "idle": 0, "content_h": 209, "foot_y": 232},
	"Bomber": {"sprite": "enemies/bomber.png", "anim": "", "idle": 0, "content_h": 252, "foot_y": 254},
	"Slacker": {"sprite": "enemies/slacker.png", "anim": "", "idle": 0, "content_h": 250, "foot_y": 253},
	"Monitor": {"sprite": "enemies/monitor.png", "anim": "", "idle": 0, "content_h": 252, "foot_y": 254},
	"BossPUA": {"sprite": "enemies/boss_pua.png", "anim": "", "idle": 0, "content_h": 254, "foot_y": 255},
}

# ================================================================ 美术实测数据
## 以下数字来自对【不透明内容包围盒】的实测扫描（2026-09-20 清晰度升级后重测；
## 用 PIL alpha 包围盒，与原 _ProbeContentBox 同口径）。**美工重出图后必须重量并更新这里。**
## 2026-09-20 清晰度升级：立绘 256→512、战斗/敌人动画帧 128→256、背景 1600×900→1920×1080
## （源图本来就是 1024/512/1920×1080，当初为移动端显存压缩，移动端缓做后放宽）。
const CHAR_PORTRAIT_TEX := 512
const CHAR_PORTRAIT_CONTENT_H := 467   # 6 张取最大（basic/sad/study 467）
const CHAR_PORTRAIT_FOOT_Y := 492
const CHAR_ANIM_TEX := 256
const CHAR_ANIM_CONTENT_H := 225   # 兜底值；char_fit 优先读 CHARS[].content_h 逐角色实测
const CHAR_ANIM_FOOT_Y := 250      # 兜底值（土豆/袋鼠组的脚底线；嘉豪组 240）
const ENEMY_TEX := 256
const ENEMY_ANIM_TEX := 256
const ENEMY_ANIM_CONTENT_H := 225
const ENEMY_ANIM_FOOT_Y := 240
const DROP_TEX := 64
const DROP_CONTENT_H := 40         # 实测：金币 40 / 经验 39 / 血瓶 42

## 显示目标高度 = 碰撞半径 × 这个系数。[PLACEHOLDER] 未 playtest，待真机校准。
## 用碰撞半径推导而不是拍脑袋定像素值，是为了让「看起来的大小」和「实际判定大小」一致。
const DISPLAY_PX_PER_RADIUS := 3.1

# ================================================================ 武器弹道
## 角色武器弹道贴图（2026-09-19 四人 + 09-20 土豆/袋鼠 + 09-20 六把进化第二形态 `_evo`；
## 源目录 `美术资源\weapons\`，规格见其 导入流程.md）。
##
## 字段：
##   tex      资源相对路径（ROOT 下）
##   frames / fw / fh / step / fps   sheet 切帧参数：帧 i 的区域 = Rect2(i*step, 0, fw, fh)
##       （金币 420 = 3*108+96，暗影 560 = 3*144+128，与源文档公式一致，探针 _ProbeWeaponArt 守这条）
##   content  单帧图的【实测】不透明内容包围盒 —— 弹体在画布内不居中
##       （粉笔弹内容中心 (42,17) vs 画布中心 (32,32)），画时必须按内容中心对齐命中点，
##       否则视觉偏离碰撞判定。sheet（旋转/脉冲）给 Rect2() → 按帧格中心对齐，
##       帧间的小幅摆动是动画的一部分，不做逐帧内容居中（会抖）。
##   cell_px  整个帧格缩放后的显示边长 [PLACEHOLDER]，真机校准后再调。
##   fallback 贴图缺失回落图元时的颜色（对齐人物设计 5.2：基础金/学习白/金融亮金/忧郁紫）。
const WEAPON_BULLETS := {
	"basic": {
		"tex": "weapons/w_basic_pellet.png",
		"frames": 1, "fw": 64, "fh": 64, "step": 0, "fps": 0.0,
		"content": Rect2(16, 13, 27, 26),
		"cell_px": 40.0,
		"fallback": Color("#FFD700"),
	},
	"study": {
		"tex": "weapons/w_chalk_pellet.png",
		"frames": 1, "fw": 64, "fh": 64, "step": 0, "fps": 0.0,
		"content": Rect2(23, 0, 39, 35),
		"cell_px": 30.0,
		"fallback": Color("#CFE8FF"),
	},
	"finance": {
		"tex": "weapons/w_coin_spin.png",
		"frames": 4, "fw": 96, "fh": 96, "step": 108, "fps": 10.0,
		"content": Rect2(),
		"cell_px": 42.0,
		"fallback": Color("#FFD700"),
	},
	# 2026-09-22 Bo 需求：忧郁嘉豪【未进化 ↔ 进化】形态的弹道贴图整体对调 ——
	# 未进化（本键，暗影弹）改用原进化贴图 w_sad_siphon；进化 sad_evo 改用原未进化贴图 w_shadow_orb。
	# 两张同为 560×128 / 4 帧 / 帧 128² / step 144 / 7fps，且都走帧格中心对齐（content 空）
	# ⇒ 只换 tex 字符串即可，尺寸 / 锚点 / 渲染层级逐项保持原样（对调不动任何显示参数）。
	"sad": {
		"tex": "weapons/w_sad_siphon.png",
		"frames": 4, "fw": 128, "fh": 128, "step": 144, "fps": 7.0,
		"content": Rect2(),
		"cell_px": 52.0,
		"fallback": Color("#6B2FA0"),
	},
	# 土豆「薯块重弹」（2026-09-20 交付）：大口径慢速弹（radius_mul 2.5）→ 显示尺寸放大。
	"potato": {
		"tex": "weapons/w_potato_slug.png",
		"frames": 1, "fw": 64, "fh": 64, "step": 0, "fps": 0.0,
		"content": Rect2(0, 1, 64, 61),
		"cell_px": 64.0,
		"fallback": Color("#C89B5A"),
	},
	# 袋鼠怪「蹦蹦拳」（2026-09-20 交付）：小口径快速弹（radius_mul 0.7）→ 显示尺寸缩小。
	"kangaroo": {
		"tex": "weapons/w_kanga_fist.png",
		"frames": 1, "fw": 64, "fh": 64, "step": 0, "fps": 0.0,
		"content": Rect2(0, 4, 64, 56),
		"cell_px": 26.0,
		"fallback": Color("#8CF07A"),
	},
	# ---- 进化第二形态专属弹道（2026-09-20 交付）：键 = 基础键 + "_evo"。
	# CombatResolver 进化态优先取本表，未配置/贴图缺失回落基础键（没美术也能跑）。
	# 显示尺寸与基础弹一致 —— 判定半径没变，视觉大小跟着判定走（见 DISPLAY_PX_PER_RADIUS）。
	# content 单帧图为 α>=128 实测实体主体包围盒（PIL，2026-09-20）；sheet 沿用帧格中心对齐。
	"basic_evo": {
		"tex": "weapons/w_basic_duet.png",
		"frames": 1, "fw": 64, "fh": 64, "step": 0, "fps": 0.0,
		"content": Rect2(3, 5, 61, 59),
		"cell_px": 40.0,
		"fallback": Color("#FFD700"),
	},
	"study_evo": {
		"tex": "weapons/w_study_nib.png",
		"frames": 1, "fw": 64, "fh": 64, "step": 0, "fps": 0.0,
		"content": Rect2(0, 10, 62, 54),
		"cell_px": 30.0,
		"fallback": Color("#CFE8FF"),
	},
	"finance_evo": {
		"tex": "weapons/w_finance_ingot.png",
		"frames": 4, "fw": 96, "fh": 96, "step": 108, "fps": 10.0,
		"content": Rect2(),
		"cell_px": 42.0,
		"fallback": Color("#FFD700"),
	},
	# 2026-09-22 与未进化 sad 键成对调换：进化（暗影汲取）改用原未进化贴图 w_shadow_orb。
	# 两键的 frames/fw/fh/step/fps/content/cell_px/fallback 全部一致 ⇒ 纯换图，显示参数不变。
	"sad_evo": {
		"tex": "weapons/w_shadow_orb.png",
		"frames": 4, "fw": 128, "fh": 128, "step": 144, "fps": 7.0,
		"content": Rect2(),
		"cell_px": 52.0,
		"fallback": Color("#6B2FA0"),
	},
	"potato_evo": {
		"tex": "weapons/w_potato_crack.png",
		"frames": 1, "fw": 64, "fh": 64, "step": 0, "fps": 0.0,
		"content": Rect2(9, 9, 45, 46),
		"cell_px": 64.0,
		"fallback": Color("#C89B5A"),
	},
	"kangaroo_evo": {
		"tex": "weapons/w_kanga_ghost.png",
		"frames": 1, "fw": 64, "fh": 64, "step": 0, "fps": 0.0,
		"content": Rect2(9, 9, 46, 46),
		"cell_px": 26.0,
		"fallback": Color("#8CF07A"),
	},
}

## 特效贴图：命中爆花 4 帧横排 sheet + 暴击星芒单帧 + 进化新星环 4 帧（2026-09-20 交付）。
## DeathBurst/EvoNova 消费：贴图缺失时回落程序画法（没美术也能跑）。
const FX := {
	"hit_burst": {"tex": "fx/hit_burst.png", "frames": 4, "fw": 128, "fh": 128},
	"crit_star": {"tex": "fx/crit_star.png", "frames": 1, "fw": 96, "fh": 96},
	"evo_nova": {"tex": "fx/evo_nova.png", "frames": 4, "fw": 128, "fh": 128},
}

## 界面杂图（非按钮/卡片框架类）。
const UI_TEXTURES := {
	"fake_qr": "ui/fake_qr.png",   # 模拟充值的展示用二维码（不可扫描）
}

# ================================================================ 掉落物 / 道具 / UI / 背景
const DROPS := {
	"gold": "drops/gold.png",
	"hp": "drops/hp.png",
	"xp": "drops/xp.png",
	"magnet": "drops/magnet.png",
}

const ITEMS := {
	"helmet": "items/helmet.png",
	"milk": "items/milk.png",
	"mj_gloves": "items/mj_gloves.png",
	"scooter": "items/scooter.png",
	# ↓↓ 由网格图切分而来（scripts/dev/SplitSheet.gd），共 24 个被动 + 3 个主动
	"iron_fist": "items/iron_fist.png",
	"sharp_arrow": "items/sharp_arrow.png",
	"hp_potion": "items/hp_potion.png",
	"gold_bag": "items/gold_bag.png",
	"leather_armor": "items/leather_armor.png",
	"crit_lens": "items/crit_lens.png",
	"crit_dmg_up": "items/crit_dmg_up.png",
	"study_lamp": "items/study_lamp.png",
	"harvest_bag": "items/harvest_bag.png",
	"mega_hp_potion": "items/mega_hp_potion.png",
	"regen_ring": "items/regen_ring.png",
	"piggy_bank": "items/piggy_bank.png",
	"multi_arrow": "items/multi_arrow.png",
	"vampire_fang": "items/vampire_fang.png",
	"dodge_boots": "items/dodge_boots.png",
	"evade_cloak": "items/evade_cloak.png",
	"sadness_aura": "items/sadness_aura.png",
	"lucky_charm": "items/lucky_charm.png",
	"investment_manual": "items/investment_manual.png",
	"finance_glasses": "items/finance_glasses.png",
	"iron_armor": "items/iron_armor.png",
	"golden_shield": "items/golden_shield.png",
	"brotato_chip": "items/brotato_chip.png",
	"endless_money": "items/endless_money.png",
	"active_nuke": "items/active_nuke.png",
	"active_speed_boots": "items/active_speed_boots.png",
	"active_time_stop": "items/active_time_stop.png",
	# 2026-09-20 商店扩充的 7 张道具图标（同批入库；items/ 规格 128×128 带 alpha）
	"s_refill": "items/s_refill.png",
	"s_reroll": "items/s_reroll.png",
	"s_extracard": "items/s_extracard.png",
	"s_magnet": "items/s_magnet.png",
	"s_thorns_sm": "items/s_thorns_sm.png",
	"s_shield_sm": "items/s_shield_sm.png",
	"s_resurrect": "items/s_resurrect.png",
}

## 升级选项的图标（GameStats.UPGRADE_POOL 的 id → 图标路径）。
const UPGRADE_ICONS := {
	"atk": "ui/upgrade_atk.png",
	"def": "ui/upgrade_def.png",
	"spd": "ui/upgrade_spd.png",
	"aspd": "ui/upgrade_aspd.png",
	"hp": "ui/upgrade_hp.png",
	"hpRegen": "ui/upgrade_hpRegen.png",
	"dodge": "ui/upgrade_dodge.png",
	"lifesteal": "ui/upgrade_lifesteal.png",
	"crit": "ui/upgrade_crit.png",
	"harvest": "ui/upgrade_harvest.png",
	"pickupRange": "ui/upgrade_pickupRange.png",
	"proj": "ui/upgrade_proj.png",
	# 2026-09-20 升级池扩充的 9 张图标（美术资源/道具/新增_2026-09-20/ 入库缩放到同规格）
	"critDmg": "ui/upgrade_critDmg.png",
	"range": "ui/upgrade_range.png",
	"projSpeed": "ui/upgrade_projSpeed.png",
	"expGain": "ui/upgrade_expGain.png",
	"thorns": "ui/upgrade_thorns.png",
	"shield": "ui/upgrade_shield.png",
	"lucky": "ui/upgrade_lucky.png",
	"maxHpPct": "ui/upgrade_maxHpPct.png",
	"cdr": "ui/upgrade_cdr.png",
}

## 副武器本体贴图（键 = 副武器 id，见 GameStats.EXTRA_WEAPON_DEFS）。
## 2026-09-22 豆包出图，经 `docs/review/_stripbg_weapons.py` 抠白底 + 裁包围盒 +
## 缩放入库（源图是 1024×1024 RGB 不透明白底 —— AI 图的老问题，必须过一遍抠图管线）。
## 闪电链 / 冰霜新星 / 毒云按设计就是程序化的，永远不需要贴图。
const EXTRA_WEAPON_TEX := {
	"orbit": "weapons/w_orbit_blade.png",     # 256×71（橙红短刀，刀尖朝右）
	"missile": "weapons/w_missile.png",       # 148×256（绿身红尾翼小火箭，头朝上）
}

const UI := {
	"slot_empty": "ui/slot_empty.png",
	"joystick_base": "ui/joystick_base.png",
	"joystick_knob": "ui/joystick_knob.png",
	"card_frame": "ui/card_frame.png",
	"card_frame_sel": "ui/card_frame_sel.png",
	"gold_plate": "ui/gold_plate.png",
	"button_normal": "ui/button_normal.png",
	"button_hover": "ui/button_hover.png",
	"button_pressed": "ui/button_pressed.png",
}

const BG := {
	"title": "bg/title.webp",
	"charsel": "bg/charsel.webp",
	## 波次主题地面整图（键 = "floor_" + 主题 id，与 GameStats.FLOOR_THEMES 对齐）
	## （旧 "grass" 键已删：Godot 版地面走 FLOOR_THEMES 五主题，无 grass；
	##  png 源文件与 ImportArt 管线映射保留，仅摘除运行时注册。2026-09-20 审查清理）
	"floor_ceramic": "bg/ceramic.png",
	"floor_wood": "bg/wood.png",
	"floor_marble": "bg/marble.png",
	"floor_metal": "bg/metal.png",
	"floor_gilded": "bg/gilded.png",
}

## 各类资源的预期尺寸与是否应带 alpha —— 供 scripts/dev/AssetProbe.gd 校验，
## 也是 ImportArt.gd 的目标尺寸依据（两处必须一致）。
const EXPECT := {
	"chars/": {"size": Vector2i(512, 512), "alpha": true},
	"enemies/": {"size": Vector2i(256, 256), "alpha": true},
	"anim/": {"size": Vector2i(256, 256), "alpha": true},
	"drops/": {"size": Vector2i(64, 64), "alpha": true},
	"items/": {"size": Vector2i(128, 128), "alpha": true},
	"ui/": {"size": Vector2i(128, 128), "alpha": true},
	"bg/title.webp": {"size": Vector2i(1920, 1080), "alpha": false},
	"bg/charsel.webp": {"size": Vector2i(1920, 1080), "alpha": false},
	# 波次主题地面：2026-09-19 三调，素材由 1920x1080 整图换成 **2048x2048 正方形**
	# 「居中徽章式地砖」。不再是 16:9 整铺 —— 由 GameStats.floor_tile_src_rect 按
	# 瓦片格比例从中心裁内接矩形后 4x4 拼接（每块等比、零变形）。
	"bg/ceramic.png": {"size": Vector2i(2048, 2048), "alpha": false},
	"bg/wood.png": {"size": Vector2i(2048, 2048), "alpha": false},
	"bg/marble.png": {"size": Vector2i(2048, 2048), "alpha": false},
	"bg/metal.png": {"size": Vector2i(2048, 2048), "alpha": false},
	"bg/gilded.png": {"size": Vector2i(2048, 2048), "alpha": false},
	# UI 元件尺寸不一，单独声明（card_frame 要当 9-slice 底框用，做了竖版；gold_plate 是横条）
	"ui/card_frame.png": {"size": Vector2i(224, 288), "alpha": true},
	"ui/card_frame_sel.png": {"size": Vector2i(224, 288), "alpha": true},
	"ui/gold_plate.png": {"size": Vector2i(256, 64), "alpha": true},
	"ui/button_normal.png": {"size": Vector2i(384, 128), "alpha": true},
	"ui/button_hover.png": {"size": Vector2i(384, 128), "alpha": true},
	"ui/button_pressed.png": {"size": Vector2i(384, 128), "alpha": true},
	# 虚拟摇杆（批次四 4a）：实测 128x128（PNG 头读取），与 ui/ 前缀规则同值，显式声明以自证
	"ui/joystick_base.png": {"size": Vector2i(128, 128), "alpha": true},
	"ui/joystick_knob.png": {"size": Vector2i(128, 128), "alpha": true},
	# 新角色立绘（T-CHAR-02）：512x512，已抠图成透明底（与既有 4 角色同一规格）。
	"chars/potato.png": {"size": Vector2i(512, 512), "alpha": true},
	"chars/kangaroo.png": {"size": Vector2i(512, 512), "alpha": true},
}


# ================================================================ 查询
static func path_of(rel: String) -> String:
	return ROOT + rel


## 按「希望内容显示多高」算出精灵的 scale 与 offset.y。
##   tex_size  : 纹理边长（我们的资源都是正方形）
##   content_h : 实测内容高度
##   foot_y    : 实测脚底所在行
##   target_h  : 希望内容显示成多高（px）
##
## Sprite2D/AnimatedSprite2D 默认以**纹理中心**对齐节点原点，而脚底在中心下方
## `foot_y - tex_size/2` 处 —— 所以要把精灵上移（offset_y 取负），脚底才落在节点原点上。
static func fit(tex_size: int, content_h: int, foot_y: int, target_h: float) -> Dictionary:
	if content_h <= 0:
		return {"scale": Vector2.ONE, "offset_y": 0.0}
	var s := target_h / float(content_h)
	return {"scale": Vector2(s, s), "offset_y": -(float(foot_y) - float(tex_size) * 0.5)}


## 角色在【战斗中】的显示参数（用动画帧）。
## 优先用 CHARS[char_id] 里逐角色实测的 content_h/foot_y —— 两组体型分档
## （嘉豪组 225/240、土豆袋鼠组 165/250），统一常量会造成一组悬空、一组沉地。
## 未登记角色回落统一兜底常量。
static func char_fit(char_id: String, radius: float) -> Dictionary:
	var info: Dictionary = CHARS.get(char_id, {})
	if info.has("content_h") and info.has("foot_y"):
		return fit(CHAR_ANIM_TEX, int(info["content_h"]), int(info["foot_y"]),
			radius * DISPLAY_PX_PER_RADIUS)
	return fit(CHAR_ANIM_TEX, CHAR_ANIM_CONTENT_H, CHAR_ANIM_FOOT_Y,
		radius * DISPLAY_PX_PER_RADIUS)


## 角色【立绘】的显示参数（选人界面等大图场合）。
static func char_portrait_fit(target_h: float) -> Dictionary:
	return fit(CHAR_PORTRAIT_TEX, CHAR_PORTRAIT_CONTENT_H, CHAR_PORTRAIT_FOOT_Y, target_h)


## 敌人在战斗中的显示参数（用静态立绘）。
static func enemy_fit(type_name: String, radius: float) -> Dictionary:
	if not ENEMIES.has(type_name):
		return {"scale": Vector2.ONE, "offset_y": 0.0}
	var info: Dictionary = ENEMIES[type_name]
	return fit(ENEMY_TEX, int(info["content_h"]), int(info["foot_y"]),
		radius * DISPLAY_PX_PER_RADIUS)


## 掉落物的显示参数：直接居中缩放（贴地小图标，不需要脚底对齐）。
static func drop_fit(target_h: float) -> Dictionary:
	var s := target_h / float(DROP_CONTENT_H)
	return {"scale": Vector2(s, s)}


## 加载一张纹理；不存在或类型不对时返回 null（调用方自行决定回落画法）。
static func tex(rel: String) -> Texture2D:
	var p := path_of(rel)
	if not ResourceLoader.exists(p):
		return null
	var res := load(p)
	if res is Texture2D:
		return res
	return null


## 角色立绘。
static func char_portrait(char_id: String) -> Texture2D:
	if not CHARS.has(char_id):
		return null
	return tex(CHARS[char_id]["portrait"])


## 某角色某组动画的全部帧（按序号升序）。缺帧则返回已加载到的部分。
## kind: "idle" | "run"
static func char_frames(char_id: String, kind: String) -> Array[Texture2D]:
	var out: Array[Texture2D] = []
	if not CHARS.has(char_id):
		return out
	var info: Dictionary = CHARS[char_id]
	var count := int(info.get(kind, 0))
	var anim_dir: String = info["anim"]
	for i in count:
		var t := tex("%s/%s/%s_%d.png" % [anim_dir, kind, kind, i])
		if t != null:
			out.append(t)
	return out


## 敌人静态立绘。
static func enemy_sprite(type_name: String) -> Texture2D:
	if not ENEMIES.has(type_name):
		return null
	return tex(ENEMIES[type_name]["sprite"])


## 敌人序列帧（没有配帧的类型返回空数组）。
static func enemy_idle_frames(type_name: String) -> Array[Texture2D]:
	var out: Array[Texture2D] = []
	if not ENEMIES.has(type_name):
		return out
	var info: Dictionary = ENEMIES[type_name]
	var anim_dir: String = info["anim"]
	if anim_dir.is_empty():
		return out
	for i in int(info["idle"]):
		var t := tex("%s/idle/idle_%d.png" % [anim_dir, i])
		if t != null:
			out.append(t)
	return out


static func drop(kind: String) -> Texture2D:
	if not DROPS.has(kind):
		return null
	return tex(DROPS[kind])


## 特效贴图（FX 表键 → Texture2D）。缺失返回 null，消费方回落程序画法。
static func fx_tex(key: String) -> Texture2D:
	if not FX.has(key):
		return null
	return tex(FX[key]["tex"])


## 界面杂图（UI_TEXTURES 键 → Texture2D）。缺失返回 null。
static func ui_tex(key: String) -> Texture2D:
	if not UI_TEXTURES.has(key):
		return null
	return tex(UI_TEXTURES[key])


## 角色武器弹道的显示配置（含已加载纹理，键比 WEAPON_BULLETS 多一个 "texture"）。
## 该角色未登记 / 贴图缺失 → 返回 {}（调用方回落图元画法，保证「没美术也能跑」）。
static func weapon_bullet(char_id: String) -> Dictionary:
	if not WEAPON_BULLETS.has(char_id):
		return {}
	var cfg: Dictionary = WEAPON_BULLETS[char_id]
	var t := tex(cfg["tex"])
	if t == null:
		return {}
	var out := cfg.duplicate()
	out["texture"] = t
	return out


static func item_icon(item_id: String) -> Texture2D:
	if not ITEMS.has(item_id):
		return null
	return tex(ITEMS[item_id])


## 升级选项图标。没有配图的升级项返回 null（面板就不画图，只显示文字）。
static func upgrade_icon(upgrade_id: String) -> Texture2D:
	if not UPGRADE_ICONS.has(upgrade_id):
		return null
	return tex(UPGRADE_ICONS[upgrade_id])


## 副武器本体贴图。未登记 / 缺图 → null（调用方回落程序化画法，不影响玩法）。
static func extra_weapon_tex(weapon_id: String) -> Texture2D:
	if not EXTRA_WEAPON_TEX.has(weapon_id):
		return null
	return tex(EXTRA_WEAPON_TEX[weapon_id])


## UI 元件纹理（摇杆 / 卡框 / 金币条 / 按钮等）。未登记或缺图返回 null，调用方自行回落。
static func ui(key: String) -> Texture2D:
	if not UI.has(key):
		return null
	return tex(UI[key])


static func bg(key: String) -> Texture2D:
	if not BG.has(key):
		return null
	return tex(BG[key])


## 波次主题地面整图：键约定 = "floor_" + 主题 id（见 GameStats.FLOOR_THEMES）。
## 图缺失时返回 null（Battle 自行回落到底色）。
static func floor_bg(theme_id: String) -> Texture2D:
	return bg("floor_" + theme_id)


## 返回所有已登记的相对路径（供自动化校验遍历）。
static func all_paths() -> Array[String]:
	var out: Array[String] = []
	for id in CHARS.keys():
		out.append(CHARS[id]["portrait"])
		var info: Dictionary = CHARS[id]
		for kind in ["idle", "run"]:
			for i in int(info.get(kind, 0)):
				out.append("%s/%s/%s_%d.png" % [info["anim"], kind, kind, i])
	for t in ENEMIES.keys():
		out.append(ENEMIES[t]["sprite"])
		var ei: Dictionary = ENEMIES[t]
		for i in int(ei["idle"]):
			out.append("%s/idle/idle_%d.png" % [ei["anim"], i])
	for k in DROPS.keys():
		out.append(DROPS[k])
	for k in ITEMS.keys():
		out.append(ITEMS[k])
	for k in UI.keys():
		out.append(UI[k])
	for k in BG.keys():
		out.append(BG[k])
	for k in WEAPON_BULLETS.keys():
		out.append(WEAPON_BULLETS[k]["tex"])
	for k in FX.keys():
		out.append(FX[k]["tex"])
	return out
