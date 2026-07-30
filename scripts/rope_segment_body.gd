extends RigidBody3D
## Dynamic physics body for one RING of player.gd's PERSISTENT rope physics
## chain (see player.gd's ROPE_PHYSICS_* consts / _spawn_physics_rope()).
##
## ROUND 30 (2026-07-30) -- "chain connected ring by ring" rebuild, per direct
## explicit user mandate: strip every accumulated tuning layer built on top of
## the base joint+collision simulation since the ROUND 12 architecture reset,
## and replace the capsule-shaped links with ring-shaped ones. See player.gd's
## ROPE_PHYSICS_* consts' doc comment and CLAUDE.md's own ROUND 30 entry for
## the full writeup of what changed and why, including the honest disclosure
## of what a Godot "ring" collision shape actually is (there is no native
## torus primitive in this engine) and what physically holds consecutive
## rings together (still a raw PhysicsServer3D pin joint -- no engine in this
## class can simulate true interlocking-geometry threading without one).
##
## REMOVED THIS ROUND (explicit "no custom physics" scope -- accumulated
## tuning on top of the base simulation, not the base simulation itself):
##  - ROPE_LINEAR_DAMP / ROPE_ANGULAR_DAMP (ROUND 17's steady-state-jitter
##    fix) -- no longer set by the caller (player.gd's _make_rope_segment_
##    body()); each body uses the engine's own un-overridden default damping.
##
## TRIED-AND-REVERTED THIS ROUND, per the task's own explicit "hold back only
## the specific catastrophic piece" carve-out -- NOT blindly kept:
## MAX_SEGMENT_SPEED (the per-body XZ speed clamp, tames "crack the whip"
## resonance on a bunched-spawn chain). Removed first, then DIRECTLY
## RE-MEASURED via tests/test_rope_physics_chain_settle.gd's own real
## full-charge-throw scenario: with it gone, the chain's own total reach
## ballooned to 101.218 units on a single throw -- 14x DART_ROPE_LENGTH
## (7.2) -- and oscillated between ~23 and ~93 units repeatedly across the
## test's full ~130-tick fold window without settling (both "unfold" and the
## chain-reach assertion FAILED). This is a genuinely catastrophic, not just
## "worse," result under this task's own stated bar -- a rope whose real
## simulated extent briefly exceeds the entire arena's diagonal on every
## single throw is structural failure, not disclosed-tradeoff jitter -- so
## MAX_SEGMENT_SPEED (value unchanged, 45.0, from ROUND 12-era tuning) is
## RESTORED below. Every other removal in this file/player.gd's own doc
## comments is shipped as attempted.
##
## KEPT THIS ROUND, per the task's own explicit instruction to investigate
## rather than blindly remove: the Y-PLANE LOCK / gravity_scale=0.0 pair.
## ROUND 16 measured removing this to make obstacle-collision and tautness
## WORSE, not better -- but that finding predates ring-shaped collision, so
## it was re-treated as a live question, not assumed to still hold, and
## tested empirically this round (see CLAUDE.md's own ROUND 30 entry for the
## actual before/after numbers with rings + no gravity-lock). Shipped
## behavior below keeps the lock ON by default (locked_y is still honored)
## since that is what this round's own re-measurement confirmed is still the
## safer configuration.
var locked_y: float = 0.0

## Off by default -- never flipped by any committed default, only ever set at
## runtime by a test/instrumentation script (same "toggle-and-revert, never
## edit the file's own default" convention as player.gd's own
## debug_disable_wrap_leash). When true, skips the Y-plane lock below
## entirely, so a test can A/B "rings + Y-lock" vs. "rings + no Y-lock" on
## the same real gameplay run without editing this file per run. Does NOT by
## itself change gravity_scale (a separate RigidBody3D property, set by the
## caller) -- a real "no gravity-lock" test must also set gravity_scale back
## to nonzero on every segment, which this flag alone does not do.
var debug_disable_plane_lock: bool = false

## RESTORED this round -- see the "TRIED-AND-REVERTED" doc comment above.
## Hard cap on this segment's own XZ speed, enforced every physics step
## below -- a legitimate physical damping-style constraint (bounds how fast
## any ONE body can move, not where it "should" be), not a position/path
## clamp. Value unchanged from every earlier round.
const MAX_SEGMENT_SPEED: float = 45.0

## Mirrors real contact state every tick -- read by the regression tests in
## tests/ as an unambiguous "is this ring genuinely touching real obstacle
## geometry right now" signal. Purely a read of the physics server's own
## already-computed contact count; not a correction of any kind, so it stays
## even though the wrap-aware leash calculation that used to consume it
## (player.gd's old _rope_leash_pivot_and_radius() branch) was removed this
## round as part of stripping accumulated tuning -- see that function's own
## updated doc comment.
var _debug_last_has_contact: bool = false


func _integrate_forces(state: PhysicsDirectBodyState3D) -> void:
	_debug_last_has_contact = state.get_contact_count() > 0
	var v: Vector3 = state.linear_velocity

	# Per-body XZ speed clamp -- see MAX_SEGMENT_SPEED's own comment above.
	var xz_speed: float = Vector2(v.x, v.z).length()
	if xz_speed > MAX_SEGMENT_SPEED:
		var clamp_ratio: float = MAX_SEGMENT_SPEED / xz_speed
		v.x *= clamp_ratio
		v.z *= clamp_ratio

	if debug_disable_plane_lock:
		state.linear_velocity = v
		return
	var t: Transform3D = state.transform
	t.origin.y = locked_y
	v.y = 0.0
	state.transform = t
	state.linear_velocity = v
