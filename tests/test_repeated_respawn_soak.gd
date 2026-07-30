extends Node
## ROUND 24 (2026-07-29) NEW -- dedicated regression coverage for the specific
## verification gap the round's own task explicitly called out: neither
## test_real_game_loop_penetration_audit.gd's organic 90s/4-hard-bot soak
## (only 4 real throws observed in that run, per its own logged
## "throws_seen=4" -- and likely zero real mid-round kills/respawns, since
## bots rarely land a hit in a short window) nor
## test_teleport_chain_drag_penetration.gd (ONE isolated teleport) actually
## exercises MANY repeated reset_for_round()/kill()->_respawn() cycles in a
## row -- exactly the scenario ROUND 23's audit identified as the real bug's
## most frequent real-world trigger ("fires at the start of literally every
## round, not just match start" / "on every single mid-round death").
##
## This test drives the REAL GameManager production flow once (_init_game_
## local() -> start_round(), same as test_real_game_loop_penetration_audit.gd)
## to get real players with real persistent rope chains, then DIRECTLY forces
## many repeated teleport cycles via the same two real production primitives
## the fix targets:
##   (a) player.kill() -> (after its real 1.5s respawn timer) _respawn(),
##       repeated by directly killing the player again as soon as it revives
##       (bypassing the need for bots to actually land real hits, which the
##       organic soak showed is rare within a short window) -- alternating
##       spawn corners on opposite sides of a pillar each cycle so every
##       cycle's straight-line hand path crosses real obstacle geometry, the
##       same adversarial setup test_teleport_chain_drag_penetration.gd uses.
##   (b) player.reset_for_round(lives, pos) called directly and repeatedly,
##       mirroring what happens at the start of every subsequent round in a
##       real match (GameManager.start_round() calls this once per player per
##       round) -- alternating opposite-corner spawn markers each call.
##
## Every physics tick across the WHOLE soak is sampled for real raw-segment
## penetration against every real obstacle in scenes/main.tscn (not just
## PillarA) -- no settle-window discard, matching this round's own
## established "measure every tick, never skip a transient" discipline.
##
## Run via: godot --headless --path . res://tests/test_repeated_respawn_soak.tscn

const RESPAWN_CYCLES: int = 12       ## kill()->_respawn() cycles, player 0
const RESET_ROUND_CYCLES: int = 12   ## direct reset_for_round() cycles, player 1
const TICKS_PER_CYCLE: int = 150     ## 2.5s of sampling after each teleport --
## generously past the documented ~157-tick/2.6s worst-case drag window from
## this round's own primary reproduction (test_teleport_chain_drag_
## penetration.gd), so a still-draining transient isn't cut off mid-measure.
const RAW_PEN_TOLERANCE: float = 0.001


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	var main_scene: Node = load("res://scenes/main.tscn").instantiate()
	add_child(main_scene)
	for i in 5:
		await get_tree().physics_frame

	var obstacles: Array = []
	for o in get_tree().get_nodes_in_group("obstacles"):
		if not o.has_method("get_rect_2d"):
			continue
		obstacles.append({"name": String(o.name), "rect": o.get_rect_2d()})
	print("[SOAK] %d real obstacles:" % obstacles.size())
	for o in obstacles:
		print("[SOAK]   %s rect=%s" % [o["name"], o["rect"]])

	GameManager.lobby_mode = false
	GameManager.is_online = false
	GameManager.total_players = 2
	GameManager.human_count = 0
	GameManager.bot_difficulty = 0   ## easy -- bots should mostly stay put;
	## this test cares about the teleport mechanism, not combat variety.
	GameManager.lives_per_round = 999   ## never actually eliminate -- this
	## test drives kill()/_respawn() and reset_for_round() directly and
	## explicitly, not via real combat deaths.
	GameManager.rounds_to_win = 999
	GameManager.round_wins.clear()
	GameManager._all_players.clear()
	GameManager._alive_players.clear()
	GameManager._init_game_local(main_scene)
	GameManager.start_round()
	for i in 10:
		await get_tree().physics_frame

	var players: Array = GameManager._all_players.duplicate()
	var p0 = players[0]
	var p1 = players[1]

	var pillar: Node = main_scene.get_node("PillarA")
	var rect: Rect2 = pillar.get_rect_2d()
	var corner_a := Vector3(rect.position.x - 6.0, 0.7, rect.position.y - 6.0)
	var corner_b := Vector3(rect.end.x + 6.0, 0.7, rect.end.y + 6.0)

	var max_pen: float = 0.0
	var worst: Dictionary = {}
	var pen_events: int = 0
	var total_ticks: int = 0
	var cycles_with_pen: int = 0

	# --- (a) player 0: repeated kill() -> real 1.5s respawn timer -> _respawn() ---
	p0.global_position = corner_a
	p0.spawn_pos = corner_a
	for i in 20:
		await get_tree().physics_frame
	for cycle in range(RESPAWN_CYCLES):
		var target: Vector3 = corner_b if (cycle % 2 == 0) else corner_a
		p0.spawn_pos = target
		print("[SOAK] (a) kill/respawn cycle=%d/%d -- next spawn_pos=%s" % [cycle, RESPAWN_CYCLES, target])
		p0.kill()
		# kill() schedules a real 1.5s SceneTreeTimer -> _respawn() -- wait for
		# it exactly as production does, no shortcut.
		var waited: int = 0
		while p0.is_dead and waited < 200:
			await get_tree().physics_frame
			waited += 1
		if p0.is_dead:
			print("[SOAK] (a) cycle=%d WARNING: player still dead after %d ticks, skipping sample window" % [cycle, waited])
			continue
		var cycle_pen: float = 0.0
		var first_pt: int = -1
		var last_pt: int = -1
		for tick in range(TICKS_PER_CYCLE):
			await get_tree().physics_frame
			total_ticks += 1
			var tp: float = _sample_penetration(p0, obstacles)
			if tp > cycle_pen:
				cycle_pen = tp
			if tp > max_pen:
				max_pen = tp
				worst = {"phase": "kill_respawn", "cycle": cycle, "tick": tick, "pen": tp}
			if tp > RAW_PEN_TOLERANCE:
				pen_events += 1
				if first_pt < 0:
					first_pt = tick
				last_pt = tick
		if cycle_pen > RAW_PEN_TOLERANCE:
			cycles_with_pen += 1
		print("[SOAK] (a) cycle=%d done -- cycle_max_pen=%.4f pen_window=[%d..%d] (span=%d ticks)" % [
			cycle, cycle_pen, first_pt, last_pt, (last_pt - first_pt + 1) if first_pt >= 0 else 0])

	# --- (b) player 1: repeated direct reset_for_round() ---
	p1.global_position = corner_a
	p1.spawn_pos = corner_a
	for i in 20:
		await get_tree().physics_frame
	for cycle in range(RESET_ROUND_CYCLES):
		var target: Vector3 = corner_b if (cycle % 2 == 0) else corner_a
		print("[SOAK] (b) reset_for_round cycle=%d/%d -- target=%s" % [cycle, RESET_ROUND_CYCLES, target])
		p1.reset_for_round(5, target)
		var cycle_pen: float = 0.0
		var first_pt: int = -1
		var last_pt: int = -1
		for tick in range(TICKS_PER_CYCLE):
			await get_tree().physics_frame
			total_ticks += 1
			var tp: float = _sample_penetration(p1, obstacles)
			if tp > cycle_pen:
				cycle_pen = tp
			if tp > max_pen:
				max_pen = tp
				worst = {"phase": "reset_for_round", "cycle": cycle, "tick": tick, "pen": tp}
			if tp > RAW_PEN_TOLERANCE:
				pen_events += 1
				if first_pt < 0:
					first_pt = tick
				last_pt = tick
		if cycle_pen > RAW_PEN_TOLERANCE:
			cycles_with_pen += 1
		print("[SOAK] (b) cycle=%d pen_window=[%d..%d] (span=%d ticks)" % [
			cycle, first_pt, last_pt, (last_pt - first_pt + 1) if first_pt >= 0 else 0])
		print("[SOAK] (b) cycle=%d done -- cycle_max_pen=%.4f" % [cycle, cycle_pen])

	print("[SOAK] ================ FINAL RESULTS ================")
	print("[SOAK] total_teleport_cycles=%d (a=%d kill/respawn, b=%d reset_for_round) total_ticks_sampled=%d" % [
		RESPAWN_CYCLES + RESET_ROUND_CYCLES, RESPAWN_CYCLES, RESET_ROUND_CYCLES, total_ticks])
	print("[SOAK] max_pillar_pen=%.4f worst=%s" % [max_pen, worst])
	print("[SOAK] pen_events=%d/%d ticks (%.3f%%) cycles_with_any_penetration=%d/%d" % [
		pen_events, total_ticks, 100.0 * float(pen_events) / float(maxi(total_ticks, 1)),
		cycles_with_pen, RESPAWN_CYCLES + RESET_ROUND_CYCLES])
	if max_pen > RAW_PEN_TOLERANCE:
		print("[SOAK] FAIL: at least one teleport cycle dragged the chain through real obstacle geometry")
	else:
		print("[SOAK] PASS: zero real obstacle penetration across every repeated teleport cycle")
	print("REPEATED_RESPAWN_SOAK_TEST_DONE")


func _sample_penetration(p, obstacles: Array) -> float:
	if not p._physics_rope_active:
		return 0.0
	var tick_pen: float = 0.0
	for seg in p._physics_rope_segments:
		var sp: Vector3 = (seg as RigidBody3D).global_position
		var p2 := Vector2(sp.x, sp.z)
		for o in obstacles:
			var rect: Rect2 = o["rect"]
			if rect.has_point(p2):
				var pen: float = minf(p2.x - rect.position.x, rect.end.x - p2.x)
				pen = minf(pen, minf(p2.y - rect.position.y, rect.end.y - p2.y))
				if pen > tick_pen:
					tick_pen = pen
	return tick_pen
