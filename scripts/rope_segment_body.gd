extends RigidBody3D
## Dynamic physics body for one link of player.gd's thrown-rope physics
## chain (see player.gd's ROPE_PHYSICS_* consts / _spawn_physics_rope()).
##
## Per explicit user requirement -- "I want the rope to disregard gravity and
## live on a plane" -- every segment must never leave the dart's fixed
## plane_y height (see rope_dart.gd's own class doc comment on why the whole
## rope+dart system already lives at one fixed horizontal plane; this just
## extends that same invariant to the rope's physics simulation).
##
## Two layers of enforcement, deliberately redundant:
##  1. The caller (player.gd's _make_rope_segment_body()) sets gravity_scale
##     to 0 -- the cleanest, most literal way to satisfy "disregard gravity":
##     no downward force is ever applied at all, rather than being applied
##     and then corrected after the fact.
##  2. _integrate_forces() below is Godot's own documented, solver-safe entry
##     point for overriding a RigidBody3D's transform/velocity each physics
##     step (PhysicsDirectBodyState3D) -- directly poking global_position
##     from OUTSIDE physics processing (e.g. once per _physics_process() tick
##     in player.gd, the way the kinematic hand/tip anchors are driven) is
##     explicitly discouraged by Godot's own docs as producing "unpredictable
##     behavior," since it fights the solver's already-computed contact/joint
##     resolution for that step instead of being incorporated into it. This
##     is the actual authoritative fix: it clamps Y back to locked_y and
##     zeroes vertical velocity every physics step, catching any Y drift from
##     the joint solver itself (not just gravity) -- e.g. the joint's own
##     positional-correction bias nudging a segment toward a neighbor that
##     has (for whatever transient numerical reason) drifted off-plane.
##
## Root-cause note (why this file exists at all): an earlier version of this
## chain had NEITHER of the above -- full default gravity, no Y constraint --
## and real user footage (a screen recording, not just a screenshot) showed
## the anchored rope collapsing to a tiny ~0.3-0.5 unit hanging stub next to
## the dart within moments of anchoring, staying that way for many seconds
## even with the character standing several grid cells away. Root cause:
## default PIN_JOINT_BIAS/DAMPING (left at PhysicsServer3D's own un-stiffened
## defaults -- see player.gd's ROPE_PHYSICS_* comment for why a stiffer
## tuning was already tried once and found to make the chain explode) only
## SOFTLY corrects joint position error each step; against a constant,
## continuous downward pull from gravity on light (low-mass) dynamic
## segments, that soft correction can't keep the chain taut across a real
## multi-unit anchored span -- it settles into some other equilibrium
## instead, which visually reads as exactly this collapse. A short synthetic
## soak test run right after a throw (this session's own prior verification)
## never caught this because it only measured LOCAL gaps between adjacent
## segment endpoints, which gravity pulls on fairly uniformly -- it never
## measured whether the WHOLE chain still spans the real hand-to-dart
## distance over a sustained multi-second hold, which is what the user's
## recording actually showed failing.
##
## locked_y is set once by player.gd right after instantiating this body
## (see _make_rope_segment_body()) and never changes for this segment's
## lifetime, mirroring rope_dart.gd's own plane_y (fixed per-dart, not
## per-frame, per that script's own class doc comment).
var locked_y: float = 0.0

## Hard cap on this segment's own XZ speed, enforced every physics step below
## -- see the "UNSPOOL WHIPLASH" note above _integrate_forces() for why this
## exists. A bit above rope_dart.gd's fastest possible speed (recall_speed
## 24.0, or travel_speed up to BASE_SPEED*2.0 = 36.0 at a full charge) so a
## segment can still keep pace with a legitimately fast-moving dart, but any
## solver-driven spike well beyond that (measured, see below) gets bounded
## instead of compounding.
const MAX_SEGMENT_SPEED: float = 45.0

## Small outward safety margin used by _clamp_target_inside_obstacle() --
## grows every obstacle's rect by this much before testing a clamp candidate
## against it. Without this, a handful of ticks in soak-testing still showed
## brief (single-tick, non-sustained) penetration up to ~0.12 units: the
## candidate point tested exactly on/just outside a rect's true edge, passed
## the check, got committed, and then the joint solver's own next correction
## (pulling a NEIGHBORING segment, which drags this one slightly via the pin
## joint) nudged it the last fraction of a unit across the boundary before
## the next tick's own check could catch it. A small buffer here means a
## candidate has to clear the surface by a bit of headroom, not just
## technically not-yet-touch it, closing that gap. Roughly 3x ROPE_RADIUS
## (0.035, see player.gd) -- big enough to matter, small enough not to
## visibly push the rope away from a surface it should be resting against.
const CLAMP_OBSTACLE_MARGIN: float = 0.2

## --- Growing-leash unspool clamp (see the doc comment inside
## _integrate_forces() below for the full root-cause writeup) ---
## Updated every physics tick by player.gd's _update_physics_rope_anchors(),
## NOT set once at spawn like locked_y -- both need to track the hand's real
## (animated) position and the dart's real, currently-growing travel distance
## live. hand_pos_2d/max_reach_from_hand default to values that make the
## clamp a no-op (max_reach_from_hand very large) until the first tick
## player.gd drives them, so a freshly spawned segment before its first
## _update_physics_rope_anchors() call this tick doesn't get spuriously
## snapped to the origin.
var hand_pos_2d: Vector2 = Vector2.ZERO
var max_reach_from_hand: float = 1.0e9

## --- Tension clamp (see the doc comment inside _integrate_forces() below,
## and player.gd's ROPE_TAUT_PERP_RADIUS comment, for the full writeup) ---
## Also updated every physics tick by player.gd's _update_physics_rope_anchors(),
## same lifecycle reasoning as hand_pos_2d/max_reach_from_hand above.
## max_perp_from_line defaults large so the clamp is a no-op before the first
## live update, same reasoning as max_reach_from_hand's own default.
var tip_pos_2d: Vector2 = Vector2.ZERO
var max_perp_from_line: float = 1.0e9


## ROUND 5 CLIPPING FIX (per direct user course-correction rejecting the prior
## round's "detect obstruction, draw a synthetic straight line through a
## computed contact point" render-only approach -- see player.gd's
## _make_rope_segment_body() doc comment and this session's CLAUDE.md entry
## for the full writeup): root-caused via direct measurement (segment
## position vs. a pillar's own get_rect_2d(), sampled every tick through a
## real draped throw), not assumed from the symptom alone. The two position
## clamps below (max_reach_from_hand's sphere-around-the-hand, and
## max_perp_from_line's tube-around-the-straight-hand-to-tip-LINE) are BOTH
## computed purely from the hand/tip's own live positions, with zero
## awareness of obstacle geometry -- so whenever the straight hand-to-tip
## line itself passes through a pillar's interior (exactly the "dart anchored
## behind a pillar" screenshot), max_perp_from_line's 0.3-unit tube sits
## centered ON a line that runs through solid geometry, and every tick
## forcibly recenters any segment the REAL collision solver had just
## correctly pushed outward (draping it around the pillar's edge) back
## in toward that line -- i.e. back through the pillar -- fighting the
## solver's own contact response every single step. This produces both
## halves of the reported bug at once: visible interpenetration (the clamp
## literally relocates the segment inside the obstacle's footprint every
## tick) AND lost tautness (the segment never settles into the solver's real
## resting position; it's yanked back and forth between "pushed out by
## contact" and "pulled back by the clamp" instead).
##
## Fix has TWO layers, because the first one alone was measured (via the same
## direct penetration-vs-rect probe) to be insufficient on its own:
##
## Layer 1: both clamps YIELD whenever this segment has a real, currently
## active contact (state.get_contact_count() > 0 -- see player.gd's
## contact_monitor/max_contacts_reported setup on why this is unambiguously
## "touching an obstacle," never a player/ground/another segment) -- skip
## repositioning entirely for that tick and let the solver's own contact
## resolution stand, instead of overriding it.
##
## Layer 2 (the one that actually closes the gap Layer 1 leaves open):
## contact_count() reflects contacts detected as of the END of the PREVIOUS
## physics step, so it can flicker off for a single tick even while a segment
## is still resting right at an obstacle's surface (sub-tick jitter in the
## narrow phase, or the joint solver nudging the segment a hair off the
## surface as it resolves other constraints in the chain) -- and on exactly
## that tick, Layer 1's gate reads false, so the clamp reactivates and pulls
## the segment straight back onto the hand-to-tip line, which (by definition
## of "this line is obstructed") runs THROUGH the obstacle's interior,
## re-injecting the segment into solid geometry it had just correctly been
## pushed out of. Measured directly: with Layer 1 alone, a diagonal
## corner-wrap scenario (hand/tip on opposite corners of a pillar, forcing
## real wraparound instead of a flat face-press) showed WORSE sustained
## penetration than with no gating at all (0.70 max vs. 0.59 ungated),
## because contact flicker was actually made the trigger for repeated
## yank-back-through-the-box cycles instead of a steady-state fight.
## Fix: before actually committing to either clamp's own candidate
## destination point, test that point directly against every real obstacle's
## own get_rect_2d() (arena_obstacle.gd's already-established ground truth
## for "solid footprint," the same rect rope_dart.gd's obstacle stop and this
## whole bug's own verification probe use) -- if the clamp's candidate would
## itself land inside an obstacle, skip applying that clamp this tick,
## regardless of whether get_contact_count() happened to catch it. This is
## NOT a synthetic path/route computation (nothing here decides where the
## rope SHOULD go, or draws any line) -- it's a plain "is this specific
## candidate point I'm about to move a physics body to solid ground" safety
## check on the clamp's own existing math, the same category of concern as
## Layer 1 (don't let a hand-authored position override fight real collision
## geometry), just checked directly against ground truth instead of inferred
## from a one-tick-stale proxy signal. Segments with no active contact AND
## whose clamp target isn't inside any obstacle (the common case: mid-air
## spans, or anchored in open space) are completely unaffected -- both clamps
## still apply exactly as before, which is what keeps the free portions of
## the rope from sagging/whipping.
## Lightweight introspection field, kept (not stripped after round-5
## verification) because tests/test_rope_obstacle_clip.gd -- the permanent
## regression test for this whole bug class -- reads it every sampled tick to
## report how many segments are genuinely yielding to real collision
## response, alongside its own direct penetration-vs-rect measurement.
## Mirrors has_obstacle_contact every tick; no gameplay behavior depends on
## it.
var _debug_last_has_contact: bool = false


func _clamp_target_inside_obstacle(p: Vector2) -> bool:
	## Layer 2 of the ROUND 5 CLIPPING FIX (see this file's doc comment above
	## _integrate_forces()) -- a plain, direct ground-truth check: would
	## relocating this segment to `p` land it inside a real obstacle's own
	## footprint? Queried live every call (not cached) since obstacles don't
	## move but the candidate point does, every tick, for every segment.
	## Cheap in practice -- this codebase's arenas only ever have a handful of
	## obstacles (see arena_obstacle.gd/nature_scatter.gd).
	if not is_inside_tree():
		return false
	for obs in get_tree().get_nodes_in_group("obstacles"):
		if not obs.has_method("get_rect_2d"):
			continue
		var rect: Rect2 = obs.get_rect_2d().grow(CLAMP_OBSTACLE_MARGIN)
		if rect.has_point(p):
			return true
	return false


func _integrate_forces(state: PhysicsDirectBodyState3D) -> void:
	var has_obstacle_contact: bool = state.get_contact_count() > 0
	_debug_last_has_contact = has_obstacle_contact
	var t: Transform3D = state.transform
	t.origin.y = locked_y
	var v: Vector3 = state.linear_velocity
	v.y = 0.0
	# UNSPOOL WHIPLASH FIX: when player.gd started spawning every segment of
	# the chain BUNCHED near the hand instead of laid out to the chain's full
	# length (see player.gd's ROPE_PHYSICS_SEGMENTS doc comment on the
	# "reeling out" feature this enables), EVERY joint along the chain starts
	# with a real, simultaneous positional violation (each capsule's own
	# local anchor points sit ~ROPE_PHYSICS_SEGMENT_HALF_LENGTH from its
	# near-coincident neighbor's). Measured directly via a temporary per-tick
	# probe (printing real hand-to-dart distance vs. the chain's actual max
	# reach from the hand every physics tick after a throw): with NO clamp,
	# this reliably produced a genuine solver "crack the whip" resonance, not
	# a bounded transient like the already-validated single-joint tip-anchor
	# spike -- chain_max_reach shot up to 4x the total rope length (~30+
	# units against a real hand-to-dart distance of ~4) within about 10
	# ticks, one single tick alone moving a segment ~7 units (~420 units/sec)
	# -- then took another ~20-30 ticks to decay back down toward the real
	# distance. Root cause: many simultaneously-violated joints along a
	# chain of very light (ROPE_SEGMENT_MASS = 0.03) bodies, each computing
	# its own corrective impulse against an already-moving neighbor, so the
	# correction compounds link-to-link instead of damping -- the same class
	# of instability as the already-documented "stiffer bias/damping
	# explodes the chain" finding, just triggered by many simultaneous small
	# violations instead of one large one. This clamp bounds the RESULT
	# (actual per-tick speed) directly, regardless of which joint/how many
	# simultaneous corrections caused it, rather than trying to tune the
	# solver's own bias/damping/impulse further -- deterministic and cheap,
	# and verified (see this session's own final report) to bring
	# chain_max_reach back to closely tracking the real hand-to-dart
	# distance instead of overshooting it by multiples.
	var xz_speed: float = Vector2(v.x, v.z).length()
	if xz_speed > MAX_SEGMENT_SPEED:
		# Named clamp_ratio, not scale -- Node3D already has a `scale`
		# property, and a local var of the same name in a RigidBody3D
		# subclass shadows it (GDScript warning, though harmless here).
		var clamp_ratio: float = MAX_SEGMENT_SPEED / xz_speed
		v.x *= clamp_ratio
		v.z *= clamp_ratio

	# GROWING-LEASH FIX (this round, on top of the speed clamp above): a
	# per-body velocity cap alone was tried in isolation (down to 8.0, far
	# below the already-shipped 45.0) and measured, via the same real per-tick
	# probe, to barely change the chain's overall unspool timing at all --
	# the chain still reached ~70-90% of its full 8-unit length within the
	# same ~4-6 ticks regardless. Root cause: a per-body speed clamp only
	# bounds how fast any ONE body moves, but multiple bodies along the chain
	# can each move at a modest, individually-legal speed SIMULTANEOUSLY,
	# and their combined effect can still unfold a large fraction of the
	# chain's total slack within a handful of ticks -- the real bottleneck is
	# the AGGREGATE rate the whole chain's length grows at, not any single
	# body's speed, and no per-body speed limit can bound that on its own.
	#
	# Fix: directly cap this segment's own distance from the hand (XZ only,
	# matching this game's flat-plane invariant) to max_reach_from_hand --
	# updated every physics tick by player.gd to equal the REAL, currently
	# known hand-to-dart distance plus a small fixed slack allowance (see
	# player.gd's ROPE_UNSPOOL_SLACK), capped at the chain's own total
	# capacity (DART_ROPE_LENGTH). This directly and deterministically ties
	# how far ANY point of the rope can be from the hand to how far the REAL
	# dart has ACTUALLY traveled so far -- which is itself already smooth and
	# non-explosive (a kinematic read of the dart's own position, not
	# anything joint-solver-derived) -- rather than hoping the joint solver's
	# emergent, hard-to-bound-precisely equilibrium happens to grow at a
	# similar rate. Any segment the solver tries to push out past that live
	# budget gets pulled back radially (preserving its current angle/side, so
	# it doesn't fight the solver's own XZ shaping -- draping over obstacles
	# etc. from the existing real-physics collision is unaffected, since nothing
	# here touches the segments' capsule collision response, only this extra
	# position ceiling); the outward-radial component of its velocity is also
	# zeroed so it doesn't immediately re-violate the same cap next tick and
	# buzz/jitter against it.
	var xz_pos := Vector2(t.origin.x, t.origin.z)
	var offset: Vector2 = xz_pos - hand_pos_2d
	var dist: float = offset.length()
	if not has_obstacle_contact and dist > max_reach_from_hand and dist > 0.0001:
		var radial_dir: Vector2 = offset / dist
		var clamped_xz: Vector2 = hand_pos_2d + radial_dir * max_reach_from_hand
		if not _clamp_target_inside_obstacle(clamped_xz):
			t.origin.x = clamped_xz.x
			t.origin.z = clamped_xz.y
			var v2 := Vector2(v.x, v.z)
			var radial_speed: float = v2.dot(radial_dir)
			if radial_speed > 0.0:
				v2 -= radial_dir * radial_speed
				v.x = v2.x
				v.z = v2.y

	# TENSION CLAMP (per explicit user feedback: "The tension of the rope
	# should be 2 times stronger" -- see player.gd's ROPE_TAUT_PERP_RADIUS
	# doc comment for the full root-cause writeup on why max_reach_from_hand
	# above -- a SPHERE around the hand point -- was tried first and measured
	# to NOT reliably help, sometimes making the visible bulge worse). This
	# clamps the segment's distance to the straight HAND-TO-TIP LINE (a
	# "tube" around the taut line), which is what actually controls how
	# straight/taut the rope looks, independent of the sphere-radius clamp
	# above (which only controls unspool PACING -- how far ahead of real dart
	# travel the chain's farthest point can get in ANY direction, not how
	# straight the path there is).
	var line_vec: Vector2 = tip_pos_2d - hand_pos_2d
	var line_len: float = line_vec.length()
	if line_len > 0.01:
		var line_dir: Vector2 = line_vec / line_len
		var xz_pos2 := Vector2(t.origin.x, t.origin.z)
		var rel: Vector2 = xz_pos2 - hand_pos_2d
		var along: float = rel.dot(line_dir)
		var perp_vec: Vector2 = rel - line_dir * along
		var perp_dist: float = perp_vec.length()
		if not has_obstacle_contact and perp_dist > max_perp_from_line and perp_dist > 0.0001:
			var perp_dir: Vector2 = perp_vec / perp_dist
			var clamped_xz2: Vector2 = hand_pos_2d + line_dir * along + perp_dir * max_perp_from_line
			if not _clamp_target_inside_obstacle(clamped_xz2):
				t.origin.x = clamped_xz2.x
				t.origin.z = clamped_xz2.y
				var v3 := Vector2(v.x, v.z)
				var perp_speed: float = v3.dot(perp_dir)
				if perp_speed > 0.0:
					v3 -= perp_dir * perp_speed
					v.x = v3.x
					v.z = v3.y

	state.transform = t
	state.linear_velocity = v
