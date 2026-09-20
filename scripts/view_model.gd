## Подгонка моделей оружия под вид от первого лица.
##
## Модели из паков приходят в произвольном масштабе и ориентации: винтовка
## лежит вдоль Z с наклоном, пистолет — вдоль X, размеры в десятках юнитов.
## Здесь они приводятся к общему виду: длинная ось смотрит в -Z, длина равна
## length из WeaponData, центр — в начале координат пивота.
class_name ViewModel
extends RefCounted

static func fit(model: Node3D, data: WeaponData, auto_orient: bool = false) -> void:
	var points := vertices(model)
	if points.is_empty():
		return

	# Масштаб всегда считается по самой длинной стороне габаритов, независимо
	# от того, разворачиваем модель автоматически или нет.
	var box_size := aabb(model).size
	var length_along_barrel: float = maxf(box_size.x, maxf(box_size.y, box_size.z))

	var base := Basis()
	if auto_orient:
		var barrel := barrel_axis(points)
		length_along_barrel = barrel.y
		# Ствол уводим в -Z, вертикаль модели сохраняем как «верх» оружия.
		var forward: Vector3 = barrel.x
		var up := Vector3.UP
		if absf(forward.dot(up)) > 0.95:
			up = Vector3.BACK
		base = Basis().looking_at(forward, up)
	if data.model_flip:
		base = Basis(Vector3.UP, PI) * base

	var scale_factor: float = data.length / maxf(length_along_barrel, 0.0001) * data.model_scale
	var oriented := (Basis.from_euler(data.model_rotation) * base).scaled(Vector3.ONE * scale_factor)
	# Центр модели переносится в model_offset, дальше позицию задаёт пивот.
	var center := aabb(model).get_center()
	model.transform = Transform3D(oriented, data.model_offset - oriented * center)

	paint(model, data.body_color)

## Направление ствола и его длина: {x = единичный вектор от приклада к дулу,
## y = длина модели вдоль этого вектора}.
##
## Ось ищется приёмом «самая далёкая точка от самой далёкой точки», потому что
## AABB врёт на моделях, лежащих под углом. Дулом считается более тонкий конец:
## у приклада и рукояти поперечный размер всегда больше.
static func barrel_axis(points: PackedVector3Array) -> Dictionary:
	var centroid := Vector3.ZERO
	for p in points:
		centroid += p
	centroid /= points.size()

	var a := _farthest_from(points, centroid)
	var b := _farthest_from(points, a)
	var axis := b - a
	var length := axis.length()
	if length < 0.0001:
		return {"x": Vector3.FORWARD, "y": 1.0}
	axis /= length

	# Средний разлёт точек поперёк оси в крайних третях.
	var spread_a := _cross_spread(points, a, axis, length, 0.0, 0.33)
	var spread_b := _cross_spread(points, a, axis, length, 0.67, 1.0)
	var forward: Vector3 = axis if spread_b < spread_a else -axis
	return {"x": forward, "y": length}

static func _farthest_from(points: PackedVector3Array, origin: Vector3) -> Vector3:
	var best := origin
	var best_distance := -1.0
	for p in points:
		var d := origin.distance_squared_to(p)
		if d > best_distance:
			best_distance = d
			best = p
	return best

static func _cross_spread(points: PackedVector3Array, origin: Vector3, axis: Vector3, length: float, from: float, to: float) -> float:
	var total := 0.0
	var count := 0
	for p in points:
		var along: float = (p - origin).dot(axis) / length
		if along < from or along > to:
			continue
		var offset: Vector3 = (p - origin) - axis * (p - origin).dot(axis)
		total += offset.length()
		count += 1
	return total / maxf(float(count), 1.0)

## Все вершины модели в её собственных координатах.
static func vertices(model: Node3D) -> PackedVector3Array:
	var to_local := model.global_transform.affine_inverse()
	var out := PackedVector3Array()
	for node in walk(model):
		if node is MeshInstance3D and node.mesh != null:
			var transform: Transform3D = to_local * node.global_transform
			var mesh: Mesh = node.mesh
			for surface in mesh.get_surface_count():
				var arrays := mesh.surface_get_arrays(surface)
				var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
				for v in verts:
					out.append(transform * v)
	return out

## Габариты в координатах самой модели: меши лежат внутри Skeleton3D со своими
## трансформами, поэтому локальный AABB меша нельзя брать напрямую.
static func aabb(model: Node3D) -> AABB:
	var to_local := model.global_transform.affine_inverse()
	var result := AABB()
	var first := true
	for node in walk(model):
		if node is VisualInstance3D:
			var box: AABB = (to_local * node.global_transform) * node.get_aabb()
			if first:
				result = box
				first = false
			else:
				result = result.merge(box)
	return result

## В FBX из пака материалов нет, поэтому цвет берётся из каталога оружия.
static func paint(model: Node3D, color: Color) -> void:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.metallic = 0.65
	mat.roughness = 0.4
	for node in walk(model):
		if node is MeshInstance3D:
			node.material_override = mat
			node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

static func walk(node: Node) -> Array[Node]:
	var out: Array[Node] = [node]
	for child in node.get_children():
		out.append_array(walk(child))
	return out
