extends RigidBody3D
## Dynamic physics body for one link of player.gd's PERSISTENT rope physics
## chain (see player.gd's ROPE_PHYSICS_* consts / _spawn_physics_rope()).
##
## FULL ARCHITECTURE RESET (see CLAUDE.md's dated entry / player.gd's own
## ROPE_PHYSICS_* doc comment): per direct, explicit user mandate rejecting
## every earlier round's render-side "compute where the rope should be, then
## draw/force that" correction, this script now does ONLY two things to a
## segment's raw simulated motion, both physically-motivated, not geometric
## corrections:
##  1. Y-PLANE LOCK (non-negotiable -- per explicit user requirement, "I want
##     the rope to disregard gravity and live on a plane").
##  2. A per-body XZ SPEED CLAMP (MAX_SEGMENT_SPEED) -- a legitimate physical
##     damping-style limit (bounding how fast any one body can move), not a
##     position/path clamp that decides where a segment "should" be.
##
## Deliberately REMOVED this round: the old `max_reach_from_hand`
## (growing-leash sphere around the hand, used to pace the throw/recall
## unspool) and `max_perp_from_line` (taut hand-to-tip-line tube, used for
## rope "tension") position clamps, plus the `_clamp_target_inside_obstacle()`
## ground-truth check that gated them. Both were exactly the kind of
## "compute where the rope SHOULD be based on geometry, then force it there"
## correction the user's reset explicitly rejects -- with the chain now
## persistent and its tip anchor driven directly by the dart's own real,
## already-smooth position (idle: the hand itself; thrown: the dart), the
## unfold/fold pacing that used to need an artificial clamp now falls
## straight out of real joint-constraint propagation instead. Real collision
## against obstacle geometry is Godot's own solver reacting to each
## segment's capsule CollisionShape3D on ROPE_OBSTACLE_LAYER_BIT -- nothing
## in this script ever reads obstacle geometry directly any more.
##
## Y-PLANE LOCK mechanism, unchanged from every earlier round: (a) the caller
## (player.gd's _make_rope_segment_body()) sets gravity_scale to 0 -- the
## cleanest, most literal way to satisfy "disregard gravity": no downward
## force is ever applied at all, rather than being applied and then
## corrected after the fact. (b) _integrate_forces() below is Godot's own
## documented, solver-safe entry point for overriding a RigidBody3D's
## transform/velocity each physics step (PhysicsDirectBodyState3D) --
## directly poking global_position from OUTSIDE physics processing is
## explicitly discouraged by Godot's own docs as producing "unpredictable
## behavior," since it fights the solver's already-computed contact/joint
## resolution for that step instead of being incorporated into it. This is
## the actual authoritative fix: it clamps Y back to locked_y and zeroes
## vertical velocity every physics step, catching any Y drift from the joint
## solver itself (not just gravity).
##
## locked_y is set once by player.gd right after instantiating this body
## (see _make_rope_segment_body()) and never changes for this segment's
## lifetime, mirroring rope_dart.gd's own plane_y (fixed per-dart, not
## per-frame, per that script's own class doc comment).
var locked_y: float = 0.0

## Hard cap on this segment's own XZ speed, enforced every physics step below
## -- a legitimate physical damping-style constraint (bounds how fast any ONE
## body can move), kept from earlier rounds' "crack the whip" investigation:
## with every joint along a freshly-spawned, densely-bunched chain
## simultaneously violated by roughly one segment-length, Godot's iterative
## solver can otherwise propagate a runaway resonance across the whole chain
## within a handful of ticks (measured, at 8 segments with no clamp: chain
## reach spiking to ~4x total rope length, one single tick alone moving a
## segment ~7 units / ~420 units/sec, before slowly decaying). This was
## RE-DERIVED, not assumed, for the 32-segment reset -- see this round's own
## verification notes (a per-tick chain-reach probe, re-run after the
## segment-count/mass change) for the actual before/after numbers. A bit
## above rope_dart.gd's fastest possible speed (recall_speed 24.0, or
## travel_speed up to BASE_SPEED*2.0 = 36.0 at a full charge) so a segment
## can still keep pace with a legitimately fast-moving dart, but any
## solver-driven spike well beyond that gets bounded instead of compounding.
const MAX_SEGMENT_SPEED: float = 45.0

## Mirrors has_obstacle_contact every tick -- read by player.gd's
## _clamp_to_rope_leash() (the wrap-aware leash pivot: only trust "pivot on
## the chain's first segment" once there's a real corner it's actually
## resting against) and by the regression tests in tests/. No clamp in this
## script gates on it any more (see this file's own doc comment above for
## why both clamps that used to were deleted) -- kept purely as an
## unambiguous "is this segment genuinely touching real obstacle geometry
## right now" signal for OTHER systems to read.
var _debug_last_has_contact: bool = false


func _integrate_forces(state: PhysicsDirectBodyState3D) -> void:
	_debug_last_has_contact = state.get_contact_count() > 0
	var t: Transform3D = state.transform
	t.origin.y = locked_y
	var v: Vector3 = state.linear_velocity
	v.y = 0.0

	# Per-body XZ speed clamp -- see MAX_SEGMENT_SPEED's own comment above.
	var xz_speed: float = Vector2(v.x, v.z).length()
	if xz_speed > MAX_SEGMENT_SPEED:
		# Named clamp_ratio, not scale -- Node3D already has a `scale`
		# property, and a local var of the same name in a RigidBody3D
		# subclass shadows it (GDScript warning, though harmless here).
		var clamp_ratio: float = MAX_SEGMENT_SPEED / xz_speed
		v.x *= clamp_ratio
		v.z *= clamp_ratio

	state.transform = t
	state.linear_velocity = v
