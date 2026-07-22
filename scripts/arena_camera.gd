extends Camera3D
## Dynamic orthographic camera. Pans and zooms to keep all alive players in frame.

@export var base_size: float = 14.0
@export var max_size: float = 26.0
@export var lerp_speed: float = 3.5
@export var margin: float = 4.5
@export var arena_clamp: float = 13.0

# Isometric offset from the ground look-at center.
# Computed from the initial camera transform in _ready().
var _offset: Vector3 = Vector3(0, 14, 12)


func _ready() -> void:
	projection = PROJECTION_ORTHOGONAL
	size = base_size
	# Derive the ground look-at point and compute offset
	var fwd := -global_transform.basis.z
	if abs(fwd.y) > 0.001:
		var t := -global_position.y / fwd.y
		var ground_hit := global_position + fwd * t
		_offset = global_position - ground_hit
	else:
		_offset = Vector3(0, 14, 12)


func _process(delta: float) -> void:
	var players := get_tree().get_nodes_in_group("players")
	var active: Array = players.filter(func(p): return p.lives > 0 and not p.is_dead)
	if active.is_empty():
		return

	var min_x := INF; var max_x := -INF
	var min_z := INF; var max_z := -INF
	for p in active:
		var pos: Vector2 = p.get_pos_2d()
		min_x = minf(min_x, pos.x); max_x = maxf(max_x, pos.x)
		min_z = minf(min_z, pos.y); max_z = maxf(max_z, pos.y)

	# Thrown rope darts can fly well past their owner (up to ROPE_LENGTH) and
	# then sit there anchored until picked up -- without this, one lying out
	# near the edge of a wide shot can end up outside the frame entirely.
	for d in get_tree().get_nodes_in_group("darts"):
		var dpos: Vector2 = d.head_2d
		min_x = minf(min_x, dpos.x); max_x = maxf(max_x, dpos.x)
		min_z = minf(min_z, dpos.y); max_z = maxf(max_z, dpos.y)

	min_x = maxf(min_x - margin, -arena_clamp)
	max_x = minf(max_x + margin,  arena_clamp)
	min_z = maxf(min_z - margin, -arena_clamp)
	max_z = minf(max_z + margin,  arena_clamp)

	var cx: float = (min_x + max_x) * 0.5
	var cz: float = (min_z + max_z) * 0.5
	var span: float = maxf(max_x - min_x, max_z - min_z)

	var target_size: float = clamp(remap(span, 6.0, 24.0, base_size, max_size), base_size, max_size)
	size = lerpf(size, target_size, lerp_speed * delta)

	var target_pos: Vector3 = Vector3(cx, 0.0, cz) + _offset
	global_position = global_position.lerp(target_pos, lerp_speed * delta)
