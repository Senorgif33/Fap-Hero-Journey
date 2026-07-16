extends GdUnitTestSuite

# Stock journey compatibility for Restim V0 intensity work.
# Stock / linear play must not require schema migration; Soft Touch is opt-in;
# Restim V0 modulation only applies when the Restim stroke path is used
# (ComputeRestimVolumeFactor with include_scale mirrors that fold).


func _fx(kind: String, factor: Variant = null) -> Dictionary:
	var d: Dictionary = {"kind": kind, "name": kind}
	if factor != null:
		d["factor"] = factor
	return d


# No active effects → full volume (no forced Soft Touch / attenuation on stock runs).
func test_empty_effects_leave_full_volume() -> void:
	assert_float(FunscriptPlayer.ComputeRestimVolumeFactor([], true)).is_equal(1.0)
	assert_bool(FunscriptPlayer.RestimAxesMuted([])).is_false()


# Non-Restim stroke path does not fold scale into V0 (include_scale=false).
func test_linear_path_does_not_fold_scale_into_v0() -> void:
	var effects: Array = [
		_fx("scale", 0.6),
		{"kind": "clamp", "min": 0, "max": 50, "name": "clamp"},
		{"kind": "reverse", "name": "reverse"},
	]
	assert_float(FunscriptPlayer.ComputeRestimVolumeFactor(effects, false)).is_equal(1.0)


# Classic stock stroke modifiers still transform linear Handy points (unchanged).
func test_stock_scale_still_affects_handy_geometry() -> void:
	var pts: Array = [
		{"t": 0, "x": 0},
		{"t": 500, "x": 100},
		{"t": 1000, "x": 0},
	]
	var out: Array = HandyPoints.apply_effects(pts, [{"kind": "scale", "factor": 0.6}])
	assert_int(int((out[1] as Dictionary)["x"])).is_equal(60)


# Soft Touch is registry-only: not granted on inventory reset; fixed shops omit it
# unless authored.
func test_soft_touch_is_opt_in_not_forced() -> void:
	InventoryService.Reset()
	assert_bool(InventoryService.OwnsItem("soft_touch")).is_false()

	var data: Dictionary = InventoryService.GetItemData("soft_touch")
	assert_str(str(data.get("kind", ""))).is_equal("volume_attenuate")

	var fixed_shop := {"mode": "fixed", "items": ["mirror", "key"], "count": 2}
	var registry: Array = InventoryService.GetAllItemIds()
	var offer: Array = JourneyData.resolve_shop_offer(fixed_shop, registry)
	assert_int(offer.size()).is_equal(2)
	assert_array(offer).contains(["key"])
	assert_array(offer).contains(["mirror"])
	assert_bool("soft_touch" in offer).is_false()


# Journey coerce still accepts a plain stock round with no Restim/cooldown fields.
func test_stock_round_coerce_needs_no_new_fields() -> void:
	var round: Dictionary = JourneyData.coerce_node_save_data(
		"round",
		{"name": "Stock Round", "video_path": "", "funscript_path": "", "coins": 10}
	)
	assert_str(str(round.get("name", ""))).is_equal("Stock Round")
	assert_int(int(round.get("coins", -1))).is_equal(10)
	# New optional fields default harmlessly when coerced from stock data.
	assert_int(int(round.get("cooldown_days", -1))).is_equal(0)
	assert_bool(bool(round.get("items_blocked", true))).is_false()
