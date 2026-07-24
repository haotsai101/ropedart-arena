extends Node
## Regression/verification test for "dart can fly and anchor past the arena
## edge, over the void" (rope_dart.gd's removed arena_half clamp -- see this
## session's CLAUDE.md entry). Mirrors test_player_map_boundary.gd's own
## standalone-instantiate pattern: real main.tscn obstacles instanced as a
## plain child (not a scene swap), players/darts instantiated and driven
## directly rather than through GameManager's spawn flow (lobby_mode stays at
## its normal default of true, so GameManager's own _init_game() no-ops here
## exactly like it does for test_player_map_boundary.gd).
##
## OLD_ARENA_HALF (14.5) is rope_dart.gd's own removed constant, kept here
## only as the test's own reference value for "where the dart used to be
## forced to stop" -- not read from rope_dart.gd at all anymore (it no longer
## exists there), which is itself part of what this test confirms.

const OLD_ARENA_HALF: float = 14.5
const ROPE_LENGTH: float = 8.0
const DT: float = 0.016

var any_failure := false


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	var main_scene: Node = load("res://scenes/main.tscn").instantiate()
	add_child(main_scene)
	for i in 5:
		await get_tree().physics_frame

	GameManager.current_state = GameManager.RoundState.PLAYING

	# 1) Thrown straight out over open void, from a position already close to
	# the OLD boundary -- should now sail past OLD_ARENA_HALF and anchor at
	# full ROPE_LENGTH instead of snapping to the old wall.
	await _run_void_throw("east over the void (+X)", Vector2(12.0, 0.0), Vector2(1, 0), main_scene)
	await _run_void_throw("south over the void (+Z)", Vector2(0.0, 12.0), Vector2(0, 1), main_scene)
	await _run_void_throw("northwest diagonal over the void", Vector2(-10.0, -10.0), Vector2(-1, -1).normalized(), main_scene)

	# 2) Regression: thrown at a REAL obstacle (PillarA at (-5,-5), half_size
	# 1.0) should still anchor on it, not fly through it out to ROPE_LENGTH --
	# confirms the raycast-obstacle stop condition is untouched by removing
	# the boundary clamp.
	await _run_obstacle_hit_regression(main_scene)

	print("[dart void test] %s" % ("ALL PASSED" if not any_failure else "FAILURES FOUND — see above"))
	print("DART_VOID_TEST_DONE")


func _run_void_throw(label: String, from_pos: Vector2, aim: Vector2, main_scene: Node) -> void:
	var player_scene: PackedScene = load("res://scenes/player.tscn")
	var player = player_scene.instantiate()
	main_scene.add_child(player)
	player.global_position = Vector3(from_pos.x, 1.0, from_pos.y)
	player.player_index = 0
	player.is_dead = false
	for i in 3:
		await get_tree().physics_frame

	var dart_scene: PackedScene = load("res://scenes/rope_dart.tscn")
	var dart = dart_scene.instantiate()
	main_scene.add_child(dart)
	dart.launch(player, from_pos, aim, 0.0)
	# Drive the owner's own dart reference too, so player.gd's
	# _update_persistent_rope()/_spawn_physics_rope() physics-rope chain is
	# actually exercised out over the void, not just the dart's own script --
	# this is what would crash/error if the off-map anchor point caused any
	# problem in the rope-rendering system.
	player.dart = dart

	var frames := 0
	while dart.state == 0 and frames < 200:  # State.FLYING == 0
		await get_tree().physics_frame
		frames += 1

	var final_pos: Vector2 = dart.head_2d
	var dist_from_origin: float = final_pos.distance_to(from_pos)
	var relevant_coord: float = maxf(absf(final_pos.x), absf(final_pos.y))

	print("[dart void test] %s: state=%d final_pos=%s dist_from_origin=%.3f relevant_coord=%.3f frames=%d" \
		% [label, dart.state, final_pos, dist_from_origin, relevant_coord, frames])

	if dart.state != 1:  # State.ANCHORED
		_fail(label, "dart never reached ANCHORED within %d frames (state=%d)" % [frames, dart.state])
	if relevant_coord <= OLD_ARENA_HALF:
		_fail(label, "dart anchored at %.3f, still inside the OLD arena_half=%.1f boundary -- the clamp was not actually removed" % [relevant_coord, OLD_ARENA_HALF])
	if absf(dist_from_origin - ROPE_LENGTH) > 0.05:
		_fail(label, "dart anchored %.3f units from its throw origin, expected exactly ROPE_LENGTH=%.1f (open void, nothing to hit before max range)" % [dist_from_origin, ROPE_LENGTH])

	# Let a couple more frames run with the physics rope chain active and
	# anchored off-map, to catch any error/crash from the rope system
	# reaching out past the platform edge.
	for i in 10:
		await get_tree().physics_frame

	# Confirm the owner's own leash clamp (_clamp_to_rope_leash) doesn't
	# explode/NaN the player position now that the anchor lives out over
	# the void with no ground under it.
	if not is_finite(player.global_position.x) or not is_finite(player.global_position.z):
		_fail(label, "player position went non-finite after an off-map anchor (%s)" % [player.global_position])

	player.dart = null
	dart.queue_free()
	player.queue_free()
	await get_tree().physics_frame


func _run_obstacle_hit_regression(main_scene: Node) -> void:
	var label := "regression: still anchors on a real obstacle (PillarA)"
	var player_scene: PackedScene = load("res://scenes/player.tscn")
	var player = player_scene.instantiate()
	main_scene.add_child(player)
	# PillarA sits at (-5, -5) with half_size 1.0 -- throw from due south of
	# it, straight north, so the dart's path runs directly into its face.
	var from_pos := Vector2(-5.0, -2.0)
	player.global_position = Vector3(from_pos.x, 1.0, from_pos.y)
	player.player_index = 0
	player.is_dead = false
	for i in 3:
		await get_tree().physics_frame

	var dart_scene: PackedScene = load("res://scenes/rope_dart.tscn")
	var dart = dart_scene.instantiate()
	main_scene.add_child(dart)
	dart.launch(player, from_pos, Vector2(0, -1), 0.0)
	player.dart = dart

	var frames := 0
	while dart.state == 0 and frames < 200:
		await get_tree().physics_frame
		frames += 1

	var final_pos: Vector2 = dart.head_2d
	var dist_from_origin: float = final_pos.distance_to(from_pos)
	print("[dart void test] %s: state=%d final_pos=%s dist_from_origin=%.3f frames=%d" \
		% [label, dart.state, final_pos, dist_from_origin, frames])

	if dart.state != 1:
		_fail(label, "dart never anchored (state=%d) -- expected an obstacle hit" % dart.state)
	elif dist_from_origin >= ROPE_LENGTH - 0.1:
		_fail(label, "dart traveled %.3f units (near/at full ROPE_LENGTH=%.1f) instead of stopping on PillarA -- obstacle raycast stop condition may be broken" % [dist_from_origin, ROPE_LENGTH])

	player.dart = null
	dart.queue_free()
	player.queue_free()
	await get_tree().physics_frame


func _fail(label: String, reason: String) -> void:
	any_failure = true
	print("[dart void test] %s: FAIL — %s" % [label, reason])
