## Единая точка нанесения урона.
##
## Мультиплеер: урон считает только сервер. В одиночной игре
## multiplayer.is_server() == true, поэтому тот же код работает локально,
## а при подключении ENet-пира клиент просто перестанет вредить сам себе.
class_name Damage
extends RefCounted

static func apply(target: Node, amount: float, attacker: Node, headshot: bool, penetration: float) -> float:
	if target == null or not is_instance_valid(target):
		return 0.0
	var hp := find_health(target)
	if hp == null:
		return 0.0
	if not target.is_inside_tree():
		return 0.0

	# В сетевом матче здоровье списывает владелец цели, поэтому чужому бойцу
	# отправляем RPC вместо прямого урона.
	var net := _net_wrapper(target)
	if net != null:
		if net.replicator.has_authority():
			return hp.take_damage(amount, attacker, headshot, penetration)
		var attacker_id: int = attacker.get("peer_id") if attacker != null and attacker.get("peer_id") != null else 0
		Fusion.rpc_to_player(net.replicator.get_owner_id(),
			Callable(net, "apply_remote_damage").bind(amount, headshot, attacker_id))
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
	for child in target.get_children():
		if child is Health:
			return child
	return null

## Попадание выше этой высоты над ногами считается в голову.
static func is_headshot(target: Node3D, point: Vector3, crouched: bool = false) -> bool:
	var head_line: float = 1.42 if not crouched else 0.95
	return point.y - target.global_position.y >= head_line
