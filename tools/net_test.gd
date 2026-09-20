## Проверка сетевой сессии без редактора: поднимает матч и печатает,
## дошло ли дело до комнаты и появился ли свой боец.
##   Godot_v4.7.2-stable_win64.exe --headless --path <проект> res://tools/net_test.tscn
extends Node

const RUN_SECONDS := 20.0

var main: Node
var _elapsed: float = 0.0
var _log: Array[String] = []

func _ready() -> void:
	print("blocker: '%s'" % NetConfig.blocker())
	print("app_id задан: %s, регион: %s" % [str(NetConfig.app_id() != ""), NetConfig.region()])
	print("SDK: %s" % str(NetConfig.sdk_installed()))
	main = load("res://scenes/main.tscn").instantiate()
	add_child(main)
	await get_tree().process_frame
	if main.get("net") != null:
		main.net.session_state.connect(func(text: String) -> void:
			_log.append("%.1fs %s" % [_elapsed, text]))

func _process(delta: float) -> void:
	_elapsed += delta
	if _elapsed < RUN_SECONDS:
		return
	set_process(false)
	_report()
	get_tree().quit()

func _report() -> void:
	print("--- NET TEST ---")
	for line in _log:
		print("  ", line)
	print("статус подключения: %s" % str(Fusion.get_connection_status()))
	print("подключён: %s, в комнате: %s" % [
		str(Fusion.is_connected_to_photon()), str(Fusion.is_in_room())])
	if Fusion.is_in_room():
		var room := Fusion.get_room()
		print("комната: %s, игроков: %d, мастер: %s" % [
			room.get_room_name(), room.get_player_count(), str(Fusion.is_master_client())])
		print("мой id: %d" % Fusion.get_local_player_id())
	var actors: Node = main.get_node("Actors")
	var net_players := 0
	for node in actors.get_children():
		# Обвязку узнаём по методу: её скрипт не существует без Photon SDK.
		if node.has_method("apply_remote_damage"):
			net_players += 1
	print("сетевых бойцов в сцене: %d, свой игрок: %s" % [
		net_players, str(main.player != null)])
	print("--- END ---")
