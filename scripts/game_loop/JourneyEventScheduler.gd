class_name JourneyEventScheduler
extends RefCounted
## Pure fire-once decision logic for journey.json Events[] → Vector EVT.
## Driven by round video position (not session T0). GameLoop applies SendEvt.
##
## Fire when `pos_ms >= time_ms - lookahead_ms`. Seek policy (v1):
##   • forward past due points → catch-up fire once
##   • backward past a fire point → re-arm (clear fired) so it can play again
## Pause is a no-op: position stops moving.

var _events: Array = []  # sorted by time_ms; each dict is a runtime event
var _fired: Dictionary = {}  # index → true
var _lookahead_ms: int = 2000
var _pos_ms: int = -1


func load_events(events: Array, lookahead_ms: int = 2000) -> void:
	_events = []
	for e: Variant in events:
		if e is Dictionary:
			_events.append((e as Dictionary).duplicate(true))
	_events.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return int(a.get("time_ms", 0)) < int(b.get("time_ms", 0))
	)
	_lookahead_ms = maxi(0, lookahead_ms)
	_fired.clear()
	_pos_ms = -1


func set_lookahead_ms(ms: int) -> void:
	_lookahead_ms = maxi(0, ms)


func lookahead_ms() -> int:
	return _lookahead_ms


func clear() -> void:
	_events.clear()
	_fired.clear()
	_pos_ms = -1


func is_idle() -> bool:
	return _events.is_empty()


## Advances to `pos_ms` and returns events that should fire this tick (in time order).
func tick(pos_ms: int) -> Array:
	if _pos_ms >= 0 and pos_ms < _pos_ms:
		_rearm_after_backward_seek(pos_ms)
	_pos_ms = pos_ms

	var out: Array = []
	for i: int in _events.size():
		if _fired.has(i):
			continue
		var fire_at: int = int(_events[i].get("time_ms", 0)) - _lookahead_ms
		if pos_ms >= fire_at:
			_fired[i] = true
			out.append(_events[i])
	return out


func _rearm_after_backward_seek(pos_ms: int) -> void:
	# Clear fired entries whose fire point is still ahead of (or at) the new position.
	var to_clear: Array = []
	for i: Variant in _fired:
		var fire_at: int = int(_events[int(i)].get("time_ms", 0)) - _lookahead_ms
		if fire_at > pos_ms:
			to_clear.append(i)
	for i: Variant in to_clear:
		_fired.erase(i)
