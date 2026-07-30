extends Node
## AUDIT-ONLY test (2026-07-29, "does the rope-vs-obstacle penetration test
## suite actually reflect real gameplay" investigation). NOT a synthetic
## force-anchor probe like every other test in this directory -- this one
## drives the REAL GameManager round state machine (LOBBY->COUNTDOWN->PLAYING,
## _init_game_local(), start_round(), the real per-frame _process() countdown
## timer) with REAL bot_controller-driven players (CHASE->AIM->RETREAT, real
## aim noise, real throw timing) fighting each other continuously in the REAL
## scenes/main.tscn map, for an extended continuous soak with NO scripted
## force-anchor shortcuts and NO per-config "settle then measure once" pauses
## -- every single physics tick of the whole soak is sampled.
##
## Investigates, with direct measurement, the four hypotheses the coordinator
## raised about why 20+ rounds of "0.0000 penetration" test results might not
## match a real user's actual play experience:
##  1. Are synthetic test configs representative of what a REAL throw (real
##     bot aim noise, real angles, real distances, real animation-driven hand
##     tracking) actually produces?
##  2. Does the RENDERED tube curve (Catmull-Rom through the real control
##     points, the same function _update_rope_tube_mesh() calls) penetrate
##     obstacles even when the raw physics segments don't -- and is that gap
##     bigger/more frequent than the one or two configs
##     test_rope_corner_tube_overshoot.gd already checks?
##  3. Do the existing tests' generous "settle N ticks then measure" windows
##     hide transients that a real, continuously-moving, continuously-thrown
##     game never lets fully decay?
##  4. Does the real map's obstacle variety (2 square pillars AND 2 randomly
##     rotated, ASYMMETRIC cactus footprints, via nature_scatter.gd) expose
##     anything the hand-picked PillarA-only test configs never touch?
##
## Every obstacle actually in the group is measured, not just PillarA -- see
## _collect_obstacle_rects().
##
## RESULT (2026-07-29, see CLAUDE.md's dated ROUND 23 entry for the full
## writeup): a 90s/4-hard-bot real soak measured a REAL raw-physics-segment
## penetration (max 0.037, into a real cactus TreeObstacle) at tick 18 -- well
## before any dart was ever thrown (state was still COUNTDOWN). Root-caused by
## test_teleport_chain_drag_penetration.gd (same directory): NOT a thrown-dart
## bug at all -- the persistent idle rope chain is built once, synchronously,
## in player.gd's _ready() at whatever position the player node occupies at
## that instant (player.tscn's baked-in default transform, near world
## origin/between the two real pillars), and GameManager's own real
## _init_game_local() -> start_round() -> reset_for_round() sequence teleports
## global_position to the real spawn marker immediately afterward, in the same
## frame, without touching the already-built chain's 24 dynamic segments --
## which then get violently "reeled in" toward the new hand position over the
## next several real seconds, sweeping through whatever real obstacle lies on
## the straight-line path between the stale build position and the new spawn.
## The exact same sequence recurs on EVERY round's reset_for_round() and every
## kill()->_respawn() teleport, not just match start.
##
## Run via: godot --headless --path . res://tests/test_real_game_loop_penetration_audit.tscn

const SOAK_TICKS: int = 5400   ## 90s at 60Hz -- long enough for many real
## throw/anchor/recall/kill/respawn/round-transition cycles with multiple
## simultaneous bots, not just one throw's own settle window.
const LOG_EVERY: int = 300     ## ~5s
const RAW_PEN_TOLERANCE: float = 0.001  ## same tolerance every existing test
## in this suite already uses for the raw-segment guarantee.


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	var main_scene: Node = load("res://scenes/main.tscn").instantiate()
	add_child(main_scene)
	for i in 5:
		await get_tree().physics_frame

	var obstacles: Array = _collect_obstacle_rects(main_scene)
	print("[AUDIT] %d real obstacles in scenes/main.tscn:" % obstacles.size())
	for o in obstacles:
		print("[AUDIT]   %s rect=%s" % [o["name"], o["rect"]])

	# --- Drive the REAL GameManager flow, not a hand-instantiated player list.
	GameManager.lobby_mode = false
	GameManager.is_online = false
	GameManager.total_players = 4
	GameManager.human_count = 0       ## every slot is a real bot_controller
	GameManager.bot_difficulty = 2    ## hard -- most aggressive throw/dodge cadence
	GameManager.lives_per_round = 5
	GameManager.rounds_to_win = 999   ## don't let MATCH_END stop the soak early
	GameManager.round_wins.clear()
	GameManager._all_players.clear()
	GameManager._alive_players.clear()
	GameManager._init_game_local(main_scene)
	GameManager.start_round()
	print("[AUDIT] GameManager real flow started: total_players=%d human_count=%d bot_difficulty=%d" % [
		GameManager.total_players, GameManager.human_count, GameManager.bot_difficulty])

	var players: Array = GameManager._all_players.duplicate()

	# --- Aggregate audit signals ---
	var max_raw_pen: float = 0.0
	var max_curve_pen: float = 0.0
	var raw_pen_events: int = 0     ## ticks with ANY raw segment penetration > tolerance
	var curve_pen_events: int = 0   ## ticks with ANY curve-sample penetration > tolerance
	var curve_only_events: int = 0  ## ticks where curve penetrated but raw did NOT (the hypothesis-2 gap)
	var worst_raw: Dictionary = {}
	var worst_curve: Dictionary = {}
	var worst_curve_only: Dictionary = {}
	var throws_seen: int = 0
	var anchors_seen_this_tick_prev: Dictionary = {}  ## player -> was dart != null last tick
	var real_throw_samples: Array = []  ## [{dist, angle_deg}] logged at throw-instant, for hypothesis-1 variety check
	var state_outside_playing_ticks: int = 0
	var cactus_contact_ticks: int = 0  ## ticks where ANY chain penetrated a CACTUS (non-pillar) rect specifically

	var total_ticks: int = 0
	for tick in range(SOAK_TICKS):
		await get_tree().physics_frame
		total_ticks += 1

		if GameManager.current_state != GameManager.RoundState.PLAYING:
			state_outside_playing_ticks += 1

		var tick_raw_pen: float = 0.0
		var tick_curve_pen: float = 0.0

		for p in players:
			if not is_instance_valid(p):
				continue

			# Detect a fresh throw this tick (dart went from null -> non-null)
			# for the real-throw-variety log, independent of the penetration
			# measurement below.
			var has_dart_now: bool = p.dart != null and is_instance_valid(p.dart)
			var had_dart_prev: bool = anchors_seen_this_tick_prev.get(p, false)
			if has_dart_now and not had_dart_prev:
				throws_seen += 1
				var hand0: Vector3 = p._get_rope_hand_anchor_pos()
				var dist: float = Vector2(hand0.x, hand0.z).distance_to(p.dart.head_2d)
				real_throw_samples.append({"dist": dist, "player": p.player_index})
			anchors_seen_this_tick_prev[p] = has_dart_now

			if not p._physics_rope_active:
				continue

			var control_points: Array[Vector3] = []
			var hand_body: RigidBody3D = p._physics_rope_hand_anchor
			var tip_body: RigidBody3D = p._physics_rope_tip_anchor
			if hand_body == null or tip_body == null:
				continue
			control_points.append(hand_body.global_position)
			for seg in p._physics_rope_segments:
				control_points.append((seg as RigidBody3D).global_position)
			control_points.append(tip_body.global_position)

			# RAW physics segments vs every real obstacle.
			for cp in control_points:
				var p2 := Vector2(cp.x, cp.z)
				for o in obstacles:
					var rect: Rect2 = o["rect"]
					if rect.has_point(p2):
						var pen: float = minf(p2.x - rect.position.x, rect.end.x - p2.x)
						pen = minf(pen, minf(p2.y - rect.position.y, rect.end.y - p2.y))
						if pen > tick_raw_pen:
							tick_raw_pen = pen
						if pen > max_raw_pen:
							max_raw_pen = pen
							worst_raw = {"tick": tick, "player": p.player_index, "obstacle": o["name"], "pen": pen, "pos": p2}
						if not bool(o.get("is_pillar", true)) and pen > RAW_PEN_TOLERANCE:
							cactus_contact_ticks += 1

			# RENDERED curve (the exact real function _update_rope_tube_mesh() calls).
			var curve_pts: Array[Vector3] = p._compute_rope_tube_curve_points(control_points)
			for cpt in curve_pts:
				var p2c := Vector2(cpt.x, cpt.z)
				for o in obstacles:
					var rect2: Rect2 = o["rect"]
					if rect2.has_point(p2c):
						var penc: float = minf(p2c.x - rect2.position.x, rect2.end.x - p2c.x)
						penc = minf(penc, minf(p2c.y - rect2.position.y, rect2.end.y - p2c.y))
						if penc > tick_curve_pen:
							tick_curve_pen = penc
						if penc > max_curve_pen:
							max_curve_pen = penc
							worst_curve = {"tick": tick, "player": p.player_index, "obstacle": o["name"], "pen": penc, "pos": p2c}

		if tick_raw_pen > RAW_PEN_TOLERANCE:
			raw_pen_events += 1
		if tick_curve_pen > RAW_PEN_TOLERANCE:
			curve_pen_events += 1
		if tick_curve_pen > RAW_PEN_TOLERANCE and tick_raw_pen <= RAW_PEN_TOLERANCE:
			curve_only_events += 1
			if tick_curve_pen > worst_curve_only.get("pen", 0.0):
				worst_curve_only = {"tick": tick, "pen": tick_curve_pen}

		if (tick + 1) % LOG_EVERY == 0:
			print("[AUDIT] tick=%d/%d (~%.0fs) throws_seen=%d max_raw_pen_running=%.4f max_curve_pen_running=%.4f raw_pen_events_running=%d curve_pen_events_running=%d curve_only_events_running=%d state_outside_playing=%d" % [
				tick + 1, SOAK_TICKS, float(tick + 1) / 60.0, throws_seen, max_raw_pen, max_curve_pen,
				raw_pen_events, curve_pen_events, curve_only_events, state_outside_playing_ticks])

	print("[AUDIT] ================ FINAL RESULTS over %d ticks (~%.0fs real soak, %d real bots, %d throws observed) ================" % [
		total_ticks, float(total_ticks) / 60.0, players.size(), throws_seen])
	print("[AUDIT] max_raw_pen=%.5f (RAW_PEN_TOLERANCE=%.3f) -> %s" % [
		max_raw_pen, RAW_PEN_TOLERANCE, "PASS (never penetrated)" if max_raw_pen <= RAW_PEN_TOLERANCE else "FAIL (real physics penetration occurred)"])
	print("[AUDIT] worst_raw=%s" % [worst_raw])
	print("[AUDIT] max_curve_pen=%.5f -> %s" % [
		max_curve_pen, "never penetrated" if max_curve_pen <= RAW_PEN_TOLERANCE else "RENDERED CURVE PENETRATED OBSTACLE"])
	print("[AUDIT] worst_curve=%s" % [worst_curve])
	print("[AUDIT] raw_pen_events=%d/%d ticks (%.2f%%)" % [
		raw_pen_events, total_ticks, 100.0 * float(raw_pen_events) / float(maxi(total_ticks, 1))])
	print("[AUDIT] curve_pen_events=%d/%d ticks (%.2f%%)" % [
		curve_pen_events, total_ticks, 100.0 * float(curve_pen_events) / float(maxi(total_ticks, 1))])
	print("[AUDIT] curve_only_events (curve penetrated, raw did NOT -- the render/physics measurement gap)=%d/%d ticks (%.2f%%) worst=%s" % [
		curve_only_events, total_ticks, 100.0 * float(curve_only_events) / float(maxi(total_ticks, 1)), worst_curve_only])
	print("[AUDIT] cactus_contact_ticks (non-pillar, rotated/asymmetric obstacle penetration ticks)=%d" % cactus_contact_ticks)
	print("[AUDIT] state_outside_playing_ticks=%d/%d (%.2f%%) -- ticks where GameManager.current_state != PLAYING while sampling ran" % [
		state_outside_playing_ticks, total_ticks, 100.0 * float(state_outside_playing_ticks) / float(maxi(total_ticks, 1))])

	# Real-throw distance/angle variety, for the hypothesis-1 "are synthetic
	# configs representative" comparison -- existing tests use a handful of
	# fixed hand-picked distances; this reports what real bot AI actually
	# produced across the whole soak.
	var min_dist: float = INF
	var max_dist: float = 0.0
	var sum_dist: float = 0.0
	for s in real_throw_samples:
		var d: float = s["dist"]
		min_dist = minf(min_dist, d)
		max_dist = maxf(max_dist, d)
		sum_dist += d
	var mean_dist: float = sum_dist / float(maxi(real_throw_samples.size(), 1))
	print("[AUDIT] real throw hand-to-anchor distance range across %d real throws: min=%.2f max=%.2f mean=%.2f (DART_ROPE_LENGTH=%.2f)" % [
		real_throw_samples.size(), min_dist if real_throw_samples.size() > 0 else -1.0, max_dist, mean_dist, players[0].DART_ROPE_LENGTH if players.size() > 0 else -1.0])

	print("REAL_GAME_LOOP_PENETRATION_AUDIT_DONE")


func _collect_obstacle_rects(main_scene: Node) -> Array:
	## Every real "obstacles" group member currently in the tree -- NOT just
	## PillarA, unlike every other test in this suite. Includes PillarA/
	## PillarB (square, 2x2) AND the real CactusScatter TreeObstacle instances
	## (nature_scatter.gd's _add_obstacle_collision -- rotated, asymmetric
	## footprint, half-extent (1.019, 0.2756) native before rotation/scale) --
	## see hypothesis 4.
	var out: Array = []
	for o in get_tree().get_nodes_in_group("obstacles"):
		if not o.has_method("get_rect_2d"):
			continue
		var rect: Rect2 = o.get_rect_2d()
		var is_pillar: bool = String(o.name).begins_with("Pillar")
		out.append({"name": String(o.name), "rect": rect, "is_pillar": is_pillar})
	return out
