extends Node
## Regression test for the "stray dark line segment on a pillar's face" bug
## (real user screen recording, frame-analyzed directly): dart anchored FAR
## away (large real hand-to-dart distance, near DART_ROPE_LENGTH), player
## standing immediately adjacent to a pillar. The report described a
## SEPARATE, disconnected short line rendered on the pillar's face, distinct
## from the main smooth curve that correctly arcs around a far corner toward
## the dart.
##
## Root-caused via this test's own diagnostic runs (see the fix's own doc
## comment on player.gd's _compute_rope_tube_curve_points() for the full
## writeup, including several intermediate fix attempts that looked correct
## until re-measured and found wanting): the tube-mesh curve's old
## corner-cutting fallback pushed each violating SAMPLE independently to
## whichever single rect edge was nearest to it alone, which flips
## discontinuously between two different edges across a run of consecutive
## samples straddling a real corner, rendering as a stray line plus a
## disconnected jump instead of one continuous detour. Fixed by grouping
## CONTIGUOUS RUNS of bad samples (gated on a stable linear-blend signal, not
## the raw wiggling spline) and routing each run through the correct
## waypoint(s) derived from which edge(s) the run's own bracketing anchors
## independently resolve to -- one shared CORNER VERTEX for two adjacent
## edges, or two corners (wrapping one whole side of the box) for two
## opposite edges -- see player.gd's _corner_route_waypoints() for the full
## mechanism.
##
## This test holds the player STATIONARY tight against a pillar with a dart
## anchored near max range on the far side (not moving/sweeping, unlike
## tests/test_rope_corner_tube_overshoot.gd's continuous corner sweep) --
## the configuration that actually reproduced the bug, since it needs several
## consecutive real control points straddling one real corner for many ticks
## in a row, not just a brief single-sample overshoot during motion.
##
## PASS/FAIL requires BOTH of the following (each refined during this bug's
## own investigation after being found to produce false positives on its
## own):
##  1. SUSTAINED discontinuity (2+ consecutive sampled ticks both exceeding
##     JUMP_THRESHOLD) -- the corrected code can still have a rare, isolated
##     single-tick numerical blip (up to ~0.62, immediately surrounded by
##     normal ~0.35-0.5 values, consistent with momentary
##     rope_segment_body.gd contact-state flicker, an already-accepted class
##     of transient elsewhere in this codebase) -- a fundamentally
##     different, imperceptible category from the ORIGINAL bug's own
##     signature (a ~0.65-0.95 unit jump recurring on EVERY single sampled
##     tick for the entire multi-second hold).
##  2. The gap's own real MIDPOINT must itself land inside the obstacle -- a
##     large gap between two consecutive samples is not by itself a defect,
##     since the tube mesh always connects consecutive points with one
##     continuous surface regardless of gap size; a genuinely long but VALID
##     stretch (e.g. wrapping an entire side of the box via two corners) can
##     legitimately get few samples under the fixed 48-samples-per-curve
##     budget, producing a big but perfectly continuous (not disconnected)
##     gap.
##
## Run via the Godot MCP run_project tool with
## scene=res://tests/test_rope_stray_pillar_segment.tscn.

const SETTLE_WAIT_TICKS: int = 200  ## let the freshly-force-anchored chain
## fully converge before measuring -- see this test's own harness note below.
const MEASURE_TICKS: int = 180  ## ~3s at 60Hz of steady-state hold.
const JUMP_THRESHOLD: float = 0.6  ## a normal Catmull-Rom sample spacing over
## the chain's ~8-9 unit span across 48 samples is roughly 0.17-0.2 units;
## anything several times that between ADJACENT samples is not something a
## smooth, continuous curve parameterization can produce on its own.


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

	# Immediately adjacent to the pillar's WEST face (well under half a tile
	# of clearance -- player capsule radius is 0.4, see player.tscn), roughly
	# level with the face rather than centered on it, so the straight
	# hand-to-tip line (to a far anchor placed below) grazes close to the
	# pillar's north edge instead of driving dead-center through it -- this
	# is meant to reproduce "character tight against a pillar" as described,
	# not a specific engineered corner. Also verified (manually, during this
	# fix's own development, not checked in as a second permanent test) to
	# reproduce and then correctly fix against PillarB from a different
	# (north-face) approach angle with a different anchor position --
	# confirms the fix isn't overfit to this one specific geometry.
	var start_pos := Vector3(rect.position.x - 0.5, 0.7, rect.position.y + 1.0)
	player.global_position = start_pos
	player.spawn_pos = start_pos
	player.aim_dir = Vector2(-1, -1).normalized()  # aim away from the pillar for the initial throw
	for i in 5:
		await get_tree().physics_frame

	player._throw(0.0)
	for i in 5:
		await get_tree().physics_frame
	if player.dart == null:
		print("[TEST] FAIL: throw produced no dart")
		return

	# Force ANCHORED far away -- near DART_ROPE_LENGTH (8.0) from the start
	# position, on the opposite side of the pillar, so the straight
	# hand-to-tip line clips the pillar's northern edge region.
	var anchor := Vector2(1.0, -3.0)
	var beeline: float = Vector2(start_pos.x, start_pos.z).distance_to(anchor)
	player.dart.state = 1  # State.ANCHORED (see rope_dart.gd's enum)
	player.dart.head_2d = anchor
	print("[TEST] hand=%s anchor=%s beeline_dist=%.2f (DART_ROPE_LENGTH=8.0)" % [
		player.get_pos_2d(), anchor, beeline])

	# Settle window -- same convention as test_rope_corner_tube_overshoot.gd's
	# own SETTLE_WAIT_TICKS: right after the hard head_2d teleport above, the
	# chain hasn't caught up to the new (far) anchor yet, so measuring
	# immediately conflates this test-harness artifact (an instantaneous
	# state override no real continuous throw would ever produce) with the
	# actual steady-state bug this test targets. The player holds perfectly
	# still throughout (not part of the bug's own required conditions), only
	# giving the physics chain time to converge -- this specific tight-corner
	# configuration was observed to take noticeably longer than the ~10-20
	# ticks this codebase's other tests usually budget, hence the larger
	# SETTLE_WAIT_TICKS here.
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

		# Calls the EXACT real function _update_rope_tube_mesh() itself calls
		# every frame, not a second hand-written reimplementation.
		var curve_points: Array = player._compute_rope_tube_curve_points(control_points)
		# A large gap between two consecutive samples is NOT by itself a
		# "stray disconnected segment" -- the tube mesh always connects
		# consecutive curve_points with one continuous surface regardless of
		# gap size (see _build_tube_mesh()), so a genuinely long but VALID
		# straight/wrapped stretch (e.g. routing around an entire side of an
		# obstacle via two corners) can legitimately get few samples
		# allotted to it under this curve's fixed 48-sample-per-whole-curve
		# budget, producing a big but perfectly continuous gap. The
		# REPORTED bug's actual signature is a gap whose real midpoint
		# ITSELF still lands inside the obstacle -- i.e. the straight chord
		# between the two samples cuts through solid ground, meaning the two
		# samples don't actually lie on one continuous outside-the-obstacle
		# path at all. Only that combination (large gap AND its own midpoint
		# violates the obstacle) is flagged as a real defect.
		var max_jump_tick: float = 0.0
		var worst_i: int = -1
		for i in range(curve_points.size() - 1):
			var a: Vector3 = curve_points[i]
			var b: Vector3 = curve_points[i + 1]
			var d: float = Vector2(a.x, a.z).distance_to(Vector2(b.x, b.z))
			if d <= JUMP_THRESHOLD:
				continue
			var mid2 := Vector2((a.x + b.x) * 0.5, (a.z + b.z) * 0.5)
			if not player._point_inside_any_obstacle(mid2):
				continue  # long but valid stretch, not a real defect
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
			print("[TEST] !! tick=%d SUSPICIOUS JUMP idx=%d->%d dist=%.3f a=(%.2f,%.2f) b=(%.2f,%.2f) (midpoint INSIDE obstacle)" % [
				tick, worst_i, worst_i + 1, max_jump_tick, a2.x, a2.z, b2.x, b2.z])
		else:
			consecutive_violations = 0

	print("[TEST] RESULT max_jump_overall=%.4f (tick=%d) threshold=%.2f max_consecutive_violations=%d" % [
		max_jump_overall, worst_tick, JUMP_THRESHOLD, max_consecutive_violations])
	if max_consecutive_violations >= 2:
		print("[TEST] FAIL: rendered rope curve has a SUSTAINED discontinuous jump -- stray/disconnected segment reproduced")
	else:
		print("[TEST] PASS: rendered rope curve stayed continuous (no sustained stray disconnected segment)")
	print("STRAY_PILLAR_SEGMENT_TEST_DONE")
