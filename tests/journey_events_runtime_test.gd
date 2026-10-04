# Journey Events → Vector EVT: FormatEvt + JourneyEventScheduler (plan A).
extends GdUnitTestSuite


func test_format_evt_name_only() -> void:
	assert_str(VectorService.FormatEvt("edge")).is_equal("EVT name=edge")


func test_format_evt_with_params() -> void:
	var params := {
		"duration_ms": 18321,
		"volume_boost": 0.15,
		"buzz_freq": 10,
		"buzz_intensity": 0.07,
		"ramp_up_ms": 500,
	}
	assert_str(VectorService.FormatEvt("edge", params)).is_equal(
		(
			"EVT name=edge duration_ms=18321 volume_boost=0.15 buzz_freq=10 "
			+ "buzz_intensity=0.07 ramp_up_ms=500"
		)
	)


func test_format_evt_bool_and_int_float() -> void:
	var params := {"enabled": true, "count": 3, "gain": 1.0}
	assert_str(VectorService.FormatEvt("fast", params)).is_equal(
		"EVT name=fast enabled=true count=3 gain=1"
	)


func test_parse_journey_event_pascal_case() -> void:
	var runtime := JourneyData.parse_journey_event(
		{
			"RoundId": "inferno_C01_003",
			"TimeMs": 194026,
			"Name": "fast",
			"Params": {"duration_ms": 24895, "volume_boost": 0.03},
		}
	)
	assert_str(runtime["round_id"]).is_equal("inferno_C01_003")
	assert_int(runtime["time_ms"]).is_equal(194026)
	assert_str(runtime["name"]).is_equal("fast")
	assert_float(runtime["params"]["volume_boost"]).is_equal_approx(0.03, 0.0001)
	var round_trip := JourneyData.parse_journey_event(JourneyData.coerce_journey_event(runtime))
	assert_str(round_trip["name"]).is_equal("fast")
	assert_int(round_trip["time_ms"]).is_equal(194026)


func test_parse_journey_events_empty_defaults() -> void:
	assert_array(JourneyData.parse_journey_events([])).is_empty()
	assert_dict(JourneyData.index_journey_events([])).is_empty()


func test_index_journey_events_by_round() -> void:
	var events: Array = JourneyData.parse_journey_events(
		[
			{"RoundId": "a", "TimeMs": 1000, "Name": "edge", "Params": {}},
			{"RoundId": "b", "TimeMs": 500, "Name": "fast", "Params": {}},
			{"RoundId": "a", "TimeMs": 2000, "Name": "cum", "Params": {}},
		]
	)
	var by_round: Dictionary = JourneyData.index_journey_events(events)
	assert_int((by_round["a"] as Array).size()).is_equal(2)
	assert_int((by_round["b"] as Array).size()).is_equal(1)


# ── Scheduler ────────────────────────────────────────────────────────────────


func _evt(time_ms: int, name: String = "edge") -> Dictionary:
	return {"round_id": "r1", "time_ms": time_ms, "name": name, "params": {}}


func test_scheduler_fires_at_time_minus_lookahead() -> void:
	# Event at 5000 ms, lookahead 2000 → fire when pos >= 3000
	var s := JourneyEventScheduler.new()
	s.load_events([_evt(5000)], 2000)
	assert_array(s.tick(2999)).is_empty()
	var due: Array = s.tick(3000)
	assert_int(due.size()).is_equal(1)
	assert_str(due[0]["name"]).is_equal("edge")
	assert_array(s.tick(4000)).is_empty()  # once only


func test_scheduler_empty_round_is_idle() -> void:
	var s := JourneyEventScheduler.new()
	s.load_events([], 2000)
	assert_bool(s.is_idle()).is_true()
	assert_array(s.tick(9999)).is_empty()


func test_scheduler_forward_catchup_fires_due() -> void:
	var s := JourneyEventScheduler.new()
	s.load_events([_evt(5000, "a"), _evt(8000, "b")], 2000)
	# Jump past both fire points (3000 and 6000)
	var due: Array = s.tick(7000)
	assert_array([due[0]["name"], due[1]["name"]]).is_equal(["a", "b"])


func test_scheduler_backward_seek_rearms() -> void:
	var s := JourneyEventScheduler.new()
	s.load_events([_evt(5000)], 2000)
	assert_int(s.tick(3000).size()).is_equal(1)
	s.tick(1000)  # backward → re-arm (fire_at 3000 > 1000)
	assert_int(s.tick(3000).size()).is_equal(1)


func test_scheduler_pause_is_noop() -> void:
	var s := JourneyEventScheduler.new()
	s.load_events([_evt(5000)], 2000)
	s.tick(3000)
	for _i: int in 5:
		assert_array(s.tick(3000)).is_empty()


# ── Builder helpers (plan C) ─────────────────────────────────────────────────


func test_events_for_round_sorted() -> void:
	var events: Array = JourneyData.parse_journey_events(
		[
			{"RoundId": "r1", "TimeMs": 3000, "Name": "b", "Params": {}},
			{"RoundId": "r1", "TimeMs": 1000, "Name": "a", "Params": {}},
			{"RoundId": "r2", "TimeMs": 500, "Name": "x", "Params": {}},
		]
	)
	var for_r1: Array = JourneyData.events_for_round(events, "r1")
	assert_int(for_r1.size()).is_equal(2)
	assert_int(for_r1[0]["time_ms"]).is_equal(1000)
	assert_int(for_r1[1]["time_ms"]).is_equal(3000)


func test_replace_round_events_preserves_others() -> void:
	var events: Array = JourneyData.parse_journey_events(
		[
			{"RoundId": "a", "TimeMs": 1, "Name": "edge", "Params": {}},
			{"RoundId": "b", "TimeMs": 2, "Name": "fast", "Params": {}},
		]
	)
	var replaced: Array = JourneyData.replace_round_events(
		events,
		"a",
		[{"round_id": "a", "time_ms": 99, "name": "cum", "params": {"duration_ms": 10}}]
	)
	var by: Dictionary = JourneyData.index_journey_events(replaced)
	assert_int((by["a"] as Array).size()).is_equal(1)
	assert_str((by["a"] as Array)[0]["name"]).is_equal("cum")
	assert_int((by["b"] as Array).size()).is_equal(1)


func test_validate_journey_event_span_and_duplicate() -> void:
	var ev := {
		"round_id": "r",
		"time_ms": 8000,
		"name": "fast",
		"params": {"duration_ms": 5000},
	}
	var warns: Array = JourneyData.validate_journey_event(ev, 10000)
	assert_int(warns.size()).is_equal(1)
	assert_str(str(warns[0])).contains("spans past")

	var round_evs: Array = [
		{"round_id": "r", "time_ms": 100, "name": "edge", "params": {}},
		{"round_id": "r", "time_ms": 100, "name": "edge", "params": {}},
	]
	var dup: Array = JourneyData.validate_round_events(round_evs, 0)
	var found_dup := false
	for w: Variant in dup:
		if str(w).begins_with("Duplicate"):
			found_dup = true
			break
	assert_bool(found_dup).is_true()


func test_parse_event_definitions_fixture() -> void:
	var path := "res://tests/fixtures/sample_event_definitions.yml"
	var abs_path := ProjectSettings.globalize_path(path)
	var defs: Dictionary = EventDefinitions.load_path(abs_path)
	assert_str(str(defs.get("error", ""))).is_empty()
	var names: Array = defs.get("names", []) as Array
	assert_int(names.size()).is_equal(3)
	assert_bool(names.has("edge")).is_true()
	assert_bool(names.has("fast")).is_true()
	assert_bool(names.has("cum")).is_true()
	var edge: Dictionary = EventDefinitions.default_params_for(defs, "edge")
	assert_int(int(edge["duration_ms"])).is_equal(15000)
	assert_float(float(edge["volume_boost"])).is_equal_approx(0.15, 0.0001)
	assert_int(int(edge["buzz_freq"])).is_equal(10)
	# steps must not leak into params
	assert_bool(edge.has("operation")).is_false()
	var cum: Dictionary = EventDefinitions.default_params_for(defs, "cum")
	assert_bool(bool(cum["enabled"])).is_true()
