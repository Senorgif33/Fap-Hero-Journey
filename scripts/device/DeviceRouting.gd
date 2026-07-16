class_name DeviceRouting
extends RefCounted

# ---------------------------------------------------------------------------
# DeviceRouting  (pure static resolver — no engine state, unit-tested)
#
# Turns the saved routing config plus a live device catalog into a concrete
# dispatch plan the player fans its output over. The per-actuator mapping is
# Buttplug-only; serial / Restim T-code are addressed by backend sentinels.
#
# Actuator id: "<device_id>:<kind>:<channel>", where device_id = "<name>#<occ>",
# kind is linear / vibrate / constrict, channel is 0-based. The stroke target is
# such an id (a Buttplug linear) or a backend sentinel: "serial" (COM T-code),
# "restim" (Restim websocket T-code for FOC/e-stim), or "handy" (The Handy cloud
# API — GameLoop drives it, not FunscriptPlayer, so the C# plan consumer leaves
# the stroke backend unset for it by design).
#
# Catalog entry (one connected Buttplug device):
#   { "id": "Edge 2#0", "linear": bool, "vibrate_channels": int, "constrict_channels": int }
# ---------------------------------------------------------------------------

const SERIAL_TARGET: String = "serial"
const RESTIM_TARGET: String = "restim"
const HANDY_TARGET: String = "handy"
const VIBE_SOURCES: Array = ["vibe1", "vibe2", "stroke"]  # "stroke" = follow the L0 envelope


static func make_actuator_id(device_id: String, kind: String, channel: int) -> String:
	return "%s:%s:%d" % [device_id, kind, channel]


# Splits an actuator id into { device, kind, channel }, or {} if malformed. Splits
# from the right, so device names (which never contain ':') stay intact.
static func parse_actuator_id(id: String) -> Dictionary:
	var parts: PackedStringArray = id.rsplit(":", true, 2)
	if parts.size() != 3 or not parts[2].is_valid_int():
		return {}
	return {"device": parts[0], "kind": parts[1], "channel": int(parts[2])}


# Resolves the config against `catalog`, dropping every route whose device isn't
# connected or whose channel is out of range. Returns:
#   {
#     "stroke":    {} | {"backend": "serial"|"restim"|"handy"|"bp", ...},
#     "vibration": [ {"device": <id>, "channel": <int>, "source": "vibe1"|"vibe2"|"stroke"}, ... ],
#     "constrict": [ {"device": <id>, "channel": <int>}, ... ],
#   }
static func resolve(
	stroke_target: String,
	vibration_routes: Dictionary,
	constrict_routes: Dictionary,
	catalog: Array
) -> Dictionary:
	var by_id: Dictionary = {}
	for entry: Dictionary in catalog:
		by_id[str(entry.get("id", ""))] = entry

	var plan: Dictionary = {"stroke": {}, "vibration": [], "constrict": []}

	# Stroke — exactly one target, or none when it isn't available. Backend
	# sentinels resolve unconditionally (availability is a runtime concern the
	# device banner owns, same as serial).
	if stroke_target == SERIAL_TARGET:
		plan["stroke"] = {"backend": "serial"}
	elif stroke_target == RESTIM_TARGET:
		plan["stroke"] = {"backend": "restim"}
	elif stroke_target == HANDY_TARGET:
		plan["stroke"] = {"backend": "handy"}
	elif stroke_target != "":
		var s: Dictionary = parse_actuator_id(stroke_target)
		if not s.is_empty() and s["kind"] == "linear" and by_id.has(s["device"]):
			if bool((by_id[s["device"]] as Dictionary).get("linear", false)):
				plan["stroke"] = {
					"backend": "bp", "device": s["device"], "channel": int(s["channel"])
				}

	# Vibration — each mapped actuator that's present with a valid channel + source.
	for aid: String in vibration_routes:
		var a: Dictionary = parse_actuator_id(aid)
		var source: String = str(vibration_routes[aid])
		if a.is_empty() or a["kind"] != "vibrate" or not VIBE_SOURCES.has(source):
			continue
		if not by_id.has(a["device"]):
			continue
		if int(a["channel"]) >= int((by_id[a["device"]] as Dictionary).get("vibrate_channels", 0)):
			continue
		(plan["vibration"] as Array).append(
			{"device": a["device"], "channel": int(a["channel"]), "source": source}
		)

	# Constrict — each enabled actuator that's present with a valid channel.
	for aid: String in constrict_routes:
		if not bool(constrict_routes[aid]):
			continue
		var c: Dictionary = parse_actuator_id(aid)
		if c.is_empty() or c["kind"] != "constrict" or not by_id.has(c["device"]):
			continue
		if (
			int(c["channel"])
			>= int((by_id[c["device"]] as Dictionary).get("constrict_channels", 0))
		):
			continue
		(plan["constrict"] as Array).append({"device": c["device"], "channel": int(c["channel"])})

	return plan
