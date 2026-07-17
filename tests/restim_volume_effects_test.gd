extends GdUnitTestSuite

# Restim intensity — V0 from scale / volume_attenuate.
# Factor clamped to [0, 1]; final send also clamps to [0, 1].
# Pure effect-dict math; no device connection required.
# Note: C# default args are not visible to GDScript — always pass include_scale.


func _fx(kind: String, factor: Variant = null) -> Dictionary:
	var d: Dictionary = {"kind": kind, "name": kind}
	if factor != null:
		d["factor"] = factor
	return d


func _vol(effects: Array, include_scale: bool = true) -> float:
	return FunscriptPlayer.ComputeRestimVolumeFactor(effects, include_scale)


func test_no_effects_is_full_volume() -> void:
	assert_float(_vol([])).is_equal(1.0)


func test_volume_attenuate_multiplies() -> void:
	var effects: Array = [_fx("volume_attenuate", 0.3), _fx("volume_attenuate", 0.5)]
	assert_float(_vol(effects)).is_equal_approx(0.15, 0.001)


func test_scale_folds_into_v0_when_include_scale() -> void:
	var effects: Array = [_fx("scale", 0.6)]
	assert_float(_vol(effects, true)).is_equal_approx(0.6, 0.001)
	# Linear path does not use this helper for scale; include_scale=false leaves V0 alone.
	assert_float(_vol(effects, false)).is_equal(1.0)


func test_scale_and_volume_attenuate_stack() -> void:
	var effects: Array = [_fx("scale", 0.6), _fx("volume_attenuate", 0.5)]
	assert_float(_vol(effects, true)).is_equal_approx(0.3, 0.001)


func test_block_forces_zero_and_mutes_axes() -> void:
	var effects: Array = [_fx("block"), _fx("volume_attenuate", 0.8)]
	assert_float(_vol(effects, true)).is_equal(0.0)
	assert_bool(FunscriptPlayer.RestimAxesMuted(effects)).is_true()


func test_clamp_reverse_ignored_for_v0() -> void:
	# clamp/reverse are L0-geometry only — must not change Restim V0 factor.
	var effects: Array = [
		{"kind": "clamp", "min": 0, "max": 50, "name": "clamp"},
		{"kind": "reverse", "name": "reverse"},
	]
	assert_float(_vol(effects, true)).is_equal(1.0)
	assert_bool(FunscriptPlayer.RestimAxesMuted(effects)).is_false()


func test_factor_clamps_to_unit_interval() -> void:
	# Boost factors are capped at 1; negative floors at 0.
	var high: Array = [_fx("scale", 2.0)]
	assert_float(_vol(high, true)).is_equal(1.0)
	var mild: Array = [_fx("scale", 1.1)]
	assert_float(_vol(mild, true)).is_equal(1.0)
	var neg: Array = [_fx("volume_attenuate", -1.0)]
	assert_float(_vol(neg, true)).is_equal(0.0)


func test_apply_restim_intensity_norm() -> void:
	assert_float(FunscriptPlayer.ApplyRestimIntensityNorm(0.75, 0.60)).is_equal_approx(0.45, 0.001)
	assert_float(FunscriptPlayer.ApplyRestimIntensityNorm(0.90, 1.20)).is_equal(1.0)


func test_soft_touch_item_is_volume_attenuate() -> void:
	var data: Dictionary = InventoryService.GetItemData("soft_touch")
	assert_str(str(data.get("kind", ""))).is_equal("volume_attenuate")
	assert_float(float(data.get("factor", 0.0))).is_equal_approx(0.5, 0.001)
