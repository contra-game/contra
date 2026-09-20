## Снимает два кадра матча и выходит — вид от игрока и общий план карты.
##   Godot_v4.7.2-stable_win64.exe --path <проект> res://tools/screenshot.tscn
## Кадры кладутся в tools/shot_player.png и tools/shot_map.png.
extends Node

const WARMUP := 1.2

func _ready() -> void:
	var main: Node = load("res://scenes/main.tscn").instantiate()
	main.online = false   # снимки делаем в офлайн-матче
	add_child(main)
	# Боты замораживаются, иначе к моменту съёмки игрок обычно уже убит
	# и оружие убрано в кобуру.
	for node in main.get_node("Actors").get_children():
		if node is Bot:
			node.set_physics_process(false)
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

	# Отладочный кадр: игрок со стороны, видно, где висит модель оружия.
	var player: PlayerCharacter = main.player
	overview.global_position = player.global_position + player.global_transform.basis * Vector3(1.4, 1.9, 1.2)
	overview.look_at(player.camera.global_position, Vector3.UP)
	overview.fov = 55.0
	await _shoot("res://tools/shot_thirdperson.png")
	overview.fov = 70.0

	# Кадр с оптикой: выдаём AWP и зажимаем прицеливание.
	player.weapons.give(&"awp", true)
	var aim := InputEventAction.new()
	aim.action = "aim"
	aim.pressed = true
	Input.parse_input_event(aim)
	await get_tree().create_timer(0.4).timeout
	player.camera.current = true
	await _shoot("res://tools/shot_scope.png")
	aim.pressed = false
	Input.parse_input_event(aim)
	await get_tree().process_frame
	overview.current = true

	# Кадр магазина: событие отправляется как настоящее нажатие B.
	var buy := InputEventAction.new()
	buy.action = "buy"
	buy.pressed = true
	Input.parse_input_event(buy)
	await get_tree().process_frame
	await _shoot("res://tools/shot_shop.png")
	Input.parse_input_event(buy)
	await get_tree().process_frame

	# Третий кадр — крупный план бойца, чтобы видеть модель и анимацию.
	for node in main.get_node("Actors").get_children():
		if node is Bot:
			overview.global_position = node.global_position + Vector3(2.2, 1.6, 2.2)
			overview.look_at(node.global_position + Vector3.UP * 0.9, Vector3.UP)
			await _shoot("res://tools/shot_bot.png")
			break

	get_tree().quit()

func _shoot(path: String) -> void:
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var image := get_viewport().get_texture().get_image()
	image.save_png(path)
	print("saved %s (%dx%d)" % [path, image.get_width(), image.get_height()])
