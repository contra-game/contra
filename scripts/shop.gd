## Магазин оружия: открывается на B, покупка по цифрам.
##
## Игра при этом не встаёт на паузу и мышь остаётся захваченной — в аркадном
## шутере закупаться приходится на бегу. Пока магазин открыт, цифровые клавиши
## тратятся на покупку, а не на смену оружия (см. PlayerCharacter.shop_open).
class_name Shop
extends PanelContainer

signal purchased(weapon_id: StringName)

const ROW_HEIGHT := 30

var player: PlayerCharacter
var economy: Economy

var _rows: Array = []          # [{id, price, label, is_armor}]
var _money_label: Label
var _list: VBoxContainer

func _ready() -> void:
	custom_minimum_size = Vector2(380, 0)
	set_anchors_preset(Control.PRESET_TOP_LEFT)
	position = Vector2(40, 120)
	visible = false
	process_mode = Node.PROCESS_MODE_ALWAYS

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	add_child(box)

	var title := _label("ЗАКУПКА", 24, Color(0.96, 0.78, 0.25))
	box.add_child(title)

	_money_label = _label("$0", 20, Color(0.55, 0.85, 0.5))
	box.add_child(_money_label)

	_list = VBoxContainer.new()
	_list.add_theme_constant_override("separation", 2)
	box.add_child(_list)

	box.add_child(_label("B — закрыть, цифра — купить", 13, Color(0.7, 0.72, 0.76)))

func bind(player_node: PlayerCharacter, economy_node: Economy) -> void:
	player = player_node
	economy = economy_node
	economy.money_changed.connect(_on_money_changed)
	_build_rows()
	_refresh()

func toggle() -> void:
	visible = not visible
	if player != null:
		player.shop_open = visible
	if visible:
		_refresh()

func close() -> void:
	if not visible:
		return
	visible = false
	if player != null:
		player.shop_open = false

## Возвращает true, если цифра ушла в покупку и не должна менять оружие.
func handle_digit(index: int) -> bool:
	if not visible or index < 0 or index >= _rows.size():
		return false
	_buy(_rows[index])
	return true

func _build_rows() -> void:
	_rows.clear()
	for id in Weapons.ids():
		var data: WeaponData = Weapons.get_weapon(id)
		if data.price <= 0:
			continue
		_rows.append({"id": data.id, "price": data.price, "name": data.display_name, "armor": false})
	_rows.append({"id": &"armor", "price": Economy.ARMOR_PRICE, "name": "Броня +50", "armor": true})

	for child in _list.get_children():
		child.queue_free()
	for i in _rows.size():
		var row: Dictionary = _rows[i]
		var label := _label("%d. %s — $%d" % [i + 1, row.name, row.price], 17, Color(0.88, 0.9, 0.93))
		label.custom_minimum_size.y = ROW_HEIGHT
		_list.add_child(label)
		row["label"] = label

func _buy(row: Dictionary) -> void:
	if economy == null or player == null:
		return
	if not economy.can_afford(row.price):
		Sfx.play_2d(&"empty", 0.8, -2.0)
		return

	var bought := false
	if row.armor:
		if player.health.armor < player.health.max_armor:
			player.health.add_armor(Economy.ARMOR_AMOUNT)
			bought = true
	else:
		bought = player.weapons.give(row.id, true)

	if not bought:
		Sfx.play_2d(&"empty", 0.8, -2.0)
		return
	economy.spend(row.price)
	Sfx.play_2d(&"pickup", 1.0, -2.0)
	purchased.emit(row.id)
	_refresh()

func _on_money_changed(_amount: int) -> void:
	_refresh()

func _refresh() -> void:
	if economy == null:
		return
	_money_label.text = "$%d" % economy.money
	for row in _rows:
		var label: Label = row.get("label")
		if label == null:
			continue
		var affordable: bool = economy.can_afford(row.price)
		label.add_theme_color_override("font_color",
			Color(0.88, 0.9, 0.93) if affordable else Color(0.55, 0.45, 0.45))

func _label(text: String, size: int, color: Color) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", size)
	label.add_theme_color_override("font_color", color)
	return label
