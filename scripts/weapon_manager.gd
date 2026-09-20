## Инвентарь и стрельба: два слота, хитскан с разбросом, отдача, перезарядка.
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

const SLOT_COUNT := 2
const HIT_MASK := 1 | 2 | 4        # мир + игроки + боты

## Положения модели оружия относительно камеры.
const HIP_POSITION := Vector3(0.18, -0.13, -0.45)
const AIM_POSITION := Vector3(0.0, -0.05, -0.35)

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
var _kick: float = 0.0
var _anim: AnimationPlayer
var _fire_anim: String = ""
var _reload_anim: String = ""
var _scoped: bool = false
var _local_visuals: bool = true

func setup(body: Node3D, camera: Camera3D, pivot: Node3D) -> void:
	_owner = body
	_camera = camera
	_pivot = pivot
	_local_visuals = body.local_control
	slots.resize(SLOT_COUNT)
	reset_loadout()

## Возрождение выдаёт свежий комплект. Слоты чистятся полностью: give()
## на занятом слоте только докладывает патроны в резерв и не трогает магазин,
## поэтому после смерти оружие оставалось с теми же патронами, что и было.
func reset_loadout() -> void:
	_holstered = false
	reloading = false
	_reload_left = 0.0
	_cooldown = 0.0
	_equip_left = 0.0
	_spread = 0.0
	_scoped = false
	for i in SLOT_COUNT:
		slots[i] = null
	current_slot = 0
	give(default_primary, true)
	give(default_secondary, false)
	_equip(0, true)
	scope_changed.emit(false)

func set_local_visuals(enabled: bool) -> void:
	_local_visuals = enabled
	_pivot.visible = enabled
	if enabled and _view_model == null:
		_build_view_model(current_data())

## Кладёт ствол в его слот. Если такой же уже есть — только патроны.
func give(weapon_id: StringName, auto_equip: bool) -> bool:
	var data: WeaponData = Weapons.get_weapon(weapon_id)
	if data == null:
		return false
	var slot: int = 0 if data.slot == WeaponData.Slot.PRIMARY else 1
	var existing = slots[slot]
	if existing != null and existing.data.id == data.id:
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
	var slot: int = 0 if data.slot == WeaponData.Slot.PRIMARY else 1
	var existing = slots[slot]
	return existing == null or existing.data.id != data.id or existing.reserve < data.reserve_ammo

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

	_cooldown = maxf(_cooldown - delta, 0.0)
	_equip_left = maxf(_equip_left - delta, 0.0)
	var can_input: bool = _owner.input_enabled and not _owner.shop_open and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED
	aiming = can_input and Input.is_action_pressed("aim") and _equip_left <= 0.0 and not reloading
	_update_scope()

	_tick_reload(delta)
	_tick_spread(delta, state)
	if can_input:
		_read_weapon_input(state)
	_update_view_model(delta, state)

func _read_weapon_input(state: Dictionary) -> void:
	# Цифры при открытом магазине тратятся на покупку.
	if not _owner.get("shop_open"):
		if Input.is_action_just_pressed("slot_1"):
			_equip(0, false)
		elif Input.is_action_just_pressed("slot_2"):
			_equip(1, false)
		elif Input.is_action_just_pressed("slot_next"):
			_equip((current_slot + 1) % SLOT_COUNT, false)
		elif Input.is_action_just_pressed("slot_prev"):
			_equip((current_slot + SLOT_COUNT - 1) % SLOT_COUNT, false)

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
	if slot == null or _cooldown > 0.0 or _equip_left > 0.0:
		return
	var data: WeaponData = slot.data

	if reloading:
		# Болтовки и дробовики прерывают перезарядку выстрелом — привычно по CS.
		if slot.mag > 0:
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
	_cooldown = data.seconds_per_shot()
	ammo_changed.emit(slot.mag, slot.reserve)

	_fire_rays(data, state)

	# Отдача: вверх всегда, вбок — случайно в обе стороны.
	var side := data.recoil_side * randf_range(-1.0, 1.0)
	var aim_mult: float = 0.7 if aiming else 1.0
	recoil_kick.emit(data.recoil_up * aim_mult, side * aim_mult)
	_spread = minf(_spread + data.spread_per_shot, data.spread_max)
	_kick = 1.0

	Sfx.play_shot(data.id, _muzzle_position(), data.shot_pitch)
	Effects.muzzle_flash(_pivot, Vector3(0, 0, -data.length))
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

	for pellet in data.pellets:
		var dir := _spread_direction(forward, spread_deg)
		var hit := _cast(origin, dir, data.max_range)
		var end: Vector3 = hit.get("position", origin + dir * data.max_range)
		Effects.tracer(world, _muzzle_position(), end)
		if pellet == 0:
			shot_fired.emit(String(data.id), _muzzle_position(), end)
		if hit.is_empty():
			continue
		_resolve_hit(hit, data, origin, world)

func _cast(origin: Vector3, dir: Vector3, distance: float) -> Dictionary:
	var space := _owner.get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.create(origin, origin + dir * distance)
	query.collision_mask = HIT_MASK
	query.exclude = [_owner.get_rid()]
	return space.intersect_ray(query)

func _resolve_hit(hit: Dictionary, data: WeaponData, origin: Vector3, world: Node) -> void:
	var point: Vector3 = hit.position
	var normal: Vector3 = hit.normal
	var body: Node = hit.collider
	var target_health := Damage.find_health(body)
	var is_flesh := target_health != null

	Effects.impact(world, point, normal, is_flesh)
	if not is_flesh:
		Sfx.play_3d(&"step", point, randf_range(1.4, 1.8), -6.0, 40.0)
		return

	var crouched: bool = body.get("crouching") if body.get("crouching") != null else false
	var headshot := Damage.is_headshot(body, point, crouched)
	var amount := data.damage_at(origin.distance_to(point))
	if headshot:
		amount *= data.headshot_multiplier

	var dealt := Damage.apply(body, amount, _owner, headshot, data.armor_penetration)
	if Damage._net_wrapper(body) != null and not body.local_control:
		return # Подтверждение попадания придёт от владельца цели.
	if dealt <= 0.0:
		return

	var killed := not target_health.alive
	Sfx.play_2d(&"headshot" if headshot else &"hit", 1.0, -4.0)
	hit_confirmed.emit(headshot, killed)

# --- разброс и перезарядка ---------------------------------------------------

func _tick_spread(delta: float, state: Dictionary) -> void:
	var data := current_data()
	if data == null:
		return
	_spread = maxf(_spread - data.spread_recovery * delta, 0.0)
	spread_changed.emit(_current_spread(data, state))

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
		spread *= data.spread_aim_mult
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
	if slot == null or reloading or _equip_left > 0.0:
		return
	var data: WeaponData = slot.data
	if slot.mag >= data.magazine or slot.reserve <= 0:
		return
	reloading = true
	_reload_left = data.reload_time
	aiming = false
	Sfx.play_2d(&"reload", 1.0, -2.0)
	_animate_reload(data.reload_time)

func _tick_reload(delta: float) -> void:
	if not reloading:
		return
	_reload_left -= delta
	if _reload_left > 0.0:
		return
	reloading = false
	var slot = slots[current_slot]
	if slot == null:
		return
	var data: WeaponData = slot.data
	var needed: int = data.magazine - slot.mag
	var taken: int = mini(needed, slot.reserve)
	slot.mag += taken
	slot.reserve -= taken
	Sfx.play_2d(&"reload", 1.2, -4.0)
	ammo_changed.emit(slot.mag, slot.reserve)

func _cancel_reload() -> void:
	reloading = false
	_reload_left = 0.0

func _equip(slot_index: int, force: bool) -> void:
	if slot_index < 0 or slot_index >= SLOT_COUNT:
		return
	if slots[slot_index] == null:
		return
	if slot_index == current_slot and not force:
		return
	_cancel_reload()
	aiming = false
	current_slot = slot_index
	_update_scope()
	var data: WeaponData = slots[slot_index].data
	_equip_left = data.equip_time
	_spread = 0.0
	_build_view_model(data)
	weapon_changed.emit(data)
	ammo_changed.emit(slots[slot_index].mag, slots[slot_index].reserve)

func holster() -> void:
	_holstered = true
	aiming = false
	_cancel_reload()
	_update_scope()
	if _view_model != null:
		_view_model.visible = false

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
	_pivot.add_child(_view_model)
	_anim = null

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
			ViewModel.attach_hands(_view_model, data)
			_anim = _find_animation_player(model)
			_fire_anim = _resolve_anim(data.anim_fire, ["FireWBullet", "Fire"])
			_reload_anim = _resolve_anim(data.anim_reload, ["Reload"])
			for node in _walk(model):
				if node is GeometryInstance3D:
					node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			_view_model.position = HIP_POSITION
			_view_model.rotation = Vector3(0.0, -0.07, 0.0)
			return

	_build_primitive_model(data)

func _build_primitive_model(data: WeaponData) -> void:

	var mat := StandardMaterial3D.new()
	mat.albedo_color = data.body_color
	mat.metallic = 0.6
	mat.roughness = 0.45

	var dark := StandardMaterial3D.new()
	dark.albedo_color = data.body_color.darkened(0.45)
	dark.metallic = 0.5
	dark.roughness = 0.5

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
	if _scoped:
		return
	_view_model.visible = true
	_kick = lerpf(_kick, 0.0, delta * 12.0)

	# Прицеливание подтягивает ствол к центру экрана, бег — уводит вбок.
	var target_pos := HIP_POSITION
	var target_rot := Vector3.ZERO
	if aiming:
		target_pos = AIM_POSITION
	elif state.get("sprinting", false) and state.get("speed", 0.0) > 4.0:
		target_pos = SPRINT_POSITION
		target_rot = Vector3(0.0, -0.5, 0.35)
	if reloading:
		target_pos += Vector3(0.0, -0.12, 0.06)
		target_rot += Vector3(0.6, 0.0, 0.0)

	# Небольшое запаздывание модели за поворотом мыши.
	var mouse_delta := Input.get_last_mouse_velocity() * 0.000018
	_sway = _sway.lerp(Vector2(clampf(mouse_delta.x, -0.05, 0.05), clampf(mouse_delta.y, -0.05, 0.05)), delta * 6.0)

	target_pos += Vector3(-_sway.x, -_sway.y, _kick * 0.06)
	target_rot += Vector3(_kick * 0.12, _sway.x * 2.0, 0.0)

	var t := clampf(delta * 14.0, 0.0, 1.0)
	_view_model.position = _view_model.position.lerp(target_pos, t)
	_view_model.rotation = _view_model.rotation.lerp(target_rot, t)

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
	if _play_anim(_reload_anim, duration):
		return
	if _view_model == null:
		return
	var tween := _view_model.create_tween()
	tween.tween_property(_view_model, "rotation:x", 0.7, duration * 0.3)
	tween.tween_interval(duration * 0.35)
	tween.tween_property(_view_model, "rotation:x", 0.0, duration * 0.35)

func _muzzle_position() -> Vector3:
	var data := current_data()
	var length: float = data.length if data != null else 0.6
	return _camera.global_position - _camera.global_transform.basis.z * (length + 0.2) - _camera.global_transform.basis.y * 0.08

## Оптика: в прицеливании модель убирается с экрана, вместо неё окуляр.
func _update_scope() -> void:
	var data := current_data()
	var active: bool = aiming and data != null and data.has_scope
	if active == _scoped:
		return
	_scoped = active
	if _view_model != null:
		_view_model.visible = not active
	scope_changed.emit(active)
