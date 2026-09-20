## Сетевая сессия на Photon Fusion (Shared Authority).
##
## Каждый клиент владеет своим бойцом и реплицирует его позицию; урон
## применяет владелец цели — стрелок лишь сообщает о попадании. Такая схема
## проще серверной и не требует выделенного хоста: комната живёт в облаке.
##
## Если SDK или App ID нет, менеджер молча отключается и матч идёт офлайн —
## см. NetConfig.blocker().
class_name NetManager
extends Node

signal session_state(text: String)
signal local_player_spawned(player: Node)
signal remote_player_spawned(player: Node)

const APP_VERSION := "0.2"
const PLAYER_SCENE := preload("res://scenes/net_player.tscn")

@export var room_name: String = "contra-city"
@export var max_players: int = 8

var spawner: FusionSpawner
var connected: bool = false

var _spawn_root: Node3D
var _local_player: Node = null

func start(spawn_root: Node3D) -> bool:
	_spawn_root = spawn_root
	var blocker := NetConfig.blocker()
	if blocker != "":
		session_state.emit("офлайн: %s" % blocker)
		return false

	spawner = FusionSpawner.new()
	spawner.name = "FusionSpawner"
	spawner.add_spawnable_scene(PLAYER_SCENE)
	spawner.set_spawn_path(spawn_root.get_path())
	spawner.spawned.connect(_on_spawned)
	# Менеджер сам создаётся в _ready игры, поэтому узел добавляем отложенно.
	add_child.call_deferred(spawner)

	Fusion.connected_to_photon.connect(_on_connected)
	Fusion.connection_failed.connect(_on_connection_failed)
	Fusion.room_joined.connect(_on_room_joined)
	Fusion.room_left.connect(_on_room_left)
	Fusion.player_joined.connect(_on_player_joined)
	Fusion.player_left.connect(_on_player_left)

	Fusion.set_app_id(NetConfig.app_id())
	var user_id := "player-%d" % (randi() % 1000000)
	session_state.emit("подключение к Photon (%s)…" % NetConfig.region())
	Fusion.connect_to_photon(user_id, NetConfig.region(), APP_VERSION)
	return true

func stop() -> void:
	if Fusion.is_in_room():
		Fusion.leave_room()
	if Fusion.is_connected_to_photon():
		Fusion.disconnect_from_photon()

func is_online() -> bool:
	return connected and Fusion.is_in_room()

# --- события Photon ----------------------------------------------------------

func _on_connected() -> void:
	session_state.emit("подключено, вход в комнату «%s»…" % room_name)
	var options := FusionRoomOptions.new()
	options.set_max_players(max_players)
	options.set_is_open(true)
	options.set_is_visible(true)
	Fusion.join_or_create_room(room_name, options)

func _on_connection_failed(error) -> void:
	connected = false
	session_state.emit("Photon недоступен (%s) — матч офлайн" % str(error))

func _on_room_joined() -> void:
	connected = true
	var room := Fusion.get_room()
	var count: int = room.get_player_count() if room != null else 1
	session_state.emit("в комнате «%s», игроков: %d" % [room_name, count])
	_spawn_local()

func _on_room_left() -> void:
	connected = false
	session_state.emit("вышли из комнаты")

func _on_player_joined(player_id: int, _user_id: String) -> void:
	session_state.emit("игрок %d подключился" % player_id)

func _on_player_left(player_id: int, _is_inactive: bool) -> void:
	session_state.emit("игрок %d вышел" % player_id)

# --- спавн -------------------------------------------------------------------

func _spawn_local() -> void:
	if _local_player != null and is_instance_valid(_local_player):
		return
	spawner.spawn(PLAYER_SCENE, Callable())

## Сигнал приходит и на свои, и на чужие объекты: своего отличаем по авторитету.
func _on_spawned(node: Node) -> void:
	var replicator: FusionReplicator = node.get_node_or_null("Replicator")
	var mine: bool = replicator != null and replicator.has_authority()
	if mine:
		_local_player = node
		local_player_spawned.emit(node)
	else:
		remote_player_spawned.emit(node)
