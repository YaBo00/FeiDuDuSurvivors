extends SceneTree
# 模拟 Godot 项目管理器的项目扫描逻辑，输出它「应该」看到什么。
# 运行：Godot_v4.7.2-stable_win64_console.exe --headless --script res://scripts/dev/SimulateProjectManager.gd

func _initialize() -> void:
	var out: Array[String] = []
	out.append("=== SIMULATE PROJECT MANAGER ===")

	# --- 1. 定位 projects.cfg（与引擎一致：OS.get_data_dir() 的父级 + Godot） ---
	var roaming := OS.get_environment("APPDATA")
	var cfg_path := roaming.path_join("Godot").path_join("projects.cfg")
	out.append("cfg_path = %s" % cfg_path)

	# --- 2. 读取 ---
	var cf := ConfigFile.new()
	var err := cf.load(cfg_path)
	out.append("ConfigFile.load err = %d (0=OK)" % err)
	if err != OK:
		out.append("RESULT=FAIL load_error")
		_dump(out)
		return

	# --- 3. 枚举登记项（项目管理器的判定逻辑） ---
	var keys := cf.get_section_keys("gd_project_manager")
	out.append("registered_count = %d" % keys.size())

	var visible := 0
	for raw_key in keys:
		var key := String(raw_key)
		var disp := String(cf.get_value("gd_project_manager", raw_key, ""))
		out.append("--- entry ---")
		out.append("  raw_key = <<<%s>>>" % key)
		out.append("  display = <<<%s>>>" % disp)

		# 引擎内部用 ProjectSettings 的规范化路径比对
		var norm := key.replace("\\", "/")
		while norm.ends_with("/"):
			norm = norm.substr(0, norm.length() - 1)
		out.append("  normalized = <<<%s>>>" % norm)

		var proj_file := norm.path_join("project.godot")
		var dir_ok := DirAccess.dir_exists_absolute(norm)
		var file_ok := FileAccess.file_exists(proj_file)
		out.append("  dir_exists = %s" % dir_ok)
		out.append("  project.godot exists = %s" % file_ok)
		out.append("  project.godot raw = %s" % proj_file)

		if not dir_ok or not file_ok:
			out.append("  VERDICT = MISSING (会显示『缺失项目』)")
			continue

		# 尝试解析 project.godot，取 config/name
		var pcf := ConfigFile.new()
		var perr := pcf.load(proj_file)
		out.append("  project.godot parse err = %d (0=OK)" % perr)
		if perr != OK:
			out.append("  VERDICT = IMPORT_ERROR (会显示『无法导入』)")
			continue

		var pname := String(pcf.get_value("application", "config/name", ""))
		out.append("  config/name = <<<%s>>>" % pname)

		var features: Variant = pcf.get_value("application", "config/features", PackedStringArray())
		out.append("  config/features = %s" % str(features))

		var icon := String(pcf.get_value("application", "config/icon", ""))
		out.append("  config/icon = <<<%s>>>" % icon)
		if icon.begins_with("res://"):
			out.append("  icon file exists = %s" % ResourceLoader.exists(icon))

		out.append("  VERDICT = OK (应正常显示)")
		visible += 1

	out.append("visible_count = %d" % visible)
	out.append("RESULT=%s" % ("PASS" if visible > 0 else "FAIL no_visible_project"))
	_dump(out)


func _dump(lines: Array[String]) -> void:
	# 同时 print 和写盘，方便 PowerShell 落盘读取
	var text := "\n".join(lines)
	print(text)
	var f := FileAccess.open("user://sim_pm.txt", FileAccess.WRITE)
	if f:
		f.store_string(text)
		f.close()
	print("[WROTE] user://sim_pm.txt -> %s" % ProjectSettings.globalize_path("user://sim_pm.txt"))
	quit()
