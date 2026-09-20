## Оптика снайперской винтовки: всё вне окуляра затемняется, в центре —
## перекрестие с рисками. Показывается только когда в руках ствол с прицелом.
class_name ScopeOverlay
extends Control

const RING := Color(0.02, 0.02, 0.03)
const LINE := Color(0.05, 0.06, 0.05, 0.9)

func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	visible = false

func _draw() -> void:
	var centre := size * 0.5
	var radius: float = minf(size.x, size.y) * 0.42

	# Затемнение по углам: четыре прямоугольника вокруг окуляра плюс кольцо.
	draw_rect(Rect2(0, 0, size.x, centre.y - radius), RING)
	draw_rect(Rect2(0, centre.y + radius, size.x, size.y - centre.y - radius), RING)
	draw_rect(Rect2(0, centre.y - radius, centre.x - radius, radius * 2.0), RING)
	draw_rect(Rect2(centre.x + radius, centre.y - radius, size.x - centre.x - radius, radius * 2.0), RING)
	draw_arc(centre, radius, 0.0, TAU, 96, RING, radius * 0.22, true)

	# Перекрестие во всю ширину окуляра и риски по вертикали.
	draw_line(Vector2(centre.x - radius, centre.y), Vector2(centre.x + radius, centre.y), LINE, 1.5)
	draw_line(Vector2(centre.x, centre.y - radius), Vector2(centre.x, centre.y + radius), LINE, 1.5)
	for i in range(1, 5):
		var offset := radius * 0.16 * i
		var width := radius * 0.05
		draw_line(Vector2(centre.x - width, centre.y + offset), Vector2(centre.x + width, centre.y + offset), LINE, 1.5)
