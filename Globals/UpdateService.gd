extends Node

# ---------------------------------------------------------------------------
# UpdateService  (autoload)
# The check is a single unauthenticated GET per launch (GitHub allows 60/hr/IP).
# Network is best-effort: a failure is silent (no banner), never blocking.
# ---------------------------------------------------------------------------

signal update_available(latest_version: String, release: Dictionary)
signal up_to_date
signal check_failed(reason: String)

signal download_started
signal download_progress(downloaded: int, total: int)  # total is -1 when unknown
signal download_ready(folder: String)  # extracted build dir (absolute)
signal download_failed(reason: String)

const REPO: String = "SaekoM/Fap-Hero-Journey"
const LATEST_URL: String = "https://api.github.com/repos/SaekoM/Fap-Hero-Journey/releases/latest"
const UA_HEADER: String = "User-Agent: FapHeroJourney-Updater"

var _http: HTTPRequest = null  # version check (signal-driven)
var _dl: HTTPRequest = null  # downloads (await-driven, no persistent connection)
var _downloading: bool = false
var _latest_release: Dictionary = {}

# Session state — the check runs once per launch; callers read these on re-entry
# (e.g. returning to the main menu) instead of re-firing the request.
var available_version: String = ""  # non-empty once a newer release is found
var _checked: bool = false


func has_update() -> bool:
	return available_version != ""


func checked() -> bool:
	return _checked


func _ready() -> void:
	_http = HTTPRequest.new()
	add_child(_http)
	_http.request_completed.connect(_on_check_completed)
	_dl = HTTPRequest.new()
	add_child(_dl)  # no persistent connection — the download flow uses await


func _process(_delta: float) -> void:
	if _downloading and _dl != null:
		download_progress.emit(_dl.get_downloaded_bytes(), _dl.get_body_size())


func current_version() -> String:
	return str(ProjectSettings.get_setting("application/config/version", ""))


# Public release page for the latest release (fallback to the generic /latest URL).
func release_url() -> String:
	return str(_latest_release.get("html_url", "https://github.com/%s/releases/latest" % REPO))


# Kicks off the async check. Runs at most once per session (re-entry is a no-op —
# read has_update()/available_version instead). Emits exactly one of
# update_available / up_to_date / check_failed.
func check_for_update() -> void:
	if _checked:
		return
	_checked = true
	# GitHub requires a User-Agent; the Accept header pins the API version.
	var headers: PackedStringArray = [
		"Accept: application/vnd.github+json",
		"User-Agent: FapHeroJourney-Updater",
	]
	var err: int = _http.request(LATEST_URL, headers)
	if err != OK:
		check_failed.emit("request error %d" % err)


func _on_check_completed(
	result: int, code: int, _headers: PackedStringArray, body: PackedByteArray
) -> void:
	if result != HTTPRequest.RESULT_SUCCESS or code != 200:
		check_failed.emit("HTTP %d (result %d)" % [code, result])
		return
	var parser: JSON = JSON.new()
	if parser.parse(body.get_string_from_utf8()) != OK or not (parser.data is Dictionary):
		check_failed.emit("malformed response")
		return

	var release: Dictionary = parser.data
	var latest: String = _normalize_version(str(release.get("tag_name", "")))
	if latest == "":
		check_failed.emit("no tag_name")
		return

	if _is_newer(latest, _normalize_version(current_version())):
		_latest_release = release
		available_version = latest
		update_available.emit(latest, release)
	else:
		up_to_date.emit()


# The release asset matching the running platform, or {} if none. Asset names
# follow "Fap Hero JOURNEY v<ver> - <Platform> Build" — but GitHub replaces spaces
# with dots on upload ("...-.Windows.Build.zip"), so we match the platform keyword
# plus "build" separator-agnostically rather than the literal phrase.
func platform_asset() -> Dictionary:
	var want: String = ""
	match OS.get_name():
		"Windows":
			want = "windows"
		"Linux", "FreeBSD", "NetBSD", "OpenBSD", "BSD":
			want = "linux"
		_:
			return {}
	for asset_variant in _latest_release.get("assets", []):
		var n: String = str(asset_variant.get("name", "")).to_lower()
		if want in n and "build" in n:
			return asset_variant
	return {}


# Strips a leading "v"/"V" from a tag so "v0.4.0" compares against "0.4.0".
func _normalize_version(s: String) -> String:
	s = s.strip_edges()
	if s.begins_with("v") or s.begins_with("V"):
		s = s.substr(1)
	return s


# Dotted numeric compare — true when `a` is strictly newer than `b`. Missing
# segments count as 0 (so "0.4" > "0.3.9"). Non-numeric suffixes are ignored.
func _is_newer(a: String, b: String) -> bool:
	var pa: PackedStringArray = a.split(".")
	var pb: PackedStringArray = b.split(".")
	var n: int = maxi(pa.size(), pb.size())
	for i in n:
		var va: int = int(pa[i]) if i < pa.size() else 0
		var vb: int = int(pb[i]) if i < pb.size() else 0
		if va != vb:
			return va > vb
	return false


# ── Phase 2: download → verify → extract beside the install → reveal ─────────


# Orchestrates the whole flow. Emits download_progress along the way, then exactly
# one of download_ready(folder) / download_failed(reason). The running app is
# never touched — the new build lands in a sibling folder the user launches.
func download_and_stage() -> void:
	var asset: Dictionary = platform_asset()
	if asset.is_empty():
		download_failed.emit("No build available for this platform (%s)." % OS.get_name())
		return
	var fname: String = str(asset.get("name", "update.zip"))
	download_started.emit()

	var zip_path: String = await _download_to_file(
		str(asset.get("browser_download_url", "")), fname
	)
	if zip_path == "":
		download_failed.emit("Download failed (network or server error).")
		return

	match await _verify_checksum(zip_path, fname):
		"mismatch":
			download_failed.emit("Checksum mismatch — the download looks corrupt. Not extracting.")
			return
		# "ok" / "skip" both proceed.

	var folder: String = _extract_beside(zip_path, fname)
	if folder == "":
		download_failed.emit("Could not extract the update (check folder write permission).")
		return

	OS.shell_open(folder)  # reveal the new build's folder in the file manager
	download_ready.emit(folder)


# Downloads `url` to user://updates/<fname>. Returns the path, or "" on failure.
func _download_to_file(url: String, fname: String) -> String:
	if url == "":
		return ""
	var dir: String = "user://updates"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
	var path: String = dir + "/" + fname
	_dl.download_file = path
	if _dl.request(url, [UA_HEADER, "Accept: application/octet-stream"]) != OK:
		return ""
	_downloading = true
	var res: Array = await _dl.request_completed
	_downloading = false
	download_progress.emit(1, 1)  # snap the bar to 100%
	# res = [result, response_code, headers, body]
	if int(res[0]) != HTTPRequest.RESULT_SUCCESS or int(res[1]) != 200:
		return ""
	return path


# Returns "ok" / "mismatch" / "skip". Skips (non-fatal) when the release ships no
# checksums file or the asset isn't listed in it.
func _verify_checksum(zip_path: String, fname: String) -> String:
	var ca: Dictionary = _checksums_asset()
	if ca.is_empty():
		return "skip"
	var text: String = await _fetch_text(str(ca.get("browser_download_url", "")))
	var expected: String = _hash_for(text, fname)
	if expected == "":
		return "skip"
	var actual: String = _sha256_file(zip_path)
	return "ok" if actual.to_lower() == expected.to_lower() else "mismatch"


# Downloads a small text asset (the checksums file) into memory.
func _fetch_text(url: String) -> String:
	if url == "":
		return ""
	_dl.download_file = ""  # to body, not a file
	if _dl.request(url, [UA_HEADER]) != OK:
		return ""
	var res: Array = await _dl.request_completed
	if int(res[0]) != HTTPRequest.RESULT_SUCCESS or int(res[1]) != 200:
		return ""
	return (res[3] as PackedByteArray).get_string_from_utf8()


# The release's checksums asset, if any (e.g. checksums.txt / *.sha256).
func _checksums_asset() -> Dictionary:
	for asset_variant in _latest_release.get("assets", []):
		var n: String = str(asset_variant.get("name", "")).to_lower()
		if "checksum" in n or n.ends_with(".sha256"):
			return asset_variant
	return {}


# Finds the SHA-256 for `filename` in a checksums file. Lines look like
# "<hash>  <filename>" (filenames may contain spaces — the hash is the 1st token).
func _hash_for(text: String, filename: String) -> String:
	for raw_line in text.split("\n"):
		var line: String = raw_line.strip_edges()
		if line != "" and filename in line:
			var parts: PackedStringArray = line.split(" ", false)
			if parts.size() >= 1:
				return parts[0].lstrip("*").strip_edges()
	return ""


# Streaming SHA-256 of a (possibly large) file → lowercase hex, "" on error.
func _sha256_file(path: String) -> String:
	var f: FileAccess = FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	var ctx: HashingContext = HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	while not f.eof_reached():
		var chunk: PackedByteArray = f.get_buffer(1 << 20)  # 1 MiB
		if chunk.size() > 0:
			ctx.update(chunk)
	f.close()
	return ctx.finish().hex_encode()


# Extracts the zip into a sibling folder of the install (named after the zip).
# In the editor it stages under user:// instead of writing next to the editor.
# Returns the absolute target folder, or "" on failure.
func _extract_beside(zip_path: String, fname: String) -> String:
	var reader: ZIPReader = ZIPReader.new()
	if reader.open(ProjectSettings.globalize_path(zip_path)) != OK:
		return ""
	var target: String = _install_base_dir().path_join(fname.get_basename())
	if (
		DirAccess.make_dir_recursive_absolute(target) != OK
		and not DirAccess.dir_exists_absolute(target)
	):
		reader.close()
		return ""
	for entry: String in reader.get_files():
		if entry.ends_with("/"):
			continue
		var out_path: String = target.path_join(entry)
		DirAccess.make_dir_recursive_absolute(out_path.get_base_dir())
		var fo: FileAccess = FileAccess.open(out_path, FileAccess.WRITE)
		if fo == null:
			reader.close()
			return ""
		fo.store_buffer(reader.read_file(entry))
		fo.close()
	reader.close()
	return target


# Where to extract — the parent of the install folder (so the new build sits
# beside the current one). In-editor, stage under user:// to avoid writing next
# to the Godot editor binary. Always an absolute OS path.
func _install_base_dir() -> String:
	if OS.has_feature("editor"):
		return ProjectSettings.globalize_path("user://updates/staged")
	return OS.get_executable_path().get_base_dir().get_base_dir()
