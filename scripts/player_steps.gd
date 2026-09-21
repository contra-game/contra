## Sweep капсулы для ступеней. Не изменяет горизонтальную скорость игрока.
extends RefCounted

static func step_up(body: CharacterBody3D, delta: float, height: float) -> float:
	if height <= 0.0 or not body.is_on_floor() or body.velocity.y > 0.0:
		return 0.0
	var forward := Vector3(body.velocity.x, 0.0, body.velocity.z) * delta
	if forward.length_squared() < 0.000001:
		return 0.0
	var obstacle := KinematicCollision3D.new()
	if not body.test_move(body.global_transform, forward, obstacle, body.safe_margin):
		return 0.0
	if walkable(body, obstacle.get_normal()):
		return 0.0
	var lift := Vector3.UP * height
	if body.test_move(body.global_transform, lift, null, body.safe_margin):
		return 0.0
	var raised := body.global_transform
	raised.origin += lift
	if body.test_move(raised, forward, null, body.safe_margin):
		return 0.0
	raised.origin += forward
	var floor_hit := KinematicCollision3D.new()
	if not body.test_move(raised, Vector3.DOWN * (height + 0.04), floor_hit, body.safe_margin):
		return 0.0
	# Круглый низ капсулы находит ребро раньше площадки и даёт наклонную
	# нормаль. Берём высоту самой площадки, чтобы не застрять на ребре.
	var edge := floor_hit.get_position() + forward.normalized() * 0.025
	var query := PhysicsRayQueryParameters3D.create(Vector3(edge.x, body.global_position.y + height + 0.01, edge.z), Vector3(edge.x, body.global_position.y + 0.015, edge.z), body.collision_mask, [body.get_rid()])
	var surface := body.get_world_3d().direct_space_state.intersect_ray(query)
	if surface.is_empty() or not walkable(body, surface.normal):
		return 0.0
	var landing_y: float = surface.position.y + body.safe_margin
	var rise := landing_y - body.global_position.y
	if rise < 0.02 or rise > height + 0.001:
		return 0.0
	body.global_position.y = landing_y
	return rise

static func snap_down(body: CharacterBody3D, height: float) -> void:
	if body.is_on_floor() or body.velocity.y > 0.0 or height <= 0.0:
		return
	var floor_hit := KinematicCollision3D.new()
	if body.test_move(body.global_transform, Vector3.DOWN * (height + 0.03), floor_hit, body.safe_margin) and walkable(body, floor_hit.get_normal()):
		body.global_position += floor_hit.get_travel()
		body.apply_floor_snap()

static func walkable(body: CharacterBody3D, normal: Vector3) -> bool:
	return normal.dot(body.up_direction) >= cos(body.floor_max_angle)
