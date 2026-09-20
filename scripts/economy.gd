## Кошелёк бойца: деньги капают за убийства и тратятся в магазине.
##
## Суммы взяты из логики CS: стартовых денег хватает на пистолет с бронёй,
## на винтовку нужно сначала пострелять.
class_name Economy
extends Node

signal money_changed(amount: int)

const START_MONEY := 800
const MAX_MONEY := 16000
const KILL_REWARD := 300
const HEADSHOT_BONUS := 100
const DEATH_CONSOLATION := 200
const ARMOR_PRICE := 650
const ARMOR_AMOUNT := 50.0

var money: int = START_MONEY

func reset() -> void:
	money = START_MONEY
	money_changed.emit(money)

func award_kill(headshot: bool) -> void:
	_add(KILL_REWARD + (HEADSHOT_BONUS if headshot else 0))

## Небольшая компенсация после смерти, иначе из бедности не выбраться.
func award_death() -> void:
	_add(DEATH_CONSOLATION)

func can_afford(price: int) -> bool:
	return price > 0 and money >= price

func spend(price: int) -> bool:
	if not can_afford(price):
		return false
	money -= price
	money_changed.emit(money)
	return true

func _add(amount: int) -> void:
	money = clampi(money + amount, 0, MAX_MONEY)
	money_changed.emit(money)
