## One room snapshot carries the phase deadline and round results. A migrated
## master resumes that deadline using Photon time, without restarting the round.
extends Node

signal phase_changed(phase: int, round_index: int)

enum Phase { WARMUP, ACTIVE, ROUND_END, POST_MATCH }
const ROOM_KEY := "match_flow_state"
const TOTAL_ROUNDS := 3
const FRAG_LIMIT := 20

var warmup_seconds: float = 8.0
var active_seconds: float = 180.0
var round_end_seconds: float = 5.0
var post_match_seconds: float = 10.0
var phase: Phase = Phase.WARMUP
var round_index: int = 1
var snapshot: Dictionary = {}
var online: bool = false
var seed_value: int = 0
var score_provider: Callable
var _elapsed: float = 0.0
var _poll_left: float = 0.0
var _seen_revision: int = -1

func _ready() -> void:
	add_to_group("match_flow")

func configure(networked: bool, map_seed: int, scores: Callable) -> void:
	online = networked
	seed_value = map_seed
	score_provider = scores
	if online:
		_read_room()
	if snapshot.is_empty() and _is_authority():
		_publish(Phase.WARMUP, 1, warmup_seconds, {})

func _process(delta: float) -> void:
	tick(delta)

func tick(delta: float) -> void:
	_elapsed += delta
	_poll_left -= delta
	if online and _poll_left <= 0.0:
		_poll_left = 0.15
		_read_room()
	if not _is_authority():
		return
	if snapshot.is_empty():
		_publish(Phase.WARMUP, 1, warmup_seconds, {})
		return
	if phase == Phase.ACTIVE:
		var scores: Dictionary = score_provider.call() if score_provider.is_valid() else {}
		var reached_limit := false
		for row in scores.values():
			reached_limit = reached_limit or int(row.get("frags", 0)) >= FRAG_LIMIT
		if reached_limit or seconds_left() <= 0.0:
			_finish_round(scores)
		return
	if seconds_left() > 0.0:
		return
	match phase:
		Phase.WARMUP:
			_publish(Phase.ACTIVE, round_index, active_seconds, snapshot.get("wins", {}))
		Phase.ROUND_END:
			if round_index >= TOTAL_ROUNDS:
				_publish(Phase.POST_MATCH, round_index, post_match_seconds, snapshot.get("wins", {}), snapshot.get("result", ""))
			else:
				_publish(Phase.ACTIVE, round_index + 1, active_seconds, snapshot.get("wins", {}))
		Phase.POST_MATCH:
			_publish(Phase.WARMUP, 1, warmup_seconds, {})

func allows_combat() -> bool:
	return not snapshot.is_empty() and (phase == Phase.WARMUP or phase == Phase.ACTIVE)

func scores_enabled() -> bool:
	return not snapshot.is_empty() and phase == Phase.ACTIVE

func seconds_left() -> float:
	return maxf(float(snapshot.get("end_at", _now())) - _now(), 0.0)

func label() -> String:
	match phase:
		Phase.WARMUP:
			return "РАЗМИНКА · %d" % ceili(seconds_left())
		Phase.ACTIVE:
			var seconds := ceili(seconds_left())
			return "РАУНД %d/%d · %02d:%02d · ДО %d ФРАГОВ" % [round_index, TOTAL_ROUNDS, seconds / 60, seconds % 60, FRAG_LIMIT]
		Phase.ROUND_END:
			return "%s · следующий раунд через %d" % [snapshot.get("result", "РАУНД ОКОНЧЕН"), ceili(seconds_left())]
		_:
			return "МАТЧ ОКОНЧЕН · %s · новая разминка через %d" % [_match_result(), ceili(seconds_left())]

func _finish_round(scores: Dictionary) -> void:
	var highest := 0
	var leaders: Array[String] = []
	for id in scores:
		var frags := int(scores[id].get("frags", 0))
		if frags > highest:
			highest = frags
			leaders = [str(id)]
		elif frags == highest:
			leaders.append(str(id))
	var wins: Dictionary = snapshot.get("wins", {}).duplicate(true)
	var result := "НИЧЬЯ"
	if leaders.size() == 1 and highest > 0:
		var id := leaders[0]
		var name_value := str(scores[id].get("name", id)).substr(0, 24)
		var row: Dictionary = wins.get(id, {"name": name_value, "rounds": 0})
		row["rounds"] = int(row.get("rounds", 0)) + 1
		row["name"] = name_value
		wins[id] = row
		result = "%s выиграл раунд (%d)" % [name_value, highest]
	_publish(Phase.ROUND_END, round_index, round_end_seconds, wins, result)

func _match_result() -> String:
	var best := 0
	var winners: Array[String] = []
	for row in snapshot.get("wins", {}).values():
		var count := int(row.get("rounds", 0))
		if count > best:
			best = count
			winners = [str(row.get("name", ""))]
		elif count == best:
			winners.append(str(row.get("name", "")))
	return "победитель: %s" % winners[0] if winners.size() == 1 else "ничья"

func _now() -> float:
	return NetApi.network_time() if online else _elapsed

func _is_authority() -> bool:
	return not online or NetApi.is_master_client()

func _publish(next: Phase, next_round: int, duration: float, wins: Dictionary, result: String = "") -> void:
	var state := {"seed": seed_value, "revision": int(snapshot.get("revision", 0)) + 1, "phase": int(next), "round": next_round, "end_at": _now() + duration, "wins": wins, "result": result}
	if online:
		# This SDK's room properties support primitive values, not Variant maps.
		NetApi.set_room_property(ROOM_KEY, JSON.stringify(state))
	accept_snapshot(state)

func _read_room() -> void:
	var payload = NetApi.room_property(ROOM_KEY, "")
	if payload is String and not payload.is_empty():
		var state = JSON.parse_string(payload)
		if state is Dictionary:
			accept_snapshot(state)

func accept_snapshot(state: Dictionary) -> bool:
	if not state.get("wins", {}) is Dictionary or not state.get("result", "") is String:
		return false
	if int(state.get("seed", -1)) != seed_value or int(state.get("revision", -1)) <= _seen_revision:
		return false
	var next := int(state.get("phase", -1))
	var next_round := int(state.get("round", 0))
	var deadline := float(state.get("end_at", -1.0))
	if next < Phase.WARMUP or next > Phase.POST_MATCH or next_round < 1 or next_round > TOTAL_ROUNDS or not is_finite(deadline):
		return false
	snapshot = state.duplicate(true)
	_seen_revision = int(state.revision)
	phase = next as Phase
	round_index = next_round
	phase_changed.emit(phase, round_index)
	return true
