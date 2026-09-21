## Независимый depth buffer оружия, общие мировые координаты и проекция.
## Мир не может перекрыть руки; мировой трассер совпадает с маркером дула.
extends Node

const MASK := 1 << 19
var source: Camera3D
var viewport: SubViewport
var camera: Camera3D
var overlay: CanvasLayer
var image: TextureRect

func setup(world_camera: Camera3D) -> void:
	source = world_camera
	source.cull_mask &= ~MASK
	viewport = SubViewport.new()
	viewport.name = "WeaponViewport"
	viewport.transparent_bg = true
	viewport.world_3d = source.get_world_3d()
	viewport.handle_input_locally = false
	viewport.gui_disable_input = true
	viewport.msaa_3d = Viewport.MSAA_2X
	add_child(viewport)
	camera = Camera3D.new()
	camera.cull_mask = MASK
	camera.near = 0.015
	camera.far = 20.0
	var environment := Environment.new()
	environment.background_mode = Environment.BG_CLEAR_COLOR
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color(0.85, 0.9, 1.0)
	environment.ambient_light_energy = 0.7
	camera.environment = environment
	viewport.add_child(camera)
	camera.make_current()
	# Свет оружия находится на том же слое; свет мира слой 20 может не видеть.
	var key := DirectionalLight3D.new()
	key.layers = MASK
	key.light_cull_mask = MASK
	key.light_energy = 1.4
	key.rotation_degrees = Vector3(-28, -35, 0)
	camera.add_child(key)
	var fill := DirectionalLight3D.new()
	fill.layers = MASK
	fill.light_cull_mask = MASK
	fill.light_color = Color(0.7, 0.8, 1.0)
	fill.light_energy = 0.5
	fill.rotation_degrees = Vector3(20, 140, 0)
	camera.add_child(fill)
	overlay = CanvasLayer.new()
	overlay.layer = 1 # Мир < оружие < HUD и меню.
	add_child(overlay)
	image = TextureRect.new()
	image.mouse_filter = Control.MOUSE_FILTER_IGNORE
	image.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	image.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	image.texture = viewport.get_texture()
	overlay.add_child(image)
	sync(false)

func sync(enabled: bool) -> void:
	var active := enabled and source.is_current()
	overlay.visible = active
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS if active else SubViewport.UPDATE_DISABLED
	var screen := Vector2i(source.get_viewport().get_visible_rect().size)
	if screen.x > 0 and screen.y > 0 and viewport.size != screen:
		viewport.size = screen
	# FOV совпадает намеренно: иной FOV потребовал бы перепроекции трассера.
	camera.global_transform = source.global_transform
	camera.fov = source.fov
	camera.keep_aspect = source.keep_aspect
	camera.h_offset = source.h_offset
	camera.v_offset = source.v_offset

static func tag(root: Node) -> void:
	if root is VisualInstance3D:
		root.layers = MASK
	if root is Light3D:
		root.light_cull_mask = MASK
	for child in root.get_children():
		tag(child)
