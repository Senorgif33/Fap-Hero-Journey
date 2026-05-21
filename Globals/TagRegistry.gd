class_name TagRegistry
extends RefCounted

# ---------------------------------------------------------------------------
# TagRegistry
# Loads and caches the journey-tag definitions from res://tags.json so the tag
# list can be extended without a recompile. Pure data — no UI, no node state.
#
# Each tag definition: { id: String, label: String, color: Color }
#
#   TagRegistry.all()          -> Array[Dictionary]  (definition order)
#   TagRegistry.get_tag(id)    -> Dictionary or {}
#   TagRegistry.label_of(id)   -> String
#   TagRegistry.color_of(id)   -> Color
#   TagRegistry.is_valid(id)   -> bool
#
# Unknown tag ids (e.g. removed from tags.json) degrade gracefully.
# ---------------------------------------------------------------------------

const TAGS_PATH: String = "res://data/tags.json"
const FALLBACK_COLOR: Color = Color(0.7, 0.7, 0.7)

static var _tags: Array = []      # Array[Dictionary] {id, label, color}
static var _loaded: bool = false


# All tag definitions, in the order declared in tags.json.
static func all() -> Array:
	_ensure_loaded()
	return _tags


# Tag definition for `id`, or {} if unknown.
static func get_tag(id: String) -> Dictionary:
	for t: Dictionary in all():
		if t["id"] == id:
			return t
	return {}


static func label_of(id: String) -> String:
	var t: Dictionary = get_tag(id)
	return t["label"] if not t.is_empty() else id.capitalize()


static func color_of(id: String) -> Color:
	var t: Dictionary = get_tag(id)
	return t["color"] if not t.is_empty() else FALLBACK_COLOR


static func is_valid(id: String) -> bool:
	return not get_tag(id).is_empty()


# Filters a list of tag ids down to ones that still exist in tags.json,
# preserving definition order. Used so a journey never shows a stale chip.
static func sanitize(ids: Array) -> Array:
	var result: Array = []
	for t: Dictionary in all():
		if t["id"] in ids:
			result.append(t["id"])
	return result


static func _ensure_loaded() -> void:
	if _loaded:
		return
	_loaded = true
	_tags = []

	if not FileAccess.file_exists(TAGS_PATH):
		push_warning("TagRegistry: %s not found — tag system disabled." % TAGS_PATH)
		return
	var f: FileAccess = FileAccess.open(TAGS_PATH, FileAccess.READ)
	if f == null:
		push_warning("TagRegistry: cannot open %s." % TAGS_PATH)
		return
	var parser: JSON = JSON.new()
	var err: int = parser.parse(f.get_as_text())
	f.close()
	if err != OK or not (parser.data is Array):
		push_warning("TagRegistry: %s is malformed." % TAGS_PATH)
		return

	for entry in parser.data:
		if not (entry is Dictionary):
			continue
		var id: String = entry.get("id", "")
		if id == "":
			continue
		_tags.append({
			"id":    id,
			"label": entry.get("label", id.capitalize()),
			"color": Color.html(entry.get("color", "#b3b3b3")),
		})
