## Офлайн-регресс без редактора, с кодом возврата:
##   Godot_v4.7.2-stable_win64.exe --headless --path . res://tools/regression_test.tscn
##
## Сюда дописываются проверки на каждый закрытый дефект. Провал любой проверки
## завершает процесс кодом 1 — этим пользуется tools/run_offline_tests.ps1.
extends Node

var main: Node
var failures: int = 0

func _ready() -> void:
	main = load("res://scenes/main.tscn").instantiate()
	main.online = false
	add_child(main)
	# Карта, игрок и боты появляются за первый кадр, а вот физика — нет: спавн
	# стоит в 0.2 м над дорогой, и на падение уходит около 13 физкадров.
	await get_tree().process_frame
	await _settle()
	await _run()
	print("REGRESSION TEST: ", "PASS" if failures == 0 else "FAIL", " failures=", failures)
	get_tree().quit(0 if failures == 0 else 1)

## Ждём, пока бойцы улягутся на землю. Потолок по кадрам оставлен намеренно:
## если игрок так и не приземлился, проверка должна упасть, а не висеть.
func _settle() -> void:
	for i in 60:
		await get_tree().physics_frame
		if main.player != null and main.player.is_on_floor():
			return

func _run() -> void:
	var player: PlayerCharacter = main.player
	_check(player != null and player.is_on_floor(), "игрок стоит на земле")

	var bot: Bot = _first_bot()
	_check(bot != null, "бот создан")

	# Труп не должен ловить пули и мешать ходить.
	bot.health.take_damage(10000.0, player, false, 1.0)
	await get_tree().physics_frame
	_check(bot.collision_layer == 0, "труп бота убран со слоя попаданий")

	var space := player.get_world_3d().direct_space_state
	var across := PhysicsRayQueryParameters3D.create(
		bot.global_position + Vector3.UP * 0.9 + Vector3.RIGHT * 4.0,
		bot.global_position + Vector3.UP * 0.9 - Vector3.RIGHT * 4.0)
	across.collision_mask = 1 | 2 | 4
	_check(space.intersect_ray(across).get("collider") != bot, "луч проходит сквозь труп")

	# Игроки должны сталкиваться телами друг с другом.
	_check(player.collision_mask & 2 != 0, "игрок сталкивается с игроками")
	_check(bot.collision_mask & 4 != 0, "боты сталкиваются друг с другом")

	# Матч без живого соединения обязан быть честно офлайновым.
	_check(not main.online, "офлайн-матч не притворяется сетевым")
	for node in main.get_node("Actors").get_children():
		if node is WeaponPickup:
			_check(node.network_index < 0, "точка оружия офлайн не ждёт хоста")
			break

	# Дробь складывается по цели: один выстрел — одно подтверждение, а не девять.
	# Бот ставится в 2.5 м прямо перед игроком: это внутри той же клетки карты
	# (клетка 6.5 м), поэтому стена между ними появиться не может.
	var victim: Bot = _bots()[1]
	var shooter: PlayerCharacter = main.player
	victim.global_position = shooter.global_position - shooter.global_transform.basis.z * 2.5
	victim.state = Bot.State.IDLE
	await get_tree().physics_frame
	var confirms := [0]
	shooter.weapons.hit_confirmed.connect(func(_h, _k) -> void: confirms[0] += 1)
	shooter.weapons.give(&"spas", true)
	shooter.weapons._equip_left = 0.0
	shooter.weapons._cooldown = 0.0
	shooter.weapons._try_fire({"speed": 0.0, "on_floor": true, "crouching": false, "sprinting": false})
	await get_tree().physics_frame
	_check(confirms[0] == 1, "выстрел дробью подтверждается один раз (получено %d)" % confirms[0])

	# Токен-бакет: 20 пакетов в секунду при запасе 30 — тридцать первый подряд
	# обязан быть отброшен.
	var budget := RateLimiter.new(20.0, 30.0)
	var allowed := 0
	for i in 40:
		if budget.allow(7):
			allowed += 1
	_check(allowed == 30, "бюджет RPC пропускает ровно запас (пропущено %d)" % allowed)

	# Имя приходит от чужого клиента: длину режем при показе.
	main.player.display_name = "Ы".repeat(200)
	_check(main._name_of(main.player).length() <= 24, "длинное имя обрезается в киллфиде")

	# Прицел должен знать текущий fov, иначе в прицеливании штрихи врут.
	# Физику игрока глушим: иначе _update_view утянет fov назад к базовому.
	main.player.set_physics_process(false)
	main.player.camera.fov = 55.0
	await get_tree().process_frame
	await get_tree().process_frame
	_check(is_equal_approx(main.hud._crosshair.fov_degrees, 55.0), "прицел знает fov камеры")
	main.player.set_physics_process(true)

	# Повторная сборка не должна удваивать карту.
	var city: CityMap = main.get_node("Map")
	var spawns := city.player_spawns.size()
	var props := city.get_node("Props").get_child_count()
	var started := Time.get_ticks_msec()
	city.build(main.match_seed)
	print("сборка карты: %d мс" % (Time.get_ticks_msec() - started))
	await get_tree().process_frame
	_check(city.player_spawns.size() == spawns, "повторная сборка не удваивает спавны")
	_check(city.get_node("Props").get_child_count() == props, "повторная сборка не удваивает пропы")

func _bots() -> Array:
	return main.get_node("Actors").get_children().filter(func(n): return n is Bot)

func _first_bot() -> Bot:
	for node in main.get_node("Actors").get_children():
		if node is Bot:
			return node
	return null

func _check(ok: bool, label: String) -> void:
	if not ok:
		failures += 1
	print("PASS" if ok else "FAIL", " ", label)
