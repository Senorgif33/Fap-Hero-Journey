class_name ReleaseLogic
extends RefCounted

# Pure helpers for the mid-round Release / "I came" control. GameLoop owns UI +
# side effects; this module decides visibility, press outcomes, and deadline
# awards so the mode matrix is unit-testable without a scene tree.


const MODES: Array[String] = [
	"windows",
	"stamp_flag",
	"fail_jump",
	"timed_window",
	"loop_until_clean",
	"punish_polarity",
]

# Builder dropdown — timed_window is deprecated (author as windows).
const BUILDER_MODES: Array[String] = [
	"windows",
	"stamp_flag",
	"fail_jump",
	"loop_until_clean",
	"punish_polarity",
]

# Press outcomes returned by press_action:
#   set_flag      — stamp release_flag, continue
#   fail_jump     — stop and JumpToNode(release_jump_to)
#   stamp         — mark pressed for timed_window (no flag unless release_flag set)
#   restart       — RestartCurrentRound / replay
#   success_stamp — punish_polarity must-release success (stamp flag, continue)
#   windows       — resolve band by playhead (GameLoop applies outcomes)
#   none          — ignore
const ACTION_SET_FLAG := "set_flag"
const ACTION_FAIL_JUMP := "fail_jump"
const ACTION_STAMP := "stamp"
const ACTION_RESTART := "restart"
const ACTION_SUCCESS_STAMP := "success_stamp"
const ACTION_WINDOWS := "windows"
const ACTION_NONE := "none"


static func normalize(src: Dictionary) -> Dictionary:
	return JourneyData.normalize_release_round(src)


# Whether the Release button / R hotkey should be live for this round.
static func is_available(cfg: Dictionary, has_flag: Callable) -> bool:
	if not bool(cfg.get("release_enabled", false)):
		return false
	var gate: String = str(cfg.get("release_disabled_if_flag", ""))
	if gate != "" and bool(has_flag.call(gate)):
		return false
	return true


static func press_action(cfg: Dictionary) -> String:
	if not bool(cfg.get("release_enabled", false)):
		return ACTION_NONE
	match str(cfg.get("release_mode", "")):
		"windows":
			return ACTION_WINDOWS
		"stamp_flag":
			return ACTION_SET_FLAG
		"fail_jump":
			return ACTION_FAIL_JUMP
		"timed_window":
			return ACTION_STAMP
		"loop_until_clean":
			return ACTION_RESTART
		"punish_polarity":
			# invert = must-release: pressing succeeds. Default: pressing fails.
			return (
				ACTION_SUCCESS_STAMP if bool(cfg.get("release_invert", false)) else ACTION_FAIL_JUMP
			)
		_:
			return ACTION_NONE


# Whether this press action leaves the round playing (eligible for round-level seek).
static func keeps_playing(action: String) -> bool:
	return action in [ACTION_SET_FLAG, ACTION_STAMP, ACTION_SUCCESS_STAMP, ACTION_WINDOWS]


# Round-level seek applies after continuing legacy presses (not windows — band seek).
static func applies_round_seek(cfg: Dictionary, action: String) -> bool:
	if int(cfg.get("release_seek_to_ms", -1)) < 0:
		return false
	match action:
		ACTION_SET_FLAG, ACTION_SUCCESS_STAMP:
			return true
		_:
			return false


# Score delta awarded when a timed_window deadline fires.
static func deadline_score(cfg: Dictionary, stamped: bool) -> int:
	return int(cfg.get("release_score_hit" if stamped else "release_score_miss", 0))


# punish_polarity + invert: finishing clean without pressing fails → jump.
static func fail_on_clean_finish(cfg: Dictionary, pressed: bool) -> bool:
	return (
		bool(cfg.get("release_enabled", false))
		and str(cfg.get("release_mode", "")) == "punish_polarity"
		and bool(cfg.get("release_invert", false))
		and not pressed
	)


# First band where until_ms == 0 or t < until_ms. Empty → {}.
static func resolve_window(cfg: Dictionary, t_ms: int) -> Dictionary:
	var bands: Array = cfg.get("release_windows", []) as Array
	if bands.is_empty():
		return {}
	var t: int = maxi(0, t_ms)
	for b: Variant in bands:
		if not (b is Dictionary):
			continue
		var until: int = int((b as Dictionary).get("until_ms", 0))
		if until == 0 or t < until:
			return b as Dictionary
	# Fallback: last band (should be open-ended after normalize).
	var last: Variant = bands[bands.size() - 1]
	return last as Dictionary if last is Dictionary else {}


# Finite-band "award coins if no release" newly due at playhead t_ms (never pressed).
# `fired` is a Dictionary-as-set of band indices already awarded; mutated in place.
static func expire_coins_due(cfg: Dictionary, t_ms: int, pressed: bool, fired: Dictionary) -> int:
	if pressed or str(cfg.get("release_mode", "")) != "windows":
		return 0
	var bands: Array = cfg.get("release_windows", []) as Array
	var total: int = 0
	var t: int = maxi(0, t_ms)
	for i: int in bands.size():
		if fired.has(i):
			continue
		var b: Dictionary = bands[i] as Dictionary
		var until: int = int(b.get("until_ms", 0))
		if until <= 0:
			continue  # open-ended → round-end path
		if t < until:
			continue
		var delta: int = int(b.get("expire_coins", b.get("expire_score", 0)))
		fired[i] = true
		total += delta
	return total


# Open-ended last band expire_coins at clean round end (never pressed).
static func expire_coins_at_round_end(cfg: Dictionary, pressed: bool, fired: Dictionary) -> int:
	if pressed or str(cfg.get("release_mode", "")) != "windows":
		return 0
	var bands: Array = cfg.get("release_windows", []) as Array
	if bands.is_empty():
		return 0
	var last_i: int = bands.size() - 1
	if fired.has(last_i):
		return 0
	var last: Dictionary = bands[last_i] as Dictionary
	if int(last.get("until_ms", 0)) != 0:
		return 0
	var delta: int = int(last.get("expire_coins", last.get("expire_score", 0)))
	fired[last_i] = true
	return delta


# Back-compat aliases for callers/tests still using the old names.
static func expire_scores_due(cfg: Dictionary, t_ms: int, pressed: bool, fired: Dictionary) -> int:
	return expire_coins_due(cfg, t_ms, pressed, fired)


static func expire_score_at_round_end(cfg: Dictionary, pressed: bool, fired: Dictionary) -> int:
	return expire_coins_at_round_end(cfg, pressed, fired)
