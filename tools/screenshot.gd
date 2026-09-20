## Снимает два кадра матча и выходит — вид от игрока и общий план карты.
##   Godot_v4.7.2-stable_win64.exe --path <проект> res://tools/screenshot.tscn
## Кадры кладутся в tools/shot_player.png и tools/shot_map.png.
extends Node

const WARMUP := 1.2

func _ready() -> void:
	var main: Node = load("res://scenes/main.tscn").instantiate()
	add_child(main)
	await get_tree().create_timer(WARMUP).timeout
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

	await _shoot("res://tools/shot_player.png")

	# Общий план: камера над центром карты, смотрит вниз под углом.
	var map: CityMap = main.get_node("Map")
	var overview := Camera3D.new()
	overview.fov = 70.0
	overview.far = 800.0
	add_child(overview)
	overview.global_position = Vector3(0.0, map.size_meters() * 0.62, map.size_meters() * 0.62)
	overview.look_at(Vector3.ZERO, Vector3.UP)
	overview.current = true
	await _shoot("res://tools/shot_map.png")

	get_tree().quit()

func _shoot(path: String) -> void:
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var image := get_viewport().get_texture().get_image()
	image.save_png(path)
	print("saved %s (%dx%d)" % [path, image.get_width(), image.get_height()])
