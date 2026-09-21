## Physics-timed locomotion blending; the combat skeleton modifier adds aim/IK.
extends AnimationTree

var move_speed: float = 0.0
var backward: bool = false
var airborne: bool = false
var _ground_blend: float = 0.0
var _air_blend: float = 0.0
var _was_airborne: bool = false

func _ready() -> void:
	callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
	active = true

func set_locomotion(velocity: Vector3, in_air: bool, alive: bool) -> void:
	move_speed = Vector2(velocity.x, velocity.z).length()
	airborne = in_air
	active = alive

func _physics_process(delta: float) -> void:
	if not active:
		return
	var blend := 1.0 - exp(-12.0 * delta)
	_ground_blend = lerpf(_ground_blend, clampf(move_speed / 2.2, 0.0, 1.0), blend)
	_air_blend = lerpf(_air_blend, 1.0 if airborne else 0.0, blend)
	set("parameters/Ground/blend_amount", _ground_blend)
	set("parameters/Air/blend_amount", _air_blend)
	set("parameters/Stride/scale", clampf(move_speed / 4.2, 0.45, 1.8) * (-1.0 if backward else 1.0))
	if airborne and not _was_airborne:
		set("parameters/JumpStart/seek_request", 0.0)
	_was_airborne = airborne
	advance(delta)
