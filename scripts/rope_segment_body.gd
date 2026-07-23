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


func _integrate_forces(state: PhysicsDirectBodyState3D) -> void:
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
	if dist > max_reach_from_hand and dist > 0.0001:
		var radial_dir: Vector2 = offset / dist
		var clamped_xz: Vector2 = hand_pos_2d + radial_dir * max_reach_from_hand
		t.origin.x = clamped_xz.x
		t.origin.z = clamped_xz.y
		var v2 := Vector2(v.x, v.z)
		var radial_speed: float = v2.dot(radial_dir)
		if radial_speed > 0.0:
			v2 -= radial_dir * radial_speed
			v.x = v2.x
			v.z = v2.y

	state.transform = t
	state.linear_velocity = v
