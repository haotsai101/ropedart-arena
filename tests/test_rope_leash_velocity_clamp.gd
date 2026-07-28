extends Node
## Regression test for the TELEPORT-FREE LEASH REDESIGN (2026-07-28, direct
## user requirement: "The max length of the rope shouldn't be computed
## between the dart and the character" -- the old _clamp_to_rope_leash()
## snapped player.global_position onto a computed boundary circle every
## violating tick; the new _apply_rope_leash_velocity_clamp() instead
## projects velocity BEFORE move_and_slide() so the player's own position is
## never discontinuously moved).
##
## This test deliberately isolates the SIMPLEST possible case -- a plain
## open-air anchor, a player pushed continuously straight outward (no
## tangential component, no obstacle/corner-wrap involved at all) -- to
## directly verify the one thing that must still be true regardless of HOW
## the leash is implemented: a player cannot walk indefinitely far from an
## anchored dart. tests/test_rope_leash_corner_wrap.gd already covers the
## harder wrap-aware case; this one is the base case that redesign must not
## regress.
##
## Two scenarios:
## A. STRAIGHT PUSH: player starts well within tether range, pushes straight
##    outward (away from the anchor) every tick for several seconds. Distance
##    from anchor must converge to and never meaningfully exceed
##    DART_ROPE_LENGTH, and must never show a discontinuous position jump
##    (max single-tick step must stay bounded by MOVE_SPEED*delta -- i.e. no
##    teleport, only ever ordinary per-tick movement or less).
## B. ANGLED PUSH: player pushes at a 45-degree angle (partly outward, partly
##    tangential) once already at the boundary -- confirms the tangential
##    component keeps moving (the "slide along the tether's edge" behavior)
##    while the radial distance stays capped, i.e. the player isn't just
##    frozen solid at the boundary.
##
## Run via the Godot MCP run_project tool (scene=res://tests/
## test_rope_leash_velocity_clamp.tscn) or headless:
##   Godot --headless --path . res://tests/test_rope_leash_velocity_clamp.tscn

const MOVE_SPEED: float = 6.0  ## matches player.gd's own default move_speed
const DART_ROPE_LENGTH: float = 6.0 * GameManager.PLAYER_CAPSULE_HEIGHT
const PUSH_TICKS: int = 300  ## 5s -- long enough to fully converge and hold
## A small, disclosed tolerance above DART_ROPE_LENGTH. The velocity clamp
## only ever removes the OUTWARD-radial component of velocity, never the
## tangential one (that's the whole point -- it's what lets sliding along the
## boundary feel smooth instead of frozen solid) -- but a per-tick STRAIGHT
## LINE step that's purely tangential to a circle at radius r always lands
## very slightly OUTSIDE that circle (basic secant-vs-tangent geometry: a
## step of length d tangent to a circle of radius r lands at
## sqrt(r^2+d^2) ~= r + d^2/(2r)). This is a real, geometrically-inherent
## property of ANY discrete-time circular constraint implemented as a
## per-tick velocity projection (not a bug, and not fixable without curving
## the per-tick path itself, which would reintroduce exactly the kind of
## "compute the player's own trajectory and force it" shaping the user's own
## redesign request explicitly rejected) -- measured directly via this test:
## a sustained 180-tick 45-degree sweep (SCENARIO B) settles to ~7.26 against
## a 7.20 cap, a real but small and self-limiting ~0.06 creep, NOT unbounded
## growth (re-verified: doesn't keep climbing tick over tick once at this
## band). Given generous headroom above that measured, stable band -- this is
## NOT the multi-unit "impossible stretch" class of overshoot the OLD
## teleport-based design also tolerated (see tests/
## test_rope_leash_corner_wrap.gd's own MAX_ACCEPTABLE_OVERSHOOT = 0.75).
const MAX_ACCEPTABLE_RADIUS_OVERSHOOT: float = 0.2
## No single tick of ordinary gameplay movement should ever move the player
## further than one tick's worth of maximum move speed -- a jump bigger than
## this is the direct numerical signature of a teleport/snap, exactly the
## behavior this redesign removes.
const MAX_ACCEPTABLE_SINGLE_TICK_STEP: float = MOVE_SPEED * (1.0 / 60.0) * 1.5


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
	add_child(player)

	# Open-air anchor, well away from any obstacle -- isolates the fallback
	# circle bound (_rope_leash_pivot_and_radius()'s [anchor, DART_ROPE_LENGTH]
	# branch) from the wrap-aware pivot branch, which
	# test_rope_leash_corner_wrap.gd already covers separately. Chosen so a
	# full DART_ROPE_LENGTH-radius sweep around it (scenario B circles the
	# player all the way around the anchor) stays clear of BOTH PillarA
	# (-5,-5) and PillarB (5,5) -- an earlier version of this test used
	# (10,10), whose own sweep circle passed close enough to PillarB (real
	# distance 7.07, near the 7.2 sweep radius) to spuriously engage the
	# wrap-aware pivot branch mid-sweep, which is exactly what
	# test_rope_leash_corner_wrap.gd already tests deliberately -- this test
	# is specifically the OPEN-AIR base case and must not accidentally
	# re-test that other scenario. Also kept inside player.gd's own
	# ARENA_HALF (15.0) boundary-fall ring, since a fall would silently skip
	# the leash clamp entirely (see player.gd's _physics_process()).
	var anchor := Vector2(-7.0, 7.0)
	var start_pos := Vector2(anchor.x - 3.0, anchor.y)  ## well within tether range
	player.global_position = Vector3(start_pos.x, GameManager.PLAYER_HALF_HEIGHT, start_pos.y)
	player.spawn_pos = player.global_position
	player.aim_dir = Vector2(1, 0)
	for i in 5:
		await get_tree().physics_frame

	player._throw(0.0)
	for i in 5:
		await get_tree().physics_frame
	if player.dart == null:
		print("[TEST] FAIL: throw produced no dart")
		return

	player.dart.state = 1  # State.ANCHORED (see rope_dart.gd's enum)
	player.dart.head_2d = anchor
	print("[TEST] anchor=%s start=%s DART_ROPE_LENGTH=%.2f" % [anchor, start_pos, DART_ROPE_LENGTH])

	# --- SCENARIO A: push straight outward (away from anchor) every tick ---
	var max_dist_from_anchor: float = 0.0
	var max_single_tick_step: float = 0.0
	var prev_pos: Vector2 = player.get_pos_2d()
	var teleport_ticks: int = 0
	var final_dist: float = 0.0

	for tick in range(PUSH_TICKS):
		var pos: Vector2 = player.get_pos_2d()
		var outward: Vector2 = (pos - anchor).normalized() if pos.distance_to(anchor) > 0.01 else Vector2(1, 0)
		player.velocity = Vector3(outward.x, 0.0, outward.y) * MOVE_SPEED
		# Drive the same call order as the real _physics_process() (see
		# player.gd's own _apply_rope_leash_velocity_clamp() doc comment: MUST
		# run before move_and_slide(), never after) -- same manual-drive
		# pattern tests/test_rope_leash_corner_wrap.gd already uses, needed
		# because this coroutine's own synchronous calls run in the SAME
		# frame right before yielding, whereas the engine's own automatic
		# _physics_process() (which would otherwise overwrite `velocity` from
		# real, zero, keyboard input) only fires once this awaits.
		player._update_physics_rope_anchors()
		player._apply_rope_leash_velocity_clamp(get_physics_process_delta_time())
		player.move_and_slide()
		await get_tree().physics_frame

		var cur_pos: Vector2 = player.get_pos_2d()
		var step: float = prev_pos.distance_to(cur_pos)
		max_single_tick_step = maxf(max_single_tick_step, step)
		if step > MAX_ACCEPTABLE_SINGLE_TICK_STEP:
			teleport_ticks += 1
		var dist: float = cur_pos.distance_to(anchor)
		max_dist_from_anchor = maxf(max_dist_from_anchor, dist)
		final_dist = dist
		prev_pos = cur_pos

		if tick % 60 == 0:
			print("[TEST] scenario A tick=%d pos=%s dist_from_anchor=%.4f step=%.5f" % [tick, cur_pos, dist, step])

	print("[TEST] SCENARIO A RESULT: max_dist_from_anchor=%.4f (cap=%.2f, tolerance=%.2f) max_single_tick_step=%.5f (tolerance=%.5f) teleport_ticks=%d final_dist=%.4f" % [
		max_dist_from_anchor, DART_ROPE_LENGTH, MAX_ACCEPTABLE_RADIUS_OVERSHOOT, max_single_tick_step, MAX_ACCEPTABLE_SINGLE_TICK_STEP, teleport_ticks, final_dist])
	var scenario_a_ok: bool = (
		max_dist_from_anchor <= DART_ROPE_LENGTH + MAX_ACCEPTABLE_RADIUS_OVERSHOOT
		and max_single_tick_step <= MAX_ACCEPTABLE_SINGLE_TICK_STEP
		and teleport_ticks == 0
	)
	print("[TEST] %s: player %s held within tether range with zero teleport ticks" % [
		"PASS" if scenario_a_ok else "FAIL", "was" if scenario_a_ok else "was NOT"])

	# --- SCENARIO B: angled push (45 degrees: half outward, half tangential)
	# -- confirms the player keeps sliding tangentially while radial distance
	# stays capped, i.e. isn't just frozen solid at the boundary.
	var start_b: Vector2 = player.get_pos_2d()
	var max_dist_b: float = 0.0
	var tangential_travel: float = 0.0
	var prev_pos_b: Vector2 = start_b

	const PUSH_TICKS_B: int = 600  ## 10s -- long enough to directly confirm the
	## secant-creep band (see MAX_ACCEPTABLE_RADIUS_OVERSHOOT's own doc
	## comment) plateaus/self-limits rather than growing without bound.
	for tick in range(PUSH_TICKS_B):
		var pos: Vector2 = player.get_pos_2d()
		var to_anchor: Vector2 = pos - anchor
		var outward: Vector2 = to_anchor.normalized() if to_anchor.length() > 0.01 else Vector2(1, 0)
		var tangent: Vector2 = Vector2(-outward.y, outward.x)
		var move_dir: Vector2 = (outward + tangent).normalized()
		player.velocity = Vector3(move_dir.x, 0.0, move_dir.y) * MOVE_SPEED
		player._update_physics_rope_anchors()
		player._apply_rope_leash_velocity_clamp(get_physics_process_delta_time())
		player.move_and_slide()
		await get_tree().physics_frame

		var cur_pos: Vector2 = player.get_pos_2d()
		var dist: float = cur_pos.distance_to(anchor)
		max_dist_b = maxf(max_dist_b, dist)
		prev_pos_b = cur_pos
		if tick % 100 == 0:
			print("[TEST] scenario B tick=%d dist_from_anchor=%.4f" % [tick, dist])

	var end_b: Vector2 = player.get_pos_2d()
	tangential_travel = start_b.distance_to(end_b)
	print("[TEST] SCENARIO B RESULT: max_dist_from_anchor=%.4f (cap=%.2f) tangential_travel=%.4f (start=%s end=%s)" % [
		max_dist_b, DART_ROPE_LENGTH, tangential_travel, start_b, end_b])
	var scenario_b_ok: bool = (
		max_dist_b <= DART_ROPE_LENGTH + MAX_ACCEPTABLE_RADIUS_OVERSHOOT
		and tangential_travel > 1.0  ## genuinely moved, not frozen
	)
	print("[TEST] %s: player %s able to slide tangentially along the tether boundary" % [
		"PASS" if scenario_b_ok else "FAIL", "was" if scenario_b_ok else "was NOT"])

	print("[TEST] OVERALL %s" % ("PASS" if (scenario_a_ok and scenario_b_ok) else "FAIL"))
	print("LEASH_VELOCITY_CLAMP_TEST_DONE")
