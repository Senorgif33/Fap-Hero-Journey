class_name JourneyData
extends RefCounted

# ---------------------------------------------------------------------------
# JourneyData
# Pure-data helpers for the journey-builder model. No UI. Stateless static-
# style methods that take and return plain Dictionaries / Arrays.
#
# The "model" is a flat Array of item dicts where each item is one of:
#   { type: "round",      name, funscript_path, video_path, coins }
#   { type: "shop",       title, mode, count, items, price_multiplier }
#   { type: "storyboard", coins, image, lines }
#   { type: "fork",       title, description, paths: [ {name, description, image_path, items: [...]} ] }
# Nested forks are stored inside a path's `items` array (recursive).
#
# Used by JourneyBuilder.gd via class-name calls:
#   JourneyData.parse_journey(j)            – inflate from saved JSON dict
#   JourneyData.validate(items, name)       – returns "" or first error
#   JourneyData.find_video_in_round(folder) – first video file in a folder
# ---------------------------------------------------------------------------

const DIFFICULTIES: Array = ["Easy", "Medium", "Hard", "Very Hard", "Extreme", "Insane"]

const VIDEO_EXTENSIONS:     Array[String] = ["mp4", "m4v", "mkv", "avi", "mov", "wmv", "webm"]
const FUNSCRIPT_EXTENSIONS: Array[String] = ["funscript", "json"]
const IMAGE_EXTENSIONS:     Array[String] = ["png", "jpg", "jpeg", "webp"]

# Secondary T-code axes supported for serial devices (L0 = main stroke, handled separately).
const EXTRA_AXES: Array[String] = ["L1", "L2", "R0", "R1", "R2"]

# Standard funscript multi-axis / vibrator suffixes, keyed by our internal channel
# id. Used to name pooled channel scripts (content/m_<fp>.<suffix>.funscript) so the
# pooled files stay self-describing and follow the funscript multi-axis convention.
const AXIS_SUFFIXES: Dictionary = {
	"L1": "surge", "L2": "sway", "R0": "twist", "R1": "roll", "R2": "pitch",
}
const VIB_SUFFIXES: Dictionary = {
	"vib1": "vibe1", "vib2": "vibe2",
}

# Curse catalog — the GAMEPLAY afflictions a cursed round can apply (they change
# the device output, the economy, or the controls). Non-gameplay visual/audio
# effects live in SENSORY_CATALOG below. Single source of truth shared by the
# builder (curse picker) and GameLoop (rolling/applying). Each entry is a
# boss-modifier-shaped dict: stroke curses (scale/clamp/reverse/block) are applied
# by FunscriptPlayer; the rest (coin_penalty/toll/hud_hide/no_pause) by GameLoop.
# "name" is the unique id used to select.
const CURSE_CATALOG: Array = [
	{"kind": "scale",        "factor": 0.6,        "name": "Shrunken", "desc": "Strokes shortened to 60% of their length."},
	{"kind": "clamp",        "min": 40, "max": 60, "name": "Choked",   "desc": "Strokes confined to the middle of the range."},
	{"kind": "clamp",        "min": 0,  "max": 45, "name": "Sunken",   "desc": "Strokes confined to the bottom of the range."},
	{"kind": "reverse",                            "name": "Inverted", "desc": "Up and down are flipped."},
	{"kind": "block",                              "name": "Numbed",   "desc": "The device ignores the script entirely."},
	{"kind": "coin_penalty", "factor": 0.5,        "name": "Greed",    "desc": "Coins earned this round are halved."},
	{"kind": "coin_penalty", "factor": 0.0,        "name": "Pauper",   "desc": "No coins are earned this round."},
	{"kind": "toll",                               "name": "Toll",     "desc": "Lose 40 coins immediately."},
	{"kind": "hud_hide",                           "name": "Fog",      "desc": "The HUD is hidden for the whole round."},
	{"kind": "no_pause",                           "name": "Restless", "desc": "You can't pause this round."},
]

# Non-gameplay (sensory) modifiers — purely visual/audio; they don't touch the
# device, economy, or controls. Authors can add these to cursed or boss rounds
# (the "Non-gameplay modifiers" picker), and a cursed round can optionally let
# them into its random pool. Single-sourced here; GameLoop applies every kind via
# its hex pipeline (_apply_hex), and Blinded rides the active-effect chip scan.
# Each entry with an adjustable intensity carries imin/imax/idef: a per-round
# slider edits a normalized intensity (0–1), and the real effect value is
# lerp(imin, imax, intensity). imin may exceed imax for "inverted" effects where
# a stronger result is a lower number (pixelate blocks, strobe interval, low-pass
# cutoff, tunnel ramp). idef reproduces the current default value. Binary effects
# (Blinded, Silence) carry no intensity fields → no slider.
const SENSORY_CATALOG: Array = [
	# Visibility / audio deniers.
	{"kind": "blackout",  "name": "Blinded",  "desc": "The video is hidden — the device plays on in the dark."},
	{"kind": "murk",      "name": "Murk",     "desc": "The screen is dimmed.", "imin": 0.40, "imax": 0.95, "idef": 0.58},
	{"kind": "tunnel",    "name": "Tunnel",   "desc": "Vision closes to a narrow tunnel.", "imin": 0.60, "imax": 0.20, "idef": 0.38},
	{"kind": "strobe",    "name": "Strobe",   "desc": "The screen fades to black and back every few seconds.", "imin": 5.0, "imax": 1.0, "idef": 0.50},
	{"kind": "mute",      "name": "Silence",  "desc": "The audio is muted."},
	# Per-pixel video effects (one composable shader on the video).
	{"kind": "grayscale", "name": "Drained",  "desc": "Color is drained from the video.", "imin": 0.40, "imax": 1.00, "idef": 1.00},
	{"kind": "blur",      "name": "Bleary",   "desc": "The video blurs out of focus.", "imin": 1.0, "imax": 6.0, "idef": 0.30},
	{"kind": "pixelate",  "name": "Censored", "desc": "The video is pixelated.", "imin": 160.0, "imax": 30.0, "idef": 0.54},
	{"kind": "invert",    "name": "Negative", "desc": "The video's colors are inverted.", "imin": 0.40, "imax": 1.00, "idef": 1.00},
	{"kind": "sepia",     "name": "Faded",    "desc": "The video washes out to sepia.", "imin": 0.40, "imax": 1.00, "idef": 1.00},
	{"kind": "posterize", "name": "Banded",   "desc": "The video's colors crush into harsh bands.", "imin": 10.0, "imax": 3.0, "idef": 0.71},
	{"kind": "saturate",  "name": "Feverish", "desc": "The video's colors run hot and oversaturated.", "imin": 1.4, "imax": 3.5, "idef": 0.38},
	{"kind": "chromatic", "name": "Fracture", "desc": "The video's colors split apart.", "imin": 0.002, "imax": 0.020, "idef": 0.22},
	{"kind": "wave",      "name": "Swoon",    "desc": "The video ripples and sways.", "imin": 0.003, "imax": 0.020, "idef": 0.29},
	# Overlay-node visual effects.
	{"kind": "bloodshot", "name": "Bloodshot",   "desc": "A red haze pulses over the screen.", "imin": 0.50, "imax": 1.00, "idef": 1.00},
	{"kind": "static",    "name": "Interference","desc": "Static crawls across the screen.", "imin": 0.12, "imax": 0.50, "idef": 0.47},
	{"kind": "flicker",   "name": "Flicker",  "desc": "The screen flickers erratically.", "imin": 0.50, "imax": 1.20, "idef": 0.71},
	{"kind": "tremor",    "name": "Tremor",   "desc": "The screen shakes.", "imin": 3.0, "imax": 18.0, "idef": 0.40},
	# Audio-bus effects.
	{"kind": "lowpass",   "name": "Muffled",  "desc": "The audio is muffled, as if underwater.", "imin": 2200.0, "imax": 300.0, "idef": 0.79},
	{"kind": "reverb",    "name": "Cavern",   "desc": "The audio echoes in a vast space.", "imin": 0.30, "imax": 0.90, "idef": 0.50},
	{"kind": "distort",   "name": "Distorted","desc": "The audio is distorted and harsh.", "imin": 0.20, "imax": 0.90, "idef": 0.43},
	{"kind": "volwobble", "name": "Faltering","desc": "The audio swells and fades.", "imin": -10.0, "imax": -40.0, "idef": 0.47},
]

# The SENSORY_CATALOG kinds that are audio (everything else is visual). Used to
# split the "Non-gameplay modifiers" picker into Visual / Audio subsections.
const AUDIO_SENSORY_KINDS: Array = ["mute", "lowpass", "reverb", "distort", "volwobble"]

# Boon catalog — the blessings a blessed round can apply. Like CURSE_CATALOG, but
# positive. score_multiplier/coin_jackpot/scale ride existing effect kinds;
# gift/ward/lingering/interest are applied by GameLoop.
const BLESSING_CATALOG: Array = [
	{"kind": "score_multiplier", "factor": 2.0,    "name": "Fervor",    "desc": "Double score this round."},
	{"kind": "coin_jackpot",     "factor": 2.0,    "name": "Fortune",   "desc": "Double the coins earned this round."},
	{"kind": "scale",            "factor": 1.35,   "name": "Surge",     "desc": "Stronger, longer strokes."},
	{"kind": "gift",                               "name": "Gift",      "desc": "Start the round holding a free item."},
	{"kind": "ward",                               "name": "Ward",      "desc": "The next curse is repelled automatically."},
	{"kind": "lingering",                          "name": "Lingering", "desc": "Your active item effects don't run out this round."},
	{"kind": "interest",                           "name": "Interest",  "desc": "Gain coins equal to 25% of your balance."},
]


# ── Round serialization ──────────────────────────────────────────────────────

# Normalizes a graph node's in-editor `data` into its canonical on-disk (Format-2) form: the
# lowercase field set the runtime + scanner expect, with every field typed. Two jobs:
#   1. Guarantee the BASELINE fields a node always carries (a never-edited new node has only
#      a couple of keys; the runtime should still get a complete, fully-populated record).
#   2. Re-coerce numerics: JSON loads every number as float, so coins/costs round-trip as 5.0
#      unless re-coerced to int here — the "coins lesson" (HANDOFF §1a).
# Any EXTRA keys already on `data` (e.g. boss_modifiers, future fields) pass through via the
# initial deep copy. The save walk rewrites the MEDIA-path fields AFTER this. Pure → unit-tested.
static func coerce_node_save_data(type: String, data: Dictionary) -> Dictionary:
	var out: Dictionary = data.duplicate(true)
	out.erase("type")     # node-level — lives outside data on disk
	out.erase("node_id")  # node-level — the node's dict key IS its id
	out.erase("paths")    # legacy tree key; fork choices are out-edges in the graph
	# Scalars get coercing overwrites (value types — no aliasing). Collection fields (arrays /
	# dicts) are ALREADY deep-copied into `out`; only fill a default when ABSENT — reassigning
	# `out[k] = data.get(k, …)` would re-alias the source's live array/dict and let a later
	# mutation of the save-data bleed back into the editor node.
	match type:
		"round":
			# The full round field set, lowercase. Media paths (funscript/video/boss/axis/vib) +
			# action_count/length_ms + folder are overwritten afterwards by _save_round_node_media.
			out["coins"]           = int(data.get("coins", 0))
			out["round_type"]      = str(data.get("round_type", "normal"))
			out["is_checkpoint"]   = bool(data.get("is_checkpoint", false))
			out["curse_reward"]    = int(data.get("curse_reward", 0))
			out["cleanse_cost"]    = int(data.get("cleanse_cost", 50))
			out["curse_random"]    = bool(data.get("curse_random", true))
			out["boon_random"]     = bool(data.get("boon_random", true))
			out["gift_item"]       = str(data.get("gift_item", ""))
			out["boss_tagline"]    = str(data.get("boss_tagline", ""))
			out["sensory_in_pool"] = bool(data.get("sensory_in_pool", false))
			out["show_reveal"]     = bool(data.get("show_reveal", true))
			_fill_default(out, "curses", [])
			_fill_default(out, "boons", [])
			_fill_default(out, "boss_modifiers", [])   # lowercase {kind,…}; deep-copied pass-through
			_fill_default(out, "sensory", [])
			_fill_default(out, "sensory_intensity", {})
		"shop":
			out["title"]            = str(data.get("title", ""))
			out["mode"]             = str(data.get("mode", "pool"))
			out["count"]            = int(data.get("count", 3))
			out["price_multiplier"] = float(data.get("price_multiplier", 1.0))
			_fill_default(out, "items", [])
		"storyboard":
			# image + lines are overwritten by _save_storyboard_node_media.
			out["coins"] = int(data.get("coins", 0))
			out["item"]  = str(data.get("item", ""))
		"fork":
			out["title"]        = str(data.get("title", ""))
			out["description"]  = str(data.get("description", ""))
			out["resolution"]   = str(data.get("resolution", "choice"))
			out["cond_metric"]  = str(data.get("cond_metric", "score"))
			out["cond_decider"] = str(data.get("cond_decider", "game"))
			out["default_path"] = int(data.get("default_path", 0))
			out["after_order"]  = int(data.get("after_order", 0))
	return out


# Sets out[key] = default only when key is absent. Used for collection fields whose present
# value is already deep-copied into `out`, so we must not reassign and re-alias the source.
static func _fill_default(out: Dictionary, key: String, default: Variant) -> void:
	if not out.has(key):
		out[key] = default


# ── Item templates ───────────────────────────────────────────────────────────

# A stable per-node id, minted when an item is created and persisted to journey.json
# as "NodeId". JourneyGraph.build_graph uses it as the graph node key, so ids survive
# saves — the anchor that lets redirect edges (skip/converge) and Test-From-Here seeks
# reference a node. Random rather than a counter so copy/paste (across items, paths, or
# journeys) can't collide; build_graph also guards against a stray duplicate.
static func new_node_id() -> String:
	return "n_%08x%08x" % [randi(), randi()]


# Normalizes a flag list (from a comma-separated field or a saved array) to a deduped, trimmed,
# non-empty string array. Shared by a node's "sets flags" and a fork choice's "sets flags".
static func clean_flag_list(v: Variant) -> Array:
	var out: Array = []
	var src: Array = v if v is Array else []
	for f: Variant in src:
		var s: String = str(f).strip_edges()
		if s != "" and not (s in out):
			out.append(s)
	return out


# Returns a fresh default item dict for a builder node of the given type. Single
# source of truth for the empty-item shape, used by the insert menu, the quick-
# add buttons, and the Ctrl+1–4 shortcuts.
static func new_item(type: String) -> Dictionary:
	match type:
		"round":
			return {"type": "round", "name": "", "funscript_path": "", "video_path": "", "coins": 0, "axis_scripts": {}, "node_id": new_node_id()}
		"shop":
			return {"type": "shop", "title": "", "node_id": new_node_id()}
		"storyboard":
			# coins / item: optional reward granted when the storyboard is finished.
			return {"type": "storyboard", "coins": 0, "item": "", "image": "", "lines": [], "node_id": new_node_id()}
		"fork":
			# resolution: "choice" | "random" | "conditional" | "sacrifice"
			# cond_metric (conditional only): "score" | "coins" | "item"
			# default_path (conditional only): index taken when no rule matches
			# Per-path config (only the field(s) for the active resolution are used):
			#   weight (random) · threshold (conditional score/coins) ·
			#   required_item (conditional item check, OR sacrifice — consumed) ·
			#   cost (sacrifice — coins spent). required_item "" = none/free.
			return {"type": "fork", "node_id": new_node_id(), "title": "", "description": "",
				"resolution": "choice", "cond_metric": "score", "default_path": 0,
				"paths": [
					{"name": "Path A", "description": "", "image_path": "", "items": [], "weight": 1, "threshold": 0, "required_item": "", "cost": 0},
					{"name": "Path B", "description": "", "image_path": "", "items": [], "weight": 1, "threshold": 0, "required_item": "", "cost": 0},
				]}
	return {"type": type}


# ── Parse ───────────────────────────────────────────────────────────────────

# Takes a journey dict as parsed by JourneySelect._parse_journey() and
# returns the builder model:
#   {
#     "name":           String,
#     "author":         String,
#     "description":    String,
#     "difficulty_idx": int,
#     "cover_path":     String,
#     "items":          Array[Dictionary],
#   }
static func parse_journey(journey: Dictionary) -> Dictionary:
	var name: String        = journey.get("title", "")
	var author: String      = journey.get("author", "")
	var description: String = journey.get("description", "")

	var diff: String  = journey.get("difficulty", "Easy")
	var diff_idx: int = DIFFICULTIES.find(diff)
	if diff_idx < 0:
		diff_idx = 0

	var cover_path: String = journey.get("cover_path", "")

	var rounds: Array = (journey.get("rounds", []) as Array).duplicate()
	rounds.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return (a.get("order", 0) as int) < (b.get("order", 0) as int)
	)
	var forks:       Array = (journey.get("forks",       []) as Array).duplicate()
	var shops:       Array = (journey.get("shops",       []) as Array).duplicate()
	var storyboards: Array = (journey.get("storyboards", []) as Array).duplicate()

	# Interleave by the same key scheme as GameState.BuildSequence so authoring
	# order is preserved after a round-trip through disk.
	var seq: Array = []
	for r: Dictionary in rounds:
		seq.append({
			"key":  (r.get("order", 0) as int) * 3,
			"data": {
				"type":            "round",
				"name":            r.get("name", ""),
				"funscript_path":  r.get("funscript_path", ""),
				"axis_scripts":    r.get("axis_scripts", {}),
				"vib_scripts":     r.get("vib_scripts", {}),
				"round_type":      r.get("round_type", "normal"),
				"is_checkpoint":   bool(r.get("is_checkpoint", false)),
				"curse_reward":    int(r.get("curse_reward", 0)),
				"cleanse_cost":    int(r.get("cleanse_cost", 50)),
				"curse_random":    bool(r.get("curse_random", true)),
				"curses":          (r.get("curses", []) as Array).duplicate(),
				"boon_random":     bool(r.get("boon_random", true)),
				"boons":           (r.get("boons", []) as Array).duplicate(),
				"gift_item":       r.get("gift_item", ""),
				"boss_image":      r.get("boss_image", ""),
				"boss_tagline":    r.get("boss_tagline", ""),
				"boss_modifiers":  r.get("boss_modifiers", []),
				"sensory":         (r.get("sensory", []) as Array).duplicate(),
				"sensory_in_pool": bool(r.get("sensory_in_pool", false)),
				"sensory_intensity": (r.get("sensory_intensity", {}) as Dictionary).duplicate(),
				"show_reveal":     bool(r.get("show_reveal", true)),
				"video_path":      _round_video(r),
				"coins":           r.get("coins", 0),
				"original_folder": r.get("folder", ""),
				"node_id":         r.get("node_id", ""),
			},
		})
	for sb: Dictionary in storyboards:
		seq.append({
			"key":  (sb.get("order", 0) as int) * 3,
			"data": {
				"type":  "storyboard",
				"coins": sb.get("coins", 0),
				"item":  sb.get("item", ""),
				"image": sb.get("image", ""),
				"lines": sb.get("lines", []),
				"node_id": sb.get("node_id", ""),
			},
		})
	for sh: Dictionary in shops:
		seq.append({
			"key":  (sh.get("after_order", 0) as int) * 3 + 1,
			"data": _build_shop_item(sh),
		})
	for f: Dictionary in forks:
		seq.append({
			"key":  (f.get("after_order", 0) as int) * 3 + 2,
			"data": _build_fork_item(f),
		})
	# Sort by runtime key, tie-break by append index. Current saves give every
	# item a unique key (monotonic position), so ties never happen — but a journey
	# last saved under the old "anchor shops/forks to the previous round" scheme can
	# have colliding keys, and a bare sort_custom is NOT stable, so those journeys
	# would load in a different item order on each open. That nondeterminism is what
	# made Test-From-Here behave differently per reopen. The index tie-break pins a
	# deterministic order.
	for i in seq.size():
		seq[i]["_ord"] = i
	seq.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return (a["key"] as int) < (b["key"] as int) if a["key"] != b["key"] else (a["_ord"] as int) < (b["_ord"] as int))

	var items: Array = []
	for s in seq:
		items.append(s["data"])

	return {
		"name":           name,
		"author":         author,
		"description":    description,
		"difficulty_idx": diff_idx,
		"cover_path":     cover_path,
		"tags":           journey.get("tags", []),
		"map_enabled":    bool(journey.get("map_enabled", true)),
		"map_fog":        bool(journey.get("map_fog", false)),
		"map_fog_reveal": int(journey.get("map_fog_reveal", 1)),
		"redirects":      journey.get("redirects", {}),
		"items":          items,
	}


# Inflates a scanned shop dict into the builder's shop item model.
static func _build_shop_item(sh: Dictionary) -> Dictionary:
	return {
		"type":             "shop",
		"title":            sh.get("title", ""),
		"mode":             sh.get("mode", "pool"),
		"count":            int(sh.get("count", 3)),
		"items":            (sh.get("items", []) as Array).duplicate(),
		"price_multiplier": float(sh.get("price_multiplier", 1.0)),
		"node_id":          sh.get("node_id", ""),
	}


static func _build_fork_item(f: Dictionary) -> Dictionary:
	var paths_out: Array = []
	for p: Dictionary in f.get("paths", []):
		paths_out.append({
			"name":          p.get("name", ""),
			"description":   p.get("description", ""),
			"image_path":    p.get("image_path", ""),
			"items":         _build_path_items(p),
			"weight":        int(p.get("weight", 1)),
			"threshold":     int(p.get("threshold", 0)),
			"required_item": str(p.get("required_item", "")),
			"cost":          int(p.get("cost", 0)),
		})
	return {
		"type":         "fork",
		"title":        f.get("title", ""),
		"description":  f.get("description", ""),
		"resolution":   str(f.get("resolution", "choice")),
		"cond_metric":  str(f.get("cond_metric", "score")),
		"default_path": int(f.get("default_path", 0)),
		"paths":        paths_out,
		"node_id":      f.get("node_id", ""),
	}


# Recursively rebuilds a path's mixed items[] array from the parsed-journey
# separate rounds/storyboards/shops/forks arrays. Nested forks recurse.
static func _build_path_items(p: Dictionary) -> Array:
	var sub: Array = []
	for pr: Dictionary in p.get("rounds", []):
		sub.append({
			"key":  (pr.get("order", 0) as int) * 3,
			"data": {
				"type":            "round",
				"name":            pr.get("name", ""),
				"funscript_path":  pr.get("funscript_path", ""),
				"axis_scripts":    pr.get("axis_scripts", {}),
				"vib_scripts":     pr.get("vib_scripts", {}),
				"round_type":      pr.get("round_type", "normal"),
				"is_checkpoint":   bool(pr.get("is_checkpoint", false)),
				"curse_reward":    int(pr.get("curse_reward", 0)),
				"cleanse_cost":    int(pr.get("cleanse_cost", 50)),
				"curse_random":    bool(pr.get("curse_random", true)),
				"curses":          (pr.get("curses", []) as Array).duplicate(),
				"boon_random":     bool(pr.get("boon_random", true)),
				"boons":           (pr.get("boons", []) as Array).duplicate(),
				"gift_item":       pr.get("gift_item", ""),
				"boss_image":      pr.get("boss_image", ""),
				"boss_tagline":    pr.get("boss_tagline", ""),
				"boss_modifiers":  pr.get("boss_modifiers", []),
				"sensory":         (pr.get("sensory", []) as Array).duplicate(),
				"sensory_in_pool": bool(pr.get("sensory_in_pool", false)),
				"sensory_intensity": (pr.get("sensory_intensity", {}) as Dictionary).duplicate(),
				"show_reveal":     bool(pr.get("show_reveal", true)),
				"video_path":      _round_video(pr),
				"coins":           pr.get("coins", 0),
				"original_folder": pr.get("folder", ""),
				"node_id":         pr.get("node_id", ""),
			},
		})
	for psb: Dictionary in p.get("storyboards", []):
		sub.append({
			"key":  (psb.get("order", 0) as int) * 3,
			"data": {
				"type":  "storyboard",
				"coins": psb.get("coins", 0),
				"item":  psb.get("item", ""),
				"image": psb.get("image", ""),
				"lines": psb.get("lines", []),
				"node_id": psb.get("node_id", ""),
			},
		})
	for ps: Dictionary in p.get("shops", []):
		sub.append({
			"key":  (ps.get("after_order", 0) as int) * 3 + 1,
			"data": _build_shop_item(ps),
		})
	for nf: Dictionary in p.get("forks", []):
		sub.append({
			"key":  (nf.get("after_order", 0) as int) * 3 + 2,
			"data": _build_fork_item(nf),
		})
	# Stable tie-break by append index (see parse_journey) so a fork path with
	# legacy colliding keys orders deterministically instead of varying per open.
	for i in sub.size():
		sub[i]["_ord"] = i
	sub.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return (a["key"] as int) < (b["key"] as int) if a["key"] != b["key"] else (a["_ord"] as int) < (b["_ord"] as int))
	var items: Array = []
	for s in sub:
		items.append(s["data"])
	return items


# ── Validate ────────────────────────────────────────────────────────────────

# Returns "" if the model is valid for saving, otherwise a user-facing message
# describing the first problem encountered.
static func validate(items: Array, journey_name: String) -> String:
	if journey_name.strip_edges() == "":
		return "Please enter a journey name."

	var top_round_count: int = items.reduce(
		func(acc: int, it: Dictionary) -> int:
			return acc + (1 if it.get("type", "round") == "round" else 0),
		0)
	if top_round_count == 0:
		return "Please add at least one round before saving."

	var round_idx_global: int = 0
	for item: Dictionary in items:
		var item_type: String = item.get("type", "round")
		match item_type:
			"round":
				round_idx_global += 1
				if (item.get("name", "") as String).strip_edges() == "":
					return "Round %d needs a name." % round_idx_global
				if item.get("funscript_path", "") == "":
					return "Round \"%s\" needs a funscript." % item.get("name", "?")
			"fork":
				var context_label: String = "fork after round %d" % round_idx_global
				var fork_error: String = validate_fork(item, context_label)
				if fork_error != "":
					return fork_error
			"storyboard":
				var lines: Array = item.get("lines", [])
				if lines.is_empty():
					return "A storyboard needs at least one line."
	return ""


# Recursively validates a fork. Returns "" if OK, or an error message.
# `context_label` is used in messages so the user knows where the error is
# (e.g. "fork after round 3" or "nested fork in path \"Path A\"").
static func validate_fork(fork_item: Dictionary, context_label: String) -> String:
	var paths: Array = fork_item.get("paths", [])
	if paths.size() < 2:
		return "The %s needs at least 2 paths." % context_label
	for pi in paths.size():
		var ppath: Dictionary = paths[pi]
		var pname: String = ppath.get("name", "")
		if pname.strip_edges() == "":
			return "Path %d of %s needs a name." % [pi + 1, context_label]
		var pi_list: Array = ppath.get("items", [])
		var pr_count: int = pi_list.reduce(
			func(acc: int, x: Dictionary) -> int:
				return acc + (1 if x.get("type", "round") == "round" else 0),
			0)
		if pr_count == 0:
			return "Path \"%s\" (in %s) needs at least one round." % [pname, context_label]
		for pi_item: Dictionary in pi_list:
			var pi_t: String = pi_item.get("type", "round")
			match pi_t:
				"round":
					if (pi_item.get("name", "") as String).strip_edges() == "":
						return "A round in path \"%s\" needs a name." % pname
					if pi_item.get("funscript_path", "") == "":
						return "Round \"%s\" in path \"%s\" needs a funscript." % [pi_item.get("name", "?"), pname]
				"fork":
					var nested_err: String = validate_fork(pi_item, "nested fork in path \"%s\"" % pname)
					if nested_err != "":
						return nested_err
	return ""


# ── Filesystem helpers ──────────────────────────────────────────────────────

# Resolves a round's video: the explicit scanner-provided path when present
# (the shared-media / VideoPath case), else a folder-scan fallback so journeys
# saved before VideoPath keep resolving. r is a scanner round_data dict.
static func _round_video(r: Dictionary) -> String:
	var explicit: String = r.get("video_path", "")
	if explicit != "":
		return explicit
	return find_video_in_round(r.get("folder", ""))


# Returns the path to the first video file in `folder`, or "" if none.
static func find_video_in_round(folder: String) -> String:
	if folder == "":
		return ""
	var dir: DirAccess = DirAccess.open(folder)
	if dir == null:
		return ""
	dir.list_dir_begin()
	var fname: String = dir.get_next()
	while fname != "":
		if not dir.current_is_dir() and fname.get_extension().to_lower() in VIDEO_EXTENSIONS:
			dir.list_dir_end()
			return folder + "/" + fname
		fname = dir.get_next()
	dir.list_dir_end()
	return ""


# ── Shared content pool ──────────────────────────────────────────────────────
# Per-round playback assets (video / funscript / axis / vib / boss image) are
# stored once under content/m_<fingerprint>.<ext> and referenced by explicit
# paths, so an asset reused across rounds (e.g. a clip used by a Normal round and
# a Cursed round in a fork) lives on disk and in the shared zip exactly once.
# (The media/ folder is separate — it holds journey images.)

# Source identity for pool dedup: globalized path + byte size + mtime, hashed to
# a short hex. Deliberately NOT a content hash — that would mean reading whole
# multi-GB videos every save. Two rounds reusing the same source file produce the
# same fingerprint (so they pool to one file); editing the source (new size or
# mtime) yields a new fingerprint, so a re-save picks up the changed bytes.
static func media_fingerprint(src: String) -> String:
	var abs: String = ProjectSettings.globalize_path(src)
	var size: int = 0
	var f: FileAccess = FileAccess.open(abs, FileAccess.READ)
	if f != null:
		size = f.get_length()
		f.close()
	var mtime: int = FileAccess.get_modified_time(abs)
	var identity: String = "%s|%d|%d" % [abs, size, mtime]
	return identity.sha256_text().substr(0, 16)


# Journey-root-relative path for a fingerprinted pooled content file. Pooled
# playback content (video / funscript / axis / vib / boss image) lives under
# content/, kept separate from media/ which holds journey IMAGES (cover,
# storyboard art, fork-path art).
static func pooled_media_rel(fingerprint: String, ext: String) -> String:
	return "content/m_%s.%s" % [fingerprint, ext]


# Pure dedup planner (the testable core of the save-time pooling). `sources` is
# an ordered Array of {fingerprint, ext}; returns a parallel Array of
# {rel, copy} where `copy` is true only the first time a given pooled rel is
# seen — repeats reference the same rel and skip the write. The save flow mirrors
# this with a live map so it can interleave the async transcode/copy work.
static func plan_media_pool(sources: Array) -> Array:
	var out: Array = []
	var seen: Dictionary = {}
	for s: Dictionary in sources:
		var rel: String = pooled_media_rel(s.get("fingerprint", ""), s.get("ext", ""))
		var is_copy: bool = not seen.has(rel)
		seen[rel] = true
		out.append({"rel": rel, "copy": is_copy})
	return out


# Recursively deletes a directory and all its contents. Accepts either a
# user:// path or an OS-absolute path — globalize_path leaves absolutes
# unchanged, so this is safe for both callers.
static func delete_dir_recursive(path: String) -> void:
	var dir: DirAccess = DirAccess.open(path)
	if dir == null:
		return
	dir.list_dir_begin()
	var fname: String = dir.get_next()
	while fname != "":
		var child: String = path + "/" + fname
		if dir.current_is_dir():
			delete_dir_recursive(child)
		else:
			DirAccess.remove_absolute(ProjectSettings.globalize_path(child))
		fname = dir.get_next()
	dir.list_dir_end()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


# Loads an image by inspecting magic bytes rather than trusting the file
# extension — handles covers that are JPEG/WebP saved with a .png extension.
# Returns the Image, or null if the path is empty / unreadable / undecodable.
static func load_image_smart(user_path: String) -> Image:
	if user_path == "":
		return null
	var abs_path: String = ProjectSettings.globalize_path(user_path)
	var f: FileAccess = FileAccess.open(abs_path, FileAccess.READ)
	if f == null:
		return null
	var bytes: PackedByteArray = f.get_buffer(f.get_length())
	f.close()
	if bytes.is_empty():
		return null

	var img: Image = Image.new()
	var err: Error

	if bytes.size() >= 4 and bytes[0] == 0x89 and bytes[1] == 0x50 and bytes[2] == 0x4E and bytes[3] == 0x47:
		err = img.load_png_from_buffer(bytes)
	elif bytes.size() >= 3 and bytes[0] == 0xFF and bytes[1] == 0xD8 and bytes[2] == 0xFF:
		err = img.load_jpg_from_buffer(bytes)
	elif bytes.size() >= 12 and bytes[0] == 0x52 and bytes[1] == 0x49 and bytes[2] == 0x46 and bytes[3] == 0x46 \
			and bytes[8] == 0x57 and bytes[9] == 0x45 and bytes[10] == 0x42 and bytes[11] == 0x50:
		err = img.load_webp_from_buffer(bytes)
	else:
		err = img.load_jpg_from_buffer(bytes)
		if err != OK:
			err = img.load_png_from_buffer(bytes)
		if err != OK:
			err = img.load_webp_from_buffer(bytes)

	return img if err == OK else null


# Parses a funscript and returns {count, length_ms}: the number of actions and
# the timestamp of the last action. Both 0 if the file is missing/unreadable.
# JourneyBuilder calls this once at save time to cache the stats into
# journey.json so the catalogue scan never has to re-parse funscripts.
# Loads a funscript's action points as an Array of Vector2(at_ms, pos), sorted by
# time. Returns [] if the file is missing or malformed. Used by the in-builder
# funscript preview graph.
static func read_funscript_actions(path: String) -> Array:
	var points: Array = []
	if path == "" or not FileAccess.file_exists(path):
		return points
	var f: FileAccess = FileAccess.open(path, FileAccess.READ)
	if f == null:
		return points
	var parser: JSON = JSON.new()
	if parser.parse(f.get_as_text()) == OK and parser.data is Dictionary:
		for a in (parser.data as Dictionary).get("actions", []):
			if a is Dictionary:
				points.append(Vector2(float(a.get("at", 0)), float(a.get("pos", 0))))
	f.close()
	points.sort_custom(func(p: Vector2, q: Vector2) -> bool: return p.x < q.x)
	return points


static func read_funscript_stats(path: String) -> Dictionary:
	var result: Dictionary = {"count": 0, "length_ms": 0}
	if path == "" or not FileAccess.file_exists(path):
		return result
	var f: FileAccess = FileAccess.open(path, FileAccess.READ)
	if f == null:
		return result
	var parser: JSON = JSON.new()
	if parser.parse(f.get_as_text()) == OK and parser.data is Dictionary:
		var actions: Array = (parser.data as Dictionary).get("actions", [])
		result["count"] = actions.size()
		if not actions.is_empty():
			result["length_ms"] = int(actions[-1].get("at", 0))
	f.close()
	return result


# True when any round node in the graph carries a video_path. Drives the save's transcode
# plan + whether to show the streaming modal.
static func graph_has_any_video(graph: Dictionary) -> bool:
	for id: String in graph.get("nodes", {}):
		var n: Dictionary = graph["nodes"][id]
		if str(n.get("type", "")) == "round" \
				and str((n.get("data", {}) as Dictionary).get("video_path", "")) != "":
			return true
	return false


# Unique video source paths across every round node, for transcode probing (a source reused
# across rounds is probed once — identity by path).
static func graph_video_sources(graph: Dictionary) -> Array:
	var sources: Array = []
	for id: String in graph.get("nodes", {}):
		var n: Dictionary = graph["nodes"][id]
		if str(n.get("type", "")) == "round":
			var v: String = str((n.get("data", {}) as Dictionary).get("video_path", ""))
			if v != "" and not sources.has(v):
				sources.append(v)
	return sources


# Sanitize an arbitrary string into a filesystem-safe folder name.
# (Moved from JourneyBuilder.gd — used by the save flow.)
static func sanitize_folder_name(name: String) -> String:
	const INVALID: String = "\\/:*?\"<>|"
	var result: String = ""
	for ch: String in name:
		if ch in INVALID:
			continue
		result += "_" if ch == " " else ch
	return result if result != "" else "Journey"


