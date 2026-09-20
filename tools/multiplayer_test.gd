## Интеграционный тест двух процессов через настоящий Photon.
## -- --role=host|client --room=<unique-room>
extends Node

var main: Node
var role := "host"
var failures := 0
var hits := 0
var capture_path := "res://build/network-proof.png"
var _deadline := 0

func _ready() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--role="):
			role = arg.trim_prefix("--role=")
		if arg.begins_with("--room="):
			Session.room_name = arg.trim_prefix("--room=")
		if arg.begins_with("--capture-output="):
			capture_path = arg.trim_prefix("--capture-output=")
	_deadline = Time.get_ticks_msec() + 100000
	Session.player_name = "Test_" + role
	Session.match_started.connect(func(_value): Session.online = true)
	if not await Session.connect_and_join():
		_fail("connection")
		return
	if role == "host":
		if not await _until(func(): return Session.players().size() == 2, "second peer joins"):
			return
		Session.start_match()
	else:
		Session.watch_match_start()
	if not await _until(func(): return Session.match_seed != 0, "match seed"):
		return
	await _create_match()
	if not await _until(func(): return _fighters().size() == 2 and main.player != null, "both spawned"):
		return
	main.player.set_physics_process(false)
	print("STATE [", role, "] local id=", main.player.peer_id, " pos=", main.player.position, " other id=", _other().player.peer_id, " pos=", _other().player.position)
	main.player.weapons.hit_confirmed.connect(func(_head, _killed): hits += 1)
	await get_tree().create_timer(1.0).timeout
	_check(main.player.camera.current, "local camera remains current")
	_check(not _other().player.camera.current, "remote camera inactive")
	_check(not _other().player.weapon_pivot.visible, "remote first-person arms hidden")
	_check(_other().player._body_model != null and _other().player._body_model.visible, "remote character visible")
	_check(main.player.global_position.distance_to(_other().player.global_position) > 2.0, "different spawn points")
	_check(main.player.weapons._view_model.is_visible_in_tree(), "local weapon visible")
	_set_flag(role + "_ready")
	if role == "host":
		await _host()
	else:
		await _client()

func _create_match() -> void:
	main = load("res://scenes/main.tscn").instantiate()
	main.name = "Match"
	add_child(main)
	await get_tree().process_frame

func _host() -> void:
	if not await _until(func(): return _flag("client_ready"), "client ready"):
		return
	main.player.position += Vector3(2, 0, 1)
	main.player.rotation.y = 1.2
	main.player.look_pitch = 0.3
	main.player.velocity = Vector3(3, 0, 0)
	main.player.crouching = true
	main.player.weapons._equip(1, true)
	_set_flag("movement")
	if not await _until(func(): return _flag("movement_ok"), "movement replicated"):
		return
	if not await _until(func(): return main.player.health.health < 100.0, "damage received"):
		return
	_check(is_equal_approx(main.player.health.health, 78.85), "armor penetration from catalog")
	_set_flag("damage_ok")
	if not await _until(func(): return main.deaths == 1, "death counted"):
		return
	_check(not main.player.health.alive, "owner dead")
	_check(main.player.collision_layer == 0, "dead body not hittable")
	_set_flag("death_ok")
	if not await _until(func(): return main.player.health.alive, "respawn"):
		return
	_check(main.player.weapons.ammo_text() == "30 / 90", "respawn restores ammo")
	_check(main.player.collision_layer == 2, "respawn restores collision")
	_set_flag("respawn_ok")
	if not await _until(func(): return _flag("pickup_ok"), "shared pickup"):
		return
	_check(not Session.net._pickups[0]._available, "pickup hidden on host")
	_set_flag("pickup_seen")
	if not await _until(func(): return _flag("rejoin_ok"), "client rejoined"):
		return
	_check(_fighters().size() == 2, "no ghost after rejoin")
	_set_flag("host_leaving")
	Session.leave()
	await get_tree().create_timer(1.0).timeout
	_finish()

func _client() -> void:
	if not await _until(func(): return _flag("movement"), "host movement"):
		return
	var other := _other()
	if not await _until(func(): return absf(angle_difference(other.player.rotation.y, 1.2)) < 0.05 and other.weapon_id == "glock", "rotation and weapon sync"):
		return
	_check(absf(other.player.look_pitch - 0.3) < 0.05, "pitch synced")
	_check(other.player.crouching, "crouch synced")
	_check(other.player.velocity.x > 2.0, "velocity synced")
	_check(other.player.display_name == "Test_host", "name synced")
	var ray_origin: Vector3 = other.player.global_position + Vector3(0, 0.6, 2.0)
	var hit: Dictionary = main.player.weapons._cast(ray_origin, Vector3.FORWARD, 3.0)
	_check(hit.get("collider") == other.player, "hitscan detects remote body")
	if OS.get_cmdline_user_args().has("--capture"):
		main.player.input_enabled = false
		var target: Vector3 = other.player.global_position + Vector3.UP * 0.6
		for i in 16:
			var angle: float = i * TAU / 16.0
			var eye := target + Vector3(sin(angle) * 3.0, 0.8, cos(angle) * 3.0)
			var query := PhysicsRayQueryParameters3D.create(target, eye, 1)
			if main.player.get_world_3d().direct_space_state.intersect_ray(query).is_empty():
				main.player.camera.global_position = eye
				main.player.camera.look_at(target)
				print("CAPTURE eye=", eye, " target=", target, " camera=", get_viewport().get_camera_3d().get_path())
				break
		await RenderingServer.frame_post_draw
		await RenderingServer.frame_post_draw
		_check(get_viewport().get_texture().get_image().save_png(capture_path) == OK, "capture saved")
	_set_flag("movement_ok")
	# Урон по чужому бойцу описывается стволом: бронепробитие жертва берёт из
	# каталога, а не с провода, поэтому выстрел обязан быть из настоящего ствола.
	# 25 урона АК: 25 * lerp(0.45, 1.0, 0.72) = 21.15 по здоровью.
	Damage.apply(other.player, 25.0, main.player, false, 0.72, "ak47")
	if not await _until(func(): return _flag("damage_ok") and hits == 1, "hit acknowledged"):
		return
	if not await _until(func(): return absf(other.player.health.health - 78.85) < 0.01, "health replicated"):
		return
	Damage.apply(other.player, 115.0, main.player, false, 0.95, "awp")
	if not await _until(func(): return main.kills == 1 and not other.player.health.alive, "kill and death replicated"):
		return
	_check(main.player.economy.money == 1100, "kill pays once")
	_check(not other.player._body_model.visible, "dead remote hidden")
	if not await _until(func(): return _flag("respawn_ok") and other.player.health.alive, "remote respawn"):
		return
	_check(other.weapon_id == "ak47", "respawn weapon synced")
	_check(other.deaths == 1, "remote deaths synced")
	main.hud.toggle_pause()
	_check(not get_tree().paused and not main.player.input_enabled, "online menu keeps network running")
	main.hud.toggle_pause()
	main.hud._refresh_scoreboard()
	_check("Test_host" in main.hud._score_rows.text and "1 / 0" in main.hud._score_rows.text, "scoreboard shows players and score")
	var pickup: WeaponPickup = Session.net._pickups[0]
	var data := Weapons.get_weapon(pickup.weapon_id)
	var slot_index := 0 if data.slot == WeaponData.Slot.PRIMARY else 1
	if main.player.weapons.slots[slot_index].data.id == data.id:
		main.player.weapons.slots[slot_index].reserve = 0
	main.player.position = pickup.position - Vector3.UP * 0.9
	await get_tree().create_timer(0.5).timeout
	pickup.pick_up(main.player)
	if not await _until(func(): return not pickup._available and main.player.weapons.current_data().id == data.id, "pickup granted and shared"):
		return
	_set_flag("pickup_ok")
	if not await _until(func(): return _flag("pickup_seen"), "host observed pickup"):
		return
	Session.leave()
	main.queue_free()
	await get_tree().create_timer(1.0).timeout
	if not await Session.connect_and_join():
		_fail("rejoin connection")
		return
	Session.watch_match_start()
	if not await _until(func(): return Session.match_seed != 0, "late join gets active match"):
		return
	await _create_match()
	if not await _until(func(): return _fighters().size() == 2 and main.player != null, "late join receives both players"):
		return
	main.player.set_physics_process(false)
	await get_tree().create_timer(1.0).timeout
	_check(main.player.camera.current, "camera survives rejoin")
	_set_flag("rejoin_ok")
	if not await _until(func(): return Session.is_host() and _fighters().size() == 1, "host migration removes departed player"):
		return
	Session.leave()
	await get_tree().create_timer(1.0).timeout
	_finish()

func _fighters() -> Array:
	if not is_instance_valid(main):
		return []
	return main.actors.get_children().filter(func(n): return n.has_method("apply_remote_damage"))

func _other() -> Node:
	for n in _fighters():
		if not n.player.local_control:
			return n
	return null

func _set_flag(key: String) -> void:
	Fusion.get_room().set_property("test_" + key, true)

func _flag(key: String) -> bool:
	var room := Fusion.get_room()
	return room != null and room.get_custom_properties().get("test_" + key, false)

func _until(predicate: Callable, label: String) -> bool:
	var end := mini(Time.get_ticks_msec() + 16000, _deadline)
	while Time.get_ticks_msec() < end:
		if predicate.call():
			print("PASS [", role, "] ", label)
			return true
		await get_tree().create_timer(0.05).timeout
	_fail(label)
	return false

func _check(ok: bool, label: String) -> void:
	if not ok:
		failures += 1
	print("PASS" if ok else "FAIL", " [", role, "] ", label)

func _fail(label: String) -> void:
	failures += 1
	for node in _fighters():
		print("FAIL STATE ", role, " local=", node.player.local_control, " peer=", node.player.peer_id, " owner=", node.replicator.get_owner_id(), " pos=", node.player.position, " yaw=", node.player.rotation.y, " weapon=", node.weapon_id, " life=", node.life_serial, " hp=", node.net_health)
	push_error("FAIL [" + role + "] " + label)
	Session.leave()
	get_tree().quit(1)

func _finish() -> void:
	print("NETWORK TEST ", role, ": ", "PASS" if failures == 0 else "FAIL", " failures=", failures)
	main.queue_free()
	await get_tree().process_frame
	get_tree().quit(0 if failures == 0 else 1)
