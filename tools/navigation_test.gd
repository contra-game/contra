extends Node3D

var failures: int = 0

class Target:
	extends CharacterBody3D
	var team: int = 0
	var local_control: bool = true

func _ready() -> void:
	var city := CityMap.new()
	add_child(city)
	city.build()
	for frame in 600:
		await get_tree().physics_frame
		if not city.navigation_baking:
			break
	for frame in 3: await get_tree().physics_frame
	_check(not city.navigation_baking, "city navigation bake completes")
	var mesh := city.navigation_region.navigation_mesh
	_check(mesh != null and mesh.get_polygon_count() > 10, "collision geometry produces a usable navigation mesh")
	if mesh == null:
		_finish()
		return
	var map_rid := get_world_3d().navigation_map
	var start := Vector3(-32.5, 0.25, -26.0)
	var finish := Vector3(-13.0, 0.25, -26.0)
	start = NavigationServer3D.map_get_closest_point(map_rid, start)
	finish = NavigationServer3D.map_get_closest_point(map_rid, finish)
	var route := NavigationServer3D.map_get_path(map_rid, start, finish, true)
	var length := 0.0
	var clear := true
	for step in range(1, route.size()):
		length += route[step - 1].distance_to(route[step])
		var query := PhysicsRayQueryParameters3D.create(route[step - 1] + Vector3.UP, route[step] + Vector3.UP, 1)
		clear = clear and get_world_3d().direct_space_state.intersect_ray(query).is_empty()
	_check(route.size() >= 3 and length > start.distance_to(finish) + 2.0, "route goes around the intervening building")
	_check(clear, "route segments clear real world collision")
	var bot := (load("res://scenes/bot.tscn") as PackedScene).instantiate() as Bot
	add_child(bot)
	bot.global_position = start + Vector3.UP * 0.2
	bot.set_physics_process(false)
	bot.state = Bot.State.CHASE
	for frame in 900:
		await get_tree().physics_frame
		bot._path_refresh = maxf(bot._path_refresh - 1.0 / 60.0, 0.0)
		bot._move_towards(finish, bot.move_speed, 1.0 / 60.0)
		bot.velocity.y = -1.0
		bot.move_and_slide()
		if bot.global_position.distance_to(finish) < 1.0:
			break
	_check(bot.global_position.distance_to(finish) < 1.0, "NavigationAgent drives a live capsule around the building")
	if bot.global_position.distance_to(finish) >= 1.0:
		print("Route: ", route, " stop=", bot.global_position, " next=", bot.navigation_agent.get_next_path_position(), " walls=", bot.get_slide_collision_count())

	# A hidden enemy cannot drag the last-seen pursuit point through walls.
	bot.global_position = Vector3(0.0, 0.15, -6.5)
	bot.rotation = Vector3.ZERO
	var enemy := Target.new()
	enemy.collision_layer = 2
	enemy.add_to_group("combatants")
	var shape := CollisionShape3D.new()
	var capsule := CapsuleShape3D.new()
	capsule.height = 1.8
	capsule.radius = 0.4
	shape.shape = capsule
	shape.position.y = 0.9
	enemy.add_child(shape)
	var health := Health.new()
	health.name = "Health"
	enemy.add_child(health)
	add_child(enemy)
	enemy.global_position = bot.global_position + Vector3(0, 0, -4)
	await get_tree().physics_frame
	bot._acquire_target(1.0 / 60.0)
	_check(bot.state == Bot.State.ATTACK and bot._reaction_left > 0.0, "visible target starts reaction delay before attack")
	var magazine_before := bot._mag
	bot._do_attack(1.0 / 60.0)
	_check(bot._mag == magazine_before, "reaction delay prevents an immediate shot")
	var remembered := bot._last_seen
	var wall := StaticBody3D.new()
	var block := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(3.0, 3.0, 0.5)
	block.shape = box
	wall.add_child(block)
	add_child(wall)
	wall.global_position = bot.global_position + Vector3(0, 1.5, -2)
	enemy.global_position += Vector3(0, 0, -3)
	await get_tree().physics_frame
	bot._acquire_target(0.1)
	_check(not bot._visible_target and bot.state == Bot.State.CHASE, "wall interrupts sight and starts pursuit")
	_check(bot._last_seen.is_equal_approx(remembered), "pursuit retains last observed position")
	var found_cover := bot._find_cover()
	_check(found_cover, "bot locates reachable cover around world geometry")
	if found_cover:
		var cover_ray := PhysicsRayQueryParameters3D.create(enemy.global_position + Vector3.UP * 1.3, bot._cover_point + Vector3.UP * 1.25, 1)
		_check(not get_world_3d().direct_space_state.intersect_ray(cover_ray).is_empty(), "chosen cover blocks the enemy chest-height line of fire")
	bot._memory_left = 0.05
	bot._acquire_target(0.1)
	_check(bot.target == null and bot.state == Bot.State.PATROL, "bot gives up an expired invisible target")
	_finish()

func _check(ok: bool, label: String) -> void:
	if not ok:
		failures += 1
	print("PASS" if ok else "FAIL", " ", label)

func _finish() -> void:
	print("NAVIGATION TEST: ", "PASS" if failures == 0 else "FAIL", " failures=", failures)
	get_tree().quit(0 if failures == 0 else 1)
