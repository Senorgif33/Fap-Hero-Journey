class_name RestimAxisKit
extends RefCounted

## Hardcoded Restim funscript kit (from diglet48/restim defaults + FOC E1–E4).
## Filename suffix → kit name → T-code axis. No restim.ini is read at runtime —
## each user may keep Restim config elsewhere; this is Fap-Hero's fixed mapping.
##
## Kit rows (auto_loading → sibling autofill + Extra Axes drop zones):
##   alpha→L0, beta→L1, volume→V0, frequency→C0, pulse_*→P0–P3,
##   e1–e4→E1–E4, sensor_suppression→S1
##
## Dual-Restim filename routing (see detect_slotted_axis):
##   .a.alpha / .b.volume — explicit slot override
##   .alpha-<labelSlug> — tagged kit → matching Options slot label
##   pulse_* / sensor_suppression — always shared
##   plain .alpha / .e1 / … — slot A
##   SSR (.surge, .L1, …) — shared

# Longer Restim suffixes first so pulse_frequency wins over frequency.
const KIT: Array = [
	{"name": "pulse_interval_random", "tcode": "P2", "auto_loading": true},
	{"name": "pulse_frequency", "tcode": "P0", "auto_loading": true},
	{"name": "pulse_rise_time", "tcode": "P3", "auto_loading": true},
	{"name": "pulse_width", "tcode": "P1", "auto_loading": true},
	{"name": "sensor_suppression", "tcode": "S1", "auto_loading": true},
	{"name": "frequency", "tcode": "C0", "auto_loading": true},
	{"name": "volume", "tcode": "V0", "auto_loading": true},
	{"name": "alpha", "tcode": "L0", "auto_loading": true},
	{"name": "beta", "tcode": "L1", "auto_loading": true},
	{"name": "e1", "tcode": "E1", "auto_loading": true},
	{"name": "e2", "tcode": "E2", "auto_loading": true},
	{"name": "e3", "tcode": "E3", "auto_loading": true},
	{"name": "e4", "tcode": "E4", "auto_loading": true},
]

# SR6 / OSR2 axes — not in Restim kit; always available alongside Restim scripts.
const SSR_AXIS_SUFFIXES: Array = [
	{"suffix": "_l1", "name": "L1"},
	{"suffix": ".l1", "name": "L1"},
	{"suffix": "_l2", "name": "L2"},
	{"suffix": ".l2", "name": "L2"},
	{"suffix": "_r0", "name": "R0"},
	{"suffix": ".r0", "name": "R0"},
	{"suffix": "_r1", "name": "R1"},
	{"suffix": ".r1", "name": "R1"},
	{"suffix": "_r2", "name": "R2"},
	{"suffix": ".r2", "name": "R2"},
	{"suffix": "_surge", "name": "L1"},
	{"suffix": ".surge", "name": "L1"},
	{"suffix": "_sway", "name": "L2"},
	{"suffix": ".sway", "name": "L2"},
	{"suffix": "_twist", "name": "R0"},
	{"suffix": ".twist", "name": "R0"},
	{"suffix": "_roll", "name": "R1"},
	{"suffix": ".roll", "name": "R1"},
	{"suffix": "_pitch", "name": "R2"},
	{"suffix": ".pitch", "name": "R2"},
]


static func _suffixes_for(name: String) -> PackedStringArray:
	return PackedStringArray([".%s" % name, "_%s" % name])


# Filename tag from an Options slot label: lowercase, spaces/punct → `-`.
# "Prostate" → "prostate"; "My Kit" → "my-kit"; "Restim A" → "restim-a".
static func slugify_label(label: String) -> String:
	var s: String = label.strip_edges().to_lower()
	if s == "":
		return ""
	var out: String = ""
	var prev_dash: bool = false
	for i: int in s.length():
		var ch: String = s.substr(i, 1)
		var code: int = ch.unicode_at(0)
		var is_alnum: bool = (
			(code >= 97 and code <= 122) or (code >= 48 and code <= 57)
		)
		if is_alnum:
			out += ch
			prev_dash = false
		elif not prev_dash:
			out += "-"
			prev_dash = true
	return out.strip_edges().trim_prefix("-").trim_suffix("-")


# pulse_* + sensor_suppression always fan out to both Restim peers.
static func is_always_shared_kit_axis(axis: String) -> bool:
	var key: String = axis.to_lower()
	return key.begins_with("pulse_") or key == "sensor_suppression"


static func _detect_ssr_axis(stem_lower: String) -> String:
	for entry: Dictionary in SSR_AXIS_SUFFIXES:
		if stem_lower.ends_with(str(entry["suffix"])):
			return str(entry["name"])
	return ""


static func _detect_plain_kit_axis(stem_lower: String) -> String:
	for entry: Dictionary in KIT:
		for suffix: String in _suffixes_for(str(entry["name"])):
			if stem_lower.ends_with(suffix):
				return str(entry["name"])
	return ""


# Slot-prefixed first, then label-tagged kit, then always-shared, plain kit → A, SSR → shared.
# label_a / label_b are Options display names (exact slug match for tags).
static func detect_slotted_axis(
	stem_lower: String, label_a: String = "", label_b: String = ""
) -> Dictionary:
	for slot: String in ["a", "b"]:
		for entry: Dictionary in KIT:
			var axis: String = str(entry["name"])
			for suffix: String in [".%s.%s" % [slot, axis], "_%s_%s" % [slot, axis]]:
				if stem_lower.ends_with(suffix):
					return {"slot": slot, "axis": axis}

	var labels: Array = [["a", label_a], ["b", label_b]]
	for pair: Array in labels:
		var slot: String = str(pair[0])
		var slug: String = slugify_label(str(pair[1]))
		if slug == "":
			continue
		for entry: Dictionary in KIT:
			var axis: String = str(entry["name"])
			for suffix: String in [".%s-%s" % [axis, slug], "_%s_%s" % [axis, slug]]:
				if stem_lower.ends_with(suffix):
					return {"slot": slot, "axis": axis}

	var kit_axis: String = _detect_plain_kit_axis(stem_lower)
	if kit_axis != "":
		if is_always_shared_kit_axis(kit_axis):
			return {"slot": "shared", "axis": kit_axis}
		return {"slot": "a", "axis": kit_axis}

	var ssr: String = _detect_ssr_axis(stem_lower)
	if ssr != "":
		return {"slot": "shared", "axis": ssr}
	return {}


# True when the stem looks like .<kit_axis>-<tag> / _<kit_axis>_<tag> (so it is not a
# main L0 script). Used to skip orphaned tags that matched no Options label.
static func has_kit_axis_tag(stem_lower: String) -> bool:
	for entry: Dictionary in KIT:
		var axis: String = str(entry["name"])
		var dot_tag: String = ".%s-" % axis
		var idx: int = stem_lower.rfind(dot_tag)
		if idx >= 0 and idx + dot_tag.length() < stem_lower.length():
			return true
		var us_tag: String = "_%s_" % axis
		var uidx: int = stem_lower.rfind(us_tag)
		if uidx >= 0 and uidx + us_tag.length() < stem_lower.length():
			# Avoid treating plain _alpha as a tag — require trailing chars after _axis_.
			return true
	return false


static func _detect_axis_unprefixed(stem_lower: String) -> String:
	var kit: String = _detect_plain_kit_axis(stem_lower)
	if kit != "":
		return kit
	return _detect_ssr_axis(stem_lower)


static func detect_axis(
	stem_lower: String, label_a: String = "", label_b: String = ""
) -> String:
	var slotted: Dictionary = detect_slotted_axis(stem_lower, label_a, label_b)
	if not slotted.is_empty():
		return str(slotted["axis"])
	return ""


# Strips the longest recognised axis/vib-style kit suffix (slot-prefixed, label-tagged,
# plain kit, or SSR). label_a/label_b help strip exact tagged forms; generic .<axis>-*
# is also stripped so files group with the video even when labels differ.
static func strip_suffix(stem: String, label_a: String = "", label_b: String = "") -> String:
	var low: String = stem.to_lower()
	var best_len: int = 0
	var out: String = stem
	var candidates: PackedStringArray = PackedStringArray()

	for slot: String in ["a", "b"]:
		for entry: Dictionary in KIT:
			var axis: String = str(entry["name"])
			candidates.append(".%s.%s" % [slot, axis])
			candidates.append("_%s_%s" % [slot, axis])

	for pair: Array in [["a", label_a], ["b", label_b]]:
		var slug: String = slugify_label(str(pair[1]))
		if slug == "":
			continue
		for entry: Dictionary in KIT:
			var axis: String = str(entry["name"])
			candidates.append(".%s-%s" % [axis, slug])
			candidates.append("_%s_%s" % [axis, slug])

	for entry: Dictionary in KIT:
		for suffix: String in _suffixes_for(str(entry["name"])):
			candidates.append(suffix)
	for entry: Dictionary in SSR_AXIS_SUFFIXES:
		candidates.append(str(entry["suffix"]))

	for suffix: String in candidates:
		if low.ends_with(suffix) and suffix.length() > best_len:
			best_len = suffix.length()
			out = stem.substr(0, stem.length() - suffix.length())

	# Generic tagged kit: .<axis>-<tag> / _<axis>_<tag> (any non-empty tag).
	for entry: Dictionary in KIT:
		var axis: String = str(entry["name"])
		var dot_tag: String = ".%s-" % axis
		var idx: int = low.rfind(dot_tag)
		if idx >= 0 and idx + dot_tag.length() < low.length():
			var suf_len: int = low.length() - idx
			if suf_len > best_len:
				best_len = suf_len
				out = stem.substr(0, idx)
		var us_tag: String = "_%s_" % axis
		var uidx: int = low.rfind(us_tag)
		if uidx >= 0 and uidx + us_tag.length() < low.length():
			var usuf_len: int = low.length() - uidx
			if usuf_len > best_len:
				best_len = usuf_len
				out = stem.substr(0, uidx)

	return out


static func tcode_for(axis_key: String) -> String:
	var key: String = axis_key.to_lower()
	for entry: Dictionary in KIT:
		if str(entry["name"]) == key:
			return str(entry["tcode"])
	var upper: String = axis_key.to_upper()
	if upper in ["L1", "L2", "R0", "R1", "R2"]:
		return upper
	return ""


static func has_tcode(axis_key: String) -> bool:
	return tcode_for(axis_key) != ""


static func is_kit_axis(name: String) -> bool:
	var key: String = name.to_lower()
	for entry: Dictionary in KIT:
		if str(entry["name"]) == key:
			return true
	return false


static func is_auto_loading(name: String) -> bool:
	var key: String = name.to_lower()
	for entry: Dictionary in KIT:
		if str(entry["name"]) == key:
			return bool(entry.get("auto_loading", false))
	return false


## Sibling autofill / bulk import: Restim kit when auto_loading; SSR axes always.
static func should_autofill(axis: String) -> bool:
	if axis == "L0" or axis.is_empty():
		return false
	if is_kit_axis(axis):
		return is_auto_loading(axis)
	return axis.to_upper() in ["L1", "L2", "R0", "R1", "R2"]


static func auto_loading_names() -> Array[String]:
	var out: Array[String] = []
	for entry: Dictionary in KIT:
		if bool(entry.get("auto_loading", false)):
			out.append(str(entry["name"]))
	return out


static func all_autofill_axis_keys() -> Array[String]:
	var out: Array[String] = auto_loading_names()
	for entry: Dictionary in SSR_AXIS_SUFFIXES:
		var n: String = str(entry["name"])
		if not out.has(n):
			out.append(n)
	return out


static func all_script_suffixes() -> PackedStringArray:
	var sorted: Array = []
	for slot: String in ["a", "b"]:
		for entry: Dictionary in KIT:
			var axis: String = str(entry["name"])
			sorted.append(".%s.%s" % [slot, axis])
			sorted.append("_%s_%s" % [slot, axis])
	for entry: Dictionary in KIT:
		for suffix: String in _suffixes_for(str(entry["name"])):
			sorted.append(suffix)
	for entry: Dictionary in SSR_AXIS_SUFFIXES:
		sorted.append(str(entry["suffix"]))
	sorted.sort_custom(func(a: String, b: String) -> bool: return a.length() > b.length())
	var result: PackedStringArray = PackedStringArray()
	for s: String in sorted:
		result.append(s)
	return result


## Hardcoded Restim FOC kit — no restim.ini read at runtime.
##   alpha→L0, beta→L1, e1–e4→E1–E4, volume→V0, frequency→C0, pulse_*→P0–P3, sensor_suppression→S1
static func axis_display_label(name: String) -> String:
	var tcode: String = tcode_for(name)
	if tcode != "":
		return "%s  →  %s" % [name.to_upper(), tcode]
	return name.to_upper()
