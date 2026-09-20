## Подгонка моделей оружия под вид от первого лица.
##
## Ключевой момент: анимации в паке двигают сам корень модели (дорожки на
## "PistolArmature" и т.п.), поэтому собственный transform модели трогать
## нельзя — иначе анимация дерётся с подгонкой и ствол пляшет. Всё, что нужно,
## задаётся на узле-держателе: масштаб, разворот и смещение.
##
## Пак Quaternius сделан под Unity, где вперёд +Z, а в Godot вперёд -Z —
## отсюда разворот держателя на 180°.
class_name ViewModel
extends RefCounted

## Модели пака лежат стволом вниз под углом — общий для пака наклон.
const PACK_PITCH := 0.19
const UNITY_TO_GODOT_YAW := 0.0

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

	# Авторская раскладка у каждой модели своя, поэтому центр ствола ставим
	# в одну и ту же точку: чуть впереди начала координат держателя.
	# Центр ствола попадает в начало координат держателя, а куда поставить сам
	# держатель, решают HIP/AIM-позиции в WeaponManager.
	var centre := holder.transform.basis * box.get_center()
	holder.position = data.model_offset - centre

	paint(model, data.body_color)

## Руки от первого лица. Готовых CC0-рук с анимациями под пак не нашлось,
## поэтому они собираются из примитивов: предплечье-капсула тянется от нижнего
## края экрана к точке хвата, кисть — коробка на конце. Руки живут в том же
## держателе, что и ствол, поэтому ходят с ним и в отдаче, и в перезарядке.
static func attach_hands(holder: Node3D, data: WeaponData) -> void:
	var grip := Vector3(0.0, -0.02, data.length * 0.16)        # рукоять, ближе к прикладу
	var support := Vector3(0.0, -0.03, -data.length * 0.22)    # цевьё
	# Плечи условно находятся ниже и ближе к камере, чем оружие.
	_add_arm(holder, Vector3(0.12, -0.26, 0.26), grip, data)
	if data.slot == WeaponData.Slot.PRIMARY:
		_add_arm(holder, Vector3(-0.1, -0.26, 0.2), support, data)

static func _add_arm(holder: Node3D, from: Vector3, to: Vector3, data: WeaponData) -> void:
	var skin := StandardMaterial3D.new()
	skin.albedo_color = Color(0.76, 0.58, 0.45)
	skin.roughness = 0.9
	var sleeve := StandardMaterial3D.new()
	sleeve.albedo_color = Color(0.22, 0.25, 0.3)
	sleeve.roughness = 0.95

	var arm := Node3D.new()
	holder.add_child(arm)
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
