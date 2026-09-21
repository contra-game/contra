## Самостоятельный труп: респавн бойца не телепортирует физический скелет.
extends Node3D

const GROUP := "combat_ragdolls"
const LIMIT := 8
const LIFETIME := 14.0
const LAYER := 1 << 4
## Кость, конец сегмента, родительское тело, радиус, масса, конус сустава.
const PARTS := [
	["Hips", "Spine", "", 0.12, 10.0, 0.45],
	["Spine", "Neck", "Hips", 0.14, 14.0, 0.4],
	["Head", "Head_end", "Spine", 0.19, 5.0, 0.6],
	["LeftArm", "LeftForeArm", "Spine", 0.06, 2.5, 1.2],
	["LeftForeArm", "LeftHand", "LeftArm", 0.05, 1.5, 0.75],
	["RightArm", "RightForeArm", "Spine", 0.06, 2.5, 1.2],
	["RightForeArm", "RightHand", "RightArm", 0.05, 1.5, 0.75],
	["LeftUpLeg", "LeftLeg", "Hips", 0.085, 6.0, 0.9],
	["LeftLeg", "LeftFoot", "LeftUpLeg", 0.065, 3.0, 0.65],
	["RightUpLeg", "RightLeg", "Hips", 0.085, 6.0, 0.9],
	["RightLeg", "RightFoot", "RightUpLeg", 0.065, 3.0, 0.65],
]
var bodies: Dictionary = {}
var skeleton: Skeleton3D
var age: float = 0.0

static func spawn(source: Node3D, world: Node, velocity: Vector3, direction: Vector3) -> Node3D:
	if not is_instance_valid(source) or world == null:
		return null
	var existing := world.get_tree().get_nodes_in_group(GROUP)
	while existing.size() >= LIMIT:
		var oldest: Node = existing.pop_front()
		oldest.remove_from_group(GROUP)
		oldest.queue_free()
	var corpse := preload("res://scripts/combat_ragdoll.gd").new()
	world.add_child(corpse)
	corpse.add_to_group(GROUP)
	corpse._build(source, velocity, direction)
	return corpse

func _build(source: Node3D, velocity: Vector3, direction: Vector3) -> void:
	var source_skeleton: Skeleton3D
	for node in ViewModel.walk(source):
		if node is Skeleton3D:
			source_skeleton = node
			break
	if source_skeleton == null:
		queue_free()
		return
	var model := (load(CharacterModel.MODEL) as PackedScene).instantiate() as Node3D
	add_child(model)
	model.global_transform = source.global_transform
	CharacterModel._apply_skin(model, source.get_meta("skin_name", "criminalMaleA"))
	for node in ViewModel.walk(model):
		if node is Skeleton3D:
			skeleton = node
		elif node is AnimationPlayer:
			node.stop()
	skeleton.global_transform = source_skeleton.global_transform
	var motion = CharacterModel.motion(source)
	for index in skeleton.get_bone_count():
		var pose: Transform3D = motion.last_pose[index] if motion != null and motion.last_pose.size() == skeleton.get_bone_count() else source_skeleton.get_bone_pose(index)
		skeleton.set_bone_pose(index, pose)
	var driver := preload("res://scripts/ragdoll_pose.gd").new()
	skeleton.add_child(driver)
	var kick := direction.normalized() if direction.length_squared() > 0.001 else -source.global_basis.z.normalized()
	for part in PARTS:
		var bone := skeleton.find_bone(part[0])
		var end := skeleton.find_bone(part[1])
		if bone < 0 or end < 0:
			continue
		var bone_pose := skeleton.global_transform * skeleton.get_bone_global_pose(bone)
		var tip := (skeleton.global_transform * skeleton.get_bone_global_pose(end)).origin
		var segment := tip - bone_pose.origin
		var body := RigidBody3D.new()
		body.name = part[0]
		body.mass = part[4]
		body.collision_layer = LAYER
		body.collision_mask = 1 # Косметическая физика не толкает живых игроков.
		body.linear_damp = 0.35
		body.angular_damp = 2.0
		body.continuous_cd = true
		body.set_meta("surface", "flesh")
		var material := PhysicsMaterial.new()
		material.friction = 0.85
		material.bounce = 0.05
		body.physics_material_override = material
		add_child(body)
		body.global_transform = Transform3D(Basis(Quaternion(Vector3.UP, segment.normalized())), bone_pose.origin + segment * 0.5)
		var collider := CollisionShape3D.new()
		var capsule := CapsuleShape3D.new()
		capsule.radius = part[3]
		capsule.height = maxf(segment.length(), capsule.radius * 2.0)
		collider.shape = capsule
		body.add_child(collider)
		body.linear_velocity = velocity.limit_length(8.0) + kick * 1.7 + Vector3.UP * 0.4
		bodies[part[0]] = body
		driver.bindings.append({"bone": bone, "body": body, "offset": body.global_transform.affine_inverse() * bone_pose})
		if bodies.has(part[2]):
			var joint := ConeTwistJoint3D.new()
			add_child(joint)
			joint.global_position = bone_pose.origin
			joint.swing_span = part[5]
			joint.twist_span = 0.35
			joint.node_a = joint.get_path_to(bodies[part[2]])
			joint.node_b = joint.get_path_to(body)
			joint.exclude_nodes_from_collision = true
	# Ограничиваем энергию: смерть не должна разбрасывать тело через всю карту.
	if bodies.has("Spine"):
		bodies.Spine.apply_impulse(kick * 6.0, Vector3.UP * 0.15)
	if motion != null and is_instance_valid(motion.weapon) and motion.data != null and not motion.actor is PlayerCharacter:
		var magazine: int = motion.actor._mag if motion.actor is Bot else motion.data.magazine
		_drop_weapon(motion.weapon, motion.data, velocity + kick, magazine)

func _drop_weapon(original: Node3D, data: WeaponData, velocity: Vector3, magazine: int) -> void:
	var dropped := RigidBody3D.new()
	dropped.name = "DroppedWeapon"
	dropped.mass = 2.5
	dropped.collision_layer = LAYER
	dropped.collision_mask = 1
	dropped.continuous_cd = true
	dropped.angular_damp = 1.5
	dropped.set_meta("surface", "metal")
	add_child(dropped)
	dropped.global_transform = original.global_transform.orthonormalized()
	var visual := original.duplicate() as Node3D
	dropped.add_child(visual)
	visual.transform = Transform3D.IDENTITY
	visual.visible = true
	for node in ViewModel.walk(visual):
		if node is AnimationPlayer:
			node.stop()
	var collision := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(0.08, 0.14, data.length * 0.85)
	collision.shape = box
	collision.position = Vector3(0, 0.04, -data.length * 0.2)
	dropped.add_child(collision)
	dropped.linear_velocity = velocity.limit_length(8.0) + Vector3.UP
	dropped.angular_velocity = Vector3(2.0, 4.0, 1.0)
	if data.is_firearm():
		var pickup := WeaponPickup.new()
		pickup.dropped = true
		pickup.weapon_id = data.id
		pickup.stored_mag = clampi(magazine, 0, data.magazine)
		pickup.stored_reserve = data.reserve_ammo
		dropped.add_child(pickup)

func _physics_process(delta: float) -> void:
	age += delta
	if age >= LIFETIME:
		queue_free()
	# Защита от редкого взрыва решателя на тесном углу карты.
	for body: RigidBody3D in bodies.values():
		if body.linear_velocity.length_squared() > 144.0:
			body.linear_velocity = body.linear_velocity.limit_length(12.0)
		if body.angular_velocity.length_squared() > 144.0:
			body.angular_velocity = body.angular_velocity.limit_length(12.0)
