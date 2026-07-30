extends Node
## Focused follow-up to test_real_game_loop_penetration_audit.gd's own
## surprising early-tick (tick~18, during COUNTDOWN, before any bot can
## legally throw) penetration finding -- prints full per-player diagnostic
## state every tick for the first 120 ticks so the actual mechanism can be
## identified precisely instead of guessed at.

const OBS_MARGIN: float = 0.0


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	var main_scene: Node = load("res://scenes/main.tscn").instantiate()
	add_child(main_scene)
	for i in 5:
		await get_tree().physics_frame

	var obstacles: Array = []
	for o in get_tree().get_nodes_in_group("obstacles"):
		obstacles.append({"name": String(o.name), "rect": o.get_rect_2d()})
	for o in obstacles:
		print("[DBG] obstacle %s rect=%s" % [o["name"], o["rect"]])

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
	for p in players:
		print("[DBG] player_index=%d spawn=%s is_bot=%s" % [p.player_index, p.get_pos_2d(), p.is_bot])

	for tick in range(120):
		await get_tree().physics_frame
		var line: String = "[DBG] tick=%d state=%d" % [tick, GameManager.current_state]
		for p in players:
			if not is_instance_valid(p):
				continue
			line += " | P%d pos=%s dart=%s active=%s" % [
				p.player_index, p.get_pos_2d(),
				("null" if p.dart == null else str(p.dart.state)),
				p._physics_rope_active]
			if p._physics_rope_active and p._physics_rope_hand_anchor != null and p._physics_rope_tip_anchor != null:
				var hand: Vector3 = p._physics_rope_hand_anchor.global_position
				var tip: Vector3 = p._physics_rope_tip_anchor.global_position
				var max_reach: float = 0.0
				var worst_seg_pos: Vector3 = hand
				for seg in p._physics_rope_segments:
					var sp: Vector3 = (seg as RigidBody3D).global_position
					var d: float = Vector2(hand.x, hand.z).distance_to(Vector2(sp.x, sp.z))
					if d > max_reach:
						max_reach = d
						worst_seg_pos = sp
				line += " hand=(%.2f,%.2f) tip=(%.2f,%.2f) max_seg_reach_from_hand=%.3f worst_seg=(%.2f,%.2f)" % [
					hand.x, hand.z, tip.x, tip.z, max_reach, worst_seg_pos.x, worst_seg_pos.z]
				for o in obstacles:
					var rect: Rect2 = o["rect"]
					if rect.has_point(Vector2(worst_seg_pos.x, worst_seg_pos.z)):
						line += " <<< WORST_SEG_INSIDE_%s" % o["name"]
		print(line)

	print("DEBUG_EARLY_PENETRATION_DONE")
