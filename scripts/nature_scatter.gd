extends Node3D
## Deterministically scatters ground-cover / tree meshes across the arena floor.
## Runs once in _ready() with a fixed RNG seed so the layout is stable across
## runs (important for visual verification via screenshots).
##
## Two modes:
##  - MultiMesh mode (default, use_individual_instances = false): cheap, single
##    draw call per mesh type. Purely decorative — no collision, no gameplay
##    effect. Use for small repeated meshes (grass/clover/fern).
##  - Individual instance mode (use_individual_instances = true): spawns real
##    scene instances as children. Use for trees, where each placement should
##    read as a distinct object with its own bark/leaf materials. When
##    mesh_obstacle_footprint has a non-zero entry for a given mesh, each
##    instance also gets a real StaticBody3D obstacle (arena_obstacle.gd, same
##    pattern as the PillarA/PillarB blocks), sized to that instance's actual
##    rotated+scaled AABB footprint (see _add_obstacle_collision) so it
##    visually matches the mesh's real silhouette — not shrunk down to
##    whatever survives any random rotation, which makes the rope's
##    wrap-around detour too small to actually see.

@export var mesh_scenes: Array[PackedScene] = []
@export var instances_per_mesh: int = 120
@export var min_scale: float = 0.85
@export var max_scale: float = 1.25
@export var square_limit: float = 13.5 ## samples are drawn from [-square_limit, square_limit] on both axes
@export var clear_radius: float = 5.5 ## disk around the origin left free of this layer
@export var obstacle_rects: Array[Rect2] = [] ## extra rects (e.g. pillar footprints) to avoid
@export var avoid_points: Array[Vector2] = [] ## extra points to avoid (e.g. spawn markers)
@export var avoid_radius: float = 1.2
@export var use_individual_instances: bool = false
@export var rng_seed: int = 1337

## Some megakit models (notably DeadTree/TwistedTree) are authored at wildly
## different native scales with off-center pivots. These optional parallel
## arrays (indexed the same as mesh_scenes) correct for that so every layer
## reads as a consistent size, and so the visual canopy stays centered on the
## sampled point regardless of random rotation.
@export var mesh_base_scale: Array[float] = [] ## per-mesh baseline multiplier (default 1.0)
@export var mesh_local_center: Array[Vector2] = [] ## per-mesh local XZ centroid to recenter around (default 0,0)
@export var mesh_instance_counts: Array[int] = [] ## per-mesh instance count override (default instances_per_mesh)

## Per-mesh NATIVE (scale-1.0) footprint half-extent in local (X, Z) — i.e.
## half the mesh's actual measured AABB width/depth on the ground plane, not
## a defensively-shrunk "safe at any rotation" square. Vector2.ZERO (the
## default when an index is missing) means "no obstacle" — purely
## decorative, same as before. Only meaningful when use_individual_instances
## = true. Each instance's random yaw + scale is applied to THIS footprint
## via a proper rotated-AABB computation (see _add_obstacle_collision) to
## get a tight, correctly-sized axis-aligned rect for that specific
## instance — not a single one-size-fits-all box. An earlier version of this
## used a fixed worst-case-rotation square, which came out small enough
## (~0.2 half-size vs. a ~1 unit visual canopy) that the rope's wrap-around
## detour around it was visually imperceptible — technically correct, but
## looked exactly like "the rope goes through the tree."
@export var mesh_obstacle_footprint: Array[Vector2] = []

## Optional per-mesh NATIVE (scale-1.0, unrotated) footprint OUTLINE — a
## polygon of local (X, Z) points tracing the mesh's actual base silhouette
## (e.g. a trunk with root-flare notches), instead of just a bounding box.
## When present for a given mesh index, it's used INSTEAD of
## mesh_obstacle_footprint: rotated+scaled per instance the same way, then
## handed to the spawned obstacle as arena_obstacle.gd's outline_points (not
## currently read by any gameplay system, but kept for a future feature that
## wants a more precise per-object footprint). Collision uses a convex hull
## of the same points (via ConvexPolygonShape3D) — deliberately not a true
## concave collider, since a tree base's small root-flare dents don't need
## to be physically enterable.
@export var mesh_obstacle_outline: Array[PackedVector2Array] = []

const ArenaObstacleScript: Script = preload("res://scripts/arena_obstacle.gd")


func _ready() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = rng_seed
	for idx: int in mesh_scenes.size():
		var scene: PackedScene = mesh_scenes[idx]
		var base_scale: float = mesh_base_scale[idx] if idx < mesh_base_scale.size() else 1.0
		var center: Vector2 = mesh_local_center[idx] if idx < mesh_local_center.size() else Vector2.ZERO
		var count: int = mesh_instance_counts[idx] if idx < mesh_instance_counts.size() else instances_per_mesh
		var obstacle_footprint: Vector2 = mesh_obstacle_footprint[idx] if idx < mesh_obstacle_footprint.size() else Vector2.ZERO
		var obstacle_outline: PackedVector2Array = mesh_obstacle_outline[idx] if idx < mesh_obstacle_outline.size() else PackedVector2Array()
		if use_individual_instances:
			_scatter_instances(scene, rng, base_scale, center, count, obstacle_footprint, obstacle_outline)
		else:
			_scatter_multimesh(scene, rng, base_scale, center, count)


func _pick_transforms(rng: RandomNumberGenerator, base_scale: float, center: Vector2, count: int) -> Array[Transform3D]:
	var placed: Array[Transform3D] = []
	var attempts := 0
	var max_attempts: int = count * 12
	var center3: Vector3 = Vector3(center.x, 0.0, center.y)
	while placed.size() < count and attempts < max_attempts:
		attempts += 1
		var x: float = rng.randf_range(-square_limit, square_limit)
		var z: float = rng.randf_range(-square_limit, square_limit)
		var p: Vector2 = Vector2(x, z)
		if p.length() < clear_radius:
			continue
		var blocked := false
		for r: Rect2 in obstacle_rects:
			if r.has_point(p):
				blocked = true
				break
		if not blocked:
			for a: Vector2 in avoid_points:
				if p.distance_to(a) < avoid_radius:
					blocked = true
					break
		if blocked:
			continue
		var s: float = base_scale * rng.randf_range(min_scale, max_scale)
		var rot: float = rng.randf_range(0.0, TAU)
		var inst_basis: Basis = Basis(Vector3.UP, rot).scaled(Vector3(s, s, s))
		# Offset the origin so the mesh's local centroid (after scale + rotation)
		# lands on the sampled point, instead of the mesh's raw local origin.
		var origin: Vector3 = Vector3(x, 0.02, z) - inst_basis * center3
		placed.append(Transform3D(inst_basis, origin))
	return placed


func _scatter_multimesh(scene: PackedScene, rng: RandomNumberGenerator, base_scale: float, center: Vector2, count: int) -> void:
	var sample: Node = scene.instantiate()
	var mesh: Mesh = _find_mesh(sample)
	sample.queue_free()
	if mesh == null:
		return
	var placed: Array[Transform3D] = _pick_transforms(rng, base_scale, center, count)
	if placed.is_empty():
		return
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = mesh
	mm.instance_count = placed.size()
	for i: int in placed.size():
		mm.set_instance_transform(i, placed[i])
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = mm
	add_child(mmi)


func _scatter_instances(scene: PackedScene, rng: RandomNumberGenerator, base_scale: float, center: Vector2, count: int, obstacle_footprint: Vector2, obstacle_outline: PackedVector2Array) -> void:
	var placed: Array[Transform3D] = _pick_transforms(rng, base_scale, center, count)
	for t: Transform3D in placed:
		var inst: Node = scene.instantiate()
		add_child(inst)
		if inst is Node3D:
			(inst as Node3D).transform = t
		if not obstacle_outline.is_empty():
			_add_outline_obstacle_collision(t, obstacle_outline)
		elif obstacle_footprint != Vector2.ZERO:
			_add_obstacle_collision(t, obstacle_footprint)


func _add_obstacle_collision(t: Transform3D, native_footprint: Vector2) -> void:
	## Spawns a StaticBody3D + arena_obstacle.gd + BoxShape3D at the same XZ
	## position as the paired visual instance, mirroring the PillarA/PillarB
	## pattern exactly (registers in "obstacles" group via arena_obstacle.gd's
	## own _ready(), exposes get_rect_2d() for dagger.gd's swept-rect stop test).
	##
	## The collision body's basis is identity (never rotated) since
	## arena_obstacle.gd's rect is always axis-aligned — but rather than
	## shrinking the footprint down to whatever survives ANY rotation (which
	## made a prior version of this nearly invisible for an asymmetric mesh
	## like the cactus), compute the TIGHT axis-aligned bounding box for
	## THIS instance's actual yaw + scale via the standard rotated-rect AABB
	## formula. This is exact (not approximate) for a rectangular footprint:
	## a box with local half-extents (hw, hd) rotated by angle r has world
	## axis-aligned half-extents (hw*|cos r| + hd*|sin r|, hw*|sin r| + hd*|cos r|).
	var uniform_scale: float = t.basis.get_scale().x
	var rot: float = t.basis.get_euler().y
	var hw: float = native_footprint.x * uniform_scale
	var hd: float = native_footprint.y * uniform_scale
	var world_half_size := Vector2(
		hw * absf(cos(rot)) + hd * absf(sin(rot)),
		hw * absf(sin(rot)) + hd * absf(cos(rot))
	)

	var body := StaticBody3D.new()
	body.name = "TreeObstacle"
	body.transform = Transform3D(Basis.IDENTITY, t.origin + Vector3(0, 1.0, 0))
	body.set_script(ArenaObstacleScript)
	body.half_size = world_half_size
	# force_readable_name=true: add_child() defaults to an opaque internal
	# name ("@StaticBody3D@19") on a sibling-name collision instead of the
	# usual human-readable "TreeObstacle2" — every instance after the first
	# would otherwise be unidentifiable in the remote scene tree/debugger.
	add_child(body, true)

	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(body.half_size.x * 2.0, 2.0, body.half_size.y * 2.0)
	shape.shape = box
	body.add_child(shape)


func _add_outline_obstacle_collision(t: Transform3D, native_outline: PackedVector2Array) -> void:
	## Same StaticBody3D + arena_obstacle.gd pattern as _add_obstacle_collision,
	## but for a mesh with a real (possibly concave) footprint outline instead
	## of a simple box. The outline is rotated + scaled by this instance's
	## actual transform (same yaw/scale math, just applied per-point instead
	## of to a bounding box) and handed to the obstacle as outline_points (not
	## currently read by any gameplay system — see arena_obstacle.gd).
	##
	## Collision itself uses a ConvexPolygonShape3D built from the SAME
	## points (a prism: one ring at y=0, one at y=2) — deliberately the hull,
	## not a true concave collider. A tree's root-flare dents don't need to
	## be physically walkable; a full concave collision mesh would be real
	## extra complexity for no gameplay benefit.
	var uniform_scale: float = t.basis.get_scale().x
	var rot: float = t.basis.get_euler().y
	var cos_r: float = cos(rot)
	var sin_r: float = sin(rot)
	var local_outline := PackedVector2Array()
	for p in native_outline:
		var sx: float = p.x * uniform_scale
		var sy: float = p.y * uniform_scale
		local_outline.append(Vector2(sx * cos_r - sy * sin_r, sx * sin_r + sy * cos_r))

	var body := StaticBody3D.new()
	body.name = "TreeObstacle"
	body.transform = Transform3D(Basis.IDENTITY, t.origin + Vector3(0, 1.0, 0))
	body.set_script(ArenaObstacleScript)
	body.outline_points = local_outline
	add_child(body, true)

	var hull_points := PackedVector3Array()
	for p in local_outline:
		hull_points.append(Vector3(p.x, 0.0, p.y))
		hull_points.append(Vector3(p.x, 2.0, p.y))
	var shape := CollisionShape3D.new()
	var poly := ConvexPolygonShape3D.new()
	poly.points = hull_points
	shape.shape = poly
	body.add_child(shape)


func _find_mesh(node: Node) -> Mesh:
	if node is MeshInstance3D:
		return (node as MeshInstance3D).mesh
	for child in node.get_children():
		var found: Mesh = _find_mesh(child)
		if found != null:
			return found
	return null
