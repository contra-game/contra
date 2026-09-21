## Реальная симуляция рэгдолла, поверхности, физика гильз и бюджеты эффектов.
extends Node3D

const Ragdoll = preload("res://scripts/combat_ragdoll.gd")
var failures := 0

func _ready() -> void:
	var environment := WorldEnvironment.new()
	environment.environment = Environment.new()
	environment.environment.background_mode = Environment.BG_COLOR
	environment.environment.background_color = Color(0.11, 0.14, 0.19)
	environment.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.environment.ambient_light_color = Color.WHITE
	environment.environment.ambient_light_energy = 0.65
	add_child(environment)
	var light := DirectionalLight3D.new()
	add_child(light)
	light.rotation_degrees = Vector3(-50, -30, 0)
	light.shadow_enabled = true
	var camera := Camera3D.new()
	add_child(camera)
	camera.position = Vector3(3.5, 3.2, 5.2)
	camera.look_at(Vector3(0, 0.7, 0))
	camera.current = true
	_box(Vector3(0, -0.15, 0), Vector3(14, 0.3, 14), Color(0.26, 0.29, 0.32))
	var wall := _box(Vector3(0, 1.0, -2), Vector3(4, 2, 0.2), Color(0.48, 0.48, 0.44))
	var metal := _box(Vector3(2.3, 0.65, -1.2), Vector3(0.8, 1.3, 0.5), Color(0.2, 0.39, 0.48))
	metal.set_meta("surface", "metal")
	_check(Effects.surface(wall) == "concrete" and Effects.surface(metal) == "metal", "материал поверхности выбирается правильно")
	var mark := Effects.bullet_mark(self, Vector3(0, 1, -1.9), Vector3.BACK, wall)
	_check(mark.get_meta("effect_surface", 0) == wall.get_instance_id(), "след привязан к поверхности")
	_check(absf(mark.global_basis.z.normalized().dot(Vector3.BACK)) > 0.999, "след ориентирован по нормали")
	var previous := mark.global_position
	wall.position.x += 0.2
	Effects.prewarm(self)._process(0.0)
	_check(mark.global_position.distance_to(previous + Vector3.RIGHT * 0.2) < 0.001, "след перемещается вместе с объектом")
	wall.position.x -= 0.2
	for i in 7:
		Effects.impact(self, Vector3(-0.7 + i * 0.23, 1.1 + sin(i) * 0.15, -1.899), Vector3.BACK, false, wall)
	Effects.impact(self, Vector3(2.3, 0.8, -0.949), Vector3.BACK, false, metal)
	var before := get_tree().get_nodes_in_group("bullet_marks").size()
	Effects.impact(self, Vector3.ZERO, Vector3.UP, true)
	_check(before == get_tree().get_nodes_in_group("bullet_marks").size(), "попадание в бойца не оставляет висящий декаль")
	var actor := Node3D.new()
	add_child(actor)
	actor.position = Vector3(-0.6, 0.4, 0)
	var source := CharacterModel.build("criminalMaleA", 1.8)
	actor.add_child(source)
	source.rotation.y = PI
	var animation: AnimationPlayer = source.get_node("AnimationPlayer")
	animation.play("idle")
	var motion = CharacterModel.motion(source)
	motion.equip(actor, Weapons.get_weapon(&"ak47"))
	for i in 12:
		await get_tree().physics_frame
	var corpse = Ragdoll.spawn(source, self, Vector3(0.2, 0, 0), Vector3.BACK)
	source.visible = false
	_check(corpse.bodies.size() == 11, "рэгдолл содержит 11 физических частей")
	var joints := corpse.get_children().filter(func(node): return node is Joint3D)
	_check(joints.size() == 10, "части связаны десятью суставами")
	_check(corpse.get_node_or_null("DroppedWeapon") is RigidBody3D, "оружие выпадает отдельным физическим объектом")
	var chest: RigidBody3D = corpse.bodies.Spine
	var initial := chest.global_position
	# Респавн исходного бойца не тянет старое тело за ним.
	actor.position += Vector3(8, 0, 0)
	_check(chest.global_position.is_equal_approx(initial), "тело отделено от респавнившегося бойца")
	var casing := Effects.casing(self, Transform3D(Basis.IDENTITY, Vector3(0, 1.3, 0)))
	_check(casing.collision_layer == 0 and casing.collision_mask == 1, "гильза сталкивается с картой и не блокирует игрока")
	for i in 18:
		await get_tree().physics_frame
	_check(chest.global_position.distance_to(initial) > 0.2, "тело падает и получает импульс")
	if "--capture" in OS.get_cmdline_user_args():
		await _capture("physics-fall")
	for i in 150:
		await get_tree().physics_frame
	var stable := true
	for body: RigidBody3D in corpse.bodies.values():
		stable = stable and body.global_position.is_finite() and body.global_position.y > -0.2 and body.global_position.y < 1.0
	_check(stable, "части тела лежат на полу без проваливания и разлёта")
	_check(casing.global_position.y > -0.03 and casing.global_position.y < 0.12, "гильза упала на пол")
	var query := PhysicsRayQueryParameters3D.create(chest.global_position - Vector3.RIGHT, chest.global_position + Vector3.RIGHT, Ragdoll.LAYER)
	_check(not get_world_3d().direct_space_state.intersect_ray(query).is_empty(), "косметический луч находит физическое тело")
	query.collision_mask = 1 | 2 | 4
	_check(get_world_3d().direct_space_state.intersect_ray(query).is_empty(), "косметическое тело не поглощает боевой hitscan")
	var pushed := Effects.physical_hit(self, chest.global_position - Vector3.RIGHT, chest.global_position + Vector3.RIGHT, 8.0)
	_check(pushed != null, "выстрел передаёт импульс физическому телу")
	# Изолированный объект проверяет силу импульса независимо от случайной
	# позы трупа, трения пола и выпавшего оружия перед лучом.
	var probe := RigidBody3D.new()
	probe.collision_layer = Ragdoll.LAYER
	probe.collision_mask = 1
	probe.gravity_scale = 0.0
	var probe_shape := CollisionShape3D.new()
	probe_shape.shape = SphereShape3D.new()
	probe.add_child(probe_shape)
	add_child(probe)
	probe.position = Vector3(0, 3, 3)
	for i in 2:
		await get_tree().physics_frame
	Effects.physical_hit(self, probe.position - Vector3.RIGHT, probe.position + Vector3.RIGHT, 4.0)
	for i in 3:
		await get_tree().physics_frame
	_check(probe.linear_velocity.x > 3.5, "пуля изменяет скорость физического объекта")
	probe.queue_free()
	if "--capture" in OS.get_cmdline_user_args():
		await _capture("physics-settled")
	# Нагрузка не увеличивает число объектов без ограничения.
	for i in Effects.MARK_LIMIT + 4:
		Effects.bullet_mark(self, Vector3(0, -5, 0), Vector3.UP)
	_check(get_tree().get_nodes_in_group("bullet_marks").size() == Effects.MARK_LIMIT, "бюджет следов пуль соблюдается")
	for i in Effects.CASING_LIMIT + 2:
		Effects.casing(self, Transform3D(Basis.IDENTITY, Vector3(0, 1, 0)))
	_check(get_tree().get_nodes_in_group("spent_casings").size() == Effects.CASING_LIMIT, "бюджет гильз соблюдается")
	for i in 20:
		Effects.impact(self, Vector3(0, 1, -1.9), Vector3.BACK, false, wall)
	_check(get_tree().get_nodes_in_group("impact_bursts").size() <= Effects.BURST_LIMIT, "бюджет частиц соблюдается")
	for i in Ragdoll.LIMIT + 1:
		Ragdoll.spawn(source, self, Vector3.ZERO, Vector3.BACK)
	_check(get_tree().get_nodes_in_group(Ragdoll.GROUP).size() == Ragdoll.LIMIT, "бюджет рэгдоллов соблюдается")
	var latest: Node = get_tree().get_nodes_in_group(Ragdoll.GROUP).back()
	latest.age = Ragdoll.LIFETIME
	await get_tree().physics_frame
	await get_tree().process_frame
	_check(not is_instance_valid(latest) or latest.is_queued_for_deletion(), "старое тело автоматически удаляется")
	print("PHYSICS EFFECTS TEST: ", "PASS" if failures == 0 else "FAIL", " failures=", failures)
	get_tree().quit(0 if failures == 0 else 1)

func _box(point: Vector3, size: Vector3, color: Color) -> StaticBody3D:
	var body := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	shape.shape = box
	body.add_child(shape)
	var visual := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = size
	visual.mesh = mesh
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	visual.material_override = material
	body.add_child(visual)
	add_child(body)
	body.position = point
	return body

func _capture(label: String) -> void:
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png("res://build/%s.png" % label)

func _check(ok: bool, label: String) -> void:
	if not ok:
		failures += 1
	print("PASS" if ok else "FAIL", " ", label)
