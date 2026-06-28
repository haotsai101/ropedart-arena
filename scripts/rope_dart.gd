extends Node3D
## Rope dart: EXTENDING → ANCHORED → RECALLING state machine.
## All positions are 2D (XZ plane); 3D mesh is rebuilt each frame for lighting.
## Kill detection uses 2D math — no physics collision shapes needed.

enum State { EXTENDING, ANCHORED, RECALLING }

@export var travel_speed: float = 18.0
@export var recall_speed: float = 24.0
@export var max_range: float = 7.0
@export var visual_height: float = 0.5
@export var hit_radius: float = 0.45
@export var arena_half: float = 14.5

## Baseline values used to compute charged-throw speed and range.
const BASE_SPEED: float = 18.0
const BASE_MAX_RANGE: float = 7.0

var state: int = State.EXTENDING
var owner_player: Node3D = null
var head_2d: Vector2 = Vector2.ZERO
var origin_2d: Vector2 = Vector2.ZERO
var dir_2d: Vector2 = Vector2.ZERO
var charge_ratio: float = 0.0

@onready var head_mesh: Node3D = $Head
@onready var rope_mesh: MeshInstance3D = $Rope


func launch(player: Node3D, from_2d: Vector2, aim: Vector2, ratio: float = 0.0) -> void:
	owner_player = player
	origin_2d = from_2d
	head_2d = from_2d
	dir_2d = aim.normalized()
	charge_ratio = ratio
	# Scale speed and range linearly: min charge = baseline, max charge = 2×
	travel_speed = BASE_SPEED * lerp(1.0, 2.0, ratio)
	max_range = BASE_MAX_RANGE * lerp(1.0, 2.0, ratio)
	# Larger head mesh at higher charge gives instant visual feedback on launch
	head_mesh.scale = Vector3.ONE * lerp(1.0, 1.5, ratio)
	state = State.EXTENDING
	add_to_group("darts")


func recall() -> void:
	if state != State.RECALLING:
		state = State.RECALLING


func _physics_process(delta: float) -> void:
	if not is_instance_valid(owner_player):
		queue_free()
		return

	var player_2d: Vector2 = owner_player.get_pos_2d()

	match state:
		State.EXTENDING:
			head_2d += dir_2d * travel_speed * delta
			if _check_head_hits():
				state = State.RECALLING
				_render()
				return
			# Anchor at arena boundary walls
			if absf(head_2d.x) >= arena_half or absf(head_2d.y) >= arena_half:
				head_2d.x = clampf(head_2d.x, -arena_half, arena_half)
				head_2d.y = clampf(head_2d.y, -arena_half, arena_half)
				state = State.ANCHORED
			elif head_2d.distance_to(origin_2d) >= max_range:
				state = State.ANCHORED
			else:
				var hit_obs = _get_hit_obstacle()
				if hit_obs != null:
					head_2d = _snap_to_rect_edge(head_2d, hit_obs.get_rect_2d())
					state = State.ANCHORED

		State.ANCHORED:
			if GameManager.current_state != GameManager.RoundState.PLAYING:
				pass
			else:
				for body in get_tree().get_nodes_in_group("players"):
					if body == owner_player or body.is_dead:
						continue
					if _seg_dist(body.get_pos_2d(), player_2d, head_2d) < hit_radius:
						if body.has_method("trip"):
							body.trip()

		State.RECALLING:
			var to_player := player_2d - head_2d
			var step := recall_speed * delta
			if to_player.length() <= step:
				_return_to_player()
				return
			head_2d += to_player.normalized() * step
			_check_head_hits()  # returns bool but we don't stop early during recall

	_render()


func _check_head_hits() -> bool:
	if GameManager.current_state != GameManager.RoundState.PLAYING:
		return false
	var hit := false
	for body in get_tree().get_nodes_in_group("players"):
		if body == owner_player or body.is_dead:
			continue
		if body.get_pos_2d().distance_to(head_2d) < hit_radius:
			body.kill()
			hit = true
	return hit


func _get_hit_obstacle():  # returns first obstacle node whose rect contains head_2d, or null
	for obs in get_tree().get_nodes_in_group("obstacles"):
		if obs.get_rect_2d().has_point(head_2d):
			return obs
	return null


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


func _render() -> void:
	if not is_instance_valid(owner_player):
		return
	# Endpoint B: pin to the head node's actual world position so they are
	# guaranteed in sync regardless of call order.
	head_mesh.global_position = Vector3(head_2d.x, visual_height, head_2d.y)
	var b: Vector3 = head_mesh.global_position
	# Endpoint A: use the player's real 3D position (not a 2D projection with a
	# hardcoded Y).  The +0.5 places the rope origin at the player's hand/body
	# centre rather than at floor level.
	var a: Vector3 = owner_player.global_position + Vector3(0.0, 0.5, 0.0)
	_draw_rope_tube(a, b)


func _draw_rope_tube(a: Vector3, b: Vector3) -> void:
	var mid := (a + b) * 0.5
	var diff := b - a
	var length := diff.length()
	var mesh_res := rope_mesh.mesh as CylinderMesh
	if mesh_res:
		mesh_res.height = maxf(length, 0.001)
	if length > 0.001:
		var dir := diff / length
		# CylinderMesh is oriented along local Y.  Build an orthonormal basis
		# with local Y = dir so the cylinder spans exactly from A to B.
		# Choose a stable side vector: UP works unless dir is nearly vertical,
		# in which case RIGHT is used to avoid a near-zero cross product.
		var side: Vector3 = Vector3.UP if absf(dir.dot(Vector3.UP)) < 0.99 else Vector3.RIGHT
		var x_axis := dir.cross(side).normalized()
		var z_axis := x_axis.cross(dir)   # already unit length; no normalize needed
		rope_mesh.global_transform = Transform3D(Basis(x_axis, dir, z_axis), mid)
	else:
		rope_mesh.global_position = mid


func _return_to_player() -> void:
	if is_instance_valid(owner_player) and owner_player.has_method("_on_dart_returned"):
		owner_player._on_dart_returned()
	queue_free()
