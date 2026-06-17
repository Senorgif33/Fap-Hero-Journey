extends GdUnitTestSuite

# JourneyGraph migration (tree → DAG). The cutover hinges on this being behaviour-
# preserving: walking the migrated graph must reproduce exactly what the old tree
# runtime (GameState.BuildSequence + ResolveFork + fork_end) produced — same item
# order, and every fork path rejoining at the node that followed the fork. Each fork's
# implicit rejoin becomes an EXPLICIT edge (path tail → post-fork node), which is what
# later lets authors rewire it to skip/converge.

func _round(order: int, name: String) -> Dictionary:
	return {"order": order, "name": name}

func _fork(after: int, title: String, paths: Array) -> Dictionary:
	return {"after_order": after, "title": title, "resolution": "choice", "paths": paths}

func _path(name: String, rounds: Array, forks: Array = []) -> Dictionary:
	return {"name": name, "rounds": rounds, "shops": [], "storyboards": [], "forks": forks}

# A round A, a 2-path fork after it (P0 = [X, Y], P1 = [Z]), then round B. Both paths
# must rejoin at B — the canonical tree shape.
func _fork_journey() -> Dictionary:
	return {
		"rounds": [_round(0, "A"), _round(1, "B")],
		"shops": [], "storyboards": [],
		"forks": [_fork(0, "F", [
			_path("P0", [_round(0, "X"), _round(1, "Y")]),
			_path("P1", [_round(0, "Z")]),
		])],
	}


# Walks the graph from start, taking `fork_choices[i]` at the i-th fork reached.
# Returns a label per node: "<type>:<name/title>" (forks as "fork:<title>").
func _walk(graph: Dictionary, fork_choices: Array) -> Array:
	var seq: Array = []
	var id: String = graph["start"]
	var bi: int = 0
	var guard: int = 0
	while id != "" and guard < 200:
		guard += 1
		var n: Dictionary = JourneyGraph.node(graph, id)
		if n.is_empty():
			break
		if n["type"] == JourneyGraph.FORK_TYPE:
			seq.append("fork:%s" % n["data"].get("title", ""))
			var edges: Array = n["out"]
			var idx: int = int(fork_choices[bi]) if bi < fork_choices.size() else 0
			bi += 1
			id = str(edges[idx]["to"]) if idx < edges.size() else ""
		else:
			seq.append("%s:%s" % [n["type"], n["data"].get("name", n["data"].get("title", ""))])
			var out: Array = n["out"]
			id = str(out[0]["to"]) if not out.is_empty() else ""
	return seq


func _first_fork(graph: Dictionary) -> Dictionary:
	for id: String in graph["nodes"]:
		if (graph["nodes"][id] as Dictionary)["type"] == JourneyGraph.FORK_TYPE:
			return graph["nodes"][id]
	return {}

# Node id of the round named `name` (ids are positional; tests look up by content).
func _id_of(graph: Dictionary, name: String) -> String:
	for id: String in graph["nodes"]:
		var n: Dictionary = graph["nodes"][id]
		if n["type"] == "round" and n["data"].get("name", "") == name:
			return id
	return ""

func _depth_of(graph: Dictionary, name: String) -> int:
	var id: String = _id_of(graph, name)
	return int((graph["nodes"][id] as Dictionary).get("depth", -1)) if id != "" else -1


# Each path plays its own rounds, then BOTH rejoin at B (the explicit rejoin edge).
func test_migration_walks_each_path_and_rejoins() -> void:
	var g := JourneyGraph.build_graph(_fork_journey())
	assert_array(_walk(g, [0])).is_equal(["round:A", "fork:F", "round:X", "round:Y", "round:B"])
	assert_array(_walk(g, [1])).is_equal(["round:A", "fork:F", "round:Z", "round:B"])


# A plain linear journey maps to a simple chain.
func test_linear_journey() -> void:
	var g := JourneyGraph.build_graph({
		"rounds": [_round(0, "A"), _round(1, "B"), _round(2, "C")],
		"shops": [], "storyboards": [], "forks": [],
	})
	assert_array(_walk(g, [])).is_equal(["round:A", "round:B", "round:C"])
	assert_str(g["start"]).is_not_equal("")


# Interleave: a shop authored between two rounds sorts between them (key after*3+1).
func test_shop_interleave() -> void:
	var g := JourneyGraph.build_graph({
		"rounds": [_round(0, "A"), _round(1, "B")],
		"shops": [{"after_order": 0, "title": "S"}],
		"storyboards": [], "forks": [],
	})
	assert_array(_walk(g, [])).is_equal(["round:A", "shop:S", "round:B"])


# A fork as the LAST item: its paths run out at an end (no rejoin node exists).
func test_fork_last_paths_reach_end() -> void:
	var g := JourneyGraph.build_graph({
		"rounds": [_round(0, "A")], "shops": [], "storyboards": [],
		"forks": [_fork(0, "F", [_path("P0", [_round(0, "X")]), _path("P1", [_round(0, "Z")])])],
	})
	assert_array(_walk(g, [0])).is_equal(["round:A", "fork:F", "round:X"])
	assert_array(_walk(g, [1])).is_equal(["round:A", "fork:F", "round:Z"])


# An empty path edge points straight at the rejoin (no wasted node).
func test_empty_path_goes_straight_to_rejoin() -> void:
	var g := JourneyGraph.build_graph({
		"rounds": [_round(0, "A"), _round(1, "B")], "shops": [], "storyboards": [],
		"forks": [_fork(0, "F", [_path("P0", []), _path("P1", [_round(0, "Z")])])],
	})
	assert_array(_walk(g, [0])).is_equal(["round:A", "fork:F", "round:B"])
	assert_array(_walk(g, [1])).is_equal(["round:A", "fork:F", "round:Z", "round:B"])


# Fork meta lands on the node; per-choice config lands on the edges.
func test_fork_meta_and_edge_config() -> void:
	var fork := _fork(0, "F", [
		{"name": "Pay", "rounds": [_round(0, "X")], "shops": [], "storyboards": [], "forks": [],
		 "weight": 3, "threshold": 50, "required_item": "key", "cost": 20, "image_path": "media/x.png"},
		_path("Free", [_round(0, "Z")]),
	])
	fork["resolution"] = "sacrifice"
	fork["cond_metric"] = "coins"
	fork["default_path"] = 1
	var g := JourneyGraph.build_graph({"rounds": [_round(0, "A")], "shops": [], "storyboards": [], "forks": [fork]})
	var b := _first_fork(g)
	assert_str(b["data"]["resolution"]).is_equal("sacrifice")
	assert_str(b["data"]["cond_metric"]).is_equal("coins")
	assert_int(b["data"]["default_path"]).is_equal(1)
	var e0: Dictionary = b["out"][0]
	assert_str(e0["name"]).is_equal("Pay")
	assert_int(e0["weight"]).is_equal(3)
	assert_int(e0["threshold"]).is_equal(50)
	assert_str(e0["required_item"]).is_equal("key")
	assert_int(e0["cost"]).is_equal(20)
	assert_str(e0["image_path"]).is_equal("media/x.png")


# Trajectory-relative progress basis: longest round-count to any end. For _fork_journey
# that's A → X → Y → B = 4 (the P0 fork), not the shorter P1 (A,Z,B = 3).
func test_longest_round_path() -> void:
	var g := JourneyGraph.build_graph(_fork_journey())
	assert_int(JourneyGraph.longest_round_path(g, g["start"])).is_equal(4)


# Nested fork inside a path still rejoins correctly (depth-2 tree → graph).
func test_nested_fork() -> void:
	var inner := _fork(0, "Inner", [_path("Q0", [_round(0, "M")])])
	var outer := _fork(0, "Outer", [_path("P0", [_round(0, "X")], [inner]), _path("P1", [_round(0, "Z")])])
	var g := JourneyGraph.build_graph({
		"rounds": [_round(0, "A"), _round(1, "B")], "shops": [], "storyboards": [], "forks": [outer],
	})
	# Outer P0 → X, then the inner fork → Q0 = [M], rejoining the inner at B, then B.
	assert_array(_walk(g, [0, 0])).is_equal(["round:A", "fork:Outer", "round:X", "fork:Inner", "round:M", "round:B"])
	# Outer P1 → Z → B.
	assert_array(_walk(g, [1])).is_equal(["round:A", "fork:Outer", "round:Z", "round:B"])


# A redirect points a node past its default successor — a skip ahead.
func test_redirect_skips_ahead() -> void:
	var g := JourneyGraph.build_graph({
		"rounds": [_round(0, "A"), _round(1, "B"), _round(2, "C")], "shops": [], "storyboards": [], "forks": [],
	})
	JourneyGraph.apply_redirects(g, {_id_of(g, "A"): _id_of(g, "C")})
	assert_array(_walk(g, [])).is_equal(["round:A", "round:C"])   # B skipped


# A redirect to "" ends the journey early.
func test_redirect_to_end() -> void:
	var g := JourneyGraph.build_graph({
		"rounds": [_round(0, "A"), _round(1, "B")], "shops": [], "storyboards": [], "forks": [],
	})
	JourneyGraph.apply_redirects(g, {_id_of(g, "A"): ""})
	assert_array(_walk(g, [])).is_equal(["round:A"])


# Both fork paths skip the default rejoin (B) and converge directly onto C.
func test_redirect_converges_paths() -> void:
	var g := JourneyGraph.build_graph({
		"rounds": [_round(0, "A"), _round(1, "B"), _round(2, "C")],
		"shops": [], "storyboards": [],
		"forks": [_fork(0, "F", [_path("P0", [_round(0, "X")]), _path("P1", [_round(0, "Z")])])],
	})
	var c := _id_of(g, "C")
	JourneyGraph.apply_redirects(g, {_id_of(g, "X"): c, _id_of(g, "Z"): c})   # both skip B → C
	assert_array(_walk(g, [0])).is_equal(["round:A", "fork:F", "round:X", "round:C"])
	assert_array(_walk(g, [1])).is_equal(["round:A", "fork:F", "round:Z", "round:C"])


# Nodes carry their tree-nesting depth (reproduces the old fork_depth for the end screen).
func test_node_depth_tracks_nesting() -> void:
	var inner := _fork(0, "Inner", [_path("Q0", [_round(0, "M")])])
	var outer := _fork(0, "Outer", [_path("P0", [_round(0, "X")], [inner])])
	var g := JourneyGraph.build_graph({
		"rounds": [_round(0, "A")], "shops": [], "storyboards": [], "forks": [outer],
	})
	assert_int(_depth_of(g, "A")).is_equal(0)   # top level
	assert_int(_depth_of(g, "X")).is_equal(1)   # inside outer's path
	assert_int(_depth_of(g, "M")).is_equal(2)   # inside inner's path
