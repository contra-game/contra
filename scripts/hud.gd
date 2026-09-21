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
var _scope: ScopeOverlay
var _money_label: Label
var _paused: bool = false
var _respawn_left: float = 0.0
var _scoreboard: PanelContainer
var _score_rows: Label
var _score_refresh: float = 0.0
var _interaction_label: Label
var _reload_bar: ProgressBar
var _damage_indicator: Control
var _slots_label: Label
var _sensitivity_label: Label
var _ping_label: Label
var _ping_refresh: float = 0.0

func _ready() -> void:
	layer = 10
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build_crosshair()
	_build_status()
	_build_killfeed()
	_build_center()
	_build_pause()
	_build_shop()
	_scope = ScopeOverlay.new()
	add_child(_scope)
	_damage_indicator = Control.new()
	_damage_indicator.set_script(preload("res://scripts/damage_indicator.gd"))
	_damage_indicator.set_anchors_preset(Control.PRESET_FULL_RECT)
	_damage_indicator.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_damage_indicator)
	_build_scoreboard()

func bind(game_node: Node, player_node: PlayerCharacter) -> void:
	game = game_node
	player = player_node
	_damage_indicator.camera = player.camera

	player.health.changed.connect(_on_health_changed)
	player.died.connect(_on_player_died)
	player.respawned.connect(_on_player_respawned)
	player.weapons.ammo_changed.connect(_on_ammo_changed)
	player.weapons.weapon_changed.connect(_on_weapon_changed)
	player.weapons.spread_changed.connect(_crosshair.set_spread)
	player.weapons.hit_confirmed.connect(_on_hit_confirmed)
	player.weapons.scope_changed.connect(_on_scope_changed)
	player.health.damaged.connect(_on_damaged)

	_shop.bind(player_node, player_node.economy)
	player.economy.money_changed.connect(_on_money_changed)
	_on_money_changed(player.economy.money)
	game.score_changed.connect(_on_score_changed)
	game.killfeed.connect(push_killfeed)

	_on_health_changed(player.health.health, player.health.armor)
	_on_score_changed(0, 0)
	_on_weapon_changed(player.weapons.current_data())
	var slot := player.weapons.current()
	_on_ammo_changed(slot.mag, slot.reserve)

func _process(delta: float) -> void:
	_update_ping(delta)
	_scoreboard.visible = Input.is_action_pressed("scoreboard") and not _paused
	_score_refresh -= delta
	if _scoreboard.visible and _score_refresh <= 0.0:
		_score_refresh = 0.25
		_refresh_scoreboard()
	if _respawn_left > 0.0:
		_respawn_left = maxf(_respawn_left - delta, 0.0)
		_center_label.text = "Вы убиты\nВозрождение через %.1f" % _respawn_left
	_damage_flash.modulate.a = lerpf(_damage_flash.modulate.a, 0.0, delta * 3.5)
	if player != null and player.weapons != null:
		_update_slots()
		_crosshair.set_fov(player.camera.fov)
		_crosshair.set_reticle_alpha(1.0 - smoothstep(0.35, 0.9, player.weapons.ads_blend))
		var combat_ui := player.health.alive and not _paused and not player.shop_open
		_hint_label.visible = combat_ui and player.weapons.reloading
		_hint_label.text = "ПЕРЕЗАРЯДКА · %.1f с" % player.weapons._reload_left
		var data := player.weapons.current_data()
		if player.weapons.reloading and data != null and data.reload_per_shell:
			_hint_label.text = "ЗАРЯДКА · ЛКМ — прервать"
		elif combat_ui and not player.weapons.reloading:
			var slot := player.weapons.current()
			if not slot.is_empty() and slot.mag <= 0:
				_hint_label.visible = true
				_hint_label.text = "[R] Перезарядить" if slot.reserve > 0 else "Нет патронов · [1–4] Сменить оружие"
		_reload_bar.visible = combat_ui and player.weapons.reloading
		_reload_bar.value = player.weapons.reload_progress()
		_interaction_label.text = player.interaction_hint
		_interaction_label.visible = combat_ui and not player.interaction_hint.is_empty()
		_damage_indicator.visible = combat_ui

## Цвет важнее цифры: зелёный — играбельно, красный — стрелять с упреждением.
func _update_ping(delta: float) -> void:
	if not Session.online:
		_ping_label.visible = false
		return
	_ping_refresh -= delta
	if _ping_refresh > 0.0:
		return
	_ping_refresh = 0.5
	var ping := int(NetApi.rtt() * 1000.0)
	_ping_label.visible = true
	_ping_label.text = "%d мс" % ping
	var color := Color(0.5, 0.85, 0.5)
	if ping > 120:
		color = DANGER
	elif ping > 60:
		color = ACCENT
	_ping_label.add_theme_color_override("font_color", color)

func _on_sensitivity_changed(value: float) -> void:
	Session.set_mouse_sensitivity(value)
	_sensitivity_label.text = "Чувствительность мыши — %.2f×" % Session.mouse_sensitivity

func _update_slots() -> void:
	if _slots_label == null:
		_slots_label = _make_label("", 16, Color(0.8, 0.83, 0.86))
		_slots_label.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
		_slots_label.position = Vector2(-450, -175)
		_slots_label.custom_minimum_size.x = 415
		_slots_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		_slots_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(_slots_label)
	var lines: Array[String] = []
	for index in player.weapons.SLOT_COUNT:
		var slot = player.weapons.slots[index]
		var label: String = slot.data.display_name if slot != null else "—"
		lines.append("%s%d %s" % ["› " if index == player.weapons.current_slot else "", index + 1, label])
	_slots_label.text = "   ".join(lines.slice(0, 2)) + "\n" + "   ".join(lines.slice(2)) + "\n[G] Выбросить · [E] Подобрать"
	_slots_label.visible = player.health.alive and not _paused and not player.shop_open
	if player.weapons.current_data() != null and player.weapons.current_data().slot == WeaponData.Slot.MELEE:
		_ammo_label.text = "БЛИЖНИЙ БОЙ"

func _build_scoreboard() -> void:
	_scoreboard = PanelContainer.new()
	_scoreboard.set_anchors_preset(Control.PRESET_CENTER)
	_scoreboard.position = Vector2(-280, -160)
	_scoreboard.custom_minimum_size = Vector2(560, 240)
	_scoreboard.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_scoreboard.visible = false
	add_child(_scoreboard)
	_score_rows = _make_label("", 24, Color.WHITE)
	_score_rows.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_scoreboard.add_child(_score_rows)

func _refresh_scoreboard() -> void:
	var rows: Array[String] = []
	if Session.online:
		rows.append("%s  •  %d игроков  •  %d мс" % [
			Session.room_name, Session.players().size(), int(NetApi.rtt() * 1000.0)])
		rows.append("ИГРОК                         ФРАГИ / СМЕРТИ")
		for actor in get_tree().get_nodes_in_group("combatants"):
			if not actor is PlayerCharacter:
				continue
			# Обвязку узнаём по методу, а не по классу: её скрипт не существует
			# без Photon SDK, а табло должно открываться и офлайн.
			var wrapper: Node = actor.get_parent()
			if wrapper == null or not wrapper.has_method("apply_remote_damage"):
				continue
			rows.append("%s%s        %d / %d" % [
				actor.display_name.substr(0, 24), " (вы)" if actor.local_control else "",
				wrapper.frags, wrapper.deaths])
	elif game != null:
		rows.append("Тренировка\n%s        %d / %d" % [Session.player_name, game.kills, game.deaths])
	_score_rows.text = "\n\n".join(rows)

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

	# Пинг на виду, а не только по Tab: «лагает или я мажу» решается взглядом.
	_ping_label = _make_label("", 16, Color(0.5, 0.85, 0.5))
	_ping_label.set_anchors_preset(Control.PRESET_TOP_LEFT)
	_ping_label.position = Vector2(34, 54)
	_ping_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_ping_label.visible = false
	add_child(_ping_label)

	_hint_label = _make_label("ПЕРЕЗАРЯДКА", 22, ACCENT)
	_hint_label.set_anchors_preset(Control.PRESET_CENTER)
	_hint_label.position = Vector2(-260, 70)
	_hint_label.custom_minimum_size.x = 520
	_hint_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hint_label.visible = false
	add_child(_hint_label)
	_reload_bar = ProgressBar.new()
	_reload_bar.set_anchors_preset(Control.PRESET_CENTER)
	_reload_bar.position = Vector2(-90, 103)
	_reload_bar.size = Vector2(180, 5)
	_reload_bar.max_value = 1.0
	_reload_bar.show_percentage = false
	var track := StyleBoxFlat.new()
	track.bg_color = Color(0.08, 0.1, 0.13, 0.8)
	var fill := StyleBoxFlat.new()
	fill.bg_color = ACCENT
	_reload_bar.add_theme_stylebox_override("background", track)
	_reload_bar.add_theme_stylebox_override("fill", fill)
	_reload_bar.size = Vector2(180, 5)
	_reload_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_reload_bar.visible = false
	add_child(_reload_bar)
	_interaction_label = _make_label("", 22, ACCENT)
	_interaction_label.set_anchors_preset(Control.PRESET_CENTER)
	_interaction_label.position = Vector2(-300, 130)
	_interaction_label.custom_minimum_size.x = 600
	_interaction_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_interaction_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_interaction_label)

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
	_pause_panel.custom_minimum_size = Vector2(340, 300)
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

	_sensitivity_label = _make_label("", 15, Color(0.78, 0.8, 0.84))
	_sensitivity_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(_sensitivity_label)
	var sensitivity := HSlider.new()
	sensitivity.min_value = Session.SENSITIVITY_MIN
	sensitivity.max_value = Session.SENSITIVITY_MAX
	sensitivity.step = 0.05
	sensitivity.value = Session.mouse_sensitivity
	sensitivity.custom_minimum_size.x = 300
	# Игрок видит результат, пока тянет; в файл значение уходит по отпусканию
	# ручки и при закрытии паузы — запись на каждый пиксель движения не нужна.
	sensitivity.value_changed.connect(_on_sensitivity_changed)
	sensitivity.drag_ended.connect(func(changed: bool) -> void:
		if changed:
			Session.save_settings())
	box.add_child(sensitivity)
	_on_sensitivity_changed(Session.mouse_sensitivity)

	var resume := Button.new()
	resume.text = "Продолжить"
	resume.pressed.connect(toggle_pause)
	box.add_child(resume)

	var to_menu := Button.new()
	to_menu.text = "Выйти в меню"
	to_menu.pressed.connect(func() -> void:
		get_tree().paused = false
		Session.to_menu())
	box.add_child(to_menu)

	var quit := Button.new()
	quit.text = "Выйти из игры"
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

func _on_damaged(_amount: float, attacker: Node, _headshot: bool) -> void:
	_damage_flash.modulate.a = 1.0
	if is_instance_valid(attacker) and attacker is Node3D:
		_damage_indicator.show_damage(attacker.global_position)

func _on_player_died(_attacker: Node) -> void:
	_shop.close()
	_respawn_left = game.respawn_delay if game != null else 3.0
	_crosshair.visible = false

func _on_player_respawned() -> void:
	_respawn_left = 0.0
	_center_label.text = ""
	_crosshair.visible = true
	_damage_indicator.time_left = 0.0
	_damage_indicator.queue_redraw()
	_damage_flash.modulate.a = 0.0

## Метка едет внутри обёртки, а не сама по себе: VBoxContainer переписывает
## position своих детей каждый кадр, и анимация сдвига уехала бы в никуда.
func push_killfeed(text: String, kind: int = 0) -> void:
	var color := Color(0.86, 0.88, 0.9)
	if kind == 1:
		color = ACCENT
	elif kind == 2:
		color = DANGER
	var label := _make_label(text, 16, color)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	label.size.x = 400
	var row := Control.new()
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.clip_contents = true
	row.add_child(label)
	label.position.x = 60
	label.modulate.a = 0.0
	_killfeed.add_child(row)
	# Высота меряется после входа в дерево: до этого тема ещё не применена.
	row.custom_minimum_size = Vector2(400, label.get_minimum_size().y)
	# Твин, который гасит строку, держит на неё ссылку; немедленный free()
	# оставляет твин с освобождённой целью. Снимаем с дерева сразу, чтобы лишняя
	# строка не участвовала в подсчёте до конца кадра.
	while _killfeed.get_child_count() > 5:
		var oldest := _killfeed.get_child(0)
		_killfeed.remove_child(oldest)
		oldest.queue_free()
	var tween := create_tween()
	tween.set_parallel(true)
	tween.tween_property(label, "position:x", 0.0, 0.22).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tween.tween_property(label, "modulate:a", 1.0, 0.16)
	tween.set_parallel(false)
	tween.tween_interval(4.5)
	tween.tween_property(label, "modulate:a", 0.0, 0.6)
	tween.tween_callback(func() -> void:
		if is_instance_valid(row):
			row.queue_free())

func toggle_pause() -> void:
	_shop.close()
	_paused = not _paused
	_pause_panel.visible = _paused
	# Ползунок двигают и клавишами — drag_ended тогда не приходит.
	if not _paused:
		Session.save_settings()
	get_tree().paused = _paused and not Session.online
	if player != null:
		player.input_enabled = not _paused
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
	if event.is_action_pressed("ui_cancel"):
		if _shop.visible:
			_shop.close()
		else:
			toggle_pause()
		get_viewport().set_input_as_handled()
		return
	if _paused:
		return
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

## Обычный прицел затухает через reticle_alpha; хитмаркер остаётся и в оптике.
func _on_scope_changed(active: bool) -> void:
	_scope.visible = active
	_crosshair.visible = player != null and not player.is_dead()
	if active:
		_scope.queue_redraw()
