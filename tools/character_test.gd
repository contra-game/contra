## Проверка итоговых поз после SkeletonModifier3D, а не только параметров.
## -- --capture сохраняет виды боевых стоек для визуальной проверки.
extends Node3D
var model: Node3D
var actor: Node3D
var motion
var anim: AnimationPlayer
var poses: Dictionary = {}
var failures := 0
var snapshots: Dictionary = {}
func _ready():
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color(0.13,0.16,0.2)
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.environment.ambient_light_color = Color.WHITE
	env.environment.ambient_light_energy = 0.7
	add_child(env)
	var key := DirectionalLight3D.new()
	add_child(key)
	key.rotation_degrees = Vector3(-40,-25,0)
	var camera := Camera3D.new()
	add_child(camera)
	camera.position = Vector3(2.5,1.9,-3.5)
	camera.look_at(Vector3(0,0.9,0))
	camera.current = true
	camera.fov = 38
	actor = Node3D.new()
	add_child(actor)
	model = CharacterModel.build("criminalMaleA",1.8)
	actor.add_child(model)
	model.rotation.y = PI
	anim = model.get_node("AnimationPlayer")
	motion = CharacterModel.motion(model)
	motion.equip(actor,Weapons.get_weapon(&"ak47"))
	motion.modification_processed.connect(_remember_pose)
	var states := {
		"ready": {},
		"aim": {"aiming":true,"pitch":0.18},
		"strafe": {"velocity":Vector3(3,0,0),"aiming":true},
		"crouch": {"crouching":true,"aiming":true},
		"reload": {"reload":0.5},
		"jump": {"airborne":true,"velocity":Vector3(0,3,0)},
	}
	for key_name in states:
		var state: Dictionary = states[key_name]
		CharacterModel.drive(model,actor,state)
		CharacterModel.animate(anim,state.get("velocity",Vector3.ZERO),state.get("airborne",false),true)
		for i in 36: await get_tree().physics_frame
		snapshots[key_name] = poses.duplicate()
		_check(poses.RightHand.distance_to(motion.weapon.to_global(Vector3(0,-0.02,motion.data.length * 0.16) / motion.data.model_scale)) < 0.025, "%s: правая рука удерживает оружие" % key_name)
		_check(model.scale.is_equal_approx(Vector3.ONE * model.scale.x), "%s: поза не сплющивает модель" % key_name)
		_check(poses.Hips.is_finite() and poses.LeftHand.is_finite(), "%s: скелет без некорректных трансформаций" % key_name)
		if "--capture" in OS.get_cmdline_user_args():
			await RenderingServer.frame_post_draw
			get_viewport().get_texture().get_image().save_png("res://build/character-%s.png" % key_name)
	_check(snapshots.ready.Hips.y - snapshots.crouch.Hips.y > 0.28, "приседание опускает таз")
	_check(absf(snapshots.ready.LeftFoot.y - snapshots.crouch.LeftFoot.y) < 0.04, "приседание сохраняет опору стоп")
	_check(snapshots.aim.RightHand.y > snapshots.ready.RightHand.y + 0.1, "прицеливание поднимает оружие к плечу")
	_check(snapshots.reload.LeftHand.distance_to(snapshots.ready.LeftHand) > 0.2, "перезарядка переводит левую руку к подсумку")
	CharacterModel.drive(model,actor,{"velocity":Vector3(0,0,3)})
	CharacterModel.animate(anim,Vector3(0,0,3),false,true)
	CharacterModel.drive(model,actor,{"velocity":Vector3(0,0,3)})
	for i in 2: await get_tree().physics_frame
	_check(float(model.get_node("AnimationTree").get("parameters/Stride/scale")) < 0.0, "отступление проигрывает шаг назад")
	for id in Weapons.ids():
		motion.equip(actor,Weapons.get_weapon(id))
		CharacterModel.drive(model,actor,{"aiming":true})
		CharacterModel.animate(anim,Vector3.ZERO,false,true)
		for i in 30: await get_tree().physics_frame
		_check(motion.muzzle != null and motion.muzzle.global_position.is_finite(), "%s: оружие имеет живой маркер дула" % id)
		_check(poses.RightHand.distance_to(motion.weapon.to_global(Vector3(0,-0.02,motion.data.length * 0.16) / motion.data.model_scale)) < 0.025, "%s: хват сохраняется при ADS" % id)
		_check(poses.LeftHand.distance_to(motion.support_target) < 0.025, "%s: поддерживающая рука остаётся на оружии" % id)
	motion.fire()
	motion.hit(20.0)
	for i in 3: await get_tree().physics_frame
	_check(motion._recoil.value.length() > 0.001 and motion._impact.value.length() > 0.001, "выстрел и попадание дают отдельные реакции")
	for i in 120: await get_tree().physics_frame
	_check(motion._recoil.value.length() < 0.001 and motion._impact.value.length() < 0.001, "боевые реакции затухают")
	motion.fire()
	motion.reset_motion()
	_check(motion._recoil.velocity.is_zero_approx(), "респавн сбрасывает импульсы")
	print("CHARACTER TEST: ", "PASS" if failures == 0 else "FAIL", " failures=",failures)
	get_tree().quit(0 if failures == 0 else 1)
func _remember_pose():
	for key in ["RightHand","LeftHand","Hips","RightFoot","LeftFoot"]:
		poses[key] = motion._world_pose(key).origin

func _check(ok: bool, label: String) -> void:
	if not ok: failures += 1
	print("PASS" if ok else "FAIL", " ",label)
