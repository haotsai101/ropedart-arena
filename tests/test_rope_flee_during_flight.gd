extends Node
## ROUND 30 (2026-07-31) regression test: reproduces and verifies the fix for
## a direct user report -- "The rope joints are not fixed. The segments are
## pulled apart when the max rope length is exceeded."
##
## ROOT CAUSE (see player.gd's _apply_rope_leash_velocity_clamp() own updated
## doc comment): that clamp used to return immediately unless
## dart.state == DART_STATE_ANCHORED, so a player had ZERO movement
## restriction while their own dart was FLYING or RECALLING. RopeChainPBD's
## two endpoints (hand/tip) are driven KINEMATICALLY every tick regardless of
## state -- pinning them farther apart than the chain's own total capacity
## (ROPE_PHYSICS_SEGMENTS * ROPE_PHYSICS_SEGMENT_LENGTH == DART_ROPE_LENGTH)
## is mathematically infeasible for a one-sided <= distance constraint (by
## the triangle inequality, at least one link MUST exceed its own max length
## if the endpoints are pinned farther apart than the sum of every link's
## capacity) -- this is exactly "segments pulled apart," a real, large,
## structural violation, not the small ~0.05-0.16 unit convergence-order
## residual rope_chain_pbd.gd's own class doc already discloses elsewhere.
##
## This test directly measures RopeChainPBD.max_link_gap_violation() (the
## same primary-suite metric test_rope_pbd_chain_rigidity.gd uses) while a
## player throws a full-charge dart (travel_speed up to 36 u/s) and
## immediately, continuously flees in the OPPOSITE direction at DASH_SPEED
## (20 u/s) -- the exact real-gameplay scenario the bug report describes --
## across both the FLYING and RECALLING states.
##
## Run via:
##   godot --headless --path . res://tests/test_rope_flee_during_flight.tscn

const GAP_TOLERANCE: float = 0.02  ## generous floating-point residual only -- see test_rope_pbd_chain_rigidity.gd's own identical tolerance


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	print("[FLEE_TEST] ============ starting ============")
	var main_scene: Node = load("res://scenes/main.tscn").instantiate()
	add_child(main_scene)
	for i in 5:
		await get_tree().physics_frame

	GameManager.lobby_mode = false
	GameManager.is_online = false
	GameManager.total_players = 1
	GameManager.human_count = 1
	GameManager.bot_difficulty = 2
	GameManager.lives_per_round = 99
	GameManager.rounds_to_win = 999
	GameManager.round_wins.clear()
	GameManager._all_players.clear()
	GameManager._alive_players.clear()
	GameManager._init_game_local(main_scene)
	GameManager.start_round()
	GameManager.current_state = GameManager.RoundState.PLAYING

	var p0 = GameManager._all_players[0]
	var dart_rope_len: float = p0.DART_ROPE_LENGTH
	var delta: float = 1.0 / 60.0

	var overall_max_gap: float = 0.0
	var overall_max_hand_to_dart: float = 0.0
	var gap_violation_events: int = 0
	var samples: int = 0

	# ------------------------------------------------------------------
	# SCENARIO A: throw a full-charge dart due east into open air (no
	# obstacle/player in the way, so it flies the full ROPE_LENGTH and
	# anchors), then IMMEDIATELY flee due WEST (directly away from the
	# dart's own flight path) at full dash speed, sustained through both
	# FLYING and ANCHORED.
	# ------------------------------------------------------------------
	p0.reset_for_round(5, Vector3(0.0, 0.0, 0.0))
	for i in 50:  # past SPAWN_INVINCIBLE_DURATION (0.75s/45 ticks), which also blocks _throw()
		await get_tree().physics_frame
	p0.aim_dir = Vector2(1, 0)
	p0._throw(1.0)
	for i in 1:
		await get_tree().physics_frame
	if p0.dart == null:
		print("[FLEE_TEST] scenario A: FAILED TO THROW (dart is null) -- aborting scenario A")
	else:
		print("[FLEE_TEST] scenario A: thrown, dart.state=%d travel_speed=%.1f" % [p0.dart.state, p0.dart.travel_speed])

	p0.set_physics_process(false)  # drive velocity/anchors/clamp by hand -- see test_rope_pbd_chain_rigidity.gd's own identical rationale
	for tick in range(240):
		p0._update_physics_rope_anchors()
		p0.velocity = Vector3(-1, 0, 0) * 20.0  # flee due WEST at full DASH_SPEED, directly away from the eastward throw
		p0._apply_rope_leash_velocity_clamp(delta)
		p0.move_and_slide()
		await get_tree().physics_frame
		if p0._rope_chain != null:
			samples += 1
			var v: float = p0._rope_chain.max_link_gap_violation()
			overall_max_gap = maxf(overall_max_gap, v)
			if v > GAP_TOLERANCE:
				gap_violation_events += 1
			if p0.dart != null and is_instance_valid(p0.dart):
				var hand_2d: Vector2 = p0._rope_chain.points[0]
				overall_max_hand_to_dart = maxf(overall_max_hand_to_dart, hand_2d.distance_to(p0.dart.head_2d))
	p0.set_physics_process(true)
	print("[FLEE_TEST] scenario A done: max_gap_violation=%.5f max_hand_to_dart=%.4f (DART_ROPE_LENGTH=%.2f)" % [
		overall_max_gap, overall_max_hand_to_dart, dart_rope_len])

	# ------------------------------------------------------------------
	# SCENARIO B: same, but flee during RECALLING specifically -- throw,
	# let it anchor, manually trigger recall(), then flee away from the
	# dart's live retracting position.
	# ------------------------------------------------------------------
	if p0.dart != null:
		p0.dart.queue_free()
		p0.dart = null
	for i in 3:
		await get_tree().physics_frame
	p0.reset_for_round(5, Vector3(0.0, 0.0, 0.0))
	for i in 50:
		await get_tree().physics_frame
	p0.aim_dir = Vector2(0, 1)
	p0._throw(1.0)
	for i in 1:
		await get_tree().physics_frame
	if p0.dart == null:
		print("[FLEE_TEST] scenario B: FAILED TO THROW (dart is null) -- aborting scenario B")
		print("[FLEE_TEST] ============ FINAL RESULTS (scenario B skipped) ============")
		print("[FLEE_TEST] total samples=%d gap_violation_events(>%.3f)=%d" % [samples, GAP_TOLERANCE, gap_violation_events])
		print("[FLEE_TEST] overall_max_gap_violation=%.6f" % overall_max_gap)
		print("[FLEE_TEST] overall_max_hand_to_dart=%.4f (DART_ROPE_LENGTH=%.2f)" % [overall_max_hand_to_dart, dart_rope_len])
		print("FLEE_TEST_DONE")
		get_tree().quit()
		return
	p0.set_physics_process(false)
	# Let it fly to a real anchor first (no forced player movement yet).
	for tick in range(60):
		p0._update_physics_rope_anchors()
		p0.velocity = Vector3.ZERO
		p0.move_and_slide()
		await get_tree().physics_frame
	if p0.dart != null and is_instance_valid(p0.dart):
		p0.dart.recall()
		p0._is_recalling = true
		print("[FLEE_TEST] scenario B: recall triggered, dart.state=%d" % p0.dart.state)
	for tick in range(240):
		p0._update_physics_rope_anchors()
		p0.velocity = Vector3(0, 0, -1) * 20.0  # flee due SOUTH, away from the northward throw/recall line
		p0._apply_rope_leash_velocity_clamp(delta)
		p0.move_and_slide()
		await get_tree().physics_frame
		if p0._rope_chain != null:
			samples += 1
			var v: float = p0._rope_chain.max_link_gap_violation()
			overall_max_gap = maxf(overall_max_gap, v)
			if v > GAP_TOLERANCE:
				gap_violation_events += 1
			if p0.dart != null and is_instance_valid(p0.dart):
				var hand_2d: Vector2 = p0._rope_chain.points[0]
				overall_max_hand_to_dart = maxf(overall_max_hand_to_dart, hand_2d.distance_to(p0.dart.head_2d))
	p0.set_physics_process(true)
	print("[FLEE_TEST] scenario B done (cumulative): max_gap_violation=%.5f max_hand_to_dart=%.4f (DART_ROPE_LENGTH=%.2f)" % [
		overall_max_gap, overall_max_hand_to_dart, dart_rope_len])

	print("[FLEE_TEST] ============ FINAL RESULTS ============")
	print("[FLEE_TEST] total samples=%d gap_violation_events(>%.3f)=%d" % [samples, GAP_TOLERANCE, gap_violation_events])
	print("[FLEE_TEST] overall_max_gap_violation=%.6f (requirement: must be ~0.0 always, same tolerance as test_rope_pbd_chain_rigidity.gd)" % overall_max_gap)
	print("[FLEE_TEST] overall_max_hand_to_dart=%.4f (DART_ROPE_LENGTH=%.2f, overshoot=%.4f)" % [
		overall_max_hand_to_dart, dart_rope_len, overall_max_hand_to_dart - dart_rope_len])

	var pass_gap: bool = overall_max_gap <= GAP_TOLERANCE
	var pass_hand_to_dart: bool = (overall_max_hand_to_dart - dart_rope_len) <= 0.5
	print("[FLEE_TEST] PASS_GAP=%s PASS_HAND_TO_DART=%s" % [pass_gap, pass_hand_to_dart])

	print("FLEE_TEST_DONE")
	get_tree().quit()
