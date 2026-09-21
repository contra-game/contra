## Master arbitrates dropped-weapon claims; room state survives host migration.
extends Node

const MAX_DROPS := 24
var drops: Dictionary = {}
var _nodes: Dictionary = {}
var _poll: float = 0.0
var _serial: int = 0
var pending: Dictionary = {}
var _budget := RateLimiter.new(2.0, 6.0)

func _ready() -> void:
	add_to_group("world_inventory")
	if NetApi.is_in_room():
		NetApi.api().call("register_broadcast_receiver", self)

func _exit_tree() -> void:
	if NetApi.available():
		NetApi.api().call("unregister_broadcast_receiver", self)

func _process(delta: float) -> void:
	if not NetApi.is_in_room():
		return
	_poll -= delta
	if _poll > 0.0:
		return
	_poll = 0.15
	drops = _read_drops()
	for key in pending.keys():
		if drops.has(key):
			pending.erase(key)
		elif Time.get_ticks_msec() - int(pending[key].sent) > 400:
			_send_drop(key)
	var changed := false
	if NetApi.is_master_client():
		for id in drops.keys():
			if NetApi.network_time() - float(drops[id].time) > 30.0:
				drops.erase(id)
				changed = true
		if changed:
			_publish()
	_sync_nodes()

func request_drop(id: String, mag: int, reserve: int, at: Transform3D, motion: Vector3) -> void:
	_serial += 1
	var key := "%d:%d:%d" % [NetApi.local_player_id(), Time.get_ticks_msec(), _serial]
	pending[key] = {"weapon": id, "mag": mag, "reserve": reserve, "at": at, "motion": motion, "sent": 0}
	var actor := _actor(NetApi.local_player_id())
	if actor != null:
		actor.get_parent()._publish_inventory()
	_send_drop(key)

func _send_drop(key: String) -> void:
	var row: Dictionary = pending[key]
	row.sent = Time.get_ticks_msec()
	var position := _wire_vector(row.at.origin)
	var velocity := _wire_vector(row.motion)
	if NetApi.is_master_client():
		_accept_drop(NetApi.local_player_id(), key, row.weapon, row.mag, row.reserve, row.at, row.motion)
	else:
		NetApi.rpc_to_master(receive_drop, [key, row.weapon, row.mag, row.reserve, position, velocity])

@rpc("any_peer", "call_remote", "reliable")
func receive_drop(key: String, id: String, mag: int, reserve: int, position: Array, velocity: Array) -> void:
	if NetApi.is_master_client():
		var at := Transform3D(Basis.IDENTITY, _read_vector(position))
		var motion := _read_vector(velocity)
		if at.origin.is_finite() and motion.is_finite():
			_accept_drop(NetApi.rpc_sender(), key, id, mag, reserve, at, motion)

func _accept_drop(sender: int, key: String, id: String, mag: int, reserve: int, at: Transform3D, motion: Vector3) -> void:
	if not key.begins_with(str(sender) + ":") or key.length() > 80 or drops.has(key):
		return
	var actor := _actor(sender)
	var data := Weapons.get_weapon(StringName(id))
	if actor == null or data == null or not data.is_firearm() or not _budget.allow(sender):
		return
	if not at.origin.is_finite() or not motion.is_finite() or actor.global_position.distance_to(at.origin) > 6.0:
		return
	var owned := false
	if actor.local_control:
		owned = pending.has(key) and pending[key].weapon == id
	else:
		var snapshot = JSON.parse_string(actor.get_parent().inventory_manifest)
		if snapshot is Array:
			for slot in snapshot:
				if slot is Array and slot.size() == 4 and slot[0] == id and slot[3] == key:
					owned = mag >= 0 and reserve >= 0 and mag <= int(slot[1]) and reserve <= int(slot[2])
	if not owned:
		return
	# Read before mutation: a new master continues the same room-owned inventory.
	drops = _read_drops()
	while drops.size() >= MAX_DROPS:
		drops.erase(drops.keys()[0])
	drops[key] = {"weapon": id, "mag": clampi(mag, 0, data.magazine), "reserve": clampi(reserve, 0, data.reserve_ammo), "position": at.origin, "yaw": actor.rotation.y, "motion": motion.limit_length(12.0), "time": NetApi.network_time(), "taken": false}
	_publish()
	_sync_nodes()

func request_pickup(id: String) -> void:
	if NetApi.is_master_client():
		_claim(NetApi.local_player_id(), id)
	else:
		NetApi.rpc_to_master(receive_claim, [id])

@rpc("any_peer", "call_remote", "reliable")
func receive_claim(id: String) -> void:
	if NetApi.is_master_client():
		_claim(NetApi.rpc_sender(), id)

func _claim(sender: int, id: String) -> void:
	var actor := _actor(sender)
	if actor == null or not actor.health.alive or not drops.has(id) or drops[id].taken:
		return
	var pickup: WeaponPickup = _nodes.get(id)
	if not is_instance_valid(pickup) or actor.global_position.distance_to(pickup.global_position) > 3.8:
		return
	var ray := PhysicsRayQueryParameters3D.create(actor.global_position + Vector3.UP * 1.4, pickup.global_position, 1)
	if not actor.get_world_3d().direct_space_state.intersect_ray(ray).is_empty():
		return
	drops[id].taken = true
	drops[id].recipient = sender
	drops[id].returned = false
	_publish()
	pickup.set_available(false)
	var row: Dictionary = drops[id]
	if sender == NetApi.local_player_id():
		_apply_grant(id, row.weapon, row.mag, row.reserve)
	else:
		NetApi.rpc_to_player(sender, receive_grant, [id, row.weapon, row.mag, row.reserve])

@rpc("any_peer", "call_remote", "reliable")
func receive_grant(id: String, weapon: String, mag: int, reserve: int) -> void:
	var room := NetApi.room()
	if room != null and NetApi.rpc_sender() == int(room.call("get_master_client_id")):
		_apply_grant(id, weapon, mag, reserve)

var _received: Dictionary = {}
func _apply_grant(id: String, weapon: String, mag: int, reserve: int) -> void:
	if _received.has(id):
		return
	_received[id] = true
	var actor := _actor(NetApi.local_player_id())
	if actor == null:
		return
	var remaining := Vector2i(mag, reserve)
	if actor.health.alive:
		remaining = actor.weapons.receive_drop(StringName(weapon), mag, reserve)
		Sfx.play_3d(&"pickup", actor.global_position, 1.0, -2.0)
	if remaining != Vector2i.ZERO:
		if NetApi.is_master_client():
			_return_grant(NetApi.local_player_id(), id, remaining.x, remaining.y)
		else:
			NetApi.rpc_to_master(return_grant, [id, remaining.x, remaining.y])

@rpc("any_peer", "call_remote", "reliable")
func return_grant(id: String, mag: int, reserve: int) -> void:
	if NetApi.is_master_client():
		_return_grant(NetApi.rpc_sender(), id, mag, reserve)

func _return_grant(sender: int, id: String, mag: int, reserve: int) -> void:
	# Unused ammunition belongs to the original grant, so it does not spend the
	# player's drop budget. The receipt permits one bounded return only.
	if not drops.has(id):
		return
	var row: Dictionary = drops[id]
	if not row.taken or row.get("recipient", -1) != sender or row.get("returned", false):
		return
	if mag < 0 or reserve < 0 or mag + reserve > int(row.mag) + int(row.reserve):
		return
	row.returned = true
	var returned: Dictionary = row.duplicate()
	returned.mag = mag
	returned.reserve = reserve
	returned.taken = false
	returned.time = NetApi.network_time()
	drops[id + ":remainder"] = returned
	_publish()
	_sync_nodes()

func _publish() -> void:
	# Photon room properties support scalar/string values; nested Godot Variant
	# dictionaries are not round-tripped by this SDK. Vectors use explicit XYZ.
	var wire: Dictionary = drops.duplicate(true)
	for id in wire:
		var row: Dictionary = wire[id]
		for key in ["position", "motion"]:
			var v: Vector3 = row[key]
			row[key] = [v.x, v.y, v.z]
	NetApi.set_room_property("world_drops", JSON.stringify(wire))

func _read_drops() -> Dictionary:
	var encoded = NetApi.room_property("world_drops", "")
	if not encoded is String or encoded.is_empty():
		return {}
	var parsed = JSON.parse_string(encoded)
	if not parsed is Dictionary:
		return {}
	var result: Dictionary = {}
	for id in parsed.keys().slice(0, MAX_DROPS * 2):
		var row = parsed[id]
		if not row is Dictionary or not row.has_all(["weapon", "mag", "reserve", "position", "motion", "yaw", "time", "taken"]):
			continue
		var valid := true
		for key in ["position", "motion"]:
			var xyz = row[key]
			if not xyz is Array or xyz.size() != 3:
				valid = false
				break
			var v := Vector3(float(xyz[0]), float(xyz[1]), float(xyz[2]))
			if not v.is_finite():
				valid = false
				break
			row[key] = v
		if valid:
			result[id] = row
	return result

func _sync_nodes() -> void:
	for id in _nodes.keys():
		if not drops.has(id) or drops[id].taken:
			if is_instance_valid(_nodes[id]):
				_nodes[id].get_parent().queue_free()
			_nodes.erase(id)
	for id in drops:
		var row: Dictionary = drops[id]
		if row.taken or _nodes.has(id):
			continue
		var at := Transform3D(Basis(Vector3.UP, row.yaw), row.position)
		_nodes[id] = WeaponPickup.spawn_drop(get_parent(), StringName(row.weapon), row.mag, row.reserve, at, row.motion, id)

func _actor(id: int) -> PlayerCharacter:
	for node in get_tree().get_nodes_in_group("combatants"):
		if node is PlayerCharacter and node.peer_id == id:
			return node
	return null

func _wire_vector(value: Vector3) -> Array:
	return [value.x, value.y, value.z]

func _read_vector(value: Array) -> Vector3:
	if value.size() != 3:
		return Vector3.INF
	return Vector3(float(value[0]), float(value[1]), float(value[2]))
