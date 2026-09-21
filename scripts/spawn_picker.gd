## Spawn scoring uses the actual capsule and world sight lines.
extends RefCounted

static func choose(world: Node3D, candidates: Array[Transform3D], actor: Node3D, free_for_all: bool = false) -> Dictionary:
	var best: Dictionary = {}
	var best_score := -INF
	var space := world.get_world_3d().direct_space_state
	for point in candidates:
		if not clear(space, point, actor):
			continue
		var nearest := 80.0
		var visible := 0
		var occupied := false
		for other in world.get_tree().get_nodes_in_group("combatants"):
			if other == actor or not is_instance_valid(other):
				continue
			var health := Damage.find_health(other)
			if health == null or not health.alive:
				continue
			var distance := point.origin.distance_to(other.global_position)
			# Newly added bodies may not yet be in the physics broad phase.
			if distance < 1.25:
				occupied = true
				break
			if not free_for_all and other.get("team") == actor.get("team"):
				continue
			nearest = minf(nearest, distance)
			var ray := PhysicsRayQueryParameters3D.create(other.global_position + Vector3.UP * 1.5, point.origin + Vector3.UP * 1.2, 1)
			if space.intersect_ray(ray).is_empty():
				visible += 1
		if occupied:
			continue
		var score := nearest - float(visible) * 45.0
		if score > best_score:
			best_score = score
			best = {"transform": point, "score": score, "visible_enemies": visible, "nearest_enemy": nearest}
	return best

static func clear(space: PhysicsDirectSpaceState3D, at: Transform3D, actor: Node3D) -> bool:
	var capsule := CapsuleShape3D.new()
	capsule.radius = 0.42
	capsule.height = 1.8
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = capsule
	query.transform = Transform3D(Basis.IDENTITY, at.origin + Vector3.UP * 0.92)
	query.collision_mask = 1 | 2 | 4
	if actor is CollisionObject3D:
		query.exclude = [actor.get_rid()]
	return space.intersect_shape(query, 1).is_empty()
