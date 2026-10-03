extends Node
## End-to-end online MATCH test: a host and a guest Godot process play a real
## 2-player match through the local signaling/relay server, driving the
## guest with injected key events. Checks the host-authoritative sync path:
##   A: both peers reach PLAYING (ready handshake + round reset/countdown).
##   B: guest movement input moves the guest's player on the host, and the
##      guest renders it where the host has it.
##   C: guest's spawn protection expires on the host (guest becomes hittable).
##   D: guest Slash (melee input) costs the host's player a life, seen on
##      both peers.
##   E: guest throw (hold + release) puts the guest's dart in flight on the
##      host, and the guest sees its own dart leave its hand.
##   F: guest eliminates the host's player -> round ends with the guest's win
##      on both peers -> the next round resets lives/visibility on both.
##   G: host quits mid-match -> the guest is returned to the lobby scene.
##
## Run via tests/run_online_match_test.sh (starts the server + both peers).
## User args: --role=host|guest --url=ws://... --code-file=/path
##            [--total=N]  (default 2; N > 2 adds host-simulated bots -- a
##            smoke mode, since bots can legitimately disturb B-F's checks)
##
## The test scene's own root is replaced by change_scene_to_file() when the
## match loads, so the real driver is re-parented under /root (same path on
## both peers, which its RPCs rely on).

const TIMEOUT_SEC := 45.0
const MAP := "res://scenes/main.tscn"


func _ready() -> void:
	var driver := Driver.new()
	driver.name = "OnlineMatchDriver"
	get_tree().root.add_child.call_deferred(driver)


class Driver extends Node:
	var role := ""
	var url := ""
	var code_file := ""
	var total := 2
	var elapsed := 0.0
	var results: Array = []
	var failed := false
	var _started_match := false
	var _script_running := false
	# Guest-side observations of its own dart, reported back to the host.
	var guest_seen_dart_states: Dictionary = {}
	var _guest_report: Dictionary = {}
	var _expect_host_drop := false

	func _ready() -> void:
		for arg: String in OS.get_cmdline_user_args():
			if arg.begins_with("--role="):
				role = arg.get_slice("=", 1)
			elif arg.begins_with("--url="):
				url = arg.substr(6)
			elif arg.begins_with("--code-file="):
				code_file = arg.substr(12)
			elif arg.begins_with("--total="):
				total = int(arg.get_slice("=", 1))
		NetworkManager.set_signaling_url(url)
		NetworkManager.connection_failed.connect(func(r: String): _finish(false, "connection_failed: " + r))
		NetworkManager.game_starting.connect(_on_game_starting)
		if role == "host":
			NetworkManager.connected_to_room.connect(func(code: String, _id: int):
				var f := FileAccess.open(code_file, FileAccess.WRITE)
				f.store_string(code)
				f.close())
			multiplayer.peer_connected.connect(func(_id: int):
				await get_tree().create_timer(0.5).timeout
				NetworkManager.send_start_game())
			NetworkManager.create_room(total, 0, 0)
		else:
			while not FileAccess.file_exists(code_file) or FileAccess.get_file_as_string(code_file).strip_edges() == "":
				await get_tree().create_timer(0.1).timeout
			NetworkManager.join_room(FileAccess.get_file_as_string(code_file).strip_edges())

	# Same steps lobby.gd's _start_online_game() takes, minus the UI.
	func _on_game_starting() -> void:
		if _started_match:
			return
		_started_match = true
		GameManager.is_online = true
		GameManager.total_players = total
		GameManager.bot_difficulty = 0
		GameManager.human_count = NetworkManager.room_players.size()
		GameManager.lobby_mode = false
		GameManager.selected_map_scene = MAP
		GameManager.set_online_slots(NetworkManager.room_players)
		GameManager.assign_default_characters(hash(NetworkManager.room_code) & 0x7fffffff)
		get_tree().change_scene_to_file(MAP)
		GameManager.call_deferred("_init_game")

	func _process(delta: float) -> void:
		elapsed += delta
		if elapsed > TIMEOUT_SEC and not failed:
			_finish(false, "timeout -- results so far: %s" % [results])
		if role == "guest" and GameManager._all_players.size() >= 2:
			var me = GameManager._all_players[1]
			if is_instance_valid(me) and is_instance_valid(me.dart):
				guest_seen_dart_states[me.dart.state] = true
		if _expect_host_drop and get_tree().current_scene != null \
				and get_tree().current_scene.scene_file_path == "res://scenes/lobby.tscn":
			_expect_host_drop = false
			print("[online match test] G: PASS -- guest returned to lobby after host drop (is_online=%s)" % GameManager.is_online)
			_finish(not GameManager.is_online, "G")
		if role == "host" and not _script_running and GameManager.current_state == GameManager.RoundState.PLAYING:
			_script_running = true
			_run_host_script()

	func _check(label: String, ok: bool, detail: String) -> void:
		results.append("%s:%s" % [label, "PASS" if ok else "FAIL"])
		print("[online match test] %s: %s -- %s" % [label, "PASS" if ok else "FAIL", detail])
		if not ok:
			failed = true

	func _wait(sec: float) -> void:
		await get_tree().create_timer(sec).timeout

	func _run_host_script() -> void:
		var host_p = GameManager._all_players[0]
		var guest_p = GameManager._all_players[1]
		_check("A", true, "host reached PLAYING; guest peer ids %s" % [GameManager.online_slot_peers])
		await _ask_guest_report()
		_check("A2", _guest_report.get("state", -1) == GameManager.RoundState.PLAYING,
			"guest round state %s" % _guest_report.get("state", -1))

		# C first: protection must have expired before the guest can be moved/hit.
		await _wait(1.6)
		_check("C", not guest_p.is_dead, "guest is_dead on host after 1.6s of PLAYING: %s" % guest_p.is_dead)

		# B: movement
		var start: Vector3 = guest_p.global_position
		_rpc_press.rpc(KEY_D, 0.5)
		await _wait(1.0)
		var moved: float = start.distance_to(guest_p.global_position)
		await _ask_guest_report()
		var guest_view: Vector3 = _guest_report.get("guest_pos", Vector3.ZERO)
		var view_err: float = guest_view.distance_to(guest_p.global_position)
		_check("B", moved > 1.0 and view_err < 0.3,
			"guest moved %.2f on host; guest renders it %.3f away from host" % [moved, view_err])

		# D: guest Slash on the host's player
		guest_p.global_position = host_p.global_position + Vector3(1.2, 0.0, 0.0)
		var host_lives: int = host_p.lives
		await _wait(0.3)
		_rpc_press.rpc(KEY_E, 0.1)
		await _wait(0.6)
		await _ask_guest_report()
		_check("D", host_p.lives == host_lives - 1 and int(_guest_report.get("host_lives", -1)) == host_p.lives,
			"host player lives %d -> %d on host, %d on guest" % [host_lives, host_p.lives, int(_guest_report.get("host_lives", -1))])

		# E: guest throw
		var seen_on_host: Dictionary = {}
		_rpc_press.rpc(KEY_SPACE, 0.4)
		var t := 0.0
		while t < 1.5:
			seen_on_host[guest_p.dart.state] = true
			await get_tree().physics_frame
			t += get_physics_process_delta_time()
		await _ask_guest_report()
		var flying: int = 2  # rope_dart.gd State.FLYING
		var guest_seen: Array = _guest_report.get("dart_states", [])
		_check("E", seen_on_host.has(flying) and guest_seen.has(flying),
			"guest dart states on host %s, on guest %s" % [seen_on_host.keys(), guest_seen])

		# F: elimination -> round end -> next round
		guest_p.dart.force_holster()
		host_p.lives = 1
		await _wait(1.3)  # host player's respawn protection from D expires
		guest_p.global_position = host_p.global_position + Vector3(1.2, 0.0, 0.0)
		await _wait(0.3)
		_rpc_press.rpc(KEY_E, 0.1)
		await _wait(0.8)
		await _ask_guest_report()
		var guest_wins: Dictionary = _guest_report.get("round_wins", {})
		_check("F1", host_p.is_eliminated and bool(_guest_report.get("host_eliminated", false)) \
				and int(guest_wins.get(1, 0)) == 1,
			"host player eliminated on host=%s guest=%s; guest round_wins %s" % [
				host_p.is_eliminated, _guest_report.get("host_eliminated", "?"), guest_wins])
		var waited := 0.0
		while GameManager.current_state != GameManager.RoundState.COUNTDOWN and waited < 6.0:
			await _wait(0.1)
			waited += 0.1
		await _wait(0.5)
		await _ask_guest_report()
		_check("F2", host_p.lives == GameManager.lives_per_round \
				and int(_guest_report.get("host_lives", -1)) == GameManager.lives_per_round \
				and bool(_guest_report.get("host_mesh_visible", false)),
			"next round: host player lives %d on host, %s on guest, mesh visible on guest %s" % [
				host_p.lives, _guest_report.get("host_lives", "?"), _guest_report.get("host_mesh_visible", "?")])

		# G: host drops without warning (guest checks it lands in the lobby)
		_rpc_expect_host_drop.rpc()
		await _wait(0.5)
		_finish(not failed, "results %s" % [results])

	func _ask_guest_report() -> void:
		_guest_report = {}
		_rpc_request_report.rpc()
		var waited := 0.0
		while _guest_report.is_empty() and waited < 3.0:
			await _wait(0.05)
			waited += 0.05

	@rpc("authority", "call_remote", "reliable")
	func _rpc_press(keycode: int, duration: float) -> void:
		var ev := InputEventKey.new()
		ev.keycode = keycode
		ev.pressed = true
		Input.parse_input_event(ev)
		await _wait(duration)
		var up := InputEventKey.new()
		up.keycode = keycode
		up.pressed = false
		Input.parse_input_event(up)

	@rpc("authority", "call_remote", "reliable")
	func _rpc_request_report() -> void:
		var report := {"state": GameManager.current_state}
		if GameManager._all_players.size() >= 2:
			report["guest_pos"] = GameManager._all_players[1].global_position
			report["host_lives"] = GameManager._all_players[0].lives
			report["host_eliminated"] = GameManager._all_players[0].is_eliminated
			report["host_mesh_visible"] = GameManager._all_players[0].player_mesh.visible
		report["round_wins"] = GameManager.round_wins
		report["dart_states"] = guest_seen_dart_states.keys()
		_rpc_report.rpc_id(1, report)

	@rpc("any_peer", "call_remote", "reliable")
	func _rpc_report(report: Dictionary) -> void:
		_guest_report = report

	@rpc("authority", "call_remote", "reliable")
	func _rpc_expect_host_drop() -> void:
		_expect_host_drop = true

	func _finish(ok: bool, detail: String) -> void:
		print("[online match test %s] %s -- %s" % [role, "PASS" if ok else "FAIL", detail])
		get_tree().quit(0 if ok else 1)
