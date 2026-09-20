## Игровая сессия: живёт дольше сцены и связывает меню, лобби и матч.
##
## Раньше сеть поднимал сам матч, поэтому соединение умирало вместе со сценой и
## лобби было негде держать. Теперь Photon живёт здесь: меню подключается, лобби
## показывает состав комнаты, матч только берёт готовое соединение.
extends Node

signal state_text(text: String)
signal lobby_changed()
signal match_started(seed_value: int)

const MENU_SCENE := "res://scenes/menu.tscn"
const LOBBY_SCENE := "res://scenes/lobby.tscn"
const MATCH_SCENE := "res://scenes/main.tscn"
const SETTINGS_PATH := "user://settings.cfg"
## Ключ свойства комнаты, через который хост объявляет старт матча.
const SEED_KEY := "seed"

## Строка списка игроков в лобби.
class LobbyPlayer:
	var id: int = 0
	var name: String = ""
	var is_host: bool = false

var player_name: String = "Игрок"
var room_name: String = "contra-city"
var online: bool = false
var match_seed: int = 0

const NET_MANAGER_SCRIPT := "res://scripts/net_manager.gd"

## Обычный Node, а не типизированный NetManager: скрипт менеджера ссылается на
## классы GDExtension и не компилируется без установленного Photon SDK.
var net: Node = null

## Активный seed принимают и поздно подключившиеся игроки.
var _seen_seed: int = 0
var _watching: bool = false
var last_error: String = ""

func _ready() -> void:
	load_settings()
	if not NetApi.available():
		print("[сеть] Photon SDK не поднялся — доступен только офлайн-режим")
		return
	net = (load(NET_MANAGER_SCRIPT) as GDScript).new()
	net.name = "NetManager"
	add_child(net)
	net.session_state.connect(_on_net_state)
	net.lobby_changed.connect(func() -> void: lobby_changed.emit())
	net.joined.connect(_on_joined)
	net.connection_lost.connect(_on_connection_lost)

## Сетевые события дублируются в консоль: альфа собирается с консолью именно
## затем, чтобы при сбое у напарника было видно причину.
func _on_net_state(text: String) -> void:
	print("[сеть] ", text)
	state_text.emit(text)

## Идентификатор для Photon: имя плюс хвост, чтобы двое тёзок не столкнулись.
func user_id() -> String:
	return "%s#%04d" % [player_name, randi() % 10000]

func connect_and_join() -> bool:
	if net == null:
		return false
	# Photon цепляет свои узлы к дереву, поэтому подключаться из _ready нельзя:
	# сцена в этот момент ещё «занята» и add_child падает.
	await get_tree().process_frame
	if not net.connect_and_join(user_id(), room_name):
		return false
	return await net.joined

func leave() -> void:
	print("[сессия] выход из комнаты")
	_watching = false
	if net != null:
		net.stop()

func players() -> Array:
	var out: Array = []
	if net == null:
		return out
	for player in net.players():
		var row := LobbyPlayer.new()
		row.id = player.get_number()
		row.name = player.get_user_id().split("#")[0]
		row.is_host = player.get_is_master_client()
		out.append(row)
	return out

func is_host() -> bool:
	return net != null and net.is_host()

func is_online() -> bool:
	return net != null and net.is_online()

# --- старт матча -------------------------------------------------------------

## Хост объявляет старт через свойство комнаты: seed один на всех, иначе карта
## соберётся разная. Широковещательный RPC тут не годится — Fusion шлёт их
## только от узлов с репликатором, а сессия живёт вне сетевого дерева.
func start_match() -> void:
	if not is_online() or not is_host() or match_seed != 0:
		return
	# Photon хранит целые свойства комнаты как signed int32.
	var seed_value := randi() & 0x7fffffff
	if seed_value == 0:
		seed_value = 1
	NetApi.set_room_property(SEED_KEY, seed_value)
	_apply_start(seed_value)

func _apply_start(seed_value: int) -> void:
	if match_seed == seed_value:
		return
	print("[сессия] старт матча, seed=%d" % seed_value)
	_watching = false
	_seen_seed = seed_value
	match_seed = seed_value
	online = is_online()
	match_started.emit(seed_value)

## Пока сидим в лобби, ждём, когда хост положит в комнату новый seed.
func _process(_delta: float) -> void:
	if not _watching or not is_online():
		return
	var value := int(NetApi.room_property(SEED_KEY, 0))
	if value != 0 and value != _seen_seed:
		_apply_start(value)

func _on_joined(success: bool) -> void:
	if not success:
		return
	match_seed = 0
	_seen_seed = 0
	# Лобби включает наблюдение после подключения обработчика match_started.
	_watching = false

func watch_match_start() -> void:
	_watching = true

func _on_connection_lost() -> void:
	last_error = "Соединение потеряно. Подключитесь к комнате снова."
	to_menu.call_deferred()

func start_offline() -> void:
	leave()
	online = false
	match_seed = randi()
	get_tree().change_scene_to_file(MATCH_SCENE)

func go_to_match() -> void:
	print("[сессия] переход в матч")
	var err := get_tree().change_scene_to_file(MATCH_SCENE)
	if err != OK:
		print("[сессия] ОШИБКА перехода: %d" % err)

func to_menu() -> void:
	print("[сессия] возврат в меню")
	online = false
	match_seed = 0
	leave()
	get_tree().paused = false
	get_tree().change_scene_to_file(MENU_SCENE)

# --- настройки ---------------------------------------------------------------

func save_settings() -> void:
	var config := ConfigFile.new()
	config.set_value("player", "name", player_name)
	config.set_value("player", "room", room_name)
	config.save(SETTINGS_PATH)

func load_settings() -> void:
	var config := ConfigFile.new()
	if config.load(SETTINGS_PATH) != OK:
		return
	player_name = str(config.get_value("player", "name", player_name))
	room_name = str(config.get_value("player", "room", room_name))
