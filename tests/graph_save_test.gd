extends GdUnitTestSuite

# Slice-4 (Format-2 graph save) pure helpers in JourneyData: node-data normalization
# (coerce_node_save_data — the "coins lesson" + baseline-field guarantees + node-key
# stripping) and the save's video planning (graph_has_any_video / graph_video_sources).
# These are the testable core of the save rewrite; the file-I/O assembly (_save_graph_nodes
# and its media helpers) stays manual/integration, like the rest of the copy/transcode path.

# ── coerce_node_save_data: numeric coercion (the "coins lesson") ──────────────


# JSON loads every number as float; the integer round fields must persist as int.
func test_coerce_round_coerces_int_fields() -> void:
	var out := (
		JourneyData
		. coerce_node_save_data(
			"round",
			{
				"name": "A",
				"coins": 5.0,
				"curse_reward": 10.0,
				"cleanse_cost": 25.0,
			}
		)
	)
	assert_int(typeof(out["coins"])).is_equal(TYPE_INT)
	assert_int(out["coins"]).is_equal(5)
	assert_int(typeof(out["curse_reward"])).is_equal(TYPE_INT)
	assert_int(out["curse_reward"]).is_equal(10)
	assert_int(typeof(out["cleanse_cost"])).is_equal(TYPE_INT)
	assert_int(out["cleanse_cost"]).is_equal(25)


func test_coerce_shop_fields() -> void:
	var out := JourneyData.coerce_node_save_data(
		"shop", {"title": "S", "count": 3.0, "price_multiplier": 1.5}
	)
	assert_int(typeof(out["count"])).is_equal(TYPE_INT)
	assert_int(out["count"]).is_equal(3)
	assert_float(out["price_multiplier"]).is_equal(1.5)  # float stays float
	assert_str(out["mode"]).is_equal("pool")  # default filled


func test_coerce_storyboard_fields() -> void:
	var out := JourneyData.coerce_node_save_data("storyboard", {"coins": 7.0})
	assert_int(typeof(out["coins"])).is_equal(TYPE_INT)
	assert_int(out["coins"]).is_equal(7)
	assert_str(out["item"]).is_equal("")  # default filled


func test_coerce_fork_fields() -> void:
	var out := JourneyData.coerce_node_save_data(
		"fork", {"title": "F", "default_path": 1.0, "after_order": 2.0}
	)
	assert_int(typeof(out["default_path"])).is_equal(TYPE_INT)
	assert_int(out["default_path"]).is_equal(1)
	assert_int(typeof(out["after_order"])).is_equal(TYPE_INT)
	assert_int(out["after_order"]).is_equal(2)
	assert_str(out["resolution"]).is_equal("choice")  # default filled


# ── coerce_node_save_data: baseline fields, key stripping, pass-through ───────


# A never-edited new round (only a name) still gets the full baseline field set with the
# documented defaults — parity with what the tree save's round_to_json always wrote, so a
# new node's on-disk record is complete instead of relying on read-time defaults.
func test_coerce_round_fills_baseline_defaults() -> void:
	var out := JourneyData.coerce_node_save_data("round", {"name": "A"})
	assert_str(out["round_type"]).is_equal("normal")
	assert_bool(out["is_checkpoint"]).is_false()
	assert_bool(out["curse_random"]).is_true()
	assert_int(out["cleanse_cost"]).is_equal(50)
	assert_array(out["curses"]).is_empty()
	assert_array(out["boons"]).is_empty()
	assert_array(out["sensory"]).is_empty()
	assert_bool(out["show_reveal"]).is_true()


# Node-level keys (type / node_id / paths) never belong inside on-disk node.data.
func test_coerce_strips_node_level_keys() -> void:
	var out := (
		JourneyData
		. coerce_node_save_data(
			"round",
			{
				"name": "A",
				"type": "round",
				"node_id": "n_x",
				"paths": [{}],
			}
		)
	)
	assert_bool(out.has("type")).is_false()
	assert_bool(out.has("node_id")).is_false()
	assert_bool(out.has("paths")).is_false()


# Extra / future keys and genuine float fields pass through via the deep-copy base.
func test_coerce_passes_through_extras_and_floats() -> void:
	var out := (
		JourneyData
		. coerce_node_save_data(
			"round",
			{
				"name": "A",
				"sensory_intensity": {"Strobe": 0.5},
				"future_key": "keep",
			}
		)
	)
	assert_float((out["sensory_intensity"] as Dictionary)["Strobe"]).is_equal(0.5)
	assert_str(out["future_key"]).is_equal("keep")


# The copy is deep — mutating the result can't bleed back into the editor's live node data.
func test_coerce_deep_copies_source() -> void:
	var src := {"name": "A", "curses": ["Greed"]}
	var out := JourneyData.coerce_node_save_data("round", src)
	(out["curses"] as Array).append("Pauper")
	assert_int((src["curses"] as Array).size()).is_equal(1)


# ── video planning (transcode plan + progress modal) ─────────────────────────


func _graph(nodes: Dictionary) -> Dictionary:
	return {"start": "", "nodes": nodes}


func test_graph_has_any_video_false_without_video() -> void:
	(
		assert_bool(
			(
				JourneyData
				. graph_has_any_video(
					_graph(
						{
							"a": {"type": "round", "data": {"video_path": ""}},
							"b": {"type": "shop", "data": {}},
						}
					)
				)
			)
		)
		. is_false()
	)


func test_graph_has_any_video_true_with_video() -> void:
	(
		assert_bool(
			(
				JourneyData
				. graph_has_any_video(
					_graph(
						{
							"a": {"type": "round", "data": {"video_path": "/x/v.mp4"}},
						}
					)
				)
			)
		)
		. is_true()
	)


# Sources are deduped (a clip reused across rounds is probed once) and only rounds count.
func test_graph_video_sources_dedups_rounds_only() -> void:
	var srcs := (
		JourneyData
		. graph_video_sources(
			_graph(
				{
					"a": {"type": "round", "data": {"video_path": "/x/v.mp4"}},
					"b": {"type": "round", "data": {"video_path": "/x/v.mp4"}},  # reused → once
					"c": {"type": "round", "data": {"video_path": "/y/w.mp4"}},
					"d": {"type": "round", "data": {"video_path": ""}},  # no video
					"e": {"type": "storyboard", "data": {"image": "/z/i.png"}},  # not a round
				}
			)
		)
	)
	assert_int(srcs.size()).is_equal(2)
	assert_bool(srcs.has("/x/v.mp4")).is_true()
	assert_bool(srcs.has("/y/w.mp4")).is_true()
