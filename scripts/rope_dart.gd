extends CharacterBody3D
## Rope dart weapon -- Phase 1+2 of the post-GDD-rewrite rebuild (see
## docs/implementation-plan.md). Full GDD state machine is declared up front
## (HOLSTERED, CHARGING, FLYING, EMBEDDED, SWINGING, RETURNING). Phase 1 built
## HOLSTERED -> CHARGING -> FLYING -> EMBEDDED; Phase 2 (this pass) adds
## RETURNING plus player-hit detection (dart contact = lethal, rope-line
## contact = trip/slow) -- see begin_recall()/_process_returning() and
## _check_player_hits() below. SWINGING is still an unused ordinal, left for
## Phase 4.
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
## the floor." From EMBEDDED, Recall (Phase 2, see begin_recall()) is the way
## out into RETURNING; there is no unanchor/swing yet (Phase 4).

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

var _charge_time: float = 0.0
var _flight_speed: float = 16.0
var _recall_time: float = 0.0

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
const ROPE_LINK_SPACING: float = 0.18
const ROPE_LINK_MAX_COUNT: int = 48
## Every other link is additionally tilted 90 degrees around its own local
## X axis so consecutive rings alternately face "on" vs "edge-on" toward the
## rope's own travel direction -- the standard interlocked chain-link look
## (a torus is rotationally symmetric around its own Y axis, so twisting
## around Y would be invisible; this instead alternates which axis the ring
## opens along).
const ROPE_LINK_TILT: float = PI * 0.5
@onready var collision_shape: CollisionShape3D = $CollisionShape3D


func _ready() -> void:
	collision_layer = 0  # nothing else's mask can ever detect this body back
	collision_mask = 1   # detects the default layer: ground, pillars, trees
	pos_2d = _hand_pos_2d()
	global_position = Vector3(pos_2d.x, PLANE_Y, pos_2d.y)
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
			own_mm.instance_count = src_mm.instance_count
			own_mm.visible_instance_count = 0
			rope_mesh.multimesh = own_mm


func _process(_delta: float) -> void:
	if owner_player == null or not is_instance_valid(owner_player):
		return
	if state == State.HOLSTERED or state == State.CHARGING:
		pos_2d = _hand_pos_2d()
		global_position = Vector3(pos_2d.x, PLANE_Y, pos_2d.y)
	if rope_mesh != null:
		rope_mesh.visible = (state == State.FLYING or state == State.EMBEDDED or state == State.RETURNING)
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
			# Stationary, but still lethal on contact (GDD Combat: dart contact
			# is always lethal "in every dart state: Flying, Embedded landing,
			# Swinging, Returning") -- a player walking into a landed dart dies.
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
	# the raw straight-line beeline -- exceed rope_length this tick. See
	# _clamp_along_wrap_path()/_compute_rope_path_2d() below.
	var reached_max_range := false
	var clamped_pos_2d: Vector2 = _clamp_along_wrap_path(owner_pos, next_pos_2d, rope_length)
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


## Called on Recall-button press while the dart is away (FLYING or EMBEDDED
## -- see player.gd's _handle_recall_input()). No-op from any other state
## (already HOLSTERED/CHARGING, or already RETURNING).
func begin_recall() -> void:
	if state != State.FLYING and state != State.EMBEDDED:
		return
	state = State.RETURNING
	_recall_time = 0.0
	state_changed.emit(state)


## RETURNING: straight line back toward the OWNER's current (possibly
## moving) position, not a fixed point captured at recall-start -- so a
## moving owner still gets a chasing dart, not one that returns to where they
## used to be. Speed ramps up over time (GDD: "Recall speed increases over
## time"). Deliberately ignores obstacles/rope_length -- being pulled back in
## isn't a physics sweep like FLYING, it's a scripted retrieval.
func _process_returning(delta: float) -> void:
	if owner_player == null or not is_instance_valid(owner_player):
		_holster_in_place()
		return
	_recall_time += delta
	var speed: float = recall_base_speed + recall_accel * _recall_time
	var owner_pos: Vector2 = owner_player.get_pos_2d()
	var to_owner: Vector2 = owner_pos - pos_2d
	var dist: float = to_owner.length()
	if dist <= recall_arrival_radius:
		_holster_in_place()
		return
	var move_dir: Vector2 = to_owner / dist
	pos_2d += move_dir * minf(speed * delta, dist)
	dir_2d = move_dir
	global_position = Vector3(pos_2d.x, PLANE_Y, pos_2d.y)


func _holster_in_place() -> void:
	state = State.HOLSTERED
	state_changed.emit(state)


## Player-hit detection (Phase 2). Deliberately NOT the move_and_collide
## physics sweep used for FLYING's wall/pillar/tree embed detection --
## rope_dart.gd adds a collision exception for every player every tick
## specifically so that sweep never touches players (see this file's header
## comment and _process_flying()). This is a separate, purely-2D distance
## check run every tick the dart is away from the owner's hand
## (FLYING/EMBEDDED/RETURNING -- see _physics_process()'s match above).
##
## Dart contact (distance from pos_2d to a player) is always lethal. Rope
## contact -- as of Task #7 item 4, distance from ANY segment of the rope's
## real wrap-aware path (hand -> wrap point(s) -> dart, see
## _compute_rope_path_2d()), not just a single straight hand-to-dart segment
## -- only trips/slows, checked second, and only for players who weren't
## already killed by the dart-contact check this tick, so a player standing
## right at the dart head is never *also* counted as merely tripped.
func _check_player_hits() -> void:
	if owner_player == null or not is_instance_valid(owner_player):
		return
	var hand: Vector2 = _hand_pos_2d()
	var rope_path: PackedVector2Array = _compute_rope_path_2d(hand, pos_2d)
	for p in get_tree().get_nodes_in_group("players"):
		if p == owner_player or not is_instance_valid(p):
			continue
		if p.get("is_dead") == true:
			continue
		var p_pos: Vector2 = p.get_pos_2d()
		if p_pos.distance_to(pos_2d) <= dart_hit_radius:
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
	var path: PackedVector2Array = _compute_rope_path_2d(hand_2d, pos_2d)

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
	return _compute_rope_path_2d(pos_2d, to_point)


## Builds the polyline from `from` to `to`, inserting wrap points wherever
## the straight line between two consecutive points currently crosses a real
## obstacle's (grown) rect. Common case (no obstacle in the way) costs one
## cheap intersection test per obstacle and returns the original 2-point
## line unchanged -- no extra allocation beyond the 2-element array itself.
func _compute_rope_path_2d(from: Vector2, to: Vector2) -> PackedVector2Array:
	var path: PackedVector2Array = PackedVector2Array([from, to])
	var obstacles: Array = get_tree().get_nodes_in_group("obstacles")
	if obstacles.is_empty():
		return path

	for _pass_i in MAX_WRAP_PASSES:
		var inserted := false
		var seg_i := 0
		while seg_i < path.size() - 1:
			var a: Vector2 = path[seg_i]
			var b: Vector2 = path[seg_i + 1]
			var hit_rect: Rect2
			var found_hit := false
			for obs in obstacles:
				if not is_instance_valid(obs) or not obs.has_method("get_rect_2d"):
					continue
				var rect: Rect2 = obs.get_rect_2d().grow(WRAP_MARGIN)
				# Detection uses a slightly SHRUNK copy of the grown rect, not
				# the grown rect itself -- a segment that ends exactly AT one
				## of the grown rect's own corners (any wrap point this same
				# function just inserted, by construction) only ever touches
				# that rect's boundary, and _segment_intersects_rect() is
				# boundary-inclusive. Without this shrink, a freshly-inserted
				# wrap segment would immediately re-trigger its own
				# "needs wrapping" check next pass -- confirmed by direct
				# measurement (a real headless probe run showed the same
				# corner pair inserted a dozen redundant times, one extra
				# pair per pass, before this fix). The candidate corners
				# themselves (_route_around_rect()) still use the un-shrunk
				# `rect` so wrap points stay genuinely WRAP_MARGIN clear of
				# the obstacle's real footprint.
				var interior: Rect2 = rect.grow(-WRAP_INTERIOR_EPS)
				if interior.size.x <= 0.0 or interior.size.y <= 0.0:
					continue
				if _segment_intersects_rect(a, b, interior):
					hit_rect = rect
					found_hit = true
					break
			if found_hit:
				var wrap_pts: PackedVector2Array = _route_around_rect(a, b, hit_rect)
				var new_path: PackedVector2Array = PackedVector2Array()
				for i in seg_i + 1:
					new_path.append(path[i])
				new_path.append_array(wrap_pts)
				for i in range(seg_i + 1, path.size()):
					new_path.append(path[i])
				path = new_path
				inserted = true
				seg_i += wrap_pts.size() + 1
			else:
				seg_i += 1
		if not inserted:
			break
	return path


## Finds the shortest-of-a-small-fixed-set detour around a single obstacle's
## rect that gets from a to b: either via one of its 4 corners, or (needed
## whenever a and b sit on roughly opposite sides of the rect, so no single
## corner alone clears it -- e.g. a dart embedded directly behind a pillar
## with the player on the far side) via two adjacent corners hugging one of
## its 4 sides. Only 12 fixed candidates are ever considered (4 one-corner +
## 8 two-corner, one pair per side per direction) -- a small, constant-time
## check, not a general visibility-graph search. Prefers the shortest
## candidate whose own sub-segments genuinely clear the rect's interior;
## falls back to the shortest candidate overall if none fully clear it (rare
## degenerate case, e.g. an endpoint itself sitting inside the grown rect).
func _route_around_rect(a: Vector2, b: Vector2, rect: Rect2) -> PackedVector2Array:
	var c0: Vector2 = rect.position                              # (min x, min y)
	var c1 := Vector2(rect.end.x, rect.position.y)                # (max x, min y)
	var c2: Vector2 = rect.end                                    # (max x, max y)
	var c3 := Vector2(rect.position.x, rect.end.y)                # (min x, max y)

	var candidates: Array = [
		PackedVector2Array([c0]), PackedVector2Array([c1]), PackedVector2Array([c2]), PackedVector2Array([c3]),
		PackedVector2Array([c0, c1]), PackedVector2Array([c1, c2]), PackedVector2Array([c2, c3]), PackedVector2Array([c3, c0]),
		PackedVector2Array([c1, c0]), PackedVector2Array([c2, c1]), PackedVector2Array([c3, c2]), PackedVector2Array([c0, c3]),
	]

	var interior_rect: Rect2 = rect.grow(-WRAP_INTERIOR_EPS)
	var best_valid: PackedVector2Array = PackedVector2Array()
	var best_valid_len := INF
	var best_any: PackedVector2Array = PackedVector2Array()
	var best_any_len := INF

	for cand in candidates:
		var pts: PackedVector2Array = PackedVector2Array([a])
		pts.append_array(cand)
		pts.append(b)
		var total_len := 0.0
		var valid := true
		for i in pts.size() - 1:
			total_len += pts[i].distance_to(pts[i + 1])
			if valid and interior_rect.size.x > 0.0 and interior_rect.size.y > 0.0 and _segment_intersects_rect(pts[i], pts[i + 1], interior_rect):
				valid = false
		if total_len < best_any_len:
			best_any_len = total_len
			best_any = cand
		if valid and total_len < best_valid_len:
			best_valid_len = total_len
			best_valid = cand

	return best_valid if best_valid_len < INF else best_any


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
## within budget (the common case). Used by both _process_flying()'s FLYING
## constraint and (via get_rope_path_2d()) player.gd's EMBEDDED leash clamp.
func _clamp_along_wrap_path(from_pos: Vector2, target: Vector2, max_len: float) -> Vector2:
	var path: PackedVector2Array = _compute_rope_path_2d(from_pos, target)
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
