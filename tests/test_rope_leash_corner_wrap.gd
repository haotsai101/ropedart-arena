extends Node
## Regression test for the "corner-wrap-at-max-leash fold" bug (real user
## screen recording, frame-extracted and reviewed directly): wrapping the
## rope around a pillar corner reads clean until the player reaches max
## leash range and keeps pushing further/around the corner, at which point
## the rope visibly develops a sharp zigzag/hook fold right at the corner
## contact point.
##
## Deterministically forces the reported condition -- dart anchored on the
## FAR side of a real pillar, player starting near the NEAR corner with
## real (beeline) slack, then driven in a sustained outward+tangential sweep
## around that corner for several seconds, well past where the naive
## straight-line leash circle alone would allow -- instead of relying on
## random bot play to stumble into it. Measures, every few ticks:
##   - chain_len: the REAL simulated chain's own total path length (hand ->
##     every dynamic segment -> tip), vs. its fixed DART_ROPE_LENGTH capacity
##     -- a chain being asked to exceed its own physical length is exactly
##     the "impossible stretch" this bug's root cause describes.
##   - max_pillar_pen: whether any segment is pushed inside the pillar's own
##     get_rect_2d() footprint (regression check against the earlier,
##     separately-fixed straight-line-penetration bug).
##   - fold_jump: the largest single-tick displacement of any one segment --
##     a real "zigzag/hook fold" reads as a large jump immediately followed
##     by a comparable jump back the other way, not a smooth multi-tick
##     ramp (this codebase's own established precedent for what counts as a
##     decaying/acceptable transient vs. a real fold -- see e.g. the
##     already-validated ~10-12 unit tip-joint spike that reliably decays).
##
## Run this scene directly (F6 in the editor, or via the Godot MCP
## run_project tool with scene=res://tests/test_rope_leash_corner_wrap.tscn)
## any time player.gd's _clamp_to_rope_leash()/_update_physics_rope_anchors()
## or rope_segment_body.gd's clamps change.

const SETTLE_TICKS: int = 300  ## ~5s at 60Hz -- long enough to sweep well past max leash
const MOVE_SPEED: float = 6.0  ## matches player.gd's own default move_speed
const DART_ROPE_LENGTH: float = 8.0  ## must match player.gd's own DART_ROPE_LENGTH
## A single-tick position jump bigger than this, immediately followed by a
## comparable jump back the OTHER way, is what "zigzag/hook fold" looks like
## numerically.
const FOLD_JUMP_THRESHOLD: float = 1.0
## How far the chain's own real path length may exceed its fixed physical
## capacity before we call it a genuine overstretch rather than ordinary
## solver slop -- a bit above the perpendicular tension tolerance
## (ROPE_TAUT_PERP_RADIUS = 0.3) plus some headroom for a settling transient.
const MAX_ACCEPTABLE_OVERSHOOT: float = 0.75


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

	# Start southwest of the pillar's near corner -- close enough (beeline)
	# to the eventual anchor that the player starts with real leash slack,
	# but circling tangentially around that near corner toward the anchor's
	# far side quickly demands real wrap-around length, not just beeline.
	var near_corner: Vector2 = rect.position
	var far_corner: Vector2 = rect.end
	player.global_position = Vector3(near_corner.x - 1.2, GameManager.PLAYER_HALF_HEIGHT, near_corner.y - 1.2)
	player.spawn_pos = player.global_position
	player.aim_dir = Vector2(-1, -1).normalized()
	for i in 5:
		await get_tree().physics_frame

	player._throw(0.0)
	for i in 5:
		await get_tree().physics_frame
	if player.dart == null:
		print("[TEST] FAIL: throw produced no dart")
		return

	player.dart.state = 1  # State.ANCHORED (see rope_dart.gd's enum)
	var anchor: Vector2 = far_corner + Vector2(1.2, 1.2)
	player.dart.head_2d = anchor
	print("[TEST] hand=%s anchor=%s beeline_dist=%.2f (DART_ROPE_LENGTH=%.1f)" % [
		player.get_pos_2d(), anchor, player.get_pos_2d().distance_to(anchor), DART_ROPE_LENGTH])

	# --- Settle phase: hold the player STATIONARY while the freshly-spawned
	# chain (bunched near the hand at throw-instant, see player.gd's
	# ROPE_BUNCH_SPACING doc comment) pays out and wraps the corner on its
	# own. This is deliberately separate from the sweep below so the
	# already-documented, already-accepted "first tick(s) after a throw can
	# briefly reach 60-95% of full extension" transient (CLAUDE.md's own
	# ROUND 2 UNSPOOL FIX writeup) doesn't get conflated with the actual bug
	# under test here -- a fold specifically once the player is already at
	# or near max leash and CONTINUES pushing outward/around the corner.
	const SETTLE_WAIT_TICKS: int = 90
	for tick in range(SETTLE_WAIT_TICKS):
		player.velocity = Vector3.ZERO
		player._update_physics_rope_anchors()
		player.move_and_slide()
		player._clamp_to_rope_leash()
		await get_tree().physics_frame
	var settle_hand: Vector3 = player._get_rope_hand_anchor_pos()
	var settle_tip: Vector3 = player._get_rope_tip_target()
	var settle_len: float = _chain_path_length_2d(player, Vector2(settle_hand.x, settle_hand.z), Vector2(settle_tip.x, settle_tip.z))
	print("[TEST] after %d-tick settle (player stationary): chain_len=%.2f (cap=%.1f)" % [
		SETTLE_WAIT_TICKS, settle_len, DART_ROPE_LENGTH])

	# Sweep the player in a circular arc AROUND the pillar's near corner,
	# always pushing tangentially AND outward -- exactly the reported "keeps
	# pushing further away/around the corner" input pattern -- for long
	# enough to run well past where the real wrapped tether should max out.
	var center: Vector2 = near_corner
	var max_pillar_pen: float = 0.0
	var max_chain_overshoot: float = 0.0
	var max_fold_jump: float = 0.0
	var prev_seg_pos: Array[Vector2] = []
	for seg in player._physics_rope_segments:
		var p3: Vector3 = (seg as RigidBody3D).global_position
		prev_seg_pos.append(Vector2(p3.x, p3.z))
	var fold_events: Array = []

	for tick in range(SETTLE_TICKS):
		var pos: Vector2 = player.get_pos_2d()
		var to_center: Vector2 = pos - center
		var tangent: Vector2 = Vector2(-to_center.y, to_center.x).normalized() if to_center.length() > 0.01 else Vector2(1, 0)
		var outward: Vector2 = to_center.normalized() if to_center.length() > 0.01 else Vector2(1, 0)
		var move_dir: Vector2 = (tangent * 0.8 + outward * 0.5).normalized()
		player.velocity = Vector3(move_dir.x, 0.0, move_dir.y) * MOVE_SPEED

		player._update_physics_rope_anchors()
		player.move_and_slide()
		player._clamp_to_rope_leash()
		await get_tree().physics_frame

		if tick % 5 != 0:
			continue

		var hand_pos: Vector3 = player._get_rope_hand_anchor_pos()
		var tip_pos: Vector3 = player._get_rope_tip_target()
		var hand_2d := Vector2(hand_pos.x, hand_pos.z)
		var tip_2d := Vector2(tip_pos.x, tip_pos.z)

		var seg_positions: Array[Vector2] = []
		var chain_len: float = 0.0
		var prev_pt: Vector2 = hand_2d
		var pen: float = 0.0
		for seg in player._physics_rope_segments:
			var p3: Vector3 = (seg as RigidBody3D).global_position
			var p2 := Vector2(p3.x, p3.z)
			seg_positions.append(p2)
			chain_len += prev_pt.distance_to(p2)
			prev_pt = p2
			if rect.has_point(p2):
				var this_pen: float = minf(p2.x - rect.position.x, rect.end.x - p2.x)
				this_pen = minf(this_pen, minf(p2.y - rect.position.y, rect.end.y - p2.y))
				pen = maxf(pen, this_pen)
		chain_len += prev_pt.distance_to(tip_2d)
		max_pillar_pen = maxf(max_pillar_pen, pen)
		var overshoot: float = chain_len - DART_ROPE_LENGTH
		max_chain_overshoot = maxf(max_chain_overshoot, overshoot)

		var fold_jump: float = 0.0
		if prev_seg_pos.size() == seg_positions.size():
			for i in range(seg_positions.size()):
				fold_jump = maxf(fold_jump, prev_seg_pos[i].distance_to(seg_positions[i]))
		max_fold_jump = maxf(max_fold_jump, fold_jump)
		if fold_jump > FOLD_JUMP_THRESHOLD:
			fold_events.append([tick, fold_jump])
		prev_seg_pos = seg_positions

		print("[TEST] tick=%d player=%s beeline_to_anchor=%.2f chain_len=%.2f (cap=%.1f, overshoot=%.2f) max_pillar_pen=%.3f fold_jump=%.2f" % [
			tick, player.get_pos_2d(), player.get_pos_2d().distance_to(anchor), chain_len, DART_ROPE_LENGTH, overshoot, max_pillar_pen, fold_jump])

	print("[TEST] RESULT max_chain_overshoot=%.3f max_pillar_penetration=%.4f max_fold_jump=%.2f fold_events=%d" % [
		max_chain_overshoot, max_pillar_pen, max_fold_jump, fold_events.size()])
	if fold_events.size() > 0:
		print("[TEST] fold events (tick, jump): %s" % [fold_events])
	if max_chain_overshoot > MAX_ACCEPTABLE_OVERSHOOT or max_pillar_pen > 0.001 or fold_events.size() > 0:
		print("[TEST] FAIL: chain overshot its own physical capacity, penetrated the pillar, and/or a zigzag fold was detected")
	else:
		print("[TEST] PASS: chain stayed within its own capacity, never penetrated the pillar, no fold jumps detected")
	print("LEASH_CORNER_TEST_DONE")


func _chain_path_length_2d(player, hand_2d: Vector2, tip_2d: Vector2) -> float:
	## Self-contained (doesn't call any player.gd method by name) so this test
	## measures identically whether or not player.gd has its own equivalent
	## helper yet -- only reads _physics_rope_segments' real positions,
	## duck-typed the same way the rest of this test (and
	## test_rope_obstacle_clip.gd before it) already does.
	if player._physics_rope_segments.is_empty():
		return hand_2d.distance_to(tip_2d)
	var total: float = 0.0
	var prev: Vector2 = hand_2d
	for seg in player._physics_rope_segments:
		var p3: Vector3 = (seg as RigidBody3D).global_position
		var p2d := Vector2(p3.x, p3.z)
		total += prev.distance_to(p2d)
		prev = p2d
	total += prev.distance_to(tip_2d)
	return total
