extends Node
## Graph-agnostic media operations shared by the journey builder's save pipeline
## and the randomizer library. Resolves the ffmpeg / ffprobe binaries, probes a
## source video (codec / pixel format / duration), decides whether a source needs
## re-encoding for the runtime decoder (EIRTeam.FFmpeg decodes H.264 only), and
## runs the actual transcode.
##
## Pure I/O + process control: it owns no journey / graph / UI state. Progress and
## cancellation are injected as Callables, so any caller wires its own modal — the
## builder feeds its save-progress modal, the randomizer its library-add modal.
## Extracted from JourneyBuilder so both paths share one implementation.

# Codecs the runtime decoder treats as H.264 (ffprobe codec_name variants).
const H264_NAMES: Array[String] = ["h264", "avc1", "avc"]

# Pixel formats EIRTeam.FFmpeg handles: 8-bit 4:2:0, both the standard (yuv420p)
# and full-range JPEG (yuvj420p) variants. Anything else (10-bit, 4:2:2, 4:4:4) is
# re-encoded even when the codec is already H.264 — the "it's h264 but still won't
# play" cases. Kept broad to avoid needless re-encodes.
const SAFE_PIX_FMTS: Array[String] = ["yuv420p", "yuvj420p"]

# Scratch file ffmpeg writes -progress lines to; polled to drive the progress bar.
const PROGRESS_FILE: String = "user://transcode_progress.txt"

# PID of the in-flight ffmpeg encode (-1 when idle). Owned here so a caller's
# cancel callback only needs to flip a bool — transcode_video does the kill.
var _pid: int = -1

# ── Binary resolution ────────────────────────────────────────────────────────


func resolve_binary(name: String) -> String:
	# Resolution order (custom folder → bundled → PATH) lives in
	# SettingsService.resolve_ffmpeg_binary so the Options "Test" button shares it.
	# The one export concern: in an exported build res://bin/ is inside the PCK and
	# can't be executed, so extract to user://bin/ on first use. Only bother when
	# resolution otherwise falls through to a bare PATH name (i.e. no custom folder
	# and nothing extracted yet).
	var path: String = SettingsService.resolve_ffmpeg_binary(name)
	if path == name and not OS.has_feature("editor"):
		var exe: String = name + ".exe" if OS.get_name() == "Windows" else name
		var user_abs: String = ProjectSettings.globalize_path("user://bin/" + exe)
		if not FileAccess.file_exists(user_abs):
			_extract_binary("res://bin/" + exe, user_abs)
		path = SettingsService.resolve_ffmpeg_binary(name)
	return path


# Copies a binary from the PCK (res://) to an absolute filesystem path so it can
# be executed. Called once per binary per user data directory.
func _extract_binary(src_res: String, dst_abs: String) -> void:
	if not FileAccess.file_exists(src_res):
		return
	DirAccess.make_dir_recursive_absolute(dst_abs.get_base_dir())
	var f_in: FileAccess = FileAccess.open(src_res, FileAccess.READ)
	if f_in == null:
		return
	var bytes: PackedByteArray = f_in.get_buffer(f_in.get_length())
	f_in.close()
	var f_out: FileAccess = FileAccess.open(dst_abs, FileAccess.WRITE)
	if f_out == null:
		return
	f_out.store_buffer(bytes)
	f_out.close()
	if OS.get_name() != "Windows":
		OS.execute("chmod", ["+x", dst_abs], [], true)


func is_available() -> bool:
	var out: Array = []
	return OS.execute(resolve_binary("ffprobe"), ["-version"], out, true, false) == 0


# ── Probing ──────────────────────────────────────────────────────────────────


# Probes a video's primary stream for both codec name and pixel format in one
# ffprobe call. Returns {"codec": String, "pix_fmt": String} (lowercased; empty
# strings when the probe fails).
func probe_stream_info(path: String) -> Dictionary:
	var out: Array = []
	var args: PackedStringArray = [
		"-v",
		"error",
		"-select_streams",
		"v:0",
		"-show_entries",
		"stream=codec_name,pix_fmt",
		"-of",
		"csv=p=0",
		ProjectSettings.globalize_path(path),
	]
	if OS.execute(resolve_binary("ffprobe"), args, out, true, false) != 0 or out.is_empty():
		return {"codec": "", "pix_fmt": ""}
	# csv=p=0 yields "codec_name,pix_fmt" on the first non-empty line. Take the
	# first non-empty line (stderr is merged in with read_stderr=true).
	for raw_line: String in (out[0] as String).split("\n"):
		var line: String = raw_line.strip_edges().to_lower()
		if line == "":
			continue
		var parts: PackedStringArray = line.split(",")
		var codec: String = parts[0].strip_edges() if parts.size() > 0 else ""
		var pix_fmt: String = parts[1].strip_edges() if parts.size() > 1 else ""
		return {"codec": codec, "pix_fmt": pix_fmt}
	return {"codec": "", "pix_fmt": ""}


func probe_duration_seconds(path: String) -> float:
	var out: Array = []
	var args: PackedStringArray = [
		"-v",
		"error",
		"-show_entries",
		"format=duration",
		"-of",
		"csv=p=0",
		ProjectSettings.globalize_path(path),
	]
	if OS.execute(resolve_binary("ffprobe"), args, out, true, false) != 0 or out.is_empty():
		return 0.0
	return (out[0] as String).strip_edges().to_float()


# Decides whether a probed source needs re-encoding, and why. Returns the reason
# string used for the plan key / modal ("" = no encode needed). A source is
# planned when its codec can't be read (re-encode to be safe), isn't H.264, or is
# H.264 with an undecodable pixel format (10-bit, 4:2:2, …). `is_trim` forces an
# encode even on a clean source — a frame-accurate cut can't ship as a copy.
func classify_transcode(codec: String, pix_fmt: String, is_trim: bool) -> String:
	var reason: String = ""
	if codec == "":
		reason = "unverifiable"  # couldn't read — re-encode to be safe
	elif not (codec in H264_NAMES):
		reason = codec  # wrong codec (HEVC/AV1/VP9/…)
	elif pix_fmt != "" and not (pix_fmt in SAFE_PIX_FMTS):
		reason = "%s %s" % [codec, pix_fmt]  # h264 but undecodable profile
	if is_trim and reason == "":
		reason = "trim"  # fine codec, but the cut itself demands the encode
	return reason


# ── Transcode ────────────────────────────────────────────────────────────────


# Re-encodes `input` to H.264 .mp4 at `output`, optionally baking a trim window.
# `duration` is the (trimmed) output length in seconds — drives the progress bar.
# `on_progress`, when valid, is called as on_progress.call(fraction, current_s,
# total_s, speed) each poll. `should_cancel`, when valid, is polled each loop; a
# true return kills ffmpeg and returns false. Returns true only when the output
# file exists at the end.
func transcode_video(
	input: String,
	output: String,
	duration: float,
	trim_in_ms: int = 0,
	trim_out_ms: int = 0,
	on_progress: Callable = Callable(),
	should_cancel: Callable = Callable()
) -> bool:
	var progress_abs: String = ProjectSettings.globalize_path(PROGRESS_FILE)
	# Truncate any prior progress file so old data doesn't mislead the parser.
	var pf: FileAccess = FileAccess.open(progress_abs, FileAccess.WRITE)
	if pf:
		pf.close()

	var args: PackedStringArray = []
	args.append_array(["-y", "-hide_banner", "-loglevel", "error"])
	# Trim bake: -ss before -i (fast input seek; frame-accurate because we always
	# re-encode) + an explicit -t duration after it. `duration` is already the
	# trimmed length, so the progress bar stays honest.
	if trim_in_ms > 0:
		args.append_array(["-ss", "%.3f" % (trim_in_ms / 1000.0)])
	args.append_array(["-i", ProjectSettings.globalize_path(input)])
	if trim_out_ms > 0 or trim_in_ms > 0:
		var trim_len: float = duration
		if trim_len > 0.0:
			args.append_array(["-t", "%.3f" % trim_len])
	(
		args
		. append_array(
			[
				"-c:v",
				"libx264",
				"-preset",
				"fast",
				"-crf",
				"22",
				"-pix_fmt",
				"yuv420p",
				"-c:a",
				"aac",
				"-b:a",
				"192k",
				"-progress",
				progress_abs,
				ProjectSettings.globalize_path(output),
			]
		)
	)

	_pid = OS.create_process(resolve_binary("ffmpeg"), args)
	if _pid <= 0:
		return false

	while OS.is_process_running(_pid):
		if should_cancel.is_valid() and should_cancel.call():
			OS.kill(_pid)
			_pid = -1
			return false
		_poll_progress(progress_abs, duration, on_progress)
		await get_tree().create_timer(0.4).timeout

	# Final poll to flush "progress=end".
	_poll_progress(progress_abs, duration, on_progress)
	_pid = -1
	return FileAccess.file_exists(output)


func _poll_progress(progress_path: String, duration: float, on_progress: Callable) -> void:
	if not on_progress.is_valid():
		return
	var f: FileAccess = FileAccess.open(progress_path, FileAccess.READ)
	if f == null:
		return
	var text: String = f.get_as_text()
	f.close()
	var out_time_us: int = 0
	var speed: String = ""
	for raw_line: String in text.split("\n"):
		var line: String = raw_line.strip_edges()
		if line.begins_with("out_time_us="):
			out_time_us = line.substr(12).to_int()
		elif line.begins_with("out_time_ms="):
			out_time_us = line.substr(12).to_int()
		elif line.begins_with("speed="):
			speed = line.substr(6)
	var current_seconds: float = out_time_us / 1_000_000.0
	var progress: float = 0.0
	if duration > 0.0:
		progress = clampf(current_seconds / duration, 0.0, 1.0)
	on_progress.call(progress, current_seconds, duration, speed)
