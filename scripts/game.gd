## Матч: строит карту, спавнит игрока и ботов, ведёт счёт и респавны.
##
## В сети Photon каждый владеет своим бойцом; фраг подтверждает владелец цели.
extends Node3D

signal score_changed(kills: int, deaths: int)
## Тип события задаёт та сторона, которая его знает: разбирать готовую строку
## по подстроке «Вы убили» на стороне HUD было бы хрупко.
signal killfeed(text: String, kind: int)

enum Feed { NEUTRAL, MINE, DEATH }

const PLAYER_SCENE := preload("res://scenes/player.tscn")
const BOT_SCENE := preload("res://scenes/bot.tscn")
const SpawnPicker := preload("res://scripts/spawn_picker.gd")

@export var bot_count: int = 8
@export var online: bool = true
@export var respawn_delay: float = 3.0
@export var bot_respawn_delay: float = 5.0
@export var match_seed: int = 20260920
@export var match_flow_enabled: bool = true

@onready var map: CityMap = $Map
@onready var actors: Node3D = $Actors
@onready var hud: Hud = $Hud

var player: PlayerCharacter
## Обычный Node, а не типизированный менеджер: его скрипт ссылается на классы
## GDExtension и не компилируется без установленного Photon SDK.
var net: Node
var kills: int = 0
var deaths: int = 0
var match_flow: Node
var _match_label: Label
var _round_frags: Dictionary = {}

var _rng := RandomNumberGenerator.new()

func _ready() -> void:
	# Режим и seed приходят из сессии: в сети карта должна собраться одинаковой
	# у всех, поэтому seed раздаёт хост, а не константа матча. Флаг считается
	# один раз и по факту живого соединения: если связь отвалилась между лобби и
	# матчем, матч должен быть полностью офлайновым, иначе точки оружия ждут
	# хоста, которого нет, а счёт пишется в узел без сетевой обвязки.
	online = Session.online and Session.is_online()
	if Session.match_seed != 0:
		match_seed = Session.match_seed
	print("[матч] режим=%s seed=%d ботов=%d" % [
		"сеть" if online else "офлайн", match_seed, 0 if online else bot_count])
	_rng.seed = match_seed
	map.build(match_seed)
	Effects.prewarm(self)
	var inventory := preload("res://scripts/world_inventory.gd").new()
	inventory.name = "WorldInventory"
	add_child(inventory)
	if match_flow_enabled:
		match_flow = preload("res://scripts/match_flow.gd").new()
		match_flow.name = "MatchFlow"
		add_child(match_flow)
		match_flow.phase_changed.connect(_on_match_phase)
		match_flow.configure(online, match_seed, _match_scores)
		_build_match_label()
	_spawn_pickups()

	if online:
		_bind_network()
		# В сети бойцов нет кроме живых игроков: бот был бы локальным у каждого
		# клиента, то есть невидимым для остальных, и счёт по нему бы разъезжался.
		# В сети своего бойца создаёт Photon — ждём сигнала о спавне.
		await net.begin_match(actors)
		return

	_spawn_player()
	_spawn_bots(bot_count)

func _process(_delta: float) -> void:
	if match_flow != null and _match_label != null:
		_match_label.text = match_flow.label()

func _build_match_label() -> void:
	_match_label = Label.new()
	_match_label.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	_match_label.position = Vector2(-400, 24)
	_match_label.size = Vector2(800, 35)
	_match_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_match_label.add_theme_font_size_override("font_size", 19)
	_match_label.add_theme_color_override("font_color", Hud.ACCENT)
	_match_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hud.add_child(_match_label)

func _on_match_phase(phase: int, _round: int) -> void:
	if phase == match_flow.Phase.ACTIVE or phase == match_flow.Phase.WARMUP:
		kills = 0
		deaths = 0
		_round_frags.clear()
		if is_instance_valid(player):
			if online:
				player.get_parent().frags = 0
				player.get_parent().deaths = 0
				player.get_parent().score_round = int(match_flow.snapshot.revision)
			player.respawn(_network_spawn(false))
			player.economy.reset()
		for bot in actors.get_children():
			if bot is Bot:
				bot.respawn(_safe_spawn(map.bot_spawns, bot))
		score_changed.emit(kills, deaths)
	if is_instance_valid(player):
		player.input_enabled = match_flow.allows_combat()
	for bot in actors.get_children():
		if bot is Bot:
			if not match_flow.allows_combat():
				bot.velocity = Vector3.ZERO
				CharacterModel.animate(bot._model_anim, Vector3.ZERO, false, bot.health.alive)
			bot.set_physics_process(match_flow.allows_combat())

func _scoring() -> bool:
	return match_flow == null or match_flow.scores_enabled()

func _match_scores() -> Dictionary:
	var rows: Dictionary = {}
	for actor in get_tree().get_nodes_in_group("combatants"):
		if not is_instance_valid(actor):
			continue
		var id := str(actor.get_instance_id())
		var frags := int(_round_frags.get(id, 0))
		if online and actor is PlayerCharacter:
			id = str(actor.peer_id)
			frags = int(actor.get_parent().get("frags"))
			if match_flow != null and int(actor.get_parent().score_round) != int(match_flow.snapshot.get("revision", 0)):
				frags = 0
		rows[id] = {"name": _name_of(actor), "frags": frags}
	return rows

func _record_frag(attacker: Node) -> void:
	if is_instance_valid(attacker):
		var id := str(attacker.get_instance_id())
		_round_frags[id] = int(_round_frags.get(id, 0)) + 1

## Сеть уже поднята сессией — матч только подписывается на её события.
func _bind_network() -> void:
	net = Session.net
	if not net.local_player_spawned.is_connected(_on_local_player_spawned):
		net.local_player_spawned.connect(_on_local_player_spawned)
	if not net.session_state.is_connected(_on_session_state):
		net.session_state.connect(_on_session_state)
	if not net.remote_player_spawned.is_connected(_on_remote_player_spawned):
		net.remote_player_spawned.connect(_on_remote_player_spawned)
	net.kill_confirmed.connect(_on_network_kill)
	if not net.death_announced.is_connected(_on_death_announced):
		net.death_announced.connect(_on_death_announced)

func _on_session_state(text: String) -> void:
	killfeed.emit(text, Feed.NEUTRAL)

## Чужой боец приезжает от Photon — сообщаем, что в бою есть кто-то живой.
func _on_remote_player_spawned(node: Node) -> void:
	var other: PlayerCharacter = node.get_node_or_null("Player") as PlayerCharacter
	if other == null:
		return
	other.add_to_group("combatants")
	print("[матч] в бою появился %s" % other.display_name)
	killfeed.emit("%s в бою" % other.display_name, Feed.NEUTRAL)

func _on_local_player_spawned(node: Node) -> void:
	player = node.get_node("Player") as PlayerCharacter
	player.respawn(_network_spawn(true))
	player.died.connect(_on_player_died)
	player.weapons.hit_confirmed.connect(_on_player_hit)
	player.input_enabled = match_flow == null or match_flow.allows_combat()
	if match_flow != null:
		player.get_parent().score_round = int(match_flow.snapshot.get("revision", 0))
	hud.bind(self, player)
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

# --- спавны ------------------------------------------------------------------

func _spawn_player() -> void:
	player = PLAYER_SCENE.instantiate() as PlayerCharacter
	player.display_name = Session.player_name
	player.team = 0
	player.add_to_group("combatants")
	actors.add_child(player)
	player.global_transform = _safe_spawn(map.player_spawns, player)
	player.died.connect(_on_player_died)
	player.weapons.hit_confirmed.connect(_on_player_hit)
	hud.bind(self, player)
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

func _spawn_bots(count: int) -> void:
	for i in count:
		var bot := BOT_SCENE.instantiate() as Bot
		bot.display_name = "Бот %d" % (i + 1)
		bot.team = 1
		bot.weapon_id = Weapons.random_id(WeaponData.Slot.PRIMARY)
		bot.add_to_group("combatants")
		actors.add_child(bot)
		# На старте боты расходятся по всем точкам карты, а не жмутся в один угол.
		bot.global_transform = _safe_spawn(map.bot_spawns, bot, i)
		bot.died.connect(_on_bot_died.bind(bot))

func _spawn_pickups() -> void:
	var ids := Weapons.ids()
	var pickups: Array[WeaponPickup] = []
	for point in map.weapon_spawns:
		var pickup := WeaponPickup.new()
		pickup.weapon_id = ids[_rng.randi() % ids.size()]
		pickup.network_index = pickups.size() if online else -1
		pickups.append(pickup)
		actors.add_child(pickup)
		pickup.global_position = point
	if online:
		Session.net.register_pickups(pickups)

## Prefer distance and world cover, checking the full standing capsule.
func _safe_spawn(points: Array[Transform3D], actor: Node3D, preferred: int = 0) -> Transform3D:
	var ordered: Array[Transform3D] = []
	for i in points.size():
		ordered.append(points[(i + preferred) % points.size()])
	var result := SpawnPicker.choose(self, ordered, actor, online)
	return result.transform if not result.is_empty() else actor.global_transform

# --- смерти и счёт -----------------------------------------------------------

func _on_player_died(attacker: Node) -> void:
	if _scoring():
		deaths += 1
		if online:
			player.get_parent().deaths = deaths
		elif attacker != player:
			_record_frag(attacker)
		player.economy.award_death()
	score_changed.emit(kills, deaths)
	killfeed.emit("%s убил вас" % _name_of(attacker), Feed.DEATH)
	get_tree().create_timer(respawn_delay).timeout.connect(_respawn_player)

func _respawn_player() -> void:
	if player == null or not is_instance_valid(player):
		return
	if player.health.alive or (match_flow != null and not match_flow.allows_combat()):
		return
	var at := _network_spawn(false)
	if not SpawnPicker.clear(get_world_3d().direct_space_state, at, player):
		get_tree().create_timer(0.5).timeout.connect(_respawn_player)
		return
	player.respawn(at)

func _network_spawn(initial: bool) -> Transform3D:
	var points: Array[Transform3D] = map.player_spawns.duplicate()
	points.append_array(map.bot_spawns)
	return _safe_spawn(points, player, maxi(player.peer_id - 1, 0) if initial else 0)

func _on_network_kill(victim_name: String, _headshot: bool) -> void:
	# Подтверждение может прийти раньше, чем Photon отдал нам своего бойца.
	if player == null or not is_instance_valid(player):
		return
	if not _scoring():
		return
	kills += 1
	player.get_parent().frags = kills
	score_changed.emit(kills, deaths)
	killfeed.emit("Вы убили %s" % victim_name, Feed.MINE)

## Своё убийство уже показал kill_confirmed, поэтому строки от своего имени
## пропускаем. Тёзки в одной комнате потеряют одну строку — терпимо, имена в
## Photon не уникальны и сравнивать больше нечего.
func _on_death_announced(victim_name: String, killer_name: String, headshot: bool) -> void:
	if player != null and is_instance_valid(player) and killer_name == player.display_name:
		return
	killfeed.emit("%s убил %s%s" % [killer_name, victim_name, " в голову" if headshot else ""], Feed.NEUTRAL)

func _on_bot_died(attacker: Node, bot: Bot) -> void:
	if _scoring() and attacker != bot:
		_record_frag(attacker)
	if attacker == player and _scoring():
		kills += 1
		score_changed.emit(kills, deaths)
		killfeed.emit("Вы убили %s" % bot.display_name, Feed.MINE)
	else:
		killfeed.emit("%s убил %s" % [_name_of(attacker), bot.display_name], Feed.NEUTRAL)
	get_tree().create_timer(bot_respawn_delay).timeout.connect(_respawn_bot.bind(bot))

func _respawn_bot(bot: Bot) -> void:
	if not is_instance_valid(bot) or bot.health.alive or (match_flow != null and not match_flow.allows_combat()):
		return
	var at := _safe_spawn(map.bot_spawns, bot)
	if not SpawnPicker.clear(get_world_3d().direct_space_state, at, bot):
		get_tree().create_timer(0.5).timeout.connect(_respawn_bot.bind(bot))
		return
	bot.respawn(at)

func _name_of(node: Node) -> String:
	if node == null or not is_instance_valid(node):
		return "Мир"
	var label = node.get("display_name")
	var text: String = str(label) if label != null else String(node.name)
	# Имя чужого бойца реплицируется его клиентом: при показе режем длину.
	return text.substr(0, 24)

## Деньги начисляются за фактическое убийство, а не за факт смерти цели:
## так добивание чужой цели не оплачивается.
func _on_player_hit(headshot: bool, killed: bool) -> void:
	if killed and player != null and _scoring():
		player.economy.award_kill(headshot)
