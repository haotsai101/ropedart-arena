extends Node3D
## Thrown rope dart: FLYING → ANCHORED → (optionally) RECALLING.
##
## The rope+dart system lives entirely within ONE fixed horizontal plane at
## the owner's hand height (see plane_y, computed once in launch() from
## get_hand_world_position() and held constant for the dart's whole
## lifetime) -- this is what makes "real" physics collision for this weapon
## compatible with the rest of the game's flat XZ-plane gameplay math (see
## CLAUDE.md's core invariant): rather than a free-hanging 3D rope, it's a
## rope+dart constrained to 2 degrees of freedom, with real physics used
## only for detecting what's solid at that one height.
##
## FLYING uses a real physics raycast each tick (see _raycast_obstacle())
## against the map's actual CollisionShape3D geometry (the same one players
## already collide with) to detect pillars/trees/cacti -- explicitly
## excluding every player body, so the rope/dart always passes through
## characters. A hit ANCHORS the dart there, stuck until the owner recalls
## it or walks over it (pickup_radius) -- same as before.
##
## The rope has a fixed length (ROPE_LENGTH, 4x a character's height) rather
## than growing with charge power -- charge now scales travel_speed only.
## Reaching full extension without hitting anything doesn't anchor it in
## place; it immediately yanks back into RECALLING instead, like snapping
## taut on a real tether.
##
## Player hit detection (_check_hits()) is unchanged: still pure 2D capsule
## math, head vs. body, kill vs. trip()'s "clothesline" stagger -- that's a
## separate concern from the map-collision system above and was never the
## part reported as broken.

enum State { FLYING, ANCHORED, RECALLING }

@export var travel_speed: float = 18.0
@export var hit_radius: float = 0.6  # matches the character's outstretched arm/leg reach (~0.79 at max swing), not just body radius (~0.48)
## Tight radius around the capsule's top point only -- a hit inside this is a
## head hit (kill); anywhere else within hit_radius along the capsule is a
## body hit (clothesline).
@export var head_hit_radius: float = 0.35
@export var arena_half: float = 14.5
## How close the owner needs to be (walking up, or via recall) to reclaim the dart.
@export var pickup_radius: float = 0.9
## Recall is deliberately faster than the base throw speed -- pulling it back
## in should feel snappier than the outbound throw, especially since charged
## throws can nearly double travel_speed on the way out.
@export var recall_speed: float = 24.0

const BASE_SPEED: float = 18.0
## A KayKit character reads at ~2.0 units tall on screen (see player.gd's
## _ready() comment on the 0.85 mesh scale) -- 4x that.
const ROPE_LENGTH: float = 8.0

## Obstacle collision boxes (pillars in main.tscn, trees/cacti added by
## nature_scatter.gd's _add_obstacle_collision) all uniformly span world Y
## [0.0, 2.0]. get_hand_world_position() tracks the owner's actual animated
## hand bone, which sweeps through a wide arc during the charge/throw
## animations -- sampled raw at the exact instant launch() fires, this
## occasionally landed near/below ground (rope render fell under the floor)
## or above the obstacle band (the raycast's fixed-height line passed clean
## over a pillar it visually looked like it should hit, since a physics ray
## only detects geometry actually intersecting that one exact height).
## Clamping the one-time sample into a safe band well inside the shared
## obstacle range fixes both without needing to fight the animation's timing.
const MIN_PLANE_Y: float = 0.5
const MAX_PLANE_Y: float = 1.6

## A player's hitbox is a capsule (base at their ground position, extending
## toward CAPSULE_DIR by capsule_height) instead of a single circle, so it
## covers head-to-toe rather than just the body's ground footprint. This
## matters specifically because arena_camera.gd uses a fixed 45°-tilted
## orthographic view: a point at world height h renders at the same screen
## position as a ground-level point shifted by h in -Z (orthographic
## projection is invariant along the view direction), so a character's
## visually "upper body" appears shifted toward -Z from their true XZ
## position — the capsule's far end approximates where that upper body
## actually reads on screen.
const CAPSULE_DIR: Vector2 = Vector2(0, -1)
@export var capsule_height: float = 1.4

## Number of straight segments the rope is drawn as between hand and head --
## a single stretched segment (the old approach) reads as a rigid rod
## recalculated every frame rather than an actual rope, since it's always
## the exact straight-line distance between the two points. Sampling
## several points along a sagging curve and drawing a short segment between
## each pair gives it a real hanging-rope silhouette instead.
const ROPE_SEGMENTS: int = 8
## World-space vertical droop applied at the rope's midpoint, scaled by its
## current length (a fully-extended throw sags more than a rope that's
## mostly reeled back in during RECALLING).
const ROPE_SAG_FACTOR: float = 0.12
const ROPE_SAG_MAX: float = 0.35
## _snap_to_rect_edge() (reused from the dart's own obstacle-stop logic)
## returns a point exactly ON the obstacle's boundary -- with zero
## clearance, a rope bending there sits flush against the surface, which
## can read as "still touching" the obstacle rather than visibly clearing
## it. Pushed outward from the rect center by this much instead.
const ROPE_BEND_CLEARANCE: float = 0.15

## dart_head.glb's own local geometry, measured directly off its exported
## glTF vertex data (NOT by re-importing into Blender, which silently
## converts back from glTF's Y-up to Blender's Z-up and hides the real
## axes): blade tip at local Z=-0.55, pommel at local Z=+0.315 -- so "blade
## forward" is local -Z, and the rope should attach at the pommel end
## (DAGGER_POMMEL_OFFSET), not the model's origin.
const DAGGER_POMMEL_OFFSET: float = 0.315

var state: int = State.FLYING
var owner_player: Node3D = null
var head_2d: Vector2 = Vector2.ZERO
var origin_2d: Vector2 = Vector2.ZERO
var dir_2d: Vector2 = Vector2.ZERO
var charge_ratio: float = 0.0
## The one world-space height the whole rope+dart lives at for this dart's
## entire lifetime -- set once in launch() from the owner's hand bone and
## never touched again, even as the owner moves or crouches or the dart
## changes state. This is what keeps the "real physics" raycast below
## meaningful: a single ray at a fixed height, not a moving target.
var plane_y: float = 1.0
var _rope_segments: Array[MeshInstance3D] = []

@onready var head_mesh: Node3D = $Head
@onready var rope_mesh: MeshInstance3D = $Rope


func _ready() -> void:
	# $Rope (authored in rope_dart.tscn, with the actual rope material) is
	# segment 0; build the rest by sharing its mesh + material rather than
	# duplicating the scene-authored resources.
	_rope_segments.append(rope_mesh)
	var shared_mat: Material = rope_mesh.get_surface_override_material(0)
	for i in range(ROPE_SEGMENTS - 1):
		var seg := MeshInstance3D.new()
		seg.mesh = rope_mesh.mesh
		seg.set_surface_override_material(0, shared_mat)
		add_child(seg)
		_rope_segments.append(seg)


func launch(player: Node3D, from_2d: Vector2, aim: Vector2, ratio: float = 0.0) -> void:
	owner_player = player
	origin_2d = from_2d
	head_2d = from_2d
	dir_2d = aim.normalized()
	charge_ratio = ratio
	# Scale speed only -- rope length is fixed (ROPE_LENGTH), not charge-scaled.
	travel_speed = BASE_SPEED * lerp(1.0, 2.0, ratio)
	var raw_hand_y: float = player.get_hand_world_position().y if player.has_method("get_hand_world_position") \
		else player.global_position.y + 1.0
	plane_y = clampf(raw_hand_y, MIN_PLANE_Y, MAX_PLANE_Y)
	# Larger dart mesh at higher charge gives instant visual feedback on launch
	head_mesh.scale = Vector3.ONE * lerp(1.0, 1.5, ratio)

	# Tint dart + rope to player's color
	var head_mi: MeshInstance3D = head_mesh as MeshInstance3D
	if head_mi == null:
		# GLB head is a Node3D wrapping a MeshInstance3D child — find by type
		for child in head_mesh.find_children("*", "MeshInstance3D", true, false):
			head_mi = child as MeshInstance3D
			if head_mi != null:
				break
	if head_mi != null:
		var surface_count: int = head_mi.get_surface_override_material_count()
		var base_mat: StandardMaterial3D
		if surface_count > 0:
			base_mat = head_mi.get_surface_override_material(0) as StandardMaterial3D
		if base_mat == null and head_mi.mesh != null:
			base_mat = head_mi.mesh.surface_get_material(0) as StandardMaterial3D
		if base_mat != null:
			var tinted := base_mat.duplicate() as StandardMaterial3D
			tinted.albedo_color = owner_player.player_color
			tinted.emission_enabled = true
			tinted.emission = owner_player.player_color * 0.4
			head_mi.set_surface_override_material(0, tinted)
	# Rope keeps its own authored material (natural rope color, see
	# rope_dart.tscn) rather than being player-tinted like the blade --
	# the head is what identifies whose dart it is.

	state = State.FLYING
	add_to_group("darts")


## Called by the owner (pressing throw again while the dart is out) to pull
## it back regardless of whether it's still flying or already anchored.
## No-op while already recalling.
func recall() -> void:
	if state != State.RECALLING:
		state = State.RECALLING


func _physics_process(delta: float) -> void:
	if not is_instance_valid(owner_player):
		queue_free()
		return

	match state:
		State.FLYING:
			var prev_head_2d: Vector2 = head_2d
			head_2d += dir_2d * travel_speed * delta
			if _check_hits():
				_anchor()
				_render()
				return
			# Anchor at the arena boundary walls
			if absf(head_2d.x) >= arena_half or absf(head_2d.y) >= arena_half:
				head_2d.x = clampf(head_2d.x, -arena_half, arena_half)
				head_2d.y = clampf(head_2d.y, -arena_half, arena_half)
				_anchor()
			else:
				# Real physics raycast (prev_head_2d -> head_2d, at plane_y) against
				# the map's actual CollisionShape3D geometry instead of a hand-rolled
				# 2D rect test -- this is what actually stops the dart on pillars,
				# trees, and cacti using the same collision the player already
				# bumps into, with player bodies explicitly excluded so the dart
				# never anchors on a character it merely grazed.
				var hit_point_2d: Variant = _raycast_obstacle(prev_head_2d, head_2d)
				if hit_point_2d != null:
					head_2d = hit_point_2d
					_anchor()
				elif head_2d.distance_to(origin_2d) >= ROPE_LENGTH:
					# Fixed-length rope snapping taut: rather than anchoring at empty
					# air, it yanks straight back toward the owner.
					head_2d = origin_2d + dir_2d * ROPE_LENGTH
					recall()

		State.ANCHORED:
			if owner_player.get_pos_2d().distance_to(head_2d) < pickup_radius:
				_pick_up()
				return

		State.RECALLING:
			var to_owner: Vector2 = owner_player.get_pos_2d() - head_2d
			if to_owner.length() < pickup_radius:
				_pick_up()
				return
			head_2d += to_owner.normalized() * recall_speed * delta

	_render()


func _anchor() -> void:
	state = State.ANCHORED


func _pick_up() -> void:
	if is_instance_valid(owner_player) and owner_player.has_method("_on_dart_returned"):
		owner_player._on_dart_returned()
	queue_free()


func _check_hits() -> bool:
	if GameManager.current_state != GameManager.RoundState.PLAYING:
		return false
	var hit := false
	for body in get_tree().get_nodes_in_group("players"):
		if body == owner_player or body.is_dead:
			continue
		var base: Vector2 = body.get_pos_2d()
		var top: Vector2 = _capsule_top(base)
		if _seg_dist(head_2d, base, top) < hit_radius:
			if head_2d.distance_to(top) < head_hit_radius:
				body.kill()
			else:
				body.trip()
			hit = true
	return hit


func _raycast_obstacle(prev: Vector2, cur: Vector2) -> Variant:
	## Real physics raycast against the map's actual collision geometry, at
	## the dart's fixed plane_y, from prev to cur (this frame's swept motion,
	## not just the new point -- a fast dart can move a good fraction of a
	## unit per tick and tunnel through a pillar's footprint if only the
	## endpoint were tested). Excludes every player body via RID so darts
	## never stop on the character throwing or standing near them; anything
	## else solid (pillars, trees, cacti -- all still on the default physics
	## layer, same as players, per project-wide grep) counts as a hit.
	## Returns the 2D hit point, or null if the ray reaches cur unobstructed.
	var space_state: PhysicsDirectSpaceState3D = get_world_3d().direct_space_state
	var from: Vector3 = Vector3(prev.x, plane_y, prev.y)
	var to: Vector3 = Vector3(cur.x, plane_y, cur.y)
	var query := PhysicsRayQueryParameters3D.create(from, to)
	var excluded: Array[RID] = []
	for p in get_tree().get_nodes_in_group("players"):
		if p is CollisionObject3D:
			excluded.append((p as CollisionObject3D).get_rid())
	query.exclude = excluded
	var result: Dictionary = space_state.intersect_ray(query)
	if result.is_empty():
		return null
	var pos: Vector3 = result.get("position")
	return Vector2(pos.x, pos.z)


func _get_swept_hit_obstacle(prev: Vector2, cur: Vector2) -> Variant:
	## Swept segment-vs-rect test across every obstacle for the dart's
	## motion this frame (prev -> cur). Returns {"obstacle": Node, "point":
	## Vector2} for the obstacle hit closest to prev (smallest t), or null.
	var best_obs: Node = null
	var best_t: float = INF
	var best_point: Vector2 = cur
	for obs in get_tree().get_nodes_in_group("obstacles"):
		var hit: Variant = _segment_rect_intersect(prev, cur, obs.get_rect_2d())
		if hit != null:
			var hit_dict: Dictionary = hit
			var t: float = hit_dict.get("t")
			if t < best_t:
				best_t = t
				best_obs = obs
				best_point = hit_dict.get("point")
	if best_obs != null:
		return {"obstacle": best_obs, "point": best_point}
	return null


func _segment_rect_intersect(p0: Vector2, p1: Vector2, r: Rect2) -> Variant:
	## Standard slab-method segment-vs-AABB intersection. Returns
	## {"t": float, "point": Vector2} for the first point (smallest t in
	## [0, 1]) where the segment enters the rect, or null if it never does.
	## If p0 already starts inside the rect, t = 0 and point = p0.
	var d: Vector2 = p1 - p0
	var tmin: float = 0.0
	var tmax: float = 1.0
	var mn: Vector2 = r.position
	var mx: Vector2 = r.end
	for axis: int in range(2):
		var p0a: float = p0[axis]
		var da: float = d[axis]
		var mna: float = mn[axis]
		var mxa: float = mx[axis]
		if absf(da) < 0.000001:
			if p0a < mna or p0a > mxa:
				return null
		else:
			var t1: float = (mna - p0a) / da
			var t2: float = (mxa - p0a) / da
			if t1 > t2:
				var tmp: float = t1
				t1 = t2
				t2 = tmp
			tmin = maxf(tmin, t1)
			tmax = minf(tmax, t2)
			if tmin > tmax:
				return null
	return {"t": tmin, "point": p0 + d * tmin}


func _snap_to_rect_edge(p: Vector2, r: Rect2) -> Vector2:
	# Find the nearest point on the perimeter of the rectangle.
	var best: Vector2 = p
	var best_d: float = INF
	var candidates: Array[Vector2] = [
		Vector2(r.position.x, clampf(p.y, r.position.y, r.end.y)),   # left edge
		Vector2(r.end.x,      clampf(p.y, r.position.y, r.end.y)),   # right edge
		Vector2(clampf(p.x, r.position.x, r.end.x), r.position.y),  # top edge
		Vector2(clampf(p.x, r.position.x, r.end.x), r.end.y),       # bottom edge
	]
	for c in candidates:
		var d: float = p.distance_to(c)
		if d < best_d:
			best_d = d
			best = c
	return best


func _seg_dist(p: Vector2, a: Vector2, b: Vector2) -> float:
	var ab := b - a
	var len_sq := ab.length_squared()
	if len_sq < 0.0001:
		return p.distance_to(a)
	var t: float = clampf((p - a).dot(ab) / len_sq, 0.0, 1.0)
	return p.distance_to(a + t * ab)


func _capsule_top(base: Vector2) -> Vector2:
	return base + CAPSULE_DIR * capsule_height


func _render() -> void:
	if not is_instance_valid(owner_player):
		return
	# Always at the dart's own fixed plane_y -- see the class doc comment for
	# why this stays constant rather than varying by state or the owner's
	# current height.
	head_mesh.global_position = Vector3(head_2d.x, plane_y, head_2d.y)

	# Blade points away from wherever the rope currently comes from (the
	# owner) -- covers FLYING (roughly dir_2d, but stays correct even if the
	# owner moves mid-flight), ANCHORED (re-orients if the owner walks around
	# it), and RECALLING (blade trails, pommel leads back toward the owner)
	# with one rule instead of three special cases. Falls back to dir_2d
	# only in the degenerate case of head_2d and the owner coinciding.
	var owner_pos_2d: Vector2 = owner_player.get_pos_2d()
	var blade_dir_2d: Vector2 = head_2d - owner_pos_2d
	if blade_dir_2d.length() < 0.01:
		blade_dir_2d = dir_2d
	if blade_dir_2d.length() > 0.001:
		var blade_forward: Vector3 = Vector3(blade_dir_2d.x, 0.0, blade_dir_2d.y).normalized()
		var z_axis: Vector3 = -blade_forward
		var basis_seed: Vector3 = Vector3.RIGHT if absf(z_axis.dot(Vector3.UP)) > 0.99 else Vector3.UP
		var x_axis: Vector3 = basis_seed.cross(z_axis).normalized()
		var y_axis: Vector3 = z_axis.cross(x_axis).normalized()
		head_mesh.global_transform.basis = Basis(x_axis, y_axis, z_axis)

	_update_rope()


func _update_rope() -> void:
	# XZ tracks the hand bone's real current position (so the rope's near end
	# visibly follows the owner's arm), but Y is pinned to the dart's fixed
	# plane_y rather than the bone's current animated height -- the rope
	# lives in a single flat plane for its whole life, per the class doc
	# comment, not a free-hanging 3D line.
	var hand_pos: Vector3 = owner_player.get_hand_world_position() if owner_player.has_method("get_hand_world_position") \
		else Vector3(owner_player.get_pos_2d().x, plane_y, owner_player.get_pos_2d().y)
	var from: Vector3 = Vector3(hand_pos.x, plane_y, hand_pos.z)
	# Attach at the dagger's pommel (DAGGER_POMMEL_OFFSET along its own local
	# +Z), not its origin -- transforming by head_mesh's full global
	# transform (not just its position) so this follows the blade's current
	# orientation too. head_mesh.global_position.y is already plane_y (see
	# _render()), so this stays in-plane automatically.
	var to: Vector3 = head_mesh.global_transform * Vector3(0.0, 0.0, DAGGER_POMMEL_OFFSET)
	to.y = plane_y

	# Route around map geometry -- a pillar directly between the hand and the
	# dart (e.g. after the owner walks around one post-anchor) would
	# otherwise just clip straight through it. Deliberately checks only the
	# "obstacles" group via the same _get_swept_hit_obstacle()/
	# _snap_to_rect_edge() the dart's own flight already uses, never
	# "players" -- the rope always passes freely through other characters
	# regardless of where they're standing.
	var path: Array[Vector3] = [from]
	var bend_2d: Variant = _get_rope_bend_point(Vector2(from.x, from.z), Vector2(to.x, to.z))
	var bent: bool = bend_2d != null
	if bent:
		var b: Vector2 = bend_2d
		path.append(Vector3(b.x, (from.y + to.y) * 0.5, b.y))
	path.append(to)

	var total_length: float = 0.0
	for i in range(path.size() - 1):
		total_length += path[i].distance_to(path[i + 1])
	if total_length < 0.05:
		for seg in _rope_segments:
			seg.visible = false
		return

	# Sample points along a shallow hanging curve (parabolic droop, zero at
	# both ends, peak at the midpoint) instead of a single straight line --
	# see ROPE_SEGMENTS' comment for why. Skipped across a bend (a rope
	# caught on a corner reads as taut there, and a smooth parabola doesn't
	# make sense across a kinked path anyway).
	var sag: float = 0.0 if bent else minf(total_length * ROPE_SAG_FACTOR, ROPE_SAG_MAX)
	var n: int = _rope_segments.size()
	var points: Array[Vector3] = []
	points.resize(n + 1)
	for i in range(n + 1):
		var t: float = float(i) / float(n)
		var p: Vector3 = _sample_path(path, t)
		p.y -= sag * 4.0 * t * (1.0 - t)
		points[i] = p

	for i in range(n):
		_render_rope_segment(_rope_segments[i], points[i], points[i + 1])


func _get_rope_bend_point(from_2d: Vector2, to_2d: Vector2) -> Variant:
	## Returns a single Vector2 bend point that routes the direct line around
	## whichever obstacle blocks it, or null if unobstructed.
	##
	## An earlier version routed through _snap_to_rect_edge()'s point (where
	## the direct line first ENTERS the rect) -- wrong: for a line passing
	## near the rect's center, the second leg (bend -> to) can cut straight
	## back through the rest of the box on its way out, since the entry
	## point is just the edge crossing, not a point that clears the whole
	## shape. A rect's CORNER is the only kind of point where routing through
	## it is geometrically guaranteed to clear a convex shape on both sides.
	## Tries all 4 corners (pushed outward for clearance -- see
	## ROPE_BEND_CLEARANCE), keeps only the ones where BOTH from->corner and
	## corner->to independently miss the same rect, and picks whichever adds
	## the least extra distance over the direct line.
	##
	## Checks ONLY the "obstacles" group (via _get_swept_hit_obstacle(), the
	## same one the dart's own flight already uses), never "players" -- the
	## rope always passes freely through other characters regardless of
	## where they're standing.
	var hit: Variant = _get_swept_hit_obstacle(from_2d, to_2d)
	if hit == null:
		return null
	var hit_dict: Dictionary = hit
	var hit_obs: Node = hit_dict.get("obstacle")
	var rect: Rect2 = hit_obs.get_rect_2d()
	var center: Vector2 = rect.get_center()
	var corners: Array[Vector2] = [
		rect.position, Vector2(rect.end.x, rect.position.y), rect.end, Vector2(rect.position.x, rect.end.y)
	]

	var direct_length: float = from_2d.distance_to(to_2d)
	var best_point: Vector2 = Vector2.ZERO
	var best_extra: float = INF
	for corner in corners:
		var outward: Vector2 = corner - center
		var pushed: Vector2 = corner + (outward.normalized() * ROPE_BEND_CLEARANCE if outward.length() > 0.001 else Vector2.ZERO)
		if _segment_rect_intersect(from_2d, pushed, rect) != null:
			continue
		if _segment_rect_intersect(pushed, to_2d, rect) != null:
			continue
		var extra: float = from_2d.distance_to(pushed) + pushed.distance_to(to_2d) - direct_length
		if extra < best_extra:
			best_extra = extra
			best_point = pushed

	if best_extra < INF:
		return best_point
	# Fallback for the (shouldn't normally happen, single convex rect) case
	# where no single corner clears both legs -- the old edge-snap point,
	# still pushed outward for clearance.
	var hit_point: Vector2 = hit_dict.get("point")
	var edge_point: Vector2 = _snap_to_rect_edge(hit_point, rect)
	var edge_outward: Vector2 = edge_point - center
	if edge_outward.length() > 0.001:
		edge_point += edge_outward.normalized() * ROPE_BEND_CLEARANCE
	return edge_point


func _sample_path(path: Array[Vector3], t: float) -> Vector3:
	## Sample a point at fraction t (0..1) along a piecewise-linear path,
	## proportionally to each leg's actual length (not evenly split by
	## point count), so a short bend leg doesn't get over-represented.
	if path.size() == 2:
		return path[0].lerp(path[1], t)
	var lengths: Array[float] = []
	var total: float = 0.0
	for i in range(path.size() - 1):
		var seg_len: float = path[i].distance_to(path[i + 1])
		lengths.append(seg_len)
		total += seg_len
	if total < 0.001:
		return path[0]
	var target: float = t * total
	var accum: float = 0.0
	for i in range(lengths.size()):
		if target <= accum + lengths[i] or i == lengths.size() - 1:
			var local_t: float = 0.0 if lengths[i] < 0.001 else clampf((target - accum) / lengths[i], 0.0, 1.0)
			return path[i].lerp(path[i + 1], local_t)
		accum += lengths[i]
	return path[path.size() - 1]


func _render_rope_segment(seg: MeshInstance3D, from_pt: Vector3, to_pt: Vector3) -> void:
	var diff: Vector3 = to_pt - from_pt
	var length: float = diff.length()
	if length < 0.001:
		seg.visible = false
		return
	seg.visible = true
	var y_axis: Vector3 = diff / length
	# Any vector not parallel to y_axis works as a basis seed for building an
	# orthonormal frame around it; UP fails only when a segment points
	# (near-)vertically, which never happens here since both endpoints share
	# roughly the same height band, but guard it anyway.
	var basis_seed: Vector3 = Vector3.RIGHT if absf(y_axis.dot(Vector3.UP)) > 0.99 else Vector3.UP
	var x_axis: Vector3 = basis_seed.cross(y_axis).normalized()
	var z_axis: Vector3 = x_axis.cross(y_axis).normalized()
	# CylinderMesh's unit height runs along local Y -- encode the stretch
	# directly into that basis column rather than touching .scale separately,
	# so this single assignment can't fight with any other transform write.
	seg.global_transform = Transform3D(Basis(x_axis, y_axis * length, z_axis), (from_pt + to_pt) * 0.5)
