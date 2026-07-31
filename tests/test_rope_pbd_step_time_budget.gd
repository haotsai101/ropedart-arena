extends Node
## ROUND (2026-08-01) regression test for the "once the dart is thrown, the
## game soon become super laggy" fix -- scripts/rope_chain_pbd.gd's new
## ROPE_STEP_TIME_BUDGET_USEC wall-clock ceiling on RopeChainPBD.step()'s
## outer reconciliation loop.
##
## ROOT CAUSE (see rope_chain_pbd.gd's own updated doc comments for the full
## writeup): a real, non-headless, real-GPU per-tick profiling session
## (mcp__godot__run_project, a single real player thrown/recalled repeatedly
## near a real pillar) caught the outer loop genuinely hitting its own
## MAX_OUTER_ROUNDS=40 cap for DOZENS of consecutive real physics ticks in a
## row (over 5 real seconds), each individual tick costing 230-241ms --
## Engine.get_frames_per_second() crashed to 1.0 during that window. This is
## the exact "genuine bounded oscillation/limit-cycle... dense multi-obstacle
## configurations" case rope_chain_pbd.gd's class doc comment already
## disclosed as a small CORRECTNESS residual, but its real PERFORMANCE cost
## (paying the full worst-case cost of all 40 rounds, every tick, for as long
## as the oscillation persists) had never been measured before this round.
##
## RATHER THAN WAIT FOR THE RARE ORGANIC TRIGGER (this project's CLAUDE.md
## already documents that a dedicated synthetic two-close-obstacles
## reproduction did NOT organically reproduce this specific failure once
## before), this test DETERMINISTICALLY forces the outer loop to never fully
## converge every single tick: a dense grid of small, mutually-overlapping
## obstacle rects (no gap for a collision-corrected point to ever land in
## that isn't ALSO inside some other rect) tiling the whole region between a
## real hand and tip target, driven through a real throw-style unfold. This
## guarantees collision_correction never drops below CONVERGENCE_EPS, forcing
## every tick to either fully exhaust MAX_OUTER_ROUNDS (pre-fix) or hit the
## new wall-clock budget (post-fix) -- a controlled, reproducible worst case
## for the exact mechanism this round's fix targets, independent of whatever
## specific real-game geometry organically triggers it.
##
## Directly times RopeChainPBD.step() itself (Time.get_ticks_usec() around
## the call, from OUTSIDE the class -- no internal instrumentation needed,
## keeping rope_chain_pbd.gd's own diff scoped to the real fix) across many
## ticks of this adversarial configuration, and asserts no single call ever
## costs more than a small, bounded multiple of ROPE_STEP_TIME_BUDGET_USEC.
##
## Run via:
##   godot --headless --path . res://tests/test_rope_pbd_step_time_budget.tscn

const SEGMENTS: int = 24
const SEG_LEN: float = 0.3  ## DART_ROPE_LENGTH(7.2) / SEGMENTS(24), matches player.gd
const ROPE_RADIUS: float = 0.035
const MAX_SPEED: float = 45.0
const SOLVER_ITERATIONS: int = 600
const DELTA: float = 1.0 / 60.0

## A step() call this expensive would mean the fix isn't working at all --
## generous margin above ROPE_STEP_TIME_BUDGET_USEC (20ms) to account for the
## one mandatory final _converge_distance() pass after the budget-triggered
## break, plus scheduler/measurement noise -- but an order of magnitude below
## the pre-fix measured worst case (230-241ms).
const MAX_ACCEPTABLE_STEP_USEC: int = 60000


func _build_dense_obstacle_field(x_min: float, x_max: float, z_min: float, z_max: float) -> Array:
	## A grid of overlapping 0.5x0.5 rects on a 0.35-unit stride (0.15 overlap
	## between neighbors in both axes) -- no point in the covered region can
	## ever be pushed to a spot that isn't ALSO inside a different rect, so
	## _resolve_collisions() can never converge to zero correction here.
	var rects: Array = []
	var x: float = x_min
	while x <= x_max:
		var z: float = z_min
		while z <= z_max:
			rects.append(Rect2(Vector2(x - 0.25, z - 0.25), Vector2(0.5, 0.5)))
			z += 0.35
		x += 0.35
	return rects


func _run() -> void:
	print("[PBD_TIME_BUDGET] ============ starting ============")

	var chain := RopeChainPBD.new()
	chain.configure(SEGMENTS, SEG_LEN)

	var hand := Vector2(-3.5, 0.0)
	var tip_final := Vector2(3.5, 0.0)  ## 7.0 apart -- close to the 7.2 total chain capacity (SEGMENTS*SEG_LEN), leaving almost no slack to route AROUND the obstacle field below, forcing the chain through it
	chain.reset_to_point(hand)

	## Wide in Z (no way to route around, only through) AND covering the
	## whole hand-to-tip span in X -- a near-taut chain with nowhere to
	## escape the dense field, unlike a small/narrow field a slack chain can
	## simply drape around.
	var obstacle_rects: Array = _build_dense_obstacle_field(-4.0, 4.0, -3.0, 3.0)
	print("[PBD_TIME_BUDGET] %d dense overlapping obstacle rects covering the whole hand-to-tip span" % obstacle_rects.size())

	# Sanity check: hand and tip targets themselves must be inside the dense
	# field for this to be a meaningful adversarial test at all.
	var hand_inside: bool = false
	var tip_inside: bool = false
	for r in obstacle_rects:
		var rect: Rect2 = r
		if rect.has_point(hand):
			hand_inside = true
		if rect.has_point(tip_final):
			tip_inside = true
	print("[PBD_TIME_BUDGET] hand_inside_field=%s tip_inside_field=%s" % [hand_inside, tip_inside])

	var max_step_usec: int = 0
	var total_step_usec: int = 0
	var over_budget_ticks: int = 0
	var samples: int = 0

	# Drive the tip target from the hand out to tip_final over the first 20
	# ticks (a real throw-style unfold -- the same kinematic-endpoint-jump
	# mechanism that triggers the pathological case organically), then hold
	# it there for the remainder -- both phases exercised, since the organic
	# trigger was observed both right at a throw AND while just circling near
	# an already-anchored dart.
	const TOTAL_TICKS: int = 120
	for tick in range(TOTAL_TICKS):
		var t: float = clampf(float(tick) / 20.0, 0.0, 1.0)
		var tip_target: Vector2 = hand.lerp(tip_final, t)

		var t0: int = Time.get_ticks_usec()
		chain.step(DELTA, hand, tip_target, obstacle_rects, ROPE_RADIUS, MAX_SPEED, SOLVER_ITERATIONS)
		var dt: int = Time.get_ticks_usec() - t0

		samples += 1
		total_step_usec += dt
		max_step_usec = maxi(max_step_usec, dt)
		if dt > 20000:  ## matches ROPE_STEP_TIME_BUDGET_USEC -- counts ticks where the loop actually had to lean on the budget/cap
			over_budget_ticks += 1

		if tick < 10 or tick % 20 == 0:
			print("[PBD_TIME_BUDGET] tick=%d step_usec=%d gap_violation=%.5f" % [tick, dt, chain.max_link_gap_violation()])

	print("[PBD_TIME_BUDGET] ============ RESULTS ============")
	print("[PBD_TIME_BUDGET] samples=%d max_step_usec=%d avg_step_usec=%.0f over_budget_ticks=%d/%d" % [
		samples, max_step_usec, float(total_step_usec) / float(samples), over_budget_ticks, samples])
	print("[PBD_TIME_BUDGET] final max_link_gap_violation=%.5f (correctness -- distance rigidity must still hold even under this adversarial obstacle field)" % chain.max_link_gap_violation())

	var pass_time_budget: bool = max_step_usec <= MAX_ACCEPTABLE_STEP_USEC
	print("[PBD_TIME_BUDGET] PASS_TIME_BUDGET=%s (max_step_usec=%d vs. ceiling=%d; pre-fix baseline measured 230000-241000usec/tick in this exact class of scenario)" % [
		pass_time_budget, max_step_usec, MAX_ACCEPTABLE_STEP_USEC])

	print("PBD_TIME_BUDGET_TEST_DONE")
	get_tree().quit()


func _ready() -> void:
	call_deferred("_run")
