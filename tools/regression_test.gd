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

	# Игроки должны сталкиваться телами друг с другом.
	_check(player.collision_mask & 2 != 0, "игрок сталкивается с игроками")

func _first_bot() -> Bot:
	for node in main.get_node("Actors").get_children():
		if node is Bot:
			return node
	return null

func _check(ok: bool, label: String) -> void:
	if not ok:
		failures += 1
	print("PASS" if ok else "FAIL", " ", label)
