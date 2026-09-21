## Real physics occlusion plus fixed node identities across repeated reuse.
extends Node3D

var failures := 0
var checks := 0

func _ready() -> void:
	var camera := Camera3D.new()
	add_child(camera)
	camera.position = Vector3(0, 1, 4)
	camera.current = true
	var wall := _box(Vector3(0, 1, 0), Vector3(2, 2, 0.4), "concrete")
	_box(Vector3(4, -0.1, 0), Vector3(2, 0.2, 2), "metal")
	_box(Vector3(7, -0.1, 0), Vector3(2, 0.2, 2), "earth")
	var actor := Node3D.new()
	add_child(actor)
	var pool = Effects.prewarm(self)
	_check(pool == Effects.prewarm(self), "prewarming is idempotent")
	var allocated: int = pool.created_count
	var node_ids: Array = pool.get_children().map(func(node): return node.get_instance_id())
	# След пули летит сегментом, а не висит полосой во всю дистанцию выстрела.
	var shot: MeshInstance3D = Effects.tracer(self, Vector3(0, 1, 30), Vector3(0, 1, 0))
	var span: float = shot.global_transform.basis.get_scale().z
	_check(span <= Effects.Tracer.MAX_LENGTH + 0.01, "tracer draws a short segment, not the whole flight path")
	var launched := shot.global_position
	shot._process(0.05)
	_check(shot.global_position.z < launched.z - 0.5, "tracer travels toward the impact point")
	for i in 400:
		Effects.bullet_mark(self, Vector3(0, 1, 0.201), Vector3.BACK, wall)
		Effects.tracer(self, Vector3(0, 1, 4), Vector3(0, 1, 0.201))
		Effects.casing(self, Transform3D(Basis.IDENTITY, Vector3(4, 1, 0)), i % 2 == 0)
		Effects.impact(self, Vector3(0, 1, 0.201), Vector3.BACK, false, wall)
		Effects.muzzle_flash(actor, Vector3.ZERO, 1 << 19 if i % 2 == 0 else 1)
	_check(pool.created_count == allocated and pool.get_child_count() == allocated, "400 volleys allocate no additional effect nodes")
	_check(node_ids == pool.get_children().map(func(node): return node.get_instance_id()), "marks, bursts, casings, tracers and flashes reuse original nodes")
	_check(pool.reused_count > 1000, "saturated pools recycle active slots")
	_check(pool.active_count(&"mark") == Effects.MARK_LIMIT, "mark count is capped")
	_check(pool.active_count(&"burst") == Effects.BURST_LIMIT, "dust and sparks share one particle cap")
	_check(pool.active_count(&"casing") == Effects.CASING_LIMIT, "casing count is capped")
	_check(pool.active_count(&"tracer") == Effects.TRACER_LIMIT, "tracer count is capped")
	_check(pool.active_count(&"flash") == Effects.FLASH_LIMIT, "flash count is capped")
	# Пламя живёт на слое ствола, но свет обязан доставать и до мировых стен:
	# иначе вспышка озаряет только руки, а тёмный угол остаётся тёмным.
	for flash: Node3D in get_tree().get_nodes_in_group("muzzle_flashes"):
		var mask: int = flash.get_node("Light").light_cull_mask
		var drawn: int = flash.get_node("Mesh").layers
		_check(mask & drawn == drawn, "muzzle light covers the layer its flame is drawn on")
		_check(mask & Effects.WORLD_LAYER != 0, "muzzle light always reaches world geometry")
	var marks_before: int = pool.active_count(&"mark")
	Effects.explosion(self, Vector3(0, 4, 0))
	_check(pool.active_count(&"mark") == marks_before, "free-space blast creates no floating bullet marks")
	_check(pool.created_count == allocated, "explosions reuse prewarmed particles and flash nodes")
	for i in Effects.FLASH_LIMIT:
		Effects.muzzle_flash(actor, Vector3.ZERO, 1 << 19)
	var reset_flash := true
	for entry: Dictionary in pool.slots[&"flash"]:
		reset_flash = reset_flash and entry.node.get_node("Mesh").mesh is CylinderMesh and is_equal_approx(entry.node.get_node("Light").light_energy, 3.5)
	_check(reset_flash, "muzzle flash resets mesh and intensity after explosion reuse")
	var mark := Effects.bullet_mark(self, Vector3(0, 1, 0.201), Vector3.BACK, wall)
	var previous := mark.global_position
	wall.position += Vector3.RIGHT
	pool._process(0)
	_check(mark.global_position.is_equal_approx(previous + Vector3.RIGHT), "pooled mark follows moving surface")
	wall.position -= Vector3.RIGHT
	pool._process(0)
	pool._physics_process(6.1)
	_check(pool.active_count(&"casing") == 0 and pool.active_count(&"flash") == 0 and pool.active_count(&"tracer") == 0, "expired transient slots deactivate")
	var inert := true
	for entry: Dictionary in pool.slots[&"casing"]:
		inert = inert and entry.node.freeze and entry.node.collision_mask == 0 and not entry.node.visible
	_check(inert, "inactive casings have no visible or physical activity")
	var reused := Effects.casing(self, Transform3D(Basis.IDENTITY, Vector3(4, 1, 0)), true)
	_check(reused.visible and not reused.freeze and reused.collision_mask == 1 and reused.age == 0.0, "expired casing resets and reactivates")
	for i in 3:
		await get_tree().physics_frame
	_check(Sfx.is_occluded(self, camera.global_position, Vector3(0, 1, -4)), "world wall occludes source")
	_check(not Sfx.is_occluded(self, camera.global_position, Vector3(3, 1, 3)), "clear source is not occluded")
	actor.position = Vector3(4, 0.02, 0)
	_check(Sfx.footstep_surface(actor) == &"metal", "metal floor selects metal footsteps")
	actor.position = Vector3(7, 0.02, 0)
	_check(Sfx.footstep_surface(actor) == &"earth", "earth floor selects earth footsteps")
	actor.position = Vector3(10, 0.02, 0)
	_check(Sfx.footstep_surface(actor) == &"concrete", "missing metadata uses concrete fallback")
	Sfx.play_3d(&"explosion", Vector3(0, 1, -4))
	var occluded_voice: AudioStreamPlayer3D = Sfx._pool_3d[(Sfx._next_3d + Sfx.POOL_3D - 1) % Sfx.POOL_3D]
	_check(occluded_voice.bus == Sfx.OCCLUDED_BUS and occluded_voice.volume_db < Sfx.VOLUME_DB - 10.0, "occluded sound is filtered and quieter")
	Sfx.play_3d(&"explosion", Vector3(3, 1, 3))
	var clear_voice: AudioStreamPlayer3D = Sfx._pool_3d[(Sfx._next_3d + Sfx.POOL_3D - 1) % Sfx.POOL_3D]
	_check(clear_voice.bus == &"Master" and is_equal_approx(clear_voice.volume_db, Sfx.VOLUME_DB), "open sound restores unfiltered voice settings")
	var filter_bus := AudioServer.get_bus_index(Sfx.OCCLUDED_BUS)
	_check(AudioServer.get_bus_effect(filter_bus, 0) is AudioEffectLowPassFilter, "occlusion uses an actual low-pass filter")
	_check(Sfx._bank["step_metal"] != Sfx._bank["step_earth"] and Sfx._bank["step_earth"] != Sfx._bank["step_concrete"], "floor materials have distinct audio samples")
	var detached := Node3D.new()
	add_child(detached)
	var detached_mark := Effects.bullet_mark(self, Vector3.UP, Vector3.UP, detached)
	remove_child(detached)
	pool._process(0)
	_check(not detached_mark.visible, "detaching live surface safely releases its mark")
	detached.free()
	wall.queue_free()
	await get_tree().process_frame
	pool._process(0)
	_check(is_instance_valid(mark) and not mark.visible, "deleted surfaces release marks without destroying pooled nodes")
	pool._physics_process(31.0)
	_check(pool.active_count(&"mark") == 0 and get_tree().get_nodes_in_group("bullet_marks").is_empty(), "expired decals leave no active group entries")
	var scene := Node3D.new()
	add_child(scene)
	var scene_pool = Effects.prewarm(scene)
	var scene_pool_ref: WeakRef = weakref(scene_pool)
	var child_ref: WeakRef = weakref(scene_pool.get_child(0))
	scene.queue_free()
	await get_tree().process_frame
	await get_tree().process_frame
	_check(scene_pool_ref.get_ref() == null and child_ref.get_ref() == null, "scene teardown frees pool and all retained slots")
	print("EFFECTS AUDIO TEST: ", "PASS" if failures == 0 else "FAIL", " checks=", checks, " failures=", failures)
	get_tree().quit(0 if failures == 0 else 1)

func _box(point: Vector3, size: Vector3, surface: String) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.set_meta("surface", surface)
	var collision := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	collision.shape = box
	body.add_child(collision)
	add_child(body)
	body.position = point
	return body

func _check(ok: bool, label: String) -> void:
	checks += 1
	if not ok:
		failures += 1
	print("PASS" if ok else "FAIL", " ", label)
