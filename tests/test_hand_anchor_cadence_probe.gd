extends Node
## ROUND 28 (2026-07-30) -- narrow, targeted verification of a specific
## hypothesis raised while chasing ROUND 27's hand-side (segment 0) rope
## tunneling event: does the KINEMATIC hand anchor's driven position
## (player.gd's _get_rope_hand_anchor_pos(), sourced from the animated
## handslot.r BoneAttachment3D's global_position) actually update EVERY
## physics tick, or only once per RENDERED (idle-process) frame -- i.e. is
## Skeleton3D/AnimationPlayer bone-pose evaluation decoupled from the fixed
## 60Hz physics step? If physics ticks can run more than once per rendered
## frame (e.g. under CPU load), the hand anchor's position would be
## artificially STALE (frozen) for several consecutive physics ticks, then
## JUMP by several ticks' worth of real animation motion in a single
## physics step when the next render frame's bone pose finally lands --
## exactly the kind of large, discontinuous, joint-solver-breaking
## displacement that could drag segment 0 (the segment jointed directly to
## this kinematic anchor) clean through a thin obstacle edge within a
## handful of ticks, distinct from and unbounded by the player's own root
## CharacterBody3D speed (already ruled out by ROUND 27).
##
## This test does NOT chase the rare pillar-tunneling event itself -- it
## directly measures the update CADENCE of the hand anchor position vs. the
## physics tick counter vs. the idle/render frame counter, single instance,
## no parallel CPU contention, so any staleness found here is attributable
## to the engine's own physics/idle decoupling, not to this session's own
## multi-process soak methodology.
##
## Run via:
##   godot --headless --path . res://tests/test_hand_anchor_cadence_probe.tscn -- --ticks=3600

var SOAK_TICKS: int = 3600
var _idle_frame_count: int = 0
var _physics_tick_count: int = 0


func _ready() -> void:
	call_deferred("_run")


func _process(_delta: float) -> void:
	_idle_frame_count += 1


func _run() -> void:
	var rng_seed: int = randi()
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--ticks="):
			SOAK_TICKS = int(arg.substr(8))
		elif arg.begins_with("--seed="):
			rng_seed = int(arg.substr(7))
	seed(rng_seed)
	print("[CADENCEPROBE] starting: SOAK_TICKS=%d rng_seed=%d physics_ticks_per_second=%d" % [
		SOAK_TICKS, rng_seed, Engine.physics_ticks_per_second])

	var main_scene: Node = load("res://scenes/main.tscn").instantiate()
	add_child(main_scene)
	for i in 5:
		await get_tree().physics_frame

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
	print("[CADENCEPROBE] real GameManager flow started: %d real players" % players.size())

	var prev_hand_pos: Dictionary = {}
	var unchanged_streak: Dictionary = {}
	var streak_histogram: Dictionary = {}  ## streak length (int) -> occurrence count
	var max_streak: int = 0
	var total_hand_updates: int = 0
	var total_hand_samples: int = 0
	var jump_after_streak_events: Array = []  ## top few biggest jumps preceded by a long freeze
	var idle_at_start: int = _idle_frame_count

	for tick in range(SOAK_TICKS):
		await get_tree().physics_frame
		_physics_tick_count += 1

		for p in players:
			if not is_instance_valid(p):
				continue
			if not p.has_method("_get_rope_hand_anchor_pos"):
				continue
			var hand3: Vector3 = p._get_rope_hand_anchor_pos()
			var hand2: Vector2 = Vector2(hand3.x, hand3.z)
			total_hand_samples += 1

			if prev_hand_pos.has(p.player_index):
				var prev: Vector2 = prev_hand_pos[p.player_index]
				var delta: float = hand2.distance_to(prev)
				if delta < 0.00001:
					unchanged_streak[p.player_index] = int(unchanged_streak.get(p.player_index, 0)) + 1
				else:
					total_hand_updates += 1
					var streak: int = int(unchanged_streak.get(p.player_index, 0))
					streak_histogram[streak] = int(streak_histogram.get(streak, 0)) + 1
					if streak > max_streak:
						max_streak = streak
					if streak >= 2 and delta > 0.15:
						jump_after_streak_events.append({
							"tick": tick, "player": p.player_index, "frozen_ticks": streak,
							"jump_delta": delta, "hand_pos": hand2,
							"idle_frames_elapsed_total": _idle_frame_count - idle_at_start,
							"physics_ticks_elapsed_total": _physics_tick_count,
						})
					unchanged_streak[p.player_index] = 0
			prev_hand_pos[p.player_index] = hand2

		if (tick + 1) % 600 == 0:
			print("[CADENCEPROBE] progress tick=%d/%d idle_frames_so_far=%d ratio(physics_ticks/idle_frames)=%.3f max_streak_so_far=%d" % [
				tick + 1, SOAK_TICKS, _idle_frame_count - idle_at_start,
				float(_physics_tick_count) / float(maxi(_idle_frame_count - idle_at_start, 1)), max_streak])

	print("[CADENCEPROBE] ================ DONE ================")
	print("[CADENCEPROBE] physics_ticks=%d idle_frames=%d ratio=%.3f (>1.0 means physics ran faster/more-often than rendering -- i.e. multiple physics ticks per idle frame is possible)" % [
		_physics_tick_count, _idle_frame_count - idle_at_start, float(_physics_tick_count) / float(maxi(_idle_frame_count - idle_at_start, 1))])
	print("[CADENCEPROBE] total_hand_samples=%d total_hand_position_CHANGES=%d (%.1f%% of samples saw a real position delta)" % [
		total_hand_samples, total_hand_updates, 100.0 * float(total_hand_updates) / float(maxi(total_hand_samples, 1))])
	print("[CADENCEPROBE] max consecutive-unchanged-tick streak observed (hand anchor frozen for N physics ticks in a row before jumping)=%d" % max_streak)
	print("[CADENCEPROBE] streak length histogram (streak_len -> how many times a jump was preceded by exactly that many frozen ticks):")
	var streak_keys: Array = streak_histogram.keys()
	streak_keys.sort()
	for k in streak_keys:
		print("[CADENCEPROBE]   streak=%d count=%d" % [k, streak_histogram[k]])
	print("[CADENCEPROBE] top jump-after-freeze events (streak>=2 AND jump_delta>0.15):")
	jump_after_streak_events.sort_custom(func(a, b): return float(a["jump_delta"]) > float(b["jump_delta"]))
	for idx in range(mini(20, jump_after_streak_events.size())):
		print("[CADENCEPROBE]   %s" % [jump_after_streak_events[idx]])

	print("CADENCE_PROBE_DONE")
	get_tree().quit()
