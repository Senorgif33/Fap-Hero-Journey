extends GdUnitTestSuite

# Cooldown Force Save & Quit must advance past the gap before capturing
# current_node — otherwise Resume re-enters the gap and locks out again.


func _gap_then_session_graph() -> Dictionary:
	return {
		"start": "gap",
		"nodes":
		{
			"gap":
			{
				"type": "round",
				"data": {"name": "Cooldown Gap", "coins": 0, "cooldown_days": 1},
				"out": [{"to": "session"}],
			},
			"session":
			{
				"type": "round",
				"data": {"name": "Punish Session", "coins": 15, "cooldown_days": 0},
				"out": [],
			},
		},
	}


# Mirrors GameLoop._on_cooldown_save_and_quit: Advance then CaptureSaveData.
func test_cooldown_save_advances_to_next_node() -> void:
	GameState.StartJourney(_gap_then_session_graph())
	assert_str(GameState.CurrentNodeId()).is_equal("gap")
	assert_int(int(GameState.CurrentRound().get("cooldown_days", 0))).is_equal(1)

	# Same contract as _on_cooldown_save_and_quit before _write_journey_save.
	assert_bool(GameState.IsLastRound()).is_false()
	GameState.Advance()

	var snap: Dictionary = GameState.CaptureSaveData()
	assert_str(str(snap.get("current_node", ""))).is_equal("session")
	assert_str(GameState.CurrentRound().get("name", "")).is_equal("Punish Session")
	assert_int(int(GameState.CurrentRound().get("cooldown_days", -1))).is_equal(0)


# Resume from that save must open the session, not the gap.
func test_cooldown_resume_loads_session_not_gap() -> void:
	var journey: Dictionary = _gap_then_session_graph()
	GameState.StartJourney(journey)
	GameState.Advance()
	var snap: Dictionary = GameState.CaptureSaveData()

	GameState.LoadFromSave(journey, snap)
	assert_str(GameState.CurrentNodeId()).is_equal("session")
	assert_str(GameState.CurrentRound().get("name", "")).is_equal("Punish Session")
	assert_int(int(GameState.CurrentRound().get("cooldown_days", -1))).is_equal(0)
