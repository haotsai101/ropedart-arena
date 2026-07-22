extends Node3D
## Thrown rope dart: FLYING → ANCHORED → (optionally) RECALLING. All positions
## are 2D (XZ plane); 3D mesh rebuilt each frame for lighting. Kill/hit
## detection uses 2D math — no physics collision shapes needed for that;
## obstacles use a simple 2D swept-rect test against their footprint (see
## _get_swept_hit_obstacle) — this obstacle/boundary-stop logic is carried
## over unchanged from the previous straight-thrown-dagger weapon, which is
## current codebase, not the old (discarded) rope dart design.
##
## Unlike that dagger, this weapon stays tethered: a multi-segment sagging
## rope (see ROPE_SEGMENTS) is drawn from the owner's hand to the head every
## frame in every state, and the owner can actively recall it (see recall())
## from anywhere -- flying or anchored -- instead of only retrieving it by
## walking over it (still also supported; walking within pickup_radius
## always retrieves it too).
##
## Hit resolution distinguishes head vs. body: a head hit (tight radius right
## at the top of the target's capsule) is an instant kill, same as the old
## dagger's economy. A body hit is a non-lethal "clothesline" -- trip()'s
## existing freeze-then-slow stagger. Either kind of hit anchors the dart at
## the point of contact, same as hitting an obstacle or the arena boundary.

enum State { FLYING, ANCHORED, RECALLING }

@export var travel_speed: float = 18.0
@export var max_range: float = 7.0
## Extra offset added to owner_player.global_position.y (the player's FEET —
## KayKit character meshes are authored feet-at-local-origin and added to
## the CharacterBody3D with no position offset) to get the dart's render
## height. 1.1 lands it roughly at hand/chest height while flying.
@export var visual_height: float = 1.1
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
## Height above the owner's feet the rope's near end is drawn from --
## approximates hand height without needing to reach into the owner's actual
## hand-bone attachment (see player.gd's _setup_dagger_in_hand()).
@export var rope_hand_height: float = 1.0

## Baseline values used to compute charged-throw speed and range.
const BASE_SPEED: float = 18.0
const BASE_MAX_RANGE: float = 7.0

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

var state: int = State.FLYING
var owner_player: Node3D = null
var head_2d: Vector2 = Vector2.ZERO
var origin_2d: Vector2 = Vector2.ZERO
var dir_2d: Vector2 = Vector2.ZERO
var charge_ratio: float = 0.0
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
	# Scale speed and range linearly: min charge = baseline, max charge = 2×
	travel_speed = BASE_SPEED * lerp(1.0, 2.0, ratio)
	max_range = BASE_MAX_RANGE * lerp(1.0, 2.0, ratio)
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
				# Swept segment-vs-rect test (prev_head_2d -> head_2d) instead of
				# point-sampling the new position — a fast dart can move ~0.5+
				# units per tick, which is thin enough to tunnel through a pillar
				# footprint if only the endpoint is tested.
				var obs_hit: Variant = _get_swept_hit_obstacle(prev_head_2d, head_2d)
				if obs_hit != null:
					var hit_dict: Dictionary = obs_hit
					var hit_obs: Node = hit_dict.get("obstacle")
					var hit_point: Vector2 = hit_dict.get("point")
					head_2d = _snap_to_rect_edge(hit_point, hit_obs.get_rect_2d())
					_anchor()
				elif head_2d.distance_to(origin_2d) >= max_range:
					_anchor()

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
	# Sits a little lower once anchored, to read as planted/stuck rather than
	# floating at the same height it flew at.
	var height: float = visual_height if state == State.FLYING else visual_height * 0.25
	var mid_y: float = owner_player.global_position.y + height
	head_mesh.global_position = Vector3(head_2d.x, mid_y, head_2d.y)
	_update_rope()


func _update_rope() -> void:
	var owner_pos_2d: Vector2 = owner_player.get_pos_2d()
	var from: Vector3 = Vector3(owner_pos_2d.x, owner_player.global_position.y + rope_hand_height, owner_pos_2d.y)
	var to: Vector3 = head_mesh.global_position
	var total_length: float = from.distance_to(to)
	if total_length < 0.05:
		for seg in _rope_segments:
			seg.visible = false
		return

	# Sample points along a shallow hanging curve (parabolic droop, zero at
	# both ends, peak at the midpoint) instead of a single straight line --
	# see ROPE_SEGMENTS' comment for why.
	var sag: float = minf(total_length * ROPE_SAG_FACTOR, ROPE_SAG_MAX)
	var n: int = _rope_segments.size()
	var points: Array[Vector3] = []
	points.resize(n + 1)
	for i in range(n + 1):
		var t: float = float(i) / float(n)
		var p: Vector3 = from.lerp(to, t)
		p.y -= sag * 4.0 * t * (1.0 - t)
		points[i] = p

	for i in range(n):
		_render_rope_segment(_rope_segments[i], points[i], points[i + 1])


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
