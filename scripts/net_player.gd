## Владелец симулирует бойца; остальные отображают полученное состояние.
##
## class_name намеренно нет: файл ссылается на классы GDExtension и живёт
## только вместе с поднятым Photon SDK.
extends Node3D

@onready var replicator: FusionSharedReplicator = $Replicator
@onready var player: PlayerCharacter = $Player

var weapon_id: String = "ak47"
var inventory_manifest: String = "[]"
var _inventory_timer: float = 0.0
var net_health: float = 100.0
var net_armor: float = 50.0
var net_alive: bool = true
var life_serial: int = 0
var frags: int = 0
var score_round: int = 0
var deaths: int = 0
var death_push := Vector3.ZERO
var _credited_life: int = -1
var _shown_weapon: String = ""
var _world_weapon: Node3D
var _world_muzzle: Marker3D
var _remote_life: int = -1
var _last_headshot: bool = false
var _footstep_position := Vector3.INF
var _footstep_distance: float = 0.0
var _grenade_life: int = -1
var _grenades_seen: int = 0
var _equipment_budget := RateLimiter.new(3.0, 4.0)
var _throw_serial: int = 0
var _grenade_visuals: Dictionary = {}

# Бюджеты входящих RPC. Самый частый законный случай — M4A1 на 720 выстрелов в
# минуту, то есть 12 пакетов в секунду; 20/с с запасом 30 покрывают его вместе
# с залпом дроби и догоняющими пакетами после лага.
var _damage_budget := RateLimiter.new(20.0, 30.0)
var _shot_budget := RateLimiter.new(20.0, 30.0)

func _ready() -> void:
	replicator.authority_changed.connect(_on_authority_changed)
	replicator.spawned.connect(configure_owner)
	player.health.changed.connect(_publish_health)
	player.respawned.connect(_on_respawned)
	player.weapons.weapon_changed.connect(_on_weapon_changed)
	player.weapons.ammo_changed.connect(func(_mag, _reserve): _publish_inventory())
	player.weapons.shot_fired.connect(_on_shot)
	player.weapons.equipment_used.connect(_on_equipment)
	player.died.connect(_on_local_died)
	player.health.damaged.connect(_on_local_damaged)
	configure_owner()

func configure_owner() -> void:
	player.peer_id = NetApi.local_player_id() if replicator.has_authority() else replicator.get_owner_id()
	player.configure_control(replicator.has_authority())
	player.add_to_group("combatants")
	player.team = player.peer_id
	if player.local_control:
		player.display_name = Session.player_name
		_publish_health(player.health.health, player.health.armor)
		_publish_inventory()
		if _world_weapon != null:
			_world_weapon.visible = false
	else:
		_update_remote()

func _on_authority_changed(_mine: bool) -> void:
	configure_owner()

func _process(_delta: float) -> void:
	if not player.local_control:
		_update_remote()
		_remote_footsteps()
		for key in _grenade_visuals.keys():
			if NetApi.network_time() - float(_grenade_visuals[key].time) > 4.5:
				_grenade_visuals.erase(key)
	else:
		_inventory_timer -= _delta
		if _inventory_timer <= 0.0:
			_inventory_timer = 0.1
			_publish_inventory()

func _publish_inventory() -> void:
	if not replicator.has_authority():
		return
	var snapshot: Array = []
	for slot in player.weapons.slots:
		if slot != null:
			snapshot.append([String(slot.data.id), slot.mag, slot.reserve])
	var inventory := get_tree().get_first_node_in_group("world_inventory")
	if inventory != null:
		for key in inventory.pending:
			var drop: Dictionary = inventory.pending[key]
			snapshot.append([drop.weapon, drop.mag, drop.reserve, key])
	inventory_manifest = JSON.stringify(snapshot)

func _remote_footsteps() -> void:
	if _footstep_position.is_finite():
		var distance := Vector2(player.global_position.x - _footstep_position.x, player.global_position.z - _footstep_position.z).length()
		if net_alive and not player.combat_airborne and distance < 1.5:
			_footstep_distance += distance
		else:
			_footstep_distance = 0.0
		if _footstep_distance >= 1.8:
			_footstep_distance = 0.0
			Sfx.play_footstep(player)
	_footstep_position = player.global_position

func _update_remote() -> void:
	if player.health.alive and not net_alive:
		player.spawn_death_ragdoll(death_push)
	if net_health < player.health.health and net_alive:
		var motion = CharacterModel.motion(player._body_model)
		if motion != null:
			motion.hit(player.health.health - net_health)
	player.health.health = net_health
	player.health.armor = net_armor
	player.health.alive = net_alive
	player.update_life_visuals()
	if _remote_life != life_serial:
		_remote_life = life_serial
		var motion = CharacterModel.motion(player._body_model)
		if motion != null:
			motion.reset_motion()
		# Респавн не должен интерполироваться сквозь всю карту.
		if replicator.has_shadow_data():
			replicator.reset_state()
	if _shown_weapon != weapon_id:
		_build_world_weapon()
	if _world_weapon != null:
		_world_weapon.visible = net_alive

func _publish_health(hp: float, armor: float) -> void:
	if not replicator.has_authority():
		return
	net_health = hp
	net_armor = armor
	net_alive = hp > 0.0

func _on_respawned() -> void:
	if replicator.has_authority():
		life_serial += 1

func _on_local_damaged(_amount: float, _attacker: Node, headshot: bool) -> void:
	_last_headshot = headshot
	death_push = (player.global_position - _attacker.global_position).normalized() if _attacker is Node3D else -player.global_basis.z
	var motion = CharacterModel.motion(player._body_model)
	if motion != null:
		motion.hit(_amount)

## Кто именно убил — знает только владелец цели, поэтому смерть объявляет он.
## RPC call_remote: себе не приходит, свою смерть покажет game._on_player_died.
func _on_local_died(attacker: Node) -> void:
	if not replicator.has_authority() or not NetApi.is_in_room():
		return
	var killer := "Мир"
	if attacker != null and is_instance_valid(attacker):
		var label = attacker.get("display_name")
		if label != null:
			killer = str(label)
	NetApi.rpc_all(announce_death, [player.display_name, killer, _last_headshot])

@rpc("authority", "call_remote", "reliable")
func announce_death(victim_name: String, killer_name: String, headshot: bool) -> void:
	if NetApi.rpc_sender() != replicator.get_owner_id():
		return
	if Session.net != null:
		Session.net.death_announced.emit(victim_name.substr(0, 24), killer_name.substr(0, 24), headshot)

func _on_weapon_changed(data: WeaponData) -> void:
	if replicator.has_authority():
		weapon_id = String(data.id)
		_publish_inventory()

## Урон применяет владелец цели. Стрелок присылает только идентификатор ствола и
## сумму: потолок, дистанцию и прямую видимость жертва считает сама по каталогу и
## своей геометрии. Бронепробитие тоже берётся из каталога, а не с провода.
## Номер жизни отсекает урон, прилетевший после респавна.
@rpc("any_peer", "call_remote", "reliable")
func apply_remote_damage(weapon_id_in: String, amount: float, headshot: bool, target_life: int) -> void:
	if not replicator.has_authority() or not player.health.alive or target_life != life_serial:
		return
	var attacker_id: int = NetApi.rpc_sender()
	if not _damage_budget.allow(attacker_id):
		return
	var attacker := _find_player(attacker_id)
	if attacker == null or attacker == player or not attacker.health.alive:
		return
	var data := Weapons.get_weapon(StringName(weapon_id_in))
	if data == null or not is_finite(amount) or amount <= 0.0:
		return
	var flow := get_tree().get_first_node_in_group("match_flow")
	if flow != null and not flow.allows_combat():
		return
	if data.slot == WeaponData.Slot.GRENADE:
		return # Grenade damage is simulated and confirmed by each victim.
	# Потолок — самый жирный законный выстрел этого ствола: вся дробь в голову
	# в упор, плюс 5 % на расхождение чисел у двух машин.
	var cap: float = data.damage * float(maxi(data.pellets, 1)) * 1.05
	if headshot:
		cap *= data.headshot_multiplier
	if amount > cap:
		return
	if attacker.global_position.distance_to(player.global_position) > data.max_range * 1.2:
		return
	if not _has_line_of_sight(attacker):
		return
	var dealt := player.health.take_damage(amount, attacker, headshot,
		clampf(data.armor_penetration, 0.0, 1.0))
	if dealt > 0.0:
		NetApi.rpc_all(confirm_hit, [attacker_id, headshot, not player.health.alive, life_serial])

@rpc("authority", "call_remote", "reliable")
func confirm_hit(attacker_id: int, headshot: bool, killed: bool, victim_life: int) -> void:
	if NetApi.rpc_sender() != replicator.get_owner_id():
		return
	var attacker := _find_player(attacker_id)
	if attacker == null or not attacker.local_control:
		return
	if killed:
		if victim_life <= _credited_life:
			return
		_credited_life = victim_life
		Session.net.kill_confirmed.emit(player.display_name, headshot)
	Sfx.play_2d(&"kill" if killed else (&"headshot" if headshot else &"hit"), 1.0, -4.0)
	attacker.weapons.hit_confirmed.emit(headshot, killed)

func _on_shot(id: String, origin: Vector3, end: Vector3) -> void:
	if replicator.has_authority() and NetApi.is_in_room():
		NetApi.rpc_all(show_shot, [id, origin, end])

func _on_equipment(id: String, origin: Vector3, motion: Vector3) -> void:
	if replicator.has_authority() and NetApi.is_in_room():
		_throw_serial += 1
		if id == "grenade" and is_instance_valid(player.weapons.last_grenade):
			player.weapons.last_grenade.detonated.connect(_on_grenade_detonated.bind(life_serial, _throw_serial))
		NetApi.rpc_all(show_equipment, [id, origin, motion, life_serial, NetApi.network_time(), _throw_serial])

func _on_grenade_detonated(point: Vector3, life: int, serial: int) -> void:
	if replicator.has_authority() and NetApi.is_in_room():
		NetApi.rpc_all(show_explosion, [life, serial, point])

@rpc("authority", "call_remote", "reliable")
func show_equipment(id: String, origin: Vector3, motion: Vector3, life: int, thrown_at: float, serial: int) -> void:
	var sender := NetApi.rpc_sender()
	if sender != replicator.get_owner_id() or player.local_control or life != life_serial:
		return
	if not _equipment_budget.allow(sender) or not origin.is_finite() or not motion.is_finite() or not is_finite(thrown_at):
		return
	if player.global_position.distance_to(origin) > 4.0 or motion.length() > 24.0:
		return
	var age := NetApi.network_time() - thrown_at
	if age < -0.25 or age > 1.0:
		return
	if id == "grenade":
		if _grenade_life != life:
			_grenade_life = life
			_grenades_seen = 0
		if _grenades_seen >= Weapons.get_weapon(&"grenade").magazine:
			return
		_grenades_seen += 1
		var grenade = preload("res://scripts/thrown_grenade.gd").launch(get_tree().current_scene, player, origin, motion)
		grenade.wait_for_confirmation = true
		grenade.fuse = maxf(0.1, grenade.fuse - maxf(age, 0.0))
		_grenade_visuals[serial] = {"node": weakref(grenade), "life": life, "time": thrown_at, "origin": origin}
	elif id == "knife":
		Sfx.play_3d(&"melee", origin, 1.0, -4.0, 14.0)
	else:
		return
	var body_motion = CharacterModel.motion(player._body_model)
	if body_motion != null:
		body_motion.fire()

@rpc("authority", "call_remote", "reliable")
func show_explosion(life: int, serial: int, point: Vector3) -> void:
	if NetApi.rpc_sender() != replicator.get_owner_id() or player.local_control or not point.is_finite():
		return
	if not _grenade_visuals.has(serial):
		return
	var row: Dictionary = _grenade_visuals[serial]
	var elapsed := NetApi.network_time() - float(row.time)
	if row.life != life or elapsed < 1.8 or elapsed > 4.2 or point.distance_to(row.origin) > 60.0:
		return
	# One validated throw permits one detonation. Damage uses the thrower's
	# actual physics position, never the latency-shifted visual replica.
	_grenade_visuals.erase(serial)
	var grenade = row.node.get_ref()
	if is_instance_valid(grenade):
		grenade.confirm_explosion(point)

@rpc("authority", "call_remote", "unreliable")
func show_shot(id: String, origin: Vector3, end: Vector3) -> void:
	var sender: int = NetApi.rpc_sender()
	if sender != replicator.get_owner_id() or player.local_control:
		return
	if not _shot_budget.allow(sender):
		return
	var data := Weapons.get_weapon(StringName(id))
	if data == null or not origin.is_finite() or not end.is_finite():
		return
	if not data.is_firearm():
		return
	var motion = CharacterModel.motion(player._body_model)
	if motion != null:
		motion.fire()
	var visual_origin := _world_muzzle.global_position if is_instance_valid(_world_muzzle) else origin
	Sfx.play_shot(data.id, visual_origin, data.shot_pitch)
	Effects.tracer(get_tree().current_scene, visual_origin, end)
	Effects.physical_hit(player, origin, end)
	# Авторитет уже прислал конечную точку. Короткий локальный луч нужен
	# только для нормали и материала эффекта, повторный урон не наносится.
	var direction := origin.direction_to(end)
	var query := PhysicsRayQueryParameters3D.create(end - direction * 0.2, end + direction * 0.2, 1 | 2 | 4)
	query.exclude = [player.get_rid()]
	var hit := player.get_world_3d().direct_space_state.intersect_ray(query)
	if not hit.is_empty():
		Effects.impact(get_tree().current_scene, hit.position, hit.normal, Damage.find_health(hit.collider) != null, hit.collider)
	if is_instance_valid(_world_muzzle):
		Effects.muzzle_flash(_world_muzzle, Vector3.ZERO)
		if motion != null and is_instance_valid(motion.ejection):
			Effects.casing(get_tree().current_scene, motion.ejection.global_transform, data.pellets > 1)

func _find_player(id: int) -> PlayerCharacter:
	for node in get_tree().get_nodes_in_group("combatants"):
		if node is PlayerCharacter and node.peer_id == id:
			return node
	return null

## Из-за интерполяции чужое тело у нас стоит не там, где его видел стрелок,
## поэтому целимся в три точки по высоте и довольствуемся одной свободной.
## Маска — только мир: бойцы друг друга не заслоняют, иначе на своего же
## союзника перед стволом урон бы не проходил.
func _has_line_of_sight(attacker: PlayerCharacter) -> bool:
	var space := player.get_world_3d().direct_space_state
	var from: Vector3 = attacker.global_position + Vector3.UP * 1.55
	for height in [1.5, 0.9, 0.3]:
		var query := PhysicsRayQueryParameters3D.create(from, player.global_position + Vector3.UP * height)
		query.collision_mask = 1
		query.exclude = [attacker.get_rid(), player.get_rid()]
		if space.intersect_ray(query).is_empty():
			return true
	return false

func _build_world_weapon() -> void:
	_shown_weapon = weapon_id
	var motion = CharacterModel.motion(player._body_model)
	if motion == null:
		return
	motion.equip(player, Weapons.get_weapon(StringName(weapon_id)))
	_world_weapon = motion.weapon
	_world_muzzle = motion.muzzle
