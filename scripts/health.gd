## Здоровье + броня. Висит на игроке и на боте, поэтому правила урона
## одинаковы для всех. Урон применяется только на авторитете (сервере),
## см. Damage.apply() в scripts/damage.gd.
class_name Health
extends Node

signal changed(health: float, armor: float)
signal damaged(amount: float, attacker: Node, headshot: bool)
signal died(attacker: Node)

@export var max_health: float = 100.0
@export var max_armor: float = 100.0
@export var start_armor: float = 0.0

var health: float
var armor: float
var alive: bool = true

func _ready() -> void:
	health = max_health
	armor = start_armor
	changed.emit(health, armor)

func reset() -> void:
	health = max_health
	armor = start_armor
	alive = true
	changed.emit(health, armor)

func heal(amount: float) -> void:
	health = minf(health + amount, max_health)
	changed.emit(health, armor)

func add_armor(amount: float) -> void:
	armor = minf(armor + amount, max_armor)
	changed.emit(health, armor)

## Возвращает фактически нанесённый урон по здоровью.
func take_damage(amount: float, attacker: Node = null, headshot: bool = false, penetration: float = 0.6) -> float:
	if not alive or amount <= 0.0:
		return 0.0

	var to_health := amount
	if armor > 0.0:
		# Броня съедает часть урона; бронебойные стволы пробивают её сильнее.
		to_health = amount * lerpf(0.45, 1.0, clampf(penetration, 0.0, 1.0))
		var to_armor: float = (amount - to_health) * 0.9
		if to_armor > armor:
			# Броня кончилась на этом выстреле — остаток проходит по здоровью.
			to_health += to_armor - armor
			to_armor = armor
		armor -= to_armor

	# Ноль — нижняя граница: иначе отрицательное здоровье уедет в HUD.
	health = maxf(health - to_health, 0.0)
	damaged.emit(to_health, attacker, headshot)
	changed.emit(health, armor)

	if health <= 0.0:
		alive = false
		died.emit(attacker)
	return to_health
