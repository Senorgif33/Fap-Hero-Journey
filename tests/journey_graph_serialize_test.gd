extends GdUnitTestSuite

# JourneyGraph serialization (Phase 1b). Proves the graph round-trips through journey.json
# and that JourneyScanner.parse_graph reads BOTH the new node format and (by migrating via
# build_graph) the legacy tree format. Locks the on-disk schema before the runtime cutover.
# No media files: rounds carry cached ActionCount/LengthMs so the legacy parse never hits disk.

const TEST_DIR := "user://test_graph_serialize"
const JOURNEY := "g"


func after() -> void:
	var base := ProjectSettings.globalize_path(TEST_DIR)
	DirAccess.remove_absolute(base + "/" + JOURNEY + "/journey.json")
	DirAccess.remove_absolute(base + "/" + JOURNEY)
	DirAccess.remove_absolute(base)


func _jdir() -> String:
	return TEST_DIR + "/" + JOURNEY


func _write_journey(data: Dictionary) -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(_jdir()))
	var f := FileAccess.open(_jdir() + "/journey.json", FileAccess.WRITE)
	f.store_string(JSON.stringify(data))
	f.close()


# ── Scanner-style fixtures (what build_graph consumes) ──────────────────────

func _round(order: int, name: String) -> Dictionary:
	return {"order": order, "name": name}

func _fork(after: int, title: String, paths: Array) -> Dictionary:
	return {"after_order": after, "title": title, "resolution": "choice", "paths": paths}

func _path(name: String, rounds: Array) -> Dictionary:
	return {"name": name, "rounds": rounds, "shops": [], "storyboards": [], "forks": []}

# A, FORK(P0=[X,Y], P1=[Z]), B — both paths rejoin at B.
func _fork_journey() -> Dictionary:
	return {
		"rounds": [_round(0, "A"), _round(1, "B")],
		"shops": [], "storyboards": [],
		"forks": [_fork(0, "F", [_path("P0", [_round(0, "X"), _round(1, "Y")]), _path("P1", [_round(0, "Z")])])],
	}


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

func _first_round_data(graph: Dictionary) -> Dictionary:
	for id: String in graph["nodes"]:
		if (graph["nodes"][id] as Dictionary)["type"] == "round":
			return graph["nodes"][id]["data"]
	return {}


# ── Tests ────────────────────────────────────────────────────────────────

# In-memory: to_json → from_json restores the same graph (walks + fork edges intact).
func test_to_json_from_json_round_trip() -> void:
	var g := JourneyGraph.build_graph(_fork_journey())
	var restored := JourneyGraph.from_json(JourneyGraph.to_json(g))
	assert_array(_walk(restored, [0])).is_equal(["round:A", "fork:F", "round:X", "round:Y", "round:B"])
	assert_array(_walk(restored, [1])).is_equal(["round:A", "fork:F", "round:Z", "round:B"])
	var b := _first_fork(restored)
	assert_int((b["out"] as Array).size()).is_equal(2)
	assert_str(b["out"][0]["name"]).is_equal("P0")


# Through disk: a fork + its edges survive JSON.stringify → file → parse_graph.
func test_disk_round_trip_preserves_fork() -> void:
	_write_journey(JourneyGraph.to_json(JourneyGraph.build_graph(_fork_journey())))
	var graph := JourneyScanner.parse_graph(_jdir(), JOURNEY)
	assert_array(_walk(graph, [0])).is_equal(["round:A", "fork:F", "round:X", "round:Y", "round:B"])
	assert_array(_walk(graph, [1])).is_equal(["round:A", "fork:F", "round:Z", "round:B"])


# parse_graph resolves a node's stored-relative media paths to absolute (base = folder).
func test_disk_round_trip_resolves_paths() -> void:
	var g := JourneyGraph.build_graph({
		"rounds": [{"order": 0, "name": "A", "funscript_path": "r001/s.funscript", "video_path": "content/v.mp4"}],
		"shops": [], "storyboards": [], "forks": [],
	})
	var journey_json := JourneyGraph.to_json(g)
	journey_json["Name"] = "Disk RT"   # journey-level meta sits alongside, harmlessly
	_write_journey(journey_json)
	var graph := JourneyScanner.parse_graph(_jdir(), JOURNEY)
	assert_array(_walk(graph, [])).is_equal(["round:A"])
	var rd := _first_round_data(graph)
	assert_str(rd["funscript_path"]).is_equal(_jdir() + "/r001/s.funscript")
	assert_str(rd["video_path"]).is_equal(_jdir() + "/content/v.mp4")


# parse_graph migrates a LEGACY (tree) journey.json — no "Nodes" key — via build_graph,
# producing the same walk as the graph format. Cached stats keep the parse off disk.
func test_parse_graph_migrates_legacy() -> void:
	_write_journey({
		"Name": "Legacy",
		"Rounds": [
			{"Name": "A", "FolderName": "r001", "FunscriptPath": "r001/s.funscript", "ActionCount": 3, "LengthMs": 1000, "Order": 0},
			{"Name": "B", "FolderName": "r002", "FunscriptPath": "r002/s.funscript", "ActionCount": 3, "LengthMs": 1000, "Order": 1},
		],
		"Forks": [{"AfterOrder": 0, "Title": "F", "Resolution": "choice", "Paths": [
			{"Name": "P0", "Rounds": [{"Name": "X", "FolderName": "fork0_p0_r001", "FunscriptPath": "fork0_p0_r001/s.funscript", "ActionCount": 1, "LengthMs": 100, "Order": 0}], "Shops": [], "Storyboards": [], "Forks": []},
			{"Name": "P1", "Rounds": [{"Name": "Z", "FolderName": "fork0_p1_r001", "FunscriptPath": "fork0_p1_r001/s.funscript", "ActionCount": 1, "LengthMs": 100, "Order": 0}], "Shops": [], "Storyboards": [], "Forks": []},
		]}],
		"Shops": [], "Storyboards": [],
	})
	var graph := JourneyScanner.parse_graph(_jdir(), JOURNEY)
	assert_array(_walk(graph, [0])).is_equal(["round:A", "fork:F", "round:X", "round:B"])
	assert_array(_walk(graph, [1])).is_equal(["round:A", "fork:F", "round:Z", "round:B"])


# New-format parse_graph carries journey meta + a DAG total alongside the graph.
func test_parse_graph_carries_meta_new_format() -> void:
	var jj := JourneyGraph.to_json(JourneyGraph.build_graph(_fork_journey()))
	jj["Name"] = "Graphy"
	jj["Author"] = "Mara"
	jj["MapEnabled"] = false
	_write_journey(jj)
	var g := JourneyScanner.parse_graph(_jdir(), JOURNEY)
	assert_str(g["title"]).is_equal("Graphy")
	assert_str(g["author"]).is_equal("Mara")
	assert_bool(g["map_enabled"]).is_false()
	assert_int(g["total_rounds"]).is_equal(4)   # longest round path A → X → Y → B
	assert_str(g["start"]).is_not_equal("")      # graph still attached


# Legacy parse_graph keeps the nested model (map/catalogue still work) AND attaches the
# migrated graph under start/nodes.
func test_parse_graph_legacy_keeps_nested_and_adds_graph() -> void:
	_write_journey({
		"Name": "Legacy2", "Author": "T",
		"Rounds": [{"Name": "A", "FolderName": "r001", "FunscriptPath": "r001/s.funscript", "ActionCount": 2, "LengthMs": 500, "Order": 0}],
		"Forks": [], "Shops": [], "Storyboards": [],
	})
	var g := JourneyScanner.parse_graph(_jdir(), JOURNEY)
	assert_str(g["title"]).is_equal("Legacy2")
	assert_int((g["rounds"] as Array).size()).is_equal(1)   # nested model still present
	assert_str(g["start"]).is_not_equal("")                  # graph attached
	assert_array(_walk(g, [])).is_equal(["round:A"])


# An empty / missing journey returns {} rather than erroring.
func test_missing_returns_empty() -> void:
	assert_dict(JourneyScanner.parse_graph(TEST_DIR + "/nope", "nope")).is_empty()
