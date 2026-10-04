extends Node
## Signaling + relay autoload. Access globally as "NetworkManager".
## Owns the single WebSocket connection to the signaling server. Text frames on
## it are JSON room/lobby signaling; binary frames are Godot high-level
## multiplayer traffic tunneled through the server by RelayMultiplayerPeer (see
## that class's header for why this replaced direct WebRTC), so RPC and
## MultiplayerSynchronizer work transparently once a room is created/joined.

signal connected_to_room(code: String, peer_id: int)
signal guest_joined(peer_id: int)
signal peer_disconnected(peer_id: int)
signal connection_failed(reason: String)
signal player_list_updated(players: Array)   # Array of {username, peer_id} Dicts
signal settings_updated(settings: Dictionary)
signal game_starting
signal host_disconnected
signal rooms_fetched(rooms: Array)           # Array of room Dicts from /rooms
signal character_chosen(peer_id: int, char_id: String)
signal headwear_chosen(peer_id: int, headwear_id: String)
signal cloth_chosen(peer_id: int, cloth_id: String)
signal color_chosen(peer_id: int, color_index: int)  # mascot body color (MASCOT_COLORS index)
signal mask_chosen(peer_id: int, mask_id: String)    # mascot mask (MASK_PATTERNS id)
## Raw game packet (NetCodec) from a room peer -- see send_game_packet().
signal game_packet(from: int, data: PackedByteArray)

const MAX_PLAYERS := 6

var is_host := false
var my_peer_id := 0
var room_code := ""
var room_settings: Dictionary = {"max_players": 4, "bot_difficulty": 0, "map_id": 0}
var room_players: Array = []   # [{username, peer_id}]
var peer_characters: Dictionary = {}   # peer_id (int) → character id (String)
var peer_headwear: Dictionary = {}     # peer_id (int) → headwear id (String), "" = native
var peer_cloth: Dictionary = {}        # peer_id (int) → cloth id (String), "" = native
var peer_colors: Dictionary = {}       # peer_id (int) → MASCOT_COLORS index (int)
var peer_masks: Dictionary = {}        # peer_id (int) → MASK_PATTERNS id (String)

var _signaling_url := "wss://ropedart-arena.onrender.com"

var _ws: WebSocketPeer = null
var _ws_open := false
var _ws_was_open := false
var _pending_send: Array = []

## WebSocket buffer sizes -- the defaults (64 KiB) are sized for signaling
## only; game traffic from up to MAX_PLAYERS synchronizers + RPCs can burst
## past that on a slow frame.
const WS_BUFFER_SIZE := 1 << 20

var _relay: RelayMultiplayerPeer = null

var _http: HTTPRequest = null


func set_signaling_url(url: String) -> void:
	_signaling_url = url


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

func create_room(max_players: int = 4, bot_difficulty: int = 0, map_id: int = 0) -> void:
	is_host = true
	my_peer_id = 1
	room_settings = {"max_players": max_players, "bot_difficulty": bot_difficulty, "map_id": map_id}
	_connect_signaling()
	# Queue create message — will be sent in _flush_pending after WS opens
	_pending_send.append(JSON.stringify({
		"type": "create",
		"max_players": max_players,
		"bot_difficulty": bot_difficulty,
		"map_id": map_id,
		"version": GameVersion.VERSION,
	}))


func join_room(code: String) -> void:
	is_host = false
	room_code = code.to_upper()
	_connect_signaling()
	_pending_send.append(JSON.stringify({"type": "join", "code": room_code, "version": GameVersion.VERSION}))


func disconnect_from_room() -> void:
	if _ws != null:
		_ws.close()
		_ws = null
	_ws_open = false
	_ws_was_open = false
	_pending_send.clear()
	_close_relay()
	is_host = false
	my_peer_id = 0
	room_code = ""
	room_players.clear()
	room_settings = {"max_players": 4, "bot_difficulty": 0, "map_id": 0}
	peer_characters.clear()
	peer_headwear.clear()
	peer_cloth.clear()
	peer_colors.clear()
	peer_masks.clear()
	multiplayer.multiplayer_peer = null


func update_settings(max_players: int, bot_difficulty: int, map_id: int = 0) -> void:
	_send_signal({"type": "update_settings", "max_players": max_players, "bot_difficulty": bot_difficulty, "map_id": map_id})
	room_settings = {"max_players": max_players, "bot_difficulty": bot_difficulty, "map_id": map_id}


func send_start_game() -> void:
	_send_signal({"type": "start_game"})


func send_character_choice(char_id: String) -> void:
	## Broadcast local player's character pick to all peers in the room.
	## Stores locally immediately; remote peers receive it if the server relays it.
	peer_characters[my_peer_id] = char_id
	emit_signal("character_chosen", my_peer_id, char_id)
	_send_signal({"type": "character_choice", "char_id": char_id})


func send_headwear_choice(headwear_id: String) -> void:
	## Same pattern as send_character_choice(), for the headwear slot.
	peer_headwear[my_peer_id] = headwear_id
	emit_signal("headwear_chosen", my_peer_id, headwear_id)
	_send_signal({"type": "headwear_choice", "headwear_id": headwear_id})


func send_cloth_choice(cloth_id: String) -> void:
	## Same pattern as send_character_choice(), for the cloth/cape slot.
	peer_cloth[my_peer_id] = cloth_id
	emit_signal("cloth_chosen", my_peer_id, cloth_id)
	_send_signal({"type": "cloth_choice", "cloth_id": cloth_id})


func send_color_choice(color_index: int) -> void:
	## Same pattern as send_character_choice(), for the mascot's body color.
	peer_colors[my_peer_id] = color_index
	emit_signal("color_chosen", my_peer_id, color_index)
	_send_signal({"type": "color_choice", "color_index": color_index})


func send_mask_choice(mask_id: String) -> void:
	## Same pattern as send_character_choice(), for the mascot's mask pattern.
	peer_masks[my_peer_id] = mask_id
	emit_signal("mask_chosen", my_peer_id, mask_id)
	_send_signal({"type": "mask_choice", "mask_id": mask_id})


func fetch_rooms() -> void:
	if _http == null:
		_http = HTTPRequest.new()
		add_child(_http)
		_http.request_completed.connect(_on_rooms_fetched)
	var base_url: String = _signaling_url.replace("wss://", "https://").replace("ws://", "http://")
	_http.request(base_url + "/rooms")


# ---------------------------------------------------------------------------
# Internal — signaling WebSocket
# ---------------------------------------------------------------------------

func _connect_signaling() -> void:
	_ws = WebSocketPeer.new()
	_ws.inbound_buffer_size = WS_BUFFER_SIZE
	_ws.outbound_buffer_size = WS_BUFFER_SIZE
	_ws_open = false
	var err := _ws.connect_to_url(_signaling_url)
	if err != OK:
		emit_signal("connection_failed", "Could not connect to signaling server (err %d)" % err)
		_ws = null


func _send_signal(obj: Dictionary) -> void:
	var text := JSON.stringify(obj)
	if _ws == null:
		return
	if _ws_open:
		_ws.send_text(text)
	else:
		_pending_send.append(text)


func _flush_pending() -> void:
	# Always send username first so the server registers it before create/join
	_ws.send_text(JSON.stringify({"type": "set_username", "username": UsernameManager.username}))
	for text: String in _pending_send:
		_ws.send_text(text)
	_pending_send.clear()


# ---------------------------------------------------------------------------
# _process — poll the WS every frame
# ---------------------------------------------------------------------------

## Frame alignment (each misplaced poll cost a whole frame per hop -- measured
## ~50ms of RTT on a 0.4ms-ping local server):
##   - physics runs first: read the socket and dispatch RPCs right away, so a
##     guest input / host snapshot reaches the players in THIS tick instead of
##     waiting for SceneTree's own multiplayer poll in the next _process.
##   - _process runs last (process_priority): polling the socket there flushes
##     everything queued during this frame's physics/process to the wire.
func _ready() -> void:
	process_physics_priority = -100
	process_priority = 100


func _physics_process(_delta: float) -> void:
	_poll_socket()
	if _relay != null:
		multiplayer.poll()


func _process(_delta: float) -> void:
	_poll_socket()
	if _relay != null:
		multiplayer.poll()


func _poll_socket() -> void:
	if _ws != null:
		_ws.poll()
		var ws_state := _ws.get_ready_state()

		if not _ws_open and ws_state == WebSocketPeer.STATE_OPEN:
			_ws_open = true
			_ws_was_open = true
			_flush_pending()

		# Drain packets before handling a close so frames that arrived just
		# before the socket closed are still delivered.
		while _ws != null and _ws.get_available_packet_count() > 0:
			var packet := _ws.get_packet()
			if _ws.was_string_packet():
				var msg: Variant = JSON.parse_string(packet.get_string_from_utf8())
				if msg is Dictionary:
					_handle_signal(msg)
			elif _relay != null:
				_relay.receive_frame(packet)

		if _ws != null and ws_state == WebSocketPeer.STATE_CLOSED:
			if _ws_open:
				_ws_open = false
				if _relay != null:
					# Mid-room drop: every remote peer is gone with the socket.
					_close_relay()
					emit_signal("connection_failed", "Lost connection to server")
			elif not _ws_was_open:
				emit_signal("connection_failed", "Could not reach signaling server")
				_ws = null


# ---------------------------------------------------------------------------
# Signal message dispatch
# ---------------------------------------------------------------------------

func _handle_signal(msg: Dictionary) -> void:
	var msg_type: String = msg.get("type", "")
	match msg_type:
		"created":
			room_code = str(msg.get("code", ""))
			# Add host as first player in local list
			room_players = [{"username": UsernameManager.username, "peer_id": 1}]
			_open_relay(1, true)
			emit_signal("connected_to_room", room_code, 1)

		"joined":
			my_peer_id = int(msg.get("peer_id", 2))
			var joined_settings: Variant = msg.get("settings", null)
			if joined_settings is Dictionary:
				room_settings = joined_settings
			_open_relay(my_peer_id, false)
			_relay.add_remote_peer(1)  # guests only ever see the host (star topology)
			emit_signal("connected_to_room", room_code, my_peer_id)

		"player_list":
			var players: Variant = msg.get("players", [])
			if players is Array:
				room_players = players
				emit_signal("player_list_updated", room_players)

		"settings_updated":
			var new_settings: Variant = msg.get("settings", null)
			if new_settings is Dictionary:
				room_settings = new_settings
				emit_signal("settings_updated", room_settings)

		"game_starting":
			emit_signal("game_starting")

		"host_disconnected":
			if _relay != null:
				_relay.remove_remote_peer(1)
			emit_signal("host_disconnected")

		"guest_joined":
			var peer_id: int = int(msg.get("peer_id", 0))
			if peer_id > 0:
				if _relay != null:
					_relay.add_remote_peer(peer_id)
				emit_signal("guest_joined", peer_id)

		"peer_disconnected":
			var peer_id: int = int(msg.get("peer_id", 0))
			if _relay != null and is_host:
				_relay.remove_remote_peer(peer_id)
			emit_signal("peer_disconnected", peer_id)

		"character_choice":
			# Relayed by the signaling server when a peer broadcasts their character pick.
			var peer_id: int = int(msg.get("peer_id", 0))
			var char_id: String = str(msg.get("char_id", GameManager.default_character_id()))
			if peer_id > 0 and peer_id != my_peer_id:
				peer_characters[peer_id] = char_id
				emit_signal("character_chosen", peer_id, char_id)

		"headwear_choice":
			# Same relay pattern as "character_choice", for the headwear slot.
			var peer_id: int = int(msg.get("peer_id", 0))
			var headwear_id: String = str(msg.get("headwear_id", ""))
			if peer_id > 0 and peer_id != my_peer_id:
				peer_headwear[peer_id] = headwear_id
				emit_signal("headwear_chosen", peer_id, headwear_id)

		"cloth_choice":
			# Same relay pattern as "character_choice", for the cloth/cape slot.
			var peer_id: int = int(msg.get("peer_id", 0))
			var cloth_id: String = str(msg.get("cloth_id", ""))
			if peer_id > 0 and peer_id != my_peer_id:
				peer_cloth[peer_id] = cloth_id
				emit_signal("cloth_chosen", peer_id, cloth_id)

		"color_choice":
			var peer_id: int = int(msg.get("peer_id", 0))
			var color_index: int = int(msg.get("color_index", 0))
			if peer_id > 0 and peer_id != my_peer_id:
				peer_colors[peer_id] = color_index
				emit_signal("color_chosen", peer_id, color_index)

		"mask_choice":
			var peer_id: int = int(msg.get("peer_id", 0))
			var mask_id: String = str(msg.get("mask_id", "plain"))
			if peer_id > 0 and peer_id != my_peer_id:
				peer_masks[peer_id] = mask_id
				emit_signal("mask_chosen", peer_id, mask_id)

		"error":
			var err_code: String = str(msg.get("code", ""))
			if err_code == "version_mismatch":
				var host_version: String = str(msg.get("host_version", "?"))
				emit_signal("connection_failed", "Version mismatch (you: %s, host: %s) — please update your game and try again." % [GameVersion.VERSION, host_version])
			else:
				emit_signal("connection_failed", str(msg.get("message", "Unknown signaling error")))


# ---------------------------------------------------------------------------
# HTTP rooms fetch
# ---------------------------------------------------------------------------

func _on_rooms_fetched(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	if result != HTTPRequest.RESULT_SUCCESS or response_code != 200:
		emit_signal("rooms_fetched", [])
		return
	var parsed: Variant = JSON.parse_string(body.get_string_from_utf8())
	if parsed is Array:
		emit_signal("rooms_fetched", parsed)
	else:
		emit_signal("rooms_fetched", [])


# ---------------------------------------------------------------------------
# Relay multiplayer peer
# ---------------------------------------------------------------------------

func _open_relay(unique_id: int, as_host: bool) -> void:
	_close_relay()
	_relay = RelayMultiplayerPeer.new()
	_relay.setup(_ws, unique_id, as_host)
	_relay.raw_packet.connect(_on_relay_raw_packet)
	multiplayer.multiplayer_peer = _relay


func _on_relay_raw_packet(from: int, data: PackedByteArray) -> void:
	game_packet.emit(from, data)


## Send a NetCodec packet: target > 0 one peer, 0 everyone else in the room.
## Unlike an RPC broadcast, a target-0 send leaves this device once.
func send_game_packet(target: int, data: PackedByteArray) -> void:
	if _relay != null:
		_relay.send_raw(target, data)


func _close_relay() -> void:
	if _relay == null:
		return
	_relay.close()
	_relay = null
	multiplayer.multiplayer_peer = null
