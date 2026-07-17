extends GdUnitTestSuite

# Cooldown + cutscene Format-2 node types: reachability via release→cutscene,
# Advance-on-quit for cooldown nodes, coerce/save rules (no funscript).


func _edge(to: String) -> Dictionary:
	return {"to": to}


func _n(type: String, outs: Array, data: Dictionary = {}) -> Dictionary:
	var edges: Array = []
	for t: String in outs:
		edges.append(_edge(t))
	return {"type": type, "data": data, "out": edges}


func _g(start: String, nodes: Dictionary) -> Dictionary:
	return {"start": start, "nodes": nodes}


# release_jump_to may target a cutscene; that island must stay reachable.
func test_release_jump_to_cutscene_is_reachable() -> void:
	var main := _n("round", [], {"release_jump_to": "ep"})
	var ep := _n("cutscene", ["fate"], {"name": "EP1", "video_path": "", "items_blocked": true})
	var fate := _n("cutscene", ["cd"], {"name": "Fate", "video_path": ""})
	var cd := _n("cooldown", ["session"], {"name": "Wait", "days": 1})
	var session := _n("round", [], {"name": "Punish", "coins": 15})
	var g := _g("main", {"main": main, "ep": ep, "fate": fate, "cd": cd, "session": session})
	assert_array(JourneyGraph.validate_graph(g)).is_empty()
	var reach: Dictionary = JourneyGraph.reachable_ids(g)
	assert_bool(reach.has("ep")).is_true()
	assert_bool(reach.has("fate")).is_true()
	assert_bool(reach.has("cd")).is_true()
	assert_bool(reach.has("session")).is_true()


# Cooldown Force Save & Quit advances past the node before capturing current_node.
func test_cooldown_node_save_advances_to_next() -> void:
	var g := _g(
		"cd",
		{
			"cd": _n("cooldown", ["session"], {"name": "EP4 wait 1", "days": 1}),
			"session": _n("round", [], {"name": "Punish Session", "coins": 15}),
		}
	)
	GameState.StartJourney(g)
	assert_str(GameState.CurrentNodeId()).is_equal("cd")
	assert_str(GameState.CurrentItemType()).is_equal("cooldown")
	assert_int(int(GameState.CurrentCooldown().get("days", 0))).is_equal(1)
	assert_bool(GameState.CurrentRound().is_empty()).is_true()

	assert_bool(GameState.IsLastRound()).is_false()
	GameState.Advance()

	var snap: Dictionary = GameState.CaptureSaveData()
	assert_str(str(snap.get("current_node", ""))).is_equal("session")
	assert_str(GameState.CurrentRound().get("name", "")).is_equal("Punish Session")


# Cutscene Advance lands on the next node (mirrors end-of-video / Skip).
func test_cutscene_advance_to_next() -> void:
	var g := _g(
		"ep",
		{
			"ep":
			_n(
				"cutscene",
				["fate"],
				{"name": "EP", "video_path": "content/ep.mp4", "items_blocked": true}
			),
			"fate":
			_n("cutscene", ["cd"], {"name": "Fate", "video_path": "", "items_blocked": true}),
			"cd": _n("cooldown", [], {"name": "Wait", "days": 3}),
		}
	)
	GameState.StartJourney(g)
	assert_str(GameState.CurrentItemType()).is_equal("cutscene")
	assert_str(GameState.CurrentCutscene().get("name", "")).is_equal("EP")
	assert_bool(bool(GameState.CurrentCutscene().get("items_blocked", false))).is_true()

	GameState.Advance()
	assert_str(GameState.CurrentNodeId()).is_equal("fate")
	assert_str(GameState.CurrentItemType()).is_equal("cutscene")

	GameState.Advance()
	assert_str(GameState.CurrentNodeId()).is_equal("cd")
	assert_str(GameState.CurrentItemType()).is_equal("cooldown")
	assert_int(int(GameState.CurrentCooldown().get("days", 0))).is_equal(3)


# coerce_node_save_data: cooldown/cutscene baselines; cutscene never carries funscript.
func test_coerce_cooldown_and_cutscene() -> void:
	var cd := JourneyData.coerce_node_save_data("cooldown", {"name": "Wait", "days": 2.0})
	assert_str(cd.get("name", "")).is_equal("Wait")
	assert_int(int(cd.get("days", 0))).is_equal(2)
	assert_bool(cd.has("funscript_path")).is_false()

	var cut := JourneyData.coerce_node_save_data(
		"cutscene",
		{"name": "EP", "video_path": "v.mp4", "items_blocked": 1, "award_item": "erosphere_amulet"}
	)
	assert_str(cut.get("name", "")).is_equal("EP")
	assert_str(cut.get("video_path", "")).is_equal("v.mp4")
	assert_bool(bool(cut.get("items_blocked", false))).is_true()
	assert_str(cut.get("award_item", "")).is_equal("erosphere_amulet")
	assert_bool(cut.has("funscript_path")).is_false()

	# days floored to ≥ 1
	var cd_min := JourneyData.coerce_node_save_data("cooldown", {"days": 0})
	assert_int(int(cd_min.get("days", 0))).is_equal(1)

	# items_blocked defaults true when absent; award_item defaults empty;
	# coins / is_checkpoint default to 0 / false
	var cut_def := JourneyData.coerce_node_save_data("cutscene", {"name": "X"})
	assert_bool(bool(cut_def.get("items_blocked", false))).is_true()
	assert_str(cut_def.get("award_item", "x")).is_equal("")
	assert_int(int(cut_def.get("coins", -1))).is_equal(0)
	assert_bool(bool(cut_def.get("is_checkpoint", true))).is_false()


# new_item templates for builder Add Node.
func test_new_item_cooldown_cutscene() -> void:
	var cd: Dictionary = JourneyData.new_item("cooldown")
	assert_str(cd.get("type", "")).is_equal("cooldown")
	assert_int(int(cd.get("days", 0))).is_equal(1)

	var cut: Dictionary = JourneyData.new_item("cutscene")
	assert_str(cut.get("type", "")).is_equal("cutscene")
	assert_bool(bool(cut.get("items_blocked", false))).is_true()
	assert_str(cut.get("video_path", "")).is_equal("")
	assert_str(cut.get("award_item", "x")).is_equal("")
	assert_int(int(cut.get("coins", -1))).is_equal(0)
	assert_bool(bool(cut.get("is_checkpoint", true))).is_false()
	assert_bool(cut.has("funscript_path")).is_false()


# Legacy round.cooldown_days still exposes via CurrentRound (back-compat path).
func test_legacy_round_cooldown_days_still_readable() -> void:
	var g := _g(
		"gap",
		{
			"gap":
			_n("round", ["session"], {"name": "Legacy Gap", "coins": 0, "cooldown_days": 1}),
			"session": _n("round", [], {"name": "Next", "coins": 0}),
		}
	)
	GameState.StartJourney(g)
	assert_str(GameState.CurrentItemType()).is_equal("round")
	assert_int(int(GameState.CurrentRound().get("cooldown_days", 0))).is_equal(1)
	assert_bool(GameState.CurrentCooldown().is_empty()).is_true()
