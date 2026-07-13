extends GdUnitTestSuite

# RandomizerRun — the launch glue, tested end-to-end against the REAL scanner:
# generate → materialize a run folder → JourneyScanner.parse_graph (the exact call
# the play button makes) → assert it loads to a valid, playable graph with resolved
# media paths. This is the integration check that the generated Format-2 journey.json
# actually round-trips through the shipping load path.

const STORE: String = "user://test_rand_store"

var _run_folder: String = ""


func before_test() -> void:
	JourneyData.delete_dir_recursive(STORE)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(STORE + "/content"))


func after_test() -> void:
	JourneyData.delete_dir_recursive(STORE)
	if _run_folder != "":
		JourneyData.delete_dir_recursive(_run_folder)
		_run_folder = ""


# Builds `n` library entries AND writes their dummy pooled files into the test
# store, so materialize has real files to link/copy.
func _make_library(n: int) -> Array:
	var out: Array = []
	for i in n:
		var id: String = "c%02d" % i
		var vrel: String = "content/m_%s.mp4" % id
		var frel: String = "content/m_%s.funscript" % id
		_write(STORE + "/" + vrel, "fake-video-bytes")
		_write(STORE + "/" + frel, '{"actions":[]}')
		(
			out
			. append(
				{
					"id": id,
					"name": id,
					"video_rel": vrel,
					"funscript_rel": frel,
					"axis_rel": {},
					"vib_rel": {},
					"boss_image_rel": "",
					"action_count": 50,
					"length_ms": 60000,
					"duration_ms": 60000,
					"tags": [],
					"weight": 1.0,
					"intensity": 3,
					"last_used": 0,
				}
			)
		)
	return out


func _write(path: String, text: String) -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(path.get_base_dir()))
	var f: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
	f.close()


func _count_rounds(nodes: Dictionary) -> int:
	var c: int = 0
	for id: String in nodes:
		if str((nodes[id] as Dictionary).get("type", "")) == "round":
			c += 1
	return c


# ── Tests ────────────────────────────────────────────────────────────────────


func test_materialize_writes_folder_and_content() -> void:
	var lib: Array = _make_library(3)
	var res: Dictionary = RandomizerGenerator.generate(lib, {"seed": 1, "round_count": 3})
	var mat: Dictionary = RandomizerRun.materialize(res["journey"], res["content_rels"], STORE)
	_run_folder = mat["folder"]

	assert_bool(mat["ok"]).is_true()
	assert_bool(FileAccess.file_exists(mat["folder"] + "/journey.json")).is_true()
	# Every referenced pooled file was linked/copied into the run folder.
	for rel: String in res["content_rels"]:
		assert_bool(FileAccess.file_exists(mat["folder"] + "/" + rel)).is_true()


func test_generated_run_loads_through_scanner() -> void:
	var lib: Array = _make_library(5)
	var res: Dictionary = RandomizerGenerator.generate(
		lib, {"seed": 4, "round_count": 5, "shop_every": 2, "boss_finale": true}
	)
	var mat: Dictionary = RandomizerRun.materialize(res["journey"], res["content_rels"], STORE)
	_run_folder = mat["folder"]
	assert_bool(mat["ok"]).is_true()

	# The exact call _on_play_pressed_unguarded makes.
	var play: Dictionary = JourneyScanner.parse_graph(mat["folder"], mat["folder_name"])
	assert_bool(play.is_empty()).is_false()
	assert_bool(play.has("start")).is_true()
	assert_bool(play.has("nodes")).is_true()

	# Structurally valid DAG (no dangling / cycle / unreachable / bad start).
	var graph: Dictionary = {"start": play["start"], "nodes": play["nodes"]}
	assert_array(JourneyGraph.validate_graph(graph)).is_empty()
	assert_int(_count_rounds(play["nodes"])).is_equal(5)


func test_scanner_resolves_media_to_existing_files() -> void:
	var lib: Array = _make_library(2)
	var res: Dictionary = RandomizerGenerator.generate(lib, {"seed": 2, "round_count": 2})
	var mat: Dictionary = RandomizerRun.materialize(res["journey"], res["content_rels"], STORE)
	_run_folder = mat["folder"]

	var play: Dictionary = JourneyScanner.parse_graph(mat["folder"], mat["folder_name"])
	# Each round's video_path is now an ABSOLUTE path to a file that exists on disk.
	for id: String in play["nodes"]:
		var node: Dictionary = play["nodes"][id]
		if str(node.get("type", "")) != "round":
			continue
		var vpath: String = str((node.get("data", {}) as Dictionary).get("video_path", ""))
		assert_bool(vpath.is_absolute_path()).is_true()
		assert_bool(FileAccess.file_exists(vpath)).is_true()


func test_missing_pooled_file_fails_cleanly() -> void:
	var lib: Array = _make_library(2)
	var res: Dictionary = RandomizerGenerator.generate(lib, {"seed": 1, "round_count": 2})
	# Delete a pooled source so materialize can't find it.
	DirAccess.remove_absolute(ProjectSettings.globalize_path(STORE + "/" + res["content_rels"][0]))

	var mat: Dictionary = RandomizerRun.materialize(res["journey"], res["content_rels"], STORE)
	assert_bool(mat["ok"]).is_false()
	assert_str(mat["reason"]).is_equal("missing_pooled_file")
	# On failure no folder handle is returned (the partial run was cleaned up).
	assert_str(str(mat["folder"])).is_equal("")
