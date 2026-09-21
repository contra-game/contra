## Подгонка моделей оружия под вид от первого лица.
##
## Ключевой момент: анимации в паке двигают сам корень модели (дорожки на
## "PistolArmature" и т.п.), поэтому собственный transform модели трогать
## нельзя — иначе анимация дерётся с подгонкой и ствол пляшет. Всё, что нужно,
## задаётся на узле-держателе: масштаб, разворот и смещение.
##
## После импорта большинство стволов смотрит по -Z; исключения разворачиваются
## через model_rotation в каталоге (например, Pistol импортируется вдоль X).
class_name ViewModel
extends RefCounted

## Модели пака лежат стволом вниз под углом — общий для пака наклон.
const PACK_PITCH := 0.19
const UNITY_TO_GODOT_YAW := 0.0

## Маркеры заданы на геометрии в нейтральной позе и привязаны к Control.
## BoneAttachment переносит их вместе со стволом, включая импортированные клипы.
static func attach_markers(root: Node3D, model: Node3D, data: WeaponData) -> Array[Marker3D]:
	var parent: Node3D = root
	if model != null:
		for node in walk(model):
			if node is Skeleton3D:
				var bone: int = node.find_bone("Control")
				if bone < 0:
					continue
				var attachment := BoneAttachment3D.new()
				attachment.name = "WeaponAnchors"
				node.add_child(attachment)
				attachment.bone_idx = bone
				attachment.transform = node.get_bone_global_pose(bone)
				parent = attachment
				break
	var markers: Array[Marker3D] = []
	for key in ["MuzzleMarker", "SightNode", "EjectionMarker"]:
		var marker := Marker3D.new()
		marker.name = key
		parent.add_child(marker)
		var point := data.muzzle_offset if key == "MuzzleMarker" else data.sight_offset
		if key == "EjectionMarker":
			point = data.ejection_offset
		marker.global_transform = root.global_transform * Transform3D(Basis.from_euler(data.sight_rotation), point)
		markers.append(marker)
	# У всех стволов без оптики есть читаемый целик и контрастная мушка.
	# Маркер ставится над геометрией, чтобы линия прицеливания была открыта.
	if data.is_firearm() and not data.has_scope:
		_attach_open_sight(markers[1], data)
	return markers

static func _attach_open_sight(sight: Marker3D, data: WeaponData) -> void:
	var pistol := data.slot == WeaponData.Slot.SECONDARY
	var span := clampf(data.length * 0.42, 0.1, 0.26)
	var width := 0.009 if pistol else 0.016
	var dark := StandardMaterial3D.new()
	dark.albedo_color = Color(0.055, 0.06, 0.07)
	dark.roughness = 0.6
	for x in [-width, width]:
		_sight_piece(sight, Vector3(x, -0.007, 0.0), Vector3(0.005, 0.018, 0.008), dark)
	_sight_piece(sight, Vector3(0, -0.018, 0), Vector3(width * 2.0 + 0.005, 0.006, 0.008), dark)
	_sight_piece(sight, Vector3(0, -0.012, -span), Vector3(0.004, 0.024, 0.008), dark)
	var bead := StandardMaterial3D.new()
	bead.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	bead.albedo_color = Color(0.55, 1.0, 0.65)
	_sight_piece(sight, Vector3(0, 0, -span + 0.005), Vector3(0.0025, 0.0025, 0.002), bead)

static func _sight_piece(parent: Node3D, point: Vector3, size: Vector3, material: Material) -> void:
	var piece := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = size
	piece.mesh = box
	piece.material_override = material
	piece.position = point
	parent.add_child(piece)

## Ставит модель в держатель и настраивает держатель под длину ствола.
static func fit(holder: Node3D, model: Node3D, data: WeaponData) -> void:
	var box := aabb(model)
	var longest: float = maxf(box.size.x, maxf(box.size.y, box.size.z))
	if longest < 0.0001:
		return

	var scale_factor: float = data.length / longest * data.model_scale
	holder.scale = Vector3.ONE * scale_factor
	holder.rotation = Vector3(
		PACK_PITCH + data.model_rotation.x,
		UNITY_TO_GODOT_YAW + data.model_rotation.y,
		data.model_rotation.z)

	var centre := holder.transform.basis * box.get_center()
	holder.position = data.model_offset - centre
	# AABB skinned-меша описывает исходные вершины, а не текущую позу костей.
	# У импортированных FBX его центр часто далеко от рукояти. Совмещаем
	# спусковой крючок с точкой хвата, оставляя анимации внутри держателя.
	for node in walk(model):
		if node is Skeleton3D:
			var trigger: int = node.find_bone("Trigger")
			if trigger < 0:
				continue
			var relative := Transform3D.IDENTITY
			var current: Node = node
			while current != holder and current != null:
				if current is Node3D:
					relative = current.transform * relative
				current = current.get_parent()
			var anchor: Vector3 = relative * node.get_bone_global_pose(trigger).origin
			var grip := Vector3(0.0, 0.015, data.length * 0.16 - 0.025)
			holder.position = data.model_offset + grip - holder.transform.basis * anchor
			break

	paint(model, data.body_color)

## Руки от первого лица. Готовых CC0-рук с анимациями под пак не нашлось,
## поэтому они собираются из примитивов: предплечье-капсула тянется от нижнего
## края экрана к точке хвата, кисть — коробка на конце. Руки живут в том же
## держателе, что и ствол, поэтому ходят с ним и в отдаче, и в перезарядке.
static func attach_hands(holder: Node3D, data: WeaponData, model: Node3D = null) -> void:
	var grip := Vector3(0.0, -0.02, data.length * 0.16)        # рукоять, ближе к прикладу
	var support := Vector3(0.0, -0.01 + sin(PACK_PITCH) * data.length * 0.38, -data.length * 0.22)
	# Плечи условно находятся ниже и ближе к камере, чем оружие.
	var arms: Array[Node3D] = []
	arms.append(_add_arm(holder, Vector3(0.12, -0.26, 0.26), grip))
	if data.slot == WeaponData.Slot.PRIMARY:
		arms.append(_add_arm(holder, Vector3(-0.1, -0.26, 0.2), support))
	else:
		arms.append(_add_arm(holder, Vector3(-0.12, -0.26, 0.22), grip + Vector3(-0.045, -0.01, 0.015)))
	if model == null:
		return
	for node in walk(model):
		if not node is Skeleton3D:
			continue
		var bone: int = node.find_bone("Control")
		if bone < 0:
			continue
		var anchor: Transform3D = node.global_transform * node.get_bone_global_pose(bone)
		for arm in arms:
			arm.set_meta("skeleton", node)
			arm.set_meta("bone", bone)
			arm.set_meta("grip_offset", anchor.affine_inverse() * arm.global_position)
		break

static func _add_arm(holder: Node3D, from: Vector3, to: Vector3) -> Node3D:
	var skin := StandardMaterial3D.new()
	skin.albedo_color = Color(0.76, 0.58, 0.45)
	skin.roughness = 0.9
	var sleeve := StandardMaterial3D.new()
	sleeve.albedo_color = Color(0.22, 0.25, 0.3)
	sleeve.roughness = 0.95

	var arm := Node3D.new()
	holder.add_child(arm)
	arm.set_meta("shoulder", from)
	# Всё в координатах держателя: look_at_* работают с глобальными и здесь
	# не годятся — узел уехал бы в мировой ноль.
	var direction := to - from
	if direction.length() < 0.01:
		direction = Vector3.FORWARD
	arm.transform = Transform3D(Basis.looking_at(direction, Vector3.UP), to)

	var length := from.distance_to(to)
	var forearm := MeshInstance3D.new()
	var capsule := CapsuleMesh.new()
	capsule.radius = 0.034
	capsule.height = maxf(length, 0.12)
	forearm.mesh = capsule
	forearm.name = "Forearm"
	forearm.material_override = sleeve
	# Капсула растёт вдоль Y, а рука смотрит вдоль -Z, отсюда доворот.
	forearm.rotation.x = PI * 0.5
	forearm.position.z = capsule.height * 0.5 - 0.02
	forearm.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	arm.add_child(forearm)

	var hand := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(0.06, 0.075, 0.05)
	hand.mesh = box
	hand.material_override = skin
	hand.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	arm.add_child(hand)
	return arm

## Предплечья тянутся к хвату в текущей позе, поэтому кисть не висит в воздухе
## во время внутренней анимации отдачи/перезарядки FBX.
static func update_hands(holder: Node3D) -> void:
	for arm in holder.get_children():
		if not arm.has_meta("skeleton"):
			continue
		var skeleton: Skeleton3D = arm.get_meta("skeleton")
		var bone: int = arm.get_meta("bone")
		var anchor := skeleton.global_transform * skeleton.get_bone_global_pose(bone)
		var to := holder.to_local(anchor * (arm.get_meta("grip_offset") as Vector3))
		var from: Vector3 = arm.get_meta("shoulder")
		if from.distance_squared_to(to) < 0.0001:
			continue
		arm.transform = Transform3D(Basis.looking_at(to - from, Vector3.UP), to)
		var forearm: MeshInstance3D = arm.get_node("Forearm")
		var capsule := forearm.mesh as CapsuleMesh
		capsule.height = maxf(from.distance_to(to), 0.12)
		forearm.position.z = capsule.height * 0.5 - 0.02

## Габариты модели в её собственных координатах.
static func aabb(model: Node3D) -> AABB:
	var boxes: Array[AABB] = []
	for child in model.get_children():
		_collect(child, Transform3D.IDENTITY, boxes)
	if model is VisualInstance3D:
		boxes.append(model.get_aabb())
	if boxes.is_empty():
		return AABB()
	var result: AABB = boxes[0]
	for i in range(1, boxes.size()):
		result = result.merge(boxes[i])
	return result

static func _collect(node: Node, parent_transform: Transform3D, out: Array[AABB]) -> void:
	var transform := parent_transform
	if node is Node3D:
		transform = parent_transform * node.transform
	if node is VisualInstance3D:
		out.append(transform * node.get_aabb())
	for child in node.get_children():
		_collect(child, transform, out)

## В FBX из пака материалов нет, поэтому цвет берётся из каталога оружия.
static func paint(model: Node3D, color: Color, shadows: bool = false) -> void:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.metallic = 0.65
	mat.roughness = 0.4
	for node in walk(model):
		if node is MeshInstance3D:
			node.material_override = mat
			if not shadows:
				node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

static func walk(node: Node) -> Array[Node]:
	var out: Array[Node] = [node]
	for child in node.get_children():
		out.append_array(walk(child))
	return out
