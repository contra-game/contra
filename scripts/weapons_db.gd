## Autoload "Weapons" — каталог стволов.
## Добавить новый ствол = дописать сюда одну функцию _make(...).
extends Node

var _catalog: Dictionary = {}

func _ready() -> void:
	_register(_make({
		"id": &"ak47", "name": "AK-47", "slot": WeaponData.Slot.PRIMARY, "price": 2700,
		"mode": WeaponData.FireMode.AUTO,
		"damage": 33.0, "hs": 4.0, "pen": 0.72, "rpm": 600.0,
		"mag": 30, "reserve": 90, "reload": 2.4,
		"spread_base": 0.32, "per_shot": 0.38, "max_spread": 7.0,
		"recoil_up": 1.25, "recoil_side": 0.5,
		"color": Color(0.35, 0.22, 0.12), "length": 0.66, "pitch": 0.95,
		"model": "res://assets/weapons/Rifle.fbx",
		"muzzle": Vector3(-0.00014, 0.19051, -0.561),
		"sight": Vector3(0.0, 0.092, 0.05),
		"ads_speed": 13.0, "aim_fov": 58.0,
	}))
	_register(_make({
		"id": &"m4", "name": "M4A1", "slot": WeaponData.Slot.PRIMARY, "price": 3100,
		"mode": WeaponData.FireMode.AUTO,
		"damage": 28.0, "hs": 4.0, "pen": 0.68, "rpm": 720.0,
		"mag": 30, "reserve": 90, "reload": 2.2,
		"spread_base": 0.26, "per_shot": 0.3, "max_spread": 6.0,
		"recoil_up": 0.95, "recoil_side": 0.36,
		"color": Color(0.16, 0.17, 0.18), "length": 0.62, "pitch": 1.08,
		"model": "res://assets/weapons/P90.fbx",
		"muzzle": Vector3(-0.00087, 0.13236, -0.29089),
		"sight": Vector3(0.0, 0.235, 0.02), "eye_distance": 0.55,
		"ads_speed": 16.0, "aim_fov": 60.0,
	}))
	_register(_make({
		"id": &"spas", "name": "SPAS-12", "slot": WeaponData.Slot.PRIMARY, "price": 1800,
		"mode": WeaponData.FireMode.SEMI,
		"damage": 13.0, "hs": 2.0, "pen": 0.5, "rpm": 95.0,
		"mag": 8, "reserve": 32, "reload": 3.2,
		"reload_per_shell": true,
		"pellets": 9, "range": 45.0, "falloff": 8.0, "falloff_mult": 0.25,
		"spread_base": 2.6, "per_shot": 0.6, "max_spread": 6.0,
		"recoil_up": 3.4, "recoil_side": 0.9,
		"color": Color(0.22, 0.14, 0.1), "length": 0.7, "pitch": 0.7,
		"model": "res://assets/weapons/Shotgun.fbx",
		"muzzle": Vector3(0.00019, 0.16676, -0.49941),
		"sight": Vector3(0.0, 0.108, 0.02), "eye_distance": 0.44,
		"ads_speed": 11.0, "aim_fov": 65.0,
	}))
	_register(_make({
		"id": &"awp", "name": "AWP", "slot": WeaponData.Slot.PRIMARY, "price": 4750,
		"model_scale": 0.95,
		"mode": WeaponData.FireMode.BOLT,
		"damage": 115.0, "hs": 2.2, "pen": 0.95, "rpm": 41.0,
		"mag": 5, "reserve": 25, "reload": 3.5,
		"range": 250.0, "falloff": 200.0, "falloff_mult": 0.9,
		"spread_base": 0.1, "per_shot": 3.0, "max_spread": 9.0,
		"aim_mult": 0.02, "recoil_up": 4.5, "recoil_side": 0.6,
		"color": Color(0.1, 0.18, 0.12), "length": 0.95, "scope": true,
		"model": "res://assets/weapons/SniperRifle.fbx",
		"muzzle": Vector3(0.00145, 0.16626, -0.50645),
		"sight": Vector3(0.0, 0.116, 0.1),
		"aim_fov": 18.0, "speed": 0.82, "pitch": 0.6,
		"ads_speed": 9.0,
	}))
	_register(_make({
		"id": &"deagle", "name": "Deagle", "slot": WeaponData.Slot.SECONDARY, "price": 700,
		"mode": WeaponData.FireMode.SEMI,
		"damage": 54.0, "hs": 3.2, "pen": 0.8, "rpm": 260.0,
		"mag": 7, "reserve": 35, "reload": 2.1,
		"range": 90.0, "falloff": 25.0,
		"spread_base": 0.35, "per_shot": 1.2, "max_spread": 8.0,
		"recoil_up": 2.6, "recoil_side": 0.7,
		"color": Color(0.5, 0.42, 0.2), "length": 0.3, "speed": 1.08, "pitch": 0.8,
		"model": "res://assets/weapons/Revolver.fbx",
		"muzzle": Vector3(-0.00049, 0.1275, -0.2167),
		"sight": Vector3(0.0, 0.113, 0.06), "eye_distance": 0.38,
		"ads_speed": 16.0, "aim_fov": 62.0,
	}))
	_register(_make({
		"id": &"glock", "name": "Glock-18", "slot": WeaponData.Slot.SECONDARY, "price": 200,
		"mode": WeaponData.FireMode.SEMI,
		"damage": 22.0, "hs": 3.4, "pen": 0.45, "rpm": 400.0,
		"mag": 20, "reserve": 60, "reload": 1.9,
		"range": 70.0, "falloff": 18.0,
		"spread_base": 0.5, "per_shot": 0.7, "max_spread": 7.0,
		"recoil_up": 1.2, "recoil_side": 0.5,
		"color": Color(0.14, 0.14, 0.16), "length": 0.26, "speed": 1.1, "pitch": 1.2,
		"model": "res://assets/weapons/Pistol.fbx",
		"model_rotation": Vector3(-ViewModel.PACK_PITCH, PI * 0.5, 0.0),
		"muzzle": Vector3(0.0, 0.08175, -0.20921),
		"sight": Vector3(0.0, 0.115, 0.07), "sight_rotation": Vector3.ZERO,
		"eye_distance": 0.38,
		"ads_speed": 19.0, "aim_fov": 65.0,
	}))

	_register(_make({
		"id": &"knife", "name": "Нож", "slot": WeaponData.Slot.MELEE,
		"mode": WeaponData.FireMode.SEMI, "damage": 45.0, "hs": 1.5,
		"pen": 0.9, "rpm": 100.0, "mag": 1, "reserve": 0,
		"range": 2.2, "falloff": 2.2, "length": 0.3, "speed": 1.15,
		"spread_base": 0.0, "recoil_up": 0.0,
		"color": Color(0.55, 0.6, 0.65),
	}))
	_register(_make({
		"id": &"grenade", "name": "Осколочная граната", "slot": WeaponData.Slot.GRENADE,
		"mode": WeaponData.FireMode.SEMI, "damage": 100.0, "hs": 1.0,
		"pen": 0.65, "rpm": 45.0, "mag": 2, "reserve": 0,
		"range": 8.0, "falloff": 1.5, "length": 0.15, "speed": 1.0,
		"spread_base": 0.0, "recoil_up": 0.0,
		"color": Color(0.24, 0.30, 0.12),
	}))

func get_weapon(id: StringName) -> WeaponData:
	return _catalog.get(id)

func ids(include_equipment: bool = false) -> Array:
	return _catalog.keys().filter(func(key): return include_equipment or _catalog[key].is_firearm())

## Случайный ствол нужного слота — для раскладки пикапов на карте.
func random_id(slot: int = -1) -> StringName:
	var pool: Array[StringName] = []
	for key in _catalog:
		var w: WeaponData = _catalog[key]
		if slot < 0 or w.slot == slot:
			pool.append(w.id)
	return pool.pick_random()

func _register(w: WeaponData) -> void:
	_catalog[w.id] = w

func _make(d: Dictionary) -> WeaponData:
	var w := WeaponData.new()
	w.id = d.get("id", &"unnamed")
	w.display_name = d.get("name", "Unnamed")
	w.slot = d.get("slot", WeaponData.Slot.PRIMARY)
	w.fire_mode = d.get("mode", WeaponData.FireMode.AUTO)
	w.damage = d.get("damage", 30.0)
	w.headshot_multiplier = d.get("hs", 4.0)
	w.armor_penetration = d.get("pen", 0.6)
	w.max_range = d.get("range", 150.0)
	w.falloff_start = d.get("falloff", 30.0)
	w.falloff_end_mult = d.get("falloff_mult", 0.6)
	w.pellets = d.get("pellets", 1)
	w.rpm = d.get("rpm", 600.0)
	w.magazine = d.get("mag", 30)
	w.reserve_ammo = d.get("reserve", 90)
	w.reload_time = d.get("reload", 2.4)
	w.reload_per_shell = d.get("reload_per_shell", false)
	w.spread_base = d.get("spread_base", 0.4)
	w.spread_per_shot = d.get("per_shot", 0.35)
	w.spread_max = d.get("max_spread", 7.0)
	w.spread_aim_mult = d.get("aim_mult", 0.35)
	w.recoil_up = d.get("recoil_up", 1.1)
	w.recoil_side = d.get("recoil_side", 0.45)
	w.body_color = d.get("color", Color(0.17, 0.17, 0.19))
	w.length = d.get("length", 0.62)
	w.has_scope = d.get("scope", false)
	w.aim_fov = d.get("aim_fov", 55.0)
	w.move_speed_mult = d.get("speed", 1.0)
	w.shot_pitch = d.get("pitch", 1.0)
	w.model_path = d.get("model", "")
	w.model_scale = d.get("model_scale", 1.35)
	w.model_offset = d.get("model_offset", Vector3.ZERO)
	w.model_rotation = d.get("model_rotation", Vector3.ZERO)
	w.muzzle_offset = d.get("muzzle", Vector3(0.0, 0.026, -w.length))
	w.sight_offset = d.get("sight", Vector3(0.0, 0.055, 0.02))
	w.sight_rotation = d.get("sight_rotation", Vector3(ViewModel.PACK_PITCH, 0.0, 0.0))
	w.ejection_offset = d.get("ejection", Vector3(0.045, w.muzzle_offset.y * 0.65, -w.length * 0.18))
	w.ads_eye_distance = d.get("eye_distance", 0.32)
	w.ads_speed = d.get("ads_speed", 14.0)
	w.anim_fire = d.get("fire_anim", "")
	w.anim_reload = d.get("reload_anim", "")
	w.price = d.get("price", 0)
	return w
