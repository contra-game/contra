extends Node3D

const Flow := preload("res://scripts/match_flow.gd")
const Spawns := preload("res://scripts/spawn_picker.gd")
var failures: int = 0
var scores := {"1": {"name": "One", "frags": 0}, "2": {"name": "Two", "frags": 0}}

class Combatant:
	extends CharacterBody3D
	var team: int = 0

class ScoreWrapper:
	extends Node3D
	var frags: int = 20
	var score_round: int = 0

func _ready() -> void:
	var flow := Flow.new()
	add_child(flow)
	flow.set_process(false)
	flow.warmup_seconds = 1.0
	flow.active_seconds = 3.0
	flow.round_end_seconds = 1.0
	flow.post_match_seconds = 1.0
	flow.configure(false, 321, func(): return scores)
	_check(flow.phase == Flow.Phase.WARMUP and flow.allows_combat() and not flow.scores_enabled(), "warmup allows combat without counting scores")
	flow.tick(1.1)
	_check(flow.phase == Flow.Phase.ACTIVE and flow.scores_enabled(), "warmup transitions into a timed scored round")
	scores["1"].frags = 20
	flow.tick(0.1)
	_check(flow.phase == Flow.Phase.ROUND_END and not flow.allows_combat(), "frag limit ends the round and blocks combat")
	_check(int(flow.snapshot.wins["1"].rounds) == 1, "round winner is retained in shared match snapshot")
	var copy := Flow.new()
	add_child(copy)
	copy.set_process(false)
	copy.seed_value = 321
	copy._elapsed = flow._elapsed
	var wire_state = JSON.parse_string(JSON.stringify(flow.snapshot))
	_check(copy.accept_snapshot(wire_state) and copy.phase == flow.phase, "late join restores current phase and result from JSON room property")
	_check(is_equal_approx(copy.seconds_left(), flow.seconds_left()), "restored authority keeps the original deadline")
	_check(not copy.accept_snapshot(flow.snapshot), "duplicate room snapshot does not replay round reset")
	var stale: Dictionary = flow.snapshot.duplicate(true)
	stale.revision = int(stale.revision) - 1
	_check(not copy.accept_snapshot(stale), "stale room updates cannot rewind the round")
	copy.tick(1.1)
	_check(copy.phase == Flow.Phase.ACTIVE and copy.round_index == 2, "restored authority advances the existing match")
	flow.tick(1.1)
	scores["1"].frags = 0
	scores["2"].frags = 2
	flow.tick(3.1)
	_check(flow.phase == Flow.Phase.ROUND_END and int(flow.snapshot.wins["2"].rounds) == 1, "time limit selects the current leader")
	flow.tick(1.1)
	_check(flow.round_index == 3 and flow.phase == Flow.Phase.ACTIVE, "next round continues the same match")
	scores["1"].frags = 3
	flow.tick(3.1)
	flow.tick(1.1)
	_check(flow.phase == Flow.Phase.POST_MATCH and "One" in flow.label(), "third round produces the overall match result")
	flow.tick(1.1)
	_check(flow.phase == Flow.Phase.WARMUP and flow.snapshot.wins.is_empty(), "post-match starts a fresh warmup")
	flow.free()
	copy.free()
	await _test_spawns()
	await _test_game_cycle()
	print("MATCH TEST: ", "PASS" if failures == 0 else "FAIL", " failures=", failures)
	get_tree().quit(0 if failures == 0 else 1)

func _test_spawns() -> void:
	var actor := _combatant(Vector3(0, 0, 5), 0)
	var enemy := _combatant(Vector3(0, 0, -8), 1)
	var wall := StaticBody3D.new()
	var collision := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(6, 3, 1)
	collision.shape = box
	wall.add_child(collision)
	add_child(wall)
	wall.position = Vector3(0, 1.5, -3)
	for i in 2: await get_tree().physics_frame
	var points: Array[Transform3D] = [Transform3D(Basis.IDENTITY, Vector3(8, 0.2, 0)), Transform3D(Basis.IDENTITY, Vector3(0, 0.2, 0)), Transform3D(Basis.IDENTITY, Vector3(0, 0.2, -3))]
	var selected := Spawns.choose(self, points, actor)
	_check(not selected.is_empty() and selected.transform.origin == Vector3(0, 0.2, 0), "spawn favors cover over an exposed distant point")
	_check(not Spawns.clear(get_world_3d().direct_space_state, points[2], actor), "capsule occupancy excludes a spawn inside a wall")
	var friendly := _combatant(Vector3(0, 0.2, 0), 0)
	for i in 2: await get_tree().physics_frame
	selected = Spawns.choose(self, points, actor)
	_check(not selected.is_empty() and selected.transform.origin == Vector3(8, 0.2, 0), "occupied protected spawn falls back to a free point")
	var only_blocked: Array[Transform3D] = [points[2]]
	_check(Spawns.choose(self, only_blocked, actor).is_empty(), "no free spawn returns no result instead of teleporting into geometry")
	actor.queue_free()
	enemy.queue_free()
	friendly.queue_free()
	wall.queue_free()
	for i in 2: await get_tree().physics_frame

func _test_game_cycle() -> void:
	var game := (load("res://scenes/main.tscn") as PackedScene).instantiate()
	game.bot_count = 2
	add_child(game)
	for i in 3: await get_tree().physics_frame
	var bots: Array = []
	for actor in game.actors.get_children():
		if actor is Bot:
			actor.set_physics_process(false)
			bots.append(actor)
	game.match_flow.set_process(false)
	bots[0].health.take_damage(1000, game.player)
	_check(game.kills == 0, "warmup death does not increment the game score")
	game.match_flow.active_seconds = 0.2
	game.match_flow.tick(8.1)
	_check(bots[0].health.alive and game.player.health.alive and game.kills == 0, "round start respawns combatants and clears scores")
	bots[0].health.take_damage(1000, game.player)
	_check(game.kills == 1, "active round counts a confirmed kill")
	game.match_flow.tick(0.3)
	_check(not game.player.input_enabled and not bots[1].is_physics_processing(), "round results stop player input and bot combat")
	var health_before: float = bots[1].health.health
	Damage.apply(bots[1], 50, game.player, false, 1.0, "ak47")
	_check(is_equal_approx(bots[1].health.health, health_before), "damage cannot change the result after the round ends")
	game.match_flow.tick(5.1)
	_check(game.player.input_enabled and game.kills == 0 and game.match_flow.round_index == 2, "next round restores input and resets scoreboard")
	var wrapper := ScoreWrapper.new()
	game.add_child(wrapper)
	game.player.reparent(wrapper)
	game.online = true
	var score_id := str(game.player.peer_id)
	_check(int(game._match_scores()[score_id].frags) == 0, "previous round's delayed remote score cannot end the new round")
	wrapper.score_round = int(game.match_flow.snapshot.revision)
	_check(int(game._match_scores()[score_id].frags) == 20, "score counts when its replicated round epoch matches")
	game.online = false
	game.player.reparent(game.actors)
	wrapper.free()
	game.queue_free()

func _combatant(at: Vector3, team_id: int) -> Combatant:
	var body := Combatant.new()
	body.team = team_id
	body.collision_layer = 2
	body.add_to_group("combatants")
	var collision := CollisionShape3D.new()
	var capsule := CapsuleShape3D.new()
	capsule.height = 1.8
	capsule.radius = 0.4
	collision.shape = capsule
	collision.position.y = 0.9
	body.add_child(collision)
	var health := Health.new()
	health.name = "Health"
	body.add_child(health)
	add_child(body)
	body.global_position = at
	return body

func _check(ok: bool, label: String) -> void:
	if not ok:
		failures += 1
	print("PASS" if ok else "FAIL", " ", label)
