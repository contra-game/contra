## Проверка сессии без редактора: подключение, комната, список игроков, старт.
##
##   Godot_v4.7.2-stable_win64.exe --headless --path . res://tools/lobby_test.tscn
extends Node

func _ready() -> void:
	print("--- LOBBY TEST ---")
	print("blocker: '%s'" % NetConfig.blocker())
	Session.player_name = "TestBot"
	Session.room_name = "contra-test"
	Session.state_text.connect(func(t: String) -> void: print("  ", t))

	var ok: bool = await Session.connect_and_join()
	print("вошли в комнату: %s" % str(ok))
	print("игроков в лобби: %d" % Session.players().size())
	for player in Session.players():
		print("  %s (id=%d, хост=%s)" % [player.name, player.id, str(player.is_host)])
	print("я хост: %s" % str(Session.is_host()))

	# Старт рассылается через Fusion.rpc. Сцену переключает лобби по сигналу,
	# поэтому здесь достаточно поймать сигнал и посмотреть на seed.
	Session.match_started.connect(func(value: int) -> void:
		print("сигнал старта, seed=%d" % value))
	Session.start_match()
	print("seed после старта: %d (ненулевой = RPC отработал)" % Session.match_seed)

	Session.leave()
	print("--- END ---")
	get_tree().quit()
