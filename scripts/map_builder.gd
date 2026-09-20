## Собирает городской квартал из CC0-моделей Kenney по текстовой схеме.
##
## Править карту = править LAYOUT ниже. Один символ — одна клетка GRID×GRID
## метров. Коллизии считаются автоматически по мешам, так что новую модель
## достаточно добавить в списки — ничего настраивать в редакторе не нужно.
class_name CityMap
extends Node3D

## Размер клетки в метрах. Модели Kenney сделаны в масштабе "1 клетка = 1 юнит",
## поэтому тот же коэффициент используется как масштаб мешей.
const GRID := 6.5

const LAYOUT := [
	"#############",
	"#P..w.B.w..P#",
	"#.##.x.x.##.#",
	"#.##..t..##.#",
	"#B.x..I..x.B#",
	"#w.........w#",
	"#..B.x.x.B..#",
	"#w.........w#",
	"#B.x..I..x.B#",
	"#.##..t..##.#",
	"#.##.x.x.##.#",
	"#P..w.B.w..P#",
	"#############",
]

## Улицы с разметкой поверх асфальта.
const ROAD_ROWS := [5, 7]
const ROAD_COLS := [5, 7]

const COMMERCIAL := "res://assets/city/commercial/"
const INDUSTRIAL := "res://assets/city/industrial/"
const ROADS := "res://assets/city/roads/"

const HOUSES := [
	"building-a", "building-b", "building-c", "building-d", "building-e",
	"building-f", "building-g", "building-h", "building-i", "building-j",
	"building-k", "building-l", "building-m", "building-n",
]
const TOWERS := [
	"building-skyscraper-a", "building-skyscraper-b", "building-skyscraper-c",
	"building-skyscraper-d", "building-skyscraper-e",
]
const FACTORIES := [
	"building-a", "building-c", "building-e", "building-g", "building-j",
	"building-l", "building-n", "building-q", "building-s",
]
const CONTAINERS := ["shipping-container-a", "shipping-container-b", "shipping-container-c"]

var player_spawns: Array[Transform3D] = []
var bot_spawns: Array[Transform3D] = []
var weapon_spawns: Array[Vector3] = []

var _cache: Dictionary = {}
## Путь модели -> [{"shape": Shape3D, "transform": Transform3D}, ...].
var _shapes: Dictionary = {}
var _rng := RandomNumberGenerator.new()
var _props: Node3D
var _has_models: bool = ResourceLoader.exists(COMMERCIAL + "building-a.glb")

func build(seed_value: int = 20260920) -> void:
	# Повторный вызов не должен удваивать карту. remove_child до queue_free —
	# иначе освобождение отложится до конца кадра, имя "Props" окажется занято
	# и новый узел получит имя "Props2".
	player_spawns.clear()
	bot_spawns.clear()
	weapon_spawns.clear()
	for child in get_children():
		remove_child(child)
		child.queue_free()

	_rng.seed = seed_value
	_props = Node3D.new()
	_props.name = "Props"
	add_child(_props)

	_build_environment()
	_build_ground()
	_build_cells()
	_build_boundary()

func size_meters() -> float:
	return LAYOUT.size() * GRID

# --- разбор схемы ------------------------------------------------------------

func _build_cells() -> void:
	for row in LAYOUT.size():
		var line: String = LAYOUT[row]
		for col in line.length():
			var cell := line[col]
			var center := _cell_center(row, col)
			match cell:
				"#":
					_place_building(center, _is_corner(row, col))
				"I":
					_place_factory(center)
				"x":
					_place_container(center)
				"t":
					_place_landmark(center)
				"P":
					player_spawns.append(_spawn_transform(center))
					_place_road(row, col, center)
				"B":
					bot_spawns.append(_spawn_transform(center))
					_place_road(row, col, center)
				"w":
					weapon_spawns.append(center + Vector3.UP * 0.9)
					_place_road(row, col, center)
				_:
					_place_road(row, col, center)

func _cell_center(row: int, col: int) -> Vector3:
	var half := LAYOUT.size() * 0.5 - 0.5
	return Vector3((col - half) * GRID, 0.0, (row - half) * GRID)

func _is_corner(row: int, col: int) -> bool:
	var last := LAYOUT.size() - 1
	return (row <= 1 or row >= last - 1) and (col <= 1 or col >= last - 1)

func _spawn_transform(center: Vector3) -> Transform3D:
	var t := Transform3D.IDENTITY
	t.origin = center + Vector3.UP * 0.2
	# Разворачиваем спавн лицом к центру карты.
	var to_center := -center
	to_center.y = 0.0
	if to_center.length() > 0.5:
		t.basis = Basis(Vector3.UP, atan2(-to_center.x, -to_center.z))
	return t

# --- объекты -----------------------------------------------------------------

func _place_building(center: Vector3, corner: bool) -> void:
	if not _has_models:
		_place_block(center, Vector3(GRID * 0.9, 12.0 if corner else 8.0, GRID * 0.9), Color(0.42, 0.4, 0.38))
		return
	var model_name: String = TOWERS[_rng.randi() % TOWERS.size()] if corner else HOUSES[_rng.randi() % HOUSES.size()]
	_place_model(COMMERCIAL + model_name + ".glb", center, _rng.randi() % 4 * PI * 0.5, true)

func _place_factory(center: Vector3) -> void:
	if not _has_models:
		_place_block(center, Vector3(GRID * 0.8, 6.0, GRID * 0.8), Color(0.35, 0.36, 0.4))
		return
	var model_name: String = FACTORIES[_rng.randi() % FACTORIES.size()]
	_place_model(INDUSTRIAL + model_name + ".glb", center, _rng.randi() % 4 * PI * 0.5, true)

func _place_container(center: Vector3) -> void:
	if not _has_models:
		_place_block(center, Vector3(2.4, 2.6, 6.0), Color(0.6, 0.35, 0.2))
		return
	var model_name: String = CONTAINERS[_rng.randi() % CONTAINERS.size()]
	var offset := Vector3(_rng.randf_range(-1.2, 1.2), 0.0, _rng.randf_range(-1.2, 1.2))
	_place_model(INDUSTRIAL + model_name + ".glb", center + offset, _rng.randf_range(0.0, PI), true)

func _place_landmark(center: Vector3) -> void:
	if not _has_models:
		_place_block(center, Vector3(3.0, 9.0, 3.0), Color(0.5, 0.5, 0.52))
		return
	var model_name := "water-tower" if _rng.randf() < 0.6 else "detail-tank-large"
	_place_model(INDUSTRIAL + model_name + ".glb", center, _rng.randf_range(0.0, TAU), true)

## Асфальт с разметкой на перекрёстках улиц.
func _place_road(row: int, col: int, center: Vector3) -> void:
	if not _has_models:
		return
	var on_row := ROAD_ROWS.has(row)
	var on_col := ROAD_COLS.has(col)
	if not on_row and not on_col:
		return
	var model_name := "road-straight"
	var yaw := 0.0
	if on_row and on_col:
		model_name = "road-crossroad"
	elif on_row:
		yaw = PI * 0.5
	var road := _place_model(ROADS + model_name + ".glb", center - Vector3.UP * 0.05, yaw, false)
	if road != null and _rng.randf() < 0.18:
		_place_model(ROADS + "light-square.glb", center + Vector3(GRID * 0.42, 0.0, 0.0), _rng.randi() % 4 * PI * 0.5, false)

func _place_model(path: String, position: Vector3, yaw: float, with_collision: bool) -> Node3D:
	var scene: PackedScene = _cache.get(path)
	if scene == null:
		if not ResourceLoader.exists(path):
			return null
		scene = load(path)
		_cache[path] = scene
	var node := scene.instantiate() as Node3D
	if node == null:
		return null
	_props.add_child(node)
	node.position = position
	node.rotation.y = yaw
	node.scale = Vector3.ONE * GRID
	if with_collision:
		_attach_collision(node, _collision_shapes(path, node))
	return node

## Формы считаются один раз на модель и переиспользуются всеми её копиями:
## раньше на каждый из 118 объектов заново строился вогнутый тримеш.
## Выпуклая оболочка на меш дешевле и для коробчатых домов Kenney достаточна —
## внутрь них всё равно не заходят, а дороги и декали коллизию не получают.
func _collision_shapes(path: String, node: Node3D) -> Array:
	if _shapes.has(path):
		return _shapes[path]
	var built: Array = []
	if node is MeshInstance3D and node.mesh != null:
		_append_shape(node.mesh, Transform3D.IDENTITY, built)
	for child in node.get_children():
		_collect_shapes(child, Transform3D.IDENTITY, built)
	_shapes[path] = built
	return built

func _collect_shapes(node: Node, parent_transform: Transform3D, out: Array) -> void:
	var transform := parent_transform
	if node is Node3D:
		transform = parent_transform * node.transform
	if node is MeshInstance3D and node.mesh != null:
		_append_shape(node.mesh, transform, out)
	for child in node.get_children():
		_collect_shapes(child, transform, out)

func _append_shape(mesh: Mesh, transform: Transform3D, out: Array) -> void:
	var shape := mesh.create_convex_shape(true, true)
	if shape != null:
		out.append({"shape": shape, "transform": transform})

## Один StaticBody3D на объект вместо одного на каждый меш внутри него.
func _attach_collision(node: Node3D, shapes: Array) -> void:
	if shapes.is_empty():
		return
	var body := StaticBody3D.new()
	node.add_child(body)
	for row in shapes:
		var collision := CollisionShape3D.new()
		collision.shape = row["shape"]
		collision.transform = row["transform"]
		body.add_child(collision)

func _place_block(center: Vector3, size: Vector3, color: Color) -> void:
	var mesh := BoxMesh.new()
	mesh.size = size
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.roughness = 0.85
	var node := MeshInstance3D.new()
	node.mesh = mesh
	node.material_override = mat
	_props.add_child(node)
	node.position = center + Vector3.UP * size.y * 0.5

	# Коробке хватает BoxShape3D: тримеш по её же мешу — лишняя работа.
	var body := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	shape.shape = box
	body.add_child(shape)
	node.add_child(body)

# --- земля, границы, небо ----------------------------------------------------

func _build_ground() -> void:
	var extent := size_meters()
	var mesh := BoxMesh.new()
	mesh.size = Vector3(extent, 1.0, extent)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.29, 0.29, 0.31)
	mat.roughness = 0.95
	mat.uv1_scale = Vector3(extent * 0.25, extent * 0.25, 1.0)
	var ground := MeshInstance3D.new()
	ground.name = "Ground"
	ground.mesh = mesh
	ground.material_override = mat
	add_child(ground)
	ground.position = Vector3(0, -0.5, 0)

	var body := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = mesh.size
	shape.shape = box
	body.add_child(shape)
	ground.add_child(body)

## Невидимые стены по краю: даже если по периметру не хватит домов,
## с карты не уйти.
func _build_boundary() -> void:
	var extent := size_meters() * 0.5
	var height := 40.0
	for i in 4:
		var body := StaticBody3D.new()
		var shape := CollisionShape3D.new()
		var box := BoxShape3D.new()
		var horizontal := i < 2
		box.size = Vector3(extent * 2.0, height, 1.0) if horizontal else Vector3(1.0, height, extent * 2.0)
		shape.shape = box
		body.add_child(shape)
		add_child(body)
		var sign_value := 1.0 if i % 2 == 0 else -1.0
		body.position = Vector3(0, height * 0.5, extent * sign_value) if horizontal else Vector3(extent * sign_value, height * 0.5, 0)

func _build_environment() -> void:
	var env := Environment.new()
	var sky_material := ProceduralSkyMaterial.new()
	sky_material.sky_top_color = Color(0.29, 0.42, 0.62)
	sky_material.sky_horizon_color = Color(0.68, 0.71, 0.74)
	sky_material.ground_bottom_color = Color(0.22, 0.21, 0.2)
	sky_material.ground_horizon_color = Color(0.6, 0.58, 0.55)
	sky_material.sun_angle_max = 12.0
	var sky := Sky.new()
	sky.sky_material = sky_material
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 0.9
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.tonemap_white = 4.0
	env.ssao_enabled = true
	env.ssao_intensity = 1.4
	env.glow_enabled = true
	env.glow_intensity = 0.25
	env.fog_enabled = true
	env.fog_light_color = Color(0.68, 0.71, 0.76)
	env.fog_density = 0.0045
	env.fog_sky_affect = 0.2

	var world_env := WorldEnvironment.new()
	world_env.name = "WorldEnvironment"
	world_env.environment = env
	add_child(world_env)

	var sun := DirectionalLight3D.new()
	sun.name = "Sun"
	sun.light_energy = 1.15
	sun.light_color = Color(1.0, 0.96, 0.88)
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 140.0
	add_child(sun)
	sun.rotation_degrees = Vector3(-52.0, 38.0, 0.0)
