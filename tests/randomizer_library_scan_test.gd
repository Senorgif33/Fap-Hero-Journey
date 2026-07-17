extends GdUnitTestSuite

# RandomizerLibrary — restim_axis coerce + sibling scan backfill.


var _tmp: String = ""
var _saved_entries: Array = []


func before_test() -> void:
	_tmp = "user://randomizer_scan_test_%d" % Time.get_ticks_usec()
	DirAccess.make_dir_recursive_absolute(_tmp)
	_saved_entries = RandomizerLibrary.get_all()
	# Soft-clear without wiping the shared content pool on disk.
	RandomizerLibrary._entries = []
	RandomizerLibrary.save_registry()


func after_test() -> void:
	_rm_rf(_tmp)
	SettingsService.set_restim_label("a", SettingsService.DEFAULT_RESTIM_LABEL_A)
	SettingsService.set_restim_label("b", SettingsService.DEFAULT_RESTIM_LABEL_B)
	SettingsService.save()
	RandomizerLibrary._entries = _saved_entries
	RandomizerLibrary.save_registry()
	RandomizerLibrary.library_changed.emit()


func _rm_rf(path: String) -> void:
	var d: DirAccess = DirAccess.open(path)
	if d == null:
		return
	d.list_dir_begin()
	var f: String = d.get_next()
	while f != "":
		var full: String = "%s/%s" % [path, f]
		if d.current_is_dir():
			_rm_rf(full)
		else:
			DirAccess.remove_absolute(full)
		f = d.get_next()
	d.list_dir_end()
	DirAccess.remove_absolute(path)


func _touch(name: String, body: String = "{}") -> String:
	var p: String = "%s/%s" % [_tmp, name]
	var fa: FileAccess = FileAccess.open(p, FileAccess.ModeFlags.WRITE)
	fa.store_string(body)
	fa.close()
	return p


func _minimal_funscript() -> String:
	return '{"actions":[{"at":0,"pos":0},{"at":1000,"pos":100}]}'


func test_coerce_legacy_axis_into_restim_shared() -> void:
	var e: Dictionary = RandomizerLibrary._coerce_entry(
		{"id": "x", "axis_src": {"pulse_frequency": "/p.funscript"}, "axis_rel": {}}
	)
	assert_str(str((e["restim_axis_src"]["shared"] as Dictionary)["pulse_frequency"])).is_equal(
		"/p.funscript"
	)
	assert_str(str((e["axis_src"] as Dictionary)["pulse_frequency"])).is_equal("/p.funscript")


func test_scan_attach_sibling_scripts() -> void:
	var video: String = _touch("clip.mp4", "not-a-real-video")
	var add_res: Dictionary = RandomizerLibrary.add_clip(video, "", {}, {}, [], 1.0, 3, "clip")
	assert_bool(bool(add_res.get("ok", false))).is_true()
	var id: String = str((add_res["entry"] as Dictionary).get("id", ""))
	assert_str(str(RandomizerLibrary.get_entry(id).get("funscript_src", ""))).is_equal("")

	_touch("clip.funscript", _minimal_funscript())
	_touch("clip.alpha.funscript", _minimal_funscript())
	_touch("clip.alpha-prostate.funscript", _minimal_funscript())
	SettingsService.set_restim_label("a", "Restim")
	SettingsService.set_restim_label("b", "Prostate")
	SettingsService.save()

	var n: int = RandomizerLibrary.scan_attach_sibling_scripts()
	assert_int(n).is_equal(1)
	var entry: Dictionary = RandomizerLibrary.get_entry(id)
	assert_str(str(entry.get("funscript_src", ""))).contains("clip.funscript")
	assert_str(str((entry["restim_axis_src"]["a"] as Dictionary).get("alpha", ""))).contains(
		"clip.alpha.funscript"
	)
	assert_str(str((entry["restim_axis_src"]["b"] as Dictionary).get("alpha", ""))).contains(
		"alpha-prostate"
	)
	assert_int(int(entry.get("action_count", 0))).is_greater(0)

	# Idempotent — already-filled slots untouched.
	assert_int(RandomizerLibrary.scan_attach_sibling_scripts()).is_equal(0)
