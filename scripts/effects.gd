## Scene-owned, prewarmed effects. Saturation recycles the oldest active slot.
class_name Effects
extends RefCounted

const Pool = preload("res://scripts/effect_pool.gd")
const Tracer = preload("res://scripts/bullet_tracer.gd")
## Слой мировой геометрии: вспышка обязана освещать и его, и слой оружия.
const WORLD_LAYER := 1
const MARK_LIMIT := 128
const BURST_LIMIT := 32
const CASING_LIMIT := 48
const TRACER_LIMIT := 64
const FLASH_LIMIT := 16
const POOL_NAME := "CombatEffectsPool"
static var _tracer_materials: Dictionary = {}
static var _marks: Dictionary = {}
static var _spark: Mesh
static var _dust_mesh: Mesh
static var _casing_mesh: Mesh
static var _shell_mesh: Mesh
static var _flash_mesh: Mesh
static var _explosion_mesh: Mesh
static var _tracer_mesh: Mesh
static var _mark_mesh: Mesh

static func prewarm(world: Node) -> Node3D:
	if not is_instance_valid(world) or not world.is_inside_tree():
		return null
	var existing := world.get_node_or_null(POOL_NAME)
	if existing != null:
		return existing
	var pool := Pool.new()
	pool.name = POOL_NAME
	pool.process_priority = 100
	world.add_child(pool)
	pool.warm(&"mark", MARK_LIMIT, _new_mark)
	pool.warm(&"burst", BURST_LIMIT, _new_burst)
	pool.warm(&"casing", CASING_LIMIT, _new_casing)
	pool.warm(&"tracer", TRACER_LIMIT, _new_tracer)
	pool.warm(&"flash", FLASH_LIMIT, _new_flash)
	_mark_material("concrete")
	_mark_material("metal")
	_tracer_material(Color(1.0, 0.85, 0.45))
	_tracer_material(Color(1.0, 0.55, 0.3))
	_get_dust_mesh()
	_get_explosion_mesh()
	return pool

static func tracer(world: Node, from: Vector3, to: Vector3, color: Color = Color(1.0, 0.85, 0.45)) -> MeshInstance3D:
	if not is_instance_valid(world) or not from.is_finite() or not to.is_finite() or from.distance_to(to) < 0.05:
		return null
	var pool = prewarm(world)
	if pool == null:
		return null
	var lifetime := Tracer.duration_for(from.distance_to(to))
	var node: MeshInstance3D = pool.take(&"tracer", lifetime, &"bullet_tracers")
	node.material_override = _tracer_material(color)
	node.activate(from, to)
	return node

static func _new_tracer() -> MeshInstance3D:
	if _tracer_mesh == null:
		var mesh := BoxMesh.new()
		mesh.size = Vector3(0.006, 0.006, 1.0)
		_tracer_mesh = mesh
	var node := _visual(_tracer_mesh)
	node.set_script(Tracer)
	node.set_process(false)
	return node

static func _tracer_material(color: Color) -> StandardMaterial3D:
	var cached: StandardMaterial3D = _tracer_materials.get(color)
	if cached != null:
		return cached
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = color
	mat.emission_enabled = true
	mat.emission = color
	mat.emission_energy_multiplier = 2.0
	_tracer_materials[color] = mat
	return mat

## Material metadata belongs to map objects; colliders inherit it from parents.
static func surface(body: Node) -> String:
	var node := body
	while is_instance_valid(node):
		if node.has_meta("surface"):
			return str(node.get_meta("surface"))
		node = node.get_parent()
	return "concrete"

static func impact(world: Node, point: Vector3, normal: Vector3, flesh: bool, body: Node3D = null) -> void:
	if not is_instance_valid(world) or not point.is_finite() or not normal.is_finite() or normal.length_squared() < 0.01:
		return
	var pool = prewarm(world)
	if pool == null:
		return
	normal = normal.normalized()
	var kind := "flesh" if flesh else surface(body)
	var metal := kind == "metal"
	var color := Color(0.58, 0.055, 0.04) if flesh else (Color(1.0, 0.72, 0.25) if metal else Color(0.6, 0.56, 0.48))
	var sparks: CPUParticles3D = pool.take(&"burst", 0.7, &"impact_bursts")
	sparks.mesh = _spark_mesh()
	sparks.color_ramp = null
	sparks.lifetime = 0.24 if metal else 0.4
	sparks.direction = normal
	sparks.spread = 58.0
	sparks.initial_velocity_min = 2.0 if metal else 0.7
	sparks.initial_velocity_max = 6.0 if metal else 2.5
	sparks.gravity = Vector3(0, -9.0, 0)
	sparks.scale_amount_min = 0.2 if metal else 0.5
	sparks.scale_amount_max = 0.5 if metal else 1.2
	sparks.color = color
	sparks.global_transform = Transform3D(Basis.IDENTITY, point + normal * 0.015)
	sparks.restart()
	sparks.emitting = true
	if not flesh:
		bullet_mark(world, point, normal, body, kind)
		if not metal:
			_dust(pool, point, normal, color)
		Sfx.play_3d(&"impact_metal" if metal else &"impact_stone", point + normal * 0.04, randf_range(0.85, 1.15), -9.0, 35.0)

static func bullet_mark(world: Node, point: Vector3, normal: Vector3, body: Node3D = null, kind: String = "concrete") -> MeshInstance3D:
	if not point.is_finite() or not normal.is_finite() or normal.length_squared() < 0.01:
		return null
	var pool = prewarm(world)
	if pool == null:
		return null
	normal = normal.normalized()
	var mark: MeshInstance3D = pool.take(&"mark", 30.0, &"bullet_marks")
	mark.material_override = _mark_material(kind)
	var up := Vector3.UP if absf(normal.dot(Vector3.UP)) < 0.98 else Vector3.FORWARD
	var basis := Basis.looking_at(normal, up).rotated(normal, randf_range(0, TAU))
	mark.global_transform = Transform3D(basis.scaled(Vector3.ONE * (0.065 if kind == "metal" else 0.105)), point + normal * 0.002)
	if is_instance_valid(body):
		pool.follow(mark, body)
	return mark

static func _new_mark() -> MeshInstance3D:
	if _mark_mesh == null:
		var quad := QuadMesh.new()
		quad.size = Vector2.ONE
		_mark_mesh = quad
	return _visual(_mark_mesh)

static func _mark_material(kind: String) -> ShaderMaterial:
	var key := "metal" if kind == "metal" else "concrete"
	if not _marks.has(key):
		var material := ShaderMaterial.new()
		material.shader = preload("res://scripts/bullet_mark.gdshader")
		material.set_shader_parameter("rim_color", Color(0.36, 0.39, 0.41) if key == "metal" else Color(0.34, 0.31, 0.26))
		_marks[key] = material
	return _marks[key]

static func _new_burst() -> CPUParticles3D:
	var particles := CPUParticles3D.new()
	particles.emitting = false
	particles.amount = 14
	particles.mesh = _spark_mesh()
	particles.one_shot = true
	particles.explosiveness = 1.0
	particles.local_coords = false
	particles.set_meta("dust_ramp", Gradient.new())
	return particles

static func _dust(pool: Node3D, point: Vector3, normal: Vector3, color: Color) -> void:
	var dust: CPUParticles3D = pool.take(&"burst", 0.8, &"impact_bursts")
	dust.mesh = _get_dust_mesh()
	dust.lifetime = 0.55
	dust.direction = normal
	dust.spread = 65.0
	dust.initial_velocity_min = 0.25
	dust.initial_velocity_max = 1.2
	dust.gravity = Vector3(0, 0.3, 0)
	var ramp: Gradient = dust.get_meta("dust_ramp")
	ramp.set_color(0, Color(color, 0.35))
	ramp.set_color(1, Color(color, 0.0))
	dust.color_ramp = ramp
	dust.color = Color.WHITE
	dust.scale_amount_min = 0.7
	dust.scale_amount_max = 2.0
	dust.global_transform = Transform3D(Basis.IDENTITY, point + normal * 0.035)
	dust.restart()
	dust.emitting = true

static func _get_dust_mesh() -> Mesh:
	if _dust_mesh == null:
		var mesh := SphereMesh.new()
		mesh.radius = 0.04
		mesh.height = 0.08
		mesh.radial_segments = 8
		mesh.rings = 4
		var material := StandardMaterial3D.new()
		material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		material.vertex_color_use_as_albedo = true
		mesh.material = material
		_dust_mesh = mesh
	return _dust_mesh

## Cosmetic physics uses its own mask and never absorbs authoritative hitscan.
static func physical_hit(world: Node3D, from: Vector3, to: Vector3, strength: float = 4.0) -> RigidBody3D:
	if from.distance_squared_to(to) < 0.001:
		return null
	var query := PhysicsRayQueryParameters3D.create(from, to, 1 << 4)
	var hit := world.get_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty() or not hit.collider is RigidBody3D:
		return null
	var body: RigidBody3D = hit.collider
	body.apply_impulse(from.direction_to(to) * clampf(strength, 0.5, 8.0), hit.position - body.global_position)
	impact(world.get_tree().current_scene, hit.position, hit.normal, surface(body) == "flesh", body)
	return body

static func casing(world: Node, at: Transform3D, shell: bool = false) -> RigidBody3D:
	var pool = prewarm(world)
	if pool == null:
		return null
	var body: RigidBody3D = pool.take(&"casing", 6.0, &"spent_casings")
	var visual: MeshInstance3D = body.get_node("Mesh")
	visual.mesh = _get_casing_mesh(shell)
	var collider: CollisionShape3D = body.get_node("Collision")
	collider.shape.size = Vector3(0.014, 0.038 if shell else 0.025, 0.014)
	body.activate(at)
	return body

static func _new_casing() -> RigidBody3D:
	var body := preload("res://scripts/spent_casing.gd").new()
	body.mass = 0.012
	body.collision_layer = 0
	body.collision_mask = 0
	body.continuous_cd = true
	body.linear_damp = 0.15
	body.angular_damp = 0.7
	body.freeze = true
	var physical := PhysicsMaterial.new()
	physical.bounce = 0.35
	physical.friction = 0.6
	body.physics_material_override = physical
	var visual := _visual(_get_casing_mesh(false))
	_get_casing_mesh(true)
	visual.name = "Mesh"
	body.add_child(visual)
	var collider := CollisionShape3D.new()
	collider.name = "Collision"
	var shape := BoxShape3D.new()
	shape.size = Vector3(0.014, 0.025, 0.014)
	collider.shape = shape
	body.add_child(collider)
	return body

static func _get_casing_mesh(shell: bool) -> Mesh:
	var cached := _shell_mesh if shell else _casing_mesh
	if cached != null:
		return cached
	var mesh := CylinderMesh.new()
	mesh.top_radius = 0.007 if shell else 0.005
	mesh.bottom_radius = mesh.top_radius
	mesh.height = 0.038 if shell else 0.025
	mesh.radial_segments = 8
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.55, 0.09, 0.06) if shell else Color(0.72, 0.49, 0.16)
	material.metallic = 0.45 if shell else 0.8
	material.roughness = 0.32
	mesh.material = material
	if shell:
		_shell_mesh = mesh
	else:
		_casing_mesh = mesh
	return mesh

## Свет светит и в мир, и на слой оружия: иначе вспышка озаряет только руки, а
## стена в полуметре остаётся чёрной. Пламя живёт на слое оружия и в мир не
## выносится — у локального игрока ствол рисуется поверх мира, и мировое пламя
## оказалось бы внутри ближайшей стены.
static func muzzle_flash(parent: Node3D, offset: Vector3, render_mask: int = 1, scale_factor: float = 1.0) -> void:
	if not is_instance_valid(parent) or not parent.is_inside_tree():
		return
	var world: Node = parent.get_tree().current_scene
	if world == null:
		world = parent.get_parent()
	var pool = prewarm(world)
	if pool == null:
		return
	var size := clampf(scale_factor, 0.5, 2.0)
	var flash: Node3D = pool.take(&"flash", 0.045, &"muzzle_flashes")
	var light: OmniLight3D = flash.get_node("Light")
	light.light_cull_mask = WORLD_LAYER | render_mask
	light.layers = WORLD_LAYER | render_mask
	light.light_energy = 3.5 * size
	light.omni_range = 6.0 * size
	var mesh: MeshInstance3D = flash.get_node("Mesh")
	mesh.layers = render_mask
	mesh.mesh = _flash_mesh
	# Разворот вокруг оси ствола: на автомате одинаковое пламя десять раз в
	# секунду читается как застывшая картинка.
	mesh.transform = Transform3D(
		Basis(Vector3.FORWARD, randf() * TAU) * Basis(Vector3.RIGHT, -PI * 0.5) * Basis.IDENTITY.scaled(Vector3.ONE * size),
		Vector3.FORWARD * 0.06)
	flash.global_transform = parent.global_transform.orthonormalized() * Transform3D(Basis.IDENTITY, offset)
	pool.follow(flash, parent)

## Free-space blast: smoke, hot fragments and a brief light, never surface marks.
static func explosion(world: Node, point: Vector3) -> void:
	if not point.is_finite():
		return
	var pool = prewarm(world)
	if pool == null:
		return
	var sparks: CPUParticles3D = pool.take(&"burst", 0.8, &"impact_bursts")
	sparks.mesh = _spark_mesh()
	sparks.color_ramp = null
	sparks.color = Color(1.0, 0.48, 0.10)
	sparks.lifetime = 0.55
	sparks.direction = Vector3.UP
	sparks.spread = 180.0
	sparks.initial_velocity_min = 2.0
	sparks.initial_velocity_max = 7.0
	sparks.gravity = Vector3(0, -3, 0)
	sparks.scale_amount_min = 1.0
	sparks.scale_amount_max = 3.0
	sparks.global_transform = Transform3D(Basis.IDENTITY, point)
	sparks.restart()
	sparks.emitting = true
	var smoke: CPUParticles3D = pool.take(&"burst", 1.6, &"impact_bursts")
	smoke.mesh = _get_dust_mesh()
	smoke.color = Color.WHITE
	var ramp: Gradient = smoke.get_meta("dust_ramp")
	ramp.set_color(0, Color(0.24, 0.22, 0.19, 0.55))
	ramp.set_color(1, Color(0.28, 0.27, 0.25, 0.0))
	smoke.color_ramp = ramp
	smoke.lifetime = 1.15
	smoke.direction = Vector3.UP
	smoke.spread = 180.0
	smoke.initial_velocity_min = 0.5
	smoke.initial_velocity_max = 2.3
	smoke.gravity = Vector3(0, 0.6, 0)
	smoke.scale_amount_min = 4.0
	smoke.scale_amount_max = 12.0
	smoke.global_transform = Transform3D(Basis.IDENTITY, point)
	smoke.restart()
	smoke.emitting = true
	var flash: Node3D = pool.take(&"flash", 0.11, &"muzzle_flashes")
	flash.global_transform = Transform3D(Basis.IDENTITY, point)
	var light: OmniLight3D = flash.get_node("Light")
	light.layers = 1
	light.light_cull_mask = 1
	light.light_energy = 12.0
	light.omni_range = 10.0
	var mesh: MeshInstance3D = flash.get_node("Mesh")
	mesh.layers = 1
	mesh.mesh = _get_explosion_mesh()
	mesh.transform = Transform3D.IDENTITY

static func _get_explosion_mesh() -> Mesh:
	if _explosion_mesh == null:
		var mesh := SphereMesh.new()
		mesh.radius = 0.38
		mesh.height = 0.76
		mesh.radial_segments = 12
		mesh.rings = 6
		mesh.material = _tracer_material(Color(1.0, 0.55, 0.15))
		_explosion_mesh = mesh
	return _explosion_mesh

static func _new_flash() -> Node3D:
	var root := Node3D.new()
	var light := OmniLight3D.new()
	light.name = "Light"
	light.light_color = Color(1.0, 0.82, 0.5)
	light.light_energy = 3.5
	light.omni_range = 6.0
	root.add_child(light)
	if _flash_mesh == null:
		var flame := CylinderMesh.new()
		flame.top_radius = 0.002
		flame.bottom_radius = 0.035
		flame.height = 0.16
		flame.radial_segments = 6
		flame.material = _tracer_material(Color(1.0, 0.55, 0.15))
		_flash_mesh = flame
	var mesh := _visual(_flash_mesh)
	mesh.name = "Mesh"
	mesh.position = Vector3.FORWARD * 0.06
	mesh.rotation.x = -PI * 0.5
	root.add_child(mesh)
	return root

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

static func _visual(mesh: Mesh) -> MeshInstance3D:
	var visual := MeshInstance3D.new()
	visual.mesh = mesh
	visual.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return visual
