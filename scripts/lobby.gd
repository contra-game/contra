## Лобби: кто сидит в комнате и кнопка старта у хоста.
extends Control

@onready var title: Label = $Center/Panel/Rows/Title
@onready var list: VBoxContainer = $Center/Panel/Rows/Players
@onready var start_button: Button = $Center/Panel/Rows/StartButton
@onready var leave_button: Button = $Center/Panel/Rows/LeaveButton
@onready var status: Label = $Center/Panel/Rows/Status

func _ready() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	title.text = "Комната «%s»" % Session.room_name

	start_button.pressed.connect(func() -> void: Session.start_match())
	leave_button.pressed.connect(func() -> void: Session.to_menu())
	Session.lobby_changed.connect(_refresh)
	Session.state_text.connect(func(text: String) -> void: status.text = text)
	# Матч начинает хост, а переход делают все — каждый по своему сигналу.
	Session.match_started.connect(func(_seed: int) -> void: Session.go_to_match())
	Session.watch_match_start()

	_refresh()

	# Проверочный режим: хост сам начинает матч, чтобы билд на двоих можно было
	# прогнать без кликов в двух окнах.
	if OS.get_cmdline_user_args().has("--auto"):
		await get_tree().create_timer(8.0).timeout
		if Session.is_host():
			Session.start_match()

func _refresh() -> void:
	for child in list.get_children():
		child.queue_free()
	for player in Session.players():
		var row := Label.new()
		row.text = "%s%s" % [player.name, "   — хост" if player.is_host else ""]
		list.add_child(row)

	var host := Session.is_host()
	start_button.disabled = not host
	start_button.text = "НАЧАТЬ МАТЧ" if host else "Ждём хоста…"
