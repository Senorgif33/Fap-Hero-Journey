class_name RestimAxisKit
extends RefCounted

## Hardcoded Restim funscript kit (from diglet48/restim defaults + FOC E1–E4).
## Filename suffix → kit name → T-code axis. No restim.ini is read at runtime —
## each user may keep Restim config elsewhere; this is Fap-Hero's fixed mapping.
##
## Kit rows (auto_loading → sibling autofill + Extra Axes drop zones):
##   alpha→L0, beta→L1, volume→V0, frequency→C0, pulse_*→P0–P3,
##   e1–e4→E1–E4, sensor_suppression→S1

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


static func detect_axis(stem_lower: String) -> String:
	for entry: Dictionary in KIT:
		for suffix: String in _suffixes_for(str(entry["name"])):
			if stem_lower.ends_with(suffix):
				return str(entry["name"])
	for entry: Dictionary in SSR_AXIS_SUFFIXES:
		if stem_lower.ends_with(str(entry["suffix"])):
			return str(entry["name"])
	return ""


static func strip_suffix(stem: String) -> String:
	var low: String = stem.to_lower()
	var best_len: int = 0
	var out: String = stem
	for entry: Dictionary in KIT:
		for suffix: String in _suffixes_for(str(entry["name"])):
			if low.ends_with(suffix) and suffix.length() > best_len:
				best_len = suffix.length()
				out = stem.substr(0, stem.length() - suffix.length())
	for entry: Dictionary in SSR_AXIS_SUFFIXES:
		var suffix: String = str(entry["suffix"])
		if low.ends_with(suffix) and suffix.length() > best_len:
			best_len = suffix.length()
			out = stem.substr(0, stem.length() - suffix.length())
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
