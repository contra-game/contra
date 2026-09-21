## Боевые позы поверх импортированных клипов. Все цели IK заданы в метрах
## тела, поэтому масштаб и нестандартные оси FBX не попадают в настройки.
extends SkeletonModifier3D

const Spring = preload("res://scripts/viewmodel_spring.gd")
var actor: Node3D
var local_velocity := Vector3.ZERO
var pitch: float = 0.0
var aiming: bool = false
var crouching: bool = false
var airborne: bool = false
var alive: bool = true
var reload_progress: float = -1.0
var weapon: Node3D
var muzzle: Marker3D
var ejection: Marker3D
var data: WeaponData
var support_target := Vector3.ZERO
var last_pose: Array[Transform3D] = []
var _bones: Dictionary = {}
var _time: float = 0.0
var _crouch: float = 0.0
var _aim: float = 0.0
var _leg_yaw: float = 0.0
var _lean := Vector2.ZERO
var _last_yaw: float = 0.0
var _was_airborne: bool = false
var _recoil := Spring.new()
var _impact := Spring.new()
var _landing := Spring.new()

func _ready() -> void:
	_time = fmod(float(get_instance_id()), 97.0) * 0.13
	modification_processed.connect(_cache_pose)

func _cache_pose() -> void:
	if not alive:
		return
	var skeleton := get_skeleton()
	last_pose.resize(skeleton.get_bone_count())
	for index in last_pose.size():
		last_pose[index] = skeleton.get_bone_pose(index)

func reset_motion() -> void:
	_recoil.reset()
	_impact.reset()
	_landing.reset()
	_crouch = 0.0
	_aim = 0.0
	_leg_yaw = 0.0
	_lean = Vector2.ZERO
	_was_airborne = false
	_last_yaw = actor.global_rotation.y if is_instance_valid(actor) else 0.0

func fire() -> void:
	_recoil.impulse(Vector3(0.7, 0.0, 0.0) * (data.recoil_up if data != null else 1.0))

func hit(amount: float) -> void:
	_impact.impulse(Vector3(clampf(amount / 40.0, 0.2, 1.3), 0.25, 0.0))

func equip(body: Node3D, next: WeaponData) -> void:
	actor = body
	data = next
	reset_motion()
	if is_instance_valid(weapon):
		weapon.visible = false
		weapon.queue_free()
	muzzle = null
	ejection = null
	weapon = Node3D.new()
	weapon.name = "CombatWeapon"
	add_child(weapon)
	weapon.global_transform = body.global_transform
	if next == null:
		return
	if not next.is_firearm():
		var visual := MeshInstance3D.new()
		var shape := BoxMesh.new()
		shape.size = Vector3(0.035, 0.015, 0.3) if next.slot == WeaponData.Slot.MELEE else Vector3(0.08, 0.12, 0.08)
		visual.mesh = shape
		var material := StandardMaterial3D.new()
		material.albedo_color = next.body_color
		visual.material_override = material
		weapon.add_child(visual)
		return
	if not ResourceLoader.exists(next.model_path):
		return
	var holder := Node3D.new()
	weapon.add_child(holder)
	var mesh := (load(next.model_path) as PackedScene).instantiate() as Node3D
	holder.add_child(mesh)
	ViewModel.fit(holder, mesh, next)
	var anchors := ViewModel.attach_markers(weapon, mesh, next)
	muzzle = anchors[0]
	ejection = anchors[2]
	holder.scale /= maxf(next.model_scale, 0.001)
	holder.position /= maxf(next.model_scale, 0.001)
	ViewModel.paint(mesh, next.body_color, true)

func _bone(key: String) -> int:
	if not _bones.has(key):
		_bones[key] = get_skeleton().find_bone(key)
	return _bones[key]

func _world_pose(key: String) -> Transform3D:
	return get_skeleton().global_transform * get_skeleton().get_bone_global_pose(_bone(key))

func _set_world_pose(key: String, pose: Transform3D) -> void:
	var skeleton := get_skeleton()
	skeleton.set_bone_global_pose(_bone(key), skeleton.global_transform.affine_inverse() * pose)

func _rotate(key: String, rotation_basis: Basis) -> void:
	if _bone(key) < 0:
		return
	var pose := _world_pose(key)
	pose.basis = rotation_basis * pose.basis
	_set_world_pose(key, pose)

## Аналитический двухзвенный IK с устойчивым направлением локтя/колена.
func _limb(upper: String, lower: String, end: String, target: Vector3, pole: Vector3) -> void:
	if _bone(upper) < 0 or _bone(lower) < 0 or _bone(end) < 0:
		return
	var a := _world_pose(upper).origin
	var b := _world_pose(lower).origin
	var c := _world_pose(end).origin
	var end_basis := _world_pose(end).basis
	var length_a := a.distance_to(b)
	var length_b := b.distance_to(c)
	var distance := clampf(a.distance_to(target), absf(length_a - length_b) + 0.001, length_a + length_b - 0.001)
	var direction := a.direction_to(target)
	if direction.is_zero_approx() or length_a < 0.001:
		return
	var bend := pole - a
	bend = (bend - direction * bend.dot(direction)).normalized()
	if bend.is_zero_approx():
		return
	var along := (length_a * length_a + distance * distance - length_b * length_b) / (2.0 * distance)
	var elbow := a + direction * along + bend * sqrt(maxf(length_a * length_a - along * along, 0.0))
	_rotate(upper, Basis(Quaternion((b - a).normalized(), (elbow - a).normalized())))
	b = _world_pose(lower).origin
	c = _world_pose(end).origin
	var reachable := a + direction * distance
	_rotate(lower, Basis(Quaternion((c - b).normalized(), (reachable - b).normalized())))
	if end.ends_with("Foot"):
		var foot := _world_pose(end)
		foot.basis = end_basis
		_set_world_pose(end, foot)

func _process_modification_with_delta(delta: float) -> void:
	if not is_instance_valid(actor) or not alive or _bone("Hips") < 0:
		return
	_time += delta
	var blend := 1.0 - exp(-12.0 * delta)
	_crouch = lerpf(_crouch, 1.0 if crouching else 0.0, blend)
	_aim = lerpf(_aim, 1.0 if aiming else 0.0, blend)
	if _was_airborne and not airborne:
		_landing.impulse(Vector3(1.5, 0.0, 0.0))
	_was_airborne = airborne
	var recoil := _recoil.step(delta).x
	var impact := _impact.step(delta)
	var landing := _landing.step(delta).x
	var speed := Vector2(local_velocity.x, local_velocity.z).length()
	var direction := local_velocity
	if direction.z > 0.0:
		direction = -direction
	var wanted_yaw := clampf(atan2(-direction.x, -direction.z), -1.1, 1.1) if speed > 0.25 else 0.0
	_leg_yaw = lerp_angle(_leg_yaw, wanted_yaw, blend)
	var yaw := actor.global_rotation.y
	var turn := wrapf(yaw - _last_yaw, -PI, PI) / maxf(delta, 0.001)
	_last_yaw = yaw
	_lean = _lean.lerp(Vector2(clampf(-local_velocity.z * 0.018, -0.07, 0.12), clampf(-local_velocity.x * 0.022 - turn * 0.025, -0.14, 0.14)), blend)
	var right := actor.global_basis.x.normalized()
	var forward := -actor.global_basis.z.normalized()
	# Ноги разворачиваются по движению; грудь сохраняет направление оружия.
	_rotate("Hips", Basis(Vector3.UP, _leg_yaw))
	_rotate("Chest", Basis(Vector3.UP, -_leg_yaw))
	var left_foot := _world_pose("LeftFoot").origin
	var right_foot := _world_pose("RightFoot").origin
	var hips := _world_pose("Hips")
	hips.origin.y -= _crouch * 0.34 + landing
	_set_world_pose("Hips", hips)
	if _crouch > 0.001 or landing > 0.001:
		_limb("LeftUpLeg", "LeftLeg", "LeftFoot", left_foot, left_foot + forward)
		_limb("RightUpLeg", "RightLeg", "RightFoot", right_foot, right_foot + forward)
	var breath := sin(_time * 2.1) * 0.012 * lerpf(1.0, 0.25, _aim)
	_rotate("Spine", Basis(right, pitch * 0.35 + _lean.x + breath - impact.x) * Basis(forward, _lean.y + impact.y))
	_rotate("Head", Basis(right, pitch * 0.6 - _lean.x))
	if data == null or weapon == null:
		return
	var reload_arc := sin(clampf(reload_progress, 0.0, 1.0) * PI) if reload_progress >= 0.0 else 0.0
	var low_ready := (1.0 - _aim) * 0.12
	var gun_rotation := Vector3(pitch - data.sight_rotation.x - low_ready - reload_arc * 0.35 + recoil, 0.0, -reload_arc * 0.3)
	var gun_basis := Basis.from_euler(gun_rotation)
	var grip := Vector3(0.13, 1.06 - _crouch * 0.34 - landing + breath * 0.35, -0.25)
	grip.y += _aim * 0.14 - reload_arc * 0.12
	grip.z += recoil * 0.15
	var right_grip := Vector3(0.0, -0.02, data.length * 0.16) / data.model_scale
	weapon.global_transform = actor.global_transform * Transform3D(gun_basis, grip - gun_basis * right_grip)
	# Длинную винтовку поддерживаем ближе к ствольной коробке, чтобы кисть
	# оставалась на оружии, а не упиралась в предел длины руки.
	var support := right_grip + Vector3(-0.03, 0.015, -minf(data.length * 0.38 / data.model_scale, 0.18))
	if data.slot == WeaponData.Slot.SECONDARY:
		support = right_grip + Vector3(-0.045, -0.01, 0.015)
	# Левая рука уходит к подсумку и возвращается к цевью.
	var left_target := weapon.to_global(support).lerp(actor.to_global(Vector3(-0.18, 0.85 - _crouch * 0.34, -0.08)), reload_arc)
	support_target = left_target
	_limb("RightArm", "RightForeArm", "RightHand", weapon.to_global(right_grip), actor.to_global(Vector3(0.48, 0.8 - _crouch * 0.34, -0.04)))
	_limb("LeftArm", "LeftForeArm", "LeftHand", left_target, actor.to_global(Vector3(-0.48, 0.8 - _crouch * 0.34, -0.04)))
