extends Node
## ROUND 22 (2026-07-29) NEW -- direct regression/characterization test for
## the "let it be dragged around the character" requirement (per direct user
## instruction: "Let's try fixed rope length, no damping and folding or
## coiling. let it be dragged around the character."). See player.gd's
## _make_rope_tip_body() / _update_physics_rope_anchors() for the mechanism:
## the chain's tip end is now UNFROZEN into a real dynamic RigidBody3D while
## dart == null (idle), instead of being kinematically forced to the hand's
## own position every tick (the old ROUND 12 behavior, which is what forced
## the now-rejected tight fold/coil -- both ends pinned to literally the same
## point every frame has nowhere to go but bunch up there).
##
## This test measures, with real logged per-tick data (not eyeballing a
## recording), whether that architecture change actually produces a
## plausible "drag" -- a real trailing lag behind the moving hand, growing
## and settling like a real dragged rope, staying BOUNDED the whole time --
## rather than either (a) silently staying frozen/glued to the hand (the
## thing this round explicitly removed) or (b) diverging without limit (a
## genuine physics instability, the risk flagged by this round's own task).
##
## TWO PHASES:
##  1. SETTLE: player spawns and holds completely still for SETTLE_TICKS.
##     Diagnostic only (not pass/fail) -- separately documents how far the
##     freed tip drifts from the hand from residual spawn-time relaxation
##     alone, with ZERO player movement involved, so that number is never
##     confused with "real dragging caused by movement" in the WALK phase
##     below. See this round's own CLAUDE.md entry for the full, disclosed
##     analysis of this idle-drift number (it is real and larger than a
##     player might expect from "at rest", independent of movement).
##  2. WALK: player holds a real KEY_D (east) input via
##     Input.parse_input_event() for WALK_TICKS (~4s), driving the actual
##     unmodified _get_move_input()/_physics_process() pipeline -- logs the
##     hand-to-tip lag distance and every segment's own max reach from the
##     hand every tick. PASS requires (a) a real, nonzero trailing lag
##     actually appears (proves the tip isn't just sitting glued to the hand
##     under a different name) and (b) every measured quantity stays under
##     SANE_BOUND (proves it's a bounded drag, not a divergence).
##
## Run via the Godot MCP run_project tool, or headless:
## Godot --headless --path . res://tests/test_rope_idle_drag.tscn
## scene=res://tests/test_rope_idle_drag.tscn.

const SETTLE_TICKS: int = 60   ## ~1s -- lets the initial spawn-time bunch
## layout's own tiny release transient (see this file's own header comment)
## mostly play out before the WALK phase starts, so the WALK phase's own
## lag measurement is attributable to movement, not leftover spawn settling.
const WALK_TICKS: int = 240    ## ~4s of continuous walking
const SAMPLE_EVERY: int = 20
const SANE_BOUND: float = 20.0 ## generous -- total chain capacity is
## DART_ROPE_LENGTH (7.2 at the time this test was written); anything far
## past this is a real, unbounded divergence, not a plausible dragged shape.
const MIN_REAL_LAG: float = 0.05 ## a trailing lag must exceed this to count
## as "a real drag happened," not just numerical noise around zero.


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	var main_scene: Node = load("res://scenes/main.tscn").instantiate()
	add_child(main_scene)
	for i in 5:
		await get_tree().physics_frame

	GameManager.current_state = GameManager.RoundState.PLAYING

	var player_scene: PackedScene = load("res://scenes/player.tscn")
	var player = player_scene.instantiate()
	player.player_index = 0
	player.is_bot = false
	add_child(player)
	player.global_position = Vector3(0.0, GameManager.PLAYER_HALF_HEIGHT, 0.0)
	player.spawn_pos = player.global_position
	player.aim_dir = Vector2(0, -1)
	for i in 5:
		await get_tree().physics_frame

	print("[TEST] --- PHASE 1: SETTLE (no input, %d ticks) ---" % SETTLE_TICKS)
	for tick in range(SETTLE_TICKS):
		await get_tree().physics_frame

	var hand0: Vector3 = player._get_rope_hand_anchor_pos()
	var tip0: Vector3 = player._physics_rope_tip_anchor.global_position
	var settle_dist: float = Vector2(hand0.x, hand0.z).distance_to(Vector2(tip0.x, tip0.z))
	print("[TEST] post-settle (diagnostic only, no player movement involved): hand=%s tip=%s hand_to_tip_dist=%.4f" % [
		hand0, tip0, settle_dist])

	print("[TEST] --- PHASE 2: WALK (real KEY_D held, %d ticks) ---" % WALK_TICKS)
	var key_down := InputEventKey.new()
	key_down.keycode = KEY_D
	key_down.physical_keycode = KEY_D
	key_down.pressed = true
	Input.parse_input_event(key_down)

	var max_lag: float = 0.0
	var max_reach_any_seg: float = 0.0
	var bounded_ok := true
	var start_player_pos: Vector2 = player.get_pos_2d()
	for tick in range(WALK_TICKS):
		await get_tree().physics_frame
		var hand_pos: Vector3 = player._get_rope_hand_anchor_pos()
		var hand_2d := Vector2(hand_pos.x, hand_pos.z)
		var tip_pos: Vector3 = player._physics_rope_tip_anchor.global_position
		var tip_2d := Vector2(tip_pos.x, tip_pos.z)
		var lag: float = hand_2d.distance_to(tip_2d)
		max_lag = maxf(max_lag, lag)
		for seg in player._physics_rope_segments:
			var p3: Vector3 = (seg as RigidBody3D).global_position
			max_reach_any_seg = maxf(max_reach_any_seg, hand_2d.distance_to(Vector2(p3.x, p3.z)))
		if lag > SANE_BOUND or max_reach_any_seg > SANE_BOUND:
			bounded_ok = false
		if tick % SAMPLE_EVERY == 0:
			print("[TEST] walk tick=%d player_pos=%s hand=%s tip_lag=%.4f max_seg_reach=%.4f" % [
				tick, player.get_pos_2d(), hand_2d, lag, max_reach_any_seg])

	var walked_dist: float = start_player_pos.distance_to(player.get_pos_2d())
	print("[TEST] SUMMARY: walked_dist=%.4f max_tip_lag=%.4f max_seg_reach_from_hand=%.4f sane_bound=%.1f" % [
		walked_dist, max_lag, max_reach_any_seg, SANE_BOUND])

	var drags_not_frozen: bool = max_lag > MIN_REAL_LAG
	print("[TEST] %s: tip %s a real trailing lag behind the moving hand (max_lag=%.4f vs min=%.2f)" % [
		"PASS" if drags_not_frozen else "FAIL",
		"shows" if drags_not_frozen else "does NOT show",
		max_lag, MIN_REAL_LAG])
	print("[TEST] %s: every measured quantity stayed bounded under sane_bound=%.1f (no divergence)" % [
		"PASS" if bounded_ok else "FAIL", SANE_BOUND])

	var overall_ok: bool = drags_not_frozen and bounded_ok
	print("[TEST] OVERALL %s" % ("PASS" if overall_ok else "FAIL"))
	print("ROPE_IDLE_DRAG_TEST_DONE")
