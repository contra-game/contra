## Перенос физических тел в скелет после остановки живой анимации.
extends SkeletonModifier3D

var bindings: Array[Dictionary] = []

func _process_modification_with_delta(_delta: float) -> void:
	var skeleton := get_skeleton()
	var inverse := skeleton.global_transform.affine_inverse()
	for binding in bindings:
		var body: RigidBody3D = binding.body
		if is_instance_valid(body):
			skeleton.set_bone_global_pose(binding.bone, inverse * body.global_transform * binding.offset)
