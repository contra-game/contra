## Единая точка нанесения урона.
##
## В Photon здоровье меняет владелец цели, в офлайне — локальная симуляция.
class_name Damage
extends RefCounted

static func apply(target: Node, amount: float, attacker: Node, headshot: bool, penetration: float) -> float:
	if target == null or not is_instance_valid(target):
		return 0.0
	var hp := find_health(target)
	if hp == null or not hp.alive:
		return 0.0
	if not target.is_inside_tree():
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
		# Аргументы уходят списком: Callable.bind() Fusion не понимает и роняет
		# процесс. Метод живёт на обвязке — это узел с дочерним репликатором,
		# по нему SDK и находит того же бойца на чужом клиенте.
		Fusion.rpc_to_player(net.replicator.get_owner_id(),
			net.apply_remote_damage, amount, headshot, penetration, net.life_serial)
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
