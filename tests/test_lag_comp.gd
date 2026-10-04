extends Node
## Lag compensation check: does the host hit-test a guest's attacks against
## where that guest SAW its targets?
##
## The host's own player runs left/right (injected keys) for a few seconds.
## Every physics tick the guest reports [its newest input seq, where it
## renders the host's player]. Whenever the host simulates that guest's
## input `seq`, it records GameManager.hit_test_pos(host player, guest player)
## -- what a dart/slash from the guest would be tested against -- and the
## host player's current (un-rewound) position. Comparing both with what the
## guest saw for that same seq gives the error with and without rewinding.
##
## Run via tests/run_lag_comp_test.sh [ws(s)://url]. PASS when the rewound
## error p50 is under 0.25 units and well below the un-rewound error.

const MAP := "res://scenes/main.tscn"
const MOVE_SEC := 4.0


func _ready() -> void:
	var driver := Driver.new()
	driver.name = "LagCompDriver"
	get_tree().root.add_child.call_deferred(driver)


class Driver extends Node:
	var role := ""
	var url := ""
	var code_file := ""
	var _started := false
	var _measuring := false
	var _seen_by_seq := {}       # host: guest seq -> guest-rendered host pos
	var _host_by_seq := {}       # host: guest seq -> [rewound pos, current pos]
	var _elapsed := 0.0

	func _ready() -> void:
		for arg: String in OS.get_cmdline_user_args():
			if arg.begins_with("--role="):
				role = arg.get_slice("=", 1)
			elif arg.begins_with("--url="):
				url = arg.substr(6)
			elif arg.begins_with("--code-file="):
				code_file = arg.substr(12)
		NetworkManager.set_signaling_url(url)
		NetworkManager.game_starting.connect(_on_game_starting)
		NetworkManager.host_disconnected.connect(func(): get_tree().quit(0))
		if role == "host":
			NetworkManager.connected_to_room.connect(func(code: String, _id: int):
				var f := FileAccess.open(code_file, FileAccess.WRITE)
				f.store_string(code)
				f.close())
			multiplayer.peer_connected.connect(func(_id: int):
				await get_tree().create_timer(0.5).timeout
				NetworkManager.send_start_game())
			NetworkManager.create_room(2, 0, 0)
		else:
			while not FileAccess.file_exists(code_file) or FileAccess.get_file_as_string(code_file).strip_edges() == "":
				await get_tree().create_timer(0.1).timeout
			NetworkManager.join_room(FileAccess.get_file_as_string(code_file).strip_edges())

	func _on_game_starting() -> void:
		if _started:
			return
		_started = true
		GameManager.is_online = true
		GameManager.total_players = 2
		GameManager.bot_difficulty = 0
		GameManager.human_count = NetworkManager.room_players.size()
		GameManager.lobby_mode = false
		GameManager.selected_map_scene = MAP
		GameManager.set_online_slots(NetworkManager.room_players)
		GameManager.assign_default_characters(hash(NetworkManager.room_code) & 0x7fffffff)
		get_tree().change_scene_to_file(MAP)
		GameManager.call_deferred("_init_game")

	func _physics_process(delta: float) -> void:
		_elapsed += delta
		if _elapsed > 60.0:
			print("[lag comp test %s] FAIL -- timeout" % role)
			get_tree().quit(1)
		if GameManager._all_players.size() < 2:
			return
		var host_p = GameManager._all_players[0]
		var guest_p = GameManager._all_players[1]
		if role == "guest" and GameManager.current_state == GameManager.RoundState.PLAYING:
			_rpc_seen.rpc_id(1, guest_p._pred_seq, host_p.get_pos_2d())
		if role != "host":
			return
		if GameManager.current_state == GameManager.RoundState.PLAYING and not _measuring and not guest_p.is_dead:
			_measuring = true
			_run_host()
		if _measuring:
			var seq: int = guest_p._net_ack_seq
			if seq > 0 and not _host_by_seq.has(seq):
				_host_by_seq[seq] = [GameManager.hit_test_pos(host_p, guest_p), host_p.get_pos_2d()]

	@rpc("any_peer", "call_remote", "unreliable_ordered")
	func _rpc_seen(seq: int, pos: Vector2) -> void:
		_seen_by_seq[seq] = pos

	func _key(code: int, pressed: bool) -> void:
		var ev := InputEventKey.new()
		ev.keycode = code
		ev.physical_keycode = code
		ev.pressed = pressed
		Input.parse_input_event(ev)

	func _run_host() -> void:
		await get_tree().create_timer(1.5).timeout  # let spawn protection end
		_seen_by_seq.clear()
		_host_by_seq.clear()
		var t := 0.0
		var key := KEY_D
		while t < MOVE_SEC:
			_key(key, true)
			await get_tree().create_timer(0.6).timeout
			_key(key, false)
			key = KEY_A if key == KEY_D else KEY_D
			t += 0.6
		await get_tree().create_timer(0.5).timeout
		var rewound: Array = []
		var current: Array = []
		for seq: int in _host_by_seq:
			if _seen_by_seq.has(seq):
				var seen: Vector2 = _seen_by_seq[seq]
				rewound.append(seen.distance_to(_host_by_seq[seq][0]))
				current.append(seen.distance_to(_host_by_seq[seq][1]))
		rewound.sort()
		current.sort()
		if rewound.size() < 30:
			print("[lag comp test] FAIL -- only %d matched samples" % rewound.size())
			get_tree().quit(1)
			return
		var p50r: float = rewound[rewound.size() / 2]
		var p90r: float = rewound[int(rewound.size() * 0.9)]
		var p50c: float = current[current.size() / 2]
		var p90c: float = current[int(current.size() * 0.9)]
		var ok: bool = p50r < 0.25 and p50r < p50c * 0.5
		print("[lag comp test] %s -- target error vs what the guest saw (n=%d): rewound p50 %.3f p90 %.3f | not rewound p50 %.3f p90 %.3f" % [
			"PASS" if ok else "FAIL", rewound.size(), p50r, p90r, p50c, p90c])
		get_tree().quit(0 if ok else 1)
