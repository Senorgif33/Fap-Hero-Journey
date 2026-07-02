extends Node

# ---------------------------------------------------------------------------
# JourneySaveService  (autoload)
#
# Per-journey resume data persistence. One save file per journey, stored at
# `user://journey_saves/<journey_folder_name>.json`. New saves overwrite the
# previous one (single-slot design — see design notes).
#
# This service is just file I/O — it has no knowledge of the game's state
# structure. Callers (GameLoop / GameState) capture the snapshot, hand it in,
# and reverse the process on load. Keeping the schema opaque here means the
# service doesn't need to change when game state evolves.
#
# Save schema:
#   {
#     "version":          int        — for forward-compat if we change shape
#     "saved_at":         String     — ISO timestamp (display + sort)
#     "journey_folder":   String     — sanity check on load
#     "sequence_index":   int        — _seqIndex in GameState
#     "sequence":         Array      — full spliced sequence snapshot
#     "coins":            int        — CoinService balance
#     "score":            int        — ScoreService cumulative score
#     "total_actions":    int        — for end-screen stat
#     "total_length_ms":  int        — for end-screen stat
#     "round_names":      Array      — round-name log for the end screen
#   }
#
# C# callers reach this via the autoload node:
#   GetNode("/root/JourneySaveService").Call("has_save", folder).AsBool()
# ---------------------------------------------------------------------------

const SAVES_DIR: String = "user://journey_saves"
const SCHEMA_VERSION: int = 1


func _ready() -> void:
	# Lazily create the saves directory so the first SaveCurrent doesn't fail.
	if not DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(SAVES_DIR)):
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(SAVES_DIR))


# Returns the absolute path where a journey's save file would live. Used both
# for read and write; nonexistence at this path means "no save for this
# journey."
func _save_path_for(journey_folder_name: String) -> String:
	return SAVES_DIR + "/" + JourneyData.sanitize_folder_name(journey_folder_name) + ".json"


# True when a non-empty save file exists for this journey. JourneySelect uses
# this to choose between Resume / Play UI.
func has_save(journey_folder_name: String) -> bool:
	if journey_folder_name.is_empty():
		return false
	var path: String = _save_path_for(journey_folder_name)
	if not FileAccess.file_exists(path):
		return false
	# Guard against zero-byte / truncated files from an interrupted write.
	var f: FileAccess = FileAccess.open(path, FileAccess.READ)
	if f == null:
		return false
	var length: int = f.get_length()
	f.close()
	return length > 0


# Reads and parses the save for the given journey. Returns {} if no save, the
# file is missing, the JSON is malformed, or the schema version is unsupported.
# Errors are logged via printerr so a misbehaving save file is diagnosable
# without surfacing a modal to the user (they just see "no save available").
func read_save(journey_folder_name: String) -> Dictionary:
	if not has_save(journey_folder_name):
		return {}
	var path: String = _save_path_for(journey_folder_name)
	var f: FileAccess = FileAccess.open(path, FileAccess.READ)
	if f == null:
		printerr("JourneySaveService: cannot open %s for read" % path)
		return {}
	var text: String = f.get_as_text()
	f.close()
	var parser: JSON = JSON.new()
	if parser.parse(text) != OK:
		printerr("JourneySaveService: JSON parse failed for %s" % path)
		return {}
	if not (parser.data is Dictionary):
		printerr("JourneySaveService: save is not a Dictionary: %s" % path)
		return {}
	var data: Dictionary = parser.data
	var version: int = int(data.get("version", 0))
	if version != SCHEMA_VERSION:
		# A future-us could migrate older versions here. For now, refuse rather
		# than risk loading mismatched state.
		printerr("JourneySaveService: unsupported save version %d in %s" % [version, path])
		return {}
	return data


# Writes a save for the given journey, overwriting any previous file. Caller
# supplies a Dictionary with the game-state portion of the schema; this
# service stamps in `version`, `saved_at`, and `journey_folder` so callers
# can't forget those fields.
#
# Returns true on success. Failures (disk full, permissions) log via printerr.
func write_save(journey_folder_name: String, payload: Dictionary) -> bool:
	if journey_folder_name.is_empty():
		printerr("JourneySaveService: cannot write save with empty journey folder name")
		return false
	# Ensure the directory exists at write time too — Options' storage-location
	# change can move user:// indirectly, and we want to be defensive about it.
	var dir_abs: String = ProjectSettings.globalize_path(SAVES_DIR)
	if not DirAccess.dir_exists_absolute(dir_abs):
		DirAccess.make_dir_recursive_absolute(dir_abs)

	var record: Dictionary = payload.duplicate()
	record["version"] = SCHEMA_VERSION
	record["saved_at"] = Time.get_datetime_string_from_system()
	record["journey_folder"] = journey_folder_name

	var path: String = _save_path_for(journey_folder_name)
	var f: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		printerr("JourneySaveService: cannot open %s for write" % path)
		return false
	f.store_string(JSON.stringify(record, "\t"))
	f.close()
	return true


# Removes the save for the given journey. Idempotent — silently does nothing
# if no save existed. Called from "New Run" flow when the player chooses to
# overwrite an existing save, and from end-of-journey to clean up the save
# after a successful completion.
func delete_save(journey_folder_name: String) -> void:
	if journey_folder_name.is_empty():
		return
	var path: String = _save_path_for(journey_folder_name)
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


# Convenience: when did the save happen? Used by the catalogue to display
# something like "Saved 2 days ago". Returns "" when no save exists.
func get_save_timestamp(journey_folder_name: String) -> String:
	var data: Dictionary = read_save(journey_folder_name)
	return data.get("saved_at", "") as String
