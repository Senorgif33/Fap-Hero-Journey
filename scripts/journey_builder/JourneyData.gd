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
#   JourneyData.items_have_any_video(items) – any round in the tree has a video?
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

# Stable per-item key for the journey map's "you are here" correlation. Rounds use
# their globally-unique folder slug; other item types use their order/after_order.
# Computed identically on the graph side (stamped as `_map_key` by parse_journey)
# and the runtime side (GameLoop), so the marker can find the node for the current
# sequence item. NOTE: non-round keys can collide across fork levels — the map
# resolves that by advancing the marker monotonically down the graph.
static func map_key(item_type: String, id: Variant) -> String:
	return "%s:%s" % [item_type, str(id)]

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

# The authored (non-media) journey.json fields for a round, derived purely from
# the builder item model — the gameplay config shared by top-level and fork-path
# rounds. The save flow merges in the media/slug fields (Name, FolderName, Order,
# FunscriptPath, AxisScripts, VibScripts, BossImage, ActionCount, LengthMs) it
# computes while copying files. Single source for the bug-prone curse/boon/sensory/
# boss key set; JourneyScanner.parse_journey reads these keys back.
static func round_to_json(item: Dictionary) -> Dictionary:
	return {
		"CoinsAwarded":     int(item.get("coins", 0)),
		"RoundType":        round_type_label(item.get("round_type", "normal")),
		"IsCheckpoint":     bool(item.get("is_checkpoint", false)),
		"CurseReward":      int(item.get("curse_reward", 0)),
		"CleanseCost":      int(item.get("cleanse_cost", 50)),
		"CurseRandom":      bool(item.get("curse_random", true)),
		"Curses":           item.get("curses", []),
		"BoonRandom":       bool(item.get("boon_random", true)),
		"Boons":            item.get("boons", []),
		"GiftItem":         item.get("gift_item", ""),
		"BossTagline":      item.get("boss_tagline", ""),
		"BossModifiers":    boss_modifiers_json(item.get("boss_modifiers", [])),
		"Sensory":          item.get("sensory", []),
		"SensoryInPool":    bool(item.get("sensory_in_pool", false)),
		"SensoryIntensity": item.get("sensory_intensity", {}),
		"ShowReveal":       bool(item.get("show_reveal", true)),
	}


# Internal round_type → journey.json label. JourneyScanner lowercases on parse.
static func round_type_label(round_type: String) -> String:
	match round_type:
		"boss":    return "Boss"
		"cursed":  return "Cursed"
		"blessed": return "Blessed"
		_:         return "Normal"


# Internal boss modifiers ({kind, factor?/min?/max?}) → journey.json form
# ({Kind, Factor?/Min?/Max?}). Only the keys relevant to the kind are written.
static func boss_modifiers_json(modifiers: Array) -> Array:
	var out: Array = []
	for mod in modifiers:
		if not mod is Dictionary:
			continue
		var entry: Dictionary = {"Kind": mod.get("kind", "")}
		if mod.has("factor"):
			entry["Factor"] = mod["factor"]
		if mod.has("min"):
			entry["Min"] = mod["min"]
		if mod.has("max"):
			entry["Max"] = mod["max"]
		out.append(entry)
	return out


# ── Item templates ───────────────────────────────────────────────────────────

# Returns a fresh default item dict for a builder node of the given type. Single
# source of truth for the empty-item shape, used by the insert menu, the quick-
# add buttons, and the Ctrl+1–4 shortcuts.
static func new_item(type: String) -> Dictionary:
	match type:
		"round":
			return {"type": "round", "name": "", "funscript_path": "", "video_path": "", "coins": 0, "axis_scripts": {}}
		"shop":
			return {"type": "shop", "title": ""}
		"storyboard":
			# coins / item: optional reward granted when the storyboard is finished.
			return {"type": "storyboard", "coins": 0, "item": "", "image": "", "lines": []}
		"fork":
			# resolution: "choice" | "random" | "conditional" | "sacrifice"
			# cond_metric (conditional only): "score" | "coins" | "item"
			# default_path (conditional only): index taken when no rule matches
			# Per-path config (only the field(s) for the active resolution are used):
			#   weight (random) · threshold (conditional score/coins) ·
			#   required_item (conditional item check, OR sacrifice — consumed) ·
			#   cost (sacrifice — coins spent). required_item "" = none/free.
			return {"type": "fork", "title": "", "description": "",
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
				"_map_key":        map_key("round", r.get("folder", "")),
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
				"_map_key": map_key("storyboard", sb.get("order", 0)),
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
		"items":          items,
	}


# Recursively converts a parsed-journey fork dict into the builder _items model
# (which uses a single mixed items[] array per path rather than separate
# rounds/storyboards/shops/forks arrays).
# Inflates a scanned shop dict into the builder's shop item model.
static func _build_shop_item(sh: Dictionary) -> Dictionary:
	return {
		"type":             "shop",
		"title":            sh.get("title", ""),
		"mode":             sh.get("mode", "pool"),
		"count":            int(sh.get("count", 3)),
		"items":            (sh.get("items", []) as Array).duplicate(),
		"price_multiplier": float(sh.get("price_multiplier", 1.0)),
		"_map_key":         map_key("shop", sh.get("after_order", 0)),
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
		"_map_key":     map_key("fork", f.get("after_order", 0)),
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
				"_map_key":        map_key("round", pr.get("folder", "")),
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
				"_map_key": map_key("storyboard", psb.get("order", 0)),
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


# Recursively scans a items[] tree (including nested fork paths) for any
# round that has a video_path attached.
static func items_have_any_video(items: Array) -> bool:
	for it in items:
		match it.get("type", "round"):
			"round":
				if it.get("video_path", "") != "":
					return true
			"fork":
				for p in it.get("paths", []):
					if items_have_any_video(p.get("items", [])):
						return true
	return false


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


