class_name FunscriptIntensity
extends RefCounted
## Derives a 1–5 intensity rating from a funscript's actions using AVERAGE SPEED —
## the sum of absolute position deltas divided by the script's duration, in
## positions/second. Average speed captures both how often the device strokes and
## how far it travels, so it tracks "how vigorous" a script feels better than raw
## action count. Pure + unit-tested; the buckets are deliberately rough (the user
## can override any clip's intensity by hand).

# Ascending positions/sec thresholds. A speed ≥ THRESHOLDS[i] bumps the rating one
# level, so [1] slow → [5] extreme. Tuned to typical stroke scripts (positions are
# the 0–100 funscript scale): ~80/s is a gentle 1 Hz half-range stroke, ~550+/s is
# fast full-range.
const SPEED_THRESHOLDS: Array[float] = [100.0, 250.0, 400.0, 550.0]

# Returned when a script can't be read/parsed — a neutral middle rating.
const UNKNOWN_INTENSITY: int = 3


# Average speed (positions/sec) of an actions array [{at:ms, pos:0-100}, …].
static func average_speed(actions: Array) -> float:
	if actions.size() < 2:
		return 0.0
	var dist: float = 0.0
	var prev: float = float((actions[0] as Dictionary).get("pos", 0))
	for i in range(1, actions.size()):
		var pos: float = float((actions[i] as Dictionary).get("pos", 0))
		dist += absf(pos - prev)
		prev = pos
	var span_ms: float = float(
		int((actions[-1] as Dictionary).get("at", 0)) - int((actions[0] as Dictionary).get("at", 0))
	)
	if span_ms <= 0.0:
		return 0.0
	return dist / (span_ms / 1000.0)


# Maps an average speed to a 1–5 bucket via SPEED_THRESHOLDS.
static func bucket(speed: float) -> int:
	var level: int = 1
	for t: float in SPEED_THRESHOLDS:
		if speed >= t:
			level += 1
	return level


static func from_actions(actions: Array) -> int:
	if actions.size() < 2:
		return 1  # no motion → gentlest
	return bucket(average_speed(actions))


# Reads a funscript file and rates it. Returns UNKNOWN_INTENSITY when the path is
# empty/unreadable/unparseable so a caller gets a sane default.
static func from_path(path: String) -> int:
	if path == "" or not FileAccess.file_exists(ProjectSettings.globalize_path(path)):
		return UNKNOWN_INTENSITY
	var f: FileAccess = FileAccess.open(path, FileAccess.READ)
	if f == null:
		return UNKNOWN_INTENSITY
	var parser := JSON.new()
	var ok: bool = parser.parse(f.get_as_text()) == OK and parser.data is Dictionary
	f.close()
	if not ok:
		return UNKNOWN_INTENSITY
	return from_actions((parser.data as Dictionary).get("actions", []))
