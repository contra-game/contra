## Бот-противник. Без навигационной сетки: цель ищется по прямой, препятствия
## обходятся тремя лучами-усами. Для прототипа этого достаточно, а когда
## появится NavigationRegion3D, менять придётся только _move_towards().
class_name Bot
extends CharacterBody3D

signal died(attacker: Node)

enum State { IDLE, PATROL, CHASE, ATTACK, DEAD }

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
var _weapon_model: Node3D

func _ready() -> void:
	_data = Weapons.get_weapon(weapon_id)
	_mag = _data.magazine if _data != null else 30
	_patrol_point = global_position
	health.died.connect(_on_died)
	health.damaged.connect(_on_damaged)
	_build_visual()
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
	_tick_reload(delta)

	_acquire_target(delta)
	match state:
		State.ATTACK:
			_do_attack(delta)
		State.CHASE:
			_do_chase(delta)
		_:
			_do_patrol(delta)

	if not is_on_floor():
		velocity.y -= float(ProjectSettings.get_setting("physics/3d/default_gravity", 16.0)) * delta
	else:
		velocity.y = -0.1
	move_and_slide()
	_update_animation()

# --- восприятие --------------------------------------------------------------

func _acquire_target(delta: float) -> void:
	var candidate := _nearest_enemy()
	if candidate == null:
		target = null
		if state != State.PATROL:
			state = State.PATROL
		return

	target = candidate
	var distance := global_position.distance_to(candidate.global_position)
	if distance < 42.0 and _can_see(candidate):
		if state != State.ATTACK:
			_reaction_left = reaction_time * randf_range(0.7, 1.3)
			state = State.ATTACK
		else:
			_reaction_left = maxf(_reaction_left - delta, 0.0)
	else:
		state = State.CHASE

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
		if distance < best_distance:
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
	query.collision_mask = 1 | 2
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
	_move_towards(_patrol_point, move_speed * 0.55, delta)

func _do_chase(delta: float) -> void:
	if target == null:
		_do_patrol(delta)
		return
	_face(target.global_position, delta, 6.0)
	_move_towards(target.global_position, move_speed, delta)

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
	_apply_move(wish.normalized() * move_speed * 0.85, delta)

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
	var query := PhysicsRayQueryParameters3D.create(origin, origin + dir * _data.max_range)
	query.collision_mask = 1 | 2 | 4
	query.exclude = [get_rid()]
	var hit := space.intersect_ray(query)
	var end: Vector3 = hit.get("position", origin + dir * _data.max_range)

	var world := get_tree().current_scene
	Effects.tracer(world, origin + dir * 0.6, end, Color(1.0, 0.55, 0.3))
	Sfx.play_shot(_data.id, origin, _data.shot_pitch)

	if hit.is_empty():
		return
	var body: Node = hit.collider
	var hp := Damage.find_health(body)
	Effects.impact(world, hit.position, hit.normal, hp != null)
	if hp == null:
		return
	var crouched: bool = body.get("crouching") if body.get("crouching") != null else false
	var headshot := Damage.is_headshot(body, hit.position, crouched)
	var amount := _data.damage_at(origin.distance_to(hit.position))
	if headshot:
		amount *= _data.headshot_multiplier
	Damage.apply(body, amount, self, headshot, _data.armor_penetration, String(_data.id))

func _tick_reload(delta: float) -> void:
	if _reload_left <= 0.0:
		return
	_reload_left -= delta
	if _reload_left <= 0.0:
		_mag = _data.magazine if _data != null else 30

# --- движение ----------------------------------------------------------------

func _move_towards(point: Vector3, speed: float, delta: float) -> void:
	var to_point := point - global_position
	to_point.y = 0.0
	if to_point.length() < 0.5:
		_apply_move(Vector3.ZERO, delta)
		return
	var dir := _avoid_obstacles(to_point.normalized())
	_apply_move(dir * speed, delta)
	if state != State.ATTACK:
		_face(global_position + dir, delta, 5.0)

## Три луча вперёд: если упёрлись — уходим в свободную сторону.
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
	query.collision_mask = 1 | 4          # мир и другие боты
	query.exclude = [get_rid()]
	return not space.intersect_ray(query).is_empty()

func _apply_move(wish: Vector3, delta: float) -> void:
	var horizontal := Vector3(velocity.x, 0.0, velocity.z)
	horizontal = horizontal.move_toward(Vector3(wish.x, 0.0, wish.z), 26.0 * delta)
	velocity.x = horizontal.x
	velocity.z = horizontal.z

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
	# Получил в спину — разворачиваемся к обидчику.
	if attacker is Node3D and state != State.ATTACK:
		target = attacker
		state = State.CHASE

func _on_died(attacker: Node) -> void:
	state = State.DEAD
	velocity = Vector3.ZERO
	_update_life_state()
	Sfx.play_3d(&"death", global_position, randf_range(0.85, 1.15))
	var tween := create_tween()
	tween.tween_property(mesh_root, "rotation:x", deg_to_rad(-85.0), 0.35)
	died.emit(attacker)

func respawn(at: Transform3D) -> void:
	global_transform = at
	velocity = Vector3.ZERO
	mesh_root.rotation = Vector3.ZERO
	state = State.PATROL
	target = null
	_mag = _data.magazine if _data != null else 30
	_reload_left = 0.0
	health.reset()
	_update_life_state()

## Труп не должен ловить пули и мешать ходить. У игрока это уже так
## (player.gd, update_life_visuals), у бота коллайдер оставался включённым весь
## респавн: выстрел в корпус глотался кровавыми искрами вместо урона.
func _update_life_state() -> void:
	var alive := health.alive
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
		_model_anim = model.get_node_or_null("AnimationPlayer")
		# Без этого боец стоит в T-позе, пока не сделает первый шаг.
		if _model_anim != null and _model_anim.has_animation("idle"):
			_model_anim.play("idle")
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
	if _model_anim == null:
		return
	var wanted := "run" if Vector2(velocity.x, velocity.z).length() > 0.8 else "idle"
	if state == State.DEAD:
		if _model_anim.is_playing():
			_model_anim.stop()
		return
	if _model_anim.current_animation != wanted and _model_anim.has_animation(wanted):
		_model_anim.play(wanted)

## Ствол в руке: видно, с чем бот бегает, и понятно, чего от него ждать.
## Крепится к кости правой кисти, поэтому едет вместе с анимацией.
func _attach_weapon(model: Node3D) -> void:
	if _data == null or _data.model_path == "" or not ResourceLoader.exists(_data.model_path):
		return
	var skeleton: Skeleton3D = null
	for node in ViewModel.walk(model):
		if node is Skeleton3D:
			skeleton = node
			break
	if skeleton == null:
		return
	var bone := skeleton.find_bone("RightHand")
	if bone < 0:
		return

	var attachment := BoneAttachment3D.new()
	attachment.name = "WeaponHand"
	skeleton.add_child(attachment)
	attachment.bone_idx = bone

	var holder := Node3D.new()
	attachment.add_child(holder)
	var weapon := (load(_data.model_path) as PackedScene).instantiate() as Node3D
	holder.add_child(weapon)
	ViewModel.fit(holder, weapon, _data)
	# Точка крепления наследует масштаб кости, скелета и самой модели бойца.
	# Без компенсации ствол раздувается в разы и бегает по карте великаном.
	attachment.force_update_transform()
	var attach_scale: float = attachment.global_transform.basis.get_scale().x
	# model_scale задан для вида от первого лица (там ствол намеренно крупнее);
	# в мире оружие должно быть настоящего размера.
	var compensation: float = attach_scale * maxf(_data.model_scale, 0.001)
	if compensation > 0.0001:
		# Делим и смещение: оно посчитано в старом масштабе держателя.
		holder.scale /= compensation
		holder.position /= compensation
	ViewModel.paint(weapon, _data.body_color, true)
	_weapon_model = weapon
