## Владелец симулирует бойца; остальные отображают полученное состояние.
class_name NetPlayer
extends Node3D

@onready var replicator: FusionSharedReplicator = $Replicator
@onready var player: PlayerCharacter = $Player

var weapon_id: String = "ak47"
var net_health: float = 100.0
var net_armor: float = 50.0
var net_alive: bool = true
var life_serial: int = 0
var frags: int = 0
var deaths: int = 0
var _credited_life: int = -1
var _shown_weapon: String = ""
var _world_weapon: Node3D
var _remote_life: int = -1
var _hand_skeleton: Skeleton3D
var _hand_bone: int = -1

func _ready() -> void:
	replicator.authority_changed.connect(_on_authority_changed)
	replicator.spawned.connect(configure_owner)
	player.health.changed.connect(_publish_health)
	player.respawned.connect(_on_respawned)
	player.weapons.weapon_changed.connect(_on_weapon_changed)
	player.weapons.shot_fired.connect(_on_shot)
	configure_owner()

func configure_owner() -> void:
	player.peer_id = Fusion.get_local_player_id() if replicator.has_authority() else replicator.get_owner_id()
	player.configure_control(replicator.has_authority())
	player.add_to_group("combatants")
	player.team = player.peer_id
	if player.local_control:
		player.display_name = Session.player_name
		_publish_health(player.health.health, player.health.armor)
		if _world_weapon != null:
			_world_weapon.visible = false
	else:
		_update_remote()

func _on_authority_changed(_mine: bool) -> void:
	configure_owner()

func _process(_delta: float) -> void:
	if not player.local_control:
		_update_remote()

func _update_remote() -> void:
	player.health.health = net_health
	player.health.armor = net_armor
	player.health.alive = net_alive
	player.update_life_visuals()
	if _remote_life != life_serial:
		_remote_life = life_serial
		# Респавн не должен интерполироваться сквозь всю карту.
		if replicator.has_shadow_data():
			replicator.reset_state()
	if _shown_weapon != weapon_id:
		_build_world_weapon()
	if _world_weapon != null:
		_world_weapon.visible = net_alive
		if _hand_skeleton != null and _hand_bone >= 0:
			var hand: Transform3D = _hand_skeleton.global_transform * _hand_skeleton.get_bone_global_pose(_hand_bone)
			_world_weapon.global_position = hand.origin

func _publish_health(hp: float, armor: float) -> void:
	if not replicator.has_authority():
		return
	net_health = hp
	net_armor = armor
	net_alive = hp > 0.0

func _on_respawned() -> void:
	if replicator.has_authority():
		life_serial += 1

func _on_weapon_changed(data: WeaponData) -> void:
	if replicator.has_authority():
		weapon_id = String(data.id)

## Sender берём из транспорта, а номер жизни отсекает урон до респавна.
@rpc("any_peer", "call_remote", "reliable")
func apply_remote_damage(amount: float, headshot: bool, penetration: float, target_life: int) -> void:
	if not replicator.has_authority() or not player.health.alive or target_life != life_serial:
		return
	var attacker_id: int = Fusion.get_rpc_sender()
	var attacker := _find_player(attacker_id)
	if attacker == null or attacker == player or not attacker.health.alive:
		return
	if not is_finite(amount) or amount <= 0.0 or amount > 1000.0 or not is_finite(penetration):
		return
	var dealt := player.health.take_damage(amount, attacker, headshot, clampf(penetration, 0.0, 1.0))
	if dealt > 0.0:
		Fusion.rpc(confirm_hit, attacker_id, headshot, not player.health.alive, life_serial)

@rpc("authority", "call_remote", "reliable")
func confirm_hit(attacker_id: int, headshot: bool, killed: bool, victim_life: int) -> void:
	if Fusion.get_rpc_sender() != replicator.get_owner_id():
		return
	var attacker := _find_player(attacker_id)
	if attacker == null or not attacker.local_control:
		return
	if killed:
		if victim_life <= _credited_life:
			return
		_credited_life = victim_life
		Session.net.kill_confirmed.emit(player.display_name, headshot)
	Sfx.play_2d(&"headshot" if headshot else &"hit", 1.0, -4.0)
	attacker.weapons.hit_confirmed.emit(headshot, killed)

func _on_shot(id: String, origin: Vector3, end: Vector3) -> void:
	if replicator.has_authority() and Fusion.is_in_room():
		Fusion.rpc(show_shot, id, origin, end)

@rpc("authority", "call_remote", "unreliable")
func show_shot(id: String, origin: Vector3, end: Vector3) -> void:
	if Fusion.get_rpc_sender() != replicator.get_owner_id() or player.local_control:
		return
	var data := Weapons.get_weapon(StringName(id))
	if data == null or not origin.is_finite() or not end.is_finite():
		return
	Sfx.play_shot(data.id, origin, data.shot_pitch)
	Effects.tracer(get_tree().current_scene, origin, end)
	if _world_weapon != null:
		Effects.muzzle_flash(_world_weapon, Vector3(0, 0, -data.length))

func _find_player(id: int) -> PlayerCharacter:
	for node in get_tree().get_nodes_in_group("combatants"):
		if node is PlayerCharacter and node.peer_id == id:
			return node
	return null

func _build_world_weapon() -> void:
	_shown_weapon = weapon_id
	if _world_weapon != null:
		_world_weapon.free()
	_world_weapon = Node3D.new()
	player.head.add_child(_world_weapon)
	_world_weapon.position = Vector3(0.24, -0.38, -0.28)
	if _hand_skeleton == null and player._body_model != null:
		for node in CharacterModel._walk(player._body_model):
			if node is Skeleton3D:
				_hand_skeleton = node
				_hand_bone = node.find_bone("RightHand")
				break
	var data := Weapons.get_weapon(StringName(weapon_id))
	if data == null or not ResourceLoader.exists(data.model_path):
		return
	var holder := Node3D.new()
	_world_weapon.add_child(holder)
	var model := (load(data.model_path) as PackedScene).instantiate() as Node3D
	holder.add_child(model)
	ViewModel.fit(holder, model, data)
	# Масштаб первого лица намеренно увеличен; в мире размер задаёт длина ствола.
	holder.scale /= maxf(data.model_scale, 0.001)
	holder.position /= maxf(data.model_scale, 0.001)
	holder.position.z -= data.length * 0.2
