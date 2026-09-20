## Сетевая сессия на Photon Fusion (Shared Authority).
##
## Каждый клиент владеет своим бойцом и реплицирует его позицию; урон
## применяет владелец цели — стрелок лишь сообщает о попадании. Такая схема
## проще серверной и не требует выделенного хоста: комната живёт в облаке.
##
## Работа разбита на два этапа: connect_and_join() поднимает соединение и
## заводит комнату — этого хватает лобби, а begin_match() создаёт спавнер и
## выпускает бойца, когда матч уже построил карту.
##
## Меню проверяет готовность сети через NetConfig.blocker().
##
## class_name намеренно нет: файл ссылается на классы GDExtension и без
## установленного Photon SDK не компилируется, поэтому его грузит по пути
## session.gd и только при живом расширении.
extends Node

signal session_state(text: String)
signal lobby_changed()
signal joined(success: bool)
signal local_player_spawned(player: Node)
signal remote_player_spawned(player: Node)
signal kill_confirmed(victim_name: String, headshot: bool)
signal death_announced(victim_name: String, killer_name: String, headshot: bool)
signal connection_lost()

const APP_VERSION := "0.3"
const PLAYER_SCENE := preload("res://scenes/net_player.tscn")

var spawner: FusionSpawner
var connected: bool = false

var _room_name: String = "contra-city"
var _max_players: int = 8
var _local_player: Node = null
var _signals_bound: bool = false
var _joining: bool = false
var _connect_deadline: int = 0
var _pickups: Array[WeaponPickup] = []
var _pickup_expiry: Dictionary = {}

func _ready() -> void:
	Fusion.register_broadcast_receiver(self)

func _exit_tree() -> void:
	Fusion.unregister_broadcast_receiver(self)

func register_pickups(pickups: Array[WeaponPickup]) -> void:
	_pickups = pickups
	_pickup_expiry.clear()

func request_pickup(index: int) -> void:
	if not is_online():
		return
	if is_host():
		_grant_pickup(index, Fusion.get_local_player_id())
	else:
		Fusion.rpc_to(Fusion.TARGET_MASTER, receive_pickup_request, index)

@rpc("any_peer", "call_remote", "reliable")
func receive_pickup_request(index: int) -> void:
	# RPC может догнать нас уже после выхода из комнаты.
	if is_host() and NetApi.room() != null:
		_grant_pickup(index, NetApi.rpc_sender())

func _grant_pickup(index: int, sender: int) -> void:
	if index < 0 or index >= _pickups.size() or not is_instance_valid(_pickups[index]):
		return
	var pickup := _pickups[index]
	var now: float = NetApi.network_time()
	var expires: float = maxf(_pickup_expiry.get(index, 0.0),
		float(NetApi.room_property("pickup_%d" % index, 0.0)))
	if now < expires:
		return
	for actor in get_tree().get_nodes_in_group("combatants"):
		if actor is PlayerCharacter and actor.peer_id == sender and actor.health.alive:
			if actor.global_position.distance_to(pickup.global_position) > 3.8:
				return
			_pickup_expiry[index] = now + pickup.respawn_delay
			NetApi.set_room_property("pickup_%d" % index, _pickup_expiry[index])
			pickup.set_available(false)
			if sender == NetApi.local_player_id():
				_apply_pickup(index)
			else:
				NetApi.rpc_to_player(sender, receive_pickup_grant, [index])
			return

@rpc("any_peer", "call_remote", "reliable")
func receive_pickup_grant(index: int) -> void:
	var room := NetApi.room()
	if room == null or NetApi.rpc_sender() != int(room.call("get_master_client_id")):
		return
	_apply_pickup(index)

func _apply_pickup(index: int) -> void:
	if index < 0 or index >= _pickups.size() or not is_instance_valid(_local_player):
		return
	var pickup := _pickups[index]
	if _local_player.player.health.alive and _local_player.player.weapons.give(pickup.weapon_id, true):
		Sfx.play_3d(&"pickup", pickup.global_position, 1.0, -2.0)
		pickup.picked_up.emit(pickup.weapon_id, _local_player.player)

## Подключается к Photon и входит в комнату; результат приходит сигналом joined.
## Возвращает false сразу, если сеть поднять нечем.
func connect_and_join(user_id: String, room: String, max_players: int = 8) -> bool:
	if _joining or connected:
		return false
	var blocker := NetConfig.blocker()
	if blocker != "":
		session_state.emit("офлайн: %s" % blocker)
		return false

	_bind_signals()
	_joining = true
	_connect_deadline = Time.get_ticks_msec() + 20000
	_room_name = room
	_max_players = max_players
	session_state.emit("подключение к Photon (%s)…" % NetConfig.region())
	if not Fusion.is_initialized():
		Fusion.set_app_id(NetConfig.app_id())
	if Fusion.is_connected_to_photon():
		_on_connected()
		return true
	Fusion.connect_to_photon(user_id, NetConfig.region(), APP_VERSION)
	return true

## Спавнер живёт только в матче: в лобби бойца выпускать некуда.
func begin_match(spawn_root: Node3D) -> void:
	if spawner != null and is_instance_valid(spawner):
		spawner.queue_free()
	spawner = FusionSpawner.new()
	spawner.name = "FusionSpawner"
	spawner.add_spawnable_scene(PLAYER_SCENE)
	spawner.set_spawn_path(spawn_root.get_path())
	spawner.spawned.connect(_on_spawned)
	# Photon добавляет свои узлы в дерево, поэтому узел цепляем отложенно:
	# во время _ready сцена ещё «занята» и add_child падает.
	add_child.call_deferred(spawner)
	await get_tree().process_frame
	await get_tree().process_frame
	if is_online() and is_instance_valid(spawner) and is_instance_valid(spawn_root):
		spawner.spawn(PLAYER_SCENE, Callable())

func players() -> Array:
	var room := Fusion.get_room()
	if room == null:
		return []
	return room.get_players()

func is_host() -> bool:
	return Fusion.is_master_client()

func is_online() -> bool:
	return connected and Fusion.is_in_room()

func leave() -> void:
	connected = false
	_joining = false
	if is_instance_valid(spawner):
		if is_instance_valid(_local_player) and Fusion.is_in_room():
			spawner.despawn(_local_player)
		spawner.queue_free()
	spawner = null
	_local_player = null
	_pickups.clear()
	_pickup_expiry.clear()
	if Fusion.is_in_room():
		Fusion.leave_room()

func stop() -> void:
	leave()
	if Fusion.is_connected_to_photon():
		Fusion.disconnect_from_photon()

# --- события Photon ----------------------------------------------------------

## Подписка одноразовая: в меню можно зайти и выйти несколько раз за запуск.
func _bind_signals() -> void:
	if _signals_bound:
		return
	_signals_bound = true
	Fusion.connected_to_photon.connect(_on_connected)
	Fusion.connection_failed.connect(_on_connection_failed)
	Fusion.room_joined.connect(_on_room_joined)
	Fusion.room_left.connect(_on_room_left)
	Fusion.player_joined.connect(_on_player_joined)
	Fusion.player_left.connect(_on_player_left)
	Fusion.master_client_changed.connect(_on_master_changed)
	Fusion.connection_status_changed.connect(_on_connection_status)

func _process(_delta: float) -> void:
	if _joining and Time.get_ticks_msec() >= _connect_deadline:
		_on_connection_failed("время ожидания истекло")
		Fusion.disconnect_from_photon()
	if is_online() and not _pickups.is_empty():
		var room := NetApi.room()
		if room == null:
			return
		var props: Dictionary = room.call("get_custom_properties")
		var now: float = NetApi.network_time()
		for i in _pickups.size():
			if is_instance_valid(_pickups[i]):
				var expiry: float = maxf(_pickup_expiry.get(i, 0.0), float(props.get("pickup_%d" % i, 0.0)))
				_pickups[i].set_available(now >= expiry)

func _on_connection_status(status: int) -> void:
	if status == Fusion.STATUS_DISCONNECTED or status == Fusion.STATUS_ERROR:
		if _joining:
			_on_connection_failed("соединение прервано")
		elif connected:
			connected = false
			connection_lost.emit()

func _on_connected() -> void:
	if not _joining:
		return
	session_state.emit("подключено, вход в комнату «%s»…" % _room_name)
	var options := FusionRoomOptions.new()
	options.set_max_players(_max_players)
	options.set_is_open(true)
	options.set_is_visible(true)
	Fusion.join_or_create_room(_room_name, options)

func _on_connection_failed(error) -> void:
	var was_joining := _joining
	var was_connected := connected
	_joining = false
	connected = false
	session_state.emit("Photon недоступен (%s)" % str(error))
	if was_joining:
		joined.emit(false)
	elif was_connected:
		connection_lost.emit()

func _on_room_joined() -> void:
	if not _joining:
		Fusion.leave_room()
		return
	_joining = false
	connected = true
	var room := Fusion.get_room()
	var count: int = room.get_player_count() if room != null else 1
	session_state.emit("в комнате «%s», игроков: %d" % [_room_name, count])
	joined.emit(true)
	lobby_changed.emit()

func _on_room_left() -> void:
	var unexpected := connected
	connected = false
	session_state.emit("вышли из комнаты")
	lobby_changed.emit()
	if unexpected:
		connection_lost.emit()

func _on_player_joined(player_id: int, _user_id: String) -> void:
	session_state.emit("игрок %d подключился" % player_id)
	lobby_changed.emit()

func _on_player_left(player_id: int, _is_inactive: bool) -> void:
	session_state.emit("игрок %d вышел" % player_id)
	lobby_changed.emit()

## Photon шлёт сюда старого и нового мастера — берём оба, чтобы не спорить
## о сигнатуре.
func _on_master_changed(_old_id: int = 0, _new_id: int = 0) -> void:
	lobby_changed.emit()

# --- спавн -------------------------------------------------------------------

## Сигнал приходит и на свои, и на чужие объекты: своего отличаем по авторитету.
func _on_spawned(node: Node) -> void:
	if node.has_method("configure_owner"):
		node.configure_owner()
	var replicator: FusionReplicator = node.get_node_or_null("Replicator")
	var mine: bool = replicator != null and replicator.has_authority()
	if mine:
		_local_player = node
		local_player_spawned.emit(node)
	else:
		remote_player_spawned.emit(node)
