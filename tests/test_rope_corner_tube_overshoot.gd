extends Node
## Regression test for the "rope arcs through the pillar during a tight
## circle around its near corner" bug (real user screen recording,
## frame-extracted and reviewed directly: character circles CLOSE around a
## pillar's near corner -- not pushing outward at max leash, the trigger for
## the already-fixed ROUND 6 fold bug -- and the rope's rendered curve dips
## through the pillar's solid base for a couple of frames mid-sweep, then
## reads correctly again once past the corner).
##
## This is deliberately a DIFFERENT scenario from
## tests/test_rope_leash_corner_wrap.gd: that test drives the player OUTWARD
## + tangentially, deliberately stressing the chain past its own physical
## capacity near max leash range. This test keeps the player CLOSE to the
## pillar (small, roughly constant radius from the corner) and purely
## tangential (no outward push), well under max leash the whole time --
## isolating whether a tight corner sweep alone (independent of leash
## tension) can still produce visible clipping.
##
## Measures TWO separate things every sampled tick, to distinguish a real
## physics-chain regression from a render-only artifact:
##   - max_pen_raw: real RigidBody3D segment positions vs PillarA's own
##     get_rect_2d() -- the ROUND 5 regression metric, should stay ~0.
##   - max_pen_curve: the exact same Catmull-Rom curve
##     _update_rope_tube_mesh()/_build_tube_mesh() samples through
##     [hand, ...segments, tip] (duplicated here point-for-point, same
##     ROPE_TUBE_CURVE_SAMPLES=48 step count) vs the same rect -- if this is
##     meaningfully worse than max_pen_raw, the raw physics chain is already
##     correct and the bug is in the render-side spline overshooting past its
##     own real control points at a sharp corner bend, not a physics
##     regression.
##
## Run this scene directly (F6 in the editor, or via the Godot MCP
## run_project tool with scene=res://tests/test_rope_corner_tube_overshoot.tscn).
##
## HARNESS NOTE (root-caused and fixed during this test's own development,
## kept here so a future editor doesn't reintroduce it): an earlier version
## of this test called _clamp_to_rope_leash() during the short post-reset
## settle window below, and intermittently (~half of runs) got yanked far
## from the intended tight orbit before the sweep even started -- root
## cause: _rope_chain_rest_length_2d() reads the chain's first dynamic
## segment's REAL position, which doesn't teleport when this test resets
## player.global_position directly; acting on that stale reading via the
## leash clamp during the catch-up window produced a large, wrong
## reposition. Fixed by NOT calling _clamp_to_rope_leash() during that
## specific catch-up window (see its own comment below) -- the clamp is
## still exercised normally, every tick, once the sweep begins.

const SETTLE_WAIT_TICKS: int = 90  ## let the freshly-thrown chain settle/wrap
## before starting the adversarial sweep, same reasoning as
## test_rope_leash_corner_wrap.gd's own settle phase -- keeps the already-
## accepted "first ticks after a throw" unspool transient out of this test's
## own measurement window.
const SWEEP_TICKS: int = 180  ## ~3s at 60Hz
const MOVE_SPEED: float = 4.0  ## a deliberately SLOWER, tighter circle than
## test_rope_leash_corner_wrap.gd's MOVE_SPEED=6.0 -- mimics an ordinary
## careful walk around a corner, not a fast dash.
const SAMPLE_EVERY: int = 3
const ROPE_TUBE_CURVE_SAMPLES: int = 48  ## mirrors player.gd's own const by
## hand -- same established convention as this codebase's other hand-synced
## duplicated constants (see e.g. player.gd's DART_STATE_ANCHORED comment).


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	var main_scene: Node = load("res://scenes/main.tscn").instantiate()
	add_child(main_scene)
	for i in 5:
		await get_tree().physics_frame

	var pillar: Node = main_scene.get_node("PillarA")
	var rect: Rect2 = pillar.get_rect_2d()
	print("[TEST] PillarA rect=%s (world XZ)" % [rect])

	GameManager.current_state = GameManager.RoundState.PLAYING

	var player_scene: PackedScene = load("res://scenes/player.tscn")
	var player = player_scene.instantiate()
	add_child(player)

	# near_corner is the pillar's southwest corner -- the specific corner
	# doesn't matter (any convex corner reproduces the same geometry), what
	# matters is a TIGHT exterior sweep around it while the dart is anchored
	# on the far side, forcing the straight hand-to-tip line's relationship
	# to the corner to change continuously through the sweep.
	var near_corner: Vector2 = rect.position
	var far_corner: Vector2 = rect.end
	# Start close to the west face -- 0.7 units of clearance from the corner
	# vertex (player capsule radius is 0.4, see player.tscn's PlayerShape --
	# leaves a real but tight gap, not clipping the pillar itself), roughly
	# level with the corner so the sweep begins right at the edge of the
	# exterior quadrant.
	var start_radius: float = 0.75
	player.global_position = Vector3(near_corner.x - start_radius, GameManager.PLAYER_HALF_HEIGHT, near_corner.y + 0.05)
	player.spawn_pos = player.global_position
	# Aim AWAY from the pillar for the initial throw (matching
	# test_rope_obstacle_clip.gd/test_rope_leash_corner_wrap.gd's own
	# convention) -- the player starts right next to the pillar's west face,
	# so aiming toward it would anchor the dart almost instantly, within
	# pickup_radius of the player's own hand, silently auto-recalling and
	# picking it back up before this test ever gets a chance to force-place
	# it on the far side below.
	player.aim_dir = Vector2(-1, -1).normalized()
	for i in 5:
		await get_tree().physics_frame

	player._throw(0.0)
	for i in 5:
		await get_tree().physics_frame
	if player.dart == null:
		print("[TEST] FAIL: throw produced no dart")
		return

	# Force ANCHORED on the far side, well within DART_ROPE_LENGTH (8.0) of
	# the player's starting position -- unlike test_rope_leash_corner_wrap.gd,
	# this test deliberately does NOT stress max leash range; the anchor sits
	# comfortably inside reach the whole sweep, isolating the tight-corner
	# geometry as the only variable.
	player.dart.state = 1  # State.ANCHORED (see rope_dart.gd's enum)
	var anchor: Vector2 = far_corner + Vector2(1.0, 1.0)
	player.dart.head_2d = anchor
	print("[TEST] hand=%s anchor=%s beeline_dist=%.2f (DART_ROPE_LENGTH=8.0)" % [
		player.get_pos_2d(), anchor, player.get_pos_2d().distance_to(anchor)])

	for tick in range(SETTLE_WAIT_TICKS):
		player.velocity = Vector3.ZERO
		player._update_physics_rope_anchors()
		player.move_and_slide()
		player._clamp_to_rope_leash()
		await get_tree().physics_frame

	# _clamp_to_rope_leash()'s wrap-aware bound (see player.gd, ROUND 6) reads
	# _rope_chain_rest_length_2d(anchor) from the REAL segment positions --
	# right after the hard head_2d teleport above, the chain hasn't caught up
	# to the new (far) anchor yet, so that reading is transiently inflated,
	# which can itself yank the player to an unintended position during the
	# early part of settle (a real, disclosed side effect of this test
	# harness's own instantaneous state-override shortcut -- see
	# test_rope_obstacle_clip.gd/test_rope_leash_corner_wrap.gd's own use of
	# the same shortcut -- NOT something a real continuous throw trajectory
	# would ever produce, since head_2d only ever moves by travel_speed*delta
	# per tick there). By now (SETTLE_WAIT_TICKS later) the chain has long
	# since converged to the real anchor (established convergence window is
	# ~10-20 ticks per this codebase's own prior rounds), so re-placing the
	# player at the INTENDED tight-orbit start point here, after settle, is
	# safe and won't be immediately re-yanked -- this is what actually
	# isolates "tight circling near a corner" from "large teleport settling,"
	# which are two different phenomena this test does not want to conflate.
	player.global_position = Vector3(near_corner.x - start_radius, GameManager.PLAYER_HALF_HEIGHT, near_corner.y + 0.05)
	player.velocity = Vector3.ZERO
	player.move_and_slide()
	print("[TEST] post-settle reset: player=%s (chain should already be converged to the real anchor)" % [player.get_pos_2d()])

	# Short SECOND settle window, stationary, right after the hard position
	# reset above -- see this file's own "KNOWN RUN-TO-RUN FLAKINESS" doc
	# comment: _clamp_to_rope_leash()'s wrap-aware bound reads
	# _rope_chain_rest_length_2d() from the chain's first dynamic segment,
	# which doesn't teleport with global_position -- it can take a few ticks
	# to physically catch up to this test's own instantaneous reset. Reading
	# a stale rest_len during that window and ACTING on it (repositioning the
	# player via _clamp_to_rope_leash()) is exactly what was measured to yank
	# the player far from the intended orbit before the sweep even starts
	# (confirmed directly: the very first tick's own "post-reset settle done"
	# print already showed the runaway position, i.e. it happens within this
	# catch-up window itself, not gradually during the sweep). Deliberately
	# does NOT call _clamp_to_rope_leash() here -- this window's only job is
	# to let the PHYSICS CHAIN (segments/anchors) catch up to the
	# already-valid, already-reset player position, not to let the clamp
	# reposition the player again while its own input (rest_len) is still
	# transiently wrong. The clamp is unconditionally part of real gameplay's
	# _physics_process() every tick once the sweep begins below, so this is
	# not skipping a mechanic the fix depends on -- only deferring its FIRST
	# application until the chain has real state to read.
	const POST_RESET_SETTLE_TICKS: int = 20
	for i in POST_RESET_SETTLE_TICKS:
		player.velocity = Vector3.ZERO
		player._update_physics_rope_anchors()
		player.move_and_slide()
		await get_tree().physics_frame
	print("[TEST] post-reset settle done: player=%s" % [player.get_pos_2d()])

	# --- Tight, roughly-constant-radius sweep around near_corner, PURELY
	# tangential (no outward push) -- deliberately different from
	# test_rope_leash_corner_wrap.gd's outward+tangential max-leash stress.
	# Capped by ACCUMULATED SWEPT ANGLE (MAX_SWEEP_RAD), not a fixed tick
	# count -- a fixed tick budget at this tight a radius would sweep several
	# full loops around the whole pillar (angular speed = MOVE_SPEED/radius
	# is large at a small radius), wandering past the near corner into the
	# far corner/anchor's own vicinity and conflating this test's "ordinary
	# tight walk past one corner" scenario with an unrelated close-to-anchor
	# case. ~150 degrees is enough to sweep fully past one corner (from one
	# face, through the corner, onto the next face) and stop.
	const MAX_SWEEP_RAD: float = 2.6  # ~150 degrees
	var max_pen_raw: float = 0.0
	var max_pen_curve: float = 0.0
	var max_pen_curve_fixed: float = 0.0
	var worst_raw_tick: int = -1
	var worst_curve_tick: int = -1
	var swept_angle: float = 0.0
	var prev_angle: float = (player.get_pos_2d() - near_corner).angle()

	var tick: int = 0
	while swept_angle < MAX_SWEEP_RAD and tick < SWEEP_TICKS:
		var pos: Vector2 = player.get_pos_2d()
		var to_center: Vector2 = pos - near_corner
		var tangent: Vector2 = Vector2(-to_center.y, to_center.x).normalized() if to_center.length() > 0.01 else Vector2(1, 0)
		player.velocity = Vector3(tangent.x, 0.0, tangent.y) * MOVE_SPEED

		player._update_physics_rope_anchors()
		player.move_and_slide()
		player._clamp_to_rope_leash()
		await get_tree().physics_frame

		var cur_angle: float = (player.get_pos_2d() - near_corner).angle()
		swept_angle += absf(wrapf(cur_angle - prev_angle, -PI, PI))
		prev_angle = cur_angle
		tick += 1

		if tick % SAMPLE_EVERY != 0:
			continue

		var hand_pos: Vector3 = player._get_rope_hand_anchor_pos()
		var tip_pos: Vector3 = player._get_rope_tip_target()
		var control_points: Array[Vector3] = [hand_pos]
		var pen_raw: float = 0.0
		for seg in player._physics_rope_segments:
			var p3: Vector3 = (seg as RigidBody3D).global_position
			var p2 := Vector2(p3.x, p3.z)
			control_points.append(p3)
			if rect.has_point(p2):
				var pen: float = minf(p2.x - rect.position.x, rect.end.x - p2.x)
				pen = minf(pen, minf(p2.y - rect.position.y, rect.end.y - p2.y))
				pen_raw = maxf(pen_raw, pen)
		control_points.append(tip_pos)

		# UNCLAMPED: exact mirror of the raw Catmull-Rom sampling math, no
		# obstacle awareness -- this is what the render used to do,
		# unconditionally, before the corner-cutting fix. Kept as a permanent
		# diagnostic so a future regression that reintroduces the raw
		# overshoot (e.g. bypassing the fix, or a change to
		# ROPE_TUBE_OBSTACLE_MARGIN large enough to defeat it) is still
		# visible here even if the FIXED metric below looks fine. This one
		# still IS a local reimplementation (deliberately, since the real
		# code no longer has an "unclamped" code path to call into once the
		# fix shipped) -- kept minimal and side-by-side with the real fixed
		# path below for direct comparison.
		var curve_unclamped: Array[Vector2] = _sample_catmull_rom_2d_unclamped(control_points, ROPE_TUBE_CURVE_SAMPLES)
		var pen_curve_unclamped: float = 0.0
		for p2u in curve_unclamped:
			if rect.has_point(p2u):
				var penu: float = minf(p2u.x - rect.position.x, rect.end.x - p2u.x)
				penu = minf(penu, minf(p2u.y - rect.position.y, rect.end.y - p2u.y))
				pen_curve_unclamped = maxf(pen_curve_unclamped, penu)

		# FIXED: calls player._compute_rope_tube_curve_points() directly --
		# the EXACT real function _update_rope_tube_mesh() itself calls every
		# frame -- so this measures the actual shipped code path, not a
		# second hand-written reimplementation that could silently drift
		# from what's really running.
		var curve_fixed_3d: Array = player._compute_rope_tube_curve_points(control_points)
		var pen_curve_fixed: float = 0.0
		for p3f in curve_fixed_3d:
			var p2f := Vector2((p3f as Vector3).x, (p3f as Vector3).z)
			if rect.has_point(p2f):
				var penf: float = minf(p2f.x - rect.position.x, rect.end.x - p2f.x)
				penf = minf(penf, minf(p2f.y - rect.position.y, rect.end.y - p2f.y))
				pen_curve_fixed = maxf(pen_curve_fixed, penf)

		if pen_raw > max_pen_raw:
			max_pen_raw = pen_raw
			worst_raw_tick = tick
		if pen_curve_unclamped > max_pen_curve:
			max_pen_curve = pen_curve_unclamped
			worst_curve_tick = tick
		max_pen_curve_fixed = maxf(max_pen_curve_fixed, pen_curve_fixed)

		print("[TEST] tick=%d player=%s pen_raw=%.3f pen_curve_unclamped=%.3f pen_curve_fixed=%.3f" % [
			tick, player.get_pos_2d(), pen_raw, pen_curve_unclamped, pen_curve_fixed])

	print("[TEST] RESULT max_pen_raw=%.4f (tick=%d) max_pen_curve_unclamped=%.4f (tick=%d) max_pen_curve_fixed=%.4f" % [
		max_pen_raw, worst_raw_tick, max_pen_curve, worst_curve_tick, max_pen_curve_fixed])
	if max_pen_raw > 0.01:
		print("[TEST] raw physics chain DID penetrate the pillar -- real physics-level regression, not render-only")
	else:
		print("[TEST] raw physics chain stayed clear of the pillar (as expected per ROUND 5)")
	if max_pen_curve > max_pen_raw + 0.05:
		print("[TEST] UNCLAMPED curve penetrates meaningfully more than raw control points -- confirms the render-side Catmull-Rom overshoot bug")
	else:
		print("[TEST] UNCLAMPED curve tracked raw control points closely -- did not reproduce the overshoot this run")
	if max_pen_curve_fixed > 0.01:
		print("[TEST] FAIL: FIXED curve still penetrates the pillar (max=%.4f) -- corner-cutting fix did not close the gap" % [max_pen_curve_fixed])
	else:
		print("[TEST] PASS: FIXED curve never penetrates the pillar")
	print("CORNER_TUBE_OVERSHOOT_TEST_DONE")


func _sample_catmull_rom_2d_unclamped(control_points_3d: Array[Vector3], samples: int) -> Array[Vector2]:
	## Bare Catmull-Rom sampling, NO obstacle awareness -- reproduces exactly
	## what _update_rope_tube_mesh() did before the corner-cutting fix, as a
	## permanent side-by-side diagnostic baseline (see this test's own
	## RESULT-line comment). Takes the same Vector3 control points the real
	## code operates on and projects each output sample to 2D (XZ) since this
	## test only ever cares about the footprint vs. the pillar's rect.
	var n: int = control_points_3d.size()
	var curve_points: Array[Vector2] = []
	curve_points.resize(samples + 1)
	for i in range(samples + 1):
		var t: float = float(i) / float(samples)
		var f: float = t * float(n - 1)
		var seg_i: int = clampi(int(f), 0, n - 2)
		var local_t: float = f - float(seg_i)
		var p0: Vector3 = control_points_3d[clampi(seg_i - 1, 0, n - 1)]
		var p1: Vector3 = control_points_3d[seg_i]
		var p2: Vector3 = control_points_3d[clampi(seg_i + 1, 0, n - 1)]
		var p3: Vector3 = control_points_3d[clampi(seg_i + 2, 0, n - 1)]
		var sample: Vector3 = p1.cubic_interpolate(p2, p0, p3, local_t)
		curve_points[i] = Vector2(sample.x, sample.z)
	return curve_points
