extends StaticBody3D
## Registers this node in the "obstacles" group so dagger.gd can stop a
## thrown dagger against its footprint (see get_rect_2d(), a simple 2D
## swept-rect test — no physics-engine query needed for that).

## EXPERIMENT (2026-07-25, feature/melee-slash-v2): the dedicated
## ROPE_OBSTACLE_LAYER_BIT ("rope_obstacles", layer 2 in project.godot's
## [layer_names]) this node used to add on top of its own default layer 1 --
## the one-directional bit player.gd's real physics rope chain used as its
## collision_mask so the rope could react to real map geometry without ever
## being detectable by/colliding with players, the ground, or the dart head
## -- is REMOVED, per direct, explicit user instruction: "Let's try dropping
## the special collision logic all together... Use the default collision
## engine." This obstacle now sits on nothing but its own original default
## layer (1, untouched, never explicitly set here) -- the same one players'
## capsules and the ground already use -- and player.gd's rope segments
## react to it (and everything else on layer 1) via their own newly-default
## collision_mask, not a bespoke shared bit. See player.gd's
## _make_rope_segment_body()/_spawn_physics_rope() for the corresponding
## removal and the new collision-exception-with-owner call it required.
## project.godot's own layer_2="rope_obstacles" name entry is now unused dead
## config -- left in place rather than edited, since removing a
## [layer_names] entry has no functional effect and this experiment may be
## reverted (see this file's own CLAUDE.md dated entry for the merge
## decision).

@export var half_size: Vector2 = Vector2(0.75, 0.75)

## Optional true footprint, as a polygon of LOCAL (X, Z) offsets from this
## obstacle's center, for a shape that isn't just an axis-aligned box — e.g. a
## tree trunk with root-flare notches. Currently unused by any gameplay
## system (the dagger only ever tests against the coarse bounding box, see
## get_rect_2d()) but kept available, and still populated by
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
