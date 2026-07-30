extends Node
## ROUND 28 (2026-07-30) -- targeted follow-up to ROUND 27's live rope monitor.
##
## ROUND 27 found a rare, severe (0.74 penetration depth) tunneling event on
## segment 0 (the HAND-side segment, jointed directly to the kinematic hand
## anchor, not another dynamic segment) during ORDINARY MOVEMENT, and ruled
## out one candidate cause (the hand anchor's own per-tick displacement bound
## by the player's root CharacterBody3D speed, DASH_SPEED=20 -> ~0.33
## units/tick) with real numbers.
##
## This test hunts for the SAME class of event but logs far more per-tick
## detail than test_live_rope_monitor.gd's own aggregate-focused report:
## for every player's chain, every tick, it keeps a rolling window of
## (a) segment 0 and segment 1's own position/velocity/contact,
## (b) the HAND ANCHOR's own real position (_get_rope_hand_anchor_pos(),
##     duck-typed via get_hand_world_position()) and its OWN frame-to-frame
##     delta -- this is NOT the same quantity ROUND 27 measured (that was the
##     player's CharacterBody3D root/get_pos_2d(), not the animated hand BONE
##     the kinematic anchor is actually driven from -- see player.gd's
##     _get_rope_hand_anchor_pos()/get_hand_world_position(), which tracks
##     the handslot.r BoneAttachment3D's live global_position, itself moved by
##     whatever animation is currently playing, independent of root motion
##     speed) -- a fast melee-swing (Sword_Attack/Punch_Jab, this branch's
##     own new feature) or throw/recall Enter-phase animation could move the
##     hand bone itself much faster than the character's own root ever moves.
## (c) the player's own _current_anim / _throw_anim_phase / _recall_anim_phase
##     at that instant, so a tunneling event can be correlated with "was a
##     melee/throw/recall animation playing right then."
##
## On any tick where any segment's penetration into a real obstacle exceeds
## SEVERE_PEN_THRESHOLD, dumps the full rolling window (PRE_TICKS before to
## POST_TICKS after) for that player's chain to stdout, tagged
## [TUNNEL_EVENT], so the exact mechanism can be read directly from the log
## instead of inferred from an aggregate.
##
## Run via:
##   godot --headless --path . res://tests/test_hand_side_tunnel_probe.tscn -- --ticks=10800 --seed=N

var SOAK_TICKS: int = 10800
const SEVERE_PEN_THRESHOLD: float = 0.3
const PRE_TICKS: int = 15
const POST_TICKS: int = 15
const DUMP_COOLDOWN_TICKS: int = 60  ## avoid re-dumping the same decaying event over and over


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	var rng_seed: int = randi()
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--ticks="):
			SOAK_TICKS = int(arg.substr(8))
		elif arg.begins_with("--seed="):
			rng_seed = int(arg.substr(7))

	seed(rng_seed)
	print("[TUNNELPROBE] starting: SOAK_TICKS=%d rng_seed=%d" % [SOAK_TICKS, rng_seed])

	var main_scene: Node = load("res://scenes/main.tscn").instantiate()
	add_child(main_scene)
	for i in 5:
		await get_tree().physics_frame

	var obstacles: Array = _collect_obstacle_rects()
	print("[TUNNELPROBE] %d real obstacles:" % obstacles.size())
	for o in obstacles:
		print("[TUNNELPROBE]   %s rect=%s" % [o["name"], o["rect"]])

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
	print("[TUNNELPROBE] real GameManager flow started: %d real players" % players.size())

	# Rolling window: per player_index, an Array of per-tick snapshot dicts,
	# capped at PRE_TICKS+1 entries (drops oldest).
	var window: Dictionary = {}
	for p in players:
		window[p.player_index] = []

	var prev_hand_pos: Dictionary = {}
	var prev_seg_pos: Dictionary = {}  # key "%d_%d" -> Vector2
	var dump_cooldown_until: Dictionary = {}  # player_index -> tick
	var post_dump_remaining: Dictionary = {}  # player_index -> ticks left to keep appending post-event
	var events_found: int = 0
	var max_pen_seen: float = 0.0
	var max_hand_delta_seen: float = 0.0
	var max_hand_delta_snap: Dictionary = {}
	var max_seg0_speed_seen: float = 0.0
	var max_seg0_speed_snap: Dictionary = {}
	var hand_delta_by_anim: Dictionary = {}  # anim name -> max hand_delta seen while that anim was playing

	var total_ticks: int = 0
	for tick in range(SOAK_TICKS):
		await get_tree().physics_frame
		total_ticks += 1

		for p in players:
			if not is_instance_valid(p):
				continue
			if not p._physics_rope_active:
				continue

			var hand_pos3: Vector3 = p._get_rope_hand_anchor_pos() if p.has_method("_get_rope_hand_anchor_pos") else Vector3.ZERO
			var hand_pos2: Vector2 = Vector2(hand_pos3.x, hand_pos3.z)
			var hand_delta: float = 0.0
			if prev_hand_pos.has(p.player_index):
				hand_delta = hand_pos2.distance_to(prev_hand_pos[p.player_index])
			prev_hand_pos[p.player_index] = hand_pos2

			var segs: Array = p._physics_rope_segments
			var seg_snaps: Array = []
			var tick_max_pen: float = 0.0
			var tick_max_pen_idx: int = -1
			for i in range(segs.size()):
				var seg: RigidBody3D = segs[i]
				if seg == null or not is_instance_valid(seg):
					continue
				var pos3: Vector3 = seg.global_position
				var pos2: Vector2 = Vector2(pos3.x, pos3.z)
				var vel3: Vector3 = seg.linear_velocity
				var vel2: Vector2 = Vector2(vel3.x, vel3.z)
				var key: String = "%d_%d" % [p.player_index, i]
				var seg_delta: float = 0.0
				if prev_seg_pos.has(key):
					seg_delta = pos2.distance_to(prev_seg_pos[key])
				prev_seg_pos[key] = pos2
				var has_contact: bool = bool(seg.get("_debug_last_has_contact"))

				var pen: float = 0.0
				for o in obstacles:
					var rect: Rect2 = o["rect"]
					if rect.has_point(pos2):
						var this_pen: float = minf(pos2.x - rect.position.x, rect.end.x - pos2.x)
						this_pen = minf(this_pen, minf(pos2.y - rect.position.y, rect.end.y - pos2.y))
						pen = maxf(pen, this_pen)

				if i <= 3 or pen > 0.01:  # keep segments near the hand always + anything touching
					seg_snaps.append({
						"i": i, "pos": pos2, "vel": vel2, "speed": vel2.length(),
						"delta": seg_delta, "contact": has_contact, "pen": pen,
					})

				if pen > tick_max_pen:
					tick_max_pen = pen
					tick_max_pen_idx = i
				if pen > max_pen_seen:
					max_pen_seen = pen

			var anim: String = String(p.get("_current_anim")) if p.get("_current_anim") != null else ""
			var throw_phase: int = int(p.get("_throw_anim_phase")) if p.get("_throw_anim_phase") != null else -1
			var recall_phase: int = int(p.get("_recall_anim_phase")) if p.get("_recall_anim_phase") != null else -1
			var has_dart: bool = p.dart != null and is_instance_valid(p.dart)

			var snap: Dictionary = {
				"tick": tick, "player": p.player_index, "player_pos": p.get_pos_2d(),
				"hand_pos": hand_pos2, "hand_delta": hand_delta,
				"anim": anim, "throw_phase": throw_phase, "recall_phase": recall_phase,
				"has_dart": has_dart,
				"tick_max_pen": tick_max_pen, "tick_max_pen_idx": tick_max_pen_idx,
				"segs": seg_snaps,
			}

			if hand_delta > max_hand_delta_seen:
				max_hand_delta_seen = hand_delta
				max_hand_delta_snap = snap.duplicate()
			var anim_key: String = anim if anim != "" else "(none)"
			hand_delta_by_anim[anim_key] = maxf(float(hand_delta_by_anim.get(anim_key, 0.0)), hand_delta)
			for seg in seg_snaps:
				if int(seg["i"]) == 0 and float(seg["speed"]) > max_seg0_speed_seen:
					max_seg0_speed_seen = float(seg["speed"])
					max_seg0_speed_snap = snap.duplicate()

			var w: Array = window[p.player_index]
			w.append(snap)
			if w.size() > PRE_TICKS + 1:
				w.pop_front()

			if int(post_dump_remaining.get(p.player_index, 0)) > 0:
				print("[TUNNELPROBE][POST] %s" % [_fmt_snap(snap)])
				post_dump_remaining[p.player_index] = int(post_dump_remaining[p.player_index]) - 1

			if tick_max_pen > SEVERE_PEN_THRESHOLD and tick >= int(dump_cooldown_until.get(p.player_index, 0)):
				events_found += 1
				dump_cooldown_until[p.player_index] = tick + DUMP_COOLDOWN_TICKS
				post_dump_remaining[p.player_index] = POST_TICKS
				print("[TUNNELPROBE] ================ TUNNEL_EVENT #%d: player=%d tick=%d pen=%.4f seg_idx=%d ================" % [
					events_found, p.player_index, tick, tick_max_pen, tick_max_pen_idx])
				print("[TUNNELPROBE] --- PRE-EVENT WINDOW (oldest to newest, includes triggering tick) ---")
				for s in w:
					print("[TUNNELPROBE][PRE] %s" % [_fmt_snap(s)])

		if (tick + 1) % 1800 == 0:
			print("[TUNNELPROBE] progress tick=%d/%d (~%.0fs) events_found=%d max_pen_seen=%.4f" % [
				tick + 1, SOAK_TICKS, float(tick + 1) / 60.0, events_found, max_pen_seen])

	print("[TUNNELPROBE] ================ DONE: %d ticks (~%.0fs) events_found=%d max_pen_seen=%.4f ================" % [
		total_ticks, float(total_ticks) / 60.0, events_found, max_pen_seen])
	print("[TUNNELPROBE] max_hand_delta_seen (hand BONE, not root, per-tick displacement)=%.4f  snap=%s" % [max_hand_delta_seen, _fmt_snap(max_hand_delta_snap)])
	print("[TUNNELPROBE] max_seg0_speed_seen (segment 0 linear_velocity XZ magnitude)=%.4f  snap=%s" % [max_seg0_speed_seen, _fmt_snap(max_seg0_speed_snap)])
	print("[TUNNELPROBE] --- max hand_delta observed per animation state ---")
	for k in hand_delta_by_anim.keys():
		print("[TUNNELPROBE]   anim=%s max_hand_delta=%.4f" % [k, hand_delta_by_anim[k]])
	print("TUNNEL_PROBE_DONE")
	get_tree().quit()


func _fmt_snap(s: Dictionary) -> String:
	var segs_str: String = ""
	for seg in s["segs"]:
		segs_str += "  seg%d(pos=%s spd=%.3f delta=%.3f contact=%s pen=%.4f)" % [
			seg["i"], seg["pos"], seg["speed"], seg["delta"], seg["contact"], seg["pen"]]
	return "tick=%d p=%d ppos=%s hand=%s hand_delta=%.4f anim=%s throw_ph=%d recall_ph=%d has_dart=%s max_pen=%.4f@%d |%s" % [
		s["tick"], s["player"], s["player_pos"], s["hand_pos"], s["hand_delta"],
		s["anim"], s["throw_phase"], s["recall_phase"], s["has_dart"],
		s["tick_max_pen"], s["tick_max_pen_idx"], segs_str]


func _collect_obstacle_rects() -> Array:
	var out: Array = []
	for o in get_tree().get_nodes_in_group("obstacles"):
		if not o.has_method("get_rect_2d"):
			continue
		var rect: Rect2 = o.get_rect_2d()
		var is_pillar: bool = String(o.name).begins_with("Pillar")
		out.append({"name": String(o.name), "rect": rect, "is_pillar": is_pillar})
	return out
