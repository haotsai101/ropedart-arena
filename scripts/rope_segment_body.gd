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


func _integrate_forces(state: PhysicsDirectBodyState3D) -> void:
	var t: Transform3D = state.transform
	t.origin.y = locked_y
	state.transform = t
	var v: Vector3 = state.linear_velocity
	v.y = 0.0
	state.linear_velocity = v
