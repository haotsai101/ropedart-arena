extends Node
## ROUND 11 PROPERTY-BASED / SWEPT REGRESSION TEST for player.gd's rope
## tube-mesh obstacle-avoidance routing (_compute_rope_tube_curve_points()
## and its new _visibility_graph_route() helper).
##
## Context: ROUNDS 8-10 (see this file's sibling tests --
## test_rope_obstacle_clip.gd, test_rope_corner_tube_overshoot.gd,
## test_rope_stray_pillar_segment.gd, test_rope_pillar_face_chord.gd -- and
## player.gd's own CLAUDE.md entry) each fixed ONE specific relative
## configuration of hand/tip/obstacle-corner as it was individually reported,
## with hand-written edge/corner-selection heuristics. After ROUND 10 shipped,
## the coordinator found a 5th distinct configuration directly, despite all
## four existing point-sample tests still passing -- the predictable failure
## mode of enumerating cases instead of solving the actual, general problem.
## This round (ROUND 11) replaced the whole heuristic pile with a
## visibility-graph + Dijkstra shortest-path algorithm (see player.gd's own
## doc comment on _compute_rope_tube_curve_points() for the full writeup).
##
## THIS TEST is what actually closes that whack-a-mole loop: instead of one
## more single hand-crafted scenario, it sweeps MANY relative configurations
## (a full angular/radial GRID around a single obstacle, PLUS randomized
## samples for less-regular coverage, PLUS a separate two-obstacle batch) and
## checks, for every single one:
##   (a) NO-PENETRATION: every sampled point on the rendered curve stays at
##       least MIN_CLEARANCE outside every obstacle's REAL (ungrown) rect.
##   (b) NO-GROSS-DETOUR: the curve's own total arc length is not grossly
##       longer than an INDEPENDENTLY, separately implemented reference
##       shortest-path calculation (_ref_shortest_path_len() below -- its own
##       standalone visibility-graph Dijkstra, sharing no code with player.gd,
##       over the SAME grown rects the real render path routes around) --
##       this is what would catch a self-crossing "bowtie" bug (ROUND 10's
##       own historical bug): a bowtie path is always measurably LONGER than
##       the true shortest path, since true shortest paths around convex
##       obstacles are never self-intersecting.
##
## Calls player._compute_rope_tube_curve_points() directly on synthetic
## 2-point [hand, tip] control-point lists -- deliberately NOT going through
## a real thrown dart/physics chain (settle windows, physics-tick waits,
## etc.) at all, since this function's obstacle-avoidance behavior is pure
## 2D geometry, independent of how the hand/tip positions were arrived at
## (see that function's own 2-control-point degenerate-case support, exactly
## what this exploits). This is what makes thousands of configurations
## practical to check in one run -- each one is a handful of synchronous
## GDScript calls, not a multi-second physics settle.
##
## Run via the Godot MCP run_project tool with
## scene=res://tests/test_rope_visibility_route_sweep.tscn.

const MIN_CLEARANCE: float = 0.15  ## same convention as
## test_rope_pillar_face_chord.gd -- a bit under ROPE_TUBE_OBSTACLE_MARGIN
## (0.2) to tolerate ordinary floating-point/curve-sampling noise.
const ROPE_TUBE_OBSTACLE_MARGIN: float = 0.2  ## mirrors player.gd's own
## const by hand -- same established convention as this codebase's other
## hand-synced duplicated constants (see e.g. player.gd's DART_STATE_ANCHORED
## comment, or test_rope_corner_tube_overshoot.gd's own
## ROPE_TUBE_CURVE_SAMPLES copy).
const SAMPLE_Y: float = 0.7
const LENGTH_REL_TOLERANCE: float = 0.15  ## 15% over the independently
## computed true shortest path is generous slack for curve-resampling
## overhead in unobstructed stretches (Catmull-Rom through a physics chain
## isn't exercised here at all -- only the 2-point degenerate case -- but the
## SAME resampling/final-push code path is), while still being nowhere near
## enough slack to hide a genuine bowtie/self-crossing detour (which
## historically produced 1.4-1.7 unit jumps on top of an already-computed
## correct route -- see ROUND 10's CLAUDE.md entry -- a large fraction of a
## typical single-obstacle detour's own total length).
const LENGTH_ABS_TOLERANCE: float = 0.3  ## flat additive slack on top of the
## relative one, so very short reference paths (near-grazing configurations)
## aren't held to an unreasonably tight bound.

var _player: Node


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	_player = load("res://scenes/player.tscn").instantiate()
	add_child(_player)
	await get_tree().physics_frame
	await get_tree().physics_frame

	var total: int = 0
	var pen_fail: int = 0
	var len_fail: int = 0
	var worst_clearance: float = 1.0e9
	var worst_clearance_cfg: String = ""
	var worst_len_ratio: float = 0.0
	var worst_len_cfg: String = ""

	# ---------------------------------------------------------------
	# SCENARIO 1: single obstacle, full angular x radial GRID sweep --
	# guarantees dense coverage of every approach angle at two different
	# distances, for BOTH hand and tip independently (so every combination
	# of "which side each end approaches from" is exercised, not just a
	# handful of hand-picked ones).
	# ---------------------------------------------------------------
	var rect_a := Rect2(Vector2(-1, -1), Vector2(2, 2))
	var obs_a: StaticBody3D = _spawn_obstacle(Vector2(0.0, 0.0), Vector2(1, 1))
	var radii: Array[float] = [2.0, 4.0]
	var angle_step_deg: int = 15
	var positions: Array[Vector2] = []
	for radius in radii:
		for angle_deg in range(0, 360, angle_step_deg):
			var rad: float = deg_to_rad(float(angle_deg))
			positions.append(Vector2(cos(rad), sin(rad)) * radius)

	for hand in positions:
		for tip in positions:
			if hand.distance_to(tip) < 0.5:
				continue
			var res: Dictionary = _check_configuration([rect_a], hand, tip)
			total += 1
			if not res.pen_ok:
				pen_fail += 1
			if not res.len_ok:
				len_fail += 1
			if res.clearance < worst_clearance:
				worst_clearance = res.clearance
				worst_clearance_cfg = "grid hand=%s tip=%s" % [hand, tip]
			if res.len_ratio > worst_len_ratio:
				worst_len_ratio = res.len_ratio
				worst_len_cfg = "grid hand=%s tip=%s arc=%.3f ref=%.3f" % [hand, tip, res.arc_len, res.ref_len]
			if not res.pen_ok or not res.len_ok:
				print("[TEST] !! FAIL grid hand=%s tip=%s clearance=%.4f arc=%.3f ref=%.3f" % [
					hand, tip, res.clearance, res.arc_len, res.ref_len])

	print("[TEST] scenario 1 (single-obstacle grid) done: %d configurations checked" % [positions.size() * positions.size()])

	# ---------------------------------------------------------------
	# SCENARIO 2: single obstacle, RANDOMIZED sweep -- less-regular
	# coverage than the grid (arbitrary distances/angles, not just the two
	# grid radii), fixed seed for reproducibility.
	# ---------------------------------------------------------------
	var rng := RandomNumberGenerator.new()
	rng.seed = 20260724
	const RANDOM_SINGLE_SAMPLES: int = 400
	for i in range(RANDOM_SINGLE_SAMPLES):
		var hand: Vector2 = _random_point_outside(rng, [rect_a.grow(ROPE_TUBE_OBSTACLE_MARGIN)], 8.0)
		var tip: Vector2 = _random_point_outside(rng, [rect_a.grow(ROPE_TUBE_OBSTACLE_MARGIN)], 8.0)
		var res: Dictionary = _check_configuration([rect_a], hand, tip)
		total += 1
		if not res.pen_ok:
			pen_fail += 1
		if not res.len_ok:
			len_fail += 1
		if res.clearance < worst_clearance:
			worst_clearance = res.clearance
			worst_clearance_cfg = "random1 hand=%s tip=%s" % [hand, tip]
		if res.len_ratio > worst_len_ratio:
			worst_len_ratio = res.len_ratio
			worst_len_cfg = "random1 hand=%s tip=%s arc=%.3f ref=%.3f" % [hand, tip, res.arc_len, res.ref_len]
		if not res.pen_ok or not res.len_ok:
			print("[TEST] !! FAIL random1 hand=%s tip=%s clearance=%.4f arc=%.3f ref=%.3f" % [
				hand, tip, res.clearance, res.arc_len, res.ref_len])

	print("[TEST] scenario 2 (single-obstacle random) done: %d configurations checked" % RANDOM_SINGLE_SAMPLES)
	obs_a.queue_free()
	await get_tree().physics_frame

	# ---------------------------------------------------------------
	# SCENARIO 3: TWO obstacles side by side, randomized sweep -- exercises
	# multi-obstacle chaining (a route that has to thread between/around two
	# separate pillars), which no single-obstacle configuration can cover.
	# ---------------------------------------------------------------
	var rect_b1 := Rect2(Vector2(-4.0, -1.0), Vector2(2, 2))
	var rect_b2 := Rect2(Vector2(1.0, -1.0), Vector2(2, 2))
	var obs_b1: StaticBody3D = _spawn_obstacle(Vector2(-3.0, 0.0), Vector2(1, 1))
	var obs_b2: StaticBody3D = _spawn_obstacle(Vector2(2.0, 0.0), Vector2(1, 1))
	var grown_multi: Array[Rect2] = [rect_b1.grow(ROPE_TUBE_OBSTACLE_MARGIN), rect_b2.grow(ROPE_TUBE_OBSTACLE_MARGIN)]
	const RANDOM_MULTI_SAMPLES: int = 200
	for i in range(RANDOM_MULTI_SAMPLES):
		var hand: Vector2 = _random_point_outside(rng, grown_multi, 9.0)
		var tip: Vector2 = _random_point_outside(rng, grown_multi, 9.0)
		var res: Dictionary = _check_configuration([rect_b1, rect_b2], hand, tip)
		total += 1
		if not res.pen_ok:
			pen_fail += 1
		if not res.len_ok:
			len_fail += 1
		if res.clearance < worst_clearance:
			worst_clearance = res.clearance
			worst_clearance_cfg = "multi hand=%s tip=%s" % [hand, tip]
		if res.len_ratio > worst_len_ratio:
			worst_len_ratio = res.len_ratio
			worst_len_cfg = "multi hand=%s tip=%s arc=%.3f ref=%.3f" % [hand, tip, res.arc_len, res.ref_len]
		if not res.pen_ok or not res.len_ok:
			print("[TEST] !! FAIL multi hand=%s tip=%s clearance=%.4f arc=%.3f ref=%.3f" % [
				hand, tip, res.clearance, res.arc_len, res.ref_len])

	print("[TEST] scenario 3 (two-obstacle random) done: %d configurations checked" % RANDOM_MULTI_SAMPLES)
	obs_b1.queue_free()
	obs_b2.queue_free()

	print("[TEST] RESULT total_configurations=%d pen_fail=%d len_fail=%d" % [total, pen_fail, len_fail])
	print("[TEST] RESULT worst_clearance=%.4f (required >= %.2f) at [%s]" % [worst_clearance, MIN_CLEARANCE, worst_clearance_cfg])
	print("[TEST] RESULT worst_len_ratio=%.4f (curve_len / true_shortest_len) at [%s]" % [worst_len_ratio, worst_len_cfg])

	if pen_fail == 0 and len_fail == 0:
		print("[TEST] PASS: all %d swept configurations stayed clear of every obstacle and never took a grossly-too-long route" % total)
	else:
		print("[TEST] FAIL: %d/%d configurations penetrated an obstacle, %d/%d took a grossly-too-long (bowtie-suspect) route" % [
			pen_fail, total, len_fail, total])
	print("VISIBILITY_ROUTE_SWEEP_TEST_DONE")


func _spawn_obstacle(pos: Vector2, half_size: Vector2) -> StaticBody3D:
	var obs := StaticBody3D.new()
	obs.set_script(load("res://scripts/arena_obstacle.gd"))
	obs.half_size = half_size
	obs.position = Vector3(pos.x, 0.0, pos.y)
	add_child(obs)
	return obs


func _random_point_outside(rng: RandomNumberGenerator, grown_rects: Array[Rect2], bound: float) -> Vector2:
	for _attempt in range(50):
		var p := Vector2(rng.randf_range(-bound, bound), rng.randf_range(-bound, bound))
		var ok := true
		for rect in grown_rects:
			if rect.has_point(p):
				ok = false
				break
		if ok:
			return p
	return Vector2(bound, bound)  ## degenerate fallback, should never hit given the sizes used above


func _check_configuration(real_rects: Array[Rect2], hand: Vector2, tip: Vector2) -> Dictionary:
	var control_points: Array[Vector3] = [
		Vector3(hand.x, SAMPLE_Y, hand.y),
		Vector3(tip.x, SAMPLE_Y, tip.y),
	]
	var curve: Array = _player._compute_rope_tube_curve_points(control_points)

	var min_clear: float = 1.0e9
	for cp in curve:
		var p2 := Vector2((cp as Vector3).x, (cp as Vector3).z)
		for rect in real_rects:
			var dx: float = maxf(rect.position.x - p2.x, p2.x - rect.end.x)
			var dz: float = maxf(rect.position.y - p2.y, p2.y - rect.end.y)
			var outside_dist: float = maxf(dx, dz)
			min_clear = minf(min_clear, outside_dist)

	var arc_len: float = 0.0
	for i in range(curve.size() - 1):
		var a: Vector3 = curve[i]
		var b: Vector3 = curve[i + 1]
		arc_len += Vector2(a.x, a.z).distance_to(Vector2(b.x, b.z))

	var grown_rects: Array[Rect2] = []
	for r in real_rects:
		grown_rects.append(r.grow(ROPE_TUBE_OBSTACLE_MARGIN))
	var ref_len: float = _ref_shortest_path_len(hand, tip, grown_rects)
	var ratio: float = arc_len / maxf(ref_len, 0.001)

	return {
		"clearance": min_clear,
		"pen_ok": min_clear >= MIN_CLEARANCE,
		"arc_len": arc_len,
		"ref_len": ref_len,
		"len_ratio": ratio,
		"len_ok": arc_len <= ref_len * (1.0 + LENGTH_REL_TOLERANCE) + LENGTH_ABS_TOLERANCE,
	}


## --- Independent reference shortest-path oracle -----------------------
## Deliberately its OWN standalone implementation, sharing no code with
## player.gd's _visibility_graph_route()/_segment_crosses_rect_interior() --
## the point is to have a second, separately-written answer to compare
## against, so an integration bug in the real render pipeline (resampling,
## run-detection edge cases, y-handling, node-building order, ...) is likely
## to disagree with this, even though both independently implement the same
## well-known "visibility graph + Dijkstra" algorithm.

func _ref_point_strictly_inside(p: Vector2, rect: Rect2) -> bool:
	return p.x > rect.position.x and p.x < rect.end.x and p.y > rect.position.y and p.y < rect.end.y


func _ref_segment_crosses_rect(p: Vector2, q: Vector2, rect: Rect2) -> bool:
	var eps: float = 0.001
	var r: Rect2 = rect.grow(-eps)
	if r.size.x <= 0.0 or r.size.y <= 0.0:
		return false
	var d: Vector2 = q - p
	var t0: float = 0.0
	var t1: float = 1.0
	var p_vals: Array[float] = [-d.x, d.x, -d.y, d.y]
	var q_vals: Array[float] = [p.x - r.position.x, r.end.x - p.x, p.y - r.position.y, r.end.y - p.y]
	for idx in range(4):
		var pv: float = p_vals[idx]
		var qv: float = q_vals[idx]
		if absf(pv) < 0.0000001:
			if qv < 0.0:
				return false
		else:
			var tt: float = qv / pv
			if pv < 0.0:
				if tt > t1:
					return false
				if tt > t0:
					t0 = tt
			else:
				if tt < t0:
					return false
				if tt < t1:
					t1 = tt
	return t0 < t1


func _ref_visible(p: Vector2, q: Vector2, rects: Array[Rect2]) -> bool:
	for rect in rects:
		if _ref_segment_crosses_rect(p, q, rect):
			return false
	return true


func _ref_shortest_path_len(hand: Vector2, tip: Vector2, grown_rects: Array[Rect2]) -> float:
	if grown_rects.is_empty():
		return hand.distance_to(tip)
	var nodes: Array[Vector2] = [hand, tip]
	for rect in grown_rects:
		var corners: Array[Vector2] = [
			rect.position, Vector2(rect.end.x, rect.position.y), rect.end, Vector2(rect.position.x, rect.end.y)
		]
		for c in corners:
			var buried := false
			for other in grown_rects:
				if other == rect:
					continue
				if _ref_point_strictly_inside(c, other):
					buried = true
					break
			if not buried:
				nodes.append(c)

	var n: int = nodes.size()
	var dist: Array[float] = []
	var visited: Array[bool] = []
	dist.resize(n)
	visited.resize(n)
	for idx in range(n):
		dist[idx] = INF
		visited[idx] = false
	dist[0] = 0.0
	for _iter in range(n):
		var u: int = -1
		var best: float = INF
		for idx in range(n):
			if not visited[idx] and dist[idx] < best:
				best = dist[idx]
				u = idx
		if u == -1:
			break
		visited[u] = true
		if u == 1:
			break
		for v in range(n):
			if visited[v] or v == u:
				continue
			if not _ref_visible(nodes[u], nodes[v], grown_rects):
				continue
			var w: float = nodes[u].distance_to(nodes[v])
			if dist[u] + w < dist[v]:
				dist[v] = dist[u] + w
	return dist[1]
