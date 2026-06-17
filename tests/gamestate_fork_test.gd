extends GdUnitTestSuite

# GameState (C#) graph walk + fork resolution — the deterministic core of journey
# progression after the graph cutover. Fixtures are the scanner's nested model; we run
# them through JourneyGraph.build_graph (migration) and StartJourney walks the resulting
# DAG. The fork *decision* (which edge) is GameLoop's job — ResolveFork takes the index,
# so this stays deterministic. Behaviour matches the old spliced-sequence model: same item
# order, fork paths rejoining at the node that followed the fork.

func _round(order: int, name: String) -> Dictionary:
	return {"order": order, "name": name}

func _fork(after_order: int, title: String, paths: Array) -> Dictionary:
	return {"after_order": after_order, "title": title, "paths": paths}

func _path(name: String, rounds: Array, forks: Array = []) -> Dictionary:
	return {"name": name, "rounds": rounds, "forks": forks, "shops": [], "storyboards": []}

# A round + a 2-path fork after it. P0 = [X, Y], P1 = [Z]. Fork is last → paths end.
func _fork_journey() -> Dictionary:
	return {
		"rounds": [_round(0, "A")], "shops": [], "storyboards": [],
		"forks": [_fork(0, "F", [
			_path("P0", [_round(0, "X"), _round(1, "Y")]),
			_path("P1", [_round(0, "Z")]),
		])],
	}

# Starts a journey by migrating the nested fixture to the graph (what parse_graph does).
func _start(journey: Dictionary) -> void:
	GameState.StartJourney(JourneyGraph.build_graph(journey))


# Items interleave by the order*3 / +1 / +2 scheme (round/shop/storyboard/fork).
func test_walk_ordering() -> void:
	_start({
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


# A fork authored before a shop stays before it: A's successor is the fork, and the shop
# only follows once the fork's path rejoins. (Guards the migration's interleave ordering —
# the old "shop reorders ahead of the fork" bug.)
func test_fork_before_shop_keeps_authoring_order() -> void:
	_start({
		"rounds": [_round(1, "A")],
		"forks": [_fork(2, "F", [_path("P0", [_round(0, "X")])])],
		"shops": [{"after_order": 3, "title": "S"}],
		"storyboards": [],
	})
	assert_str(GameState.CurrentRound()["name"]).is_equal("A")
	GameState.Advance()
	assert_str(GameState.CurrentItemType()).is_equal("fork")     # A → fork, NOT the shop
	assert_str(GameState.CurrentFork()["title"]).is_equal("F")
	GameState.ResolveFork(0)
	assert_str(GameState.CurrentRound()["name"]).is_equal("X")
	GameState.Advance()
	assert_str(GameState.CurrentItemType()).is_equal("shop")     # shop follows the path
	assert_str(GameState.CurrentShop()["title"]).is_equal("S")


# Before resolution, TotalRounds is the trajectory MAX — the longest round path ahead
# (A → P0[X,Y] = 3), not just the rounds resolved so far.
func test_fork_unresolved_total_is_longest_path() -> void:
	_start(_fork_journey())
	assert_int(GameState.TotalRounds()).is_equal(3)
	GameState.Advance()
	assert_str(GameState.CurrentItemType()).is_equal("fork")
	assert_str(GameState.CurrentFork()["title"]).is_equal("F")


# Resolving a fork enters the chosen path's first node; counts track the path taken.
func test_resolve_fork_enters_chosen_path() -> void:
	_start(_fork_journey())
	GameState.Advance()                                          # → fork
	GameState.ResolveFork(0)                                     # P0 = [X, Y]
	assert_str(GameState.CurrentItemType()).is_equal("round")
	assert_str(GameState.CurrentRound()["name"]).is_equal("X")
	assert_int(GameState.TotalRounds()).is_equal(3)             # A, X, Y on this path
	assert_int(GameState.RoundNumber).is_equal(2)              # A then X
	assert_bool(GameState.IsLastRound()).is_false()
	GameState.Advance()
	assert_str(GameState.CurrentRound()["name"]).is_equal("Y")
	assert_bool(GameState.IsLastRound()).is_true()             # nothing follows Y
	GameState.Advance()
	assert_bool(GameState.IsSequenceDone()).is_true()


# Path index selects the edge; out-of-range and negative clamp to edge 0.
func test_resolve_fork_path_selection_and_clamp() -> void:
	_start(_fork_journey())
	GameState.Advance()
	GameState.ResolveFork(1)                                     # P1 = [Z]
	assert_str(GameState.CurrentRound()["name"]).is_equal("Z")

	_start(_fork_journey())
	GameState.Advance()
	GameState.ResolveFork(99)                                    # clamps to P0
	assert_str(GameState.CurrentRound()["name"]).is_equal("X")

	_start(_fork_journey())
	GameState.Advance()
	GameState.ResolveFork(-1)                                    # clamps to P0
	assert_str(GameState.CurrentRound()["name"]).is_equal("X")


# A fork nested inside a path resolves correctly and the run ends after the deepest path.
func test_nested_fork() -> void:
	var inner := _fork(0, "Inner", [_path("Q0", [_round(0, "M")])])
	var outer := _fork(0, "Outer", [_path("P0", [_round(0, "X")], [inner])])
	_start({"rounds": [_round(0, "A")], "shops": [], "storyboards": [], "forks": [outer]})

	GameState.Advance()                                         # → outer fork
	assert_str(GameState.CurrentFork()["title"]).is_equal("Outer")
	GameState.ResolveFork(0)                                    # P0 = [X, inner-fork]
	assert_str(GameState.CurrentRound()["name"]).is_equal("X")

	GameState.Advance()                                         # → inner fork
	assert_str(GameState.CurrentItemType()).is_equal("fork")
	assert_str(GameState.CurrentFork()["title"]).is_equal("Inner")
	GameState.ResolveFork(0)                                    # Q0 = [M]
	assert_str(GameState.CurrentRound()["name"]).is_equal("M")
	assert_int(GameState.TotalRounds()).is_equal(3)            # A, X, M

	GameState.Advance()
	assert_bool(GameState.IsSequenceDone()).is_true()


# Capturing after a fork choice and reloading restores the current node + progress, so a
# resumed run keeps the path already taken.
func test_save_restores_position() -> void:
	_start(_fork_journey())
	GameState.Advance()
	GameState.ResolveFork(0)                                    # on X (P0)
	var snapshot: Dictionary = GameState.CaptureSaveData()

	_start(_fork_journey())                                     # wipe to a fresh build
	GameState.LoadFromSave(JourneyGraph.build_graph(_fork_journey()), snapshot)
	assert_str(GameState.CurrentRound()["name"]).is_equal("X")
	assert_int(GameState.RoundNumber).is_equal(2)             # A then X
	assert_int(GameState.TotalRounds()).is_equal(3)           # A, X, Y


# Current* accessors return the right dict for the current node type, empty otherwise.
func test_current_accessors() -> void:
	_start({
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
