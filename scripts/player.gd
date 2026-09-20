## Игрок от первого лица: движение, камера, присед, отдача, подбор оружия.
##
## Мультиплеер: local_control означает "этим телом управляет мышь и клавиатура
## на этой машине". Для чужих игроков он выставляется в false, и тело двигает
## сеть, а не ввод. Урон в любом случае применяет только сервер (см. damage.gd).
class_name PlayerCharacter
extends CharacterBody3D

signal died(attacker: Node)
signal respawned()

const STAND_HEIGHT := 1.8
const CROUCH_HEIGHT := 1.2
const STAND_EYE := 1.62
const CROUCH_EYE := 1.05

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

@export_group("Мышь")
@export var sensitivity: float = 0.0022
@export var max_pitch_deg: float = 89.0

@onready var collider: CollisionShape3D = $Collider
@onready var head: Node3D = $Head
@onready var camera: Camera3D = $Head/Camera
@onready var weapon_pivot: Node3D = $Head/Camera/WeaponPivot
@onready var body_mesh: MeshInstance3D = $Body
@onready var health: Health = $Health
@onready var weapons: WeaponManager = $WeaponManager

var look_yaw: float = 0.0
var look_pitch: float = 0.0
var crouching: bool = false
var sprinting: bool = false
var base_fov: float = 85.0

var _capsule: CapsuleShape3D
var _recoil := Vector2.ZERO          # текущий увод камеры (pitch, yaw) в радианах
var _recoil_target := Vector2.ZERO
var _bob_time: float = 0.0
var _step_accum: float = 0.0
var _land_kick: float = 0.0
var _input_dir := Vector2.ZERO
var _wants_jump: bool = false

func _ready() -> void:
	# Форма коллайдера общая для всех инстансов сцены — копируем под себя.
	_capsule = (collider.shape as CapsuleShape3D).duplicate()
	collider.shape = _capsule
	_set_height(STAND_HEIGHT)

	base_fov = camera.fov
	camera.current = local_control
	body_mesh.visible = not local_control

	health.died.connect(_on_died)
	weapons.recoil_kick.connect(_on_recoil_kick)
	weapons.setup(self, camera, weapon_pivot)

	if local_control:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

func _unhandled_input(event: InputEvent) -> void:
	if not local_control or not health.alive:
		return
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		var motion := event as InputEventMouseMotion
		var zoom_scale: float = camera.fov / base_fov   # в прицеле мышь медленнее
		look_yaw -= motion.relative.x * sensitivity * zoom_scale
		look_pitch -= motion.relative.y * sensitivity * zoom_scale
		look_pitch = clampf(look_pitch, -deg_to_rad(max_pitch_deg), deg_to_rad(max_pitch_deg))
	elif event.is_action_pressed("interact"):
		_try_interact()

func _physics_process(delta: float) -> void:
	if not local_control:
		_update_view(delta)
		return

	_read_input()
	_update_crouch(delta)
	_apply_gravity(delta)
	_apply_movement(delta)

	var was_on_floor := is_on_floor()
	var fall_speed := velocity.y
	move_and_slide()
	if is_on_floor() and not was_on_floor and fall_speed < -6.0:
		_land_kick = clampf(-fall_speed * 0.012, 0.0, 0.14)
		Sfx.play_3d(&"step", global_position, 0.7, 2.0)

	_update_footsteps(delta)
	_update_view(delta)
	weapons.player_tick(delta, _movement_state())

func _read_input() -> void:
	_input_dir = Input.get_vector("move_left", "move_right", "move_forward", "move_back")
	_wants_jump = Input.is_action_pressed("jump")
	sprinting = Input.is_action_pressed("sprint") and not crouching and _input_dir.y < 0.0

func _apply_gravity(delta: float) -> void:
	if is_on_floor():
		if _wants_jump:
			velocity.y = jump_velocity
		else:
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
		# В воздухе управление ослаблено, инерция прыжка сохраняется.
		horizontal = horizontal.move_toward(target, air_accel * speed * delta)
		if horizontal.length() > speed * 1.35:
			horizontal = horizontal.normalized() * speed * 1.35

	velocity.x = horizontal.x
	velocity.z = horizontal.z

func _target_speed() -> float:
	var base: float = crouch_speed if crouching else (sprint_speed if sprinting else walk_speed)
	return base * weapons.speed_multiplier()

func _update_crouch(delta: float) -> void:
	var want_crouch := Input.is_action_pressed("crouch")
	if not want_crouch and crouching and _blocked_above():
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

func _blocked_above() -> bool:
	var space := get_world_3d().direct_space_state
	var from := global_position + Vector3.UP * (CROUCH_HEIGHT - 0.1)
	var query := PhysicsRayQueryParameters3D.create(from, from + Vector3.UP * (STAND_HEIGHT - CROUCH_HEIGHT + 0.15))
	query.exclude = [get_rid()]
	query.collision_mask = 1
	return not space.intersect_ray(query).is_empty()

func _update_view(delta: float) -> void:
	# Отдача уводит камеру вверх и сама возвращается назад не полностью —
	# остаток игрок компенсирует мышью, как в классических шутерах.
	_recoil = _recoil.lerp(_recoil_target, clampf(delta * 18.0, 0.0, 1.0))
	_recoil_target = _recoil_target.lerp(Vector2.ZERO, clampf(delta * weapons.recoil_recovery(), 0.0, 1.0))

	rotation.y = look_yaw
	head.rotation.x = clampf(look_pitch + _recoil.x, -deg_to_rad(max_pitch_deg), deg_to_rad(max_pitch_deg))
	head.rotation.z = _recoil.y * 0.25

	# Покачивание при ходьбе и просадка после приземления.
	var planar := Vector2(velocity.x, velocity.z).length()
	if is_on_floor() and planar > 0.4:
		_bob_time += delta * planar * 1.35
	else:
		_bob_time = lerpf(_bob_time, 0.0, delta * 6.0)
	_land_kick = lerpf(_land_kick, 0.0, delta * 7.0)

	var bob_scale: float = 0.0 if weapons.is_aiming() else 1.0
	camera.position.y = sin(_bob_time * 2.0) * 0.022 * bob_scale - _land_kick
	camera.position.x = cos(_bob_time) * 0.018 * bob_scale
	camera.rotation.z = lerpf(camera.rotation.z, -_input_dir.x * 0.025, delta * 8.0)
	camera.fov = lerpf(camera.fov, weapons.target_fov(base_fov), delta * 12.0)

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
		Sfx.play_3d(&"step", global_position, randf_range(0.9, 1.1), -4.0, 25.0)

func _movement_state() -> Dictionary:
	return {
		"speed": Vector2(velocity.x, velocity.z).length(),
		"on_floor": is_on_floor(),
		"crouching": crouching,
		"sprinting": sprinting,
	}

func _try_interact() -> void:
	var space := get_world_3d().direct_space_state
	var from := camera.global_position
	var query := PhysicsRayQueryParameters3D.create(from, from - camera.global_transform.basis.z * 2.8)
	query.exclude = [get_rid()]
	query.collision_mask = 1 << 3          # слой pickup
	query.collide_with_areas = true
	query.collide_with_bodies = false
	var hit := space.intersect_ray(query)
	if hit.is_empty():
		return
	var node: Node = hit.collider
	if node.has_method("pick_up"):
		node.pick_up(self)

func _on_recoil_kick(pitch: float, yaw: float) -> void:
	_recoil_target.x += deg_to_rad(pitch)
	_recoil_target.y += deg_to_rad(yaw)

func _on_died(attacker: Node) -> void:
	if local_control:
		Sfx.play_2d(&"death", 1.0, 2.0)
	weapons.holster()
	died.emit(attacker)

func respawn(at: Transform3D) -> void:
	global_transform = at
	look_yaw = at.basis.get_euler().y
	look_pitch = 0.0
	velocity = Vector3.ZERO
	_recoil = Vector2.ZERO
	_recoil_target = Vector2.ZERO
	health.reset()
	weapons.reset_loadout()
	respawned.emit()

func _gravity() -> float:
	return float(ProjectSettings.get_setting("physics/3d/default_gravity", 16.0))

func is_dead() -> bool:
	return not health.alive
