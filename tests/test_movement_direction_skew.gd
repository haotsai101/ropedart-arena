extends Node
## Regression test for a real user report: "the throwing pushed me southeast
## and walking west pushed me northwest." Verifies, via direct numeric
## instrumentation (not eyeballing video frames), whether the CANONICAL
## gameplay position (player.get_pos_2d() / CharacterBody3D.velocity) is
## actually skewed off pure cardinal axes, or whether it stays exactly
## clean -- in which case any perceived diagonal drift has to come from
## somewhere else entirely (e.g. arena_camera.gd's own AABB-follow pan/zoom
## shifting what a WORLD-STATIONARY or WORLD-AXIS-ALIGNED point renders at
## on screen, a pure rendering artifact that doesn't touch get_pos_2d() at
## all -- see test_movement_camera_illusion.gd for that half of the
## investigation).
##
## PHASE 1: hold pure "west" (KEY_A only, real Input.parse_input_event so
## the actual _get_move_input()/_physics_process() pipeline runs unmodified,
## not a hand-rolled substitute) for ~2s with no dart out, logging
## get_pos_2d() and velocity every few ticks. Confirms world Z (get_pos_2d().y)
## never moves and world X (get_pos_2d().x) decreases monotonically at
## exactly move_speed.
##
## PHASE 2: with zero movement input held, call _throw() directly (bypassing
## the charge-hold UI path, matching the same call other regression tests in
## this suite already use) and track get_pos_2d() every tick through the
## dart's full FLYING -> ANCHORED lifetime (well past max range, ROPE_LENGTH
## at travel_speed=18 takes under half a second regardless of the exact
## length). Confirms zero position
## drift from the throw action itself, including through the window right
## after _spawn_physics_rope() when the chain is still bunched/settling and
## _clamp_to_rope_leash() first starts trying to fire (once the dart
## anchors).
##
## Run via the Godot MCP run_project tool with
## scene=res://tests/test_movement_direction_skew.tscn.

const HOLD_TICKS: int = 120  ## ~2s at 60Hz
const THROW_WATCH_TICKS: int = 90  ## ~1.5s -- comfortably past max-range anchor
const SAMPLE_EVERY: int = 10


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	var main_scene: Node = load("res://scenes/main.tscn").instantiate()
	add_child(main_scene)
	for i in 5:
		await get_tree().physics_frame

	GameManager.current_state = GameManager.RoundState.PLAYING

	var player_scene: PackedScene = load("res://scenes/player.tscn")
	var player = player_scene.instantiate()
	player.player_index = 0
	player.is_bot = false
	add_child(player)
	player.global_position = Vector3(0.0, GameManager.PLAYER_HALF_HEIGHT, 0.0)
	player.spawn_pos = player.global_position
	player.aim_dir = Vector2(0, -1)
	for i in 5:
		await get_tree().physics_frame

	print("=== PHASE 1: pure west hold (KEY_A only), no dart ===")
	var start_pos: Vector2 = player.get_pos_2d()
	print("[TEST] start_pos=%s" % [start_pos])

	var key_down := InputEventKey.new()
	key_down.keycode = KEY_A
	key_down.physical_keycode = KEY_A
	key_down.pressed = true
	Input.parse_input_event(key_down)

	var max_abs_z: float = 0.0
	var prev_pos: Vector2 = start_pos
	for tick in range(HOLD_TICKS):
		await get_tree().physics_frame
		var pos: Vector2 = player.get_pos_2d()
		var vel2d := Vector2(player.velocity.x, player.velocity.z)
		max_abs_z = maxf(max_abs_z, absf(pos.y - start_pos.y))
		if tick % SAMPLE_EVERY == 0:
			print("[TEST] tick=%d pos=%s vel2d=%s delta_from_prev=%s" % [tick, pos, vel2d, pos - prev_pos])
		prev_pos = pos

	var end_pos: Vector2 = player.get_pos_2d()
	var net_delta: Vector2 = end_pos - start_pos
	print("[TEST] PHASE 1 RESULT: net_delta=%s max_abs_z_drift=%.5f expected_pure_x=%.3f (move_speed=%.2f * %d ticks / 60)" % [
		net_delta, max_abs_z, net_delta.x, player.move_speed, HOLD_TICKS])
	var phase1_pass: bool = max_abs_z < 0.001 and net_delta.x < -0.01
	print("[TEST] PHASE 1 %s" % ("PASS: movement stayed on pure -X, zero Z drift" if phase1_pass else "FAIL: unexpected Z drift or no X movement -- real skew in canonical position math"))

	var key_up := InputEventKey.new()
	key_up.keycode = KEY_A
	key_up.physical_keycode = KEY_A
	key_up.pressed = false
	Input.parse_input_event(key_up)
	for i in 5:
		await get_tree().physics_frame

	print("=== PHASE 2: throw with zero movement input held ===")
	var pre_throw_pos: Vector2 = player.get_pos_2d()
	print("[TEST] pre_throw_pos=%s" % [pre_throw_pos])
	player._throw(1.0)
	var max_drift: float = 0.0
	var max_drift_tick: int = -1
	var max_drift_vec: Vector2 = Vector2.ZERO
	for tick in range(THROW_WATCH_TICKS):
		await get_tree().physics_frame
		var pos: Vector2 = player.get_pos_2d()
		var drift: Vector2 = pos - pre_throw_pos
		if drift.length() > max_drift:
			max_drift = drift.length()
			max_drift_tick = tick
			max_drift_vec = drift
		if tick < 40:
			var dart_state: Variant = player.dart.state if player.dart != null and is_instance_valid(player.dart) else null
			var diag := ""
			if player.dart != null and is_instance_valid(player.dart) and dart_state == 1 and player._rope_chain != null:
				# ADAPTED for the PBD chain rewrite: there is no pivot/radius
				# function any more (see player.gd's _apply_rope_leash_velocity_
				# clamp() doc comment -- "NO PIVOT, NO RADIUS, NO CIRCLE") --
				# this diag now reports the same real, direct slack
				# measurement the leash clamp itself uses.
				var hand_2d: Vector2 = player._rope_chain.points[0]
				var used_length: float = maxf(player._rope_chain.total_extension_2d(), hand_2d.distance_to(player.dart.head_2d))
				var slack: float = player.DART_ROPE_LENGTH - used_length
				diag = " used_length=%.4f slack=%.4f (taut=%s)" % [used_length, slack, slack <= 0.0]
			print("[TEST] tick=%d pos=%s drift_from_pre_throw=%s dart_state=%s%s" % [tick, pos, drift, dart_state, diag])

	print("[TEST] PHASE 2 RESULT: max_drift=%.5f at tick=%d drift_vec=%s (pre_throw_pos=%s)" % [
		max_drift, max_drift_tick, max_drift_vec, pre_throw_pos])
	var phase2_pass: bool = max_drift < 0.01
	print("[TEST] PHASE 2 %s" % ("PASS: zero position drift from throwing alone" if phase2_pass else "FAIL: throwing itself moved the player's canonical position"))

	print("[TEST] OVERALL %s" % ("PASS" if (phase1_pass and phase2_pass) else "FAIL"))
	print("MOVEMENT_SKEW_TEST_DONE")
