extends Node
## FOLLOW-UP, ROOT-CAUSE-CONFIRMING test for a finding surfaced by
## test_real_game_loop_penetration_audit.gd's real-game-loop soak: a real
## penetration event at tick~18 of a real match, well before any dart was
## ever thrown, during COUNTDOWN.
##
## HYPOTHESIS: player.gd's persistent physics rope chain is built once,
## synchronously, in _ready() (_setup_dagger_in_hand() -> _spawn_physics_rope(),
## see player.gd line ~801) -- AT WHATEVER POSITION THE PLAYER NODE HAPPENS TO
## OCCUPY AT THAT EXACT MOMENT. Every one of this codebase's OWN existing
## tests' _spawn_player(pos, aim) helper calls add_child(player) (which runs
## _ready() synchronously, building the chain at player.tscn's DEFAULT scene
## position) BEFORE setting player.global_position = pos -- i.e. every
## existing test ALREADY reproduces a "chain built at position A, player body
## then teleported to position B" sequence, but always follows it with a
## generous settle window (5-300+ ticks) before ever taking a measurement,
## so this transient has never once been directly measured.
##
## The REAL production code path (game_manager.gd's _init_game() ->
## _init_game_local() [adds all players, ready() fires, chain built at
## default scene position] -> start_round() -> reset_for_round() [teleports
## global_position to the real spawn marker, does NOT touch the already-built
## chain bodies]) follows the exact same sequence -- and, separately,
## reset_for_round() fires again at the start of EVERY subsequent round (chain
## already exists, converged near wherever the player ended the PREVIOUS
## round, then teleported to a new spawn marker up to the full arena diagonal
## away), and kill()/_respawn() teleports global_position on every mid-round
## death/respawn too. None of these three real, frequent, recurring
## teleport-after-chain-exists events has ever been exercised by any existing
## test.
##
## This test isolates the mechanism directly: spawn a player far from any
## obstacle, let its chain fully settle/collapse near the hand (confirmed,
## not assumed), THEN perform a single instantaneous global_position teleport
## (mirroring reset_for_round()'s own exact mechanism -- a bare
## global_position write, nothing else) to a position on the OPPOSITE side of
## PillarA from the settle point, so the straight-line hand-anchor path the
## kinematic endpoint takes necessarily crosses straight through the pillar's
## real rect. Measures every physics tick, no settle window, starting from
## the instant of the teleport.

const PRE_TELEPORT_SETTLE_TICKS: int = 360  ## 6s -- past the documented
## ~4-5s idle-collapse convergence window, so the PRE-teleport chain state is
## a genuine, confirmed-converged rest configuration, not itself mid-transient.
const POST_TELEPORT_SAMPLE_TICKS: int = 300  ## 5s, no settle skip at all --
## every single tick from the instant of teleport is sampled.


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	var main_scene: Node = load("res://scenes/main.tscn").instantiate()
	add_child(main_scene)
	for i in 5:
		await get_tree().physics_frame

	var pillar: Node = main_scene.get_node("PillarA")
	var rect: Rect2 = pillar.get_rect_2d()
	print("[TELEPORT-DRAG] PillarA rect=%s" % [rect])

	GameManager.current_state = GameManager.RoundState.PLAYING

	# Spawn FAR from PillarA, on its southwest side.
	var start_pos := Vector3(rect.position.x - 6.0, 0.7, rect.position.y - 6.0)
	var player_scene: PackedScene = load("res://scenes/player.tscn")
	var player = player_scene.instantiate()
	add_child(player)
	player.global_position = start_pos
	player.spawn_pos = start_pos
	player.aim_dir = Vector2(0, 1)
	for i in 5:
		await get_tree().physics_frame

	print("[TELEPORT-DRAG] pre-settle: letting chain fully converge near the hand at start_pos=%s..." % [start_pos])
	for i in PRE_TELEPORT_SETTLE_TICKS:
		await get_tree().physics_frame

	var hand0: Vector3 = player._get_rope_hand_anchor_pos()
	var pre_max_reach: float = 0.0
	for seg in player._physics_rope_segments:
		var sp: Vector3 = (seg as RigidBody3D).global_position
		pre_max_reach = maxf(pre_max_reach, Vector2(hand0.x, hand0.z).distance_to(Vector2(sp.x, sp.z)))
	print("[TELEPORT-DRAG] pre-teleport confirmed chain state: max_seg_reach_from_hand=%.4f (should be small/collapsed, matching test_rope_physics_chain_settle.gd's own ~1.35 idle-collapse finding)" % pre_max_reach)

	# THE TELEPORT: exactly mirrors reset_for_round()/​_respawn()'s own real
	# mechanism -- a bare global_position write, nothing else touched. Target
	# is on PillarA's OPPOSITE (northeast) side -- the straight hand-anchor
	# path from start_pos to here necessarily crosses the pillar's real rect.
	var end_pos := Vector3(rect.end.x + 6.0, 0.7, rect.end.y + 6.0)
	player.global_position = end_pos
	print("[TELEPORT-DRAG] TELEPORT at this tick: %s -> %s (straight path crosses PillarA rect=%s)" % [start_pos, end_pos, rect])

	var max_pen: float = 0.0
	var worst_tick: int = -1
	var worst_pos: Vector2 = Vector2.ZERO
	var first_pen_tick: int = -1
	var last_pen_tick: int = -1
	for tick in range(POST_TELEPORT_SAMPLE_TICKS):
		await get_tree().physics_frame
		var hand: Vector3 = player._get_rope_hand_anchor_pos()
		var max_reach: float = 0.0
		var tick_pen: float = 0.0
		for seg in player._physics_rope_segments:
			var sp: Vector3 = (seg as RigidBody3D).global_position
			var p2 := Vector2(sp.x, sp.z)
			max_reach = maxf(max_reach, Vector2(hand.x, hand.z).distance_to(p2))
			if rect.has_point(p2):
				var pen: float = minf(p2.x - rect.position.x, rect.end.x - p2.x)
				pen = minf(pen, minf(p2.y - rect.position.y, rect.end.y - p2.y))
				tick_pen = maxf(tick_pen, pen)
				if pen > max_pen:
					max_pen = pen
					worst_tick = tick
					worst_pos = p2
		if tick_pen > 0.001:
			if first_pen_tick < 0:
				first_pen_tick = tick
			last_pen_tick = tick
		if tick < 30 or tick % 15 == 0:
			print("[TELEPORT-DRAG] tick=%d hand=(%.2f,%.2f) max_seg_reach_from_hand=%.3f tick_pillar_pen=%.4f" % [
				tick, hand.x, hand.z, max_reach, tick_pen])

	print("[TELEPORT-DRAG] RESULT max_pillar_pen=%.4f at tick=%d pos=%s" % [max_pen, worst_tick, worst_pos])
	print("[TELEPORT-DRAG] penetration window: first_tick=%d last_tick=%d (span=%d ticks, ~%.2fs)" % [
		first_pen_tick, last_pen_tick,
		(last_pen_tick - first_pen_tick + 1) if first_pen_tick >= 0 else 0,
		float(last_pen_tick - first_pen_tick + 1) / 60.0 if first_pen_tick >= 0 else 0.0])
	if max_pen > 0.001:
		print("[TELEPORT-DRAG] CONFIRMED: a real reset_for_round()/_respawn()-style teleport drags the existing physics chain straight through a real obstacle's collision rect.")
	else:
		print("[TELEPORT-DRAG] NOT REPRODUCED this run: chain avoided the pillar despite the teleport.")

	print("TELEPORT_CHAIN_DRAG_TEST_DONE")
