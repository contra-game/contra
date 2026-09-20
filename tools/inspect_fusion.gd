## Печатает API, которое регистрирует GDExtension Photon Fusion:
## классы, их методы и сигналы. Нужен, чтобы писать сетевой код по фактическому
## API аддона, а не по памяти.
##   Godot_v4.7.2-stable_win64.exe --headless --path <проект> res://tools/inspect_fusion.tscn
extends Node

func _ready() -> void:
	var classes: Array = []
	for name in ClassDB.get_class_list():
		if name.begins_with("Fusion"):
			classes.append(name)
	classes.sort()
	print("классы Fusion: ", ", ".join(classes))

	for name in classes:
		print("\n=== ", name, " (наследует ", ClassDB.get_parent_class(name), ")")
		var methods: Array = []
		for method in ClassDB.class_get_method_list(name, true):
			var args: Array = []
			for arg in method.args:
				args.append("%s: %s" % [arg.name, type_string(arg.type)])
			methods.append("%s(%s)" % [method.name, ", ".join(args)])
		if not methods.is_empty():
			print("  методы: ", "; ".join(methods))
		var signals: Array = []
		for sig in ClassDB.class_get_signal_list(name, true):
			var args: Array = []
			for arg in sig.args:
				args.append(arg.name)
			signals.append("%s(%s)" % [sig.name, ", ".join(args)])
		if not signals.is_empty():
			print("  сигналы: ", "; ".join(signals))
		var props: Array = []
		for prop in ClassDB.class_get_property_list(name, true):
			props.append(prop.name)
		if not props.is_empty():
			print("  свойства: ", ", ".join(props))

	# Синглтон Fusion, судя по документации, доступен как автозагрузка аддона.
	print("\nсинглтон Fusion в дереве: ", str(get_node_or_null("/root/Fusion")))
	get_tree().quit()
