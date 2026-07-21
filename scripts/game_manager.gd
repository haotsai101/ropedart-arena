extends Node
## Round state machine autoload. Access globally as "GameManager".

enum RoundState { LOBBY, COUNTDOWN, PLAYING, ROUND_END, MATCH_END }

signal state_changed(new_state: int)
signal round_ended(winner_index: int)
signal match_ended(winner_index: int)

@export var lives_per_round: int = 3
@export var rounds_to_win: int = 3
@export var countdown_duration: float = 3.0
@export var round_end_delay: float = 3.5
@export var total_players: int = 4
@export var human_count: int = 1
@export var bot_difficulty: int = 0   # 0=Easy 1=Medium 2=Hard

var lobby_mode: bool = true   # set to false by lobby.gd before transitioning
var is_online: bool = false   # set to true by lobby.gd when launching online match
var selected_map_scene: String = "res://scenes/main.tscn"   # set by lobby.gd before change_scene_to_file

var current_state: int = RoundState.LOBBY
var round_wins: Dictionary = {}
var player_characters: Dictionary = {}   # player_index (int) → character id (String)
var _all_players: Array = []
var _alive_players: Array = []
var _timer: float = 0.0
var _winner_index: int = -1

const PLAYER_COLORS := [
	Color(0.3, 0.6, 0.9),
	Color(0.9, 0.2, 0.2),
	Color(0.2, 0.8, 0.3),
	Color(0.9, 0.8, 0.1),
	Color(0.9, 0.4, 0.8),
	Color(0.4, 0.9, 0.9),
]

## KayKit Adventurers 2.0 characters. Unlike the old fruit set, these share
## one identical skeleton wrapper name ("Rig_Medium") across every character
## and both animation source files, so no body_mesh_name / per-character
## rig-renaming hack is needed (see player.gd's _setup_animation()) — color
## identification is applied as an emission tint across every mesh part
## instead of overriding one named body mesh, since these are fully textured
## models, not flat-shaded shapes.
const CHARACTER_DEFS: Array = [
	{"id": "char_barbarian",    "glb_path": "res://assets/kaykit_adventurers/characters/Barbarian.glb",    "display_name": "Barbarian",      "character_color": Color(0.85, 0.08, 0.04, 1.0)},
	{"id": "char_knight",       "glb_path": "res://assets/kaykit_adventurers/characters/Knight.glb",       "display_name": "Knight",         "character_color": Color(0.30, 0.50, 0.90, 1.0)},
	{"id": "char_mage",         "glb_path": "res://assets/kaykit_adventurers/characters/Mage.glb",         "display_name": "Mage",           "character_color": Color(0.60, 0.20, 0.85, 1.0)},
	{"id": "char_ranger",       "glb_path": "res://assets/kaykit_adventurers/characters/Ranger.glb",       "display_name": "Ranger",         "character_color": Color(0.18, 0.62, 0.18, 1.0)},
	{"id": "char_rogue",        "glb_path": "res://assets/kaykit_adventurers/characters/Rogue.glb",        "display_name": "Rogue",          "character_color": Color(0.98, 0.78, 0.08, 1.0)},
	{"id": "char_rogue_hooded", "glb_path": "res://assets/kaykit_adventurers/characters/Rogue_Hooded.glb", "display_name": "Rogue (Hooded)", "character_color": Color(0.42, 0.26, 0.62, 1.0)},
]

const PLAYER_HALF_HEIGHT := 0.7  # half-height of the player capsule; added to spawn marker Y

const _FALLBACK_SPAWNS := [
	Vector3(-10.0, 0.7, -10.0),
	Vector3( 10.0, 0.7, -10.0),
	Vector3(-10.0, 0.7,  10.0),
	Vector3( 10.0, 0.7,  10.0),
	Vector3(  0.0, 0.7, -12.0),
	Vector3(  0.0, 0.7,  12.0),
]


func _ready() -> void:
	call_deferred("_init_game")


func _init_game() -> void:
	if lobby_mode:
		return
	var main: Node = get_tree().current_scene
	# Safety re-defer: if change_scene_to_file hasn't completed yet, wait one more frame.
	# Using a 0-second SceneTreeTimer instead of call_deferred() so each retry happens
	# at a frame boundary — this prevents the tight re-defer loop that would otherwise
	# block the MessageQueue and prevent the scene change from ever executing.
	if main == null or main.scene_file_path == "res://scenes/lobby.tscn":
		get_tree().create_timer(0.0).timeout.connect(func(): _init_game())
		return

	if is_online:
		_init_game_online(main)
	else:
		_init_game_local(main)

	start_round()


func _init_game_local(main: Node) -> void:
	if player_characters.is_empty():
		assign_default_characters()
	var player_scene := load("res://scenes/player.tscn") as PackedScene
	var bot_script := load("res://scripts/bot_controller.gd")
	for i in total_players:
		var p = player_scene.instantiate()
		p.name = "Player%d" % i
		p.player_index = i
		p.is_bot = (i >= human_count)
		p.character_id = player_characters.get(i, "char_barbarian")
		main.add_child(p)
		round_wins[i] = 0
		p.player_killed.connect(_on_player_killed)
		p.player_eliminated.connect(_on_player_eliminated)
		_all_players.append(p)
		if p.is_bot:
			var bc = bot_script.new()
			bc.name = "BotController"
			bc.difficulty = bot_difficulty
			p.add_child(bc)


func _init_game_online(main: Node) -> void:
	# In online mode, each peer owns exactly one player.
	# Host (peer_id=1) owns player_index 0; guests own their peer_id-1 index.
	# All peers spawn all player nodes so scene state is consistent, but each
	# player node's set_multiplayer_authority() limits which peer drives movement.
	# Slots without a connected human peer become host-driven bots.
	if player_characters.is_empty():
		assign_default_characters()
	var player_scene := load("res://scenes/player.tscn") as PackedScene
	var bot_script := load("res://scripts/bot_controller.gd")
	var my_id: int = multiplayer.get_unique_id()

	# Build the set of peer IDs that have actual human players in this room
	var connected_peers: Dictionary = {}
	for entry in NetworkManager.room_players:
		if entry is Dictionary and entry.has("peer_id"):
			connected_peers[int(entry["peer_id"])] = true

	for i in total_players:
		var p = player_scene.instantiate()
		p.name = "Player%d" % i
		p.player_index = i
		# peer_id 1 owns player 0; peer_id 2 owns player 1, etc.
		var owner_peer_id: int = i + 1
		var is_human_slot: bool = connected_peers.has(owner_peer_id)

		if is_human_slot:
			p.is_bot = false
			p.player_peer_id = owner_peer_id
			p.is_network_controlled = (my_id != owner_peer_id)
		else:
			# No human for this slot — host drives it as a bot
			p.is_bot = true
			p.player_peer_id = 1  # host is authoritative; its MultiplayerSynchronizer replicates position
			p.is_network_controlled = (my_id != 1)

		p.character_id = player_characters.get(i, CHARACTER_DEFS[i % CHARACTER_DEFS.size()]["id"])
		main.add_child(p)
		round_wins[i] = 0
		p.player_killed.connect(_on_player_killed)
		p.player_eliminated.connect(_on_player_eliminated)
		_all_players.append(p)
		if p.is_bot and multiplayer.is_server():
			var bc = bot_script.new()
			bc.name = "BotController"
			bc.difficulty = bot_difficulty
			p.add_child(bc)


func assign_default_characters() -> void:
	player_characters.clear()
	var shuffled: Array = CHARACTER_DEFS.duplicate()
	shuffled.shuffle()
	var slot: int = 0
	for def in shuffled:
		if slot >= total_players:
			break
		player_characters[slot] = def["id"]
		slot += 1


@rpc("authority", "call_local", "reliable")
func _rpc_sync_characters(chars: Dictionary) -> void:
	player_characters = chars


func sync_characters_rpc() -> void:
	## Lobby calls this before changing scene so all peers know the char assignments.
	if multiplayer.multiplayer_peer != null and multiplayer.is_server():
		rpc("_rpc_sync_characters", player_characters)


func _process(delta: float) -> void:
	match current_state:
		RoundState.COUNTDOWN:
			_timer -= delta
			# Transition after a short "GO!" window so the HUD can display it
			if _timer <= -0.5:
				_set_state(RoundState.PLAYING)
		RoundState.ROUND_END:
			_timer -= delta
			if _timer <= 0.0:
				_check_match_end()


func _set_state(new_state: int) -> void:
	if is_online and multiplayer.multiplayer_peer != null:
		# Only the host drives state; it broadcasts to all clients including itself.
		if multiplayer.is_server():
			rpc("_rpc_set_state", new_state)
		# Clients receive _rpc_set_state; do not set locally here.
		return
	current_state = new_state
	state_changed.emit(new_state)


@rpc("authority", "call_local", "reliable")
func _rpc_set_state(new_state: int) -> void:
	current_state = new_state
	state_changed.emit(new_state)


@rpc("authority", "call_local", "reliable")
func _rpc_sync_settings(total: int, humans: int, difficulty: int, lives: int, rounds: int) -> void:
	total_players = total
	human_count = humans
	bot_difficulty = difficulty
	lives_per_round = lives
	rounds_to_win = rounds


func get_countdown_remaining() -> float:
	return maxf(_timer, 0.0)


func start_round() -> void:
	# In online mode, only the host starts rounds; the RPC propagates the state.
	if is_online and multiplayer.multiplayer_peer != null and not multiplayer.is_server():
		return
	# Sync match settings to all clients before starting countdown.
	if is_online and multiplayer.multiplayer_peer != null and multiplayer.is_server():
		rpc("_rpc_sync_settings", total_players, human_count, bot_difficulty, lives_per_round, rounds_to_win)
		if player_characters.is_empty():
			assign_default_characters()
		rpc("_rpc_sync_characters", player_characters)
	var spawn_positions := _get_spawn_positions()
	for i in _all_players.size():
		var p = _all_players[i]
		var pos: Vector3 = spawn_positions[i % spawn_positions.size()]
		p.reset_for_round(lives_per_round, pos)
	_alive_players = _all_players.duplicate()
	_timer = countdown_duration
	_set_state(RoundState.COUNTDOWN)


func _get_spawn_positions() -> Array:
	var markers := get_tree().get_nodes_in_group("spawn_points")
	if markers.size() > 0:
		var positions: Array = []
		for m in markers:
			positions.append(m.global_position + Vector3(0, PLAYER_HALF_HEIGHT, 0))
		return positions
	return _FALLBACK_SPAWNS


func _on_player_killed(_player: Variant) -> void:
	pass  # HUD handles lives display via player's own signal


func _on_player_eliminated(player: Variant) -> void:
	_alive_players.erase(player)
	if _alive_players.size() <= 1 and current_state == RoundState.PLAYING:
		if _alive_players.size() == 0:
			_end_round(-1)  # Everyone dead at once — draw
		else:
			_end_round(_alive_players[0].player_index)


func _end_round(winner_idx: int) -> void:
	if winner_idx >= 0:
		_winner_index = winner_idx
		round_wins[_winner_index] = round_wins.get(_winner_index, 0) + 1
		round_ended.emit(_winner_index)
	else:
		_winner_index = -1
		round_ended.emit(-1)
	_timer = round_end_delay
	_set_state(RoundState.ROUND_END)


func _check_match_end() -> void:
	for idx: int in round_wins:
		if round_wins[idx] >= rounds_to_win:
			match_ended.emit(idx)
			_set_state(RoundState.MATCH_END)
			return
	start_round()
