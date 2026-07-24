extends Node
## Regression probe for the "crack the whip" spawn-time resonance this
## project has hit (and fixed) multiple times across its history -- see
## CLAUDE.md's player.gd section, "UNSPOOL WHIPLASH FIX" / "GROWING-LEASH
## FIX" entries. Every dynamic segment of the thrown-rope physics chain is
## spawned BUNCHED near the hand (player.gd's ROPE_BUNCH_SPACING), leaving a
## real, simultaneous positional violation at every joint at throw-instant;
## an unmitigated solver can propagate that into a large multi-tick overshoot
## (previously measured at ~4x the chain's own physical length) before
## settling.
##
## No permanent regression test for THIS specific failure mode existed in
## tests/ before this round -- every prior round's own verification was a
## temporary, throwaway per-tick probe (per this project's own established
## convention, see CLAUDE.md), never checked in. Added now specifically
## because the 2026-07-24 "core simulation only" experiment removes both
## mitigations that were added to fix this (rope_segment_body.gd's
## MAX_SEGMENT_SPEED clamp and the growing-leash max_reach_from_hand clamp),
## so this failure mode needs a way to be checked again in the future without
## re-deriving a probe from scratch.
##
## Deterministically forces an ordinary unobstructed throw (no pillar
## involved -- isolates the spawn-time solver behavior from any
## obstacle-contact interaction) and samples, every physics tick for the
## first SAMPLE_TICKS ticks:
##   - real_dist: the actual, already-known hand-to-dart distance (a smooth,
##     non-explosive kinematic quantity -- the dart's own travel_speed is
##     bounded, see rope_dart.gd).
##   - chain_reach: the farthest any dynamic segment or the tip anchor
##     currently sits from the hand anchor, in the XZ plane.
## A genuine "crack the whip" resonance reads as chain_reach spiking to many
## times real_dist within the first several ticks, then decaying back down
## over the following ~20-30 ticks (the historical signature, per CLAUDE.md).
##
## Run via the Godot MCP run_project tool with
## scene=res://tests/test_rope_spawn_whiplash.tscn.

const SAMPLE_TICKS: int = 60  ## ~1s at 60Hz -- comfortably covers the
## historically-observed decay window (~20-30 ticks) with margin.
## Historical baseline (8 segments, WITH the now-removed MAX_SEGMENT_SPEED +
## growing-leash clamps): chain_reach never exceeded the chain's own total
## capacity (DART_ROPE_LENGTH, 8.0) by more than a small settling margin.
## Anything reaching several multiples of DART_ROPE_LENGTH is the historical
## "crack the whip" failure signature reappearing.
const DART_ROPE_LENGTH: float = 8.0
const EXPLOSION_THRESHOLD: float = DART_ROPE_LENGTH * 2.0


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
	add_child(player)

	# Open ground, well clear of any obstacle -- isolates spawn-time solver
	# behavior from obstacle-contact interaction (that's covered separately
	# by tests/test_rope_obstacle_clip.gd).
	player.global_position = Vector3(5.0, GameManager.PLAYER_HALF_HEIGHT, 5.0)
	player.spawn_pos = player.global_position
	player.aim_dir = Vector2(1, 0)
	for i in 5:
		await get_tree().physics_frame

	# Full-charge throw -- fastest dart travel_speed (see rope_dart.gd), the
	# most demanding case for the kinematic tip anchor's own per-tick pull on
	# the freshly-bunched chain.
	player._throw(1.0)
	if player.dart == null:
		print("[TEST] FAIL: throw produced no dart")
		return

	var max_chain_reach: float = 0.0
	var max_real_dist: float = 0.0
	var max_ratio: float = 0.0
	var worst_tick: int = -1

	for tick in range(SAMPLE_TICKS):
		await get_tree().physics_frame
		if player.dart == null:
			print("[TEST] tick=%d dart already returned/anchored-and-gone -- stopping early" % [tick])
			break

		var hand_pos: Vector3 = player._get_rope_hand_anchor_pos()
		var tip_pos: Vector3 = player._get_rope_tip_target()
		var hand_2d := Vector2(hand_pos.x, hand_pos.z)
		var tip_2d := Vector2(tip_pos.x, tip_pos.z)
		var real_dist: float = hand_2d.distance_to(tip_2d)

		var chain_reach: float = tip_2d.distance_to(hand_2d)
		for seg in player._physics_rope_segments:
			var p3: Vector3 = (seg as RigidBody3D).global_position
			var p2d := Vector2(p3.x, p3.z)
			chain_reach = maxf(chain_reach, hand_2d.distance_to(p2d))

		max_chain_reach = maxf(max_chain_reach, chain_reach)
		max_real_dist = maxf(max_real_dist, real_dist)
		var ratio: float = chain_reach / maxf(real_dist, 0.01)
		if ratio > max_ratio:
			max_ratio = ratio
			worst_tick = tick

		if tick % 3 == 0 or chain_reach > EXPLOSION_THRESHOLD:
			print("[TEST] tick=%d real_dist=%.3f chain_reach=%.3f ratio=%.2f" % [
				tick, real_dist, chain_reach, ratio])

	print("[TEST] RESULT max_chain_reach=%.3f max_real_dist=%.3f max_ratio=%.2f (worst tick=%d) DART_ROPE_LENGTH=%.1f" % [
		max_chain_reach, max_real_dist, max_ratio, worst_tick, DART_ROPE_LENGTH])
	if max_chain_reach > EXPLOSION_THRESHOLD:
		print("[TEST] FAIL: chain_reach exceeded %.1f (2x DART_ROPE_LENGTH) -- crack-the-whip resonance reproduced" % [EXPLOSION_THRESHOLD])
	else:
		print("[TEST] PASS: chain_reach stayed within a reasonable multiple of DART_ROPE_LENGTH -- no runaway resonance observed")
	print("SPAWN_WHIPLASH_TEST_DONE")
