## Летящий след пули: сегмент постоянной длины идёт от дула к точке попадания.
##
## Скорость намеренно нереалистичная. Настоящая пуля проходит типичные 30 м боя
## за 0.09 с, а четыре метра — за 0.012 с, то есть меньше одного кадра: след был
## бы невидим именно там, где по нему считывают направление огня.
extends MeshInstance3D

const SPEED := 140.0
const MAX_LENGTH := 6.0
const MIN_DURATION := 0.05
const MAX_DURATION := 0.35

var _origin := Vector3.ZERO
var _direction := Vector3.FORWARD
var _distance: float = 0.0
var _length: float = 0.0
var _travelled: float = 0.0
var _speed: float = 0.0

## Сколько след будет лететь: пул гасит узел ровно через это время.
static func duration_for(distance: float) -> float:
	return clampf(distance / SPEED, MIN_DURATION, MAX_DURATION)

func activate(from: Vector3, to: Vector3) -> void:
	_distance = from.distance_to(to)
	if _distance < 0.001:
		set_process(false)
		return
	_origin = from
	_direction = (to - from) / _distance
	_length = minf(MAX_LENGTH, _distance)
	_speed = _distance / duration_for(_distance)
	# След вылетает уже прочерченным: иначе первый кадр он нулевой длины.
	_travelled = minf(_length * 0.35, _distance)
	_apply()
	set_process(true)

func _process(delta: float) -> void:
	# Пул мог погасить узел раньше, чем след долетел.
	if not visible:
		set_process(false)
		return
	_travelled += _speed * delta
	if _travelled >= _distance:
		set_process(false)
		return
	_apply()

## Хвост не выезжает назад за дуло, голова — вперёд за точку попадания.
func _apply() -> void:
	var head := minf(_travelled, _distance)
	var tail := maxf(head - _length, 0.0)
	var span := head - tail
	if span < 0.001:
		return
	var up := Vector3.UP if absf(_direction.dot(Vector3.UP)) < 0.98 else Vector3.FORWARD
	global_transform = Transform3D(
		Basis.looking_at(_direction, up).scaled_local(Vector3(1, 1, span)),
		_origin + _direction * (tail + span * 0.5))
