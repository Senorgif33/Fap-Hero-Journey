extends Node

# ---------------------------------------------------------------------------
# ScoreboardService  (autoload)
#
# Per-journey local run history. One file per journey at
# `user://scoreboards/<journey_folder_name>.json`, keyed the same way as
# JourneySaveService so the two stay in lockstep (a journey rebuild or deletion
# clears both). Pure file I/O — callers hand in a run entry, this stamps the
# date and keeps the list ranked + capped.
#
# A "run" is recorded when a journey ends: completed (reached the end screen) or
# abandoned (quit to menu mid-journey). Save & Quit at a checkpoint is NOT a run
# — it's intent to resume. Test plays never record.
#
# File schema:
#   {
#     "version": int,
#     "journey_folder": String,
#     "runs": [
#       { "score": int, "completed": bool, "rounds_done": int,
#         "rounds_total": int, "date": String (ISO) },
#       ...
#     ]   # ranked by score desc, capped to MAX_RUNS
#   }
#
# C# callers reach this via the autoload node:
#   GetNode("/root/ScoreboardService").Call("add_run", folder, entry)
# ---------------------------------------------------------------------------

const SCOREBOARD_DIR: String = "user://scoreboards"
const SCHEMA_VERSION: int = 1
const MAX_RUNS: int = 10  # the board keeps the top N runs by score


func _ready() -> void:
	var dir_abs: String = ProjectSettings.globalize_path(SCOREBOARD_DIR)
	if not DirAccess.dir_exists_absolute(dir_abs):
		DirAccess.make_dir_recursive_absolute(dir_abs)


func _path_for(journey_folder_name: String) -> String:
	return SCOREBOARD_DIR + "/" + JourneyData.sanitize_folder_name(journey_folder_name) + ".json"


# The journey's runs, ranked by score (highest first). Empty array when there's
# no scoreboard yet, the file is missing/malformed, or the version is unsupported.
func read_runs(journey_folder_name: String) -> Array:
	if journey_folder_name.is_empty():
		return []
	var path: String = _path_for(journey_folder_name)
	if not FileAccess.file_exists(path):
		return []
	var f: FileAccess = FileAccess.open(path, FileAccess.READ)
	if f == null:
		return []
	var text: String = f.get_as_text()
	f.close()
	var parser: JSON = JSON.new()
	if parser.parse(text) != OK or not (parser.data is Dictionary):
		printerr("ScoreboardService: malformed scoreboard at %s" % path)
		return []
	var data: Dictionary = parser.data
	if int(data.get("version", 0)) != SCHEMA_VERSION:
		printerr("ScoreboardService: unsupported version in %s" % path)
		return []
	var runs: Array = data.get("runs", [])
	runs.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return int(a.get("score", 0)) > int(b.get("score", 0)))
	return runs


# Records one run for the journey. The caller supplies score / completed /
# rounds_done / rounds_total; this stamps the date, ranks by score, and caps the
# list to MAX_RUNS. Empty folder name is a no-op (e.g. a malformed journey).
func add_run(journey_folder_name: String, entry: Dictionary) -> void:
	if journey_folder_name.is_empty():
		return
	var dir_abs: String = ProjectSettings.globalize_path(SCOREBOARD_DIR)
	if not DirAccess.dir_exists_absolute(dir_abs):
		DirAccess.make_dir_recursive_absolute(dir_abs)

	var runs: Array = read_runs(journey_folder_name)
	var record: Dictionary = entry.duplicate()
	record["date"] = Time.get_datetime_string_from_system()
	runs.append(record)
	runs.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return int(a.get("score", 0)) > int(b.get("score", 0)))
	if runs.size() > MAX_RUNS:
		runs = runs.slice(0, MAX_RUNS)

	var out: Dictionary = {
		"version": SCHEMA_VERSION,
		"journey_folder": journey_folder_name,
		"runs": runs,
	}
	var path: String = _path_for(journey_folder_name)
	var f: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		printerr("ScoreboardService: cannot open %s for write" % path)
		return
	f.store_string(JSON.stringify(out, "\t"))
	f.close()


# Wipes the journey's run history. Idempotent. Called when the player clears it
# manually, when the journey is deleted, and when the author rebuilds it.
func clear(journey_folder_name: String) -> void:
	if journey_folder_name.is_empty():
		return
	var path: String = _path_for(journey_folder_name)
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


# True when the journey has at least one recorded run.
func has_runs(journey_folder_name: String) -> bool:
	return not read_runs(journey_folder_name).is_empty()
