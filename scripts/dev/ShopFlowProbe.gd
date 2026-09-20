extends SceneTree
## 门禁：商店流程（开商店 → 买 → 关商店 → 下一波）
##
## 断言：
##   1. 打开商店后：面板可见、状态机进 SHOP、整棵树暂停、抽到 4 件不重复商品、价格合法
##   2. 买一件：金币扣掉价格、对应属性真的变了（按物品效果键核对）
##   3. 买不起的卡是禁用状态（金币被压到不够时）
##   4. 离开商店：解除暂停、状态机回 FIGHTING、进入下一波
##
## 用法: godot --headless --path <项目> --script res://scripts/dev/ShopFlowProbe.gd
## 退出码 0=PASS 1=FAIL

var failures: Array[String] = []
var battle: Node = null
var phase := 0
var frames := 0
var gold_before := 0
var bought_id := ""
var bought_price := 0
var bought_index := -1
var bonus_before := {}


func _initialize() -> void:
	print("=".repeat(72))
	print(" 门禁：商店流程")
	print("=".repeat(72))


func _process(_delta: float) -> bool:
	frames += 1
	match phase:
		0:
			if frames < 3:
				return false
			var packed: PackedScene = load("res://scenes/battle/Battle.tscn")
			battle = packed.instantiate()
			root.add_child(battle)
			phase = 1
		1:
			# 等战斗真的跑起来（敌人出现 + 地面烘好）
			if battle.enemies.size() <= 0 and frames < 600:
				return false
			_phase_open()
			phase = 2
		2:
			_phase_check_open()
			phase = 3
		3:
			_phase_buy()
			phase = 4
		4:
			_phase_check_bought()
			phase = 5
		5:
			_phase_close()
			phase = 6
		6:
			_phase_check_closed()
			_report()
			return true
	return false


func _phase_open() -> void:
	battle.player.gold = 500
	battle._open_shop()


func _phase_check_open() -> void:
	var sp = battle.shop_panel
	if not sp.visible:
		failures.append("商店面板没有显示")
	if battle.state != battle.State.SHOP:
		failures.append("状态机未进入 SHOP（当前 %d）" % battle.state)
	if not paused:
		failures.append("打开商店时游戏没有被暂停 —— 选商品时还会挨打")
	print("  商店已打开：状态=SHOP 暂停=%s" % str(paused))

	var ids: Array = sp._ids
	if ids.size() != GameStats.SHOP_SLOTS:
		failures.append("商品数量 %d，应为 %d" % [ids.size(), GameStats.SHOP_SLOTS])
	var uniq := {}
	for id in ids:
		uniq[id] = true
		if not GameStats.ITEM_DEFS.has(String(id)):
			failures.append("抽到未定义的商品：%s" % id)
		else:
			var price := GameStats.shop_price(String(id), battle.player.shop_discount)
			if price <= 0:
				failures.append("商品 %s 价格非法：%d" % [id, price])
	if uniq.size() != ids.size():
		failures.append("商品重复上架：%s" % str(ids))
	print("  商品: %s" % str(ids))


func _phase_buy() -> void:
	gold_before = battle.player.gold
	var sp = battle.shop_panel
	for i in sp._ids.size():
		var id := String(sp._ids[i])
		var price: int = sp._prices[i]
		if gold_before >= price:
			# 只挑「效果落在 _bonus 上」的物品来核对属性变化
			var eff: Dictionary = GameStats.ITEM_DEFS[id]["effect"]
			var simple := true
			for k in eff.keys():
				if String(k) in ["gold", "gold_per_kill", "shop_discount", "xp_mul",
					"heal_pct", "reroll", "extra_card", "magnet_mul", "shield_flat", "resurrect"]:
					simple = false
			if not simple:
				continue
			bonus_before = {}
			for k in eff.keys():
				bonus_before[String(k)] = battle.player._bonus.get(String(k), 0.0)
			bought_id = id
			bought_price = price
			bought_index = i
			break
	if bought_id.is_empty():
		failures.append("500 金币居然买不起任何一件简单物品（定价失衡？）")
		return
	print("  购买：%s（$%d，金币 %d → ?）" % [bought_id, bought_price, gold_before])
	# 【必须走真实 UI 链路】卡片点击 → purchased 信号 → Battle 校验扣款。
	# 旧版直接调 battle._on_shop_purchased(...)，绕过了信号接线——
	# 结果接线断了门禁还全绿（真正的线上 bug 就是这么漏掉的）。
	battle.shop_panel._on_card_pressed(bought_index)


func _phase_check_bought() -> void:
	var after: int = battle.player.gold
	if after != gold_before - bought_price:
		failures.append("买完金币 %d，应为 %d（%d - %d）" % [
			after, gold_before - bought_price, gold_before, bought_price,
		])
	# 购买成功后该卡必须被锁（已售出、不可再点）——防止同一张卡反复购买
	if battle.shop_panel._sold[bought_index]:
		print("  卡片已锁定为「已售出」✓")
	else:
		failures.append("买完的卡没有被标记为已售出（可重复购买）")
	# 核对每个效果键的加成确实落上了
	var eff: Dictionary = GameStats.ITEM_DEFS[bought_id]["effect"]
	for k in eff.keys():
		var key := String(k)
		if key in ["gold", "gold_per_kill", "shop_discount", "xp_mul",
			"heal_pct", "reroll", "extra_card", "magnet_mul", "shield_flat", "resurrect"]:
			continue
		var before: float = float(bonus_before.get(key, 0.0))
		var now: float = float(battle.player._bonus.get(key, 0.0))
		if absf(now - before - float(eff[k])) > 0.001:
			failures.append("物品 %s 的效果 %s 没落上：%s → %s（应 +%.2f）" % [
				bought_id, key, before, now, float(eff[k]),
			])
	print("  金币 %d → %d；加成已核对" % [gold_before, after])

	# 买不起的卡应当是禁用的
	battle.player.gold = 0
	battle.shop_panel.refresh(0)
	var disabled_ok := true
	for i in battle.shop_panel._cards.size():
		if battle.shop_panel._sold[i]:
			continue
		if not battle.shop_panel._cards[i].disabled:
			disabled_ok = false
	if not disabled_ok:
		failures.append("金币为 0 时仍有可点击的商品卡")
	else:
		print("  金币 0 时商品卡全部禁用 ✓")
	battle.player.gold = after
	battle.shop_panel.refresh(after)


func _phase_close() -> void:
	battle.shop_panel.close()
	if battle.shop_panel._on_close.is_valid():
		battle.shop_panel._on_close.call()


func _phase_check_closed() -> void:
	if paused:
		failures.append("离开商店后游戏仍是暂停状态")
	if battle.state != battle.State.FIGHTING:
		failures.append("离开商店后状态机应为 FIGHTING（当前 %d）" % battle.state)
	if battle.wave_num != 2:
		failures.append("离开商店应进入第 2 波（当前 %d）" % battle.wave_num)
	print("  离开商店：状态=FIGHTING 当前波=%d 暂停=%s" % [
		battle.wave_num, str(paused),
	])


func _report() -> void:
	print("\n" + "=".repeat(72))
	if failures.is_empty():
		print(" RESULT=PASS 商店流程完整可用")
		quit(0)
	else:
		for m in failures:
			print(" FAIL: %s" % m)
		print(" RESULT=FAIL 失败项=%d" % failures.size())
		quit(1)
