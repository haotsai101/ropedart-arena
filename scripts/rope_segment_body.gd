extends RigidBody3D
## Dynamic physics body for one link of player.gd's PERSISTENT rope physics
## chain (see player.gd's ROPE_PHYSICS_* consts / _spawn_physics_rope()).
##
## EXPERIMENT (2026-07-25, feature/melee-slash-v2), per direct, explicit user
## instruction that REVERSES an earlier hard requirement: "Let's try dropping
## the special collision logic all together. The ropedart doesn't need to be
## on a special plane. Use the default collision engine." Every prior round
## on this file (see CLAUDE.md's dated history) treated "disregard gravity
## and live on a plane" as non-negotiable; this round explicitly asks to try
## the opposite and measure what happens, not assume either outcome is right.
##
## REMOVED THIS ROUND:
##  1. The Y-PLANE LOCK -- _integrate_forces() no longer overrides
##     state.transform.origin.y or zeroes state.linear_velocity.y. A segment's
##     Y position/velocity is now whatever the real 3D solver (gravity +
##     joints + collision) produces, same as any other dynamic RigidBody3D.
##  2. gravity_scale = 0.0 (set by player.gd's _make_rope_segment_body()) --
##     removed there; segments now use RigidBody3D's own default
##     gravity_scale = 1.0, same as any other dynamic body in this project.
##  3. The one-directional ROPE_OBSTACLE_LAYER_BIT collision layer/mask
##     scheme (collision_layer=0 / collision_mask=ROPE_OBSTACLE_LAYER_BIT) --
##     see player.gd's _make_rope_segment_body() and arena_obstacle.gd for
##     the matching removal. Segments now sit on Godot's plain default
##     physics layer/mask (1/1), the same one players, the ground, and
##     obstacles already use with no special-casing -- see player.gd's
##     _spawn_physics_rope() for the collision-exception-with-owner call this
##     required (a real rope hangs from the character's own hand, spawned
##     bunched right at/inside their own capsule -- without an exception it
##     would be in constant, degenerate contact with its own wielder the
##     instant gravity/default collision are both live).
##
## KEPT THIS ROUND, both because they are not part of the "special plane /
## special layer" scheme being dropped:
##  - The per-body speed clamp below (MAX_SEGMENT_SPEED), now applied to the
##    FULL 3D velocity vector rather than only its XZ component (there is no
##    longer a "the plane" to measure speed within) -- a legitimate physical
##    damping-style limit against joint-solver whiplash, unchanged in kind
##    from every earlier round's own version of this same idea.
##  - has_obstacle_contact tracking, now narrowed to ONLY count a contact as
##    "real obstacle contact" if the actual colliding object is in the
##    "obstacles" group (see below) -- under the new default layer/mask a
##    segment can now also legitimately touch the ground, another segment of
##    its own chain (though see player.gd's joint_disable_collisions_between_
##    bodies call, which suppresses that specific case), or another player,
##    none of which should trip player.gd's _clamp_to_rope_leash() wrap-aware
##    pivot -- that logic's own "a segment resting against real obstacle
##    contact is exactly where the solver actually put it" assumption is only
##    true for genuine obstacle contact, so the signal must stay that
##    specific, not "touching anything at all."
var _debug_last_has_contact: bool = false

## Hard cap on this segment's own speed, enforced every physics step below --
## a legitimate physical damping-style limit (bounds how fast any one body
## can move), kept from earlier rounds' "crack the whip" investigation: with
## every joint along a freshly-spawned, densely-bunched chain simultaneously
## violated by roughly one segment-length, Godot's iterative solver can
## otherwise propagate a runaway resonance across the whole chain within a
## handful of ticks. Re-verify this value's continued sufficiency under real
## gravity + default collision (a different dynamical system than the one it
## was originally tuned against) rather than assuming it still holds -- see
## this round's own verification notes in CLAUDE.md / agent memory for the
## actual before/after numbers. A bit above rope_dart.gd's fastest possible
## speed (recall_speed 24.0, or travel_speed up to BASE_SPEED*2.0 = 36.0 at a
## full charge) so a segment can still keep pace with a legitimately
## fast-moving dart, but any solver-driven spike well beyond that gets
## bounded instead of compounding.
const MAX_SEGMENT_SPEED: float = 45.0


func _integrate_forces(state: PhysicsDirectBodyState3D) -> void:
	_debug_last_has_contact = _has_real_obstacle_contact(state)

	# Per-body 3D speed clamp -- see MAX_SEGMENT_SPEED's own comment above.
	# Was XZ-only (v.x/v.z) while the Y-plane lock made Y motion impossible by
	# construction; now that Y is a free, gravity-driven axis too, the clamp
	# must bound the WHOLE velocity vector or a purely-vertical solver spike
	# (e.g. a segment popping off a ledge/corner) would sail straight through
	# uncapped.
	var v: Vector3 = state.linear_velocity
	var speed: float = v.length()
	if speed > MAX_SEGMENT_SPEED:
		v *= MAX_SEGMENT_SPEED / speed
		state.linear_velocity = v


func _has_real_obstacle_contact(state: PhysicsDirectBodyState3D) -> bool:
	## See this file's own doc comment above for why this can no longer be a
	## bare state.get_contact_count() > 0 check now that the default
	## collision layer/mask means a segment can legitimately touch the
	## ground, another player, or (absent the joint-collision-exception call
	## in player.gd) its own chain neighbors -- none of which are "an
	## obstacle to wrap/pivot around" in the sense player.gd's
	## _clamp_to_rope_leash() needs.
	var count: int = state.get_contact_count()
	for i in range(count):
		var collider: Object = state.get_contact_collider_object(i)
		if collider is Node and (collider as Node).is_in_group("obstacles"):
			return true
	return false
