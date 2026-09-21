## Реальные столкновения капсулы: ступени, уклон, потолок и управление в воздухе.
extends Node3D

class DrivenPlayer extends PlayerCharacter:
	func _read_input() -> void:
		pass

var failures := 0
var player: PlayerCharacter

func _ready() -> void:
	_box(Vector3(0, -0.15, 0), Vector3(30, 0.3, 30))
	player = preload("res://scenes/player.tscn").instantiate()
	player.set_script(DrivenPlayer)
	add_child(player)
	player.position = Vector3(0, 0.02, 5)
	await _frames(8)
	_check(player.is_on_floor(), "капсула стабильно стоит на полу")
	player._input_dir = Vector2(0, -1)
	await _frames(12)
	_check(-player.velocity.z > 4.5, "разгон до скорости ходьбы меньше чем за 0.2 с")
	player._input_dir = Vector2.ZERO
	await _frames(12)
	_check(Vector2(player.velocity.x, player.velocity.z).length() < 0.01, "остановка на земле гасит инерцию")
	player._jump_buffer = 0.15
	await _frames(2)
	_check(player.velocity.y > 4.5 and not player.is_on_floor(), "буфер прыжка запускает отрыв от земли")
	player._jump_buffer = 0.15
	await _frames(8)
	_check(player.velocity.y < 4.0, "повторный ввод в воздухе не создаёт двойной прыжок")

	# Свободный полёт не тормозит сам по себе, встречный ввод меняет импульс.
	player.position = Vector3(0, 6, 5)
	player.velocity = Vector3(5, 0, 0)
	await _frames(2)
	var air_speed := player.velocity.x
	await _frames(12)
	_check(absf(player.velocity.x - air_speed) < 0.01, "прыжок без ввода сохраняет горизонтальный импульс")
	player._input_dir = Vector2(-1, 0)
	await _frames(8)
	_check(player.velocity.x < air_speed - 0.8, "air control позволяет постепенно контрстрейфить")
	player._input_dir = Vector2.ZERO
	await _frames(65)
	_check(player.is_on_floor(), "падение заканчивается устойчивой посадкой")
	_check(absf(player._land_kick) < 0.04, "пружина посадки возвращает камеру")

	# Край навеса не пересекает центральный луч, но блокирует плечо капсулы.
	player.position = Vector3(-5, 0.02, 0)
	player.velocity = Vector3.ZERO
	await _frames(8)
	player._set_height(PlayerCharacter.CROUCH_HEIGHT)
	var ceiling := _box(Vector3(-4.68, 1.62, 0), Vector3(0.2, 0.2, 1.0))
	await _frames(2)
	_check(player._blocked_above(), "край потолка блокирует вставание всей капсулой")
	ceiling.queue_free()
	await _frames(2)
	_check(not player._blocked_above(), "пол не даёт ложного запрета вставания")
	player._set_height(PlayerCharacter.STAND_HEIGHT)
	_check(is_equal_approx(player.head.position.y, PlayerCharacter.STAND_EYE), "высота глаз соответствует стоящей капсуле")
	player._set_height(PlayerCharacter.CROUCH_HEIGHT)
	_check(is_equal_approx(player.head.position.y, PlayerCharacter.CROUCH_EYE), "присед уменьшает капсулу и высоту глаз")
	player._set_height(PlayerCharacter.STAND_HEIGHT)

	# Три ступени по 25 см. Узкий высокий блок дальше не должен преодолеваться.
	for i in 3:
		_box(Vector3(0, (i + 1) * 0.125, 1.5 - i * 0.9), Vector3(2.5, (i + 1) * 0.25, 0.9))
	_box(Vector3(0, 0.95, -1.2), Vector3(2.5, 1.9, 0.9))
	player.position = Vector3(0, 0.02, 3.0)
	player.velocity = Vector3.ZERO
	player._step_camera_offset = 0.0
	await _frames(8)
	player._input_dir = Vector2(0, -1)
	var peak := 0.0
	var max_eye_delta := 0.0
	var previous_eye := player.camera.global_position.y
	for i in 90:
		await get_tree().physics_frame
		peak = maxf(peak, player.position.y)
		max_eye_delta = maxf(max_eye_delta, absf(player.camera.global_position.y - previous_eye))
		previous_eye = player.camera.global_position.y
	_check(peak > 0.72, "контроллер поднимается по трём ступеням")
	_check(player.position.z > -0.7, "высокая преграда остаётся непроходимой")
	_check(max_eye_delta < 0.16, "камера сглаживает подъём по ступеням")
	player._input_dir = Vector2(0, 1)
	await _frames(70)
	player._input_dir = Vector2.ZERO
	await _frames(10)
	_check(player.position.y < 0.03 and player.is_on_floor(), "контроллер спускается со ступеней и сохраняет контакт с полом")

	var ramp := _box(Vector3(6, 0.3, 0), Vector3(3, 0.3, 5))
	ramp.rotation.x = deg_to_rad(12.0)
	player.position = Vector3(6, 0.03, 3)
	player.velocity = Vector3.ZERO
	await _frames(8)
	player._input_dir = Vector2(0, -1)
	await _frames(38)
	player._input_dir = Vector2.ZERO
	await _frames(12)
	var resting := player.position
	await _frames(30)
	_check(player.is_on_floor() and player.position.y > 0.35, "капсула поднимается по разрешённому уклону")
	_check(player.position.distance_to(resting) < 0.02, "на склоне нет скольжения и вертикальной тряски")

	# Высота шага сама по себе не разрешает втиснуть голову в потолок.
	_box(Vector3(-8, 0.125, 0), Vector3(2.5, 0.25, 2))
	_box(Vector3(-8, 2.12, 0.5), Vector3(2.5, 0.3, 4))
	player.position = Vector3(-8, 0.02, 2.8)
	player.velocity = Vector3.ZERO
	await _frames(8)
	player._input_dir = Vector2(0, -1)
	await _frames(45)
	_check(player.position.z > 1.2 and player.position.y < 0.06, "низкий потолок блокирует подъём без проникновения капсулы")
	player._input_dir = Vector2.ZERO
	player.set_physics_process(false)
	player._on_recoil_kick(2.0, 1.0)
	player._update_view(1.0 / 60.0)
	_check(player.head.rotation.x > 0.0 and player.head.rotation.y > 0.0, "пружина отдачи меняет реальное направление камеры")
	player._camera_recoil_spring.reset()
	player._on_recoil_kick(2.0, 1.0)
	for i in 12:
		player._update_view(1.0 / 60.0)
	var recoil_60 := player.head.rotation
	player._camera_recoil_spring.reset()
	player._on_recoil_kick(2.0, 1.0)
	for i in 24:
		player._update_view(1.0 / 120.0)
	_check(player.head.rotation.distance_to(recoil_60) < 0.00001, "пружина камеры совпадает при 60 и 120 FPS")
	player._update_view(2.0)
	_check(absf(player.head.rotation.x) < 0.0001 and absf(player.head.rotation.y) < 0.0001, "отдача возвращается без дрейфа при длинном кадре")
	player.respawn(Transform3D(Basis.IDENTITY, Vector3(-8, 1, 4)))
	_check(is_zero_approx(player._step_camera_offset) and player._landing_spring.value == Vector3.ZERO, "респавн сбрасывает пружину и смещение ступеней")
	print("MOVEMENT TEST: ", "PASS" if failures == 0 else "FAIL", " failures=", failures)
	get_tree().quit(0 if failures == 0 else 1)

func _box(point: Vector3, size: Vector3) -> StaticBody3D:
	var body := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	shape.shape = box
	body.add_child(shape)
	add_child(body)
	body.position = point
	return body

func _frames(count: int) -> void:
	for i in count:
		await get_tree().physics_frame

func _check(ok: bool, label: String) -> void:
	if not ok:
		failures += 1
	print("PASS" if ok else "FAIL", " ", label)
