extends StaticBody3D
## Registers this node in the "obstacles" group -- basic map/arena collision
## geometry (pillars, scattered trees/cacti via nature_scatter.gd). Exposes
## get_rect_2d()/get_outline_2d(), a simple 2D footprint read with no
## physics-engine query needed, for any gameplay system that wants a cheap
## 2D collision test against these obstacles.
##
## WEAPON/COMBAT SYSTEM REMOVED (branch remove-weapon-system): this used to
## also carry a dedicated "rope_obstacles" collision layer bit for the now-
## deleted rope dart's physics chain (RigidBody3D segments reacting to real
## obstacle geometry). That bit has been removed -- this node's
## collision_layer is left exactly as authored (normally the default layer
## 1) with no extra bit added.

@export var half_size: Vector2 = Vector2(0.75, 0.75)

## Optional true footprint, as a polygon of LOCAL (X, Z) offsets from this
## obstacle's center, for a shape that isn't just an axis-aligned box — e.g. a
## tree trunk with root-flare notches. Currently unused by any gameplay
## system (nothing tests against anything finer than the coarse bounding box,
## see get_rect_2d()) but kept available, and still populated by
## nature_scatter.gd per scattered object, for any future feature that wants
## a more precise per-object footprint than a plain box.
@export var outline_points: PackedVector2Array = []

var _outline_hull: PackedVector2Array = []


func _ready() -> void:
	add_to_group("obstacles")
	_compute_outline_hull()


func get_rect_2d() -> Rect2:
	var center := Vector2(global_position.x, global_position.z)
	return Rect2(center - half_size, half_size * 2.0)


func get_outline_2d() -> PackedVector2Array:
	return _outline_hull


func _compute_outline_hull() -> void:
	if outline_points.is_empty():
		# No custom outline configured — fall back to the box's own 4
		# corners, which keeps every existing rect-only obstacle (PillarA,
		# PillarB, the tree-scatter boxes) behaving exactly as before.
		var r: Rect2 = get_rect_2d()
		_outline_hull = PackedVector2Array([
			r.position, Vector2(r.end.x, r.position.y), r.end, Vector2(r.position.x, r.end.y)
		])
		return
	var center := Vector2(global_position.x, global_position.z)
	var world_points := PackedVector2Array()
	for p in outline_points:
		world_points.append(center + p)
	_outline_hull = Geometry2D.convex_hull(world_points)
