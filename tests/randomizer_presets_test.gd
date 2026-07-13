extends GdUnitTestSuite

# RandomizerPresets — the pure list mutation (upsert / without). No disk.


func _preset(name: String, count: int) -> Dictionary:
	return {"name": name, "settings": {"round_count": count}}


func test_upsert_appends_new() -> void:
	var out: Array = RandomizerPresets.upsert([], "Quick", {"round_count": 5})
	assert_int(out.size()).is_equal(1)
	assert_str(str((out[0] as Dictionary)["name"])).is_equal("Quick")
	assert_int(int(((out[0] as Dictionary)["settings"] as Dictionary)["round_count"])).is_equal(5)


func test_upsert_replaces_in_place() -> void:
	var start: Array = [_preset("A", 1), _preset("B", 2), _preset("C", 3)]
	var out: Array = RandomizerPresets.upsert(start, "B", {"round_count": 99})
	# Same length, same order, B's settings replaced.
	assert_int(out.size()).is_equal(3)
	assert_str(str((out[1] as Dictionary)["name"])).is_equal("B")
	assert_int(int(((out[1] as Dictionary)["settings"] as Dictionary)["round_count"])).is_equal(99)
	assert_str(str((out[0] as Dictionary)["name"])).is_equal("A")
	assert_str(str((out[2] as Dictionary)["name"])).is_equal("C")


func test_upsert_deep_copies_settings() -> void:
	var settings: Dictionary = {"round_count": 5}
	var out: Array = RandomizerPresets.upsert([], "X", settings)
	settings["round_count"] = 777  # mutate the source afterward
	assert_int(int(((out[0] as Dictionary)["settings"] as Dictionary)["round_count"])).is_equal(5)


func test_without_removes_by_name() -> void:
	var start: Array = [_preset("A", 1), _preset("B", 2)]
	var out: Array = RandomizerPresets.without(start, "A")
	assert_int(out.size()).is_equal(1)
	assert_str(str((out[0] as Dictionary)["name"])).is_equal("B")


func test_without_missing_is_noop() -> void:
	var start: Array = [_preset("A", 1)]
	assert_int(RandomizerPresets.without(start, "Z").size()).is_equal(1)
