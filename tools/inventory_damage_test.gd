## Real ray/physics checks for hurt zones, dropped ammo and grenade cover.
extends Node3D

const Hitboxes = preload("res://scripts/combat_hitboxes.gd")
const Grenade = preload("res://scripts/thrown_grenade.gd")
const STILL := {"speed": 0.0, "on_floor": true, "crouching": false, "sprinting": false}
var checks := 0
var failures := 0
var _rendered_centers: Array[Vector3] = []

class TestActor extends CharacterBody3D:
	var health: Health
	var weapons: WeaponManager
	var camera: Camera3D
	var local_control := false
	var input_enabled := false
	var shop_open := false
	var crouching := false
	var _body_model: Node3D
	var _character_model: Node3D
	var peer_id := 0
	func is_dead() -> bool:
		return not health.alive
	func _movement_state() -> Dictionary:
		return {"speed": 0.0, "on_floor": true, "crouching": false, "sprinting": false}

class TestAuthority extends RefCounted:
	var mine := false
	func has_authority() -> bool:
		return mine

class TestWrapper extends Node3D:
	var replicator := TestAuthority.new()
	var life_serial := 0
	func apply_remote_damage(_id: String, _amount: float, _headshot: bool, _life: int) -> void:
		pass
	func confirm_hit(_attacker: int, _headshot: bool, _killed: bool, _life: int) -> void:
		pass

func _ready() -> void:
	Effects.prewarm(self)
	await _test_hit_zones()
	await _test_animated_hit_zones()
	await _test_inventory()
	await _test_grenades()
	print("INVENTORY DAMAGE TEST: ", "PASS" if failures == 0 else "FAIL", " checks=", checks, " failures=", failures)
	get_tree().quit(0 if failures == 0 else 1)

func _test_hit_zones() -> void:
	var target := _actor(Vector3.ZERO)
	var shooter := _actor(Vector3(0, 0, 4))
	await _physics()
	var space := get_world_3d().direct_space_state
	var data: WeaponData = Weapons.get_weapon(&"ak47").duplicate()
	data.damage = 10.0
	for row: Array in [[&"head", Vector3(0, 1.65, 0)], [&"body", Vector3(0, 1.15, 0)], [&"limb", Vector3(-0.13, 0.35, 0)]]:
		var point: Vector3 = row[1]
		var ray := Damage.raycast(space, point + Vector3.BACK * 3, point + Vector3.FORWARD * 2, shooter)
		_check(not ray.is_empty() and Damage.hit_zone(ray.collider, ray.position) == row[0], "physical ray resolves %s volume" % row[0])
		if not ray.is_empty():
			_check(Damage.resolve_target(ray.collider) == target and Damage.find_health(ray.collider) == target.health, "hurt area resolves owning Health")
			var tally: Dictionary = {}
			target.health.reset()
			shooter.weapons._tally_hit(ray, data, point + Vector3.BACK * 3, self, tally)
			shooter.weapons._apply_tally(target, data, tally[target])
			_check(is_equal_approx(target.health.health, 100.0 - 10.0 * Damage.zone_multiplier(data, row[0])), "%s multiplier reaches centralized damage" % row[0])
	var gap := Damage.raycast(space, Vector3(0.34, 0.7, 3), Vector3(0.34, 0.7, -2), shooter)
	_check(gap.is_empty(), "movement capsule does not fill gaps between hurt volumes")
	var through_self := Damage.raycast(space, Vector3(0, 1.65, 6), Vector3(0, 1.65, -2), shooter)
	_check(not through_self.is_empty() and Damage.resolve_target(through_self.collider) == target, "shooter capsule and all shooter hurt volumes are excluded")
	var wall := _wall(Vector3(0, 1, 1.4), Vector3(2, 2.5, 0.2))
	await _physics()
	var blocked := Damage.raycast(space, Vector3(0, 1.65, 3), Vector3(0, 1.65, -2), shooter)
	_check(not blocked.is_empty() and blocked.collider == wall, "world wall terminates hitscan before head volume")
	wall.queue_free()
	target.crouching = true
	await _physics()
	var standing := Damage.raycast(space, Vector3(0, 1.65, 3), Vector3(0, 1.65, -2), shooter)
	var crouched := Damage.raycast(space, Vector3(0, 1.1, 3), Vector3(0, 1.1, -2), shooter)
	_check(standing.is_empty(), "crouch removes standing head volume")
	_check(not crouched.is_empty() and Damage.hit_zone(crouched.collider, crouched.position) == &"head", "crouched head volume follows lower posture")
	target.health.reset()
	target.health.armor = 50.0
	var armored := Damage.apply(target, 40, shooter, false, 0.0)
	target.health.reset()
	target.health.armor = 50.0
	var piercing := Damage.apply(target, 40, shooter, false, 1.0)
	_check(armored < piercing and is_equal_approx(piercing, 40.0), "catalog penetration changes armor absorption")
	target.health.take_damage(1000, shooter, false, 1.0)
	await _physics()
	_check(Damage.raycast(space, Vector3(0, 1.1, 3), Vector3(0, 1.1, -2), shooter).is_empty(), "dead actor no longer absorbs hurt-volume hitscan")
	target.queue_free()
	shooter.queue_free()
	await _physics()

func _test_inventory() -> void:
	var actor := _actor(Vector3(20, 0, 0))
	actor.local_control = true
	var manager := actor.weapons
	_check(manager.slots.size() == 4 and manager.slots[2].data.id == &"knife" and manager.slots[3].data.id == &"grenade", "loadout contains primary, secondary, knife and grenades")
	manager._equip_left = 0.0
	manager.current().mag = 7
	manager.current().reserve = 19
	manager.drop_current()
	_check(manager.slots[0] == null and manager.current_data().id == &"knife", "dropping removes firearm and equips melee")
	var dropped := _pickup(&"ak47")
	_check(dropped != null and dropped.stored_mag == 7 and dropped.stored_reserve == 19, "ground weapon preserves exact magazine and reserve")
	if dropped != null:
		dropped.pick_up(actor)
		_check(manager.current_data().id == &"ak47" and manager.current().mag == 7 and manager.current().reserve == 19, "pickup restores exact ammunition")
		_check(not dropped._available and dropped.get_parent().is_queued_for_deletion(), "consumed drop cannot be picked up twice")
	var data := manager.current_data()
	manager.current().reserve = data.reserve_ammo - 3
	var duplicate := WeaponPickup.spawn_drop(self, data.id, 5, 12, Transform3D(Basis.IDENTITY, actor.position + Vector3.UP), Vector3.ZERO)
	duplicate.pick_up(actor)
	_check(manager.current().mag == 7 and manager.current().reserve == data.reserve_ammo, "duplicate transfers only fitting reserve, preserving loaded magazine")
	_check(duplicate._available and duplicate.stored_mag + duplicate.stored_reserve == 14, "unconsumed duplicate ammunition stays on ground")
	var before_left := duplicate.stored_mag + duplicate.stored_reserve
	duplicate.pick_up(actor)
	_check(duplicate.stored_mag + duplicate.stored_reserve == before_left, "full inventory leaves duplicate unchanged")
	manager.current().reserve -= 14
	duplicate.pick_up(actor)
	_check(not duplicate._available and duplicate.get_parent().is_queued_for_deletion(), "last remaining ammunition consumes drop")
	var old_mag: int = manager.current().mag
	var old_reserve: int = manager.current().reserve
	var replacement := WeaponPickup.spawn_drop(self, &"m4", 4, 11, Transform3D(Basis.IDENTITY, actor.position + Vector3.UP), Vector3.ZERO)
	replacement.pick_up(actor)
	var previous := _pickup(&"ak47")
	_check(manager.current_data().id == &"m4" and manager.current().mag == 4 and manager.current().reserve == 11, "different primary replaces slot with supplied ammunition")
	_check(previous != null and previous.stored_mag == old_mag and previous.stored_reserve == old_reserve, "replaced primary drops its original ammunition")
	await _physics()
	var empty := WeaponPickup.spawn_drop(self, &"spas", 0, 0, Transform3D(Basis.IDENTITY, actor.position + Vector3.UP), Vector3.ZERO)
	empty.pick_up(actor)
	_check(manager.current_data().id == &"spas" and manager.current().mag == 0 and manager.current().reserve == 0, "empty weapon can still change inventory ownership")
	_check(not empty._available and empty.get_parent().is_queued_for_deletion(), "empty weapon ownership transfer consumes physical pickup")
	manager._equip_left = 0.0
	manager._cooldown = 0.0
	manager._equip(1, false)
	_check(manager.state == WeaponManager.State.HOLSTERING and manager.current_slot == 0, "switch starts holster without instant slot change")
	manager.player_tick(0.08, STILL)
	_check(manager.current_slot == 0, "old slot persists during lowering animation")
	manager.player_tick(0.09, STILL)
	_check(manager.current_slot == 1 and manager.state == WeaponManager.State.EQUIPPING, "holster completion begins drawing selected slot")
	var ammo_before: int = manager.current().mag
	manager._try_fire(STILL)
	_check(manager.current().mag == ammo_before, "drawing weapon blocks firing")
	manager.player_tick(1.0, STILL)
	_check(manager.state == WeaponManager.State.READY, "equip timer returns state to ready")
	manager.holster()
	manager._try_fire(STILL)
	_check(manager.state == WeaponManager.State.DISABLED and manager.current().mag == ammo_before, "death holster prevents all firing")
	manager.reset_loadout()
	_check(not manager._holstered and manager.current_data().id == &"ak47", "respawn restores full usable loadout")
	actor.queue_free()
	for body in get_tree().get_nodes_in_group("dropped_weapons"):
		body.queue_free()
	await _physics()

func _test_animated_hit_zones() -> void:
	var actor := _actor(Vector3(-20, 0, 0))
	actor._body_model = CharacterModel.build("criminalMaleA", 1.8)
	actor.add_child(actor._body_model)
	actor._body_model.rotation.y = PI
	var motion = CharacterModel.motion(actor._body_model)
	motion.equip(actor, Weapons.get_weapon(&"ak47"))
	var skeleton: Skeleton3D = motion.get_skeleton()
	var hitboxes = actor.get_node("Hitboxes")
	var animation: AnimationPlayer = actor._body_model.get_node("AnimationPlayer")
	motion.modification_processed.connect(func():
		_rendered_centers.clear()
		for part: Array in Hitboxes.PARTS:
			var start := skeleton.find_bone(part[1])
			var end := skeleton.find_bone(part[2])
			var from := skeleton.global_transform * skeleton.get_bone_global_pose(start).origin
			var to := skeleton.global_transform * skeleton.get_bone_global_pose(end).origin
			_rendered_centers.append((from + to) * 0.5)
	)
	var states := {"idle": {}, "aim": {"aiming": true, "pitch": 0.7}, "strafe": {"velocity": Vector3(3, 0, 1), "aiming": true}, "crouch": {"crouching": true, "aiming": true}}
	var idle_head := Vector3.ZERO
	for key in states:
		var stance: Dictionary = states[key]
		actor.crouching = stance.get("crouching", false)
		CharacterModel.drive(actor._body_model, actor, stance)
		CharacterModel.animate(animation, stance.get("velocity", Vector3.ZERO), false, true)
		for i in 36:
			await get_tree().physics_frame
		await get_tree().process_frame
		var max_error := 0.0
		if _rendered_centers.size() == hitboxes.volumes.size():
			for i in _rendered_centers.size():
				max_error = maxf(max_error, hitboxes.volumes[i].global_position.distance_to(_rendered_centers[i]))
		else:
			max_error = INF
		_check(max_error < 0.045, "%s hurt volumes follow actual post-modifier rendered skeleton (max %.4f m)" % [key, max_error])
		if key == "idle":
			idle_head = hitboxes.volumes[0].global_position
	_check(idle_head.y - hitboxes.volumes[0].global_position.y > 0.25, "animated crouch lowers head hurt volume with model")
	actor.health.take_damage(1000, null, false, 1.0)
	CharacterModel.drive(actor._body_model, actor, {"alive": false})
	CharacterModel.animate(animation, Vector3.ZERO, false, false)
	await _physics()
	_check(hitboxes.volumes.all(func(area): return area.collision_layer == 0), "death disables all animated hurt volumes")
	actor.position += Vector3(5, 0, 0)
	actor.health.reset()
	actor.crouching = false
	motion.reset_motion()
	CharacterModel.drive(actor._body_model, actor, {})
	CharacterModel.animate(animation, Vector3.ZERO, false, true)
	await _physics()
	await get_tree().process_frame
	_check(hitboxes.volumes.all(func(area): return area.collision_layer == Hitboxes.LAYER), "respawn reactivates all hurt zones")
	_check(hitboxes.volumes[0].global_position.distance_to(_rendered_centers[0]) < 0.045, "respawn hurt volume follows new actor transform and current pose")
	actor.local_control = true
	actor._body_model.visible = false
	actor.crouching = true
	CharacterModel.drive(actor._body_model, actor, {"alive": false})
	CharacterModel.animate(animation, Vector3.ZERO, false, false)
	await _physics()
	var fallback_head := actor.global_transform * Vector3(0, (1.61 + 1.68) * 0.5 * 0.66, 0)
	_check(hitboxes.volumes[0].global_position.is_equal_approx(fallback_head), "local crouch uses fresh posture instead of stale hidden death model")
	actor.queue_free()
	await _physics()
func _test_grenades() -> void:
	var origin := Vector3(40, 0.9, 0)
	var thrower := _actor(Vector3(40, 0, 1))
	var near := _actor(Vector3(42, 0, 0))
	var far := _actor(Vector3(46, 0, 0))
	var protected := _actor(Vector3(40, 0, -3))
	var outside := _actor(Vector3(49, 0, 0))
	_wall(Vector3(40, 1.0, -1.5), Vector3(3, 3, 0.3))
	await _physics()
	var grenade := Grenade.launch(self, thrower, origin, Vector3.ZERO)
	grenade.freeze = true
	grenade.set_physics_process(false)
	grenade.explode()
	_check(near.health.health < far.health.health and far.health.health < 100.0, "blast damage decreases with radius")
	_check(is_equal_approx(near.health.health, 25.0) and is_equal_approx(far.health.health, 75.0), "grenade radial falloff matches catalog damage and range")
	_check(protected.health.health == 100.0, "solid cover blocks grenade damage")
	_check(outside.health.health == 100.0, "actors beyond blast radius are untouched")
	_check(thrower.health.health < 100.0, "thrower receives self damage inside blast")
	var health_after: float = far.health.health
	grenade.explode()
	_check(far.health.health == health_after, "grenade explosion applies damage once")
	near.health.reset()
	thrower.health.take_damage(1000, null, false, 1.0)
	var delayed := Grenade.launch(self, thrower, origin, Vector3.ZERO)
	delayed.freeze = true
	delayed.set_physics_process(false)
	delayed.explode()
	_check(near.health.health < 100.0, "previously thrown grenade remains dangerous after thrower death")
	var no_thrower := Grenade.launch(self, thrower, origin + Vector3.RIGHT * 3, Vector3.ZERO)
	no_thrower.freeze = true
	no_thrower.set_physics_process(false)
	thrower.queue_free()
	await _physics()
	far.health.reset()
	no_thrower.explode()
	_check(far.health.health < 100.0, "thrower disconnect does not cancel physical grenade")
	await _physics()
	var own_wrapper := TestWrapper.new()
	own_wrapper.replicator.mine = true
	add_child(own_wrapper)
	var own_victim := _actor(Vector3(60, 0, 0))
	own_victim.reparent(own_wrapper)
	var remote_wrapper := TestWrapper.new()
	add_child(remote_wrapper)
	var remote_victim := _actor(Vector3(62, 0, 0))
	remote_victim.reparent(remote_wrapper)
	await _physics()
	var authoritative := Grenade.launch(self, own_victim, Vector3(61, 0.9, 0), Vector3.ZERO)
	authoritative.freeze = true
	authoritative.set_physics_process(false)
	authoritative.explode()
	_check(own_victim.health.health < 100.0, "grenade applies damage on victim authority")
	_check(remote_victim.health.health == 100.0, "local grenade simulation leaves remote victim HP to its owner")
	await _physics()
	own_victim.health.reset()
	var replica := Grenade.launch(self, own_victim, Vector3(65, 0.9, 0), Vector3.ZERO)
	replica.freeze = true
	replica.set_physics_process(false)
	replica.wait_for_confirmation = true
	replica._physics_process(2.3)
	_check(own_victim.health.health == 100.0 and not replica._exploded, "remote projectile cannot damage victims before detonation confirmation")
	replica.confirm_explosion(Vector3(61, 0.9, 0))
	_check(replica.global_position.is_equal_approx(Vector3(61, 0.9, 0)) and is_equal_approx(own_victim.health.health, 12.5), "confirmed detonation uses shared point for victim damage")
	await _physics()

func _actor(at: Vector3) -> TestActor:
	var actor := TestActor.new()
	actor.collision_layer = 2
	actor.collision_mask = 1
	actor.health = Health.new()
	actor.health.name = "Health"
	actor.add_child(actor.health)
	var collision := CollisionShape3D.new()
	var capsule := CapsuleShape3D.new()
	capsule.height = 1.8
	capsule.radius = 0.4
	collision.shape = capsule
	collision.position.y = 0.9
	actor.add_child(collision)
	actor.camera = Camera3D.new()
	actor.camera.position.y = 1.62
	actor.add_child(actor.camera)
	var pivot := Node3D.new()
	actor.camera.add_child(pivot)
	actor.weapons = WeaponManager.new()
	actor.add_child(actor.weapons)
	var hitboxes := Hitboxes.new()
	hitboxes.name = "Hitboxes"
	actor.add_child(hitboxes)
	add_child(actor)
	actor.position = at
	actor.weapons.setup(actor, actor.camera, pivot)
	actor.add_to_group("combatants")
	return actor

func _pickup(id: StringName) -> WeaponPickup:
	for body in get_tree().get_nodes_in_group("dropped_weapons"):
		if body.is_queued_for_deletion():
			continue
		for node in body.get_children():
			if node is WeaponPickup and node.weapon_id == id:
				return node
	return null

func _wall(at: Vector3, size: Vector3) -> StaticBody3D:
	var body := StaticBody3D.new()
	var collision := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	collision.shape = box
	body.add_child(collision)
	add_child(body)
	body.position = at
	return body

func _physics() -> void:
	for i in 3:
		await get_tree().physics_frame

func _check(ok: bool, label: String) -> void:
	checks += 1
	if not ok:
		failures += 1
	print("PASS" if ok else "FAIL", " ", label)
