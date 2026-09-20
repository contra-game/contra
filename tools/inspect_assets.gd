## Печатает структуру импортированных моделей: узлы, меши, анимации.
## Нужен, чтобы понять, что именно лежит в скачанном паке, не открывая редактор.
##   Godot_v4.7.2-stable_win64.exe --headless --path <проект> res://tools/inspect_assets.tscn
extends Node

const PATHS := [
	"res://assets/weapons/Rifle.fbx",
	"res://assets/weapons/Pistol.fbx",
	"res://assets/weapons/Shotgun.fbx",
	"res://assets/weapons/SniperRifle.fbx",
	"res://assets/weapons/P90.fbx",
	"res://assets/weapons/Revolver.fbx",
	"res://assets/raw/protagonists/Model/characterMedium.fbx",
	"res://assets/raw/protagonists/Animations/idle.fbx",
]

func _ready() -> void:
	for path in PATHS:
		print("=== ", path)
		if not ResourceLoader.exists(path):
			print("  (не импортирован)")
			continue
		var scene: PackedScene = load(path)
		var root: Node = scene.instantiate()
		_dump(root, 1)
		root.free()
	get_tree().quit()

func _dump(node: Node, depth: int) -> void:
	var pad := "  ".repeat(depth)
	var extra := ""
	if node is MeshInstance3D:
		var mesh: Mesh = node.mesh
		extra = " [mesh: %d поверхностей, %s]" % [
			mesh.get_surface_count() if mesh != null else 0,
			str(mesh.get_aabb().size.snappedf(0.01)) if mesh != null else "-"]
	elif node is AnimationPlayer:
		var names: Array = []
		for anim in node.get_animation_list():
			var a: Animation = node.get_animation(anim)
			names.append("%s(%.2fs)" % [anim, a.length])
		extra = " [анимации: %s]" % ", ".join(names)
	elif node is Skeleton3D:
		extra = " [костей: %d]" % node.get_bone_count()
	print(pad, node.name, " <", node.get_class(), ">", extra)
	for child in node.get_children():
		_dump(child, depth + 1)
