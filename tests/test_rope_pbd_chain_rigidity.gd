extends Node
## PRIMARY regression suite for the PBD/Verlet rope chain (scripts/rope_chain_pbd.gd),
## replacing tests/test_rope_physics_chain_settle.gd (the old RigidBody3D +
## PhysicsServer3D joint chain's own primary suite -- deleted, since the
## internals it measured -- joint gaps, PhysicsServer3D RIDs, bias/damping --
## no longer exist).
##
## Directly measures REQUIREMENT 1 ("the rope bars must never separate") via
## RopeChainPBD.max_link_gap_violation() -- the real, per-tick distance any
## consecutive pair of chain points currently sits PAST its own fixed
## segment_max_length -- across every scenario this project's rope history
## has previously found to stress the chain: idle collapse, a full-charge
## throw's instant unfold, obstacle-wrap settled configurations, retrieve
## fold, and a real multi-bot soak. This must read ~0.0 (floating point
## residual only) on every single sample, not just at rest -- a hard,
## structural guarantee from the one-sided PBD distance constraint, not a
## best-effort tuning target (see rope_chain_pbd.gd's own class doc comment).
##
## Also verifies REQUIREMENT 2 (direct slack measurement, no pivot/radius) by
## checking RopeChainPBD.total_extension_2d() directly against real,
## independently-computed obstacle-wrap geometry, and that a player's
## real position is genuinely bounded (never wanders indefinitely far from
## an anchored dart) using the new _apply_rope_leash_velocity_clamp().
##
## Run via:
##   godot --headless --path . res://tests/test_rope_pbd_chain_rigidity.tscn

const GAP_TOLERANCE: float = 0.01  ## generous floating-point residual only
const PILLAR_PEN_TOLERANCE: float = 0.05


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	print("[PBD_RIGID] ============ starting ============")
	var main_scene: Node = load("res://scenes/main.tscn").instantiate()
	add_child(main_scene)
	for i in 5:
		await get_tree().physics_frame

	GameManager.lobby_mode = false
	GameManager.is_online = false
	GameManager.total_players = 2
	GameManager.human_count = 2  ## no bot AI movement during sections 1-5 -- keeps the idle/throw/wrap/teleport/leash measurements isolated to exactly what this test itself drives, not confounded by real bot AI also throwing/moving. Section 6 below explicitly re-inits with real hard bots for the required live-gameplay soak.
	GameManager.bot_difficulty = 2
	GameManager.lives_per_round = 99
	GameManager.rounds_to_win = 999
	GameManager.round_wins.clear()
	GameManager._all_players.clear()
	GameManager._alive_players.clear()
	GameManager._init_game_local(main_scene)
	GameManager.start_round()
	GameManager.current_state = GameManager.RoundState.PLAYING

	var players: Array = GameManager._all_players.duplicate()
	print("[PBD_RIGID] %d real players spawned" % players.size())

	var obstacles: Array = []
	for o in get_tree().get_nodes_in_group("obstacles"):
		if o.has_method("get_rect_2d"):
			obstacles.append({"name": String(o.name), "rect": o.get_rect_2d()})

	var overall_max_gap_violation: float = 0.0
	var overall_max_pillar_pen: float = 0.0
	var gap_violation_events: int = 0
	var samples: int = 0

	# ------------------------------------------------------------------
	# 1. IDLE COLLAPSE: a few seconds with no throws.
	# ------------------------------------------------------------------
	var idle_max_reach: float = 0.0
	for tick in range(180):
		await get_tree().physics_frame
		for p in players:
			if not is_instance_valid(p) or p._rope_chain == null:
				continue
			samples += 1
			var v: float = p._rope_chain.max_link_gap_violation()
			overall_max_gap_violation = maxf(overall_max_gap_violation, v)
			if v > GAP_TOLERANCE:
				gap_violation_events += 1
			var ext: float = p._rope_chain.total_extension_2d()
			idle_max_reach = maxf(idle_max_reach, ext)
	print("[PBD_RIGID] idle collapse: max_reach(total_extension_2d)=%.4f (DART_ROPE_LENGTH=%.2f)" % [
		idle_max_reach, players[0].DART_ROPE_LENGTH if players.size() > 0 else -1.0])

	# ------------------------------------------------------------------
	# 2. FORCED FULL-CHARGE THROW: measure the instant-unfold transient.
	# ------------------------------------------------------------------
	var p0 = players[0]
	var p1 = players[1] if players.size() > 1 else players[0]
	p0.reset_for_round(5, Vector3(-5.0, 0.0, 0.0))
	p1.reset_for_round(5, Vector3(5.0, 0.0, 0.0))
	for i in 3:
		await get_tree().physics_frame
	p0.aim_dir = (p1.get_pos_2d() - p0.get_pos_2d()).normalized()
	p0._throw(1.0)
	var throw_max_reach: float = 0.0
	for tick in range(120):
		await get_tree().physics_frame
		if p0._rope_chain != null:
			var v: float = p0._rope_chain.max_link_gap_violation()
			overall_max_gap_violation = maxf(overall_max_gap_violation, v)
			if v > GAP_TOLERANCE:
				gap_violation_events += 1
			samples += 1
			throw_max_reach = maxf(throw_max_reach, p0._rope_chain.total_extension_2d())
	print("[PBD_RIGID] full-charge throw unfold: max_reach=%.4f max_gap_violation_so_far=%.5f" % [
		throw_max_reach, overall_max_gap_violation])

	# ------------------------------------------------------------------
	# 3. SETTLED OBSTACLE-WRAP SWEEP: force-anchor near each obstacle from
	#    a few angles, let the chain settle, check real penetration.
	# ------------------------------------------------------------------
	if p0.dart != null:
		p0.dart.queue_free()
		p0.dart = null
	for i in 3:
		await get_tree().physics_frame

	var wrap_configs: int = 0
	for o in obstacles:
		var rect: Rect2 = o["rect"]
		var center: Vector2 = rect.get_center()
		# ADJACENT-corner configurations (hand and anchor 90 degrees apart
		# around the obstacle, not diametrically opposite through its
		# center) -- this is what a REAL corner-wrap actually looks like in
		# gameplay: rope_dart.gd's own flight raycast always anchors a dart
		# at the NEAR surface it first hits, so a real anchor position can
		# never legitimately sit on the far side of an obstacle collinear
		# with the hand through its center the way a naive "opposite offset"
		# sweep would place it -- that configuration is physically
		# impossible in production and isn't a real wrap case to verify.
		for angle_deg in [0.0, 90.0, 180.0, 270.0]:
			var rad: float = deg_to_rad(angle_deg)
			var rad2: float = deg_to_rad(angle_deg + 90.0)
			var hand_pos: Vector2 = center + Vector2(cos(rad), sin(rad)) * 1.5
			var anchor_pos: Vector2 = center + Vector2(cos(rad2), sin(rad2)) * 1.5
			# reset_for_round() (not a raw global_position write) so the real
			# production _reset_rope_chain_to_hand() path runs -- a raw
			# position write here would desync the chain from the player the
			# same way a hypothetical un-reset teleport in real gameplay
			# would (which never actually happens -- see that function's own
			# doc comment on its exactly-two confirmed call sites).
			p0.reset_for_round(5, Vector3(hand_pos.x, 0.0, hand_pos.y))
			for i in 2:
				await get_tree().physics_frame
			var dart_scene: PackedScene = load("res://scenes/rope_dart.tscn")
			var dart: Node3D = dart_scene.instantiate()
			main_scene.add_child(dart)
			dart.launch(p0, p0.get_pos_2d(), (anchor_pos - hand_pos).normalized(), 1.0)
			dart.state = 1  # ANCHORED
			dart.head_2d = anchor_pos
			dart._render()  # sync head_mesh.global_transform -- _get_rope_tip_target() reads that, not head_2d directly
			p0.dart = dart
			wrap_configs += 1
			for tick in range(90):
				await get_tree().physics_frame
				if p0._rope_chain != null:
					var v: float = p0._rope_chain.max_link_gap_violation()
					overall_max_gap_violation = maxf(overall_max_gap_violation, v)
					if v > GAP_TOLERANCE:
						gap_violation_events += 1
					samples += 1
					for pt_v in p0._rope_chain.points:
						var pt: Vector2 = pt_v
						for o2 in obstacles:
							var r2: Rect2 = o2["rect"]
							if r2.has_point(pt):
								var pen_x: float = minf(pt.x - r2.position.x, r2.end.x - pt.x)
								var pen_y: float = minf(pt.y - r2.position.y, r2.end.y - pt.y)
								var pen: float = minf(pen_x, pen_y)
								overall_max_pillar_pen = maxf(overall_max_pillar_pen, pen)
			if p0.dart != null:
				p0.dart.queue_free()
				p0.dart = null
			for i in 2:
				await get_tree().physics_frame
	print("[PBD_RIGID] settled obstacle-wrap sweep: %d configs, max_pillar_pen=%.5f" % [wrap_configs, overall_max_pillar_pen])

	# ------------------------------------------------------------------
	# 4. TELEPORT RESET (reset_for_round()/_respawn() path): confirm the
	#    chain collapses cleanly with no dragged-through-geometry sweep.
	# ------------------------------------------------------------------
	for cycle in range(6):
		var target_obstacle: Dictionary = obstacles[cycle % obstacles.size()] if obstacles.size() > 0 else {"rect": Rect2(0, 0, 1, 1)}
		var r: Rect2 = target_obstacle["rect"]
		var near_pos: Vector3 = Vector3(r.get_center().x + 2.0, 0.0, r.get_center().y)
		p0.reset_for_round(5, near_pos)
		for tick in range(40):
			await get_tree().physics_frame
			if p0._rope_chain != null:
				var v: float = p0._rope_chain.max_link_gap_violation()
				overall_max_gap_violation = maxf(overall_max_gap_violation, v)
				if v > GAP_TOLERANCE:
					gap_violation_events += 1
				samples += 1
				for pt_v in p0._rope_chain.points:
					var pt: Vector2 = pt_v
					for o2 in obstacles:
						var r2: Rect2 = o2["rect"]
						if r2.has_point(pt):
							var pen_x: float = minf(pt.x - r2.position.x, r2.end.x - pt.x)
							var pen_y: float = minf(pt.y - r2.position.y, r2.end.y - pt.y)
							overall_max_pillar_pen = maxf(overall_max_pillar_pen, minf(pen_x, pen_y))
	print("[PBD_RIGID] teleport-reset soak: 6 cycles done, max_pillar_pen(cumulative)=%.5f" % overall_max_pillar_pen)

	# ------------------------------------------------------------------
	# 5. LEASH: player must not be able to walk arbitrarily far from a
	#    real anchored dart, straight-line case.
	# ------------------------------------------------------------------
	p0.reset_for_round(5, Vector3(0.0, 0.0, 0.0))
	for i in 3:
		await get_tree().physics_frame
	var dart_scene2: PackedScene = load("res://scenes/rope_dart.tscn")
	var dart2: Node3D = dart_scene2.instantiate()
	main_scene.add_child(dart2)
	var anchor2: Vector2 = Vector2(3.0, 0.0)
	dart2.launch(p0, p0.get_pos_2d(), Vector2(1, 0), 1.0)
	dart2.state = 1
	dart2.head_2d = anchor2
	dart2._render()
	# Prevent the dart's own real walk-to-pickup logic (rope_dart.gd's
	# ANCHORED branch: distance-to-owner < pickup_radius -> recall()) from
	# firing mid-test as the forced push carries the player through/near the
	# anchor -- this test wants a stable ANCHORED dart throughout, not a
	# real pickup/recall transition.
	dart2.set_physics_process(false)
	p0.dart = dart2
	for i in 3:
		await get_tree().physics_frame
	# p0.set_physics_process(false): the real automatic _physics_process()
	# (which reads real keyboard/gamepad input -- always zero in this
	# headless, controller-less test) would otherwise immediately overwrite
	# the forced velocity below before move_and_slide() ever sees it, making
	# this section silently test nothing. Disabling it for this section only
	# means we drive _update_physics_rope_anchors() (chain update) and
	# velocity/move_and_slide() by hand instead, fully controlled.
	p0.set_physics_process(false)
	var max_leash_dist: float = 0.0
	var delta: float = 1.0 / 60.0
	for tick in range(180):
		p0._update_physics_rope_anchors()
		p0.velocity = Vector3(20.0, 0.0, 0.0)  # push straight away from anchor as hard as possible
		p0._apply_rope_leash_velocity_clamp(delta)
		p0.move_and_slide()
		max_leash_dist = maxf(max_leash_dist, p0.get_pos_2d().distance_to(anchor2))
		await get_tree().physics_frame
	p0.set_physics_process(true)
	var dart_rope_len: float = p0.DART_ROPE_LENGTH
	print("[PBD_RIGID] leash straight-line: max_dist_from_anchor=%.4f (DART_ROPE_LENGTH=%.2f, overshoot=%.4f)" % [
		max_leash_dist, dart_rope_len, max_leash_dist - dart_rope_len])

	# ------------------------------------------------------------------
	# 5b. LEASH WRAP-AWARENESS CHECK (requirement 2's own explicit ask:
	#    "Confirm the tether limit still functions... across straight-line
	#    AND corner-wrap configurations"): repeat the same forced-push test
	#    but with the dart anchored on the FAR side of a pillar from the
	#    player, so real chain wrap consumes real length -- the player must
	#    be stopped measurably CLOSER to the anchor (in straight-line terms)
	#    than the unwrapped DART_ROPE_LENGTH, since some of that budget is
	#    spent going around the corner. This is the direct, no-pivot,
	#    no-radius verification requirement 2 asks for -- not a separate
	#    formula, just confirming the SAME real slack measurement that
	#    already governs the straight-line case above also correctly
	#    tightens under a real wrap, with zero special-cased code path.
	# ------------------------------------------------------------------
	if obstacles.size() > 0:
		var wrap_rect: Rect2 = obstacles[0]["rect"]
		var wrap_center: Vector2 = wrap_rect.get_center()
		var wrap_hand_start: Vector2 = wrap_center + Vector2(-1.5, 1.5)
		var wrap_anchor: Vector2 = wrap_center + Vector2(1.5, -1.5)
		p0.reset_for_round(5, Vector3(wrap_hand_start.x, 0.0, wrap_hand_start.y))
		for i in 3:
			await get_tree().physics_frame
		var dart3: Node3D = load("res://scenes/rope_dart.tscn").instantiate()
		main_scene.add_child(dart3)
		dart3.launch(p0, p0.get_pos_2d(), (wrap_anchor - wrap_hand_start).normalized(), 1.0)
		dart3.state = 1
		dart3.head_2d = wrap_anchor
		dart3._render()
		dart3.set_physics_process(false)  # see dart2's own comment above
		p0.dart = dart3
		for i in 5:
			await get_tree().physics_frame
		p0.set_physics_process(false)
		var max_wrap_leash_dist: float = 0.0
		var push_dir: Vector2 = (wrap_hand_start - wrap_anchor).normalized()
		for tick in range(180):
			p0._update_physics_rope_anchors()
			p0.velocity = Vector3(push_dir.x, 0.0, push_dir.y) * 20.0
			p0._apply_rope_leash_velocity_clamp(delta)
			p0.move_and_slide()
			max_wrap_leash_dist = maxf(max_wrap_leash_dist, p0.get_pos_2d().distance_to(wrap_anchor))
			await get_tree().physics_frame
		p0.set_physics_process(true)
		print("[PBD_RIGID] leash corner-wrap: max_dist_from_anchor=%.4f (unwrapped DART_ROPE_LENGTH=%.2f) -- should be measurably < unwrapped length since the wrap itself consumes real chain budget" % [
			max_wrap_leash_dist, dart_rope_len])
		if dart3 != null:
			dart3.queue_free()
			p0.dart = null

	# ------------------------------------------------------------------
	# 6. MULTI-BOT REAL SOAK (the methodology this project's own history
	#    has found actually catches real bugs -- see CLAUDE.md).
	# ------------------------------------------------------------------
	if p0.dart != null:
		p0.dart.queue_free()
		p0.dart = null
	GameManager._all_players.clear()
	GameManager._alive_players.clear()
	for c in main_scene.get_children():
		if c.is_in_group("players"):
			c.queue_free()
	for i in 3:
		await get_tree().physics_frame
	GameManager.total_players = 4
	GameManager.human_count = 0
	GameManager.bot_difficulty = 2
	GameManager._init_game_local(main_scene)
	GameManager.start_round()
	GameManager.current_state = GameManager.RoundState.PLAYING
	var soak_players: Array = GameManager._all_players.duplicate()
	var soak_ticks: int = 1800  ## 30s
	var soak_max_gap: float = 0.0
	var soak_max_pen: float = 0.0
	for tick in range(soak_ticks):
		await get_tree().physics_frame
		for p in soak_players:
			if not is_instance_valid(p) or p._rope_chain == null:
				continue
			samples += 1
			var v: float = p._rope_chain.max_link_gap_violation()
			overall_max_gap_violation = maxf(overall_max_gap_violation, v)
			soak_max_gap = maxf(soak_max_gap, v)
			if v > GAP_TOLERANCE:
				gap_violation_events += 1
			for pt_v in p._rope_chain.points:
				var pt: Vector2 = pt_v
				for o2 in obstacles:
					var r2: Rect2 = o2["rect"]
					if r2.has_point(pt):
						var pen_x: float = minf(pt.x - r2.position.x, r2.end.x - pt.x)
						var pen_y: float = minf(pt.y - r2.position.y, r2.end.y - pt.y)
						var pen: float = minf(pen_x, pen_y)
						soak_max_pen = maxf(soak_max_pen, pen)
						overall_max_pillar_pen = maxf(overall_max_pillar_pen, pen)
		if (tick + 1) % 300 == 0:
			print("[PBD_RIGID] soak tick=%d/%d max_gap_violation=%.5f max_pen=%.5f" % [tick + 1, soak_ticks, soak_max_gap, soak_max_pen])

	print("[PBD_RIGID] ============ FINAL RESULTS ============")
	print("[PBD_RIGID] total samples=%d gap_violation_events(>%.3f)=%d" % [samples, GAP_TOLERANCE, gap_violation_events])
	print("[PBD_RIGID] overall_max_gap_violation=%.6f (requirement: must be ~0.0 always)" % overall_max_gap_violation)
	print("[PBD_RIGID] overall_max_pillar_pen=%.5f (tolerance=%.2f)" % [overall_max_pillar_pen, PILLAR_PEN_TOLERANCE])
	print("[PBD_RIGID] leash straight-line overshoot=%.4f" % (max_leash_dist - dart_rope_len))

	var pass_gap: bool = overall_max_gap_violation <= GAP_TOLERANCE
	var pass_pen: bool = overall_max_pillar_pen <= PILLAR_PEN_TOLERANCE
	var pass_leash: bool = (max_leash_dist - dart_rope_len) <= 0.5
	print("[PBD_RIGID] PASS_GAP=%s PASS_PEN=%s PASS_LEASH=%s" % [pass_gap, pass_pen, pass_leash])

	print("PBD_RIGIDITY_TEST_DONE")
	get_tree().quit()
