extends GdUnitTestSuite

# Erosphere pack items in the stock registry — ids + effect kinds.


func test_erosphere_items_in_registry() -> void:
	var ids: Array = [
		"erosphere_amulet",
		"erosphere_psychic_divorce",
		"erosphere_feign_death",
		"erosphere_blinding_light",
		"erosphere_time_control",
	]
	for id: String in ids:
		var data: Dictionary = InventoryService.GetItemData(id)
		assert_dict(data).is_not_empty()
		assert_str(str(data.get("id", ""))).is_equal(id)
		assert_bool(id in InventoryService.GetAllItemIds()).is_true()


func test_feign_death_volume_round_scoped() -> void:
	var data: Dictionary = InventoryService.GetItemData("erosphere_feign_death")
	assert_str(str(data.get("kind", ""))).is_equal("volume_attenuate")
	assert_float(float(data.get("factor", 0.0))).is_equal_approx(0.30, 0.001)
	assert_bool(bool(data.get("round_scoped", false))).is_true()


func test_blinding_light_blackout_soft_kind() -> void:
	var data: Dictionary = InventoryService.GetItemData("erosphere_blinding_light")
	assert_str(str(data.get("kind", ""))).is_equal("blackout_soft")
	assert_float(float(data.get("factor", 0.0))).is_equal_approx(0.60, 0.001)
	assert_int(int(data.get("duration_ms", 0))).is_equal(30000)


func test_cooldown_shave_hours() -> void:
	assert_int(int(InventoryService.GetItemData("erosphere_amulet").get("shave_hours", 0))).is_equal(24)
	assert_int(
		int(InventoryService.GetItemData("erosphere_psychic_divorce").get("shave_hours", 0))
	).is_equal(48)


func test_round_coerce_calendar_defaults() -> void:
	var round: Dictionary = JourneyData.coerce_node_save_data("round", {"name": "X", "coins": 1})
	assert_int(int(round.get("cooldown_days", -1))).is_equal(0)
	assert_bool(bool(round.get("items_blocked", true))).is_false()
