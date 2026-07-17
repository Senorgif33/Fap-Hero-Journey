extends GdUnitTestSuite

# Dual Restim — restim_axis_scripts coerce / legacy migration.


func test_empty_restim_axis_scripts_shape() -> void:
	var e: Dictionary = JourneyData.empty_restim_axis_scripts()
	assert_bool(e.has("a")).is_true()
	assert_bool(e.has("b")).is_true()
	assert_bool(e.has("shared")).is_true()
	assert_bool((e["a"] as Dictionary).is_empty()).is_true()


func test_legacy_axis_scripts_migrate_to_shared() -> void:
	var ras: Dictionary = JourneyData.coerce_restim_axis_scripts(
		{"axis_scripts": {"alpha": "a.funscript", "pulse_frequency": "p.funscript"}}
	)
	assert_str(str((ras["shared"] as Dictionary)["alpha"])).is_equal("a.funscript")
	assert_str(str((ras["shared"] as Dictionary)["pulse_frequency"])).is_equal("p.funscript")
	assert_bool((ras["a"] as Dictionary).is_empty()).is_true()
	assert_bool((ras["b"] as Dictionary).is_empty()).is_true()


func test_explicit_slots_preserved_legacy_fills_gaps() -> void:
	var ras: Dictionary = JourneyData.coerce_restim_axis_scripts(
		{
			"restim_axis_scripts":
			{
				"a": {"alpha": "prostate_alpha.funscript"},
				"b": {"alpha": "foc_alpha.funscript"},
				"shared": {"pulse_frequency": "pulse.funscript"},
			},
			"axis_scripts": {"beta": "legacy_beta.funscript", "alpha": "ignored.funscript"},
		}
	)
	assert_str(str((ras["a"] as Dictionary)["alpha"])).is_equal("prostate_alpha.funscript")
	assert_str(str((ras["b"] as Dictionary)["alpha"])).is_equal("foc_alpha.funscript")
	assert_str(str((ras["shared"] as Dictionary)["pulse_frequency"])).is_equal("pulse.funscript")
	# alpha already in a/b — legacy alpha must not overwrite shared
	assert_bool((ras["shared"] as Dictionary).has("alpha")).is_false()
	# beta only in legacy → shared
	assert_str(str((ras["shared"] as Dictionary)["beta"])).is_equal("legacy_beta.funscript")


func test_ensure_restim_axis_scripts_writes_both_keys() -> void:
	var d: Dictionary = {"axis_scripts": {"volume": "v.funscript"}}
	var ras: Dictionary = JourneyData.ensure_restim_axis_scripts(d)
	assert_str(str((ras["shared"] as Dictionary)["volume"])).is_equal("v.funscript")
	assert_str(str((d["axis_scripts"] as Dictionary)["volume"])).is_equal("v.funscript")
	assert_bool(d.has("restim_axis_scripts")).is_true()


func test_coerce_pool_entry_includes_restim_kits() -> void:
	var e: Dictionary = JourneyData.coerce_pool_entry(
		{
			"restim_axis_scripts": {"a": {"e1": "e.funscript"}, "b": {}, "shared": {}},
		}
	)
	assert_str(str((e["restim_axis_scripts"]["a"] as Dictionary)["e1"])).is_equal("e.funscript")


func test_import_scanner_slotted_detection() -> void:
	var slotted: Dictionary = ImportScanner.detect_funscript_slotted_axis(
		"/x/scene.a.alpha.funscript", "Restim A", "Restim B"
	)
	assert_str(str(slotted.get("slot", ""))).is_equal("a")
	assert_str(str(slotted.get("axis", ""))).is_equal("alpha")
	var shared: Dictionary = ImportScanner.detect_funscript_slotted_axis(
		"/x/scene.pulse_width.funscript", "Restim A", "Restim B"
	)
	assert_str(str(shared.get("slot", ""))).is_equal("shared")
	assert_str(str(shared.get("axis", ""))).is_equal("pulse_width")
	var plain: Dictionary = ImportScanner.detect_funscript_slotted_axis(
		"/x/scene.alpha.funscript", "Restim A", "Restim B"
	)
	assert_str(str(plain.get("slot", ""))).is_equal("a")
	assert_bool(
		ImportScanner.detect_funscript_slotted_axis("/x/scene.funscript").is_empty()
	).is_true()
