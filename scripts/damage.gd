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
	if not target.is_inside_tree() or not target.multiplayer.is_server():
		return 0.0
	return hp.take_damage(amount, attacker, headshot, penetration)

static func find_health(target: Node) -> Health:
	for child in target.get_children():
		if child is Health:
			return child
	return null

## Попадание выше этой высоты над ногами считается в голову.
static func is_headshot(target: Node3D, point: Vector3, crouched: bool = false) -> bool:
	var head_line: float = 1.42 if not crouched else 0.95
	return point.y - target.global_position.y >= head_line
