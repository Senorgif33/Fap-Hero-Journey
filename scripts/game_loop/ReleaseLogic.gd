class_name ReleaseLogic
extends RefCounted

# Pure helpers for the mid-round Release / "I came" control. GameLoop owns UI +
# side effects; this module decides visibility, press outcomes, and deadline
# awards so the mode matrix is unit-testable without a scene tree.


const MODES: Array[String] = [
	"stamp_flag",
	"fail_jump",
	"timed_window",
	"loop_until_clean",
	"punish_polarity",
]

# Press outcomes returned by press_action:
#   set_flag      — stamp release_flag, continue
#   fail_jump     — stop and JumpToNode(release_jump_to)
#   stamp         — mark pressed for timed_window (no flag unless release_flag set)
#   restart       — RestartCurrentRound / replay
#   success_stamp — punish_polarity must-release success (stamp flag, continue)
#   none          — ignore
const ACTION_SET_FLAG := "set_flag"
const ACTION_FAIL_JUMP := "fail_jump"
const ACTION_STAMP := "stamp"
const ACTION_RESTART := "restart"
const ACTION_SUCCESS_STAMP := "success_stamp"
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
