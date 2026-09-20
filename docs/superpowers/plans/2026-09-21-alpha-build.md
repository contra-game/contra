# Альфа-билд Contra City — план реализации

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** собрать `.exe`, в который двое заходят через меню с лобби, видят друг друга моделями бойцов и держат стволы нормальными руками.

**Architecture:** сетевая сессия переезжает в autoload `Session`, который живёт дольше сцены и разводит два этапа — «подключились и сидим в лобби» и «спавним бойцов в матче». Меню и лобби — обычные `Control`-сцены поверх этой сессии. Руки и тело бойца берутся из уже лежащего в репозитории `characterMedium.fbx`.

**Tech Stack:** Godot 4.7.2, GDScript, Photon Fusion Godot SDK 3.0.0 Preview Build 555 (GDExtension).

**Спека:** `docs/superpowers/specs/2026-09-21-alpha-build-design.md`

**Запуск редактора и проверок — только через 4.7.2:**

```bash
"/c/Users/admin/Desktop/Godot_v4.7.2-stable_win64.exe" --headless --path . res://tools/smoke_test.tscn
```

---

## Файловая структура

| Файл | Ответственность |
| --- | --- |
| `scripts/session.gd` (создать) | autoload `Session`: имя, комната, состояние лобби, переходы между сценами |
| `scripts/net_manager.gd` (переписать) | только Photon: подключение, комната, спавн бойцов; без знания о сценах |
| `scripts/menu.gd` + `scenes/menu.tscn` (создать) | главное меню, ввод имени и комнаты, сохранение настроек |
| `scripts/lobby.gd` + `scenes/lobby.tscn` (создать) | список игроков, кнопка старта у хоста |
| `scripts/first_person_arms.gd` (создать) | вырезает меш рук из модели бойца по весам костей |
| `scripts/view_model.gd` (правка) | удалить `attach_hands` с примитивами |
| `scripts/weapon_manager.gd` (правка) | вешать новые руки вместо примитивов |
| `scripts/game.gd` (правка) | берёт готовую сессию, не поднимает сеть сам; seed приходит извне |
| `scenes/player.tscn` (правка) | модель бойца вместо `CapsuleMesh` |
| `scripts/player.gd` (правка) | собрать модель, гонять idle/run по скорости |
| `scripts/hud.gd` (правка) | в паузе кнопка «Выйти в меню» |
| `tools/lobby_test.gd` + `tools/lobby_test.tscn` (создать) | headless-проверка сессии и лобби |
| `export_presets.cfg` (создать) | пресет Windows Desktop, debug |

---

## Task 1: Сессия, которая переживает смену сцен

**Files:**
- Create: `scripts/session.gd`
- Modify: `scripts/net_manager.gd` (целиком), `project.godot` (autoload), `scripts/game.gd:33-57`
- Test: `tools/lobby_test.gd`, `tools/lobby_test.tscn`

- [ ] **Step 1: Написать падающую проверку**

`tools/lobby_test.gd`:

```gdscript
## Проверка сессии без редактора: подключение, комната, список игроков.
extends Node

func _ready() -> void:
	print("--- LOBBY TEST ---")
	print("blocker: '%s'" % NetConfig.blocker())
	Session.player_name = "TestBot"
	Session.room_name = "contra-test"
	Session.state_text.connect(func(t: String) -> void: print("  ", t))
	var ok := await Session.connect_and_join()
	print("вошли в комнату: %s" % str(ok))
	print("игроков в лобби: %d" % Session.players().size())
	for p in Session.players():
		print("  %s (id=%d, хост=%s)" % [p.name, p.id, str(p.is_host)])
	print("я хост: %s" % str(Session.is_host()))
	Session.leave()
	print("--- END ---")
	get_tree().quit()
```

`tools/lobby_test.tscn`:

```
[gd_scene load_steps=2 format=3]
[ext_resource type="Script" path="res://tools/lobby_test.gd" id="1"]
[node name="LobbyTest" type="Node"]
script = ExtResource("1")
```

- [ ] **Step 2: Убедиться, что проверка падает**

Run: `"/c/Users/admin/Desktop/Godot_v4.7.2-stable_win64.exe" --headless --path . res://tools/lobby_test.tscn`
Expected: FAIL — `Identifier "Session" not declared in the current scope`.

- [ ] **Step 3: Переписать `net_manager.gd` — развести подключение и спавн**

Сейчас `start()` делает всё сразу и требует `spawn_root`, которого в лобби ещё нет. Разводим на два этапа:

```gdscript
## Сетевая сессия на Photon Fusion (Shared Authority).
##
## Два этапа: connect_and_join() поднимает соединение и заводит комнату — этого
## хватает лобби; begin_match() создаёт спавнер и выпускает бойца в матч.
class_name NetManager
extends Node

signal session_state(text: String)
signal lobby_changed()
signal local_player_spawned(player: Node)
signal remote_player_spawned(player: Node)
signal joined(success: bool)

const APP_VERSION := "0.2"
const PLAYER_SCENE := preload("res://scenes/net_player.tscn")

var spawner: FusionSpawner
var connected: bool = false

var _local_player: Node = null
var _signals_bound: bool = false

## Подключается к Photon и входит в комнату. Результат приходит в joined.
func connect_and_join(user_id: String, room_name: String, max_players: int) -> bool:
	var blocker := NetConfig.blocker()
	if blocker != "":
		session_state.emit("офлайн: %s" % blocker)
		return false

	_bind_signals()
	_room_name = room_name
	_max_players = max_players
	session_state.emit("подключение к Photon (%s)…" % NetConfig.region())
	Fusion.set_app_id(NetConfig.app_id())
	Fusion.connect_to_photon(user_id, NetConfig.region(), APP_VERSION)
	return true

## Спавнер живёт только в матче: в лобби спавнить некуда.
func begin_match(spawn_root: Node3D) -> void:
	spawner = FusionSpawner.new()
	spawner.name = "FusionSpawner"
	spawner.add_spawnable_scene(PLAYER_SCENE)
	spawner.set_spawn_path(spawn_root.get_path())
	spawner.spawned.connect(_on_spawned)
	add_child(spawner)
	await get_tree().process_frame
	spawner.spawn(PLAYER_SCENE, Callable())

func players() -> Array:
	var room := Fusion.get_room()
	if room == null:
		return []
	return room.get_players()

func is_host() -> bool:
	return Fusion.is_master_client()

func leave() -> void:
	if Fusion.is_in_room():
		Fusion.leave_room()

func stop() -> void:
	leave()
	if Fusion.is_connected_to_photon():
		Fusion.disconnect_from_photon()

func is_online() -> bool:
	return connected and Fusion.is_in_room()
```

Приватная часть — подписки и обработчики; `_bind_signals()` защищает от повторной подписки при возврате в меню и новом входе:

```gdscript
var _room_name: String = "contra-city"
var _max_players: int = 8

func _bind_signals() -> void:
	if _signals_bound:
		return
	_signals_bound = true
	Fusion.connected_to_photon.connect(_on_connected)
	Fusion.connection_failed.connect(_on_connection_failed)
	Fusion.room_joined.connect(_on_room_joined)
	Fusion.room_left.connect(_on_room_left)
	Fusion.player_joined.connect(_on_player_joined)
	Fusion.player_left.connect(_on_player_left)
	Fusion.master_client_changed.connect(_on_master_changed)

func _on_connected() -> void:
	session_state.emit("подключено, вход в комнату «%s»…" % _room_name)
	var options := FusionRoomOptions.new()
	options.set_max_players(_max_players)
	options.set_is_open(true)
	options.set_is_visible(true)
	Fusion.join_or_create_room(_room_name, options)

func _on_connection_failed(error) -> void:
	connected = false
	session_state.emit("Photon недоступен (%s)" % str(error))
	joined.emit(false)

func _on_room_joined() -> void:
	connected = true
	session_state.emit("в комнате «%s»" % _room_name)
	joined.emit(true)
	lobby_changed.emit()

func _on_room_left() -> void:
	connected = false
	session_state.emit("вышли из комнаты")
	lobby_changed.emit()

func _on_player_joined(player_id: int, _user_id: String) -> void:
	session_state.emit("игрок %d подключился" % player_id)
	lobby_changed.emit()

func _on_player_left(player_id: int, _is_inactive: bool) -> void:
	session_state.emit("игрок %d вышел" % player_id)
	lobby_changed.emit()

func _on_master_changed(_id: int) -> void:
	lobby_changed.emit()

func _on_spawned(node: Node) -> void:
	var replicator: FusionReplicator = node.get_node_or_null("Replicator")
	var mine: bool = replicator != null and replicator.has_authority()
	if mine:
		_local_player = node
		local_player_spawned.emit(node)
	else:
		remote_player_spawned.emit(node)
```

- [ ] **Step 4: Написать `scripts/session.gd`**

```gdscript
## Игровая сессия: живёт дольше сцены и связывает меню, лобби и матч.
##
## Сеть поднимается один раз в меню и держится до выхода, поэтому NetManager
## висит здесь, а не внутри матча, как было раньше.
extends Node

signal state_text(text: String)
signal lobby_changed()

const MENU_SCENE := "res://scenes/menu.tscn"
const LOBBY_SCENE := "res://scenes/lobby.tscn"
const MATCH_SCENE := "res://scenes/main.tscn"
const SETTINGS_PATH := "user://settings.cfg"

class LobbyPlayer:
	var id: int
	var name: String
	var is_host: bool

var player_name: String = "Игрок"
var room_name: String = "contra-city"
var online: bool = false
var match_seed: int = 0

var net: NetManager

func _ready() -> void:
	load_settings()
	net = NetManager.new()
	net.name = "NetManager"
	add_child(net)
	net.session_state.connect(func(t: String) -> void: state_text.emit(t))
	net.lobby_changed.connect(func() -> void: lobby_changed.emit())
	Fusion.register_broadcast_receiver(self)

## Уникальный идентификатор для Photon: имя плюс хвост, чтобы не столкнуться.
func user_id() -> String:
	return "%s#%04d" % [player_name, randi() % 10000]

func connect_and_join() -> bool:
	if not net.connect_and_join(user_id(), room_name, 8):
		return false
	return await net.joined

func leave() -> void:
	net.leave()

func players() -> Array:
	var out: Array = []
	for p in net.players():
		var lp := LobbyPlayer.new()
		lp.id = p.get_number()
		lp.name = p.get_user_id().split("#")[0]
		lp.is_host = p.get_is_master_client()
		out.append(lp)
	return out

func is_host() -> bool:
	return net.is_host()

## Хост рассылает старт, чтобы карта у всех собралась из одного seed.
func start_match() -> void:
	var seed_value := randi()
	Fusion.rpc(Callable(self, "_remote_start").bind(seed_value))
	_remote_start(seed_value)

func _remote_start(seed_value: int) -> void:
	if match_seed == seed_value:
		return
	match_seed = seed_value
	online = true
	get_tree().change_scene_to_file(MATCH_SCENE)

func start_offline() -> void:
	online = false
	match_seed = randi()
	get_tree().change_scene_to_file(MATCH_SCENE)

func to_menu() -> void:
	online = false
	match_seed = 0
	leave()
	get_tree().change_scene_to_file(MENU_SCENE)

func save_settings() -> void:
	var config := ConfigFile.new()
	config.set_value("player", "name", player_name)
	config.set_value("player", "room", room_name)
	config.save(SETTINGS_PATH)

func load_settings() -> void:
	var config := ConfigFile.new()
	if config.load(SETTINGS_PATH) != OK:
		return
	player_name = str(config.get_value("player", "name", player_name))
	room_name = str(config.get_value("player", "room", room_name))
```

- [ ] **Step 5: Зарегистрировать autoload**

В `project.godot`, секция `[autoload]`, третьей строкой после `Sfx`:

```
Session="*res://scripts/session.gd"
```

- [ ] **Step 6: Прогнать проверку**

Run: `"/c/Users/admin/Desktop/Godot_v4.7.2-stable_win64.exe" --headless --path . res://tools/lobby_test.tscn`
Expected: PASS — `вошли в комнату: true`, `игроков в лобби: 1`, `я хост: true`.

- [ ] **Step 7: Развязать `game.gd` от поднятия сети**

Заменить `_ready` и `_start_network` (`scripts/game.gd:33-57`):

```gdscript
func _ready() -> void:
	online = Session.online
	match_seed = Session.match_seed if Session.match_seed != 0 else match_seed
	_rng.seed = match_seed
	map.build(match_seed)
	_spawn_pickups()

	if online and Session.net.is_online():
		net = Session.net
		net.local_player_spawned.connect(_on_local_player_spawned)
		net.session_state.connect(func(text: String) -> void: killfeed.emit(text))
		await net.begin_match(actors)
		_spawn_bots(online_bot_count)
		return

	_spawn_player()
	_spawn_bots(bot_count)
```

- [ ] **Step 8: Убедиться, что офлайн-матч цел**

Run: `"/c/Users/admin/Desktop/Godot_v4.7.2-stable_win64.exe" --headless --path . res://tools/smoke_test.tscn`
Expected: PASS — строка `урон: бот 100 -> 60`, боты живы, ошибок парсинга нет.

---

## Task 2: Главное меню

**Files:**
- Create: `scenes/menu.tscn`, `scripts/menu.gd`
- Modify: `project.godot` (`run/main_scene`)

- [ ] **Step 1: Написать `scripts/menu.gd`**

```gdscript
## Главное меню: имя, комната, выбор сетевого или офлайн-матча.
extends Control

@onready var name_edit: LineEdit = $Panel/Rows/NameRow/NameEdit
@onready var room_edit: LineEdit = $Panel/Rows/RoomRow/RoomEdit
@onready var online_button: Button = $Panel/Rows/OnlineButton
@onready var status: Label = $Panel/Rows/Status

func _ready() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	name_edit.text = Session.player_name
	room_edit.text = Session.room_name
	Session.state_text.connect(_on_state)
	online_button.pressed.connect(_on_online)
	$Panel/Rows/OfflineButton.pressed.connect(_on_offline)
	$Panel/Rows/QuitButton.pressed.connect(func() -> void: get_tree().quit())
	var blocker := NetConfig.blocker()
	status.text = "сеть не готова: %s" % blocker if blocker != "" else "готов к бою"

func _on_state(text: String) -> void:
	status.text = text

func _on_online() -> void:
	_remember()
	online_button.disabled = true
	var ok: bool = await Session.connect_and_join()
	online_button.disabled = false
	if ok:
		get_tree().change_scene_to_file(Session.LOBBY_SCENE)

func _on_offline() -> void:
	_remember()
	Session.start_offline()

func _remember() -> void:
	Session.player_name = name_edit.text.strip_edges()
	Session.room_name = room_edit.text.strip_edges()
	if Session.player_name == "":
		Session.player_name = "Игрок"
	if Session.room_name == "":
		Session.room_name = "contra-city"
	Session.save_settings()
```

- [ ] **Step 2: Собрать `scenes/menu.tscn`**

Дерево: `Menu` (Control, anchors full rect) → `Panel` (PanelContainer, центр) → `Rows` (VBoxContainer) → `Title` (Label «CONTRA CITY»), `NameRow` (HBoxContainer: Label «Имя» + `NameEdit` LineEdit), `RoomRow` (HBoxContainer: Label «Комната» + `RoomEdit` LineEdit), `OnlineButton` («Играть по сети»), `OfflineButton` («Офлайн с ботами»), `QuitButton` («Выход»), `Status` (Label). Скрипт `menu.gd` на корне.

- [ ] **Step 3: Сделать меню стартовой сценой**

В `project.godot`: `run/main_scene="res://scenes/menu.tscn"`.

- [ ] **Step 4: Проверить запуск**

Run: `"/c/Users/admin/Desktop/Godot_v4.7.2-stable_win64.exe" --path . --quit-after 120`
Expected: открывается меню, в консоли нет ошибок скриптов.

---

## Task 3: Лобби и старт матча

**Files:**
- Create: `scenes/lobby.tscn`, `scripts/lobby.gd`
- Modify: `tools/lobby_test.gd` (проверка RPC старта)

- [ ] **Step 1: Написать `scripts/lobby.gd`**

```gdscript
## Лобби: кто в комнате и кнопка старта у хоста.
extends Control

@onready var list: VBoxContainer = $Panel/Rows/Players
@onready var start_button: Button = $Panel/Rows/StartButton
@onready var status: Label = $Panel/Rows/Status

func _ready() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	$Panel/Rows/Title.text = "Комната «%s»" % Session.room_name
	start_button.pressed.connect(func() -> void: Session.start_match())
	$Panel/Rows/LeaveButton.pressed.connect(func() -> void: Session.to_menu())
	Session.lobby_changed.connect(_refresh)
	Session.state_text.connect(func(t: String) -> void: status.text = t)
	_refresh()

func _refresh() -> void:
	for child in list.get_children():
		child.queue_free()
	for player in Session.players():
		var row := Label.new()
		row.text = "%s%s" % [player.name, "   — хост" if player.is_host else ""]
		list.add_child(row)
	start_button.disabled = not Session.is_host()
	start_button.text = "НАЧАТЬ МАТЧ" if Session.is_host() else "Ждём хоста…"
```

- [ ] **Step 2: Собрать `scenes/lobby.tscn`**

Дерево: `Lobby` (Control) → `Panel` (PanelContainer) → `Rows` (VBoxContainer) → `Title` (Label), `Players` (VBoxContainer), `StartButton`, `LeaveButton` («Выйти из комнаты»), `Status` (Label). Скрипт `lobby.gd` на корне.

- [ ] **Step 3: Проверить, что broadcast RPC доходит**

Дописать в конец `tools/lobby_test.gd` перед `get_tree().quit()`:

```gdscript
	# Старт рассылается через Fusion.rpc; в одиночной комнате проверяем, что
	# вызов проходит и сцена матча получает seed.
	Session.match_seed = 0
	Session.start_match()
	print("seed после старта: %d (ненулевой = RPC отработал)" % Session.match_seed)
```

Run: `"/c/Users/admin/Desktop/Godot_v4.7.2-stable_win64.exe" --headless --path . res://tools/lobby_test.tscn`
Expected: `seed после старта:` с ненулевым числом.

- [ ] **Step 4: Если RPC не доходит — фолбэк на свойство комнаты**

Симптом: у второго клиента матч не стартует, `_remote_start` не вызывается. Тогда в `session.gd` заменить рассылку на свойство комнаты и опрос:

```gdscript
func start_match() -> void:
	var seed_value := randi()
	var room := Fusion.get_room()
	if room != null:
		room.set_property("seed", seed_value)
	_remote_start(seed_value)

## Клиенты опрашивают комнату, пока сидят в лобби: сигнала на смену свойств
## комнаты в SDK нет.
func _process(_delta: float) -> void:
	if match_seed != 0 or not net.is_online():
		return
	var room := Fusion.get_room()
	if room == null:
		return
	var props := room.get_custom_properties()
	if props.has("seed"):
		_remote_start(int(props["seed"]))
```

- [ ] **Step 5: Проверить вдвоём на одной машине**

Запустить два экземпляра: `--path .` дважды, войти в одну комнату, нажать старт у хоста.
Expected: оба оказываются в матче, в киллфиде обоих видно второго игрока.

---

## Task 4: Выход в меню из паузы

**Files:**
- Modify: `scripts/hud.gd`, `scripts/game.gd`

- [ ] **Step 1: Добавить кнопку в паузу**

В `hud.gd`, там где собирается меню паузы, добавить кнопку «Выйти в меню»:

```gdscript
var to_menu := Button.new()
to_menu.text = "Выйти в меню"
to_menu.pressed.connect(func() -> void:
	get_tree().paused = false
	Session.to_menu())
pause_menu.add_child(to_menu)
```

- [ ] **Step 2: Проверить**

Run: `"/c/Users/admin/Desktop/Godot_v4.7.2-stable_win64.exe" --path .`
Expected: в матче Esc открывает паузу, «Выйти в меню» возвращает в меню, оттуда можно зайти снова.

---

## Task 5: Руки из модели бойца

**Files:**
- Create: `scripts/first_person_arms.gd`
- Modify: `scripts/view_model.gd` (удалить `attach_hands`), `scripts/weapon_manager.gd:375`

- [ ] **Step 1: Написать `scripts/first_person_arms.gd`**

```gdscript
## Руки от первого лица из модели бойца.
##
## В паке Kenney персонаж — один меш с одной поверхностью, отдельных объектов
## головы и ног нет. Поэтому руки вырезаются по весам костей: вершина едет в
## новый меш, если больше половины её веса приходится на кости рук.
class_name FirstPersonArms
extends RefCounted

const MODEL := "res://assets/characters/Model/characterMedium.fbx"
const ARM_BONES := ["LeftShoulder", "LeftArm", "LeftForeArm", "LeftHand",
	"RightShoulder", "RightArm", "RightForeArm", "RightHand"]
const WEIGHT_CUTOFF := 0.5

## Возвращает узел с руками: Skeleton3D с обрезанным мешом, готовый к позированию.
static func build() -> Node3D:
	var model: Node3D = load(MODEL).instantiate()
	var skeleton: Skeleton3D = model.find_child("Skeleton3D", true, false)
	var mesh_instance: MeshInstance3D = skeleton.find_child("characterMedium", true, false)
	var arms := _filter_mesh(mesh_instance.mesh, skeleton)
	if arms == null:
		return null
	mesh_instance.mesh = arms
	return model

## Оставляет только те треугольники, все три вершины которых принадлежат рукам.
static func _filter_mesh(source: Mesh, skeleton: Skeleton3D) -> ArrayMesh:
	var arrays: Array = source.surface_get_arrays(0)
	var bones: PackedInt32Array = arrays[Mesh.ARRAY_BONES]
	var weights: PackedFloat32Array = arrays[Mesh.ARRAY_WEIGHTS]
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	var vertex_count: int = (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
	if vertex_count == 0 or bones.is_empty():
		return null

	var per_vertex: int = bones.size() / vertex_count
	var arm_ids := {}
	for name in ARM_BONES:
		var idx := skeleton.find_bone(name)
		if idx >= 0:
			arm_ids[idx] = true
	# Пальцы тоже наши: у них имена вида RightHandIndex1.
	for i in skeleton.get_bone_count():
		var bone_name := skeleton.get_bone_name(i)
		if bone_name.contains("Hand"):
			arm_ids[i] = true

	var keep := PackedByteArray()
	keep.resize(vertex_count)
	for v in vertex_count:
		var sum := 0.0
		for k in per_vertex:
			if arm_ids.has(bones[v * per_vertex + k]):
				sum += weights[v * per_vertex + k]
		keep[v] = 1 if sum > WEIGHT_CUTOFF else 0

	var remap := {}
	var out := _empty_arrays(arrays)
	for v in vertex_count:
		if keep[v] == 0:
			continue
		remap[v] = _copy_vertex(arrays, out, v, per_vertex)

	var out_indices := PackedInt32Array()
	for t in range(0, indices.size(), 3):
		var a: int = indices[t]
		var b: int = indices[t + 1]
		var c: int = indices[t + 2]
		if remap.has(a) and remap.has(b) and remap.has(c):
			out_indices.append_array([remap[a], remap[b], remap[c]])
	out[Mesh.ARRAY_INDEX] = out_indices

	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, out)
	mesh.surface_set_material(0, source.surface_get_material(0))
	return mesh
```

Вспомогательные методы копируют вершину со всеми её атрибутами:

```gdscript
static func _empty_arrays(source: Array) -> Array:
	var out: Array = []
	out.resize(Mesh.ARRAY_MAX)
	out[Mesh.ARRAY_VERTEX] = PackedVector3Array()
	out[Mesh.ARRAY_NORMAL] = PackedVector3Array()
	out[Mesh.ARRAY_TEX_UV] = PackedVector2Array()
	out[Mesh.ARRAY_BONES] = PackedInt32Array()
	out[Mesh.ARRAY_WEIGHTS] = PackedFloat32Array()
	if source[Mesh.ARRAY_COLOR] != null:
		out[Mesh.ARRAY_COLOR] = PackedColorArray()
	return out

## Возвращает новый индекс вершины.
static func _copy_vertex(source: Array, out: Array, v: int, per_vertex: int) -> int:
	out[Mesh.ARRAY_VERTEX].append(source[Mesh.ARRAY_VERTEX][v])
	if source[Mesh.ARRAY_NORMAL] != null:
		out[Mesh.ARRAY_NORMAL].append(source[Mesh.ARRAY_NORMAL][v])
	if source[Mesh.ARRAY_TEX_UV] != null:
		out[Mesh.ARRAY_TEX_UV].append(source[Mesh.ARRAY_TEX_UV][v])
	if source[Mesh.ARRAY_COLOR] != null:
		out[Mesh.ARRAY_COLOR].append(source[Mesh.ARRAY_COLOR][v])
	for k in per_vertex:
		out[Mesh.ARRAY_BONES].append(source[Mesh.ARRAY_BONES][v * per_vertex + k])
		out[Mesh.ARRAY_WEIGHTS].append(source[Mesh.ARRAY_WEIGHTS][v * per_vertex + k])
	return out[Mesh.ARRAY_VERTEX].size() - 1
```

- [ ] **Step 2: Проверить, что меш вырезался**

Временная сцена `tools/arms_test.tscn` со скриптом, печатающим размеры:

```gdscript
extends Node
func _ready() -> void:
	var arms := FirstPersonArms.build()
	var mi: MeshInstance3D = arms.find_child("characterMedium", true, false)
	var aabb := mi.mesh.get_aabb()
	print("рук: поверхностей=%d, размер=%.2f x %.2f x %.2f" % [
		mi.mesh.get_surface_count(), aabb.size.x, aabb.size.y, aabb.size.z])
	get_tree().quit()
```

Run: `"/c/Users/admin/Desktop/Godot_v4.7.2-stable_win64.exe" --headless --path . res://tools/arms_test.tscn`
Expected: одна поверхность, высота заметно меньше роста бойца (руки, а не весь человек).

- [ ] **Step 3: Повесить руки вместо примитивов**

В `weapon_manager.gd:375` заменить `ViewModel.attach_hands(_view_model, data)` на постановку рук из `FirstPersonArms.build()` в `_view_model`, с позой: развернуть модель к камере и подвести кисти к рукояти через повороты костей `RightHand` и `LeftHand`.

- [ ] **Step 4: Удалить примитивы**

Вырезать `ViewModel.attach_hands` и вспомогательные методы построения капсул из `scripts/view_model.gd`.

- [ ] **Step 5: Снять кадр и подогнать позу**

Run: `"/c/Users/admin/Desktop/Godot_v4.7.2-stable_win64.exe" --path . res://tools/screenshot.tscn`
Expected: в `tools/shot_player.png` руки держат ствол, голова и ноги в кадр не лезут. Подгонять повороты костей, пока кадр не станет правильным.

---

## Task 6: Модель бойца вместо капсулы

**Files:**
- Modify: `scenes/player.tscn:26-28`, `scripts/player.gd:68-69`

- [ ] **Step 1: Заменить меш на модель**

В `player.gd`, в `_ready`, вместо показа капсулы собирать модель тем же кодом, что и у ботов:

```gdscript
	# Своё тело игрок не видит, но напарник по сети должен видеть бойца,
	# а не капсулу. Модель та же, что у ботов.
	if CharacterModel.available():
		var model := CharacterModel.build("survivorMaleA", 1.8)
		body_mesh.queue_free()
		add_child(model)
		body_mesh = model
	body_mesh.visible = not local_control
```

- [ ] **Step 2: Гонять анимацию по скорости**

В `_physics_process`, после расчёта скорости:

```gdscript
	if not local_control and _animation != null:
		var speed := Vector2(velocity.x, velocity.z).length()
		var want := "run" if speed > 0.6 else "idle"
		if _animation.current_animation != want:
			_animation.play(want)
```

- [ ] **Step 3: Проверить, что смоук цел**

Run: `"/c/Users/admin/Desktop/Godot_v4.7.2-stable_win64.exe" --headless --path . res://tools/smoke_test.tscn`
Expected: PASS, урон и боты как раньше.

- [ ] **Step 4: Проверить вид чужого игрока**

Запустить два экземпляра, зайти в одну комнату, посмотреть друг на друга.
Expected: вместо белой капсулы — боец со стволом.

---

## Task 7: Сборка альфа-билда

**Files:**
- Create: `export_presets.cfg`, `build/README.txt`
- Modify: `.gitignore`

- [ ] **Step 1: Скачать шаблоны экспорта**

```bash
curl -sL -o "$SCRATCH/templates.tpz" "https://github.com/godotengine/godot/releases/download/4.7.2-stable/Godot_v4.7.2-stable_export_templates.tpz"
```

Сверить SHA-512 с `SHA512-SUMS.txt` того же релиза, распаковать в
`%APPDATA%\Godot\export_templates\4.7.2.stable\`.

- [ ] **Step 2: Создать пресет**

`export_presets.cfg`: платформа `Windows Desktop`, `export_path="build/contra.exe"`,
`include_filter="photon.cfg"`, `binary_format/embed_pck=false`, консоль включена.

- [ ] **Step 3: Экспортировать**

```bash
"/c/Users/admin/Desktop/Godot_v4.7.2-stable_win64.exe" --headless --path . --export-debug "Windows Desktop" build/contra.exe
```

Expected: в `build/` появляются `contra.exe`, `contra.pck`,
`libfusion.windows.template_debug.x86_64.release.dll`.

- [ ] **Step 4: Проверить, что App ID уехал в билд**

```bash
strings build/contra.pck | grep -c "69ed4093"
```

Expected: не ноль — иначе `photon.cfg` не попал в пакет и билд уйдёт в офлайн.

- [ ] **Step 5: Запустить билд и войти в комнату**

Запустить `build/contra.exe` дважды, в обоих меню ввести одну комнату, у хоста нажать старт.
Expected: оба в матче, видят друг друга.

- [ ] **Step 6: Собрать архив**

```bash
cd build && zip -r contra-alpha-debug.zip contra.exe contra.pck *.dll README.txt
```

- [ ] **Step 7: Закрыть от git**

В `.gitignore` добавить `build/` и `export_presets.cfg`.

---

## Порядок и зависимости

Task 1 — фундамент, без него меню и лобби некуда вешать. Task 2 и 3 идут следом и проверяются вместе. Task 4 короткий, закрывает возврат в меню. Task 5 и 6 не зависят от сети и могут идти в любой момент после Task 1. Task 7 — последний, ему нужно всё остальное.
