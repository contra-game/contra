## Прицел, который расходится ровно на текущий разброс оружия:
## штрихи стоят там, куда реально может уйти пуля.
class_name Crosshair
extends Control

const THICKNESS := 2.0
const LENGTH := 7.0
const MIN_GAP := 4.0
const COLOR := Color(0.85, 0.95, 0.85, 0.9)

const HIT_TIME := 0.35
## Штрихи хитмаркера разъезжаются из центра за это время, дальше только гаснут.
const HIT_GROWTH := 0.06
## Скорость схлопывания зазора, доля остатка в секунду.
const SPREAD_SETTLE := 14.0

var spread_degrees: float = 0.5
var fov_degrees: float = 85.0
var reticle_alpha: float = 1.0

var _drawn_spread: float = 0.5
var _hit_time: float = 0.0
var _hit_headshot: bool = false
var _hit_kill: bool = false

func _ready() -> void:
	set_process(true)

func _process(delta: float) -> void:
	if _hit_time > 0.0:
		_hit_time = maxf(_hit_time - delta, 0.0)
		queue_redraw()
	if not is_equal_approx(_drawn_spread, spread_degrees):
		_drawn_spread = lerpf(_drawn_spread, spread_degrees, 1.0 - exp(-SPREAD_SETTLE * delta))
		if absf(_drawn_spread - spread_degrees) < 0.01:
			_drawn_spread = spread_degrees
		queue_redraw()

## Расширение мгновенное, схлопывание плавное. Сглаживать рост нельзя: прицел
## показал бы разброс меньше настоящего ровно в тот момент, когда игрок решает,
## стрелять ли дальше. Отставание при схлопывании врёт в безопасную сторону.
func set_spread(degrees: float) -> void:
	if absf(degrees - spread_degrees) < 0.01:
		return
	spread_degrees = degrees
	if degrees > _drawn_spread:
		_drawn_spread = degrees
		queue_redraw()

## Разброс считается в пикселях от углового, поэтому прицелу нужен текущий fov:
## в оптике и в прицеливании он другой.
func set_fov(degrees: float) -> void:
	if absf(degrees - fov_degrees) < 0.01:
		return
	fov_degrees = degrees
	queue_redraw()

func set_reticle_alpha(value: float) -> void:
	if is_equal_approx(reticle_alpha, value):
		return
	reticle_alpha = value
	queue_redraw()

func show_hitmarker(headshot: bool, killed: bool) -> void:
	_hit_time = HIT_TIME
	_hit_headshot = headshot
	_hit_kill = killed
	queue_redraw()

## Доля от полного размера штрихов хитмаркера: 0 в момент попадания, 1 после
## фазы роста. Вынесено из _draw, чтобы рост можно было проверить.
func hit_growth() -> float:
	if _hit_time <= 0.0:
		return 0.0
	return clampf((HIT_TIME - _hit_time) / HIT_GROWTH, 0.0, 1.0)

func _draw() -> void:
	var center := size * 0.5
	var gap := MIN_GAP + _spread_pixels()

	var reticle_color := Color(COLOR, COLOR.a * reticle_alpha)
	draw_rect(Rect2(center - Vector2(1, 1), Vector2(2, 2)), reticle_color)
	for dir: Vector2 in [Vector2.UP, Vector2.DOWN, Vector2.LEFT, Vector2.RIGHT]:
		var from := center + dir * gap
		var to := from + dir * LENGTH
		draw_line(from, to, Color(0, 0, 0, 0.55 * reticle_alpha), THICKNESS + 2.0)
		draw_line(from, to, reticle_color, THICKNESS)

	if _hit_time > 0.0:
		# Первые кадры штрихи выезжают из центра, дальше держат размер и гаснут.
		var growth := hit_growth()
		var alpha := clampf(_hit_time / (HIT_TIME - HIT_GROWTH), 0.0, 1.0)
		var color := Color(1.0, 0.25, 0.2, alpha) if _hit_kill else (Color(1.0, 0.85, 0.3, alpha) if _hit_headshot else Color(1.0, 1.0, 1.0, alpha))
		var reach: float = 12.0 if _hit_kill else 9.0
		for diagonal: Vector2 in [Vector2(1, 1), Vector2(1, -1), Vector2(-1, 1), Vector2(-1, -1)]:
			var from := center + diagonal * 5.0 * growth
			draw_line(from, from + diagonal * reach * growth, color, 2.5)

## Угловой разброс в пиксели экрана с учётом текущего поля зрения.
func _spread_pixels() -> float:
	var half_fov := deg_to_rad(fov_degrees) * 0.5
	if half_fov <= 0.0:
		return 0.0
	return (size.y * 0.5) * tan(deg_to_rad(_drawn_spread)) / tan(half_fov)
