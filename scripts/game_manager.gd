extends Node
## Round state machine autoload. Access globally as "GameManager".
##
## Phase 5 (docs/implementation-plan.md) restored the round/match win-loop
## that WEAPON/COMBAT SYSTEM REMOVAL (branch remove-weapon-system) had
## stripped out: RoundState now includes ROUND_END/MATCH_END, and
## lives_per_round/rounds_to_win/round_wins drive a real FFA win condition
## (no team modes exist yet -- a round ends the instant only one tracked
## player still has lives > 0, see _check_round_win()). The state machine
## now runs LOBBY -> COUNTDOWN -> PLAYING -> (ROUND_END -> COUNTDOWN)* ->
## MATCH_END, where the ROUND_END loop repeats until someone reaches
## rounds_to_win. MATCH_END is a deliberate dead end (see _apply_round_result()
## for the "no further action" judgment call, flagged there and in hud.gd).

enum RoundState { LOBBY, COUNTDOWN, PLAYING, ROUND_END, MATCH_END }

signal state_changed(new_state: int)

@export var countdown_duration: float = 3.0
@export var total_players: int = 4
@export var human_count: int = 1
@export var bot_difficulty: int = 0   # 0=Easy 1=Medium 2=Hard
## Lives each player starts a round with (player.gd's `lives`, decremented by
## take_dart_hit() -- reaching 0 eliminates that player for the rest of the
## round, see player.gd's _eliminate()).
@export var lives_per_round: int = 3
## Round-wins (round_wins below) needed to end the whole match, not just a
## round -- see _apply_round_result().
@export var rounds_to_win: int = 2
## Brief pause after a round ends (ROUND_END state) before the next round's
## COUNTDOWN begins, so the HUD's round-end banner (hud.gd) has time to be
## read before the arena resets.
@export var round_end_pause_duration: float = 2.5

var lobby_mode: bool = true   # set to false by lobby.gd before transitioning
var is_online: bool = false   # set to true by lobby.gd when launching online match
var selected_map_scene: String = "res://scenes/main.tscn"   # set by lobby.gd before change_scene_to_file

var current_state: int = RoundState.LOBBY
## player_index (int) -> round-win count (int), persists across rounds within
## ONE match; reset to empty at the start of a fresh match (_init_game_local/
## _init_game_online below), not at the start of each round (start_round()
## deliberately leaves this untouched -- see its own comment).
var round_wins: Dictionary = {}
## Winner of the most recently finished round (-1 if none yet, or in the rare
## simultaneous-elimination draw case -- see _check_round_win()) / of the
## match once MATCH_END is reached. hud.gd polls these (same "poll
## GameManager state every frame" convention _process() below already uses
## for current_state) to build its round-end/match-end banner text.
var last_round_winner_index: int = -1
var match_winner_index: int = -1
var player_characters: Dictionary = {}   # player_index (int) → character id (String)
## "" means "use the base character's native accessory" (see CHARACTER_DEFS'
## native_headwear/native_cloth fields, resolved via resolve_headwear_id/
## resolve_cloth_id below) -- an explicit "none" id means the player
## deliberately picked no accessory, distinct from "hasn't chosen yet".
var player_headwear: Dictionary = {}     # player_index (int) → headwear id (String)
var player_cloth: Dictionary = {}        # player_index (int) → cloth id (String)
var _all_players: Array = []
var _timer: float = 0.0

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
## native_headwear/native_cloth record which HEADWEAR_DEFS/CLOTH_DEFS id (below)
## this character models natively in its own glb -- "" means it has none.
## Picking a base character defaults its two accessory slots to these (see
## GameManager.resolve_headwear_id/resolve_cloth_id) rather than forcing
## everything to "none"; the player can still override either slot from there.
const CHARACTER_DEFS: Array = [
	{"id": "char_barbarian",    "glb_path": "res://assets/kaykit_adventurers/characters/Barbarian.glb",    "display_name": "Barbarian",      "character_color": Color(0.85, 0.08, 0.04, 1.0), "native_headwear": "barbarian_bearhat",  "native_cloth": "none"},
	{"id": "char_knight",       "glb_path": "res://assets/kaykit_adventurers/characters/Knight.glb",       "display_name": "Knight",         "character_color": Color(0.30, 0.50, 0.90, 1.0), "native_headwear": "knight_helmet",      "native_cloth": "knight_cape"},
	{"id": "char_mage",         "glb_path": "res://assets/kaykit_adventurers/characters/Mage.glb",         "display_name": "Mage",           "character_color": Color(0.60, 0.20, 0.85, 1.0), "native_headwear": "mage_hat",           "native_cloth": "mage_cape"},
	{"id": "char_ranger",       "glb_path": "res://assets/kaykit_adventurers/characters/Ranger.glb",       "display_name": "Ranger",         "character_color": Color(0.18, 0.62, 0.18, 1.0), "native_headwear": "none",               "native_cloth": "ranger_cape"},
	{"id": "char_rogue",        "glb_path": "res://assets/kaykit_adventurers/characters/Rogue.glb",        "display_name": "Rogue",          "character_color": Color(0.98, 0.78, 0.08, 1.0), "native_headwear": "none",               "native_cloth": "rogue_cape"},
	{"id": "char_rogue_hooded", "glb_path": "res://assets/kaykit_adventurers/characters/Rogue_Hooded.glb", "display_name": "Rogue (Hooded)", "character_color": Color(0.42, 0.26, 0.62, 1.0), "native_headwear": "rogue_hooded_mask",  "native_cloth": "rogue_hooded_cape"},
]

## Headwear pool, poolable across ALL base characters (unlike base character
## picks, duplicates are allowed here -- see CLAUDE.md's uniqueness note).
## Each non-"none" entry's mesh_names are pulled from source_char_id's own
## glb and reparented onto whichever base character the player picked -- see
## scripts/character_builder.gd for how, and its header comment for why this
## skins correctly (every character shares one skeleton, "Rig_Medium", with
## identical bone names). Mesh names verified directly against each glb's
## exported node names (Rogue_Hooded's parts are prefixed "RogueHooded_", not
## "Rogue_Hooded_" -- deliberately not a naming-convention typo here).
const HEADWEAR_DEFS: Array = [
	{"id": "none",               "display_name": "None",        "source_char_id": "",                "mesh_names": []},
	{"id": "barbarian_bearhat",  "display_name": "Bear Hat",     "source_char_id": "char_barbarian",    "mesh_names": ["Barbarian_BearHat"]},
	{"id": "knight_helmet",      "display_name": "Helmet",       "source_char_id": "char_knight",       "mesh_names": ["Knight_Helmet", "Knight_HelmetVisor"]},
	{"id": "mage_hat",           "display_name": "Wizard Hat",   "source_char_id": "char_mage",         "mesh_names": ["Mage_Hat"]},
	{"id": "rogue_hooded_mask",  "display_name": "Hood & Mask",  "source_char_id": "char_rogue_hooded", "mesh_names": ["RogueHooded_Mask"]},
]

## Cloth/cape pool, poolable across all base characters (same rules as
## HEADWEAR_DEFS above). Ranger/Rogue/Rogue_Hooded's own capes are included
## here as pickable options too, not just Knight/Mage's.
const CLOTH_DEFS: Array = [
	{"id": "none",               "display_name": "None",        "source_char_id": "",                "mesh_names": []},
	{"id": "knight_cape",        "display_name": "Knight Cape",  "source_char_id": "char_knight",       "mesh_names": ["Knight_Cape"]},
	{"id": "mage_cape",          "display_name": "Mage Cape",    "source_char_id": "char_mage",         "mesh_names": ["Mage_Cape"]},
	{"id": "ranger_cape",        "display_name": "Ranger Cape",  "source_char_id": "char_ranger",       "mesh_names": ["Ranger_Cape"]},
	{"id": "rogue_cape",         "display_name": "Rogue Cape",   "source_char_id": "char_rogue",        "mesh_names": ["Rogue_Cape"]},
	{"id": "rogue_hooded_cape",  "display_name": "Hooded Cape",  "source_char_id": "char_rogue_hooded", "mesh_names": ["RogueHooded_Cape"]},
]


func get_character_def(char_id: String) -> Dictionary:
	for def: Dictionary in CHARACTER_DEFS:
		if def.get("id", "") == char_id:
			return def
	return CHARACTER_DEFS[0]


func get_headwear_def(headwear_id: String) -> Dictionary:
	for def: Dictionary in HEADWEAR_DEFS:
		if def.get("id", "") == headwear_id:
			return def
	return HEADWEAR_DEFS[0]  # "none"


func get_cloth_def(cloth_id: String) -> Dictionary:
	for def: Dictionary in CLOTH_DEFS:
		if def.get("id", "") == cloth_id:
			return def
	return CLOTH_DEFS[0]  # "none"


func resolve_headwear_id(base_char_id: String, choice: String) -> String:
	## "" (unset) falls back to the base character's own native headwear;
	## any other value (including the explicit "none") is used as-is.
	if choice != "":
		return choice
	return str(get_character_def(base_char_id).get("native_headwear", "none"))


func resolve_cloth_id(base_char_id: String, choice: String) -> String:
	if choice != "":
		return choice
	return str(get_character_def(base_char_id).get("native_cloth", "none"))

## Half-height of the player capsule; added to spawn marker Y (spawn markers
## in main.tscn/main_forest.tscn sit at Y=0, i.e. floor level) so a spawned
## player's capsule CENTER lands at the right height above the floor, and
## subtracted back off in player.gd's _mesh_ground_offset so the rendered
## mesh's feet land exactly at the floor regardless of this value (the two
## offsets are always equal and opposite, so they cancel -- see that
## constant's own comment).
##
## Resolved by direct in-engine measurement (Task #7, 2026-08-05), not
## assumption: a headless probe (`tests/_tmp_measure_player_aabb.gd`, since
## removed) instantiated a real player.tscn with the DEFAULT character
## (char_barbarian, its own native headwear equipped -- the actual default
## appearance a player spawns with) and measured every MeshInstance3D's real
## world-space AABB. Result: feet sit at world Y ~0.0 in every case (already
## the offset math's own designed invariant, confirmed rather than assumed),
## head (including native headwear) tops out at world Y ~2.038. The same
## probe run across all 6 CHARACTER_DEFS (with each one's own native
## headwear) showed a 1.85-2.26 range -- e.g. Mage's tall wizard hat is the
## outlier at the top -- so a single shared capsule sized to the exact
## default-character number will slightly undershoot a couple of the taller
## hat silhouettes and slightly overshoot the shorter ones; this is an
## accepted trade-off for one shared CapsuleShape3D across every character
## model, same "representative character, not a per-character shape" scope
## the task asked for.
const PLAYER_HALF_HEIGHT := 1.0  # half of PLAYER_CAPSULE_HEIGHT below

## The RAW scenes/player.tscn CapsuleShape3D.height value, mirrored here by
## hand (no way to read a .tscn sub-resource from a const expression at
## compile time). Previously 1.2 (a stale torso-only guess that disagreed
## with PLAYER_HALF_HEIGHT*2.0=1.4, leaving the capsule both floating above
## the true floor and far too short to reach any character's actual head --
## see PLAYER_HALF_HEIGHT's own comment for the real measurement). Now 2.0,
## matching that measurement and kept in agreement with PLAYER_HALF_HEIGHT
## (2.0 / 2.0 = 1.0) rather than the two constants disagreeing with each
## other. Read by rope_dart.gd's rope_length export (6x character height).
const PLAYER_CAPSULE_HEIGHT := 2.0

const _FALLBACK_SPAWNS := [
	Vector3(-10.0, PLAYER_HALF_HEIGHT, -10.0),
	Vector3( 10.0, PLAYER_HALF_HEIGHT, -10.0),
	Vector3(-10.0, PLAYER_HALF_HEIGHT,  10.0),
	Vector3( 10.0, PLAYER_HALF_HEIGHT,  10.0),
	Vector3(  0.0, PLAYER_HALF_HEIGHT, -12.0),
	Vector3(  0.0, PLAYER_HALF_HEIGHT,  12.0),
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
	_reset_match_state()
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
		p.character_headwear_id = str(player_headwear.get(i, ""))
		p.character_cloth_id = str(player_cloth.get(i, ""))
		main.add_child(p)
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
	_reset_match_state()
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
		p.character_headwear_id = str(player_headwear.get(i, ""))
		p.character_cloth_id = str(player_cloth.get(i, ""))
		main.add_child(p)
		_all_players.append(p)
		if p.is_bot and multiplayer.is_server():
			var bc = bot_script.new()
			bc.name = "BotController"
			bc.difficulty = bot_difficulty
			p.add_child(bc)


func assign_default_characters() -> void:
	player_characters.clear()
	# Fresh match: reset accessory picks to "" (native) too -- a stale
	# headwear/cloth id left over from a previous match's roster shouldn't
	# silently carry over onto whichever base character now lands in that slot.
	player_headwear.clear()
	player_cloth.clear()
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


@rpc("authority", "call_local", "reliable")
func _rpc_sync_accessories(headwear: Dictionary, cloth: Dictionary) -> void:
	player_headwear = headwear
	player_cloth = cloth


func sync_accessories_rpc() -> void:
	## Lobby calls this alongside sync_characters_rpc(), before changing scene,
	## so all peers know each other's headwear/cloth picks too.
	if multiplayer.multiplayer_peer != null and multiplayer.is_server():
		rpc("_rpc_sync_accessories", player_headwear, player_cloth)


func _process(delta: float) -> void:
	match current_state:
		RoundState.COUNTDOWN:
			_timer -= delta
			# Transition after a short "GO!" window so the HUD can display it
			if _timer <= -0.5:
				_set_state(RoundState.PLAYING)
		RoundState.PLAYING:
			_check_round_win()
		RoundState.ROUND_END:
			_timer -= delta
			if _timer <= 0.0:
				# Only the host actually restarts the loop; on clients start_round()
				# is a no-op guard (see its own check) since the host's own
				# _rpc_set_state(COUNTDOWN) already told them the next round began.
				start_round()


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
func _rpc_sync_settings(total: int, humans: int, difficulty: int) -> void:
	total_players = total
	human_count = humans
	bot_difficulty = difficulty


func get_countdown_remaining() -> float:
	return maxf(_timer, 0.0)


func start_round() -> void:
	# In online mode, only the host starts rounds; the RPC propagates the state.
	if is_online and multiplayer.multiplayer_peer != null and not multiplayer.is_server():
		return
	# Sync match settings to all clients before starting countdown.
	if is_online and multiplayer.multiplayer_peer != null and multiplayer.is_server():
		rpc("_rpc_sync_settings", total_players, human_count, bot_difficulty)
		if player_characters.is_empty():
			assign_default_characters()
		rpc("_rpc_sync_characters", player_characters)
		rpc("_rpc_sync_accessories", player_headwear, player_cloth)
	# NOTE: round_wins/last_round_winner_index/match_winner_index are
	# deliberately NOT touched here -- they persist across rounds within a
	# match (see round_wins' own comment); only _reset_match_state() (a whole
	# NEW match starting) clears them.
	var spawn_positions := _get_spawn_positions()
	for i in _all_players.size():
		var p = _all_players[i]
		var pos: Vector3 = spawn_positions[i % spawn_positions.size()]
		p.reset_for_round(pos)
	_timer = countdown_duration
	_set_state(RoundState.COUNTDOWN)


func _reset_match_state() -> void:
	## A genuinely NEW match starting (called from _init_game_local/
	## _init_game_online, both of which only ever run once per scene load) --
	## clears round_wins and the last-winner trackers so a replayed session
	## within the same process (GameManager is a persistent autoload, unlike
	## the scene tree) doesn't carry a stale winner/pip count into a fresh
	## match. Deliberately NOT called from start_round() itself, which also
	## runs at the start of every ROUND within a match and must leave this data
	## alone (see start_round()'s own comment).
	round_wins.clear()
	last_round_winner_index = -1
	match_winner_index = -1


## FFA-only win check (per the GDD's default mode -- no team modes exist yet):
## a round ends the instant at most one tracked player still has lives > 0.
## Runs every PLAYING frame off _all_players (the match's real roster, NOT the
## "players" group -- ad hoc player nodes instantiated by regression tests
## outside GameManager's own _init_game_local/_init_game_online never populate
## _all_players, so this is naturally a no-op in that context and can't
## interfere with those tests) -- cheap at the <=6-player scale this game
## supports, same "poll every frame" convention COUNTDOWN's own _timer
## countdown above already uses rather than an event-driven callback.
func _check_round_win() -> void:
	if is_online and multiplayer.multiplayer_peer != null and not multiplayer.is_server():
		return  # only the host decides; _rpc_round_result below propagates it
	if _all_players.size() < 2:
		return
	var alive: Array = []
	for p in _all_players:
		if not is_instance_valid(p):
			continue
		if p.get("lives") == null or p.lives > 0:
			alive.append(p)
	if alive.size() > 1:
		return
	var winner_idx: int = alive[0].player_index if alive.size() == 1 else -1
	_end_round(winner_idx)


## winner_idx == -1 covers the rare simultaneous-elimination draw (the last
## two-or-more players' lives both hit 0 on the exact same _check_round_win()
## poll) -- no round_wins increment happens for a draw, and the match simply
## proceeds to another round rather than crediting anyone.
func _end_round(winner_idx: int) -> void:
	var new_round_wins: Dictionary = round_wins.duplicate()
	if winner_idx >= 0:
		new_round_wins[winner_idx] = int(new_round_wins.get(winner_idx, 0)) + 1
	var match_winner: int = -1
	if winner_idx >= 0 and int(new_round_wins.get(winner_idx, 0)) >= rounds_to_win:
		match_winner = winner_idx
	if is_online and multiplayer.multiplayer_peer != null:
		rpc("_rpc_round_result", new_round_wins, winner_idx, match_winner)
	else:
		_apply_round_result(new_round_wins, winner_idx, match_winner)


@rpc("authority", "call_local", "reliable")
func _rpc_round_result(new_round_wins: Dictionary, winner_idx: int, match_winner: int) -> void:
	_apply_round_result(new_round_wins, winner_idx, match_winner)


## Judgment call (flagged per this task's own instructions, see hud.gd's
## MATCH_END overlay for the other half of this): once rounds_to_win is
## reached, MATCH_END is a deliberate dead end -- no auto-return to the lobby,
## no "rematch" button, just a static banner. There's no existing
## post-match-flow precedent anywhere else in this project to follow (lobby.gd
## only ever flows INTO a match, never back out of one), and the task's own
## instructions say to pick the simplest reasonable option when genuinely
## undecided rather than invent new lobby-return plumbing here.
func _apply_round_result(new_round_wins: Dictionary, winner_idx: int, match_winner: int) -> void:
	round_wins = new_round_wins
	last_round_winner_index = winner_idx
	if match_winner >= 0:
		match_winner_index = match_winner
		_set_state(RoundState.MATCH_END)
	else:
		_timer = round_end_pause_duration
		_set_state(RoundState.ROUND_END)


func _get_spawn_positions() -> Array:
	var markers := get_tree().get_nodes_in_group("spawn_points")
	if markers.size() > 0:
		var positions: Array = []
		for m in markers:
			positions.append(m.global_position + Vector3(0, PLAYER_HALF_HEIGHT, 0))
		return positions
	return _FALLBACK_SPAWNS
