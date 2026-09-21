## Ballistic projectile. Every peer simulates effects; each victim owns its HP.
extends RigidBody3D

signal detonated(position: Vector3)

var thrower: Node3D
var fuse: float = 2.2
var _exploded: bool = false
var wait_for_confirmation: bool = false

static func launch(world: Node, actor: Node3D, origin: Vector3, speed: Vector3) -> RigidBody3D:
	var grenade := preload("res://scripts/thrown_grenade.gd").new()
	grenade.thrower = actor
	grenade.collision_layer = 16
	grenade.collision_mask = 1
	grenade.mass = 0.4
	grenade.continuous_cd = true
	grenade.set_meta("surface", "metal")
	var material := PhysicsMaterial.new()
	material.bounce = 0.35
	material.friction = 0.65
	grenade.physics_material_override = material
	var collision := CollisionShape3D.new()
	var shape := SphereShape3D.new()
	shape.radius = 0.065
	collision.shape = shape
	grenade.add_child(collision)
	var visual := MeshInstance3D.new()
	var mesh := SphereMesh.new()
	mesh.radius = 0.065
	mesh.height = 0.14
	visual.mesh = mesh
	var paint := StandardMaterial3D.new()
	paint.albedo_color = Color(0.25, 0.31, 0.1)
	visual.material_override = paint
	grenade.add_child(visual)
	world.add_child(grenade)
	grenade.global_position = origin
	grenade.linear_velocity = speed
	grenade.angular_velocity = Vector3(7, 3, 2)
	grenade.add_to_group("grenades")
	return grenade

func _physics_process(delta: float) -> void:
	fuse -= delta
	if fuse <= 0.0:
		if not wait_for_confirmation:
			explode()
		elif fuse < -2.0:
			queue_free() # Thrower disconnected or the confirmation was rejected.

func confirm_explosion(point: Vector3) -> void:
	global_position = point
	wait_for_confirmation = false
	explode()

func explode() -> void:
	if _exploded or wait_for_confirmation:
		return
	_exploded = true
	set_physics_process(false)
	detonated.emit(global_position)
	var data := Weapons.get_weapon(&"grenade")
	var world := get_tree().current_scene
	Sfx.play_3d(&"explosion", global_position, 1.0, 3.0, 120.0)
	Effects.explosion(world, global_position)
	for target in get_tree().get_nodes_in_group("combatants"):
		if not is_instance_valid(target) or target.is_dead():
			continue
		var wrapper := Damage._net_wrapper(target)
		if wrapper != null and not wrapper.replicator.has_authority():
			continue
		var point: Vector3 = target.global_position + Vector3.UP * 0.9
		var distance := point.distance_to(global_position)
		if distance > data.max_range:
			continue
		var ray := PhysicsRayQueryParameters3D.create(global_position, point, 1)
		if not get_world_3d().direct_space_state.intersect_ray(ray).is_empty():
			continue
		var attacker: Node = thrower if is_instance_valid(thrower) else null
		var dealt := Damage.apply(target, data.damage * (1.0 - distance / data.max_range), attacker, false, data.armor_penetration, "grenade")
		if dealt > 0.0 and attacker != null and attacker != target:
			if wrapper != null:
				NetApi.rpc_all(wrapper.confirm_hit, [attacker.peer_id, false, target.is_dead(), wrapper.life_serial])
			if attacker is PlayerCharacter and attacker.local_control:
				attacker.weapons.hit_confirmed.emit(false, target.is_dead())
	for corpse in get_tree().get_nodes_in_group("combat_ragdolls"):
		for body: RigidBody3D in corpse.bodies.values():
			var offset := body.global_position - global_position
			if offset.length() < data.max_range:
				body.apply_central_impulse((offset.normalized() + Vector3.UP * 0.4) * 8.0 * (1.0 - offset.length() / data.max_range))
	hide()
	collision_layer = 0
	collision_mask = 0
	freeze = true
	var cleanup := create_tween()
	cleanup.tween_interval(0.1)
	cleanup.tween_callback(queue_free)
