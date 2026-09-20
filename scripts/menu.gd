## Главное меню: имя, комната, выбор сетевого или офлайн-матча.
extends Control

@onready var name_edit: LineEdit = $Center/Panel/Rows/NameRow/NameEdit
@onready var room_edit: LineEdit = $Center/Panel/Rows/RoomRow/RoomEdit
@onready var online_button: Button = $Center/Panel/Rows/OnlineButton
@onready var offline_button: Button = $Center/Panel/Rows/OfflineButton
@onready var quit_button: Button = $Center/Panel/Rows/QuitButton
@onready var status: Label = $Center/Panel/Rows/Status

func _ready() -> void:
	if OS.is_debug_build() and OS.get_cmdline_user_args().has("--network-test"):
		get_tree().change_scene_to_file.call_deferred("res://tools/multiplayer_test.tscn")
		return
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	get_tree().paused = false
	name_edit.text = Session.player_name
	room_edit.text = Session.room_name

	Session.state_text.connect(_on_state)
	online_button.pressed.connect(_on_online)
	offline_button.pressed.connect(_on_offline)
	quit_button.pressed.connect(func() -> void: get_tree().quit())

	var blocker := NetConfig.blocker()
	status.text = "сеть не готова: %s" % blocker if blocker != "" else "готов к бою"
	if Session.last_error != "":
		status.text = Session.last_error
		Session.last_error = ""
	online_button.disabled = blocker != ""

	# Запуск с «-- --auto» сразу лезет в сеть: так проверяется билд на двоих,
	# без кликов в двух окнах.
	if OS.get_cmdline_user_args().has("--auto"):
		_on_online()

func _on_state(text: String) -> void:
	status.text = text

func _on_online() -> void:
	_remember()
	online_button.disabled = true
	offline_button.disabled = true
	var ok: bool = await Session.connect_and_join()
	online_button.disabled = false
	offline_button.disabled = false
	if ok:
		get_tree().change_scene_to_file(Session.LOBBY_SCENE)
	else:
		status.text = "не вышло подключиться — играйте офлайн"

func _on_offline() -> void:
	_remember()
	Session.start_offline()

const NAME_LIMIT := 20
const ROOM_LIMIT := 24

func _remember() -> void:
	Session.player_name = _clean(name_edit.text, NAME_LIMIT, "Игрок")
	Session.room_name = _clean(room_edit.text, ROOM_LIMIT, "contra-city")
	name_edit.text = Session.player_name
	room_edit.text = Session.room_name
	Session.save_settings()

## Решётка — разделитель в user_id («Имя#1234»), поэтому в самом имени её быть
## не должно: лобби показало бы обрезанное имя. Длину режем здесь же — имя
## уезжает всем по сети, и отсутствие лимита превращает его в канал для мусора.
func _clean(text: String, limit: int, fallback: String) -> String:
	var value := text.replace("#", "").strip_edges()
	if value.length() > limit:
		value = value.substr(0, limit)
	return value if value != "" else fallback
