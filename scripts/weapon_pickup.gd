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
var network_drop_id: String = ""
var dropped: bool = false
var stored_mag: int = 0
var stored_reserve: int = 0

func _ready() -> void:
	collision_layer = 1 << 3      # слой pickup
	collision_mask = 0
	monitorable = true
	monitoring = false
	if dropped:
		var shape := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = Vector3(0.8, 0.45, 0.8)
		shape.shape = box
		add_child(shape)
		return
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
	if who is PlayerCharacter and not who.health.alive:
		return
	var manager = who.get("weapons")
	if not network_drop_id.is_empty():
		if who is PlayerCharacter and who.local_control and manager.can_receive(weapon_id):
			var inventory := get_tree().get_first_node_in_group("world_inventory")
			if inventory != null:
				inventory.request_pickup(network_drop_id)
		return
	if network_index >= 0:
		if who is PlayerCharacter and who.local_control and who.health.alive and manager.can_receive(weapon_id):
			Session.net.request_pickup(network_index)
		return
	if dropped:
		if manager == null or not manager.can_receive(weapon_id):
			return
		var data := Weapons.get_weapon(weapon_id)
		var previous = manager.slots[int(data.slot)]
		var same_weapon: bool = previous != null and previous.data.id == weapon_id
		var left: Vector2i = manager.receive_drop(weapon_id, stored_mag, stored_reserve)
		if same_weapon and left == Vector2i(stored_mag, stored_reserve):
			return
		stored_mag = left.x
		stored_reserve = left.y
		Sfx.play_3d(&"pickup", global_position, 1.0, -2.0)
		picked_up.emit(weapon_id, who)
		if left == Vector2i.ZERO:
			_available = false
			get_parent().queue_free()
		return
	if manager == null or not manager.give(weapon_id, true):
		return
	_available = false
	_model.visible = false
	Sfx.play_3d(&"pickup", global_position, 1.0, -2.0)
	picked_up.emit(weapon_id, who)
	get_tree().create_timer(respawn_delay).timeout.connect(_restore)

func interaction_text(who: PlayerCharacter) -> String:
	if not _available:
		return ""
	var data := Weapons.get_weapon(weapon_id)
	if data == null:
		return ""
	if not who.weapons.can_receive(weapon_id):
		return "%s · Боезапас полон" % data.display_name
	var slot_index := int(data.slot)
	var slot = who.weapons.slots[slot_index]
	if slot != null and slot.data.id == weapon_id:
		return "[E] Патроны · %s" % data.display_name
	return "[E] Подобрать %s" % data.display_name

func set_available(value: bool) -> void:
	_available = value
	if _model != null:
		_model.visible = value
	if dropped and get_parent() is RigidBody3D:
		get_parent().visible = value
	collision_layer = 8 if value else 0

static func spawn_drop(world: Node, id: StringName, mag: int, reserve: int, at: Transform3D, motion: Vector3, net_id: String = "") -> WeaponPickup:
	var data := Weapons.get_weapon(id)
	if data == null or not data.is_firearm():
		return null
	var drops := world.get_tree().get_nodes_in_group("dropped_weapons")
	if drops.size() >= 24 and net_id.is_empty():
		drops[0].queue_free()
	var body := RigidBody3D.new()
	body.name = "DroppedWeapon"
	body.mass = 2.5
	body.collision_layer = 16
	body.collision_mask = 1
	body.continuous_cd = true
	body.angular_damp = 1.5
	body.set_meta("surface", "metal")
	var collision := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(0.12, 0.16, data.length)
	collision.shape = box
	body.add_child(collision)
	var holder := Node3D.new()
	body.add_child(holder)
	if ResourceLoader.exists(data.model_path):
		var model := (load(data.model_path) as PackedScene).instantiate() as Node3D
		holder.add_child(model)
		ViewModel.fit(holder, model, data)
	var pickup := WeaponPickup.new()
	pickup.dropped = true
	pickup.weapon_id = id
	pickup.stored_mag = clampi(mag, 0, data.magazine)
	pickup.stored_reserve = clampi(reserve, 0, data.reserve_ammo)
	pickup.network_drop_id = net_id
	body.add_child(pickup)
	world.add_child(body)
	body.global_transform = at.orthonormalized()
	body.linear_velocity = motion.limit_length(12.0)
	body.angular_velocity = Vector3(2, 3, 1)
	body.add_to_group("dropped_weapons")
	if net_id.is_empty():
		var lifetime := body.create_tween()
		lifetime.tween_interval(30.0)
		lifetime.tween_callback(body.queue_free)
	return pickup

func _restore() -> void:
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
