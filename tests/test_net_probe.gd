extends Node
## Network measurement probe: one host + N guests play a real online match
## through the signaling/relay server while every process records its
## connection metrics, then dumps them as JSON for analysis
## (tests/analyze_net_probe.py). Not a pass/fail test.
##
## Phases (host-driven, broadcast by RPC once the host reaches PLAYING):
##   idle    -- nobody touches input: baseline traffic + ping RTT
##   latency -- each guest repeatedly taps a move key and times how long until
##              the host's snapshot shows its own player moving (no client-side
##              prediction exists, so this is the real input-to-screen delay)
##   chaos   -- every player mashes random move/aim/throw/melee/dash input
##   finish  -- everyone writes its JSON and quits
##
## Recorded per process: timeline of connection milestones, RPC ping RTT +
## one-way delays (all processes share one machine clock), per-mode relay
## traffic, snapshot/input inter-arrival times, WebSocket outbound backlog,
## frames dropped by the relay peer, and FPS.
##
## User args: --role=host|guest --url=ws(s)://... --code-file=/path
##            --out=/dir [--total=4] [--idle=10] [--latency=25] [--chaos=40]

const MAP := "res://scenes/main.tscn"
const TIMEOUT_SEC := 240.0


func _ready() -> void:
	var driver := Driver.new()
	driver.name = "NetProbeDriver"
	get_tree().root.add_child.call_deferred(driver)


## RelayMultiplayerPeer that also counts every frame it sends and receives.
class StatsRelay extends RelayMultiplayerPeer:
	var sent := {}             # mode -> [frames, bytes]
	var recv := {}             # "peer:mode" -> [frames, bytes]
	var arrivals := {}         # "peer:mode" -> [[t_usec, size], ...] (unreliable only)
	var sends_unreliable: Array = []  # [t_usec, size, target_peer]
	var dropped_unknown_peer := 0

	func receive_frame(frame: PackedByteArray) -> void:
		if frame.size() >= HEADER_SIZE:
			var from: int = frame.decode_s32(0)
			if not _remote_peers.has(from):
				dropped_unknown_peer += 1
			else:
				# Raw game packets are keyed by NetCodec packet type instead of
				# transfer mode: "1:raw1" = snapshot, "1:raw2" = own-state,
				# "N:raw3" = input.
				var key := "%d:%d" % [from, frame[4]]
				if frame[5] == RAW_CHANNEL and frame.size() > HEADER_SIZE:
					key = "%d:raw%d" % [from, frame[HEADER_SIZE]]
				var c: Array = recv.get(key, [0, 0])
				c[0] += 1
				c[1] += frame.size()
				recv[key] = c
				if frame[4] != TRANSFER_MODE_RELIABLE:
					if not arrivals.has(key):
						arrivals[key] = []
					arrivals[key].append([Time.get_ticks_usec(), frame.size()])
		super.receive_frame(frame)

	func _send_frame(target: int, mode: int, channel: int, payload: PackedByteArray) -> Error:
		var key: Variant = mode
		var kind := "rpc"
		if channel == RAW_CHANNEL and payload.size() > 0:
			kind = "raw%d" % payload[0]
			key = kind
		var c: Array = sent.get(key, [0, 0])
		c[0] += 1
		c[1] += payload.size() + HEADER_SIZE
		sent[key] = c
		if mode != TRANSFER_MODE_RELIABLE:
			sends_unreliable.append([Time.get_ticks_usec(), payload.size() + HEADER_SIZE, target, kind])
		return super._send_frame(target, mode, channel, payload)


class Driver extends Node:
	var role := ""
	var url := ""
	var code_file := ""
	var out_dir := ""
	var total := 4
	var phase_len := {"idle": 10.0, "latency": 25.0, "chaos": 40.0}

	var relay: StatsRelay = null
	var t0_usec := 0
	var timeline: Array = []          # [label, ms since start, unix_ms]
	var phase := "join"
	var phase_marks: Array = []       # [phase, t_usec]
	var pings: Array = []             # guest: [seq, rtt_ms, oneway_up_ms, oneway_down_ms, phase]
	var ping_arrivals: Dictionary = {}  # host: peer -> [[oneway_ms, phase], ...]
	var latency_trials: Array = []    # guest: [ms or -1, phase]
	var outbound_max := 0
	var outbound_samples: Array = []  # [t_usec, bytes] every ~100ms
	var fps_samples: Array = []
	var state_changes: Array = []
	var input_queue_samples: Array = []  # host: [t_usec, peer, queued inputs] every ~100ms
	var _ping_seq := 0
	var _ping_sent: Dictionary = {}
	var _ping_accum := 0.0
	var _sample_accum := 0.0
	var _started_match := false
	var _ready_peers := {}
	var _host_script_started := false
	var _chaos_keys: Array = []
	var _finished := false
	var elapsed := 0.0

	func _ready() -> void:
		t0_usec = Time.get_ticks_usec()
		for arg: String in OS.get_cmdline_user_args():
			var v := arg.get_slice("=", 1)
			if arg.begins_with("--role="): role = v
			elif arg.begins_with("--url="): url = arg.substr(6)
			elif arg.begins_with("--code-file="): code_file = arg.substr(12)
			elif arg.begins_with("--out="): out_dir = arg.substr(6)
			elif arg.begins_with("--total="): total = int(v)
			elif arg.begins_with("--idle="): phase_len["idle"] = float(v)
			elif arg.begins_with("--latency="): phase_len["latency"] = float(v)
			elif arg.begins_with("--chaos="): phase_len["chaos"] = float(v)
		_mark("start")
		NetworkManager.set_signaling_url(url)
		NetworkManager.connection_failed.connect(func(r: String):
			_mark("connection_failed: " + r)
			_finish())
		NetworkManager.connected_to_room.connect(_on_connected_to_room)
		NetworkManager.game_starting.connect(_on_game_starting)
		GameManager.state_changed.connect(func(s: int): state_changes.append([s, _ms()]))
		if role == "host":
			multiplayer.peer_connected.connect(_on_host_peer_connected)
			NetworkManager.create_room(total, 0, 0)
		else:
			while not FileAccess.file_exists(code_file) or FileAccess.get_file_as_string(code_file).strip_edges() == "":
				await get_tree().create_timer(0.05).timeout
			_mark("code_read")
			NetworkManager.join_room(FileAccess.get_file_as_string(code_file).strip_edges())

	func _ms() -> float:
		return (Time.get_ticks_usec() - t0_usec) / 1000.0

	func _mark(label: String) -> void:
		timeline.append([label, _ms(), Time.get_unix_time_from_system() * 1000.0])

	# Swap NetworkManager's relay for the counting subclass. Runs synchronously
	# inside the "created"/"joined" handler, so no relay frame can be missed.
	func _on_connected_to_room(code: String, peer_id: int) -> void:
		_mark("room_ready")
		relay = StatsRelay.new()
		relay.setup(NetworkManager._ws, peer_id, peer_id == 1)
		relay.raw_packet.connect(NetworkManager._on_relay_raw_packet)
		NetworkManager._relay = relay
		multiplayer.multiplayer_peer = relay
		if peer_id != 1:
			relay.add_remote_peer(1)
		else:
			var f := FileAccess.open(code_file, FileAccess.WRITE)
			f.store_string(code)
			f.close()

	func _on_host_peer_connected(id: int) -> void:
		_mark("peer_connected_%d" % id)
		if multiplayer.get_peers().size() >= total - 1:
			_mark("all_peers_connected")
			await get_tree().create_timer(0.5).timeout
			NetworkManager.send_start_game()

	func _on_game_starting() -> void:
		if _started_match:
			return
		_started_match = true
		_mark("game_starting")
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
		if elapsed > TIMEOUT_SEC and not _finished:
			_mark("timeout")
			_finish()
			return
		if NetworkManager._ws != null and NetworkManager._ws_open and not _has_mark("ws_open"):
			_mark("ws_open")
		if not _has_mark("scene_built") and GameManager._all_players.size() == total:
			_mark("scene_built")
		if relay != null and not _has_mark("first_unreliable_rx") and not relay.arrivals.is_empty():
			_mark("first_unreliable_rx")
		if GameManager.current_state == GameManager.RoundState.PLAYING and not _has_mark("playing"):
			_mark("playing")
		if NetworkManager._ws != null:
			var ob: int = NetworkManager._ws.get_current_outbound_buffered_amount()
			outbound_max = maxi(outbound_max, ob)
		_sample_accum += delta
		if _sample_accum >= 0.1:
			_sample_accum = 0.0
			if NetworkManager._ws != null:
				outbound_samples.append([Time.get_ticks_usec(), NetworkManager._ws.get_current_outbound_buffered_amount()])
			fps_samples.append(Engine.get_frames_per_second())
			if role == "host":
				for p in GameManager._all_players:
					if is_instance_valid(p) and not p.is_bot and p.player_peer_id != 1:
						input_queue_samples.append([Time.get_ticks_usec(), p.player_peer_id, p._net_queue.size()])
		# Guests ping the host 4x/s from the moment they're in the room.
		if role == "guest" and relay != null and phase != "finish":
			_ping_accum += delta
			if _ping_accum >= 0.25:
				_ping_accum = 0.0
				_ping_seq += 1
				_ping_sent[_ping_seq] = Time.get_ticks_usec()
				_rpc_ping.rpc_id(1, _ping_seq, Time.get_unix_time_from_system() * 1000.0)
		if role == "host" and not _host_script_started and GameManager.current_state == GameManager.RoundState.PLAYING:
			_host_script_started = true
			_run_host_script()

	func _has_mark(label: String) -> bool:
		for m: Array in timeline:
			if m[0] == label:
				return true
		return false

	# --- phase control (host) ------------------------------------------------

	func _run_host_script() -> void:
		for p: String in ["idle", "latency", "chaos"]:
			_rpc_phase.rpc(p)
			_enter_phase(p)
			await get_tree().create_timer(phase_len[p]).timeout
		_rpc_phase.rpc("finish")
		_enter_phase("finish")
		await get_tree().create_timer(3.0).timeout  # let guests flush + write
		_finish()

	@rpc("authority", "call_remote", "reliable")
	func _rpc_phase(p: String) -> void:
		_enter_phase(p)

	func _enter_phase(p: String) -> void:
		phase = p
		phase_marks.append([p, Time.get_ticks_usec()])
		_mark("phase_" + p)
		_release_all()
		match p:
			"latency":
				if role == "guest":
					_run_latency_trials()
			"chaos":
				_run_chaos()
			"finish":
				if role == "guest":
					await get_tree().create_timer(1.0).timeout
					_finish()

	# --- input injection -----------------------------------------------------

	func _key(code: int, pressed: bool) -> void:
		var ev := InputEventKey.new()
		ev.keycode = code
		ev.physical_keycode = code
		ev.pressed = pressed
		Input.parse_input_event(ev)

	func _release_all() -> void:
		for k: int in [KEY_W, KEY_A, KEY_S, KEY_D, KEY_SPACE, KEY_E, KEY_SHIFT]:
			_key(k, false)

	func _my_player() -> Node:
		return GameManager._find_player_by_peer(NetworkManager.my_peer_id if role == "guest" else 1)

	func _run_latency_trials() -> void:
		var dir_keys := [KEY_D, KEY_A, KEY_S, KEY_W]
		var i := 0
		# Stagger guests so their trials don't all line up on the same ticks.
		await get_tree().create_timer(0.1 * NetworkManager.my_peer_id).timeout
		while phase == "latency":
			var me = _my_player()
			if me == null or me.is_dead or me.is_eliminated or GameManager.current_state != GameManager.RoundState.PLAYING:
				await get_tree().create_timer(0.2).timeout
				continue
			await get_tree().create_timer(0.5).timeout  # settle
			if phase != "latency":
				break
			# Every third trial is a Slash, every third a throw (see
			# _action_trial()); the rest time movement.
			if i % 3 == 1:
				i += 1
				await _action_trial(me, "slash")
				continue
			if i % 3 == 2:
				i += 1
				await _action_trial(me, "throw")
				continue
			# Two clocks per trial: "shown" = our body moves on this screen
			# (client-side prediction), "confirmed" = the host's state for us
			# moves (input -> host -> back; what everyone else sees).
			var base_confirmed: Vector3 = me._net_target_pos
			var base_shown: Vector3 = me.global_position
			var key: int = dir_keys[i % dir_keys.size()]
			i += 1
			var t_press := Time.get_ticks_usec()
			_key(key, true)
			var got := -1.0
			var shown := -1.0
			while Time.get_ticks_usec() - t_press < 1_500_000:
				await get_tree().process_frame
				if not is_instance_valid(me):
					break
				var now_ms := (Time.get_ticks_usec() - t_press) / 1000.0
				if shown < 0.0 and me.global_position.distance_to(base_shown) > 0.02:
					shown = now_ms
				if got < 0.0 and me._net_target_pos.distance_to(base_confirmed) > 0.02:
					got = now_ms
				if got >= 0.0 and shown >= 0.0:
					break
			_key(key, false)
			latency_trials.append([got, phase, shown, "move"])
			await get_tree().create_timer(0.3).timeout

	## Time from the input to the guest SEEING the action: slash = our swing
	## animation starts; throw = on release, our dart leaves the hand (FLYING).
	## Records [-1, phase, shown_ms, kind].
	func _action_trial(me, kind: String) -> void:
		if me.dart == null or me.dart.state != 0:  # need the dart holstered
			await get_tree().create_timer(0.3).timeout
			return
		var t0 := 0
		var shown := -1.0
		if kind == "slash":
			await get_tree().create_timer(0.45).timeout  # melee cooldown
			t0 = Time.get_ticks_usec()
			_key(KEY_E, true)
			while Time.get_ticks_usec() - t0 < 1_500_000:
				await get_tree().process_frame
				if me._combat_anim_active:
					shown = (Time.get_ticks_usec() - t0) / 1000.0
					break
			_key(KEY_E, false)
		else:
			_key(KEY_SPACE, true)
			await get_tree().create_timer(0.25).timeout
			t0 = Time.get_ticks_usec()
			_key(KEY_SPACE, false)
			while Time.get_ticks_usec() - t0 < 1_500_000:
				await get_tree().process_frame
				if me.dart.state == 2:  # FLYING
					shown = (Time.get_ticks_usec() - t0) / 1000.0
					break
			# recall it and wait until it's back in hand
			await get_tree().create_timer(0.3).timeout
			_key(KEY_SPACE, true)
			await get_tree().create_timer(0.05).timeout
			_key(KEY_SPACE, false)
			var t1 := Time.get_ticks_usec()
			while me.dart.state != 0 and Time.get_ticks_usec() - t1 < 3_000_000:
				await get_tree().process_frame
		latency_trials.append([-1.0, phase, shown, kind])
		await get_tree().create_timer(0.3).timeout

	func _run_chaos() -> void:
		var rng := RandomNumberGenerator.new()
		rng.seed = hash(role) + NetworkManager.my_peer_id
		var keys := [KEY_W, KEY_A, KEY_S, KEY_D]
		while phase == "chaos":
			_release_all()
			# 1-2 movement keys, sometimes an action
			_key(keys[rng.randi() % 4], true)
			if rng.randf() < 0.5:
				_key(keys[rng.randi() % 4], true)
			var r := rng.randf()
			if r < 0.25:
				_key(KEY_SPACE, true)
			elif r < 0.4:
				_key(KEY_E, true)
			elif r < 0.5:
				_key(KEY_SHIFT, true)
			await get_tree().create_timer(rng.randf_range(0.15, 0.6)).timeout
		_release_all()

	# --- ping ----------------------------------------------------------------

	@rpc("any_peer", "call_remote", "reliable")
	func _rpc_ping(seq: int, sent_unix_ms: float) -> void:
		var now := Time.get_unix_time_from_system() * 1000.0
		var from := multiplayer.get_remote_sender_id()
		if not ping_arrivals.has(from):
			ping_arrivals[from] = []
		ping_arrivals[from].append([now - sent_unix_ms, phase])
		_rpc_pong.rpc_id(from, seq, sent_unix_ms, now)

	@rpc("authority", "call_remote", "reliable")
	func _rpc_pong(seq: int, sent_unix_ms: float, host_rx_unix_ms: float) -> void:
		var now := Time.get_unix_time_from_system() * 1000.0
		if not _ping_sent.has(seq):
			return
		var rtt: float = (Time.get_ticks_usec() - int(_ping_sent[seq])) / 1000.0
		_ping_sent.erase(seq)
		pings.append([seq, rtt, host_rx_unix_ms - sent_unix_ms, now - host_rx_unix_ms, phase])

	# --- output --------------------------------------------------------------

	func _finish() -> void:
		if _finished:
			return
		_finished = true
		_mark("finish")
		var marks := {}
		for m: Array in phase_marks:
			marks[m[0]] = m[1]
		var data := {
			"role": role,
			"peer_id": NetworkManager.my_peer_id if role == "guest" else 1,
			"url": url,
			"t0_usec": t0_usec,
			"timeline": timeline,
			"phase_marks_usec": marks,
			"state_changes": state_changes,
			"input_queue_samples": input_queue_samples,
			"pings": pings,
			"ping_arrivals": ping_arrivals,
			"latency_trials": latency_trials,
			"outbound_max": outbound_max,
			"outbound_samples": outbound_samples,
			"fps_samples": fps_samples,
			"physics_tps": Engine.physics_ticks_per_second,
			"pings_unanswered": _ping_sent.size(),
		}
		var me = _my_player()
		if role == "guest" and me != null and is_instance_valid(me):
			data["pred_corrections"] = me.pred_corrections
			data["pred_dart_corrections"] = me.pred_dart_corrections
		if relay != null:
			data["sent"] = relay.sent
			data["recv"] = relay.recv
			data["arrivals"] = relay.arrivals
			data["sends_unreliable"] = relay.sends_unreliable
			data["dropped_unknown_peer"] = relay.dropped_unknown_peer
		var path := "%s/%s_%d.json" % [out_dir, role, data["peer_id"]]
		var f := FileAccess.open(path, FileAccess.WRITE)
		f.store_string(JSON.stringify(data))
		f.close()
		print("[net probe %s] wrote %s" % [role, path])
		get_tree().quit(0)
