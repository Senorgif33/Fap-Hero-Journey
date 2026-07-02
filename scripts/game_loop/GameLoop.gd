extends Control

const OptionsScene = preload("res://scenes/options/Options.tscn")
const ForkScene = preload("res://scenes/fork_screen/ForkScreen.tscn")
const ShopScene = preload("res://scenes/shop_screen/ShopScreen.tscn")
const StoryboardScene = preload("res://scenes/storyboard_screen/StoryboardScreen.tscn")
const InventoryPanelScene = preload("res://scenes/inventory/InventoryPanel.tscn")
const BeatBarScript = preload("res://scripts/game_loop/BeatBar.gd")
const GraphViewScene = preload("res://scenes/graph_view/GraphView.tscn")

# ---------------------------------------------------------------------------
# GameLoop.gd  –  Round controller and video player
# Reads the active journey from GameState, loads each round's video and
# funscript in sequence, then transitions to EndScreen when all rounds finish.
#
# MP4 NOTE: Godot's built-in VideoStreamPlayer only decodes .ogv (Theora).
# Install EIRTeam.FFmpeg GDExtension for MP4 support, then replace the
# _load_video() body with that extension's API.
# ---------------------------------------------------------------------------

const HUD_BAR_HEIGHT: int = 68
# Playback-capable formats. Intentionally distinct from JourneyData.VIDEO_EXTENSIONS
# (the import/transcode set): includes "ogv" (Godot-native, no FFmpeg needed) and
# omits container types that only matter at import time.
const VIDEO_EXTS: Array = ["mp4", "mkv", "webm", "avi", "mov", "ogv"]

# Sequence-boundary fade timings (~1.2s total).
const TRANSITION_FADE_TIME: float = 0.45
const TRANSITION_HOLD_TIME: float = 0.30

# Boss rounds: the red frame pulses during the round's final stretch.
const BOSS_CLIMAX_SECS: float = 30.0
# Boss forced-modifier kind → HUD chip label.
const BOSS_EFFECT_NAMES: Dictionary = {
	"scale": "SCALE",
	"clamp": "CLAMP",
	"reverse": "REVERSE",
	"blackout": "BLACKOUT",
	"score_multiplier": "SCORE ×",
}

@onready var _bg: ColorRect = $Background
@onready var _video: VideoStreamPlayer = $VideoPlayer
@onready var _hud: Control = $HUD
@onready var _hud_bar: PanelContainer = $HUD/HUDBar
@onready var _hud_layout: HBoxContainer = $HUD/HUDBar/HUDLayout
@onready var _round_lbl: Label = $HUD/HUDBar/HUDLayout/RoundLabel
@onready var _coin_lbl: Label = $HUD/HUDBar/HUDLayout/CoinLabel
@onready var _progress: ProgressBar = $HUD/ProgressBar
@onready var _score_lbl: Label = $HUD/HUDBar/HUDLayout/ScoreLabel
@onready var _pause_btn: Button = $HUD/HUDBar/HUDLayout/PauseBtn
@onready var _inv_btn: Button = $HUD/HUDBar/HUDLayout/InventoryBtn
@onready var _menu_btn: Button = $HUD/HUDBar/HUDLayout/MenuBtn
@onready var _options_btn: Button = $HUD/HUDBar/HUDLayout/OptionsBtn
@onready var _chips_row: HBoxContainer = $HUD/EffectChipsRow
@onready var _hide_timer: Timer = $HUD/HideTimer

# In-play "Quick Settings" drawer (stroke range + delay), toggled by the S key and mutually exclusive
# with the inventory drawer. Arrow keys nudge the range while it's open. STROKE_RANGE_STEP = per press.
var _session_panel: Control = null
const STROKE_RANGE_STEP: int = 5

# Persistent banner shown at top of screen whenever the *currently selected*
# output device drops its connection during play. Built dynamically in
# _apply_layout so the scene file doesn't need a new node. Lives outside the
# auto-hiding HUD so it stays visible even when the rest of the HUD fades.
var _device_warning_banner: PanelContainer = null
var _device_warning_label: Label = null
var _device_ever_seen: bool = false   # a device was present at some point this run (Slice 6 warning gate)

const DELAY_STEP: int = 10            # [ ] ; ' nudge the per-backend delays by this many ms
var _delay_toast: Label = null        # transient "delay X ms" feedback for the delay hotkeys
var _delay_toast_tween: Tween = null
@onready var _end_timer: Timer = $EndTimer
@onready var _transition: ColorRect = $TransitionLayer/TransitionOverlay

var _paused: bool = false
var _inventory_panel: Control = null

# Pause penalty — score drains while the player has *actively* paused (the pause
# button or the Options menu). System pauses (boss intro, checkpoint banner,
# shops/forks/storyboards) don't count. _options_open tracks the Options overlay
# since it pauses without setting _paused.
const PAUSE_PENALTY_PER_SEC: int = 10
var _options_open: bool = false
var _pause_penalty_accum: float = 0.0

# True while a full-screen overlay (shop / fork / storyboard) is active.
# Used to suppress gameplay hotkeys that should not fire through an overlay.
var _is_overlay_open: bool = false
# The current full-screen overlay (storyboard / shop / fork), or null. It is
# freed by the transition (after the black covers it), not by itself — see
# _transition_swap.
var _current_overlay: Control = null

# Journey map (read-only GraphView of the authored graph + "you are here" marker).
# Opened on demand (HUD button / M / overlay buttons). Self-managed (NOT
# _current_overlay, which the transition frees). Availability is authored per
# journey (_map_enabled): an author can disable it to enforce surprise, in which
# case the map is never built and the buttons never appear.
var _map_enabled: bool = true  # journey-level: author allows the player map
var _map_fog: bool = false  # journey-level: fog of war — reveal the map as it's discovered
var _map_fog_reveal: int = 1  # ghost levels revealed ahead of the trail (< 0 = whole structure)
var _map_view: GraphView = null
var _map_overlay: Control = null  # full-screen host (backdrop + map + chrome)
var _map_close_btn: Button = null
var _map_open: bool = false
# True while the active full-screen overlay permits opening the journey map over it
# (shop, storyboard, and INTERACTIVE forks). Lets the map open even though
# _is_overlay_open is set. Auto-resolving forks (random / conditional) leave it false
# so the map can't interrupt their reveal; transient banners (checkpoint / reveal
# card) never set it. While the map is open the overlay's own input is suspended (see
# _set_overlay_input_enabled) so clicks/keys can't leak through to it.
var _overlay_map_allowed: bool = false

# True for the duration of a boss round (set when the round loads, cleared at
# round end). Drives item lockout, the red frame, and the climax pulse.
var _is_boss_round: bool = false
var _boss_frame: Panel = null

# Cursed round: random negative effect(s) rolled at the start. Distinct from a
# boss round — items stay usable (the player can fight back), it hits mid-flow
# with no telegraph, and it has its own sickly "hex" identity (see below). Set
# when the round loads, cleared at round end.
var _is_cursed_round: bool = false
# Gameplay curses come from JourneyData.CURSE_CATALOG; non-gameplay visual/audio
# modifiers from JourneyData.SENSORY_CATALOG. A cursed round rolls a gameplay
# curse (random) or applies an author-selected set, plus any ticked sensory
# modifiers (and, if enabled, random sensory ones from the pool). Stroke curses
# are applied by FunscriptPlayer; the rest (coin/hud/sensory) by GameLoop. All go
# into the boss-effects list so they also surface as named HUD chips and are
# lifted together on cleanse.
#
# Chance a *random* cursed round rolls TWO curses instead of one ("double-cursed").
const DOUBLE_CURSE_CHANCE: float = 0.22
const CLEANSE_COST_DEFAULT: int = 50

var _curse_frame: Panel = null  # green "hex" border (cursed counterpart to _boss_frame)
var _curse_tint: ColorRect = null  # faint sickly tint over the play area
# The non-gameplay (visual/audio) modifier engine — overlays, video shader,
# audio bus, tremor, mute. Built in _build_curse_overlay; every hex routes
# through it first (see _apply_hex). Gameplay hexes below stay here.
var _sensory: SensoryFX = null
var _curse_hud_hidden: bool = false  # a "Fog" hex hid the HUD for this round
var _curse_no_pause: bool = false  # a "Restless" hex disabled pausing this round
const TOLL_AMOUNT: int = 40  # coins a "Toll" hex takes immediately

# Blessed round — the positive mirror of cursed. Applies boon(s) from
# JourneyData.BLESSING_CATALOG (gold frame, no cleanse/cost). Some boons carry
# state: Ward shields the next curse, Lingering freezes the effect clock.
var _is_blessed_round: bool = false
var _blessing_frame: Panel = null  # gold frame
var _blessing_tint: ColorRect = null  # faint gold tint
var _ward_next_curse: bool = false  # a "Ward" boon repels the next curse
var _blessing_lingering: bool = false  # a "Lingering" boon froze the effect clock
const INTEREST_PCT: float = 0.25  # "Interest" boon pays this fraction of the coin balance
# Effects to show on the pre-round reveal card for a cursed/blessed round. Each:
# {name, desc, benefit:bool}. Empty = no card (normal/boss rounds, warded curse).
var _reveal_effects: Array = []
const REVEAL_HOLD_SECS: float = 2.6
# Cleanse / endure decision: pay to lift the curse mid-round, or endure it to the
# end for the round's curse_reward bonus. Its own floating button (not in the HUD,
# so a Fog hex can't lock the player out of cleansing).
var _curse_cleansed: bool = false
var _curse_cleanse_btn: Button = null
var _curse_cleanse_cost: int = CLEANSE_COST_DEFAULT  # per-round, set on curse enter

# Optional beat-bar visualiser — created only when the setting is enabled.
var _beat_bar: Control = null

# Test-play mode: the journey was launched from the builder ("Save & Test from
# here") to preview a node in the real runtime. While true, the loop returns to
# the builder (not the menu/end screen) on exit, and real player saves are
# suppressed so a preview never writes or deletes a journey's run-save. The
# return journey is the catalogue-model dict the builder reloads on the way back.
var _test_mode: bool = false
var _test_return_journey: Dictionary = {}
# Seeds applied before the first node loads in a test play, so Conditional /
# Sacrifice forks can be exercised from a chosen starting point.
var _test_seed_score: int = 0
var _test_seed_coins: int = 0
var _test_seed_flags: Array = []
# Set once this run's outcome has been logged to the scoreboard (on completion)
# or when leaving via Save & Quit (a resume, not an abandon) — so the menu exit
# doesn't also record an abandoned run.
var _run_accounted: bool = false


func _ready() -> void:
	MusicService.stop()
	_apply_layout()
	_apply_theme()
	_build_boss_frame()
	_build_curse_overlay()
	_build_beat_bar()
	# Journey-level: the author can disable the player map to enforce surprise.
	_map_enabled = bool(GameState.Journey.get("map_enabled", true))
	_map_fog = bool(GameState.Journey.get("map_fog", false))
	_map_fog_reveal = int(GameState.Journey.get("map_fog_reveal", 1))
	_build_map()
	_connect_signals()
	# Resume vs fresh start: when the player picked Resume from the catalogue,
	# JourneySelect already populated the run-state autoloads (coins, score,
	# inventory) from the save record and stashed _round_names on GameState.
	# Wiping them here would defeat the resume. The "_resuming" meta is the
	# handshake — JourneySelect sets it before the scene change, we honour
	# it once, then clear it so a subsequent play of the same journey from
	# this session doesn't pick it up by accident.
	# Test-play handshake — the builder sets these metas before the scene change.
	# Read once and clear so a later normal run of the same journey can't inherit
	# test mode by accident (same pattern as the "_resuming" handshake below).
	_test_mode = bool(GameState.get_meta("_test_mode", false))
	if _test_mode:
		_test_return_journey = GameState.get_meta("_test_return_journey", {})
		_test_seed_score = int(GameState.get_meta("_test_seed_score", 0))
		_test_seed_coins = int(GameState.get_meta("_test_seed_coins", 0))
		_test_seed_flags = GameState.get_meta("_test_seed_flags", [])
		GameState.remove_meta("_test_mode")
		GameState.remove_meta("_test_return_journey")
		GameState.remove_meta("_test_seed_score")
		GameState.remove_meta("_test_seed_coins")
		GameState.remove_meta("_test_seed_flags")

	var is_resuming: bool = bool(GameState.get_meta("_resuming", false))
	if is_resuming:
		GameState.remove_meta("_resuming")
	else:
		ScoreService.Reset()
		CoinService.Reset()
		InventoryService.Reset()
		# Pure-GDScript round-name log, read by EndScreen. Stored as meta on
		# GameState so it survives the scene change. Cleared here so a new
		# journey starts fresh.
		GameState.set_meta("_round_names", PackedStringArray())
	# Apply test-play seeds after the run-state reset above (so they survive it),
	# before any node loads — a Conditional fork at the start node then sees them.
	if _test_mode:
		if _test_seed_coins > 0:
			CoinService.SetBalance(_test_seed_coins)
		if _test_seed_score > 0:
			ScoreService.SeedLastRoundScore(_test_seed_score)
		if not _test_seed_flags.is_empty():
			GameState.SeedFlags(_test_seed_flags)
	_refresh_coin_label(true)
	_load_current_item()
	_show_hud()
	if _test_mode:
		_show_test_banner()

	# Re-fit the video whenever the logical viewport changes. This fires on
	# window resize, fullscreen toggle, resolution change, AND UI-scale
	# (content_scale_factor) change — so the video tracks all of them, including
	# while paused.
	get_viewport().size_changed.connect(_fit_video_cover)


func _process(delta: float) -> void:
	if _video.is_playing():
		var len: float = _video.get_stream_length()
		if len > 0.0:
			_progress.value = _video.stream_position / len
		# Keep funscript in sync with video clock
		FunscriptPlayer.SyncTo(_video.stream_position)
		# Re-fit every frame: cheap, and keeps the video covering the screen even
		# if the viewport or UI scale changes mid-playback.
		_fit_video_cover()
	_apply_pause_penalty(delta)
	_update_chip_countdowns()
	if _is_boss_round:
		_update_boss_frame()
	elif _is_cursed_round:
		_update_curse_frame()
	elif _is_blessed_round:
		_update_blessing_frame()
	if _beat_bar != null:
		_beat_bar.set_time(FunscriptPlayer.PositionMs)


# Drains score while the player has actively paused (pause button or Options) —
# PAUSE_PENALTY_PER_SEC per whole second held. System pauses (boss intro,
# checkpoint banner, shops/forks/storyboards) don't set _paused / _options_open,
# so they're exempt. The accumulator resets the moment play resumes.
func _apply_pause_penalty(delta: float) -> void:
	if not (_paused or _options_open):
		_pause_penalty_accum = 0.0
		return
	_pause_penalty_accum += delta
	while _pause_penalty_accum >= 1.0:
		_pause_penalty_accum -= 1.0
		ScoreService.PenalizeScore(PAUSE_PENALTY_PER_SEC)


# ---------------------------------------------------------------------------
# Item loading (round or fork)
# ---------------------------------------------------------------------------


func _load_current_item() -> void:
	match GameState.CurrentItemType():
		"fork":
			_show_fork_screen(GameState.CurrentFork())
		"shop":
			_show_shop_screen(GameState.CurrentShop())
		"storyboard":
			_show_storyboard_screen(GameState.CurrentStoryboard())
		_:
			_load_current_round()


func _show_storyboard_screen(sb_data: Dictionary) -> void:
	_is_overlay_open = true
	_video.paused = true
	FunscriptPlayer.Pause()
	_start_storyboard_filler()
	var storyboard: Control = StoryboardScene.instantiate()
	storyboard.show_map_button = _map_enabled
	storyboard.completed.connect(_on_storyboard_completed)
	storyboard.map_requested.connect(_open_map_viewer)
	add_child(storyboard)
	_current_overlay = storyboard
	_overlay_map_allowed = true
	storyboard.setup(sb_data)


func _start_storyboard_filler() -> void:
	if not SettingsService.get_filler_enabled():
		return
	FunscriptPlayer.StartFiller(
		SettingsService.get_filler_lo(),
		SettingsService.get_filler_hi(),
		SettingsService.get_filler_half_cycle_ms()
	)


func _on_storyboard_completed(coins: int) -> void:
	FunscriptPlayer.StopFiller()
	_is_overlay_open = false
	_overlay_map_allowed = false
	if coins > 0:
		CoinService.AddCoins(coins)
	# Optional item reward — read before Advance() moves off the storyboard.
	var item_id: String = str(GameState.CurrentStoryboard().get("item", ""))
	if item_id != "":
		InventoryService.AddItem(item_id)
	GameState.Advance()
	if GameState.IsSequenceDone():
		_transition_to_end_screen()
		return
	await _transition_swap(
		func() -> void:
			_video.paused = false
			FunscriptPlayer.Resume()
			_load_current_item()
	)


func _show_shop_screen(shop_data: Dictionary) -> void:
	_is_overlay_open = true
	_video.paused = true
	FunscriptPlayer.Pause()
	var shop: Control = ShopScene.instantiate()
	shop.show_map_button = _map_enabled
	shop.closed.connect(_on_shop_closed)
	shop.map_requested.connect(_open_map_viewer)
	add_child(shop)
	_current_overlay = shop
	_overlay_map_allowed = true
	shop.setup(shop_data)


func _on_shop_closed() -> void:
	_is_overlay_open = false
	_overlay_map_allowed = false
	GameState.Advance()
	if GameState.IsSequenceDone():
		_transition_to_end_screen()
		return
	await _transition_swap(
		func() -> void:
			_video.paused = false
			FunscriptPlayer.Resume()
			_load_current_item()
	)


func _show_fork_screen(fork_data: Dictionary) -> void:
	_is_overlay_open = true
	_video.paused = true
	FunscriptPlayer.Pause()
	var fork_screen = ForkScene.instantiate()
	fork_screen.show_map_button = _map_enabled
	fork_screen.path_chosen.connect(_on_fork_path_chosen)
	fork_screen.map_requested.connect(_open_map_viewer)
	add_child(fork_screen)
	_current_overlay = fork_screen
	fork_screen.setup(fork_data)

	# Auto-resolved fork types pick a path and play a reveal instead of waiting
	# for the player. (Sacrifice stays interactive — the player picks & pays.)
	var resolution: String = fork_data.get("resolution", "choice")
	# Conditional forks either auto-resolve (the game "spins" to the best match) or let the player pick
	# among the paths they've unlocked (cond_decider == "player") — the latter stays interactive.
	var auto_resolved: bool = (
		resolution == "random"
		or (resolution == "conditional" and fork_data.get("cond_decider", "game") != "player")
	)
	# Interactive forks let the player consult the journey map mid-decision; the auto-resolving reveals
	# run on timers, so the map stays suppressed there.
	_overlay_map_allowed = not auto_resolved
	match resolution:
		"random":
			fork_screen.reveal(_weighted_random_path(fork_data.get("paths", [])))
		"conditional":
			if auto_resolved:
				fork_screen.reveal(_conditional_path(fork_data), _conditional_caption(fork_data))


# Picks a path index by weight (per-path "weight", default 1). The weighting math
# lives in ForkResolver.weighted_pick (pure, tested); only the random draw stays
# here. If every weight is 0, all paths are equally likely.
func _weighted_random_path(paths: Array) -> int:
	if paths.is_empty():
		return 0
	var weights: Array = []
	var total: int = 0
	for p: Dictionary in paths:
		var w: int = maxi(0, int(p.get("weight", 1)))
		weights.append(w)
		total += w
	if total <= 0:
		return randi() % paths.size()
	return ForkResolver.weighted_pick(weights, randi() % total)


# Resolves a conditional fork to a path index. Score/coins use tiered thresholds;
# item checks ownership (not consumed); default path on no-match. The resolution
# logic lives in ForkResolver.conditional_path (pure, tested) — here we just gather
# the current score / coins / ownership.
func _conditional_path(fork_data: Dictionary) -> int:
	var metric: String = fork_data.get("cond_metric", "score")
	# Flag metric: the "ownership" check is a flag-set check against GameState's run flags.
	if metric == "flag":
		return ForkResolver.conditional_path(
			fork_data.get("paths", []),
			metric,
			int(fork_data.get("default_path", 0)),
			0,
			Callable(GameState, "HasFlag")
		)
	var value: int = ScoreService.LastRoundScore if metric == "score" else CoinService.Balance
	return ForkResolver.conditional_path(
		fork_data.get("paths", []),
		metric,
		int(fork_data.get("default_path", 0)),
		value,
		Callable(InventoryService, "OwnsItem")
	)


# Flavour text shown during a conditional fork's reveal, per metric.
func _conditional_caption(fork_data: Dictionary) -> String:
	match fork_data.get("cond_metric", "score"):
		"score":
			return "BY YOUR SCORE…"
		"coins":
			return "BY YOUR COINS…"
		"item":
			return "BY WHAT YOU CARRY…"
		"flag":
			return "BY WHERE YOU'VE BEEN…"
	return "FATE DECIDES…"


func _on_fork_path_chosen(path_index: int) -> void:
	_is_overlay_open = false
	_overlay_map_allowed = false
	GameState.ResolveFork(path_index)
	await _transition_swap(
		func() -> void:
			_video.paused = false
			FunscriptPlayer.Resume()
			_load_current_item()
	)


func _load_current_round() -> void:
	var round: Dictionary = GameState.CurrentRound()
	if round.is_empty():
		push_error("GameLoop: GameState has no current round — returning to menu")
		_go_to_menu()
		return

	var total: int = GameState.TotalRounds()
	var num: int = GameState.RoundNumber

	_progress.value = 0.0
	_paused = false
	_pause_btn.text = "|| PAUSE"

	var rtype: String = round.get("round_type", "normal")
	_is_boss_round = rtype == "boss"
	_is_cursed_round = rtype == "cursed"
	_is_blessed_round = rtype == "blessed"
	if _is_boss_round:
		_round_lbl.text = (
			"⚔  BOSS  %d / %d  —  %s" % [num, total, (round.get("name", "") as String).to_upper()]
		)
	else:
		var prefix: String = "ROUND"
		if _is_cursed_round:
			prefix = "☠  CURSED"
		elif _is_blessed_round:
			prefix = "✦  BLESSED"
		_round_lbl.text = (
			"%s %d / %d  —  %s" % [prefix, num, total, (round.get("name", "") as String).to_upper()]
		)

	# Author-marked checkpoint rounds offer a Save & Quit opt-in before round
	# playback — honoured on every round type, bosses included (the banner
	# precedes the boss intro). Continuing proceeds to the round's normal start.
	if round.get("is_checkpoint", false):
		_show_checkpoint_banner(round)
	else:
		_start_round_after_gates(round)


# Starts a round once any checkpoint gate is cleared: boss rounds telegraph with
# their intro card first (playback waits for BEGIN); everything else begins now.
func _start_round_after_gates(round: Dictionary) -> void:
	if _is_boss_round:
		_show_boss_intro(round)
	else:
		_begin_round(round)


# Loads the round's scripts + video and starts playback. For boss rounds this
# runs after the intro card's BEGIN; for normal rounds, immediately.
func _begin_round(round: Dictionary) -> void:
	ScoreService.StartRound()
	# Clear any pause left by a pre-round gate (boss intro / checkpoint banner) —
	# _video.play() below doesn't reset the paused flag on its own.
	_video.paused = false

	var fs_path: String = round.get("funscript_path", "")
	if fs_path != "":
		FunscriptPlayer.LoadFunscript(fs_path)
		ScoreService.SetRoundActions(FunscriptPlayer.ActionCount)
		if _beat_bar != null:
			_beat_bar.set_beats(FunscriptPlayer.GetBeats())

	# Load secondary axis scripts (serial devices only; FunscriptPlayer ignores
	# them if output mode is Buttplug). Clear first so stale axes from a prior
	# round are never replayed.
	FunscriptPlayer.ClearAxisScripts()
	var axis_scripts: Dictionary = round.get("axis_scripts", {})
	for axis: String in axis_scripts:
		var ax_path: String = axis_scripts[axis]
		if ax_path != "":
			FunscriptPlayer.LoadAxisScript(axis, ax_path)

	# Load vibrator-channel scripts (Buttplug vibrators only; ignored for linear
	# devices and serial output). Clear first so stale channels from a prior round
	# are never sent to the device.
	FunscriptPlayer.ClearVibScripts()
	var vib_scripts: Dictionary = round.get("vib_scripts", {})
	for ch_key: String in vib_scripts:
		var vib_path: String = vib_scripts[ch_key]
		if vib_path != "":
			var channel: int = 0 if ch_key == "vib1" else 1
			FunscriptPlayer.LoadVibScript(channel, vib_path)

	# Boss / curse setup must run before _load_video → FunscriptPlayer.Play() so
	# the forced modifier is already active on the first dispatched stroke. Each
	# enter_*_mode populates _reveal_effects for the pre-round card.
	_reveal_effects = []
	if _is_boss_round:
		_enter_boss_mode(round)
	elif _is_cursed_round:
		_enter_cursed_mode()
	elif _is_blessed_round:
		_enter_blessed_mode()

	# Cursed / blessed rounds get an animated reveal card naming the effect(s)
	# before playback starts (auto-advances; the cleanse choice stays in-round) —
	# unless the author turned the intro card off for this round.
	if not _reveal_effects.is_empty() and bool(round.get("show_reveal", true)):
		await _show_reveal_card(_is_blessed_round)

	# Prefer the explicit video_path (set by the scanner from VideoPath, or by
	# JourneyData._round_video); fall back to a folder-scan for pre-VideoPath
	# journeys that never recorded one.
	var video_path: String = round.get("video_path", "")
	if video_path == "":
		video_path = _find_video(round.get("folder", ""))
	_load_video(video_path)


# ---------------------------------------------------------------------------
# Checkpoint rounds
# ---------------------------------------------------------------------------


# CHECKPOINT REACHED banner shown at the start of any round the author marked
# as a checkpoint. Two buttons: Save & Quit (writes a save + returns to
# catalogue) or Continue (dismisses the banner and starts the round normally).
# Pattern mirrors _show_boss_intro since both gate round start on user input.
func _show_checkpoint_banner(round: Dictionary) -> void:
	_is_overlay_open = true  # suppress gameplay hotkeys while the banner is up
	_halt_playback_for_gate()  # freeze any leftover playback so the score can't tick

	var parts: Dictionary = UITheme.build_centered_modal(
		"◆  CHECKPOINT REACHED  ◆", UITheme.AMBER, Vector2i(620, 320)
	)
	var modal: Control = parts["modal"]
	var vbox: VBoxContainer = parts["vbox"]
	vbox.add_theme_constant_override("separation", 18)

	var subtitle: Label = Label.new()
	subtitle.text = (round.get("name", "") as String).to_upper()
	UITheme.style_label(subtitle, UITheme.WHITE_SOFT, 14, true)
	subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(subtitle)

	var hint: Label = Label.new()
	hint.text = "You've reached a save point. Save & Quit to resume from this round later, or continue playing now. The save is one-time — used up when you resume."
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	UITheme.style_label(hint, UITheme.PURPLE_MID, 12, false)
	vbox.add_child(hint)

	var btn_row: HBoxContainer = HBoxContainer.new()
	btn_row.alignment = BoxContainer.ALIGNMENT_CENTER
	btn_row.add_theme_constant_override("separation", 16)
	vbox.add_child(btn_row)

	var save_btn: Button = Button.new()
	save_btn.text = "💾  SAVE & QUIT"
	save_btn.custom_minimum_size = Vector2(200, 0)
	UITheme.style_button(save_btn, UITheme.AMBER)
	save_btn.pressed.connect(
		func() -> void:
			modal.queue_free()
			_is_overlay_open = false
			_on_save_and_quit()
	)
	btn_row.add_child(save_btn)

	var continue_btn: Button = Button.new()
	continue_btn.text = "▶  CONTINUE"
	continue_btn.custom_minimum_size = Vector2(160, 0)
	UITheme.style_button(continue_btn, UITheme.PURPLE_BRIGHT)
	continue_btn.pressed.connect(
		func() -> void:
			modal.queue_free()
			_is_overlay_open = false
			_start_round_after_gates(round)
	)
	btn_row.add_child(continue_btn)

	add_child(modal)


# ---------------------------------------------------------------------------
# Boss rounds
# ---------------------------------------------------------------------------


# Freezes playback while a pre-round modal (boss intro / checkpoint banner) is up.
# A round reached after a shop/storyboard/fork resumes the prior video+funscript
# before loading the next item; for a gated round that real start is deferred to
# BEGIN/Continue, so without this the leftover playback would keep dispatching
# strokes and tick the score up behind the modal. _begin_round restarts cleanly.
func _halt_playback_for_gate() -> void:
	_video.paused = true
	FunscriptPlayer.Pause()


# Telegraphed intro card. The round's scripts/video do not load and playback
# does not start until the player clicks BEGIN.
func _show_boss_intro(round: Dictionary) -> void:
	_is_overlay_open = true  # suppress gameplay hotkeys while the card is up
	_halt_playback_for_gate()  # don't let leftover playback tick the score behind the card

	var overlay: Control = Control.new()
	overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(overlay)

	var backdrop: ColorRect = ColorRect.new()
	backdrop.color = Color(0, 0, 0, 0.92)
	backdrop.set_anchors_preset(Control.PRESET_FULL_RECT)
	overlay.add_child(backdrop)

	var center: CenterContainer = CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	overlay.add_child(center)

	var panel: PanelContainer = PanelContainer.new()
	var ps: StyleBoxFlat = StyleBoxFlat.new()
	ps.bg_color = UITheme.PANEL_BG
	ps.border_color = UITheme.DANGER
	ps.border_width_left = 3
	ps.border_width_right = 3
	ps.border_width_top = 3
	ps.border_width_bottom = 3
	ps.content_margin_left = 48
	ps.content_margin_right = 48
	ps.content_margin_top = 36
	ps.content_margin_bottom = 36
	panel.add_theme_stylebox_override("panel", ps)
	center.add_child(panel)

	var col: VBoxContainer = VBoxContainer.new()
	col.add_theme_constant_override("separation", 16)
	panel.add_child(col)

	var banner: Label = Label.new()
	banner.text = "⚔   B O S S   R O U N D   ⚔"
	banner.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	banner.add_theme_color_override("font_color", UITheme.DANGER)
	banner.add_theme_font_size_override("font_size", 28)
	col.add_child(banner)

	var boss_image: String = round.get("boss_image", "")
	if boss_image != "":
		var img: Image = JourneyData.load_image_smart(boss_image)
		if img != null:
			var tex: TextureRect = TextureRect.new()
			tex.texture = ImageTexture.create_from_image(img)
			tex.custom_minimum_size = Vector2(380, 240)
			tex.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			tex.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
			col.add_child(tex)

	var name_lbl: Label = Label.new()
	name_lbl.text = (round.get("name", "") as String).to_upper()
	name_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_lbl.add_theme_color_override("font_color", UITheme.WHITE_SOFT)
	name_lbl.add_theme_font_size_override("font_size", 22)
	col.add_child(name_lbl)

	var tagline: String = round.get("boss_tagline", "")
	if tagline.strip_edges() != "":
		var tag_lbl: Label = Label.new()
		tag_lbl.text = tagline
		tag_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		tag_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		tag_lbl.custom_minimum_size = Vector2(440, 0)
		tag_lbl.add_theme_color_override("font_color", UITheme.PURPLE_BRIGHT)
		tag_lbl.add_theme_font_size_override("font_size", 14)
		col.add_child(tag_lbl)

	var rules_lbl: Label = Label.new()
	rules_lbl.text = "NO ITEMS  ·  FORCED MODIFIERS"
	rules_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	rules_lbl.add_theme_color_override("font_color", UITheme.SEPARATOR)
	rules_lbl.add_theme_font_size_override("font_size", 11)
	col.add_child(rules_lbl)

	var begin_btn: Button = Button.new()
	begin_btn.text = "⚔  BEGIN"
	begin_btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	UITheme.style_button(begin_btn, UITheme.DANGER, 32, 14)
	col.add_child(begin_btn)
	begin_btn.pressed.connect(
		func() -> void:
			overlay.queue_free()
			_is_overlay_open = false
			_begin_round(round)
	)


# Clean slate, forced modifiers, item lockout, red frame on.
func _enter_boss_mode(round: Dictionary) -> void:
	# Clean slate — drop any effects the player activated before the boss.
	InventoryService.ClearActiveEffects()

	# Inject the designer's forced modifiers as boss effects.
	var boss_effects: Array = []
	for mod: Dictionary in round.get("boss_modifiers", []):
		boss_effects.append(_make_boss_effect(mod))
	if not boss_effects.is_empty():
		InventoryService.AddBossEffects(boss_effects)

	# Optional non-gameplay (visual/audio) modifiers, explicitly authored — same hex
	# pipeline as a cursed round, but forced (no cleanse). Each surfaces as a red
	# HUD chip and is torn down by _clear_curse_hexes at round end (_exit_boss_mode).
	for roll: Dictionary in _catalog_subset(JourneyData.SENSORY_CATALOG, round.get("sensory", [])):
		var hx: Dictionary = _make_boss_effect(roll)
		hx["name"] = roll.get("name", hx["name"])
		InventoryService.AddBossEffects([hx])
		_apply_hex(roll, SensoryFX.intensity_for(round, roll))

	# Item use is disabled for the whole boss round.
	if is_instance_valid(_inventory_panel):
		_inventory_panel.close()
	_inv_btn.disabled = true

	if _boss_frame != null:
		_boss_frame.visible = true
		_boss_frame.modulate.a = 0.5


# Applies this round's curse(s) as boss effects — author-selected/fixed, or rolled
# from the catalog. Unlike a boss round, items stay usable so the player can
# counter (or cleanse) it.
# Applies this round's boon(s) — author-selected/fixed or rolled from the
# catalog. Pure upside: no cleanse, no cost. score_multiplier/coin_jackpot/scale
# ride the existing pipelines; gift/ward/lingering/interest are applied here.
func _enter_blessed_mode() -> void:
	var round: Dictionary = GameState.CurrentRound()
	var selected: Array = round.get("boons", [])
	var random_mode: bool = bool(round.get("boon_random", true))
	var to_apply: Array
	if selected.is_empty():
		to_apply = _roll_from(JourneyData.BLESSING_CATALOG)
	elif random_mode:
		to_apply = _roll_from(_catalog_subset(JourneyData.BLESSING_CATALOG, selected))
	else:
		to_apply = _catalog_subset(JourneyData.BLESSING_CATALOG, selected)

	for roll: Dictionary in to_apply:
		var fx: Dictionary = _make_boss_effect(roll)
		fx["name"] = roll.get("name", fx["name"])
		fx["benefit"] = true  # green chip
		InventoryService.AddBossEffects([fx])
		_apply_boon(roll, round)

	if _blessing_tint != null:
		_blessing_tint.visible = true
	if _blessing_frame != null:
		_blessing_frame.visible = true
	_reveal_effects = _build_reveal_effects(to_apply, true)


# GameLoop-side boon behaviours (the ones not handled by an existing effect kind).
func _apply_boon(roll: Dictionary, round: Dictionary) -> void:
	match String(roll.get("kind", "")):
		"gift":
			var gift: String = str(round.get("gift_item", ""))
			if gift != "":
				InventoryService.AddItem(gift)
		"interest":
			var gain: int = roundi(CoinService.Balance * INTEREST_PCT)
			if gain > 0:
				CoinService.AddCoins(gain)
		"ward":
			_ward_next_curse = true
		"lingering":
			_blessing_lingering = true
			InventoryService.SetPaused(true)  # freeze the effect clock for the round


# Animated pre-round reveal card naming the curse(s)/boon(s) and their effects.
# Fades + pops in, holds, fades out — then the round's video plays. Awaited by
# _begin_round so playback waits for it.
func _show_reveal_card(is_blessed: bool) -> void:
	var accent: Color = Color(1.0, 0.84, 0.30) if is_blessed else Color(0.45, 0.95, 0.30)

	var root: Control = Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)

	var backdrop: ColorRect = ColorRect.new()
	backdrop.set_anchors_preset(Control.PRESET_FULL_RECT)
	backdrop.color = Color(0, 0, 0, 0.6)
	backdrop.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(backdrop)

	var center: CenterContainer = CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(center)

	var panel: PanelContainer = PanelContainer.new()
	var ps: StyleBoxFlat = StyleBoxFlat.new()
	ps.bg_color = UITheme.PANEL_BG_DEEP
	ps.border_color = accent
	ps.set_border_width_all(2)
	ps.set_corner_radius_all(8)
	ps.set_content_margin_all(28)
	panel.add_theme_stylebox_override("panel", ps)
	center.add_child(panel)

	var col: VBoxContainer = VBoxContainer.new()
	col.add_theme_constant_override("separation", 12)
	col.custom_minimum_size = Vector2(440, 0)
	panel.add_child(col)

	var header: Label = Label.new()
	header.text = "✦  BLESSED" if is_blessed else "☠  CURSED"
	header.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	header.add_theme_color_override("font_color", accent)
	header.add_theme_font_size_override("font_size", 34)
	col.add_child(header)

	for fx: Dictionary in _reveal_effects:
		var name_lbl: Label = Label.new()
		name_lbl.text = (fx.get("name", "") as String).to_upper()
		name_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		name_lbl.add_theme_color_override(
			"font_color", UITheme.SUCCESS if fx.get("benefit", false) else UITheme.ERROR_SOFT
		)
		name_lbl.add_theme_font_size_override("font_size", 20)
		col.add_child(name_lbl)
		var desc_lbl: Label = Label.new()
		desc_lbl.text = fx.get("desc", "")
		desc_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		desc_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		desc_lbl.add_theme_color_override("font_color", UITheme.WHITE_SOFT)
		desc_lbl.add_theme_font_size_override("font_size", 13)
		col.add_child(desc_lbl)

	# Animate: fade + pop in, hold, fade out.
	await get_tree().process_frame  # let layout settle so the pivot is centered
	panel.pivot_offset = panel.size / 2.0
	panel.scale = Vector2(0.92, 0.92)
	root.modulate.a = 0.0
	var tin: Tween = create_tween().set_parallel(true)
	tin.tween_property(root, "modulate:a", 1.0, 0.3)
	tin.tween_property(panel, "scale", Vector2.ONE, 0.3).set_trans(Tween.TRANS_BACK).set_ease(
		Tween.EASE_OUT
	)
	await tin.finished
	await get_tree().create_timer(REVEAL_HOLD_SECS).timeout
	if not is_inside_tree():
		return
	var tout: Tween = create_tween()
	tout.tween_property(root, "modulate:a", 0.0, 0.3)
	await tout.finished
	root.queue_free()


# Gentle gold shimmer (mirrors the curse frame's drift).
func _update_blessing_frame() -> void:
	if _blessing_frame == null:
		return
	var t: float = Time.get_ticks_msec() / 1000.0
	_blessing_frame.modulate.a = 0.45 + 0.25 * sin(t * TAU * 0.4)


func _enter_cursed_mode() -> void:
	# A "Ward" boon from an earlier blessed round repels this curse entirely.
	if _ward_next_curse:
		_ward_next_curse = false
		_curse_cleansed = true  # counts as resolved → no endure reward
		_reveal_effects = []  # nothing to reveal — no card
		_show_curse_banner("WARDED — THE CURSE IS REPELLED")
		return

	# The player's active buffs are kept (they can fight the curse) — curses live
	# in the separate boss-effects list. Two buckets resolve here:
	#   GAMEPLAY CURSE (the cleansable curse) — from CURSE_CATALOG:
	#     • author-selected + fixed → apply exactly those
	#     • author-selected + random → roll from that set
	#     • no selection + random → roll from the full gameplay catalog
	#   NON-GAMEPLAY (sensory) modifiers — from SENSORY_CATALOG:
	#     • ticked ones always apply
	#     • if "include in random pool" is on, the random roll above may also
	#       surface sensory modifiers from the full sensory set
	# Everything applied is cleansable/endurable alike (uniform boss-effect path).
	var round: Dictionary = GameState.CurrentRound()
	_curse_cleanse_cost = int(round.get("cleanse_cost", CLEANSE_COST_DEFAULT))

	var selected: Array = round.get("curses", [])
	var random_mode: bool = bool(round.get("curse_random", true))
	var sensory_in_pool: bool = bool(round.get("sensory_in_pool", false))

	var to_apply: Array = []
	if random_mode:
		var pool: Array = (
			JourneyData.CURSE_CATALOG
			if selected.is_empty()
			else _catalog_subset(JourneyData.CURSE_CATALOG, selected)
		)
		if sensory_in_pool:
			pool = pool + JourneyData.SENSORY_CATALOG
		to_apply = _roll_from(pool)
	else:
		to_apply = _catalog_subset(JourneyData.CURSE_CATALOG, selected)  # fixed: apply all selected

	# Ticked non-gameplay modifiers always apply (deduped against the roll).
	for s: Dictionary in _catalog_subset(JourneyData.SENSORY_CATALOG, round.get("sensory", [])):
		if s not in to_apply:
			to_apply.append(s)

	# A cursed round should never be a no-op. If the author configured nothing
	# (fixed mode, nothing ticked in either bucket), fall back to a random gameplay
	# curse — matching the pre-split behaviour for an unconfigured cursed round.
	if to_apply.is_empty():
		to_apply = _roll_from(JourneyData.CURSE_CATALOG)

	for roll: Dictionary in to_apply:
		var fx: Dictionary = _make_boss_effect(roll)
		fx["name"] = roll.get("name", fx["name"])
		InventoryService.AddBossEffects([fx])  # also shows as a (red) HUD chip
		_apply_hex(roll, SensoryFX.intensity_for(round, roll))  # sensory → SensoryFX, gameplay → here

	_curse_cleansed = false
	_show_curse_overlay()
	_show_cleanse_button()
	_reveal_effects = _build_reveal_effects(to_apply, false)


# Builds the reveal-card payload from a list of catalog entries.
func _build_reveal_effects(entries: Array, benefit: bool) -> Array:
	var out: Array = []
	for e: Dictionary in entries:
		(
			out
			. append(
				{
					"name": str(e.get("name", "")),
					"desc": str(e.get("desc", "")),
					"benefit": benefit,
				}
			)
		)
	return out


# Rolls one entry from `pool`, or rarely two (the "double" chance). Shared by
# cursed and blessed rounds.
func _roll_from(pool: Array) -> Array:
	if pool.is_empty():
		return []
	var shuffled: Array = pool.duplicate()
	shuffled.shuffle()
	var count: int = 2 if (shuffled.size() >= 2 and randf() < DOUBLE_CURSE_CHANCE) else 1
	return shuffled.slice(0, count)


# Entries of `catalog` whose name is in `names`, preserving catalog order.
func _catalog_subset(catalog: Array, names: Array) -> Array:
	var out: Array = []
	for entry: Dictionary in catalog:
		if entry.get("name", "") in names:
			out.append(entry)
	return out


# Floating "cleanse" button shown during a cursed round — outside the HUD so a
# Fog hex can't hide it. Pay the round's cleanse cost to lift the curse, or endure
# to the end for the round's bonus.
func _show_cleanse_button() -> void:
	_remove_cleanse_button()
	var btn: Button = Button.new()
	var has_item: bool = InventoryService.OwnsItem("cleanse")
	btn.text = (
		"✦ CLEANSE  (use Cleanse item)" if has_item else "✦ CLEANSE  (♦ %d)" % _curse_cleanse_cost
	)
	btn.tooltip_text = (
		"Lift the curse with a Cleanse item or %d coins — or endure it for the reward."
		% _curse_cleanse_cost
	)
	UITheme.style_button(btn, Color(0.45, 0.95, 0.30))
	btn.anchor_left = 0.5
	btn.anchor_right = 0.5
	btn.anchor_top = 1.0
	btn.anchor_bottom = 1.0
	btn.offset_top = -96
	btn.offset_bottom = -56
	btn.offset_left = -110
	btn.offset_right = 110
	btn.pressed.connect(_on_cleanse_pressed)
	add_child(btn)
	_curse_cleanse_btn = btn


func _remove_cleanse_button() -> void:
	if is_instance_valid(_curse_cleanse_btn):
		_curse_cleanse_btn.queue_free()
	_curse_cleanse_btn = null


func _on_cleanse_pressed() -> void:
	# Prefer a held Cleanse item (free); fall back to coins.
	if InventoryService.OwnsItem("cleanse"):
		InventoryService.ConsumeItem("cleanse")
	elif not CoinService.SpendCoins(_curse_cleanse_cost):
		_show_save_toast("✕  NEED ♦ %d OR A CLEANSE ITEM" % _curse_cleanse_cost)
		return
	_cleanse_curse()


# Lifts the active curse(s) mid-round: clears the effects, undoes hex side-effects,
# drops the overlay. Marks the round cleansed so it pays no endure reward.
func _cleanse_curse() -> void:
	_curse_cleansed = true
	InventoryService.ClearBossEffects()
	_clear_curse_hexes()
	_show_hud()  # bring the HUD straight back if a Fog hex hid it
	_hide_curse_overlay()
	_remove_cleanse_button()
	_show_save_toast("✦  CURSE CLEANSED")


# Undoes every hex side-effect — sensory ones via SensoryFX, gameplay ones
# (HUD/pause/blackout) here. Safe to call when none are active (boss rounds,
# plain rounds) — each branch no-ops.
func _clear_curse_hexes() -> void:
	_curse_hud_hidden = false
	if _curse_no_pause:
		_curse_no_pause = false
		_pause_btn.disabled = false
	_video.visible = true  # undo a Blinded (blackout) hex
	if _sensory != null:
		_sensory.clear_all()


# Applies a "hex" curse — effects beyond the stroke (which FunscriptPlayer can't
# do). Sensory (visual/audio) kinds are handled by SensoryFX, with `intensity`
# (0–1) mapped through the catalog's imin/imax; the gameplay kinds are handled
# here. coin_penalty is read at round end, not applied here.
func _apply_hex(roll: Dictionary, intensity: float = 1.0) -> void:
	if _sensory != null and _sensory.apply(roll, intensity):
		return
	match String(roll.get("kind", "")):
		"hud_hide":
			_curse_hud_hidden = true
			_hud.visible = false
		"toll":
			var take: int = mini(TOLL_AMOUNT, CoinService.Balance)
			if take > 0:
				CoinService.SpendCoins(take)
		"no_pause":
			_curse_no_pause = true
			_pause_btn.disabled = true


# Transient curse flash naming the rolled affliction.
func _show_curse_banner(curse_name: String) -> void:
	var banner: Label = Label.new()
	banner.text = "☠  CURSED  —  %s" % (curse_name as String).to_upper()
	banner.add_theme_color_override("font_color", UITheme.ERROR_SOFT)
	banner.add_theme_font_size_override("font_size", 30)
	banner.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	banner.anchor_left = 0.0
	banner.anchor_right = 1.0
	banner.anchor_top = 0.35
	banner.mouse_filter = Control.MOUSE_FILTER_IGNORE
	banner.modulate.a = 0.0
	add_child(banner)
	var tw: Tween = create_tween()
	tw.tween_property(banner, "modulate:a", 1.0, 0.3)
	tw.tween_interval(1.4)
	tw.tween_property(banner, "modulate:a", 0.0, 0.5)
	tw.tween_callback(banner.queue_free)


# Tears down boss / curse state at round end. Safe to call on plain rounds.
func _exit_boss_mode() -> void:
	if not _is_boss_round and not _is_cursed_round and not _is_blessed_round:
		return
	# Undo any hex side-effects before clearing the flags.
	_clear_curse_hexes()
	_hide_curse_overlay()
	_remove_cleanse_button()
	# Blessed teardown. Lingering un-freezes the effect clock; Ward intentionally
	# persists past this round until the next curse consumes it.
	if _blessing_lingering:
		_blessing_lingering = false
		InventoryService.SetPaused(_paused)
	if _blessing_frame != null:
		_blessing_frame.visible = false
	if _blessing_tint != null:
		_blessing_tint.visible = false
	_is_boss_round = false
	_is_cursed_round = false
	_is_blessed_round = false
	InventoryService.ClearBossEffects()
	_inv_btn.disabled = false
	if _boss_frame != null:
		_boss_frame.visible = false


# Converts a saved boss modifier ({kind, factor?, min?, max?}) into a full
# effect dict the active-effects pipeline understands.
func _make_boss_effect(mod: Dictionary) -> Dictionary:
	var kind: String = mod.get("kind", "")
	var effect: Dictionary = {
		"id": "boss_" + kind,
		"name": BOSS_EFFECT_NAMES.get(kind, kind.to_upper()),
		"kind": kind,
		"boss": true,
	}
	if mod.has("factor"):
		effect["factor"] = mod["factor"]
	if mod.has("min"):
		effect["min"] = mod["min"]
	if mod.has("max"):
		effect["max"] = mod["max"]
	return effect


func _build_beat_bar() -> void:
	if not SettingsService.get_beat_bar_enabled():
		return
	_beat_bar = BeatBarScript.new()
	_beat_bar.anchor_left = 0.0
	_beat_bar.anchor_right = 1.0
	_beat_bar.anchor_top = 1.0
	_beat_bar.anchor_bottom = 1.0
	_beat_bar.offset_left = 0.0
	_beat_bar.offset_right = 0.0
	_beat_bar.offset_top = -120.0
	_beat_bar.offset_bottom = -56.0
	add_child(_beat_bar)


# Brings the beat bar into sync with the current setting. Called after the
# Options overlay closes so toggling "Beat Bar" mid-game takes effect on the
# active round instead of requiring the user to exit and re-enter.
func _refresh_beat_bar_visibility() -> void:
	var should_show: bool = SettingsService.get_beat_bar_enabled()
	if should_show and _beat_bar == null:
		_build_beat_bar()
		# Seed the new bar with the current round's beats if a round is loaded
		# so it doesn't start blank.
		if _beat_bar != null and FunscriptPlayer.ActionCount > 0:
			_beat_bar.set_beats(FunscriptPlayer.GetBeats())
	elif not should_show and _beat_bar != null:
		_beat_bar.queue_free()
		_beat_bar = null


func _build_boss_frame() -> void:
	_boss_frame = Panel.new()
	_boss_frame.set_anchors_preset(Control.PRESET_FULL_RECT)
	_boss_frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_boss_frame.visible = false
	var s: StyleBoxFlat = StyleBoxFlat.new()
	s.bg_color = Color(0, 0, 0, 0)
	s.border_color = UITheme.DANGER
	s.border_width_left = 6
	s.border_width_right = 6
	s.border_width_top = 6
	s.border_width_bottom = 6
	_boss_frame.add_theme_stylebox_override("panel", s)
	add_child(_boss_frame)
	_send_frame_behind_hud(_boss_frame)


# Decorative round frames (boss/curse/blessing borders) must draw BEHIND the HUD
# so their edge border doesn't sit on top of the progress bar / HUD bar. Call
# right after the frame is added to the game-loop root.
func _send_frame_behind_hud(frame: Control) -> void:
	if is_instance_valid(_hud):
		move_child(frame, _hud.get_index())


# Builds the cursed-round overlay — a sickly green "hex" border plus a faint
# tint over the play area, giving cursed rounds a distinct identity from the
# boss frame's aggressive red pulse — and the SensoryFX engine, whose overlay
# stack (Murk/Tunnel/Bloodshot/Static/Flicker/Strobe) slots in above the tint
# and below the frames, preserving the original draw order. Hidden until used.
func _build_curse_overlay() -> void:
	_curse_tint = ColorRect.new()
	_curse_tint.set_anchors_preset(Control.PRESET_FULL_RECT)
	_curse_tint.color = Color(0.20, 0.45, 0.15, 0.12)  # faint toxic green
	_curse_tint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_curse_tint.visible = false
	add_child(_curse_tint)

	# Non-gameplay (sensory) modifier engine — owns its overlays, the composable
	# video shader, the VideoFX audio bus, tremor, and mute.
	_sensory = SensoryFX.new()
	add_child(_sensory)
	_sensory.setup(_video, self)

	_curse_frame = Panel.new()
	_curse_frame.set_anchors_preset(Control.PRESET_FULL_RECT)
	_curse_frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_curse_frame.visible = false
	var s: StyleBoxFlat = StyleBoxFlat.new()
	s.bg_color = Color(0, 0, 0, 0)
	s.border_color = Color(0.45, 0.95, 0.30)  # toxic green
	s.border_width_left = 5
	s.border_width_right = 5
	s.border_width_top = 5
	s.border_width_bottom = 5
	_curse_frame.add_theme_stylebox_override("panel", s)
	add_child(_curse_frame)
	_send_frame_behind_hud(_curse_frame)

	# Blessed-round counterparts — faint gold tint + gold frame.
	_blessing_tint = ColorRect.new()
	_blessing_tint.set_anchors_preset(Control.PRESET_FULL_RECT)
	_blessing_tint.color = Color(0.55, 0.45, 0.10, 0.10)
	_blessing_tint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_blessing_tint.visible = false
	add_child(_blessing_tint)

	_blessing_frame = Panel.new()
	_blessing_frame.set_anchors_preset(Control.PRESET_FULL_RECT)
	_blessing_frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_blessing_frame.visible = false
	var gs: StyleBoxFlat = StyleBoxFlat.new()
	gs.bg_color = Color(0, 0, 0, 0)
	gs.border_color = Color(1.0, 0.84, 0.30)  # gold
	gs.border_width_left = 5
	gs.border_width_right = 5
	gs.border_width_top = 5
	gs.border_width_bottom = 5
	_blessing_frame.add_theme_stylebox_override("panel", gs)
	add_child(_blessing_frame)
	_send_frame_behind_hud(_blessing_frame)


func _show_curse_overlay() -> void:
	if _curse_tint != null:
		_curse_tint.visible = true
	if _curse_frame != null:
		_curse_frame.visible = true


func _hide_curse_overlay() -> void:
	if _curse_tint != null:
		_curse_tint.visible = false
	if _curse_frame != null:
		_curse_frame.visible = false


# Slow, wavering drift — eerie/unstable rather than the boss frame's hard climax
# pulse. Never snaps; just breathes.
func _update_curse_frame() -> void:
	if _curse_frame == null:
		return
	var t: float = Time.get_ticks_msec() / 1000.0
	_curse_frame.modulate.a = 0.4 + 0.25 * sin(t * TAU * 0.35)


# Holds the boss frame at a subtle level, then pulses it in the final stretch.
func _update_boss_frame() -> void:
	if _boss_frame == null:
		return
	var remaining: float = _round_time_left()
	if remaining > 0.0 and remaining <= BOSS_CLIMAX_SECS:
		var t: float = Time.get_ticks_msec() / 1000.0
		_boss_frame.modulate.a = 0.55 + 0.45 * (0.5 + 0.5 * sin(t * TAU * 1.5))
	else:
		_boss_frame.modulate.a = 0.5


# Seconds left in the current round — from the video clock, or the no-video
# fallback timer. Returns -1 when unknown.
func _round_time_left() -> float:
	if _video.is_playing():
		var vlen: float = _video.get_stream_length()
		if vlen > 0.0:
			return vlen - _video.stream_position
	if not _end_timer.is_stopped():
		return _end_timer.time_left
	return -1.0


func _fit_video_cover() -> void:
	var texture := _video.get_video_texture()
	if texture == null:
		return
	var video_size := texture.get_size()
	if video_size.x <= 0.0 or video_size.y <= 0.0:
		return
	var screen := get_viewport_rect().size
	var video_ar := video_size.x / video_size.y
	var screen_ar := screen.x / screen.y
	var scaled: Vector2
	if video_ar > screen_ar:
		# Wider than screen — fit width, letterbox top/bottom
		scaled = Vector2(screen.x, screen.x / video_ar)
	else:
		# Taller than screen — fit height, letterbox sides
		scaled = Vector2(screen.y * video_ar, screen.y)
	_video.position = (screen - scaled) / 2.0
	_video.size = scaled

	# Tremor hex — per-frame jitter (zero when inactive). _fit_video_cover runs
	# every frame from _process, so this re-applies on top of the clean fit.
	if _sensory != null:
		_video.position += _sensory.tremor_offset()


func _find_video(folder: String) -> String:
	if folder == "":
		return ""
	var dir: DirAccess = DirAccess.open(folder)
	if dir == null:
		return ""
	dir.list_dir_begin()
	var fname: String = dir.get_next()
	while fname != "":
		if not dir.current_is_dir() and fname.get_extension().to_lower() in VIDEO_EXTS:
			dir.list_dir_end()
			return folder + "/" + fname
		fname = dir.get_next()
	dir.list_dir_end()
	return ""


func _load_video(path: String) -> void:
	_video.position = Vector2.ZERO
	_video.size = get_viewport_rect().size
	if path == "":
		push_warning("GameLoop: no video found for this round — funscript-only fallback")
		_start_no_video_fallback()
		return

	var ext: String = path.get_extension().to_lower()

	if ext == "ogv":
		var stream: Resource = ResourceLoader.load(path)
		if stream and stream is VideoStream:
			_video.stream = stream as VideoStream
			_video.play()
			FunscriptPlayer.Play()
			return
		push_warning("GameLoop: could not load .ogv at %s" % path)
		_start_no_video_fallback()
		return

	# MP4/MKV/WebM — requires EIRTeam.FFmpeg GDExtension.
	# Install: https://github.com/EIRTeam/EIRTeam.FFmpeg/releases
	# Drop the addons/ folder into the project root and reopen Godot.
	if not ClassDB.class_exists("FFmpegVideoStream"):
		push_warning(
			"GameLoop: FFmpegVideoStream not found — install EIRTeam.FFmpeg for MP4 support. Running funscript-only."
		)
		_start_no_video_fallback()
		return

	var abs_path: String = ProjectSettings.globalize_path(path)
	var stream: Resource = ClassDB.instantiate("FFmpegVideoStream")
	stream.set("file", abs_path)
	_video.stream = stream as VideoStream
	_video.play()

	# EIRTeam.FFmpeg surfaces open/decode failures as C++-level push_errors
	# rather than a catchable GDScript return value. Give the player one frame
	# to settle: if the file couldn't be opened the player will have stopped
	# itself, and is_playing() returns false. In that case wipe the stream and
	# fall back to the funscript-only timer so the round still advances.
	await get_tree().process_frame
	if not _video.is_playing():
		push_warning("GameLoop: video failed to open '%s' — funscript-only fallback." % abs_path)
		_video.stream = null
		_start_no_video_fallback()
		return
	FunscriptPlayer.Play()


func _start_no_video_fallback() -> void:
	# No video: use funscript length to drive a timer so the round still advances.
	FunscriptPlayer.Play()
	var dur_ms: int = GameState.CurrentRound().get("length_ms", 0)
	if dur_ms > 0:
		_end_timer.wait_time = dur_ms / 1000.0
		_end_timer.start()
	else:
		# Unknown length — let the player advance manually (pause button becomes skip)
		_pause_btn.text = "> SKIP"


# ---------------------------------------------------------------------------
# Round / scene transitions
# ---------------------------------------------------------------------------


func _on_round_ended() -> void:
	# Extract the name here in GDScript where Dictionary access is reliable,
	# then pass it explicitly so C# never needs to look up the key itself.
	var _cur: Dictionary = GameState.CurrentRound()
	var _cur_name: String = _cur.get("name", "") as String
	var _cur_ms: int = _cur.get("length_ms", 0) as int
	GameState.LogRound(_cur, _cur_name, _cur_ms)

	# Append to the GDScript-side round-name log (see _ready). EndScreen reads
	# this directly, avoiding any potential C#→GDScript Dictionary marshalling
	# quirks for the name string.
	var _names: PackedStringArray = (
		GameState.get_meta("_round_names", PackedStringArray()) as PackedStringArray
	)
	_names.append(_cur_name)
	GameState.set_meta("_round_names", _names)
	ScoreService.EndRound()
	FunscriptPlayer.Stop()
	# Capture coin modifiers BEFORE _exit_boss_mode clears the boss-effect list:
	# a "Fortune" boon (coin_jackpot) and a "Greed"/"Pauper" curse (coin_penalty)
	# both live there, alongside any active shop jackpot.
	var jackpot_factor: float = 1.0
	var penalty_factor: float = 1.0
	for fx: Dictionary in InventoryService.GetActiveEffects():
		match fx.get("kind", ""):
			"coin_jackpot":
				jackpot_factor *= float(fx.get("factor", 1.0))
			"coin_penalty":
				penalty_factor *= float(fx.get("factor", 1.0))
	# Endure-payout: a cursed round carried to the end without cleansing pays its
	# curse_reward bonus. Captured before _exit_boss_mode clears the cursed flag.
	var endure_reward: int = 0
	if _is_cursed_round and not _curse_cleansed:
		endure_reward = int(GameState.CurrentRound().get("curse_reward", 0))
	# Tear down boss / curse / blessing state (modifiers, lockout, frames) if active.
	_exit_boss_mode()

	var coins: int = GameState.CurrentRound().get("coins", 0)
	coins = roundi(coins * jackpot_factor)
	# Consume any active shop jackpot so it only ever doubles one round's reward
	# (the boss-effect Fortune was already cleared by _exit_boss_mode above).
	InventoryService.ConsumeEffects("coin_jackpot")
	# Greed/Pauper curse: coins reduced (captured above, before effects cleared).
	coins = roundi(coins * penalty_factor)
	# Endure reward: bonus for carrying a curse to the end (on top of the round
	# coins, so it survives a Greed penalty).
	coins += endure_reward
	if coins > 0:
		CoinService.AddCoins(coins)
	if endure_reward > 0:
		_show_save_toast("✦  CURSE ENDURED  +♦ %d" % endure_reward)

	if GameState.IsLastRound():
		_transition_to_end_screen()
		return
	await _transition_swap(
		func() -> void:
			GameState.Advance()
			_load_current_item()
	)


# Fade-to-black → hold → run swap → fade-from-black. Used at every sequence
# boundary so transitions feel intentional instead of jump-cut. The transition
# overlay lives on a high-layer CanvasLayer, so it always sits above shop /
# storyboard / fork screens that may be added/removed during the swap.
func _transition_swap(swap_action: Callable) -> void:
	_transition.mouse_filter = Control.MOUSE_FILTER_STOP

	var tween_in: Tween = create_tween()
	tween_in.tween_property(_transition, "modulate:a", 1.0, TRANSITION_FADE_TIME).set_ease(
		Tween.EASE_IN
	)
	await tween_in.finished

	# Black now fully covers the screen — including any overlay we're leaving.
	# Overlays deliberately don't free themselves (see _show_*_screen), so they
	# stay visible and dim into the black instead of vanishing and flashing the
	# play area behind them. Free it now, under cover of the opaque black.
	_free_current_overlay()

	# Hide the HUD under the black so it can't flash in at full opacity when the
	# black clears; it's faded back in below once we land on a round.
	_hud.modulate.a = 0.0

	# Hold on the black, then run the swap so the next round's video loads behind it.
	await get_tree().create_timer(TRANSITION_HOLD_TIME).timeout
	swap_action.call()

	# Hold the black until the next round's video actually has a frame, so the
	# fade never reveals the bare background between rounds.
	await _await_video_ready()

	var tween_out: Tween = create_tween()
	tween_out.tween_property(_transition, "modulate:a", 0.0, TRANSITION_FADE_TIME).set_ease(
		Tween.EASE_OUT
	)
	await tween_out.finished

	_transition.mouse_filter = Control.MOUSE_FILTER_IGNORE

	# Fade the HUD back in only when we've landed on a round — overlays (fork /
	# shop / storyboard) cover the screen and own their own UI.
	if not (GameState.CurrentItemType() in ["fork", "shop", "storyboard"]):
		_show_hud(true)


# Waits until the video player has produced a frame (or a short cap elapses), so
# a round transition doesn't reveal the background before the video renders.
# Returns immediately when no video is playing (no-video rounds / overlays).
func _await_video_ready() -> void:
	if not _video.is_playing():
		return
	for _i in 90:  # ~1.5s cap so a stalled or failed decode never hangs the fade
		var tex: Texture2D = _video.get_video_texture()
		if tex != null and tex.get_size().x > 0.0:
			return
		await get_tree().process_frame


# Frees the overlay we're transitioning away from. Called from _transition_swap
# once the black is opaque, so the overlay dims into the black instead of
# vanishing and exposing the play area. No-op for round-to-round transitions.
func _free_current_overlay() -> void:
	if is_instance_valid(_current_overlay):
		_current_overlay.queue_free()
	_current_overlay = null


# ---------------------------------------------------------------------------
# Journey map — read-only GraphView of the authored graph with a "you are here"
# marker. Opened on demand: the HUD ◇ MAP button, the M key, or the map button on
# a shop / storyboard / interactive-fork overlay. Availability is authored per
# journey (_map_enabled); a journey can hide it to keep its layout a surprise.
# ---------------------------------------------------------------------------


# Builds the persistent map (hidden) on its own CanvasLayer, plus the HUD map
# button. Self-contained: reads the journey accent locally. Skipped entirely when
# the author has disabled the map for this journey — _map_view stays null, so
# _open_map_viewer no-ops and the overlay map buttons aren't shown.
func _build_map() -> void:
	if not _map_enabled:
		return
	var accent: Color = UITheme.PURPLE_BRIGHT

	var layer: CanvasLayer = CanvasLayer.new()
	layer.layer = 2  # above TransitionLayer (1) and the overlays, so the map sits on top
	add_child(layer)

	_map_overlay = Control.new()
	_map_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	_map_overlay.visible = false
	layer.add_child(_map_overlay)

	var backdrop: ColorRect = ColorRect.new()
	backdrop.set_anchors_preset(Control.PRESET_FULL_RECT)
	backdrop.color = Color(0.0, 0.0, 0.0, 0.85)
	backdrop.mouse_filter = Control.MOUSE_FILTER_STOP  # block clicks reaching the game
	_map_overlay.add_child(backdrop)

	_map_view = GraphViewScene.instantiate()
	_map_view.map_mode = true
	_map_view.set_anchors_preset(Control.PRESET_FULL_RECT)
	_map_view.offset_top = 56
	_map_view.offset_bottom = -16
	_map_view.offset_left = 16
	_map_view.offset_right = -16
	_map_overlay.add_child(_map_view)
	_map_view.set_marker_color(accent)
	# Render the map from the journey GRAPH (the same DAG the runtime walks). Edges show the real
	# flow — including authored skips / converges / islands the old nested render couldn't draw —
	# so there's no separate redirect overlay any more. Format-2 journeys carry the author's node
	# positions; legacy (migrated) ones don't, so seed the layout the same way the editor does.
	# Copy the nodes first so seeding never mutates GameState.Journey.
	var map_graph: Dictionary = {
		"start": str(GameState.Journey.get("start", "")),
		"nodes": (GameState.Journey.get("nodes", {}) as Dictionary).duplicate(true),
	}
	for nid: String in map_graph["nodes"]:
		if not (map_graph["nodes"][nid] as Dictionary).has("pos"):
			GraphLayout.seed_positions(map_graph)  # any node missing a pos → seed the whole graph
			break
	_map_view.set_graph(map_graph)

	var title: Label = Label.new()
	title.text = "◇  JOURNEY MAP"
	title.add_theme_color_override("font_color", accent)
	title.add_theme_font_size_override("font_size", 18)
	title.position = Vector2(22, 16)
	title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_map_overlay.add_child(title)

	var hint: Label = Label.new()
	hint.text = "DRAG TO PAN  ·  SCROLL TO ZOOM  ·  ESC TO CLOSE"
	hint.add_theme_color_override("font_color", UITheme.DARK_TEXT)
	hint.add_theme_font_size_override("font_size", 11)
	hint.position = Vector2(24, 39)
	hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_map_overlay.add_child(hint)

	_map_close_btn = Button.new()
	_map_close_btn.text = "✕ CLOSE"
	_map_close_btn.focus_mode = Control.FOCUS_NONE
	_style_button(_map_close_btn, UITheme.MAGENTA)
	_map_close_btn.anchor_left = 1.0
	_map_close_btn.anchor_right = 1.0
	_map_close_btn.offset_left = -132
	_map_close_btn.offset_right = -16
	_map_close_btn.offset_top = 14
	_map_close_btn.offset_bottom = 48
	_map_close_btn.pressed.connect(_close_map_viewer)
	_map_overlay.add_child(_map_close_btn)

	# HUD map button, inserted before the inventory button.
	var map_btn: Button = Button.new()
	map_btn.text = "◇ MAP"
	map_btn.focus_mode = Control.FOCUS_NONE
	map_btn.tooltip_text = "View the journey map (M)"
	_style_button(map_btn, accent)
	_hud_layout.add_child(map_btn)
	_hud_layout.move_child(map_btn, _inv_btn.get_index())
	map_btn.pressed.connect(_on_map_pressed)
	map_btn.mouse_entered.connect(_show_hud)


func _on_map_pressed() -> void:
	if _map_open:
		_close_map_viewer()
	else:
		_open_map_viewer()


func _open_map_viewer() -> void:
	if _map_open or _map_view == null:
		return
	_map_open = true
	# Suspend the underlying overlay's input so a click/key meant for the map can't
	# leak through to it (shop/storyboard handle raw _input, which a backdrop's
	# mouse_filter does NOT block). The map's own modal handling stays in GameLoop.
	_set_overlay_input_enabled(false)
	_map_close_btn.visible = true
	if _map_fog:
		# Fog of war (author opt-in): re-render the map for the current discovery (refreshed each open so
		# newly-played nodes appear). set_fog defers its relayout — and that relayout frees the marker —
		# so place the marker / centre AFTER it settles. Overlay stays hidden until then, so no flash.
		_map_view.set_fog(true, GameState.DiscoveredNodes(), _map_fog_reveal)
		call_deferred("_finish_open_map_viewer")
	else:
		_finish_open_map_viewer()


# Marker + centre + fade-in for the open map. Split out so the fog path can run it after its relayout.
func _finish_open_map_viewer() -> void:
	if not _map_open or _map_view == null:
		return
	# The graph map highlights the current node by its stable id (GameState walks the DAG by id).
	var node_id: String = GameState.CurrentNodeId()
	_map_view.set_marker_at(node_id)
	_map_view.center_on(node_id)
	_map_overlay.modulate.a = 0.0
	_map_overlay.visible = true
	create_tween().tween_property(_map_overlay, "modulate:a", 1.0, 0.18)


func _close_map_viewer() -> void:
	if not _map_open:
		return
	_map_open = false
	# Hand input back to the overlay (shop / storyboard / fork) underneath.
	_set_overlay_input_enabled(true)
	var t: Tween = create_tween()
	t.tween_property(_map_overlay, "modulate:a", 0.0, 0.15)
	await t.finished
	_map_overlay.visible = false


# Suspends or restores the active overlay's input callbacks while the map is open.
# No-op outside an overlay (plain in-round map open) — _current_overlay is null then.
func _set_overlay_input_enabled(enabled: bool) -> void:
	if is_instance_valid(_current_overlay):
		_current_overlay.set_process_input(enabled)
		_current_overlay.set_process_unhandled_input(enabled)


func _go_to_menu() -> void:
	_video.stop()
	FunscriptPlayer.Stop()
	# In a test play, "back to menu" (button or Esc) returns to the builder the
	# preview was launched from, not the main menu.
	if _test_mode:
		_exit_test_to_builder()
		return
	# Quitting mid-journey is an abandoned run — unless we already accounted for
	# this run (completed it, or left via Save & Quit to resume later).
	if not _run_accounted:
		_record_run(false)
	Transition.change_scene("res://scenes/main/Main.tscn")


# Called from every "journey finished" exit site. Wipes the save file so the
# next time the player opens the journey it offers a fresh start instead of
# a stale Resume button pointing at a completed run.
func _transition_to_end_screen() -> void:
	# A test play has no results screen — reaching the end just returns to the
	# builder. Crucially, skip the save delete: a preview must never touch a
	# real player's run-save for this journey.
	if _test_mode:
		_exit_test_to_builder()
		return
	_record_run(true)  # completed run → scoreboard
	JourneySaveService.delete_save(GameState.Journey.get("folder_name", ""))
	Transition.change_scene("res://scenes/end_screen/EndScreen.tscn")


# Records this run's outcome to the journey's local scoreboard. `completed` is
# true when the journey reached the end screen, false for an abandoned (quit)
# run — which logs the score-so-far and how far the player got. No-op in test
# mode; sets _run_accounted so a later menu exit can't double-record.
func _record_run(completed: bool) -> void:
	_run_accounted = true
	if _test_mode:
		return
	var folder: String = GameState.Journey.get("folder_name", "")
	if folder.is_empty():
		return
	var total: int = GameState.TotalRounds()
	var reached: int = total if completed else clampi(GameState.RoundNumber, 0, total)
	(
		ScoreboardService
		. add_run(
			folder,
			{
				"score": ScoreService.TotalScore,
				"completed": completed,
				"rounds_done": reached,
				"rounds_total": total,
			}
		)
	)


# Returns from a test play to the builder, reloading the same journey so the
# author lands back on the graph they launched from. The journey was saved
# before the test started, so the on-disk state the builder reloads is exactly
# what was being edited — no in-memory state needs to be carried across.
func _exit_test_to_builder() -> void:
	_video.stop()
	FunscriptPlayer.Stop()
	JourneyBuilder.edit_journey = _test_return_journey
	Transition.change_scene("res://scenes/journey_builder/JourneyBuilder.tscn")


# Top-center "TEST MODE" indicator shown for the duration of a test play, so the
# author always knows this is a preview and how to leave it.
func _show_test_banner() -> void:
	var text: String = "▶  TEST MODE  —  ESC TO EXIT"
	if _test_seed_score > 0 or _test_seed_coins > 0:
		text += "    (SEED  %d PTS / ♦ %d)" % [_test_seed_score, _test_seed_coins]
	var banner: Label = Label.new()
	banner.text = text
	banner.add_theme_color_override("font_color", UITheme.AMBER)
	banner.add_theme_font_size_override("font_size", 16)
	banner.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	banner.anchor_left = 0.0
	banner.anchor_right = 1.0
	banner.offset_top = 12
	banner.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(banner)


# ---------------------------------------------------------------------------
# Save / Resume
# ---------------------------------------------------------------------------


# Writes a save for the current journey at the start of the current round.
# Used by both the checkpoint banner's "Save & Quit" button and the save_now
# inventory item. Returns true on success.
#
# Save point semantics: whatever round the player is *currently in* is the
# resume point. We don't preserve mid-round position — the player restarts
# the current round from action 0 on resume. This keeps the save model
# simple and predictable (you replay the round you were doing).
func _write_journey_save() -> bool:
	# Real saves are disabled during a test play — a preview must never write a
	# run-save (the Safe Word item and checkpoint Save & Quit both route here).
	if _test_mode:
		return false
	var journey: Dictionary = GameState.Journey
	var folder_name: String = journey.get("folder_name", "")
	if folder_name == "":
		push_warning("GameLoop: cannot save — journey has no folder_name")
		return false

	# Stitch together one payload from each service that owns part of the run.
	# Inventory carries through; active effects do NOT (clean modifier slate
	# on resume — see InventoryService.LoadFromSave for the rationale).
	var game_state_data: Dictionary = GameState.CaptureSaveData()
	var score_data: Dictionary = ScoreService.CaptureSaveData()
	var payload: Dictionary = {
		"sequence_index": game_state_data.get("sequence_index", 0),
		"sequence": game_state_data.get("sequence", []),
		"fork_depth": game_state_data.get("fork_depth", 0),
		"coins": CoinService.Balance,
		"score": score_data.get("score", 0),
		"total_actions": score_data.get("strokes", 0),
		"inventory": InventoryService.CaptureSaveData(),
		"round_names": GameState.get_meta("_round_names", PackedStringArray()) as PackedStringArray,
	}
	return JourneySaveService.write_save(folder_name, payload)


# Triggered by the checkpoint banner's "Save & Quit" button (also by the
# save_now item — both flow through here). Writes the save, then returns to
# the catalogue with the same cleanup as a regular Back-to-Menu.
func _on_save_and_quit() -> void:
	# In test mode there's no real save to write; just leave (back to the builder).
	if _test_mode:
		_go_to_menu()
		return
	var ok: bool = _write_journey_save()
	if not ok:
		push_warning("GameLoop: save failed — returning to menu without saving")
	# Saved for resume — this isn't an abandoned run, so don't let the menu exit
	# log it to the scoreboard.
	_run_accounted = true
	_go_to_menu()


# Triggered when the save_now utility item is consumed. Unlike the checkpoint
# banner's Save & Quit, the run keeps going — the item just writes a save the
# player can return to later. Boss-round lockout is enforced by the inventory
# panel which disables item use during bosses, so we don't need to check
# round type here.
func _on_save_item_used() -> void:
	if _test_mode:
		_show_save_toast("✕  SAVING DISABLED IN TEST")
		return
	var ok: bool = _write_journey_save()
	if ok:
		_show_save_toast("✓  PROGRESS SAVED")
	else:
		_show_save_toast("✕  SAVE FAILED")


# Brief auto-dismissing notification used after the save_now item fires. Keeps
# the player in the round instead of pulling them into a modal.
func _show_save_toast(text: String) -> void:
	var toast: PanelContainer = PanelContainer.new()
	toast.mouse_filter = Control.MOUSE_FILTER_IGNORE
	toast.anchor_left = 0.5
	toast.anchor_right = 0.5
	toast.anchor_top = 0.0
	toast.anchor_bottom = 0.0
	toast.grow_horizontal = Control.GROW_DIRECTION_BOTH
	toast.offset_top = 70  # below the device-warning banner

	var s: StyleBoxFlat = StyleBoxFlat.new()
	s.bg_color = Color(UITheme.AMBER.r, UITheme.AMBER.g, UITheme.AMBER.b, 0.92)
	s.border_color = UITheme.AMBER
	s.border_width_left = 2
	s.border_width_right = 2
	s.border_width_top = 2
	s.border_width_bottom = 2
	s.content_margin_left = 20
	s.content_margin_right = 20
	s.content_margin_top = 8
	s.content_margin_bottom = 8
	s.corner_radius_top_left = 6
	s.corner_radius_top_right = 6
	s.corner_radius_bottom_left = 6
	s.corner_radius_bottom_right = 6
	toast.add_theme_stylebox_override("panel", s)

	var lbl: Label = Label.new()
	lbl.text = text
	UITheme.style_label(lbl, UITheme.WHITE_SOFT, 13, true)
	toast.add_child(lbl)
	add_child(toast)

	# Fade out after ~2 seconds.
	var tween: Tween = create_tween()
	tween.tween_interval(1.6)
	tween.tween_property(toast, "modulate:a", 0.0, 0.4)
	tween.finished.connect(func() -> void: toast.queue_free())


func _on_options_pressed() -> void:
	_video.paused = true
	FunscriptPlayer.Pause()
	_options_open = true  # counts as an active pause for the score penalty
	# Freeze the active-effect clock while the Options overlay is open.
	InventoryService.SetPaused(true)
	var opts: Control = OptionsScene.instantiate()
	opts.overlay_mode = true
	opts.tree_exiting.connect(_on_options_closed)
	add_child(opts)


func _on_options_closed() -> void:
	_options_open = false
	# Only resume if the round was not separately paused via the pause button —
	# in that case the effect clock must stay frozen until the player resumes.
	if not _paused:
		_video.paused = false
		FunscriptPlayer.Resume()
		InventoryService.SetPaused(false)
	# Output mode may have changed in Options — re-evaluate the disconnect
	# banner against whatever backend is now selected.
	_refresh_device_warning()
	# Beat-bar visibility setting may have toggled — create or destroy the bar
	# to match the new state without requiring the user to exit the journey.
	_refresh_beat_bar_visibility()
	# Stroke range / delay may have changed in Options — re-sync the Quick Settings drawer if open.
	if is_instance_valid(_session_panel):
		_session_panel.resync()


# ---------------------------------------------------------------------------
# Pause / HUD
# ---------------------------------------------------------------------------


func _toggle_pause() -> void:
	# A "Restless" curse forbids pausing this round.
	if _curse_no_pause and not _paused:
		_show_save_toast("✕  RESTLESS — CAN'T PAUSE")
		return
	_paused = not _paused
	_video.paused = _paused
	# Freeze the active-effect clock while paused — or for the whole round under a
	# Lingering boon, so unpausing doesn't restart the countdown.
	InventoryService.SetPaused(_paused or _blessing_lingering)
	if _paused:
		FunscriptPlayer.Pause()
		_pause_btn.text = "> RESUME"
	else:
		FunscriptPlayer.Resume()
		_pause_btn.text = "|| PAUSE"


func _show_hud(fade: bool = false) -> void:
	# A "Fog" curse hides the HUD for the whole round — don't let hover / timers
	# reveal it.
	if _curse_hud_hidden:
		_hud.visible = false
		return
	_hud.visible = true
	if fade:
		# Smoothly bring the HUD back after a round transition (rather than
		# popping in at full opacity the instant the fade clears).
		_hud.modulate = Color(1, 1, 1, 0)
		create_tween().tween_property(_hud, "modulate:a", 1.0, 0.3)
	else:
		_hud.modulate = Color(1, 1, 1, 1)
	_hide_timer.start(SettingsService.get_hud_hide_delay())


func _on_hide_timer_timeout() -> void:
	_hud.visible = false


# Toggles the in-play Quick Settings drawer (stroke range + delay). Mutually exclusive with the
# inventory drawer — opening one closes the other.
func _on_session_settings_pressed() -> void:
	if is_instance_valid(_session_panel):
		_session_panel.close()
		return
	if is_instance_valid(_inventory_panel):
		_inventory_panel.close()
	_session_panel = SessionSettingsPanel.new()
	_session_panel.closed.connect(_on_session_settings_closed)
	add_child(_session_panel)
	_show_hud()


func _on_session_settings_closed() -> void:
	_session_panel = null


# ---------------------------------------------------------------------------
# Input
# ---------------------------------------------------------------------------


func _input(event: InputEvent) -> void:
	# Any activity shows the HUD.
	if event is InputEventMouseMotion or event is InputEventMouseButton or event is InputEventKey:
		_show_hud()

	# Keyboard hotkeys — evaluated in order of specificity.
	if event is InputEventKey:
		var key_event := event as InputEventKey
		if key_event.pressed and not key_event.echo:
			# Map viewer is modal while open: Esc / M close it; swallow the rest.
			if _map_open:
				if key_event.keycode == KEY_ESCAPE or key_event.keycode == KEY_M:
					_close_map_viewer()
				get_viewport().set_input_as_handled()
				return
			match key_event.keycode:
				KEY_M:
					# M: open the journey map (when the author enabled it). Blocked while a
					# full-screen overlay is up, except shops / storyboards / interactive
					# forks, which allow it.
					if _map_enabled and (not _is_overlay_open or _overlay_map_allowed):
						_open_map_viewer()
						get_viewport().set_input_as_handled()
				KEY_SPACE:
					# Space: pause / resume — blocked while a full-screen overlay is open
					# (shop / fork / storyboard handles its own input first).
					if not _is_overlay_open:
						_toggle_pause()
						get_viewport().set_input_as_handled()
				KEY_TAB:
					# Tab: toggle inventory panel — disabled during boss rounds.
					if not _is_overlay_open and not _is_boss_round:
						_on_inventory_pressed()
						get_viewport().set_input_as_handled()
				KEY_ESCAPE:
					# Esc: close the Quick Settings drawer or inventory if open, otherwise leave to menu.
					# Overlay screens (shop/storyboard) capture Esc themselves before
					# it reaches here; the fork screen intentionally does not (no escape).
					if not _is_overlay_open:
						if is_instance_valid(_session_panel):
							_session_panel.close()
						elif is_instance_valid(_inventory_panel):
							_inventory_panel.close()
						else:
							_go_to_menu()
						get_viewport().set_input_as_handled()
				KEY_S:
					# S: toggle the in-play Quick Settings drawer (stroke range + delay).
					if not _is_overlay_open:
						_on_session_settings_pressed()
						get_viewport().set_input_as_handled()
				# Arrow keys nudge the stroke range, but only while the drawer is open: ↑/↓ max, →/← min.
				KEY_UP:
					if is_instance_valid(_session_panel):
						_session_panel.nudge_range(0, STROKE_RANGE_STEP)
						get_viewport().set_input_as_handled()
				KEY_DOWN:
					if is_instance_valid(_session_panel):
						_session_panel.nudge_range(0, -STROKE_RANGE_STEP)
						get_viewport().set_input_as_handled()
				KEY_RIGHT:
					if is_instance_valid(_session_panel):
						_session_panel.nudge_range(STROKE_RANGE_STEP, 0)
						get_viewport().set_input_as_handled()
				KEY_LEFT:
					if is_instance_valid(_session_panel):
						_session_panel.nudge_range(-STROKE_RANGE_STEP, 0)
						get_viewport().set_input_as_handled()
				# Live delay nudges (±10 ms) during play: [ / ] = serial, ; / ' = intiface.
				KEY_BRACKETLEFT:
					if not _is_overlay_open:
						_nudge_serial_delay(-DELAY_STEP)
						get_viewport().set_input_as_handled()
				KEY_BRACKETRIGHT:
					if not _is_overlay_open:
						_nudge_serial_delay(DELAY_STEP)
						get_viewport().set_input_as_handled()
				KEY_SEMICOLON:
					if not _is_overlay_open:
						_nudge_intiface_delay(-DELAY_STEP)
						get_viewport().set_input_as_handled()
				KEY_APOSTROPHE:
					if not _is_overlay_open:
						_nudge_intiface_delay(DELAY_STEP)
						get_viewport().set_input_as_handled()


# ---------------------------------------------------------------------------
# Signals
# ---------------------------------------------------------------------------

# Animated HUD counters: the score/coin labels count up (or down) to their new
# value and flash a colour + scale pulse — green for a gain, red for a loss — so
# rewards feel earned and the pause-penalty drain is actually visible.
const COUNTER_DURATION: float = 0.45
const PULSE_DURATION: float = 0.35

var _score_shown: int = 0
var _coin_shown: int = 0
# Per-label [count, scale, colour] tweens, killed/replaced on each change so
# rapid score ticks chase the target instead of stacking.
var _counter_tweens: Dictionary = {}


func _on_score_changed(total: int) -> void:
	_animate_counter(_score_lbl, _score_shown, total, "%d PTS", UITheme.MAGENTA, false)
	_score_shown = total


# Rolls `lbl` from from_val→to_val with a count-up tween and a gain/loss pulse.
# `fmt` is a printf format taking one int (e.g. "%d PTS"). `instant` snaps with
# no animation (used for the initial fill so the HUD doesn't pulse on round start).
func _animate_counter(
	lbl: Label, from_val: int, to_val: int, fmt: String, base_color: Color, instant: bool
) -> void:
	for tw: Tween in _counter_tweens.get(lbl, []):
		if tw != null and tw.is_running():
			tw.kill()

	if instant or from_val == to_val:
		lbl.text = fmt % to_val
		lbl.scale = Vector2.ONE
		lbl.add_theme_color_override("font_color", base_color)
		_counter_tweens[lbl] = []
		return

	var pulse_color: Color = UITheme.OK if to_val > from_val else UITheme.DANGER

	var count_tw: Tween = create_tween()
	(
		count_tw
		. tween_method(
			_set_counter_text.bind(lbl, fmt), float(from_val), float(to_val), COUNTER_DURATION
		)
		. set_trans(Tween.TRANS_CUBIC)
		. set_ease(Tween.EASE_OUT)
	)

	lbl.pivot_offset = lbl.size / 2.0
	var scale_tw: Tween = create_tween()
	(
		scale_tw
		. tween_property(lbl, "scale", Vector2(1.12, 1.12), 0.10)
		. set_trans(Tween.TRANS_BACK)
		. set_ease(Tween.EASE_OUT)
	)
	(
		scale_tw
		. tween_property(lbl, "scale", Vector2.ONE, PULSE_DURATION - 0.10)
		. set_trans(Tween.TRANS_CUBIC)
		. set_ease(Tween.EASE_IN)
	)

	lbl.add_theme_color_override("font_color", pulse_color)
	var color_tw: Tween = create_tween()
	color_tw.tween_method(_set_counter_color.bind(lbl), pulse_color, base_color, PULSE_DURATION)

	_counter_tweens[lbl] = [count_tw, scale_tw, color_tw]


func _set_counter_text(value: float, lbl: Label, fmt: String) -> void:
	lbl.text = fmt % int(round(value))


func _set_counter_color(c: Color, lbl: Label) -> void:
	lbl.add_theme_color_override("font_color", c)


func _connect_signals() -> void:
	_video.finished.connect(_on_round_ended)
	_end_timer.timeout.connect(_on_round_ended)
	_pause_btn.pressed.connect(_toggle_pause)
	_menu_btn.pressed.connect(_go_to_menu)
	_hide_timer.timeout.connect(_on_hide_timer_timeout)
	_pause_btn.mouse_entered.connect(_show_hud)
	_menu_btn.mouse_entered.connect(_show_hud)
	_options_btn.pressed.connect(_on_options_pressed)
	_options_btn.mouse_entered.connect(_show_hud)
	_inv_btn.pressed.connect(_on_inventory_pressed)
	_inv_btn.mouse_entered.connect(_show_hud)
	ScoreService.ScoreChanged.connect(_on_score_changed)
	CoinService.BalanceChanged.connect(_on_coin_balance_changed)
	InventoryService.ActiveEffectsChanged.connect(_refresh_effect_chips)
	# save_now utility item: writes a save mid-round so the player can resume
	# from the start of this round if they quit later. Doesn't end the run.
	InventoryService.connect("SaveRequested", _on_save_item_used)

	# Device-connection signals — surface a banner when the currently selected
	# output device drops its connection, and clear it on reconnect. We watch
	# both backends so an output-mode change in Options mid-game picks up the
	# correct state via _refresh_device_warning(). DeviceAdded / DeviceRemoved
	# matter independently of Connected/Disconnected: a device can drop
	# (battery, Bluetooth, USB unplug) while Intiface itself stays running.
	ButtplugService.connect("Connected", _refresh_device_warning)
	ButtplugService.connect("Disconnected", _refresh_device_warning)
	ButtplugService.connect(
		"DeviceAdded", func(_n: String, _i: int) -> void: _refresh_device_warning()
	)
	ButtplugService.connect("DeviceRemoved", func(_i: int) -> void: _refresh_device_warning())
	SerialDeviceService.connect("Connected", _refresh_device_warning)
	SerialDeviceService.connect("Disconnected", _refresh_device_warning)
	_refresh_device_warning()


# ---------------------------------------------------------------------------
# Device connection state
# ---------------------------------------------------------------------------


# Updates the disconnect banner to reflect the currently selected output mode
# and the relevant connection state. Called from connect/disconnect/device
# signals on both backends, plus once at startup so a session that's already
# in a bad state when the game scene loads still shows the warning.
#
# Buttplug has three distinct states the banner distinguishes:
#   • Intiface itself is not connected → reconnect Intiface in Options.
#   • Intiface connected but no device available → the device has dropped
#     (battery, Bluetooth, USB unplug). Power it on / re-pair it.
#   • The user has a specific device selected from a prior session, that
#     device isn't present, BUT a different device IS — commands are silently
#     going to the fallback device. Tell the user about the mismatch so they
#     either connect their preferred device or update their selection.
# Serial has only one failure mode (port closed) — message stays simple.
#
# Hidden when: the selected backend has a device AND either the user has no
# specific preference (selected_device is empty) or the selected one is
# present.
func _refresh_device_warning() -> void:
	if _device_warning_banner == null:
		return
	# A device is "present" if serial is connected or Intiface has a live device. Multi-device makes
	# "which device" fuzzy, so this is a general presence check across both backends.
	var serial_up: bool = SerialDeviceService.SerialConnected
	var bp_up: bool = ButtplugService.BpConnected and ButtplugService.GetActiveDeviceName() != ""
	if serial_up or bp_up:
		_device_ever_seen = true
		_device_warning_banner.visible = false
		return
	# Nothing connected right now. Only warn if a device WAS present this run — so a funscript-only
	# session with no toy never nags — and the banner clears itself the moment a device returns.
	if _device_ever_seen:
		_device_warning_label.text = "●  DEVICE DISCONNECTED  —  RECONNECT IN OPTIONS"
		_device_warning_banner.visible = true
	else:
		_device_warning_banner.visible = false


func _nudge_serial_delay(delta: int) -> void:
	var v: int = clampi(SettingsService.get_serial_delay_ms() + delta, -500, 500)
	SettingsService.set_serial_delay_ms(v)
	SettingsService.save()
	FunscriptPlayer.SetSerialDelay(v)
	_show_delay_toast("Serial delay  %d ms" % v)
	if is_instance_valid(_session_panel):
		_session_panel.resync()


func _nudge_intiface_delay(delta: int) -> void:
	var v: int = clampi(SettingsService.get_intiface_delay_ms() + delta, -500, 500)
	SettingsService.set_intiface_delay_ms(v)
	SettingsService.save()
	FunscriptPlayer.SetIntifaceDelay(v)
	_show_delay_toast("Intiface delay  %d ms" % v)
	if is_instance_valid(_session_panel):
		_session_panel.resync()


# Brief, reusable on-screen readout for the delay hotkeys (no label spam on rapid presses).
func _show_delay_toast(text: String) -> void:
	if not is_instance_valid(_delay_toast):
		_delay_toast = Label.new()
		_delay_toast.add_theme_font_size_override("font_size", 20)
		_delay_toast.add_theme_color_override("font_color", UITheme.CYAN)
		_delay_toast.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_delay_toast.anchor_left = 0.0
		_delay_toast.anchor_right = 1.0
		_delay_toast.anchor_top = 0.12
		_delay_toast.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(_delay_toast)
	_delay_toast.text = text
	_delay_toast.modulate.a = 1.0
	if _delay_toast_tween != null and _delay_toast_tween.is_valid():
		_delay_toast_tween.kill()
	_delay_toast_tween = create_tween()
	_delay_toast_tween.tween_interval(0.8)
	_delay_toast_tween.tween_property(_delay_toast, "modulate:a", 0.0, 0.4)


# ---------------------------------------------------------------------------
# Inventory / coins / effect chips
# ---------------------------------------------------------------------------


func _on_inventory_pressed() -> void:
	if is_instance_valid(_inventory_panel):
		_inventory_panel.close()
		return
	# Mutually exclusive with the Quick Settings drawer.
	if is_instance_valid(_session_panel):
		_session_panel.close()
	_inventory_panel = InventoryPanelScene.instantiate()
	_inventory_panel.closed.connect(_on_inventory_closed)
	add_child(_inventory_panel)


func _on_inventory_closed() -> void:
	_inventory_panel = null


func _on_coin_balance_changed(_balance: int) -> void:
	_refresh_coin_label()


# `instant` snaps to the balance with no count-up/pulse — used for the initial
# HUD fill during setup so the coins don't pulse before the run begins.
func _refresh_coin_label(instant: bool = false) -> void:
	var balance: int = CoinService.Balance
	_animate_counter(_coin_lbl, _coin_shown, balance, "♦ %d", UITheme.AMBER, instant)
	_coin_shown = balance


func _refresh_effect_chips() -> void:
	for child in _chips_row.get_children():
		child.queue_free()
	var has_blackout: bool = false
	for effect: Dictionary in InventoryService.GetActiveEffects():
		_chips_row.add_child(_make_chip(effect))
		if effect.get("kind", "") == "blackout":
			has_blackout = true
	_video.visible = not has_blackout


func _make_chip(effect: Dictionary) -> Control:
	# Boons green, curses / boss modifiers red, player-activated shop items amber.
	var accent: Color
	if effect.get("benefit", false):
		accent = UITheme.SUCCESS
	elif effect.get("boss", false):
		accent = UITheme.DANGER
	else:
		accent = UITheme.AMBER
	var chip: PanelContainer = PanelContainer.new()
	var s: StyleBoxFlat = StyleBoxFlat.new()
	s.bg_color = Color(accent.r, accent.g, accent.b, 0.12)
	s.border_color = accent
	s.border_width_left = 1
	s.border_width_right = 1
	s.border_width_top = 1
	s.border_width_bottom = 1
	s.content_margin_left = 10
	s.content_margin_right = 10
	s.content_margin_top = 4
	s.content_margin_bottom = 4
	chip.add_theme_stylebox_override("panel", s)

	var lbl: Label = Label.new()
	lbl.add_theme_color_override("font_color", accent)
	lbl.add_theme_font_size_override("font_size", 11)
	lbl.set_meta("effect_id", effect.get("id", ""))
	_update_chip_text(lbl, effect)
	chip.add_child(lbl)
	chip.set_meta("chip_label", lbl)
	return chip


func _update_chip_text(lbl: Label, effect: Dictionary) -> void:
	var name_str: String = (effect.get("name", "") as String).to_upper()
	# Boss forced modifiers last the whole round — no countdown.
	if effect.get("boss", false):
		lbl.text = name_str
		return
	var remaining: float = InventoryService.GetRemainingSeconds(effect)
	lbl.text = "%s  %ds" % [name_str, int(ceil(remaining))]


func _update_chip_countdowns() -> void:
	var effects: Array = InventoryService.GetActiveEffects()
	if effects.size() != _chips_row.get_child_count():
		_refresh_effect_chips()
		return
	for i in effects.size():
		var chip: Node = _chips_row.get_child(i)
		var lbl: Label = chip.get_meta("chip_label", null)
		if lbl != null:
			_update_chip_text(lbl, effects[i])


# ---------------------------------------------------------------------------
# Layout
# ---------------------------------------------------------------------------


func _apply_layout() -> void:
	anchor_right = 1.0
	anchor_bottom = 1.0

	_bg.anchor_right = 1.0
	_bg.anchor_bottom = 1.0
	_bg.offset_left = 0
	_bg.offset_top = 0
	_bg.offset_right = 0
	_bg.offset_bottom = 0

	_video.anchor_left = 0.0
	_video.anchor_top = 0.0
	_video.anchor_right = 0.0
	_video.anchor_bottom = 0.0
	_video.offset_left = 0
	_video.offset_top = 0
	_video.offset_right = 0
	_video.offset_bottom = 0
	_video.position = Vector2.ZERO
	_video.size = get_viewport_rect().size

	_hud.anchor_right = 1.0
	_hud.anchor_bottom = 1.0

	_hud_bar.anchor_left = 0.0
	_hud_bar.anchor_right = 1.0
	_hud_bar.anchor_top = 1.0
	_hud_bar.anchor_bottom = 1.0
	_hud_bar.offset_top = -HUD_BAR_HEIGHT
	_hud_bar.offset_bottom = 0

	_hud_layout.add_theme_constant_override("separation", 16)
	_round_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	# Progress bar — centered thin strip at the very bottom of the screen
	_progress.anchor_left = 0.1
	_progress.anchor_right = 0.9
	_progress.anchor_top = 1.0
	_progress.anchor_bottom = 1.0
	_progress.offset_left = 0
	_progress.offset_right = 0
	_progress.offset_top = -7
	_progress.offset_bottom = -1

	# Effect chips — row pinned just above the progress bar, centred.
	_chips_row.anchor_left = 0.0
	_chips_row.anchor_right = 1.0
	_chips_row.anchor_top = 1.0
	_chips_row.anchor_bottom = 1.0
	_chips_row.offset_top = -42
	_chips_row.offset_bottom = -12
	_chips_row.alignment = BoxContainer.ALIGNMENT_CENTER
	_chips_row.add_theme_constant_override("separation", 8)
	_chips_row.mouse_filter = Control.MOUSE_FILTER_IGNORE

	# Device-disconnected banner — pinned to the top edge of the viewport,
	# centred horizontally, hidden by default. Lives outside _hud so the
	# auto-hide timer doesn't fade it away.
	_device_warning_banner = PanelContainer.new()
	_device_warning_banner.anchor_left = 0.5
	_device_warning_banner.anchor_right = 0.5
	_device_warning_banner.anchor_top = 0.0
	_device_warning_banner.anchor_bottom = 0.0
	_device_warning_banner.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_device_warning_banner.offset_top = 12
	_device_warning_banner.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_device_warning_banner.visible = false
	add_child(_device_warning_banner)

	var banner_style: StyleBoxFlat = StyleBoxFlat.new()
	banner_style.bg_color = Color(
		UITheme.ERROR_SOFT.r, UITheme.ERROR_SOFT.g, UITheme.ERROR_SOFT.b, 0.92
	)
	banner_style.border_color = UITheme.ERROR_SOFT
	banner_style.border_width_left = 2
	banner_style.border_width_right = 2
	banner_style.border_width_top = 2
	banner_style.border_width_bottom = 2
	banner_style.content_margin_left = 18
	banner_style.content_margin_right = 18
	banner_style.content_margin_top = 8
	banner_style.content_margin_bottom = 8
	banner_style.corner_radius_top_left = 6
	banner_style.corner_radius_top_right = 6
	banner_style.corner_radius_bottom_left = 6
	banner_style.corner_radius_bottom_right = 6
	_device_warning_banner.add_theme_stylebox_override("panel", banner_style)

	_device_warning_label = Label.new()
	_device_warning_label.add_theme_color_override("font_color", UITheme.WHITE_SOFT)
	_device_warning_label.add_theme_font_size_override("font_size", 13)
	_device_warning_label.uppercase = true
	_device_warning_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_device_warning_banner.add_child(_device_warning_label)


# ---------------------------------------------------------------------------
# Theme
# ---------------------------------------------------------------------------


func _apply_theme() -> void:
	_bg.color = UITheme.BG

	var bar_style: StyleBoxFlat = StyleBoxFlat.new()
	bar_style.bg_color = UITheme.PANEL_BG_GAME
	bar_style.border_color = UITheme.PURPLE_BRIGHT
	bar_style.border_width_top = 1
	bar_style.content_margin_left = 20
	bar_style.content_margin_right = 20
	bar_style.content_margin_top = 14
	bar_style.content_margin_bottom = 14
	_hud_bar.add_theme_stylebox_override("panel", bar_style)

	_round_lbl.add_theme_color_override("font_color", UITheme.WHITE_SOFT)
	_round_lbl.add_theme_font_size_override("font_size", 13)
	_round_lbl.uppercase = true

	_score_lbl.add_theme_color_override("font_color", UITheme.MAGENTA)
	_score_lbl.add_theme_font_size_override("font_size", 13)
	_score_lbl.uppercase = true

	_coin_lbl.add_theme_color_override("font_color", UITheme.AMBER)
	_coin_lbl.add_theme_font_size_override("font_size", 13)
	_coin_lbl.uppercase = true

	_style_progress()
	_style_button(_pause_btn, UITheme.PURPLE_BRIGHT)
	_style_button(_inv_btn, UITheme.AMBER)
	_style_button(_menu_btn, UITheme.MAGENTA)
	_style_button(_options_btn, UITheme.PURPLE_MID)


# Thin delegate to UITheme — the canonical styling lives there.
func _style_button(btn: Button, accent: Color) -> void:
	UITheme.style_button_subtle(btn, accent, 14, 8, 13, true)


func _style_progress() -> void:
	var bg: StyleBoxFlat = StyleBoxFlat.new()
	bg.bg_color = Color(0.08, 0.0, 0.12, 0.8)
	bg.corner_radius_top_left = 4
	bg.corner_radius_top_right = 4
	bg.corner_radius_bottom_left = 4
	bg.corner_radius_bottom_right = 4

	var fill: StyleBoxFlat = StyleBoxFlat.new()
	fill.bg_color = UITheme.PURPLE_BRIGHT
	fill.corner_radius_top_left = 4
	fill.corner_radius_top_right = 4
	fill.corner_radius_bottom_left = 4
	fill.corner_radius_bottom_right = 4

	_progress.add_theme_stylebox_override("background", bg)
	_progress.add_theme_stylebox_override("fill", fill)
	_progress.min_value = 0.0
	_progress.max_value = 1.0
	_progress.show_percentage = false
