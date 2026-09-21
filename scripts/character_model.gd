## Модель бойца для ботов и чужих игроков.
##
## Kenney раздаёт скелет и анимации отдельными файлами, поэтому здесь они
## собираются вместе: меш масштабируется под нужный рост, на него натягивается
## скин, а анимации из Animations/*.fbx складываются в один AnimationPlayer.
class_name CharacterModel
extends RefCounted

const MODEL := "res://assets/characters/Model/characterMedium.fbx"
const SKINS := "res://assets/characters/Skins/"
const ANIMATIONS := {
	"idle": "res://assets/characters/Animations/idle.fbx",
	"run": "res://assets/characters/Animations/run.fbx",
	"jump": "res://assets/characters/Animations/jump.fbx",
}

static func available() -> bool:
	return ResourceLoader.exists(MODEL)

## Возвращает готовый узел с моделью и анимациями либо null, если ассетов нет.
static func build(skin_name: String, height: float) -> Node3D:
	if not available():
		return null
	var model := (load(MODEL) as PackedScene).instantiate() as Node3D
	if model == null:
		return null

	_scale_to_height(model, height)
	_apply_skin(model, skin_name)
	model.set_meta("skin_name", skin_name)
	_attach_animations(model)
	for node in _walk(model):
		if node is Skeleton3D:
			var motion := preload("res://scripts/character_motion.gd").new()
			motion.name = "CombatMotion"
			node.add_child(motion)
			model.set_meta("combat_motion", motion)
			break
	return model

static func motion(model: Node3D):
	return model.get_meta("combat_motion", null) if is_instance_valid(model) else null

static func drive(model: Node3D, actor: Node3D, state: Dictionary) -> void:
	var controller = motion(model)
	if controller == null:
		return
	controller.actor = actor
	controller.local_velocity = actor.global_basis.inverse() * state.get("velocity", Vector3.ZERO)
	controller.pitch = clampf(state.get("pitch", 0.0), -1.2, 1.2)
	controller.aiming = state.get("aiming", false)
	controller.crouching = state.get("crouching", false)
	controller.airborne = state.get("airborne", false)
	controller.alive = state.get("alive", true)
	controller.reload_progress = state.get("reload", -1.0)
	var tree := model.get_node_or_null("AnimationTree")
	if tree != null:
		tree.backward = controller.local_velocity.z > 0.3

static func _scale_to_height(model: Node3D, height: float) -> void:
	var box := _aabb(model)
	if box.size.y > 0.0001:
		model.scale = Vector3.ONE * (height / box.size.y)

static func _apply_skin(model: Node3D, skin_name: String) -> void:
	var path := "%s%s.png" % [SKINS, skin_name]
	var mat := StandardMaterial3D.new()
	mat.roughness = 0.85
	if ResourceLoader.exists(path):
		mat.albedo_texture = load(path)
		# Текстуры Kenney — атлас без сглаживания, фильтр только мылит.
		mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	else:
		mat.albedo_color = Color(0.7, 0.25, 0.22)
	for node in _walk(model):
		if node is MeshInstance3D:
			node.material_override = mat

## Анимации лежат в отдельных сценах с такой же иерархией Root/Skeleton3D,
## поэтому их треки подходят к нашей модели без правок.
static func _attach_animations(model: Node3D) -> void:
	var player := AnimationPlayer.new()
	player.name = "AnimationPlayer"
	model.add_child(player)

	var library := AnimationLibrary.new()
	for key in ANIMATIONS:
		var path: String = ANIMATIONS[key]
		if not ResourceLoader.exists(path):
			continue
		var source := (load(path) as PackedScene).instantiate()
		var source_player: AnimationPlayer = null
		for node in _walk(source):
			if node is AnimationPlayer:
				source_player = node
				break
		if source_player != null:
			for anim_name in source_player.get_animation_list():
				# В файле анимация называется "Root|Idle" — берём часть после «|».
				var short: String = anim_name.get_slice("|", 1) if "|" in anim_name else anim_name
				if short.to_lower().contains(key):
					var anim: Animation = source_player.get_animation(anim_name).duplicate()
					anim.loop_mode = Animation.LOOP_LINEAR if key != "jump" else Animation.LOOP_NONE
					library.add_animation(key, anim)
					break
		source.free()

	player.add_animation_library("", library)
	player.playback_default_blend_time = 0.16
	_attach_animation_tree(model, player)

static func _attach_animation_tree(model: Node3D, player: AnimationPlayer) -> void:
	if not player.has_animation("idle") or not player.has_animation("run") or not player.has_animation("jump"):
		return
	var tree := preload("res://scripts/character_animation_tree.gd").new()
	tree.name = "AnimationTree"
	tree.anim_player = NodePath("../AnimationPlayer")
	var blend := AnimationNodeBlendTree.new()
	for key in ANIMATIONS:
		var clip := AnimationNodeAnimation.new()
		clip.animation = key
		blend.add_node(key, clip)
	blend.add_node("Stride", AnimationNodeTimeScale.new())
	blend.add_node("Ground", AnimationNodeBlend2.new())
	blend.add_node("JumpStart", AnimationNodeTimeSeek.new())
	blend.add_node("Air", AnimationNodeBlend2.new())
	blend.connect_node("Stride", 0, "run")
	blend.connect_node("Ground", 0, "idle")
	blend.connect_node("Ground", 1, "Stride")
	blend.connect_node("JumpStart", 0, "jump")
	blend.connect_node("Air", 0, "Ground")
	blend.connect_node("Air", 1, "JumpStart")
	blend.connect_node("output", 0, "Air")
	tree.tree_root = blend
	model.add_child(tree)

## Одинаковые переходы для ботов и сетевых бойцов. Прыжок не зацикливаем.
static func animate(player: AnimationPlayer, velocity: Vector3, airborne: bool, alive: bool) -> void:
	if player == null:
		return
	var tree := player.get_parent().get_node_or_null("AnimationTree")
	if tree != null:
		tree.set_locomotion(velocity, airborne, alive)
		return
	if not alive:
		player.pause()
		return
	var speed := Vector2(velocity.x, velocity.z).length()
	var wanted := "jump" if airborne else ("run" if speed > 0.6 else "idle")
	if not player.has_animation(wanted):
		return
	player.speed_scale = clampf(speed / 4.2, 0.55, 1.7) if wanted == "run" else 1.0
	if player.get_meta("locomotion", "") != wanted:
		player.set_meta("locomotion", wanted)
		player.play(wanted, 0.16)
	elif not player.is_playing() and wanted != "jump":
		player.play(wanted, 0.16)

## Габариты в координатах корня модели. Считаются по локальным трансформам:
## модель ещё не в дереве, поэтому global_transform здесь недоступен.
static func _aabb(root: Node) -> AABB:
	var boxes: Array[AABB] = []
	for child in root.get_children():
		_collect(child, Transform3D.IDENTITY, boxes)
	if boxes.is_empty():
		return AABB()
	var result: AABB = boxes[0]
	for i in range(1, boxes.size()):
		result = result.merge(boxes[i])
	return result

static func _collect(node: Node, parent_transform: Transform3D, out: Array[AABB]) -> void:
	var transform := parent_transform
	if node is Node3D:
		transform = parent_transform * node.transform
	if node is VisualInstance3D:
		out.append(transform * node.get_aabb())
	for child in node.get_children():
		_collect(child, transform, out)

static func _walk(node: Node) -> Array[Node]:
	var out: Array[Node] = [node]
	for child in node.get_children():
		out.append_array(_walk(child))
	return out
