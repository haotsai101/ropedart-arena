extends Node
## PRIMARY regression test for the ROUND 12 "full architecture reset" of
## player.gd's rope (see CLAUDE.md's dated entry): replaces
## tests/test_rope_visibility_route_sweep.gd, which specifically exercised
## the now-DELETED _visibility_graph_route()/Dijkstra shortest-path function
## on SYNTHETIC control points -- per the coordinator's own explicit
## instruction, that test no longer has anything real to measure once the
## function it tested is gone. This test instead measures the REAL,
## persistent 32-segment physics chain's own settled/live positions directly
## -- since the render is now nothing but a Catmull-Rom curve traced through
## those exact points with no correction of any kind (see
## _compute_rope_tube_curve_points()), this measurement IS the real physics
## behavior, not a proxy for a separate routing function's output.
##
## FOUR things are measured, matching the task's own verification protocol:
##
## 1. IDLE DRIFT (ROUND 22, 2026-07-29 -- renamed from "IDLE COLLAPSE," see
##    below for why the old name/spec no longer applies): with no dart ever
##    thrown and the player never moving, how far does the persistent
##    chain's own tip end drift from the hand?
##
##    ARCHITECTURE CHANGE THIS ROUND, per direct, explicit user requirement:
##    "no damping and folding or coiling. let it be dragged around the
##    character." Every round before this one (see the "OLD BEHAVIOR" note
##    below) kept the tip anchor KINEMATICALLY PINNED to the hand's own
##    position, every tick, while dart == null -- i.e. this section used to
##    test whether that forced pinning actually produced a tight bunch (it
##    did, by construction: two points forced to coincide every frame have
##    nowhere else to be). That forced pinning is exactly the "folding or
##    coiling" the user's own words reject, so ROUND 22 removed it (see
##    player.gd's _make_rope_tip_body()/_update_physics_rope_anchors()): the
##    tip is now UNFROZEN into a real dynamic body while idle, so this
##    section no longer has a "collapse" invariant to assert -- there is no
##    longer any force pulling the tip back toward the hand at all (per
##    ROUND 12's own already-established finding, reaffirmed here: with
##    gravity disabled and no tension/damping source, a free rope end has no
##    physical reason to prefer a compact shape over an extended one).
##
##    WHAT THIS SECTION MEASURES NOW, informationally plus a loose
##    divergence-only bound (IDLE_DRIFT_SANE_BOUND): a real, DISCLOSED,
##    NOT-fully-explained-by-movement finding from this round's own direct
##    measurement -- even with ZERO player movement, the freed tip routinely
##    drifts 4-11+ units from the hand within 1-5 real seconds of becoming
##    idle (observed range across several runs of this test and the
##    dedicated tests/test_rope_idle_drag.gd: 4.46-11.19), i.e. a real,
##    reproducible "whip-crack" release the instant the tip stops being
##    forced to the hand, not a graceful settle-in-place. This is
##    SEPARATE from (and, per direct A/B measurement in the same round, only
##    partially caused by) this round's removal of body damping -- see
##    CLAUDE.md's own ROUND 22 entry for the full A/B numbers (damping
##    restored via a temporary isolation patch still showed 5.56-8.74 in the
##    same scenario, i.e. real but smaller). PASS/FAIL below only catches
##    genuine unbounded divergence (NaN or absurd values), NOT this drift
##    magnitude itself -- there is no known-correct "right" idle drift
##    distance for this architecture, and pretending IDLE_COLLAPSE_RADIUS's
##    old 1.6 tolerance still means something would misrepresent a real,
##    disclosed, and honestly quite possibly undesirable-on-screen behavior
##    as a clean pass. If the user's own next report is "the rope flings
##    itself out for no reason when I'm not moving," THIS is the mechanism,
##    and the fix would need to reconsider whether the tip should really be
##    fully free (vs., e.g., some new deliberately-modest restoring force --
##    which would itself risk re-approaching the "compute where it should
##    be" pattern earlier rounds rejected; not attempted this round, flagged
##    for a future round's own judgment call).
##
## 2. SETTLED-CONFIGURATION SWEEP (the direct replacement for the deleted
##    visibility-graph sweep): force-anchor a dart at many different
##    hand/tip configurations around PillarA -- open air, an adjacent-corner
##    wrap, a diagonal/opposite-corner wrap, an opposite-edges whole-side
##    wrap (the hardest case the old heuristics needed multiple rounds to
##    get right), and several pseudo-random configurations at a fixed seed
##    -- let the REAL chain settle, then measure every dynamic segment's own
##    position directly against PillarA's real (ungrown) get_rect_2d(). Must
##    be non-penetrating in every configuration; this is the whole point of
##    "real collision instead of computed routing."
##
## 3. THROW UNFOLD: log every segment's live distance from the hand at
##    intervals through a real throw, confirming the chain's own reach grows
##    roughly monotonically (no runaway "crack the whip" divergence -- see
##    rope_segment_body.gd's MAX_SEGMENT_SPEED) as the tip anchor pulls away.
##
## 4. RETRIEVE FOLD: same measurement through a real recall, confirming the
##    chain's reach shrinks back down toward the hand (~0) as the dart
##    returns, completing the "collapse -> unfold -> fold -> collapse" cycle
##    the user's spec describes end to end.
##
## Run via the Godot MCP run_project tool with
## scene=res://tests/test_rope_physics_chain_settle.tscn.

const IDLE_SETTLE_TICKS: int = 300  ## 5s -- unchanged tick count from every
## prior round; no longer expected to reach a small/tight "converged"
## configuration as of ROUND 22 (2026-07-29) -- see this file's own header
## comment's "1. IDLE DRIFT" section for the full rewrite.
const IDLE_DRIFT_SANE_BOUND: float = 15.0  ## ROUND 22 (2026-07-29) --
## replaces IDLE_COLLAPSE_RADIUS (was 1.6, asserting a tight bunch near the
## hand -- no longer a real invariant now that the tip is a freely-dragging
## dynamic body while idle, see header comment). This is a LOOSE
## divergence-only catch, set with headroom above the largest real value
## observed across several runs of this exact scenario (4.46-11.19, see
## header comment) -- it exists only to catch genuine unbounded blow-up
## (NaN, or a value like 10x this), not to assert any particular "collapsed"
## shape.

const CONFIG_SETTLE_TICKS: int = 220
const PENETRATION_TOLERANCE: float = 0.001  ## real segments must not enter
## the pillar's own (ungrown) rect at all -- this is the actual physics
## collision guarantee, not a rendered/margin-grown one.

const THROW_LOG_TICKS: int = 40
const THROW_LOG_EVERY: int = 4
const RETRIEVE_LOG_EVERY: int = 6
const RETRIEVE_MAX_TICKS: int = 240
## Separate (looser) tolerance for the POST-RETRIEVE collapse check, deliberately
## different from IDLE_COLLAPSE_RADIUS -- a dedicated long-duration probe (same
## methodology as the one behind IDLE_COLLAPSE_RADIUS, run separately during
## this test's own development, scratch-only) confirmed, via a full-charge
## (ratio=1.0) throw to near max ROPE_LENGTH followed immediately by recall(),
## that the chain converges (avg segment speed decaying to ~0.002, genuinely at
## rest) to a STABLE equilibrium in the ~2.4-3.3 range across repeated runs --
## real, sustained, non-diverging, but noticeably looser than a pristine
## from-spawn idle bundle (~1.35). This is physically expected, not a bug: a
## slack, zero-tension, zero-gravity, non-self-colliding chain has no unique
## global "tightest" equilibrium, and the specific knot/fold topology a real
## throw-then-retrieve cycle leaves it in depends on its own path history, not
## just its current endpoints -- the same reason two different real ropes
## reeled in by hand don't always end up in an identical coil. Given generous
## headroom above the observed range.
##
## ROUND 22 (2026-07-29) UPDATE, disclosed rather than silently re-tuned: with
## damping removed (this round's own "no damping" requirement), a direct
## re-measurement of this exact scenario came back at 5.27 -- a real FAIL
## against this unchanged 4.5 threshold, and during the fold phase leading up
## to it the chain's own max reach transiently ballooned to ~14.8 (see
## CLAUDE.md's ROUND 22 entry for the full trace) before settling back down.
## Left UNCHANGED rather than loosened to paper over this -- a real,
## measured regression from removing damping, not a threshold that needs
## recalibrating to a new "correct" normal.
const POST_RETRIEVE_COLLAPSE_RADIUS: float = 4.5

## 5. ANCHORED STEADY-STATE JITTER (2026-07-26 -- real user report, direct
## frame-by-frame video review by the coordinator: "the rope's rendered curve
## visibly, measurably changes shape near the anchor point from frame to
## frame" while the character stands completely still and the dart has
## already been ANCHORED for several seconds -- a genuinely different
## configuration from every prior probe on this file, which only ever
## measured (a) idle-at-hand collapse (dart == null) or (b) the first ~40
## ticks right after a throw. See this function's own doc comment below for
## the measurement design and the real root-cause finding.
const STEADY_PRE_SETTLE_TICKS: int = 600  ## 10s (was 5s/300 ticks) -- let the
## forced-anchor's own initial settle transient (same one CONFIG_SETTLE_TICKS
## above already exists to wait out) fully decay before the jitter
## measurement window starts, so residual unfold motion is never mistaken for
## steady-state jitter. Raised 300->600 (2026-07-26, direct-contact jitter
## investigation) after the new "near_corner_slack_bunch" config (short real
## span, ~5 units of slack that has to fold up right at a real corner
## contact) measured a real, one-time large hand/seg step (hand_max_step
## 0.223, seg_max_step 0.096) landing WITHIN the first ~60 ticks of the
## sampling window at the old 300-tick pre-settle -- i.e. that config's own
## initial-unfurl transient (a materially harder fold than the other 3
## configs, which all measured cleanly settled well before 300 ticks) hadn't
## fully decayed yet, not a sustained steady-state instability. Re-verified
## at 600 ticks: see this file's own dated CLAUDE.md entry for the actual
## before/after numbers.
const STEADY_SAMPLE_TICKS: int = 360  ## 6s -- inside the task's own
## requested 5-10s / 300-600 tick sampling window.
const STEADY_LOG_EVERY: int = 60  ## ~1s -- periodic running-max line, so a
## decaying-vs-sustained trend is visible in the raw log, not just one final
## aggregate number.


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

	# LEASH-CLAMP-FIRING INVESTIGATION (2026-07-28): GameManager.current_state
	# was NEVER set to PLAYING anywhere in this file before this line -- every
	# spawned test player's own real _physics_process() early-returns at its
	# "if GameManager.current_state != PLAYING: velocity = ZERO; move_and_slide();
	# return" gate, BEFORE ever reaching the leash clamp (called further down
	# the same function -- _apply_rope_leash_velocity_clamp() as of this
	# round's redesign, previously _clamp_to_rope_leash()). That means every
	# steady-state jitter number this file has ever reported (ROUND 17/18)
	# was measured with the real leash clamp completely inert -- a genuine,
	# disclosed methodology gap, not something previously investigated. Real
	# gameplay always has
	# current_state == PLAYING while a dart is anchored and a player can move,
	# so this line makes the test match reality; every player spawned below is
	# player_index 0 (keyboard) with zero real input in this headless run, so
	# velocity stays 0 from input alone -- any player-position motion measured
	# below is therefore attributable to the leash clamp itself, not movement.
	GameManager.current_state = GameManager.RoundState.PLAYING

	# TEMP-TESTING: fast-iteration flag to skip the slower tests while tuning
	# damping -- MUST be false before any real verification run / before
	# committing (zero net diff required, same convention as game_manager.gd's
	# lobby_mode TEMP-TESTING toggle).
	const QUICK_PROBE_ONLY: bool = false

	var overall_ok := true
	if not QUICK_PROBE_ONLY:
		overall_ok = await _test_idle_collapse() and overall_ok
		overall_ok = await _test_settled_configurations(rect) and overall_ok
		overall_ok = await _test_throw_unfold_and_retrieve_fold(rect) and overall_ok
	overall_ok = await _test_anchored_steady_state_jitter(rect) and overall_ok

	print("[TEST] OVERALL %s" % ("PASS" if overall_ok else "FAIL"))
	print("ROPE_PHYSICS_CHAIN_SETTLE_TEST_DONE")


func _spawn_player(pos: Vector3, aim: Vector2) -> Node:
	var player_scene: PackedScene = load("res://scenes/player.tscn")
	var player = player_scene.instantiate()
	add_child(player)
	player.global_position = pos
	player.spawn_pos = pos
	player.aim_dir = aim.normalized()
	return player


func _test_idle_collapse() -> bool:
	# ROUND 22 (2026-07-29): renamed "IDLE COLLAPSE" -> "IDLE DRIFT" in every
	# printed label -- see this file's own header comment ("1. IDLE DRIFT")
	# for the full rewrite of what this section means and why. Function name
	# itself left as _test_idle_collapse() to avoid an unnecessary call-site
	# diff; it no longer asserts a collapse.
	print("[TEST] --- 1. IDLE DRIFT (dart == null, no throw ever fired, no player movement) ---")
	var player = _spawn_player(Vector3(0.0, 0.7, 0.0), Vector2(0, 1))
	for i in IDLE_SETTLE_TICKS:
		await get_tree().physics_frame

	var hand_pos: Vector3 = player._get_rope_hand_anchor_pos()
	var hand_2d := Vector2(hand_pos.x, hand_pos.z)
	var max_dist: float = 0.0
	for seg in player._physics_rope_segments:
		var p3: Vector3 = (seg as RigidBody3D).global_position
		var d: float = hand_2d.distance_to(Vector2(p3.x, p3.z))
		max_dist = maxf(max_dist, d)
	print("[TEST] idle: %d segments, max_dist_from_hand=%.4f (divergence-only sane_bound=%.2f)" % [
		player._physics_rope_segments.size(), max_dist, IDLE_DRIFT_SANE_BOUND])
	# DIAGNOSTIC (fixed-segment-length round): is there a chronic per-joint
	# gap even at settled idle rest, independent of any throw transient?
	var idle_gaps: Array[float] = _joint_gaps(player)
	var idle_max_gap: float = 0.0
	var idle_max_gap_idx: int = -1
	for gi in range(idle_gaps.size()):
		if idle_gaps[gi] > idle_max_gap:
			idle_max_gap = idle_gaps[gi]
			idle_max_gap_idx = gi
	print("[TEST] idle diagnostic: max_joint_gap=%.4f @ joint %d (settled, no throw ever fired)" % [
		idle_max_gap, idle_max_gap_idx])

	var ok: bool = max_dist <= IDLE_DRIFT_SANE_BOUND and is_finite(max_dist)
	print("[TEST] %s: idle chain drift stayed within the loose divergence-only bound (max_dist=%.4f, no longer asserting a tight collapse -- see header comment)" % [
		"PASS" if ok else "FAIL", max_dist])
	player.queue_free()
	for i in 3:
		await get_tree().physics_frame
	return ok


func _config_name(i: int) -> String:
	const NAMES := [
		"open_air_far", "adjacent_corner_wrap", "diagonal_opposite_corner_wrap",
		"opposite_edges_whole_side_wrap", "random_0", "random_1", "random_2", "random_3",
	]
	return NAMES[i] if i < NAMES.size() else "random_%d" % i


func _test_settled_configurations(rect: Rect2) -> bool:
	print("[TEST] --- 2. SETTLED-CONFIGURATION SWEEP (real chain vs PillarA) ---")
	var near: Vector2 = rect.position
	var far: Vector2 = rect.end
	var center: Vector2 = rect.get_center()

	var configs: Array = [
		# [hand_2d, tip_2d]
		[Vector2(-8.0, -8.0), Vector2(8.0, 8.0)],                       # open air, far from pillar entirely
		[near + Vector2(-1.2, -1.2), far + Vector2(1.2, 1.2)],          # adjacent-corner style wrap
		[near + Vector2(-1.5, 0.3), far + Vector2(1.5, -0.3)],          # diagonal/opposite-corner wrap
		[Vector2(rect.position.x - 2.0, center.y), Vector2(rect.end.x + 2.0, center.y)],  # opposite-edges whole-side wrap
	]

	var rng := RandomNumberGenerator.new()
	rng.seed = 12345  # deterministic
	for _i in range(4):
		var ang_a: float = rng.randf_range(0.0, TAU)
		var ang_b: float = rng.randf_range(0.0, TAU)
		var rad_a: float = rng.randf_range(2.0, 3.5)
		var rad_b: float = rng.randf_range(2.0, 3.5)
		var a: Vector2 = center + Vector2(cos(ang_a), sin(ang_a)) * rad_a
		var b: Vector2 = center + Vector2(cos(ang_b), sin(ang_b)) * rad_b
		configs.append([a, b])

	var all_ok := true
	for idx in range(configs.size()):
		var hand2: Vector2 = configs[idx][0]
		var tip2: Vector2 = configs[idx][1]
		var cfg_name: String = _config_name(idx)

		var player = _spawn_player(Vector3(hand2.x, 0.7, hand2.y), (tip2 - hand2).normalized())
		for i in 5:
			await get_tree().physics_frame

		player._throw(0.0)
		for i in 5:
			await get_tree().physics_frame
		if player.dart == null:
			print("[TEST] config=%s FAIL: throw produced no dart" % cfg_name)
			all_ok = false
			player.queue_free()
			continue

		player.dart.state = 1  # State.ANCHORED
		player.dart.head_2d = tip2

		# TEST-HARNESS FIX (2026-07-28, found while A/B-verifying the leash
		# redesign): this settle loop used to rely, silently and by accident,
		# on the OLD _clamp_to_rope_leash()'s own position-teleport side
		# effect to keep player.global_position (and therefore the chain's
		# real hand anchor, read from get_hand_world_position()) somewhere
		# near the anchor -- for configs like open_air_far, whose hand2/tip2
		# pair (~22.6 units apart) FAR exceeds DART_ROPE_LENGTH (7.2), the old
		# clamp would immediately snap the player from hand2 to within 7.2 of
		# tip2 on literally the first tick, silently shrinking the real span
		# the chain ever had to bridge. This config's own stated purpose (see
		# this function's header comment) is "does the chain avoid tunneling
		# through a pillar between hand and tip," independent of whatever the
		# player's own movement/leash mechanics do -- so explicitly pin
		# player.global_position at hand2 every tick here, matching the
		# printed "hand=%s" value below and decoupling this measurement from
		# whichever leash mechanism happens to be in effect (a real, disclosed
		# behavior difference the new teleport-free leash redesign surfaced:
		# without a discontinuous position snap, a stationary player with zero
		# input genuinely never moves on their own, which is the whole point
		# of removing the old snap -- see player.gd's own doc comment).
		for i in CONFIG_SETTLE_TICKS:
			player.velocity = Vector3.ZERO
			player.global_position = Vector3(hand2.x, 0.7, hand2.y)
			await get_tree().physics_frame

		var max_pen: float = 0.0
		for seg in player._physics_rope_segments:
			var p3: Vector3 = (seg as RigidBody3D).global_position
			var p2 := Vector2(p3.x, p3.z)
			if rect.has_point(p2):
				var pen: float = minf(p2.x - rect.position.x, rect.end.x - p2.x)
				pen = minf(pen, minf(p2.y - rect.position.y, rect.end.y - p2.y))
				max_pen = maxf(max_pen, pen)

		var config_ok: bool = max_pen <= PENETRATION_TOLERANCE
		all_ok = all_ok and config_ok
		print("[TEST] config=%s hand=%s tip=%s max_pen=%.5f -> %s" % [
			cfg_name, hand2, tip2, max_pen, "PASS" if config_ok else "FAIL"])

		player.queue_free()
		for i in 3:
			await get_tree().physics_frame

	print("[TEST] %s: all %d settled configurations stayed clear of PillarA's real rect" % [
		"PASS" if all_ok else "FAIL", configs.size()])
	return all_ok


func _joint_gaps(player: Node) -> Array[float]:
	## Per-joint separation (XZ) between consecutive bodies' OWN declared
	## local anchor points, in chain order [hand_anchor, seg0..seg31,
	## tip_anchor]. A perfectly satisfied pin joint has its two local anchor
	## points COINCIDE in world space -- so each entry here is the real
	## "how much has this joint stretched" measurement, not a proxy (distance
	## from the fixed hand point, which is what the pre-existing max_dist
	## checks below measure -- that's total chain reach, not per-joint
	## rigidity). gaps[i] is joint i, between body i and body i+1 in the
	## [hand_anchor, seg0..seg31, tip_anchor] list.
	var half: float = player.ROPE_PHYSICS_SEGMENT_HALF_LENGTH
	var segs: Array = player._physics_rope_segments
	var hand_body: RigidBody3D = player._physics_rope_hand_anchor
	var tip_body: RigidBody3D = player._physics_rope_tip_anchor
	var gaps: Array[float] = []
	var prev_far2 := Vector2(hand_body.global_position.x, hand_body.global_position.z)
	for i in range(segs.size()):
		var seg: RigidBody3D = segs[i]
		var xform: Transform3D = seg.global_transform
		var near_pt: Vector3 = xform * Vector3(0.0, -half, 0.0)
		var far_pt: Vector3 = xform * Vector3(0.0, half, 0.0)
		var near2 := Vector2(near_pt.x, near_pt.z)
		var far2 := Vector2(far_pt.x, far_pt.z)
		gaps.append(prev_far2.distance_to(near2))
		prev_far2 = far2
	var tip2 := Vector2(tip_body.global_position.x, tip_body.global_position.z)
	gaps.append(prev_far2.distance_to(tip2))
	return gaps


func _sample_chain_points_2d(player: Node) -> Array[Vector2]:
	## [hand_anchor, seg0..segN-1, tip_anchor], the SAME chain order and the
	## SAME exact points _joint_gaps() and _update_rope_tube_mesh()'s own
	## control-point list use -- i.e. this is precisely what could show up as
	## a reshaping curve on screen, not a proxy for it.
	var pts: Array[Vector2] = []
	var hand_pos: Vector3 = (player._physics_rope_hand_anchor as RigidBody3D).global_position
	pts.append(Vector2(hand_pos.x, hand_pos.z))
	for seg in player._physics_rope_segments:
		var p3: Vector3 = (seg as RigidBody3D).global_position
		pts.append(Vector2(p3.x, p3.z))
	var tip_pos: Vector3 = (player._physics_rope_tip_anchor as RigidBody3D).global_position
	pts.append(Vector2(tip_pos.x, tip_pos.z))
	return pts


func _sample_chain_points_3d(player: Node) -> Array[Vector3]:
	## Same chain order as _sample_chain_points_2d(), but full Vector3 world
	## positions -- the exact input _update_rope_tube_mesh() itself builds
	## for _compute_rope_tube_curve_points(), used by the render-curve
	## jitter probe in _measure_steady_state_jitter().
	var pts: Array[Vector3] = [(player._physics_rope_hand_anchor as RigidBody3D).global_position]
	for seg in player._physics_rope_segments:
		pts.append((seg as RigidBody3D).global_position)
	pts.append((player._physics_rope_tip_anchor as RigidBody3D).global_position)
	return pts


func _test_anchored_steady_state_jitter(rect: Rect2) -> bool:
	print("[TEST] --- 5. ANCHORED STEADY-STATE JITTER (player stationary, dart settled several seconds, zero new input) ---")
	## THREE configs, all at PHYSICALLY ACHIEVABLE hand-to-tip distances (<=
	## DART_ROPE_LENGTH -- unlike the penetration sweep's own "open_air_far"
	## config above, whose hand/tip are ~22.6 units apart against a chain
	## that can only ever span 7.2: that config is fine for a pure
	## final-position penetration check, since it never claims the chain
	## reaches a real equilibrium, but it is NOT a valid steady-state-jitter
	## probe -- an unsolvable, permanently-overstretched kinematic tip target
	## forces the solver to fight an impossible constraint every single tick
	## forever, which was directly confirmed, not assumed: an earlier version
	## of this test that reused "open_air_far" verbatim measured a real
	## amplification(seg/hand) of ~2031x and a sustained (not decaying)
	## ~0.78-unit mean joint gap -- a genuine artifact of the invalid,
	## physically-impossible test config, not a reproduction of the reported
	## bug). "open_air_taut" (max-range anchor, ~zero slack -- the common
	## real case per rope_dart.gd's own "anchor at max range if nothing was
	## hit" behavior) and "open_air_slack" (a shorter, real anchor with
	## visible slack) both stay within real capacity; "corner_wrap_anchor"
	## (real obstacle contact, matching the user's own reported "near a
	## pillar" scenario) is unchanged from the original probe. This 3-way
	## split lets this test tell apart a general chain-level jitter from one
	## specific to tautness or to the wrap/leash-pivot interaction.
	## "near_corner_slack_bunch" (2026-07-26 -- direct-contact jitter
	## investigation, added specifically because it's a materially DIFFERENT
	## real-contact configuration from "corner_wrap_anchor" above, not a
	## duplicate): corner_wrap_anchor's hand/tip sit far out on the diagonal
	## (margin 1.2 past each opposite corner), so its own real hand-to-tip
	## distance (6.22) is close to the chain's DART_ROPE_LENGTH capacity
	## (7.2) -- only ~1 unit of slack, i.e. a near-TAUT wrap with almost no
	## excess rope left to fold up anywhere. The user's own report described
	## a "small hook/loop shape where the rope touches the pillar's base" --
	## a materially different visual (a compact tangle sitting right at one
	## corner) from a taut diagonal stretch. This config instead puts BOTH
	## hand and tip close (0.3 margin) to the SAME single corner, on its two
	## adjacent edges (real distance ~1.8, wrap path ~2.1) -- a SHORT real
	## span against the same 7.2 total capacity, deliberately forcing ~5
	## units of slack to fold up with nowhere physically reachable to go
	## except bunched right at that one genuinely-contacting corner (the
	## same "large local excess near a real contact point" combination
	## corner_wrap_anchor's own near-zero-slack geometry never exercises).
	var near_corner: Vector2 = rect.position
	var jitter_configs: Array = [
		["open_air_taut", Vector2(-8.0, -8.0), Vector2(-8.0, -8.0) + Vector2(1.0, 0.0) * 7.0],
		["open_air_slack", Vector2(-8.0, -8.0), Vector2(-8.0, -8.0) + Vector2(1.0, 0.0) * 5.5],
		["corner_wrap_anchor", rect.position + Vector2(-1.2, -1.2), rect.end + Vector2(1.2, 1.2)],
		["near_corner_slack_bunch", near_corner + Vector2(-0.3, 1.0), near_corner + Vector2(1.0, -0.3)],
	]

	var all_ok := true
	for cfg in jitter_configs:
		var cfg_name: String = cfg[0]
		var hand2: Vector2 = cfg[1]
		var tip2: Vector2 = cfg[2]

		var player = _spawn_player(Vector3(hand2.x, 0.7, hand2.y), (tip2 - hand2).normalized())
		for i in 5:
			await get_tree().physics_frame
		player._throw(0.0)
		for i in 5:
			await get_tree().physics_frame
		if player.dart == null:
			print("[TEST] config=%s FAIL: throw produced no dart" % cfg_name)
			all_ok = false
			player.queue_free()
			continue
		player.dart.state = 1  # State.ANCHORED
		player.dart.head_2d = tip2  # fixed forever below -- the tip anchor's
		## own driven target is a literal constant for the rest of this test,
		## so ANY tip-anchor motion measured below is either genuine physics
		## settle or a bug, never a moving target.

		## SELF-PICKUP CONTAMINATION FIX (2026-07-28, found while investigating
		## a reported "rope jitter near a pillar" bug): for a SHORT real
		## hand-to-tip span (e.g. near_corner_slack_bunch's own ~1.8 units),
		## the REAL, un-overridden throw above can travel far enough within
		## its own 5-tick settle window to land inside rope_dart.gd's
		## pickup_radius (0.9) of the still-standing player BEFORE this
		## function's own state/head_2d override lands -- triggering a real,
		## natural ANCHORED -> pickup-check -> recall() transition (see
		## rope_dart.gd's State.ANCHORED branch) that sets _is_recalling=true
		## via player.gd's own dart-state sync (_physics_process(), "Keep
		## _is_recalling ... in sync with the dart's OWN state"). This
		## function's override then stomps dart.state back to ANCHORED, but
		## NOTHING here was clearing _is_recalling -- which is normally only
		## ever cleared by _on_dart_returned()/kill()/reset_for_round(), none
		## of which this shortcut calls -- leaving the character stuck
		## displaying the recall sequence's own "Push" clip FOREVER (since
		## _advance_recall_anim()'s HOLD phase only exits once _is_recalling
		## goes false, which now never happens). Confirmed via a dedicated,
		## isolated repro probe (not committed) that this, not any real
		## physics/render bug, was the entire source of a large (~0.1-1.3
		## unit) "periodic hand jump" measured before this fix: root_pos/
		## root_vel/mesh_quaternion were all bit-identical every single tick
		## (ruling out player-body/collision or facing-rotation causes), and
		## the jump ticks lined up exactly with "Push"'s own current_animation
		## and a ~160-tick (2.667s, "Push"'s own clip length) recurrence --
		## i.e. the chain was innocently rendering a real hand-bone pose from
		## a real (if stuck-looping) animation clip, not exhibiting any rope-
		## physics or obstacle-contact instability. A separate, clean probe
		## (fresh spawn, no throw, no rope, 500 ticks/~8.3s at Idle_A) found
		## NO comparable jump anywhere -- ruling out a general Idle_A loop-
		## seam artifact as well. Fix: explicitly clear _is_recalling and
		## both phase/timer pairs right after the state/head_2d override, so
		## this shortcut always produces a clean forced-ANCHORED state
		## regardless of how far the real pre-override throw happened to
		## travel -- matching kill()'s own established reset pattern.
		player._is_recalling = false
		player._recall_anim_phase = 0  # ThrowAnimPhase.NONE
		player._recall_anim_timer = 0.0
		player._throw_anim_phase = 0  # ThrowAnimPhase.NONE
		player._throw_anim_timer = 0.0

		await _measure_steady_state_jitter(player, cfg_name)
		player.queue_free()
		for i in 3:
			await get_tree().physics_frame

	## FOURTH config: a REAL throw (full charge, aimed straight at PillarA),
	## left to fly and anchor NATURALLY via rope_dart.gd's own real physics
	## raycast (_raycast_obstacle()) -- unlike the three configs above, which
	## shortcut straight to a hand-picked ANCHORED state/head_2d. A real
	## throw's own flight dynamics (acceleration, the FLYING->ANCHORED
	## transition's own settle -- see _clamp_to_rope_leash()'s own
	## "TRANSIENT-SNAP" doc comment for a documented example of transition-
	## specific behavior that a synthetic force-anchor would never exercise)
	## could plausibly leave the chain in a different, possibly less-settled
	## equilibrium than an instantly-teleported anchor -- this config checks
	## that directly rather than assuming the first three configs' own
	## instant-anchor shortcut is representative of what a real player
	## actually sees.
	var pillar_center: Vector2 = rect.get_center()
	var throw_start := Vector3(pillar_center.x, 0.7, pillar_center.y - 4.0)
	var real_player = _spawn_player(throw_start, Vector2(0.0, 1.0))
	for i in 5:
		await get_tree().physics_frame
	real_player._throw(1.0)  # full charge -- fastest, longest flight
	var anchored: bool = false
	for i in 120:
		await get_tree().physics_frame
		if not is_instance_valid(real_player.dart):
			break
		if real_player.dart.state != 0:  # not FLYING any more
			anchored = true
			break
	if not anchored:
		print("[TEST] config=real_throw_at_pillar FAIL: dart never left FLYING within 120 ticks")
		all_ok = false
	else:
		await _measure_steady_state_jitter(real_player, "real_throw_at_pillar")
	real_player.queue_free()
	for i in 3:
		await get_tree().physics_frame

	print("[TEST] steady-state jitter diagnostic complete (see per-config SUMMARY lines above)")
	return all_ok


func _measure_steady_state_jitter(player: Node, cfg_name: String) -> void:
	## Shared measurement core for every config in
	## _test_anchored_steady_state_jitter() above -- assumes the caller has
	## already gotten `player` into a real ANCHORED state (however it got
	## there) and left it completely alone (no more movement/throw/recall
	## calls) from this point on.

	# Let any initial anchor-transition settle transient fully decay -- this
	# is NOT what's under test here (see CONFIG_SETTLE_TICKS above, already
	# an established-sufficient settle window for shape; doubled for extra
	# safety since this test specifically cares about TRUE rest, several
	# seconds in, not just "clear of the pillar").
	for i in STEADY_PRE_SETTLE_TICKS:
		await get_tree().physics_frame

	var prev_pts: Array[Vector2] = _sample_chain_points_2d(player)
	var hand_max_step: float = 0.0
	var hand_min: Vector2 = prev_pts[0]
	var hand_max: Vector2 = prev_pts[0]
	var seg_max_step: float = 0.0
	var seg_sum_step: float = 0.0
	var seg_sample_count: int = 0
	var joint_gap_max: float = 0.0
	var joint_gap_sum: float = 0.0
	var joint_gap_samples: int = 0
	var window_ticks: int = 0

	# RENDER-CURVE jitter (2026-07-28 -- direct-contact jitter investigation,
	# after ruling out contact-flicker and animation-clip artifacts as the
	# dominant driver): calls the REAL, shipped _compute_rope_tube_curve_
	# points() every tick on the same real control points _update_rope_tube_
	# mesh() itself uses -- i.e. this measures exactly what gets drawn on
	# screen, not a proxy for it. Tests whether the Catmull-Rom spline
	# AMPLIFIES the tiny raw-segment jitter already measured above into
	# something bigger near a sharp corner (a materially different question
	# from ROUND 8/9/10's own STATIC penetration-overshoot checks -- this is
	# about DYNAMIC frame-to-frame curve motion, never directly measured
	# before).
	var curve_max_step: float = 0.0
	var curve_sum_step: float = 0.0
	var curve_sample_count: int = 0
	var prev_curve_pts: Array[Vector3] = player._compute_rope_tube_curve_points(_sample_chain_points_3d(player))

	# LEASH-CLAMP-FIRING instrumentation (2026-07-28, "should the max leash
	# length be computed between the dart and character" investigation): with
	# GameManager.current_state now PLAYING (see _run()'s own doc comment) and
	# zero real input on this headless player, ANY tick-to-tick motion of
	# player.get_pos_2d() itself during this stationary sampling window is
	# attributable to the leash clamp's own effect on the player's position
	# (originally _clamp_to_rope_leash()'s direct position write; as of this
	# round's redesign, _apply_rope_leash_velocity_clamp()'s velocity
	# projection feeding into move_and_slide()), not to movement input or
	# unrelated move_and_slide() collision response (velocity is 0 every tick
	# from input alone, before the leash clamp runs). This instrumentation is
	# kept permanently, not reverted after the one-time baseline measurement
	# it was added for -- a real, reusable regression signal for any future
	# leash-mechanism change. player_pos_fire_events counts ticks where the
	# step exceeds a small float-noise threshold (0.0005) -- i.e. the leash
	# mechanism actually moved the player that tick, not just floating-point
	# jitter in the read.
	var player_pos_max_step: float = 0.0
	var player_pos_step_sum: float = 0.0
	var player_pos_fire_events: int = 0
	var prev_player_pos: Vector2 = player.get_pos_2d()

	# CONTACT-STATE instrumentation (2026-07-26 -- direct-contact jitter
	# investigation): reads rope_segment_body.gd's own `_debug_last_has_
	# contact` per segment, per tick, to test the specific hypothesis that
	# jitter localizes AT genuine obstacle contact points (contact-state
	# flicker: a segment repeatedly gaining/losing contact tick to tick)
	# rather than being uniform across the whole chain. `contact_step_max`/
	# `noncontact_step_max` split seg_max_step by whether THAT segment was in
	# contact onEITHER endpoint of the step (current or previous tick) --
	# this is deliberately inclusive (OR, not AND) so a step that happens
	# exactly on a contact/no-contact transition is counted as a contact-
	# adjacent step, not silently dropped from either bucket.
	var segs: Array = player._physics_rope_segments
	var prev_contact: Array[bool] = []
	for seg in segs:
		prev_contact.append(bool(seg.get("_debug_last_has_contact")))
	var flicker_events: int = 0  # total contact<->no-contact transitions, all segments, all ticks
	var contact_ticks: int = 0  # ticks where >=1 segment reports contact
	var contact_step_max: float = 0.0
	var contact_step_sum: float = 0.0
	var contact_step_count: int = 0
	var noncontact_step_max: float = 0.0
	var max_contact_segs_any_tick: int = 0

	for tick in range(STEADY_SAMPLE_TICKS):
		await get_tree().physics_frame
		window_ticks += 1
		var cur_pts: Array[Vector2] = _sample_chain_points_2d(player)

		var cur_contact: Array[bool] = []
		var contact_count_this_tick: int = 0
		for seg in segs:
			var c: bool = bool(seg.get("_debug_last_has_contact"))
			cur_contact.append(c)
			if c:
				contact_count_this_tick += 1
		max_contact_segs_any_tick = maxi(max_contact_segs_any_tick, contact_count_this_tick)
		if contact_count_this_tick > 0:
			contact_ticks += 1
		for si in range(cur_contact.size()):
			if cur_contact[si] != prev_contact[si]:
				flicker_events += 1

		# The hand anchor's own tick-to-tick motion (index 0) is the DRIVEN
		# boundary condition here, not a free physics body --
		# get_hand_world_position()'s own doc comment says its X/Z come from
		# "the real, animated, bobbing hand bone." A non-zero value here is
		# a candidate real driver (an Idle_A-driven hand bone never truly
		# stops moving), not itself a chain-instability bug -- logged
		# separately from seg_* below specifically so the two can be told
		# apart.
		var hand_step: float = prev_pts[0].distance_to(cur_pts[0])
		hand_max_step = maxf(hand_max_step, hand_step)
		hand_min.x = minf(hand_min.x, cur_pts[0].x)
		hand_min.y = minf(hand_min.y, cur_pts[0].y)
		hand_max.x = maxf(hand_max.x, cur_pts[0].x)
		hand_max.y = maxf(hand_max.y, cur_pts[0].y)

		# Every DYNAMIC segment's own tick-to-tick motion -- indices
		# [1, size-2] (index 0 is the hand anchor, the last index is the tip
		# anchor, both kinematic/driven, not free bodies). cur_pts/segs share
		# the same index offset by 1 (segs has no hand/tip entries).
		for i in range(1, cur_pts.size() - 1):
			var step: float = prev_pts[i].distance_to(cur_pts[i])
			seg_max_step = maxf(seg_max_step, step)
			seg_sum_step += step
			seg_sample_count += 1
			var seg_idx: int = i - 1
			var in_contact: bool = cur_contact[seg_idx] or prev_contact[seg_idx]
			if in_contact:
				contact_step_max = maxf(contact_step_max, step)
				contact_step_sum += step
				contact_step_count += 1
			else:
				noncontact_step_max = maxf(noncontact_step_max, step)

		var gaps: Array[float] = _joint_gaps(player)
		for g in gaps:
			joint_gap_max = maxf(joint_gap_max, g)
			joint_gap_sum += g
			joint_gap_samples += 1

		# RENDER-CURVE jitter: same real function, same real control points,
		# called fresh every tick -- see this function's own var declarations
		# above for why.
		var cur_curve_pts: Array[Vector3] = player._compute_rope_tube_curve_points(_sample_chain_points_3d(player))
		if cur_curve_pts.size() == prev_curve_pts.size():
			for ci in range(cur_curve_pts.size()):
				var cstep: float = prev_curve_pts[ci].distance_to(cur_curve_pts[ci])
				curve_max_step = maxf(curve_max_step, cstep)
				curve_sum_step += cstep
				curve_sample_count += 1
		prev_curve_pts = cur_curve_pts

		var cur_player_pos: Vector2 = player.get_pos_2d()
		var player_step: float = prev_player_pos.distance_to(cur_player_pos)
		player_pos_max_step = maxf(player_pos_max_step, player_step)
		player_pos_step_sum += player_step
		if player_step > 0.0005:
			player_pos_fire_events += 1
		prev_player_pos = cur_player_pos

		prev_pts = cur_pts
		prev_contact = cur_contact
		if (tick + 1) % STEADY_LOG_EVERY == 0:
			print("[TEST] %s steady tick=%d hand_step_running_max=%.5f seg_step_running_max=%.5f joint_gap_running_max=%.5f contact_segs_now=%d flicker_events_running=%d curve_step_running_max=%.5f player_pos_step_running_max=%.5f player_pos_fire_events_running=%d" % [
				cfg_name, tick + 1, hand_max_step, seg_max_step, joint_gap_max, contact_count_this_tick, flicker_events, curve_max_step, player_pos_max_step, player_pos_fire_events])

	var hand_bbox_diag: float = hand_min.distance_to(hand_max)
	var seg_mean_step: float = seg_sum_step / float(maxi(seg_sample_count, 1))
	var joint_gap_mean: float = joint_gap_sum / float(maxi(joint_gap_samples, 1))
	# amplification > 1 means the free dynamic segments are moving MORE, tick
	# to tick, than the driven hand boundary they're attached to -- i.e. real
	# resonance/instability on top of just following the hand. amplification
	# <= ~1 means the chain is doing the physically correct thing (passively
	# following a slightly-alive hand boundary).
	var amplification: float = seg_max_step / maxf(hand_max_step, 0.00001)
	print("[TEST] %s STEADY-STATE SUMMARY over %d ticks (~%.1fs): hand_max_step=%.5f hand_bbox_diag=%.5f seg_max_step=%.5f seg_mean_step=%.5f amplification(seg/hand)=%.3f joint_gap_max=%.5f joint_gap_mean=%.5f" % [
		cfg_name, window_ticks, float(window_ticks) / 60.0, hand_max_step, hand_bbox_diag,
		seg_max_step, seg_mean_step, amplification, joint_gap_max, joint_gap_mean])
	var contact_step_mean: float = contact_step_sum / float(maxi(contact_step_count, 1))
	print("[TEST] %s CONTACT-STATE SUMMARY: contact_ticks=%d/%d (%.1f%%) max_contact_segs_any_tick=%d flicker_events=%d contact_step_max=%.5f contact_step_mean=%.5f noncontact_step_max=%.5f" % [
		cfg_name, contact_ticks, window_ticks, 100.0 * float(contact_ticks) / float(maxi(window_ticks, 1)),
		max_contact_segs_any_tick, flicker_events, contact_step_max, contact_step_mean, noncontact_step_max])
	var curve_mean_step: float = curve_sum_step / float(maxi(curve_sample_count, 1))
	# curve_amplification > 1 means the RENDERED spline moves MORE, tick to
	# tick, than the raw physics segments it's drawn through -- i.e. the
	# Catmull-Rom fit is itself injecting extra visible motion beyond what
	# the real simulated chain is doing.
	var curve_amplification: float = curve_max_step / maxf(seg_max_step, 0.00001)
	print("[TEST] %s RENDER-CURVE SUMMARY: curve_max_step=%.5f curve_mean_step=%.5f curve_amplification(curve/seg)=%.3f" % [
		cfg_name, curve_max_step, curve_mean_step, curve_amplification])
	var player_pos_mean_step: float = player_pos_step_sum / float(maxi(window_ticks, 1))
	print("[TEST] %s LEASH-CLAMP-FIRING SUMMARY: player_pos_max_step=%.5f player_pos_mean_step=%.5f player_pos_fire_events=%d/%d (%.1f%%)" % [
		cfg_name, player_pos_max_step, player_pos_mean_step, player_pos_fire_events, window_ticks,
		100.0 * float(player_pos_fire_events) / float(maxi(window_ticks, 1))])


func _test_throw_unfold_and_retrieve_fold(_rect: Rect2) -> bool:
	print("[TEST] --- 3+4. THROW UNFOLD / RETRIEVE FOLD (open air, no obstacle) ---")
	var start_pos := Vector3(-10.0, 0.7, -10.0)
	var player = _spawn_player(start_pos, Vector2(1, 1))
	for i in 5:
		await get_tree().physics_frame

	player._throw(1.0)  # full charge -- longest, fastest throw, the adversarial case
	for i in 5:
		await get_tree().physics_frame
	if player.dart == null:
		print("[TEST] FAIL: throw produced no dart")
		player.queue_free()
		return false

	var hand_pos0: Vector3 = player._get_rope_hand_anchor_pos()
	var hand2d_fixed := Vector2(hand_pos0.x, hand_pos0.z)
	var unfold_trace: Array[float] = []
	var max_reach_unfold: float = 0.0
	var max_joint_gap_unfold: float = 0.0
	var max_joint_gap_idx: int = -1
	var max_joint_gap_tick: int = -1
	for tick in range(THROW_LOG_TICKS):
		await get_tree().physics_frame
		var gaps: Array[float] = _joint_gaps(player)
		for gi in range(gaps.size()):
			if gaps[gi] > max_joint_gap_unfold:
				max_joint_gap_unfold = gaps[gi]
				max_joint_gap_idx = gi
				max_joint_gap_tick = tick
		if tick % THROW_LOG_EVERY != 0:
			continue
		var max_dist: float = 0.0
		for seg in player._physics_rope_segments:
			var p3: Vector3 = (seg as RigidBody3D).global_position
			max_dist = maxf(max_dist, hand2d_fixed.distance_to(Vector2(p3.x, p3.z)))
		max_reach_unfold = maxf(max_reach_unfold, max_dist)
		var real_dist: float = hand2d_fixed.distance_to(player.dart.head_2d) if is_instance_valid(player.dart) else -1.0
		unfold_trace.append(max_dist)
		var tick_max_gap: float = 0.0
		var tick_max_gap_idx: int = -1
		for gi2 in range(gaps.size()):
			if gaps[gi2] > tick_max_gap:
				tick_max_gap = gaps[gi2]
				tick_max_gap_idx = gi2
		print("[TEST] unfold tick=%d max_seg_reach=%.3f real_hand_to_dart=%.3f tick_max_joint_gap=%.4f@joint%d" % [
			tick, max_dist, real_dist, tick_max_gap, tick_max_gap_idx])

	# Per-joint rigidity check: EACH joint's own separation (the direct
	# measurement of "did this bar segment stretch") must stay small at all
	# times, not just the aggregate chain reach -- see this file's own header
	# comment / CLAUDE.md's dated entry for why the OLD max_reach_unfold-only
	# check (tolerance dart_rope_length * 1.5 = 12.0) passed even at a real,
	# measured ~10.8 unit reach against an 8.0 unit true capacity: it only
	# ever caught total-chain divergence to infinity, never "did any single
	# joint separate by a meaningful fraction of its own segment length."
	# JOINT_GAP_TOLERANCE is a small ABSOLUTE tolerance (not scaled to total
	# rope length) since it represents genuine per-joint stretch, which a
	# truly rigid bar should not exhibit regardless of how many segments make
	# up the whole chain.
	const JOINT_GAP_TOLERANCE: float = 0.15
	var dart_rope_length: float = player.DART_ROPE_LENGTH
	var joint_gap_ok: bool = max_joint_gap_unfold <= JOINT_GAP_TOLERANCE
	print("[TEST] unfold: max_joint_gap=%.4f (joint %d, tick %d) vs tolerance=%.2f -> %s" % [
		max_joint_gap_unfold, max_joint_gap_idx, max_joint_gap_tick, JOINT_GAP_TOLERANCE,
		"PASS" if joint_gap_ok else "FAIL"])
	var unfold_ok: bool = max_reach_unfold <= dart_rope_length * 1.1 and joint_gap_ok
	print("[TEST] unfold: max_reach_unfold=%.3f vs DART_ROPE_LENGTH=%.1f -> %s" % [
		max_reach_unfold, dart_rope_length, "PASS" if unfold_ok else "FAIL"])

	# Let it anchor (or force it if still flying after the log window) so
	# recall() has something real to retrieve from.
	for i in 60:
		if not is_instance_valid(player.dart):
			break
		if player.dart.state != 0:  # not FLYING any more
			break
		await get_tree().physics_frame
	if is_instance_valid(player.dart):
		player.dart.recall()

	var fold_trace: Array[float] = []
	var returned: bool = false
	for tick in range(RETRIEVE_MAX_TICKS):
		await get_tree().physics_frame
		if player.dart == null:
			returned = true
			break
		if tick % RETRIEVE_LOG_EVERY != 0:
			var _skip = 0
			continue
		var hand_pos_now: Vector3 = player._get_rope_hand_anchor_pos()
		var hand2d_now := Vector2(hand_pos_now.x, hand_pos_now.z)
		var max_dist2: float = 0.0
		for seg in player._physics_rope_segments:
			var p3b: Vector3 = (seg as RigidBody3D).global_position
			max_dist2 = maxf(max_dist2, hand2d_now.distance_to(Vector2(p3b.x, p3b.z)))
		fold_trace.append(max_dist2)
		print("[TEST] fold tick=%d max_seg_reach=%.3f" % [tick, max_dist2])

	var fold_ok: bool = returned
	if returned:
		# Confirm the chain actually folded back down to a real, STABLE
		# equilibrium near the hand post-return, not left stretched out or
		# still diverging/moving. Same ~5s convergence timescale as the
		# standalone idle-collapse test above -- see POST_RETRIEVE_COLLAPSE_
		# RADIUS's own comment for why this check uses a separate, looser
		# tolerance than IDLE_COLLAPSE_RADIUS: a real, direct, repeated
		# measurement (not a guess) showed this specific post-full-extension
		# scenario settles noticeably looser than a pristine idle spawn, but
		# just as genuinely at rest.
		for i in 300:
			await get_tree().physics_frame
		var hand_pos_final: Vector3 = player._get_rope_hand_anchor_pos()
		var hand2d_final := Vector2(hand_pos_final.x, hand_pos_final.z)
		var max_dist_final: float = 0.0
		for seg in player._physics_rope_segments:
			var p3c: Vector3 = (seg as RigidBody3D).global_position
			max_dist_final = maxf(max_dist_final, hand2d_final.distance_to(Vector2(p3c.x, p3c.z)))
		fold_ok = max_dist_final <= POST_RETRIEVE_COLLAPSE_RADIUS
		print("[TEST] post-retrieve collapse check: max_dist_from_hand=%.4f (tolerance=%.2f) -> %s" % [
			max_dist_final, POST_RETRIEVE_COLLAPSE_RADIUS, "PASS" if fold_ok else "FAIL"])
	else:
		print("[TEST] FAIL: dart never returned within %d ticks" % RETRIEVE_MAX_TICKS)

	print("[TEST] retrieve: dart_returned=%s -> %s" % [returned, "PASS" if fold_ok else "FAIL"])

	player.queue_free()
	for i in 3:
		await get_tree().physics_frame

	return unfold_ok and fold_ok
