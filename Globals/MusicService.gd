extends Node

# ---------------------------------------------------------------------------
# MusicService  (autoload)
# Manages continuous background music for menu screens.
# The AudioStreamPlayer lives on this autoload Node, so it persists across
# scene changes.  Music is paused (not stopped) when entering gameplay so
# the playback position is preserved when the player returns to a menu.
# ---------------------------------------------------------------------------

const MUSIC_PATH: String = "res://assets/music/menu_music.ogg"

var _player: AudioStreamPlayer = null


func _ready() -> void:
	var stream: AudioStreamOggVorbis = load(MUSIC_PATH)
	stream.loop = true

	_player = AudioStreamPlayer.new()
	_player.stream = stream
	_player.bus = "Master"
	add_child(_player)

	var vol: float = float(SettingsService.get_music_volume())
	_player.volume_db = linear_to_db(vol)
	_player.play()


# Resume music.  Safe to call even when already playing — will not restart
# the track.
func play() -> void:
	if _player == null:
		return
	if _player.stream_paused:
		_player.stream_paused = false
	elif not _player.playing:
		_player.play()


# Pause music and preserve the playback position so the next play() call
# resumes seamlessly rather than restarting from the beginning.
func stop() -> void:
	if _player == null:
		return
	_player.stream_paused = true


# Live volume update — called by Options on every slider change.
func set_volume(linear: float) -> void:
	if _player == null:
		return
	_player.volume_db = linear_to_db(linear)
