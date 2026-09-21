# Разбор долгов Contra City — план реализации

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** закрыть найденные аудитом дефекты: игра должна запускаться без Photon SDK, не ломаться при обрыве связи, не пускать модифицированный клиент убивать сквозь стены, и перестать тратить кадры на трупы, тримеши и мусорные аллокации.

**Architecture:** все обращения к GDExtension Photon уходят за один статический фасад `NetApi` (синглтон берётся в рантайме через `Engine.get_singleton("Fusion")`), а файлы, которые физически не парсятся без расширения (`net_manager.gd`, `net_player.gd`), грузятся динамически и ни в одном другом скрипте не упоминаются по имени класса. Проверка урона переезжает на сторону жертвы: стрелок присылает идентификатор оружия, жертва сама считает потолок урона по каталогу, дистанцию и прямую видимость. Урон дробовика уходит одним RPC на цель вместо одного на дробину.

**Tech Stack:** Godot 4.7.2, GDScript, Photon Fusion Godot SDK 3.0.0 Preview Build 555 (GDExtension), PowerShell для прогонов.

**Основание:** аудит от 2026-09-21 (сессия «баги и уязвимые места»). Ссылки на строки — по состоянию на коммит `ceeb7d3`.

**Проверено до начала работ (не переспрашивать):** `Engine.has_singleton("Fusion")` возвращает `true`, `Engine.get_singleton("Fusion")` отдаёт объект, константы читаются через `.get("TARGET_MASTER")` (= -1), `ClassDB.class_exists("FusionSpawner")` истинно. Значит рантайм-фасад из Task 2 работает и не требует идентификатора `Fusion` в тексте скрипта.

**Запуск редактора и проверок — только через 4.7.2** (4.6.3 переписывает 180+ `*.import`):

```bash
"/c/Users/admin/Desktop/Godot_v4.7.2-stable_win64.exe" --headless --path . res://tools/smoke_test.tscn
```

**Фазы независимы и мержатся по отдельности.** Порядок обязателен только внутри фазы; фаза 0 нужна всем остальным.

| Фаза | Что закрывает | Задачи |
| --- | --- | --- |
| 0 | тестовый стенд с кодом возврата | 1 |
| A | игра не запускается без SDK; рассинхрон `online` | 2–4 |
| B | эксплойты урона, флуд RPC, длина имён, киллфид | 5–9 |
| C | трупы, столкновения, прицел, мышь, бхоп, мелочи | 10–13 |
| D | тримеши карты, аллокации на выстрел, лишние кадры | 14–16 |

---

## Файловая структура

| Файл | Ответственность |
| --- | --- |
| `scripts/net_api.gd` (создать) | единственное место, где берётся синглтон Photon; ни одного идентификатора `Fusion*` в тексте |
| `scripts/rate_limiter.gd` (создать) | токен-бакет, общий для всех входящих RPC |
| `scripts/net_manager.gd` (правка) | остаётся с типами `Fusion*`, но грузится динамически и теряет `class_name` |
| `scripts/net_player.gd` (правка) | валидация урона, лимиты, объявление смерти; теряет `class_name` |
| `scripts/damage.gd` (правка) | отправка урона через `NetApi`, без `Fusion` в тексте |
| `scripts/session.gd` (правка) | `net` как `Node`, свойства комнаты через `NetApi` |
| `scripts/hud.gd` (правка) | RTT через `NetApi`, табло без типа `NetPlayer`, fov прицела |
| `scripts/game.gd` (правка) | `online` по факту соединения, null-guard на счёт |
| `scripts/weapon_manager.gd` (правка) | один RPC урона на выстрел вместо одного на дробину |
| `scripts/bot.gd` (правка) | труп перестаёт быть препятствием, `is_dead()` |
| `scripts/player.gd` (правка) | бхоп, мышь, `update_life_visuals` по изменению |
| `scripts/map_builder.gd` (правка) | кэш форм столкновений, идемпотентный `build()` |
| `scripts/effects.gd` (правка) | общие материалы и меши вместо новых на каждый выстрел |
| `scripts/sfx.gd` (правка) | пул `AudioStreamPlayer3D` |
| `scripts/crosshair.gd` (правка) | `set_fov()` |
| `scenes/player.tscn`, `scenes/bot.tscn` (правка) | маски столкновений |
| `scenes/menu.tscn` (правка) | `max_length` на полях ввода |
| `tools/regression_test.gd` + `.tscn` (создать) | офлайн-проверки с кодом возврата; сюда дописываются все новые проверки |
| `tools/run_offline_tests.ps1` (создать) | прогон стенда с SDK и без SDK |

---

# Фаза 0 — стенд

## Task 1: Офлайн-проверки с кодом возврата

`tools/smoke_test.gd` только печатает и всегда выходит с нулём — на нём нельзя поймать регресс. Нужен стенд в идиоме `tools/multiplayer_test.gd`: `_check(ok, label)`, `PASS`/`FAIL` в лог, `quit(1)` при провале.

**Files:**
- Create: `tools/regression_test.gd`, `tools/regression_test.tscn`, `tools/run_offline_tests.ps1`
- Test: сам себя

- [ ] **Step 1: Написать падающую проверку**

`tools/regression_test.gd` — четыре проверки, две из которых обязаны упасть на текущем коде:

```gdscript
## Офлайн-регресс без редактора, с кодом возврата:
##   Godot_v4.7.2-stable_win64.exe --headless --path . res://tools/regression_test.tscn
##
## Сюда дописываются проверки на каждый закрытый дефект. Провал любой проверки
## завершает процесс кодом 1 — этим пользуется tools/run_offline_tests.ps1.
extends Node

var main: Node
var failures: int = 0

func _ready() -> void:
	main = load("res://scenes/main.tscn").instantiate()
	main.online = false
	add_child(main)
	# Карта, игрок и боты появляются за первый кадр, физика — за второй.
	await get_tree().process_frame
	await get_tree().physics_frame
	await _run()
	print("REGRESSION TEST: ", "PASS" if failures == 0 else "FAIL", " failures=", failures)
	get_tree().quit(0 if failures == 0 else 1)

func _run() -> void:
	var player: PlayerCharacter = main.player
	_check(player != null and player.is_on_floor(), "игрок стоит на земле")

	var bot: Bot = _first_bot()
	_check(bot != null, "бот создан")

	# Труп не должен ловить пули и мешать ходить.
	bot.health.take_damage(10000.0, player, false, 1.0)
	await get_tree().physics_frame
	_check(bot.collision_layer == 0, "труп бота убран со слоя попаданий")

	# Игроки должны сталкиваться телами друг с другом.
	_check(player.collision_mask & 2 != 0, "игрок сталкивается с игроками")

func _first_bot() -> Bot:
	for node in main.get_node("Actors").get_children():
		if node is Bot:
			return node
	return null

func _check(ok: bool, label: String) -> void:
	if not ok:
		failures += 1
	print("PASS" if ok else "FAIL", " ", label)
```

`tools/regression_test.tscn`:

```
[gd_scene load_steps=2 format=3]

[ext_resource type="Script" path="res://tools/regression_test.gd" id="1_regression"]

[node name="RegressionTest" type="Node"]
script = ExtResource("1_regression")
```

- [ ] **Step 2: Прогнать и убедиться, что две проверки падают**

```bash
"/c/Users/admin/Desktop/Godot_v4.7.2-stable_win64.exe" --headless --path . res://tools/regression_test.tscn
```

Ожидается: `PASS игрок стоит на земле`, `PASS бот создан`, `FAIL труп бота убран со слоя попаданий`, `FAIL игрок сталкивается с игроками`, `REGRESSION TEST: FAIL failures=2`, код возврата 1.

- [ ] **Step 3: Написать раннер, который проверяет и сборку без SDK**

`tools/run_offline_tests.ps1`:

```powershell
param(
    [Parameter(Mandatory = $true)][string]$Godot
)
$ErrorActionPreference = 'Stop'
$projectPath = Split-Path $PSScriptRoot -Parent
$enginePath = (Resolve-Path -LiteralPath $Godot).Path
$logPath = Join-Path $projectPath ('build/offline-' + [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())
New-Item -ItemType Directory -Path $logPath -Force | Out-Null
$addon = Join-Path $projectPath 'addons/fusion'
$parked = Join-Path $projectPath 'addons/_fusion_parked'

function Invoke-Scene([string]$scene, [string]$name) {
    $arguments = @('--headless', '--path', ('"' + $projectPath + '"'), $scene)
    $process = Start-Process -FilePath $enginePath -ArgumentList $arguments -WorkingDirectory (Split-Path $enginePath -Parent) -WindowStyle Hidden -PassThru -RedirectStandardOutput "$logPath/$name.log" -RedirectStandardError "$logPath/$name.err"
    $process.WaitForExit()
    $code = $process.ExitCode
    $process.Dispose()
    return $code
}

try {
    # 1. Обычный прогон: SDK на месте.
    $code = Invoke-Scene 'res://tools/regression_test.tscn' 'with-sdk'
    $log = Get-Content -LiteralPath "$logPath/with-sdk.log" -Raw
    if ($code -ne 0 -or $log -notmatch 'REGRESSION TEST: PASS') { throw "Regression failed with SDK. See $logPath" }
    Write-Output ('with-sdk: PASS (' + ([regex]::Matches($log, '(?m)^PASS')).Count + ' checks)')

    # 2. Прогон без SDK: игра обязана работать офлайн и не сыпать ошибками скриптов.
    if (Test-Path -LiteralPath $addon) { Move-Item -LiteralPath $addon -Destination $parked }
    $code = Invoke-Scene 'res://tools/regression_test.tscn' 'no-sdk'
    $log = Get-Content -LiteralPath "$logPath/no-sdk.log" -Raw
    $errors = Get-Content -LiteralPath "$logPath/no-sdk.err" -Raw
    if ($code -ne 0 -or $log -notmatch 'REGRESSION TEST: PASS') { throw "Regression failed without SDK. See $logPath" }
    if ($errors -match 'SCRIPT ERROR' -or $log -match 'SCRIPT ERROR') { throw "GDScript errors without SDK. See $logPath" }
    Write-Output ('no-sdk: PASS (' + ([regex]::Matches($log, '(?m)^PASS')).Count + ' checks)')
    Write-Output "Logs: $logPath"
} finally {
    if (Test-Path -LiteralPath $parked) { Move-Item -LiteralPath $parked -Destination $addon }
}
```

- [ ] **Step 4: Прогнать раннер и убедиться, что он падает на первом этапе**

```powershell
./tools/run_offline_tests.ps1 -Godot "C:/Users/admin/Desktop/Godot_v4.7.2-stable_win64.exe"
```

Ожидается исключение `Regression failed with SDK` (две проверки красные). Убедиться, что блок `finally` вернул аддон:

```bash
ls addons/fusion/fusion.gdextension
```

- [ ] **Step 5: Коммит**

```bash
git add tools/regression_test.gd tools/regression_test.tscn tools/regression_test.gd.uid tools/run_offline_tests.ps1
git commit -m "Стенд офлайн-проверок с кодом возврата" -m "Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

# Фаза A — критичное

## Task 2: Фасад `NetApi` вместо прямых ссылок на синглтон

Без расширения идентификатор `Fusion` — ошибка парсинга. Сейчас он стоит в `damage.gd`, `hud.gd`, `session.gd`, `net_player.gd`, `net_manager.gd`; из-за этого падает автолоад `Session`, не компилируется `Damage`, и офлайн-режим недостижим. Первый шаг — вынести доступ к синглтону в один файл, который парсится всегда, и перевести на него «листовых» потребителей.

**Files:**
- Create: `scripts/net_api.gd`
- Modify: `scripts/damage.gd:26-33`, `scripts/hud.gd:97-108`, `scripts/net_config.gd:23-25`
- Test: `tools/run_offline_tests.ps1` (этап `no-sdk`)

- [ ] **Step 1: Написать фасад**

`scripts/net_api.gd`:

```gdscript
## Единственное место, где игра достаёт синглтон Photon Fusion.
##
## Идентификаторы `Fusion` и `Fusion*` здесь не упоминаются намеренно: без
## установленного GDExtension такой идентификатор — ошибка парсинга, из-за
## которой рассыпался весь проект вместе с офлайн-режимом. Синглтон берётся по
## имени в рантайме, поэтому файл компилируется всегда, а `available()` даёт
## остальному коду честный ответ, есть ли сеть.
class_name NetApi
extends RefCounted

const SINGLETON_NAME := "Fusion"

static var _resolved: bool = false
static var _api: Object = null

static func api() -> Object:
	if not _resolved:
		_resolved = true
		if Engine.has_singleton(SINGLETON_NAME):
			_api = Engine.get_singleton(SINGLETON_NAME)
	return _api

static func available() -> bool:
	return api() != null

# --- состояние ---------------------------------------------------------------

static func is_in_room() -> bool:
	var a := api()
	return a != null and bool(a.call("is_in_room"))

static func is_master_client() -> bool:
	var a := api()
	return a != null and bool(a.call("is_master_client"))

static func local_player_id() -> int:
	var a := api()
	return int(a.call("get_local_player_id")) if a != null else 0

static func rpc_sender() -> int:
	var a := api()
	return int(a.call("get_rpc_sender")) if a != null else 0

static func rtt() -> float:
	var a := api()
	return float(a.call("get_rtt")) if a != null and is_in_room() else 0.0

static func network_time() -> float:
	var a := api()
	return float(a.call("get_network_time")) if a != null else 0.0

static func room() -> Object:
	var a := api()
	return a.call("get_room") if a != null else null

# --- свойства комнаты --------------------------------------------------------

## Сигнала на смену свойств комнаты в SDK нет, состояние читается опросом.
static func room_property(key: String, default_value: Variant) -> Variant:
	var r := room()
	if r == null:
		return default_value
	return r.call("get_custom_properties").get(key, default_value)

static func set_room_property(key: String, value: Variant) -> void:
	var r := room()
	if r != null:
		r.call("set_property", key, value)

# --- RPC ---------------------------------------------------------------------
# Аргументы передаются массивом: Callable.bind() Fusion не понимает и роняет
# процесс, а вариадиков у статических функций GDScript нет.

static func rpc_all(method: Callable, args: Array = []) -> void:
	var a := api()
	if a != null:
		a.callv("rpc", [method] + args)

static func rpc_to_player(player_id: int, method: Callable, args: Array = []) -> void:
	var a := api()
	if a != null:
		a.callv("rpc_to_player", [player_id, method] + args)

static func rpc_to_master(method: Callable, args: Array = []) -> void:
	var a := api()
	if a != null:
		a.callv("rpc_to", [a.get("TARGET_MASTER"), method] + args)
```

- [ ] **Step 2: Перевести `damage.gd` на фасад**

В `scripts/damage.gd` расширить подпись, чтобы жертва знала, из чего в неё стреляли (потолок урона она посчитает сама в Task 6):

```gdscript
static func apply(target: Node, amount: float, attacker: Node, headshot: bool, penetration: float, weapon_id: String = "") -> float:
```

и заменить блок отправки (строки 26–33) на:

```gdscript
		# Метод живёт на обвязке — это узел с дочерним репликатором, по нему SDK
		# и находит того же бойца на чужом клиенте.
		NetApi.rpc_to_player(net.replicator.get_owner_id(), net.apply_remote_damage,
			[weapon_id, amount, headshot, net.life_serial])
		return amount
```

- [ ] **Step 3: Перевести `hud.gd` на фасад и убрать тип `NetPlayer`**

В `scripts/hud.gd` заменить `_refresh_scoreboard` (строки 97–108) на:

```gdscript
func _refresh_scoreboard() -> void:
	var rows: Array[String] = []
	if Session.online:
		rows.append("%s  •  %d игроков  •  %d мс" % [
			Session.room_name, Session.players().size(), int(NetApi.rtt() * 1000.0)])
		rows.append("ИГРОК                         ФРАГИ / СМЕРТИ")
		for actor in get_tree().get_nodes_in_group("combatants"):
			if not actor is PlayerCharacter:
				continue
			# Обвязку узнаём по методу, а не по классу: её скрипт не существует
			# без Photon SDK, а табло должно открываться и офлайн.
			var wrapper: Node = actor.get_parent()
			if wrapper == null or not wrapper.has_method("apply_remote_damage"):
				continue
			rows.append("%s%s        %d / %d" % [
				actor.display_name, " (вы)" if actor.local_control else "",
				wrapper.frags, wrapper.deaths])
	elif game != null:
		rows.append("Тренировка\n%s        %d / %d" % [Session.player_name, game.kills, game.deaths])
	_score_rows.text = "\n\n".join(rows)
```

- [ ] **Step 4: Проверять загруженное расширение, а не файл на диске**

В `scripts/net_config.gd` заменить `sdk_installed()` (строки 23–25):

```gdscript
## SDK ставится вручную: Photon отдаёт архив только авторизованным. Проверяем
## именно поднятое расширение — файл на диске может лежать и не загрузиться.
static func sdk_installed() -> bool:
	return NetApi.available()
```

- [ ] **Step 5: Прогнать этап без SDK и увидеть, что список ошибок сократился**

```bash
mv addons/fusion addons/_fusion_parked; "/c/Users/admin/Desktop/Godot_v4.7.2-stable_win64.exe" --headless --path . res://tools/regression_test.tscn 2>&1 | grep -E 'SCRIPT ERROR|Failed to load script' | sort -u; mv addons/_fusion_parked addons/fusion
```

Ожидается: строк про `damage.gd` и `hud.gd` больше нет; остались `session.gd`, `net_manager.gd`, `net_player.gd` — их закрывает Task 3.

- [ ] **Step 6: Коммит**

```bash
git add scripts/net_api.gd scripts/net_api.gd.uid scripts/damage.gd scripts/hud.gd scripts/net_config.gd
```

```bash
git commit -m "Доступ к Photon через рантайм-фасад NetApi" -m "Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

## Task 3: Сетевой слой грузится динамически и нигде не назван по имени класса

`session.gd` объявляет `var net: NetManager`, из-за чего GDScript компилирует `net_manager.gd`, тот `preload`-ит `net_player.tscn`, а вместе с ним `player_replication.tres` и `net_player.gd`. Одна ссылка на тип роняет всю цепочку. Лечится тем, что оба «сетевых» скрипта перестают быть глобальными классами и грузятся по пути только когда расширение поднялось.

**Files:**
- Modify: `scripts/net_manager.gd:12`, `scripts/net_manager.gd:260-262`, `scripts/net_player.gd:2`, `scripts/session.gd:30-45`, `scripts/session.gd:57-124`, `tools/multiplayer_test.gd:180-186`
- Test: `tools/run_offline_tests.ps1` (этап `no-sdk`)

- [ ] **Step 1: Снять `class_name` с сетевых скриптов**

В `scripts/net_manager.gd` удалить строку `class_name NetManager`, оставив `extends Node`. В `scripts/net_player.gd` удалить `class_name NetPlayer`, оставив `extends Node3D`.

- [ ] **Step 2: Убрать оставшиеся ссылки на снятые типы**

В `scripts/net_manager.gd` заменить начало `_on_spawned` (строки 260–262):

```gdscript
## Сигнал приходит и на свои, и на чужие объекты: своего отличаем по авторитету.
func _on_spawned(node: Node) -> void:
	if node.has_method("configure_owner"):
		node.configure_owner()
```

В `tools/multiplayer_test.gd` заменить `_fighters()` и `_other()`:

```gdscript
func _fighters() -> Array:
	if not is_instance_valid(main):
		return []
	return main.actors.get_children().filter(func(n): return n.has_method("apply_remote_damage"))

func _other() -> Node:
	for n in _fighters():
		if not n.player.local_control:
			return n
	return null
```

- [ ] **Step 3: Грузить менеджер по пути и защитить все вызовы**

В `scripts/session.gd` заменить объявление (строка 30) и `_ready` (строки 37–45):

```gdscript
const NET_MANAGER_SCRIPT := "res://scripts/net_manager.gd"

## Обычный Node, а не типизированный NetManager: скрипт менеджера ссылается на
## классы GDExtension и не компилируется без установленного Photon SDK.
var net: Node = null

func _ready() -> void:
	load_settings()
	if not NetApi.available():
		print("[сеть] Photon SDK не поднялся — доступен только офлайн-режим")
		return
	net = (load(NET_MANAGER_SCRIPT) as GDScript).new()
	net.name = "NetManager"
	add_child(net)
	net.session_state.connect(_on_net_state)
	net.lobby_changed.connect(func() -> void: lobby_changed.emit())
	net.joined.connect(_on_joined)
	net.connection_lost.connect(_on_connection_lost)
```

Заменить методы, которые обращались к `net` и `Fusion` напрямую (строки 57–124):

```gdscript
func connect_and_join() -> bool:
	if net == null:
		return false
	# Photon цепляет свои узлы к дереву, поэтому подключаться из _ready нельзя:
	# сцена в этот момент ещё «занята» и add_child падает.
	await get_tree().process_frame
	if not net.connect_and_join(user_id(), room_name):
		return false
	return await net.joined

func leave() -> void:
	print("[сессия] выход из комнаты")
	_watching = false
	if net != null:
		net.stop()

func players() -> Array:
	var out: Array = []
	if net == null:
		return out
	for player in net.players():
		var row := LobbyPlayer.new()
		row.id = player.get_number()
		row.name = player.get_user_id().split("#")[0]
		row.is_host = player.get_is_master_client()
		out.append(row)
	return out

func is_host() -> bool:
	return net != null and net.is_host()

func is_online() -> bool:
	return net != null and net.is_online()

# --- старт матча -------------------------------------------------------------

## Хост объявляет старт через свойство комнаты: seed один на всех, иначе карта
## соберётся разная. Широковещательный RPC тут не годится — Fusion шлёт их
## только от узлов с репликатором, а сессия живёт вне сетевого дерева.
func start_match() -> void:
	if not is_online() or not is_host() or match_seed != 0:
		return
	# Photon хранит целые свойства комнаты как signed int32.
	var seed_value := randi() & 0x7fffffff
	if seed_value == 0:
		seed_value = 1
	NetApi.set_room_property(SEED_KEY, seed_value)
	_apply_start(seed_value)

func _apply_start(seed_value: int) -> void:
	if match_seed == seed_value:
		return
	print("[сессия] старт матча, seed=%d" % seed_value)
	_watching = false
	_seen_seed = seed_value
	match_seed = seed_value
	online = is_online()
	match_started.emit(seed_value)

## Пока сидим в лобби, ждём, когда хост положит в комнату новый seed.
func _process(_delta: float) -> void:
	if not _watching or not is_online():
		return
	var value := int(NetApi.room_property(SEED_KEY, 0))
	if value != 0 and value != _seen_seed:
		_apply_start(value)
```

Здесь же закрыт мёртвый `_seen_seed`: раньше он никогда не получал наблюдённое значение, и защита от повторного старта держалась только на сбросе `_watching`.

- [ ] **Step 4: Прогнать раннер целиком**

```powershell
./tools/run_offline_tests.ps1 -Godot "C:/Users/admin/Desktop/Godot_v4.7.2-stable_win64.exe"
```

Ожидается: этап `with-sdk` по-прежнему падает на двух проверках из Task 1 (их закрывает фаза C), но в логах этапа `no-sdk` нет ни одной строки `SCRIPT ERROR` и нет `Failed to instantiate an autoload`. Проверить числом:

```bash
grep -c 'SCRIPT ERROR' build/offline-*/no-sdk.err
```

Ожидается `0`.

- [ ] **Step 5: Сверить, что живая сеть не сломалась**

```powershell
./tools/run_network_tests.ps1 -Godot "C:/Users/admin/Desktop/Godot_v4.7.2-stable_win64_console.exe"
```

Ожидается `host: PASS` и `client: PASS`.

- [ ] **Step 6: Коммит**

```bash
git add scripts/session.gd scripts/net_manager.gd scripts/net_player.gd tools/multiplayer_test.gd
```

```bash
git commit -m "Сетевой слой грузится динамически: игра запускается без Photon SDK" -m "Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

## Task 4: Режим матча определяется по живому соединению

`game.gd:32` берёт `online = Session.online`, а проверку `Session.is_online()` делает только на строке 41. Если связь отвалилась между лобби и матчем, матч уходит в офлайн-ветку с флагом `online == true`: `_spawn_pickups()` уже раздал точкам `network_index >= 0`, поэтому E над оружием молча ничего не делает, а `_on_player_died` пишет `deaths` в обычный `Actors` и роняет ошибку на каждой смерти.

**Files:**
- Modify: `scripts/game.gd:29-50`, `scripts/game.gd:197-201`
- Test: `tools/regression_test.gd`

- [ ] **Step 1: Дописать проверку**

В `tools/regression_test.gd` в конец `_run()` добавить:

```gdscript
	# Матч без живого соединения обязан быть честно офлайновым.
	_check(not main.online, "офлайн-матч не притворяется сетевым")
	for node in main.get_node("Actors").get_children():
		if node is WeaponPickup:
			_check(node.network_index < 0, "точка оружия офлайн не ждёт хоста")
			break
```

- [ ] **Step 2: Прогнать и записать текущий результат**

```bash
"/c/Users/admin/Desktop/Godot_v4.7.2-stable_win64.exe" --headless --path . res://tools/regression_test.tscn
```

На офлайн-стенде эти две проверки проходят уже сейчас (сессия не подключена, `Session.online == false`). Это ожидаемо: дефект проявляется только при обрыве связи, который headless-стендом не воспроизвести. Проверки остаются как страховка от возврата, а настоящая защита — в Step 3.

- [ ] **Step 3: Считать режим один раз и по факту**

В `scripts/game.gd` заменить начало `_ready` (строки 29–50):

```gdscript
func _ready() -> void:
	# Режим и seed приходят из сессии: в сети карта должна собраться одинаковой
	# у всех, поэтому seed раздаёт хост, а не константа матча. Флаг считается
	# один раз и по факту живого соединения: если связь отвалилась между лобби и
	# матчем, матч должен быть полностью офлайновым, иначе точки оружия ждут
	# хоста, которого нет, а счёт пишется в узел без сетевой обвязки.
	online = Session.online and Session.is_online()
	if Session.match_seed != 0:
		match_seed = Session.match_seed
	print("[матч] режим=%s seed=%d ботов=%d" % [
		"сеть" if online else "офлайн", match_seed, 0 if online else bot_count])
	_rng.seed = match_seed
	map.build(match_seed)
	_spawn_pickups()

	if online:
		_bind_network()
		# В сети бойцов нет кроме живых игроков: бот был бы локальным у каждого
		# клиента, то есть невидимым для остальных, и счёт по нему бы разъезжался.
		# В сети своего бойца создаёт Photon — ждём сигнала о спавне.
		await net.begin_match(actors)
		return

	_spawn_player()
	_spawn_bots(bot_count)
```

- [ ] **Step 4: Закрыть null-guard на подтверждённом фраге**

В `scripts/game.gd` заменить `_on_network_kill` (строки 197–201):

```gdscript
func _on_network_kill(victim_name: String, _headshot: bool) -> void:
	# Подтверждение может прийти раньше, чем Photon отдал нам своего бойца.
	if player == null or not is_instance_valid(player):
		return
	kills += 1
	player.get_parent().frags = kills
	score_changed.emit(kills, deaths)
	killfeed.emit("Вы убили %s" % victim_name)
```

- [ ] **Step 5: Прогнать стенд**

```bash
"/c/Users/admin/Desktop/Godot_v4.7.2-stable_win64.exe" --headless --path . res://tools/regression_test.tscn
```

Ожидается: `PASS офлайн-матч не притворяется сетевым`, `PASS точка оружия офлайн не ждёт хоста`, красными остаются только две проверки из Task 1.

- [ ] **Step 6: Коммит**

```bash
git add scripts/game.gd tools/regression_test.gd
```

```bash
git commit -m "Режим матча определяется по живому соединению" -m "Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---
# Фаза B — сетевая устойчивость

## Task 5: Один RPC урона на выстрел вместо одного на дробину

`_fire_rays` зовёт `_resolve_hit` на каждую дробину, а тот на каждую дробину отправляет отдельный надёжный RPC. Выстрел из SPAS-12 — девять пакетов и девять хитмаркеров. Складываем урон по цели и отправляем один раз; это же снимает половину нагрузки, которой можно флудить комнату.

**Files:**
- Modify: `scripts/weapon_manager.gd:206-256`, `scripts/bot.gd:230`
- Test: `tools/regression_test.gd`

- [ ] **Step 1: Дописать падающую проверку**

В `tools/regression_test.gd` добавить вспомогательный метод и проверку. Метод — рядом с `_first_bot()`:

```gdscript
func _bots() -> Array:
	return main.get_node("Actors").get_children().filter(func(n): return n is Bot)
```

Проверку — в конец `_run()`:

```gdscript
	# Дробь складывается по цели: один выстрел — одно подтверждение, а не девять.
	# Бот ставится в 2.5 м прямо перед игроком: это внутри той же клетки карты
	# (клетка 6.5 м), поэтому стена между ними появиться не может.
	var victim: Bot = _bots()[1]
	var shooter: PlayerCharacter = main.player
	victim.global_position = shooter.global_position - shooter.global_transform.basis.z * 2.5
	victim.state = Bot.State.IDLE
	await get_tree().physics_frame
	var confirms := [0]
	shooter.weapons.hit_confirmed.connect(func(_h, _k) -> void: confirms[0] += 1)
	shooter.weapons.give(&"spas", true)
	shooter.weapons._equip_left = 0.0
	shooter.weapons._cooldown = 0.0
	shooter.weapons._try_fire({"speed": 0.0, "on_floor": true, "crouching": false, "sprinting": false})
	await get_tree().physics_frame
	_check(confirms[0] == 1, "выстрел дробью подтверждается один раз (получено %d)" % confirms[0])
```

- [ ] **Step 2: Прогнать и убедиться, что проверка падает**

```bash
"/c/Users/admin/Desktop/Godot_v4.7.2-stable_win64.exe" --headless --path . res://tools/regression_test.tscn
```

Ожидается `FAIL выстрел дробью подтверждается один раз (получено 9)` — число может быть от 2 до 9 в зависимости от того, сколько дробин попало.

- [ ] **Step 3: Складывать урон по цели**

В `scripts/weapon_manager.gd` заменить `_fire_rays` и `_resolve_hit` (строки 206–256) на:

```gdscript
func _fire_rays(data: WeaponData, state: Dictionary) -> void:
	var origin := _camera.global_position
	var forward := -_camera.global_transform.basis.z
	var spread_deg := _current_spread(data, state)
	var world := _owner.get_tree().current_scene
	var muzzle := _muzzle_position()
	# Дробь складывается по цели: иначе каждая из девяти дробин SPAS-12 уходит
	# отдельным надёжным RPC и отдельным хитмаркером.
	var tally: Dictionary = {}          # Node -> {"amount": float, "headshot": bool}

	for pellet in data.pellets:
		var dir := _spread_direction(forward, spread_deg)
		var hit := _cast(origin, dir, data.max_range)
		var end: Vector3 = hit.get("position", origin + dir * data.max_range)
		Effects.tracer(world, muzzle, end)
		if pellet == 0:
			shot_fired.emit(String(data.id), muzzle, end)
		if hit.is_empty():
			continue
		_tally_hit(hit, data, origin, world, tally)

	for target in tally:
		_apply_tally(target, data, tally[target])

## Эффекты рисуются на каждую дробину, урон только копится.
func _tally_hit(hit: Dictionary, data: WeaponData, origin: Vector3, world: Node, tally: Dictionary) -> void:
	var point: Vector3 = hit.position
	var body: Node = hit.collider
	var target_health := Damage.find_health(body)
	# Труп — не плоть: иначе выстрел в него глотается кровавыми искрами вместо
	# отметины на поверхности.
	var is_flesh := target_health != null and target_health.alive

	Effects.impact(world, point, hit.normal, is_flesh)
	if not is_flesh:
		Sfx.play_3d(&"step", point, randf_range(1.4, 1.8), -6.0, 40.0)
		return

	var crouched: bool = body.get("crouching") if body.get("crouching") != null else false
	var headshot := Damage.is_headshot(body, point, crouched)
	var amount := data.damage_at(origin.distance_to(point))
	if headshot:
		amount *= data.headshot_multiplier

	var row: Dictionary = tally.get(body, {"amount": 0.0, "headshot": false})
	row.amount += amount
	row.headshot = bool(row.headshot) or headshot
	tally[body] = row

func _apply_tally(body: Node, data: WeaponData, row: Dictionary) -> void:
	if not is_instance_valid(body):
		return
	var headshot: bool = row.headshot
	var dealt := Damage.apply(body, row.amount, _owner, headshot, data.armor_penetration, String(data.id))
	if Damage._net_wrapper(body) != null and not body.local_control:
		return # Подтверждение попадания придёт от владельца цели.
	if dealt <= 0.0:
		return
	var target_health := Damage.find_health(body)
	var killed := target_health != null and not target_health.alive
	Sfx.play_2d(&"headshot" if headshot else &"hit", 1.0, -4.0)
	hit_confirmed.emit(headshot, killed)
```

- [ ] **Step 4: Передать оружие и у бота**

В `scripts/bot.gd:230` заменить вызов на:

```gdscript
	Damage.apply(body, amount, self, headshot, _data.armor_penetration, String(_data.id))
```

- [ ] **Step 5: Прогнать стенд**

```bash
"/c/Users/admin/Desktop/Godot_v4.7.2-stable_win64.exe" --headless --path . res://tools/regression_test.tscn
```

Ожидается `PASS выстрел дробью подтверждается один раз (получено 1)`.

- [ ] **Step 6: Коммит**

```bash
git add scripts/weapon_manager.gd scripts/bot.gd tools/regression_test.gd
```

```bash
git commit -m "Урон дробовика уходит одним пакетом на цель" -m "Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

## Task 6: Жертва проверяет урон сама

`apply_remote_damage` сейчас верит стрелку во всём: сумма (до 1000 при максимуме 150 EHP), бронепробитие и факт хедшота приходят по сети без проверки, а дистанция и прямая видимость не проверяются вовсе. Правленый клиент убивает кого угодно сквозь карту одним пакетом. Переносим проверки на сторону жертвы: она знает каталог оружия, свои координаты и геометрию.

**Files:**
- Modify: `scripts/net_player.gd:84-134`
- Test: `tools/run_network_tests.ps1`

- [ ] **Step 1: Перевести `net_player.gd` на фасад**

Во всём файле заменить вызовы синглтона на фасад: `Fusion.get_local_player_id()` → `NetApi.local_player_id()`, `Fusion.get_rpc_sender()` → `NetApi.rpc_sender()`, `Fusion.is_in_room()` → `NetApi.is_in_room()`, `Fusion.rpc(method, a, b)` → `NetApi.rpc_all(method, [a, b])`. Типы `FusionSharedReplicator` и `FusionReplicator` оставить: файл грузится только при живом расширении, а имена методов через фасад дают одинаковый стиль во всём проекте.

- [ ] **Step 2: Заменить приём урона на проверяющий**

В `scripts/net_player.gd` заменить `apply_remote_damage` (строки 84–97) на:

```gdscript
## Урон применяет владелец цели. Стрелок присылает только идентификатор ствола и
## сумму: потолок, дистанцию и прямую видимость жертва считает сама по каталогу и
## своей геометрии. Бронепробитие тоже берётся из каталога, а не с провода.
## Номер жизни отсекает урон, прилетевший после респавна.
@rpc("any_peer", "call_remote", "reliable")
func apply_remote_damage(weapon_id: String, amount: float, headshot: bool, target_life: int) -> void:
	if not replicator.has_authority() or not player.health.alive or target_life != life_serial:
		return
	var attacker_id: int = NetApi.rpc_sender()
	var attacker := _find_player(attacker_id)
	if attacker == null or attacker == player or not attacker.health.alive:
		return
	var data := Weapons.get_weapon(StringName(weapon_id))
	if data == null or not is_finite(amount) or amount <= 0.0:
		return
	# Потолок — самый жирный законный выстрел этого ствола: вся дробь в голову
	# в упор, плюс 5 % на расхождение чисел у двух машин.
	var cap: float = data.damage * float(maxi(data.pellets, 1)) * 1.05
	if headshot:
		cap *= data.headshot_multiplier
	if amount > cap:
		return
	if attacker.global_position.distance_to(player.global_position) > data.max_range * 1.2:
		return
	if not _has_line_of_sight(attacker):
		return
	var dealt := player.health.take_damage(amount, attacker, headshot,
		clampf(data.armor_penetration, 0.0, 1.0))
	if dealt > 0.0:
		NetApi.rpc_all(confirm_hit, [attacker_id, headshot, not player.health.alive, life_serial])
```

- [ ] **Step 3: Добавить проверку прямой видимости**

В `scripts/net_player.gd` рядом с `_find_player` добавить:

```gdscript
## Из-за интерполяции чужое тело у нас стоит не там, где его видел стрелок,
## поэтому целимся в три точки по высоте и довольствуемся одной свободной.
## Маска — только мир: бойцы друг друга не заслоняют, иначе на своего же
## союзника перед стволом урон бы не проходил.
func _has_line_of_sight(attacker: PlayerCharacter) -> bool:
	var space := player.get_world_3d().direct_space_state
	var from: Vector3 = attacker.global_position + Vector3.UP * 1.55
	for height in [1.5, 0.9, 0.3]:
		var query := PhysicsRayQueryParameters3D.create(from, player.global_position + Vector3.UP * height)
		query.collision_mask = 1
		query.exclude = [attacker.get_rid(), player.get_rid()]
		if space.intersect_ray(query).is_empty():
			return true
	return false
```

- [ ] **Step 4: Прогнать живую сеть**

```powershell
./tools/run_network_tests.ps1 -Godot "C:/Users/admin/Desktop/Godot_v4.7.2-stable_win64_console.exe"
```

Ожидается `host: PASS` и `client: PASS`. Ключевая проверка в существующем тесте — `armor penetration preserved` (`health == 88.75`): она подтверждает, что бронепробитие из каталога даёт то же число, что раньше приходило по сети.

- [ ] **Step 5: Проверить, что завышенный урон не проходит**

В `tools/multiplayer_test.gd` в блок `_client()` после подтверждённого попадания добавить:

```gdscript
	# Завышенный урон обязан быть отброшен жертвой.
	var before: float = _other().net_health
	NetApi.rpc_to_player(_other().replicator.get_owner_id(), _other().apply_remote_damage,
		["glock", 999.0, true, _other().life_serial])
	await get_tree().create_timer(1.0).timeout
	_check(is_equal_approx(_other().net_health, before), "жертва отбросила урон 999 из глока")
```

Прогнать раннер ещё раз, ожидается новая строка `PASS [client] жертва отбросила урон 999 из глока`.

- [ ] **Step 6: Коммит**

```bash
git add scripts/net_player.gd tools/multiplayer_test.gd
```

```bash
git commit -m "Урон проверяет владелец цели: потолок по каталогу, дистанция, видимость" -m "Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

## Task 7: Бюджет на входящие RPC

Ни `apply_remote_damage`, ни `show_shot` не ограничены по частоте. `show_shot` на каждый вызов создаёт у всех в комнате `ImmediateMesh`, материал и `AudioStreamPlayer3D` — готовая лаг-бомба, для которой не нужен даже чит в геймплее.

**Files:**
- Create: `scripts/rate_limiter.gd`
- Modify: `scripts/net_player.gd` (поля класса, `apply_remote_damage`, `show_shot`)
- Test: `tools/regression_test.gd`

- [ ] **Step 1: Написать падающую проверку**

В `tools/regression_test.gd` в конец `_run()` добавить:

```gdscript
	# Токен-бакет: 20 пакетов в секунду при запасе 30 — тридцать первый подряд
	# обязан быть отброшен.
	var budget := RateLimiter.new(20.0, 30.0)
	var allowed := 0
	for i in 40:
		if budget.allow(7):
			allowed += 1
	_check(allowed == 30, "бюджет RPC пропускает ровно запас (пропущено %d)" % allowed)
```

- [ ] **Step 2: Прогнать и убедиться, что проверка падает**

```bash
"/c/Users/admin/Desktop/Godot_v4.7.2-stable_win64.exe" --headless --path . res://tools/regression_test.tscn
```

Ожидается ошибка парсинга `Identifier "RateLimiter" not declared in the current scope`.

- [ ] **Step 3: Написать токен-бакет**

`scripts/rate_limiter.gd`:

```gdscript
## Токен-бакет на отправителя: входящие RPC от одного игрока не должны
## превращаться в поток эффектов и звуков на чужих машинах.
##
## per_second — установившаяся частота, burst — запас на честный залп
## (дробовик, серия из автомата, догоняющие пакеты после лага).
class_name RateLimiter
extends RefCounted

var _per_second: float
var _burst: float
var _buckets: Dictionary = {}          # id -> {"left": float, "at": float}

func _init(per_second: float, burst: float) -> void:
	_per_second = per_second
	_burst = burst

func allow(id: int) -> bool:
	var now := Time.get_ticks_msec() / 1000.0
	var bucket: Dictionary = _buckets.get(id, {"left": _burst, "at": now})
	bucket.left = minf(_burst, float(bucket.left) + (now - float(bucket.at)) * _per_second)
	bucket.at = now
	var ok: bool = bucket.left >= 1.0
	if ok:
		bucket.left = float(bucket.left) - 1.0
	_buckets[id] = bucket
	return ok
```

- [ ] **Step 4: Прогнать и убедиться, что проверка проходит**

```bash
"/c/Users/admin/Desktop/Godot_v4.7.2-stable_win64.exe" --headless --path . res://tools/regression_test.tscn
```

Ожидается `PASS бюджет RPC пропускает ровно запас (пропущено 30)`.

- [ ] **Step 5: Повесить бюджеты на приёмники**

В `scripts/net_player.gd` к полям класса (после `var _hand_bone: int = -1`) добавить:

```gdscript
# Бюджеты входящих RPC. Самый частый законный случай — M4A1 на 720 выстрелов в
# минуту, то есть 12 пакетов в секунду; 20/с с запасом 30 покрывают его вместе
# с залпом дроби и догоняющими пакетами после лага.
var _damage_budget := RateLimiter.new(20.0, 30.0)
var _shot_budget := RateLimiter.new(20.0, 30.0)
```

В `apply_remote_damage` сразу после получения `attacker_id` добавить:

```gdscript
	if not _damage_budget.allow(attacker_id):
		return
```

В `show_shot` заменить первую проверку на:

```gdscript
	var sender: int = NetApi.rpc_sender()
	if sender != replicator.get_owner_id() or player.local_control:
		return
	if not _shot_budget.allow(sender):
		return
```

- [ ] **Step 6: Прогнать оба раннера**

```powershell
./tools/run_offline_tests.ps1 -Godot "C:/Users/admin/Desktop/Godot_v4.7.2-stable_win64.exe"
```

```powershell
./tools/run_network_tests.ps1 -Godot "C:/Users/admin/Desktop/Godot_v4.7.2-stable_win64_console.exe"
```

Ожидается `no-sdk: PASS` и `host/client: PASS`. Если в сетевом логе появились пропуски выстрелов — поднять `per_second` до 30, но не выше: потолок должен оставаться заметно ниже скорости, с которой можно флудить.

- [ ] **Step 7: Коммит**

```bash
git add scripts/rate_limiter.gd scripts/rate_limiter.gd.uid scripts/net_player.gd tools/regression_test.gd
```

```bash
git commit -m "Бюджет на входящие RPC урона и выстрелов" -m "Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

## Task 8: Имя и комната с ограничениями

У полей ввода в `scenes/menu.tscn` нет `max_length`, а `display_name` реплицируется всем — имя произвольной длины ломает вёрстку табло и жжёт трафик. Плюс `user_id()` склеивает `Имя#1234`, а `Session.players()` режет строку по `#`, поэтому имя с решёткой показывается обрезанным.

**Files:**
- Modify: `scenes/menu.tscn` (узлы `NameEdit`, `RoomEdit`), `scripts/menu.gd:56-63`, `scripts/session.gd:169-174`, `scripts/game.gd:214-218`, `scripts/hud.gd` (строка табло)
- Test: `tools/regression_test.gd`

- [ ] **Step 1: Дописать падающую проверку**

В `tools/regression_test.gd` в конец `_run()` добавить:

```gdscript
	# Имя приходит от чужого клиента: длину режем при показе.
	main.player.display_name = "Ы".repeat(200)
	_check(main._name_of(main.player).length() <= 24, "длинное имя обрезается в киллфиде")
```

- [ ] **Step 2: Прогнать и убедиться, что проверка падает**

```bash
"/c/Users/admin/Desktop/Godot_v4.7.2-stable_win64.exe" --headless --path . res://tools/regression_test.tscn
```

Ожидается `FAIL длинное имя обрезается в киллфиде`.

- [ ] **Step 3: Ограничить ввод в сцене**

В `scenes/menu.tscn` в узел `Center/Panel/Rows/NameRow/NameEdit` добавить строку `max_length = 20`, в узел `Center/Panel/Rows/RoomRow/RoomEdit` — `max_length = 24`. Обе строки ставятся рядом с уже существующей `placeholder_text`.

- [ ] **Step 4: Чистить и обрезать при сохранении**

В `scripts/menu.gd` заменить `_remember()` (строки 56–63) на:

```gdscript
const NAME_LIMIT := 20
const ROOM_LIMIT := 24

func _remember() -> void:
	Session.player_name = _clean(name_edit.text, NAME_LIMIT, "Игрок")
	Session.room_name = _clean(room_edit.text, ROOM_LIMIT, "contra-city")
	name_edit.text = Session.player_name
	room_edit.text = Session.room_name
	Session.save_settings()

## Решётка — разделитель в user_id («Имя#1234»), поэтому в самом имени её быть
## не должно: лобби показало бы обрезанное имя. Длину режем здесь же — имя
## уезжает всем по сети, и отсутствие лимита превращает его в канал для мусора.
func _clean(text: String, limit: int, fallback: String) -> String:
	var value := text.replace("#", "").strip_edges()
	if value.length() > limit:
		value = value.substr(0, limit)
	return value if value != "" else fallback
```

- [ ] **Step 5: Чистить и при чтении настроек**

`user://settings.cfg` правится руками, поэтому в `scripts/session.gd` заменить `load_settings()` (строки 169–174) на:

```gdscript
func load_settings() -> void:
	var config := ConfigFile.new()
	if config.load(SETTINGS_PATH) != OK:
		return
	player_name = _sanitize(str(config.get_value("player", "name", player_name)), 20, "Игрок")
	room_name = _sanitize(str(config.get_value("player", "room", room_name)), 24, "contra-city")

## Файл настроек лежит у пользователя и правится руками — доверять ему нельзя.
func _sanitize(value: String, limit: int, fallback: String) -> String:
	var text := value.replace("#", "").strip_edges()
	if text.length() > limit:
		text = text.substr(0, limit)
	return text if text != "" else fallback
```

- [ ] **Step 6: Обрезать при показе**

В `scripts/game.gd` заменить `_name_of` (строки 214–218) на:

```gdscript
func _name_of(node: Node) -> String:
	if node == null or not is_instance_valid(node):
		return "Мир"
	var label = node.get("display_name")
	var text := str(label) if label != null else node.name
	# Имя чужого бойца реплицируется его клиентом: при показе режем длину.
	return text.substr(0, 24)
```

В `scripts/hud.gd` в `_refresh_scoreboard` заменить подстановку имени на обрезанную:

```gdscript
			rows.append("%s%s        %d / %d" % [
				actor.display_name.substr(0, 24), " (вы)" if actor.local_control else "",
				wrapper.frags, wrapper.deaths])
```

- [ ] **Step 7: Прогнать стенд**

```bash
"/c/Users/admin/Desktop/Godot_v4.7.2-stable_win64.exe" --headless --path . res://tools/regression_test.tscn
```

Ожидается `PASS длинное имя обрезается в киллфиде`.

- [ ] **Step 8: Коммит**

```bash
git add scenes/menu.tscn scripts/menu.gd scripts/session.gd scripts/game.gd scripts/hud.gd tools/regression_test.gd
```

```bash
git commit -m "Ограничить длину имени и комнаты, убрать решётку из имени" -m "Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

## Task 9: Киллфид видит чужие смерти, комната больше не null

`_update_remote` пишет `player.health.alive` напрямую, минуя `take_damage`, поэтому у чужого бойца сигнал `health.died` не срабатывает: киллфид показывает только свои убийства и свою смерть. Заодно в `net_manager.gd` осталось три места, где `Fusion.get_room()` разыменовывается без проверки, — поздний RPC после выхода из комнаты роняет процесс.

**Files:**
- Modify: `scripts/net_player.gd` (`_ready`, новые `_on_local_died`/`announce_death`), `scripts/net_manager.gd:20-93`, `scripts/net_manager.gd:187-193`, `scripts/game.gd:53-61`
- Test: `tools/run_network_tests.ps1`

- [ ] **Step 1: Объявить сигнал в менеджере**

В `scripts/net_manager.gd` к списку сигналов (после `signal kill_confirmed(...)`) добавить:

```gdscript
signal death_announced(victim_name: String, killer_name: String, headshot: bool)
```

- [ ] **Step 2: Объявлять смерть от владельца цели**

В `scripts/net_player.gd` в `_ready` после существующих подключений добавить:

```gdscript
	player.died.connect(_on_local_died)
	player.health.damaged.connect(_on_local_damaged)
```

и к полям класса добавить:

```gdscript
var _last_headshot: bool = false
```

Ниже, рядом с `_on_respawned`, добавить:

```gdscript
func _on_local_damaged(_amount: float, _attacker: Node, headshot: bool) -> void:
	_last_headshot = headshot

## Кто именно убил — знает только владелец цели, поэтому смерть объявляет он.
## RPC call_remote: себе не приходит, свою смерть покажет game._on_player_died.
func _on_local_died(attacker: Node) -> void:
	if not replicator.has_authority() or not NetApi.is_in_room():
		return
	var killer := "Мир"
	if attacker != null and is_instance_valid(attacker):
		var label = attacker.get("display_name")
		if label != null:
			killer = str(label)
	NetApi.rpc_all(announce_death, [player.display_name, killer, _last_headshot])

@rpc("authority", "call_remote", "reliable")
func announce_death(victim_name: String, killer_name: String, headshot: bool) -> void:
	if NetApi.rpc_sender() != replicator.get_owner_id():
		return
	if Session.net != null:
		Session.net.death_announced.emit(victim_name.substr(0, 24), killer_name.substr(0, 24), headshot)
```

- [ ] **Step 3: Показывать чужие смерти в киллфиде**

В `scripts/game.gd` в `_bind_network` (строки 53–61) добавить подписку:

```gdscript
	if not net.death_announced.is_connected(_on_death_announced):
		net.death_announced.connect(_on_death_announced)
```

и рядом с `_on_network_kill` добавить:

```gdscript
## Своё убийство уже показал kill_confirmed, поэтому строки от своего имени
## пропускаем. Тёзки в одной комнате потеряют одну строку — терпимо, имена в
## Photon не уникальны и сравнивать больше нечего.
func _on_death_announced(victim_name: String, killer_name: String, headshot: bool) -> void:
	if player != null and is_instance_valid(player) and killer_name == player.display_name:
		return
	killfeed.emit("%s убил %s%s" % [killer_name, victim_name, " в голову" if headshot else ""])
```

- [ ] **Step 4: Убрать разыменование комнаты без проверки**

В `scripts/net_manager.gd` заменить приём заявки и выдачу (строки 56–86):

```gdscript
@rpc("any_peer", "call_remote", "reliable")
func receive_pickup_request(index: int) -> void:
	# RPC может догнать нас уже после выхода из комнаты.
	if is_host() and NetApi.room() != null:
		_grant_pickup(index, NetApi.rpc_sender())

func _grant_pickup(index: int, sender: int) -> void:
	if index < 0 or index >= _pickups.size() or not is_instance_valid(_pickups[index]):
		return
	var pickup := _pickups[index]
	var now: float = NetApi.network_time()
	var expires: float = maxf(_pickup_expiry.get(index, 0.0),
		float(NetApi.room_property("pickup_%d" % index, 0.0)))
	if now < expires:
		return
	for actor in get_tree().get_nodes_in_group("combatants"):
		if actor is PlayerCharacter and actor.peer_id == sender and actor.health.alive:
			if actor.global_position.distance_to(pickup.global_position) > 3.8:
				return
			_pickup_expiry[index] = now + pickup.respawn_delay
			NetApi.set_room_property("pickup_%d" % index, _pickup_expiry[index])
			pickup.set_available(false)
			if sender == NetApi.local_player_id():
				_apply_pickup(index)
			else:
				NetApi.rpc_to_player(sender, receive_pickup_grant, [index])
			return

@rpc("any_peer", "call_remote", "reliable")
func receive_pickup_grant(index: int) -> void:
	var room := NetApi.room()
	if room == null or NetApi.rpc_sender() != int(room.call("get_master_client_id")):
		return
	_apply_pickup(index)
```

и цикл доступности в `_process` (строки 187–193):

```gdscript
	if is_online() and not _pickups.is_empty():
		var room := NetApi.room()
		if room == null:
			return
		var props: Dictionary = room.call("get_custom_properties")
		var now: float = NetApi.network_time()
		for i in _pickups.size():
			if is_instance_valid(_pickups[i]):
				var expiry: float = maxf(_pickup_expiry.get(i, 0.0), float(props.get("pickup_%d" % i, 0.0)))
				_pickups[i].set_available(now >= expiry)
```

- [ ] **Step 5: Прогнать живую сеть и увидеть строку о чужой смерти**

```powershell
./tools/run_network_tests.ps1 -Godot "C:/Users/admin/Desktop/Godot_v4.7.2-stable_win64_console.exe"
```

Ожидается `host: PASS` и `client: PASS`. Дополнительно проверить, что объявление дошло:

```bash
grep -h 'убил' build/network-*/host.log build/network-*/client.log
```

Ожидается хотя бы одна строка вида `<имя> убил <имя>` в логе того клиента, который не был ни жертвой, ни стрелком — в тесте на двоих это лог стрелка, где строка появиться не должна, поэтому при двух участниках достаточно убедиться в отсутствии ошибок RPC:

```bash
grep -c 'apply_remote_damage\|announce_death' build/network-*/*.err
```

Ожидается `0`.

- [ ] **Step 6: Коммит**

```bash
git add scripts/net_player.gd scripts/net_manager.gd scripts/game.gd
```

```bash
git commit -m "Киллфид показывает чужие смерти, комната проверяется на null" -m "Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---
# Фаза C — геймплей

## Task 10: Труп бота перестаёт ловить пули

Замер аудита: у мёртвого бота `collision_layer == 4`, коллайдер включён, луч сквозь труп попадает в бота. Пять секунд до респавна корпус глотает выстрелы и мешает ходить. У игрока это сделано правильно (`player.gd:93`), у бота аналога нет. Заодно у `Bot` нет `is_dead()`, который `game._network_spawn` зовёт на всех участниках группы `combatants`.

**Files:**
- Modify: `scripts/bot.gd:26-27`, `scripts/bot.gd:46-52`, `scripts/bot.gd:304-320`
- Test: `tools/regression_test.gd` (проверка из Task 1)

- [ ] **Step 1: Убедиться, что проверка из Task 1 красная**

```bash
"/c/Users/admin/Desktop/Godot_v4.7.2-stable_win64.exe" --headless --path . res://tools/regression_test.tscn
```

Ожидается `FAIL труп бота убран со слоя попаданий`.

- [ ] **Step 2: Дописать проверку на луч сквозь труп**

В `tools/regression_test.gd` сразу после проверки `труп бота убран со слоя попаданий` добавить:

```gdscript
	var space := player.get_world_3d().direct_space_state
	var across := PhysicsRayQueryParameters3D.create(
		bot.global_position + Vector3.UP * 0.9 + Vector3.RIGHT * 4.0,
		bot.global_position + Vector3.UP * 0.9 - Vector3.RIGHT * 4.0)
	across.collision_mask = 1 | 2 | 4
	_check(space.intersect_ray(across).get("collider") != bot, "луч проходит сквозь труп")
```

- [ ] **Step 3: Взять коллайдер и завести общий пересчёт**

В `scripts/bot.gd` к `@onready`-полям (строки 26–27) добавить коллайдер:

```gdscript
@onready var collider: CollisionShape3D = $Collider
```

и рядом с `respawn()` добавить метод и предикат:

```gdscript
## Труп не должен ловить пули и мешать ходить. У игрока это уже так
## (player.gd, update_life_visuals), у бота коллайдер оставался включённым весь
## респавн: выстрел в корпус глотался кровавыми искрами вместо урона.
func _update_life_state() -> void:
	var alive := health.alive
	collision_layer = 4 if alive else 0
	collider.set_deferred("disabled", not alive)

## Спрашивает game._network_spawn у всех бойцов в группе combatants.
func is_dead() -> bool:
	return not health.alive
```

- [ ] **Step 4: Вызвать пересчёт на смерти, респавне и старте**

В `scripts/bot.gd` в конец `_ready()` (после `_build_visual()`) добавить:

```gdscript
	_update_life_state()
```

В `_on_died` после `velocity = Vector3.ZERO` добавить:

```gdscript
	_update_life_state()
```

В `respawn` после `health.reset()` добавить:

```gdscript
	_update_life_state()
```

- [ ] **Step 5: Прогнать стенд**

```bash
"/c/Users/admin/Desktop/Godot_v4.7.2-stable_win64.exe" --headless --path . res://tools/regression_test.tscn
```

Ожидается `PASS труп бота убран со слоя попаданий` и `PASS луч проходит сквозь труп`.

- [ ] **Step 6: Коммит**

```bash
git add scripts/bot.gd tools/regression_test.gd
```

```bash
git commit -m "Труп бота не ловит пули и не мешает ходить" -m "Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

## Task 11: Бойцы сталкиваются телами

`scenes/player.tscn` ставит `collision_mask = 5` — мир и боты, слоя `player` (2) в маске нет, поэтому двое сетевых игроков стоят в одной точке. У бота `collision_mask = 3` — боты не видят друг друга и слипаются в кучу.

**Files:**
- Modify: `scenes/player.tscn:18`, `scenes/bot.tscn:20`, `scripts/bot.gd:266-270`
- Test: `tools/regression_test.gd` (проверка из Task 1)

- [ ] **Step 1: Дописать проверку на маску бота**

В `tools/regression_test.gd` сразу после проверки `игрок сталкивается с игроками` добавить:

```gdscript
	_check(bot.collision_mask & 4 != 0, "боты сталкиваются друг с другом")
```

- [ ] **Step 2: Прогнать и убедиться, что обе проверки красные**

```bash
"/c/Users/admin/Desktop/Godot_v4.7.2-stable_win64.exe" --headless --path . res://tools/regression_test.tscn
```

Ожидается `FAIL игрок сталкивается с игроками` и `FAIL боты сталкиваются друг с другом`.

- [ ] **Step 3: Поправить маски в сценах**

В `scenes/player.tscn` в узле `Player` заменить `collision_mask = 5` на `collision_mask = 7`.

В `scenes/bot.tscn` в узле `Bot` заменить `collision_mask = 3` на `collision_mask = 7`.

Чужое тело в сети двигает репликация позиции, а не `move_and_slide`, поэтому оно работает как неподвижное препятствие и не может вытолкнуть локального игрока в геометрию.

- [ ] **Step 4: Научить бота обходить других ботов**

Без этого восемь ботов будут упираться друг в друга: усы обхода смотрят только на мир. В `scripts/bot.gd` заменить `_blocked` (строки 266–270):

```gdscript
func _blocked(space: PhysicsDirectSpaceState3D, origin: Vector3, dir: Vector3, distance: float) -> bool:
	var query := PhysicsRayQueryParameters3D.create(origin, origin + dir * distance)
	query.collision_mask = 1 | 4          # мир и другие боты
	query.exclude = [get_rid()]
	return not space.intersect_ray(query).is_empty()
```

- [ ] **Step 5: Прогнать стенд и убедиться, что боты не встали**

```bash
"/c/Users/admin/Desktop/Godot_v4.7.2-stable_win64.exe" --headless --path . res://tools/smoke_test.tscn
```

Ожидается `PASS` обеих новых проверок в `regression_test` и в `smoke_test` строка `боты: всего=8 живых=8 ... движутся=` со значением не меньше 5. Если движутся меньше пяти — боты заклинило друг о друга, тогда увеличить дистанцию бокового луча в `_avoid_obstacles` с 2.6 до 3.2.

```bash
"/c/Users/admin/Desktop/Godot_v4.7.2-stable_win64.exe" --headless --path . res://tools/regression_test.tscn
```

- [ ] **Step 6: Коммит**

```bash
git add scenes/player.tscn scenes/bot.tscn scripts/bot.gd tools/regression_test.gd
```

```bash
git commit -m "Бойцы сталкиваются телами, боты обходят друг друга" -m "Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

## Task 12: Прицел знает зум, мышь захватывается в одном месте, прыжок только по нажатию

Три независимые мелочи в управлении, которые дешевле сделать одним заходом:

1. `crosshair.gd:12` держит `fov_degrees = 85.0` и не обновляется никогда — в прицеливании (fov 55) штрихи показывают разброс примерно в 1.7 раза меньше настоящего.
2. `player.configure_control` безусловно ставит `MOUSE_MODE_CAPTURED`, а `configure_owner()` переспрашивается на `authority_changed` — при уходе хоста мышь перехватывается поверх открытой паузы или магазина.
3. `_apply_gravity` прыгает по `is_action_pressed("jump")`: зажатый пробел даёт бесконечный банихоп.

**Files:**
- Modify: `scripts/crosshair.gd:26-30`, `scripts/hud.gd:71-84`, `scripts/player.gd:79-91`, `scripts/player.gd:138-156`, `scripts/player.gd:278-288`, `scripts/game.gd:84-93`, `scripts/game.gd:75-80`
- Test: `tools/regression_test.gd`

- [ ] **Step 1: Дописать падающую проверку**

В `tools/regression_test.gd` в конец `_run()` добавить:

```gdscript
	# Прицел должен знать текущий fov, иначе в прицеливании штрихи врут.
	# Физику игрока глушим: иначе _update_view утянет fov назад к базовому.
	main.player.set_physics_process(false)
	main.player.camera.fov = 55.0
	await get_tree().process_frame
	_check(is_equal_approx(main.hud._crosshair.fov_degrees, 55.0), "прицел знает fov камеры")
	main.player.set_physics_process(true)
```

- [ ] **Step 2: Прогнать и убедиться, что проверка падает**

```bash
"/c/Users/admin/Desktop/Godot_v4.7.2-stable_win64.exe" --headless --path . res://tools/regression_test.tscn
```

Ожидается `FAIL прицел знает fov камеры`.

- [ ] **Step 3: Дать прицелу сеттер и кормить его из HUD**

В `scripts/crosshair.gd` рядом с `set_spread` добавить:

```gdscript
## Разброс считается в пикселях от углового, поэтому прицелу нужен текущий fov:
## в оптике и в прицеливании он другой.
func set_fov(degrees: float) -> void:
	if absf(degrees - fov_degrees) < 0.01:
		return
	fov_degrees = degrees
	queue_redraw()
```

В `scripts/hud.gd` в `_process` заменить блок про подсказку (строки 81–84) на:

```gdscript
	if player != null and player.weapons != null:
		_crosshair.set_fov(player.camera.fov)
		_hint_label.visible = player.weapons.reloading
		_hint_label.text = "ПЕРЕЗАРЯДКА"
```

- [ ] **Step 4: Убрать захват мыши из `configure_control`**

В `scripts/player.gd` заменить `configure_control` (строки 78–91):

```gdscript
## Вызывается и после сетевого спавна: дочерний _ready раньше родительского.
## Режимом мыши здесь не управляем — этот метод переспрашивается при смене
## авторитета (уход хоста), и захват перебивал бы открытую паузу или магазин.
## Мышь берут те, кто знает состояние экрана: game при спавне и hud в паузе.
func configure_control(mine: bool) -> void:
	local_control = mine
	if _capsule == null:
		return
	if mine:
		camera.make_current()
	elif camera.current:
		camera.clear_current()
	if not mine and _body_model == null:
		_build_body_model()
	weapons.set_local_visuals(mine)
	update_life_visuals()
```

В `scripts/game.gd` в `_on_local_player_spawned` (строки 75–80) и в `_spawn_player` (строки 84–93) добавить последней строкой в каждый метод:

```gdscript
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
```

- [ ] **Step 5: Прыжок только по новому нажатию**

В `scripts/player.gd` заменить `_read_input` (строки 138–146):

```gdscript
func _read_input() -> void:
	if not input_enabled or shop_open or Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		_input_dir = Vector2.ZERO
		_wants_jump = false
		sprinting = false
		return
	_input_dir = Input.get_vector("move_left", "move_right", "move_forward", "move_back")
	# Прыжок копится по новому нажатию и тратится при касании земли: зажатый
	# пробел больше не даёт бесконечный банихоп, но нажатие в воздухе
	# срабатывает при посадке — так привычнее.
	if Input.is_action_just_pressed("jump"):
		_wants_jump = true
	sprinting = Input.is_action_pressed("sprint") and not crouching and _input_dir.y < 0.0
```

и `_apply_gravity` (строки 148–156):

```gdscript
func _apply_gravity(delta: float) -> void:
	if is_on_floor():
		if _wants_jump:
			velocity.y = jump_velocity
			_wants_jump = false
		else:
			velocity.y = -0.1
	else:
		velocity.y -= _gravity() * delta
```

В `respawn` (строки 278–288) после `velocity = Vector3.ZERO` добавить:

```gdscript
	_wants_jump = false
```

- [ ] **Step 6: Прогнать стенд**

```bash
"/c/Users/admin/Desktop/Godot_v4.7.2-stable_win64.exe" --headless --path . res://tools/regression_test.tscn
```

Ожидается `PASS прицел знает fov камеры`.

- [ ] **Step 7: Проверить руками то, что headless не видит**

```bash
"/c/Users/admin/Desktop/Godot_v4.7.2-stable_win64.exe" --path .
```

Пройти по списку: офлайн-матч — мышь захвачена сразу, Esc отпускает и возвращает её; зажатый пробел даёт один прыжок, а не серию; в прицеливании штрихи расходятся сильнее, чем раньше.

- [ ] **Step 8: Коммит**

```bash
git add scripts/crosshair.gd scripts/hud.gd scripts/player.gd scripts/game.gd tools/regression_test.gd
```

```bash
git commit -m "Прицел знает зум, мышь захватывается в одном месте, прыжок по нажатию" -m "Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

## Task 13: Идемпотентная сборка карты и мелкий мусор

`map.build()` не чистит `player_spawns`, `bot_spawns`, `weapon_spawns` и старый узел `Props` — повторный вызов удваивает карту. Плюс два мелких дефекта: `hud.push_killfeed` делает `free()` на метке, которую ещё держит живой твин, а `weapon_pickup._restore` начинается с `if not is_instance_valid(self)` — это мёртвая проверка, на невалидном экземпляре метод не вызвать.

**Files:**
- Modify: `scripts/map_builder.gd:61-70`, `scripts/hud.gd:264-275`, `scripts/weapon_pickup.gd:57-63`
- Test: `tools/regression_test.gd`

- [ ] **Step 1: Дописать падающую проверку**

Блок ставится **в самый конец** `_run()`, после всех прочих проверок: пересборка карты пересоздаёт узлы, и проверять что-то после неё бессмысленно.

```gdscript
	# Повторная сборка не должна удваивать карту.
	var city: CityMap = main.get_node("Map")
	var spawns := city.player_spawns.size()
	var props := city.get_node("Props").get_child_count()
	city.build(main.match_seed)
	await get_tree().process_frame
	_check(city.player_spawns.size() == spawns, "повторная сборка не удваивает спавны")
	_check(city.get_node("Props").get_child_count() == props, "повторная сборка не удваивает пропы")
```

- [ ] **Step 2: Прогнать и убедиться, что проверки падают**

```bash
"/c/Users/admin/Desktop/Godot_v4.7.2-stable_win64.exe" --headless --path . res://tools/regression_test.tscn
```

Ожидается `FAIL повторная сборка не удваивает спавны` (спавнов станет 8 вместо 4).

- [ ] **Step 3: Чистить состояние перед сборкой**

В `scripts/map_builder.gd` заменить `build` (строки 61–70):

```gdscript
func build(seed_value: int = 20260920) -> void:
	# Повторный вызов не должен удваивать карту. remove_child до queue_free —
	# иначе освобождение отложится до конца кадра, имя "Props" окажется занято
	# и новый узел получит имя "Props2".
	player_spawns.clear()
	bot_spawns.clear()
	weapon_spawns.clear()
	for child in get_children():
		remove_child(child)
		child.queue_free()

	_rng.seed = seed_value
	_props = Node3D.new()
	_props.name = "Props"
	add_child(_props)

	_build_environment()
	_build_ground()
	_build_cells()
	_build_boundary()
```

- [ ] **Step 4: Освобождать метку киллфида отложенно**

В `scripts/hud.gd` в `push_killfeed` заменить строку `_killfeed.get_child(0).free()` на:

```gdscript
		_killfeed.get_child(0).queue_free()
```

Твин, который гасит метку, держит на неё ссылку; немедленный `free()` оставляет твин с освобождённой целью.

Там же, чтобы лишняя метка не участвовала в подсчёте до конца кадра, заменить условие цикла:

```gdscript
	while _killfeed.get_child_count() > 5:
		var oldest := _killfeed.get_child(0)
		_killfeed.remove_child(oldest)
		oldest.queue_free()
```

- [ ] **Step 5: Убрать мёртвую проверку**

В `scripts/weapon_pickup.gd` заменить `_restore` (строки 57–63):

```gdscript
func _restore() -> void:
	_available = true
	if _model != null:
		_model.visible = true
	Sfx.play_3d(&"pickup", global_position, 0.7, -12.0, 20.0)
```

- [ ] **Step 6: Прогнать оба стенда**

```bash
"/c/Users/admin/Desktop/Godot_v4.7.2-stable_win64.exe" --headless --path . res://tools/regression_test.tscn
```

```bash
"/c/Users/admin/Desktop/Godot_v4.7.2-stable_win64.exe" --headless --path . res://tools/smoke_test.tscn
```

Ожидается `REGRESSION TEST: PASS failures=0` и в smoke-тесте прежняя строка `карта: объектов=118, спавны игрока=4, ботов=8, оружия=8`.

- [ ] **Step 7: Коммит**

```bash
git add scripts/map_builder.gd scripts/hud.gd scripts/weapon_pickup.gd tools/regression_test.gd
```

```bash
git commit -m "Идемпотентная сборка карты, отложенное удаление строк киллфида" -m "Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---
# Фаза D — производительность

## Task 14: Формы столкновений строятся один раз на модель

`_add_collision` вызывает `create_trimesh_collision()` на каждом `MeshInstance3D` каждого из 118 объектов карты. Вогнутый тримеш строится в рантайме заново для каждой копии дома, хотя уникальных моделей около тридцати. Это самая дорогая точка загрузки матча и постоянная нагрузка на физику: лучи стрельбы и усы ботов идут по тримешам.

**Files:**
- Modify: `scripts/map_builder.gd:56-59`, `scripts/map_builder.gd:171-207`
- Test: `tools/regression_test.gd`

- [ ] **Step 1: Записать базовое время сборки**

В `tools/regression_test.gd` в блок пересборки карты (тот, что добавлен в Task 13) добавить замер — строкой перед `city.build(...)` и после:

```gdscript
	var started := Time.get_ticks_msec()
	city.build(main.match_seed)
	print("сборка карты: %d мс" % (Time.get_ticks_msec() - started))
```

Прогнать и выписать число:

```bash
"/c/Users/admin/Desktop/Godot_v4.7.2-stable_win64.exe" --headless --path . res://tools/regression_test.tscn
```

Записать строку `сборка карты: N мс` — это базовая величина, с которой сравнивается результат в Step 5.

- [ ] **Step 2: Завести кэш форм**

В `scripts/map_builder.gd` к полям (после `var _cache: Dictionary = {}`) добавить:

```gdscript
## Путь модели -> [{"shape": Shape3D, "transform": Transform3D}, ...].
var _shapes: Dictionary = {}
```

- [ ] **Step 3: Заменить построение коллизий**

В `scripts/map_builder.gd` заменить `_place_model` и `_add_collision` (строки 171–194):

```gdscript
func _place_model(path: String, position: Vector3, yaw: float, with_collision: bool) -> Node3D:
	var scene: PackedScene = _cache.get(path)
	if scene == null:
		if not ResourceLoader.exists(path):
			return null
		scene = load(path)
		_cache[path] = scene
	var node := scene.instantiate() as Node3D
	if node == null:
		return null
	_props.add_child(node)
	node.position = position
	node.rotation.y = yaw
	node.scale = Vector3.ONE * GRID
	if with_collision:
		_attach_collision(node, _collision_shapes(path, node))
	return node

## Формы считаются один раз на модель и переиспользуются всеми её копиями:
## раньше на каждый из 118 объектов заново строился вогнутый тримеш.
## Выпуклая оболочка на меш дешевле и для коробчатых домов Kenney достаточна —
## внутрь них всё равно не заходят, а дороги и декали коллизию не получают.
func _collision_shapes(path: String, node: Node3D) -> Array:
	if _shapes.has(path):
		return _shapes[path]
	var built: Array = []
	if node is MeshInstance3D and node.mesh != null:
		_append_shape(node.mesh, Transform3D.IDENTITY, built)
	for child in node.get_children():
		_collect_shapes(child, Transform3D.IDENTITY, built)
	_shapes[path] = built
	return built

func _collect_shapes(node: Node, parent_transform: Transform3D, out: Array) -> void:
	var transform := parent_transform
	if node is Node3D:
		transform = parent_transform * node.transform
	if node is MeshInstance3D and node.mesh != null:
		_append_shape(node.mesh, transform, out)
	for child in node.get_children():
		_collect_shapes(child, transform, out)

func _append_shape(mesh: Mesh, transform: Transform3D, out: Array) -> void:
	var shape := mesh.create_convex_shape(true, true)
	if shape != null:
		out.append({"shape": shape, "transform": transform})

## Один StaticBody3D на объект вместо одного на каждый меш внутри него.
func _attach_collision(node: Node3D, shapes: Array) -> void:
	if shapes.is_empty():
		return
	var body := StaticBody3D.new()
	node.add_child(body)
	for row in shapes:
		var collision := CollisionShape3D.new()
		collision.shape = row["shape"]
		collision.transform = row["transform"]
		body.add_child(collision)
```

- [ ] **Step 4: Убрать тримеш и из запасного варианта**

`_place_block` — то, что ставится когда моделей нет. Ему тримеш не нужен вовсе: это коробка. В `scripts/map_builder.gd` заменить `_place_block` (строки 196–207):

```gdscript
func _place_block(center: Vector3, size: Vector3, color: Color) -> void:
	var mesh := BoxMesh.new()
	mesh.size = size
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.roughness = 0.85
	var node := MeshInstance3D.new()
	node.mesh = mesh
	node.material_override = mat
	_props.add_child(node)
	node.position = center + Vector3.UP * size.y * 0.5

	# Коробке хватает BoxShape3D: тримеш по её же мешу — лишняя работа.
	var body := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	shape.shape = box
	body.add_child(shape)
	node.add_child(body)
```

- [ ] **Step 5: Сравнить время и проверить, что по карте по-прежнему ходят**

```bash
"/c/Users/admin/Desktop/Godot_v4.7.2-stable_win64.exe" --headless --path . res://tools/regression_test.tscn
```

Ожидается: `сборка карты: N мс` заметно меньше записанного в Step 1 (ждём кратного выигрыша за счёт кэша), `PASS игрок стоит на земле`, `PASS повторная сборка не удваивает пропы`, `REGRESSION TEST: PASS failures=0`.

```bash
"/c/Users/admin/Desktop/Godot_v4.7.2-stable_win64.exe" --headless --path . res://tools/smoke_test.tscn
```

Ожидается прежнее `карта: объектов=118`, `на земле=true`, `боты: ... на земле=8`.

- [ ] **Step 6: Проверить руками, что стены остались стенами**

```bash
"/c/Users/admin/Desktop/Godot_v4.7.2-stable_win64.exe" --path .
```

Обойти квартал по кругу: дома не проходятся насквозь, пули в них не улетают, на крыши контейнеров можно забраться. Выпуклая оболочка «запечатывает» вогнутые части — если окажется, что какой-то проход между домами закрылся, вернуть этой модели тримеш точечно, добавив её имя в список исключений, а не откатывая кэш целиком.

- [ ] **Step 7: Коммит**

```bash
git add scripts/map_builder.gd tools/regression_test.gd
```

```bash
git commit -m "Формы столкновений карты строятся один раз на модель" -m "Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

## Task 15: Эффекты и звук перестают мусорить на каждом выстреле

`Effects.tracer` создаёт новый `StandardMaterial3D` и новый `ImmediateMesh` на каждую дробину (у SPAS-12 это девять наборов за выстрел), `impact` — `CPUParticles3D` вместе с `BoxMesh` и материалом, `Sfx._spawn_3d` — новый `AudioStreamPlayer3D` на каждый звук. Восемь ботов с автоматами дают десятки таких узлов в секунду.

**Files:**
- Modify: `scripts/effects.gd:6-31`, `scripts/effects.gd:56-74`, `scripts/effects.gd:104-111`, `scripts/sfx.gd:14-27`, `scripts/sfx.gd:42-67`, `scripts/sfx.gd:119-123`
- Test: `tools/smoke_test.tscn` (глазами по логу), `tools/regression_test.gd`

- [ ] **Step 1: Дописать проверку на пул**

В `tools/regression_test.gd` перед блоком пересборки карты добавить:

```gdscript
	# Звук не должен плодить узлы: пул фиксированного размера.
	var before_players := Sfx.get_child_count()
	for i in 50:
		Sfx.play_3d(&"hit", main.player.global_position)
	await get_tree().process_frame
	_check(Sfx.get_child_count() == before_players,
		"звук берётся из пула (узлов было %d, стало %d)" % [before_players, Sfx.get_child_count()])
```

- [ ] **Step 2: Прогнать и убедиться, что проверка падает**

```bash
"/c/Users/admin/Desktop/Godot_v4.7.2-stable_win64.exe" --headless --path . res://tools/regression_test.tscn
```

Ожидается `FAIL звук берётся из пула` — узлы создаются в `current_scene`, поэтому число детей `Sfx` не изменится, но проверка станет осмысленной после Step 4; если она прошла сразу, всё равно оставить и идти дальше.

- [ ] **Step 3: Общие материалы и меши для эффектов**

В `scripts/effects.gd` к полям класса (сразу после `extends RefCounted`) добавить:

```gdscript
## Материалы и меши общие на все эффекты: раньше каждая дробина создавала свой
## StandardMaterial3D, а на них компилируются варианты шейдера.
static var _tracer_materials: Dictionary = {}     # Color -> StandardMaterial3D
static var _spark: Mesh = null
static var _mark_material: StandardMaterial3D = null
```

Заменить `tracer` (строки 6–31):

```gdscript
static func tracer(world: Node, from: Vector3, to: Vector3, color: Color = Color(1.0, 0.85, 0.45)) -> void:
	if world == null or from.distance_to(to) < 0.05:
		return
	var mesh := ImmediateMesh.new()
	mesh.surface_begin(Mesh.PRIMITIVE_LINES, _tracer_material(color))
	mesh.surface_add_vertex(from)
	mesh.surface_add_vertex(to)
	mesh.surface_end()

	var node := MeshInstance3D.new()
	node.mesh = mesh
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	world.add_child(node)
	# Раньше альфа гасилась твином по материалу — с общим материалом так нельзя,
	# да и 70 мс всё равно не разглядеть.
	_kill_later(node, 0.07)

static func _tracer_material(color: Color) -> StandardMaterial3D:
	var cached: StandardMaterial3D = _tracer_materials.get(color)
	if cached != null:
		return cached
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = color
	mat.emission_enabled = true
	mat.emission = color
	mat.emission_energy_multiplier = 2.0
	_tracer_materials[color] = mat
	return mat
```

Заменить создание отметины внутри `impact` (строки 56–74) — материал берётся общий:

```gdscript
	if not flesh:
		# Тёмная отметина на поверхности вместо полноценного декаля.
		var mark := MeshInstance3D.new()
		var quad := QuadMesh.new()
		quad.size = Vector2(0.09, 0.09)
		mark.mesh = quad
		mark.material_override = _mark()
		mark.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		world.add_child(mark)
		mark.global_position = point + normal * 0.012
		if absf(normal.dot(Vector3.UP)) < 0.98:
			mark.look_at(mark.global_position + normal, Vector3.UP)
		else:
			mark.look_at(mark.global_position + normal, Vector3.FORWARD)
		_kill_later(mark, 12.0)

static func _mark() -> StandardMaterial3D:
	if _mark_material == null:
		_mark_material = StandardMaterial3D.new()
		_mark_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_mark_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		_mark_material.albedo_color = Color(0.05, 0.04, 0.04, 0.85)
	return _mark_material
```

Заменить `_spark_mesh` (строки 104–111) и его вызов `sparks.mesh = _spark_mesh()` на общий меш:

```gdscript
static func _spark_mesh() -> Mesh:
	if _spark == null:
		var box := BoxMesh.new()
		box.size = Vector3(0.02, 0.02, 0.02)
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.vertex_color_use_as_albedo = true
		box.material = mat
		_spark = box
	return _spark
```

- [ ] **Step 4: Пул аудиоплееров**

В `scripts/sfx.gd` к константам и полям (строки 9–16) добавить:

```gdscript
const POOL_3D := 24
const POOL_2D := 8

var _pool_3d: Array[AudioStreamPlayer3D] = []
var _pool_2d: Array[AudioStreamPlayer] = []
var _next_3d: int = 0
var _next_2d: int = 0
```

В конец `_ready()` добавить создание пула:

```gdscript
	# Пул вместо узла на каждый звук: восемь ботов с автоматами создавали и
	# освобождали десятки AudioStreamPlayer3D в секунду. Узлы живут под
	# автозагрузкой и переживают смену сцены — World3D у корневого окна тот же.
	for i in POOL_3D:
		var p3 := AudioStreamPlayer3D.new()
		p3.unit_size = 10.0
		add_child(p3)
		_pool_3d.append(p3)
	for i in POOL_2D:
		var p2 := AudioStreamPlayer.new()
		add_child(p2)
		_pool_2d.append(p2)
```

Заменить `play_2d` и `_spawn_3d` (строки 42–67):

```gdscript
func play_2d(sound: StringName, pitch: float = 1.0, db_offset: float = 0.0) -> void:
	var stream: AudioStream = _bank.get(sound)
	if stream == null:
		return
	var p := _take_2d()
	p.stream = stream
	p.pitch_scale = pitch * _rng.randf_range(0.97, 1.03)
	p.volume_db = VOLUME_DB + db_offset
	p.play()

func _spawn_3d(stream: AudioStream, position: Vector3, pitch: float, db_offset: float, max_distance: float) -> void:
	var p := _take_3d()
	p.stream = stream
	p.pitch_scale = pitch * _rng.randf_range(0.96, 1.04)
	p.volume_db = VOLUME_DB + db_offset
	p.max_distance = max_distance
	p.global_position = position
	p.play()

## Свободный слот, иначе самый старый по кругу: обрыв далёкого звука слышно
## меньше, чем просадку от аллокаций.
func _take_3d() -> AudioStreamPlayer3D:
	for i in _pool_3d.size():
		var index := (_next_3d + i) % _pool_3d.size()
		if not _pool_3d[index].playing:
			_next_3d = (index + 1) % _pool_3d.size()
			return _pool_3d[index]
	var oldest := _pool_3d[_next_3d]
	_next_3d = (_next_3d + 1) % _pool_3d.size()
	return oldest

func _take_2d() -> AudioStreamPlayer:
	for i in _pool_2d.size():
		var index := (_next_2d + i) % _pool_2d.size()
		if not _pool_2d[index].playing:
			_next_2d = (index + 1) % _pool_2d.size()
			return _pool_2d[index]
	var oldest := _pool_2d[_next_2d]
	_next_2d = (_next_2d + 1) % _pool_2d.size()
	return oldest
```

Удалить `_sound_root()` (строки 119–123) — после пула он никем не вызывается.

- [ ] **Step 5: Прогнать стенды и послушать**

```bash
"/c/Users/admin/Desktop/Godot_v4.7.2-stable_win64.exe" --headless --path . res://tools/regression_test.tscn
```

Ожидается `PASS звук берётся из пула (узлов было 32, стало 32)` и `REGRESSION TEST: PASS failures=0`.

```bash
"/c/Users/admin/Desktop/Godot_v4.7.2-stable_win64.exe" --path .
```

Послушать офлайн-матч: выстрелы, шаги и попадания на месте, дальние выстрелы не обрываются во время своей же стрельбы. Если обрываются — поднять `POOL_3D` до 32.

- [ ] **Step 6: Коммит**

```bash
git add scripts/effects.gd scripts/sfx.gd tools/regression_test.gd
```

```bash
git commit -m "Общие ресурсы эффектов и пул аудиоплееров" -m "Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

## Task 16: Видимость бойца пересчитывается только на смене состояния

`player._physics_process` для чужих бойцов каждый кадр зовёт `update_life_visuals()`, а тот каждый кадр ставит `collider.set_deferred("disabled", ...)` — отложенный вызов на каждого чужого бойца в каждом кадре. Заодно `net_player._build_world_weapon` освобождает старую модель немедленным `free()` посреди `_process`.

**Files:**
- Modify: `scripts/player.gd:41-45`, `scripts/player.gd:93-98`, `scripts/net_player.gd:136-139`
- Test: `tools/regression_test.gd`

- [ ] **Step 1: Дописать проверку**

В `tools/regression_test.gd` рядом с проверкой трупа бота (после `_check(bot.collision_layer == 0, ...)`) добавить:

```gdscript
	# Пересчёт видимости идемпотентен: повторный вызов ничего не ломает.
	player.update_life_visuals()
	player.update_life_visuals()
	_check(player.collision_layer == 2, "живой игрок остаётся на своём слое")
```

- [ ] **Step 2: Прогнать — проверка должна пройти и до правки**

```bash
"/c/Users/admin/Desktop/Godot_v4.7.2-stable_win64.exe" --headless --path . res://tools/regression_test.tscn
```

Ожидается `PASS живой игрок остаётся на своём слое`. Это страховка: задача чисто оптимизационная, и проверка нужна, чтобы кэш состояния не сломал переключение слоёв.

- [ ] **Step 3: Кэшировать состояние**

В `scripts/player.gd` к полям (после `var _wants_jump: bool = false`) добавить:

```gdscript
## Битовая маска того, от чего зависит внешний вид: жив / свой / есть модель.
var _visual_state: int = -1
```

Заменить `update_life_visuals` (строки 93–98):

```gdscript
## Зовётся каждый кадр для чужих бойцов, поэтому пересчитываем только на смене
## состояния: set_deferred на каждом кадре — лишняя очередь вызовов на каждого
## бойца в комнате.
func update_life_visuals() -> void:
	var state := (1 if health.alive else 0) | (2 if local_control else 0) | (4 if _body_model != null else 0)
	if state == _visual_state:
		return
	_visual_state = state
	body_mesh.visible = not local_control and health.alive and _body_model == null
	if _body_model != null:
		_body_model.visible = not local_control and health.alive
	collision_layer = 2 if health.alive else 0
	collider.set_deferred("disabled", not health.alive)
```

- [ ] **Step 4: Освобождать старую модель оружия отложенно**

В `scripts/net_player.gd` в `_build_world_weapon` заменить `_world_weapon.free()` на:

```gdscript
	if _world_weapon != null:
		_world_weapon.queue_free()
```

Метод вызывается из `_process`; немедленный `free()` посреди обхода дерева — лишний риск без всякой выгоды.

- [ ] **Step 5: Прогнать оба стенда и живую сеть**

```bash
"/c/Users/admin/Desktop/Godot_v4.7.2-stable_win64.exe" --headless --path . res://tools/regression_test.tscn
```

```bash
"/c/Users/admin/Desktop/Godot_v4.7.2-stable_win64.exe" --headless --path . res://tools/smoke_test.tscn
```

```powershell
./tools/run_network_tests.ps1 -Godot "C:/Users/admin/Desktop/Godot_v4.7.2-stable_win64_console.exe"
```

Ожидается `REGRESSION TEST: PASS failures=0`, в smoke-тесте прежние строки про игрока и ботов, в сетевом тесте `host: PASS` и `client: PASS` — в нём есть проверки `dead body not hittable` и `remote character visible`, именно они закрывают кэш состояния.

- [ ] **Step 6: Коммит**

```bash
git add scripts/player.gd scripts/net_player.gd tools/regression_test.gd
```

```bash
git commit -m "Видимость бойца пересчитывается только на смене состояния" -m "Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

# Финальная сверка

- [ ] **Прогнать всё подряд**

```powershell
./tools/run_offline_tests.ps1 -Godot "C:/Users/admin/Desktop/Godot_v4.7.2-stable_win64.exe"
```

```powershell
./tools/run_network_tests.ps1 -Godot "C:/Users/admin/Desktop/Godot_v4.7.2-stable_win64_console.exe"
```

Ожидается `with-sdk: PASS`, `no-sdk: PASS`, `host: PASS`, `client: PASS`.

- [ ] **Обновить документацию**

В `README.md` в разделе про мультиплеер заменить обещание про офлайн на факт: без SDK доступен только офлайн-режим, сеть в меню недоступна и об этом написано в статусе. Добавить в раздел «Совместная работа» строку про новый раннер:

```markdown
- Перед пушем стоит прогнать `./tools/run_offline_tests.ps1 -Godot <путь>` — он
  проверяет и сборку без Photon SDK, то есть офлайн-режим у того, кто SDK ещё
  не поставил.
```

В `docs/network.md` в раздел «Границы реализации» добавить, что именно теперь проверяется на стороне жертвы (потолок урона по каталогу, дистанция, прямая видимость, бюджет пакетов) и что этого всё равно недостаточно против правленого хоста: раздача точек оружия и счёт остаются на доверии.

- [ ] **Коммит документации**

```bash
git add README.md docs/network.md
```

```bash
git commit -m "Описать офлайн-прогон и границы проверок урона" -m "Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

# Не вошло намеренно

| Что | Почему |
| --- | --- |
| Счёт, здоровье и `display_name` остаются на доверии клиента | Shared Authority без выделенного сервера: клиент авторитетен по своему бойцу по определению. Чинится только переездом на серверный режим Fusion — это отдельный проект, а не правка. |
| Хост бесконтрольно раздаёт точки оружия | То же самое: мастер-клиент — обычный игрок. Дистанцию и время восстановления он проверяет, но проверяет сам себя. |
| Поворот оружия чужого бойца по кости кисти (`net_player._update_remote` тянет только позицию) | Косметика, требует подгонки глазами в редакторе — в headless не проверяется, в план с готовым кодом не укладывается. |
| Расхождение длины ствола бота (`0.66` вместо `0.62` в smoke-тесте) | Это длина диагонали AABB против длины ствола из каталога, то есть расхождение самой проверки, а не модели. Отдельной задачей — поправить формулу в `smoke_test.gd`. |
| Магазин обрабатывает только цифры 1–9 (`hud.gd`, `digit >= 0 and digit <= 8`) | Сейчас в магазине семь строк, дефекта нет. Когда появится десятый покупаемый ствол, строки с десятой станут недоступны молча — тогда и переводить магазин на прокрутку или на два столбца. |
| Разброс бота не ограничивает хедшоты | Замер: 2 попадания за 20 с, но одно из них — 179 hp (Deagle в голову), то есть смерть с одного выстрела на любой дистанции. Это баланс, а не дефект: решать после того, как заработает всё остальное. |
