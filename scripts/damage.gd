## Единая точка нанесения урона.
##
## В Photon здоровье меняет владелец цели, в офлайне — локальная симуляция.
class_name Damage
extends RefCounted

static func apply(target: Node, amount: float, attacker: Node, headshot: bool, penetration: float, weapon_id: String = "") -> float:
	target = resolve_target(target)
	if target == null or not is_instance_valid(target):
		return 0.0
	var hp := find_health(target)
	if hp == null or not hp.alive:
		return 0.0
	if not target.is_inside_tree():
		return 0.0
	var flow := target.get_tree().get_first_node_in_group("match_flow")
	if flow != null and not flow.allows_combat():
		return 0.0

	# В сетевом матче здоровье списывает владелец цели, поэтому чужому бойцу
	# отправляем RPC вместо прямого урона.
	var net := _net_wrapper(target)
	if net != null:
		if net.replicator.has_authority():
			return hp.take_damage(amount, attacker, headshot, penetration)
		# Стрелять по чужому бойцу может только живой игрок: у ботов нет peer_id,
		# и звать их выстрелами чужой клиент не должен.
		if attacker == null or attacker.get("peer_id") == null:
			return 0.0
		if not attacker.local_control or not attacker.health.alive:
			return 0.0
		# Метод живёт на обвязке — это узел с дочерним репликатором, по нему SDK
		# и находит того же бойца на чужом клиенте.
		NetApi.rpc_to_player(net.replicator.get_owner_id(), net.apply_remote_damage,
			[weapon_id, amount, headshot, net.life_serial])
		return amount

	if not target.multiplayer.is_server():
		return 0.0
	return hp.take_damage(amount, attacker, headshot, penetration)

## Боец, завёрнутый в сетевую обвязку, либо null для ботов и офлайна.
static func _net_wrapper(target: Node) -> Node:
	var parent := target.get_parent()
	if parent != null and parent.get_script() != null and parent.has_method("apply_remote_damage"):
		return parent
	return null

static func find_health(target: Node) -> Health:
	target = resolve_target(target)
	if not is_instance_valid(target):
		return null
	for child in target.get_children():
		if child is Health:
			return child
	return null

static func resolve_target(collider: Node) -> Node:
	var node := collider
	while is_instance_valid(node):
		if node.get_node_or_null("Health") is Health:
			return node
		if not node is Area3D and node.name != "Hitboxes":
			break
		node = node.get_parent()
	return collider

static func hit_zone(collider: Node, point: Vector3) -> StringName:
	if collider.has_meta("hit_zone"):
		return collider.get_meta("hit_zone")
	var target := resolve_target(collider) as Node3D
	if target != null:
		var crouched: bool = target.get("crouching") == true
		if is_headshot(target, point, crouched):
			return &"head"
		if point.y - target.global_position.y < (0.5 if crouched else 0.8):
			return &"limb"
	return &"body"

static func zone_multiplier(data: WeaponData, zone: StringName) -> float:
	return data.headshot_multiplier if zone == &"head" else (0.75 if zone == &"limb" else 1.0)

## Skip movement capsules for actors with separate hurt volumes and exclude all
## of the shooter's areas. Walls still terminate the ray before any hurt volume.
static func raycast(space: PhysicsDirectSpaceState3D, from: Vector3, to: Vector3, shooter: CollisionObject3D = null) -> Dictionary:
	var exclude: Array[RID] = []
	if shooter != null:
		exclude.append(shooter.get_rid())
		var hitboxes := shooter.get_node_or_null("Hitboxes")
		if hitboxes != null:
			for area in hitboxes.get_children():
				if area is Area3D:
					exclude.append(area.get_rid())
	var query := PhysicsRayQueryParameters3D.create(from, to, 1 | 2 | 4 | 32, exclude)
	query.collide_with_areas = true
	for attempt in 64:
		var hit := space.intersect_ray(query)
		if hit.is_empty():
			return hit
		var body: Node = hit.collider
		if body is CharacterBody3D and body.has_node("Hitboxes"):
			exclude.append(body.get_rid())
			query.exclude = exclude
			continue
		return hit
	return {}

## Попадание выше этой высоты над ногами считается в голову.
static func is_headshot(target: Node3D, point: Vector3, crouched: bool = false) -> bool:
	var head_line: float = 1.42 if not crouched else 0.95
	return point.y - target.global_position.y >= head_line
