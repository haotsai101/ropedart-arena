extends Node
## Regression test for the "rope drew a straight horizontal chord across the
## pillar's face" bug (real user screen recording, frame-cropped and
## reviewed directly): dart anchored above/behind a pillar, character
## standing to its lower-right, and the rendered rope tube appeared to draw a
## straight line right along/across the pillar's near face instead of
## wrapping its near corner.
##
## Root-caused via this test's own repro (a dart force-anchored directly
## opposite the player across a pillar, both ends squarely within the
## pillar's own z-span so the straight hand-to-tip line threads through the
## box's interior near its center) plus direct manual geometry proof: for
## this specific class of configuration -- both bracketing curve points
## squarely facing OPPOSITE edges of the rect (see player.gd's
## _corner_route_waypoints() OPPOSITE-edges branch) -- a single-corner detour
## provably re-enters the rect's interior on its second leg, so
## _corner_route_waypoints()'s existing two-corner "wrap one whole side"
## path is the correct, necessary minimal route, NOT a misfire of the
## ROUND 9 adjacent-vs-opposite edge logic (see
## tests/test_rope_stray_pillar_segment.gd, a materially different diagonal
## near-corner configuration, left unaffected -- re-verified passing after
## this round's change).
##
## The actual, measured defect: that necessary two-corner wrap is a SUSTAINED
## straight run hugging an entire pillar face for several consecutive
## samples -- unlike the brief single-sample nudge
## ROPE_TUBE_OBSTACLE_MARGIN (0.12 at the time) was originally sized for, a
## long dead-straight run at that thin a clearance reads as visually
## touching/cutting across the pillar's face, matching the report, even
## though it stayed numerically outside the real (ungrown) rect. Fixed by
## raising ROPE_TUBE_OBSTACLE_MARGIN to 0.2, matching
## rope_segment_body.gd's own CLAMP_OBSTACLE_MARGIN, so the rendered tube
## never sits closer to a pillar than the real physics-simulated rope
## segments already do.
##
## PASS/FAIL requires BOTH:
##  1. No SUSTAINED discontinuous jump whose own midpoint lands inside the
##     REAL (ungrown) rect -- same jump-vs-midpoint methodology as
##     test_rope_stray_pillar_segment.gd, but checked against the real rect
##     (not the grown one) since that's the only ground truth that actually
##     matters for "does the tube visibly cut through solid geometry."
##  2. Every sampled curve point stays at least MIN_CLEARANCE outside the
##     real rect -- a direct regression guard on the margin fix itself, so a
##     future edit that shrinks ROPE_TUBE_OBSTACLE_MARGIN back down without
##     updating this test is caught here specifically, not just inferred
##     from the jump check.
##
## Run via the Godot MCP run_project tool with
## scene=res://tests/test_rope_pillar_face_chord.tscn.

const SETTLE_WAIT_TICKS: int = 200
const MEASURE_TICKS: int = 180
const JUMP_THRESHOLD: float = 0.6
const MIN_CLEARANCE: float = 0.15  ## a bit under ROPE_TUBE_OBSTACLE_MARGIN
## (0.2) to tolerate ordinary floating point/curve sampling noise, while
## still being comfortably above the pre-fix 0.12 margin -- if this ever
## fails, ROPE_TUBE_OBSTACLE_MARGIN was very likely shrunk back down.


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	var main_scene: Node = load("res://scenes/main.tscn").instantiate()
	add_child(main_scene)
	for i in 5:
		await get_tree().physics_frame

	var pillar_a: Node = main_scene.get_node("PillarA")
	var rect: Rect2 = pillar_a.get_rect_2d()
	print("[TEST] PillarA rect=%s (world XZ)" % [rect])

	var player_scene: PackedScene = load("res://scenes/player.tscn")
	var player = player_scene.instantiate()
	add_child(player)

	# Player due east of the pillar, dart anchored due west -- both roughly
	# level with the pillar's own center z, so the straight hand-to-tip line
	# threads through the box's interior near its center and both
	# bracketing curve points end up squarely facing OPPOSITE edges (the
	# configuration that requires -- and previously visually under-cleared
	# -- a genuine two-corner "wrap one whole side" detour.
	var start_pos := Vector3(-2.0, 0.7, -5.0)
	player.global_position = start_pos
	player.spawn_pos = start_pos
	player.aim_dir = Vector2(-1, 0).normalized()
	for i in 5:
		await get_tree().physics_frame

	player._throw(0.0)
	for i in 5:
		await get_tree().physics_frame
	if player.dart == null:
		print("[TEST] FAIL: throw produced no dart")
		return

	var anchor := Vector2(-9.0, -5.0)
	var beeline: float = Vector2(start_pos.x, start_pos.z).distance_to(anchor)
	player.dart.state = 1  # State.ANCHORED
	player.dart.head_2d = anchor
	print("[TEST] hand=%s anchor=%s beeline_dist=%.2f (DART_ROPE_LENGTH=8.0)" % [
		player.get_pos_2d(), anchor, beeline])

	for i in SETTLE_WAIT_TICKS:
		player.velocity = Vector3.ZERO
		player._update_physics_rope_anchors()
		player.move_and_slide()
		await get_tree().physics_frame
	print("[TEST] settle done, starting steady-state measurement")

	var max_jump_overall: float = 0.0
	var worst_tick: int = -1
	var consecutive_violations: int = 0
	var max_consecutive_violations: int = 0
	var min_clearance_seen: float = 1.0e9
	var min_clearance_tick: int = -1

	for tick in range(MEASURE_TICKS):
		player.velocity = Vector3.ZERO
		player._update_physics_rope_anchors()
		player.move_and_slide()
		await get_tree().physics_frame

		var hand_pos: Vector3 = player._get_rope_hand_anchor_pos()
		var tip_pos: Vector3 = player._get_rope_tip_target()
		var control_points: Array[Vector3] = [hand_pos]
		for seg in player._physics_rope_segments:
			control_points.append((seg as RigidBody3D).global_position)
		control_points.append(tip_pos)

		var curve_points: Array = player._compute_rope_tube_curve_points(control_points)

		# Clearance check (guard #2) -- distance from every sampled point to
		# the REAL (ungrown) rect boundary; 0 or negative would mean the
		# point is literally inside/on the real pillar footprint.
		for cp in curve_points:
			var p2 := Vector2(cp.x, cp.z)
			var dx: float = maxf(rect.position.x - p2.x, p2.x - rect.end.x)
			var dz: float = maxf(rect.position.y - p2.y, p2.y - rect.end.y)
			var outside_dist: float = maxf(dx, dz)  # Chebyshev distance outside an AABB
			if outside_dist < min_clearance_seen:
				min_clearance_seen = outside_dist
				min_clearance_tick = tick

		# Sustained-discontinuity check (guard #1) -- same methodology as
		# test_rope_stray_pillar_segment.gd, but against the REAL rect.
		var max_jump_tick: float = 0.0
		var worst_i: int = -1
		for i in range(curve_points.size() - 1):
			var a: Vector3 = curve_points[i]
			var b: Vector3 = curve_points[i + 1]
			var d: float = Vector2(a.x, a.z).distance_to(Vector2(b.x, b.z))
			if d <= JUMP_THRESHOLD:
				continue
			var mid2 := Vector2((a.x + b.x) * 0.5, (a.z + b.z) * 0.5)
			if not rect.has_point(mid2):
				continue  # long but valid stretch (e.g. a real full-side wrap), not a defect
			if d > max_jump_tick:
				max_jump_tick = d
				worst_i = i
		if max_jump_tick > max_jump_overall:
			max_jump_overall = max_jump_tick
			worst_tick = tick
		if max_jump_tick > JUMP_THRESHOLD:
			consecutive_violations += 1
			max_consecutive_violations = maxi(max_consecutive_violations, consecutive_violations)
			var a2: Vector3 = curve_points[worst_i]
			var b2: Vector3 = curve_points[worst_i + 1]
			print("[TEST] !! tick=%d SUSPICIOUS JUMP idx=%d->%d dist=%.3f a=(%.2f,%.2f) b=(%.2f,%.2f)" % [
				tick, worst_i, worst_i + 1, max_jump_tick, a2.x, a2.z, b2.x, b2.z])
		else:
			consecutive_violations = 0

	print("[TEST] RESULT max_jump_overall=%.4f (tick=%d) threshold=%.2f max_consecutive_violations=%d" % [
		max_jump_overall, worst_tick, JUMP_THRESHOLD, max_consecutive_violations])
	print("[TEST] RESULT min_clearance_seen=%.4f (tick=%d) required>=%.2f" % [
		min_clearance_seen, min_clearance_tick, MIN_CLEARANCE])

	var jump_ok: bool = max_consecutive_violations < 2
	var clearance_ok: bool = min_clearance_seen >= MIN_CLEARANCE
	if jump_ok and clearance_ok:
		print("[TEST] PASS: no sustained disconnected chord, and clearance from the real pillar footprint stayed >= %.2f" % MIN_CLEARANCE)
	else:
		if not jump_ok:
			print("[TEST] FAIL: rendered rope curve has a SUSTAINED discontinuous jump through the real pillar footprint")
		if not clearance_ok:
			print("[TEST] FAIL: rendered rope curve came within %.4f of the real pillar footprint (required >= %.2f)" % [min_clearance_seen, MIN_CLEARANCE])
	print("PILLAR_FACE_CHORD_TEST_DONE")
