## Матч: строит карту, спавнит игрока и ботов, ведёт счёт и респавны.
##
## Мультиплеер: вся логика уже разделена на "решает сервер" (спавны, счёт,
## урон) и "показывает клиент" (HUD, эффекты). Чтобы включить сеть, останется
## поднять ENetMultiplayerPeer и повесить MultiplayerSpawner на контейнер Actors.
extends Node3D

signal score_changed(kills: int, deaths: int)
signal killfeed(text: String)

const PLAYER_SCENE := preload("res://scenes/player.tscn")
const BOT_SCENE := preload("res://scenes/bot.tscn")

@export var bot_count: int = 8
@export var respawn_delay: float = 3.0
@export var bot_respawn_delay: float = 5.0
@export var match_seed: int = 20260920

@onready var map: CityMap = $Map
@onready var actors: Node3D = $Actors
@onready var hud: Hud = $Hud

var player: PlayerCharacter
var kills: int = 0
var deaths: int = 0

var _rng := RandomNumberGenerator.new()

func _ready() -> void:
	_rng.seed = match_seed
	map.build(match_seed)
	_spawn_player()
	_spawn_bots()
	_spawn_pickups()
	hud.bind(self, player)

func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		hud.toggle_pause()

# --- спавны ------------------------------------------------------------------

func _spawn_player() -> void:
	player = PLAYER_SCENE.instantiate() as PlayerCharacter
	player.display_name = "Вы"
	player.team = 0
	player.add_to_group("combatants")
	actors.add_child(player)
	player.global_transform = _pick(map.player_spawns)
	player.died.connect(_on_player_died)

func _spawn_bots() -> void:
	for i in bot_count:
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
	for point in map.weapon_spawns:
		var pickup := WeaponPickup.new()
		pickup.weapon_id = Weapons.random_id()
		actors.add_child(pickup)
		pickup.global_position = point

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
	score_changed.emit(kills, deaths)
	killfeed.emit("%s убил вас" % _name_of(attacker))
	get_tree().create_timer(respawn_delay).timeout.connect(_respawn_player)

func _respawn_player() -> void:
	if player == null or not is_instance_valid(player):
		return
	player.respawn(_pick(map.player_spawns))

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
