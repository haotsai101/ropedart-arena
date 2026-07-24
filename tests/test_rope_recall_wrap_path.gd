extends Node
## Regression test for the "walk-to-pickup after a corner wrap should retrace
## the rope, not teleport" feature (real user request: "When the character
## walks around the pillar to pickup the dagger, the dagger should follow the
## rope and go back in a loop"). See CLAUDE.md's own entry for this round.
##
## Two scenarios, deterministically forced instead of relying on random bot
## play:
##
## SCENARIO A (path fidelity): throw a dart, force it ANCHORED on the FAR
## side of a real pillar from the player, let the physics chain settle into a
## genuinely wrapped shape (same setup as test_rope_leash_corner_wrap.gd's own
## settle phase), then call recall() directly -- equivalent to the player
## pressing throw-again, and exactly what rope_dart.gd's ANCHORED branch now
## also does internally on walk-to-pickup (see rope_dart.gd). Player stays
## stationary throughout so the measurement isolates the retrieval mechanism
## itself from _clamp_to_rope_leash()'s own (unrelated, already-tested)
## behavior. Measures every few ticks:
##   - dev_from_path: how far the dart's own head_2d strays from player.gd's
##     live rope polyline (hand -> every dynamic segment) -- by construction
##     (_advance_along_path_2d() always places head_2d ON one of the path's
##     own segments) this should stay ~0.
##   - pillar_pen: whether the dart's head_2d itself ever enters PillarA's
##     collision rect -- a straight-line-through-the-obstacle regression
##     would show up here.
##
## SCENARIO B (walk-to-pickup wiring): a second, unobstructed player+dart
## pair -- no pillar involved -- confirms rope_dart.gd's ANCHORED branch
## actually routes a walk-up pickup through RECALLING (and that player.gd's
## _is_recalling sync picks it up) rather than regressing to an instant grab,
## and that it still completes (dart returns) in the trivial short-rope case.
##
## Run via the Godot MCP run_project tool with
## scene=res://tests/test_rope_recall_wrap_path.tscn.

const SETTLE_WAIT_TICKS: int = 90  ## matches test_rope_leash_corner_wrap.gd's own settle phase
const MAX_RETRIEVAL_TICKS: int = 300  ## ~5s at 60Hz -- generous upper bound
const MAX_ACCEPTABLE_PATH_DEV: float = 1.0


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	var main_scene: Node = load("res://scenes/main.tscn").instantiate()
	add_child(main_scene)
	for i in 5:
		await get_tree().physics_frame

	GameManager.current_state = GameManager.RoundState.PLAYING

	var scenario_a_ok: bool = await _run_scenario_a(main_scene)
	var scenario_b_ok: bool = await _run_scenario_b()

	print("[TEST] OVERALL %s" % ("PASS" if (scenario_a_ok and scenario_b_ok) else "FAIL"))
	print("ROPE_RECALL_WRAP_TEST_DONE")


func _run_scenario_a(main_scene: Node) -> bool:
	print("[TEST] --- SCENARIO A: wrap-path fidelity during RECALLING ---")
	var pillar: Node = main_scene.get_node("PillarA")
	var rect: Rect2 = pillar.get_rect_2d()
	print("[TEST] PillarA rect=%s (world XZ)" % [rect])

	var player_scene: PackedScene = load("res://scenes/player.tscn")
	var player = player_scene.instantiate()
	add_child(player)

	var near_corner: Vector2 = rect.position
	var far_corner: Vector2 = rect.end
	player.global_position = Vector3(near_corner.x - 1.2, GameManager.PLAYER_HALF_HEIGHT, near_corner.y - 1.2)
	player.spawn_pos = player.global_position
	player.aim_dir = Vector2(-1, -1).normalized()
	for i in 5:
		await get_tree().physics_frame

	player._throw(0.0)
	for i in 5:
		await get_tree().physics_frame
	if player.dart == null:
		print("[TEST] FAIL: throw produced no dart")
		return false

	player.dart.state = 1  # State.ANCHORED (see rope_dart.gd's enum)
	var anchor: Vector2 = far_corner + Vector2(1.2, 1.2)
	player.dart.head_2d = anchor
	print("[TEST] hand=%s anchor=%s beeline_dist=%.2f" % [
		player.get_pos_2d(), anchor, player.get_pos_2d().distance_to(anchor)])

	# Settle phase: hold the player stationary while the chain pays out and
	# wraps the corner on its own.
	for tick in range(SETTLE_WAIT_TICKS):
		await get_tree().physics_frame

	var wrapped_len: float = _chain_path_length_2d(player)
	var beeline: float = player.get_pos_2d().distance_to(anchor)
	print("[TEST] after %d-tick settle: wrapped_chain_len=%.2f beeline=%.2f" % [
		SETTLE_WAIT_TICKS, wrapped_len, beeline])
	if wrapped_len < beeline + 1.0:
		print("[TEST] WARNING: chain doesn't read as meaningfully wrapped -- test may not exercise the real scenario")

	# Trigger retrieval directly via recall() -- equivalent to a throw-again
	# press, and exactly what rope_dart.gd's ANCHORED branch now also invokes
	# internally on walk-to-pickup. Player stays stationary throughout, so
	# this isolates the retrieval path-following mechanism itself.
	player.dart.recall()
	print("[TEST] recall() called; player remains stationary at %s" % [player.get_pos_2d()])

	var picked_up: bool = false
	var saw_recalling_state: bool = false
	var saw_is_recalling_sync: bool = false
	var max_path_dev: float = 0.0
	var max_pillar_pen: float = 0.0

	for tick in range(MAX_RETRIEVAL_TICKS):
		if player.dart == null:
			picked_up = true
			print("[TEST] tick=%d dart picked up (dart == null)" % tick)
			break
		if player.dart.state == 2:  # State.RECALLING
			saw_recalling_state = true
			if player._is_recalling:
				saw_is_recalling_sync = true
			var head_2d: Vector2 = player.dart.head_2d
			var polyline: Array = player.get_rope_polyline_2d()
			var dev: float = _point_to_polyline_dist(head_2d, polyline)
			max_path_dev = maxf(max_path_dev, dev)
			if rect.has_point(head_2d):
				var pen: float = minf(head_2d.x - rect.position.x, rect.end.x - head_2d.x)
				pen = minf(pen, minf(head_2d.y - rect.position.y, rect.end.y - head_2d.y))
				max_pillar_pen = maxf(max_pillar_pen, pen)
			if tick % 10 == 0:
				var full_path: Array = polyline.duplicate()
				full_path.append(head_2d)
				var remaining: float = 0.0
				for i in range(full_path.size() - 1):
					remaining += (full_path[i] as Vector2).distance_to(full_path[i + 1] as Vector2)
				print("[TEST] tick=%d dart.state=%d head_2d=%s dev_from_path=%.3f remaining_path_len=%.3f is_recalling=%s recall_phase=%d" % [
					tick, player.dart.state, head_2d, dev, remaining, player._is_recalling, player._recall_anim_phase])
		await get_tree().physics_frame

	print("[TEST] SCENARIO A RESULT picked_up=%s saw_recalling_state=%s is_recalling_sync=%s max_path_dev=%.3f max_pillar_pen=%.4f" % [
		picked_up, saw_recalling_state, saw_is_recalling_sync, max_path_dev, max_pillar_pen])

	var ok: bool = true
	if not picked_up:
		print("[TEST] FAIL(A): dart never returned within %d ticks" % MAX_RETRIEVAL_TICKS)
		ok = false
	if not saw_recalling_state:
		print("[TEST] FAIL(A): dart never entered RECALLING")
		ok = false
	if not saw_is_recalling_sync:
		print("[TEST] FAIL(A): player._is_recalling never synced true during RECALLING -- recall animation would not play")
		ok = false
	if max_pillar_pen > 0.001:
		print("[TEST] FAIL(A): dart's return path entered PillarA's collision rect (cut through the obstacle)")
		ok = false
	if max_path_dev > MAX_ACCEPTABLE_PATH_DEV:
		print("[TEST] FAIL(A): dart strayed more than %.1f units from the rope's own live control-point path" % MAX_ACCEPTABLE_PATH_DEV)
		ok = false
	if ok:
		print("[TEST] PASS(A): dart retraced the rope's live (wrap-aware) path back into the hand")
	return ok


func _run_scenario_b() -> bool:
	print("[TEST] --- SCENARIO B: walk-to-pickup routes through RECALLING (unobstructed) ---")
	var player_scene: PackedScene = load("res://scenes/player.tscn")
	var player = player_scene.instantiate()
	add_child(player)
	player.global_position = Vector3(0.0, GameManager.PLAYER_HALF_HEIGHT, 0.0)
	player.spawn_pos = player.global_position
	player.aim_dir = Vector2(1, 0)
	for i in 5:
		await get_tree().physics_frame

	player._throw(0.0)
	for i in 5:
		await get_tree().physics_frame
	if player.dart == null:
		print("[TEST] FAIL(B): throw produced no dart")
		return false

	# Force a short, unobstructed anchor right next to the player -- well
	# within pickup_radius -- so the very next physics tick's ANCHORED
	# proximity check fires.
	player.dart.state = 1  # State.ANCHORED
	player.dart.head_2d = player.get_pos_2d() + Vector2(0.3, 0.0)
	print("[TEST] player=%s dart anchored at=%s (pickup_radius=%.2f)" % [
		player.get_pos_2d(), player.dart.head_2d, player.dart.pickup_radius])

	var saw_recalling_state: bool = false
	var picked_up: bool = false
	for tick in range(120):
		if player.dart == null:
			picked_up = true
			print("[TEST] tick=%d dart picked up (dart == null)" % tick)
			break
		if player.dart.state == 2:
			saw_recalling_state = true
		await get_tree().physics_frame

	print("[TEST] SCENARIO B RESULT picked_up=%s saw_recalling_state=%s" % [picked_up, saw_recalling_state])
	var ok: bool = true
	if not picked_up:
		print("[TEST] FAIL(B): dart never returned")
		ok = false
	if not saw_recalling_state:
		print("[TEST] FAIL(B): walk-to-pickup regressed to an instant grab -- never observed RECALLING")
		ok = false
	if ok:
		print("[TEST] PASS(B): walking within pickup_radius routed through RECALLING and completed")
	return ok


func _chain_path_length_2d(player) -> float:
	var hand_pos: Vector3 = player._get_rope_hand_anchor_pos()
	var tip_pos: Vector3 = player._get_rope_tip_target()
	var hand_2d := Vector2(hand_pos.x, hand_pos.z)
	var tip_2d := Vector2(tip_pos.x, tip_pos.z)
	if player._physics_rope_segments.is_empty():
		return hand_2d.distance_to(tip_2d)
	var total: float = 0.0
	var prev: Vector2 = hand_2d
	for seg in player._physics_rope_segments:
		var p3: Vector3 = (seg as RigidBody3D).global_position
		var p2d := Vector2(p3.x, p3.z)
		total += prev.distance_to(p2d)
		prev = p2d
	total += prev.distance_to(tip_2d)
	return total


func _point_to_polyline_dist(point: Vector2, polyline: Array) -> float:
	if polyline.is_empty():
		return 0.0
	if polyline.size() < 2:
		return point.distance_to(polyline[0])
	var best: float = INF
	for i in range(polyline.size() - 1):
		best = minf(best, _seg_dist(point, polyline[i], polyline[i + 1]))
	return best


func _seg_dist(p: Vector2, a: Vector2, b: Vector2) -> float:
	var ab := b - a
	var len_sq := ab.length_squared()
	if len_sq < 0.0001:
		return p.distance_to(a)
	var t: float = clampf((p - a).dot(ab) / len_sq, 0.0, 1.0)
	return p.distance_to(a + t * ab)
