extends Node
## ROUND 29 (2026-07-30) -- LIVE, REAL-GAMEPLAY comparison of the RENDERED
## tube-mesh curve (_compute_rope_tube_curve_points(), the actual, shipped
## function that draws what the player sees) against the REAL PHYSICS
## RigidBody3D segment positions it's sampled through.
##
## Direct follow-up to the user's report that ROUND 28's fix (which measured
## and fixed RAW PHYSICS segment penetration, down to 0.003-0.032 across 10
## soaks) produced no visible change. The leading hypothesis: the Catmull-Rom
## smoothing curve _update_rope_tube_mesh() draws through those now-clean
## physics points can still mathematically overshoot INTO an obstacle between
## two real, obstacle-clear control points -- so what's actually on screen
## could still be clipping even though the underlying RigidBody3D chain
## (already measured, elsewhere) is not.
##
## This test drives the REAL GameManager/bot_controller game loop (same
## methodology as test_live_rope_monitor.gd) and, every physics tick, for
## every active rope chain:
##   1. builds the EXACT same control_points list _update_rope_tube_mesh()
##      builds [hand anchor, every dynamic segment center, tip anchor]
##   2. calls the REAL, SHIPPED p._compute_rope_tube_curve_points() on it --
##      not a reimplementation, the actual function that runs every frame
##   3. measures penetration of (a) the raw control points and (b) every
##      sampled curve point against every real obstacle rect
## and reports whether curve penetration ever exceeds raw penetration --
## the direct, numeric signature of a render-only overshoot artifact.
##
## Run via:
##   godot --headless --path . res://tests/test_render_curve_vs_physics_monitor.tscn
##   godot --headless --path . res://tests/test_render_curve_vs_physics_monitor.tscn -- --ticks=3600 --seed=42

var SOAK_TICKS: int = 9000
const LOG_EVERY: int = 600  ## ~10s
const PEN_TOLERANCE: float = 0.001
const TOP_EVENTS_KEPT: int = 20
## How far past the raw control points' own max penetration the curve has to
## overshoot, on a given tick, to count as a distinct "render-only" event
## (i.e. not just noise/rounding on an already-penetrating raw config).
const OVERSHOOT_MARGIN: float = 0.01


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	var rng_seed: int = 1337
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--ticks="):
			SOAK_TICKS = int(arg.substr(8))
		elif arg.begins_with("--seed="):
			rng_seed = int(arg.substr(7))

	seed(rng_seed)
	print("[CURVEMON] starting: SOAK_TICKS=%d rng_seed=%d" % [SOAK_TICKS, rng_seed])

	var main_scene: Node = load("res://scenes/main.tscn").instantiate()
	add_child(main_scene)
	for i in 5:
		await get_tree().physics_frame

	var obstacles: Array = _collect_obstacle_rects()
	print("[CURVEMON] %d real obstacles:" % obstacles.size())
	for o in obstacles:
		print("[CURVEMON]   %s rect=%s" % [o["name"], o["rect"]])

	GameManager.lobby_mode = false
	GameManager.is_online = false
	GameManager.total_players = 4
	GameManager.human_count = 0
	GameManager.bot_difficulty = 2
	GameManager.lives_per_round = 5
	GameManager.rounds_to_win = 999
	GameManager.round_wins.clear()
	GameManager._all_players.clear()
	GameManager._alive_players.clear()
	GameManager._init_game_local(main_scene)
	GameManager.start_round()

	var players: Array = GameManager._all_players.duplicate()
	print("[CURVEMON] real GameManager flow started: %d real players" % players.size())

	var max_raw_pen: float = 0.0
	var max_curve_pen: float = 0.0
	var raw_pen_ticks: int = 0
	var curve_pen_ticks: int = 0
	var overshoot_ticks: int = 0     ## curve_pen > raw_pen + OVERSHOOT_MARGIN, same tick, same player
	var overshoot_events: Array = []
	var curve_only_events: Array = []  ## raw_pen == 0 but curve_pen > tolerance
	var active_chain_ticks: int = 0
	var throws_seen: int = 0
	var had_dart_prev: Dictionary = {}
	var kills_seen: int = 0
	var lives_prev: Dictionary = {}

	var total_ticks: int = 0
	for tick in range(SOAK_TICKS):
		await get_tree().physics_frame
		total_ticks += 1

		for p in players:
			if not is_instance_valid(p):
				continue

			var has_dart_now: bool = p.dart != null and is_instance_valid(p.dart)
			if has_dart_now and not had_dart_prev.get(p, false):
				throws_seen += 1
			had_dart_prev[p] = has_dart_now

			var lp: int = int(lives_prev.get(p, p.lives))
			if p.lives < lp:
				kills_seen += 1
			lives_prev[p] = p.lives

			if not p._physics_rope_active:
				continue
			if p._physics_rope_hand_anchor == null or p._physics_rope_tip_anchor == null:
				continue
			if p._physics_rope_segments.size() != p.ROPE_PHYSICS_SEGMENTS:
				continue
			active_chain_ticks += 1

			var control_points: Array[Vector3] = [p._physics_rope_hand_anchor.global_position]
			for seg in p._physics_rope_segments:
				control_points.append((seg as RigidBody3D).global_position)
			control_points.append(p._physics_rope_tip_anchor.global_position)

			var raw_pen_this: float = 0.0
			var raw_worst_pos: Vector2 = Vector2.ZERO
			for cp in control_points:
				var pos2: Vector2 = Vector2(cp.x, cp.z)
				var pen: float = _pen_against_obstacles(pos2, obstacles)
				if pen > raw_pen_this:
					raw_pen_this = pen
					raw_worst_pos = pos2

			var curve_points: Array[Vector3] = p._compute_rope_tube_curve_points(control_points)
			var curve_pen_this: float = 0.0
			var curve_worst_pos: Vector2 = Vector2.ZERO
			for cpt in curve_points:
				var pos2b: Vector2 = Vector2(cpt.x, cpt.z)
				var pen2: float = _pen_against_obstacles(pos2b, obstacles)
				if pen2 > curve_pen_this:
					curve_pen_this = pen2
					curve_worst_pos = pos2b

			if raw_pen_this > max_raw_pen:
				max_raw_pen = raw_pen_this
			if curve_pen_this > max_curve_pen:
				max_curve_pen = curve_pen_this
			if raw_pen_this > PEN_TOLERANCE:
				raw_pen_ticks += 1
			if curve_pen_this > PEN_TOLERANCE:
				curve_pen_ticks += 1

			if curve_pen_this > raw_pen_this + OVERSHOOT_MARGIN:
				overshoot_ticks += 1
				overshoot_events.append({
					"tick": tick, "player": p.player_index,
					"raw_pen": raw_pen_this, "curve_pen": curve_pen_this,
					"raw_worst_pos": raw_worst_pos, "curve_worst_pos": curve_worst_pos,
				})
				if raw_pen_this <= PEN_TOLERANCE:
					curve_only_events.append({
						"tick": tick, "player": p.player_index,
						"curve_pen": curve_pen_this, "curve_worst_pos": curve_worst_pos,
					})

		if (tick + 1) % LOG_EVERY == 0:
			print("[CURVEMON] tick=%d/%d (~%.0fs) throws=%d kills=%d max_raw_pen=%.5f max_curve_pen=%.5f overshoot_ticks=%d curve_only_events=%d" % [
				tick + 1, SOAK_TICKS, float(tick + 1) / 60.0, throws_seen, kills_seen,
				max_raw_pen, max_curve_pen, overshoot_ticks, curve_only_events.size()])

	print("[CURVEMON] ================ FINAL RESULTS over %d ticks (~%.0fs, %d players, %d throws, %d kills) ================" % [
		total_ticks, float(total_ticks) / 60.0, players.size(), throws_seen, kills_seen])
	print("[CURVEMON] active_chain_sample_ticks=%d" % active_chain_ticks)
	print("[CURVEMON] max_raw_pen=%.5f (raw_pen_ticks=%d)" % [max_raw_pen, raw_pen_ticks])
	print("[CURVEMON] max_curve_pen=%.5f (curve_pen_ticks=%d)" % [max_curve_pen, curve_pen_ticks])
	print("[CURVEMON] overshoot_ticks (curve_pen > raw_pen + %.2f)=%d" % [OVERSHOOT_MARGIN, overshoot_ticks])
	print("[CURVEMON] curve_only_events (raw clean, curve penetrating)=%d" % curve_only_events.size())

	print("[CURVEMON] --- top %d worst OVERSHOOT events (curve_pen - raw_pen) ---" % TOP_EVENTS_KEPT)
	overshoot_events.sort_custom(func(a, b): return (float(a["curve_pen"]) - float(a["raw_pen"])) > (float(b["curve_pen"]) - float(b["raw_pen"])))
	for idx in range(mini(TOP_EVENTS_KEPT, overshoot_events.size())):
		var e: Dictionary = overshoot_events[idx]
		print("[CURVEMON]   %s" % [e])

	print("[CURVEMON] --- top %d worst CURVE-ONLY events (raw fully clean) ---" % TOP_EVENTS_KEPT)
	curve_only_events.sort_custom(func(a, b): return float(a["curve_pen"]) > float(b["curve_pen"]))
	for idx in range(mini(TOP_EVENTS_KEPT, curve_only_events.size())):
		var e2: Dictionary = curve_only_events[idx]
		print("[CURVEMON]   %s" % [e2])

	print("RENDER_CURVE_MONITOR_DONE")
	get_tree().quit()


func _pen_against_obstacles(pos2: Vector2, obstacles: Array) -> float:
	var pen: float = 0.0
	for o in obstacles:
		var rect: Rect2 = o["rect"]
		if rect.has_point(pos2):
			var this_pen: float = minf(pos2.x - rect.position.x, rect.end.x - pos2.x)
			this_pen = minf(this_pen, minf(pos2.y - rect.position.y, rect.end.y - pos2.y))
			pen = maxf(pen, this_pen)
	return pen


func _collect_obstacle_rects() -> Array:
	var out: Array = []
	for o in get_tree().get_nodes_in_group("obstacles"):
		if not o.has_method("get_rect_2d"):
			continue
		var rect: Rect2 = o.get_rect_2d()
		out.append({"name": String(o.name), "rect": rect})
	return out
