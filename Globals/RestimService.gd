extends Node

## Thin T-code client for Restim's websocket server (default ws://127.0.0.1:12346).
## Sends the same axis format as SerialDeviceService — Restim routes L0→α, L1→β, E1–E4→FOC 4-phase.

signal Connected
signal Disconnected
signal ErrorOccurred(message: String)

const DEFAULT_URL: String = "ws://127.0.0.1:12346"

var _peer: WebSocketPeer = WebSocketPeer.new()
var _connected: bool = false
var _want_connect: bool = false
var _url: String = DEFAULT_URL


var RestimConnected: bool:
	get:
		return _connected


func _ready() -> void:
	set_process(true)
	if SettingsService.get_restim_auto_connect():
		var url: String = SettingsService.get_restim_url()
		if url != "":
			Connect(url)


func _process(_delta: float) -> void:
	_peer.poll()
	var state: int = _peer.get_ready_state()
	match state:
		WebSocketPeer.STATE_OPEN:
			if not _connected:
				_connected = true
				Connected.emit()
			while _peer.get_available_packet_count() > 0:
				_peer.get_packet()  # Restim T-code server is write-only for us; drain noise
		WebSocketPeer.STATE_CLOSING:
			pass
		WebSocketPeer.STATE_CLOSED:
			if _connected:
				_connected = false
				Disconnected.emit()
			elif _want_connect:
				# Failed handshake / refused — surface once then stop retry spam this session.
				_want_connect = false
				var code: int = _peer.get_close_code()
				ErrorOccurred.emit("Restim websocket closed (%d)" % code)


func Connect(url: String = "") -> void:
	Disconnect()
	_url = url if url != "" else SettingsService.get_restim_url()
	if _url == "":
		_url = DEFAULT_URL
	_want_connect = true
	var err: Error = _peer.connect_to_url(_url)
	if err != OK:
		_want_connect = false
		ErrorOccurred.emit("Restim connect failed: %s" % error_string(err))


func Disconnect() -> void:
	_want_connect = false
	if _peer.get_ready_state() != WebSocketPeer.STATE_CLOSED:
		_peer.close()
	if _connected:
		_connected = false
		Disconnected.emit()


func SendLinear(duration_ms: int, position: float) -> void:
	SendAxis("L0", duration_ms, position)


func SendAxis(tcode_axis: String, duration_ms: int, position: float) -> void:
	if not _connected:
		return
	var ticks: int = clampi(roundi(clampf(position, 0.0, 1.0) * 9999.0), 0, 9999)
	var cmd: String = "%s%04dI%d\n" % [tcode_axis, ticks, maxi(0, duration_ms)]
	_peer.send_text(cmd)


func StopAll() -> void:
	if not _connected:
		return
	_peer.send_text("DSTOP\n")


func _notification(what: int) -> void:
	if what != NOTIFICATION_WM_CLOSE_REQUEST and what != NOTIFICATION_EXIT_TREE:
		return
	if _connected:
		StopAll()
	Disconnect()
