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

var lobby_mode: bool = true  # set to false by lobby.gd before transitioning

var current_state: int = RoundState.LOBBY
var round_wins: Dictionary = {}
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
	# Safety re-defer: if change_scene_to_file hasn't completed yet, wait one more frame.
	var main: Node = get_tree().current_scene
	if main == null or main.scene_file_path == "res://scenes/lobby.tscn":
		call_deferred("_init_game")
		return
	var player_scene := load("res://scenes/player.tscn") as PackedScene
	var bot_script := load("res://scripts/bot_controller.gd")

	for i in total_players:
		var p = player_scene.instantiate()
		p.name = "Player%d" % i
		p.player_index = i
		p.is_bot = (i >= human_count)
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

	start_round()  # start_round() calls reset_for_round() for all players


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
	current_state = new_state
	state_changed.emit(new_state)


func get_countdown_remaining() -> float:
	return maxf(_timer, 0.0)


func start_round() -> void:
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
