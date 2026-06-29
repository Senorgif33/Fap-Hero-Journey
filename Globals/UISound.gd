extends Node

# ---------------------------------------------------------------------------
# UISound  (autoload)
#
# Lightweight UI feedback blips. The waveforms are SYNTHESIZED into in-memory
# AudioStreamWAV resources at startup — no audio files are shipped or imported.
# That fits the synthwave aesthetic (everything's a synth blip), avoids any
# asset/licensing management, and keeps every sound tweakable from code.
#
# Click is auto-wired to EVERY BaseButton in the app via the SceneTree's
# node_added signal, so buttons get sound with zero per-scene wiring — including
# ones built dynamically (the builder, modals, the shop, …). Screens can also
# call the semantic helpers (hover / confirm / back / error) at meaningful
# moments — hover is intentionally NOT auto-played (too chatty across button rows).
#
# Gated by SettingsService ui_sound_enabled / ui_sound_volume; call
# reload_settings() after the Options toggle changes them.
# ---------------------------------------------------------------------------

const MIX_RATE: int = 44100
const POOL_SIZE: int = 6  # concurrent one-shots before the pool round-robins
const PITCH_SCALE: float = 1.0  # 1.0 plays samples at natural pitch; <1 pitches every blip down
const PITCH_VARIATION: float = 0.08  # ±fraction of random pitch jitter per play, so repeats don't sound identical

# Real UI click sample. Loaded if present; otherwise the synth tick is used.
const CLICK_OGG_PATH: String = "res://assets/sfx/click.ogg"
# Storyboard dialogue-advance sample. Falls back to the click sound if missing.
const STORYBOARD_WAV_PATH: String = "res://assets/sfx/storyboard click.wav"
# Event samples (silent if a file is missing — they're all imported normally).
const ITEM_USE_WAV_PATH: String = "res://assets/sfx/item use.wav"
const JOURNEY_WAV_PATH: String = "res://assets/sfx/journey click.wav"
const START_JOURNEY_WAV_PATH: String = "res://assets/sfx/start journey click.wav"
const GAME_COMPLETE_WAV_PATH: String = "res://assets/sfx/game complete.wav"

var _streams: Dictionary = {}  # kind -> AudioStreamWAV
var _players: Array[AudioStreamPlayer] = []
var _next_player: int = 0

# Instance-ids of buttons we've already wired, so a re-parented button isn't
# double-connected. Cleared per-button on tree_exited.
var _wired: Dictionary = {}

var _enabled: bool = true
var _volume_db: float = 0.0


func _ready() -> void:
	# Survive the game pause (boss intro, shops, options) so menu clicks during a
	# paused round still sound.
	process_mode = Node.PROCESS_MODE_ALWAYS

	_build_streams()
	for i in POOL_SIZE:
		var p: AudioStreamPlayer = AudioStreamPlayer.new()
		p.bus = "Master"
		add_child(p)
		_players.append(p)

	reload_settings()

	# Wire every button — those already in the tree, and all future ones.
	get_tree().node_added.connect(_on_node_added)
	_wire_existing(get_tree().root)


# Re-read the enabled / volume settings (call after the Options control changes).
func reload_settings() -> void:
	_enabled = SettingsService.get_ui_sound_enabled()
	_volume_db = linear_to_db(clampf(SettingsService.get_ui_sound_volume(), 0.0001, 1.0))


# ── Public play API ──────────────────────────────────────────────────────────


func click() -> void:
	_play("click")


func storyboard() -> void:
	_play("storyboard")


func item_use() -> void:
	_play("item_use")


func journey() -> void:
	_play("journey")


func start_journey() -> void:
	_play("start_journey")


func game_complete() -> void:
	_play("game_complete")


func hover() -> void:
	_play("hover")


func confirm() -> void:
	_play("confirm")


func back() -> void:
	_play("back")


func error() -> void:
	_play("error")


func _play(kind: String) -> void:
	if not _enabled:
		return
	var stream: AudioStream = _streams.get(kind)
	if stream == null:
		return
	var p: AudioStreamPlayer = _players[_next_player]
	_next_player = (_next_player + 1) % _players.size()
	p.stream = stream
	p.volume_db = _volume_db
	p.pitch_scale = PITCH_SCALE * randf_range(1.0 - PITCH_VARIATION, 1.0 + PITCH_VARIATION)
	p.play()


# ── Global button wiring ──────────────────────────────────────────────────────


func _on_node_added(node: Node) -> void:
	if node is BaseButton:
		_wire_button(node)


func _wire_existing(root: Node) -> void:
	for child in root.get_children():
		if child is BaseButton:
			_wire_button(child)
		_wire_existing(child)


func _wire_button(btn: BaseButton) -> void:
	var id: int = btn.get_instance_id()
	if _wired.has(id):
		return
	_wired[id] = true
	btn.tree_exited.connect(func() -> void: _wired.erase(id))
	# Muted buttons play their own custom sound at the call site (e.g. Play /
	# Resume play start_journey on embark), so skip the default click here.
	if btn.has_meta("ui_sound_muted") and bool(btn.get_meta("ui_sound_muted")):
		return
	# `pressed` fires on enabled buttons only, so disabled controls stay silent.
	# (hover() stays available for screens that want it explicitly.)
	btn.pressed.connect(click)


# Stops a button from auto-playing the default click — for buttons that trigger a
# custom or deferred sound themselves. Works whether called before or after the
# button was wired (disconnects an existing click hookup if present).
func mute_button(btn: BaseButton) -> void:
	if btn == null:
		return
	btn.set_meta("ui_sound_muted", true)
	if btn.pressed.is_connected(click):
		btn.pressed.disconnect(click)


# Loads an AudioStream resource if it exists and imported cleanly, else null.
func _load_stream(path: String) -> AudioStream:
	if not ResourceLoader.exists(path):
		return null
	var res: Resource = load(path)
	return res if res is AudioStream else null


# ── Synthesis ─────────────────────────────────────────────────────────────────


func _build_streams() -> void:
	# Each blip is a short tone (or note sequence) with a quick attack + decay.
	# Frequencies are musical so they read as intentional, not beeps. Hover is
	# quiet so a mouse sweep across a button row stays unobtrusive.
	_streams["hover"] = _make_blip([1046.5], 0.045, 0.14, "sine")
	# Click: prefer the real sample at CLICK_OGG_PATH; fall back to the synth noise
	# tick when it's missing or not yet imported (so the app always has UI sound).
	var click_sample: AudioStream = _load_stream(CLICK_OGG_PATH)
	if click_sample != null:
		_streams["click"] = click_sample
	else:
		_streams["click"] = _make_blip([2500.0], 0.032, 0.85, "noise")

	# Storyboard dialogue advance — its own sample, else reuse the click.
	var story_sample: AudioStream = _load_stream(STORYBOARD_WAV_PATH)
	_streams["storyboard"] = story_sample if story_sample != null else _streams["click"]

	# Event samples (no fallback — a missing one is simply silent).
	_streams["item_use"] = _load_stream(ITEM_USE_WAV_PATH)
	_streams["journey"] = _load_stream(JOURNEY_WAV_PATH)
	_streams["start_journey"] = _load_stream(START_JOURNEY_WAV_PATH)
	_streams["game_complete"] = _load_stream(GAME_COMPLETE_WAV_PATH)
	_streams["confirm"] = _make_blip([659.3, 987.8, 1318.5], 0.16, 0.30, "sine")
	_streams["back"] = _make_blip([659.3, 440.0], 0.12, 0.28, "sine")
	_streams["error"] = _make_blip([196.0, 185.0], 0.20, 0.30, "square")


# Renders `notes` (played in equal time slices) into a mono 16-bit AudioStreamWAV.
# Phase is integrated continuously across note changes so segment boundaries don't
# click; a 3 ms attack + exponential decay shapes the whole blip.
func _make_blip(notes: Array, duration: float, amp: float, wave: String) -> AudioStreamWAV:
	var n: int = int(duration * MIX_RATE)
	var data: PackedByteArray = PackedByteArray()
	data.resize(n * 2)

	var phase: float = 0.0
	var lp: float = 0.0  # one-pole lowpass state (used by the "noise" wave)
	var seg: int = maxi(notes.size(), 1)
	const ATTACK: float = 0.003

	for i in n:
		var note_idx: int = clampi(int((float(i) / float(n)) * seg), 0, seg - 1)
		var freq: float = float(notes[note_idx])
		phase += TAU * freq / float(MIX_RATE)

		var s: float = 0.0
		match wave:
			"square":
				s = 1.0 if sin(phase) >= 0.0 else -1.0
			"saw":
				s = fmod(phase / TAU, 1.0) * 2.0 - 1.0
			"noise":
				# Neutral tick: white noise through a one-pole lowpass. For this
				# wave the "note" is the cutoff in Hz — lower = duller/softer.
				var alpha: float = clampf(1.0 - exp(-TAU * freq / float(MIX_RATE)), 0.0, 1.0)
				lp += alpha * (randf_range(-1.0, 1.0) - lp)
				s = lp
			_:
				s = sin(phase)

		var tt: float = float(i) / float(MIX_RATE)
		var env: float
		if tt < ATTACK:
			env = tt / ATTACK
		else:
			env = exp(-3.5 * (tt - ATTACK) / maxf(duration - ATTACK, 0.0001))

		var v: int = int(round(clampf(s * env * amp, -1.0, 1.0) * 32767.0))
		data[i * 2] = v & 0xFF
		data[i * 2 + 1] = (v >> 8) & 0xFF

	var stream: AudioStreamWAV = AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = MIX_RATE
	stream.stereo = false
	stream.data = data
	return stream
