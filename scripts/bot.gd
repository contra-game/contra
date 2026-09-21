## NavigationAgent follows the baked city mesh; perception and cover decisions
## use physical line of sight rather than knowledge of hidden enemy positions.
class_name Bot
extends CharacterBody3D

signal died(attacker: Node)

enum State { IDLE, PATROL, CHASE, ATTACK, DEAD, COVER, SEARCH }

@export var weapon_id: StringName = &"ak47"
@export var display_name: String = "Bot"
@export var team: int = 1

@export_group("Поведение")
@export var move_speed: float = 4.2
@export var sight_range: float = 45.0
@export var fov_degrees: float = 130.0
## Задержка перед первым выстрелом после обнаружения цели.
@export var reaction_time: float = 0.95
## Во сколько раз бот мажет сильнее игрока.
@export var accuracy_penalty: float = 4.6
@export var burst_min: int = 3
@export var burst_max: int = 5

@onready var health: Health = $Health
@onready var mesh_root: Node3D = $Mesh
@onready var collider: CollisionShape3D = $Collider

var state: State = State.IDLE
var target: Node3D = null

var _data: WeaponData
var _mag: int = 0
var _cooldown: float = 0.0
var _reaction_left: float = 0.0
var _burst_left: int = 0
var _burst_pause: float = 0.0
var _reload_left: float = 0.0
var _patrol_point: Vector3
var _repath: float = 0.0
var _strafe: float = 1.0
var _strafe_timer: float = 0.0
var _model_anim: AnimationPlayer
var _weapon_muzzle: Marker3D
var _character_model: Node3D
var _death_tween: Tween
var navigation_agent: NavigationAgent3D
var _path_goal := Vector3.INF
var _path_refresh: float = 0.0
var _last_seen := Vector3.ZERO
var _memory_left: float = 0.0
var _visible_target: bool = false
var _cover_point := Vector3.ZERO
var _cover_left: float = 0.0
var _cover_retry: float = 0.0
var _step_distance: float = 0.0

func _ready() -> void:
	_data = Weapons.get_weapon(weapon_id)
	_mag = _data.magazine if _data != null else 30
	_patrol_point = global_position
	health.died.connect(_on_died)
	health.damaged.connect(_on_damaged)
	_build_visual()
	_build_navigation_agent()
	_update_life_state()

func _physics_process(delta: float) -> void:
	# Поведение считает только сервер: клиенты получат результат по сети.
	if not multiplayer.is_server():
		return
	if state == State.DEAD:
		return

	_cooldown = maxf(_cooldown - delta, 0.0)
	_burst_pause = maxf(_burst_pause - delta, 0.0)
	_repath = maxf(_repath - delta, 0.0)
	_path_refresh = maxf(_path_refresh - delta, 0.0)
	_cover_retry = maxf(_cover_retry - delta, 0.0)
	_cover_left = maxf(_cover_left - delta, 0.0)
	_tick_reload(delta)

	_acquire_target(delta)
	match state:
		State.ATTACK:
			_do_attack(delta)
		State.CHASE:
			_do_chase(delta)
		State.SEARCH:
			_do_search(delta)
		State.COVER:
			_do_cover(delta)
		_:
			_do_patrol(delta)

	if not is_on_floor():
		velocity.y -= float(ProjectSettings.get_setting("physics/3d/default_gravity", 16.0)) * delta
	else:
		velocity.y = -0.1
	move_and_slide()
	_tick_footsteps(delta)
	_update_animation()

# --- восприятие --------------------------------------------------------------

func _acquire_target(delta: float) -> void:
	var candidate := _nearest_enemy()
	var previously_visible := _visible_target
	_visible_target = candidate != null
	if _visible_target:
		if target != candidate or not previously_visible:
			_reaction_left = reaction_time * randf_range(0.7, 1.3)
		else:
			_reaction_left = maxf(_reaction_left - delta, 0.0)
		target = candidate
		_last_seen = target.global_position
		_memory_left = 5.0
		if state == State.COVER and (_reload_left > 0.0 or _cover_left > 0.0):
			return
		if (_reload_left > 0.0 or health.health < 35.0) and _cover_retry <= 0.0:
			_cover_retry = 3.0
			if _find_cover():
				state = State.COVER
				_cover_left = 1.3
				return
		state = State.ATTACK
		return
	_memory_left = maxf(_memory_left - delta, 0.0)
	if is_instance_valid(target) and _memory_left > 0.0:
		if state == State.COVER and (_reload_left > 0.0 or _cover_left > 0.0):
			return
		state = State.CHASE if global_position.distance_to(_last_seen) > 1.5 else State.SEARCH
		return
	target = null
	state = State.PATROL

func _nearest_enemy() -> Node3D:
	var best: Node3D = null
	var best_distance := sight_range
	for node in get_tree().get_nodes_in_group("combatants"):
		if node == self or not is_instance_valid(node):
			continue
		if node.get("team") == team:
			continue
		# Чужой сетевой боец — не цель: боты локальные у каждого клиента, и его
		# хозяин такого выстрела всё равно не увидит.
		if node.get("local_control") == false:
			continue
		var hp := Damage.find_health(node)
		if hp == null or not hp.alive:
			continue
		var distance := global_position.distance_to(node.global_position)
		if distance < best_distance and _can_see(node):
			best_distance = distance
			best = node
	return best

func _can_see(other: Node3D) -> bool:
	var from := _eye_position()
	var to := other.global_position + Vector3.UP * 1.3
	var to_target := (to - from)
	if rad_to_deg((-global_transform.basis.z).angle_to(to_target.normalized())) > fov_degrees * 0.5:
		return false
	var space := get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.create(from, to)
	query.collision_mask = 1 | 2 | 4
	query.exclude = [get_rid()]
	var hit := space.intersect_ray(query)
	return hit.is_empty() or hit.collider == other

func _eye_position() -> Vector3:
	return global_position + Vector3.UP * 1.55

# --- состояния ---------------------------------------------------------------

func _do_patrol(delta: float) -> void:
	if _repath <= 0.0 or global_position.distance_to(_patrol_point) < 2.0:
		_repath = randf_range(3.0, 7.0)
		var offset := Vector3(randf_range(-18.0, 18.0), 0.0, randf_range(-18.0, 18.0))
		_patrol_point = global_position + offset
		if _navigation_ready():
			_patrol_point = NavigationServer3D.map_get_closest_point(navigation_agent.get_navigation_map(), _patrol_point)
	_move_towards(_patrol_point, move_speed * 0.55, delta)

func _do_chase(delta: float) -> void:
	if target == null:
		_do_patrol(delta)
		return
	_face(_last_seen, delta, 6.0)
	_move_towards(_last_seen, move_speed, delta)

func _do_search(delta: float) -> void:
	_apply_move(Vector3.ZERO, delta)
	rotation.y += delta * 0.75

func _do_cover(delta: float) -> void:
	_move_towards(_cover_point, move_speed, delta)
	_face(_last_seen, delta, 8.0)
	if _visible_target and _reaction_left <= 0.0 and _reload_left <= 0.0:
		_shoot(delta)

## Sample reachable ground around the bot. A cover spot must actually hide
## its chest from the enemy, and its path must terminate at that spot.
func _find_cover() -> bool:
	if not _navigation_ready() or not is_instance_valid(target):
		return false
	var map_rid := navigation_agent.get_navigation_map()
	var space := get_world_3d().direct_space_state
	var threat := target.global_position + Vector3.UP * 1.3
	var best_score := INF
	for index in 16:
		var angle := float(index) * TAU / 16.0
		var candidate := global_position + Vector3(cos(angle), 0.0, sin(angle)) * (6.0 if index % 2 == 0 else 10.0)
		candidate = NavigationServer3D.map_get_closest_point(map_rid, candidate)
		var query := PhysicsRayQueryParameters3D.create(threat, candidate + Vector3.UP * 1.25, 1)
		if space.intersect_ray(query).is_empty():
			continue
		var route := NavigationServer3D.map_get_path(map_rid, global_position, candidate, true)
		if route.size() < 2 or route[-1].distance_to(candidate) > 0.8:
			continue
		var score := 0.0
		for step in range(1, route.size()):
			score += route[step - 1].distance_to(route[step])
		if score < best_score:
			best_score = score
			_cover_point = candidate
	return is_finite(best_score)

func _do_attack(delta: float) -> void:
	if target == null:
		state = State.PATROL
		return

	_face(target.global_position, delta, 9.0)

	# На месте бот — лёгкая мишень, поэтому он подстраивает дистанцию и стрейфит.
	_strafe_timer -= delta
	if _strafe_timer <= 0.0:
		_strafe_timer = randf_range(0.8, 2.0)
		_strafe = -_strafe
	var to_target := target.global_position - global_position
	var distance := to_target.length()
	var forward := to_target.normalized()
	var side := forward.cross(Vector3.UP).normalized()
	var wish := side * _strafe
	if distance > 18.0:
		wish += forward
	elif distance < 8.0:
		wish -= forward
	# Во время перезарядки отступаем и обходим стену при стрейфе.
	if _reload_left > 0.0:
		wish = side * _strafe - forward
	_move_towards(global_position + wish.normalized() * 3.0, move_speed * 0.85, delta)

	if _reaction_left <= 0.0:
		_shoot(delta)

func _shoot(delta: float) -> void:
	if _data == null or _reload_left > 0.0 or _cooldown > 0.0 or _burst_pause > 0.0:
		return
	if _mag <= 0:
		_reload_left = _data.reload_time
		return
	if not _can_see(target):
		return

	_mag -= 1
	var motion = CharacterModel.motion(_character_model)
	if motion != null:
		motion.fire()
	_cooldown = _data.seconds_per_shot()
	if _burst_left <= 0:
		_burst_left = randi_range(burst_min, burst_max)
	_burst_left -= 1
	if _burst_left <= 0:
		_burst_pause = randf_range(0.9, 2.0)

	var origin := _eye_position()
	var aim_point: Vector3 = target.global_position + Vector3.UP * randf_range(0.9, 1.5)
	var dir := (aim_point - origin).normalized()
	# Чем дальше цель, тем сильнее бот мажет: иначе восемь ботов простреливают
	# всю карту насквозь и у игрока нет шанса перебежать улицу.
	var distance_penalty := 1.0 + origin.distance_to(aim_point) / 22.0
	dir = _apply_spread(dir, (_data.spread_base + 0.6) * accuracy_penalty * distance_penalty)

	var space := get_world_3d().direct_space_state
	var hit := Damage.raycast(space, origin, origin + dir * _data.max_range, self)
	var end: Vector3 = hit.get("position", origin + dir * _data.max_range)

	var world := get_tree().current_scene
	var visual_origin := _weapon_muzzle.global_position if is_instance_valid(_weapon_muzzle) else origin
	Effects.tracer(world, visual_origin, end, Color(1.0, 0.55, 0.3))
	Effects.physical_hit(self, origin, end)
	if is_instance_valid(_weapon_muzzle):
		Effects.muzzle_flash(_weapon_muzzle, Vector3.ZERO)
		if motion != null and is_instance_valid(motion.ejection):
			Effects.casing(world, motion.ejection.global_transform, _data.pellets > 1)
	Sfx.play_shot(_data.id, origin, _data.shot_pitch)

	if hit.is_empty():
		return
	var body: Node = Damage.resolve_target(hit.collider)
	var hp := Damage.find_health(body)
	Effects.impact(world, hit.position, hit.normal, hp != null, body)
	if hp == null:
		return
	var zone := Damage.hit_zone(hit.collider, hit.position)
	var headshot := zone == &"head"
	var amount := _data.damage_at(origin.distance_to(hit.position))
	amount *= Damage.zone_multiplier(_data, zone)
	Damage.apply(body, amount, self, headshot, _data.armor_penetration, String(_data.id))

func _tick_reload(delta: float) -> void:
	if _reload_left <= 0.0:
		return
	_reload_left -= delta
	if _reload_left <= 0.0:
		_mag = _data.magazine if _data != null else 30

# --- движение ----------------------------------------------------------------

func _move_towards(point: Vector3, speed: float, delta: float) -> void:
	# Empty/not-yet-synchronized maps must never cause a direct charge through
	# buildings. A waypoint query starts only after the bake reaches the server.
	if not _navigation_ready():
		_apply_move(Vector3.ZERO, delta)
		return
	if _path_refresh <= 0.0 and (_path_goal.distance_to(point) > 0.75 or navigation_agent.is_navigation_finished()):
		_path_goal = point
		navigation_agent.target_position = point
		_path_refresh = 0.25
	var next := navigation_agent.get_next_path_position()
	var to_point := next - global_position
	to_point.y = 0.0
	if navigation_agent.is_navigation_finished() or to_point.length() < 0.05:
		_apply_move(Vector3.ZERO, delta)
		return
	var dir := _avoid_obstacles(to_point.normalized())
	_apply_move(dir * speed, delta)
	if state != State.ATTACK and state != State.COVER:
		_face(global_position + dir, delta, 5.0)

func _build_navigation_agent() -> void:
	navigation_agent = NavigationAgent3D.new()
	navigation_agent.name = "NavigationAgent"
	navigation_agent.path_desired_distance = 0.18
	navigation_agent.path_height_offset = 0.5
	navigation_agent.target_desired_distance = 0.65
	navigation_agent.path_max_distance = 2.0
	navigation_agent.radius = 0.4
	navigation_agent.height = 1.8
	add_child(navigation_agent)
	floor_snap_length = 0.3

func _navigation_ready() -> bool:
	return is_instance_valid(navigation_agent) and NavigationServer3D.map_get_iteration_id(navigation_agent.get_navigation_map()) > 0

## The mesh handles walls. Short rays only separate moving combatants so
## obstacle steering cannot undo a valid corner path from NavigationAgent.
func _avoid_obstacles(dir: Vector3) -> Vector3:
	var space := get_world_3d().direct_space_state
	var origin := global_position + Vector3.UP * 0.9
	if not _blocked(space, origin, dir, 2.2):
		return dir
	var left := dir.rotated(Vector3.UP, deg_to_rad(55.0))
	if not _blocked(space, origin, left, 2.6):
		return left
	var right := dir.rotated(Vector3.UP, deg_to_rad(-55.0))
	if not _blocked(space, origin, right, 2.6):
		return right
	return dir.rotated(Vector3.UP, deg_to_rad(140.0))

func _blocked(space: PhysicsDirectSpaceState3D, origin: Vector3, dir: Vector3, distance: float) -> bool:
	var query := PhysicsRayQueryParameters3D.create(origin, origin + dir * distance)
	query.collision_mask = 2 | 4
	query.exclude = [get_rid()]
	return not space.intersect_ray(query).is_empty()

func _apply_move(wish: Vector3, delta: float) -> void:
	var horizontal := Vector3(velocity.x, 0.0, velocity.z)
	horizontal = horizontal.move_toward(Vector3(wish.x, 0.0, wish.z), 26.0 * delta)
	velocity.x = horizontal.x
	velocity.z = horizontal.z

func _tick_footsteps(delta: float) -> void:
	if not is_on_floor():
		return
	_step_distance += Vector2(velocity.x, velocity.z).length() * delta
	if _step_distance >= 2.5:
		_step_distance = fmod(_step_distance, 2.5)
		Sfx.play_footstep(self)

func _face(point: Vector3, delta: float, speed: float) -> void:
	var to_point := point - global_position
	to_point.y = 0.0
	if to_point.length_squared() < 0.01:
		return
	var wanted := atan2(-to_point.x, -to_point.z)
	rotation.y = lerp_angle(rotation.y, wanted, clampf(delta * speed, 0.0, 1.0))

func _apply_spread(dir: Vector3, spread_deg: float) -> Vector3:
	var angle := deg_to_rad(spread_deg) * sqrt(randf())
	var roll := randf() * TAU
	var basis_x := dir.cross(Vector3.UP)
	if basis_x.length_squared() < 0.0001:
		basis_x = Vector3.RIGHT
	basis_x = basis_x.normalized()
	var basis_y := basis_x.cross(dir).normalized()
	return (dir + (basis_x * cos(roll) + basis_y * sin(roll)) * tan(angle)).normalized()

# --- жизнь и смерть ----------------------------------------------------------

func _on_damaged(_amount: float, attacker: Node, _headshot: bool) -> void:
	var motion = CharacterModel.motion(_character_model)
	if motion != null:
		motion.hit(_amount)
	# Получил в спину — разворачиваемся к обидчику.
	if attacker is Node3D and state != State.ATTACK:
		target = attacker
		_last_seen = attacker.global_position
		_memory_left = 5.0
		state = State.CHASE

func _on_died(attacker: Node) -> void:
	state = State.DEAD
	var push := -global_basis.z
	if attacker is Node3D:
		push = (global_position - attacker.global_position).normalized()
	if _character_model != null:
		preload("res://scripts/combat_ragdoll.gd").spawn(_character_model, get_tree().current_scene, velocity, push)
	velocity = Vector3.ZERO
	_update_life_state()
	Sfx.play_3d(&"death", global_position, randf_range(0.85, 1.15))
	CharacterModel.animate(_model_anim, Vector3.ZERO, false, false)
	var motion = CharacterModel.motion(_character_model)
	if motion != null:
		motion.alive = false
	if _character_model == null:
		_death_tween = create_tween()
		_death_tween.tween_property(mesh_root, "rotation:x", deg_to_rad(-85.0), 0.35)
	died.emit(attacker)

func respawn(at: Transform3D) -> void:
	if _death_tween != null and _death_tween.is_valid():
		_death_tween.kill()
	global_transform = at
	velocity = Vector3.ZERO
	mesh_root.rotation = Vector3.ZERO
	state = State.PATROL
	target = null
	_visible_target = false
	_memory_left = 0.0
	_cover_left = 0.0
	_path_goal = Vector3.INF
	_path_refresh = 0.0
	_mag = _data.magazine if _data != null else 30
	_reload_left = 0.0
	_cooldown = 0.0
	_burst_left = 0
	_burst_pause = 0.0
	health.reset()
	var motion = CharacterModel.motion(_character_model)
	if motion != null:
		motion.reset_motion()
	_update_life_state()
	_update_animation()

## Труп не должен ловить пули и мешать ходить. У игрока это уже так
## (player.gd, update_life_visuals), у бота коллайдер оставался включённым весь
## респавн: выстрел в корпус глотался кровавыми искрами вместо урона.
func _update_life_state() -> void:
	var alive := health.alive
	mesh_root.visible = alive or _character_model == null
	collision_layer = 4 if alive else 0
	collider.set_deferred("disabled", not alive)

## Спрашивает game._network_spawn у всех бойцов в группе combatants.
func is_dead() -> bool:
	return not health.alive

## Внешний вид: модель бойца, если ассеты на месте, иначе капсулы из сцены,
## покрашенные по команде.
func _build_visual() -> void:
	var model := CharacterModel.build(_skin_name(), 1.8)
	if model != null:
		for child in mesh_root.get_children():
			child.queue_free()
		mesh_root.add_child(model)
		_character_model = model
		model.rotation.y = PI
		_model_anim = model.get_node_or_null("AnimationPlayer")
		# Без этого боец стоит в T-позе, пока не сделает первый шаг.
		CharacterModel.animate(_model_anim, Vector3.ZERO, false, true)
		_attach_weapon(model)
		return

	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.72, 0.22, 0.2) if team == 1 else Color(0.2, 0.42, 0.75)
	mat.roughness = 0.7
	for child in mesh_root.get_children():
		if child is MeshInstance3D:
			child.material_override = mat

func _skin_name() -> String:
	const SKINS := ["criminalMaleA", "skaterMaleA", "skaterFemaleA", "cyborgFemaleA"]
	return SKINS[abs(get_instance_id()) % SKINS.size()]

## Анимация выбирается по фактической скорости — отдельного состояния не нужно.
func _update_animation() -> void:
	CharacterModel.animate(_model_anim, velocity, not is_on_floor(), health.alive)
	var aim_pitch := 0.0
	if is_instance_valid(target):
		var direction := target.global_position + Vector3.UP * 1.3 - _eye_position()
		aim_pitch = atan2(direction.y, Vector2(direction.x, direction.z).length())
	CharacterModel.drive(_character_model, self, {
		"velocity": velocity, "pitch": aim_pitch, "aiming": state == State.ATTACK,
		"airborne": not is_on_floor(), "alive": health.alive,
		"reload": 1.0 - _reload_left / _data.reload_time if _reload_left > 0.0 else -1.0,
	})

## Общая боевая стойка с IK рук для ботов и сетевых бойцов.
func _attach_weapon(model: Node3D) -> void:
	var motion = CharacterModel.motion(model)
	if motion == null:
		return
	motion.equip(self, _data)
	_weapon_muzzle = motion.muzzle
