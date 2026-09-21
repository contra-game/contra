## Игрок от первого лица: движение, камера, присед, отдача, подбор оружия.
##
## Мультиплеер: local_control означает "этим телом управляет мышь и клавиатура
## на этой машине". Для чужих игроков он выставляется в false, и тело двигает
## сеть, а не ввод. В сети урон применяет владелец цели (см. damage.gd).
class_name PlayerCharacter
extends CharacterBody3D

signal died(attacker: Node)
signal respawned()

const STAND_HEIGHT := 1.8
const CROUCH_HEIGHT := 1.2
const STAND_EYE := 1.62
const CROUCH_EYE := 1.05
const MovementSpring = preload("res://scripts/viewmodel_spring.gd")
const Steps = preload("res://scripts/player_steps.gd")

@export var peer_id: int = 1
@export var local_control: bool = true
@export var display_name: String = "Player"
@export var team: int = 0

@export_group("Движение")
@export var walk_speed: float = 5.4
@export var sprint_speed: float = 7.6
@export var crouch_speed: float = 2.7
@export var ground_accel: float = 14.0
@export var ground_friction: float = 12.0
@export var air_accel: float = 2.6
@export var jump_velocity: float = 5.4
@export_range(0.0, 0.6, 0.01) var step_height: float = 0.35
@export var step_smoothing: float = 12.0

@export_group("Мышь")
@export var sensitivity: float = 0.0022
@export var max_pitch_deg: float = 89.0

@onready var collider: CollisionShape3D = $Collider
@onready var head: Node3D = $Head
@onready var camera: Camera3D = $Head/Camera
@onready var weapon_pivot: Node3D = $Head/Camera/WeaponPivot
@onready var body_mesh: MeshInstance3D = $Body

var _body_model: Node3D
var _body_anim: AnimationPlayer
@onready var health: Health = $Health
@onready var weapons: WeaponManager = $WeaponManager
@onready var economy: Economy = $Economy

var look_yaw: float = 0.0
var look_pitch: float = 0.0
var crouching: bool = false
## Состояние верхнего тела передаётся вместе с движением удалённого бойца.
var combat_aiming: bool = false
var combat_reload: float = -1.0
var combat_airborne: bool = false
## Пока открыт магазин, цифровые клавиши уходят на покупку.
var shop_open: bool = false
var input_enabled: bool = true
var sprinting: bool = false
var base_fov: float = 85.0

var _capsule: CapsuleShape3D
var _recoil := Vector2.ZERO          # текущий увод камеры (pitch, yaw) в радианах
var _recoil_target := Vector2.ZERO
var _camera_recoil_spring := MovementSpring.new()
var _bob_time: float = 0.0
var _step_accum: float = 0.0
var _land_kick: float = 0.0
var _landing_spring := MovementSpring.new()
var _step_camera_offset: float = 0.0
var _floor_grace: float = 0.0
var _stand_clearance: CapsuleShape3D
var _input_dir := Vector2.ZERO
var _wants_jump: bool = false
var _jump_buffer: float = 0.0
var _bob_weight: float = 0.0
var interaction_target: Node = null
var interaction_hint: String = ""
## Битовая маска того, от чего зависит внешний вид: жив / свой / есть модель.
var _visual_state: int = -1

func _ready() -> void:
	# Форма коллайдера общая для всех инстансов сцены — копируем под себя.
	_capsule = (collider.shape as CapsuleShape3D).duplicate()
	collider.shape = _capsule
	_set_height(STAND_HEIGHT)
	_stand_clearance = CapsuleShape3D.new()
	_stand_clearance.radius = _capsule.radius
	# Чуть поднимаем низ проверки над полом, но верх совпадает с полным ростом.
	_stand_clearance.height = STAND_HEIGHT - 0.02
	floor_snap_length = step_height + 0.03
	floor_constant_speed = true
	floor_stop_on_slope = true
	safe_margin = 0.002
	_landing_spring.frequency = 22.0
	_landing_spring.damping = 0.86
	_camera_recoil_spring.damping = 0.86

	base_fov = camera.fov

	health.died.connect(_on_died)
	weapons.recoil_kick.connect(_on_recoil_kick)
	weapons.setup(self, camera, weapon_pivot)
	configure_control(local_control)

## Вызывается и после сетевого спавна: дочерний _ready раньше родительского.
## Режимом мыши здесь не управляем — этот метод переспрашивается при смене
## авторитета (уход хоста), и захват перебивал бы открытую паузу или магазин.
## Мышь берут те, кто знает состояние экрана: game при спавне и hud в паузе.
func configure_control(mine: bool) -> void:
	local_control = mine
	if _capsule == null:
		return
	if mine:
		camera.make_current()
	elif camera.current:
		camera.clear_current()
	if not mine and _body_model == null:
		_build_body_model()
	weapons.set_local_visuals(mine)
	update_life_visuals()

## Зовётся каждый кадр для чужих бойцов, поэтому пересчитываем только на смене
## состояния: set_deferred на каждом кадре — лишняя очередь вызовов на каждого
## бойца в комнате.
func update_life_visuals() -> void:
	var state := (1 if health.alive else 0) | (2 if local_control else 0) | (4 if _body_model != null else 0)
	if state == _visual_state:
		return
	_visual_state = state
	body_mesh.visible = not local_control and health.alive and _body_model == null
	if _body_model != null:
		_body_model.visible = not local_control and health.alive
	collision_layer = 2 if health.alive else 0
	collider.set_deferred("disabled", not health.alive)

func _unhandled_input(event: InputEvent) -> void:
	if not local_control or not health.alive or not input_enabled or shop_open:
		return
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		var motion := event as InputEventMouseMotion
		var zoom_scale: float = tan(deg_to_rad(camera.fov) * 0.5) / tan(deg_to_rad(base_fov) * 0.5)
		# Множитель берётся из настроек на каждое событие: ползунок в паузе
		# действует сразу, пока его тянут, и подписка на сигнал не нужна.
		var step := sensitivity * Session.mouse_sensitivity * zoom_scale
		weapons.add_look_motion(motion.relative * zoom_scale)
		look_yaw -= motion.relative.x * step
		look_pitch -= motion.relative.y * step
		look_pitch = clampf(look_pitch, -deg_to_rad(max_pitch_deg), deg_to_rad(max_pitch_deg))
	elif event.is_action_pressed("interact") and not event.is_echo() and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		_try_interact()

func _physics_process(delta: float) -> void:
	if not local_control:
		head.rotation.x = look_pitch
		_set_height(lerpf(_capsule.height, CROUCH_HEIGHT if crouching else STAND_HEIGHT, minf(delta * 14.0, 1.0)))
		update_life_visuals()
		_animate_body()
		return
	if not health.alive:
		return

	_read_input()
	_jump_buffer = maxf(_jump_buffer - delta, 0.0)
	_wants_jump = _jump_buffer > 0.0
	_update_crouch(delta)
	_floor_grace = 0.1 if is_on_floor() else maxf(0.0, _floor_grace - delta)
	_apply_gravity(delta)
	_apply_movement(delta)

	var was_on_floor := is_on_floor()
	var fall_speed := velocity.y
	var position_before := global_position
	var stepped := _try_step_up(delta)
	var snap_before := floor_snap_length
	if stepped:
		# Первый кадр подъёма не притягивает ноги обратно к нижней ступени.
		floor_snap_length = 0.0
	move_and_slide()
	floor_snap_length = snap_before
	if was_on_floor and fall_speed <= 0.0 and not stepped:
		_snap_down_step()
		# Floor snap может сразу опустить капсулу на следующую ступень.
		var descent := global_position.y - position_before.y
		if is_on_floor() and descent < -0.045:
			_step_camera_offset -= descent
	if is_on_floor() and not was_on_floor and fall_speed < -3.0:
		_landing_spring.impulse(Vector3(0.0, minf(-fall_speed, 12.0) * 0.65, 0.0))
		weapons.add_landing_impact(-fall_speed)
		Sfx.play_footstep(self, true)

	_update_footsteps(delta)
	_update_view(delta)
	weapons.player_tick(delta, _movement_state())
	combat_aiming = weapons.aiming
	combat_reload = weapons.reload_progress() if weapons.reloading else -1.0
	combat_airborne = not is_on_floor()
	_update_interaction()

func _read_input() -> void:
	if not input_enabled or shop_open or Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		_input_dir = Vector2.ZERO
		_wants_jump = false
		_jump_buffer = 0.0
		sprinting = false
		return
	_input_dir = Input.get_vector("move_left", "move_right", "move_forward", "move_back")
	# Короткий буфер позволяет нажать перед посадкой без отложенного прыжка
	# спустя несколько секунд после случайного нажатия в воздухе.
	if Input.is_action_just_pressed("jump"):
		_jump_buffer = 0.15
	sprinting = Input.is_action_pressed("sprint") and not crouching and _input_dir.y < 0.0 and not Input.is_action_pressed("aim") and not Input.is_action_pressed("fire") and not weapons.reloading

func _apply_gravity(delta: float) -> void:
	if _wants_jump and (is_on_floor() or _floor_grace > 0.0):
		velocity.y = jump_velocity
		_wants_jump = false
		_jump_buffer = 0.0
		_floor_grace = 0.0
	elif is_on_floor():
		velocity.y = -0.1
	else:
		velocity.y -= _gravity() * delta

func _apply_movement(delta: float) -> void:
	var wish_dir := (transform.basis * Vector3(_input_dir.x, 0.0, _input_dir.y)).normalized()
	var speed := _target_speed()
	var target := wish_dir * speed
	var horizontal := Vector3(velocity.x, 0.0, velocity.z)

	if is_on_floor():
		if wish_dir.length_squared() > 0.01:
			horizontal = horizontal.move_toward(target, ground_accel * speed * delta)
		else:
			horizontal = horizontal.move_toward(Vector3.ZERO, ground_friction * speed * delta)
	else:
		# Без ввода нет воздушного тормоза. Стрейф добавляет скорость только
		# вдоль желаемого направления, сохраняя импульс прыжка поперёк него.
		if wish_dir.length_squared() > 0.01:
			var previous_speed := horizontal.length()
			var room := maxf(speed - horizontal.dot(wish_dir), 0.0)
			horizontal += wish_dir * minf(air_accel * speed * delta, room)
			var speed_limit := maxf(previous_speed, sprint_speed * weapons.speed_multiplier() * 1.35)
			horizontal = horizontal.limit_length(speed_limit)

	velocity.x = horizontal.x
	velocity.z = horizontal.z

func _target_speed() -> float:
	var base: float = crouch_speed if crouching else (sprint_speed if sprinting else walk_speed)
	return base * weapons.speed_multiplier()

func _update_crouch(delta: float) -> void:
	var want_crouch := input_enabled and not shop_open and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED and Input.is_action_pressed("crouch")
	if not want_crouch and (crouching or _capsule.height < STAND_HEIGHT - 0.001) and _blocked_above():
		want_crouch = true   # встать некуда — остаёмся сидеть
	crouching = want_crouch
	var target_height: float = CROUCH_HEIGHT if crouching else STAND_HEIGHT
	_set_height(lerpf(_capsule.height, target_height, clampf(delta * 14.0, 0.0, 1.0)))

func _set_height(h: float) -> void:
	_capsule.height = h
	collider.position.y = h * 0.5
	var t := clampf(inverse_lerp(CROUCH_HEIGHT, STAND_HEIGHT, h), 0.0, 1.0)
	head.position.y = lerpf(CROUCH_EYE, STAND_EYE, t)
	body_mesh.position.y = h * 0.5
	body_mesh.scale.y = h / STAND_HEIGHT
	# Скелет приседает сгибанием ног; масштаб тела остаётся постоянным.

func _blocked_above() -> bool:
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = _stand_clearance
	query.transform = Transform3D(global_basis, global_position + Vector3.UP * (STAND_HEIGHT * 0.5 + 0.01))
	query.exclude = [get_rid()]
	query.collision_mask = collision_mask
	return not get_world_3d().direct_space_state.intersect_shape(query, 1).is_empty()

## Капсула сначала проверяет весь путь вверх, вперёд и вниз. Переносим тело
## лишь после свободного прохода: ступень не позволяет проскочить стену.
func _try_step_up(delta: float) -> bool:
	var rise := Steps.step_up(self, delta, step_height)
	_step_camera_offset -= rise
	return rise > 0.0

func _snap_down_step() -> void:
	Steps.snap_down(self, step_height)

func _update_view(delta: float) -> void:
	# Боковая отдача меняет направление выстрела, а не только наклон экрана.
	var recoil_pose := _camera_recoil_spring.step(delta)
	_recoil = Vector2(recoil_pose.x, recoil_pose.y)
	_recoil_target *= exp(-weapons.recoil_recovery() * delta)

	rotation.y = look_yaw
	head.rotation.y = _recoil.y
	head.rotation.x = clampf(look_pitch + _recoil.x, -deg_to_rad(max_pitch_deg), deg_to_rad(max_pitch_deg))
	head.rotation.z = _recoil.y * 0.25

	# Покачивание при ходьбе и просадка после приземления.
	var planar := Vector2(velocity.x, velocity.z).length()
	if is_on_floor() and planar > 0.4:
		_bob_time += delta * planar * 1.35
	var moving := is_on_floor() and planar > 0.4
	_bob_weight = lerpf(_bob_weight, 1.0 if moving else 0.0, 1.0 - exp(-10.0 * delta))
	_land_kick = _landing_spring.step(delta).y
	_step_camera_offset *= exp(-step_smoothing * delta)

	var bob_scale: float = _bob_weight * (0.1 if weapons.is_aiming() else 1.0)
	camera.position.y = sin(_bob_time * 2.0) * 0.022 * bob_scale - _land_kick + _step_camera_offset
	camera.position.x = cos(_bob_time) * 0.018 * bob_scale
	# Удар в плечо: покачивание занимает x и y, продольный откат живёт в z.
	camera.position.z = recoil_pose.z
	camera.rotation.z = lerpf(camera.rotation.z, -_input_dir.x * 0.025, 1.0 - exp(-8.0 * delta))
	camera.fov = lerpf(camera.fov, weapons.target_fov(base_fov), 1.0 - exp(-12.0 * delta))

func _update_footsteps(delta: float) -> void:
	if not is_on_floor():
		_step_accum = 0.0
		return
	var planar := Vector2(velocity.x, velocity.z).length()
	if planar < 0.6:
		return
	_step_accum += planar * delta
	var stride: float = 2.6 if sprinting else 3.1
	if _step_accum >= stride:
		_step_accum = 0.0
		Sfx.play_footstep(self)

func _movement_state() -> Dictionary:
	return {
		"speed": Vector2(velocity.x, velocity.z).length(),
		"on_floor": is_on_floor(),
		"crouching": crouching,
		"sprinting": sprinting,
	}

func _try_interact() -> void:
	_update_interaction()
	if is_instance_valid(interaction_target):
		interaction_target.pick_up(self)
		_update_interaction()

func _update_interaction() -> void:
	interaction_target = null
	interaction_hint = ""
	if not local_control or not health.alive or not input_enabled or shop_open:
		return
	var space := get_world_3d().direct_space_state
	var from := camera.global_position
	var query := PhysicsRayQueryParameters3D.create(from, from - camera.global_transform.basis.z * 2.8)
	query.exclude = [get_rid()]
	query.collision_mask = 1 | 2 | 4 | (1 << 3) # Стена и бойцы перекрывают подбор.
	query.collide_with_areas = true
	query.collide_with_bodies = true
	var hit := space.intersect_ray(query)
	if hit.is_empty():
		return
	var node: Node = hit.collider
	if node.has_method("interaction_text"):
		interaction_hint = node.interaction_text(self)
		if not interaction_hint.is_empty():
			interaction_target = node

func _on_recoil_kick(pitch: float, yaw: float) -> void:
	_recoil_target.x += deg_to_rad(pitch)
	_recoil_target.y += deg_to_rad(yaw)
	_camera_recoil_spring.frequency = clampf(weapons.recoil_recovery() * 3.5, 14.0, 40.0)
	# Откат назад по +z пропорционален подбросу: слабый пистолет не должен
	# толкать камеру так же, как дробовик.
	var kickback := deg_to_rad(absf(pitch)) * 0.16
	_camera_recoil_spring.impulse(Vector3(deg_to_rad(pitch), deg_to_rad(yaw), kickback) * _camera_recoil_spring.frequency * 1.7)

func _on_died(attacker: Node) -> void:
	if local_control:
		Sfx.play_2d(&"death", 1.0, 2.0)
	weapons.holster()
	var push := -global_basis.z
	if attacker is Node3D:
		push = (global_position - attacker.global_position).normalized()
	spawn_death_ragdoll(push)
	interaction_target = null
	interaction_hint = ""
	update_life_visuals()
	died.emit(attacker)

func spawn_death_ragdoll(push: Vector3 = Vector3.ZERO) -> void:
	if _body_model == null:
		_build_body_model()
	if local_control and _body_model != null:
		# Скрытое локальное тело получает текущую стойку перед каждой смертью.
		CharacterModel.animate(_body_anim, velocity, combat_airborne, true)
		_body_anim.advance(0.0)
		var motion = CharacterModel.motion(_body_model)
		motion.equip(self, weapons.current_data())
		CharacterModel.drive(_body_model, self, {"velocity": velocity, "pitch": look_pitch, "aiming": combat_aiming, "crouching": crouching})
		motion._crouch = 1.0 if crouching else 0.0
		motion._aim = 1.0 if combat_aiming else 0.0
		motion._process_modification_with_delta(0.0)
		motion._cache_pose()
	if _body_model != null:
		preload("res://scripts/combat_ragdoll.gd").spawn(_body_model, get_tree().current_scene, velocity, push)

func respawn(at: Transform3D) -> void:
	global_transform = at
	look_yaw = at.basis.get_euler().y
	look_pitch = 0.0
	velocity = Vector3.ZERO
	_wants_jump = false
	_jump_buffer = 0.0
	_bob_weight = 0.0
	_bob_time = 0.0
	_land_kick = 0.0
	_landing_spring.reset()
	_step_camera_offset = 0.0
	_floor_grace = 0.0
	_recoil = Vector2.ZERO
	_recoil_target = Vector2.ZERO
	_camera_recoil_spring.reset()
	head.rotation = Vector3.ZERO
	camera.position = Vector3.ZERO
	camera.rotation = Vector3.ZERO
	camera.fov = base_fov
	health.reset()
	weapons.reset_loadout()
	combat_aiming = false
	combat_reload = -1.0
	combat_airborne = false
	update_life_visuals()
	respawned.emit()

func _gravity() -> float:
	return float(ProjectSettings.get_setting("physics/3d/default_gravity", 16.0))

func is_dead() -> bool:
	return not health.alive


## Скин выбирается по идентификатору узла, чтобы два бойца в комнате не
## оказались одинаковыми.
func _build_body_model() -> void:
	if not CharacterModel.available():
		return
	const SKINS := ["skaterFemaleA", "criminalMaleA", "skaterMaleA", "cyborgFemaleA"]
	var model := CharacterModel.build(SKINS[abs(peer_id) % SKINS.size()], 1.8)
	if model == null:
		return
	body_mesh.visible = false
	add_child(model)
	_body_model = model
	# У модели Kenney лицо направлено по +Z, у игрового тела вперёд — -Z.
	model.rotation.y = PI
	_body_anim = model.get_node_or_null("AnimationPlayer")
	if _body_anim != null and _body_anim.has_animation("idle"):
		_body_anim.play("idle")

## Сетевое тело получает скорость по репликации, в том числе вертикальную.
func _animate_body() -> void:
	CharacterModel.animate(_body_anim, velocity, combat_airborne, health.alive)
	CharacterModel.drive(_body_model, self, {
		"velocity": velocity, "pitch": look_pitch, "aiming": combat_aiming,
		"crouching": crouching, "airborne": combat_airborne,
		"alive": health.alive, "reload": combat_reload,
	})
