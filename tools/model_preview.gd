## Рендерит модель на нейтральном фоне и печатает её габариты —
## чтобы подобрать масштаб и поворот для вида от первого лица.
##   Godot_v4.7.2-stable_win64.exe --path <проект> res://tools/model_preview.tscn
extends Node3D

const MODELS := [
	"res://assets/weapons/Rifle.fbx",
	"res://assets/weapons/Pistol.fbx",
	"res://assets/raw/protagonists/Model/characterMedium.fbx",
]

func _ready() -> void:
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.18, 0.2, 0.24)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(1, 1, 1)
	e.ambient_light_energy = 0.6
	env.environment = e
	add_child(env)

	var sun := DirectionalLight3D.new()
	add_child(sun)
	sun.rotation_degrees = Vector3(-40, 35, 0)

	var camera := Camera3D.new()
	add_child(camera)
	camera.current = true

	for path in MODELS:
		if not ResourceLoader.exists(path):
			print(path, " — не импортирован")
			continue
		var model := (load(path) as PackedScene).instantiate() as Node3D
		add_child(model)
		await get_tree().process_frame

		var aabb := _combined_aabb(model, model.global_transform)
		print("%s: размер=%s центр=%s" % [
			path.get_file(), str(aabb.size.snappedf(0.001)), str(aabb.get_center().snappedf(0.001))])

		# Камера сбоку, на расстоянии, пропорциональном габаритам.
		var radius: float = maxf(aabb.size.length(), 0.001)
		camera.global_position = aabb.get_center() + Vector3(radius * 1.3, radius * 0.5, radius * 1.3)
		camera.look_at(aabb.get_center(), Vector3.UP)

		await RenderingServer.frame_post_draw
		await RenderingServer.frame_post_draw
		var image := get_viewport().get_texture().get_image()
		image.save_png("res://tools/preview_%s.png" % path.get_file().get_basename())
		model.queue_free()
		await get_tree().process_frame

	get_tree().quit()

func _combined_aabb(node: Node, base: Transform3D) -> AABB:
	var result := AABB()
	var first := true
	for child in _walk(node):
		if child is VisualInstance3D:
			var local: AABB = child.get_aabb()
			var world: Transform3D = base.affine_inverse() * child.global_transform
			var transformed: AABB = world * local
			if first:
				result = transformed
				first = false
			else:
				result = result.merge(transformed)
	return result

func _walk(node: Node) -> Array[Node]:
	var out: Array[Node] = [node]
	for child in node.get_children():
		out.append_array(_walk(child))
	return out
