## Hurt volumes follow the rendered skeleton; movement capsules never count as flesh.
extends Node3D

const LAYER := 1 << 5
const PARTS := [
	[&"head", "Head", "Head_end", 0.18, Vector3(0, 1.61, 0), Vector3(0, 1.68, 0)],
	[&"body", "Hips", "Spine", 0.20, Vector3(0, 0.86, 0), Vector3(0, 1.13, 0)],
	[&"body", "Spine", "Neck", 0.21, Vector3(0, 1.12, 0), Vector3(0, 1.40, 0)],
	[&"limb", "LeftArm", "LeftForeArm", 0.085, Vector3(-0.28, 1.38, 0), Vector3(-0.32, 1.12, -0.12)],
	[&"limb", "LeftForeArm", "LeftHand", 0.07, Vector3(-0.32, 1.12, -0.12), Vector3(-0.2, 1.14, -0.37)],
	[&"limb", "RightArm", "RightForeArm", 0.085, Vector3(0.28, 1.38, 0), Vector3(0.32, 1.12, -0.12)],
	[&"limb", "RightForeArm", "RightHand", 0.07, Vector3(0.32, 1.12, -0.12), Vector3(0.2, 1.14, -0.37)],
	[&"limb", "LeftUpLeg", "LeftLeg", 0.11, Vector3(-0.13, 0.82, 0), Vector3(-0.13, 0.46, 0)],
	[&"limb", "LeftLeg", "LeftFoot", 0.09, Vector3(-0.13, 0.46, 0), Vector3(-0.13, 0.12, 0)],
	[&"limb", "RightUpLeg", "RightLeg", 0.11, Vector3(0.13, 0.82, 0), Vector3(0.13, 0.46, 0)],
	[&"limb", "RightLeg", "RightFoot", 0.09, Vector3(0.13, 0.46, 0), Vector3(0.13, 0.12, 0)],
]
var volumes: Array[Area3D] = []
var skeleton: Skeleton3D
var _bone_pairs: Array[Vector2i] = []
var actor: Node3D
var _motion: Node

func _ready() -> void:
	actor = get_parent()
	process_physics_priority = 50
	for part in PARTS:
		var area := Area3D.new()
		area.name = String(part[0]) + str(volumes.size())
		area.collision_layer = LAYER
		area.collision_mask = 0
		area.monitoring = false
		area.set_meta("hit_zone", part[0])
		var shape := CollisionShape3D.new()
		var capsule := CapsuleShape3D.new()
		capsule.radius = part[3]
		capsule.height = capsule.radius * 2.0
		shape.shape = capsule
		area.add_child(shape)
		add_child(area)
		volumes.append(area)
	_physics_process(0.0)

func _physics_process(_delta: float) -> void:
	if not is_instance_valid(actor):
		return
	var hp := actor.get_node_or_null("Health") as Health
	var alive := hp == null or hp.alive
	if not is_instance_valid(skeleton):
		var model = actor.get("_body_model")
		if model == null:
			model = actor.get("_character_model")
		if model != null:
			_motion = CharacterModel.motion(model)
			for node in ViewModel.walk(model):
				if node is Skeleton3D:
					skeleton = node
					for part in PARTS:
						_bone_pairs.append(Vector2i(skeleton.find_bone(part[1]), skeleton.find_bone(part[2])))
					break
	var crouched: bool = actor.get("crouching") == true
	for i in volumes.size():
		var area := volumes[i]
		area.collision_layer = LAYER if alive else 0
		if not alive:
			continue
		var part: Array = PARTS[i]
		var from: Vector3 = part[4]
		var to: Vector3 = part[5]
		if is_instance_valid(skeleton) and actor.get("local_control") != true and _bone_pairs[i].x >= 0 and _bone_pairs[i].y >= 0:
			from = _posed_point(_bone_pairs[i].x)
			to = _posed_point(_bone_pairs[i].y)
		else:
			if crouched:
				from.y *= 0.66
				to.y *= 0.66
			from = actor.global_transform * from
			to = actor.global_transform * to
		var segment := to - from
		var shape: CapsuleShape3D = area.get_child(0).shape
		shape.height = maxf(segment.length() + shape.radius, shape.radius * 2.0)
		var direction := segment.normalized() if segment.length_squared() > 0.00001 else Vector3.UP
		area.global_transform = Transform3D(Basis(Quaternion(Vector3.UP, direction)), (from + to) * 0.5)

func _posed_point(index: int) -> Vector3:
	# SkeletonModifier restores animation poses after drawing. Use its captured
	# final pose so crouch/IK/aim hurt volumes match the model that was rendered.
	if not is_instance_valid(_motion) or _motion.last_pose.size() != skeleton.get_bone_count():
		return skeleton.global_transform * skeleton.get_bone_global_pose(index).origin
	var pose: Transform3D = _motion.last_pose[index]
	var parent := skeleton.get_bone_parent(index)
	while parent >= 0:
		pose = _motion.last_pose[parent] * pose
		parent = skeleton.get_bone_parent(parent)
	return skeleton.global_transform * pose.origin
