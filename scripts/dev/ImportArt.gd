extends SceneTree
## 美术资源导入管线：`美术资源\`（中文目录）→ `game\assets\`（ASCII 目录）
##
## 为什么要用 Godot 来跑而不是 Python：
##   这台机器没有 PIL，而 Godot 自带 Image API —— 用它处理能保证产物【一定是引擎读得动的格式】。
##
## 本脚本做四件事：
##   1. 【修错】源目录里有 3 个 `.png` 实际是 JPEG（魔数 ffd8ff，带 AIGC 元数据块）。
##      按内容嗅探格式再统一存成真 PNG —— 否则引擎按扩展名处理会出问题，且 AIGC 元数据会被带进包。
##   2. 【改名】中文目录/文件名 → ASCII（沿用 H5 版 qclaw\art 的命名，两边可对照）。
##   3. 【缩放】源图是 1024x1024 / 512x512，但游戏里最大只显示到 ~256px。
##      按原尺寸上 GPU 约需 112 MB 显存 —— 移动端不可接受。按显示需求缩到合理尺寸。
##   4. 【校验】重新读回每张产物，断言尺寸与格式正确。
##
## 源目录只读，不改动。
##
## 用法:
##   godot --headless --path <项目> --script res://scripts/dev/ImportArt.gd

const SRC_ROOT := "C:/Users/10201/Desktop/Roguelike/美术资源"
const DST_ROOT := "C:/Users/10201/Desktop/Roguelike/game/assets"

## 目标尺寸（2026-09-20 清晰度升级：用户反馈主菜单/立绘/战斗人物发糊。
## 当初压到 256/128 是为移动端显存（原尺寸约 112MB）—— 移动端已决策缓做，
## 桌面端按「显示尺寸 ×1.3 余量」放宽；显存增量约 +20MB，pck 增量约 +6MB。
## 立绘选人页显示 400×420（源 1024）；战斗帧显示约 140 屏幕px@1080p（源 512）；
## 背景全屏 COVERED 拉伸（源 1920×1080，不再缩小）—— 全部不再放大显示。
const SIZE_CHARS := 512      # 选人页大立绘 400×420 + 缩略图
const SIZE_ENEMIES := 256
const SIZE_ANIM := 256       # 战斗帧显示约 140 屏幕px@1080p / 178@1440p
const SIZE_ITEMS := 128      # 商店图标约 64~96px
const SIZE_DROPS := 64       # 掉落物显示约 12~24px
const SIZE_UI := 128
const BG_SIZE := Vector2i(1920, 1080)   # 等于源图原尺寸（1920×1080），零缩放零再损
const GRASS_SIZE := Vector2i(512, 512) # 可平铺地面

## 角色/动画的 ASCII 名映射（与 qclaw\art 一致）
## ⚠️ 这里的 key 是【美术资源名】（美术目录/文件名），与 GameStats.CHARACTERS[].name
## （界面显示名，如「嘉豪 / 学习嘉豪 / 金融嘉豪 / 忧郁嘉豪」）**解耦**。
## 2026-09-21 角色改名时本表刻意未动 —— 美术资源没跟着改名前，改这里会断导入。
const CHAR_MAP := {
	"基础嘉豪": "basic",
	"学习豪": "study",
	"金融豪": "finance",
	"忧郁豪": "sad",
	"土豆": "potato",
	"袋鼠怪": "kangaroo",
}
const ANIM_ENEMY_MAP := {
	"肥嘟嘟袋鼠怪": "feidaduo",
	"袋鼠大王Boss": "boss",
}

var _failures: Array[String] = []
var _rows: Array = []
var _repairs: Array[String] = []
var _src_bytes := 0
var _dst_bytes := 0


## 修复「深色部分被误抠成半透明」的损坏 —— 这批动画帧真实踩过的坑。
##
## 【成因】原生产脚本 `_anim_process.py` 从【左上角 12x12】采样背景色。
##   但动画帧送到它手上时，左上角已经是【完全透明】的（RGBA=0,0,0,0），
##   于是采到的背景色是【纯黑】。而「嘉豪」穿的是黑卫衣、戴黑口罩、兜帽拉起 ——
##   身上的黑与背景色同色，距离≈0 → 被判定为背景 → alpha 被压到 1~63。
##   结果：整帧人物变成近乎透明的「幽灵」。
##   （学习嘉豪颜色多、肥嘟嘟袋鼠怪是明黄，都没事，所以问题只在部分帧上。）
##
## 【为什么能修】损坏只发生在 alpha 上，RGB 与轮廓都完好：
##   低 alpha（1~63）像素数量 ≫ 高 alpha（>=200）像素数量 —— 健康帧恰好相反。
##   而真正的背景 alpha 恒为 0。所以「a>0 即应不透明」这条规则能精确还原轮廓。
##
## 【判定规则】low/high > 1.0 视为损坏。实测健康帧该比值 ≈ 0.08~0.11，
##   损坏帧（嘉豪）≈ 9。差距两个数量级，判定非常稳。
func _repair_dark_alpha(img: Image) -> Dictionary:
	img.convert(Image.FORMAT_RGBA8)
	var w := img.get_width()
	var h := img.get_height()
	var data := img.get_data()
	var low := 0
	var high := 0
	for i in w * h:
		var a := data[i * 4 + 3]
		if a > 0 and a < 64:
			low += 1
		elif a >= 200:
			high += 1
	if high <= 0 or float(low) / float(high) <= 1.0:
		return {"repaired": false, "low": low, "high": high}
	# 恢复：非零 alpha 一律拉满；0 保持 0（背景）
	for i in w * h:
		var o := i * 4 + 3
		if data[o] > 0:
			data[o] = 255
	img.set_data(w, h, false, Image.FORMAT_RGBA8, data)
	return {"repaired": true, "low": low, "high": high}


func _initialize() -> void:
	print("=".repeat(78))
	print(" 美术资源导入：%s" % SRC_ROOT)
	print("            →  %s" % DST_ROOT)
	print("=".repeat(78))

	_import_chars()
	_import_enemies()
	_import_drops()
	_import_items()
	_import_ui()
	_import_bg()
	_import_anim()

	print("\n" + "=".repeat(78))
	print(" 逐项结果（源尺寸 → 目标尺寸）")
	print("=".repeat(78))
	for r in _rows:
		print("  %-34s %-11s → %-11s %7.0f KB → %6.0f KB  [%s]" % [
			r["dst"], r["src_size"], r["dst_size"],
			r["src_kb"], r["dst_kb"], r["fmt"],
		])

	print("\n" + "=".repeat(78))
	print(" 汇总")
	print("=".repeat(78))
	print("  文件数        : %d" % _rows.size())
	print("  源合计        : %.1f MB" % (_src_bytes / 1048576.0))
	print("  产物合计      : %.1f MB" % (_dst_bytes / 1048576.0))

	if not _repairs.is_empty():
		print("\n  修复了 %d 个「深色被误抠成半透明」的损坏帧：" % _repairs.size())
		for r in _repairs:
			print("    · %s" % r)
		print("  （成因与修法见本脚本 _repair_dark_alpha 的注释；根治办法是重出这批图，")
		print("    出图时用【纯白不透明背景】，不要交透明底的 PNG。）")

	if _failures.is_empty():
		print("  RESULT=PASS")
		quit(0)
	else:
		print("  失败 %d 项：" % _failures.size())
		for m in _failures:
			print("    FAIL: %s" % m)
		print("  RESULT=FAIL")
		quit(1)


# ---------------------------------------------------------------- 分组导入
func _import_chars() -> void:
	for cn in CHAR_MAP.keys():
		_one("角色/%s.png" % cn, "chars/%s.png" % CHAR_MAP[cn], SIZE_CHARS, SIZE_CHARS, true)


func _import_enemies() -> void:
	_one("敌人/史莱姆小怪.png", "enemies/slime.png", SIZE_ENEMIES, SIZE_ENEMIES, true)
	_one("敌人/肥嘟嘟袋鼠怪.png", "enemies/feidaduo.png", SIZE_ENEMIES, SIZE_ENEMIES, true)
	_one("敌人/外卖袋鼠精英.png", "enemies/elite.png", SIZE_ENEMIES, SIZE_ENEMIES, true)
	_one("敌人/袋鼠大王Boss.png", "enemies/boss.png", SIZE_ENEMIES, SIZE_ENEMIES, true)
	# ---- 2026-09-20 新敌人批次（源图 256×256 真透明，规格与 SIZE_ENEMIES 一致，零缩放）----
	_one("敌人/rat.png", "enemies/rat.png", SIZE_ENEMIES, SIZE_ENEMIES, true)
	_one("敌人/student.png", "enemies/student.png", SIZE_ENEMIES, SIZE_ENEMIES, true)
	_one("敌人/charger.png", "enemies/charger.png", SIZE_ENEMIES, SIZE_ENEMIES, true)
	_one("敌人/ox.png", "enemies/ox.png", SIZE_ENEMIES, SIZE_ENEMIES, true)
	_one("敌人/splitter.png", "enemies/splitter.png", SIZE_ENEMIES, SIZE_ENEMIES, true)
	_one("敌人/bomber.png", "enemies/bomber.png", SIZE_ENEMIES, SIZE_ENEMIES, true)
	_one("敌人/slacker.png", "enemies/slacker.png", SIZE_ENEMIES, SIZE_ENEMIES, true)
	_one("敌人/monitor.png", "enemies/monitor.png", SIZE_ENEMIES, SIZE_ENEMIES, true)
	_one("敌人/boss_pua.png", "enemies/boss_pua.png", SIZE_ENEMIES, SIZE_ENEMIES, true)


func _import_drops() -> void:
	_one("掉落物/金币.png", "drops/gold.png", SIZE_DROPS, SIZE_DROPS, true)
	_one("掉落物/血瓶.png", "drops/hp.png", SIZE_DROPS, SIZE_DROPS, true)
	_one("掉落物/经验宝石.png", "drops/xp.png", SIZE_DROPS, SIZE_DROPS, true)


func _import_items() -> void:
	_one("道具/袋鼠头盔.png", "items/helmet.png", SIZE_ITEMS, SIZE_ITEMS, true)
	_one("道具/电动车.png", "items/scooter.png", SIZE_ITEMS, SIZE_ITEMS, true)
	_one("道具/野生狗奶.png", "items/milk.png", SIZE_ITEMS, SIZE_ITEMS, true)
	_one("道具/MJ蛛丝手套.png", "items/mj_gloves.png", SIZE_ITEMS, SIZE_ITEMS, true)


func _import_ui() -> void:
	_one("UI/道具槽空框.png", "ui/slot_empty.png", SIZE_UI, SIZE_UI, true)


func _import_bg() -> void:
	# 这三张源文件其实是 JPEG（无 alpha、有损）。
	# 若按 PNG 无损重编码，体积会【不降反升】（实测 1143KB → 2375KB）——
	# 有损源做无损重编码纯粹是白涨体积，恢复不了任何质量。
	# 所以两张全屏背景改用【有损 WebP】；草地图保持 PNG，因为它是平铺纹理，
	# 有损压缩会在平铺接缝处产生可见块状伪影。
	_one("背景/标题画面.png", "bg/title.webp", BG_SIZE.x, BG_SIZE.y, false, "webp")
	_one("背景/角色选择界面.png", "bg/charsel.webp", BG_SIZE.x, BG_SIZE.y, false, "webp")
	_one("背景/草地地面.png", "bg/grass.png", GRASS_SIZE.x, GRASS_SIZE.y, false)


func _import_anim() -> void:
	for cn in CHAR_MAP.keys():
		var ascii: String = CHAR_MAP[cn]
		_anim_dir("动画/%s" % cn, "anim/%s" % ascii, 4, 6)
	for cn in ANIM_ENEMY_MAP.keys():
		var ascii2: String = ANIM_ENEMY_MAP[cn]
		_anim_dir("动画/敌人/%s" % cn, "anim/enemies/%s" % ascii2, 4, 0)


func _anim_dir(src_sub: String, dst_sub: String, idle_count: int, run_count: int) -> void:
	# 新角色的动画帧可能还没从美术侧生成（豆包排队中）。整目录缺失时优雅跳过：
	# push_warning 一次、不计入 _failures（不把整条管线打成红），美术就位后重跑即可。
	# 现有 4 角色的目录恒存在 → 行为逐位不变。
	var d := DirAccess.open(SRC_ROOT)
	if d == null or not d.dir_exists(src_sub):
		push_warning("ImportArt: 动画源目录缺失，跳过：%s（美术就位后重跑管线补齐）" % src_sub)
		return
	for i in idle_count:
		_one("%s/idle/idle_%d.png" % [src_sub, i], "%s/idle/idle_%d.png" % [dst_sub, i],
			SIZE_ANIM, SIZE_ANIM, true)
	for i in run_count:
		_one("%s/run/run_%d.png" % [src_sub, i], "%s/run/run_%d.png" % [dst_sub, i],
			SIZE_ANIM, SIZE_ANIM, true)


# ---------------------------------------------------------------- 单张处理
func _one(src_rel: String, dst_rel: String, tw: int, th: int, want_alpha: bool,
		out_fmt: String = "png") -> void:
	var src_abs := SRC_ROOT.path_join(src_rel)
	var dst_abs := DST_ROOT.path_join(dst_rel)

	if not FileAccess.file_exists(src_abs):
		_failures.append("源文件不存在：%s" % src_abs)
		return

	var raw := FileAccess.get_file_as_bytes(src_abs)
	if raw.is_empty():
		_failures.append("读不到内容：%s" % src_abs)
		return
	_src_bytes += raw.size()

	# ---- 1. 按【内容】嗅探真实格式 ----
	var img := Image.new()
	var fmt := "?"
	var err := ERR_FILE_UNRECOGNIZED
	if raw.size() > 8 and raw[0] == 0x89 and raw[1] == 0x50:
		err = img.load_png_from_buffer(raw); fmt = "PNG"
	elif raw.size() > 3 and raw[0] == 0xFF and raw[1] == 0xD8:
		err = img.load_jpg_from_buffer(raw); fmt = "JPEG冒充PNG"
	elif raw.size() > 12 and raw[4] == 0x46 and raw[8] == 0x57:
		err = img.load_webp_from_buffer(raw); fmt = "WebP"
	else:
		_failures.append("无法识别的图片格式：%s（前4字节 %02X%02X%02X%02X）" % [
			src_rel, raw[0], raw[1], raw[2], raw[3],
		])
		return
	if err != OK:
		_failures.append("解码失败(%d)：%s" % [err, src_rel])
		return

	var src_size := "%dx%d" % [img.get_width(), img.get_height()]

	# ---- 2. 统一像素格式 ----
	if want_alpha:
		img.convert(Image.FORMAT_RGBA8)
	else:
		img.convert(Image.FORMAT_RGB8)

	# ---- 3. 缩放（Lanczos 高质量降采样）----
	if img.get_width() != tw or img.get_height() != th:
		img.resize(tw, th, Image.INTERPOLATE_LANCZOS)

	# ---- 3b. 修复「深色被误抠成半透明」的损坏（详见 _repair_dark_alpha）----
	# 必须在【缩放之后、落盘之前】：放在落盘后面改的是内存副本，文件早写完了 —— 这个坑踩过一次。
	if want_alpha:
		var rep := _repair_dark_alpha(img)
		if rep["repaired"]:
			_repairs.append("%s（低alpha %d → 高alpha %d）" % [
				dst_rel, rep["low"], rep["high"],
			])

	# ---- 4. 落盘（并把另一种扩展名的旧产物删掉，避免残留两份）----
	DirAccess.make_dir_recursive_absolute(dst_abs.get_base_dir())
	var others: Array[String] = []
	if out_fmt == "webp":
		others = [dst_abs.get_basename() + ".png"]
	else:
		others = [dst_abs.get_basename() + ".webp"]
	for o in others:
		if FileAccess.file_exists(o):
			DirAccess.remove_absolute(o)
			print("  （清掉旧格式残留：%s）" % o)

	if out_fmt == "webp":
		err = img.save_webp(dst_abs, true, 0.92)   # 有损，质量 0.92（2026-09-20 清晰度升级 0.9→0.92）
	else:
		err = img.save_png(dst_abs)
	if err != OK:
		_failures.append("写出失败(%d)：%s" % [err, dst_abs])
		return

	var expect_fmt := Image.FORMAT_RGB8 if not want_alpha else Image.FORMAT_RGBA8
	if img.get_format() != expect_fmt:
		_failures.append("内部格式异常：%s" % dst_rel)

	# ---- 5. 读回校验 ----
	var check := Image.new()
	if check.load(dst_abs) != OK:
		_failures.append("产物读不回：%s" % dst_abs)
		return
	if check.get_width() != tw or check.get_height() != th:
		_failures.append("产物尺寸不符：%s 期望 %dx%d 实际 %dx%d" % [
			dst_rel, tw, th, check.get_width(), check.get_height(),
		])
		return
	if want_alpha and not check.detect_alpha():
		# 新角色立绘源图是【满幅不透明底】（AIGC 直出，没抠图）。
		# 不把它打成管线失败：立绘照样落盘并计入清单（选人页显示为一张方卡，无破图），
		# 只警告不红 —— 美术重出透明底图后重跑管线，这里会自动恢复静默。
		# 现有 4 角色（已抠图）恒有 alpha，永远走不到这个分支，行为逐位不变。
		push_warning("ImportArt: 立绘源图不带透明通道（满幅底图）：%s —— 待美术抠图后重跑管线" % src_rel)
	if not want_alpha and check.detect_alpha():
		_failures.append("不透明图却带了 alpha 通道：%s" % dst_rel)
		return

	var dst_bytes := FileAccess.get_file_as_bytes(dst_abs).size()
	_dst_bytes += dst_bytes
	_rows.append({
		"dst": dst_rel,
		"src_size": src_size,
		"dst_size": "%dx%d" % [tw, th],
		"src_kb": raw.size() / 1024.0,
		"dst_kb": dst_bytes / 1024.0,
		"fmt": fmt,
	})
