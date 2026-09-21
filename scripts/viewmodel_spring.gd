## Аналитическое решение затухающей пружины: одинаковая отдача при любом FPS.
extends RefCounted

var value := Vector3.ZERO
var velocity := Vector3.ZERO
var frequency: float = 28.0
var damping: float = 0.78

func impulse(amount: Vector3) -> void:
	velocity += amount

func reset() -> void:
	value = Vector3.ZERO
	velocity = Vector3.ZERO

func step(delta: float) -> Vector3:
	var decay := damping * frequency
	var oscillation := frequency * sqrt(1.0 - damping * damping)
	var envelope := exp(-decay * delta)
	var sine := sin(oscillation * delta)
	var cosine := cos(oscillation * delta)
	var next := (value * cosine + (velocity + value * decay) * sine / oscillation) * envelope
	velocity = (velocity * cosine - (velocity * decay + value * frequency * frequency) * sine / oscillation) * envelope
	value = next
	return value
