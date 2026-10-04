class_name EventDefinitions
extends RefCounted

## Lightweight reader for funscript-tools / Vector `event_definitions.yml`.
## Extracts event names + `default_params` only — ignores `steps`, `groups`, `normalization`.
## Not a full YAML engine; tuned to the indent-based shape of config.event_definitions.yml.

const EMPTY: Dictionary = {"names": [], "params": {}, "error": ""}


## Load and parse a definitions file. Missing/unreadable → empty result with `error` set.
static func load_path(path: String) -> Dictionary:
	var p: String = path.strip_edges()
	if p.is_empty():
		return EMPTY.duplicate(true)
	if not FileAccess.file_exists(p):
		var miss: Dictionary = EMPTY.duplicate(true)
		miss["error"] = "File not found."
		return miss
	var f: FileAccess = FileAccess.open(p, FileAccess.READ)
	if f == null:
		var fail: Dictionary = EMPTY.duplicate(true)
		fail["error"] = "Could not open file."
		return fail
	return parse_text(f.get_as_text())


## Parse definitions YAML text → `{ names: Array[String], params: {name: {key: value}}, error: String }`.
static func parse_text(text: String) -> Dictionary:
	var names: Array = []
	var params_by_name: Dictionary = {}
	var lines: PackedStringArray = text.replace("\r\n", "\n").replace("\r", "\n").split("\n")

	var found_defs: bool = false
	var defs_indent: int = -1
	var event_indent: int = -1
	var current_name: String = ""
	var in_default_params: bool = false
	var params_indent: int = -1
	var skip_until_indent: int = -1  # when >= 0, skip lines with indent > this (e.g. steps body)

	var i: int = 0
	while i < lines.size():
		var raw: String = lines[i]
		i += 1
		var indent: int = _leading_spaces(raw)
		var content: String = _strip_yaml_comment(raw.substr(indent)).strip_edges()
		if content.is_empty():
			continue

		if not found_defs:
			if content == "definitions:" or content.begins_with("definitions:"):
				found_defs = true
				defs_indent = indent
			continue

		# Left the definitions block (another top-level key).
		if indent <= defs_indent and content.ends_with(":") and not content.begins_with("-"):
			break

		# Skipping steps / other nested blocks.
		if skip_until_indent >= 0:
			if indent > skip_until_indent:
				continue
			skip_until_indent = -1
			# Fall through to re-handle this line at the event level.

		# Event name line: first child of definitions (indent must be greater than defs).
		if event_indent < 0 and indent > defs_indent and content.ends_with(":") and not content.begins_with("-"):
			event_indent = indent

		if event_indent >= 0 and indent == event_indent and content.ends_with(":") and not content.begins_with("-"):
			current_name = content.substr(0, content.length() - 1).strip_edges()
			in_default_params = false
			params_indent = -1
			if current_name != "" and not params_by_name.has(current_name):
				names.append(current_name)
				params_by_name[current_name] = {}
			continue

		if current_name.is_empty():
			continue

		# Sub-keys under an event (default_params / steps / …).
		if indent > event_indent and content.ends_with(":") and not content.begins_with("-"):
			var key: String = content.substr(0, content.length() - 1).strip_edges()
			if key == "default_params":
				in_default_params = true
				params_indent = indent
				continue
			# Anything else under the event (steps, …) — skip its body.
			in_default_params = false
			params_indent = -1
			skip_until_indent = indent
			continue

		if in_default_params:
			if indent <= params_indent:
				in_default_params = false
				params_indent = -1
				# Re-handle: may be steps: or next event — rewind one line.
				i -= 1
				continue
			var colon: int = content.find(":")
			if colon <= 0:
				continue
			var pkey: String = content.substr(0, colon).strip_edges()
			var pval: String = content.substr(colon + 1).strip_edges()
			if pkey.is_empty():
				continue
			(params_by_name[current_name] as Dictionary)[pkey] = _parse_scalar(pval)

	var out: Dictionary = EMPTY.duplicate(true)
	out["names"] = names
	out["params"] = params_by_name
	if not found_defs:
		out["error"] = "No definitions: block found."
	elif names.is_empty():
		out["error"] = "definitions: block has no events."
	return out


static func default_params_for(defs: Dictionary, name: String) -> Dictionary:
	var all: Dictionary = defs.get("params", {}) as Dictionary
	var raw: Variant = all.get(name, {})
	if raw is Dictionary:
		return (raw as Dictionary).duplicate(true)
	return {}


static func param_keys_for(defs: Dictionary, name: String) -> Array:
	return default_params_for(defs, name).keys()


static func _leading_spaces(line: String) -> int:
	var n: int = 0
	for c: int in line.length():
		if line[c] == " ":
			n += 1
		elif line[c] == "\t":
			n += 2  # treat tab as 2 spaces
		else:
			break
	return n


static func _strip_yaml_comment(s: String) -> String:
	# Drop unquoted `# …` comments. Quoted strings with # are uncommon in this file's params.
	var in_single: bool = false
	var in_double: bool = false
	for i: int in s.length():
		var ch: String = s[i]
		if ch == "'" and not in_double:
			in_single = not in_single
		elif ch == '"' and not in_single:
			in_double = not in_double
		elif ch == "#" and not in_single and not in_double:
			return s.substr(0, i)
	return s


static func _parse_scalar(raw: String) -> Variant:
	var s: String = raw.strip_edges()
	if s.is_empty():
		return ""
	if (s.begins_with('"') and s.ends_with('"')) or (s.begins_with("'") and s.ends_with("'")):
		return s.substr(1, s.length() - 2)
	var lower: String = s.to_lower()
	if lower == "true":
		return true
	if lower == "false":
		return false
	if lower == "null" or lower == "~":
		return null
	if s.is_valid_int():
		return s.to_int()
	if s.is_valid_float():
		return s.to_float()
	return s
