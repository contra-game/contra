## Интеграционный тест двух процессов через настоящий Photon.
## -- --role=host|client --room=<unique-room>
extends Node

var main: Node
var role := "host"
var failures := 0
var hits := 0
var capture_path := "res://build/network-proof.png"
## Объявления чужих смертей: при двух участниках строку киллфида показать некому
## (убийца отфильтрует своё же имя), поэтому проверяем сам факт доставки RPC.
var announced: Array[String] = []
var _deadline := 0
var grenade_damage_events := 0
const FIXTURE_HOST := Vector3(0, 60, 0)
const FIXTURE_CLIENT := Vector3(0, 60, 8)
const FIXTURE_BLAST := Vector3(0, 60.9, 4)

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
	Session.net.death_announced.connect(func(victim, killer, _head): announced.append(killer + "/" + victim))
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
	# Эти сценарии управляют здоровьем и респавном вручную; разминка не должна
	# одновременно сбрасывать их состояния. Цикл матча проверяется отдельно.
	main.match_flow_enabled = false
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
	main.player.combat_aiming = true
	main.player.combat_reload = 0.4
	main.player.combat_airborne = false
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
	_check(not get_tree().get_nodes_in_group("combat_ragdolls").is_empty(), "local death creates ragdoll")
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
	if not await _host_shared_systems():
		return
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
	_check(other.player.combat_aiming, "ADS pose synced")
	_check(absf(other.player.combat_reload - 0.4) < 0.05, "reload pose synced")
	_check(not other.player.combat_airborne, "grounded pose synced")
	_check(other.player.velocity.x > 2.0, "velocity synced")
	_check(other.player.display_name == "Test_host", "name synced")
	var ray_origin: Vector3 = other.player.global_position + Vector3(0, 0.6, 2.0)
	var hit: Dictionary = main.player.weapons._cast(ray_origin, Vector3.FORWARD, 3.0)
	_check(not hit.is_empty() and Damage.resolve_target(hit.collider) == other.player, "hitscan detects remote hurt volume")
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
	# Урон проверяет жертва и отбрасывает выстрелы без прямой видимости, а спавны
	# разнесены на полкарты. Встаём в двух метрах от цели — ровно ту линию только
	# что проверил hitscan выше — и ждём, пока новая позиция доедет до хоста:
	# видимость он считает по нашему реплицированному телу, а не по нашим словам.
	main.player.global_position = other.player.global_position + Vector3(0.0, 0.0, 2.0)
	await get_tree().create_timer(1.5).timeout
	# Урон по чужому бойцу описывается стволом: бронепробитие жертва берёт из
	# каталога, а не с провода, поэтому выстрел обязан быть из настоящего ствола.
	# 25 урона АК: 25 * lerp(0.45, 1.0, 0.72) = 21.15 по здоровью.
	Damage.apply(other.player, 25.0, main.player, false, 0.72, "ak47")
	if not await _until(func(): return _flag("damage_ok") and hits == 1, "hit acknowledged"):
		return
	if not await _until(func(): return absf(other.player.health.health - 78.85) < 0.01, "health replicated"):
		return
	# Завышенный урон обязан быть отброшен жертвой.
	var before: float = _other().net_health
	NetApi.rpc_to_player(_other().replicator.get_owner_id(), _other().apply_remote_damage,
		["glock", 999.0, true, _other().life_serial])
	await get_tree().create_timer(1.0).timeout
	_check(is_equal_approx(_other().net_health, before), "жертва отбросила урон 999 из глока")
	Damage.apply(other.player, 115.0, main.player, false, 0.95, "awp")
	if not await _until(func(): return main.kills == 1 and not other.player.health.alive, "kill and death replicated"):
		return
	# Смерть объявляет владелец цели: только он знает, кто именно убил.
	if not await _until(func(): return announced.has("Test_client/Test_host"), "death announced by target owner"):
		return
	_check(main.player.economy.money == 1100, "kill pays once")
	_check(not other.player._body_model.visible, "dead remote hidden")
	_check(not get_tree().get_nodes_in_group("combat_ragdolls").is_empty(), "remote death creates ragdoll")
	_check(other.death_push.is_finite() and other.death_push.length() > 0.5, "death impulse direction synced")
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
	var duplicate: bool = main.player.weapons.slots[slot_index].data.id == data.id
	if duplicate:
		main.player.weapons.slots[slot_index].reserve = 0
	main.player.position = pickup.position - Vector3.UP * 0.9
	await get_tree().create_timer(0.5).timeout
	pickup.pick_up(main.player)
	if not await _until(func(): return not pickup._available and main.player.weapons.slots[slot_index].data.id == data.id and (not duplicate or main.player.weapons.slots[slot_index].reserve > 0), "pickup granted and shared"):
		return
	_set_flag("pickup_ok")
	if not await _until(func(): return _flag("pickup_seen"), "host observed pickup"):
		return
	if not await _client_shared_systems():
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
	var taken_id := str(NetApi.room_property("test_taken_drop", ""))
	var late_id := str(NetApi.room_property("test_late_drop", ""))
	if not await _until(func(): return _inventory() != null and _inventory()._nodes.has(late_id), "late join receives unclaimed world inventory"):
		return
	var late_pickup := _freeze_drop(late_id)
	_check(late_pickup.weapon_id == &"deagle" and late_pickup.stored_mag == 2 and late_pickup.stored_reserve == 13, "late join preserves exact dropped magazine and reserve")
	_check(not _inventory()._nodes.has(taken_id), "late join does not recreate consumed drop")
	main.player.global_position = late_pickup.global_position - Vector3.UP
	await get_tree().create_timer(0.6).timeout
	_set_flag("rejoin_ok")
	if not await _until(func(): return Session.is_host() and _fighters().size() == 1, "host migration removes departed player"):
		return
	_inventory().request_pickup(late_id)
	if not await _until(func(): return main.player.weapons.current_data().id == &"deagle", "new master can claim inherited drop"):
		return
	_check(main.player.weapons.current().mag == 2 and main.player.weapons.current().reserve == 13, "host migration preserves exact ammunition on pickup")
	Session.leave()
	await get_tree().create_timer(1.0).timeout
	_finish()

func _host_shared_systems() -> bool:
	_fixture_position(FIXTURE_HOST)
	main.player.health.reset()
	main.player.health.damaged.connect(func(_amount, _attacker, _head): grenade_damage_events += 1)
	main.player.weapons._equip(int(WeaponData.Slot.MELEE), true)
	_set_flag("equipment_host_ready")
	if not await _until(func(): return _flag("equipment_client_ready") and _other().weapon_id == "grenade" and _other().player.global_position.distance_to(FIXTURE_CLIENT) < 0.05, "grenade slot replicated to victim"):
		return false
	_set_flag("grenade_receiver_ready")
	if not await _until(func(): return _grenade_from(_other().player.peer_id) != null, "remote grenade projectile spawned"):
		return false
	_set_flag("grenade_remote_seen")
	if not await _until(func(): return _hp_near(main.player.health.health), "victim confirms authoritative grenade explosion"):
		return false
	_check(_hp_near(main.player.health.health), "victim applies grenade falloff and armor once")
	_check(grenade_damage_events == 1, "victim emits one grenade damage event")
	_set_flag("grenade_victim_applied")
	if not await _until(func(): return _flag("grenade_client_done"), "thrower observed victim authority"):
		return false
	_check(grenade_damage_events == 1, "remote grenade replica does not duplicate victim damage")
	main.player.weapons.give(&"spas", true)
	main.player.weapons.current().mag = 3
	main.player.weapons.current().reserve = 11
	main.player.weapons.drop_current()
	if not await _until(func(): return not _find_drop("spas", 3, 11).is_empty(), "host drop published with exact ammunition"):
		return false
	var taken_id := _find_drop("spas", 3, 11)
	_freeze_drop(taken_id)
	NetApi.set_room_property("test_taken_drop", taken_id)
	_set_flag("drop_published")
	if not await _until(func(): return _flag("drop_claimed"), "client claimed dropped weapon"):
		return false
	_check(_inventory().drops[taken_id].taken, "host marks claimed drop as consumed")
	_check(not _find_drop("ak47", 7, 19).is_empty(), "master accepts replacement weapon dropped by remote client")
	_inventory().request_pickup(taken_id)
	_check(main.player.weapons.slots[int(WeaponData.Slot.PRIMARY)] == null, "second peer cannot claim consumed weapon")
	# Оставляем другой неприсвоенный предмет для позднего подключения и миграции.
	main.player.weapons.give(&"deagle", true)
	main.player.weapons.current().mag = 2
	main.player.weapons.current().reserve = 13
	main.player.weapons.drop_current()
	if not await _until(func(): return not _find_drop("deagle", 2, 13).is_empty(), "unclaimed drop published for late join"):
		return false
	var late_id := _find_drop("deagle", 2, 13)
	_freeze_drop(late_id)
	NetApi.set_room_property("test_late_drop", late_id)
	_set_flag("shared_systems_done")
	return true

func _client_shared_systems() -> bool:
	if not await _until(func(): return _flag("equipment_host_ready") and _other().weapon_id == "knife", "melee slot replicated to remote player"):
		return false
	_check(_other()._world_weapon != null and _other()._world_weapon.visible, "remote melee weapon has visible third person model")
	_fixture_position(FIXTURE_CLIENT)
	main.player.health.reset()
	main.player.health.damaged.connect(func(_amount, _attacker, _head): grenade_damage_events += 1)
	main.player.weapons._equip(int(WeaponData.Slot.GRENADE), true)
	await get_tree().create_timer(0.8).timeout
	_set_flag("equipment_client_ready")
	if not await _until(func(): return _flag("grenade_receiver_ready"), "victim received thrower position before equipment RPC"):
		return false
	var ammo_before: int = main.player.weapons.current().mag
	var thrown_at := Time.get_ticks_msec()
	main.player.weapons._fire_equipment(main.player.weapons.current_data())
	_check(main.player.weapons.current().mag == ammo_before - 1, "throw consumes exactly one grenade")
	var grenade := _hold_grenade(_grenade_from(main.player.peer_id))
	_check(grenade != null, "thrower creates local ballistic grenade")
	_set_flag("grenade_local_held")
	if not await _until(func(): return _flag("grenade_remote_seen"), "victim spawned remote grenade before explosion"):
		return false
	# Проверка сети допускает взрыв после срока запала; удерживаем только
	# положение локального снаряда, чтобы не зависеть от столкновений города.
	var fuse_wait := maxf(2.05 - float(Time.get_ticks_msec() - thrown_at) / 1000.0, 0.0)
	if fuse_wait > 0.0:
		await get_tree().create_timer(fuse_wait).timeout
	var remote_before: float = _other().player.health.health
	grenade.explode()
	_check(is_equal_approx(_other().player.health.health, remote_before), "thrower explosion does not mutate remote health locally")
	_check(_hp_near(main.player.health.health) and grenade_damage_events == 1, "thrower owns its own blast damage once")
	if not await _until(func(): return _flag("grenade_victim_applied") and _hp_near(_other().player.health.health), "grenade health replicated from victim"):
		return false
	remote_before = _other().player.health.health
	# Самостоятельный damage RPC для гранаты отвергается: её взрыв считает жертва.
	NetApi.rpc_to_player(_other().replicator.get_owner_id(), _other().apply_remote_damage, ["grenade", 20.0, false, _other().life_serial])
	var owner_wrapper := Damage._net_wrapper(main.player)
	NetApi.rpc_all(owner_wrapper.show_explosion, [owner_wrapper.life_serial, owner_wrapper._throw_serial, FIXTURE_BLAST])
	await get_tree().create_timer(0.7).timeout
	_check(is_equal_approx(_other().player.health.health, remote_before), "victim rejects direct grenade damage and duplicate explosion RPC")
	_set_flag("grenade_client_done")
	if not await _until(func(): return _flag("drop_published"), "shared dropped weapon published"):
		return false
	var taken_id := str(NetApi.room_property("test_taken_drop", ""))
	if not await _until(func(): return _inventory() != null and _inventory()._nodes.has(taken_id), "remote physical drop spawned"):
		return false
	var pickup := _freeze_drop(taken_id)
	_check(pickup.weapon_id == &"spas" and pickup.stored_mag == 3 and pickup.stored_reserve == 11, "remote drop preserves magazine and reserve separately")
	main.player.weapons.give(&"ak47", true)
	main.player.weapons.slots[int(WeaponData.Slot.PRIMARY)].mag = 7
	main.player.weapons.slots[int(WeaponData.Slot.PRIMARY)].reserve = 19
	main.player.global_position = pickup.global_position - Vector3.UP
	await get_tree().create_timer(0.8).timeout
	pickup.pick_up(main.player)
	_inventory().request_pickup(taken_id)
	if not await _until(func(): return main.player.weapons.current_data().id == &"spas", "master grants dropped weapon"):
		return false
	await get_tree().create_timer(0.7).timeout
	_check(main.player.weapons.current().mag == 3 and main.player.weapons.current().reserve == 11, "duplicate claim grants ammunition only once")
	_check(_inventory()._received.has(taken_id), "drop grant is recorded for deduplication")
	if not await _until(func(): return not _find_drop("ak47", 7, 19).is_empty(), "remote drop request retains replaced weapon and ammunition"):
		return false
	_set_flag("drop_claimed")
	return await _until(func(): return _flag("shared_systems_done"), "shared equipment and inventory stages complete")

func _fixture_position(at: Vector3) -> void:
	main.player.global_position = at
	main.player.velocity = Vector3.ZERO
	main.player.rotation = Vector3.ZERO
	main.player.look_yaw = 0.0
	main.player.look_pitch = 0.0
	main.player.head.rotation = Vector3.ZERO
	main.player.camera.position = Vector3.ZERO
	main.player.camera.rotation = Vector3.ZERO

func _inventory() -> Node:
	return get_tree().get_first_node_in_group("world_inventory")

func _find_drop(weapon: String, mag: int, reserve: int) -> String:
	var inventory := _inventory()
	if inventory == null:
		return ""
	for id in inventory.drops:
		var row: Dictionary = inventory.drops[id]
		if not row.taken and row.weapon == weapon and row.mag == mag and row.reserve == reserve:
			return str(id)
	return ""

func _hp_near(value: float) -> bool:
	# Fusion replicates float properties at network precision (±0.01 HP).
	return absf(value - 59.625) < 0.02

func _freeze_drop(id: String) -> WeaponPickup:
	var inventory := _inventory()
	var pickup: WeaponPickup = inventory._nodes.get(id)
	if pickup != null:
		pickup.get_parent().freeze = true
		pickup.get_parent().global_position = inventory.drops[id].position
	return pickup

func _grenade_from(peer: int) -> Node:
	for grenade in get_tree().get_nodes_in_group("grenades"):
		if is_instance_valid(grenade.thrower) and grenade.thrower.peer_id == peer:
			return grenade
	return null

func _hold_grenade(grenade: Node) -> Node:
	if grenade != null:
		grenade.freeze = true
		grenade.set_physics_process(false)
		grenade.global_position = FIXTURE_BLAST
	return grenade

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
	print("FAIL BUDGET ", role, " осталось ", _deadline - Time.get_ticks_msec(), " мс из общего дедлайна")
	for node in _fighters():
		print("FAIL STATE ", role, " local=", node.player.local_control, " peer=", node.player.peer_id, " owner=", node.replicator.get_owner_id(), " pos=", node.player.position, " yaw=", node.player.rotation.y, " weapon=", node.weapon_id, " life=", node.life_serial, " hp=", node.net_health)
	var inventory := _inventory()
	if inventory != null:
		for id in inventory.drops:
			var row: Dictionary = inventory.drops[id]
			print("FAIL DROP ", role, " id=", id, " weapon=", row.weapon, " ammo=", row.mag, "/", row.reserve, " taken=", row.taken, " node=", inventory._nodes.has(id))
	push_error("FAIL [" + role + "] " + label)
	Session.leave()
	get_tree().quit(1)

func _finish() -> void:
	print("NETWORK TEST ", role, ": ", "PASS" if failures == 0 else "FAIL", " failures=", failures)
	main.queue_free()
	await get_tree().process_frame
	get_tree().quit(0 if failures == 0 else 1)
