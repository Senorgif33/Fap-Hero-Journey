extends Control

const OptionsScene         = preload("res://scenes/options/Options.tscn")
const ForkScene            = preload("res://scenes/fork_screen/ForkScreen.tscn")
const ShopScene            = preload("res://scenes/shop_screen/ShopScreen.tscn")
const StoryboardScene      = preload("res://scenes/storyboard_screen/StoryboardScreen.tscn")
const InventoryPanelScene  = preload("res://scenes/inventory/InventoryPanel.tscn")
const BeatBarScript        = preload("res://scripts/game_loop/BeatBar.gd")

# ---------------------------------------------------------------------------
# GameLoop.gd  –  Round controller and video player
# Reads the active journey from GameState, loads each round's video and
# funscript in sequence, then transitions to EndScreen when all rounds finish.
#
# MP4 NOTE: Godot's built-in VideoStreamPlayer only decodes .ogv (Theora).
# Install EIRTeam.FFmpeg GDExtension for MP4 support, then replace the
# _load_video() body with that extension's API.
# ---------------------------------------------------------------------------

const HUD_BAR_HEIGHT:  int   = 68
# Playback-capable formats. Intentionally distinct from JourneyData.VIDEO_EXTENSIONS
# (the import/transcode set): includes "ogv" (Godot-native, no FFmpeg needed) and
# omits container types that only matter at import time.
const VIDEO_EXTS:      Array = ["mp4", "mkv", "webm", "avi", "mov", "ogv"]

# Sequence-boundary fade timings (~1.2s total).
const TRANSITION_FADE_TIME: float = 0.45
const TRANSITION_HOLD_TIME: float = 0.30

# Boss rounds: the red frame pulses during the round's final stretch.
const BOSS_CLIMAX_SECS: float = 30.0
# Boss forced-modifier kind → HUD chip label.
const BOSS_EFFECT_NAMES: Dictionary = {
	"scale":            "SCALE",
	"clamp":            "CLAMP",
	"reverse":          "REVERSE",
	"blackout":         "BLACKOUT",
	"score_multiplier": "SCORE ×",
}

@onready var _bg:          ColorRect         = $Background
@onready var _video:       VideoStreamPlayer = $VideoPlayer
@onready var _hud:         Control           = $HUD
@onready var _hud_bar:     PanelContainer    = $HUD/HUDBar
@onready var _hud_layout:  HBoxContainer     = $HUD/HUDBar/HUDLayout
@onready var _round_lbl:   Label             = $HUD/HUDBar/HUDLayout/RoundLabel
@onready var _coin_lbl:    Label             = $HUD/HUDBar/HUDLayout/CoinLabel
@onready var _progress:    ProgressBar       = $HUD/ProgressBar
@onready var _score_lbl:   Label             = $HUD/HUDBar/HUDLayout/ScoreLabel
@onready var _pause_btn:   Button            = $HUD/HUDBar/HUDLayout/PauseBtn
@onready var _inv_btn:     Button            = $HUD/HUDBar/HUDLayout/InventoryBtn
@onready var _menu_btn:    Button            = $HUD/HUDBar/HUDLayout/MenuBtn
@onready var _options_btn: Button            = $HUD/HUDBar/HUDLayout/OptionsBtn
@onready var _chips_row:   HBoxContainer     = $HUD/EffectChipsRow
@onready var _hide_timer:  Timer             = $HUD/HideTimer

# Persistent banner shown at top of screen whenever the *currently selected*
# output device drops its connection during play. Built dynamically in
# _apply_layout so the scene file doesn't need a new node. Lives outside the
# auto-hiding HUD so it stays visible even when the rest of the HUD fades.
var _device_warning_banner: PanelContainer = null
var _device_warning_label:  Label          = null
@onready var _end_timer:   Timer             = $EndTimer
@onready var _transition:  ColorRect         = $TransitionLayer/TransitionOverlay

var _paused: bool = false
var _inventory_panel: Control = null

# True while a full-screen overlay (shop / fork / storyboard) is active.
# Used to suppress gameplay hotkeys that should not fire through an overlay.
var _is_overlay_open: bool = false
# The current full-screen overlay (storyboard / shop / fork), or null. It is
# freed by the transition (after the black covers it), not by itself — see
# _transition_swap.
var _current_overlay: Control = null

# True for the duration of a boss round (set when the round loads, cleared at
# round end). Drives item lockout, the red frame, and the climax pulse.
var _is_boss_round: bool  = false
var _boss_frame:    Panel = null

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

var _curse_frame:   Panel     = null  # green "hex" border (cursed counterpart to _boss_frame)
var _curse_tint:    ColorRect = null  # faint sickly tint over the play area
var _curse_murk:    ColorRect = null  # "Murk" — dims the screen
var _curse_strobe:  ColorRect = null  # "Strobe" — flickering black overlay
var _curse_tunnel:  TextureRect = null  # "Tunnel" — closing vignette
var _curse_bloodshot: ColorRect = null  # "Bloodshot" — pulsing red haze
var _curse_static:    ColorRect = null  # "Interference" — animated TV static
var _curse_flicker:   ColorRect = null  # "Flicker" — erratic brightness dips
var _video_fx_mat:    ShaderMaterial = null  # composable per-pixel video effects (Drained/Bleary/Censored/…)
var _strobe_tween:    Tween     = null
var _bloodshot_tween: Tween     = null
var _flicker_tween:   Tween     = null
var _volwobble_tween: Tween     = null
var _curse_tremor:    bool      = false  # "Tremor" — shakes the video each frame
var _curse_tremor_amp: float    = 9.0    # Tremor shake amplitude (set from intensity)
var _curse_tunnel_grad: Gradient = null  # Tunnel vignette gradient (mid point set from intensity)
const VIDEO_FX_BUS: String = "VideoFX"  # dedicated audio bus for hex audio effects
var _curse_hud_hidden: bool   = false  # a "Fog" hex hid the HUD for this round
var _curse_muted:      bool   = false  # a "Silence" hex muted the video this round
var _curse_no_pause:   bool   = false  # a "Restless" hex disabled pausing this round
var _pre_curse_volume_db: float = 0.0  # restored when a "Silence" hex ends
const TOLL_AMOUNT: int = 40  # coins a "Toll" hex takes immediately

# Blessed round — the positive mirror of cursed. Applies boon(s) from
# JourneyData.BLESSING_CATALOG (gold frame, no cleanse/cost). Some boons carry
# state: Ward shields the next curse, Lingering freezes the effect clock.
var _is_blessed_round:  bool      = false
var _blessing_frame:    Panel     = null  # gold frame
var _blessing_tint:     ColorRect = null  # faint gold tint
var _ward_next_curse:   bool      = false  # a "Ward" boon repels the next curse
var _blessing_lingering: bool     = false  # a "Lingering" boon froze the effect clock
const INTEREST_PCT: float = 0.25  # "Interest" boon pays this fraction of the coin balance
# Effects to show on the pre-round reveal card for a cursed/blessed round. Each:
# {name, desc, benefit:bool}. Empty = no card (normal/boss rounds, warded curse).
var _reveal_effects: Array = []
const REVEAL_HOLD_SECS: float = 2.6
# Cleanse / endure decision: pay to lift the curse mid-round, or endure it to the
# end for the round's curse_reward bonus. Its own floating button (not in the HUD,
# so a Fog hex can't lock the player out of cleansing).
var _curse_cleansed:    bool   = false
var _curse_cleanse_btn: Button = null
var _curse_cleanse_cost: int   = CLEANSE_COST_DEFAULT  # per-round, set on curse enter

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


func _ready() -> void:
	MusicService.stop()
	_setup_audio_fx_bus()
	_apply_layout()
	_apply_theme()
	_build_boss_frame()
	_build_curse_overlay()
	_build_beat_bar()
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
		GameState.remove_meta("_test_mode")
		GameState.remove_meta("_test_return_journey")
		GameState.remove_meta("_test_seed_score")
		GameState.remove_meta("_test_seed_coins")

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
	_refresh_coin_label()
	_load_current_item()
	_show_hud()
	if _test_mode:
		_show_test_banner()

	# Re-fit the video whenever the logical viewport changes. This fires on
	# window resize, fullscreen toggle, resolution change, AND UI-scale
	# (content_scale_factor) change — so the video tracks all of them, including
	# while paused.
	get_viewport().size_changed.connect(_fit_video_cover)


func _process(_delta: float) -> void:
	if _video.is_playing():
		var len: float = _video.get_stream_length()
		if len > 0.0:
			_progress.value = _video.stream_position / len
		# Keep funscript in sync with video clock
		FunscriptPlayer.SyncTo(_video.stream_position)
		# Re-fit every frame: cheap, and keeps the video covering the screen even
		# if the viewport or UI scale changes mid-playback.
		_fit_video_cover()
	_update_chip_countdowns()
	if _is_boss_round:
		_update_boss_frame()
	elif _is_cursed_round:
		_update_curse_frame()
	elif _is_blessed_round:
		_update_blessing_frame()
	if _beat_bar != null:
		_beat_bar.set_time(FunscriptPlayer.PositionMs)


# Leaving the game loop (Esc out of a test, journey complete, etc.) — strip any
# audio effects off the global VideoFX bus so they don't bleed into the next run
# or anything else routed through it.
func _exit_tree() -> void:
	_stop_volwobble()
	_clear_audio_effects()


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
	storyboard.completed.connect(_on_storyboard_completed)
	add_child(storyboard)
	_current_overlay = storyboard
	storyboard.setup(sb_data)


func _start_storyboard_filler() -> void:
	if not SettingsService.get_filler_enabled():
		return
	FunscriptPlayer.StartFiller(
		SettingsService.get_filler_lo(),
		SettingsService.get_filler_hi(),
		SettingsService.get_filler_half_cycle_ms())


func _on_storyboard_completed(coins: int) -> void:
	FunscriptPlayer.StopFiller()
	_is_overlay_open = false
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
	await _transition_swap(func() -> void:
		_video.paused = false
		FunscriptPlayer.Resume()
		_load_current_item()
	)


func _show_shop_screen(shop_data: Dictionary) -> void:
	_is_overlay_open = true
	_video.paused = true
	FunscriptPlayer.Pause()
	var shop: Control = ShopScene.instantiate()
	shop.closed.connect(_on_shop_closed)
	add_child(shop)
	_current_overlay = shop
	shop.setup(shop_data)


func _on_shop_closed() -> void:
	_is_overlay_open = false
	GameState.Advance()
	if GameState.IsSequenceDone():
		_transition_to_end_screen()
		return
	await _transition_swap(func() -> void:
		_video.paused = false
		FunscriptPlayer.Resume()
		_load_current_item()
	)


func _show_fork_screen(fork_data: Dictionary) -> void:
	_is_overlay_open = true
	_video.paused = true
	FunscriptPlayer.Pause()
	var fork_screen = ForkScene.instantiate()
	fork_screen.path_chosen.connect(_on_fork_path_chosen)
	add_child(fork_screen)
	_current_overlay = fork_screen
	fork_screen.setup(fork_data)

	# Auto-resolved fork types pick a path and play a reveal instead of waiting
	# for the player. (Sacrifice stays interactive — the player picks & pays.)
	match fork_data.get("resolution", "choice"):
		"random":
			fork_screen.reveal(_weighted_random_path(fork_data.get("paths", [])))
		"conditional":
			fork_screen.reveal(_conditional_path(fork_data), _conditional_caption(fork_data))


# Picks a path index by weight (per-path "weight", default 1). Zero/negative
# weights are treated as 0; if every weight is 0, all paths are equally likely.
func _weighted_random_path(paths: Array) -> int:
	if paths.is_empty():
		return 0
	var total: int = 0
	for p: Dictionary in paths:
		total += maxi(0, int(p.get("weight", 1)))
	if total <= 0:
		return randi() % paths.size()
	var r: int = randi() % total
	var acc: int = 0
	for i in paths.size():
		acc += maxi(0, int(paths[i].get("weight", 1)))
		if r < acc:
			return i
	return paths.size() - 1


# Resolves a conditional fork to a path index. Score/coins use tiered thresholds
# (highest one the value meets wins). Item checks ownership top-down (NOT
# consumed). Falls back to the author's default path when nothing matches.
func _conditional_path(fork_data: Dictionary) -> int:
	var paths: Array = fork_data.get("paths", [])
	if paths.is_empty():
		return 0
	var default_idx: int = clampi(int(fork_data.get("default_path", 0)), 0, paths.size() - 1)
	var metric: String = fork_data.get("cond_metric", "score")

	if metric == "item":
		for i in paths.size():
			var req: String = str(paths[i].get("required_item", ""))
			if req != "" and InventoryService.OwnsItem(req):
				return i
		return default_idx

	# score / coins → highest met threshold wins.
	var value: int = ScoreService.LastRoundScore if metric == "score" else CoinService.Balance
	var best_idx: int = -1
	var best_threshold: int = -1
	for i in paths.size():
		var t: int = int(paths[i].get("threshold", 0))
		if value >= t and t > best_threshold:
			best_threshold = t
			best_idx = i
	return best_idx if best_idx >= 0 else default_idx


# Flavour text shown during a conditional fork's reveal, per metric.
func _conditional_caption(fork_data: Dictionary) -> String:
	match fork_data.get("cond_metric", "score"):
		"score":
			return "BY YOUR SCORE…"
		"coins":
			return "BY YOUR COINS…"
		"item":
			return "BY WHAT YOU CARRY…"
	return "FATE DECIDES…"


func _on_fork_path_chosen(path_index: int) -> void:
	_is_overlay_open = false
	GameState.ResolveFork(path_index)
	await _transition_swap(func() -> void:
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
	var num:   int = GameState.RoundNumber

	_progress.value = 0.0
	_paused = false
	_pause_btn.text = "|| PAUSE"

	var rtype: String = round.get("round_type", "normal")
	_is_boss_round = rtype == "boss"
	_is_cursed_round = rtype == "cursed"
	_is_blessed_round = rtype == "blessed"
	if _is_boss_round:
		_round_lbl.text = "⚔  BOSS  %d / %d  —  %s" % [num, total,
			(round.get("name", "") as String).to_upper()]
	else:
		var prefix: String = "ROUND"
		if _is_cursed_round:
			prefix = "☠  CURSED"
		elif _is_blessed_round:
			prefix = "✦  BLESSED"
		_round_lbl.text = "%s %d / %d  —  %s" % [prefix, num, total,
			(round.get("name", "") as String).to_upper()]

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

	var folder: String = round.get("folder", "")
	var video_path: String = _find_video(folder)
	_load_video(video_path)


# ---------------------------------------------------------------------------
# Checkpoint rounds
# ---------------------------------------------------------------------------

# CHECKPOINT REACHED banner shown at the start of any round the author marked
# as a checkpoint. Two buttons: Save & Quit (writes a save + returns to
# catalogue) or Continue (dismisses the banner and starts the round normally).
# Pattern mirrors _show_boss_intro since both gate round start on user input.
func _show_checkpoint_banner(round: Dictionary) -> void:
	_is_overlay_open = true   # suppress gameplay hotkeys while the banner is up

	var parts: Dictionary    = UITheme.build_centered_modal("◆  CHECKPOINT REACHED  ◆", UITheme.AMBER, Vector2i(620, 320))
	var modal: Control       = parts["modal"]
	var vbox:  VBoxContainer = parts["vbox"]
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
	save_btn.pressed.connect(func() -> void:
		modal.queue_free()
		_is_overlay_open = false
		_on_save_and_quit()
	)
	btn_row.add_child(save_btn)

	var continue_btn: Button = Button.new()
	continue_btn.text = "▶  CONTINUE"
	continue_btn.custom_minimum_size = Vector2(160, 0)
	UITheme.style_button(continue_btn, UITheme.PURPLE_BRIGHT)
	continue_btn.pressed.connect(func() -> void:
		modal.queue_free()
		_is_overlay_open = false
		_start_round_after_gates(round)
	)
	btn_row.add_child(continue_btn)

	add_child(modal)


# ---------------------------------------------------------------------------
# Boss rounds
# ---------------------------------------------------------------------------

# Telegraphed intro card. The round's scripts/video do not load and playback
# does not start until the player clicks BEGIN.
func _show_boss_intro(round: Dictionary) -> void:
	_is_overlay_open = true  # suppress gameplay hotkeys while the card is up

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
	ps.border_width_left = 3; ps.border_width_right = 3
	ps.border_width_top = 3; ps.border_width_bottom = 3
	ps.content_margin_left = 48; ps.content_margin_right = 48
	ps.content_margin_top = 36;  ps.content_margin_bottom = 36
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
			tex.expand_mode  = TextureRect.EXPAND_IGNORE_SIZE
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
	begin_btn.pressed.connect(func() -> void:
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
		_apply_hex(roll, _sensory_intensity(round, roll))

	# Item use is disabled for the whole boss round.
	if is_instance_valid(_inventory_panel):
		_inventory_panel.close()
	_inv_btn.disabled = true

	if _boss_frame != null:
		_boss_frame.visible    = true
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
		name_lbl.add_theme_color_override("font_color", UITheme.SUCCESS if fx.get("benefit", false) else UITheme.ERROR_SOFT)
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
	tin.tween_property(panel, "scale", Vector2.ONE, 0.3).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
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
		_reveal_effects = []     # nothing to reveal — no card
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
		var pool: Array = (JourneyData.CURSE_CATALOG if selected.is_empty()
			else _catalog_subset(JourneyData.CURSE_CATALOG, selected))
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
		_apply_hex(roll, _sensory_intensity(round, roll))  # GameLoop-side hex behaviours

	_curse_cleansed = false
	_show_curse_overlay()
	_show_cleanse_button()
	_reveal_effects = _build_reveal_effects(to_apply, false)


# Builds the reveal-card payload from a list of catalog entries.
func _build_reveal_effects(entries: Array, benefit: bool) -> Array:
	var out: Array = []
	for e: Dictionary in entries:
		out.append({
			"name":    str(e.get("name", "")),
			"desc":    str(e.get("desc", "")),
			"benefit": benefit,
		})
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
	btn.text = "✦ CLEANSE  (use Cleanse item)" if has_item else "✦ CLEANSE  (♦ %d)" % _curse_cleanse_cost
	btn.tooltip_text = "Lift the curse with a Cleanse item or %d coins — or endure it for the reward." % _curse_cleanse_cost
	UITheme.style_button(btn, Color(0.45, 0.95, 0.30))
	btn.anchor_left = 0.5; btn.anchor_right = 0.5
	btn.anchor_top = 1.0;  btn.anchor_bottom = 1.0
	btn.offset_top = -96; btn.offset_bottom = -56
	btn.offset_left = -110; btn.offset_right = 110
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


# Undoes every hex side-effect (HUD/mute/pause/visuals). Safe to call when none
# are active (boss rounds, plain rounds) — each branch no-ops.
func _clear_curse_hexes() -> void:
	_curse_hud_hidden = false
	if _curse_muted:
		_curse_muted = false
		_video.volume_db = _pre_curse_volume_db
	if _curse_no_pause:
		_curse_no_pause = false
		_pause_btn.disabled = false
	_video.visible = true  # undo a Blinded (blackout) hex
	_reset_video_fx()      # undo every per-pixel video hex (Drained/Bleary/…)
	_clear_audio_effects() # undo low-pass / reverb / distortion + restore bus level
	_stop_strobe()
	_stop_bloodshot()
	_stop_flicker()
	_stop_volwobble()
	_curse_tremor = false
	if _curse_murk != null:
		_curse_murk.visible = false
	if _curse_strobe != null:
		_curse_strobe.visible = false
	if _curse_tunnel != null:
		_curse_tunnel.visible = false
	if _curse_bloodshot != null:
		_curse_bloodshot.visible = false
	if _curse_static != null:
		_curse_static.visible = false
	if _curse_flicker != null:
		_curse_flicker.visible = false


func _start_strobe(clear_secs: float = 3.0) -> void:
	_stop_strobe()
	# Pulse to full black: <clear_secs> clear → 1s fade in → 1s black → 1s fade
	# back. Intensity shortens the clear gap (more frequent = more intense).
	_curse_strobe.modulate.a = 0.0
	_strobe_tween = create_tween().set_loops()
	_strobe_tween.tween_interval(maxf(0.2, clear_secs))
	_strobe_tween.tween_property(_curse_strobe, "modulate:a", 1.0, 1.0)
	_strobe_tween.tween_interval(1.0)
	_strobe_tween.tween_property(_curse_strobe, "modulate:a", 0.0, 1.0)


func _stop_strobe() -> void:
	if _strobe_tween != null and _strobe_tween.is_valid():
		_strobe_tween.kill()
	_strobe_tween = null
	if _curse_strobe != null:
		_curse_strobe.modulate.a = 0.0


# The real effect value for a sensory hex at the given intensity (0–1), mapped
# through the catalog entry's imin/imax. imin may exceed imax (inverted effects).
func _ival(roll: Dictionary, intensity: float) -> float:
	return lerpf(float(roll.get("imin", 0.0)), float(roll.get("imax", 1.0)), clampf(intensity, 0.0, 1.0))


# This round's intensity (0–1) for a sensory modifier: the author's per-round
# override if set, else the catalog default. Used by cursed and boss rounds.
func _sensory_intensity(round: Dictionary, entry: Dictionary) -> float:
	var overrides: Dictionary = round.get("sensory_intensity", {})
	var nm: String = str(entry.get("name", ""))
	if overrides.has(nm):
		return clampf(float(overrides[nm]), 0.0, 1.0)
	return float(entry.get("idef", 0.5))


# Moves the Tunnel vignette's mid ramp point — smaller offset = narrower clear
# centre = a tighter tunnel. (imin/imax for tunnel are offsets, not 0–1.)
func _set_tunnel_intensity(mid_offset: float) -> void:
	if _curse_tunnel_grad != null:
		_curse_tunnel_grad.set_offset(1, clampf(mid_offset, 0.05, 0.95))


# Applies a "hex" curse — effects beyond the stroke (which FunscriptPlayer can't
# do). coin_penalty is read at round end; here we handle the immediate ones. For
# non-gameplay (sensory) hexes, `intensity` (0–1) maps to the real effect value
# via the catalog's imin/imax (see _ival); other kinds ignore it.
func _apply_hex(roll: Dictionary, intensity: float = 1.0) -> void:
	match String(roll.get("kind", "")):
		"hud_hide":
			_curse_hud_hidden = true
			_hud.visible = false
		"mute":
			_curse_muted = true
			_pre_curse_volume_db = _video.volume_db
			_video.volume_db = -80.0
		"toll":
			var take: int = mini(TOLL_AMOUNT, CoinService.Balance)
			if take > 0:
				CoinService.SpendCoins(take)
		"murk":
			if _curse_murk != null:
				_curse_murk.color.a = _ival(roll, intensity)
				_curse_murk.visible = true
		"tunnel":
			if _curse_tunnel != null:
				_set_tunnel_intensity(_ival(roll, intensity))
				_curse_tunnel.visible = true
		"strobe":
			if _curse_strobe != null:
				_curse_strobe.visible = true
				_start_strobe(_ival(roll, intensity))
		"no_pause":
			_curse_no_pause = true
			_pause_btn.disabled = true
		# Per-pixel video hexes — one composable shader, one uniform each.
		"grayscale":
			_set_video_fx("grayscale", _ival(roll, intensity))
		"blur":
			_set_video_fx("blur", _ival(roll, intensity))
		"pixelate":
			_set_video_fx("pixelate", _ival(roll, intensity))
		"invert":
			_set_video_fx("invert", _ival(roll, intensity))
		"sepia":
			_set_video_fx("sepia", _ival(roll, intensity))
		"posterize":
			_set_video_fx("posterize", _ival(roll, intensity))
		"saturate":
			_set_video_fx("saturation", _ival(roll, intensity))
		"chromatic":
			_set_video_fx("chromatic", _ival(roll, intensity))
		"wave":
			_set_video_fx("wave", _ival(roll, intensity))
		# Overlay-node visual hexes.
		"bloodshot":
			if _curse_bloodshot != null:
				_curse_bloodshot.visible = true
				_start_bloodshot(_ival(roll, intensity))
		"static":
			if _curse_static != null:
				if _curse_static.material != null:
					(_curse_static.material as ShaderMaterial).set_shader_parameter("strength", _ival(roll, intensity))
				_curse_static.visible = true
		"flicker":
			if _curse_flicker != null:
				_curse_flicker.visible = true
				_start_flicker(_ival(roll, intensity))
		"tremor":
			_curse_tremor_amp = _ival(roll, intensity)
			_curse_tremor = true
		# Audio hexes — bus effects (Faltering wobbles the bus level).
		"lowpass":
			var lp: AudioEffectLowPassFilter = AudioEffectLowPassFilter.new()
			lp.cutoff_hz = _ival(roll, intensity)
			_add_audio_effect(lp)
		"reverb":
			var rv: AudioEffectReverb = AudioEffectReverb.new()
			rv.wet = _ival(roll, intensity)            # imin/imax = wet range
			rv.room_size = lerpf(0.6, 0.95, clampf(intensity, 0.0, 1.0))
			rv.dry = 0.5
			_add_audio_effect(rv)
		"distort":
			var ds: AudioEffectDistortion = AudioEffectDistortion.new()
			ds.mode = AudioEffectDistortion.MODE_CLIP
			ds.drive = _ival(roll, intensity)
			ds.post_gain = -10.0
			_add_audio_effect(ds)
		"volwobble":
			_start_volwobble(_ival(roll, intensity))


# Transient curse flash naming the rolled affliction.
func _show_curse_banner(curse_name: String) -> void:
	var banner: Label = Label.new()
	banner.text = "☠  CURSED  —  %s" % (curse_name as String).to_upper()
	banner.add_theme_color_override("font_color", UITheme.ERROR_SOFT)
	banner.add_theme_font_size_override("font_size", 30)
	banner.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	banner.anchor_left   = 0.0
	banner.anchor_right  = 1.0
	banner.anchor_top    = 0.35
	banner.mouse_filter  = Control.MOUSE_FILTER_IGNORE
	banner.modulate.a    = 0.0
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
		"id":   "boss_" + kind,
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
	_beat_bar.anchor_left   = 0.0
	_beat_bar.anchor_right  = 1.0
	_beat_bar.anchor_top    = 1.0
	_beat_bar.anchor_bottom = 1.0
	_beat_bar.offset_left   = 0.0
	_beat_bar.offset_right  = 0.0
	_beat_bar.offset_top    = -120.0
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
	s.border_width_left = 6; s.border_width_right  = 6
	s.border_width_top  = 6; s.border_width_bottom = 6
	_boss_frame.add_theme_stylebox_override("panel", s)
	add_child(_boss_frame)


# One composable canvas_item shader for every per-pixel video hex. Each effect is
# a uniform defaulting to identity (off); multiple can be on at once. Applied to
# the video node only, so the HUD/frames keep their colour.
const VIDEO_FX_SHADER: String = """
shader_type canvas_item;

uniform float grayscale = 0.0;
uniform float invert = 0.0;
uniform float sepia = 0.0;
uniform float saturation = 1.0;
uniform float posterize = 0.0;   // 0 = off, else number of colour levels
uniform float blur = 0.0;        // 0 = off, else texel radius
uniform float pixelate = 0.0;    // 0 = off, else blocks across the width
uniform float chromatic = 0.0;   // 0 = off, else channel UV offset
uniform float wave = 0.0;        // 0 = off, else ripple amplitude in UV

void fragment() {
	vec2 uv = UV;

	if (wave > 0.0) {
		uv.x += sin(uv.y * 28.0 + TIME * 3.0) * wave;
		uv.y += cos(uv.x * 24.0 + TIME * 2.3) * wave;
	}

	if (pixelate > 0.0) {
		float ar = TEXTURE_PIXEL_SIZE.y / TEXTURE_PIXEL_SIZE.x;
		vec2 grid = vec2(pixelate, max(1.0, pixelate / ar));
		uv = (floor(uv * grid) + 0.5) / grid;
	}

	vec4 col;
	if (chromatic > 0.0) {
		col.r = texture(TEXTURE, uv + vec2(chromatic, 0.0)).r;
		col.g = texture(TEXTURE, uv).g;
		col.b = texture(TEXTURE, uv - vec2(chromatic, 0.0)).b;
		col.a = texture(TEXTURE, uv).a;
	} else if (blur > 0.0) {
		vec2 t = TEXTURE_PIXEL_SIZE * blur;
		vec4 s = texture(TEXTURE, uv) * 2.0;
		s += texture(TEXTURE, uv + vec2(t.x, 0.0));
		s += texture(TEXTURE, uv - vec2(t.x, 0.0));
		s += texture(TEXTURE, uv + vec2(0.0, t.y));
		s += texture(TEXTURE, uv - vec2(0.0, t.y));
		s += texture(TEXTURE, uv + t);
		s += texture(TEXTURE, uv - t);
		s += texture(TEXTURE, uv + vec2(t.x, -t.y));
		s += texture(TEXTURE, uv + vec2(-t.x, t.y));
		col = s / 10.0;
	} else {
		col = texture(TEXTURE, uv);
	}

	vec3 c = col.rgb;

	if (saturation != 1.0) {
		float l = dot(c, vec3(0.299, 0.587, 0.114));
		c = mix(vec3(l), c, saturation);
	}
	if (posterize > 0.0) {
		c = floor(c * posterize) / posterize;
	}
	if (sepia > 0.0) {
		float l = dot(c, vec3(0.299, 0.587, 0.114));
		c = mix(c, vec3(l) * vec3(1.07, 0.74, 0.43), sepia);
	}
	if (grayscale > 0.0) {
		float l = dot(c, vec3(0.299, 0.587, 0.114));
		c = mix(c, vec3(l), grayscale);
	}
	if (invert > 0.0) {
		c = mix(c, vec3(1.0) - c, invert);
	}

	COLOR = vec4(c, col.a);
}
"""

# Animated TV static for the Interference hex, drawn on a full-rect overlay.
const STATIC_SHADER: String = """
shader_type canvas_item;

uniform float strength : hint_range(0.0, 1.0) = 0.30;

float rand(vec2 p) {
	return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453);
}

void fragment() {
	vec2 cell = floor(UV * vec2(480.0, 270.0));
	float n = rand(cell + vec2(fract(TIME) * 91.0, fract(TIME * 1.7) * 57.0));
	COLOR = vec4(vec3(n), strength);
}
"""


# Builds the cursed-round overlay — a sickly green "hex" border plus a faint
# tint over the play area, giving cursed rounds a distinct identity from the
# boss frame's aggressive red pulse. Hidden until a cursed round starts.
func _build_curse_overlay() -> void:
	_curse_tint = ColorRect.new()
	_curse_tint.set_anchors_preset(Control.PRESET_FULL_RECT)
	_curse_tint.color = Color(0.20, 0.45, 0.15, 0.12)  # faint toxic green
	_curse_tint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_curse_tint.visible = false
	add_child(_curse_tint)

	# Murk — a flat dark dim (a softer Blinded; you can still half-see).
	_curse_murk = ColorRect.new()
	_curse_murk.set_anchors_preset(Control.PRESET_FULL_RECT)
	_curse_murk.color = Color(0, 0, 0, 0.72)
	_curse_murk.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_curse_murk.visible = false
	add_child(_curse_murk)

	# Tunnel — a radial vignette: clear centre, dark edges.
	var grad: Gradient = Gradient.new()
	grad.set_color(0, Color(0, 0, 0, 0.0))
	grad.set_color(1, Color(0, 0, 0, 0.99))
	# Ramp the darkening inward so the clear centre is narrower and the edges
	# crush to near-black sooner — a tighter, more obtrusive tunnel.
	grad.add_point(0.45, Color(0, 0, 0, 0.40))
	_curse_tunnel_grad = grad  # kept so Tunnel intensity can move the mid ramp point
	var gtex: GradientTexture2D = GradientTexture2D.new()
	gtex.gradient  = grad
	gtex.fill      = GradientTexture2D.FILL_RADIAL
	gtex.fill_from = Vector2(0.5, 0.5)
	gtex.fill_to   = Vector2(0.5, 1.0)
	_curse_tunnel = TextureRect.new()
	_curse_tunnel.texture = gtex
	_curse_tunnel.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_curse_tunnel.stretch_mode = TextureRect.STRETCH_SCALE
	_curse_tunnel.set_anchors_preset(Control.PRESET_FULL_RECT)
	_curse_tunnel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_curse_tunnel.visible = false
	add_child(_curse_tunnel)

	# Per-pixel video hexes (Drained/Bleary/Censored/Negative/Faded/Banded/
	# Feverish/Fracture/Swoon) all ride ONE composable shader on the video node so
	# several can stack at once (double-curse / multi-hex boss). Each is a uniform,
	# default = identity; _set_video_fx flips one on, _reset_video_fx clears all.
	var fx_shader: Shader = Shader.new()
	fx_shader.code = VIDEO_FX_SHADER
	_video_fx_mat = ShaderMaterial.new()
	_video_fx_mat.shader = fx_shader
	_reset_video_fx_params()

	# Bloodshot — a red haze that pulses (animated in _start_bloodshot).
	_curse_bloodshot = ColorRect.new()
	_curse_bloodshot.set_anchors_preset(Control.PRESET_FULL_RECT)
	_curse_bloodshot.color = Color(0.6, 0.0, 0.0, 0.35)
	_curse_bloodshot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_curse_bloodshot.visible = false
	add_child(_curse_bloodshot)

	# Interference — animated TV static, generated by a noise shader on the rect.
	var static_shader: Shader = Shader.new()
	static_shader.code = STATIC_SHADER
	var static_mat: ShaderMaterial = ShaderMaterial.new()
	static_mat.shader = static_shader
	_curse_static = ColorRect.new()
	_curse_static.set_anchors_preset(Control.PRESET_FULL_RECT)
	_curse_static.material = static_mat
	_curse_static.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_curse_static.visible = false
	add_child(_curse_static)

	# Flicker — opaque black whose alpha jitters in quick dips (animated in
	# _start_flicker). Distinct from Strobe's slow full fade-to-black.
	_curse_flicker = ColorRect.new()
	_curse_flicker.set_anchors_preset(Control.PRESET_FULL_RECT)
	_curse_flicker.color = Color(0, 0, 0, 1)
	_curse_flicker.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_curse_flicker.modulate.a = 0.0
	_curse_flicker.visible = false
	add_child(_curse_flicker)

	# Strobe — opaque black whose alpha flickers (animated in _start_strobe).
	_curse_strobe = ColorRect.new()
	_curse_strobe.set_anchors_preset(Control.PRESET_FULL_RECT)
	_curse_strobe.color = Color(0, 0, 0, 1)
	_curse_strobe.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_curse_strobe.visible = false
	_curse_strobe.modulate.a = 0.0
	add_child(_curse_strobe)

	_curse_frame = Panel.new()
	_curse_frame.set_anchors_preset(Control.PRESET_FULL_RECT)
	_curse_frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_curse_frame.visible = false
	var s: StyleBoxFlat = StyleBoxFlat.new()
	s.bg_color = Color(0, 0, 0, 0)
	s.border_color = Color(0.45, 0.95, 0.30)  # toxic green
	s.border_width_left = 5; s.border_width_right  = 5
	s.border_width_top  = 5; s.border_width_bottom = 5
	_curse_frame.add_theme_stylebox_override("panel", s)
	add_child(_curse_frame)

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
	gs.border_width_left = 5; gs.border_width_right  = 5
	gs.border_width_top  = 5; gs.border_width_bottom = 5
	_blessing_frame.add_theme_stylebox_override("panel", gs)
	add_child(_blessing_frame)


# Routes the video's audio through a dedicated bus (→ Master) so audio hexes
# (low-pass / reverb / distortion / volume wobble) affect only the video, never
# any other sound. Idempotent — the bus survives scene reloads, so reuse it.
func _setup_audio_fx_bus() -> void:
	if AudioServer.get_bus_index(VIDEO_FX_BUS) == -1:
		var idx: int = AudioServer.bus_count
		AudioServer.add_bus(idx)
		AudioServer.set_bus_name(idx, VIDEO_FX_BUS)
		AudioServer.set_bus_send(idx, "Master")
	_video.bus = VIDEO_FX_BUS
	# The bus is global and survives scene reloads — start each session clean so a
	# prior run that exited mid-round (e.g. Esc out of a test) can't leave a stale
	# audio effect (distortion/reverb/…) routed onto this run's video.
	_clear_audio_effects()


# Turns one per-pixel video effect on (lazily assigning the shared shader to the
# video). Several may be active at once — each is an independent uniform.
func _set_video_fx(param: String, value: float) -> void:
	if _video_fx_mat == null:
		return
	_video.material = _video_fx_mat
	_video_fx_mat.set_shader_parameter(param, value)


# Resets every video-effect uniform to its identity (off) value.
func _reset_video_fx_params() -> void:
	if _video_fx_mat == null:
		return
	_video_fx_mat.set_shader_parameter("grayscale", 0.0)
	_video_fx_mat.set_shader_parameter("invert", 0.0)
	_video_fx_mat.set_shader_parameter("sepia", 0.0)
	_video_fx_mat.set_shader_parameter("saturation", 1.0)
	_video_fx_mat.set_shader_parameter("posterize", 0.0)
	_video_fx_mat.set_shader_parameter("blur", 0.0)
	_video_fx_mat.set_shader_parameter("pixelate", 0.0)
	_video_fx_mat.set_shader_parameter("chromatic", 0.0)
	_video_fx_mat.set_shader_parameter("wave", 0.0)


# Clears all video effects and drops the shader off the video entirely.
func _reset_video_fx() -> void:
	_reset_video_fx_params()
	_video.material = null


func _add_audio_effect(effect: AudioEffect) -> void:
	var idx: int = AudioServer.get_bus_index(VIDEO_FX_BUS)
	if idx != -1:
		AudioServer.add_bus_effect(idx, effect)


# Strips every audio effect off the VideoFX bus and restores its level (undoing a
# Faltering wobble). Safe when none are present.
func _clear_audio_effects() -> void:
	var idx: int = AudioServer.get_bus_index(VIDEO_FX_BUS)
	if idx == -1:
		return
	while AudioServer.get_bus_effect_count(idx) > 0:
		AudioServer.remove_bus_effect(idx, 0)
	AudioServer.set_bus_volume_db(idx, 0.0)


func _start_bloodshot(peak: float = 1.0) -> void:
	_stop_bloodshot()
	# Pulse between a faint floor and the intensity-driven peak alpha.
	_curse_bloodshot.modulate.a = 0.0
	_bloodshot_tween = create_tween().set_loops()
	_bloodshot_tween.tween_property(_curse_bloodshot, "modulate:a", clampf(peak, 0.0, 1.0), 0.9)
	_bloodshot_tween.tween_property(_curse_bloodshot, "modulate:a", clampf(peak * 0.3, 0.0, 1.0), 0.9)


func _stop_bloodshot() -> void:
	if _bloodshot_tween != null and _bloodshot_tween.is_valid():
		_bloodshot_tween.kill()
	_bloodshot_tween = null
	if _curse_bloodshot != null:
		_curse_bloodshot.modulate.a = 0.0


# Quick erratic black dips — a jittered cadence so it reads as a faulty signal
# rather than the slow, regular Strobe fade.
func _start_flicker(scale: float = 1.0) -> void:
	_stop_flicker()
	# Intensity scales the dip darkness (cadence stays fixed). clampf keeps the
	# scaled peaks valid even when the catalog range pushes above 1.0.
	var s: float = clampf(scale, 0.0, 1.0 / 0.85)  # 0.85 is the tallest dip below
	_curse_flicker.modulate.a = 0.0
	_flicker_tween = create_tween().set_loops()
	_flicker_tween.tween_interval(0.8)
	_flicker_tween.tween_property(_curse_flicker, "modulate:a", 0.7 * s, 0.04)
	_flicker_tween.tween_property(_curse_flicker, "modulate:a", 0.0, 0.04)
	_flicker_tween.tween_interval(0.12)
	_flicker_tween.tween_property(_curse_flicker, "modulate:a", 0.45 * s, 0.03)
	_flicker_tween.tween_property(_curse_flicker, "modulate:a", 0.0, 0.06)
	_flicker_tween.tween_interval(0.5)
	_flicker_tween.tween_property(_curse_flicker, "modulate:a", 0.85 * s, 0.03)
	_flicker_tween.tween_property(_curse_flicker, "modulate:a", 0.0, 0.05)


func _stop_flicker() -> void:
	if _flicker_tween != null and _flicker_tween.is_valid():
		_flicker_tween.kill()
	_flicker_tween = null
	if _curse_flicker != null:
		_curse_flicker.modulate.a = 0.0


# Faltering — swells the VideoFX bus level up and down (bus, not _video.volume_db,
# so it never collides with a Silence/mute hex on the same round).
func _start_volwobble(depth_db: float = -24.0) -> void:
	_stop_volwobble()
	var idx: int = AudioServer.get_bus_index(VIDEO_FX_BUS)
	if idx == -1:
		return
	# Swell between 0 dB and the intensity-driven depth (deeper = more dramatic).
	var set_db: Callable = func(v: float) -> void: AudioServer.set_bus_volume_db(idx, v)
	_volwobble_tween = create_tween().set_loops()
	_volwobble_tween.tween_method(set_db, 0.0, depth_db, 1.2)
	_volwobble_tween.tween_method(set_db, depth_db, 0.0, 1.2)


func _stop_volwobble() -> void:
	if _volwobble_tween != null and _volwobble_tween.is_valid():
		_volwobble_tween.kill()
	_volwobble_tween = null


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

	# Tremor hex — jitter the video each frame (mixed frequencies so it reads as a
	# shake, not a wobble). _fit_video_cover runs every frame from _process.
	if _curse_tremor:
		var ts: float = Time.get_ticks_msec() / 1000.0
		_video.position += Vector2(
			sin(ts * 97.0) + sin(ts * 61.0),
			cos(ts * 89.0) + sin(ts * 53.0)
		) * (_curse_tremor_amp * 0.5)


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
		push_warning("GameLoop: FFmpegVideoStream not found — install EIRTeam.FFmpeg for MP4 support. Running funscript-only.")
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
	var _cur_ms: int      = _cur.get("length_ms", 0) as int
	GameState.LogRound(_cur, _cur_name, _cur_ms)

	# Append to the GDScript-side round-name log (see _ready). EndScreen reads
	# this directly, avoiding any potential C#→GDScript Dictionary marshalling
	# quirks for the name string.
	var _names: PackedStringArray = GameState.get_meta("_round_names", PackedStringArray()) as PackedStringArray
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
			"coin_jackpot": jackpot_factor *= float(fx.get("factor", 1.0))
			"coin_penalty": penalty_factor *= float(fx.get("factor", 1.0))
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
	await _transition_swap(func() -> void:
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
	tween_in.tween_property(_transition, "modulate:a", 1.0, TRANSITION_FADE_TIME).set_ease(Tween.EASE_IN)
	await tween_in.finished

	# Black now fully covers the screen — including any overlay we're leaving.
	# Overlays deliberately don't free themselves (see _show_*_screen), so they
	# stay visible and dim into the black instead of vanishing and flashing the
	# play area behind them. Free it now, under cover of the opaque black.
	_free_current_overlay()

	# Hide the HUD under the black so it can't flash in at full opacity when the
	# black clears; it's faded back in below once we land on a round.
	_hud.modulate.a = 0.0

	await get_tree().create_timer(TRANSITION_HOLD_TIME).timeout
	swap_action.call()

	# Hold the black until the next round's video actually has a frame, so the
	# fade never reveals the bare background between rounds.
	await _await_video_ready()

	var tween_out: Tween = create_tween()
	tween_out.tween_property(_transition, "modulate:a", 0.0, TRANSITION_FADE_TIME).set_ease(Tween.EASE_OUT)
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


func _go_to_menu() -> void:
	_video.stop()
	FunscriptPlayer.Stop()
	# In a test play, "back to menu" (button or Esc) returns to the builder the
	# preview was launched from, not the main menu.
	if _test_mode:
		_exit_test_to_builder()
		return
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
	JourneySaveService.delete_save(GameState.Journey.get("folder_name", ""))
	Transition.change_scene("res://scenes/end_screen/EndScreen.tscn")


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
	banner.anchor_left  = 0.0
	banner.anchor_right = 1.0
	banner.offset_top   = 12
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
	var score_data: Dictionary       = ScoreService.CaptureSaveData()
	var payload: Dictionary = {
		"sequence_index": game_state_data.get("sequence_index", 0),
		"sequence":       game_state_data.get("sequence", []),
		"fork_depth":     game_state_data.get("fork_depth", 0),
		"coins":          CoinService.Balance,
		"score":          score_data.get("score", 0),
		"total_actions":  score_data.get("strokes", 0),
		"inventory":      InventoryService.CaptureSaveData(),
		"round_names":    (GameState.get_meta("_round_names", PackedStringArray()) as PackedStringArray),
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
	toast.anchor_left  = 0.5; toast.anchor_right  = 0.5
	toast.anchor_top   = 0.0; toast.anchor_bottom = 0.0
	toast.grow_horizontal = Control.GROW_DIRECTION_BOTH
	toast.offset_top = 70    # below the device-warning banner

	var s: StyleBoxFlat = StyleBoxFlat.new()
	s.bg_color              = Color(UITheme.AMBER.r, UITheme.AMBER.g, UITheme.AMBER.b, 0.92)
	s.border_color          = UITheme.AMBER
	s.border_width_left     = 2; s.border_width_right  = 2
	s.border_width_top      = 2; s.border_width_bottom = 2
	s.content_margin_left   = 20; s.content_margin_right  = 20
	s.content_margin_top    = 8;  s.content_margin_bottom = 8
	s.corner_radius_top_left    = 6; s.corner_radius_top_right    = 6
	s.corner_radius_bottom_left = 6; s.corner_radius_bottom_right = 6
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
	# Freeze the active-effect clock while the Options overlay is open.
	InventoryService.SetPaused(true)
	var opts: Control = OptionsScene.instantiate()
	opts.overlay_mode = true
	opts.tree_exiting.connect(_on_options_closed)
	add_child(opts)


func _on_options_closed() -> void:
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


# ---------------------------------------------------------------------------
# Input
# ---------------------------------------------------------------------------

func _input(event: InputEvent) -> void:
	# Any activity shows the HUD.
	if event is InputEventMouseMotion or event is InputEventMouseButton \
			or event is InputEventKey:
		_show_hud()

	# Keyboard hotkeys — evaluated in order of specificity.
	if event is InputEventKey:
		var key_event := event as InputEventKey
		if key_event.pressed and not key_event.echo:
			match key_event.keycode:
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
					# Esc: close inventory if open, otherwise leave to menu.
					# Overlay screens (shop/storyboard) capture Esc themselves before
					# it reaches here; the fork screen intentionally does not (no escape).
					if not _is_overlay_open:
						if is_instance_valid(_inventory_panel):
							_inventory_panel.close()
						else:
							_go_to_menu()
						get_viewport().set_input_as_handled()


# ---------------------------------------------------------------------------
# Signals
# ---------------------------------------------------------------------------

func _on_score_changed(total: int) -> void:
	_score_lbl.text = str(total) + " PTS"


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
	ButtplugService.connect("Connected",      _refresh_device_warning)
	ButtplugService.connect("Disconnected",   _refresh_device_warning)
	ButtplugService.connect("DeviceAdded",    func(_n: String, _i: int) -> void: _refresh_device_warning())
	ButtplugService.connect("DeviceRemoved",  func(_i: int) -> void: _refresh_device_warning())
	SerialDeviceService.connect("Connected",    _refresh_device_warning)
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
	var mode: String = SettingsService.get_output_mode()
	var disconnected: bool = false
	var label_text: String = ""
	if mode == "serial":
		disconnected = not SerialDeviceService.SerialConnected
		label_text   = "●  SERIAL DEVICE DISCONNECTED  —  RECONNECT IN OPTIONS"
	else:
		if not ButtplugService.BpConnected:
			disconnected = true
			label_text   = "●  INTIFACE DISCONNECTED  —  RECONNECT IN OPTIONS"
		else:
			var selected_name: String = SettingsService.get_selected_device()
			var active_name: String   = ButtplugService.GetActiveDeviceName()
			if active_name == "":
				disconnected = true
				label_text   = "●  NO DEVICE CONNECTED  —  POWER ON OR RE-PAIR YOUR DEVICE"
			elif selected_name != "" and selected_name != active_name:
				# User has an explicit preference that isn't currently present.
				# Playback still works via the fallback to active_name; the
				# banner just tells the user it's not the device they picked.
				disconnected = true
				label_text   = "●  \"%s\" UNAVAILABLE  —  USING \"%s\" INSTEAD  (CHANGE IN OPTIONS)" % [
					selected_name.to_upper(), active_name.to_upper(),
				]
	if disconnected:
		_device_warning_label.text = label_text
	_device_warning_banner.visible = disconnected


# ---------------------------------------------------------------------------
# Inventory / coins / effect chips
# ---------------------------------------------------------------------------

func _on_inventory_pressed() -> void:
	if is_instance_valid(_inventory_panel):
		_inventory_panel.close()
		return
	_inventory_panel = InventoryPanelScene.instantiate()
	_inventory_panel.closed.connect(_on_inventory_closed)
	add_child(_inventory_panel)


func _on_inventory_closed() -> void:
	_inventory_panel = null


func _on_coin_balance_changed(_balance: int) -> void:
	_refresh_coin_label()


func _refresh_coin_label() -> void:
	_coin_lbl.text = "♦ %d" % CoinService.Balance


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
	s.bg_color            = Color(accent.r, accent.g, accent.b, 0.12)
	s.border_color        = accent
	s.border_width_left   = 1
	s.border_width_right  = 1
	s.border_width_top    = 1
	s.border_width_bottom = 1
	s.content_margin_left   = 10
	s.content_margin_right  = 10
	s.content_margin_top    = 4
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
	anchor_right  = 1.0
	anchor_bottom = 1.0

	_bg.anchor_right  = 1.0
	_bg.anchor_bottom = 1.0
	_bg.offset_left   = 0
	_bg.offset_top    = 0
	_bg.offset_right  = 0
	_bg.offset_bottom = 0

	_video.anchor_left   = 0.0
	_video.anchor_top    = 0.0
	_video.anchor_right  = 0.0
	_video.anchor_bottom = 0.0
	_video.offset_left   = 0
	_video.offset_top    = 0
	_video.offset_right  = 0
	_video.offset_bottom = 0
	_video.position      = Vector2.ZERO
	_video.size          = get_viewport_rect().size

	_hud.anchor_right  = 1.0
	_hud.anchor_bottom = 1.0

	_hud_bar.anchor_left   = 0.0
	_hud_bar.anchor_right  = 1.0
	_hud_bar.anchor_top    = 1.0
	_hud_bar.anchor_bottom = 1.0
	_hud_bar.offset_top    = -HUD_BAR_HEIGHT
	_hud_bar.offset_bottom = 0

	_hud_layout.add_theme_constant_override("separation", 16)
	_round_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	# Progress bar — centered thin strip at the very bottom of the screen
	_progress.anchor_left   = 0.1
	_progress.anchor_right  = 0.9
	_progress.anchor_top    = 1.0
	_progress.anchor_bottom = 1.0
	_progress.offset_left   = 0
	_progress.offset_right  = 0
	_progress.offset_top    = -7
	_progress.offset_bottom = -1

	# Effect chips — row pinned just above the progress bar, centred.
	_chips_row.anchor_left   = 0.0
	_chips_row.anchor_right  = 1.0
	_chips_row.anchor_top    = 1.0
	_chips_row.anchor_bottom = 1.0
	_chips_row.offset_top    = -42
	_chips_row.offset_bottom = -12
	_chips_row.alignment     = BoxContainer.ALIGNMENT_CENTER
	_chips_row.add_theme_constant_override("separation", 8)
	_chips_row.mouse_filter = Control.MOUSE_FILTER_IGNORE

	# Device-disconnected banner — pinned to the top edge of the viewport,
	# centred horizontally, hidden by default. Lives outside _hud so the
	# auto-hide timer doesn't fade it away.
	_device_warning_banner = PanelContainer.new()
	_device_warning_banner.anchor_left   = 0.5
	_device_warning_banner.anchor_right  = 0.5
	_device_warning_banner.anchor_top    = 0.0
	_device_warning_banner.anchor_bottom = 0.0
	_device_warning_banner.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_device_warning_banner.offset_top    = 12
	_device_warning_banner.mouse_filter  = Control.MOUSE_FILTER_IGNORE
	_device_warning_banner.visible       = false
	add_child(_device_warning_banner)

	var banner_style: StyleBoxFlat = StyleBoxFlat.new()
	banner_style.bg_color              = Color(UITheme.ERROR_SOFT.r, UITheme.ERROR_SOFT.g, UITheme.ERROR_SOFT.b, 0.92)
	banner_style.border_color          = UITheme.ERROR_SOFT
	banner_style.border_width_left     = 2; banner_style.border_width_right  = 2
	banner_style.border_width_top      = 2; banner_style.border_width_bottom = 2
	banner_style.content_margin_left   = 18; banner_style.content_margin_right  = 18
	banner_style.content_margin_top    = 8;  banner_style.content_margin_bottom = 8
	banner_style.corner_radius_top_left     = 6; banner_style.corner_radius_top_right    = 6
	banner_style.corner_radius_bottom_left  = 6; banner_style.corner_radius_bottom_right = 6
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
	bar_style.bg_color            = UITheme.PANEL_BG_GAME
	bar_style.border_color        = UITheme.PURPLE_BRIGHT
	bar_style.border_width_top    = 1
	bar_style.content_margin_left  = 20
	bar_style.content_margin_right = 20
	bar_style.content_margin_top   = 14
	bar_style.content_margin_bottom = 14
	_hud_bar.add_theme_stylebox_override("panel", bar_style)

	_round_lbl.add_theme_color_override("font_color",    UITheme.WHITE_SOFT)
	_round_lbl.add_theme_font_size_override("font_size", 13)
	_round_lbl.uppercase = true

	_score_lbl.add_theme_color_override("font_color",    UITheme.MAGENTA)
	_score_lbl.add_theme_font_size_override("font_size", 13)
	_score_lbl.uppercase = true

	_coin_lbl.add_theme_color_override("font_color",    UITheme.AMBER)
	_coin_lbl.add_theme_font_size_override("font_size", 13)
	_coin_lbl.uppercase = true

	_style_progress()
	_style_button(_pause_btn,   UITheme.PURPLE_BRIGHT)
	_style_button(_inv_btn,     UITheme.AMBER)
	_style_button(_menu_btn,    UITheme.MAGENTA)
	_style_button(_options_btn, UITheme.PURPLE_MID)


func _style_button(btn: Button, accent: Color) -> void:
	btn.add_theme_color_override("font_color",         accent)
	btn.add_theme_color_override("font_hover_color",   UITheme.WHITE_SOFT)
	btn.add_theme_color_override("font_pressed_color", UITheme.BG)
	btn.add_theme_font_size_override("font_size", 13)
	btn.text = btn.text.to_upper()

	var s: StyleBoxFlat = StyleBoxFlat.new()
	s.bg_color            = Color(accent.r, accent.g, accent.b, 0.12)
	s.border_color        = accent
	s.border_width_left   = 1
	s.border_width_right  = 1
	s.border_width_top    = 1
	s.border_width_bottom = 1
	s.content_margin_left   = 14
	s.content_margin_right  = 14
	s.content_margin_top    = 8
	s.content_margin_bottom = 8
	btn.add_theme_stylebox_override("normal", s)

	var s_hover: StyleBoxFlat = s.duplicate()
	s_hover.bg_color = Color(accent.r, accent.g, accent.b, 0.32)
	btn.add_theme_stylebox_override("hover", s_hover)

	var s_pressed: StyleBoxFlat = s.duplicate()
	s_pressed.bg_color = accent
	btn.add_theme_stylebox_override("pressed", s_pressed)
	btn.add_theme_stylebox_override("focus", StyleBoxEmpty.new())


func _style_progress() -> void:
	var bg: StyleBoxFlat = StyleBoxFlat.new()
	bg.bg_color                  = Color(0.08, 0.0, 0.12, 0.8)
	bg.corner_radius_top_left    = 4
	bg.corner_radius_top_right   = 4
	bg.corner_radius_bottom_left = 4
	bg.corner_radius_bottom_right = 4

	var fill: StyleBoxFlat = StyleBoxFlat.new()
	fill.bg_color                  = UITheme.PURPLE_BRIGHT
	fill.corner_radius_top_left    = 4
	fill.corner_radius_top_right   = 4
	fill.corner_radius_bottom_left = 4
	fill.corner_radius_bottom_right = 4

	_progress.add_theme_stylebox_override("background", bg)
	_progress.add_theme_stylebox_override("fill", fill)
	_progress.min_value      = 0.0
	_progress.max_value      = 1.0
	_progress.show_percentage = false
