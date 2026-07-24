extends RigidBody3D
## Dynamic physics body for one link of player.gd's thrown-rope physics
## chain (see player.gd's ROPE_PHYSICS_* consts / _spawn_physics_rope()).
##
## Per explicit user requirement -- "I want the rope to disregard gravity and
## live on a plane" -- every segment must never leave the dart's fixed
## plane_y height (see rope_dart.gd's own class doc comment on why the whole
## rope+dart system already lives at one fixed horizontal plane; this just
## extends that same invariant to the rope's physics simulation). This is a
## fundamental design requirement, NOT one of the experimental clamps removed
## below -- it stays unconditionally.
##
## Two layers of enforcement, deliberately redundant:
##  1. The caller (player.gd's _make_rope_segment_body()) sets gravity_scale
##     to 0 -- the cleanest, most literal way to satisfy "disregard gravity":
##     no downward force is ever applied at all, rather than being applied
##     and then corrected after the fact.
##  2. _integrate_forces() below is Godot's own documented, solver-safe entry
##     point for overriding a RigidBody3D's transform/velocity each physics
##     step (PhysicsDirectBodyState3D) -- directly poking global_position
##     from OUTSIDE physics processing is explicitly discouraged by Godot's
##     own docs as producing "unpredictable behavior." This clamps Y back to
##     locked_y and zeroes vertical velocity every physics step, catching any
##     Y drift from the joint solver itself (not just gravity).
##
## Root-cause note (why this file exists at all): an earlier version had
## NEITHER of the above -- full default gravity, no Y constraint -- and real
## user footage showed the anchored rope collapsing to a tiny hanging stub
## within moments, sagging downward, even with the character standing several
## grid cells away. See CLAUDE.md's player.gd section for the full writeup.
##
## locked_y is set once by player.gd right after instantiating this body (see
## _make_rope_segment_body()) and never changes for this segment's lifetime,
## mirroring rope_dart.gd's own plane_y (fixed per-dart, not per-frame).
var locked_y: float = 0.0

## EXPERIMENT (2026-07-24, "core simulation only" round -- per direct user
## request: "Let's try only core simulation and do 24 segments instead of
## 8"). Every geometric safety clamp previously layered onto this file has
## been REMOVED:
##   - MAX_SEGMENT_SPEED (a hard per-segment XZ speed cap, added to tame the
##     bunched-spawn "crack the whip" resonance)
##   - the growing-leash `max_reach_from_hand`/`hand_pos_2d` position clamp
##     (paced the rope's visible extent to the dart's real travel distance)
##   - the tension `max_perp_from_line`/`tip_pos_2d` clamp (bounded how far a
##     segment could bow off the straight hand-to-tip line)
##   - both clamps' obstacle-contact-yield / obstacle-rect-skip logic
##     (`_clamp_target_inside_obstacle()`, `CLAMP_OBSTACLE_MARGIN`) from the
##     ROUND 5 clipping fix
## What remains below is ONLY the Y-plane lock/gravity-disregard above (a
## fundamental requirement, not a clipping patch) plus whatever the real
## RigidBody3D joints + capsule collision against the map's obstacle layer
## (see player.gd's ROPE_OBSTACLE_LAYER_BIT) produce on their own -- the
## actual "core simulation" the experiment asks to evaluate. See CLAUDE.md's
## dated entry for this round for the measured results (spawn-time
## stability, corner-wrap fidelity, tautness) and the final recommendation on
## whether this is kept, reverted, or hybridized with the segment count.

## Pure introspection, kept (not removed with the clamps above) purely
## because tests/test_rope_obstacle_clip.gd -- a permanent regression test
## predating this experiment -- reads it every sampled tick to report how
## many segments are in real contact with obstacle geometry. No gameplay
## behavior reads or depends on this value anymore.
var _debug_last_has_contact: bool = false


func _integrate_forces(state: PhysicsDirectBodyState3D) -> void:
	_debug_last_has_contact = state.get_contact_count() > 0
	var t: Transform3D = state.transform
	t.origin.y = locked_y
	var v: Vector3 = state.linear_velocity
	v.y = 0.0
	state.transform = t
	state.linear_velocity = v
