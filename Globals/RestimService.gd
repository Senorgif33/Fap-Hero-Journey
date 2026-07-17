extends Node

## Thin T-code client for up to two Restim websocket servers.
## Slot "a" defaults to ws://127.0.0.1:12346/tcode; slot "b" to :12347/tcode.
## Restim requires the /tcode path — any other path is closed as 404.
## Sends the same axis format as SerialDeviceService — Restim routes L0→α, L1→β, E1–E4→FOC 4-phase.
## Destination "shared" fans a command out to every connected slot.

signal Connected(slot: String)
signal Disconnected(slot: String)
signal ErrorOccurred(slot: String, message: String)

const SLOTS: PackedStringArray = ["a", "b"]
const SLOT_SHARED: String = "shared"
const DEFAULT_URL_A: String = "ws://127.0.0.1:12346/tcode"
const DEFAULT_URL_B: String = "ws://127.0.0.1:12347/tcode"

var _peers: Dictionary = {}  # slot -> WebSocketPeer
var _connected: Dictionary = {}  # slot -> bool
var _want_connect: Dictionary = {}  # slot -> bool
var _urls: Dictionary = {}  # slot -> String


var RestimConnected: bool:
	get:
		return IsConnected("a") or IsConnected("b")


func _ready() -> void:
	for slot: String in SLOTS:
		_peers[slot] = WebSocketPeer.new()
		_connected[slot] = false
		_want_connect[slot] = false
		_urls[slot] = SettingsService.get_restim_url(slot)
	set_process(true)
	for slot: String in SLOTS:
		if SettingsService.get_restim_auto_connect(slot):
			var url: String = SettingsService.get_restim_url(slot)
			if url != "":
				Connect(slot, url)


func _process(_delta: float) -> void:
	for slot: String in SLOTS:
		_poll_slot(slot)


func _poll_slot(slot: String) -> void:
	var peer: WebSocketPeer = _peers[slot]
	peer.poll()
	var state: int = peer.get_ready_state()
	match state:
		WebSocketPeer.STATE_OPEN:
			if not bool(_connected[slot]):
				_connected[slot] = true
				Connected.emit(slot)
			while peer.get_available_packet_count() > 0:
				peer.get_packet()  # Restim T-code server is write-only for us; drain noise
		WebSocketPeer.STATE_CLOSING:
			pass
		WebSocketPeer.STATE_CLOSED:
			if bool(_connected[slot]):
				_connected[slot] = false
				Disconnected.emit(slot)
			elif bool(_want_connect[slot]):
				# Failed handshake / refused — surface once then stop retry spam this session.
				_want_connect[slot] = false
				var code: int = peer.get_close_code()
				ErrorOccurred.emit(slot, "Restim %s websocket closed (%d)" % [slot.to_upper(), code])


func IsConnected(slot: String) -> bool:
	return bool(_connected.get(slot, false))


func Connect(slot: String = "a", url: String = "") -> void:
	if slot == SLOT_SHARED:
		for s: String in SLOTS:
			Connect(s, url)
		return
	if not SLOTS.has(slot):
		ErrorOccurred.emit(slot, "Unknown Restim slot: %s" % slot)
		return
	Disconnect(slot)
	var resolved: String = url if url != "" else SettingsService.get_restim_url(slot)
	if resolved == "":
		resolved = DEFAULT_URL_A if slot == "a" else DEFAULT_URL_B
	resolved = SettingsService.ensure_restim_tcode_path(resolved)
	_urls[slot] = resolved
	_want_connect[slot] = true
	var err: Error = (_peers[slot] as WebSocketPeer).connect_to_url(resolved)
	if err != OK:
		_want_connect[slot] = false
		ErrorOccurred.emit(slot, "Restim %s connect failed: %s" % [slot.to_upper(), error_string(err)])


func Disconnect(slot: String = "") -> void:
	if slot == "" or slot == SLOT_SHARED:
		for s: String in SLOTS:
			Disconnect(s)
		return
	if not SLOTS.has(slot):
		return
	_want_connect[slot] = false
	var peer: WebSocketPeer = _peers[slot]
	if peer.get_ready_state() != WebSocketPeer.STATE_CLOSED:
		peer.close()
	if bool(_connected[slot]):
		_connected[slot] = false
		Disconnected.emit(slot)


func SendLinear(duration_ms: int, position: float) -> void:
	SendAxis(SLOT_SHARED, "L0", duration_ms, position)


## destination: "a", "b", or "shared" (fan-out to every connected slot).
func SendAxis(destination: String, tcode_axis: String, duration_ms: int, position: float) -> void:
	var ticks: int = clampi(roundi(clampf(position, 0.0, 1.0) * 9999.0), 0, 9999)
	var cmd: String = "%s%04dI%d\n" % [tcode_axis, ticks, maxi(0, duration_ms)]
	if destination == SLOT_SHARED or destination == "":
		for slot: String in SLOTS:
			_send_raw(slot, cmd)
		return
	_send_raw(destination, cmd)


func _send_raw(slot: String, cmd: String) -> void:
	if not SLOTS.has(slot) or not bool(_connected.get(slot, false)):
		return
	(_peers[slot] as WebSocketPeer).send_text(cmd)


func StopAll() -> void:
	for slot: String in SLOTS:
		if bool(_connected.get(slot, false)):
			(_peers[slot] as WebSocketPeer).send_text("DSTOP\n")


func _notification(what: int) -> void:
	if what != NOTIFICATION_WM_CLOSE_REQUEST and what != NOTIFICATION_EXIT_TREE:
		return
	if RestimConnected:
		StopAll()
	Disconnect()
