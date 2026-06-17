extends GdUnitTestSuite

# GameState (C#) sequence + fork splicing — the deterministic core of journey
# progression. Driven through the GameState autoload from GDScript. Each test
# calls StartJourney (which resets index/sequence/depth/log), so no shared state
# leaks between tests. The fork *decision* (which path) is GameLoop's job and
# isn't covered here — ResolveFork takes the index, so this is all deterministic.

func _round(order: int, name: String) -> Dictionary:
	return {"order": order, "name": name}


func _fork(after_order: int, title: String, paths: Array) -> Dictionary:
	return {"after_order": after_order, "title": title, "paths": paths}


func _path(name: String, rounds: Array, forks: Array = []) -> Dictionary:
	return {"name": name, "rounds": rounds, "forks": forks, "shops": [], "storyboards": []}


# A round + a 2-path fork after it. P0 = [X, Y], P1 = [Z].
func _fork_journey() -> Dictionary:
	return {
		"rounds": [_round(0, "A")], "shops": [], "storyboards": [],
		"forks": [_fork(0, "F", [
			_path("P0", [_round(0, "X"), _round(1, "Y")]),
			_path("P1", [_round(0, "Z")]),
		])],
	}


# Items interleave by the order*3 / +1 / +2 sort scheme (round/shop/storyboard/fork).
func test_build_sequence_ordering() -> void:
	GameState.StartJourney({
		"rounds": [_round(0, "A"), _round(1, "B")],
		"shops": [{"after_order": 0}],          # key 0*3+1 = 1, between A and B
		"storyboards": [], "forks": [],
	})
	assert_str(GameState.CurrentItemType()).is_equal("round")    # A (key 0)
	assert_str(GameState.CurrentRound()["name"]).is_equal("A")
	GameState.Advance()
	assert_str(GameState.CurrentItemType()).is_equal("shop")     # key 1
	GameState.Advance()
	assert_str(GameState.CurrentItemType()).is_equal("round")    # B (key 3)
	assert_str(GameState.CurrentRound()["name"]).is_equal("B")
	GameState.Advance()
	assert_bool(GameState.IsSequenceDone()).is_true()


# A fork authored before a shop keeps that order at runtime — the exact case that
# broke "Test From Here". Under the monotonic save every item gets a unique,
# increasing position (round 1, fork 2, shop 3), so the fork's key (2*3+2 = 8)
# sorts before the shop's (3*3+1 = 10): the fork lands at sequence index 1, the
# shop at 2. (The old "anchor shops/forks to the previous round" scheme gave both
# the same anchor and sorted the shop's +1 ahead of the fork's +2, reordering
# them.) Guards the "runtime position == authoring/array index" invariant that
# _locate_node_for_test relies on to seek into a fork's path.
func test_fork_before_shop_keeps_authoring_order() -> void:
	GameState.StartJourney({
		"rounds": [_round(1, "A")],
		"forks": [_fork(2, "F", [_path("P0", [_round(0, "X")])])],
		"shops": [{"after_order": 3, "title": "S"}],
		"storyboards": [],
	})
	assert_str(GameState.CurrentItemType()).is_equal("round")       # index 0
	assert_str(GameState.CurrentRound()["name"]).is_equal("A")
	GameState.Advance()
	assert_int(GameState.RoundIndex).is_equal(1)                    # fork at index 1…
	assert_str(GameState.CurrentItemType()).is_equal("fork")        # …NOT the shop
	assert_str(GameState.CurrentFork()["title"]).is_equal("F")
	GameState.Advance()
	assert_str(GameState.CurrentItemType()).is_equal("shop")        # index 2
	assert_str(GameState.CurrentShop()["title"]).is_equal("S")


# Before resolution, only the top-level round counts toward TotalRounds.
func test_fork_unresolved_round_counts() -> void:
	GameState.StartJourney(_fork_journey())
	assert_int(GameState.TotalRounds()).is_equal(1)              # A only; fork paths not spliced
	GameState.Advance()
	assert_str(GameState.CurrentItemType()).is_equal("fork")
	assert_str(GameState.CurrentFork()["title"]).is_equal("F")


# Resolving splices the chosen path's rounds in and lands on the first of them.
func test_resolve_fork_splices_chosen_path() -> void:
	GameState.StartJourney(_fork_journey())
	GameState.Advance()                                          # → fork
	GameState.ResolveFork(0)                                     # P0 = [X, Y]
	assert_str(GameState.CurrentItemType()).is_equal("round")
	assert_str(GameState.CurrentRound()["name"]).is_equal("X")
	assert_int(GameState.TotalRounds()).is_equal(3)             # A, X, Y
	assert_int(GameState.RoundNumber).is_equal(2)              # A then X
	assert_bool(GameState.IsLastRound()).is_false()
	GameState.Advance()
	assert_str(GameState.CurrentRound()["name"]).is_equal("Y")
	assert_bool(GameState.IsLastRound()).is_true()             # only fork_end follows
	GameState.Advance()
	assert_bool(GameState.IsSequenceDone()).is_true()          # fork_end consumed


# Path index selects the path; out-of-range and negative clamp to path 0.
func test_resolve_fork_path_selection_and_clamp() -> void:
	GameState.StartJourney(_fork_journey())
	GameState.Advance()
	GameState.ResolveFork(1)                                     # P1 = [Z]
	assert_str(GameState.CurrentRound()["name"]).is_equal("Z")

	GameState.StartJourney(_fork_journey())
	GameState.Advance()
	GameState.ResolveFork(99)                                    # clamps to P0
	assert_str(GameState.CurrentRound()["name"]).is_equal("X")

	GameState.StartJourney(_fork_journey())
	GameState.Advance()
	GameState.ResolveFork(-1)                                    # clamps to P0
	assert_str(GameState.CurrentRound()["name"]).is_equal("X")


# A fork nested inside a path: depth increments per resolution and the back-to-back
# fork_end sentinels are consumed together at the end.
func test_nested_fork_depth() -> void:
	var inner := _fork(0, "Inner", [_path("Q0", [_round(0, "M")])])
	var outer := _fork(0, "Outer", [_path("P0", [_round(0, "X")], [inner])])
	GameState.StartJourney({"rounds": [_round(0, "A")], "shops": [], "storyboards": [], "forks": [outer]})

	GameState.Advance()                                         # → outer fork
	GameState.ResolveFork(0)                                    # splice P0 = [X, inner-fork]
	assert_int(GameState.CaptureSaveData()["fork_depth"]).is_equal(1)
	assert_str(GameState.CurrentRound()["name"]).is_equal("X")

	GameState.Advance()                                         # → inner fork
	assert_str(GameState.CurrentItemType()).is_equal("fork")
	GameState.ResolveFork(0)                                    # splice Q0 = [M]
	assert_int(GameState.CaptureSaveData()["fork_depth"]).is_equal(2)
	assert_str(GameState.CurrentRound()["name"]).is_equal("M")
	assert_int(GameState.TotalRounds()).is_equal(3)            # A, X, M

	GameState.Advance()                                        # consume both fork_end sentinels
	assert_bool(GameState.IsSequenceDone()).is_true()
	assert_int(GameState.CaptureSaveData()["fork_depth"]).is_equal(0)


# Capturing after a fork choice and reloading restores the spliced sequence,
# position, and depth (so a resumed run keeps the path already chosen).
func test_save_restores_spliced_sequence() -> void:
	GameState.StartJourney(_fork_journey())
	GameState.Advance()
	GameState.ResolveFork(0)                                    # now on X, depth 1
	var snapshot: Dictionary = GameState.CaptureSaveData()

	GameState.StartJourney(_fork_journey())                    # wipe to a fresh build
	GameState.LoadFromSave(_fork_journey(), snapshot)
	assert_str(GameState.CurrentRound()["name"]).is_equal("X")
	assert_int(GameState.TotalRounds()).is_equal(3)
	assert_int(GameState.CaptureSaveData()["fork_depth"]).is_equal(1)


# Current* accessors return the right dict for the current item type, empty otherwise.
func test_current_accessors() -> void:
	GameState.StartJourney({
		"rounds": [_round(0, "A")], "shops": [{"after_order": 0, "title": "S"}],
		"storyboards": [], "forks": [],
	})
	assert_str(GameState.CurrentRound()["name"]).is_equal("A")
	assert_bool(GameState.CurrentFork().is_empty()).is_true()
	assert_bool(GameState.CurrentShop().is_empty()).is_true()
	GameState.Advance()
	assert_str(GameState.CurrentItemType()).is_equal("shop")
	assert_bool(GameState.CurrentRound().is_empty()).is_true()
	assert_str(GameState.CurrentShop()["title"]).is_equal("S")
