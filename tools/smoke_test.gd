## Быстрая проверка сборки без редактора:
##   Godot_v4.7.2-stable_win64.exe --headless --path <проект> res://tools/smoke_test.tscn
##
## Поднимает матч на несколько секунд и печатает, что реально получилось:
## сколько объектов на карте, стоит ли игрок на земле, работают ли боты,
## проходит ли урон. Запускается именно как сцена — в режиме --script
## автозагрузки (Weapons, Sfx) не создаются и скрипты не компилируются.
extends Node

const RUN_SECONDS := 6.0

var main: Node
var _elapsed: float = 0.0
var _next_sample: float = 1.0
var _timeline: Array[String] = []

func _ready() -> void:
	main = load("res://scenes/main.tscn").instantiate()
	main.online = false   # проверка логики идёт офлайн и детерминированно
	add_child(main)

func _process(delta: float) -> void:
	_elapsed += delta
	# Профиль выживаемости: игрок стоит неподвижно, так что это худший случай.
	if _elapsed >= _next_sample and main.player != null:
		_timeline.append("%.2fs:%.0f/%.0f" % [
			_next_sample, main.player.health.health, main.player.health.armor])
		_next_sample += 0.25
	if _elapsed < RUN_SECONDS:
		return
	set_process(false)
	_report()
	get_tree().quit()

func _report() -> void:
	var map: CityMap = main.get_node("Map")
	var player: PlayerCharacter = main.player
	var bots: Array = []
	for node in main.get_node("Actors").get_children():
		if node is Bot:
			bots.append(node)

	print("--- SMOKE TEST ---")
	print("карта: объектов=%d, спавны игрока=%d, ботов=%d, оружия=%d, размер=%.0f м" % [
		map.get_node("Props").get_child_count(),
		map.player_spawns.size(), map.bot_spawns.size(), map.weapon_spawns.size(),
		map.size_meters()])

	print("игрок: hp=%.0f armor=%.0f pos=(%.1f, %.2f, %.1f) на земле=%s оружие=%s патроны=%s" % [
		player.health.health, player.health.armor,
		player.global_position.x, player.global_position.y, player.global_position.z,
		str(player.is_on_floor()),
		player.weapons.current_data().display_name,
		player.weapons.ammo_text()])

	var alive := 0
	var fighting := 0
	var moved := 0
	var grounded := 0
	for bot in bots:
		if bot.health.alive:
			alive += 1
		if bot.state == Bot.State.ATTACK or bot.state == Bot.State.CHASE:
			fighting += 1
		if bot.velocity.length() > 0.2:
			moved += 1
		if bot.is_on_floor():
			grounded += 1
	print("боты: всего=%d живых=%d в бою=%d движутся=%d на земле=%d" % [
		bots.size(), alive, fighting, moved, grounded])

	if not bots.is_empty():
		var sample: Bot = bots[0]
		var player_node: AnimationPlayer = null
		for node in sample.get_node("Mesh").get_children():
			player_node = node.get_node_or_null("AnimationPlayer")
			if player_node != null:
				break
		if player_node == null:
			print("модель бойца: анимаций нет (модель не собралась)")
		else:
			print("модель бойца: анимации=%s, играет=%s, дорожек в idle=%d" % [
				str(player_node.get_animation_list()), player_node.current_animation,
				player_node.get_animation("idle").get_track_count() if player_node.has_animation("idle") else -1])
			if player_node.has_animation("idle"):
				print("первая дорожка idle: %s" % str(player_node.get_animation("idle").track_get_path(0)))

	# Урон идёт через ту же точку входа, что и выстрелы.
	if not bots.is_empty():
		var victim: Bot = bots[0]
		var before: float = victim.health.health
		Damage.apply(victim, 40.0, player, false, 0.7)
		print("урон: бот %.0f -> %.0f (ожидалось -40)" % [before, victim.health.health])
		print("хедшот определяется: %s" % str(
			Damage.is_headshot(victim, victim.global_position + Vector3.UP * 1.6)))

	# Подбор оружия: выдаём снайперку и смотрим, встала ли она в слот.
	var gave: bool = player.weapons.give(&"awp", true)
	print("выдача AWP: %s, в руках=%s, патроны=%s" % [
		str(gave), player.weapons.current_data().display_name, player.weapons.ammo_text()])
	var pivot := player.weapon_pivot
	if pivot.get_child_count() > 0:
		var vm: Node3D = pivot.get_child(0)
		print("вьюмодель: видима=%s поз=%s масштаб=%s детей=%d" % [str(vm.visible), str(vm.position.snappedf(0.001)), str(vm.scale.snappedf(0.001)), vm.get_child_count()])
		if vm.get_child_count() > 0:
			var holder: Node3D = vm.get_child(0)
			print("  держатель: поз=%s масштаб=%s" % [str(holder.position.snappedf(0.001)), str(holder.scale.snappedf(0.001))])
			if holder.get_child_count() > 0:
				var m: Node3D = holder.get_child(0)
				print("  модель: локально=%s глобально=%s" % [str(m.position.snappedf(0.001)), str(m.global_position.snappedf(0.01))])
				print("  камера: %s" % str(player.camera.global_position.snappedf(0.01)))
	print("экономика: денег=%d, AK стоит %d, хватает=%s" % [
		player.economy.money, Weapons.get_weapon(&"ak47").price,
		str(player.economy.can_afford(Weapons.get_weapon(&"ak47").price))])
	print("звук выстрела AK: %s" % ("записанный wav" if ResourceLoader.exists("res://assets/sfx/weapons/ak47_1.wav") else "синтез"))
	print("выживаемость неподвижного игрока (hp/броня): %s" % ", ".join(_timeline))
	print("--- END ---")
