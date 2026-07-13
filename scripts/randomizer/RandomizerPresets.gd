class_name RandomizerPresets
extends RefCounted
## Named generation-settings presets for the randomizer ("Quick 20-min intense",
## "Long slow build", …). Persisted as a small JSON list of {name, settings}; the
## seed is deliberately NOT stored (a preset is a style, not a specific roll). The
## list mutation logic (upsert / remove) is pure so it's unit-tested; load/save wrap
## it with disk I/O.

const PATH: String = "user://randomizer_presets.json"

# ── Persistence ──────────────────────────────────────────────────────────────


static func load_all() -> Array:
	if not FileAccess.file_exists(PATH):
		return []
	var f: FileAccess = FileAccess.open(PATH, FileAccess.READ)
	if f == null:
		return []
	var parser := JSON.new()
	var ok: bool = parser.parse(f.get_as_text()) == OK
	f.close()
	if not ok or not (parser.data is Dictionary):
		return []
	var out: Array = []
	for p: Variant in (parser.data as Dictionary).get("presets", []):
		if p is Dictionary and str((p as Dictionary).get("name", "")) != "":
			(
				out
				. append(
					{
						"name": str((p as Dictionary)["name"]),
						"settings":
						((p as Dictionary).get("settings", {}) as Dictionary).duplicate(true),
					}
				)
			)
	return out


static func save_all(presets: Array) -> bool:
	var f: FileAccess = FileAccess.open(PATH, FileAccess.WRITE)
	if f == null:
		push_error("RandomizerPresets: cannot write %s" % PATH)
		return false
	f.store_string(JSON.stringify({"version": 1, "presets": presets}, "\t"))
	f.close()
	return true


static func add(name: String, settings: Dictionary) -> void:
	if name.strip_edges() == "":
		return
	save_all(upsert(load_all(), name.strip_edges(), settings))


static func remove(name: String) -> void:
	save_all(without(load_all(), name))


static func get_settings(name: String) -> Dictionary:
	for p: Dictionary in load_all():
		if str(p.get("name", "")) == name:
			return (p.get("settings", {}) as Dictionary).duplicate(true)
	return {}


# ── Pure list logic (unit-tested) ────────────────────────────────────────────


# Replaces the preset named `name` in place (preserving order), or appends it if
# new. `settings` is deep-copied so callers can't alias the stored blob.
static func upsert(presets: Array, name: String, settings: Dictionary) -> Array:
	var out: Array = []
	var replaced: bool = false
	for p: Dictionary in presets:
		if str(p.get("name", "")) == name:
			out.append({"name": name, "settings": settings.duplicate(true)})
			replaced = true
		else:
			out.append(p)
	if not replaced:
		out.append({"name": name, "settings": settings.duplicate(true)})
	return out


static func without(presets: Array, name: String) -> Array:
	return presets.filter(func(p: Dictionary) -> bool: return str(p.get("name", "")) != name)
