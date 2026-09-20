## Печатает структуру импортированных моделей: узлы, кости, анимации.
## Нужен, чтобы понять, что именно лежит в скачанном паке, не открывая редактор.
##   Godot_v4.7.2-stable_win64.exe --headless --path <проект> res://tools/inspect_assets.tscn
extends Node

func _ready() -> void:
	_dump_skeleton("res://assets/characters/Model/characterMedium.fbx")
	_dump_animations("res://assets/weapons/Rifle.fbx")
	_dump_animations("res://assets/weapons/Pistol.fbx")
	get_tree().quit()

func _dump_skeleton(path: String) -> void:
	print("=== кости ", path)
	if not ResourceLoader.exists(path):
		print("  (не импортирован)")
		return
	var root: Node = (load(path) as PackedScene).instantiate()
	for node in _walk(root):
		if node is Skeleton3D:
			var names: Array = []
			for i in node.get_bone_count():
				names.append(node.get_bone_name(i))
			print("  всего %d: %s" % [names.size(), ", ".join(names)])
	root.free()

func _dump_animations(path: String) -> void:
	print("=== анимации ", path)
	if not ResourceLoader.exists(path):
		print("  (не импортирован)")
		return
	var root: Node = (load(path) as PackedScene).instantiate()
	for node in _walk(root):
		if node is AnimationPlayer:
			for anim_name in node.get_animation_list():
				var anim: Animation = node.get_animation(anim_name)
				print("  %s: %.2f c, дорожек %d, зациклена=%s" % [
					anim_name, anim.length, anim.get_track_count(), str(anim.loop_mode)])
				for track in mini(anim.get_track_count(), 3):
					print("     дорожка %d: %s (%s)" % [
						track, str(anim.track_get_path(track)), anim.track_get_type(track)])
	root.free()

func _walk(node: Node) -> Array[Node]:
	var out: Array[Node] = [node]
	for child in node.get_children():
		out.append_array(_walk(child))
	return out
