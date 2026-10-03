class_name RelayMultiplayerPeer
extends MultiplayerPeerExtension
## MultiplayerPeer that tunnels Godot's high-level multiplayer traffic (RPCs,
## MultiplayerSynchronizer) through the signaling server's WebSocket instead of
## direct peer-to-peer WebRTC. Native Godot builds (desktop/iOS/Android) ship
## no WebRTC implementation without the separate webrtc-native GDExtension, so
## a relay is the one transport that works on every platform and every NAT.
##
## Topology is a star, same as ENet/WebSocket server mode: the host is peer 1
## (the "server") and sees every guest; each guest only sees peer 1. Guest-to-
## guest RPCs go through the host via SceneMultiplayer's own server relay
## (_is_server_relay_supported() below).
##
## NetworkManager owns the WebSocketPeer and its polling: it hands every
## BINARY frame it reads to receive_frame() here, and calls add_remote_peer()/
## remove_remote_peer() as the signaling server reports joins/leaves. Text
## frames stay JSON signaling and never reach this class.
##
## Wire format (binary frames, little-endian), both directions:
##   [int32 peer][u8 transfer_mode][u8 channel][payload...]
## Outgoing, `peer` is the target: >0 one peer, 0 everyone else in the room,
## <0 everyone except -peer (MultiplayerPeer's own target_peer convention).
## Incoming, the server has rewritten `peer` to the SENDER's id.

const HEADER_SIZE := 6

var _ws: WebSocketPeer = null
var _unique_id: int = 0
var _is_host: bool = false
var _status: ConnectionStatus = CONNECTION_DISCONNECTED
var _remote_peers: Dictionary = {}  # peer_id (int) -> true

var _target_peer: int = 0
var _transfer_mode: TransferMode = TRANSFER_MODE_RELIABLE
var _transfer_channel: int = 0
var _refusing: bool = false

# Received packets waiting for SceneMultiplayer, oldest first.
var _incoming: Array[Dictionary] = []  # {peer, mode, channel, data}


func setup(ws: WebSocketPeer, unique_id: int, is_host: bool) -> void:
	_ws = ws
	_unique_id = unique_id
	_is_host = is_host
	_status = CONNECTION_CONNECTED


func add_remote_peer(peer_id: int) -> void:
	if peer_id <= 0 or peer_id == _unique_id or _remote_peers.has(peer_id):
		return
	_remote_peers[peer_id] = true
	peer_connected.emit(peer_id)


func remove_remote_peer(peer_id: int) -> void:
	if not _remote_peers.has(peer_id):
		return
	_remote_peers.erase(peer_id)
	peer_disconnected.emit(peer_id)


func receive_frame(frame: PackedByteArray) -> void:
	if frame.size() < HEADER_SIZE:
		return
	var from: int = frame.decode_s32(0)
	if not _remote_peers.has(from):
		return  # not (yet) a peer we've announced -- SceneMultiplayer would reject it anyway
	_incoming.append({
		"peer": from,
		"mode": frame[4],
		"channel": frame[5],
		"data": frame.slice(HEADER_SIZE),
	})


# ---------------------------------------------------------------------------
# PacketPeer
# ---------------------------------------------------------------------------

func _get_available_packet_count() -> int:
	return _incoming.size()


func _get_max_packet_size() -> int:
	return 1 << 16


func _get_packet_script() -> PackedByteArray:
	if _incoming.is_empty():
		return PackedByteArray()
	return _incoming.pop_front()["data"]


func _put_packet_script(buffer: PackedByteArray) -> Error:
	if _ws == null or _status != CONNECTION_CONNECTED:
		return ERR_UNCONFIGURED
	if _ws.get_ready_state() != WebSocketPeer.STATE_OPEN:
		return ERR_CONNECTION_ERROR
	var frame := PackedByteArray()
	frame.resize(HEADER_SIZE)
	frame.encode_s32(0, _target_peer)
	frame[4] = _transfer_mode
	frame[5] = _transfer_channel
	frame.append_array(buffer)
	return _ws.send(frame, WebSocketPeer.WRITE_MODE_BINARY)


# ---------------------------------------------------------------------------
# MultiplayerPeer
# ---------------------------------------------------------------------------

# The three _get_packet_* getters describe the NEXT packet in the queue, not
# the one last returned: SceneMultiplayer.poll() reads the sender before it
# calls get_packet() (same contract ENetMultiplayerPeer implements).
func _next_packet_field(key: String, fallback: int) -> int:
	if _incoming.is_empty():
		return fallback
	return int(_incoming[0][key])


func _get_packet_channel() -> int:
	return _next_packet_field("channel", 0)


func _get_packet_mode() -> TransferMode:
	return _next_packet_field("mode", TRANSFER_MODE_RELIABLE) as TransferMode


func _get_packet_peer() -> int:
	return _next_packet_field("peer", 0)


func _set_transfer_channel(channel: int) -> void:
	_transfer_channel = channel


func _get_transfer_channel() -> int:
	return _transfer_channel


func _set_transfer_mode(mode: TransferMode) -> void:
	_transfer_mode = mode


func _get_transfer_mode() -> TransferMode:
	return _transfer_mode


func _set_target_peer(peer: int) -> void:
	_target_peer = peer


func _is_server() -> bool:
	return _is_host


func _is_server_relay_supported() -> bool:
	return true


func _get_unique_id() -> int:
	return _unique_id


func _get_connection_status() -> ConnectionStatus:
	return _status


func _set_refuse_new_connections(enable: bool) -> void:
	_refusing = enable


func _is_refusing_new_connections() -> bool:
	return _refusing


func _poll() -> void:
	pass  # NetworkManager polls the shared WebSocketPeer and feeds receive_frame()


func _disconnect_peer(peer: int, _force: bool) -> void:
	remove_remote_peer(peer)


func _close() -> void:
	for peer_id: int in _remote_peers.keys():
		peer_disconnected.emit(peer_id)
	_remote_peers.clear()
	_incoming.clear()
	_ws = null
	_status = CONNECTION_DISCONNECTED
