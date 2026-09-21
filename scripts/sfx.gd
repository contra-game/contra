## Autoload "Sfx" — звук игры.
##
## Выстрелы берутся из записанных CC0-сэмплов (assets/sfx/weapons), а всё
## остальное — попадания, шаги, перезарядка — синтезируется кодом в _ready().
## Если wav-файла для ствола нет, выстрел тоже синтезируется, так что проект
## запускается даже с пустой папкой ассетов.
extends Node

const SAMPLE_RATE := 22050
const VOLUME_DB := -8.0
const WEAPON_SFX_DIR := "res://assets/sfx/weapons/"
const WEAPON_SFX_VARIANTS := 2

const POOL_3D := 24
const POOL_2D := 8
const OCCLUDED_BUS := &"CombatOccluded"
const OCCLUSION_INTERVAL := 0.12
const OCCLUSION_LOSS_DB := -12.0

var _bank: Dictionary = {}
var _weapon_shots: Dictionary = {}     # StringName -> Array[AudioStream]
var _rng := RandomNumberGenerator.new()
var _pool_3d: Array[AudioStreamPlayer3D] = []
var _pool_2d: Array[AudioStreamPlayer] = []
var _next_3d: int = 0
var _next_2d: int = 0
var _occlusion_clock := 0.0
var _scene_id := 0

func _ready() -> void:
	_rng.randomize()
	_bank["shot"] = _render(_gen_shot, 0.30, 0.45)
	_bank["hit"] = _render(_gen_hit, 0.09, 0.0)
	_bank["headshot"] = _render(_gen_headshot, 0.22, 0.0)
	_bank["reload"] = _render(_gen_reload, 0.14, 0.2)
	_bank["empty"] = _render(_gen_empty, 0.06, 0.0)
	_bank["step"] = _render(_gen_step, 0.10, 0.6)
	_bank["death"] = _render(_gen_death, 0.45, 0.3)
	_bank["pickup"] = _render(_gen_pickup, 0.20, 0.0)
	_bank["impact_metal"] = _render(_gen_metal, 0.25, 0.0)
	_bank["impact_stone"] = _render(_gen_stone, 0.16, 0.0)
	_bank["casing"] = _render(_gen_casing, 0.16, 0.0)
	_bank["step_concrete"] = _bank["step"]
	_bank["step_metal"] = _render(_gen_step_metal, 0.17, 0.1)
	_bank["step_earth"] = _render(_gen_step_earth, 0.16, 0.7)
	_bank["kill"] = _render(_gen_kill, 0.28, 0.0)
	_bank["melee"] = _render(_gen_melee, 0.22, 0.45)
	_bank["grenade"] = _render(_gen_grenade, 0.20, 0.15)
	_bank["explosion"] = _render(_gen_explosion, 0.95, 0.5)
	_setup_occlusion_bus()

	# Пул вместо узла на каждый звук: восемь ботов с автоматами создавали и
	# освобождали десятки AudioStreamPlayer3D в секунду. Узлы живут под
	# автозагрузкой и переживают смену сцены — World3D у корневого окна тот же.
	for i in POOL_3D:
		var p3 := AudioStreamPlayer3D.new()
		p3.unit_size = 10.0
		add_child(p3)
		_pool_3d.append(p3)
	for i in POOL_2D:
		var p2 := AudioStreamPlayer.new()
		add_child(p2)
		_pool_2d.append(p2)

func _setup_occlusion_bus() -> void:
	if AudioServer.get_bus_index(OCCLUDED_BUS) >= 0:
		return
	var index := AudioServer.bus_count
	AudioServer.add_bus(index)
	AudioServer.set_bus_name(index, OCCLUDED_BUS)
	AudioServer.set_bus_send(index, &"Master")
	var filter := AudioEffectLowPassFilter.new()
	filter.cutoff_hz = 1600.0
	filter.resonance = 0.5
	AudioServer.add_bus_effect(index, filter)

func _physics_process(delta: float) -> void:
	var scene := get_tree().current_scene
	var current_id := scene.get_instance_id() if is_instance_valid(scene) else 0
	if current_id != _scene_id:
		# Scene ownership is recorded on each voice: a shot started from _ready
		# in the new scene must not be stopped together with the previous match.
		for voice in _pool_3d:
			if voice.get_meta("scene_id", current_id) != current_id:
				voice.stop()
		_scene_id = current_id
	_occlusion_clock -= delta
	if _occlusion_clock > 0.0:
		return
	_occlusion_clock = OCCLUSION_INTERVAL
	for voice in _pool_3d:
		if voice.playing:
			_update_occlusion(voice)

## Only world geometry occludes; players and cosmetic bodies do not.
func is_occluded(world: Node3D, listener: Vector3, source: Vector3) -> bool:
	if not is_instance_valid(world) or not world.is_inside_tree() or listener.distance_squared_to(source) < 0.04:
		return false
	var direction := listener.direction_to(source)
	var ray := PhysicsRayQueryParameters3D.create(listener + direction * 0.04, source - direction * 0.04, 1)
	return not world.get_world_3d().direct_space_state.intersect_ray(ray).is_empty()

func _update_occlusion(voice: AudioStreamPlayer3D) -> void:
	var camera := get_viewport().get_camera_3d()
	var blocked := camera != null and is_occluded(camera, camera.global_position, voice.global_position)
	voice.bus = OCCLUDED_BUS if blocked else &"Master"
	voice.volume_db = float(voice.get_meta("base_db", VOLUME_DB)) + (OCCLUSION_LOSS_DB if blocked else 0.0)
	voice.set_meta("occluded", blocked)

func footstep_surface(actor: Node3D) -> StringName:
	if not is_instance_valid(actor) or not actor.is_inside_tree():
		return &"concrete"
	var ray := PhysicsRayQueryParameters3D.create(actor.global_position + Vector3.UP * 0.3, actor.global_position - Vector3.UP * 0.8, 1)
	var hit := actor.get_world_3d().direct_space_state.intersect_ray(ray)
	if hit.is_empty():
		return &"concrete"
	match Effects.surface(hit.collider):
		"metal": return &"metal"
		"earth", "dirt", "ground", "grass", "sand": return &"earth"
	return &"concrete"

func play_footstep(actor: Node3D, landing: bool = false) -> void:
	if not is_instance_valid(actor) or not actor.is_inside_tree():
		return
	var kind := footstep_surface(actor)
	play_3d(StringName("step_" + kind), actor.global_position + Vector3.UP * 0.15,
		0.75 if landing else _rng.randf_range(0.9, 1.1), 0.0 if landing else -4.0, 32.0 if landing else 25.0)

## Выстрел конкретного ствола: записанный сэмпл, если он есть.
func play_shot(weapon_id: StringName, position: Vector3, pitch: float = 1.0) -> void:
	var variants := _shots_for(weapon_id)
	if variants.is_empty():
		play_3d(&"shot", position, pitch, 0.0, 140.0)
		return
	_spawn_3d(variants.pick_random(), position, pitch, 0.0, 140.0)

func play_3d(sound: StringName, position: Vector3, pitch: float = 1.0, db_offset: float = 0.0, max_distance: float = 70.0) -> void:
	var stream: AudioStream = _bank.get(sound)
	if stream != null:
		_spawn_3d(stream, position, pitch, db_offset, max_distance)

func play_2d(sound: StringName, pitch: float = 1.0, db_offset: float = 0.0) -> void:
	var stream: AudioStream = _bank.get(sound)
	if stream == null:
		return
	var p := _take_2d()
	p.stream = stream
	p.pitch_scale = pitch * _rng.randf_range(0.97, 1.03)
	p.volume_db = VOLUME_DB + db_offset
	p.play()

func _spawn_3d(stream: AudioStream, position: Vector3, pitch: float, db_offset: float, max_distance: float) -> void:
	var p := _take_3d()
	p.stream = stream
	p.pitch_scale = pitch * _rng.randf_range(0.96, 1.04)
	p.volume_db = VOLUME_DB + db_offset
	p.max_distance = max_distance
	p.global_position = position
	p.set_meta("base_db", VOLUME_DB + db_offset)
	var scene := get_tree().current_scene
	p.set_meta("scene_id", scene.get_instance_id() if is_instance_valid(scene) else 0)
	_update_occlusion(p)
	p.play()

## Свободный слот, иначе самый старый по кругу: обрыв далёкого звука слышно
## меньше, чем просадку от аллокаций.
func _take_3d() -> AudioStreamPlayer3D:
	for i in _pool_3d.size():
		var index := (_next_3d + i) % _pool_3d.size()
		if not _pool_3d[index].playing:
			_next_3d = (index + 1) % _pool_3d.size()
			return _pool_3d[index]
	var oldest := _pool_3d[_next_3d]
	_next_3d = (_next_3d + 1) % _pool_3d.size()
	return oldest

func _take_2d() -> AudioStreamPlayer:
	for i in _pool_2d.size():
		var index := (_next_2d + i) % _pool_2d.size()
		if not _pool_2d[index].playing:
			_next_2d = (index + 1) % _pool_2d.size()
			return _pool_2d[index]
	var oldest := _pool_2d[_next_2d]
	_next_2d = (_next_2d + 1) % _pool_2d.size()
	return oldest

## Ленивая загрузка сэмплов ствола; пустой массив — сэмплов нет.
func _shots_for(weapon_id: StringName) -> Array:
	if _weapon_shots.has(weapon_id):
		return _weapon_shots[weapon_id]
	var list: Array = []
	for i in range(1, WEAPON_SFX_VARIANTS + 1):
		var path := "%s%s_%d.wav" % [WEAPON_SFX_DIR, weapon_id, i]
		if ResourceLoader.exists(path):
			var res := load(path)
			if res is AudioStream:
				list.append(res)
	_weapon_shots[weapon_id] = list
	return list

# --- синтез ------------------------------------------------------------------

func _gen_step_metal(t: float) -> float:
	return _noise() * exp(-t * 55.0) * 0.28 + (sin(TAU * 430.0 * t) + sin(TAU * 870.0 * t) * 0.35) * exp(-t * 25.0) * 0.16

func _gen_step_earth(t: float) -> float:
	return _noise() * exp(-t * 25.0) * (0.25 + 0.1 * sin(TAU * 80.0 * t))

func _gen_kill(t: float) -> float:
	return (sin(TAU * 1000.0 * t) + 0.6 * sin(TAU * 1500.0 * t)) * exp(-t * 14.0) * 0.25

func _gen_melee(t: float) -> float:
	return _noise() * sin(PI * minf(t / 0.22, 1.0)) * exp(-t * 7.0) * 0.5

func _gen_grenade(t: float) -> float:
	return _noise() * exp(-t * 40.0) * 0.3 + sin(TAU * 2200.0 * t) * exp(-t * 70.0) * 0.15

func _gen_explosion(t: float) -> float:
	return _noise() * exp(-t * 7.0) * 0.8 + sin(TAU * 55.0 * t) * exp(-t * 5.0) * 0.4

func _gen_metal(t: float) -> float:
	return _noise() * exp(-t * 110.0) * 0.5 + (sin(TAU * 1850.0 * t) + sin(TAU * 2910.0 * t) * 0.4) * exp(-t * 26.0) * 0.35

func _gen_stone(t: float) -> float:
	return _noise() * exp(-t * 42.0) * 0.7 + sin(TAU * 160.0 * t) * exp(-t * 65.0) * 0.3

func _gen_casing(t: float) -> float:
	return (sin(TAU * 3100.0 * t) + sin(TAU * 4300.0 * t) * 0.35) * exp(-t * 42.0) * 0.3

func _gen_shot(t: float) -> float:
	var env := exp(-t * 19.0)
	var crack := _noise() * env
	var body := sin(TAU * 85.0 * t) * exp(-t * 26.0)
	var tail := _noise() * exp(-t * 5.0) * 0.18
	return (crack * 1.15 + body * 0.7 + tail) * 0.9

func _gen_hit(t: float) -> float:
	var env := exp(-t * 55.0)
	return (_noise() * 0.6 + sin(TAU * 420.0 * t) * 0.5) * env

func _gen_headshot(t: float) -> float:
	return sin(TAU * 1500.0 * t + sin(TAU * 40.0 * t)) * exp(-t * 14.0) * 0.55

func _gen_reload(t: float) -> float:
	var click := 0.4 if t < 0.02 else 0.0
	return (_noise() * 0.5 + click) * exp(-t * 40.0)

func _gen_empty(t: float) -> float:
	return _noise() * exp(-t * 90.0) * 0.5

func _gen_step(t: float) -> float:
	return _noise() * exp(-t * 38.0) * 0.35

func _gen_death(t: float) -> float:
	var f := lerpf(220.0, 60.0, minf(t * 3.0, 1.0))
	return (sin(TAU * f * t) * 0.6 + _noise() * 0.2) * exp(-t * 6.0)

func _gen_pickup(t: float) -> float:
	var f := lerpf(600.0, 1200.0, minf(t * 6.0, 1.0))
	return sin(TAU * f * t) * exp(-t * 11.0) * 0.4

# --- инфраструктура ----------------------------------------------------------

func _noise() -> float:
	return _rng.randf_range(-1.0, 1.0)

## generator(t) -> float в диапазоне [-1, 1]; smoothing работает как простой ФНЧ.
func _render(generator: Callable, duration: float, smoothing: float) -> AudioStreamWAV:
	var count := int(SAMPLE_RATE * duration)
	var data := PackedByteArray()
	data.resize(count * 2)
	var prev := 0.0
	for i in count:
		var sample: float = generator.call(float(i) / SAMPLE_RATE)
		prev = lerpf(sample, prev, clampf(smoothing, 0.0, 0.95))
		# Мягкий фейд в конце, чтобы не щёлкало на обрыве сэмпла.
		var fade := clampf(float(count - i) / 120.0, 0.0, 1.0)
		data.encode_s16(i * 2, int(clampf(prev * fade, -1.0, 1.0) * 30000.0))
	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = SAMPLE_RATE
	stream.stereo = false
	stream.data = data
	return stream
