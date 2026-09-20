## Ствол, лежащий на карте. Подбирается по E, после подбора уходит в
## перезапуск и возвращается через respawn_delay — как точки оружия в аренах.
class_name WeaponPickup
extends Area3D

signal picked_up(weapon_id: StringName, by: Node)

@export var weapon_id: StringName = &"ak47"
@export var respawn_delay: float = 12.0

var _model: Node3D
var _available: bool = true
var _spin: float = 0.0
var network_index: int = -1

func _ready() -> void:
	collision_layer = 1 << 3      # слой pickup
	collision_mask = 0
	monitorable = true
	monitoring = false
	_build()

func setup(id: StringName) -> void:
	weapon_id = id
	if is_inside_tree():
		_build()

func _process(delta: float) -> void:
	if _model == null:
		return
	_spin += delta * 1.6
	_model.rotation.y = _spin
	_model.position.y = sin(_spin * 1.5) * 0.08

## Вызывается игроком из луча взаимодействия.
func pick_up(who: Node) -> void:
	if not _available or who == null:
		return
	var manager = who.get("weapons")
	if network_index >= 0:
		if who is PlayerCharacter and who.local_control and who.health.alive and manager.can_receive(weapon_id):
			Session.net.request_pickup(network_index)
		return
	if manager == null or not manager.give(weapon_id, true):
		return
	_available = false
	_model.visible = false
	Sfx.play_3d(&"pickup", global_position, 1.0, -2.0)
	picked_up.emit(weapon_id, who)
	get_tree().create_timer(respawn_delay).timeout.connect(_restore)

func set_available(value: bool) -> void:
	_available = value
	if _model != null:
		_model.visible = value

func _restore() -> void:
	if not is_instance_valid(self):
		return
	_available = true
	if _model != null:
		_model.visible = true
	Sfx.play_3d(&"pickup", global_position, 0.7, -12.0, 20.0)

func _build() -> void:
	for child in get_children():
		child.queue_free()

	var data: WeaponData = Weapons.get_weapon(weapon_id)
	var color: Color = data.body_color if data != null else Color(0.3, 0.3, 0.3)
	var length: float = data.length if data != null else 0.6

	_model = Node3D.new()
	add_child(_model)

	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.metallic = 0.7
	mat.roughness = 0.35
	mat.emission_enabled = true
	mat.emission = color
	mat.emission_energy_multiplier = 0.35

	_add_box(Vector3(length, 0.09, 0.07), Vector3.ZERO, mat)
	_add_box(Vector3(length * 0.3, 0.16, 0.05), Vector3(-length * 0.2, -0.1, 0.0), mat)

	# Подсветка снизу, чтобы точку было видно издалека.
	var glow := OmniLight3D.new()
	glow.light_color = color.lightened(0.4)
	glow.light_energy = 1.6
	glow.omni_range = 4.0
	_model.add_child(glow)

	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(1.2, 1.0, 1.2)
	shape.shape = box
	add_child(shape)

func _add_box(size: Vector3, offset: Vector3, mat: Material) -> void:
	var mesh := BoxMesh.new()
	mesh.size = size
	var node := MeshInstance3D.new()
	node.mesh = mesh
	node.material_override = mat
	node.position = offset
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_model.add_child(node)
