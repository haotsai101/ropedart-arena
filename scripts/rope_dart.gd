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
## Reaching full extension without hitting anything now ANCHORS the dart in
## open air at that point (same as an obstacle/player hit) -- per explicit
## user direction, reversing an earlier design decision where this instead
## auto-triggered recall() ("yank back") without ever anchoring. See the
## FLYING branch's own comment in _physics_process() for the change.
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

## How far the dart's ORIGIN sits past the raycast hit point, along the
## travel direction, when it anchors on a real obstacle -- NEGATIVE, i.e.
## pulled back outside the surface. dart_head.glb's blade tip is at local
## Z=-0.55, pommel at local Z=+0.315 (see DAGGER_POMMEL_OFFSET's comment in
## player.gd), so the dagger's own true midpoint sits at local Z=-0.1175 --
## noticeably closer to the origin than the tip is. For that midpoint (not
## the origin itself) to land on the surface -- i.e. the dagger actually
## reading as half embedded -- the origin needs to sit (-0.55 + 0.315) / 2
## = -0.1175 outside the surface, not past it. An earlier version pushed
## the origin 0.3 further IN, which buried nearly the whole dagger (pommel
## included) with nothing left visible -- reading as the rope just
## vanishing into solid rock rather than a stuck blade. Not applied for
## player hits or the arena boundary -- there's no solid geometry to
## visibly sink into there.
const ANCHOR_EMBED_DEPTH: float = -0.1175

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
## The travel direction frozen at the moment of anchoring (a copy of dir_2d
## at that instant) -- see _anchor()/_render(). Keeps the embedded dart's
## orientation fixed once stuck, instead of continuously re-aiming at
## wherever the owner currently stands.
var _anchor_dir_2d: Vector2 = Vector2.ZERO

@onready var head_mesh: Node3D = $Head


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
	# The rope itself is player.gd's own persistent object now (see
	# _update_persistent_rope()), not something this dart draws.

	state = State.FLYING
	add_to_group("darts")
	# Without this, head_mesh sits at its scene-default transform (world
	# origin -- the map's center) for the one render frame between
	# add_child() and this dart's first _physics_process() tick, flashing
	# there before snapping to the real thrown position.
	_render()


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
					# Push past the surface along the travel direction so the
					# blade reads as embedded rather than just touching it --
					# see ANCHOR_EMBED_DEPTH's comment.
					head_2d = (hit_point_2d as Vector2) + dir_2d * ANCHOR_EMBED_DEPTH
					_anchor()
				elif head_2d.distance_to(origin_2d) >= ROPE_LENGTH:
					# Per explicit user direction (reversing an earlier design
					# decision that auto-recalled here instead): reaching max
					# range without hitting anything now ANCHORS the dart in
					# open air at that point, same as an obstacle/player hit --
					# it stays stuck there until the owner recalls it or walks
					# over it (pickup_radius), rather than auto-yanking back.
					head_2d = origin_2d + dir_2d * ROPE_LENGTH
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
	# Freeze the embedded orientation now, from the direction it was actually
	# traveling -- see _anchor_dir_2d's comment and _render()'s use of it.
	_anchor_dir_2d = dir_2d


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

	# ANCHORED: frozen at the moment it stuck (see _anchor()) -- an embedded
	# blade doesn't swivel just because the owner walks to a different angle.
	# FLYING/RECALLING: blade points away from wherever the rope currently
	# comes from (the owner) -- roughly dir_2d while flying, and trails with
	# the pommel leading back toward the owner while recalling, covered by
	# the same rule. Falls back to dir_2d only in the degenerate case of
	# head_2d and the owner coinciding.
	var blade_dir_2d: Vector2
	if state == State.ANCHORED:
		blade_dir_2d = _anchor_dir_2d
	else:
		var owner_pos_2d: Vector2 = owner_player.get_pos_2d()
		blade_dir_2d = head_2d - owner_pos_2d
		if blade_dir_2d.length() < 0.01:
			blade_dir_2d = dir_2d
	if blade_dir_2d.length() > 0.001:
		var blade_forward: Vector3 = Vector3(blade_dir_2d.x, 0.0, blade_dir_2d.y).normalized()
		var z_axis: Vector3 = -blade_forward
		var basis_seed: Vector3 = Vector3.RIGHT if absf(z_axis.dot(Vector3.UP)) > 0.99 else Vector3.UP
		var x_axis: Vector3 = basis_seed.cross(z_axis).normalized()
		var y_axis: Vector3 = z_axis.cross(x_axis).normalized()
		head_mesh.global_transform.basis = Basis(x_axis, y_axis, z_axis)
	# The rope itself is drawn by player.gd's _update_persistent_rope() every
	# frame, reading this dart's head_mesh/plane_y by duck typing -- this
	# script no longer renders any rope of its own.
