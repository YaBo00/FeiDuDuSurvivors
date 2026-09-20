class_name GameStats
extends RefCounted
## 《肥嘟嘟幸存者》—— 全局数值单一数据源（Single Source of Truth）。
##
## 设计约定（务必遵守）：
##   1. 所有数值常量只在这里定义一次，任何脚本都不得自行硬编码数值。
##      （H5 原型就是因为全局变量满天飞、脚本里到处 Math.round(...)，才难以维护。）
##   2. 未 playtest 的数值必须带 [PLACEHOLDER] 注释。
##   3. 本文件不持有任何运行时状态（无 var），只放 const + static func，
##      因此可被任意脚本以 GameStats.XXX 安全引用。
##
## 空间尺度：H5 逻辑画布 800x600 → Godot 视口 1280x720。
##   速度类 / 屏幕距离类数值 ×SPATIAL_SCALE；碰撞半径保持不变（见下方注释说明）。

# ============================================================ 空间尺度

## [PLACEHOLDER] H5 画布宽 800 → Godot 视口宽 1280，取 1.5 作为统一折算系数。
const SPATIAL_SCALE := 1.5

## 视口尺寸（与 project.godot 的 viewport_width/height 保持一致）。
## 注意：这是【屏幕/设计尺寸】，UI（Hud/商店/结算面板）全部按它绝对定位；
## 世界（竞技场）尺寸是独立的 ARENA_W/ARENA_H，见下。
const VIEW_WIDTH := 1280.0
const VIEW_HEIGHT := 720.0

## 【世界】竞技场尺寸：用户要求「地图扩到 2 倍、视角缩到一半、镜头跟随玩家」。
## 世界实体（角色/敌人/弹道）的世界尺寸不变 —— 视角拉近后它们在屏幕上看起来是 2 倍大，
## 这正是「不再一眼看到整张地图」的预期效果。
const ARENA_W := VIEW_WIDTH * 2.0
const ARENA_H := VIEW_HEIGHT * 2.0
const ARENA_CENTER := Vector2(ARENA_W * 0.5, ARENA_H * 0.5)
## 相机缩放（Godot 4 中 zoom>1 = 拉近）。
## 2.0 为原始设计（视角缩到一半）；2026-09-20 用户反馈「镜头距地过近、场景局促」，
## 取景范围拉远 20%（zoom ÷1.2）→ 1.6667：1280×720 视口下可视世界 768×432
## （每边 +20%，面积 +44%）。元素的世界尺寸/位置/比例全部不变，只动取景范围；
## 刷怪环走 visible_world_rect() 自动外扩，无需改刷怪逻辑。
const CAMERA_ZOOM := 1.6667

# ============================================================ 触摸控制（批次四 4a）
## 摇杆 knob 相对 base 中心的最大偏移（屏幕像素）。
const TOUCH_MAX_RADIUS := 110.0
## 浮动摇杆的 base 只在【屏幕左半边】首次按下时出现。
const TOUCH_LEFT_HALF_RATIO := 0.5

# ============================================================ 相机

## 受击震屏时长（秒）与强度（像素）。Camera2D.offset 抖动，纯视觉，不影响任何判定。
const SHAKE_DURATION := 0.18
const SHAKE_STRENGTH := 8.0

## 竞技场边界线。非 16:9 屏幕上可视区比竞技场大，玩家会被「看不见的墙」挡住，
## 画出边界让这条约束可见。
const ARENA_BORDER_COLOR := Color(1, 1, 1, 0.10)
const ARENA_BORDER_WIDTH := 3.0

## 竞技场贴图缺失时的兜底底色由 Battle.tscn 的 Background ColorRect 承担
## （Color(0.106, 0.102, 0.133)），这里不另设常量 —— 场景即数据。

# ============================================================ 建筑物（带碰撞的障碍）

## 竞技场里散布的建筑物：既做点缀，也给走位提供掩体/绕行目标。
## 数量按用户反馈从 7 调到 2 —— 太多会挤占走位空间，2 个刚好当参照物。
const OBSTACLE_COUNT := 2
const OBSTACLE_MIN_SIZE := Vector2(72.0, 72.0)
const OBSTACLE_MAX_SIZE := Vector2(150.0, 150.0)
## 建筑物之间的最小间距（px，两矩形外扩这么多后不得相交）—— 别挤成一坨。
const OBSTACLE_GAP := 70.0
## 距竞技场边缘的最小留边。
const OBSTACLE_MARGIN := 70.0
## 距玩家出生点（竞技场中心）的最小距离 —— 别把玩家开局就关在墙角里。
const OBSTACLE_CLEAR_RADIUS := 230.0
## 摆位尝试次数上限（随机摆不下就放弃这一栋，不无限重试）。
const OBSTACLE_PLACE_TRIES := 40

## 物理层：1 = 玩家，2 = 建筑物。
## 玩家与敌人【只和建筑物碰撞，彼此之间不碰撞】——
## 否则几十只怪会互相顶住堆成一堵墙，玩家反而被围死动不了。
const LAYER_PLAYER := 1
const LAYER_OBSTACLE := 2

const OBSTACLE_FILL := Color(0.310, 0.259, 0.239, 1.0)
const OBSTACLE_TOP := Color(0.416, 0.349, 0.310, 1.0)
const OBSTACLE_EDGE := Color(0.639, 0.529, 0.412, 0.9)
const OBSTACLE_SIDE := Color(0.188, 0.161, 0.153, 1.0)
const OBSTACLE_WINDOW := Color(1.0, 0.88, 0.55, 0.20)

## 叠在主题贴图上的氛围层：中央柔光（视线聚焦玩家）/ 边缘压暗（突出角色）。
## ⚠️ 贴图自带透视聚光与暗角，这两层只做【很轻】的统一调色 ——
## 旧值（glow 0.10 / vignette 0.50）是给程序化纯渐变底调的，叠在真实贴图上
## 会把暗图压出黑晕、把亮图（marble）中心叠到过曝，2026-09-19 随背景重构调轻。
## 2026-09-19 四调（用户反馈「线条太复杂、看着头晕」）：vignette 0.18 → 0.10。
## 理由：暗角覆盖整个竞技场，走到边缘时**整屏亮度缓慢漂移**，也是眩晕的来源之一，
## 而且它压暗的正是屏幕四角 —— 那里反而是玩家最需要看清敌人的地方。
const FLOOR_GLOW := Color(1.0, 0.95, 0.82, 0.03)
const FLOOR_VIGNETTE := 0.10

# ============================================================ 地面压场（缓解眩晕）
#
# 2026-09-19 用户反馈「地面线条太复杂、看着头晕想吐」。实拍 + 实测复查后确认四个来源：
#
#   ① 细亮线对比过强：地面亮度/对比都压过角色 ⇒ 角色"陷进"花纹里，眼睛抓不住主体；
#   ② 每块砖自带高光心 + 暗角：拼接后随镜头平移反复经过"亮→暗"，
#      被视觉系统读成**起伏的地面**（假景深）—— 眩晕感的主要来源；
#   ③ 网格太密：3×3 时约 2.4 纹素/世界单位 = 屏幕 1.2 纹素/像素，
#      细亮线正好卡在奈奎斯特附近 ⇒ 平移时**微闪烁**（temporal aliasing）；
#   ④ 5 套主题平均亮度差 3 倍（陶瓷 0.28 ↔ 大理石 0.83），每 4 波一次整屏亮度突变。
#
# 对策：**亮度统一（grade，乘法）+ 对比压缩（veil，向主题自身平均色混合）**。
# veil 用「主题自己的平均色」是关键 —— 只压对比、不移动色调，所以不会把大理石洗成灰泥。
# 下方 grade / veil 的数值由 `docs/review/preview_floor_variants.py` 同目录的实测得出：
#   实测（中心 16:9 区域平均，0~1）：ceramic(0.20,0.29,0.39) 亮度0.28 σ17.9
#                                   wood(0.75,0.43,0.19) 亮度0.48 σ25.9
#                                   marble(0.82,0.83,0.83) 亮度0.83 σ13.9
#                                   metal(0.58,0.60,0.62) 亮度0.59 σ42.4
#                                   gilded(0.40,0.24,0.10) 亮度0.27 σ43.3
#   grade = min(1, 目标亮度0.38 / 实测亮度)  —— 只压不抬（已够暗的主题不再提亮）
#   veil  = 实测平均色，alpha 按【实测对比度 σ】分配：越花的主题压得越狠 ——
#           σ 13~18（云石/陶瓷）→ 0.28~0.30；σ≈26（木造）→ 0.35；σ≈43（钢铁/鎏金）→ 0.45
#           这样"本来就安静"的主题不会被洗白，而"最吵"的两个被重点压住。
## 参照的目标平均亮度（见上）。
const FLOOR_GRADE_TARGET_LUM := 0.38

# ============================================================ 地面主题（按关卡换材质）

## 每 4 波换一种地面材质；20 波正好 5 种，越往后越「贵」。
## 2026-09-19 背景重构：地面从「程序化渐变 + 花纹」换成**真实贴图**
## （assets/bg/{id}.png，2048×2048 方图，按格子比例居中裁切后 3×3 拼接）。
## 主题表字段：
##   id      主题键（同时是贴图键：AssetDB.floor_bg(id) → bg/{id}.png）
##   name    波次横幅显示名
##   border  竞技场边框颜色（跟主题走，一眼能看出换关了）
##   grade   地面整体调色（draw 的 modulate）：把主题平均亮度【归一】到同一档
##   veil    柔化纱颜色（含 alpha）：向主题【自身平均色】混合 ⇒ 只压对比、不动色调
## grade / veil 的来历与算法见上方「地面压场」段落的实测表，不要凭手感改。
const WAVES_PER_THEME := 4

const FLOOR_THEMES := [
	{"id": "ceramic", "name": "陶瓷大厅", "border": Color(0.62, 0.70, 0.82, 0.55),
		"grade": Color(0.660, 0.660, 0.660), "veil": Color(0.160, 0.260, 0.320, 0.28)},
	{"id": "wood", "name": "木造工坊", "border": Color(0.72, 0.52, 0.32, 0.55),
		"grade": Color(0.787, 0.787, 0.787), "veil": Color(0.752, 0.432, 0.190, 0.35)},
	{"id": "marble", "name": "云石回廊", "border": Color(0.72, 0.82, 0.94, 0.55),
		"grade": Color(0.461, 0.461, 0.461), "veil": Color(0.823, 0.825, 0.833, 0.28)},
	{"id": "metal", "name": "钢铁车间", "border": Color(0.58, 0.68, 0.76, 0.55),
		"grade": Color(0.640, 0.640, 0.640), "veil": Color(0.575, 0.597, 0.616, 0.45)},
	{"id": "gilded", "name": "鎏金王座", "border": Color(1.0, 0.84, 0.42, 0.60),
		"grade": Color(1.00, 1.00, 1.00), "veil": Color(0.403, 0.244, 0.101, 0.45)},
]

## 主题数据缺失时的兜底（例如探针只挂了贴图没挂主题）：不调色、不加纱。
const FLOOR_GRADE_DEFAULT := Color(1.0, 1.0, 1.0)
const FLOOR_VEIL_DEFAULT := Color(0.0, 0.0, 0.0, 0.0)


## 本波该用哪种地面主题。波 1..20 与旧 clampi 结果【逐位一致】（idx 0..4）；
## 无尽模式（波 > 20）按主题数取模【循环复用】，而不是卡死在最后一个主题。
static func floor_theme_for_wave(wave_num: int) -> Dictionary:
	var idx := int((maxi(1, wave_num) - 1) / WAVES_PER_THEME) % FLOOR_THEMES.size()
	return FLOOR_THEMES[idx]


# ---- 地面瓦片拼接（2026-09-19 背景重构二调；同日三调：素材换成 2048² 方图）----
##
## 【为什么拼瓦片】竞技场是 2560×1440 世界像素，相机 zoom=1.6667（原 2.0）→
## 屏幕只看到其中一部分（1280×720 视口下约 768×432，≈1/4.9 面积）。
## 原来把一张主题贴图【拉伸整铺】到整个竞技场：贴图被放大、屏幕上的纹素（texel）被摊薄 → 观感发糊。
## 改成把【同一张贴图】复制成 COLS×ROWS 份、按网格拼接铺满：
## 每一块都重复画完整贴图，屏幕纹素密度成倍提高，画面更细腻。
## 注意：这不是把原图【切成】碎片 —— 每块内容完全相同，只是各画一份完整贴图。
##
## 【三调：素材早就换成 2048×2048 方图了】5 套地面是「居中徽章式地砖」（方形、放射对称）。
## 直接把方图塞进 16:9 的格子会【非等比压扁】（菱形地砖被横拉）→ 所以每块瓦片改从贴图
## 中心裁出与【格子宽高比】一致的内接矩形再画（见 floor_tile_src_rect）。
##
## 【四调后 3×3 → 2×2】用户反馈「线条太复杂、头晕」。3×3 时约 2.4 纹素/世界单位、
## 屏幕 1.2 纹素/像素 —— 细亮线正好卡在奈奎斯特附近，平移时会闪烁（temporal aliasing），
## 而每屏能看到约 5 条横线 × 3 条竖线。2×2 每格 1280×720 世界单位（正好 = 2 屏），
## 纹素密度降到 1.6/世界单位 = 屏幕 0.8 纹素/像素 ⇒ **微放大**，闪烁消失；
## 每屏线数约降到原来的 2/3。代价是略微变软 —— 为减轻眩晕，这个取舍是值得的。
## ⚠️ 再降（=1）会明显发糊且失去"每格一个徽章"的层次，不建议低于 2。
##
## 【如何一键回退到 1×1】把两个常量都设成 1：floor_tile_rects(1, 1) 返回【唯一一个】
## 覆盖整个 arena_rect() 的矩形，行为精确退回旧的「整张铺满」。
const FLOOR_TILE_COLS := 2
const FLOOR_TILE_ROWS := 2


## 竞技场地面瓦片矩形（行优先：先第 0 行从左到右、再第 1 行…），共 cols*rows 个，世界空间。
##
## 无缝保证：用 ARENA_W/cols、ARENA_H/rows 这类【精确除法】推导，相邻瓦片的共享边坐标
## 完全相同（不留缝、不重叠），并集精确等于 arena_rect()；派生自常量、不引入随机/取整漂移。
## 参数带默认值是为了可验证：floor_tile_rects(1, 1) 退回「整张铺满」，任意 cols/rows ≥ 1 均无缝无叠。
static func floor_tile_rects(cols: int = FLOOR_TILE_COLS, rows: int = FLOOR_TILE_ROWS) -> Array[Rect2]:
	var c := maxi(1, cols)
	var r := maxi(1, rows)
	var tw := ARENA_W / float(c)
	var th := ARENA_H / float(r)
	var out: Array[Rect2] = []
	for iy in r:
		for ix in c:
			out.append(Rect2(float(ix) * tw, float(iy) * th, tw, th))
	return out


## 每块瓦片该从贴图的哪个区域取像素（源矩形，单位 = 纹素；行优先同一套矩阵）。
##
## 【为什么需要它】5 套地面贴图是 2048×2048 的【正方形】居中徽章地砖，而瓦片格是 16:9
## （640×360 世界）。若把方图直接塞进格子，菱形地砖会被【横向拉伸】1.78 倍 —— 非等比变形。
## 这里按【格子宽高比】从贴图中心裁出最大的内接矩形，于是每块瓦片都是等比缩放、零变形。
##
## 【向后兼容】贴图本来就和格子同比例时（例如旧的 1920×1080 = 16:9）返回【整张贴图】，
## 行为与改造前逐像素一致。所以本函数让地面绘制对【素材宽高比免疫】—— 以后再换图不用改绘制逻辑。
##
## tex_size 传 0 或负值（贴图缺失）时返回 Rect2(0,0,0,0)，调用方自行判断跳过。
static func floor_tile_src_rect(tex_size: Vector2, cols: int = FLOOR_TILE_COLS,
		rows: int = FLOOR_TILE_ROWS) -> Rect2:
	var c := maxi(1, cols)
	var r := maxi(1, rows)
	if tex_size.x <= 0.0 or tex_size.y <= 0.0:
		return Rect2()
	var cell_aspect := (ARENA_W / float(c)) / (ARENA_H / float(r))
	if tex_size.x / tex_size.y > cell_aspect:
		# 贴图比格子更宽 → 裁掉左右，保留居中
		var nw := tex_size.y * cell_aspect
		return Rect2((tex_size.x - nw) * 0.5, 0.0, nw, tex_size.y)
	# 贴图比格子更高（方图就是这种）→ 裁掉上下，保留居中
	var nh := tex_size.x / cell_aspect
	return Rect2(0.0, (tex_size.y - nh) * 0.5, tex_size.x, nh)


# ============================================================ 商店物品

## 商店物品表（28 个被动道具，id 对齐 AssetDB.ITEMS 的图标键）。
##
## effect 的键对齐 Player 的加成键；【特殊键】：
##   gold           立刻获得金币
##   gold_per_kill  每次击杀额外金币
##   shop_discount  商店价格折扣（乘法，0.82 = 打 82 折）
##   xp_mul         升级所需经验倍率（乘法，0.8 = 经验需求降 20%）
##   all            全属性百分比（Player.recalc_stats 的全局乘区）
##
## ⚠️ sadness_aura（减速光环）与 lucky_charm（幸运）的玩法还没实现，暂不上架 ——
##    图标已就位，等机制做了再进池子。
const RARITY_PRICE := {
	"common": 18, "uncommon": 32, "rare": 50, "epic": 75, "legendary": 110,
}
## 商店随机抽商品的稀有度权重
const RARITY_WEIGHTS := {
	"common": 45, "uncommon": 30, "rare": 17, "epic": 6, "legendary": 2,
}
## 每波上架几件商品
const SHOP_SLOTS := 4

# ---- 全场磁吸掉落（参考 C3 掉落三件套：回血 / 清屏 / 限时全场磁吸）----
## [PLACEHOLDER] 磁铁掉落的稀有度：普通怪死亡的掉率；精英（Elite）/Boss 击杀必掉。
const MAGNET_DROP_CHANCE := 0.01
## [PLACEHOLDER] 拾取磁铁后的全场磁吸时长（秒）：期间场上所有掉落物无视拾取范围飞向玩家。
const MAGNET_ALL_DURATION := 8.0

const ITEM_DEFS := {
	"iron_fist": {"name": "铁拳手套", "rarity": "common", "desc": "攻击力 +15",
		"effect": {"atk": 15.0}},
	"sharp_arrow": {"name": "锋利箭头", "rarity": "common", "desc": "攻速 +12%",
		"effect": {"aspd": 0.12}},
	"hp_potion": {"name": "HP药水", "rarity": "common", "desc": "生命上限 +15",
		"effect": {"hp": 15.0}},
	"gold_bag": {"name": "钱袋", "rarity": "common", "desc": "立刻获得 $40",
		"effect": {"gold": 40}},
	"leather_armor": {"name": "皮甲", "rarity": "common", "desc": "护甲 +3",
		"effect": {"def": 3.0}},
	"crit_lens": {"name": "暴击透镜", "rarity": "uncommon", "desc": "暴击率 +10%",
		"effect": {"crit": 0.10}},
	"crit_dmg_up": {"name": "暴击之牙", "rarity": "uncommon", "desc": "暴击伤害 +40%（需：暴击透镜）",
		"effect": {"critd": 0.40}, "requires": "crit_lens"},
	"milk": {"name": "野生狗奶", "rarity": "uncommon", "desc": "攻击力 +10，攻速 +8%",
		"effect": {"atk": 10.0, "aspd": 0.08}},
	"study_lamp": {"name": "学习台灯", "rarity": "uncommon", "desc": "经验需求 -20%，攻击力 -5",
		"effect": {"xp_mul": 0.80, "atk": -5.0}},
	"harvest_bag": {"name": "收获袋", "rarity": "uncommon", "desc": "金币收益 +30%",
		"effect": {"harvest": 0.30}},
	"mega_hp_potion": {"name": "大HP药水", "rarity": "uncommon", "desc": "生命上限 +40（需：HP药水）",
		"effect": {"hp": 40.0}, "requires": "hp_potion"},
	"regen_ring": {"name": "回复戒指", "rarity": "uncommon", "desc": "每秒回血 +2",
		"effect": {"hpRegen": 2.0}},
	"piggy_bank": {"name": "存钱罐", "rarity": "uncommon", "desc": "每次击杀额外 +$1",
		"effect": {"gold_per_kill": 1}},
	"multi_arrow": {"name": "多重箭袋", "rarity": "rare", "desc": "弹道数 +1",
		"effect": {"proj": 1.0}},
	"vampire_fang": {"name": "吸血鬼之牙", "rarity": "rare", "desc": "吸血 +12%",
		"effect": {"lifesteal": 0.12}},
	"helmet": {"name": "袋鼠头盔", "rarity": "rare", "desc": "护甲 +6，攻击力 +12",
		"effect": {"def": 6.0, "atk": 12.0}},
	"dodge_boots": {"name": "闪避靴", "rarity": "rare", "desc": "闪避 +12%",
		"effect": {"dodge": 0.12}},
	"evade_cloak": {"name": "闪避披风", "rarity": "rare", "desc": "闪避 +22%，攻速 -10%（需：闪避靴）",
		"effect": {"dodge": 0.22, "aspd": -0.10}, "requires": "dodge_boots"},
	"investment_manual": {"name": "投资手册", "rarity": "rare", "desc": "商店价格 -18%",
		"effect": {"shop_discount": 0.82}},
	"scooter": {"name": "电动车", "rarity": "rare", "desc": "移速 +25%，闪避 +5%",
		"effect": {"spd": 0.25, "dodge": 0.05}},
	"finance_glasses": {"name": "金融眼镜", "rarity": "rare", "desc": "暴击率 +15%，金币收益 +25%",
		"effect": {"crit": 0.15, "harvest": 0.25}},
	"iron_armor": {"name": "铁甲", "rarity": "rare", "desc": "护甲 +10（需：皮甲）",
		"effect": {"def": 10.0}, "requires": "leather_armor"},
	"golden_shield": {"name": "金盾", "rarity": "epic", "desc": "护甲 +15，移速 -10%（需：铁甲）",
		"effect": {"def": 15.0, "spd": -0.10}, "requires": "iron_armor"},
	"mj_gloves": {"name": "MJ蛛丝手套", "rarity": "epic", "desc": "攻速 +18%，弹道数 +1",
		"effect": {"aspd": 0.18, "proj": 1.0}},
	"brotato_chip": {"name": "土豆芯片", "rarity": "legendary", "desc": "全属性 +8%",
		"effect": {"all": 0.08}},
	"endless_money": {"name": "无限金卡", "rarity": "legendary", "desc": "金币收益 +100%",
		"effect": {"harvest": 1.00}},
	# 武器精通手册（2026-09-20 可达性升级）：进化第三途径（升级卡 / 波末保底之外，金色购买）。
	# 满层（6）后 shop_roll 不再上架（见其 mastery_level 参数）。
	"weapon_mastery_book": {"name": "武器精通手册", "rarity": "epic", "desc": "武器精通 +1（每层攻击 +3，满 6 层进化）",
		"effect": {"weapon_mastery": 1.0}},
}


## 按稀有度权重抽 n 件不重复的商品（id 列表）。
## owned：本局已购道具集合（A4 前置解锁链）。带 requires 的道具只在其前置已购时
## 进池。**默认 null = 完全旧行为（全道具进池）**——不能用空数组当默认值：
## GDScript 里「缺省」与「显式传 []」无法区分，空数组默认会把前置件永远滤光。
static func shop_roll(n: int, owned: Variant = null, mastery_level := -1) -> Array[String]:
	var pool: Array[String] = []
	var weights: Array[float] = []
	for id in ITEM_DEFS.keys():
		var d: Dictionary = ITEM_DEFS[id]
		if owned != null and d.has("requires") and not (owned as Array).has(String(d["requires"])):
			continue             # 前置未购：本波不上架
		# 武器精通手册：武器已进化（6 层满）后不再上架 —— 无效商品是负反馈。
		# mastery_level 缺省 -1 = 不过滤（旧调用方/探针行为逐位不变）。
		if id == "weapon_mastery_book" and mastery_level >= WEAPON_EVOLVE_LEVEL:
			continue
		pool.append(String(id))
		weights.append(float(RARITY_WEIGHTS[d["rarity"]]))
	var out: Array[String] = []
	var total := weights.size()
	for i in mini(n, pool.size()):
		var sum := 0.0
		for j in total:
			if not pool[j].is_empty():
				sum += weights[j]
		var roll := rng_global().randf() * sum
		var acc := 0.0
		var pick := -1
		for j in total:
			if pool[j].is_empty():
				continue
			acc += weights[j]
			if roll <= acc:
				pick = j
				break
		if pick < 0:
			break
		out.append(pool[pick])
		weights[pick] = 0.0      # 已抽到的不重复上架（权重清零）
	return out


## 物品价格：基础价 × 玩家的商店折扣。
static func shop_price(item_id: String, discount: float) -> int:
	var d: Dictionary = ITEM_DEFS[item_id]
	return maxi(1, roundi(float(RARITY_PRICE[d["rarity"]]) * discount))


## 全局随机源（商店抽卡用；不污染全局 randf 的调用顺序）
static var _rng := RandomNumberGenerator.new()


static func rng_global() -> RandomNumberGenerator:
	return _rng


## 竞技场世界矩形（固定尺寸，不随窗口变化 —— 保证不同设备手感与难度一致）。
static func arena_rect() -> Rect2:
	return Rect2(Vector2.ZERO, Vector2(ARENA_W, ARENA_H))

# ============================================================ 波次 / 关卡

## 每波时长（秒）。来自 H5 WAVE_DURATION。
const WAVE_DURATION := 30.0
## 波数：打满 20 波即通关（无尽模式 --endless 下此值仍是「正常通关点」，
## 波 1..20 的所有曲线逐位不变，超过它才走无尽放大分支）。
## 之前是 3 波（垂直切片验证用），对齐《土豆兄弟》的量级改成 20。
const WAVE_COUNT := 20
## 无尽模式【自检】跑到第几波收束（无尽真玩时永不结算，靠阵亡结束）。
const ENDLESS_SELFTEST_WAVES := 40
## 无尽模式 Boss 周期：波 > WAVE_COUNT 后每这么多个周期波补刷一只 Boss
## （否则波 20 之后永远没有 Boss）。
const ENDLESS_BOSS_PERIOD := 10
## Boss 出现的波次：第 10 波小 Boss（练手）、第 20 波终 Boss（收尾高潮）。
## Boss 不占 spawn_count 名额 —— 波开刷的瞬间独立多刷一只。
## [PLACEHOLDER] Boss 基础数值见 ENEMY_TEMPLATES["Boss"]，playtest 后再调。
const BOSS_WAVES: Array[int] = [10, 20]


## 是否为 Boss 波。波 ≤20 只看固定表（逐位不变）；无尽下每 ENDLESS_BOSS_PERIOD 波补一只。
static func is_boss_wave(wave_num: int) -> bool:
	return BOSS_WAVES.has(wave_num) or (wave_num > WAVE_COUNT and wave_num % ENDLESS_BOSS_PERIOD == 0)
## 波末升级三选一的选项数（基础值；学习豪的天赋会 +1）。
const UPGRADE_OPTIONS := 3

# ============================================================ 角色

## 角色表。4 个嘉豪。差异按 H5 CHARACTERS 的 baseStats 原样照抄 ——
## H5 是把天赋效果【直接烘进 baseStats】的（例如忧郁豪的 maxHp 65 / atk 14 / spd 172
## 本身就是「HP-30%、伤害+40%、移速+15%」的结果），这里保持一致，不另写一套天赋系统。
##
## 属性表达不了的天赋用额外字段：
##   start_gold         初始金币（H5 金融豪 = 80）
##   xp_mul             升级所需经验的倍率（学习豪 0.77 = 更快升级）
##   upgrade_opt_bonus  升级选项数量加成（学习豪 +1）
##
## `base` 里的 pickupRange 是新增的（H5 没有），见「掉落 / 拾取」一节。
const CHARACTERS := {
	"basic": {
		"name": "基础嘉豪", "portrait": "chars/basic.png",
		"talent": "新手保护·初心",
		"desc": "每局第一次致死免死：回 1 血并获得 1 秒无敌。其余成长全为标准值。",
		"trait_id": "beginner_save",
		"start_gold": 20, "xp_mul": 1.0, "upgrade_opt_bonus": 0,
		"base": {
			"maxHp": 100, "atk": 10, "def": 0, "spd": 150, "aspd": 1.0, "proj": 1,
			"crit": 0.05, "critd": 1.5, "hpRegen": 0.0, "dodge": 0.0, "lifesteal": 0.0,
			"harvest": 1.0, "luck": 0.0, "pickupRange": 36.0,
		},
	},
	"study": {
		"name": "学习豪", "portrait": "chars/study.png",
		"talent": "题海精进",
		"desc": "经验 +30%，升级选项 +1；每升一级永久 +3% 攻速。",
		"trait_id": "levelup_aspd",
		"start_gold": 20, "xp_mul": 0.77, "upgrade_opt_bonus": 1,
		"base": {
			"maxHp": 90, "atk": 8, "def": 0, "spd": 160, "aspd": 1.0, "proj": 1,
			"crit": 0.05, "critd": 1.5, "hpRegen": 0.0, "dodge": 0.05, "lifesteal": 0.0,
			"harvest": 1.0, "luck": 0.0, "pickupRange": 36.0,
		},
	},
	"finance": {
		"name": "金融豪", "portrait": "chars/finance.png",
		"talent": "见钱眼开",
		"desc": "金币 +50%，初始 $80；捡金币移速短暂 +5%（最多 3 层），商店永久 9 折。",
		"trait_id": "money_rush",
		"start_gold": 80, "xp_mul": 1.0, "upgrade_opt_bonus": 0,
		"base": {
			"maxHp": 85, "atk": 9, "def": 0, "spd": 145, "aspd": 0.9, "proj": 1,
			"crit": 0.10, "critd": 1.5, "hpRegen": 0.0, "dodge": 0.0, "lifesteal": 0.0,
			"harvest": 1.5, "luck": 0.0, "pickupRange": 36.0,
		},
	},
	"sad": {
		"name": "忧郁豪", "portrait": "chars/sad.png",
		"talent": "背水一战",
		"desc": "伤害 +40%，HP −30%，移速 +15%；血量低于 50% 伤害再 +25%、低于 25% 共 +40%。",
		"trait_id": "low_hp_fury",
		"start_gold": 20, "xp_mul": 1.0, "upgrade_opt_bonus": 0,
		"base": {
			"maxHp": 65, "atk": 14, "def": 0, "spd": 172, "aspd": 1.1, "proj": 1,
			"crit": 0.05, "critd": 1.5, "hpRegen": 0.0, "dodge": 0.0, "lifesteal": 0.0,
			"harvest": 1.0, "luck": 0.0, "pickupRange": 36.0,
		},
	},
	# ---- 批次新增（T-CHAR-02，docs/角色设计_土豆与袋鼠怪_2026-09-19.md §1.3 原文粘贴）----
	"potato": {
		"name": "土豆", "portrait": "chars/potato.png",   # [PLACEHOLDER] 待美术接线
		"talent": "越挫越勇",
		"desc": "每次受击后 +2 点护甲（最多 5 层），3 秒不受击后清零。",
		"trait_id": "armor_stack",
		"start_gold": 20, "xp_mul": 1.0, "upgrade_opt_bonus": 0,
		"base": {
			"maxHp": 150,      # [PLACEHOLDER] 全队最高（basic 100 的 1.5 倍），肉盾立身之本
			"atk": 8,          # [PLACEHOLDER] 低于基准 10 —— 不允许全面更优
			"def": 6,          # [PLACEHOLDER] 全队最高（其余人全 0），叠满天赋共 16
			"spd": 118,        # [PLACEHOLDER] 全队最低，慢是肉盾的代价（挨打时长 ↑）
			"aspd": 0.75,      # [PLACEHOLDER] 全队最低攻速，配重弹武器
			"proj": 1,         # [PLACEHOLDER]
			"crit": 0.05,      # [PLACEHOLDER] 与 basic 同档
			"critd": 1.5,      # [PLACEHOLDER] 与 basic 同档
			"hpRegen": 1.0,    # [PLACEHOLDER] 唯一自带回血，强化「站得住」
			"dodge": 0.0,      # [PLACEHOLDER] 肉盾不闪避（闪避让 armor_stack 无收益）
			"lifesteal": 0.0,  # [PLACEHOLDER] 吸血留给武器/升级，避免双重回复过肉
			"harvest": 1.0,    # [PLACEHOLDER] 与 basic 同档
			"luck": 0.0,       # [PLACEHOLDER] 与 basic 同档
			"pickupRange": 36.0,  # [PLACEHOLDER] 与 basic 同档
		},
	},
	# ---- §2.3 原文粘贴 ----
	"kangaroo": {
		"name": "袋鼠怪", "portrait": "chars/kangaroo.png",   # [PLACEHOLDER] 待美术接线
		"talent": "停不下来",
		"desc": "持续移动每秒 +1 层：每层 +2% 移速 +3% 攻速（最多 5 层），停下 1 秒清零。",
		"trait_id": "move_stacks",
		"start_gold": 20, "xp_mul": 1.0, "upgrade_opt_bonus": 0,
		"base": {
			"maxHp": 80,       # [PLACEHOLDER] 全队第二脆（仅高于忧郁豪 65），敢站桩就死
			"atk": 9,          # [PLACEHOLDER] 低于基准 10，DPS 由武器与天赋层数补
			"def": 0,          # [PLACEHOLDER] 脆皮不设甲
			"spd": 188,        # [PLACEHOLDER] 全队最高（basic 150 的 1.25 倍），游击立身之本
			"aspd": 1.0,       # [PLACEHOLDER] 基准攻速，天赋层负责往上抬
			"proj": 1,         # [PLACEHOLDER]
			"crit": 0.05,      # [PLACEHOLDER] 与 basic 同档
			"critd": 1.5,      # [PLACEHOLDER] 与 basic 同档
			"hpRegen": 0.0,    # [PLACEHOLDER] 脆皮无回复，靠走位而非数值站撸
			"dodge": 0.10,     # [PLACEHOLDER] 全队最高，机动向的第二层生存
			"lifesteal": 0.0,  # [PLACEHOLDER] 不吸血，保持「敢挨打就死」的偏科纯粹性
			"harvest": 1.0,    # [PLACEHOLDER] 与 basic 同档
			"luck": 0.0,       # [PLACEHOLDER] 与 basic 同档
			"pickupRange": 36.0,  # [PLACEHOLDER] 与 basic 同档
		},
	},
}

## 默认角色（选人界面之前 / 自检时的兜底）。
const DEFAULT_CHAR := "basic"


static func character(id: String) -> Dictionary:
	if CHARACTERS.has(id):
		return CHARACTERS[id]
	return CHARACTERS[DEFAULT_CHAR]


static func character_ids() -> Array:
	return CHARACTERS.keys()


## 取角色的特性 id（`beginner_save` / `levelup_aspd` / `money_rush` / `low_hp_fury`）。
## 玩家特性判定统一走这个入口，**不硬编码 char_id** —— 改表即可换特性归属。
## 缺失时返回空串（视为无特性），不报错。
static func trait_id_for_char(id: String) -> String:
	return String(character(id).get("trait_id", ""))

## 玩家碰撞半径。半径类数值保持 H5 原值（不做 ×1.5）：
## 若半径也放大，则单位在放大后的世界里视觉上会比 H5 更「胖」，
## 而 H5 的手感是基于 radius=18 调出来的，故保留原值。
const PLAYER_RADIUS := 18.0
## [PLACEHOLDER] 玩家加/减速度（指数趋近速率，1/秒）。
## 之前是瞬间满速/瞬间停（手感像滑冰板）。数值待 playtest。
const PLAYER_ACCEL := 15.0
const PLAYER_DECEL := 22.0
## [PLACEHOLDER] 拾取磁吸：进入拾取范围后掉落物飞向玩家的速度/加速度/结算距离。
## [PLACEHOLDER] 接触伤害叠加封顶（A8 迭代）：同帧多怪接触时总伤 = Σ各怪伤害，
## 但不超过「单只最痛怪的 N 倍」—— 被围仍然痛、且有界，不会 10 只叠出秒杀。
const CONTACT_DMG_CAP_MULT := 3.0

# ---- 武器进化·本期切片（B2 迭代：完整进化树见 docs/参考复用批次总结）----
## 「武器精通」升级可重复取；叠到 WEAPON_EVOLVE_LEVEL 层时武器进化，
## 出膛伤害 ×WEAPON_EVOLVE_DMG_MUL（挂在 on_player_fired 伤害公式尾）。
## [PLACEHOLDER] 数值未 playtest；进化后的第二形态（质变招式）是后续迭代。
const WEAPON_EVOLVE_LEVEL := 6
const WEAPON_EVOLVE_DMG_MUL := 1.25
## 武器精通每层的即时小额收益（2026-09-20 用户需求）：叠层期间不至于白板，
## 但必须低于最普通的攻击卡（+5/8/12）—— 进化的核心收益仍是满层的质变。
const WEAPON_MASTERY_STACK_ATK := 3.0

## 武器进化·第二形态（2026-09-20）：满 WEAPON_EVOLVE_LEVEL 层进化后，武器获得
## 【形态专属质变】—— 每把武器一个主题方向的附加特性，与既有机制叠加。
##   shots        每次攻击额外弹道数（加进 shots = base_shots + form.shots + proj − 1）
##   pierce       额外穿透数（加到逐弹道 pierce_cap）
##   gold_on_hit  命中掉金概率增量（加法叠加，上限 1 自然封顶）
##   lifesteal    武器吸血增量（与玩家/武器吸血合并后仍受 MAX_LIFESTEAL 封顶）
##   rate_add     攻速倍率增量（加到 rate_mul 上，进化瞬间 recalc 生效）
##   aoe_radius / aoe_pct   命中溅射：以命中点为圆心，圈内其他敌人受直接伤害的 aoe_pct
##               （溅射不暴击不吸血；目标记入该弹已命中集合，杜绝逐帧重复伤害）
## [PLACEHOLDER] 全部数值待 playtest。
const WEAPON_EVOLUTIONS := {
	"basic": {"name": "连珠·二重奏", "shots": 1},
	"study": {"name": "贯穿书写", "pierce": 2},
	"finance": {"name": "贪婪回馈", "gold_on_hit": 0.08},
	"sad": {"name": "暗影汲取", "lifesteal": 0.06},
	"potato": {"name": "爆裂薯块", "aoe_radius": 90.0, "aoe_pct": 0.40},
	"kangaroo": {"name": "残影连拳", "rate_add": 0.35},
}


## 取某角色的第二形态定义。未登记/未知角色 → 空字典（消费方零行为变化）。
static func weapon_evolution(char_id: String) -> Dictionary:
	if WEAPON_EVOLUTIONS.has(char_id):
		return WEAPON_EVOLUTIONS[char_id]
	return {}

# ---- 正弦怪潮（B1 迭代）：波内投放节奏呼吸化，总量精确守恒 ----
## 投放速率乘以 1 + A·sin(2π·elapsed/period)，period = SPAWN_WINDOW/2
## ⇒ 投放窗口内恰好两个整周期，正弦积分为 0 ⇒ **总投放量与匀速模式逐只一致**。
## 效果：怪潮一波三折（涌上来 → 略喘 → 再涌），纯手感调节，不改变难度总量。
## [PLACEHOLDER] A = 0.35 未 playtest；= 0 即关闭怪潮回到匀速。
const SPAWN_TIDE_AMPLITUDE := 0.35


## 投放速率的潮汐乘区（elapsed_in_window = 已进入投放窗口的秒数）。
static func spawn_tide_mul(elapsed_in_window: float) -> float:
	var period := SPAWN_WINDOW / 2.0
	return 1.0 + SPAWN_TIDE_AMPLITUDE * sin(TAU * elapsed_in_window / period)
const MAGNET_SPEED := 980.0
const MAGNET_ACCEL := 2600.0
const MAGNET_COLLECT := 20.0
## [PLACEHOLDER] 暴击击杀时的 hit-stop（时间放缓比例与时长，秒）。
const HITSTOP_SCALE := 0.30
const HITSTOP_TIME := 0.05
## 敌人分离：空间网格格子尺寸（世界像素），也供弹道碰撞查询复用。
const GRID_CELL := 96.0
## 攻击基础间隔（秒）：实际间隔 = ATTACK_BASE_COOLDOWN / aspd。
const ATTACK_BASE_COOLDOWN := 0.5
## 攻击距离（玩家中心 → 目标中心，世界像素）。之前没有距离门：场上有敌人就开火
## → 怪在视野外就被打死。视野换算：原始设计 zoom=2 → 可视世界 640x360（半宽320/半高180），
## 230 = 横向几乎贴屏幕边、纵向越界仅 50px；略大于 SPAWN_MIN_DIST(225)，
## 「能出生的距离」与「能被打的距离」一致，不存在永远够不着的死区。
## 2026-09-20 取景拉远（zoom 1.6667 → 半宽 384/半高 216）：攻击距离值保持不变
## —— 距离门的锚点是刷怪距离而非屏幕边，玩家现在能看到射程外的怪走过来（预期观感）。
## [PLACEHOLDER] 待 playtest。参数化预留：Player._bonus["attackRange"]（百分比加成），
## 将来做「可调攻击距离」升级/道具时直接往该键加值，无需再改逻辑。
const ATTACK_RANGE_BASE := 230.0
## 受击后的无敌帧时长（秒）。H5 里是全局变量，Godot 版放到玩家自身。
const IFRAME_DURATION := 0.5

const START_LEVEL := 1
const START_XP := 0
const START_XP_TO_NEXT := 20
## 击杀掉落的经验 = 金币 × 这个倍率（原本写死在 Enemy.setup 里）。
const XP_PER_GOLD := 3
## 每次升级后 xpToNext 的倍率。
## H5 是 1.5，实测 20 波只升到 8 级、成长感太弱 → 降到 1.32。
const XP_GROWTH := 1.32

# 属性上限（对齐 H5 recalcPlayerStats）
const MAX_DODGE := 0.8
const MAX_CRIT := 0.9
const MAX_LIFESTEAL := 0.9
const MAX_PROJ := 5
const MAX_ASPD := 10.0   # [PLACEHOLDER] 攻速倍率硬上限，防止极端叠加导致间隔→0

# ============================================================ 弹道

## [PLACEHOLDER] 弹道速度。H5 PROJ_SPEED=300 → ×SPATIAL_SCALE。
const PROJ_SPEED := 300.0 * SPATIAL_SCALE
const PROJ_RADIUS := 5.0
## 弹道寿命（秒）。旧值 2.0 → 最远飞 900px（跨半张地图），射程改近后
## 落空的弹会飞进视野深处才消失、甚至在远处打死怪。0.8 x 450px/s = 360px，
## 恰好飞出射程圈一小段（留穿透余量）。
const PROJ_LIFE := 0.8
## 最多命中数（穿透）：命中计数 >= 2 即移除。
const PROJ_PIERCE := 2
## 多弹道扇形的每发偏角（弧度）。
const PROJ_SPREAD := 0.3
## 天赋增伤：本切片土豆无天赋，固定 1.0。
const PROJ_DMG_BOOST := 1.0

# ============================================================ 敌方弹道

## 远程怪的弹道参数（比玩家弹道慢、粗、红）。
const ENEMY_PROJ_SPEED := 280.0 * SPATIAL_SCALE
const ENEMY_PROJ_RADIUS := 7.0
const ENEMY_PROJ_LIFE := 4.0
const ENEMY_PROJ_COLOR := Color(1.0, 0.3, 0.25, 0.9)

## 远程怪保持距离区间（px，直接写世界值，不再乘 SPATIAL_SCALE）。
## 上限必须与玩家攻击距离（ATTACK_RANGE_BASE=230）协调：260~380 意味着
## 玩家贴身 0.5 秒即可把怪纳入射程（怪边退边被打，被逼到墙角就能围杀）。
## 旧值 330~510 会让远程怪永远站在玩家射程外无伤点名。
const RANGED_KEEP_MIN := 260.0
const RANGED_KEEP_MAX := 380.0
## 远程怪射击间隔（秒）。
const RANGED_FIRE_INTERVAL := 2.5

# ============================================================ Boss 特殊技能（2026-09-19 批次三）
#
# Boss 不再只是「高血量、慢速追击的怪」。它按【固定顺序】循环出招：
#   扇形弹幕（fan）→ 冲锋（charge）→ 召唤小弟（summon）
# 每招都有【前摇】：前摇期间 Boss 站住不动并给出视觉预警，给玩家反应窗口 ——
# 这是公平性底线（门禁断言"每招前摇 > 0"）。
#
# ⚠️ 出招顺序刻意【不做随机】：顺序确定才可被门禁确定性断言，玩家也才学得会。
#
# [PLACEHOLDER] 以下数值全部未 playtest，手感不对就逐个调。

## 出招循环顺序（下标循环递增）。
const BOSS_SKILL_ORDER: Array[String] = ["fan", "charge", "summon"]
## 各招前摇时长（秒）。必须全部 > 0。
const BOSS_SKILL_WINDUP := {"fan": 0.85, "charge": 0.70, "summon": 1.00}
## 出招后硬直（秒）：招式的"代价"，也是玩家反打窗口。
const BOSS_SKILL_RECOVER := 0.45
## 两次出招之间的间隔（秒），从「硬直结束」开始计；开局首招也用它。
const BOSS_SKILL_INTERVAL := 3.2
## 扇形弹幕：发数与总张角（度）。总张角以「朝玩家方向」为中轴左右均分。
const BOSS_FAN_COUNT := 7
const BOSS_FAN_SPREAD_DEG := 70.0
## 冲锋：速度（世界单位/秒，属速度类 ⇒ 乘 SPATIAL_SCALE）与持续时间（秒）。
## [PLACEHOLDER] 540 world/s ≈ 玩家移速（225）的 2.4 倍 —— 必须靠前摇躲，硬顶是顶不住的。
const BOSS_CHARGE_SPEED := 360.0 * SPATIAL_SCALE
const BOSS_CHARGE_DURATION := 0.45
## 召唤小弟：类型、数量与落点半径（px，距离类直接写世界值）。
const BOSS_SUMMON_TYPE := "Slime"
const BOSS_SUMMON_COUNT := 3
const BOSS_SUMMON_RADIUS := 130.0

# ============================================================ 武器

## 角色武器表。**键恒等于 char_id**（`weapon_for_char` 按此索引，查不到回落 basic）。
##
## 每项字段（全部齐备，缺一不可）：
##   name        显示名（CharSelect / 结算展示）
##   base_shots  基础弹道数（实际发数 = base_shots + player.proj − 1，见 Player/Battle）
##   dmg_mul     出膛伤害乘区（乘在 atk 之后、暴击判定之前）
##   rate_mul    攻击间隔除数（间隔 = ATTACK_BASE_COOLDOWN / aspd / rate_mul）
##   pierce      逐弹道穿透上限（不是全局 PROJ_PIERCE！sad 用 99 贯穿全屏）
##   speed_mul   弹速乘区
##   radius_mul  弹体半径乘区
##   lifesteal   武器自带吸血（出膛时与 player.lifesteal 相加，**不进 recalc**）
##   gold_on_hit 命中时掉金币的概率（0 = 不掉）
##
## 数值来源：docs/design/人物设计_嘉豪四人组_2026-09-19.md §0.1 / §1.3 / §2.3 / §3.3 / §4.3。
## 全部为 [PLACEHOLDER] 初稿，playtest 后按该文档 §9 的旋钮调。
const WEAPON_DEFS := {
	"basic": {
		"name": "随手连弹", "base_shots": 1, "dmg_mul": 1.0, "rate_mul": 1.0,
		"pierce": 2, "speed_mul": 1.0, "radius_mul": 1.0,
		"lifesteal": 0.0, "gold_on_hit": 0.0,
	},
	"study": {
		"name": "粉笔连射", "base_shots": 2, "dmg_mul": 0.55, "rate_mul": 1.35,
		"pierce": 1, "speed_mul": 1.1, "radius_mul": 0.8,
		"lifesteal": 0.0, "gold_on_hit": 0.0,
	},
	"finance": {
		"name": "金币镖", "base_shots": 1, "dmg_mul": 0.9, "rate_mul": 0.8,
		"pierce": 5, "speed_mul": 1.0, "radius_mul": 1.8,
		"lifesteal": 0.0, "gold_on_hit": 0.12,
	},
	"sad": {
		"name": "暗影弹", "base_shots": 1, "dmg_mul": 1.8, "rate_mul": 0.6,
		"pierce": 99, "speed_mul": 0.85, "radius_mul": 2.2,
		"lifesteal": 0.08, "gold_on_hit": 0.0,
	},
	# ---- 批次新增（T-CHAR-02，设计文档 §1.4 / §2.4 原文粘贴）----
	"potato": {
		"name": "薯块重弹", "base_shots": 1, "dmg_mul": 1.4, "rate_mul": 0.65,
		"pierce": 3, "speed_mul": 0.8, "radius_mul": 2.5,
		"lifesteal": 0.0, "gold_on_hit": 0.0,
	},
	"kangaroo": {
		"name": "蹦蹦拳", "base_shots": 1, "dmg_mul": 0.7, "rate_mul": 1.5,
		"pierce": 1, "speed_mul": 1.25, "radius_mul": 0.7,
		"lifesteal": 0.0, "gold_on_hit": 0.0,
	},
}

## 武器弹体颜色（透传 Projectile.body_color；色值 [PLACEHOLDER]，playtest 后可调）。
const WEAPON_COLORS := {
	"basic": Color("#FFD700"),
	"study": Color("#CFE8FF"),
	"finance": Color("#FFD700"),
	"sad": Color("#6B2FA0"),
	# 批次新增（T-CHAR-02）：土豆皮棕黄（与 basic 金色区分）／弹跳青草绿
	"potato": Color("#C89B5A"),     # [PLACEHOLDER]
	"kangaroo": Color("#8CF07A"),   # [PLACEHOLDER]
}


## 取角色武器定义。查不到（未知 char_id / 表被改坏）→ 回落 basic，永不返回空字典。
static func weapon_for_char(id: String) -> Dictionary:
	if WEAPON_DEFS.has(id):
		return WEAPON_DEFS[id]
	return WEAPON_DEFS["basic"]


## 取武器弹体颜色。回落 basic 金色。
static func weapon_color(id: String) -> Color:
	if WEAPON_COLORS.has(id):
		return WEAPON_COLORS[id]
	return WEAPON_COLORS["basic"]


# ---- 角色特性常量（全部 [PLACEHOLDER]，来源同 WEAPON_DEFS 头注释）----

## 初心（basic）免死后的独立无敌时长（秒）。刻意长于 IFRAME_DURATION(0.5)，给足脱离时间。
const TRAIT_SAVE_IFRAME := 1.0
## 题海精进（study）每升一级永久增加的攻速（加法进 _bonus["aspd"]）。
const TRAIT_ASPD_PER_LEVEL := 0.03
## 见钱眼开（finance）每层移速加成（加法叠层，非 _bonus，只做运行时 buff）。
const TRAIT_MONEY_BOOST_STEP := 0.05
## 见钱眼开单次捡钱的加速持续时长（秒）。
const TRAIT_MONEY_BOOST_TIME := 2.5
## 见钱眼开加速最大层数（3 层 = +15%）。
const TRAIT_MONEY_BOOST_MAX := 3
## 见钱眼开商店永久折扣（与「投资手册 0.82」乘法叠加 → 0.738）。
const TRAIT_SHOP_DISCOUNT_FINANCE := 0.9
## 背水一战（sad）一档：血量占比低于此值 → 增伤 TRAIT_FURY_T1_BONUS。
const TRAIT_FURY_T1_HP := 0.5
## 背水一战一档增伤（+25%）。
const TRAIT_FURY_T1_BONUS := 0.25
## 背水一战二档：血量占比低于此值 → 再叠 TRAIT_FURY_T2_BONUS（合计 +40%）。
const TRAIT_FURY_T2_HP := 0.25
## 背水一战二档增伤（再 +15%）。
const TRAIT_FURY_T2_BONUS := 0.15

# ---- 越挫越勇（potato / armor_stack）（T-CHAR-02，设计文档 §3.1 原文粘贴）----
## 每层护甲加成（点数，受击结算后叠 1 层）。
const TRAIT_ARMOR_STEP := 2.0        # [PLACEHOLDER]
## 护甲层数上限。
const TRAIT_ARMOR_MAX := 5           # [PLACEHOLDER]
## 不受击多少秒后层数清零。
const TRAIT_ARMOR_DECAY_TIME := 3.0  # [PLACEHOLDER]

# ---- 停不下来（kangaroo / move_stacks）----
## 持续移动多久叠 1 层（秒）。
const TRAIT_KANGA_STACK_TIME := 1.0  # [PLACEHOLDER]
## 每层移速加成（乘区步进，运行时乘区）。
const TRAIT_KANGA_SPD_STEP := 0.02   # [PLACEHOLDER]
## 每层攻速加成（乘区步进，运行时乘区）。
const TRAIT_KANGA_ASPD_STEP := 0.03  # [PLACEHOLDER]
## 层数上限。
const TRAIT_KANGA_MAX := 5           # [PLACEHOLDER]
## 停下多久清零（秒）。
const TRAIT_KANGA_STOP_CLEAR := 1.0  # [PLACEHOLDER]

## 武器命中掉金币的面额基数（× harvest 取整，最少 1）。
const WEAPON_GOLD_ON_HIT_VALUE := 1
## 攻击间隔硬下限（秒）。防 aspd + 题海精进 + 粉笔连射叠加把间隔打到接近 0。
## 与 MAX_ASPD=10 同性质的防爆炸护栏。
const ATTACK_INTERVAL_MIN := 0.05

# ============================================================ 掉落 / 拾取

## 拾取范围基准（玩家中心 → 掉落物的距离，px）。
##
## ⚠️ 刻意做得很小：掉落物必须【走到跟前】才捡得起来。
## 之前用的是 150（H5 的 100 × 1.5），玩家还没走到就隔着老远自动吸走 ——
## 既不合理，也让「增加拾取范围」这个成长项失去意义。
## 现在它是玩家属性 `pickupRange`（见 CHARACTERS[].base），可由升级提升。
const PICKUP_RANGE_BASE := 36.0
const PICKUP_RADIUS := 6.0
const PICKUP_LIFE := 8.0
## 金币掉落的寿命倍率（2026-09-20 用户需求）：金币没捡到就消失太亏，寿命翻倍。
## 其他掉落物（经验/磁铁）不变。 [PLACEHOLDER] 待 playtest。
const PICKUP_GOLD_LIFE_MULT := 2.0
## 回合结束金币回收（2026-09-20 用户需求）：结算时场上未拾取的金币按此比例
## 自动计入玩家金币（向下取整），避免「打了却完全拿不到」。 [PLACEHOLDER] 待 playtest。
const GOLD_SALVAGE_RATIO := 0.5

# ============================================================ 刷怪

## 屏幕外出生点向外偏移（H5 getSpawnPos 的 m=30）→ ×SPATIAL_SCALE。
const SPAWN_MARGIN := 30.0 * SPATIAL_SCALE
## 出生点距玩家过近的阈值（H5 的 150）→ ×SPATIAL_SCALE。
const SPAWN_MIN_DIST := 150.0 * SPATIAL_SCALE
## 过近时改到玩家周围该半径的随机角度上（H5 的 250）→ ×SPATIAL_SCALE。
const SPAWN_RESERVE_RADIUS := 250.0 * SPATIAL_SCALE

## 每波【持续投放】的窗口（秒）：只在这个窗口内出怪，最后几秒是清场时间。
## 目的：修掉「开局一股脑全出 → 玩家清完 → 干等倒计时结束」。
const SPAWN_WINDOW := 26.0
## 场上同时存活的上限（性能保护）。达到上限时投放会暂停，怪被清掉后继续。
const SPAWN_LIVE_CAP := 80
## 每波投放总数 = SPAWN_BASE + 波次 × SPAWN_GROWTH。
## 难度二调（2026-09-19）：旧值 10+4（波1=14）配合无限射程，站桩即可清完前几波。
## 现在 16+5 → 波1=21、波5=41、波10=66、波20=116（受 LIVE_CAP=80 截停）；
## 再叠加攻击距离门（怪走进 230px 才会被打），前 3 波站桩必然被围死。
const SPAWN_BASE := 16
const SPAWN_GROWTH := 5

# ============================================================ 敌人模板

## 关键修正：每个模板都【显式】声明 def:int = 0。
##
## H5 原型的 spawnEnemy 从未给敌人设 def 字段，但伤害公式里有
## Math.round(e.def*0.5) → undefined*0.5 = NaN → e.hp -= NaN → hp 变 NaN
## → (hp<=0) 恒为 false → 敌人永远打不死，击杀/金币/升级闭环全断。
## Godot 版从数据结构层面杜绝该路径：def 一定是有定义的整数。
const ENEMY_TEMPLATES := {
	"Slime": {"hp": 20, "dmg": 5, "spd": 60, "radius": 12, "gold": 1, "def": 0, "behavior": "melee"},
	"Medium": {"hp": 50, "dmg": 10, "spd": 80, "radius": 16, "gold": 2, "def": 0, "behavior": "melee"},
	"Elite": {"hp": 120, "dmg": 15, "spd": 70, "radius": 20, "gold": 4, "def": 0, "behavior": "melee"},
	"Ranged": {"hp": 35, "dmg": 8, "spd": 55, "radius": 14, "gold": 3, "def": 0, "behavior": "ranged"},
	"Boss": {"hp": 600, "dmg": 25, "spd": 45, "radius": 36, "gold": 25, "def": 0, "behavior": "boss"},
	# ---- 2026-09-20 新敌人批次（docs/新敌人_代码接入说明_2026-09-20.md §2 数值原文粘贴，全 [PLACEHOLDER]）----
	"Rat": {"hp": 12, "dmg": 4, "spd": 95, "radius": 10, "gold": 1, "def": 0, "behavior": "melee"},
	"Student": {"hp": 8, "dmg": 6, "spd": 110, "radius": 12, "gold": 2, "def": 0, "behavior": "melee"},
	"Charger": {"hp": 45, "dmg": 14, "spd": 55, "radius": 14, "gold": 3, "def": 0, "behavior": "charger"},
	"Ox": {"hp": 180, "dmg": 18, "spd": 35, "radius": 24, "gold": 5, "def": 0, "behavior": "melee"},
	"Splitter": {"hp": 60, "dmg": 8, "spd": 55, "radius": 16, "gold": 2, "def": 0, "behavior": "splitter"},
	"Bomber": {"hp": 30, "dmg": 20, "spd": 85, "radius": 13, "gold": 2, "def": 0, "behavior": "bomber"},
	"Slacker": {"hp": 35, "dmg": 8, "spd": 50, "radius": 14, "gold": 3, "def": 0, "behavior": "ranged"},
	"Monitor": {"hp": 50, "dmg": 5, "spd": 45, "radius": 14, "gold": 4, "def": 0, "behavior": "support"},
	# BossPUA：复用 boss 三招状态机；召唤类型/数量/群体加速走模板字段（见 Enemy._start_active）
	"BossPUA": {"hp": 800, "dmg": 20, "spd": 40, "radius": 30, "gold": 30, "def": 0, "behavior": "boss",
		"summon_type": "Rat", "summon_count": 2, "summon_aura": [1.3, 3.0]},
}

# ---- 新敌人行为常量（2026-09-20，数值来自接入说明 §3，全 [PLACEHOLDER] 待 --balance）----
## charger（卷王）：玩家进入 250px → 前摇 0.6s（闪红锁定方向）→ 沿锁定方向 spd×3.5 冲 0.5s → 硬直 0.8s
const CHARGER_TRIGGER_DIST := 250.0
const CHARGER_WINDUP_TIME := 0.6
const CHARGER_DASH_SPEED_MUL := 3.5
const CHARGER_DASH_TIME := 0.5
const CHARGER_RECOVER_TIME := 0.8
## splitter（精神内耗）：死亡分裂成 2 只 Rat，每只血量取 Rat 模板的 60%
const SPLITTER_CHILD_COUNT := 2
const SPLITTER_CHILD_HP_MUL := 0.6
## bomber（班味炸弹）：距玩家 80px 进引信 2s（与新音效时长对齐，见接入说明 §5.5）；
## 引信中玩家拉开到 160px 之外则取消；引爆时对 90px 内的玩家造成自身 dmg
const BOMBER_FUSE_DIST := 80.0
const BOMBER_FUSE_TIME := 2.0
const BOMBER_CANCEL_DIST := 160.0
const BOMBER_AOE_DIST := 90.0
## support（班长）：每 2s 给 150px 内友军 +25% 移速（持续 2s 可刷新）；每 4s 给范围内
## 血量占比最低的友军回其 max_hp 的 5%
const SUPPORT_PULSE_INTERVAL := 2.0
const SUPPORT_HEAL_INTERVAL := 4.0
const SUPPORT_AURA_DIST := 150.0
const SUPPORT_SPEED_MUL := 1.25
const SUPPORT_SPEED_DUR := 2.0
const SUPPORT_HEAL_RATIO := 0.05
## 班长游荡距离带：与玩家保持这个区间，贴太近后退、太远跟上、区间内切向游荡
const SUPPORT_WANDER_MIN := 250.0
const SUPPORT_WANDER_MAX := 350.0
## BossPUA 召唤冷却（复用 boss 技能循环时对齐接入说明 §3.5 的「每 8s」语义——
## 实际节奏由 BOSS_SKILL_INTERVAL 决定，此处仅作文档锚点）

# ---- 敌人台词表（2026-09-20 用户需求）：入场气泡 / 击杀告别 / 放招喊话 ----
## spawn = 首次进入玩家视野时冒泡（每只一次）；death = 被击杀时；skill = 放招喊话
## （键 = boss 三招名，或行为事件 windup/fuse/pulse）。**缺键 = 不说话** ——
## Slime/Medium/Rat/Student 刻意不登记：杂鱼满场刷台词会把气泡变成噪音。
## 用户点名：牛马 spawn「牛来~」death「妈--妈--」。
const ENEMY_TAUNTS := {
	"Elite": {"spawn": "就这就这？", "death": "我不甘心！"},
	"Ranged": {"spawn": "你瞅啥？", "death": "告辞！"},
	"Boss": {"spawn": "本王回来了！", "death": "呱……王座没了……",
		"skill": {"fan": "万箭齐发！", "charge": "冲鸭——！！", "summon": "孩子们，上！"}},
	"BossPUA": {"spawn": "欢迎入职~", "death": "这届员工不行……",
		"skill": {"fan": "都听我说！", "charge": "绩效冲刺！！", "summon": "都是自己人！"}},
	"Ox": {"spawn": "牛来~", "death": "妈--妈--"},
	"Charger": {"spawn": "卷王来卷了", "skill": {"windup": "卷起来！！"}, "death": "卷不动了……"},
	"Bomber": {"spawn": "班味要炸了", "skill": {"fuse": "班味爆炸！！"}, "death": "……没炸成"},
	"Splitter": {"spawn": "我精神状态很好", "death": "啊啊啊裂开了！！"},
	"Monitor": {"spawn": "大家加油鸭~", "skill": {"pulse": "都动起来！"}, "death": "后排也要挨打……"},
	"Slacker": {"spawn": "摸鱼中勿扰", "death": "鱼没了……"},
}

## 入场/击杀台词查询。缺键返回空串（调用方空串即静默）。
static func enemy_taunt(type_name: String, kind: String) -> String:
	var t: Dictionary = ENEMY_TAUNTS.get(type_name, {})
	return String(t.get(kind, ""))

## 放招台词查询（boss 三招名或行为事件键）。
static func enemy_skill_taunt(type_name: String, skill: String) -> String:
	var t: Dictionary = ENEMY_TAUNTS.get(type_name, {})
	var s: Dictionary = t.get("skill", {})
	return String(s.get(skill, ""))

# ============================================================ 升级选项池（H5 UPGRADE_POOL + 拾取范围）

## tiers = [波<10 的值, 波 10~19 的值, 波>=20 的值]
## `pickupRange` 是新增项 —— 拾取范围从「固定的大值」改成了「小的可成长值」，
## 所以必须给玩家一条把它买回来的途径。
const UPGRADE_POOL := [
	{"id": "atk", "name": "攻击力", "tiers": [5.0, 8.0, 12.0], "pct": false, "cost_tier": 2},
	{"id": "def", "name": "护甲", "tiers": [2.0, 4.0, 6.0], "pct": false, "cost_tier": 1},
	{"id": "spd", "name": "移速", "tiers": [0.08, 0.12, 0.12], "pct": true, "cost_tier": 2},
	{"id": "aspd", "name": "攻速", "tiers": [0.08, 0.12, 0.12], "pct": true, "cost_tier": 2},
	{"id": "hp", "name": "生命上限", "tiers": [12.0, 18.0, 25.0], "pct": false, "cost_tier": 2},
	{"id": "hpRegen", "name": "每秒回血", "tiers": [0.5, 1.0, 1.0], "pct": false, "cost_tier": 1},
	{"id": "dodge", "name": "闪避", "tiers": [0.03, 0.05, 0.05], "pct": true, "cost_tier": 1,
		"max": 0.50, "stat": "dodge"},
	{"id": "lifesteal", "name": "吸血", "tiers": [0.03, 0.06, 0.06], "pct": true, "cost_tier": 3,
		"max": 0.30, "stat": "lifesteal"},
	{"id": "crit", "name": "暴击率", "tiers": [0.03, 0.05, 0.05], "pct": true, "cost_tier": 3,
		"max": 0.60, "stat": "crit"},
	{"id": "harvest", "name": "金币收益", "tiers": [0.12, 0.18, 0.18], "pct": true, "cost_tier": 1},
	{"id": "pickupRange", "name": "拾取范围", "tiers": [18.0, 26.0, 36.0], "pct": false, "cost_tier": 1},
	{"id": "proj", "name": "弹道数", "tiers": [1.0, 1.0, 1.0], "pct": false, "cost_tier": 3},
	# 武器精通（B2 迭代·本期切片）：可重复取 6 次，满层武器进化（伤害 ×1.25）。
	# 2026-09-20：每层附赠即时攻击 +3（WEAPON_MASTERY_STACK_ATK，tiers 仅作卡面展示），
	# 叠层期间不再白板；借用 C2 的 max/stat 封顶过滤：满层后自动从升级池消失。
	{"id": "weapon_mastery", "name": "武器精通", "tiers": [3.0, 3.0, 3.0, 3.0, 3.0, 3.0],
		"pct": false, "cost_tier": 3, "max": 6.0, "stat": "weapon_level"},
]

# ---- 波末升级捆绑的「敌人代价」（参考 A1 双向升级投票；2026-09-20 用户选 A：只在波末捆绑）----
## 波末三选一的每张卡按 `cost_tier`（1 轻 / 2 中 / 3 重）捆绑一个「敌人变强」的代价，
## 等级升级保持纯奖励（前期爽感不受影响 —— 这是 A 方案与 A1 原味的差别）。
##
## ⚠️ 每档有 max_stacks 叠层上限（镜像 A1 的 MaxStack）：封顶后该档不再出现在选项里，
## 档位全满时波末升级退回纯奖励 ⇒ **总敌人成长有界**，不会随波数滚出控制
## （满配上限：生命 ×1.36、伤害 ×1.33 左右，量级刻意压在「可感知但不破坏既有曲线」）。
## [PLACEHOLDER] 数值未 playtest：嫌轻就加 hp_mul/dmg_mul，嫌重就砍 max_stacks。
const UPGRADE_ENEMY_COSTS := {
	1: {"name": "敌人生命 +8%", "hp_mul": 0.08, "dmg_mul": 0.0, "max_stacks": 4},
	2: {"name": "敌人伤害 +8%", "hp_mul": 0.0, "dmg_mul": 0.08, "max_stacks": 3},
	3: {"name": "敌人生命 +6% 且伤害 +6%", "hp_mul": 0.06, "dmg_mul": 0.06, "max_stacks": 3},
}


## 按档位取代价表条目（副本，调用方可安全附加字段）。档位非法返回空字典。
static func enemy_cost_for_tier(tier: int) -> Dictionary:
	var d: Dictionary = UPGRADE_ENEMY_COSTS.get(tier, {})
	return d.duplicate()


# ============================================================ 查询 / 计算（静态函数）

## 敌人模板查询，返回副本以避免外部误改常量。
static func enemy_template(type_name: String) -> Dictionary:
	return ENEMY_TEMPLATES.get(type_name, ENEMY_TEMPLATES["Slime"]).duplicate()


## 敌人移速（px/s）：固定，不随波次缩放，但 ×SPATIAL_SCALE。
static func enemy_speed(type_name: String) -> float:
	return float(enemy_template(type_name)["spd"]) * SPATIAL_SCALE


## 无尽模式（波 > WAVE_COUNT）下，血量/伤害曲线斜率的放大倍数 —— 让难度继续往上爬。
const ENDLESS_HP_SLOPE_MUL := 1.6
const ENDLESS_DMG_SLOPE_MUL := 1.6


## 曲线斜率帮助函数（私有）：
##   w ≤ WAVE_COUNT → 旧线性式 base + (w-1)*slope（保证 1..20 逐位不变）；
##   w > WAVE_COUNT → 从【波 WAVE_COUNT 的值】起接上放大后的斜率 mul*slope，
##   因此曲线在 wave=WAVE_COUNT 处【连续】、而且之后【严格单调递增】。
static func _slope(w: int, base: float, slope: float, mul: float) -> float:
	if w <= WAVE_COUNT:
		return base + float(w - 1) * slope
	var at_cap := base + float(WAVE_COUNT - 1) * slope
	return at_cap + float(w - WAVE_COUNT) * slope * mul


## 波次血量缩放：波 ≤20 为 1.1 + (wave-1)*0.10（波1 = ×1.1、波10 = ×2.0、波20 = ×3.0）。
## 波 >20 从波 20 的值起按 ENDLESS_HP_SLOPE_MUL 放大斜率继续爬。
## 历史调参：最早 0.15（波20=×3.85）击杀崩掉 → 0.09；现因攻击距离门
## 玩家有效输出窗口变短，整体再抬一档，前期怪更耐打、逼玩家走位拉扯。
static func hp_scale(wave_num: int) -> float:
	return _slope(wave_num, 1.1, 0.10, ENDLESS_HP_SLOPE_MUL)


## 波次伤害缩放：波 ≤20 为 1 + (wave-1)*0.05（波1 = ×1.0、波20 = ×1.95）；
## 波 >20 从波 20 的值起按 ENDLESS_DMG_SLOPE_MUL 放大斜率继续爬。
static func dmg_scale(wave_num: int) -> float:
	return _slope(wave_num, 1.0, 0.05, ENDLESS_DMG_SLOPE_MUL)


## 每波投放总数上限（无尽模式高波的性能护栏；波 20 = 116，尚未触顶）。
const SPAWN_COUNT_CAP := 140


## 本波计划投放的总怪数（还受 SPAWN_LIVE_CAP 约束，实际可能少投）。
## 波1=21、波5=41、波10=66、波20=116（SPAWN_BASE=16 + 波次×5）；
## 无尽高波封顶到 SPAWN_COUNT_CAP 防喷发（单调非减、有界，1..20 逐位不变）。
static func spawn_count(wave_num: int) -> int:
	return mini(SPAWN_BASE + wave_num * SPAWN_GROWTH, SPAWN_COUNT_CAP)


## 每波的平均投放速率（只/秒）。整波在 SPAWN_WINDOW 内【匀速】投放，
## 所以不会出现「开局全出完、剩下时间干等」。
## 波1 ≈ 0.69/s（约 1.4 秒一只），波20 ≈ 5.08/s（约 0.2 秒一只）。
static func spawn_rate(wave_num: int) -> float:
	if SPAWN_WINDOW <= 0.0:
		return 0.0
	return float(spawn_count(wave_num)) / SPAWN_WINDOW


## 本波敌人类型权重表（随机取一项）。
##   波1~3  ：迷你怪为主，少量中怪
##   波4+   ：中怪加量
##   波8+   ：远程怪加入（保持距离射击）
##   波14+  ：远程怪加量
static func spawn_types(wave_num: int) -> Array:
	# 2026-09-20 新敌人批次：按接入说明 §4 的首次波逐步入池（重复项 = 权重）。
	# 首次波：Rat 1 / Student 3 / Charger 5 / Ox 6 / Bomber 7 / Splitter 8 / Slacker 9 / Monitor 10。
	var t := ["Slime", "Slime", "Slime", "Medium", "Rat", "Rat", "Rat"]
	if wave_num >= 3:
		t.append_array(["Rat", "Student"])
	if wave_num >= 4:
		t.append_array(["Slime", "Medium", "Rat"])
	if wave_num >= 5:
		t.append_array(["Rat", "Charger"])
	if wave_num >= 6:
		t.append_array(["Ox", "Rat"])
	if wave_num >= 7:
		t.append_array(["Bomber"])
	if wave_num >= 8:
		t.append_array(["Medium", "Ranged", "Splitter"])
	if wave_num >= 9:
		t.append_array(["Slacker", "Rat"])
	if wave_num >= 10:
		t.append_array(["Monitor", "Ranged"])
	if wave_num >= 14:
		t.append_array(["Medium", "Ranged", "Ranged", "Charger", "Bomber", "Ox"])
	return t


## Boss 波用哪只 Boss：第 10 波 = BossPUA（新），第 20 波与无尽循环 = 现有袋鼠王 Boss
## （接入说明 §4 波次表）。
static func boss_type_for_wave(wave_num: int) -> String:
	return "BossPUA" if wave_num == 10 else "Boss"


## 波次进度 0..1（用于难度插值）。
static func wave_t(wave_num: int) -> float:
	if WAVE_COUNT <= 1:
		return 0.0
	return clampf(float(wave_num - 1) / float(WAVE_COUNT - 1), 0.0, 1.0)


## 出生点：位于「可视区域」某条边之外，再向外偏移 margin。side ∈ 0..3 = 上/右/下/左。
##
## ⚠️ 必须传【实际可视区域】，不能传设计尺寸 1280x720。
## 视口随窗口宽高比变化（实测：--resolution 1600x720 → 可视 1600x720；
## 1024x768 → 可视 1280x960）。若按设计尺寸刷怪，在 20:9 手机上敌人会刷在
## x = 1280+45 = 1325，而屏幕能显示到 1600 ⇒ 敌人当着玩家的面凭空出现，
## 而不是从屏幕外走进来。
##
## r1 / r2 是 [0,1) 的随机数，由调用方注入 —— 这样本函数是【纯函数】，
## 可以对任意宽高比做确定性测试（见 scripts/dev/SpawnBoundsProbe.gd）。
static func spawn_pos(visible: Rect2, margin: float, side: int, r1: float, r2: float) -> Vector2:
	var inner := visible.grow(-margin)
	var x := lerpf(inner.position.x, inner.end.x, r1)
	var y := lerpf(inner.position.y, inner.end.y, r2)
	match side:
		0:
			return Vector2(x, visible.position.y - margin)
		1:
			return Vector2(visible.end.x + margin, y)
		2:
			return Vector2(x, visible.end.y + margin)
		_:
			return Vector2(visible.position.x - margin, y)


## 给定窗口尺寸，推算 `stretch/mode=canvas_items` + `aspect=expand` 下的可视世界尺寸。
## 公式：scale = min(win_w/design_w, win_h/design_h)，可视尺寸 = 窗口尺寸 / scale。
## （已用实测数据验证：1600x720 → 1600x720；1024x768 → 1280x960。）
static func visible_size_for_window(win: Vector2) -> Vector2:
	if win.x <= 0.0 or win.y <= 0.0:
		return Vector2(VIEW_WIDTH, VIEW_HEIGHT)
	var scale := minf(win.x / VIEW_WIDTH, win.y / VIEW_HEIGHT)
	if scale <= 0.0:
		return Vector2(VIEW_WIDTH, VIEW_HEIGHT)
	return win / scale


## 升级项在指定波次的值。
static func upgrade_value(def: Dictionary, wave_num: int) -> float:
	var tiers: Array = def["tiers"]
	var idx := 0
	if wave_num >= 20:
		idx = 2
	elif wave_num >= 10:
		idx = 1
	return float(tiers[idx])


## 升级项的显示文本（例如 +12% / +5）。
static func upgrade_display(def: Dictionary, wave_num: int) -> String:
	var v := upgrade_value(def, wave_num)
	if def["pct"]:
		return "+%d%%" % roundi(v * 100.0)
	return "+%d" % roundi(v)


## 玩家造成伤害（H5 原式，修正 def 后等价）：
##   dmg = atk; if crit → round(dmg*critd); dmg = max(1, dmg - round(enemy_def*0.5))
static func player_damage(atk: int, crit: float, critd: float, enemy_def: int) -> Dictionary:
	var dmg := atk
	var is_crit := randf() < crit
	if is_crit:
		dmg = roundi(float(dmg) * critd)
	dmg = maxi(1, dmg - roundi(float(enemy_def) * 0.5))
	return {"dmg": dmg, "is_crit": is_crit}


## 玩家受到伤害（H5 原式）：
##   dmg = max(1, enemy_dmg - round(player_def*0.5))
static func incoming_damage(enemy_dmg: int, player_def: int) -> int:
	return maxi(1, enemy_dmg - roundi(float(player_def) * 0.5))
