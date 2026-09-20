## Матрица подбора ориентации оружия: строка — ствол (в порядке Weapons.ids()),
## колонка — вариант доворота из VARIANTS. Каждая ячейка снята камерой игрока,
## поэтому правильный вариант виден сразу: ствол уходит вглубь кадра.
## Выбранный угол прописывается в weapons_db.gd как "model_rotation".
##   Godot_v4.7.2-stable_win64.exe --path <проект> res://tools/viewmodel_preview.tscn
extends Node3D

const SHOT := Vector2i(300, 200)

## Доворот модели вокруг осей, в градусах.
const VARIANTS := [
	Vector3(0, 0, 0),
	Vector3(-90, 0, 0),
	Vector3(90, 0, 0),
	Vector3(0, 90, 0),
	Vector3(0, -90, 0),
	Vector3(0, 180, 0),
]

var _camera: Camera3D
var _pivot: Node3D

func _ready() -> void:
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.16, 0.18, 0.22)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(1, 1, 1)
	e.ambient_light_energy = 1.8
	env.environment = e
	add_child(env)

	var key := DirectionalLight3D.new()
	add_child(key)
	key.rotation_degrees = Vector3(-35, 30, 0)

	_camera = Camera3D.new()
	_camera.fov = 85.0
	_camera.near = 0.05
	add_child(_camera)
	_camera.current = true

	_pivot = Node3D.new()
	_camera.add_child(_pivot)

	var ids: Array = Weapons.ids()
	var sheet := Image.create(SHOT.x * VARIANTS.size(), SHOT.y * ids.size(), false, Image.FORMAT_RGBA8)
	for row in ids.size():
		var data: WeaponData = Weapons.get_weapon(ids[row])
		for column in VARIANTS.size():
			var shot := await _shoot(data, VARIANTS[column])
			shot.resize(SHOT.x, SHOT.y, Image.INTERPOLATE_BILINEAR)
			shot.convert(Image.FORMAT_RGBA8)
			sheet.blit_rect(shot, Rect2i(Vector2i.ZERO, SHOT), Vector2i(column * SHOT.x, row * SHOT.y))
	sheet.save_png("res://tools/view_sheet.png")
	print("строки: ", ", ".join(ids))
	print("колонки: ", VARIANTS)
	get_tree().quit()

func _shoot(data: WeaponData, degrees: Vector3) -> Image:
	var holder := Node3D.new()
	_pivot.add_child(holder)
	if data.model_path != "" and ResourceLoader.exists(data.model_path):
		var model := (load(data.model_path) as PackedScene).instantiate() as Node3D
		holder.add_child(model)
		var probe: WeaponData = data.duplicate()
		probe.model_rotation = Vector3(deg_to_rad(degrees.x), deg_to_rad(degrees.y), deg_to_rad(degrees.z))
		ViewModel.fit(model, probe)
	holder.position = WeaponManager.HIP_POSITION
	holder.rotation = Vector3(0.0, -0.07, 0.0)

	await get_tree().process_frame
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var image := get_viewport().get_texture().get_image()
	holder.queue_free()
	await get_tree().process_frame
	return image
