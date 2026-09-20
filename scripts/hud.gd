## Весь интерфейс боя: прицел, здоровье, патроны, киллфид, счёт, пауза.
## Строится кодом, чтобы вёрстка лежала рядом с логикой, которая её обновляет.
class_name Hud
extends CanvasLayer

const ACCENT := Color(0.96, 0.78, 0.25)
const DANGER := Color(0.9, 0.25, 0.22)

var game: Node
var player: PlayerCharacter

var _crosshair: Crosshair
var _health_label: Label
var _armor_label: Label
var _ammo_label: Label
var _weapon_label: Label
var _score_label: Label
var _hint_label: Label
var _center_label: Label
var _killfeed: VBoxContainer
var _damage_flash: ColorRect
var _pause_panel: PanelContainer
var _shop: Shop
var _money_label: Label
var _paused: bool = false
var _respawn_left: float = 0.0

func _ready() -> void:
	layer = 10
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build_crosshair()
	_build_status()
	_build_killfeed()
	_build_center()
	_build_pause()
	_build_shop()

func bind(game_node: Node, player_node: PlayerCharacter) -> void:
	game = game_node
	player = player_node

	player.health.changed.connect(_on_health_changed)
	player.died.connect(_on_player_died)
	player.respawned.connect(_on_player_respawned)
	player.weapons.ammo_changed.connect(_on_ammo_changed)
	player.weapons.weapon_changed.connect(_on_weapon_changed)
	player.weapons.spread_changed.connect(_crosshair.set_spread)
	player.weapons.hit_confirmed.connect(_on_hit_confirmed)
	player.health.damaged.connect(_on_damaged)

	_shop.bind(player_node, player_node.economy)
	player.economy.money_changed.connect(_on_money_changed)
	_on_money_changed(player.economy.money)
	game.score_changed.connect(_on_score_changed)
	game.killfeed.connect(push_killfeed)

	_on_health_changed(player.health.health, player.health.armor)
	_on_score_changed(0, 0)

func _process(delta: float) -> void:
	if _respawn_left > 0.0:
		_respawn_left = maxf(_respawn_left - delta, 0.0)
		_center_label.text = "Вы убиты\nВозрождение через %.1f" % _respawn_left
	_damage_flash.modulate.a = lerpf(_damage_flash.modulate.a, 0.0, delta * 3.5)
	if player != null and player.weapons != null:
		_hint_label.visible = player.weapons.reloading
		_hint_label.text = "ПЕРЕЗАРЯДКА"

# --- построение --------------------------------------------------------------

func _build_crosshair() -> void:
	_crosshair = Crosshair.new()
	_crosshair.set_anchors_preset(Control.PRESET_FULL_RECT)
	_crosshair.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_crosshair)

	_damage_flash = ColorRect.new()
	_damage_flash.color = Color(0.7, 0.05, 0.05, 0.45)
	_damage_flash.set_anchors_preset(Control.PRESET_FULL_RECT)
	_damage_flash.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_damage_flash.modulate.a = 0.0
	add_child(_damage_flash)

func _build_status() -> void:
	var left := HBoxContainer.new()
	left.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	left.position = Vector2(34, -86)
	left.add_theme_constant_override("separation", 26)
	add_child(left)

	_health_label = _make_label("100", 40, Color(0.92, 0.94, 0.96))
	_armor_label = _make_label("0", 40, Color(0.55, 0.75, 0.95))
	left.add_child(_health_label)
	left.add_child(_armor_label)

	var right := VBoxContainer.new()
	right.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	right.position = Vector2(-250, -100)
	right.alignment = BoxContainer.ALIGNMENT_END
	add_child(right)

	_weapon_label = _make_label("AK-47", 22, Color(0.8, 0.82, 0.85))
	_weapon_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_weapon_label.custom_minimum_size.x = 220
	_ammo_label = _make_label("30 / 90", 40, ACCENT)
	_ammo_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_ammo_label.custom_minimum_size.x = 220
	right.add_child(_weapon_label)
	right.add_child(_ammo_label)

	_score_label = _make_label("Фраги 0    Смерти 0", 20, Color(0.85, 0.87, 0.9))
	_score_label.set_anchors_preset(Control.PRESET_TOP_LEFT)
	_score_label.position = Vector2(34, 26)
	add_child(_score_label)

	_hint_label = _make_label("ПЕРЕЗАРЯДКА", 22, ACCENT)
	_hint_label.set_anchors_preset(Control.PRESET_CENTER)
	_hint_label.position = Vector2(-80, 70)
	_hint_label.visible = false
	add_child(_hint_label)

func _build_killfeed() -> void:
	_killfeed = VBoxContainer.new()
	_killfeed.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	_killfeed.position = Vector2(-430, 26)
	_killfeed.custom_minimum_size = Vector2(400, 0)
	_killfeed.alignment = BoxContainer.ALIGNMENT_BEGIN
	add_child(_killfeed)

func _build_center() -> void:
	_center_label = _make_label("", 30, DANGER)
	_center_label.set_anchors_preset(Control.PRESET_CENTER_TOP)
	_center_label.position = Vector2(-160, 120)
	_center_label.custom_minimum_size = Vector2(320, 0)
	_center_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	add_child(_center_label)

func _build_pause() -> void:
	_pause_panel = PanelContainer.new()
	_pause_panel.set_anchors_preset(Control.PRESET_CENTER)
	_pause_panel.position = Vector2(-170, -120)
	_pause_panel.custom_minimum_size = Vector2(340, 240)
	_pause_panel.visible = false
	add_child(_pause_panel)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 14)
	_pause_panel.add_child(box)

	var title := _make_label("ПАУЗА", 32, ACCENT)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(title)

	var help := _make_label(
		"WASD — движение, Shift — бег, Ctrl — присед\n"
		+ "ЛКМ — огонь, ПКМ — прицел, R — перезарядка\n"
		+ "1/2 и колесо — оружие, E — подобрать",
		15, Color(0.78, 0.8, 0.84))
	help.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(help)

	var resume := Button.new()
	resume.text = "Продолжить"
	resume.pressed.connect(toggle_pause)
	box.add_child(resume)

	var quit := Button.new()
	quit.text = "Выйти"
	quit.pressed.connect(func() -> void: get_tree().quit())
	box.add_child(quit)

func _make_label(text: String, size: int, color: Color) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", size)
	label.add_theme_color_override("font_color", color)
	label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.75))
	label.add_theme_constant_override("shadow_offset_x", 2)
	label.add_theme_constant_override("shadow_offset_y", 2)
	return label

# --- реакции на игру ---------------------------------------------------------

func _on_health_changed(health: float, armor: float) -> void:
	_health_label.text = str(int(ceil(health)))
	_health_label.add_theme_color_override("font_color", DANGER if health <= 35.0 else Color(0.92, 0.94, 0.96))
	_armor_label.text = str(int(ceil(armor)))
	_armor_label.visible = armor > 0.0

func _on_ammo_changed(in_mag: int, reserve: int) -> void:
	_ammo_label.text = "%d / %d" % [in_mag, reserve]
	_ammo_label.add_theme_color_override("font_color", DANGER if in_mag == 0 else ACCENT)

func _on_weapon_changed(data: WeaponData) -> void:
	_weapon_label.text = data.display_name if data != null else ""

func _on_score_changed(kills: int, deaths: int) -> void:
	_score_label.text = "Фраги %d    Смерти %d" % [kills, deaths]

func _on_hit_confirmed(headshot: bool, killed: bool) -> void:
	_crosshair.show_hitmarker(headshot, killed)

func _on_damaged(_amount: float, _attacker: Node, _headshot: bool) -> void:
	_damage_flash.modulate.a = 1.0

func _on_player_died(_attacker: Node) -> void:
	_respawn_left = game.respawn_delay if game != null else 3.0
	_crosshair.visible = false

func _on_player_respawned() -> void:
	_respawn_left = 0.0
	_center_label.text = ""
	_crosshair.visible = true

func push_killfeed(text: String) -> void:
	var label := _make_label(text, 16, Color(0.86, 0.88, 0.9))
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_killfeed.add_child(label)
	while _killfeed.get_child_count() > 5:
		_killfeed.get_child(0).free()
	var tween := create_tween()
	tween.tween_interval(4.5)
	tween.tween_property(label, "modulate:a", 0.0, 0.6)
	tween.tween_callback(func() -> void:
		if is_instance_valid(label):
			label.queue_free())

func toggle_pause() -> void:
	_paused = not _paused
	_pause_panel.visible = _paused
	get_tree().paused = _paused
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE if _paused else Input.MOUSE_MODE_CAPTURED

# --- магазин -----------------------------------------------------------------

func _build_shop() -> void:
	_shop = Shop.new()
	add_child(_shop)

	_money_label = _make_label("$800", 26, Color(0.55, 0.85, 0.5))
	_money_label.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	_money_label.position = Vector2(34, -130)
	add_child(_money_label)

func _on_money_changed(amount: int) -> void:
	_money_label.text = "$%d" % amount

## Клавиши магазина перехватываются здесь: пока он открыт, цифры покупают.
func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("buy"):
		if player != null and not player.is_dead():
			_shop.toggle()
		get_viewport().set_input_as_handled()
		return
	if not _shop.visible or not event is InputEventKey or not event.pressed or event.echo:
		return
	var key := event as InputEventKey
	var digit := key.physical_keycode - KEY_1
	if digit >= 0 and digit <= 8 and _shop.handle_digit(digit):
		get_viewport().set_input_as_handled()
