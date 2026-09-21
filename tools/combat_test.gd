## Поведенческие проверки боя. -- --capture дополнительно сохраняет кадры HUD.
extends Node3D

const STILL := {"speed": 0.0, "on_floor": true, "crouching": false, "sprinting": false}
var failures: int = 0
var main: Node
var player: PlayerCharacter
var weapons: WeaponManager

func _ready() -> void:
	main = load("res://scenes/main.tscn").instantiate()
	main.online = false
	main.match_flow_enabled = false
	add_child(main)
	player = main.player
	weapons = player.weapons
	player.set_physics_process(false)
	for actor in main.get_node("Actors").get_children():
		if actor is Bot:
			actor.set_physics_process(false)
	# Изолируем стрельбу от случайных ботов и зданий.
	player.global_position = Vector3(0, 100, 0)
	player.look_yaw = 0.0
	player.rotation = Vector3.ZERO
	player.head.rotation = Vector3.ZERO
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	await get_tree().physics_frame
	_test_spread_and_fire_rate()
	_test_reload()
	_test_camera()
	_test_feedback()
	await _test_interaction()
	await _test_animations()
	await _test_viewmodel()
	await _test_ads_input()
	await _test_hybrid_shot()
	if "--capture" in OS.get_cmdline_user_args():
		await _capture()
	print("COMBAT TEST: ", "PASS" if failures == 0 else "FAIL", " failures=", failures)
	get_tree().quit(0 if failures == 0 else 1)

func _equip(id: StringName) -> void:
	var data := Weapons.get_weapon(id)
	var slot_index := 0 if data.slot == WeaponData.Slot.PRIMARY else 1
	var existing = weapons.slots[slot_index]
	if existing == null or existing.data.id != id:
		weapons.give(id, true)
	weapons._equip(slot_index, true)
	weapons._equip_left = 0.0
	weapons._cooldown = 0.0
	weapons._cancel_reload()

func _test_spread_and_fire_rate() -> void:
	_equip(&"ak47")
	weapons._spread = 0.0
	weapons._try_fire(STILL)
	var first := weapons._spread
	weapons._tick_spread(0.1, STILL)
	weapons._cooldown = 0.0
	weapons._try_fire(STILL)
	_check(weapons._spread > first * 1.9, "очередь накапливает разброс")
	weapons._tick_spread(2.0, STILL)
	_check(is_zero_approx(weapons._spread), "разброс восстанавливается после паузы")
	var data := weapons.current_data()
	var base := weapons._current_spread(data, STILL)
	_check(weapons._current_spread(data, {"speed": 6.0, "on_floor": false}) > base, "бег и прыжок ухудшают точность")
	weapons.aiming = true
	weapons._update_view_model(1.0, STILL)
	_check(weapons._current_spread(data, STILL) < base, "прицеливание повышает точность")
	weapons.aiming = false
	for hz in [30, 60, 144]:
		_equip(&"m4")
		weapons.current().mag = 30
		for frame in hz:
			weapons.player_tick(1.0 / hz, STILL)
			weapons._try_fire(STILL)
		var fired: int = 30 - weapons.current().mag
		_check(fired == 12 or fired == 13, "M4: 720 RPM при %d Гц (%d выстрелов/с)" % [hz, fired])

func _test_reload() -> void:
	_equip(&"spas")
	var slot := weapons.current()
	slot.mag = 0
	slot.reserve = 3
	weapons.start_reload()
	weapons._try_fire(STILL)
	_check(weapons.reloading and slot.mag == 0, "пустой дробовик не прерывает зарядку")
	weapons._tick_reload(0.56)
	_check(slot.mag == 1 and slot.reserve == 2 and weapons.reloading, "дробовик вставляет один патрон")
	weapons._cooldown = 0.0
	weapons._try_fire(STILL)
	_check(slot.mag == 0 and slot.reserve == 2 and not weapons.reloading, "выстрел прерывает зарядку без потери резерва")
	weapons.start_reload()
	weapons._tick_reload(2.0)
	_check(slot.mag == 2 and slot.reserve == 0 and not weapons.reloading, "зарядка останавливается при пустом резерве")
	slot.mag = 7
	slot.reserve = 5
	weapons.start_reload()
	weapons._tick_reload(2.0)
	_check(slot.mag == 8 and slot.reserve == 4 and not weapons.reloading, "дробовик не переполняется")
	_equip(&"ak47")
	slot = weapons.current()
	slot.mag = 10
	slot.reserve = 25
	weapons.start_reload()
	weapons._try_fire(STILL)
	_check(weapons.reloading and slot.mag == 10, "автомат не стреляет во время смены магазина")
	weapons._equip(1, false)
	weapons._tick_reload(5.0)
	_check(not weapons.reloading and slot.mag == 10 and slot.reserve == 25, "смена оружия отменяет перезарядку без выдачи патронов")
	_equip(&"ak47")
	weapons.start_reload()
	weapons._tick_reload(3.0)
	_check(slot.mag == 30 and slot.reserve == 5, "магазин пополняется с сохранением общего числа патронов")
	_equip(&"awp")
	weapons.current().mag = 3
	weapons.aiming = true
	weapons._update_scope()
	weapons.start_reload()
	_check(not weapons._scoped and not weapons.aiming, "перезарядка сразу убирает оптику")
	weapons.holster()
	var before: int = weapons.current().mag
	weapons._try_fire(STILL)
	_check(not weapons.reloading and weapons.current().mag == before, "убранное после смерти оружие не стреляет")
	weapons.reset_loadout()
	_check(not weapons._holstered and weapons.current().mag == 30, "респавн возвращает исправное оружие")

func _test_camera() -> void:
	player._on_recoil_kick(2.0, 1.0)
	player._update_view(1.0 / 60.0)
	_check(player.head.rotation.x > 0.0 and player.head.rotation.y > 0.0, "отдача отклоняет прицел вверх и вбок")
	player._recoil = Vector2.ZERO
	player._recoil_target = Vector2.ZERO
	player.velocity = Vector3.ZERO
	player._bob_weight = 0.0
	player._update_view(1.0)
	_check(player.camera.position.length() < 0.001, "неподвижная камера не остаётся смещённой покачиванием")
	_check(player.camera.fov >= 18.0 and player.camera.fov <= player.base_fov, "FOV не перелетает цель на длинном кадре")
	# Удар в плечо: камера уходит назад по +z, покачивание занимает x и y.
	player._camera_recoil_spring.reset()
	player.camera.position = Vector3.ZERO
	player._on_recoil_kick(2.0, 1.0)
	player._update_view(1.0 / 60.0)
	_check(player.camera.position.z > 0.0005, "отдача толкает камеру назад")
	player._camera_recoil_spring.reset()
	player._recoil = Vector2.ZERO
	player._recoil_target = Vector2.ZERO
	player._update_view(1.0)
	_check(absf(player.camera.position.z) < 0.001, "продольный откат возвращается в ноль")

func _test_feedback() -> void:
	var crosshair: Crosshair = main.hud._crosshair
	crosshair.set_spread(1.0)
	crosshair._drawn_spread = 1.0
	crosshair.set_spread(6.0)
	_check(is_equal_approx(crosshair._drawn_spread, 6.0), "прицел расширяется без задержки")
	crosshair.set_spread(1.0)
	crosshair._process(1.0 / 60.0)
	_check(crosshair._drawn_spread > 1.0 and crosshair._drawn_spread < 6.0, "прицел схлопывается постепенно")

	crosshair.show_hitmarker(false, false)
	var early := crosshair.hit_growth()
	crosshair._process(Crosshair.HIT_GROWTH)
	_check(crosshair.hit_growth() > early, "хитмаркер вырастает из центра")

	# Под перекрёстным огнём индикатор обязан показать обоих стрелков.
	var indicator: Control = main.hud._damage_indicator
	indicator.time_left = 0.0
	indicator.show_damage(Vector3(10, 0, 0))
	indicator.show_damage(Vector3(-10, 0, 0))
	_check(indicator.sources.size() == 2, "индикатор урона держит оба источника")
	for i in 8:
		indicator.show_damage(Vector3(0, 0, float(i)))
	_check(indicator.sources.size() == 4, "источников урона не больше лимита")
	indicator.time_left = 0.0

	var restore := Session.mouse_sensitivity
	Session.set_mouse_sensitivity(999.0)
	_check(is_equal_approx(Session.mouse_sensitivity, Session.SENSITIVITY_MAX), "чувствительность зажата сверху")
	Session.set_mouse_sensitivity(0.0)
	_check(is_equal_approx(Session.mouse_sensitivity, Session.SENSITIVITY_MIN), "нулевая чувствительность не оставляет мышь мёртвой")
	Session.set_mouse_sensitivity(NAN)
	_check(is_equal_approx(Session.mouse_sensitivity, 1.0), "мусор в файле настроек не ломает поворот")
	Session.set_mouse_sensitivity(restore)

func _test_interaction() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	var pickup := WeaponPickup.new()
	pickup.weapon_id = &"deagle"
	add_child(pickup)
	pickup.global_position = player.camera.global_position + Vector3(0, 0, -2.0)
	await get_tree().physics_frame
	await get_tree().physics_frame
	player._update_interaction()
	_check(player.interaction_target == pickup and "Deagle" in player.interaction_hint, "подсказка называет оружие под прицелом")
	var wall := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(2, 2, 0.15)
	shape.shape = box
	wall.add_child(shape)
	add_child(wall)
	wall.global_position = player.camera.global_position + Vector3(0, 0, -0.8)
	await get_tree().physics_frame
	await get_tree().physics_frame
	player._try_interact()
	_check(player.interaction_target == null and pickup._available, "стена блокирует подсказку и подбор")
	wall.queue_free()
	await get_tree().physics_frame
	await get_tree().physics_frame
	player.shop_open = true
	player._try_interact()
	_check(pickup._available and player.interaction_hint.is_empty(), "магазин блокирует взаимодействие")
	player.shop_open = false
	player._try_interact()
	_check(not pickup._available and weapons.current_data().id == &"deagle", "E выдаёт оружие и скрывает точку")
	_check(player.interaction_hint.is_empty(), "подсказка исчезает после подбора")
	pickup.queue_free()

func _test_animations() -> void:
	var model := CharacterModel.build("criminalMaleA", 1.8)
	_check(model != null, "модель персонажа загружается")
	if model == null:
		return
	add_child(model)
	var anim: AnimationPlayer = model.get_node("AnimationPlayer")
	for key in ["idle", "run", "jump"]:
		_check(anim.has_animation(key), "доступна анимация %s" % key)
	CharacterModel.animate(anim, Vector3(4.2, 0, 0), false, true)
	var tree := model.get_node("AnimationTree") as AnimationTree
	for i in 20: await get_tree().physics_frame
	_check(float(tree.get("parameters/Ground/blend_amount")) > 0.9, "движение плавно смешивает стойку и бег")
	var before := float(tree.get("parameters/run/current_position"))
	CharacterModel.animate(anim, Vector3(4.2, 0, 0), false, true)
	await get_tree().physics_frame
	_check(float(tree.get("parameters/run/current_position")) > before, "бег не перезапускается каждый кадр")
	CharacterModel.animate(anim, Vector3(0, 3, 0), true, true)
	for i in 20: await get_tree().physics_frame
	_check(float(tree.get("parameters/Air/blend_amount")) > 0.9, "в воздухе смешивается прыжок")
	CharacterModel.animate(anim, Vector3.ZERO, false, false)
	_check(not tree.active, "смерть останавливает дерево анимаций")
	CharacterModel.animate(anim, Vector3.ZERO, false, true)
	for i in 30: await get_tree().physics_frame
	_check(tree.active and float(tree.get("parameters/Ground/blend_amount")) < 0.01, "респавн возобновляет стойку")
	model.queue_free()
	# Проверяем быстрый респавн: твин смерти больше не опрокидывает живого бота.
	for actor in main.get_node("Actors").get_children():
		if actor is Bot:
			actor.health.take_damage(1000, player)
			actor.respawn(actor.global_transform)
			await get_tree().create_timer(0.4).timeout
			_check(actor.mesh_root.rotation.is_zero_approx(), "респавн отменяет падение трупа")
			break

func _capture() -> void:
	player.respawn(main.get_node("Map").player_spawns[0])
	player.look_yaw -= PI * 0.5
	player._update_view(1.0 / 60.0)
	_equip(&"ak47")
	for i in 30:
		weapons._update_view_model(1.0 / 60.0, STILL)
	await _shot("combat-idle")
	var pickup := WeaponPickup.new()
	pickup.weapon_id = &"deagle"
	add_child(pickup)
	pickup.global_position = player.camera.global_position - player.camera.global_basis.z * 2.0
	await get_tree().physics_frame
	await get_tree().physics_frame
	player._update_interaction()
	weapons.current().mag = 10
	weapons.ammo_changed.emit(10, weapons.current().reserve)
	weapons.start_reload()
	weapons._tick_reload(1.2)
	for i in 12:
		weapons._update_view_model(1.0 / 60.0, STILL)
	main.hud._on_damaged(10, pickup, false)
	await _shot("combat-reload")
	pickup.queue_free()
	player.interaction_hint = ""
	main.hud._damage_flash.modulate.a = 0.0
	main.hud._damage_indicator.time_left = 0.0
	main.hud._damage_indicator.queue_redraw()
	for id in Weapons.ids():
		_equip(id)
		for i in 30:
			weapons._update_view_model(1.0 / 60.0, STILL)
		weapons._play_anim(weapons._fire_anim, 0.0)
		if weapons._anim != null:
			weapons._anim.advance(0.0)
			weapons._anim.pause()
		await _shot("combat-%s" % id)
		weapons.aiming = true
		for i in 120:
			weapons._update_view_model(1.0 / 60.0, STILL)
			player._update_view(1.0 / 60.0)
		await _shot("ads-%s" % id)
		weapons.aiming = false
		weapons._update_scope()
		player.camera.fov = player.base_fov
	# На последнем кадре стена ближе дула, но оружие должно остаться целым.
	_equip(&"ak47")
	for i in 120:
		weapons._update_view_model(1.0 / 60.0, STILL)
	var wall := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(4, 4, 0.1)
	wall.mesh = box
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.2, 0.45, 0.5)
	wall.material_override = mat
	add_child(wall)
	wall.global_transform = player.camera.global_transform * Transform3D(Basis.IDENTITY, Vector3(0, 0, -0.2))
	await _shot("ads-wall")
	wall.queue_free()

func _test_viewmodel() -> void:
	var observed: Array = []
	weapons.shot_fired.connect(func(_id, origin, end): observed.append([origin, end]))
	for id in Weapons.ids():
		_equip(id)
		await get_tree().process_frame
		var data := weapons.current_data()
		_check(weapons.muzzle_marker != null and weapons.sight_node != null, "%s: маркеры дула и прицела созданы" % id)
		weapons.aiming = true
		for frame in 150:
			weapons._update_view_model(1.0 / 60.0, STILL)
		var sight := player.camera.to_local(weapons.sight_node.global_position)
		var forward := -weapons.sight_node.global_basis.orthonormalized().z
		_check(Vector2(sight.x, sight.y).length() < 0.0001 and absf(sight.z + data.ads_eye_distance) < 0.0001,
			"%s: ADS совмещает SightNode с оптической осью камеры" % id)
		_check(forward.dot(-player.camera.global_basis.z) > 0.9999, "%s: мушка направлена вдоль луча камеры" % id)
		var muzzle_before := weapons._view_model.to_local(weapons.muzzle_marker.global_position)
		weapons.current().mag -= 1
		weapons.start_reload()
		if weapons._anim != null and not weapons._reload_anim.is_empty():
			weapons._anim.advance(0.3)
		weapons._cancel_reload()
		var muzzle_after := weapons._view_model.to_local(weapons.muzzle_marker.global_position)
		_check(muzzle_before.distance_to(muzzle_after) < 0.001, "%s: после отмены перезарядки дуло возвращается на место" % id)
		# Убираем разброс только в тестовой копии; рабочий каталог не меняется.
		var probe: WeaponData = data.duplicate()
		probe.spread_base = 0.0
		weapons._spread = 0.0
		observed.clear()
		weapons._fire_rays(probe, STILL)
		_check(observed.size() == 1 and observed[0][0].distance_to(weapons.muzzle_marker.global_position) < 0.0001,
			"%s: трассер начинается в MuzzleMarker" % id)
	# Импульс и возврат одинаковы при разных частотах рендера.
	var results: Array[Vector3] = []
	for hz in [30, 60, 144]:
		var spring = preload("res://scripts/viewmodel_spring.gd").new()
		spring.impulse(Vector3(0.0, 0.12, 1.8))
		for frame in hz / 6:
			spring.step(1.0 / hz)
		results.append(spring.value)
		spring.step(3.0)
		_check(spring.value.length() < 0.00001 and spring.velocity.length() < 0.00001, "пружина затухает при %d FPS" % hz)
	_check(results[0].distance_to(results[1]) < 0.00001 and results[1].distance_to(results[2]) < 0.00001, "отдача независима от FPS")
	var layer = weapons._weapon_layer
	player.camera.fov = 55.0
	layer.sync(true)
	_check(is_equal_approx(layer.camera.fov, player.camera.fov) and layer.camera.global_transform.is_equal_approx(player.camera.global_transform), "проекции оружия и мирового трассера совпадают")
	_check(player.camera.cull_mask & layer.MASK == 0 and layer.camera.cull_mask == layer.MASK, "оружие и мир используют разные depth buffer и слои")
	_check(layer.viewport.transparent_bg and layer.image.mouse_filter == Control.MOUSE_FILTER_IGNORE, "оверлей прозрачен и не перехватывает управление")
	weapons.holster()
	weapons._process(0.016)
	_check(not layer.overlay.visible, "смерть убирает слой оружия")
	weapons.reset_loadout()
	player.camera.fov = player.base_fov

func _test_ads_input() -> void:
	# Dummy display не поддерживает захват мыши; player_tick намеренно блокирует
	# игровой ввод без него. Реальный путь ПКМ проверяется графическим прогоном.
	if DisplayServer.get_name() == "headless":
		print("SKIP ADS input: headless display has no captured mouse")
		return
	for id in Weapons.ids():
		_equip(id)
		Input.action_press("aim")
		for frame in 60:
			weapons.player_tick(1.0 / 60.0, STILL)
			weapons._update_view_model(1.0 / 60.0, STILL)
			player._update_view(1.0 / 60.0)
		var data := weapons.current_data()
		_check(weapons.aiming and weapons.ads_blend > 0.99, "%s: ПКМ включает ADS" % id)
		_check(absf(player.camera.fov - data.aim_fov) < 0.1, "%s: индивидуальный зум достигается" % id)
		if data.has_scope:
			_check(main.hud._scope.visible and main.hud._scope.size == get_viewport().get_visible_rect().size,
				"AWP: окуляр виден и занимает весь экран")
		else:
			_check(not main.hud._scope.visible and weapons.sight_node.get_child_count() >= 5,
				"%s: открытые прицельные приспособления вместо оптики" % id)
		Input.action_release("aim")
		for frame in 90:
			weapons.player_tick(1.0 / 60.0, STILL)
			weapons._update_view_model(1.0 / 60.0, STILL)
			player._update_view(1.0 / 60.0)
		_check(not weapons.aiming and not weapons._scoped and weapons._view_model.visible and weapons.ads_blend < 0.001,
			"%s: отпускание ПКМ возвращает вид от бедра" % id)

func _test_hybrid_shot() -> void:
	_equip(&"ak47")
	weapons._view_model.transform = Transform3D(Basis.IDENTITY, Vector3(1.0, -0.25, -0.2))
	var origin := player.camera.global_position
	var forward := -player.camera.global_basis.z
	var target := _block(origin + forward * 8.0, Vector3(0.6, 0.6, 0.1))
	var shield := _block(weapons._muzzle_position() + forward * 0.3, Vector3(0.3, 0.3, 0.1))
	await get_tree().physics_frame
	await get_tree().physics_frame
	_check(weapons._cast(weapons._muzzle_position(), forward, 2.0).get("collider") == shield, "контроль: укрытие перекрывает луч из дула")
	var observed: Array = []
	var record := func(_id, start, end): observed.append([start, end])
	weapons.shot_fired.connect(record)
	var data: WeaponData = weapons.current_data().duplicate()
	data.spread_base = 0.0
	data.max_range = 12.0
	weapons._spread = 0.0
	weapons._fire_rays(data, STILL)
	_check(observed.size() == 1 and observed[0][1].distance_to(origin + forward * 7.95) < 0.001, "попадание идёт из камеры, даже если дуло закрыто укрытием")
	_check(observed[0][0].distance_to(weapons.muzzle_marker.global_position) < 0.0001, "при этом визуальный трассер выходит из дула")
	weapons.shot_fired.disconnect(record)
	target.queue_free()
	shield.queue_free()

func _block(point: Vector3, size: Vector3) -> StaticBody3D:
	var body := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	shape.shape = box
	body.add_child(shape)
	add_child(body)
	body.global_position = point
	return body

func _shot(label: String) -> void:
	await get_tree().process_frame
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png("res://build/%s.png" % label)

func _check(ok: bool, label: String) -> void:
	if not ok:
		failures += 1
	print("PASS" if ok else "FAIL", " ", label)
