## Визуальные эффекты стрельбы: трассеры, попадания, дульная вспышка.
## Всё создаётся кодом и само себя удаляет — внешних ассетов не требует.
class_name Effects
extends RefCounted

## Материалы и меши общие на все эффекты: раньше каждая дробина создавала свой
## StandardMaterial3D, а на них компилируются варианты шейдера.
static var _tracer_materials: Dictionary = {}     # Color -> StandardMaterial3D
static var _spark: Mesh = null
static var _mark_material: StandardMaterial3D = null

static func tracer(world: Node, from: Vector3, to: Vector3, color: Color = Color(1.0, 0.85, 0.45)) -> void:
	if world == null or from.distance_to(to) < 0.05:
		return
	var mesh := ImmediateMesh.new()
	mesh.surface_begin(Mesh.PRIMITIVE_LINES, _tracer_material(color))
	mesh.surface_add_vertex(from)
	mesh.surface_add_vertex(to)
	mesh.surface_end()

	var node := MeshInstance3D.new()
	node.mesh = mesh
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	world.add_child(node)
	# Раньше альфа гасилась твином по материалу — с общим материалом так нельзя,
	# да и 70 мс всё равно не разглядеть.
	_kill_later(node, 0.07)

static func _tracer_material(color: Color) -> StandardMaterial3D:
	var cached: StandardMaterial3D = _tracer_materials.get(color)
	if cached != null:
		return cached
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = color
	mat.emission_enabled = true
	mat.emission = color
	mat.emission_energy_multiplier = 2.0
	_tracer_materials[color] = mat
	return mat

static func impact(world: Node, point: Vector3, normal: Vector3, flesh: bool) -> void:
	if world == null:
		return
	var color := Color(0.75, 0.1, 0.1) if flesh else Color(0.9, 0.85, 0.7)

	var sparks := CPUParticles3D.new()
	sparks.mesh = _spark_mesh()
	sparks.emitting = true
	sparks.one_shot = true
	sparks.amount = 8 if flesh else 12
	sparks.lifetime = 0.35
	sparks.explosiveness = 1.0
	sparks.direction = normal
	sparks.spread = 45.0
	sparks.initial_velocity_min = 1.5
	sparks.initial_velocity_max = 4.5
	sparks.gravity = Vector3(0, -9.0, 0)
	sparks.scale_amount_min = 0.4
	sparks.scale_amount_max = 1.0
	sparks.color = color
	world.add_child(sparks)
	sparks.global_position = point + normal * 0.03
	_kill_later(sparks, 0.9)

	if not flesh:
		# Тёмная отметина на поверхности вместо полноценного декаля.
		var mark := MeshInstance3D.new()
		var quad := QuadMesh.new()
		quad.size = Vector2(0.09, 0.09)
		mark.mesh = quad
		mark.material_override = _mark()
		mark.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		world.add_child(mark)
		mark.global_position = point + normal * 0.012
		if absf(normal.dot(Vector3.UP)) < 0.98:
			mark.look_at(mark.global_position + normal, Vector3.UP)
		else:
			mark.look_at(mark.global_position + normal, Vector3.FORWARD)
		_kill_later(mark, 12.0)

static func _mark() -> StandardMaterial3D:
	if _mark_material == null:
		_mark_material = StandardMaterial3D.new()
		_mark_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_mark_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		_mark_material.albedo_color = Color(0.05, 0.04, 0.04, 0.85)
	return _mark_material

static func muzzle_flash(parent: Node3D, offset: Vector3) -> void:
	if parent == null:
		return
	var light := OmniLight3D.new()
	light.light_color = Color(1.0, 0.82, 0.5)
	light.light_energy = 3.5
	light.omni_range = 6.0
	parent.add_child(light)
	light.position = offset

	var flash := MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = 0.055
	sphere.height = 0.11
	flash.mesh = sphere
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(1.0, 0.9, 0.6)
	flash.material_override = mat
	flash.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(flash)
	flash.position = offset

	var tween := parent.create_tween()
	tween.tween_interval(0.045)
	tween.tween_callback(light.queue_free)
	tween.tween_callback(flash.queue_free)

static func _spark_mesh() -> Mesh:
	if _spark == null:
		var box := BoxMesh.new()
		box.size = Vector3(0.02, 0.02, 0.02)
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.vertex_color_use_as_albedo = true
		box.material = mat
		_spark = box
	return _spark

static func _kill_later(node: Node, seconds: float) -> void:
	var timer := node.get_tree().create_timer(seconds)
	timer.timeout.connect(func() -> void:
		if is_instance_valid(node):
			node.queue_free())
