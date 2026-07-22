extends Node
## WebRTC + signaling autoload. Access globally as "NetworkManager".
## Owns the WebSocket connection to the signaling server and all WebRTCPeerConnections.
## Drives Godot's high-level multiplayer API (WebRTCMultiplayerPeer) so that RPC and
## MultiplayerSynchronizer work transparently after pairing completes.

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

const MAX_PLAYERS := 6

var is_host := false
var my_peer_id := 0
var room_code := ""
var room_settings: Dictionary = {"max_players": 4, "bot_difficulty": 0, "map_id": 0}
var room_players: Array = []   # [{username, peer_id}]
var peer_characters: Dictionary = {}   # peer_id (int) → character id (String)
var peer_headwear: Dictionary = {}     # peer_id (int) → headwear id (String), "" = native
var peer_cloth: Dictionary = {}        # peer_id (int) → cloth id (String), "" = native

var _signaling_url := "wss://ropedart-arena.onrender.com"

var _ws: WebSocketPeer = null
var _ws_open := false
var _ws_was_open := false
var _pending_send: Array = []

var _rtc: WebRTCMultiplayerPeer = null
var _peer_connections: Dictionary = {}   # peer_id (int) -> WebRTCPeerConnection

var _http: HTTPRequest = null


func _ready() -> void:
	_rtc = WebRTCMultiplayerPeer.new()


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
	}))


func join_room(code: String) -> void:
	is_host = false
	room_code = code.to_upper()
	_connect_signaling()
	_pending_send.append(JSON.stringify({"type": "join", "code": room_code}))


func disconnect_from_room() -> void:
	if _ws != null:
		_ws.close()
		_ws = null
	_ws_open = false
	_ws_was_open = false
	_pending_send.clear()
	if _rtc != null:
		_rtc.close()
	_rtc = WebRTCMultiplayerPeer.new()
	_peer_connections.clear()
	is_host = false
	my_peer_id = 0
	room_code = ""
	room_players.clear()
	room_settings = {"max_players": 4, "bot_difficulty": 0, "map_id": 0}
	peer_characters.clear()
	peer_headwear.clear()
	peer_cloth.clear()
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
# _process — poll WS and RTC every frame
# ---------------------------------------------------------------------------

func _process(_delta: float) -> void:
	if _ws != null:
		_ws.poll()
		var ws_state := _ws.get_ready_state()

		if not _ws_open and ws_state == WebSocketPeer.STATE_OPEN:
			_ws_open = true
			_ws_was_open = true
			_flush_pending()

		if ws_state == WebSocketPeer.STATE_CLOSED:
			if _ws_open:
				_ws_open = false
			elif not _ws_was_open:
				emit_signal("connection_failed", "Could not reach signaling server")
				_ws = null

		while _ws != null and _ws.get_available_packet_count() > 0:
			var raw := _ws.get_packet().get_string_from_utf8()
			var msg: Variant = JSON.parse_string(raw)
			if msg is Dictionary:
				_handle_signal(msg)

	if _rtc != null:
		_rtc.poll()


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
			var err := _rtc.create_mesh(1)
			if err != OK:
				emit_signal("connection_failed", "WebRTCMultiplayerPeer.create_mesh failed: %d" % err)
				return
			multiplayer.multiplayer_peer = _rtc
			emit_signal("connected_to_room", room_code, 1)

		"joined":
			my_peer_id = int(msg.get("peer_id", 2))
			var joined_settings: Variant = msg.get("settings", null)
			if joined_settings is Dictionary:
				room_settings = joined_settings
			var err := _rtc.create_client(my_peer_id)
			if err != OK:
				emit_signal("connection_failed", "WebRTCMultiplayerPeer.create_client failed: %d" % err)
				return
			multiplayer.multiplayer_peer = _rtc
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
			emit_signal("host_disconnected")

		"guest_joined":
			var peer_id: int = int(msg.get("peer_id", 0))
			if peer_id > 0:
				_create_peer_connection(peer_id, true)
				emit_signal("guest_joined", peer_id)

		"offer":
			var peer_id: int = int(msg.get("peer_id", 0))
			if peer_id > 0:
				_create_peer_connection(peer_id, false)
				if _peer_connections.has(peer_id):
					_peer_connections[peer_id].set_remote_description("offer", str(msg.get("sdp", "")))

		"answer":
			var peer_id: int = int(msg.get("peer_id", 0))
			if _peer_connections.has(peer_id):
				_peer_connections[peer_id].set_remote_description("answer", str(msg.get("sdp", "")))

		"candidate":
			var peer_id: int = int(msg.get("peer_id", 0))
			if _peer_connections.has(peer_id):
				var cand: Variant = msg.get("candidate", {})
				if cand is Dictionary:
					_peer_connections[peer_id].add_ice_candidate(
						str(cand.get("sdpMid", "")),
						int(cand.get("sdpMLineIndex", 0)),
						str(cand.get("candidate", ""))
					)

		"peer_disconnected":
			var peer_id: int = int(msg.get("peer_id", 0))
			emit_signal("peer_disconnected", peer_id)

		"character_choice":
			# Relayed by the signaling server when a peer broadcasts their character pick.
			var peer_id: int = int(msg.get("peer_id", 0))
			var char_id: String = str(msg.get("char_id", "char_barbarian"))
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

		"error":
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
# WebRTC peer connection management
# ---------------------------------------------------------------------------

func _create_peer_connection(peer_id: int, create_offer: bool) -> void:
	if _peer_connections.has(peer_id):
		return
	var pc := WebRTCPeerConnection.new()
	var init_err := pc.initialize({
		"iceServers": [
			{"urls": ["stun:stun.l.google.com:19302"]},
			{"urls": ["stun:stun1.l.google.com:19302"]},
		]
	})
	if init_err != OK:
		emit_signal("connection_failed", "WebRTCPeerConnection.initialize failed: %d" % init_err)
		return
	pc.session_description_created.connect(_on_sdp_created.bind(peer_id))
	pc.ice_candidate_created.connect(_on_ice_candidate.bind(peer_id))
	var add_err := _rtc.add_peer(pc, peer_id)
	if add_err != OK:
		emit_signal("connection_failed", "WebRTCMultiplayerPeer.add_peer failed: %d" % add_err)
		return
	_peer_connections[peer_id] = pc
	if create_offer:
		pc.create_offer()


func _on_sdp_created(type: String, sdp: String, target_peer_id: int) -> void:
	if not _peer_connections.has(target_peer_id):
		return
	_peer_connections[target_peer_id].set_local_description(type, sdp)
	_send_signal({
		"type": type,
		"code": room_code,
		"peer_id": target_peer_id,
		"sdp": sdp
	})


func _on_ice_candidate(mid: String, index: int, candidate: String, target_peer_id: int) -> void:
	_send_signal({
		"type": "candidate",
		"code": room_code,
		"peer_id": target_peer_id,
		"candidate": {
			"sdpMid": mid,
			"sdpMLineIndex": index,
			"candidate": candidate
		}
	})
