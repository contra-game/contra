## Оптика снайперской винтовки: всё вне окуляра затемняется, в центре —
## перекрестие с рисками. Показывается только когда в руках ствол с прицелом.
class_name ScopeOverlay
extends Control

const RING := Color(0.02, 0.02, 0.03)
const LINE := Color(0.05, 0.06, 0.05, 0.9)

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	get_viewport().size_changed.connect(_resize)
	_resize()
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	z_index = -1 # Статус, попадания и меню остаются поверх оптики.
	visible = false

func _resize() -> void:
	size = get_viewport_rect().size
	queue_redraw()

func _draw() -> void:
	var centre := size * 0.5
	var radius: float = minf(size.x, size.y) * 0.42

	# Сплошная круглая маска: прямоугольные углы не просвечивают.
	var outside := size.length()
	for i in 128:
		var a := Vector2.from_angle(TAU * float(i) / 128.0)
		var b := Vector2.from_angle(TAU * float(i + 1) / 128.0)
		draw_colored_polygon(PackedVector2Array([
			centre + a * radius, centre + a * outside,
			centre + b * outside, centre + b * radius]), RING)
	draw_arc(centre, radius, 0.0, TAU, 128, RING, 8.0, true)

	# Перекрестие во всю ширину окуляра и риски по вертикали.
	draw_line(Vector2(centre.x - radius, centre.y), Vector2(centre.x + radius, centre.y), LINE, 1.5)
	draw_line(Vector2(centre.x, centre.y - radius), Vector2(centre.x, centre.y + radius), LINE, 1.5)
	draw_circle(centre, 2.0, Color(0.85, 0.22, 0.12))
	for i in range(1, 5):
		var offset := radius * 0.16 * i
		var width := radius * 0.05
		draw_line(Vector2(centre.x - width, centre.y + offset), Vector2(centre.x + width, centre.y + offset), LINE, 1.5)
