extends Node
## WebRTC + signaling autoload. Access globally as "NetworkManager".
## Owns the WebSocket connection to the signaling server and all WebRTCPeerConnections.
## Drives Godot's high-level multiplayer API (WebRTCMultiplayerPeer) so that RPC and
## MultiplayerSynchronizer work transparently after pairing completes.

signal connected_to_room(code: String, peer_count: int)
signal guest_joined(peer_id: int)
signal peer_disconnected(peer_id: int)
signal connection_failed(reason: String)

const MAX_PLAYERS := 6

var is_host := false
var my_peer_id := 0
var room_code := ""

var _signaling_url := "wss://ropedart-arena.onrender.com"

var _ws: WebSocketPeer = null
var _ws_open := false        # true once the WS handshake is complete
var _pending_send: Array = [] # messages queued before WS is open

var _rtc: WebRTCMultiplayerPeer = null
var _peer_connections: Dictionary = {}  # peer_id (int) -> WebRTCPeerConnection


func _ready() -> void:
	_rtc = WebRTCMultiplayerPeer.new()


func set_signaling_url(url: String) -> void:
	_signaling_url = url


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

func create_room() -> void:
	is_host = true
	my_peer_id = 1
	_connect_signaling()


func join_room(code: String) -> void:
	is_host = false
	room_code = code.to_upper()
	_connect_signaling()


func disconnect_from_room() -> void:
	if _ws != null:
		_ws.close()
		_ws = null
	_ws_open = false
	_pending_send.clear()
	if _rtc != null:
		_rtc.close()
	_rtc = WebRTCMultiplayerPeer.new()
	_peer_connections.clear()
	is_host = false
	my_peer_id = 0
	room_code = ""
	# Reset Godot's multiplayer peer so local play still works
	multiplayer.multiplayer_peer = null


# ---------------------------------------------------------------------------
# Internal — signaling WebSocket
# ---------------------------------------------------------------------------

func _connect_signaling() -> void:
	_ws = WebSocketPeer.new()
	_ws_open = false
	_pending_send.clear()
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
			_flush_pending()
			# First message after open: announce intent
			if is_host:
				_send_signal({"type": "create"})
			else:
				_send_signal({"type": "join", "code": room_code})

		if ws_state == WebSocketPeer.STATE_CLOSED and _ws_open:
			# Unexpected close after we were open
			_ws_open = false

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
			var err := _rtc.create_mesh(1)   # host is always multiplayer peer 1
			if err != OK:
				emit_signal("connection_failed", "WebRTCMultiplayerPeer.create_mesh failed: %d" % err)
				return
			multiplayer.multiplayer_peer = _rtc
			emit_signal("connected_to_room", room_code, 0)

		"joined":
			my_peer_id = int(msg.get("peer_id", 2))
			var err := _rtc.create_client(my_peer_id)
			if err != OK:
				emit_signal("connection_failed", "WebRTCMultiplayerPeer.create_client failed: %d" % err)
				return
			multiplayer.multiplayer_peer = _rtc
			emit_signal("connected_to_room", room_code, int(msg.get("peer_count", 1)))

		"guest_joined":
			# Host received: a new guest joined — initiate offer to them
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

		"error":
			emit_signal("connection_failed", str(msg.get("message", "Unknown signaling error")))


# ---------------------------------------------------------------------------
# WebRTC peer connection management
# ---------------------------------------------------------------------------

func _create_peer_connection(peer_id: int, create_offer: bool) -> void:
	if _peer_connections.has(peer_id):
		return  # already exists
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
	# Bind with peer_id so the lambda knows which peer generated the event
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
	# The server routes by msg.peer_id = destination peer; it stamps sender's id for the recipient.
	_send_signal({
		"type": type,
		"code": room_code,
		"peer_id": target_peer_id,
		"sdp": sdp
	})


func _on_ice_candidate(mid: String, index: int, candidate: String, target_peer_id: int) -> void:
	# Route the candidate to the correct target peer via the signaling server.
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
