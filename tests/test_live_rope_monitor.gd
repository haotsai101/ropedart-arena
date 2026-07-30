extends Node
## ROUND 27 (2026-07-30) -- LIVE, REAL-GAMEPLAY rope-segment ("bar") monitor.
##
## Per direct user request ("monitor the rope bar object for clipping and
## jittering... maybe try remove leash-length calculation completely"), and
## per the coordinator's explicit instruction that every prior round's
## SYNTHETIC test scenario has failed to reproduce/explain a jitter bug the
## user can see, reproducibly, in real gameplay (ROUND 26 measured a
## stationary-near-pillar synthetic config and found the leash velocity
## clamp structurally cannot fire for a zero-velocity player -- true, but
## real gameplay is never actually zero-velocity for long: real bot AI is
## constantly steering, retreating, dodging, chasing).
##
## This test does NOT force-anchor a dart, does NOT hold a player stationary,
## and does NOT use any settle-window discard. It drives the REAL
## GameManager state machine (_init_game_local() -> start_round(), the exact
## production call sequence) with REAL bot_controller-driven players (CHASE
## -> AIM -> RETREAT, real aim noise, real dodge logic) on the REAL
## scenes/main.tscn map, for an extended continuous soak, and logs EVERY
## PHYSICS TICK, for EVERY dynamic rope segment of EVERY active chain:
##   (a) real world position
##   (b) real penetration depth into any obstacle rect (0 if not penetrating)
##   (c) frame-to-frame position delta (jitter), per segment INDEX, not an
##       aggregate -- so a specific segment/obstacle signature can be found
##   (d) rope_segment_body.gd's own _debug_last_has_contact flag
## plus (bonus, informational, feeds Task 3's "fixed length" investigation):
## the real joint gap between every consecutive segment pair, vs. the
## chain's own fixed rest length per segment.
##
## A/B TOGGLE: pass `--disable-wrap-leash` as a user arg (after `--` on the
## godot command line) to set every real player's debug_disable_wrap_leash
## = true for the whole run -- forces _rope_leash_pivot_and_radius() to
## always fall back to the flat [anchor, DART_ROPE_LENGTH] circle, per the
## user's own suspicion that the wrap-aware leash computation itself is
## responsible for jitter/clipping. Player.gd's own committed DEFAULT for
## this field is `false` (unchanged, wrap-aware live) -- only this test's
## own runtime toggle ever flips it, same "toggle-and-revert, never edit the
## file's own default" convention as GameManager.lobby_mode.
##
## Also pass `--ticks=N` to override SOAK_TICKS (default 9000 = 150s @ 60Hz).
##
## Run via:
##   godot --headless --path . res://tests/test_live_rope_monitor.tscn
##   godot --headless --path . res://tests/test_live_rope_monitor.tscn -- --disable-wrap-leash
##   godot --headless --path . res://tests/test_live_rope_monitor.tscn -- --ticks=3600

var SOAK_TICKS: int = 9000
const LOG_EVERY: int = 600  ## ~10s
const RAW_PEN_TOLERANCE: float = 0.001
const JITTER_ALERT: float = 0.5   ## per-tick per-segment position delta considered a real "jitter spike" (units/tick @ 60Hz -> 30 units/sec)
const NEAR_OBSTACLE_DIST: float = 0.3
const MID_OBSTACLE_DIST: float = 1.0
const TOP_EVENTS_KEPT: int = 15


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	var disable_wrap_leash: bool = false
	var rng_seed: int = 1337  ## fixed default so back-to-back A/B runs (with
	## vs. without --disable-wrap-leash) drive IDENTICAL real bot AI decisions
	## (aim noise, dodge-direction commits, etc. -- see bot_controller.gd's own
	## randf()/randi() calls) up until the moment the leash behavior itself
	## causes a real divergence -- an actual controlled experiment, not two
	## independently-random matches whose different throw counts/kill counts/
	## obstacle proximity already confound any comparison on their own.
	for arg in OS.get_cmdline_user_args():
		if arg == "--disable-wrap-leash":
			disable_wrap_leash = true
		elif arg.begins_with("--ticks="):
			SOAK_TICKS = int(arg.substr(8))
		elif arg.begins_with("--seed="):
			rng_seed = int(arg.substr(7))

	seed(rng_seed)
	print("[LIVEMON] starting: disable_wrap_leash=%s SOAK_TICKS=%d rng_seed=%d" % [disable_wrap_leash, SOAK_TICKS, rng_seed])

	var main_scene: Node = load("res://scenes/main.tscn").instantiate()
	add_child(main_scene)
	for i in 5:
		await get_tree().physics_frame

	var obstacles: Array = _collect_obstacle_rects()
	print("[LIVEMON] %d real obstacles:" % obstacles.size())
	for o in obstacles:
		print("[LIVEMON]   %s rect=%s" % [o["name"], o["rect"]])

	GameManager.lobby_mode = false
	GameManager.is_online = false
	GameManager.total_players = 4
	GameManager.human_count = 0
	GameManager.bot_difficulty = 2  ## hard -- most aggressive movement/throw/dodge cadence
	GameManager.lives_per_round = 5
	GameManager.rounds_to_win = 999
	GameManager.round_wins.clear()
	GameManager._all_players.clear()
	GameManager._alive_players.clear()
	GameManager._init_game_local(main_scene)
	GameManager.start_round()

	var players: Array = GameManager._all_players.duplicate()
	if disable_wrap_leash:
		for p in players:
			p.debug_disable_wrap_leash = true
	print("[LIVEMON] real GameManager flow started: %d real players, disable_wrap_leash=%s" % [players.size(), disable_wrap_leash])

	# --- Per-segment-index aggregates (key: "%d_%d" % [player_index, seg_idx]) ---
	var seg_max_jitter: Dictionary = {}
	var seg_sum_jitter: Dictionary = {}
	var seg_jitter_samples: Dictionary = {}
	var seg_max_pen: Dictionary = {}
	var seg_contact_ticks: Dictionary = {}
	var seg_max_joint_gap: Dictionary = {}
	var prev_pos: Dictionary = {}  ## key -> Vector2

	# --- Proximity-bucketed jitter (near/mid/far from nearest obstacle edge) ---
	var bucket_jitter_sum: Dictionary = {"near": 0.0, "mid": 0.0, "far": 0.0}
	var bucket_jitter_count: Dictionary = {"near": 0, "mid": 0, "far": 0}
	var bucket_jitter_max: Dictionary = {"near": 0.0, "mid": 0.0, "far": 0.0}
	var bucket_jitter_max_contact: Dictionary = {"near": 0.0, "mid": 0.0, "far": 0.0}

	var top_jitter_events: Array = []
	var top_pen_events: Array = []

	var max_raw_pen: float = 0.0
	var raw_pen_events: int = 0
	var max_jitter_overall: float = 0.0
	var jitter_alert_events: int = 0
	var contact_ticks_total: int = 0
	var throws_seen: int = 0
	var had_dart_prev: Dictionary = {}
	var kills_seen: int = 0
	var lives_prev: Dictionary = {}
	var active_chain_ticks: int = 0

	# --- Teleport/reset grace-period tracking (reset_for_round()/_respawn()
	# both hard-teleport global_position -- ROUND 23/24/25 already found and
	# fixed the WORST of the resulting chain-drag, but the chain still has a
	# real, already-disclosed "bunched layout settling out" transient for a
	# few ticks after ANY reset. Tracked here so the near-obstacle steady-
	# state analysis below isn't polluted by that already-known, separately-
	# documented mechanism -- this test is hunting for a DIFFERENT, still-
	# unexplained steady-state jitter, per the coordinator's own framing.
	const TELEPORT_JUMP_THRESHOLD: float = 3.0
	const GRACE_TICKS: int = 20
	var prev_player_pos: Dictionary = {}
	var grace_until: Dictionary = {}
	var teleport_events_seen: int = 0

	var bucket_jitter_sum_steady: Dictionary = {"near": 0.0, "mid": 0.0, "far": 0.0}
	var bucket_jitter_count_steady: Dictionary = {"near": 0, "mid": 0, "far": 0}
	var bucket_jitter_max_steady: Dictionary = {"near": 0.0, "mid": 0.0, "far": 0.0}
	var bucket_jitter_max_contact_steady: Dictionary = {"near": 0.0, "mid": 0.0, "far": 0.0}
	var top_jitter_events_steady: Array = []
	var top_pen_events_steady: Array = []
	var max_raw_pen_steady: float = 0.0

	var total_ticks: int = 0
	for tick in range(SOAK_TICKS):
		await get_tree().physics_frame
		total_ticks += 1

		var tick_max_pen: float = 0.0

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

			# Teleport/reset detection (reset_for_round()/_respawn()) -- see
			# the grace-period block's own doc comment above.
			var cur_gpos: Vector2 = p.get_pos_2d()
			if prev_player_pos.has(p):
				if cur_gpos.distance_to(prev_player_pos[p]) > TELEPORT_JUMP_THRESHOLD:
					teleport_events_seen += 1
					grace_until[p] = tick + GRACE_TICKS
			prev_player_pos[p] = cur_gpos
			var in_grace: bool = tick < int(grace_until.get(p, -1))

			if not p._physics_rope_active:
				continue
			active_chain_ticks += 1

			var segs: Array = p._physics_rope_segments
			var prev_seg_pos: Vector2 = Vector2(p._physics_rope_hand_anchor.global_position.x, p._physics_rope_hand_anchor.global_position.z) if p._physics_rope_hand_anchor != null else Vector2.ZERO

			for i in range(segs.size()):
				var seg: RigidBody3D = segs[i]
				if seg == null or not is_instance_valid(seg):
					continue
				var pos3: Vector3 = seg.global_position
				var pos2: Vector2 = Vector2(pos3.x, pos3.z)
				var key: String = "%d_%d" % [p.player_index, i]

				# (c) frame-to-frame jitter, per segment index
				var jitter: float = 0.0
				if prev_pos.has(key):
					jitter = pos2.distance_to(prev_pos[key])
				prev_pos[key] = pos2

				# (d) real contact flag
				var has_contact: bool = bool(seg.get("_debug_last_has_contact"))
				if has_contact:
					contact_ticks_total += 1
					seg_contact_ticks[key] = int(seg_contact_ticks.get(key, 0)) + 1

				# (b) penetration + nearest-obstacle distance
				var pen: float = 0.0
				var nearest_dist: float = INF
				for o in obstacles:
					var rect: Rect2 = o["rect"]
					if rect.has_point(pos2):
						var this_pen: float = minf(pos2.x - rect.position.x, rect.end.x - pos2.x)
						this_pen = minf(this_pen, minf(pos2.y - rect.position.y, rect.end.y - pos2.y))
						pen = maxf(pen, this_pen)
						nearest_dist = 0.0
					else:
						var cx: float = clampf(pos2.x, rect.position.x, rect.end.x)
						var cy: float = clampf(pos2.y, rect.position.y, rect.end.y)
						var d: float = pos2.distance_to(Vector2(cx, cy))
						nearest_dist = minf(nearest_dist, d)

				# --- (a) position is `pos3`/`pos2`, used throughout above ---

				seg_max_jitter[key] = maxf(seg_max_jitter.get(key, 0.0), jitter)
				seg_sum_jitter[key] = float(seg_sum_jitter.get(key, 0.0)) + jitter
				seg_jitter_samples[key] = int(seg_jitter_samples.get(key, 0)) + 1
				seg_max_pen[key] = maxf(seg_max_pen.get(key, 0.0), pen)

				if jitter > max_jitter_overall:
					max_jitter_overall = jitter
				if jitter > JITTER_ALERT:
					jitter_alert_events += 1
					top_jitter_events.append({
						"tick": tick, "player": p.player_index, "seg": i, "jitter": jitter,
						"pos": pos2, "contact": has_contact, "nearest_obstacle_dist": nearest_dist, "pen": pen,
					})

				var bucket: String = "near" if nearest_dist < NEAR_OBSTACLE_DIST else ("mid" if nearest_dist < MID_OBSTACLE_DIST else "far")
				bucket_jitter_sum[bucket] = float(bucket_jitter_sum[bucket]) + jitter
				bucket_jitter_count[bucket] = int(bucket_jitter_count[bucket]) + 1
				bucket_jitter_max[bucket] = maxf(bucket_jitter_max[bucket], jitter)
				if has_contact:
					bucket_jitter_max_contact[bucket] = maxf(bucket_jitter_max_contact[bucket], jitter)

				if not in_grace:
					bucket_jitter_sum_steady[bucket] = float(bucket_jitter_sum_steady[bucket]) + jitter
					bucket_jitter_count_steady[bucket] = int(bucket_jitter_count_steady[bucket]) + 1
					bucket_jitter_max_steady[bucket] = maxf(bucket_jitter_max_steady[bucket], jitter)
					if has_contact:
						bucket_jitter_max_contact_steady[bucket] = maxf(bucket_jitter_max_contact_steady[bucket], jitter)
					if jitter > JITTER_ALERT:
						top_jitter_events_steady.append({
							"tick": tick, "player": p.player_index, "seg": i, "jitter": jitter,
							"pos": pos2, "contact": has_contact, "nearest_obstacle_dist": nearest_dist, "pen": pen,
						})

				if pen > RAW_PEN_TOLERANCE:
					if pen > tick_max_pen:
						tick_max_pen = pen
					if pen > max_raw_pen:
						max_raw_pen = pen
					top_pen_events.append({
						"tick": tick, "player": p.player_index, "seg": i, "pen": pen,
						"pos": pos2, "contact": has_contact, "jitter_this_tick": jitter,
					})
					if not in_grace:
						max_raw_pen_steady = maxf(max_raw_pen_steady, pen)
						top_pen_events_steady.append({
							"tick": tick, "player": p.player_index, "seg": i, "pen": pen,
							"pos": pos2, "contact": has_contact, "jitter_this_tick": jitter,
						})

				# --- bonus: joint gap between consecutive segments (Task 3 feed) ---
				var gap: float = pos2.distance_to(prev_seg_pos)
				seg_max_joint_gap[key] = maxf(seg_max_joint_gap.get(key, 0.0), gap)
				prev_seg_pos = pos2

		if tick_max_pen > RAW_PEN_TOLERANCE:
			raw_pen_events += 1

		if (tick + 1) % LOG_EVERY == 0:
			print("[LIVEMON] tick=%d/%d (~%.0fs) throws=%d kills=%d max_raw_pen=%.4f raw_pen_events=%d jitter_alert_events=%d max_jitter=%.3f contact_ticks=%d" % [
				tick + 1, SOAK_TICKS, float(tick + 1) / 60.0, throws_seen, kills_seen,
				max_raw_pen, raw_pen_events, jitter_alert_events, max_jitter_overall, contact_ticks_total])

	# ---------------- FINAL REPORT ----------------
	print("[LIVEMON] ================ FINAL RESULTS over %d ticks (~%.0fs, %d players, %d throws, %d kills, disable_wrap_leash=%s) ================" % [
		total_ticks, float(total_ticks) / 60.0, players.size(), throws_seen, kills_seen, disable_wrap_leash])
	print("[LIVEMON] max_raw_pen=%.5f  raw_pen_events=%d/%d ticks (%.3f%%)" % [
		max_raw_pen, raw_pen_events, total_ticks, 100.0 * float(raw_pen_events) / float(maxi(total_ticks, 1))])
	print("[LIVEMON] max_jitter_overall=%.4f  jitter_alert_events(>%.2f)=%d  active_chain_sample_ticks=%d  contact_ticks_total=%d" % [
		max_jitter_overall, JITTER_ALERT, jitter_alert_events, active_chain_ticks, contact_ticks_total])

	print("[LIVEMON] teleport_events_seen (real reset_for_round()/_respawn() teleports detected, >%.1f unit jump)=%d, %d-tick grace window applied after each" % [TELEPORT_JUMP_THRESHOLD, teleport_events_seen, GRACE_TICKS])

	print("[LIVEMON] --- proximity-bucketed jitter, ALL ticks incl. post-reset transients (near<%.1f, mid<%.1f, far>=%.1f from nearest obstacle edge) ---" % [NEAR_OBSTACLE_DIST, MID_OBSTACLE_DIST, MID_OBSTACLE_DIST])
	for b in ["near", "mid", "far"]:
		var cnt: int = int(bucket_jitter_count[b])
		var mean_j: float = float(bucket_jitter_sum[b]) / float(maxi(cnt, 1))
		print("[LIVEMON]   %-4s: samples=%d mean_jitter=%.5f max_jitter=%.4f max_jitter_while_contact=%.4f" % [
			b, cnt, mean_j, bucket_jitter_max[b], bucket_jitter_max_contact[b]])

	print("[LIVEMON] --- STEADY-STATE ONLY (excludes %d-tick window after any detected teleport/reset) -- this is the isolate-the-real-bug view ---" % GRACE_TICKS)
	print("[LIVEMON] max_raw_pen_steady=%.5f" % max_raw_pen_steady)
	for b in ["near", "mid", "far"]:
		var cnt2: int = int(bucket_jitter_count_steady[b])
		var mean_j2: float = float(bucket_jitter_sum_steady[b]) / float(maxi(cnt2, 1))
		print("[LIVEMON]   %-4s: samples=%d mean_jitter=%.5f max_jitter=%.4f max_jitter_while_contact=%.4f" % [
			b, cnt2, mean_j2, bucket_jitter_max_steady[b], bucket_jitter_max_contact_steady[b]])
	print("[LIVEMON] --- STEADY-STATE top %d worst JITTER events ---" % TOP_EVENTS_KEPT)
	top_jitter_events_steady.sort_custom(func(a, b): return float(a["jitter"]) > float(b["jitter"]))
	for idx in range(mini(TOP_EVENTS_KEPT, top_jitter_events_steady.size())):
		print("[LIVEMON]   %s" % [top_jitter_events_steady[idx]])
	print("[LIVEMON] --- STEADY-STATE top %d worst PENETRATION events ---" % TOP_EVENTS_KEPT)
	top_pen_events_steady.sort_custom(func(a, b): return float(a["pen"]) > float(b["pen"]))
	for idx in range(mini(TOP_EVENTS_KEPT, top_pen_events_steady.size())):
		print("[LIVEMON]   %s" % [top_pen_events_steady[idx]])

	print("[LIVEMON] --- per-segment-index breakdown (sorted by max_jitter desc, top 15) ---")
	var seg_keys: Array = seg_max_jitter.keys()
	seg_keys.sort_custom(func(a, b): return float(seg_max_jitter[a]) > float(seg_max_jitter[b]))
	for idx in range(mini(15, seg_keys.size())):
		var k: String = seg_keys[idx]
		var samples: int = int(seg_jitter_samples.get(k, 1))
		print("[LIVEMON]   seg=%s max_jitter=%.4f mean_jitter=%.5f max_pen=%.4f contact_ticks=%d max_joint_gap=%.4f (rest_len=%.4f)" % [
			k, seg_max_jitter[k], float(seg_sum_jitter[k]) / float(maxi(samples, 1)), seg_max_pen.get(k, 0.0),
			int(seg_contact_ticks.get(k, 0)), seg_max_joint_gap.get(k, 0.0), players[0].ROPE_PHYSICS_SEGMENT_LENGTH if players.size() > 0 else -1.0])

	print("[LIVEMON] --- per-segment-index breakdown (sorted by max_pen desc, top 15) ---")
	var seg_keys_pen: Array = seg_max_pen.keys()
	seg_keys_pen.sort_custom(func(a, b): return float(seg_max_pen[a]) > float(seg_max_pen[b]))
	for idx in range(mini(15, seg_keys_pen.size())):
		var k: String = seg_keys_pen[idx]
		if float(seg_max_pen[k]) <= RAW_PEN_TOLERANCE:
			break
		print("[LIVEMON]   seg=%s max_pen=%.4f max_jitter=%.4f contact_ticks=%d" % [
			k, seg_max_pen[k], seg_max_jitter.get(k, 0.0), int(seg_contact_ticks.get(k, 0))])

	print("[LIVEMON] --- top %d worst JITTER events (tick, player, seg, jitter, pos, contact, nearest_obstacle_dist, pen) ---" % TOP_EVENTS_KEPT)
	top_jitter_events.sort_custom(func(a, b): return float(a["jitter"]) > float(b["jitter"]))
	for idx in range(mini(TOP_EVENTS_KEPT, top_jitter_events.size())):
		print("[LIVEMON]   %s" % [top_jitter_events[idx]])

	print("[LIVEMON] --- top %d worst PENETRATION events (tick, player, seg, pen, pos, contact, jitter_this_tick) ---" % TOP_EVENTS_KEPT)
	top_pen_events.sort_custom(func(a, b): return float(a["pen"]) > float(b["pen"]))
	for idx in range(mini(TOP_EVENTS_KEPT, top_pen_events.size())):
		print("[LIVEMON]   %s" % [top_pen_events[idx]])

	print("LIVE_ROPE_MONITOR_DONE")
	get_tree().quit()


func _collect_obstacle_rects() -> Array:
	var out: Array = []
	for o in get_tree().get_nodes_in_group("obstacles"):
		if not o.has_method("get_rect_2d"):
			continue
		var rect: Rect2 = o.get_rect_2d()
		var is_pillar: bool = String(o.name).begins_with("Pillar")
		out.append({"name": String(o.name), "rect": rect, "is_pillar": is_pillar})
	return out
