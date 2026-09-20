extends SceneTree
## 临时只读脚本：导出全部模式的难度曲线 + 玩家成长对照（不改工程任何文件）。

func _initialize() -> void:
	print("# 难度曲线导出（真实调用 GameStats 函数）")
	print("# K=BOSS_HP_AVG_MUL=%d  WAVE_COUNT=%d  SPAWN_CAP=%d" % [
		GameStats.BOSS_HP_AVG_MUL, GameStats.WAVE_COUNT, GameStats.SPAWN_COUNT_CAP])
	print("# 满配敌人代价乘区：hp×%.2f dmg×%.2f" % [1.08 * 1.06, 1.08 * 1.06])
	print("# 升级：初始需 %d XP，每级 ×%.2f；经验 = 金币 × %d（harvest 1.0）" % [
		GameStats.START_XP_TO_NEXT, GameStats.XP_GROWTH, GameStats.XP_PER_GOLD])
	for diff in ["normal", "hard"]:
		GameSession.difficulty = diff
		var dd: Dictionary = GameStats.difficulty_def()
		print("=== DIFF=%s (hp×%.2f dmg×%.2f spawn×%.2f bossHP×%.2f) ===" % [
			diff, float(dd["hp_mul"]), float(dd["dmg_mul"]),
			float(dd["spawn_mul"]), float(dd["boss_hp_mul"])])
		print("wave\thp_s\tdmg_s\tspawn\tboss\tbossHP\tslimeHP\teliteHP\tavgGold\twaveXP\tcumXP\tlvl")
		var lvl := 1
		var xp := 0
		var need := GameStats.START_XP_TO_NEXT
		var cum := 0
		for w in range(1, 61):
			var bd: bool = GameStats.is_boss_wave(w)
			var boss_hp := 0
			if bd:
				var bt: String = GameStats.boss_type_for_wave(w)
				boss_hp = roundi(float(GameStats.enemy_template(bt)["hp"])
					* GameStats.hp_scale(w) * GameStats.boss_wave_hp_mul(w))
			# 池内平均金币（含 Boss 波额外一只 Boss 的金币/经验）
			var types: Array = GameStats.spawn_types(w)
			var gsum := 0.0
			for t in types:
				gsum += float(GameStats.enemy_template(String(t))["gold"])
			var avg_gold := gsum / maxf(1.0, float(types.size()))
			var wave_xp := roundi(float(GameStats.spawn_count(w)) * avg_gold
				* float(GameStats.XP_PER_GOLD))
			if bd:
				var bt2: String = GameStats.boss_type_for_wave(w)
				wave_xp += int(GameStats.enemy_template(bt2)["gold"]) * GameStats.XP_PER_GOLD
			cum += wave_xp
			xp += wave_xp
			while xp >= need:
				xp -= need
				lvl += 1
				need = roundi(float(need) * GameStats.XP_GROWTH)
			print("%d\t%.3f\t%.3f\t%d\t%s\t%d\t%d\t%d\t%.2f\t%d\t%d\t%d" % [
				w, GameStats.hp_scale(w), GameStats.dmg_scale(w),
				GameStats.spawn_count(w), "Y" if bd else "-", boss_hp,
				roundi(20.0 * GameStats.hp_scale(w)), roundi(360.0 * GameStats.hp_scale(w)),
				avg_gold, wave_xp, cum, lvl])
	GameSession.difficulty = "normal"
	quit(0)
