extends Node

# ---------------------------------------------------------------------------
# SettingsService  (autoload)
# Single source of truth for user://settings.cfg. The schema — every section,
# key, type, and default value — is declared exactly once, here.
#
# All other code reads settings through the typed get_*() methods and writes
# through set_*() followed by save(). No other file should open settings.cfg
# directly.
#
# The ConfigFile is held in memory and kept consistent: every write goes
# through a setter, so getters always reflect the latest values without a
# disk round-trip.
#
# C# callers reach this via the autoload node, e.g.:
#   GetNode("/root/SettingsService").Call("get_output_mode").AsString()
# ---------------------------------------------------------------------------

const SETTINGS_PATH: String = "user://settings.cfg"

# ── Canonical defaults ──────────────────────────────────────────────────────
const DEFAULT_MASTER_VOLUME:     float  = 1.0
const DEFAULT_MUSIC_VOLUME:      float  = 0.5
const DEFAULT_FULLSCREEN:        bool   = false
const DEFAULT_RESOLUTION_INDEX:  int    = 1
const DEFAULT_INTIFACE_ADDRESS:  String = "ws://localhost:12345"
const DEFAULT_INTIFACE_AUTO:     bool   = true
const DEFAULT_SELECTED_DEVICE:   String = ""
const DEFAULT_OUTPUT_MODE:       String = "buttplug"
const DEFAULT_SERIAL_PORT:       String = ""
const DEFAULT_SERIAL_BAUD:       int    = 115200
const DEFAULT_SERIAL_AUTO:       bool   = false
const DEFAULT_RANGE_MIN:         int    = 0
const DEFAULT_RANGE_MAX:         int    = 100
const DEFAULT_HOME_POSITION:     int    = 50
const DEFAULT_HOME_EASE_MS:      int    = 2000
const DEFAULT_LATENCY_OFFSET_MS: int    = 0
const DEFAULT_VIBE_INTENSITY:    int    = 100
const DEFAULT_MAX_STROKE_SPEED:  int    = 0     # 0 = unlimited (units/sec)
const DEFAULT_HUD_HIDE_DELAY:    float  = 3.0   # seconds
const DEFAULT_BEAT_BAR_ENABLED:  bool   = false
const DEFAULT_FILLER_ENABLED:    bool   = false
const DEFAULT_FILLER_HALF_CYCLE: int    = 2000
const DEFAULT_FILLER_LO:         int    = 0
const DEFAULT_FILLER_HI:         int    = 100
const DEFAULT_JOURNEYS_DIR:      String = "user://journeys"

var _config: ConfigFile = ConfigFile.new()


func _ready() -> void:
	# A missing file is fine — getters fall back to the canonical defaults.
	_config.load(SETTINGS_PATH)

	# Apply boot-time audio / display settings.
	AudioServer.set_bus_volume_db(0, linear_to_db(get_master_volume()))
	var mode: DisplayServer.WindowMode = DisplayServer.WINDOW_MODE_EXCLUSIVE_FULLSCREEN \
		if get_fullscreen() else DisplayServer.WINDOW_MODE_WINDOWED
	DisplayServer.window_set_mode(mode)


# ── Getters ─────────────────────────────────────────────────────────────────

func get_master_volume() -> float:
	return float(_config.get_value("audio", "master_volume", DEFAULT_MASTER_VOLUME))

func get_music_volume() -> float:
	return float(_config.get_value("audio", "music_volume", DEFAULT_MUSIC_VOLUME))

func get_fullscreen() -> bool:
	return bool(_config.get_value("display", "fullscreen", DEFAULT_FULLSCREEN))

func get_resolution_index() -> int:
	return int(_config.get_value("display", "resolution_index", DEFAULT_RESOLUTION_INDEX))

func get_intiface_address() -> String:
	return str(_config.get_value("intiface", "address", DEFAULT_INTIFACE_ADDRESS))

func get_intiface_auto_connect() -> bool:
	return bool(_config.get_value("intiface", "auto_connect", DEFAULT_INTIFACE_AUTO))

func get_selected_device() -> String:
	return str(_config.get_value("intiface", "selected_device", DEFAULT_SELECTED_DEVICE))

func get_output_mode() -> String:
	return str(_config.get_value("output", "mode", DEFAULT_OUTPUT_MODE))

func get_serial_port() -> String:
	return str(_config.get_value("serial", "port", DEFAULT_SERIAL_PORT))

func get_serial_baud() -> int:
	return int(_config.get_value("serial", "baud_rate", DEFAULT_SERIAL_BAUD))

func get_serial_auto_connect() -> bool:
	return bool(_config.get_value("serial", "auto_connect", DEFAULT_SERIAL_AUTO))

func get_range_min() -> int:
	return int(_config.get_value("device", "range_min", DEFAULT_RANGE_MIN))

func get_range_max() -> int:
	return int(_config.get_value("device", "range_max", DEFAULT_RANGE_MAX))

func get_home_position() -> int:
	return int(_config.get_value("device", "home_position", DEFAULT_HOME_POSITION))

func get_home_ease_ms() -> int:
	return int(_config.get_value("device", "home_ease_ms", DEFAULT_HOME_EASE_MS))

func get_latency_offset_ms() -> int:
	return int(_config.get_value("device", "latency_offset_ms", DEFAULT_LATENCY_OFFSET_MS))

func get_vibe_intensity() -> int:
	return int(_config.get_value("device", "vibe_intensity", DEFAULT_VIBE_INTENSITY))

func get_max_stroke_speed() -> int:
	return int(_config.get_value("device", "max_stroke_speed", DEFAULT_MAX_STROKE_SPEED))

func get_hud_hide_delay() -> float:
	return float(_config.get_value("display", "hud_hide_delay", DEFAULT_HUD_HIDE_DELAY))

func get_beat_bar_enabled() -> bool:
	return bool(_config.get_value("display", "beat_bar_enabled", DEFAULT_BEAT_BAR_ENABLED))

func get_filler_enabled() -> bool:
	return bool(_config.get_value("storyboard_filler", "enabled", DEFAULT_FILLER_ENABLED))

func get_filler_half_cycle_ms() -> int:
	return int(_config.get_value("storyboard_filler", "half_cycle_ms", DEFAULT_FILLER_HALF_CYCLE))

func get_filler_lo() -> int:
	return int(_config.get_value("storyboard_filler", "lo", DEFAULT_FILLER_LO))

func get_filler_hi() -> int:
	return int(_config.get_value("storyboard_filler", "hi", DEFAULT_FILLER_HI))

# Root folder for journey content. Either the default Godot user-data path
# (`user://journeys`) or an OS-absolute path the user picked via Options →
# Journey Storage Location. Consumers that need an OS path can pass the result
# through `ProjectSettings.globalize_path` — it's a no-op for absolute paths.
func get_journeys_dir() -> String:
	return str(_config.get_value("storage", "journeys_dir", DEFAULT_JOURNEYS_DIR))


# ── Setters ─────────────────────────────────────────────────────────────────
# Setters mutate the in-memory config only. Call save() to persist.

func set_master_volume(value: float) -> void:
	_config.set_value("audio", "master_volume", value)

func set_music_volume(value: float) -> void:
	_config.set_value("audio", "music_volume", value)

func set_fullscreen(value: bool) -> void:
	_config.set_value("display", "fullscreen", value)

func set_resolution_index(value: int) -> void:
	_config.set_value("display", "resolution_index", value)

func set_intiface_address(value: String) -> void:
	_config.set_value("intiface", "address", value)

func set_intiface_auto_connect(value: bool) -> void:
	_config.set_value("intiface", "auto_connect", value)

func set_selected_device(value: String) -> void:
	_config.set_value("intiface", "selected_device", value)

func set_output_mode(value: String) -> void:
	_config.set_value("output", "mode", value)

func set_serial_port(value: String) -> void:
	_config.set_value("serial", "port", value)

func set_serial_baud(value: int) -> void:
	_config.set_value("serial", "baud_rate", value)

func set_serial_auto_connect(value: bool) -> void:
	_config.set_value("serial", "auto_connect", value)

func set_range_min(value: int) -> void:
	_config.set_value("device", "range_min", value)

func set_range_max(value: int) -> void:
	_config.set_value("device", "range_max", value)

func set_home_position(value: int) -> void:
	_config.set_value("device", "home_position", value)

func set_home_ease_ms(value: int) -> void:
	_config.set_value("device", "home_ease_ms", value)

func set_latency_offset_ms(value: int) -> void:
	_config.set_value("device", "latency_offset_ms", value)

func set_vibe_intensity(value: int) -> void:
	_config.set_value("device", "vibe_intensity", value)

func set_max_stroke_speed(value: int) -> void:
	_config.set_value("device", "max_stroke_speed", value)

func set_hud_hide_delay(value: float) -> void:
	_config.set_value("display", "hud_hide_delay", value)

func set_beat_bar_enabled(value: bool) -> void:
	_config.set_value("display", "beat_bar_enabled", value)

func set_filler_enabled(value: bool) -> void:
	_config.set_value("storyboard_filler", "enabled", value)

func set_filler_half_cycle_ms(value: int) -> void:
	_config.set_value("storyboard_filler", "half_cycle_ms", value)

func set_filler_lo(value: int) -> void:
	_config.set_value("storyboard_filler", "lo", value)

func set_filler_hi(value: int) -> void:
	_config.set_value("storyboard_filler", "hi", value)

func set_journeys_dir(value: String) -> void:
	_config.set_value("storage", "journeys_dir", value)


# ── Persistence ─────────────────────────────────────────────────────────────

func save() -> void:
	_config.save(SETTINGS_PATH)
