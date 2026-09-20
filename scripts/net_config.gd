## Настройки сети. App ID намеренно не лежит в коде: репозиторий публичный,
## а по чужому App ID можно жечь лимиты аккаунта.
##
## Файл photon.cfg рядом с project.godot (он в .gitignore):
##   [photon]
##   app_id="..."
##   region="eu"
class_name NetConfig
extends RefCounted

const CONFIG_PATH := "res://photon.cfg"
const EXAMPLE_PATH := "res://photon.cfg.example"
## Каталог, куда распаковывается папка fusion/ из SDK.
const ADDON_PATH := "res://addons/fusion/fusion.gdextension"

static func app_id() -> String:
	return _value("app_id")

static func region() -> String:
	var value := _value("region")
	return value if value != "" else "eu"

## SDK ставится вручную: Photon отдаёт архив только авторизованным.
static func sdk_installed() -> bool:
	return ResourceLoader.exists(ADDON_PATH) or FileAccess.file_exists(ADDON_PATH)

## Что мешает поднять сеть прямо сейчас; пустая строка — всё на месте.
static func blocker() -> String:
	if not sdk_installed():
		return "не установлен Photon Fusion Godot SDK (addons/fusion)"
	if app_id() == "":
		return "не задан app_id в photon.cfg"
	return ""

static func _value(key: String) -> String:
	var config := ConfigFile.new()
	if config.load(CONFIG_PATH) != OK:
		return ""
	return str(config.get_value("photon", key, ""))
