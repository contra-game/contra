## Матч: строит карту, спавнит игрока и ботов, ведёт счёт и респавны.
##
## В сети Photon каждый владеет своим бойцом; фраг подтверждает владелец цели.
extends Node3D

signal score_changed(kills: int, deaths: int)
signal killfeed(text: String)

const PLAYER_SCENE := preload("res://scenes/player.tscn")
const BOT_SCENE := preload("res://scenes/bot.tscn")

@export var bot_count: int = 8
@export var online: bool = true
@export var respawn_delay: float = 3.0
@export var bot_respawn_delay: float = 5.0
@export var match_seed: int = 20260920

@onready var map: CityMap = $Map
@onready var actors: Node3D = $Actors
@onready var hud: Hud = $Hud

var player: PlayerCharacter
## Обычный Node, а не типизированный менеджер: его скрипт ссылается на классы
## GDExtension и не компилируется без установленного Photon SDK.
var net: Node
var kills: int = 0
var deaths: int = 0

var _rng := RandomNumberGenerator.new()

func _ready() -> void:
	# Режим и seed приходят из сессии: в сети карта должна собраться одинаковой
	# у всех, поэтому seed раздаёт хост, а не константа матча.
	online = Session.online
	if Session.match_seed != 0:
		match_seed = Session.match_seed
	print("[матч] режим=%s seed=%d ботов=%d" % [
		"сеть" if online else "офлайн", match_seed, 0 if online else bot_count])
	_rng.seed = match_seed
	map.build(match_seed)
	_spawn_pickups()

	if online and Session.is_online():
		_bind_network()
		# В сети бойцов нет кроме живых игроков: бот был бы локальным у каждого
		# клиента, то есть невидимым для остальных, и счёт по нему бы разъезжался.
		# В сети своего бойца создаёт Photon — ждём сигнала о спавне.
		await net.begin_match(actors)
		return

	_spawn_player()
	_spawn_bots(bot_count)

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

func _on_session_state(text: String) -> void:
	killfeed.emit(text)

## Чужой боец приезжает от Photon — сообщаем, что в бою есть кто-то живой.
func _on_remote_player_spawned(node: Node) -> void:
	var other: PlayerCharacter = node.get_node_or_null("Player") as PlayerCharacter
	if other == null:
		return
	other.add_to_group("combatants")
	print("[матч] в бою появился %s" % other.display_name)
	killfeed.emit("%s в бою" % other.display_name)

func _on_local_player_spawned(node: Node) -> void:
	player = node.get_node("Player") as PlayerCharacter
	player.respawn(_network_spawn(true))
	player.died.connect(_on_player_died)
	player.weapons.hit_confirmed.connect(_on_player_hit)
	hud.bind(self, player)

# --- спавны ------------------------------------------------------------------

func _spawn_player() -> void:
	player = PLAYER_SCENE.instantiate() as PlayerCharacter
	player.display_name = Session.player_name
	player.team = 0
	player.add_to_group("combatants")
	actors.add_child(player)
	player.global_transform = _pick(map.player_spawns)
	player.died.connect(_on_player_died)
	player.weapons.hit_confirmed.connect(_on_player_hit)
	hud.bind(self, player)

func _spawn_bots(count: int) -> void:
	for i in count:
		var bot := BOT_SCENE.instantiate() as Bot
		bot.display_name = "Бот %d" % (i + 1)
		bot.team = 1
		bot.weapon_id = Weapons.random_id(WeaponData.Slot.PRIMARY)
		bot.add_to_group("combatants")
		actors.add_child(bot)
		# На старте боты расходятся по всем точкам карты, а не жмутся в один угол.
		bot.global_transform = _spread_spawn(i)
		bot.died.connect(_on_bot_died.bind(bot))

func _spread_spawn(index: int) -> Transform3D:
	if map.bot_spawns.is_empty():
		return Transform3D.IDENTITY
	var point: Transform3D = map.bot_spawns[index % map.bot_spawns.size()]
	point.origin += Vector3(_rng.randf_range(-2.0, 2.0), 0.0, _rng.randf_range(-2.0, 2.0))
	return point

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

## Респавн: не в упор к игроку, но и не обязательно в дальнем углу —
## иначе бой каждый раз начинается с долгой пробежки.
const SAFE_RESPAWN_DISTANCE := 25.0

func _spawn_away_from_player(points: Array[Transform3D]) -> Transform3D:
	if points.is_empty():
		return Transform3D.IDENTITY
	if player == null:
		return _pick(points)
	var best := points[0]
	var best_distance := -1.0
	for i in 6:
		var candidate: Transform3D = points[_rng.randi() % points.size()]
		var distance := candidate.origin.distance_to(player.global_position)
		if distance >= SAFE_RESPAWN_DISTANCE:
			best = candidate
			break
		if distance > best_distance:
			best_distance = distance
			best = candidate
	# Небольшой разброс, чтобы боты не появлялись строго в одной точке.
	best.origin += Vector3(_rng.randf_range(-2.0, 2.0), 0.0, _rng.randf_range(-2.0, 2.0))
	return best

func _pick(points: Array[Transform3D]) -> Transform3D:
	if points.is_empty():
		return Transform3D.IDENTITY
	return points[_rng.randi() % points.size()]

# --- смерти и счёт -----------------------------------------------------------

func _on_player_died(attacker: Node) -> void:
	deaths += 1
	if online:
		player.get_parent().deaths = deaths
	player.economy.award_death()
	score_changed.emit(kills, deaths)
	killfeed.emit("%s убил вас" % _name_of(attacker))
	get_tree().create_timer(respawn_delay).timeout.connect(_respawn_player)

func _respawn_player() -> void:
	if player == null or not is_instance_valid(player):
		return
	player.respawn(_network_spawn(false) if online else _pick(map.player_spawns))

func _network_spawn(initial: bool) -> Transform3D:
	var points: Array[Transform3D] = map.player_spawns.duplicate()
	points.append_array(map.bot_spawns)
	if points.is_empty():
		return Transform3D.IDENTITY
	if initial:
		var preferred: Transform3D = points[(maxi(player.peer_id, 1) - 1) % points.size()]
		var occupied := false
		for other in get_tree().get_nodes_in_group("combatants"):
			if other != player and not other.is_dead() and other.global_position.distance_to(preferred.origin) < 4.0:
				occupied = true
		if not occupied:
			return preferred
	var best := points[0]
	var best_distance := -1.0
	for point in points:
		var nearest := INF
		for other in get_tree().get_nodes_in_group("combatants"):
			if other != player and not other.is_dead():
				nearest = minf(nearest, point.origin.distance_to(other.global_position))
		if nearest > best_distance:
			best_distance = nearest
			best = point
	return best

func _on_network_kill(victim_name: String, _headshot: bool) -> void:
	kills += 1
	player.get_parent().frags = kills
	score_changed.emit(kills, deaths)
	killfeed.emit("Вы убили %s" % victim_name)

func _on_bot_died(attacker: Node, bot: Bot) -> void:
	if attacker == player:
		kills += 1
		score_changed.emit(kills, deaths)
		killfeed.emit("Вы убили %s" % bot.display_name)
	else:
		killfeed.emit("%s убил %s" % [_name_of(attacker), bot.display_name])
	get_tree().create_timer(bot_respawn_delay).timeout.connect(func() -> void:
		if is_instance_valid(bot):
			bot.respawn(_spawn_away_from_player(map.bot_spawns)))

func _name_of(node: Node) -> String:
	if node == null or not is_instance_valid(node):
		return "Мир"
	var label = node.get("display_name")
	return str(label) if label != null else node.name

## Деньги начисляются за фактическое убийство, а не за факт смерти цели:
## так добивание чужой цели не оплачивается.
func _on_player_hit(headshot: bool, killed: bool) -> void:
	if killed and player != null:
		player.economy.award_kill(headshot)
