## Единственное место, где игра достаёт синглтон Photon Fusion.
##
## Идентификаторы `Fusion` и `Fusion*` здесь не упоминаются намеренно: без
## установленного GDExtension такой идентификатор — ошибка парсинга, из-за
## которой рассыпался весь проект вместе с офлайн-режимом. Синглтон берётся по
## имени в рантайме, поэтому файл компилируется всегда, а `available()` даёт
## остальному коду честный ответ, есть ли сеть.
class_name NetApi
extends RefCounted

const SINGLETON_NAME := "Fusion"

static var _resolved: bool = false
static var _api: Object = null

static func api() -> Object:
	if not _resolved:
		_resolved = true
		if Engine.has_singleton(SINGLETON_NAME):
			_api = Engine.get_singleton(SINGLETON_NAME)
	return _api

static func available() -> bool:
	return api() != null

# --- состояние ---------------------------------------------------------------

static func is_in_room() -> bool:
	var a := api()
	return a != null and bool(a.call("is_in_room"))

static func is_master_client() -> bool:
	var a := api()
	return a != null and bool(a.call("is_master_client"))

static func local_player_id() -> int:
	var a := api()
	return int(a.call("get_local_player_id")) if a != null else 0

static func rpc_sender() -> int:
	var a := api()
	return int(a.call("get_rpc_sender")) if a != null else 0

static func rtt() -> float:
	var a := api()
	return float(a.call("get_rtt")) if a != null and is_in_room() else 0.0

static func network_time() -> float:
	var a := api()
	return float(a.call("get_network_time")) if a != null else 0.0

static func room() -> Object:
	var a := api()
	return a.call("get_room") if a != null else null

# --- свойства комнаты --------------------------------------------------------

## Сигнала на смену свойств комнаты в SDK нет, состояние читается опросом.
static func room_property(key: String, default_value: Variant) -> Variant:
	var r := room()
	if r == null:
		return default_value
	return r.call("get_custom_properties").get(key, default_value)

static func set_room_property(key: String, value: Variant) -> void:
	var r := room()
	if r != null:
		r.call("set_property", key, value)

# --- RPC ---------------------------------------------------------------------
# Аргументы передаются массивом: Callable.bind() Fusion не понимает и роняет
# процесс, а вариадиков у статических функций GDScript нет.

static func rpc_all(method: Callable, args: Array = []) -> void:
	var a := api()
	if a != null:
		a.callv("rpc", [method] + args)

static func rpc_to_player(player_id: int, method: Callable, args: Array = []) -> void:
	var a := api()
	if a != null:
		a.callv("rpc_to_player", [player_id, method] + args)

static func rpc_to_master(method: Callable, args: Array = []) -> void:
	var a := api()
	if a != null:
		a.callv("rpc_to", [a.get("TARGET_MASTER"), method] + args)
