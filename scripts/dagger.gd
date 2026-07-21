extends Node3D
## Thrown dagger: FLYING → LANDED. All positions are 2D (XZ plane); 3D mesh
## rebuilt each frame for lighting. Kill detection uses 2D math — no physics
## collision shapes needed for that; obstacles use a simple 2D swept-rect
## test against their footprint (see _get_swept_hit_obstacle), same as the
## old rope dart's EXTENDING state used.
##
## Once thrown, a dagger flies in a straight line until it hits a player, an
## obstacle, the arena boundary, or its own max range, then lands and sits
## there until its owner walks back over it. There's no rope and no
## retrieval-by-recall — getting your dagger back means walking to wherever
## it landed, which is the whole point: committing to a throw is a real risk.

enum State { FLYING, LANDED }

@export var travel_speed: float = 18.0
@export var max_range: float = 7.0
## Extra offset added to owner_player.global_position.y (the player's FEET —
## KayKit character meshes are authored feet-at-local-origin and added to
## the CharacterBody3D with no position offset) to get the dagger's render
## height. 1.1 lands it roughly at hand/chest height while flying.
@export var visual_height: float = 1.1
@export var hit_radius: float = 0.6  # matches the character's outstretched arm/leg reach (~0.79 at max swing), not just body radius (~0.48)
@export var arena_half: float = 14.5
## How close the owner needs to walk to a landed dagger to pick it back up.
@export var pickup_radius: float = 0.9

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

var state: int = State.FLYING
var owner_player: Node3D = null
var head_2d: Vector2 = Vector2.ZERO
var origin_2d: Vector2 = Vector2.ZERO
var dir_2d: Vector2 = Vector2.ZERO
var charge_ratio: float = 0.0

@onready var head_mesh: Node3D = $Head


func launch(player: Node3D, from_2d: Vector2, aim: Vector2, ratio: float = 0.0) -> void:
	owner_player = player
	origin_2d = from_2d
	head_2d = from_2d
	dir_2d = aim.normalized()
	charge_ratio = ratio
	# Scale speed and range linearly: min charge = baseline, max charge = 2×
	travel_speed = BASE_SPEED * lerp(1.0, 2.0, ratio)
	max_range = BASE_MAX_RANGE * lerp(1.0, 2.0, ratio)
	# Larger dagger mesh at higher charge gives instant visual feedback on launch
	head_mesh.scale = Vector3.ONE * lerp(1.0, 1.5, ratio)

	# Tint dagger to player's color
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

	state = State.FLYING
	add_to_group("darts")


func _physics_process(delta: float) -> void:
	if not is_instance_valid(owner_player):
		queue_free()
		return

	match state:
		State.FLYING:
			var prev_head_2d: Vector2 = head_2d
			head_2d += dir_2d * travel_speed * delta
			if _check_hits():
				_land()
				_render()
				return
			# Land at the arena boundary walls
			if absf(head_2d.x) >= arena_half or absf(head_2d.y) >= arena_half:
				head_2d.x = clampf(head_2d.x, -arena_half, arena_half)
				head_2d.y = clampf(head_2d.y, -arena_half, arena_half)
				_land()
			else:
				# Swept segment-vs-rect test (prev_head_2d -> head_2d) instead of
				# point-sampling the new position — a fast dagger can move ~0.5+
				# units per tick, which is thin enough to tunnel through a pillar
				# footprint if only the endpoint is tested.
				var obs_hit: Variant = _get_swept_hit_obstacle(prev_head_2d, head_2d)
				if obs_hit != null:
					var hit_dict: Dictionary = obs_hit
					var hit_obs: Node = hit_dict.get("obstacle")
					var hit_point: Vector2 = hit_dict.get("point")
					head_2d = _snap_to_rect_edge(hit_point, hit_obs.get_rect_2d())
					_land()
				elif head_2d.distance_to(origin_2d) >= max_range:
					_land()

		State.LANDED:
			if owner_player.get_pos_2d().distance_to(head_2d) < pickup_radius:
				_pick_up()
				return

	_render()


func _land() -> void:
	state = State.LANDED


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
		if _seg_dist(head_2d, base, _capsule_top(base)) < hit_radius:
			body.kill()
			hit = true
	return hit


func _get_swept_hit_obstacle(prev: Vector2, cur: Vector2) -> Variant:
	## Swept segment-vs-rect test across every obstacle for the dagger's
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
	# Sits a little lower once landed, to read as planted/stuck rather than
	# floating at the same height it flew at.
	var height: float = visual_height if state == State.FLYING else visual_height * 0.25
	var mid_y: float = owner_player.global_position.y + height
	head_mesh.global_position = Vector3(head_2d.x, mid_y, head_2d.y)
