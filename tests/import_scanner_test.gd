extends GdUnitTestSuite

# Tests for ImportScanner — the bulk-import / sibling-detection logic extracted from JourneyBuilder.
# Pure functions are tested directly; disk functions run against a throwaway temp dir of fixture files.

# A throwaway dir of fixture files, fresh per test.
var _tmp: String = ""


func before_test() -> void:
	_tmp = "user://import_scanner_test_%d" % Time.get_ticks_usec()
	DirAccess.make_dir_recursive_absolute(_tmp)


func after_test() -> void:
	_rm_rf(_tmp)


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


# Creates an (empty-ish) fixture file in the temp dir and returns its path.
func _touch(name: String) -> String:
	var p: String = "%s/%s" % [_tmp, name]
	var fa: FileAccess = FileAccess.open(p, FileAccess.ModeFlags.WRITE)
	fa.store_string("{}")
	fa.close()
	return p


# ── Pure: filename → axis / vib / stem ───────────────────────────────────────


func test_axis_main_stroke_is_l0() -> void:
	assert_str(ImportScanner.detect_funscript_axis("/x/scene.funscript")).is_equal("L0")


func test_axis_tcode_code_suffixes() -> void:
	assert_str(ImportScanner.detect_funscript_axis("/x/scene.L1.funscript")).is_equal("L1")
	assert_str(ImportScanner.detect_funscript_axis("/x/scene_r2.funscript")).is_equal("R2")


func test_axis_human_name_suffixes() -> void:
	assert_str(ImportScanner.detect_funscript_axis("/x/scene.surge.funscript")).is_equal("L1")
	assert_str(ImportScanner.detect_funscript_axis("/x/scene_twist.funscript")).is_equal("R0")
	assert_str(ImportScanner.detect_funscript_axis("/x/scene.pitch.funscript")).is_equal("R2")


func test_restim_kit_suffixes() -> void:
	assert_str(ImportScanner.detect_funscript_axis("/x/scene.alpha.funscript")).is_equal("alpha")
	assert_str(ImportScanner.detect_funscript_axis("/x/scene.beta.funscript")).is_equal("beta")
	assert_str(ImportScanner.detect_funscript_axis("/x/scene.e3.funscript")).is_equal("e3")
	assert_str(ImportScanner.detect_funscript_axis("/x/scene.volume.funscript")).is_equal("volume")


func test_vib_channels() -> void:
	assert_str(ImportScanner.detect_vib_channel("/x/scene.vib1.funscript")).is_equal("vib1")
	assert_str(ImportScanner.detect_vib_channel("/x/scene_vibe2.funscript")).is_equal("vib2")
	assert_str(ImportScanner.detect_vib_channel("/x/scene.funscript")).is_equal("")


func test_strip_script_suffix() -> void:
	assert_str(ImportScanner.strip_script_suffix("/x/scene.L1.funscript")).is_equal("scene")
	assert_str(ImportScanner.strip_script_suffix("/x/scene_vib1.funscript")).is_equal("scene")
	assert_str(ImportScanner.strip_script_suffix("/x/scene.funscript")).is_equal("scene")
	# Preserves the stem's original casing.
	assert_str(ImportScanner.strip_script_suffix("/x/Scene_R0.funscript")).is_equal("Scene")


# ── Pure: grouping helpers ───────────────────────────────────────────────────


func test_group_key_pairs_within_a_folder() -> void:
	var k: String = ImportScanner.round_group_key("/media/scene.mp4")
	assert_str(ImportScanner.round_group_key("/media/scene.L1.funscript")).is_equal(k)
	assert_str(ImportScanner.round_group_key("/media/scene.vib1.funscript")).is_equal(k)


func test_group_key_separates_folders() -> void:
	assert_str(ImportScanner.round_group_key("/a/scene.mp4")).is_not_equal(
		ImportScanner.round_group_key("/b/scene.mp4")
	)


func test_ensure_import_group_is_idempotent() -> void:
	var groups: Dictionary = {}
	var order: Array = []
	ImportScanner.ensure_import_group(groups, order, "k")
	ImportScanner.ensure_import_group(groups, order, "k")
	assert_int(order.size()).is_equal(1)
	assert_bool(groups.has("k")).is_true()


func test_group_anchor_priority() -> void:
	(
		assert_str(
			ImportScanner.group_anchor_path(
				{"video": "v.mp4", "funscript": "f.funscript", "axis": {}, "vib": {}}
			)
		)
		. is_equal("v.mp4")
	)
	(
		assert_str(
			ImportScanner.group_anchor_path(
				{"video": "", "funscript": "f.funscript", "axis": {}, "vib": {}}
			)
		)
		. is_equal("f.funscript")
	)
	(
		assert_str(
			ImportScanner.group_anchor_path(
				{"video": "", "funscript": "", "axis": {"L1": "a.funscript"}, "vib": {}}
			)
		)
		. is_equal("a.funscript")
	)
	(
		assert_str(
			ImportScanner.group_anchor_path({"video": "", "funscript": "", "axis": {}, "vib": {}})
		)
		. is_equal("")
	)


# ── Pure: build_rounds (synthetic paths → disk autofill no-ops) ───────────────


func test_build_rounds_groups_one_round() -> void:
	var files := PackedStringArray(
		[
			"/no_such_dir/scene.mp4",
			"/no_such_dir/scene.funscript",
			"/no_such_dir/scene.L1.funscript",
			"/no_such_dir/scene.vib1.funscript",
		]
	)
	var result: Dictionary = ImportScanner.build_rounds(files)
	assert_int(result["skipped_no_video"]).is_equal(0)
	var rounds: Array = result["rounds"]
	assert_int(rounds.size()).is_equal(1)
	var r: Dictionary = rounds[0]
	assert_str(r["video_path"]).is_equal("/no_such_dir/scene.mp4")
	assert_str(r["funscript_path"]).is_equal("/no_such_dir/scene.funscript")
	assert_bool((r["axis_scripts"] as Dictionary).has("L1")).is_true()
	assert_bool((r["restim_axis_scripts"]["shared"] as Dictionary).has("L1")).is_true()
	assert_bool((r["vib_scripts"] as Dictionary).has("vib1")).is_true()


func test_build_rounds_slotted_restim_kits() -> void:
	var files := PackedStringArray(
		[
			"/no_such_dir/scene.mp4",
			"/no_such_dir/scene.funscript",
			"/no_such_dir/scene.a.alpha.funscript",
			"/no_such_dir/scene.b.volume.funscript",
			"/no_such_dir/scene.pulse_frequency.funscript",
		]
	)
	var result: Dictionary = ImportScanner.build_rounds(files, "Restim A", "Restim B")
	var r: Dictionary = result["rounds"][0]
	assert_str(str((r["restim_axis_scripts"]["a"] as Dictionary)["alpha"])).contains("a.alpha")
	assert_str(str((r["restim_axis_scripts"]["b"] as Dictionary)["volume"])).contains("b.volume")
	assert_str(
		str((r["restim_axis_scripts"]["shared"] as Dictionary)["pulse_frequency"])
	).contains("pulse_frequency")


func test_build_rounds_label_tagged_and_plain_kit() -> void:
	var files := PackedStringArray(
		[
			"/no_such_dir/scene.mp4",
			"/no_such_dir/scene.funscript",
			"/no_such_dir/scene.alpha.funscript",
			"/no_such_dir/scene.alpha-prostate.funscript",
			"/no_such_dir/scene.pulse_width.funscript",
		]
	)
	var result: Dictionary = ImportScanner.build_rounds(files, "Restim", "Prostate")
	var r: Dictionary = result["rounds"][0]
	assert_str(str((r["restim_axis_scripts"]["a"] as Dictionary)["alpha"])).contains(
		"scene.alpha.funscript"
	)
	assert_str(str((r["restim_axis_scripts"]["b"] as Dictionary)["alpha"])).contains(
		"alpha-prostate"
	)
	assert_str(str((r["restim_axis_scripts"]["shared"] as Dictionary)["pulse_width"])).contains(
		"pulse_width"
	)


func test_autofill_src_siblings_backfills_library_shape() -> void:
	_touch("scene.mp4")
	_touch("scene.funscript")
	_touch("scene.alpha.funscript")
	_touch("scene.alpha-prostate.funscript")
	_touch("scene.vib1.funscript")
	var filled: Dictionary = ImportScanner.autofill_src_siblings(
		"%s/scene.mp4" % _tmp, "", {}, {}, "Restim", "Prostate"
	)
	assert_bool(bool(filled["changed"])).is_true()
	assert_str(str(filled["funscript_src"])).contains("scene.funscript")
	assert_str(str((filled["restim_axis_src"]["a"] as Dictionary)["alpha"])).contains(
		"scene.alpha.funscript"
	)
	assert_str(str((filled["restim_axis_src"]["b"] as Dictionary)["alpha"])).contains(
		"alpha-prostate"
	)
	assert_bool((filled["vib_src"] as Dictionary).has("vib1")).is_true()
	# Second pass must not overwrite.
	var again: Dictionary = ImportScanner.autofill_src_siblings(
		"%s/scene.mp4" % _tmp,
		str(filled["funscript_src"]),
		filled["restim_axis_src"],
		filled["vib_src"],
		"Restim",
		"Prostate"
	)
	assert_bool(bool(again["changed"])).is_false()



func test_build_rounds_skips_funscript_without_video() -> void:
	var result: Dictionary = ImportScanner.build_rounds(
		PackedStringArray(["/no_such_dir/lonely.funscript"])
	)
	assert_int(result["rounds"].size()).is_equal(0)
	assert_int(result["skipped_no_video"]).is_equal(1)


func test_build_rounds_keeps_first_seen_order() -> void:
	var result: Dictionary = ImportScanner.build_rounds(PackedStringArray(["/d/a.mp4", "/d/b.mp4"]))
	var rounds: Array = result["rounds"]
	assert_int(rounds.size()).is_equal(2)
	assert_str(rounds[0]["video_path"]).is_equal("/d/a.mp4")
	assert_str(rounds[1]["video_path"]).is_equal("/d/b.mp4")


# ── Disk: sibling detection against fixture files ────────────────────────────


func test_find_sibling_scripts_classifies() -> void:
	_touch("scene.funscript")
	_touch("scene.L1.funscript")
	_touch("scene.vib1.funscript")
	_touch("other.funscript")  # different base — must be ignored
	var scan: Dictionary = ImportScanner.find_sibling_scripts(_tmp, "scene")
	assert_str(scan["funscript"]).is_equal("%s/scene.funscript" % _tmp)
	assert_bool((scan["axis"] as Dictionary).has("L1")).is_true()
	assert_bool((scan["vib"] as Dictionary).has("vib1")).is_true()
	assert_bool((scan["axis"] as Dictionary).has("R0")).is_false()


func test_find_sibling_video() -> void:
	_touch("scene.mp4")
	assert_str(ImportScanner.find_sibling_video(_tmp, "scene")).is_equal("%s/scene.mp4" % _tmp)
	assert_str(ImportScanner.find_sibling_video(_tmp, "missing")).is_equal("")


func test_autofill_fills_empty_slots() -> void:
	_touch("scene.mp4")
	_touch("scene.funscript")
	_touch("scene.R0.funscript")
	var round_data: Dictionary = {
		"funscript_path": "", "video_path": "", "axis_scripts": {}, "vib_scripts": {}
	}
	var changed: bool = ImportScanner.autofill_round_siblings(
		round_data, "%s/scene.funscript" % _tmp
	)
	assert_bool(changed).is_true()
	assert_str(round_data["funscript_path"]).is_equal("%s/scene.funscript" % _tmp)
	assert_str(round_data["video_path"]).is_equal("%s/scene.mp4" % _tmp)
	assert_bool((round_data["axis_scripts"] as Dictionary).has("R0")).is_true()


func test_autofill_never_overwrites_a_set_slot() -> void:
	_touch("scene.mp4")
	_touch("scene.funscript")
	var round_data: Dictionary = {
		"funscript_path": "KEEP", "video_path": "", "axis_scripts": {}, "vib_scripts": {}
	}
	ImportScanner.autofill_round_siblings(round_data, "%s/scene.funscript" % _tmp)
	assert_str(round_data["funscript_path"]).is_equal("KEEP")  # author's value untouched
	assert_str(round_data["video_path"]).is_equal("%s/scene.mp4" % _tmp)  # empty slot still filled


func test_expand_dropped_paths_walks_dirs_and_filters() -> void:
	_touch("a.mp4")
	_touch("a.funscript")
	_touch("notes.txt")  # non-media — must be filtered out
	var out: PackedStringArray = ImportScanner.expand_dropped_paths(PackedStringArray([_tmp]))
	assert_int(out.size()).is_equal(2)
	assert_bool(out.has("%s/a.mp4" % _tmp)).is_true()
	assert_bool(out.has("%s/notes.txt" % _tmp)).is_false()
