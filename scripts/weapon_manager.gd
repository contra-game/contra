## Four-slot inventory, hitscan, melee and throwable state transitions.
##
## Живёт на игроке, но бот пользуется теми же данными WeaponData через свой
## упрощённый код — баланс всегда один и тот же.
class_name WeaponManager
extends Node

signal ammo_changed(in_mag: int, reserve: int)
signal weapon_changed(data: WeaponData)
signal spread_changed(degrees: float)
signal recoil_kick(pitch_deg: float, yaw_deg: float)
signal hit_confirmed(headshot: bool, killed: bool)
signal scope_changed(active: bool)
signal shot_fired(weapon_id: String, origin: Vector3, end: Vector3)
signal equipment_used(weapon_id: String, origin: Vector3, launch_velocity: Vector3)

const SLOT_COUNT := 4
enum State { READY, FIRING, RELOADING, HOLSTERING, EQUIPPING, DISABLED }
var state: State = State.READY
var _pending_slot: int = -1
var _holster_left: float = 0.0
const HIT_MASK := 1 | 2 | 4        # мир + игроки + боты
## Сколько дробин залпа оставляют видимый след.
const TRACERS_PER_SHOT := 2
const Spring = preload("res://scripts/viewmodel_spring.gd")
const WeaponLayer = preload("res://scripts/viewmodel_layer.gd")

## Положения модели оружия относительно камеры.
const HIP_POSITION := Vector3(0.18, -0.13, -0.45)

const SPRINT_POSITION := Vector3(0.22, -0.18, -0.4)

@export var default_primary: StringName = &"ak47"
@export var default_secondary: StringName = &"glock"

var current_slot: int = 0
var slots: Array = []              # [{data, mag, reserve}, ...]
var aiming: bool = false
var reloading: bool = false

var _owner: Node3D
var _camera: Camera3D
var _pivot: Node3D
var _view_model: Node3D
var _spread: float = 0.0
var _cooldown: float = 0.0
var _reload_left: float = 0.0
var _equip_left: float = 0.0
var _trigger_held: bool = false
var _holstered: bool = false
var _sway := Vector2.ZERO
var _anim: AnimationPlayer
var _fire_anim: String = ""
var _reload_anim: String = ""
var _scoped: bool = false
var _local_visuals: bool = true
var _recovery_left: float = 0.0
var _reload_duration: float = 0.0
var _stride_phase: float = 0.0
var _shot_index: int = 0
var muzzle_marker: Marker3D
var sight_node: Marker3D
var ejection_marker: Marker3D
var ads_blend: float = 0.0
var _ads_transform := Transform3D.IDENTITY
var _pose_transform := Transform3D.IDENTITY
var _position_spring := Spring.new()
var _rotation_spring := Spring.new()
var _look_motion := Vector2.ZERO
var _bob_strength: float = 0.0
var _rest_nodes: Dictionary = {}
var _weapon_layer: Node
var last_grenade: RigidBody3D

func setup(body: Node3D, camera: Camera3D, pivot: Node3D) -> void:
	_owner = body
	_camera = camera
	_pivot = pivot
	_local_visuals = body.local_control
	if _local_visuals:
		_create_weapon_layer()
	slots.resize(SLOT_COUNT)
	_owner.health.died.connect(_drop_on_death)
	reset_loadout()

## Возрождение выдаёт свежий комплект. Слоты чистятся полностью: give()
## на занятом слоте только докладывает патроны в резерв и не трогает магазин,
## поэтому после смерти оружие оставалось с теми же патронами, что и было.
func reset_loadout() -> void:
	_holstered = false
	_pending_slot = -1
	_holster_left = 0.0
	state = State.READY
	reloading = false
	_reload_left = 0.0
	_cooldown = 0.0
	_equip_left = 0.0
	_spread = 0.0
	_recovery_left = 0.0
	_shot_index = 0
	_reset_motion()
	_sway = Vector2.ZERO
	_scoped = false
	for i in SLOT_COUNT:
		slots[i] = null
	current_slot = 0
	give(default_primary, true)
	give(default_secondary, false)
	give(&"knife", false)
	give(&"grenade", false)
	_equip(0, true)
	scope_changed.emit(false)

func set_local_visuals(enabled: bool) -> void:
	_local_visuals = enabled
	_pivot.visible = enabled
	if enabled and _weapon_layer == null:
		_create_weapon_layer()
	if enabled and _view_model == null:
		_build_view_model(current_data())

func _create_weapon_layer() -> void:
	_weapon_layer = WeaponLayer.new()
	add_child(_weapon_layer)
	_weapon_layer.setup(_camera)

func _process(delta: float) -> void:
	if _weapon_layer == null:
		return
	if _local_visuals and not _holstered and _owner.is_physics_processing():
		_update_view_model(delta, _owner._movement_state())
	_weapon_layer.sync(_local_visuals and not _holstered and not _scoped)

func add_look_motion(motion: Vector2) -> void:
	_look_motion += motion

func add_landing_impact(speed: float) -> void:
	var strength := clampf((speed - 3.0) * 0.12, 0.0, 1.4)
	_position_spring.impulse(Vector3(0.0, -strength, strength * 0.2))
	_rotation_spring.impulse(Vector3(-strength * 0.4, 0, strength * 0.08))

func _reset_motion() -> void:
	_position_spring.reset()
	_rotation_spring.reset()
	ads_blend = 0.0
	_look_motion = Vector2.ZERO
	_sway = Vector2.ZERO
	_bob_strength = 0.0

## Кладёт ствол в его слот. Если такой же уже есть — только патроны.
func give(weapon_id: StringName, auto_equip: bool) -> bool:
	var data: WeaponData = Weapons.get_weapon(weapon_id)
	if data == null:
		return false
	var slot: int = int(data.slot)
	var existing = slots[slot]
	if existing != null and existing.data.id == data.id:
		if not data.is_firearm():
			if existing.mag >= data.magazine:
				return false
			existing.mag = data.magazine
			if slot == current_slot:
				ammo_changed.emit(existing.mag, existing.reserve)
			return true
		var before: int = existing.reserve
		existing.reserve = mini(existing.reserve + data.magazine, data.reserve_ammo)
		if existing.reserve == before:
			return false
		if slot == current_slot:
			ammo_changed.emit(existing.mag, existing.reserve)
		return true

	slots[slot] = {"data": data, "mag": data.magazine, "reserve": data.reserve_ammo}
	if auto_equip or slot == current_slot:
		_equip(slot, true)
	return true

func can_receive(weapon_id: StringName) -> bool:
	var data := Weapons.get_weapon(weapon_id)
	if data == null:
		return false
	var slot: int = int(data.slot)
	var existing = slots[slot]
	return existing == null or existing.data.id != data.id or (existing.reserve < data.reserve_ammo if data.is_firearm() else existing.mag < data.magazine)

func current() -> Dictionary:
	var slot = slots[current_slot]
	return slot if slot != null else {}

func current_data() -> WeaponData:
	var slot = slots[current_slot]
	return slot.data if slot != null else null

# --- покадровая логика -------------------------------------------------------

func player_tick(delta: float, state: Dictionary) -> void:
	if _holstered:
		return

	# Сохраняем остаток кадра: 720 RPM не должны превращаться в 600 при 60 Гц.
	_cooldown = maxf(_cooldown - delta, -delta)
	_equip_left = maxf(_equip_left - delta, 0.0)
	if _pending_slot >= 0:
		_holster_left -= delta
		if _holster_left <= 0.0:
			var next := _pending_slot
			_pending_slot = -1
			_equip(next, true)
	var can_input: bool = _owner.input_enabled and not _owner.shop_open and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED
	aiming = can_input and current_data() != null and current_data().is_firearm() and Input.is_action_pressed("aim") and _equip_left <= 0.0 and _pending_slot < 0 and not reloading
	_update_scope()

	_tick_reload(delta)
	_tick_spread(delta, state)
	if can_input:
		_read_weapon_input(state)
	_update_scope()
	var data := current_data()
	if data != null:
		spread_changed.emit(_current_spread(data, state))
	_update_state()

func _update_state() -> void:
	if _holstered:
		state = State.DISABLED
	elif _pending_slot >= 0:
		state = State.HOLSTERING
	elif _equip_left > 0.0:
		state = State.EQUIPPING
	elif reloading:
		state = State.RELOADING
	elif _cooldown > 0.0:
		state = State.FIRING
	else:
		state = State.READY

func _read_weapon_input(state: Dictionary) -> void:
	# Цифры при открытом магазине тратятся на покупку.
	if not _owner.get("shop_open"):
		if Input.is_action_just_pressed("slot_1"):
			_equip(0, false)
		elif Input.is_action_just_pressed("slot_2"):
			_equip(1, false)
		elif Input.is_action_just_pressed("slot_3"):
			_equip(2, false)
		elif Input.is_action_just_pressed("slot_4"):
			_equip(3, false)
		elif Input.is_action_just_pressed("slot_next"):
			_cycle_slot(1)
		elif Input.is_action_just_pressed("slot_prev"):
			_cycle_slot(-1)
		elif Input.is_action_just_pressed("drop_weapon"):
			drop_current()

	if Input.is_action_just_pressed("reload"):
		start_reload()

	var data := current_data()
	if data == null:
		return
	var pressed := Input.is_action_pressed("fire")
	var just := Input.is_action_just_pressed("fire")
	var wants_shot := pressed if data.fire_mode == WeaponData.FireMode.AUTO else just
	if wants_shot:
		_try_fire(state)
	_trigger_held = pressed

func _try_fire(state: Dictionary) -> void:
	var slot = slots[current_slot]
	if _holstered or _pending_slot >= 0 or not _owner.health.alive or slot == null or _cooldown > 0.00001 or _equip_left > 0.0:
		return
	var data: WeaponData = slot.data
	var match_flow := get_tree().get_first_node_in_group("match_flow")
	if match_flow != null and not match_flow.allows_combat():
		return
	if not data.is_firearm():
		_fire_equipment(data)
		return

	if reloading:
		# Уже вставленные патроны дробовика сохраняются при прерывании.
		if data.reload_per_shell and slot.mag > 0:
			_cancel_reload()
		else:
			return

	if slot.mag <= 0:
		_cooldown = 0.25
		Sfx.play_2d(&"empty", 1.0, -2.0)
		if slot.reserve > 0:
			start_reload()
		return

	slot.mag -= 1
	_cooldown = maxf(_cooldown, -0.05) + data.seconds_per_shot()
	ammo_changed.emit(slot.mag, slot.reserve)

	_fire_rays(data, state)

	# Повторяемый рисунок очереди можно освоить и компенсировать мышью.
	var side := data.recoil_side * sin(float(_shot_index) * 1.7)
	_shot_index += 1
	var aim_mult := lerpf(1.0, 0.7, ads_blend)
	recoil_kick.emit(data.recoil_up * aim_mult, side * aim_mult)
	_spread = minf(_spread + data.spread_per_shot, data.spread_max)
	_recovery_left = data.spread_recovery_delay
	var impulse_scale := (0.6 + data.recoil_up * 0.25) * lerpf(1.0, 0.35, ads_blend)
	_position_spring.impulse(Vector3(0.0, 0.12, 1.8) * impulse_scale)
	_rotation_spring.impulse(Vector3(1.0, side * 0.12, -side * 0.16) * impulse_scale)

	Sfx.play_shot(data.id, _muzzle_position(), data.shot_pitch)
	if is_instance_valid(ejection_marker):
		Effects.casing(_owner.get_tree().current_scene, ejection_marker.global_transform, data.pellets > 1)
	if muzzle_marker != null:
		Effects.muzzle_flash(muzzle_marker, Vector3.ZERO, WeaponLayer.MASK, 0.8 + data.recoil_up * 0.16)
	# Анимация выстрела ужимается под скорострельность, иначе на автомате
	# она не успевает доиграть и ствол «залипает».
	_play_anim(_fire_anim, minf(_cooldown * 0.95, 0.35))

	if data.fire_mode == WeaponData.FireMode.BOLT:
		_cooldown = maxf(_cooldown, 1.25)

func _fire_rays(data: WeaponData, state: Dictionary) -> void:
	var origin := _camera.global_position
	var forward := -_camera.global_transform.basis.z
	var spread_deg := _current_spread(data, state)
	var world := _owner.get_tree().current_scene
	var muzzle := _muzzle_position()
	# Дробь складывается по цели: иначе каждая из девяти дробин SPAS-12 уходит
	# отдельным надёжным RPC и отдельным хитмаркером.
	var tally: Dictionary = {}          # Node -> {"amount": float, "headshot": bool}

	for pellet in data.pellets:
		var dir := _spread_direction(forward, spread_deg)
		var hit := _cast(origin, dir, data.max_range)
		var end: Vector3 = hit.get("position", origin + dir * data.max_range)
		# Девять следов от одного залпа дроби закрывают собой саму цель.
		if pellet < TRACERS_PER_SHOT:
			Effects.tracer(world, muzzle, end)
		Effects.physical_hit(_owner, origin, end, minf(data.damage * 0.08, 6.0) / float(data.pellets))
		if pellet == 0:
			shot_fired.emit(String(data.id), muzzle, end)
		if hit.is_empty():
			continue
		_tally_hit(hit, data, origin, world, tally)

	for target in tally:
		_apply_tally(target, data, tally[target])

func _fire_equipment(data: WeaponData) -> void:
	var origin := _camera.global_position
	var forward := -_camera.global_basis.z
	if data.slot == WeaponData.Slot.GRENADE:
		if current().mag <= 0:
			return
		current().mag -= 1
		ammo_changed.emit(current().mag, current().reserve)
		var launch: Vector3 = forward * 16.0 + Vector3.UP * 3.0 + _owner.velocity * 0.4
		last_grenade = preload("res://scripts/thrown_grenade.gd").launch(_owner.get_tree().current_scene, _owner, origin, launch)
		equipment_used.emit(String(data.id), origin, launch)
		Sfx.play_2d(&"grenade", 1.0, -3.0)
	else:
		var hit := _cast(origin, forward, data.max_range)
		var tally: Dictionary = {}
		if not hit.is_empty():
			_tally_hit(hit, data, origin, _owner.get_tree().current_scene, tally)
		for target in tally:
			_apply_tally(target, data, tally[target])
		equipment_used.emit(String(data.id), origin, forward)
		Sfx.play_3d(&"melee", origin, 1.0, -4.0, 14.0)
	_cooldown = data.seconds_per_shot()
	_position_spring.impulse(Vector3(-0.7, 0.3, -2.8))
	_rotation_spring.impulse(Vector3(-1.8, 2.5, -1.0))
	_update_state()

func _cycle_slot(direction: int) -> void:
	for step in range(1, SLOT_COUNT + 1):
		var index := posmod(current_slot + step * direction, SLOT_COUNT)
		if slots[index] != null:
			_equip(index, false)
			return

## Exact magazine/reserve survives a drop. Taking a duplicate only transfers
## the ammunition that fits; the remainder stays on the ground.
func receive_drop(id: StringName, mag: int, reserve: int) -> Vector2i:
	var data := Weapons.get_weapon(id)
	if data == null or not data.is_firearm():
		return Vector2i(mag, reserve)
	var previous = slots[int(data.slot)]
	if previous != null and previous.data.id == id:
		var taken := mini(mag + reserve, data.reserve_ammo - int(previous.reserve))
		previous.reserve += taken
		if current_slot == int(data.slot):
			ammo_changed.emit(previous.mag, previous.reserve)
		var left := mag + reserve - taken
		return Vector2i(mini(mag, left), maxi(left - mag, 0))
	if previous != null:
		_spawn_drop(previous)
	slots[int(data.slot)] = {"data": data, "mag": clampi(mag, 0, data.magazine), "reserve": clampi(reserve, 0, data.reserve_ammo)}
	_equip(int(data.slot), true)
	return Vector2i.ZERO

func _spawn_drop(slot: Dictionary) -> void:
	if not _owner.local_control or not slot.data.is_firearm():
		return
	var at := Transform3D(_owner.global_basis, _owner.global_position + Vector3.UP * 1.1)
	var motion: Vector3 = _owner.velocity - _owner.global_basis.z * 2.0 + Vector3.UP
	if Session.is_online():
		var inventory := get_tree().get_first_node_in_group("world_inventory")
		if inventory != null:
			inventory.request_drop(String(slot.data.id), slot.mag, slot.reserve, at, motion)
	else:
		WeaponPickup.spawn_drop(_owner.get_tree().current_scene, slot.data.id, slot.mag, slot.reserve, at, motion)

func drop_current() -> void:
	var data := current_data()
	if data == null or not data.is_firearm() or _holstered:
		return
	_spawn_drop(current())
	slots[current_slot] = null
	_cancel_reload()
	_equip(int(WeaponData.Slot.MELEE), true)

func _drop_on_death(_attacker: Node) -> void:
	for slot in slots:
		if slot != null:
			_spawn_drop(slot)

func _cast(origin: Vector3, dir: Vector3, distance: float) -> Dictionary:
	var space := _owner.get_world_3d().direct_space_state
	return Damage.raycast(space, origin, origin + dir * distance, _owner)

## Эффекты рисуются на каждую дробину, урон только копится.
func _tally_hit(hit: Dictionary, data: WeaponData, origin: Vector3, world: Node, tally: Dictionary) -> void:
	var point: Vector3 = hit.position
	var body: Node = Damage.resolve_target(hit.collider)
	var target_health := Damage.find_health(body)
	# Труп — не плоть: иначе выстрел в него глотается кровавыми искрами вместо
	# отметины на поверхности.
	var is_flesh := target_health != null and target_health.alive

	Effects.impact(world, point, hit.normal, is_flesh, body)
	if body is RigidBody3D:
		body.apply_impulse(origin.direction_to(point) * minf(data.damage * 0.08, 6.0), point - body.global_position)
	if not is_flesh:
		return

	var zone := Damage.hit_zone(hit.collider, point)
	var headshot := zone == &"head"
	var amount := data.damage_at(origin.distance_to(point)) * Damage.zone_multiplier(data, zone)

	var row: Dictionary = tally.get(body, {"amount": 0.0, "headshot": false})
	row.amount += amount
	row.headshot = bool(row.headshot) or headshot
	tally[body] = row

func _apply_tally(body: Node, data: WeaponData, row: Dictionary) -> void:
	if not is_instance_valid(body):
		return
	var headshot: bool = row.headshot
	var dealt := Damage.apply(body, row.amount, _owner, headshot, data.armor_penetration, String(data.id))
	if Damage._net_wrapper(body) != null and not body.local_control:
		return # Подтверждение попадания придёт от владельца цели.
	if dealt <= 0.0:
		return
	var target_health := Damage.find_health(body)
	var killed := target_health != null and not target_health.alive
	Sfx.play_2d(&"kill" if killed else (&"headshot" if headshot else &"hit"), 1.0, -4.0)
	hit_confirmed.emit(headshot, killed)

# --- разброс и перезарядка ---------------------------------------------------

func _tick_spread(delta: float, _state: Dictionary) -> void:
	var data := current_data()
	if data == null:
		return
	var recovery_delta := maxf(delta - _recovery_left, 0.0)
	_recovery_left = maxf(_recovery_left - delta, 0.0)
	_spread = maxf(_spread - data.spread_recovery * recovery_delta, 0.0)
	if _spread <= 0.0 and _recovery_left <= 0.0:
		_shot_index = 0

## Итоговый разброс: база + движение + прыжок, с поправкой на присед и прицел.
func _current_spread(data: WeaponData, state: Dictionary) -> float:
	var spread := data.spread_base + _spread
	var speed: float = state.get("speed", 0.0)
	spread += data.spread_move * clampf(speed / 6.0, 0.0, 1.4)
	if not state.get("on_floor", true):
		spread += data.spread_air
	if state.get("crouching", false):
		spread *= data.spread_crouch_mult
	if aiming:
		spread *= lerpf(1.0, data.spread_aim_mult, ads_blend)
	return spread

func _spread_direction(forward: Vector3, spread_deg: float) -> Vector3:
	if spread_deg <= 0.0001:
		return forward
	var angle := deg_to_rad(spread_deg) * sqrt(randf())
	var roll := randf() * TAU
	var basis_x := forward.cross(Vector3.UP)
	if basis_x.length_squared() < 0.0001:
		basis_x = Vector3.RIGHT
	basis_x = basis_x.normalized()
	var basis_y := basis_x.cross(forward).normalized()
	var offset := (basis_x * cos(roll) + basis_y * sin(roll)) * tan(angle)
	return (forward + offset).normalized()

func start_reload() -> void:
	var slot = slots[current_slot]
	if _holstered or slot == null or reloading or _equip_left > 0.0 or _pending_slot >= 0:
		return
	var data: WeaponData = slot.data
	if not data.is_firearm():
		return
	if slot.mag >= data.magazine or slot.reserve <= 0:
		return
	reloading = true
	_reload_duration = data.shell_reload_time if data.reload_per_shell else data.reload_time
	_reload_left = _reload_duration
	aiming = false
	_update_scope()
	Sfx.play_2d(&"reload", 1.0, -2.0)
	_animate_reload(_reload_duration)

func _tick_reload(delta: float) -> void:
	if not reloading:
		return
	_reload_left -= delta
	if _reload_left > 0.0:
		return
	var slot = slots[current_slot]
	if slot == null:
		_cancel_reload()
		return
	var data: WeaponData = slot.data
	if data.reload_per_shell:
		# Учитываем остаток времени, чтобы низкая частота кадров не теряла патроны.
		while _reload_left <= 0.0 and slot.mag < data.magazine and slot.reserve > 0:
			slot.mag += 1
			slot.reserve -= 1
			_reload_left += maxf(data.shell_reload_time, 0.05)
		Sfx.play_2d(&"reload", 1.2, -4.0)
		ammo_changed.emit(slot.mag, slot.reserve)
		if slot.mag >= data.magazine or slot.reserve <= 0:
			_cancel_reload()
		else:
			_animate_reload(_reload_left)
		return
	_restore_weapon_pose()
	reloading = false
	_reload_left = 0.0
	var needed: int = data.magazine - slot.mag
	var taken: int = mini(needed, slot.reserve)
	slot.mag += taken
	slot.reserve -= taken
	Sfx.play_2d(&"reload", 1.2, -4.0)
	ammo_changed.emit(slot.mag, slot.reserve)

func _cancel_reload() -> void:
	if reloading:
		_restore_weapon_pose()
	reloading = false
	_reload_left = 0.0

func reload_progress() -> float:
	return clampf(1.0 - _reload_left / maxf(_reload_duration, 0.001), 0.0, 1.0) if reloading else 0.0

func _equip(slot_index: int, force: bool) -> void:
	if slot_index < 0 or slot_index >= SLOT_COUNT:
		return
	if slots[slot_index] == null:
		return
	if slot_index == current_slot and not force:
		return
	if not force:
		_cancel_reload()
		aiming = false
		_pending_slot = slot_index
		_holster_left = 0.16
		_update_state()
		return
	_pending_slot = -1
	_cancel_reload()
	aiming = false
	current_slot = slot_index
	_update_scope()
	var data: WeaponData = slots[slot_index].data
	_equip_left = data.equip_time
	_spread = 0.0
	_recovery_left = 0.0
	_shot_index = 0
	_reset_motion()
	_build_view_model(data)
	weapon_changed.emit(data)
	ammo_changed.emit(slots[slot_index].mag, slots[slot_index].reserve)
	_update_state()

func holster() -> void:
	_holstered = true
	_pending_slot = -1
	state = State.DISABLED
	aiming = false
	_cancel_reload()
	_update_scope()
	if _view_model != null:
		_view_model.visible = false
	_reset_motion()

# --- то, что спрашивает игрок ------------------------------------------------

func speed_multiplier() -> float:
	var data := current_data()
	var mult: float = data.move_speed_mult if data != null else 1.0
	if aiming:
		mult *= 0.55
	return mult

func target_fov(base_fov: float) -> float:
	if not aiming:
		return base_fov
	var data := current_data()
	return data.aim_fov if data != null else base_fov

func recoil_recovery() -> float:
	var data := current_data()
	return data.recoil_recovery if data != null else 6.0

func is_aiming() -> bool:
	return aiming

func ammo_text() -> String:
	var slot = slots[current_slot]
	if slot == null:
		return "-- / --"
	return "%d / %d" % [slot.mag, slot.reserve]

# --- вид от первого лица -----------------------------------------------------

## Модель оружия: анимированная из пака, если она указана в WeaponData,
## иначе силуэт из примитивов по длине ствола.
func _build_view_model(data: WeaponData) -> void:
	if not _local_visuals or data == null:
		return
	if _view_model != null:
		_view_model.visible = false
		_view_model.queue_free()
	_view_model = Node3D.new()
	_view_model.name = "Viewmodel"
	_pivot.add_child(_view_model)
	_anim = null
	_fire_anim = ""
	_reload_anim = ""
	muzzle_marker = null
	sight_node = null
	ejection_marker = null
	_rest_nodes.clear()

	if data.model_path != "" and ResourceLoader.exists(data.model_path):
		var scene: PackedScene = load(data.model_path)
		var model := scene.instantiate() as Node3D
		if model != null:
			# Два уровня: внешний узел двигают прицеливание и покачивание,
			# внутренний отвечает за масштаб и раскладку модели.
			var holder := Node3D.new()
			_view_model.add_child(holder)
			holder.add_child(model)
			ViewModel.fit(holder, model, data)
			for node in ViewModel.walk(model):
				if node is Node3D:
					_rest_nodes[node] = node.transform
			ViewModel.attach_hands(_view_model, data, model)
			_anim = _find_animation_player(model)
			_fire_anim = _resolve_anim(data.anim_fire, ["FireWBullet", "Fire"])
			_reload_anim = _resolve_anim(data.anim_reload, ["Reload"])
			_prepare_fire_animation()
			for node in _walk(model):
				if node is GeometryInstance3D:
					node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			_finish_view_model(model, data)
			return

	_build_primitive_model(data)
	_finish_view_model(null, data)

func _finish_view_model(model: Node3D, data: WeaponData) -> void:
	_view_model.transform = Transform3D.IDENTITY
	var markers := ViewModel.attach_markers(_view_model, model, data)
	muzzle_marker = markers[0]
	sight_node = markers[1]
	ejection_marker = markers[2]
	var sight_rest := _view_model.global_transform.affine_inverse() * sight_node.global_transform
	sight_rest.basis = sight_rest.basis.orthonormalized()
	_ads_transform = Transform3D(Basis.IDENTITY, Vector3(0.0, 0.0, -data.ads_eye_distance)) * sight_rest.affine_inverse()
	_pose_transform = Transform3D(Basis.from_euler(Vector3(0.35, -0.07, 0.0)), HIP_POSITION + Vector3(0, -0.18, 0.08))
	_view_model.transform = _pose_transform
	WeaponLayer.tag(_view_model)

## Запечённый клип оставляем для затвора/спуска. Движение всего оружия делает
## пружина, иначе две независимые отдачи уводят мушку и маркер в разные стороны.
func _prepare_fire_animation() -> void:
	if _anim == null or _fire_anim.is_empty():
		return
	var clip: Animation = _anim.get_animation(_fire_anim).duplicate()
	for track in range(clip.get_track_count() - 1, -1, -1):
		var path := clip.track_get_path(track)
		if path.get_subname_count() == 0 or path.get_subname(0) == "Control":
			clip.remove_track(track)
	clip.loop_mode = Animation.LOOP_NONE
	var library := AnimationLibrary.new()
	library.add_animation("fire", clip)
	_anim.add_animation_library("viewmodel", library)
	_fire_anim = "viewmodel/fire"

func _restore_weapon_pose() -> void:
	if _anim != null:
		_anim.stop()
	for node in _rest_nodes:
		node.transform = _rest_nodes[node]
		if node is Skeleton3D:
			node.reset_bone_poses()
			node.force_update_all_bone_transforms()

func _build_primitive_model(data: WeaponData) -> void:

	var mat := StandardMaterial3D.new()
	mat.albedo_color = data.body_color
	mat.metallic = 0.6
	mat.roughness = 0.45

	var dark := StandardMaterial3D.new()
	dark.albedo_color = data.body_color.darkened(0.45)
	dark.metallic = 0.5
	dark.roughness = 0.5
	if not data.is_firearm():
		ViewModel.attach_hands(_view_model, data)
		if data.slot == WeaponData.Slot.MELEE:
			_add_box(Vector3(0.027, 0.035, 0.12), Vector3(0, 0, 0), dark)
			_add_box(Vector3(0.07, 0.012, 0.025), Vector3(0, 0.018, -0.08), dark)
			_add_box(Vector3(0.04, 0.007, 0.22), Vector3(0, 0.02, -0.19), mat)
		else:
			var sphere := MeshInstance3D.new()
			var mesh := SphereMesh.new()
			mesh.radius = 0.047
			mesh.height = 0.12
			sphere.mesh = mesh
			sphere.material_override = mat
			_view_model.add_child(sphere)
			_add_box(Vector3(0.02, 0.025, 0.04), Vector3(0, 0.07, 0), dark)
		return

	# Пропорции считаются от длины ствола; модель начинается у казённика
	# и уходит вперёд, иначе у камеры (near = 5 см) она выглядит бревном.
	var l := data.length
	_add_box(Vector3(0.045, 0.062, l * 0.45), Vector3(0, 0, -l * 0.28), mat)
	_add_box(Vector3(0.022, 0.024, l * 0.8), Vector3(0, 0.026, -l * 0.62), dark)
	_add_box(Vector3(0.035, 0.1, 0.05), Vector3(0, -0.075, -l * 0.16), dark)
	if data.slot == WeaponData.Slot.PRIMARY:
		_add_box(Vector3(0.04, 0.12, 0.04), Vector3(0, -0.07, -l * 0.45), mat)
		_add_box(Vector3(0.045, 0.065, 0.16), Vector3(0, -0.01, 0.02), dark)
	if data.has_scope:
		_add_box(Vector3(0.036, 0.036, l * 0.3), Vector3(0, 0.062, -l * 0.35), dark)

	_view_model.position = HIP_POSITION
	_view_model.rotation = Vector3(0.0, -0.07, 0.0)

func _add_box(size: Vector3, offset: Vector3, mat: Material) -> void:
	var mesh := BoxMesh.new()
	mesh.size = size
	var node := MeshInstance3D.new()
	node.mesh = mesh
	node.material_override = mat
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	node.position = offset
	_view_model.add_child(node)

func _update_view_model(delta: float, state: Dictionary) -> void:
	if _view_model == null:
		return
	var data := current_data()
	if data == null:
		return
	ads_blend = lerpf(ads_blend, 1.0 if aiming else 0.0, 1.0 - exp(-data.ads_speed * delta))
	_update_scope()
	_view_model.visible = not _scoped and not _holstered

	# Базовая поза не содержит пружину: накопление ошибки transform исключено.
	var target_pos := HIP_POSITION
	var target_rot := Vector3(0.0, -0.07, 0.0)
	if not aiming and state.get("sprinting", false) and state.get("speed", 0.0) > 4.0:
		target_pos = SPRINT_POSITION
		target_rot = Vector3(0.0, -0.5, 0.35)
	if reloading:
		var reload_arc := sin(reload_progress() * PI)
		target_pos += Vector3(0.0, -0.07 - reload_arc * 0.03, 0.03)
		target_rot += Vector3(0.15, 0.0, -reload_arc * 0.12)
	if _equip_left > 0.0:
		var draw_amount := clampf(_equip_left / maxf(data.equip_time, 0.001), 0.0, 1.0)
		target_pos += Vector3(0.0, -0.22, 0.12) * draw_amount
		target_rot.x += 0.45 * draw_amount
	if _pending_slot >= 0:
		var lower := 1.0 - clampf(_holster_left / 0.16, 0.0, 1.0)
		target_pos += Vector3(0, -0.25, 0.12) * lower
		target_rot.x += lower * 0.5
	var target := Transform3D(Basis.from_euler(target_rot), target_pos)
	target = target.interpolate_with(_ads_transform, ads_blend)
	_pose_transform = _pose_transform.interpolate_with(target, 1.0 - exp(-22.0 * delta))

	var speed: float = state.get("speed", 0.0)
	_stride_phase += speed * delta * 1.8
	var bob_amount := clampf(speed / 5.4, 0.0, 1.5) if state.get("on_floor", true) else 0.0
	_bob_strength = lerpf(_bob_strength, bob_amount, 1.0 - exp(-10.0 * delta))
	var steadiness := lerpf(1.0, 0.035, ads_blend)
	var bob := Vector3(sin(_stride_phase) * 0.009, cos(_stride_phase * 2.0) * 0.008, 0.0) * _bob_strength * steadiness
	var mouse_speed := _look_motion / maxf(delta, 0.001) * 0.000018
	_look_motion = Vector2.ZERO
	_sway = _sway.lerp(mouse_speed.clamp(Vector2(-0.04, -0.04), Vector2(0.04, 0.04)), 1.0 - exp(-10.0 * delta))
	var offset := _position_spring.step(delta) + bob + Vector3(-_sway.x, _sway.y, 0.0) * steadiness
	var angles := _rotation_spring.step(delta) + Vector3(_sway.y, -_sway.x, -_sway.x * 0.3) * steadiness
	_view_model.transform = _pose_transform * Transform3D(Basis.from_euler(angles), offset)
	ViewModel.update_hands(_view_model)

func _find_animation_player(root: Node) -> AnimationPlayer:
	for node in _walk(root):
		if node is AnimationPlayer:
			return node
	return null

## Имена анимаций в паках идут с префиксом арматуры ("RifleArmature|Reload"),
## причём у одной модели префикс даже с пробелом. Поэтому ищем по подстроке,
## а не по точному совпадению; явное имя в WeaponData имеет приоритет.
func _resolve_anim(override: String, keywords: Array) -> String:
	if _anim == null:
		return ""
	var available := _anim.get_animation_list()
	if override != "" and available.has(override):
		return override
	for keyword in keywords:
		for name in available:
			if name.containsn(keyword):
				return name
	return ""

func _walk(node: Node) -> Array[Node]:
	var out: Array[Node] = [node]
	for child in node.get_children():
		out.append_array(_walk(child))
	return out

## speed < 0 — подогнать анимацию под заданную длительность.
func _play_anim(anim_name: String, duration: float) -> bool:
	if _anim == null or anim_name == "":
		return false
	var anim := _anim.get_animation(anim_name)
	if anim == null:
		return false
	_anim.stop()
	if duration > 0.0:
		_anim.speed_scale = anim.length / duration
	else:
		_anim.speed_scale = 1.0
	_anim.play(anim_name)
	return true

func _animate_reload(duration: float) -> void:
	# Только внутренние кости: внешний transform обновляет _update_view_model.
	_play_anim(_reload_anim, duration)

func _muzzle_position() -> Vector3:
	if is_instance_valid(muzzle_marker):
		return muzzle_marker.global_position
	return _camera.global_position

## Оптика: в прицеливании модель убирается с экрана, вместо неё окуляр.
func _update_scope() -> void:
	var data := current_data()
	var active: bool = aiming and ads_blend > 0.94 and data != null and data.has_scope
	if active == _scoped:
		return
	_scoped = active
	if _view_model != null:
		_view_model.visible = not active
	scope_changed.emit(active)
