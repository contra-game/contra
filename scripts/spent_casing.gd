## Локальная гильза: сталкивается с картой, но не мешает игрокам и лучам.
extends RigidBody3D

var age: float = 0.0
var _rang: bool = false

func _ready() -> void:
	contact_monitor = true
	max_contacts_reported = 1
	body_entered.connect(_on_contact)

func activate(at: Transform3D) -> void:
	age = 0.0
	_rang = false
	global_transform = at.orthonormalized()
	freeze = false
	sleeping = false
	collision_mask = 1
	linear_velocity = at.basis.orthonormalized() * Vector3(randf_range(1.5, 2.5), randf_range(1.0, 1.8), randf_range(0.2, 0.8))
	angular_velocity = Vector3(8, 13, 5)
	set_physics_process(true)

func _on_contact(_body: Node) -> void:
	if _rang or age < 0.06:
		return
	_rang = true
	Sfx.play_3d(&"casing", global_position, randf_range(0.9, 1.3), -16.0, 10.0)

func _physics_process(delta: float) -> void:
	age += delta
