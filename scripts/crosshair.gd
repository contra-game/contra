## Прицел, который расходится ровно на текущий разброс оружия:
## штрихи стоят там, куда реально может уйти пуля.
class_name Crosshair
extends Control

const THICKNESS := 2.0
const LENGTH := 7.0
const MIN_GAP := 4.0
const COLOR := Color(0.85, 0.95, 0.85, 0.9)

var spread_degrees: float = 0.5
var fov_degrees: float = 85.0

var _hit_time: float = 0.0
var _hit_headshot: bool = false
var _hit_kill: bool = false

func _ready() -> void:
	set_process(true)

func _process(delta: float) -> void:
	if _hit_time > 0.0:
		_hit_time = maxf(_hit_time - delta, 0.0)
		queue_redraw()

func set_spread(degrees: float) -> void:
	if absf(degrees - spread_degrees) < 0.01:
		return
	spread_degrees = degrees
	queue_redraw()

func show_hitmarker(headshot: bool, killed: bool) -> void:
	_hit_time = 0.35
	_hit_headshot = headshot
	_hit_kill = killed
	queue_redraw()

func _draw() -> void:
	var center := size * 0.5
	var gap := MIN_GAP + _spread_pixels()

	draw_rect(Rect2(center - Vector2(1, 1), Vector2(2, 2)), COLOR)
	for dir: Vector2 in [Vector2.UP, Vector2.DOWN, Vector2.LEFT, Vector2.RIGHT]:
		var from := center + dir * gap
		var to := from + dir * LENGTH
		draw_line(from, to, Color(0, 0, 0, 0.55), THICKNESS + 2.0)
		draw_line(from, to, COLOR, THICKNESS)

	if _hit_time > 0.0:
		var alpha := clampf(_hit_time / 0.35, 0.0, 1.0)
		var color := Color(1.0, 0.25, 0.2, alpha) if _hit_kill else (Color(1.0, 0.85, 0.3, alpha) if _hit_headshot else Color(1.0, 1.0, 1.0, alpha))
		var reach: float = 12.0 if _hit_kill else 9.0
		for diagonal: Vector2 in [Vector2(1, 1), Vector2(1, -1), Vector2(-1, 1), Vector2(-1, -1)]:
			var from := center + diagonal * 5.0
			draw_line(from, from + diagonal * reach, color, 2.5)

## Угловой разброс в пиксели экрана с учётом текущего поля зрения.
func _spread_pixels() -> float:
	var half_fov := deg_to_rad(fov_degrees) * 0.5
	if half_fov <= 0.0:
		return 0.0
	return (size.y * 0.5) * tan(deg_to_rad(spread_degrees)) / tan(half_fov)
