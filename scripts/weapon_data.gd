## Описание одного ствола. Всё поведение стрельбы читается отсюда,
## поэтому баланс правится в одном месте — scripts/weapons_db.gd.
class_name WeaponData
extends Resource

enum Slot { PRIMARY, SECONDARY, MELEE, GRENADE }
enum FireMode { AUTO, SEMI, BOLT }

@export var id: StringName = &""
@export var display_name: String = ""
@export var slot: Slot = Slot.PRIMARY
@export var fire_mode: FireMode = FireMode.AUTO

@export_group("Урон")
## Урон одной пули на дистанции ближе falloff_start.
@export var damage: float = 30.0
@export var headshot_multiplier: float = 4.0
## 0 — броня держит максимум урона, 1 — броня не помогает.
@export var armor_penetration: float = 0.5
@export var max_range: float = 150.0
@export var falloff_start: float = 30.0
## Доля урона на максимальной дистанции.
@export var falloff_end_mult: float = 0.6
## Дробин за выстрел (дробовик).
@export var pellets: int = 1

@export_group("Обращение")
@export var rpm: float = 600.0
@export var magazine: int = 30
@export var reserve_ammo: int = 90
@export var reload_time: float = 2.4
@export var equip_time: float = 0.45
## Дробовик заряжается по одному патрону; остальные — целым магазином.
@export var reload_per_shell: bool = false
@export var shell_reload_time: float = 0.55

@export_group("Разброс, градусы")
@export var spread_base: float = 0.4
@export var spread_move: float = 2.4
@export var spread_air: float = 6.0
@export var spread_crouch_mult: float = 0.55
@export var spread_aim_mult: float = 0.35
@export var spread_per_shot: float = 0.35
@export var spread_max: float = 7.0
@export var spread_recovery: float = 7.0
@export var spread_recovery_delay: float = 0.16

@export_group("Отдача, градусы за выстрел")
@export var recoil_up: float = 1.1
@export var recoil_side: float = 0.45
@export var recoil_recovery: float = 6.0

@export_group("Вид")
@export var aim_fov: float = 55.0
@export var move_speed_mult: float = 1.0
@export var body_color: Color = Color(0.17, 0.17, 0.19)
@export var length: float = 0.62
@export var has_scope: bool = false
@export var shot_pitch: float = 1.0

func seconds_per_shot() -> float:
	return 60.0 / maxf(rpm, 1.0)

## Множитель урона с учётом падения на дистанции.
func damage_at(distance: float) -> float:
	if distance <= falloff_start:
		return damage
	var t := clampf((distance - falloff_start) / maxf(max_range - falloff_start, 0.001), 0.0, 1.0)
	return damage * lerpf(1.0, falloff_end_mult, t)

@export_group("Модель от первого лица")
## Путь к анимированной модели; пусто — собирается из примитивов.
@export var model_path: String = ""
@export var model_scale: float = 1.0
@export var model_offset: Vector3 = Vector3.ZERO
@export var model_rotation: Vector3 = Vector3.ZERO
## Имена анимаций внутри модели (в паке Quaternius они с префиксом арматуры).
@export var anim_fire: String = ""
@export var anim_reload: String = ""
## Развернуть модель на 180°, если дуло смотрит назад.
@export var model_flip: bool = false

@export_group("Маркеры оружия")
## Позиции в метрах относительно подогнанной модели в нейтральной позе.
## После создания Marker3D привязаны к Control и следуют за анимацией.
@export var muzzle_offset := Vector3(0.0, 0.026, -0.62)
@export var sight_offset := Vector3(0.0, 0.055, 0.02)
@export var sight_rotation := Vector3(0.19, 0.0, 0.0)
@export var ejection_offset := Vector3(0.045, 0.05, -0.08)
@export var ads_eye_distance: float = 0.32
@export var ads_speed: float = 14.0

## Цена в магазине. 0 — ствол не продаётся.
@export var price: int = 0

func is_firearm() -> bool:
	return slot == Slot.PRIMARY or slot == Slot.SECONDARY
