## Обвязка бойца для сети: настраивает репликацию и раздаёт урон по RPC.
##
## Своим телом управляет только владелец (has_authority), остальные получают
## позицию через FusionSharedReplicator. Урон применяет владелец цели: стрелок
## шлёт ему RPC, а не меняет чужое здоровье напрямую.
class_name NetPlayer
extends Node3D

@onready var replicator: FusionSharedReplicator = $Replicator
@onready var player: PlayerCharacter = $Player

func _ready() -> void:
	_configure_replication()
	Fusion.register_broadcast_receiver(self)

	var mine := replicator.has_authority()
	player.local_control = mine
	player.peer_id = replicator.get_owner_id()
	player.display_name = "Вы" if mine else "Игрок %d" % player.peer_id
	player.add_to_group("combatants")
	# Команды в дезматче нет: каждый сам за себя, поэтому боты видят всех.
	player.team = 0 if mine else 2

	replicator.authority_changed.connect(_on_authority_changed)

## Конфиг репликации собирается кодом, чтобы не заводить .tres под каждый
## вариант: реплицируются позиция и поворот тела плюс угол взгляда.
func _configure_replication() -> void:
	var config := FusionReplicationConfig.new()
	config.add_property(NodePath("Player:position"))
	config.add_property(NodePath("Player:rotation"))
	config.add_property(NodePath("Player:look_pitch"))
	replicator.replication_config = config
	replicator.set_root_path(NodePath("Player"))

func _on_authority_changed(has_authority: bool) -> void:
	player.local_control = has_authority

## Вызывается у владельца цели: только он списывает себе здоровье.
func apply_remote_damage(amount: float, headshot: bool, attacker_id: int) -> void:
	if not replicator.has_authority():
		return
	var attacker := _find_player(attacker_id)
	player.health.take_damage(amount, attacker, headshot, 0.7)

func _find_player(peer_id: int) -> Node:
	for node in get_tree().get_nodes_in_group("combatants"):
		if node.get("peer_id") == peer_id:
			return node
	return null
