## Направление источников урона относительно текущего взгляда.
##
## Источников несколько намеренно: под перекрёстным огнём одна запись показала
## бы только последнего стрелка — ровно в той ситуации, где индикатор нужнее.
extends Control

const LIFETIME := 1.1
const LIMIT := 4
## Радиус дуги в долях меньшей стороны экрана, а не в пикселях: иначе на 4K
## индикатор оказывается вплотную к прицелу.
const RADIUS_RATIO := 0.11

var camera: Camera3D
## Записи вида {"position": Vector3, "time_left": float}, свежие в конце.
var sources: Array[Dictionary] = []

## Оставлено для регресс-проверок и сброса при возрождении.
var time_left: float = 0.0:
	get:
		var longest := 0.0
		for entry in sources:
			longest = maxf(longest, entry["time_left"])
		return longest
	set(value):
		if value <= 0.0:
			sources.clear()

func show_damage(source: Vector3) -> void:
	sources.append({"position": source, "time_left": LIFETIME})
	while sources.size() > LIMIT:
		sources.pop_front()
	queue_redraw()

func _process(delta: float) -> void:
	if sources.is_empty():
		return
	var index := sources.size() - 1
	while index >= 0:
		sources[index]["time_left"] -= delta
		if sources[index]["time_left"] <= 0.0:
			sources.remove_at(index)
		index -= 1
	queue_redraw()

func _draw() -> void:
	if sources.is_empty() or not is_instance_valid(camera):
		return
	var basis := camera.global_transform.basis
	var right := basis.x
	var forward := -basis.z
	right.y = 0.0
	forward.y = 0.0
	if right.length_squared() < 0.001 or forward.length_squared() < 0.001:
		return
	right = right.normalized()
	forward = forward.normalized()
	var radius := minf(size.x, size.y) * RADIUS_RATIO
	for entry in sources:
		var direction: Vector3 = entry["position"] - camera.global_position
		direction.y = 0.0
		if direction.length_squared() < 0.001:
			continue
		var angle := atan2(direction.dot(right), direction.dot(forward)) - PI * 0.5
		var alpha: float = minf(entry["time_left"] * 2.5, 1.0)
		draw_arc(size * 0.5, radius, angle - 0.3, angle + 0.3, 20, Color(1.0, 0.25, 0.16, alpha), 5.0, true)
