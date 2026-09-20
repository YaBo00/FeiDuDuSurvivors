# 肥嘟嘟幸存者（Godot 版）

类《吸血鬼幸存者 / 土豆兄弟》的移动端割草 Roguelike。
走位 + 自动攻击，20 波 + 波末升级 / 商店 + Boss（规划中）。

> 环境部署说明见 `..\docs\handoff\Godot环境就绪说明_2026-09-18.md`；
> 交付与验证记录见 `..\docs\handoff\垂直切片交付说明_2026-09-18.md`；
> **项目结构分区方案见 `..\docs\项目结构规划_2026-09-19.md`**。这里只放速查。

---

## 快速开始

| 我想… | 怎么做 |
|---|---|
| 打开编辑器 | 双击 **`tools/open_editor.cmd`** |
| 直接跑游戏 | 双击 **`tools/run_game.cmd`** |
| 打包发人 | 双击 **`tools/export_windows.cmd`** |
| 编辑器内运行 | `F5` 运行主场景 · `F6` 运行当前场景 · `R` 重开一局 · `Esc` 退出 |
| **改完立刻查语法** | 双击 **`tools/check.cmd`**（或 `bash tools/check.sh`），几秒出结果，82 个文件全编译 |
| 验证工程是否被改坏 | 双击 **`tools/run_gates.cmd`**（或 `bash tools/run_gates.sh`），显示 ALL GATES PASS 才算好（13 项，约 5 分钟） |
| 四角色验收（里程碑） | 双击 **`tools/gates_chars.cmd`**（或 `bash tools/gates_chars.sh`）—— **六个**角色各跑一遍 20 波，约 10 分钟 |

```bash
# 一键跑完全部门禁（推荐）—— Windows 双击 tools/run_gates.cmd，或命令行跑脚本
bash tools/run_gates.sh

P="C:/Users/10201/Desktop/Roguelike/game"
B="res://scenes/battle/Battle.tscn"    # 主场景已是标题画面，战斗相关门禁要显式指定场景

# [1] 语法门（加载主场景 → 编译到所有脚本）
godot_console --headless --path "$P" --quit-after 5
# [2] 战斗主循环：无敌跑满 20 波（确定性流程门禁）
godot_console --headless --path "$P" "$B" -- --selftest
# [3] 失败结算路径
godot_console --headless --path "$P" "$B" -- --selftest-defeat
# [4] 菜单流程（标题 / 选角 / 选中角色进战斗）
godot_console --headless --path "$P" --script res://scripts/dev/MenuFlowProbe.gd
# [5] 美术资源规格      [6] 美术资源接线
godot_console --headless --path "$P" --script res://scripts/dev/AssetProbe.gd
godot_console --headless --path "$P" --script res://scripts/dev/SpriteWiringProbe.gd
# [7] 刷怪边界（出生点在可视区外、竞技场居中）   [8] 掉落物寿命 + 环境链路
godot_console --headless --path "$P" --script res://scripts/dev/SpawnBoundsProbe.gd
godot_console --headless --path "$P" --script res://scripts/dev/_ProbePickupExpiry.gd
godot_console --headless --path "$P" res://scenes/dev/EnvCheck.tscn -- --selftest

# 难度观测（不是门禁）：带真实伤害的自动驾驶跑，逐波打印压力曲线
godot_console --headless --path "$P" "$B" -- --balance

# 改了资源后刷新导入 / 导出
godot_console --headless --path "$P" --import
godot_console --headless --path "$P" --export-release "Windows Desktop" "build/windows/FeiDuDuSurvivors.exe"
```

> **语法检查别只跑 `--import`**：它不编译被脚本引用的 `.gd`，语法错误会被漏掉
> （实测踩过：Player.gd 的 Parse Error 完全没暴露）。用门禁 [1] 的 `--quit-after` 才算数。

**为什么要跑宽屏那条**：刷怪与玩家边界如果按设计尺寸 1280×720 硬编码，在 20:9 手机
（可视区 1600×720）上敌人会刷在 x=1325 —— 而屏幕能显示到 1600，于是敌人**当着玩家的面凭空出现**。
门禁 4 就是守这个的（旧逻辑在非 16:9 下有一半出生点落在屏内）。

---

## 目录约定

顶层按类型分（scenes / scripts / assets / tools），中下层**按功能域分**：

| 目录 | 放什么 |
|---|---|
| `scenes/main/` | 流程壳：`Title.tscn`（**主场景**）、`CharSelect.tscn` |
| `scenes/battle/` | `Battle.tscn` —— 主战场，实例化实体与 UI 子场景 |
| `scenes/entities/` | 可复用实体：`Player` `Enemy` `Projectile` `Pickup` `Obstacle` |
| `scenes/ui/` | 界面：`Hud` `ShopPanel` `UpgradePanel` `ResultPanel` `PauseMenu` |
| `scenes/dev/` | 仅开发期用的场景（环境自检） |
| `scripts/app/` | 全局流程与跨场景状态（`GameSession.gd`） |
| `scripts/data/` | **单一数据源**：`Stats.gd`（数值）、`AssetDB.gd`（资源路径）。改数值/资源路径只改这里 |
| `scripts/battle/` | 战斗域：`Battle`（编排/状态机/取景/地面/UI 桥接）、`WaveDirector`（波次调度）、`CombatResolver`（战斗结算）、`Enemy` `Projectile` `Pickup` `Obstacle` `BattleFeedback` `DeathBurst` |
| `scripts/player/` | 玩家域：`Player`（基础属性 + 角色特性 + 武器参数接入） |
| `scripts/ui/` | 界面脚本（与 `scenes/ui/` 大体一一对应） |
| `scripts/core/` | 通用设施：`Anim2D` `UiFont` `UiTheme` `GameAudio` |
| `scripts/dev/` | 开发期探针 / 门禁 / 导入工具。⚠️ **注意**：导出用 `export_filter="all_resources"`，这些脚本**会一起打进 pck**（约几百 KB）。要排除需单独配 `exclude_filter`，但 `mcp_interaction_server.gd` 是 autoload **绝不能排除** —— 改这项请单独验证 |
| `tools/` | 启动器与门禁脚本（`.sh` / `.cmd`）。**一律以自身所在目录的上级为工程根** |
| `assets/` | 美术资源，**路径全 ASCII**（由 `ImportArt.gd` 从 `..\美术资源\` 生成） |
| `build/` | 导出产物 |
| `.godot/` | **引擎缓存，不要提交、不要手改、不要删** |

### 美术资源

`assets/` 由 `scripts/dev/ImportArt.gd` 从 `..\美术资源\`（中文目录，只读）生成，
命名对齐 H5 版 `qclaw\art`。**不要手改 `assets/` 里的文件** —— 改源头再重跑管线：

```bash
godot_console --headless --path "$P" --script res://scripts/dev/ImportArt.gd   # 重新导入
godot_console --headless --path "$P" --script res://scripts/dev/AssetProbe.gd  # 验规格
godot_console --headless --path "$P" --script res://scripts/dev/SpriteWiringProbe.gd  # 验接线
```

| 子目录 | 内容 | 尺寸 |
|---|---|---|
| `chars/` | 角色立绘 | 256² |
| `enemies/` | 敌人立绘 | 256² |
| `anim/` | 序列帧（已统一脚底对齐） | 128² |
| `drops/` | 掉落物图标 | 64² |
| `items/` | 道具图标 | 128² |
| `ui/` | UI 元件 | 128² |
| `bg/` | 背景（全屏为有损 WebP，平铺地面为 PNG） | 1600×900 / 512² |

**两条容易踩的**：
1. 精灵的 `scale` / `offset.y` 由 `AssetDB.fit()` 依据**实测内容包围盒**算出，让脚底正好落在节点原点上。
   **美工重出图后必须用 `ContentBoxProbe.gd` 重量并更新 `AssetDB`**，否则精灵会浮空或嵌进地里。
2. 外部 AI 生图给的 `.png` **可能是 JPEG**（实测遇到过 3 个）。别信扩展名，按魔数验真 ——
   `ImportArt.gd` 已按内容嗅探格式。

---

## 环境要点（别踩）

- 引擎：**Godot 4.7.2-stable（标准版 / GDScript）**，装在 `C:\111SoftWare\Godot\`
- 渲染后端：`gl_compatibility` —— 本机显卡驱动较旧（NVIDIA 517.00），且目标平台是移动端，别随手改成 Forward+
- 纹理过滤：**`Linear Mipmap`**。美术是 Q 版平涂卡通（不是像素画），256px 的图在屏幕上只画约 56px，
  用 `Nearest` 会锯齿+抖动。**别改回 `Nearest`**；将来若真加像素画资源，在那些节点上单独覆盖 `texture_filter`
- 输入映射：`move_left/right/up/down`（WASD + 方向键）、`use_item`（空格）、`pause`（Esc）
- 存档目录：`C:\Users\10201\AppData\Roaming\FeiDuDuSurvivors\`（故意用 ASCII 名）
- **`.cmd` 文件必须 CRLF 行尾 + 纯 ASCII**，否则 cmd.exe 解析错位（仓库暂未启用 git，靠人守这条）
- **Godot 内置字体不含中文**，UI 统一走 `scripts/core/UiFont.gd`（微软雅黑回落）

---

## 取景与坐标系（改这块前先读）

工程用 `stretch/mode=canvas_items` + `aspect=expand`，所以**可视世界尺寸随窗口宽高比变化**。
实测（从场景内节点取 `get_viewport().get_visible_rect()`）：

| 窗口 | 可视世界尺寸 |
|---|---|
| 1280×720 (16:9) | 1280×720 |
| 1600×720 (20:9 手机) | **1600×720** |
| 1024×768 (4:3) | **1280×960** |

约定：

- **竞技场固定 1280×720**（`GameStats.arena_rect()`），不随窗口变 —— 保证不同设备手感与难度一致。
  玩家被 `_clamp_to_arena()` 限制在这个矩形内。
- **`Battle` 里有一个 `Camera2D`，固定对准竞技场中心**（`ARENA_CENTER`）。
  这样在任意宽高比下竞技场都**居中**，而不是像没有相机时那样贴在左上角。
  它同时提供 `Battle.shake()` 受击震屏（抖 `Camera2D.offset`，纯视觉，不参与判定）。
- **刷怪位置必须用实际可视区**（`Battle.visible_world_rect()`），不能硬编码设计尺寸。
  否则 20:9 手机上敌人会刷在屏幕内、当着玩家的面凭空出现。门禁 4 守这条。
- **`Background` 在 `BackgroundLayer`（CanvasLayer, layer=-1）里**，是屏幕空间。
  别把它挪回 Node2D 画布 —— 那样它会随相机平移，宽屏上两边露出未覆盖区域。
- 非 16:9 时竞技场外会露出背景色，`Battle._draw()` 画了一圈**竞技场边界线**，
  让「看不见的墙」可见。
- **竞技场地面用「瓦片拼接」**（2026-09-19 背景二调 / 三调换素材 / 四调压场）：同一张主题贴图
  （`assets/bg/{主题id}.png`，**2048×2048 居中徽章式方图**）复制成
  `FLOOR_TILE_COLS`×`FLOOR_TILE_ROWS`（当前 **2×2 = 4 块**，每格 1280×720 世界单位）份，
  按网格精确相邻铺满 `arena_rect()`。这**不是**把原图切成碎片。
  - 瓦片矩形由 `GameStats.floor_tile_rects()`（参数化，任意 cols/rows ≥ 1 均无缝无叠）
	在**世界空间**推导，不依赖相机/视口 ⇒ 缩放与平移时自动正确；
	`Battle.floor_tile_rects()` 透传同一函数、`_draw()` 即用它循环绘制。
  - **取图区域**由 `GameStats.floor_tile_src_rect()` 给出：按瓦片格宽高比从贴图**中心**
	裁出最大内接矩形。行列相等时格子仍是 16:9 ⇒ 2048² 裁成 2048×1152，
	**每块等比缩放、零变形**。⚠️ 若把方图直接塞进 16:9 格子，菱形地砖会被
	横向拉扁 1.78 倍。贴图本身与格子同比例时返回整张贴图（旧 1920×1080 素材逐像素不变）
	—— 所以地面绘制**对素材宽高比免疫**，以后再换图不用改绘制逻辑。
  - 调 `FLOOR_TILE_COLS/ROWS` 改拼接密度（**都设 1 即一键退回旧的「整张铺满」**）。
	2×2 是四调定的（对应用户反馈"线条太复杂、头晕"）：每格 1280×720 世界单位 = **正好 2 屏**，
	纹素密度 1.6/世界单位 = 屏幕 **0.8 纹素/像素（微放大）** ⇒ 细线不再落在奈奎斯特附近、
	平移时不再闪烁；每屏线数也比 3×3 少约 1/3。**不建议低于 2**（会明显发糊）。
  - **地面压场**（四调新增，治眩晕；数据在 `GameStats.FLOOR_THEMES` 的 `grade`/`veil`）：
	`grade` 是绘制时的 modulate，把各主题平均亮度**归一到 0.38 一档**
	（实测原值差 3 倍：陶瓷 0.28 ↔ 大理石 0.83，每 4 波一次整屏亮度突变）；
	`veil` 是叠在地面上的柔化纱，颜色 = **该主题自身的平均色**，因此**只压对比、不动色调**；
	alpha **按实测对比度 σ 分配**（σ 小的云石/陶瓷 0.28~0.30，σ≈43 的钢铁/鎏金 0.45）——
	本来就安静的主题不被洗白，最"吵"的两个被重点压住。
	数值来历见 `Stats.gd`「地面压场」段落的实测表，**不要凭手感改**。
  - ⚠️ 5 套地面素材是**用户直供**（不在 `美术资源/`、ImportArt 管线不管它们）。
	**换图后必须跑一次 `--import`**，否则 `.godot` 缓存里仍是旧图 ——
	`AssetProbe` 会照旧报旧尺寸、门禁全绿，但游戏里根本看不到新图（2026-09-19 实测踩到）。
	换图后还要按上面的实测表**重算 `grade`/`veil`**，否则亮度归一与对比压缩会失准。
- **虚拟摇杆（批次四 4a+4b）**：`scripts/ui/TouchControls.gd`（CanvasLayer，代码建节点）。
	- **浮动摇杆**：手指按在**屏幕左半边**任意位置 → base 锚定到该点；拖动跟手、偏移钳制在
		`TOUCH_MAX_RADIUS`（110px）内；抬起即清零。只跟踪**第一根**手指（`_touch_index`）。
	- 方向出口只有一个：`move_dir()`（长度 ≤ 1，未触摸恒为 `Vector2.ZERO`）。
		`Battle` 每帧把它注入 `Player.set_touch_dir()`，Player 在键盘向量之后**叠加**、
		合成超过 1 才归一 —— `_touch_dir` 为零时与纯键盘行为**逐位一致**（回归红线，门禁 [2][3] 守着）。
	- **可见性**：`DisplayServer.is_touchscreen_available()` 或命令行 `--touch`（桌面调试/探针用）。
		桌面默认隐藏，纯键盘体验不变。纹理缺失时整块自禁用（回落设计）。
	- 摇杆美术 `assets/ui/joystick_base.png` / `joystick_knob.png`（128×128）已登记进 `AssetDB.UI` + `EXPECT`。
- **正式中文字体（批次四 4c）**：`assets/fonts/main_font.ttf`（**子集字体，577KB**）。
	- 来源：霞鹜文楷 LXGWWenKai-Regular v1.522（**SIL OFL 1.1，可商用**），完整字体 24.4MB；
		用 `docs/review/make_font_subset.py` 只保留游戏源码实际用到的字形 → 577KB。
		授权文本在同目录 `OFL.txt`（OFL 要求随字体分发，必须保留）。
	- **零代码接入**：`UiFont.gd` 的 `BUNDLED_FONT` 本来就指向这个路径，存在即用、缺失回落系统字体。
	- ⚠️ **加了新的中文/全角文案必须重跑** `make_font_subset.py` 再 `--import`，
		否则新字符渲染成豆腐块 —— 门禁 **[17/17] `_ProbeFont.gd`** 会扫描源码全部非 ASCII 字符
		逐个断言字形覆盖，加字不重跑必红（不可见修饰符 U+FE00~FE0F / U+200B~200F 除外）。

---

## 开发期工具（`scripts/dev/`）

这些只在开发时用，**不是游戏本体的一部分**：

| 文件 | 用途 |
|---|---|
| `EnvCheck.gd` | 环境链路自检场景（编辑器/渲染/输入映射/物理/文件 IO） |
| `SpawnBoundsProbe.gd` | 门禁：刷怪出生点必须在实际可视区之外、竞技场居中 |
| `_ProbePickupExpiry.gd` | 门禁：掉落物 8 秒寿命真的在走（`Pickup.advance()` 被调用） |
| `_ProbeCharTraits.gd` | 门禁：**六角色**武器表 + 特性（**176** 条确定性断言，含「非本角色应为默认值」交叉对照 + 6 人 DPS 预算回归护栏） |
| `_ProbeRangedBoss.gd` | 门禁：远程怪开火 / 敌弹命中 / Boss 路由与可击杀 |
| `_ProbeAudio.gd` | 门禁：10 个音效可加载 + **BGM 是循环 OGG**（并守 2MB 体积护栏，防退回未压缩 WAV） |
| `CheckAll.gd` | 语法门：编译全部脚本与场景（`tools/check.sh` 调它） |
| `MenuFlowProbe.gd` / `ShopFlowProbe.gd` | 门禁：菜单链路 / 商店真实点击购买链路 |
| `AssetProbe.gd` / `SpriteWiringProbe.gd` | 门禁：美术规格 / 运行时精灵接线 |
| `ImportArt.gd` / `SplitSheet.gd` / `ContentBoxProbe.gd` / `AlphaViewProbe.gd` | 美术导入管线（改资源源头后重跑） |
| `mcp_interaction_server.gd` | 给 godot-mcp 的运行时工具（截图等）提供本地 TCP 通道。**自带开关**，见下 |

### MCP 运行时通道（截图 / 注入输入 / 查询状态）

该脚本已在 `project.godot` 注册为 autoload，但**默认完全不启用**（不开端口、不轮询）：

```bash
# 想用截图等运行时工具时才加 --mcp
godot_console --path "C:/Users/10201/Desktop/Roguelike/game" -- --mcp
```

不传 `--mcp` 时它什么都不做 —— 正常游玩、导出的包、上面那些门禁自检都不会开这个口子。
完整说明见上一级目录 `GodotMCP配置说明_2026-09-18.md`。

---

## 当前阶段：20 波完整循环 + Boss + 商店 + 音频

核心循环已完整（不再是最初的 3 波切片）：

- 玩家：**6 个可选角色**（基础 / 学习 / 金融 / 忧郁嘉豪 + **土豆** / **袋鼠怪**）、**每人独立武器表 + 专属特性**、
  自动攻击最近敌人、**攻击距离门**、暴击、弹道穿透、受击无敌帧、经验升级、金币、吸血 / 闪避 / 回血等属性
- 角色特性：基础「新手保护·初心」（每局免死一次）、学习「题海精进」（每级 +3% 攻速）、
  金融「见钱眼开」（捡钱加速 + 商店 9 折）、忧郁「背水一战」（残血增伤最多 +40%）、
  土豆「越挫越勇」（受击叠甲 5 层，脱战 3 秒清零 —— 全队唯一护甲/回血，移速最慢）、
  袋鼠怪「停不下来」（持续移动叠移速/攻速 5 层，停下 1 秒清零 —— 移速/闪避最高，敢站桩就死）
- 武器：随手连弹（基准）/ 粉笔连射（2 发高频）/ 金币镖（穿透 5 + 命中掉钱）/ 暗影弹（贯穿 + 自带吸血）/
  薯块重弹（慢速重弹 radius 2.5）/ 蹦蹦拳（高频轻弹）
- 敌人：`Slime` / `Medium` / `Elite` / `Ranged`（远程点射）/ `Boss`（波 10、波 20，**三招技能**）
- 循环：30 秒一波 × 20 波 → 波末三选一升级 + 商店 → 通关 / 失败结算；**无尽模式**（`--endless`）波 20 后曲线继续爬
- 商店：26 件道具（折扣 / 加钱 / 多重箭 / 吸血等），波末开店
- 反馈：伤害飘字、击杀爆裂、hit-stop、震屏、波次横幅、5 套地面主题、音效 + BGM
- HUD：血条 / 波次倒计时 / 等级 / 金币 / **常驻属性面板**
- 输入：键盘（WASD/方向键）+ **虚拟摇杆**（触摸屏自动启用，桌面 `--touch` 调试）
- 字体：**子集中文字体**（577KB，霞鹜文楷 OFL；加新中文文案必须重跑 `docs/review/make_font_subset.py`，门禁 [17/17] 守着）

**未做**：批次五-1 的美术收尾（新角色动画帧已就位；若后续换形象按 `docs/美术需求_新角色_2026-09-19.md` 的规格来）。

### 下一步建议

1. **先 playtest 手感**：所有速度类数值都带 `[PLACEHOLDER]`（`SPATIAL_SCALE = 1.5` 是把 H5 的
   800×600 画布折算到 1280×720 的折中值），精灵显示尺寸系数 `DISPLAY_PX_PER_RADIUS = 3.1` 同样待校。
   六角色武器的调参旋钮见 `..\docs\playtest_checklist.md` 第八节。
2. **待决策**：~~GDD 写 5 个可玩角色，但美术只有 4 个角色立绘，两个口径要统一~~
   **2026-09-19 已结案：补到 6 人**（土豆 + 袋鼠怪，立绘/动画帧均已入库；
   设计与平衡依据见 `..\docs\角色设计_土豆与袋鼠怪_2026-09-19.md`）。
3. 补 Godot 侧单元测试：伤害公式边界、`recalc_stats` 幂等、升级池随波次取值、掉落过期。
4. 补主动道具、无尽模式、Boss 特殊技能。
5. ~~四角色特性与武器玩法~~ —— **2026-09-19 已完成**（设计契约
   `docs/design/人物设计_嘉豪四人组_2026-09-19.md`）。`Stats.gd` 新增 `WEAPON_DEFS` /
   `TRAIT_*` / `trait_id`；`Projectile` 加逐弹道 `pierce_cap`；`Player` 加 `damage_bonus()` /
   `money_speed_mul()` / `traits_enabled`；`CombatResolver` 的出膛与命中结算改读武器表。
   验证：`tools/gates_chars.sh` 四角色四连跑 + `_ProbeCharTraits.gd` 50 条断言。
6. ~~`Battle.gd` 再拆一刀~~ —— **2026-09-19 已完成**：抽出 `WaveDirector`（波次调度）与
   `CombatResolver`（战斗结算），Battle.gd 1238 → 740 行。
   拆的是**逻辑**不是**状态**：`enemies`/`projectiles`/`pickups`/`spawn_remaining` 等共享黑板
   刻意留在 `Battle` 上，因为 5 个门禁探针直接读写它们（`_ProbeRangedBoss` 还会**写**
   `spawn_remaining` 与 `projectiles`）。后续再拆请守住这条线，否则门禁会红。

### 命令行参数

| 参数 | 作用 |
|---|---|
| `--selftest` | 无敌 + 自动驾驶跑满 20 波，确定性流程门禁（`RESULT=PASS`） |
| `--selftest-defeat` | 确定性致死，验证失败结算路径（会**关闭角色特性**，否则初心吞掉致死） |
| `--balance` | 真实伤害的平衡观测（死不等于失败，只看压力曲线） |
| `--char <id>` | 指定角色：`basic` / `study` / `finance` / `sad`。必须在 `start_run()` 前解析 |
| `--endless` | **无尽模式**：打满 20 波不结算，曲线继续爬（血量/伤害斜率 ×1.6、投放封顶 140、每 10 波一只 Boss），靠阵亡结束。与 `--selftest` 组合会跑 `ENDLESS_SELFTEST_WAVES`（40）波后收束（`RESULT=PASS`） |

例：`godot --headless --path game res://scenes/battle/Battle.tscn -- --selftest --char sad`
例（无尽自检）：`godot --headless --path game res://scenes/battle/Battle.tscn -- --selftest --endless`
