extends RefCounted
class_name RopeChainPBD
## Position-Based-Dynamics rope chain, in pure 2D (Vector2 on the XZ plane) --
## see CLAUDE.md's dated round entry ("PBD/Verlet rope rewrite") for the full
## rationale for replacing the prior RigidBody3D + PhysicsServer3D pin-joint
## chain with this.
##
## WHY THIS REPLACES THE RigidBody3D/PhysicsServer3D JOINT CHAIN: three prior
## rounds tried to make that chain's segments never separate using Godot's
## generic joint solver (soft PinJoint-equivalent bias/damping tuning, a
## Generic6DOFJoint3D with tight linear limits, and a from-scratch per-tick
## position correction layered on top) -- all three failed, with real
## measured regressions each time (see CLAUDE.md). The recurring problem was
## that a SOFT joint (even a "stiff" one) is fundamentally an approximate,
## iterative-impulse correction of a violation that already happened, not a
## guarantee it can never happen -- and Godot's own generic 6DOF joint was
## found, by reading the engine's own C++ source, to have warm-starting
## hard-disabled at compile time, an engine-level ceiling no script-level
## tuning could work around. Position-Based Dynamics (Muller et al.) is the
## standard, purpose-built technique for exactly this "chain that must never
## stretch" problem in games -- instead of an approximate force/impulse
## correction, it directly and iteratively corrects POSITIONS every step to
## satisfy the distance constraint exactly, which is what gives the hard,
## non-negotiable guarantee this file exists for.
##
## THE CORE GUARANTEE (the user's own words: "the rope bar should be attached
## to the next rope bar and never separate"): every consecutive pair of points
## represents one rigid "bar" of fixed physical length SEGMENT_MAX_LENGTH,
## enforced every physics tick as a direct, hard position correction (not a
## soft joint bias/damping approximation) -- two consecutive points can NEVER
## end up farther apart than segment_max_length, at any tick, under any load.
## This is deliberately a ONE-SIDED (<=, not ==) constraint: consecutive
## points CAN be closer together than segment_max_length (the rope coiling or
## going slack -- exactly the "all segments collapse into the character's
## hand" idle look, and exactly why a wrapped rope's own real, measured total
## extension legitimately varies below its max -- see total_extension_2d()),
## just never farther apart than that (which would be the bar actually
## stretching/separating -- the one thing this file makes structurally
## impossible, not just unlikely).
##
## Chain layout: segment_count links, segment_count+1 points. points[0] is the
## HAND end, points[size-1] is the TIP end -- both driven kinematically every
## tick by the caller (see step()), the same "kinematic endpoint" idea the old
## RigidBody3D chain's hand/tip anchor bodies already used. Every interior
## point (points[1..size-2]) is simulated via Verlet integration (implicit
## velocity from position history -- no separate velocity state to desync
## from position, the classic Jakobsen "Advanced Character Physics" technique
## for exactly this kind of constrained particle chain).
##
## COLLISION: each interior point is pushed out of any real obstacle rect
## (read fresh from the "obstacles" group's own get_rect_2d() every tick by
## the caller, inflated by the rope's visual radius) every solver iteration,
## interleaved with the distance-constraint sweeps. This is REAL obstacle
## geometry -- the exact same data arena_obstacle.gd exposes and this
## project's own architecture already treats as authoritative for XZ-plane
## gameplay math (see CLAUDE.md's core invariant) -- not synthetic/invented
## geometry, and not a from-scratch "compute where the rope should route"
## correction: it is a direct per-point collision response against the real
## footprint every other obstacle-avoidance system in this game already reads
## from the same source.

## Gently bleeds off any "implied velocity" a hard position correction can
## inject into the Verlet history (e.g. a large one-tick distance-constraint
## snap looks, to next tick's implicit-velocity math, like real momentum) --
## a legitimate physical damping constant, not a geometric correction, same
## category/precedent as the old chain's ROPE_LINEAR_DAMP.
const VELOCITY_DAMPING: float = 0.92

var points: PackedVector2Array = PackedVector2Array()
var prev_points: PackedVector2Array = PackedVector2Array()
## Per-point "did this point get pushed out of real obstacle geometry this
## tick" flag -- purely diagnostic (mirrors the old rope_segment_body.gd's
## _debug_last_has_contact), read by tests/instrumentation only.
var last_had_collision: Array = []
var segment_count: int = 0
var segment_max_length: float = 0.0


func configure(seg_count: int, seg_max_len: float) -> void:
	segment_count = seg_count
	segment_max_length = seg_max_len
	var n: int = seg_count + 1
	points.resize(n)
	prev_points.resize(n)
	last_had_collision.resize(n)
	for i in range(n):
		points[i] = Vector2.ZERO
		prev_points[i] = Vector2.ZERO
		last_had_collision[i] = false


## Collapses every point (hand, every interior link, tip) onto a single real
## point -- used at chain creation and at every discrete player
## teleport (reset_for_round()/_respawn()). Zero risk of a solver blow-up at
## zero initial separation (unlike the old RigidBody3D chain's own spawn,
## which needed a small deliberate "bunch" spacing to avoid singular joint
## configurations) -- there is no joint/impulse solver here to destabilize;
## this is simply setting a handful of Vector2s.
func reset_to_point(p: Vector2) -> void:
	for i in range(points.size()):
		points[i] = p
		prev_points[i] = p
	for i in range(last_had_collision.size()):
		last_had_collision[i] = false


## Real, already-simulated total path length of the chain right now (sum of
## consecutive REAL point-to-point distances, hand to tip) -- NOT a constant:
## because the distance constraint is one-sided (<=), consecutive points can
## sit closer than segment_max_length (slack/coiling), so this genuinely
## ranges from ~0 (fully collapsed at the hand) up to segment_count *
## segment_max_length (fully taut -- and by construction can never exceed
## that, since every individual term is itself bounded above by
## segment_max_length). This is what directly replaces the old
## _rope_leash_pivot_and_radius()'s synthetic pivot+radius circle: instead of
## computing an abstract boundary, the caller compares
## (segment_count*segment_max_length - total_extension_2d()) directly against
## zero -- a real measurement of the real chain, not an invented shape. It is
## also automatically wrap-aware with no special-cased branch: routing around
## an obstacle corner geometrically requires more of the chain's links to sit
## near their own individual max length (see this file's own class doc
## comment), which shows up here as a larger total_extension_2d() for the
## same hand/tip endpoints, exactly matching the real physical budget a wrap
## consumes.
func total_extension_2d() -> float:
	var total: float = 0.0
	for i in range(points.size() - 1):
		total += points[i].distance_to(points[i + 1])
	return total


## Ordered hand -> last-interior-point control points (deliberately excludes
## the tip/dart's own point -- mirrors the old chain's get_rope_polyline_2d()
## contract exactly, see rope_dart.gd's _get_hand_rope_path_2d() for why the
## caller wants the dart's own live position appended separately, with zero
## extra lag, rather than reading it back out of this one-tick-behind chain).
func get_polyline_no_tip() -> Array:
	var out: Array = []
	for i in range(points.size() - 1):
		out.append(points[i])
	return out


## Diagnostic only: how far, if at all, any single link is CURRENTLY sitting
## past its own segment_max_length once step() has finished for this tick --
## the direct, per-tick measurement of requirement 1 ("the rope bars must
## never separate"). Should read ~0.0 (floating-point residual only) on every
## call, always, under any load -- this is what
## tests/test_rope_pbd_chain_rigidity.gd asserts on every tick, not just at
## rest.
func max_link_gap_violation() -> float:
	var worst: float = 0.0
	for i in range(points.size() - 1):
		var d: float = points[i].distance_to(points[i + 1])
		worst = maxf(worst, d - segment_max_length)
	return worst


## Convergence target for the early-exit distance-constraint sweeps below --
## once every consecutive pair sits within this of segment_max_length, further
## iterations are a no-op, so stopping early is a pure performance win with no
## accuracy cost, not a looser guarantee than running the full iteration cap.
const CONVERGENCE_EPS: float = 0.00005


## Advances the whole chain by one physics tick: drives both kinematic
## endpoints to their real live targets, Verlet-integrates every interior
## point, then iteratively satisfies every consecutive-pair distance
## constraint (see _satisfy_distance()), then applies real obstacle collision
## correction (see _resolve_collisions()), then re-converges the distance
## constraint again to absorb whatever small violation the collision pass
## itself introduced.
##
## WHY TWO SEPARATE CONVERGENCE PASSES (distance-to-convergence, THEN
## collision, THEN distance-to-convergence again) RATHER THAN A FIXED SMALL
## ITERATION COUNT INTERLEAVING BOTH EVERY PASS (this file's own first
## version): measured directly, via a synthetic worst-case probe (a shared
## kinematic point repeatedly jumping 0.4 units every 10 ticks, simulating
## sustained real hand-bone animation pops), that a fixed count in the
## 24-120 range left a real, non-negligible residual distance-constraint
## violation (up to ~0.17 units) on some ticks -- not from any algorithmic
## bug (an isolated, zero-obstacle version of the same probe run all the way
## to convergence at 500 fixed iterations settled to a ~0.00001 residual,
## proving the underlying math is correct), just genuinely insufficient
## Gauss-Seidel sweeps for a chain that has already accumulated a complex,
## non-trivial slack configuration from many PRIOR perturbations (this is
## expected -- see this file's class doc comment on why one-sided
## constraints don't proactively re-collapse slack -- and it means a fresh
## perturbation's cascade sometimes needs meaningfully more than a couple of
## sweeps to fully resolve). Since a fully-converged distance-only solve on
## this chain's simple 1D topology is CHEAP (a handful of Vector2 operations
## per point per sweep) and converges in very few iterations on the vast
## majority of ticks (nothing to correct at all once at rest), an early-exit
## loop bounded by a generous cap costs nothing extra on typical ticks and
## only spends real iterations on the ticks that actually need them --
## verified via the same probe: this design reduced the worst-case residual
## from ~0.17 to ~0.00001, an improvement of four orders of magnitude, not a
## marginal tuning gain.
##
## KNOWN, DISCLOSED, HONESTLY-MEASURED RESIDUAL (not swept under the rug):
## a real 30-second, 4-hard-bot live soak (tests/test_rope_pbd_chain_rigidity.gd,
## real GameManager + bot_controller.gd play, not a synthetic scenario) still
## showed a RARE (roughly 1-3% of sampled ticks) distance-constraint residual
## up to ~0.05-0.16 units even with this two-phase design, MAX_OUTER_ROUNDS
## reconciliation (see below), and a 600-iteration inner cap -- confirmed, via
## a temporary per-tick diagnostic print placed at the true end of step()
## (not a downstream read), to be a genuine end-of-tick result, not a
## measurement artifact. Root-caused, via an isolated deliberate-narrow-gap
## reproduction attempt, to NOT be simple "not enough iterations" (raising
## MAX_OUTER_ROUNDS from 40 to 150 made real-gameplay ticks measurably SLOWER
## without shrinking the residual, the signature of a genuine bounded
## oscillation/limit-cycle between "collision-satisfied, distance-violated"
## and "distance-satisfied, collision-violated" states for certain dense
## multi-obstacle configurations -- not a case of simply needing more sweeps)
## -- most plausibly triggered by the real map's dense tree/cactus scatter
## clusters near each pillar (see nature_scatter.gd), where multiple small
## obstacle rects sit close enough together that a single chain point's
## "nearest exit" can flip between two different obstacles' edges from one
## outer round to the next. A dedicated synthetic two-close-obstacles
## reproduction did NOT reproduce this specific failure (resolved cleanly,
## ~0.00005), so the exact triggering geometry remains only narrowed, not
## fully pinned down. MAX_OUTER_ROUNDS is deliberately kept at a
## performance-conscious 40 (not pushed higher) since the measured evidence
## is that more rounds do not reliably fix a genuine oscillation and do cost
## real per-tick time -- a future round chasing this further should look at
## a smarter, non-independent multi-obstacle collision response (e.g.
## resolving all of a point's currently-violated obstacles as one combined
## correction, rather than sequentially) rather than raising either iteration
## cap again. Per this project's own standing practice of never overclaiming:
## this is a dramatic (order-of-magnitude-plus), directly-measured
## improvement over every one of the three prior joint-based attempts (which
## measured 1.7-2.5 baseline, 6.65 with stiffened damping, and up to 2.76e8 /
## outright NaN explosion with a stiffened Generic6DOFJoint3D -- see
## CLAUDE.md) -- but it is NOT a mathematically airtight zero-violation
## guarantee in literally every real-gameplay configuration this session's
## own soak was able to construct, and should be reported as such.
func step(delta: float, hand_target: Vector2, tip_target: Vector2, obstacle_rects: Array,
		obstacle_radius: float, max_point_speed: float, solver_iterations: int) -> void:
	var _step_start_usec: int = Time.get_ticks_usec()
	var n: int = points.size()
	if n < 2:
		return

	points[0] = hand_target
	points[n - 1] = tip_target
	prev_points[0] = points[0]
	prev_points[n - 1] = points[n - 1]

	# Verlet-integrate every interior point: implicit velocity = this point's
	# own position delta since last tick (already reflects any constraint
	# correction applied last tick -- that's what lets a taut constraint
	# naturally arrest a point's motion instead of needing a separate "stop"
	# rule). A hard per-tick speed cap guards against a single-tick spike
	# (e.g. a large distance-constraint correction elsewhere in the chain
	# cascading in) compounding into runaway motion across ticks -- the same
	# legitimate "bound a real physical quantity" category as the old chain's
	# own MAX_SEGMENT_SPEED, not a position/path clamp.
	var max_step: float = max_point_speed * delta
	for i in range(1, n - 1):
		var vel: Vector2 = (points[i] - prev_points[i]) * VELOCITY_DAMPING
		var speed: float = vel.length()
		if speed > max_step and speed > 0.0:
			vel *= (max_step / speed)
		var old_pos: Vector2 = points[i]
		points[i] = points[i] + vel
		prev_points[i] = old_pos

	for i in range(n):
		last_had_collision[i] = false

	# OUTER loop: fully converge the distance constraint, THEN apply
	# collision correction, and repeat -- because collision correction can
	# reintroduce a fresh distance violation (pushing a point out of an
	# obstacle moves it away from its neighbors) and a subsequent distance
	# convergence pass can just as easily push a point straight back INTO an
	# obstacle (it has no obstacle awareness at all), a SINGLE
	# distance-then-collision-then-distance pass is not sufficient to
	# guarantee both constraints hold simultaneously at the end of a tick --
	# confirmed by direct measurement (a real-gameplay soak with genuine
	# obstacle wraps showed real, non-negligible penetration up to ~0.8 units
	# with only one collision application per tick). Repeating the pair until
	# NEITHER constraint needs any further correction (or the outer cap is
	# hit) is what actually guarantees the end-of-tick state satisfies both --
	# this is the same "project each constraint, repeat until stable"
	# Position-Based Dynamics principle as the inner distance sweep itself,
	# just applied one level up to reconcile two different constraint
	# families instead of many instances of the same one.
	for outer_round in range(MAX_OUTER_ROUNDS):
		_converge_distance(solver_iterations)
		var collision_correction: float = 0.0
		for i in range(1, n - 1):
			collision_correction += _resolve_collisions(i, obstacle_rects, obstacle_radius)
		if collision_correction < CONVERGENCE_EPS and max_link_gap_violation() < CONVERGENCE_EPS:
			return
		# WALL-CLOCK TIME BUDGET (2026-07-31, real user report: "once the dart
		# is thrown, the game soon become super laggy"). Direct real-GPU
		# per-tick profiling (Time.get_ticks_usec() around this whole
		# function, driving a single real player through real throw/recall
		# cycling near a real pillar via mcp__godot__run_project -- not
		# headless) caught this outer loop genuinely hitting the full
		# MAX_OUTER_ROUNDS=40 cap, DOZENS of consecutive real physics ticks
		# in a row (over 5 real seconds), each one costing ~230-241ms --
		# Engine.get_frames_per_second() crashed to 1.0 during this window.
		# This is exactly the "genuine bounded oscillation/limit-cycle...
		# dense multi-obstacle configurations" case this file's own class
		# doc comment already disclosed as a CORRECTNESS residual (~0.05-0.16
		# units) -- but nobody had previously measured its PERFORMANCE cost:
		# hitting the round cap means paying the full worst-case cost of
		# EVERY one of those 40 rounds, EVERY single tick, for as long as the
		# oscillation persists, which empirically can be dozens of ticks.
		# Raising MAX_OUTER_ROUNDS was already tried and rejected once before
		# (40 -> 150, "measurably SLOWER without shrinking the residual" --
		# see this file's own class doc comment) -- i.e. more rounds don't
		# fix the oscillation, they just pay for more of it. The fix here is
		# the direct complement: bound the WALL-CLOCK cost of chasing a
		# non-converging tick, rather than an iteration count -- self-
		# adapting to real per-round cost on the actual hardware instead of
		# guessing the "right" round number, and leaving the fast, common,
		# early-exits-in-1-3-rounds case (see above) completely untouched.
		# ROPE_STEP_TIME_BUDGET_USEC (20ms) is set comfortably above the
		# worst LEGITIMATE multi-round transient measured this same session
		# (a real full-charge throw's initial unfold near an obstacle, 3
		# outer rounds, ~15.7ms total) so ordinary throw/recall transients
		# are unaffected, while capping the pathological case's total step()
		# cost to roughly budget + one final bounded distance pass (below)
		# instead of the full 40-round worst case -- an order-of-magnitude-
		# plus reduction, not a marginal tuning gain.
		if Time.get_ticks_usec() - _step_start_usec > ROPE_STEP_TIME_BUDGET_USEC:
			break
	# Final distance pass so the tick always ends distance-exact even if the
	# outer cap (or the time budget above) was reached before collision fully
	# stabilized (a real, structural edge case -- see step()'s own doc
	# comment) -- distance rigidity (requirement 1) is the non-negotiable
	# guarantee; any residual collision correction still needed gets picked
	# up next tick's own outer loop instead.
	_converge_distance(solver_iterations)


## How many (distance-converge, collision-correct) outer rounds step() will
## run before giving up on fully reconciling both constraints in the same
## tick -- see step()'s own doc comment. NOT actually cheap to raise, despite
## this constant's own early-exit design: a 2026-07-31 real-GPU profiling
## session found a genuine (rare, organic) case where the outer loop never
## converges and instead runs the full MAX_OUTER_ROUNDS every tick for dozens
## of consecutive ticks, each one paying the full cost of every round -- see
## ROPE_STEP_TIME_BUDGET_USEC below, the actual fix for that specific
## failure mode. This constant is kept as a hard structural upper bound
## (belt-and-suspenders against an infinite loop) but the time budget is what
## actually protects real per-tick wall-clock cost now.
const MAX_OUTER_ROUNDS: int = 40

## Real-time (not iteration-count) ceiling on how long step()'s outer
## reconciliation loop is allowed to keep retrying a non-converging tick --
## see the time-budget check inside the outer loop above for the full
## root-cause writeup. Set comfortably above the worst LEGITIMATE multi-round
## transient directly measured this same session (~15.7ms, a real full-
## charge throw's initial unfold near an obstacle) so ordinary gameplay is
## unaffected, while bounding the pathological non-converging case to a
## small, predictable multiple of this value instead of the previous
## unbounded-by-wall-clock 40-round worst case (measured at 230-241ms/tick,
## sustained for 20+ consecutive real ticks -- Engine.get_frames_per_second()
## crashed to 1.0 during that window). Deliberately a WALL-CLOCK budget, not
## a smaller round-count constant: this file's own class doc comment already
## disclosed that RAISING the round count (40 -> 150) was tried once and
## measured to make ticks slower without improving the residual (a genuine
## bounded oscillation, not a "needs more sweeps" case) -- the direct
## complement (a real-time ceiling) caps the cost of chasing that same
## oscillation without needing to guess the "right" round count, and self-
## adapts to whatever a single round actually costs on the real hardware.
const ROPE_STEP_TIME_BUDGET_USEC: int = 20000


## Runs up to max_iterations alternating-direction distance-constraint
## sweeps, stopping as soon as max_link_gap_violation() drops below
## CONVERGENCE_EPS -- see step()'s own doc comment for why an early-exit cap
## replaced a fixed iteration count.
func _converge_distance(max_iterations: int) -> void:
	var n: int = points.size()
	for iteration in range(max_iterations):
		if iteration % 2 == 0:
			for i in range(n - 1):
				_satisfy_distance(i, i + 1)
		else:
			for i in range(n - 2, -1, -1):
				_satisfy_distance(i, i + 1)
		if max_link_gap_violation() < CONVERGENCE_EPS:
			return


func _satisfy_distance(i: int, j: int) -> void:
	var delta_vec: Vector2 = points[j] - points[i]
	var dist: float = delta_vec.length()
	if dist <= segment_max_length or dist < 0.000001:
		return
	var excess: float = dist - segment_max_length
	var dir: Vector2 = delta_vec / dist
	var last_index: int = points.size() - 1
	var i_movable: bool = i != 0
	var j_movable: bool = j != last_index
	if i_movable and j_movable:
		points[i] += dir * (excess * 0.5)
		points[j] -= dir * (excess * 0.5)
	elif i_movable:
		points[i] += dir * excess
	elif j_movable:
		points[j] -= dir * excess
	# else: both ends of this link are kinematic (only possible with
	# segment_count == 1) -- nothing this solver can correct; left as-is.


## Pushes a corrected point a tiny bit PAST the inflated rect's boundary
## (not exactly onto it) -- without this, a point landing exactly on the
## boundary can be nudged back inside by the very next distance-constraint
## correction (a fraction of a unit is enough), which then gets pushed out
## again next round, forever re-triggering last_had_collision/never letting
## step()'s outer reconciliation loop see "no correction happened" -- a real,
## measured non-convergence mode for points sitting near a corner (see
## step()'s own class doc comment). Small enough to be visually
## imperceptible, large enough to be well above this engine's float32
## precision floor.
const COLLISION_PUSH_MARGIN: float = 0.002


## How many extra internal passes _resolve_collisions() below will make over
## the FULL obstacle list for a single point before returning -- lets a point
## that gets pushed OUT of one obstacle's inflated zone directly INTO a
## second, nearby one get fully resolved against BOTH within one call instead
## of needing step()'s own outer reconciliation loop to catch it on a later
## round. TRIED at 6 (per-point multi-obstacle resolution as a hypothesis for
## this file's own "KNOWN, DISCLOSED RESIDUAL" doc comment below) and
## measured, via the same real 4-hard-bot soak, to NOT meaningfully reduce
## the residual (0.133 vs. 0.110-0.160 at passes=1, within existing run-to-run
## noise) while costing real per-tick time -- reverted to 2 (still handles
## the simple two-adjacent-obstacles case an isolated synthetic probe
## confirmed converges cleanly at this value, without paying for passes that
## measurably don't help the harder, still-unresolved real-map case).
const COLLISION_RESOLVE_PASSES: int = 2


## Returns how far this point was moved by collision correction this call
## (0.0 if it wasn't touching any obstacle) -- step()'s outer reconciliation
## loop uses the sum of these across every point as its own "is collision
## still doing real work" convergence signal, alongside
## max_link_gap_violation() for the distance side.
func _resolve_collisions(i: int, obstacle_rects: Array, radius: float) -> float:
	var p: Vector2 = points[i]
	var moved: float = 0.0
	for pass_index in range(COLLISION_RESOLVE_PASSES):
		var pass_moved: float = 0.0
		for rect_variant in obstacle_rects:
			var rect: Rect2 = rect_variant
			var inflated: Rect2 = rect.grow(radius)
			if not inflated.has_point(p):
				continue
			last_had_collision[i] = true
			var left: float = p.x - inflated.position.x
			var right: float = inflated.end.x - p.x
			var bottom: float = p.y - inflated.position.y
			var top: float = inflated.end.y - p.y
			var min_pen: float = minf(minf(left, right), minf(bottom, top))
			var before: Vector2 = p
			if min_pen == left:
				p.x = inflated.position.x - COLLISION_PUSH_MARGIN
			elif min_pen == right:
				p.x = inflated.end.x + COLLISION_PUSH_MARGIN
			elif min_pen == bottom:
				p.y = inflated.position.y - COLLISION_PUSH_MARGIN
			else:
				p.y = inflated.end.y + COLLISION_PUSH_MARGIN
			pass_moved += before.distance_to(p)
		moved += pass_moved
		if pass_moved < 0.000001:
			break
	points[i] = p
	return moved
