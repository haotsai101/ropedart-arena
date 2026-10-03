extends Node
## End-to-end test for RelayMultiplayerPeer + the signaling server's binary
## relay. Needs a running server and three Godot processes (one host, two
## guests) -- tests/run_relay_test.sh orchestrates all of that; run it rather
## than this scene directly.
##
## Checks, from each process's own point of view:
##   host:   sees both guests connect; receives a reliable RPC from each.
##   guests: see the host connect; get the host's broadcast RPC; get the OTHER
##           guest's broadcast RPC (guest -> host -> guest via SceneMultiplayer
##           server relay); get an unreliable_ordered RPC from the host.
##
## Command-line user args (after `--`):
##   --role=host|guest  --url=ws://127.0.0.1:PORT  --code-file=/path/to/file

const TIMEOUT_SEC := 20.0

var _role := ""
var _url := ""
var _code_file := ""
var _elapsed := 0.0
var _done := false

var _connected_peers: Dictionary = {}
var _got_from: Dictionary = {}         # sender peer_id -> true (reliable hellos)
var _got_host_broadcast := false
var _got_unreliable := false
var _host_sent := false


func _ready() -> void:
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--role="):
			_role = arg.get_slice("=", 1)
		elif arg.begins_with("--url="):
			_url = arg.substr(6)
		elif arg.begins_with("--code-file="):
			_code_file = arg.substr(12)
	NetworkManager.set_signaling_url(_url)
	NetworkManager.connection_failed.connect(func(reason: String): _finish(false, "connection_failed: " + reason))
	multiplayer.peer_connected.connect(_on_peer_connected)
	if _role == "host":
		NetworkManager.connected_to_room.connect(_on_host_room_created)
		NetworkManager.create_room(3, 0, 0)
	else:
		_try_join()


func _try_join() -> void:
	# Wait for the host to publish its room code.
	while not FileAccess.file_exists(_code_file) or FileAccess.get_file_as_string(_code_file).strip_edges() == "":
		await get_tree().create_timer(0.1).timeout
	NetworkManager.join_room(FileAccess.get_file_as_string(_code_file).strip_edges())


func _on_host_room_created(code: String, _peer_id: int) -> void:
	var f := FileAccess.open(_code_file, FileAccess.WRITE)
	f.store_string(code)
	f.close()


func _on_peer_connected(peer_id: int) -> void:
	_connected_peers[peer_id] = true
	if _role == "guest":
		# Give the other guest a moment to join before broadcasting so it
		# receives this (a broadcast only reaches peers present at send time).
		await get_tree().create_timer(1.5).timeout
		_rpc_hello.rpc_id(1, multiplayer.get_unique_id())
		_rpc_guest_broadcast.rpc(multiplayer.get_unique_id())


func _process(delta: float) -> void:
	if _done:
		return
	_elapsed += delta
	if _role == "host" and not _host_sent and _connected_peers.size() >= 2:
		_host_sent = true
		await get_tree().create_timer(0.5).timeout
		_rpc_host_broadcast.rpc()
		for i in 5:
			_rpc_unreliable.rpc(i)
	_check_done()
	if not _done and _elapsed > TIMEOUT_SEC:
		_finish(false, "timeout -- state: %s" % _state_str())


func _check_done() -> void:
	if _role == "host":
		if _connected_peers.size() >= 2 and _got_from.size() >= 2:
			# Linger so outgoing broadcasts drain before we disconnect.
			_done = true
			await get_tree().create_timer(3.0).timeout
			_finish(true, _state_str())
	else:
		if _connected_peers.has(1) and _got_host_broadcast and _got_unreliable and _got_from.size() >= 1:
			_finish(true, _state_str())


func _state_str() -> String:
	return "id=%d peers=%s hellos_from=%s host_bcast=%s unreliable=%s" % [
		multiplayer.get_unique_id(), _connected_peers.keys(), _got_from.keys(),
		_got_host_broadcast, _got_unreliable]


func _finish(ok: bool, detail: String) -> void:
	_done = true
	print("[relay test %s] %s -- %s" % [_role, "PASS" if ok else "FAIL", detail])
	NetworkManager.disconnect_from_room()
	get_tree().quit(0 if ok else 1)


@rpc("any_peer", "call_remote", "reliable")
func _rpc_hello(sender_id: int) -> void:
	if multiplayer.get_remote_sender_id() == sender_id:
		_got_from[sender_id] = true


@rpc("any_peer", "call_remote", "reliable")
func _rpc_guest_broadcast(sender_id: int) -> void:
	# Guests record the OTHER guest's broadcast (relayed through the host).
	if _role == "guest" and multiplayer.get_remote_sender_id() == sender_id:
		_got_from[sender_id] = true


@rpc("authority", "call_remote", "reliable")
func _rpc_host_broadcast() -> void:
	_got_host_broadcast = true


@rpc("authority", "call_remote", "unreliable_ordered")
func _rpc_unreliable(_i: int) -> void:
	_got_unreliable = true
