extends CharacterBody3D
## Rope dart weapon -- Phase 1+2+4 of the post-GDD-rewrite rebuild (see
## docs/implementation-plan.md). Full GDD state machine is declared up front
## (HOLSTERED, CHARGING, FLYING, EMBEDDED, SWINGING, RETURNING). Phase 1 built
## HOLSTERED -> CHARGING -> FLYING -> EMBEDDED; Phase 2 adds RETURNING plus
## player-hit detection (dart contact = lethal, rope-line contact =
## trip/slow) -- see begin_recall()/_process_returning() and
## _check_player_hits() below. Phase 4 (this pass) adds SWINGING -- see
## begin_swing_redirect() below and this file's own EMBEDDED header comment.
## Task #16 narrowed dart-contact lethality: EMBEDDED (stationary, anchored)
## is the one away-state where the dart head is NOT lethal to touch -- see
## _check_player_hits()'s `dart_lethal` parameter and its EMBEDDED call site
## in _physics_process() below. Rope-line contact is unaffected in every
## state, EMBEDDED included.
##
## Lives entirely on ONE fixed horizontal plane (PLANE_Y) at roughly hand
## height, same simplifying trick the old (deleted) implementation used --
## this keeps "real" physics collision compatible with the rest of the
## game's flat XZ-plane gameplay math (see player.gd's own header comment on
## the 2D-logic/3D-rendering invariant).
##
## One instance is created per player in player.gd's _ready() and lives for
## the player's whole lifetime -- state, not existence, tracks HOLSTERED vs.
## thrown. It is NOT added to the "darts" group: that group is currently only
## read by bot_controller.gd's dodge logic, which is already known-broken
## and explicitly out of scope this phase (see player.gd's header comment) --
## staying out of the group means that broken code path is never reached
## (an empty group is a no-op loop) rather than needing its own fix here.
##
## FLYING is a real CharacterBody3D physics body (move_and_collide against
## the same static obstacle/ground CollisionShape3Ds players collide with),
## not a scripted raycast -- collision exceptions are added for every player
## every tick so the physics SWEEP always passes through characters
## untouched. Player damage/kill is a wholly separate, purely-2D distance
## check (_check_player_hits(), added in Phase 2) run alongside that sweep,
## not derived from it -- see that function's own header comment for why.
## FLYING's distance from the OWNER's current (possibly moving) position is
## clamped to rope_length every tick before the physics move -- a
## straight-line distance constraint, not the segmented/wrap-around chain
## that's Phase 4's job.
##
## EMBEDDED covers two cases: a real move_and_collide hit against an
## ArenaObstacle/pillar/tree, or simply running out the rope's max range in
## open air with nothing hit -- the dart just stops there. The latter is
## what "embeds ... in the ground" effectively means here, since PLANE_Y sits
## well above the actual ground collision geometry (see PLANE_Y's own
## comment) -- there is deliberately no vertical gameplay in this game, so a
## literal ground-plane raycast isn't how a flat XZ game "sticks a dart in
## the floor." From EMBEDDED, the SAME unified Throw/Recall button
## (player.gd's _get_action_held()) does one of two things depending on
## gesture, disambiguated entirely on player.gd's side before either of
## these is ever called: a quick tap calls Recall (begin_recall(), Phase 2)
## into RETURNING; a hold-then-release aiming a direction calls
## begin_swing_redirect() (Phase 4, this pass) into SWINGING -- an unanchor
## + relaunch from the dart's CURRENT position, reusing _process_flying()'s
## own travel/embed/wrap logic verbatim (SWINGING and FLYING are mutually
## exclusive per dart, so sharing that one function and its "flying_clamp"
## wrap-state key between them is safe) and landing back in EMBEDDED via the
## same _embed_in_place() a fresh throw uses. Chainable (EMBEDDED ->
## SWINGING -> EMBEDDED -> SWINGING -> ...); Recall is the only way out of
## either EMBEDDED or SWINGING into RETURNING (see begin_recall()'s own
## state guard). Task #20 corrected SWINGING's own charge-scaled travel-
## distance cap (player.gd's _compute_redirect_travel_distance()) to be
## measured from the OWNER, same as every other distance constraint here,
## instead of Task #18's original launch-point-relative version -- see
## _swing_effective_range's own header comment. Task #20 also added a
## pre-check on player.gd's side (too-short-hold OR too-close-to-owner)
## that skips SWINGING entirely in favor of an instant pickup
## (force_holster()) rather than attempting a near-zero-distance redirect.
## Task #22 corrected WHERE that leg actually travels TO: begin_swing_
## redirect() used to launch in the raw aim_dir compass heading from the
## dart's own (possibly off-ray) current position; per direct user spec, it
## now launches straight at a specific point on the ray from the OWNER
## through aim_dir -- owner_pos + aim_dir * charge_scaled_distance -- so a
## redirect always lands "between the character and the aim direction's max
## chain length, at a distance controlled by charge time," regardless of
## where the dart happened to be sitting before the redirect. See
## begin_swing_redirect()'s own header comment and predict_redirect_
## landing_point()'s matching Task #22 update below.

enum State { HOLSTERED, CHARGING, FLYING, EMBEDDED, SWINGING, RETURNING }

signal state_changed(new_state: int)

@export var travel_speed: float = 16.0
@export var max_charge_time: float = 0.7
@export var max_charge_speed_mult: float = 1.6
## Mirrors the old (deleted) rope_dart.gd's own tuning: originally derived as
## 6x GameManager.PLAYER_CAPSULE_HEIGHT (then 1.2) = 7.2. As of Task #7
## (2026-08-05), PLAYER_CAPSULE_HEIGHT was corrected from a stale 1.2
## (torso-only, disagreeing with PLAYER_HALF_HEIGHT) to 2.0 -- a real,
## in-engine-measured hitbox fix (see GameManager.PLAYER_HALF_HEIGHT's own
## comment), NOT a rope-length balance change. Rope length is deliberately
## kept as the literal 7.2 it already was, rather than re-deriving
## 6.0 * PLAYER_CAPSULE_HEIGHT (which would silently balloon it to 12.0) --
## the two constants no longer share a formula, only a historical origin.
@export var rope_length: float = 7.2
## Small pull-back along -dir_2d applied at the moment of embedding so the
## dart visually sticks INTO a surface instead of floating exactly on its skin.
@export var embed_depth: float = 0.15
## How far ahead of the player's own center the dart appears the instant it's
## released, so it doesn't spawn literally inside the owner's own capsule.
@export var launch_forward_offset: float = 0.6
## How far in front of the owner's position the dart hovers while holstered/
## charging (a simple hand-offset approximation -- no bone tracking this phase).
@export var hand_forward_offset: float = 0.45
## RETURNING: dart speed toward the owner at the instant Recall is pressed,
## then ramps up by recall_accel every second (GDD: "Recall speed increases
## over time") -- see _process_returning().
@export var recall_base_speed: float = 18.0
@export var recall_accel: float = 16.0
## How close pos_2d must get to the owner's position before RETURNING snaps
## to HOLSTERED -- small enough to read as "caught it", big enough that one
## fast-recall physics tick can't overshoot past it and oscillate.
@export var recall_arrival_radius: float = 0.35
## Player-hit detection (Phase 2 -- see _check_player_hits()). Dart contact
## uses the dart's own collision radius (0.12, see CollisionShape3D below)
## plus the player capsule's radius (0.4, see player.tscn's PlayerShape) plus
## a small buffer so a near-miss still reads as a hit. Rope-line contact uses
## a slightly smaller radius since the rope itself is thin (a trip, not a
## direct hit) but still needs to be generous enough to feel fair in combat.
@export var dart_hit_radius: float = 0.55
@export var rope_trip_radius: float = 0.5

## Fixed flight/embed height. Obstacle collision boxes (PillarA/B in
## main.tscn, tree/cactus obstacles from nature_scatter.gd) all uniformly
## span world Y [0, 2] -- comfortably inside this band.
const PLANE_Y: float = 1.1

var state: int = State.HOLSTERED
var owner_player: Variant = null  # duck-typed player.gd reference

## The dart's own gameplay position, XZ-plane Vector2 (see the project's core
## 2D-logic invariant) -- global_position.y is always PLANE_Y, never gameplay.
var pos_2d: Vector2 = Vector2.ZERO
var dir_2d: Vector2 = Vector2(0.0, 1.0)

## Persisted wrap-corner state for the incremental wrap router (Task #8 --
## see _compute_rope_path_2d()'s own header comment). Keyed by a small fixed
## set of caller-role strings (distinct "from/to" endpoint pairs -- hand<->
## dart for hit-detection/visual, dart<->player for player.gd's leash pivot,
## owner<->trial-target for the FLYING range clamp) so each role keeps its
## own independent memory of which corners it's currently wrapped around,
## rather than one call site's incremental state leaking into another's.
var _wrap_state: Dictionary = {}

var _charge_time: float = 0.0
var _flight_speed: float = 16.0
var _recall_time: float = 0.0

## Task #20: charge-scaled max distance FROM THE OWNER for the CURRENT
## SWINGING leg -- see begin_swing_redirect()'s own header comment and
## _process_flying()'s owner-relative range-cap for how this is used.
## Replaces Task #18's _redirect_launch_pos/_redirect_max_distance pair,
## which measured this leg's cap from the dart's OWN launch position instead
## of the owner -- corrected per user report: every other distance
## constraint in this system (FLYING's clamp, the EMBEDDED leash, rope_length
## itself) is owner-relative, and the launch-point-relative version was an
## unintended deviation from that pattern. INF is a safe default (this field
## is only ever consulted while state == State.SWINGING, gated in
## _process_flying(), so a stale value between legs is harmless -- same
## reasoning the old fields relied on) -- _process_flying() treats INF as "no
## extra cap", falling back to the plain rope_length clamp, exactly like
## begin_swing_redirect()'s own max_travel_distance <= 0.0 case.
var _swing_effective_range: float = INF

@onready var head_mesh: MeshInstance3D = $Head
@onready var rope_mesh: MultiMeshInstance3D = $RopeLine

## Chain-link visual tuning (item 1). One shared MultiMesh (rope_dart.tscn's
## RopeMultiMesh, a small TorusMesh "ring" link) is GPU-instanced along the
## rope's own wrap-aware path (see _compute_rope_path_2d() below) -- every
## frame only rewrites each instance's Transform3D and the multimesh's own
## visible_instance_count (both cheap, fixed-size writes into an
## already-allocated instance buffer), never rebuilds a mesh or allocates a
## new resource, so this stays cheap per-player/per-tick regardless of how
## the rope currently bends. ROPE_LINK_MAX_COUNT bounds the instance buffer
## (and therefore the absolute worst-case per-frame write cost) to a fixed
## size regardless of how long or bent the live path gets -- a longer/more-
## bent rope just spaces its links out a little further apart instead of
## growing the instance count past this cap.
## Task #12 fix: this used to be 0.18 -- LARGER than LinkMesh's own outer
## diameter (outer_radius=0.06 -> 0.12), so consecutive rings, even with the
## alternating tilt below, never actually overlapped in space and could only
## ever read as separate rings floating along the path at intervals, never
## as passing through each other (confirmed by direct measurement: a real
## run_project screenshot at the default in-game camera distance showed the
## rope as a visibly dotted/gapped line, not a chain). Dropping this well
## below the ring's own diameter (roughly half of it) is what actually makes
## consecutive rings' geometry overlap enough, combined with the tilt, to
## read as threaded through one another.
const ROPE_LINK_SPACING: float = 0.055
## Raised alongside the spacing cut above so a fully-extended rope
## (rope_length ~7.2, or somewhat more while wrapped) still gets the full
## tight spacing rather than silently falling back to a wider effective
## spacing once ceili(total_len / ROPE_LINK_SPACING) exceeds this cap (see
## this function's own use of link_count/spacing below) -- 160 * 0.055 ~= 8.8,
## comfortably covering the realistic max visible rope length.
const ROPE_LINK_MAX_COUNT: int = 160
## Every other link is additionally tilted 90 degrees around its own local
## X axis so consecutive rings alternately face "on" vs "edge-on" toward the
## rope's own travel direction -- the standard interlocked chain-link look
## (a torus is rotationally symmetric around its own Y axis, so twisting
## around Y would be invisible; this instead alternates which axis the ring
## opens along).
const ROPE_LINK_TILT: float = PI * 0.5
## Offset from pos_2d (the dart body's CENTER, which is what FLYING/EMBEDDED
## collision and _check_player_hits()'s rope-line trip check actually use as
## the dart-side endpoint) back to the tail/pommel end opposite the tip,
## where the visual chain should actually terminate (item 2's new TailRing --
## see rope_dart.tscn's "Head/TailRing" node, whose own local -Y offset of
## 0.28 this is tuned to land just inside so the last chain link reads as
## entering the ring, not stopping short of it). Visual-only: deliberately
## NOT used by _check_player_hits() or any gameplay math, only by
## _update_rope_visual() below, so this never changes hit detection.
const HEAD_TAIL_OFFSET: float = 0.24
@onready var collision_shape: CollisionShape3D = $CollisionShape3D


func _ready() -> void:
	collision_layer = 0  # nothing else's mask can ever detect this body back
	collision_mask = 1   # detects the default layer: ground, pillars, trees
	global_position = _hand_attach_pos_3d()
	pos_2d = Vector2(global_position.x, global_position.z)
	if rope_mesh != null:
		rope_mesh.visible = false
		# The MultiMesh resource (rope_dart.tscn's embedded RopeMultiMesh) is
		# an inline scene sub-resource, which Godot otherwise shares BY
		# REFERENCE across every instantiate() of this scene -- fine for the
		# static LinkMesh geometry it points at (read-only, never mutated),
		# but every frame this script writes live per-instance transforms
		# directly into the MultiMesh's own instance buffer
		# (_update_rope_visual()'s set_instance_transform() calls), which
		# would otherwise corrupt/flicker between whichever player's dart
		# last wrote to it. Every instance needs its OWN independent buffer.
		#
		# Deliberately NOT MultiMesh.duplicate(): confirmed by direct
		# measurement (a real headless run threw "Cannot set a buffer on a
		# Multimesh that is a different size from the Multimesh's existing
		# buffer" from inside duplicate() itself) that Resource.duplicate()
		# copies this resource's exported properties -- including its raw
		# internal transform buffer -- in an order/shape that doesn't survive
		# re-application to a new MultiMesh instance. Building a fresh
		# MultiMesh from scratch and copying over only the plain scalar
		# config (mesh reference, transform_format, instance_count) sidesteps
		# that entirely -- the new instance's buffer is allocated cleanly by
		# its own instance_count setter, never copied raw.
		if rope_mesh.multimesh != null:
			var src_mm: MultiMesh = rope_mesh.multimesh
			var own_mm := MultiMesh.new()
			own_mm.transform_format = src_mm.transform_format
			own_mm.use_colors = src_mm.use_colors
			own_mm.use_custom_data = src_mm.use_custom_data
			own_mm.mesh = src_mm.mesh
			# ROPE_LINK_MAX_COUNT, not src_mm.instance_count -- this is the
			# single source of truth for the buffer size _update_rope_visual()
			# is allowed to write into (see that const's own comment); reading
			# it back from the scene file's authored MultiMesh would silently
			# desync the two if either one is ever tuned without the other
			# (confirmed by direct measurement: exactly this desync, scene
			# file still at the OLD instance_count=48 after only the script's
			# constant was raised, threw real "Instance index out of bounds"
			# errors from inside set_instance_transform()).
			own_mm.instance_count = ROPE_LINK_MAX_COUNT
			own_mm.visible_instance_count = 0
			rope_mesh.multimesh = own_mm


func _process(_delta: float) -> void:
	if owner_player == null or not is_instance_valid(owner_player):
		return
	if state == State.HOLSTERED or state == State.CHARGING:
		# Task #19: attach to the owner's real, live animated hand bone
		# (position only -- see _hand_attach_pos_3d()'s own header comment for
		# why orientation, just below, deliberately stays on aim_dir).
		global_position = _hand_attach_pos_3d()
		pos_2d = Vector2(global_position.x, global_position.z)
	if rope_mesh != null:
		rope_mesh.visible = (state == State.FLYING or state == State.EMBEDDED or state == State.RETURNING or state == State.SWINGING)
		if rope_mesh.visible:
			_update_rope_visual()
	if head_mesh != null:
		# Point the head's tip (mesh authored along local Y) along the dart's
		# current facing -- purely cosmetic, so a screenshot reads as "the
		# dart is facing the way it flew/embedded" instead of a fixed
		# arbitrary orientation. dir_2d itself is only ever written by
		# release_throw()/_process_returning(), so while HOLSTERED/CHARGING
		# it would otherwise be stale (whatever it was after the last throw,
		# or the Vector2(0,1) default before any throw at all) -- read the
		# owner's LIVE aim_dir instead for those two states so the dart
		# visibly tracks wherever the player is currently aiming before they
		# release it, not a frozen old direction.
		var facing_2d: Vector2 = dir_2d
		if state == State.HOLSTERED or state == State.CHARGING:
			if owner_player != null and is_instance_valid(owner_player) and owner_player.aim_dir.length() > 0.01:
				facing_2d = owner_player.aim_dir
		head_mesh.basis = _basis_align_y(Vector3(facing_2d.x, 0.0, facing_2d.y))


func _physics_process(delta: float) -> void:
	match state:
		State.CHARGING:
			_charge_time = minf(_charge_time + delta, max_charge_time)
		State.FLYING:
			_process_flying(delta)
			_check_player_hits()
		State.EMBEDDED:
			# Stationary and, per the design change in docs/project.md's Combat
			# "Dart Contact" section, NOT lethal on contact -- once the dart
			# lands and sticks it's just a planted anchor point, not an active
			# threat, so a player walking into (or standing on) a landed dart
			# no longer dies from touching the dart head itself. Rope-LINE
			# contact is unaffected -- still trips/slows exactly like every
			# other away-state -- so dart_lethal=false only gates the dart-head
			# death check inside _check_player_hits(), not the rope-line one.
			_check_player_hits(false)
		State.SWINGING:
			# A redirect leg of travel is mechanically identical to FLYING's own
			# travel/embed/wrap logic (move_and_collide sweep + wrap-aware range
			# clamp against the OWNER, landing back in EMBEDDED via the same
			# _embed_in_place()) -- see begin_swing_redirect()'s own header
			# comment for why reusing _process_flying() verbatim here is safe.
			# Still lethal on contact throughout (docs/project.md's Swinging
			# section: "always lethal on contact, regardless of swing speed")
			# -- unlike EMBEDDED above, SWINGING is active dart motion, not a
			# stationary anchor, so the dart_lethal=false gate does NOT apply
			# here; this calls _check_player_hits() with its default true.
			_process_flying(delta)
			_check_player_hits()
		State.RETURNING:
			_process_returning(delta)
			_check_player_hits()
		_:
			pass


func begin_charge() -> void:
	if state != State.HOLSTERED:
		return
	state = State.CHARGING
	_charge_time = 0.0
	state_changed.emit(state)


## Called on Throw-button release while CHARGING. throw_dir is the player's
## current aim direction (Vector2, XZ-plane).
func release_throw(throw_dir: Vector2) -> void:
	if state != State.CHARGING:
		return
	var charge_ratio: float = clampf(_charge_time / max_charge_time, 0.0, 1.0)
	_flight_speed = lerp(travel_speed, travel_speed * max_charge_speed_mult, charge_ratio)
	dir_2d = throw_dir.normalized() if throw_dir.length() > 0.01 else Vector2(0.0, 1.0)
	# A fresh throw starts a conceptually brand-new rope -- any wrap corners
	# remembered from the PREVIOUS throw (now geometrically meaningless: the
	# dart just jumped to a new position near the hand) must not leak into
	# this one's incremental routing.
	_wrap_state.clear()
	if owner_player != null and is_instance_valid(owner_player):
		pos_2d = owner_player.get_pos_2d() + dir_2d * launch_forward_offset
	global_position = Vector3(pos_2d.x, PLANE_Y, pos_2d.y)
	state = State.FLYING
	state_changed.emit(state)


func _process_flying(delta: float) -> void:
	if owner_player == null or not is_instance_valid(owner_player):
		_embed_in_place()
		return

	var owner_pos: Vector2 = owner_player.get_pos_2d()
	var next_pos_2d: Vector2 = pos_2d + dir_2d * _flight_speed * delta

	# Wrap-aware distance constraint (Task #7, item 4): never let the dart's
	# distance from the (possibly still-moving) owner -- measured along the
	# REAL wrapped path through any obstacle it currently bends around, not
	# the raw straight-line beeline -- exceed this leg's own range cap this
	# tick. See _clamp_along_wrap_path()/_compute_rope_path_2d() below.
	#
	# Task #20: range_cap is rope_length for a plain FLYING throw, same as
	# always, but for a SWINGING redirect leg it's the SMALLER of
	# rope_length and _swing_effective_range -- the charge-scaled max
	# distance FROM THE OWNER player.gd computed for this specific leg (see
	# begin_swing_redirect()'s own header comment). Reuses this SAME
	# "flying_clamp" owner-relative wrap-memory key for both cases (a
	# SWINGING leg is just FLYING with a possibly-tighter range this tick,
	# not a geometrically different constraint), replacing Task #18's
	# separate launch-point-relative "redirect_travel" clamp entirely --
	# see _swing_effective_range's own header comment for why that was
	# corrected to be owner-relative instead.
	var range_cap: float = rope_length
	if state == State.SWINGING:
		range_cap = minf(range_cap, _swing_effective_range)
	var reached_max_range := false
	var clamped_pos_2d: Vector2 = _clamp_along_wrap_path(owner_pos, next_pos_2d, range_cap, "flying_clamp")
	if clamped_pos_2d != next_pos_2d:
		next_pos_2d = clamped_pos_2d
		reached_max_range = true

	# Real physics sweep for obstacle/wall/pillar/tree detection. Refresh
	# player exceptions every tick (cheap, small player counts) rather than
	# once at spawn -- spawn order across players isn't guaranteed, so a
	# once-only pass could miss a player who joins the "players" group later.
	for p in get_tree().get_nodes_in_group("players"):
		add_collision_exception_with(p)

	global_position = Vector3(pos_2d.x, PLANE_Y, pos_2d.y)
	var motion: Vector3 = Vector3(next_pos_2d.x - pos_2d.x, 0.0, next_pos_2d.y - pos_2d.y)
	var collision: KinematicCollision3D = move_and_collide(motion)
	pos_2d = Vector2(global_position.x, global_position.z)

	if collision != null:
		pos_2d -= dir_2d * embed_depth
		global_position = Vector3(pos_2d.x, PLANE_Y, pos_2d.y)
		_embed_in_place()
		return

	if reached_max_range:
		_embed_in_place()


func _embed_in_place() -> void:
	state = State.EMBEDDED
	state_changed.emit(state)


## Called on Throw/Recall-button release while EMBEDDED, after player.gd has
## already decided (via its own hold-duration tracking -- see that file's
## _handle_dart_away_input()) that this was a hold-then-release resolving to
## a real redirect, not a quick tap (-> begin_recall()) or a too-short-hold/
## too-close pickup (-> force_holster(), Task #20) -- this function trusts
## that decision and doesn't re-derive it.
## redirect_dir is the player's aim direction at the moment of release, same
## role throw_dir plays in release_throw(). max_travel_distance (Task #18,
## reinterpreted by Task #20) is the charge-scaled max distance budget for
## this leg FROM THE OWNER -- computed by player.gd's
## _compute_redirect_travel_distance() from its own tracked hold duration and
## passed in here; a value <= 0.0 (the default) means "no extra cap beyond
## the plain rope_length clamp", kept only so any other/future caller (e.g.
## a test calling this directly with just a direction) doesn't need to always
## supply one.
##
## Unanchors the dart from its CURRENT pos_2d (no repositioning -- unlike
## release_throw(), which jumps the dart to a fresh spot near the owner's
## hand, a redirect starts exactly where the dart already is) and relaunches
## it toward redirect_dir at full travel_speed (no charge-ramp ON SPEED: this
## is a snap mid-fight decision, not a held charge-up -- see docs/project.md's
## Throw/Recall/Redirect section and player.gd's own hold-threshold comment;
## the hold DOES scale travel DISTANCE instead, see max_travel_distance
## above and _process_flying()'s owner-relative range_cap for why distance,
## not speed, is the right axis to scale for this specific leg of travel).
## SWINGING's own physics_process branch calls the exact same
## _process_flying()/_check_player_hits() FLYING already uses, and
## _process_flying() itself lands back in EMBEDDED via _embed_in_place()
## regardless of which state called it -- so travel, wall/obstacle embed,
## and wrap-aware range clamping all fall out for free, unmodified.
##
## Task #22 fix: dir_2d used to be the raw redirect_dir compass heading,
## walked from the dart's OWN current pos_2d (wherever it happened to be
## left EMBEDDED, which is not generally anywhere near the owner's own
## aim ray). Per direct user spec ("the dart should land between the aiming
## direction max chain length and the character ... on the line
## corresponding to the charging time"), the intended target is a specific
## POINT defined relative to the OWNER -- owner_pos + aim_dir *
## charge_scaled_distance, i.e. a point on the ray from the character
## through the aim direction, at a distance controlled by charge time (see
## SWING_REDIRECT_MIN_DISTANCE's own comment in player.gd) -- not a compass
## heading from the dart's own arbitrary prior position. dir_2d is now
## computed as the direction FROM the dart's current position TOWARD that
## target point, so the actual straight-line travel heads at the correct
## point regardless of where the dart started. _process_flying()'s existing
## owner-relative range_cap clamp (_swing_effective_range below) is
## unchanged and stays as a safety bound for wrap-around edge cases -- see
## that field's own header comment -- it should be a near no-op in the
## common case now, since target_point already sits within (at most exactly
## on the boundary of) that same range budget.
func begin_swing_redirect(redirect_dir: Vector2, max_travel_distance: float = -1.0) -> void:
	if state != State.EMBEDDED:
		return
	var aim_dir: Vector2 = redirect_dir.normalized() if redirect_dir.length() > 0.01 else Vector2(0.0, 1.0)
	_flight_speed = travel_speed
	_swing_effective_range = max_travel_distance if max_travel_distance > 0.0 else INF
	# charge_scaled_distance: the same value _swing_effective_range holds,
	# clamped to rope_length in case a caller ever passes something larger
	# (mirrors _process_flying()'s own minf(rope_length, _swing_effective_range)
	# range_cap) -- falls back to plain rope_length when no cap was supplied
	# (max_travel_distance <= 0.0, i.e. _swing_effective_range == INF).
	var charge_scaled_distance: float = minf(rope_length, _swing_effective_range) if is_finite(_swing_effective_range) else rope_length
	var target_point: Vector2 = pos_2d
	if owner_player != null and is_instance_valid(owner_player):
		var owner_pos: Vector2 = owner_player.get_pos_2d()
		target_point = owner_pos + aim_dir * charge_scaled_distance
	var to_target: Vector2 = target_point - pos_2d
	dir_2d = to_target.normalized() if to_target.length() > 0.01 else aim_dir
	# _process_flying()'s wrap-aware range clamp keys its own incremental wrap
	# memory under "flying_clamp" -- last touched during this dart's ORIGINAL
	# throw (a different leg of travel, from the hand, potentially long
	# since-stale). Bootstrap it from "leash" instead: the EMBEDDED leash
	# clamp (player.gd's _apply_rope_leash_velocity_clamp(), which always
	# runs earlier in THIS SAME physics tick before player.gd can call this
	# function) refreshes "leash" every single EMBEDDED tick, so it's the
	# freshest possible live source for exactly the wrap corners currently
	# sitting between the dart's (unchanged-by-this-call) position and the
	# owner -- same "seed from the freshest live source rather than blank or
	# stale" reasoning begin_recall() already uses to bootstrap "returning".
	# "leash" is dart -> owner; "flying_clamp" is owner -> near-dart, hence
	# reversed below.
	var bootstrap: PackedVector2Array = _wrap_state.get("leash", PackedVector2Array())
	if not bootstrap.is_empty():
		bootstrap = bootstrap.duplicate()
		bootstrap.reverse()
	_wrap_state["flying_clamp"] = bootstrap
	state = State.SWINGING
	state_changed.emit(state)


## Called on Recall-button press while the dart is away (FLYING, EMBEDDED, or
## SWINGING -- see player.gd's _handle_dart_away_input()). No-op from any
## other state (already HOLSTERED/CHARGING, or already RETURNING). Phase 4:
## SWINGING added alongside FLYING/EMBEDDED -- Recall is the only way out of
## an in-progress redirect chain (GDD: "Recall is the only way to exit into
## Returning"), interrupting a mid-flight redirect leg exactly like it
## already interrupts a mid-flight FLYING throw.
func begin_recall() -> void:
	if state != State.FLYING and state != State.EMBEDDED and state != State.SWINGING:
		return
	state = State.RETURNING
	_recall_time = 0.0
	# Own state key ("returning") -- see _wrap_state's header comment.
	#
	# Task #13 fix: bootstrap "returning"'s wrap memory from whichever
	# already-established key represents the SAME dart->owner directional
	# path this recall is about to retrace, instead of starting from a
	# blank slate every time. Starting blank forces _compute_rope_path_2d()'s
	# very first "returning" call to re-derive the wrap from nothing, which
	# falls right back into the global-shortest-detour pick
	# _pick_wrap_corner() only uses for a genuinely first-ever wrap onto an
	# obstacle (see its own header comment) -- once a player has walked far
	# enough around a pillar while EMBEDDED that the wrap is no longer a
	# geometric tie, that from-scratch pick can choose the OPPOSITE,
	# momentarily-shorter side from the one the rope is actually sitting on,
	# so the dart visibly snaps to unwrap around a side the rendered chain
	# was never on. Confirmed by direct headless measurement (temp probe,
	# not part of the regression suite): an owner walked most of the way
	# around a pillar with the dart EMBEDDED on the far side, establishing
	# west-side wrap corners in both "hand_dart_visual" and "leash", but a
	# from-scratch "returning" bootstrap picked the EAST-side corners on its
	# very first post-recall tick -- a real, visible wrap-side mismatch
	# between the rendered chain and the dart's actual recall path.
	#
	# "leash" (dart -> player, exactly this call's own direction/endpoints,
	# refreshed every physics tick the dart is EMBEDDED by player.gd's
	# _apply_rope_leash_velocity_clamp(), which always runs earlier in the
	# SAME physics tick, before this function can be called -- see that
	# function's own call site in player.gd's _physics_process()) is
	# preferred when available. Falls back to "hand_dart_visual" (hand ->
	# dart, the OPPOSITE direction, hence reversed below) to cover the
	# FLYING-recall case, where "leash" is never populated (that clamp only
	# runs while EMBEDDED) but the visual path is still refreshed every
	# frame regardless of state (see _process()). Wrap points are plain
	# obstacle-relative corners, not tied to either source's own small
	# hand/tail endpoint offsets, so seeding from either is a safe
	# approximation -- the normal removal/insertion passes
	# _compute_rope_path_2d() always runs still validate and correct these
	# against the real pos_2d/owner_pos endpoints on this very first tick.
	var bootstrap: PackedVector2Array = _wrap_state.get("leash", PackedVector2Array())
	if bootstrap.is_empty():
		var visual: PackedVector2Array = _wrap_state.get("hand_dart_visual", PackedVector2Array())
		if not visual.is_empty():
			bootstrap = visual.duplicate()
			bootstrap.reverse()
	_wrap_state["returning"] = bootstrap
	state_changed.emit(state)


## RETURNING: retracts ALONG the same wrap-aware polyline path
## (_compute_rope_path_2d(), own "returning" state key) the chain is
## currently bent through, point by point, rather than beelining straight
## toward the owner through whatever obstacle the rope is wrapped around --
## the fix for "the dart retrieval should follow the chain to go back to the
## character." Still chases the OWNER's current (possibly moving) position,
## not a fixed point captured at recall-start. Speed still ramps up over
## time (GDD: "Recall speed increases over time").
##
## Each tick, recompute the wrap-aware path from the dart's own CURRENT
## pos_2d to the owner's current position, using the same incremental router
## FLYING/EMBEDDED/hit-detection already use -- move toward path[1] (the
## very next waypoint after the dart's own position, which is either a
## wrap corner or the owner directly if the path is currently clear). Once
## within arrival radius of a WRAP corner (path.size() > 2, i.e. there's
## still at least one more waypoint beyond it), snap onto it and consume it
## from this call's own "returning" wrap memory -- like a chain being reeled
## in past a corner it has already rounded, so the next tick's recompute
## naturally continues toward whatever comes after. Only holsters once
## within arrival radius of the owner AND the path to them is direct
## (path.size() <= 2) -- so the dart never "arrives" by cutting through an
## obstacle it's still wrapped around.
func _process_returning(delta: float) -> void:
	if owner_player == null or not is_instance_valid(owner_player):
		_holster_in_place()
		return
	_recall_time += delta
	var speed: float = recall_base_speed + recall_accel * _recall_time
	var owner_pos: Vector2 = owner_player.get_pos_2d()

	var path: PackedVector2Array = _compute_rope_path_2d(pos_2d, owner_pos, "returning")
	var next_wp: Vector2 = path[1] if path.size() > 1 else owner_pos
	var to_next: Vector2 = next_wp - pos_2d
	var dist_next: float = to_next.length()

	if dist_next <= recall_arrival_radius:
		if path.size() > 2:
			# Reached an intermediate wrap corner, not the owner -- snap onto
			# it and pop it from this call's own wrap memory so next tick's
			# path recompute treats it as already rounded, then keep chasing
			# toward whatever's next (another corner, or the owner directly).
			pos_2d = next_wp
			var remembered: PackedVector2Array = _wrap_state.get("returning", PackedVector2Array())
			if remembered.size() > 0:
				remembered.remove_at(0)
				_wrap_state["returning"] = remembered
			global_position = Vector3(pos_2d.x, PLANE_Y, pos_2d.y)
			return
		_holster_in_place()
		return

	var move_dir: Vector2 = to_next / dist_next
	pos_2d += move_dir * minf(speed * delta, dist_next)
	dir_2d = move_dir
	global_position = Vector3(pos_2d.x, PLANE_Y, pos_2d.y)


func _holster_in_place() -> void:
	state = State.HOLSTERED
	state_changed.emit(state)


## Public (Task #10): forces the dart back to HOLSTERED from ANY state --
## unlike begin_recall()/_process_returning()'s normal RETURNING-arrival exit
## (_holster_in_place() above), which only fires once the dart has actually
## traveled back to the owner's hand, this is an immediate hard reset for
## player.gd's death-respawn (take_dart_hit()) and round-start
## (reset_for_round()) paths: a player who dies/respawns while their dart is
## still FLYING/EMBEDDED/RETURNING must not leave it behind wherever it was,
## disconnected from the player who just reappeared elsewhere.
##
## Snaps pos_2d/global_position to the owner's CURRENT hand position
## immediately (via _hand_attach_pos_3d(), same real-hand-bone computation the
## HOLSTERED/CHARGING branch of _process() uses every frame -- Task #19)
## rather than waiting for that next _process() tick, so there's no one-frame
## gap where the rope visual could still show the dart at its old, now-stale
## position after the state flip. Also clears _charge_time/_recall_time/
## _wrap_state so no leftover charge progress, recall ramp-up, or remembered
## wrap-corner geometry from the interrupted throw leaks into the player's
## next throw. Caller is responsible for calling this AFTER repositioning the
## owner (spawn teleport), not before, so _hand_attach_pos_3d() computes
## against the new spawn point/pose rather than the pre-teleport one.
func force_holster() -> void:
	state = State.HOLSTERED
	_charge_time = 0.0
	_recall_time = 0.0
	_wrap_state.clear()
	global_position = _hand_attach_pos_3d()
	pos_2d = Vector2(global_position.x, global_position.z)
	if rope_mesh != null:
		rope_mesh.visible = false
	state_changed.emit(state)


## Player-hit detection (Phase 2). Deliberately NOT the move_and_collide
## physics sweep used for FLYING's wall/pillar/tree embed detection --
## rope_dart.gd adds a collision exception for every player every tick
## specifically so that sweep never touches players (see this file's header
## comment and _process_flying()). This is a separate, purely-2D distance
## check run every tick the dart is away from the owner's hand
## (FLYING/EMBEDDED/RETURNING -- see _physics_process()'s match above).
##
## Dart contact (distance from pos_2d to a player) is lethal whenever
## `dart_lethal` is true -- every away-state EXCEPT EMBEDDED (see
## docs/project.md's Combat "Dart Contact" section: a stationary anchored
## dart is not lethal to touch; _physics_process()'s EMBEDDED case is the only
## caller that passes false). Rope contact -- as of Task #7 item 4, distance
## from ANY segment of the rope's real wrap-aware path (hand -> wrap point(s)
## -> dart, see _compute_rope_path_2d()), not just a single straight
## hand-to-dart segment -- only trips/slows, checked second, unconditionally
## (rope-line contact is unaffected by dart_lethal in every away-state,
## including EMBEDDED), and only for players who weren't already killed by
## the dart-contact check this tick, so a player standing right at the dart
## head is never *also* counted as merely tripped when the dart IS lethal.
func _check_player_hits(dart_lethal: bool = true) -> void:
	if owner_player == null or not is_instance_valid(owner_player):
		return
	var hand: Vector2 = _hand_pos_2d()
	var rope_path: PackedVector2Array = _compute_rope_path_2d(hand, pos_2d, "hand_dart")
	for p in get_tree().get_nodes_in_group("players"):
		if p == owner_player or not is_instance_valid(p):
			continue
		if p.get("is_dead") == true:
			continue
		var p_pos: Vector2 = p.get_pos_2d()
		if dart_lethal and p_pos.distance_to(pos_2d) <= dart_hit_radius:
			p.take_dart_hit()
			continue
		var rope_dist := INF
		for seg_i in rope_path.size() - 1:
			rope_dist = minf(rope_dist, _point_segment_distance(p_pos, rope_path[seg_i], rope_path[seg_i + 1]))
		if rope_dist <= rope_trip_radius:
			p.apply_rope_trip()


## Shortest distance from point p to the line segment a-b (2D). Standard
## clamped-projection construction.
static func _point_segment_distance(p: Vector2, a: Vector2, b: Vector2) -> float:
	var ab: Vector2 = b - a
	var len_sq: float = ab.length_squared()
	if len_sq < 0.0001:
		return p.distance_to(a)
	var t: float = clampf((p - a).dot(ab) / len_sq, 0.0, 1.0)
	return p.distance_to(a + ab * t)


func _hand_pos_2d() -> Vector2:
	if owner_player == null or not is_instance_valid(owner_player):
		return pos_2d
	var facing: Vector2 = owner_player.aim_dir if owner_player.aim_dir.length() > 0.01 else Vector2(0.0, 1.0)
	return owner_player.get_pos_2d() + facing * hand_forward_offset


## Task #19: real 3D hand-bone position, used ONLY while HOLSTERED/CHARGING
## (the two _process()/_ready()/force_holster() call sites below) to actually
## attach the dart to the character's live animated hand instead of the flat
## fixed-offset/fixed-height approximation _hand_pos_2d() above still is.
## Deliberately does NOT replace _hand_pos_2d() itself: that function is also
## the "hand" endpoint of the rope-line used by _check_player_hits()/
## _update_rope_visual() while the dart is AWAY (FLYING/EMBEDDED/SWINGING/
## RETURNING), which this task's own scope explicitly leaves untouched -- see
## this file's header comment.
##
## Position only, deliberately -- orientation (head_mesh's basis in
## _process()) stays driven by the owner's live aim_dir exactly as before, NOT
## the hand bone's own rotation. Driving orientation from the bone too would
## make the dart wobble with idle sway/walk-cycle/attack animations instead of
## clearly telegraphing throw direction, fighting the aim-pointing behavior a
## prior task already built -- see this function's own call sites for how the
## two are kept independent (position from here, rotation unchanged).
##
## Falls back to the OLD flat approximation (at PLANE_Y) if the owner has no
## resolved hand-bone position for any reason (e.g. mesh/skeleton setup
## failed, or a duck-typed owner without get_hand_world_position() at all) --
## player.gd's get_hand_world_position() itself returns global_position
## (no forward offset) in that same failure case, which would visibly clip the
## dart into the owner's own body if used directly, so that degenerate result
## is explicitly detected and rejected here in favor of the old approximation.
func _hand_attach_pos_3d() -> Vector3:
	var fallback_2d: Vector2 = _hand_pos_2d()
	var fallback := Vector3(fallback_2d.x, PLANE_Y, fallback_2d.y)
	if owner_player == null or not is_instance_valid(owner_player):
		return fallback
	if not owner_player.has_method("get_hand_world_position"):
		return fallback
	var bone_pos: Vector3 = owner_player.get_hand_world_position()
	if not bone_pos.is_finite():
		return fallback
	if bone_pos.distance_to(owner_player.global_position) < 0.05:
		# Degenerate "unavailable" sentinel (get_hand_world_position()'s own
		# no-bone fallback) -- see this function's header comment.
		return fallback
	return bone_pos


## Chain visual (item 1) over the wrap-aware path (item 4): walks the same
## _compute_rope_path_2d() polyline _check_player_hits() and the FLYING/
## EMBEDDED constraints already use as their own source of truth, and places
## one GPU-instanced chain-link every ROPE_LINK_SPACING units along it,
## oriented along that particular sub-segment's own direction -- so a bent
## rope reads as a chain following the bend, not a straight tube overshooting
## through the obstacle it's wrapped around. Only ever writes into the
## already-allocated MultiMesh instance buffer (set_instance_transform +
## visible_instance_count) -- no per-frame mesh/resource allocation, and
## link_count is always clamped to the fixed ROPE_LINK_MAX_COUNT.
func _update_rope_visual() -> void:
	if owner_player == null or not is_instance_valid(owner_player):
		return
	var multimesh: MultiMesh = rope_mesh.multimesh
	if multimesh == null:
		return
	var hand_2d: Vector2 = _hand_pos_2d()
	# Terminate the VISUAL path at the dart's tail/pommel end (item 2's new
	# TailRing), not pos_2d (the body's center, which is what collision and
	# _check_player_hits() use) -- see HEAD_TAIL_OFFSET's own comment above.
	# rope_mesh is only ever visible during FLYING/EMBEDDED/RETURNING (see
	# _process() above), so dir_2d is always the dart's real current facing
	# here, never the stale HOLSTERED/CHARGING default.
	var tail_2d: Vector2 = pos_2d - dir_2d * HEAD_TAIL_OFFSET
	# Own state_key ("hand_dart_visual"), distinct from _check_player_hits()'s
	# "hand_dart" -- that call site's `to` endpoint is pos_2d, not tail_2d, so
	# sharing one key would feed the incremental wrap router two different
	# endpoints under the same memory slot and corrupt/oscillate its wrap
	# state (see _compute_rope_path_2d()'s own header comment on why state
	# must never leak between independent from/to endpoint pairs).
	var path: PackedVector2Array = _compute_rope_path_2d(hand_2d, tail_2d, "hand_dart_visual")

	var total_len := 0.0
	for i in path.size() - 1:
		total_len += path[i].distance_to(path[i + 1])

	if total_len < 0.01:
		multimesh.visible_instance_count = 0
		return

	var link_count: int = clampi(ceili(total_len / ROPE_LINK_SPACING), 1, ROPE_LINK_MAX_COUNT)
	var spacing: float = total_len / float(link_count)
	multimesh.visible_instance_count = link_count

	var seg_i := 0
	var seg_start: Vector2 = path[0]
	var seg_end: Vector2 = path[1]
	var seg_len: float = seg_start.distance_to(seg_end)
	var dist_into_seg := 0.0

	for link_i in link_count:
		var target_dist: float = (float(link_i) + 0.5) * spacing
		while dist_into_seg + seg_len < target_dist and seg_i < path.size() - 2:
			dist_into_seg += seg_len
			seg_i += 1
			seg_start = path[seg_i]
			seg_end = path[seg_i + 1]
			seg_len = seg_start.distance_to(seg_end)
		var t: float = clampf((target_dist - dist_into_seg) / maxf(seg_len, 0.0001), 0.0, 1.0)
		var link_pos_2d: Vector2 = seg_start.lerp(seg_end, t)
		var seg_dir: Vector2 = seg_end - seg_start
		if seg_dir.length() < 0.0001:
			seg_dir = Vector2(0.0, 1.0)
		seg_dir = seg_dir.normalized()

		var world_pos := Vector3(link_pos_2d.x, PLANE_Y, link_pos_2d.y)
		var link_basis: Basis = _basis_align_y(Vector3(seg_dir.x, 0.0, seg_dir.y))
		if link_i % 2 == 1:
			# Alternate every other link's own local-frame tilt so
			# consecutive rings read as interlocked (see ROPE_LINK_TILT's
			# own comment above for why this needs a tilt, not a twist).
			link_basis = link_basis * Basis(Vector3.RIGHT, ROPE_LINK_TILT)

		multimesh.set_instance_transform(link_i, Transform3D(link_basis, world_pos - global_position))


## Builds a Basis whose local Y axis points along dir (world-space) -- used
## to orient a unit-height cylinder mesh (authored along local Y) to stretch
## between two arbitrary points. Standard "align one axis to a direction"
## construction; the RIGHT fallback only matters if dir is ever near-vertical,
## which never happens in this flat-plane game (kept only for safety).
static func _basis_align_y(dir: Vector3) -> Basis:
	var y_axis: Vector3 = dir.normalized()
	var x_axis: Vector3 = y_axis.cross(Vector3.UP)
	if x_axis.length() < 0.001:
		x_axis = Vector3.RIGHT
	x_axis = x_axis.normalized()
	var z_axis: Vector3 = x_axis.cross(y_axis).normalized()
	return Basis(x_axis, y_axis, z_axis)


## ---------------------------------------------------------------------------
## Wrap-around routing (Task #7, item 4). Pulled forward from Phase 4's
## segmented player -> wrap point(s) -> dart constraint, WITHOUT the
## Throw+aim-direction swing-redirect input that's the rest of Phase 4 (see
## docs/implementation-plan.md) -- this only makes the existing straight-line
## FLYING/EMBEDDED/RETURNING constraint and visual wrap-aware.
##
## Deliberately a plain, bounded, script-side polyline router -- NOT the old
## (deleted, pre-weapon-removal) implementation's RigidBody3D physics-chain +
## visibility-graph approach. That system is gone along with the rest of the
## old weapon code, and its own history (many rounds of joint-solver
## instability, tunneling, and jitter chasing) is exactly why this rebuild
## intentionally does not resurrect a simulated chain: with no
## per-physics-body solver involved here, there is nothing to destabilize --
## every tick just recomputes a small, fixed-bound polyline directly from
## live obstacle geometry (arena_obstacle.gd's get_rect_2d()), the same "read
## real, already-known geometry, don't fabricate a route" principle the old
## codebase's own least-bad wrap fixes converged on.
## ---------------------------------------------------------------------------

## How far past an obstacle's own rect a wrap point is pushed out, so the
## rendered chain/constraint visibly clears the obstacle's edge instead of
## skimming exactly along its surface.
const WRAP_MARGIN: float = 0.15
## Shrink applied only for the "does this candidate sub-segment cross the
## obstacle's real interior" validity test, so a segment that just touches an
## obstacle's own corner/edge (which every candidate route legitimately does,
## by construction) is never mistaken for actually cutting through it.
const WRAP_INTERIOR_EPS: float = 0.02
## Bounds how many wrap-point-insertion passes a single path computation can
## take -- with the small, fixed number of obstacles this game ever has
## (a couple of pillars plus a handful of scattered trees/cacti), this is far
## more headroom than any real configuration needs, while still guaranteeing
## the per-tick cost and the resulting path's point count both stay bounded
## no matter what the scene contains.
const MAX_WRAP_PASSES: int = 4


## Public accessor so player.gd's own wrap-aware leash clamp
## (_apply_rope_leash_velocity_clamp()) can read the exact same live wrapped
## path this file uses for its own constraint/visual/hit-detection, rather
## than recomputing (and potentially disagreeing with) obstacle geometry
## independently. to_point is typically the player's own current position;
## the path always starts at the dart's own current pos_2d.
func get_rope_path_2d(to_point: Vector2) -> PackedVector2Array:
	return _compute_rope_path_2d(pos_2d, to_point, "leash")


## Builds the polyline from `from` to `to`, inserting/removing wrap points
## wherever a real obstacle's (grown) rect currently blocks/clears a segment.
##
## Task #8 rewrite: this used to be a fully STATELESS "shortest path among a
## fixed set of corner candidates" search, recomputed from nothing every
## single call (see git history on this function for the old body). That is
## exactly the "ninja rope" class of bug: as a player circles an obstacle
## with the dart EMBEDDED behind it, there is a point where wrapping via one
## side vs. the other side of the rect becomes equally short (or crosses
## over) and the GLOBAL argmin flips discontinuously -- a visible snap/pop to
## the opposite side of the pillar, reported as Task #8's bug.
##
## The fix is to carry real state between calls (_wrap_state, keyed by
## `state_key` so independent callers -- hand<->dart, dart<->player leash
## pivot, owner<->flying-trial-target -- don't cross-contaminate each
## other's memory) and only ever change it LOCALLY:
##  - a wrap point is REMOVED only once the segment that would bypass it
##    (its two current neighbors, skipping it) becomes genuinely clear again
##    -- "unwrapping" as the far end swings back into direct line of sight.
##  - a wrap point is INSERTED only once a currently-adjacent pair of points
##    newly becomes blocked -- "wrapping on" a corner right as the rope's
##    real physical contact with the obstacle begins.
## Neither of these ever re-litigates an already-established wrap corner
## against some OTHER, globally-shorter route -- so walking a full circle
## around an obstacle with the dart anchored behind it just keeps
## incrementally winding the wrap around the same rotational direction the
## player is walking (exactly like a real leash winding around a pole),
## continuously, instead of jumping to the "shorter" opposite side.
##
## Common case (no obstacle in the way) costs one cheap intersection test per
## obstacle and returns the original 2-point line unchanged.
func _compute_rope_path_2d(from: Vector2, to: Vector2, state_key: String = "") -> PackedVector2Array:
	var obstacles: Array = get_tree().get_nodes_in_group("obstacles")
	var margin_rects: Array[Rect2] = []
	var interior_rects: Array[Rect2] = []
	for obs in obstacles:
		if not is_instance_valid(obs) or not obs.has_method("get_rect_2d"):
			continue
		var rect: Rect2 = obs.get_rect_2d().grow(WRAP_MARGIN)
		# Blocking tests use a slightly SHRUNK copy of the grown rect, not the
		# grown rect itself -- a segment that ends exactly AT one of the grown
		# rect's own corners (any wrap point this same function just
		# inserted, by construction) only ever touches that rect's boundary,
		# and _segment_intersects_rect() is boundary-inclusive. Without this
		# shrink, a freshly-inserted wrap segment would immediately
		# re-trigger its own "needs wrapping" check next pass. The candidate
		# corners themselves still come from the un-shrunk `rect` so wrap
		# points stay genuinely WRAP_MARGIN clear of the obstacle's real
		# footprint.
		var interior: Rect2 = rect.grow(-WRAP_INTERIOR_EPS)
		if interior.size.x <= 0.0 or interior.size.y <= 0.0:
			continue
		margin_rects.append(rect)
		interior_rects.append(interior)

	if margin_rects.is_empty():
		_wrap_state.erase(state_key)
		return PackedVector2Array([from, to])

	var wrap_points: PackedVector2Array = _wrap_state.get(state_key, PackedVector2Array())

	for _pass_i in MAX_WRAP_PASSES:
		var changed := false

		# Removal pass: drop any wrap point whose bypass segment (its two
		# current neighbors, skipping it) is now clear of every obstacle.
		var i := 0
		while i < wrap_points.size():
			var prev: Vector2 = from if i == 0 else wrap_points[i - 1]
			var next: Vector2 = to if i == wrap_points.size() - 1 else wrap_points[i + 1]
			if _segment_clear_of_all(prev, next, interior_rects):
				wrap_points.remove_at(i)
				changed = true
			else:
				i += 1

		# Insertion pass: check each currently-adjacent pair of points for a
		# NEW block, inserting exactly one corner per newly-blocked segment.
		var pts: PackedVector2Array = PackedVector2Array([from])
		pts.append_array(wrap_points)
		pts.append(to)
		var seg_i := 0
		while seg_i < pts.size() - 1:
			var a: Vector2 = pts[seg_i]
			var b: Vector2 = pts[seg_i + 1]
			var blocking_idx := -1
			for r_i in interior_rects.size():
				if _segment_intersects_rect(a, b, interior_rects[r_i]):
					blocking_idx = r_i
					break
			if blocking_idx >= 0:
				var corner: Vector2 = _pick_wrap_corner(a, b, margin_rects[blocking_idx])
				wrap_points.insert(seg_i, corner)
				pts.insert(seg_i + 1, corner)
				changed = true
				seg_i += 2
			else:
				seg_i += 1

		if not changed:
			break

	_wrap_state[state_key] = wrap_points
	var path: PackedVector2Array = PackedVector2Array([from])
	path.append_array(wrap_points)
	path.append(to)
	return path


## True if segment a-b is clear of every rect in `interior_rects` (none of
## them intersect it) -- used by the removal pass above.
static func _segment_clear_of_all(a: Vector2, b: Vector2, interior_rects: Array[Rect2]) -> bool:
	for r in interior_rects:
		if _segment_intersects_rect(a, b, r):
			return false
	return true


## Picks a SINGLE corner of `margin_rect` to insert between a and b, given
## that segment a-b just became blocked by it. Deliberately local, not a
## global shortest-path search (see _compute_rope_path_2d()'s header comment
## for why): if `a` or `b` is ITSELF already one of this same rect's 4
## corners (i.e. the rope is already wrapped partway around this obstacle),
## only the two corners ADJACENT to it on the rect's own boundary are
## considered -- this is what makes a growing wrap keep hugging the same
## rotational direction it's already wrapped onto (peeling further around
## the SAME side) instead of ever jumping to the opposite side. Only when
## neither endpoint is already a corner of this rect (the first-ever wrap
## onto it) are all 4 corners considered, scored by shortest valid detour --
## unambiguous in practice since that transition only ever happens at the
## one specific corner the segment is newly grazing, not a symmetric tie.
func _pick_wrap_corner(a: Vector2, b: Vector2, margin_rect: Rect2) -> Vector2:
	var c0: Vector2 = margin_rect.position                              # (min x, min y)
	var c1 := Vector2(margin_rect.end.x, margin_rect.position.y)        # (max x, min y)
	var c2: Vector2 = margin_rect.end                                   # (max x, max y)
	var c3 := Vector2(margin_rect.position.x, margin_rect.end.y)        # (min x, max y)
	var all_corners: Array[Vector2] = [c0, c1, c2, c3]

	# A corner that coincides with an endpoint we're already routing between
	# can never usefully be inserted BETWEEN them -- exclude it from every
	# candidate set below (both the continuity-restricted search and its
	# fallback). Without this, an embedded dart -- which routinely sits
	# slightly INSIDE an obstacle's own interior test rect, since
	# embed_depth deliberately pulls it into the surface it stuck to -- would
	# have its OWN embed corner offered back to itself as a "detour",
	# inserting a duplicate, zero-length wrap segment right on top of an
	# already-chosen corner (confirmed by direct measurement: a real headless
	# probe walking a circle around a pillar caught this exact duplicate
	# corner in the live path array).
	var usable_corners: Array[Vector2] = []
	for c in all_corners:
		if c.distance_to(a) > 0.01 and c.distance_to(b) > 0.01:
			usable_corners.append(c)
	if usable_corners.is_empty():
		return all_corners[0]  # degenerate: every corner coincides with a or b

	var candidate_corners: Array[Vector2] = _neighbor_corners_of(a, all_corners)
	candidate_corners = candidate_corners.filter(func(c): return usable_corners.has(c))
	if candidate_corners.is_empty():
		candidate_corners = _neighbor_corners_of(b, all_corners).filter(func(c): return usable_corners.has(c))
	if candidate_corners.is_empty():
		candidate_corners = usable_corners

	var interior: Rect2 = margin_rect.grow(-WRAP_INTERIOR_EPS)
	var has_interior: bool = interior.size.x > 0.0 and interior.size.y > 0.0

	var best: Vector2 = usable_corners[0]
	var best_len := INF
	for c in candidate_corners:
		if has_interior and (_segment_intersects_rect(a, c, interior) or _segment_intersects_rect(c, b, interior)):
			continue
		var total: float = a.distance_to(c) + c.distance_to(b)
		if total < best_len:
			best_len = total
			best = c
	if best_len < INF:
		return best

	# Fallback: no candidate's own sub-segments fully clear the interior
	# (rare degenerate case, e.g. an endpoint itself sitting inside the grown
	# rect) -- fall back to the shortest of the remaining usable corners
	# regardless.
	for c in usable_corners:
		var total2: float = a.distance_to(c) + c.distance_to(b)
		if total2 < best_len:
			best_len = total2
			best = c
	return best


## If `p` matches one of `corners` (within a small epsilon -- exact equality
## isn't safe against float round-trip through Rect2 math), returns that
## corner's two neighbors on the rect's own boundary (cyclic order c0-c1-c2-
## c3-c0). Empty array if `p` isn't one of these 4 corners at all.
static func _neighbor_corners_of(p: Vector2, corners: Array[Vector2]) -> Array[Vector2]:
	for idx in corners.size():
		if corners[idx].distance_to(p) < 0.01:
			return [corners[(idx + 1) % 4], corners[(idx + 3) % 4]]
	return []


## Standard slab-method segment-vs-AABB overlap test (boundary-inclusive) --
## true if the segment p1-p2 touches or crosses rect at all.
static func _segment_intersects_rect(p1: Vector2, p2: Vector2, rect: Rect2) -> bool:
	var d: Vector2 = p2 - p1
	var t0 := 0.0
	var t1 := 1.0
	var mn: Vector2 = rect.position
	var mx: Vector2 = rect.end
	for axis in 2:
		var p1v: float = p1[axis]
		var dv: float = d[axis]
		var minv: float = mn[axis]
		var maxv: float = mx[axis]
		if absf(dv) < 0.000001:
			if p1v < minv or p1v > maxv:
				return false
		else:
			var ta: float = (minv - p1v) / dv
			var tb: float = (maxv - p1v) / dv
			if ta > tb:
				var tmp: float = ta
				ta = tb
				tb = tmp
			t0 = maxf(t0, ta)
			t1 = minf(t1, tb)
			if t0 > t1:
				return false
	return true


## Walks the wrap-aware path from `from_pos` toward `target`, stopping once
## `max_len` of path length is spent -- i.e. "pay out at most max_len of real
## rope, wrap included" rather than a plain circle-around-from_pos radius
## check. Returns `target` unchanged if the real wrapped distance is already
## within budget (the common case). Used by _process_flying() for its
## always-on owner-relative range constraint ("flying_clamp" key) -- always
## rope_length for a plain FLYING throw; as of Task #20, possibly a smaller
## charge-scaled value (still measured from the OWNER, same key, same
## endpoint pair) for a SWINGING redirect leg -- see that function's own
## range_cap comment.
func _clamp_along_wrap_path(from_pos: Vector2, target: Vector2, max_len: float, state_key: String = "flying_clamp") -> Vector2:
	var path: PackedVector2Array = _compute_rope_path_2d(from_pos, target, state_key)
	var total_len := 0.0
	for i in path.size() - 1:
		total_len += path[i].distance_to(path[i + 1])
	if total_len <= max_len:
		return target

	var remaining: float = max_len
	for i in path.size() - 1:
		var seg_len: float = path[i].distance_to(path[i + 1])
		if remaining <= seg_len:
			var t: float = remaining / seg_len if seg_len > 0.0001 else 0.0
			return path[i].lerp(path[i + 1], t)
		remaining -= seg_len
	return path[path.size() - 1]


## Task #21 fix: predicts where a hold-then-release SWINGING redirect leg
## would actually land, given the dart's CURRENT position, the player's aim
## direction, and this leg's charge-scaled effective_range (player.gd's
## _compute_redirect_travel_distance() -- an owner-relative max distance
## budget, NOT a travel distance -- see that const's own header comment).
## Used by player.gd's _redirect_is_pointless_micro_hop() to measure the
## REAL predicted travel distance of this leg (this landing point minus the
## dart's CURRENT pos_2d), instead of the Task #20 bug: subtracting two
## different owner-relative quantities (this leg's final owner-relative
## range budget minus the dart's ALREADY-existing owner-relative distance)
## that only coincidentally resembles "how far will this leg travel" when
## the dart starts close to the owner, and is frequently small or negative
## once the dart is already sitting anywhere near its normal, far-from-owner
## resting distance -- exactly the reported "redirect snaps the dart back to
## hand" symptom, since that wrongly read as a pointless micro-hop and
## resolved to force_holster() instead of begin_swing_redirect().
##
## Mirrors _process_flying()'s own range_cap/_clamp_along_wrap_path() call
## (SMALLER of rope_length and effective_range, wrap-aware, measured FROM
## THE OWNER) so the predicted landing point is the same point a real
## redirect leg aimed the same direction would clamp to once it travels far
## enough to hit this leg's own range cap (assuming nothing in the way stops
## it sooner via an obstacle/wall embed -- this prediction intentionally
## doesn't simulate wall collisions, only the range-cap clamp, since it only
## needs to answer "would this be a meaningfully-sized leg", not compute an
## exact final landing spot).
##
## Uses its OWN disposable wrap-state key ("redirect_preview") rather than
## "flying_clamp" -- this runs from EMBEDDED, before any real SWINGING leg
## exists, and must not perturb "flying_clamp"'s own incremental wrap memory
## (begin_swing_redirect() unconditionally re-bootstraps "flying_clamp" from
## "leash" on every real redirect anyway, so reusing that key here would
## currently be harmless in practice too, but a dedicated key keeps this
## prediction from ever becoming a hidden dependency the way "leash"/
## "flying_clamp"/"returning" already are for each other -- see
## _compute_rope_path_2d()'s own header comment on why independent callers
## get independent state keys).
##
## Task #22 fix: this used to reach "far_target" from the dart's OWN CURRENT
## position along the raw aim_dir compass heading (the same off-ray-start bug
## begin_swing_redirect() itself had) and rely on the wrap-aware clamp to cut
## that reach down to range_cap -- which, since far_target was NOT generally
## on the owner-centered aim ray, found a boundary-circle intersection point
## that could differ from where a real (now-fixed) redirect leg actually
## lands. Now computes the exact SAME target_point formula
## begin_swing_redirect() uses -- owner_pos + aim_dir * range_cap, a point
## directly on the aim ray from the OWNER -- and clamps that (wrap-aware,
## same as before) rather than an off-ray reach past it. Must stay in sync
## with begin_swing_redirect() any time that formula changes.
func predict_redirect_landing_point(owner_pos: Vector2, aim_dir: Vector2, effective_range: float) -> Vector2:
	var dir: Vector2 = aim_dir.normalized() if aim_dir.length() > 0.01 else Vector2(0.0, 1.0)
	var range_cap: float = minf(rope_length, effective_range)
	var target_point: Vector2 = owner_pos + dir * range_cap
	return _clamp_along_wrap_path(owner_pos, target_point, range_cap, "redirect_preview")
