class_name ImportScanner
extends RefCounted

## Pure file/path logic for bulk-importing rounds from dropped files: filename → axis/vib detection,
## sibling matching on disk, and grouping a folder of files into round data. No UI, no builder state —
## so it's unit-tested directly (tests/import_scanner_test.gd). JourneyBuilder owns the graph-node
## creation that consumes build_rounds(); BuilderSidePanel uses autofill_round_siblings for single drops.

# Funscript filename suffixes — Restim kit from restim.ini + SSR + vib. See RestimAxisKit.
static func script_suffixes() -> PackedStringArray:
	var out: PackedStringArray = RestimAxisKit.all_script_suffixes()
	for s: String in [".vib1", "_vib1", ".vibe1", "_vibe1", ".vib2", "_vib2", ".vibe2", "_vibe2"]:
		if not out.has(s):
			out.append(s)
	return out


# Current Options Restim slot labels (for filename tag routing).
static func current_restim_labels() -> PackedStringArray:
	return PackedStringArray(
		[SettingsService.get_restim_label("a"), SettingsService.get_restim_label("b")]
	)


static func _resolve_labels(label_a: String, label_b: String) -> PackedStringArray:
	if label_a != "" or label_b != "":
		return PackedStringArray([label_a, label_b])
	return current_restim_labels()


# Infers the axis_scripts key from a funscript filename.
# Returns "L0" for the unmarked main stroke script.
# Restim kit names (alpha, beta, e1, volume, …) come from restim.ini funscript_names.
static func detect_funscript_axis(
	path: String, label_a: String = "", label_b: String = ""
) -> String:
	var labels: PackedStringArray = _resolve_labels(label_a, label_b)
	var stem: String = path.get_file().get_basename().to_lower()
	var restim: String = RestimAxisKit.detect_axis(stem, labels[0], labels[1])
	if restim != "":
		return restim
	return "L0"


# Returns {slot, axis} for Restim dual kits, or {} for L0 / vib / unknown.
# slot is "a", "b", or "shared".
static func detect_funscript_slotted_axis(
	path: String, label_a: String = "", label_b: String = ""
) -> Dictionary:
	var stem: String = path.get_file().get_basename().to_lower()
	if detect_vib_channel(path) != "":
		return {}
	var labels: PackedStringArray = _resolve_labels(label_a, label_b)
	return RestimAxisKit.detect_slotted_axis(stem, labels[0], labels[1])


# Returns "vib1" or "vib2" when the filename carries a recognised vibrator-script suffix
# (.vib1, _vib1, .vibe1, _vibe1 → "vib1"; .vib2 variants → "vib2"). Returns "" for any other filename.
static func detect_vib_channel(path: String) -> String:
	var stem: String = path.get_file().get_basename().to_lower()
	for s: String in [".vib1", "_vib1", ".vibe1", "_vibe1"]:
		if stem.ends_with(s):
			return "vib1"
	for s: String in [".vib2", "_vib2", ".vibe2", "_vibe2"]:
		if stem.ends_with(s):
			return "vib2"
	return ""


# The file's basename with any recognised axis/vib suffix removed, so a secondary-axis or vib script
# groups with its main round during bulk import. Preserves the original casing of the stem.
static func strip_script_suffix(
	path: String, label_a: String = "", label_b: String = ""
) -> String:
	var stem: String = path.get_file().get_basename()
	var low: String = stem.to_lower()
	for s: String in [".vib1", "_vib1", ".vibe1", "_vibe1", ".vib2", "_vib2", ".vibe2", "_vibe2"]:
		if low.ends_with(s):
			return stem.substr(0, stem.length() - s.length())
	var labels: PackedStringArray = _resolve_labels(label_a, label_b)
	return RestimAxisKit.strip_suffix(stem, labels[0], labels[1])


# Round grouping key: directory + base name (suffix stripped), lowercased — so a video and its scripts
# in one folder pair up, while same-named files in different folders stay separate rounds.
static func round_group_key(
	path: String, label_a: String = "", label_b: String = ""
) -> String:
	return (
		"%s/%s" % [path.get_base_dir(), strip_script_suffix(path, label_a, label_b)]
	).to_lower()


# Any one real path from an import group (video, then funscript, then an axis, then a vib), or "".
# Anchors the disk scan for sibling autofill.
static func group_anchor_path(g: Dictionary) -> String:
	if g["video"] != "":
		return g["video"]
	if g["funscript"] != "":
		return g["funscript"]
	var ras: Dictionary = g.get("restim_axis", JourneyData.empty_restim_axis_scripts())
	for slot: String in JourneyData.RESTIM_AXIS_SLOTS:
		for a: String in (ras[slot] as Dictionary).values():
			return a
	for a: String in (g["axis"] as Dictionary).values():
		return a
	for v: String in (g["vib"] as Dictionary).values():
		return v
	return ""


# Creates an empty import group for `key` (preserving first-seen order) if absent.
static func ensure_import_group(groups: Dictionary, order: Array, key: String) -> void:
	if not groups.has(key):
		groups[key] = {
			"video": "",
			"funscript": "",
			"axis": {},
			"restim_axis": JourneyData.empty_restim_axis_scripts(),
			"vib": {},
			"name": "",
		}
		order.append(key)


# Expands a dropped path list: directories are walked recursively and replaced by the video/funscript
# files inside; plain files pass through. Sorted for a stable round order.
static func expand_dropped_paths(files: PackedStringArray) -> PackedStringArray:
	var out: PackedStringArray = []
	for f: String in files:
		if DirAccess.dir_exists_absolute(f):
			collect_files_recursive(f, out)
		else:
			out.append(f)
	out.sort()
	return out


# Recursively appends every video/funscript file under `dir` into `out`.
static func collect_files_recursive(dir: String, out: PackedStringArray) -> void:
	var d: DirAccess = DirAccess.open(dir)
	if d == null:
		return
	d.list_dir_begin()
	var fname: String = d.get_next()
	while fname != "":
		if fname != "." and fname != "..":
			var full: String = "%s/%s" % [dir, fname]
			if d.current_is_dir():
				collect_files_recursive(full, out)
			else:
				var ext: String = fname.get_extension().to_lower()
				if ext in JourneyData.VIDEO_EXTENSIONS or ext in JourneyData.FUNSCRIPT_EXTENSIONS:
					out.append(full)
		fname = d.get_next()
	d.list_dir_end()


# Scans `dir` for every funscript whose base name (suffix stripped) matches `base`, classifying each
# into the main stroke script, a secondary axis, or a vib channel — reusing the same suffix detection
# as drag-routing. Returns {"funscript": String, "axis": Dictionary, "restim_axis": Dictionary,
# "vib": Dictionary}; first match wins per slot.
static func find_sibling_scripts(
	dir: String, base: String, label_a: String = "", label_b: String = ""
) -> Dictionary:
	var result: Dictionary = {
		"funscript": "",
		"axis": {},
		"restim_axis": JourneyData.empty_restim_axis_scripts(),
		"vib": {},
	}
	var labels: PackedStringArray = _resolve_labels(label_a, label_b)
	var base_low: String = base.to_lower()
	var d: DirAccess = DirAccess.open(dir)
	if d == null:
		return result
	d.list_dir_begin()
	var fname: String = d.get_next()
	while fname != "":
		if (
			not d.current_is_dir()
			and fname.get_extension().to_lower() in JourneyData.FUNSCRIPT_EXTENSIONS
		):
			var full: String = "%s/%s" % [dir, fname]
			if strip_script_suffix(full, labels[0], labels[1]).to_lower() == base_low:
				var vib_ch: String = detect_vib_channel(full)
				if vib_ch != "":
					if not result["vib"].has(vib_ch):
						result["vib"][vib_ch] = full
				else:
					var slotted: Dictionary = detect_funscript_slotted_axis(
						full, labels[0], labels[1]
					)
					if slotted.is_empty():
						var stem_low: String = full.get_file().get_basename().to_lower()
						if RestimAxisKit.has_kit_axis_tag(stem_low):
							pass  # orphaned label tag — not main L0
						elif result["funscript"] == "":
							result["funscript"] = full
					else:
						var slot: String = str(slotted["slot"])
						var axis: String = str(slotted["axis"])
						if RestimAxisKit.should_autofill(axis):
							var slot_map: Dictionary = result["restim_axis"][slot] as Dictionary
							if not slot_map.has(axis):
								slot_map[axis] = full
							# Flat axis map = shared only (legacy / serial).
							if slot == "shared" and not result["axis"].has(axis):
								result["axis"][axis] = full
		fname = d.get_next()
	d.list_dir_end()
	return result


# Finds a video next to a funscript/round by base name. Returns its path, or "" if none exists.
static func find_sibling_video(dir: String, base: String) -> String:
	for ext: String in JourneyData.VIDEO_EXTENSIONS:
		var cand: String = "%s/%s.%s" % [dir, base, ext]
		if FileAccess.file_exists(cand):
			return cand
	return ""


# Fills any EMPTY slots of `round_data` (main funscript, video, secondary axes, vib channels) from
# same-named files sitting next to `anchor_path` on disk. Never overwrites a slot the author already
# set. Returns true if anything was filled. Used by the bulk importer and the single-round drop.
static func autofill_round_siblings(
	round_data: Dictionary, anchor_path: String, label_a: String = "", label_b: String = ""
) -> bool:
	var labels: PackedStringArray = _resolve_labels(label_a, label_b)
	var dir: String = anchor_path.get_base_dir()
	var base: String = strip_script_suffix(anchor_path, labels[0], labels[1])
	var changed: bool = false

	var scan: Dictionary = find_sibling_scripts(dir, base, labels[0], labels[1])

	if (round_data.get("funscript_path", "") as String) == "" and scan["funscript"] != "":
		round_data["funscript_path"] = scan["funscript"]
		changed = true
	if (round_data.get("video_path", "") as String) == "":
		var sv: String = find_sibling_video(dir, base)
		if sv != "":
			round_data["video_path"] = sv
			changed = true

	JourneyData.ensure_restim_axis_scripts(round_data)
	var ras: Dictionary = round_data["restim_axis_scripts"] as Dictionary
	var scan_ras: Dictionary = scan["restim_axis"] as Dictionary
	for slot: String in JourneyData.RESTIM_AXIS_SLOTS:
		var dest: Dictionary = ras[slot] as Dictionary
		var src: Dictionary = scan_ras[slot] as Dictionary
		for axis: String in src:
			if not dest.has(axis):
				dest[axis] = src[axis]
				changed = true

	# Keep flat axis_scripts aligned with shared.
	round_data["axis_scripts"] = (ras["shared"] as Dictionary).duplicate(true)

	if not round_data.has("vib_scripts"):
		round_data["vib_scripts"] = {}
	for ch: String in scan["vib"]:
		if not (round_data["vib_scripts"] as Dictionary).has(ch):
			round_data["vib_scripts"][ch] = scan["vib"][ch]
			changed = true

	return changed


# Library-shaped autofill (Randomizer entries): empty funscript_src / restim_axis_src / vib_src
# filled from siblings next to video_src. Never overwrites set slots.
# Returns { changed, funscript_src, restim_axis_src, vib_src }.
static func autofill_src_siblings(
	video_src: String,
	funscript_src: String = "",
	restim_axis_src: Dictionary = {},
	vib_src: Dictionary = {},
	label_a: String = "",
	label_b: String = ""
) -> Dictionary:
	var labels: PackedStringArray = _resolve_labels(label_a, label_b)
	var ras: Dictionary = JourneyData.coerce_restim_axis_scripts(
		{"restim_axis_scripts": restim_axis_src, "axis_scripts": {}}
	)
	var vib: Dictionary = vib_src.duplicate(true)
	var fs: String = funscript_src
	var changed: bool = false
	if video_src == "" or not FileAccess.file_exists(ProjectSettings.globalize_path(video_src)):
		return {
			"changed": false,
			"funscript_src": fs,
			"restim_axis_src": ras,
			"vib_src": vib,
		}

	var dir: String = video_src.get_base_dir()
	var base: String = strip_script_suffix(video_src, labels[0], labels[1])
	var scan: Dictionary = find_sibling_scripts(dir, base, labels[0], labels[1])

	if fs == "" and scan["funscript"] != "":
		fs = scan["funscript"]
		changed = true

	var scan_ras: Dictionary = scan["restim_axis"] as Dictionary
	for slot: String in JourneyData.RESTIM_AXIS_SLOTS:
		var dest: Dictionary = ras[slot] as Dictionary
		var src: Dictionary = scan_ras[slot] as Dictionary
		for axis: String in src:
			if not dest.has(axis):
				dest[axis] = src[axis]
				changed = true

	for ch: String in scan["vib"]:
		if not vib.has(ch):
			vib[ch] = scan["vib"][ch]
			changed = true

	return {
		"changed": changed,
		"funscript_src": fs,
		"restim_axis_src": ras,
		"vib_src": vib,
	}


# Groups dropped files by folder + base name (a video + its matched scripts → one round) and builds
# each group's round data: the round template + the group's media, then any missing siblings autofilled
# from disk. A group needs a video to become a round; funscript-only groups are counted in
# skipped_no_video. Returns { "rounds": Array[Dictionary], "skipped_no_video": int } in first-seen order.
static func build_rounds(
	files: PackedStringArray, label_a: String = "", label_b: String = ""
) -> Dictionary:
	var labels: PackedStringArray = _resolve_labels(label_a, label_b)
	var groups: Dictionary = {}  # round_key -> {video, funscript, axis:{}, restim_axis, vib:{}, name}
	var order: Array = []  # round_keys in first-seen order
	for f: String in files:
		var ext: String = f.get_extension().to_lower()
		var key: String = round_group_key(f, labels[0], labels[1])
		if ext in JourneyData.VIDEO_EXTENSIONS:
			ensure_import_group(groups, order, key)
			groups[key]["video"] = f
			if groups[key]["name"] == "":
				groups[key]["name"] = f.get_file().get_basename()
		elif ext in JourneyData.FUNSCRIPT_EXTENSIONS:
			ensure_import_group(groups, order, key)
			var vib_ch: String = detect_vib_channel(f)
			if vib_ch != "":
				groups[key]["vib"][vib_ch] = f
			else:
				var slotted: Dictionary = detect_funscript_slotted_axis(f, labels[0], labels[1])
				if slotted.is_empty():
					var stem_low: String = f.get_file().get_basename().to_lower()
					if RestimAxisKit.has_kit_axis_tag(stem_low):
						pass  # orphaned label tag — not main L0
					else:
						groups[key]["funscript"] = f
						if groups[key]["name"] == "":
							groups[key]["name"] = f.get_file().get_basename()
				elif RestimAxisKit.should_autofill(str(slotted["axis"])):
					var slot: String = str(slotted["slot"])
					var axis: String = str(slotted["axis"])
					(groups[key]["restim_axis"][slot] as Dictionary)[axis] = f
					if slot == "shared":
						groups[key]["axis"][axis] = f

	var rounds: Array = []
	var skipped_no_video: int = 0
	for key: String in order:
		var g: Dictionary = groups[key]
		var data: Dictionary = JourneyData.new_item("round").duplicate(true)
		data.erase("type")
		data.erase("node_id")
		data.erase("paths")
		data["name"] = (g["name"] as String) if (g["name"] as String) != "" else key
		data["funscript_path"] = g["funscript"]
		data["video_path"] = g["video"]
		data["restim_axis_scripts"] = (g["restim_axis"] as Dictionary).duplicate(true)
		data["axis_scripts"] = (
			(g["restim_axis"]["shared"] as Dictionary).duplicate(true)
			if (g["restim_axis"] as Dictionary).has("shared")
			else (g["axis"] as Dictionary).duplicate(true)
		)
		data["vib_scripts"] = g["vib"]
		var anchor: String = group_anchor_path(g)
		if anchor != "":
			autofill_round_siblings(data, anchor, labels[0], labels[1])
		if str(data.get("video_path", "")) == "":
			skipped_no_video += 1
			continue
		rounds.append(data)
	return {"rounds": rounds, "skipped_no_video": skipped_no_video}
