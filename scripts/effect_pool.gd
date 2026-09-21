## A scene owns one pool; recycled effects never retain a destroyed surface.
extends Node3D

var slots: Dictionary = {}
var _entries: Dictionary = {}
var _sequence := 0
var created_count := 0
var reused_count := 0

func warm(kind: StringName, count: int, factory: Callable) -> void:
	if slots.has(kind):
		return
	var list: Array = []
	for i in count:
		var node: Node3D = factory.call()
		add_child(node)
		var entry := {"node": node, "remaining": 0.0, "active": false,
			"group": StringName(), "sequence": 0, "follow": null,
			"local": Transform3D.IDENTITY, "following": false}
		list.append(entry)
		_entries[node.get_instance_id()] = entry
		_disable(entry)
		created_count += 1
	slots[kind] = list

func take(kind: StringName, lifetime: float, group: StringName = &"") -> Node3D:
	var list: Array = slots.get(kind, [])
	if list.is_empty():
		return null
	var selected: Dictionary = list[0]
	for entry: Dictionary in list:
		if not entry.active:
			selected = entry
			break
		if entry.sequence < selected.sequence:
			selected = entry
	if selected.sequence > 0:
		reused_count += 1
	_disable(selected)
	_sequence += 1
	selected.sequence = _sequence
	selected.remaining = lifetime
	selected.active = true
	selected.group = group
	selected.node.visible = true
	if not group.is_empty():
		selected.node.add_to_group(group)
	return selected.node

func follow(node: Node3D, target: Node3D) -> void:
	var entry: Dictionary = _entries[node.get_instance_id()]
	entry.follow = weakref(target)
	entry.local = target.global_transform.affine_inverse() * node.global_transform
	entry.following = true
	node.set_meta("effect_surface", target.get_instance_id())

func release(node: Node3D) -> void:
	if is_instance_valid(node) and _entries.has(node.get_instance_id()):
		_disable(_entries[node.get_instance_id()])

func active_count(kind: StringName) -> int:
	var count := 0
	for entry: Dictionary in slots.get(kind, []):
		if entry.active:
			count += 1
	return count

func _process(_delta: float) -> void:
	# Running after actors also tracks animated muzzles on render frames.
	for list: Array in slots.values():
		for entry: Dictionary in list:
			if not entry.active or not entry.following:
				continue
			var target = entry.follow.get_ref()
			if not is_instance_valid(target) or not target.is_inside_tree() or target.is_queued_for_deletion():
				_disable(entry)
			else:
				entry.node.global_transform = target.global_transform * entry.local

func _physics_process(delta: float) -> void:
	for list: Array in slots.values():
		for entry: Dictionary in list:
			if not entry.active:
				continue
			entry.remaining -= delta
			if entry.remaining <= 0.0:
				_disable(entry)

func _disable(entry: Dictionary) -> void:
	var node: Node3D = entry.node
	node.visible = false
	if not entry.group.is_empty() and node.is_in_group(entry.group):
		node.remove_from_group(entry.group)
	if node.has_meta("effect_surface"):
		node.remove_meta("effect_surface")
	if node is CPUParticles3D:
		node.emitting = false
	if node is RigidBody3D:
		node.freeze = true
		node.sleeping = true
		node.collision_mask = 0
		node.linear_velocity = Vector3.ZERO
		node.angular_velocity = Vector3.ZERO
		node.set_physics_process(false)
	entry.active = false
	entry.follow = null
	entry.following = false
	entry.group = StringName()
