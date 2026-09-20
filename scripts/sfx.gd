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

var _bank: Dictionary = {}
var _weapon_shots: Dictionary = {}     # StringName -> Array[AudioStream]
var _rng := RandomNumberGenerator.new()

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
	var p := AudioStreamPlayer.new()
	p.stream = stream
	p.pitch_scale = pitch * _rng.randf_range(0.97, 1.03)
	p.volume_db = VOLUME_DB + db_offset
	add_child(p)
	p.finished.connect(p.queue_free)
	p.play()

func _spawn_3d(stream: AudioStream, position: Vector3, pitch: float, db_offset: float, max_distance: float) -> void:
	var root := _sound_root()
	if root == null:
		return
	var p := AudioStreamPlayer3D.new()
	p.stream = stream
	p.pitch_scale = pitch * _rng.randf_range(0.96, 1.04)
	p.volume_db = VOLUME_DB + db_offset
	p.max_distance = max_distance
	p.unit_size = 10.0
	root.add_child(p)
	p.global_position = position
	p.finished.connect(p.queue_free)
	p.play()

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

func _sound_root() -> Node:
	var tree := get_tree()
	if tree == null:
		return null
	return tree.current_scene if tree.current_scene != null else tree.root

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
