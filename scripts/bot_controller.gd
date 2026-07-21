extends Node
## AI bot controller. Attach as child "BotController" under a Player node.
## Drives the player by feeding desired move/aim/throw inputs each frame.

enum Difficulty { EASY = 0, MEDIUM = 1, HARD = 2 }
enum BotState { CHASE, AIM, RETREAT }

@export var difficulty: int = Difficulty.EASY

const DART_STATE_EXTENDING = 0  # mirrors RopeDart.State.EXTENDING ordinal
const SLASH_RANGE := 1.4  # mirrors player.gd's MELEE_RANGE

const THROW_RANGE   := [4.0, 5.5, 7.0]
const AIM_DURATION  := [1.4, 0.7, 0.25]
const AIM_NOISE_DEG := [35.0, 15.0, 3.0]
const RETREAT_TIME  := [1.2, 0.9, 0.6]
const SPEED_MULT    := [0.65, 0.85, 1.0]

var player  # untyped for duck-typed access to player_index, get_pos_2d(), dart, etc.
var _state: int = BotState.CHASE
var _timer: float = 0.0
var _desired_move: Vector2 = Vector2.ZERO
var _desired_aim: Vector2 = Vector2(0.0, 1.0)
var _throw_pending: bool = false
var _slash_pending: bool = false
var _dodge_dir: Vector2 = Vector2.ZERO  # committed dodge direction; reset when threat clears


func _ready() -> void:
	player = get_parent()
	player.bot_controller = self
	_timer = randf_range(0.2, 1.2)  # stagger initial activation


func get_desired_move() -> Vector2:
	return _desired_move

func get_desired_aim() -> Vector2:
	return _desired_aim

func get_desired_throw() -> bool:
	if _throw_pending:
		_throw_pending = false
		return true
	return false

func get_desired_slash() -> bool:
	if _slash_pending:
		_slash_pending = false
		return true
	return false


func _physics_process(delta: float) -> void:
	if GameManager.current_state != GameManager.RoundState.PLAYING:
		_desired_move = Vector2.ZERO
		return
	if player.is_dead:
		_desired_move = Vector2.ZERO
		return

	var target = _find_target()
	if target == null:
		_desired_move = Vector2.ZERO
		return

	var my_pos: Vector2 = player.get_pos_2d()
	var target_pos: Vector2 = target.get_pos_2d()
	var to_target: Vector2 = target_pos - my_pos
	var dist: float = to_target.length()
	var dir: Vector2 = to_target.normalized() if dist > 0.01 else Vector2.ZERO

	_timer -= delta

	# Opportunistic melee slash: any live target within range gets slashed,
	# regardless of CHASE/AIM/RETREAT — same idea as dodge overriding the state machine.
	if dist <= SLASH_RANGE:
		_desired_aim = dir
		_slash_pending = true

	# Dodge incoming darts (medium and hard bots only)
	if difficulty >= Difficulty.MEDIUM:
		var dodge := _get_dodge_dir(my_pos)
		if dodge != Vector2.ZERO:
			_desired_move = dodge * SPEED_MULT[difficulty]
			_desired_aim = dir
			return

	match _state:
		BotState.CHASE:
			_desired_aim = dir
			if player.dart != null or dist > THROW_RANGE[difficulty]:
				_desired_move = dir * SPEED_MULT[difficulty]
			else:
				_desired_move = Vector2.ZERO
				_state = BotState.AIM
				_timer = AIM_DURATION[difficulty]

		BotState.AIM:
			_desired_move = Vector2.ZERO
			var noise: float = randf_range(-1.0, 1.0) * deg_to_rad(AIM_NOISE_DEG[difficulty])
			_desired_aim = Vector2.from_angle(dir.angle() + noise)
			if _timer <= 0.0:
				if player.dart == null:
					_throw_pending = true
				_state = BotState.RETREAT
				_timer = RETREAT_TIME[difficulty]

		BotState.RETREAT:
			_desired_move = -_desired_aim * SPEED_MULT[difficulty]
			if _timer <= 0.0:
				_state = BotState.CHASE


func _find_target():  # returns untyped player node for duck-typed access
	var closest = null
	var best_dist := INF
	for p in get_tree().get_nodes_in_group("players"):
		if p == player or p.is_dead or p.lives <= 0:
			continue
		var d: float = player.get_pos_2d().distance_to(p.get_pos_2d())
		if d < best_dist:
			best_dist = d
			closest = p
	return closest


func _get_dodge_dir(my_pos: Vector2) -> Vector2:
	for dart in get_tree().get_nodes_in_group("darts"):
		if not is_instance_valid(dart):
			continue
		if dart.owner_player == player or dart.state != DART_STATE_EXTENDING:
			continue
		var to_me: Vector2 = my_pos - (dart.head_2d as Vector2)
		if to_me.length() > 8.0:
			continue
		if (dart.dir_2d as Vector2).dot(to_me.normalized()) > cos(deg_to_rad(40.0)):
			# Commit to a side on first detection; keep it until the threat clears
			if _dodge_dir == Vector2.ZERO:
				var side: float = 1.0 if randf() > 0.5 else -1.0
				_dodge_dir = (dart.dir_2d as Vector2).rotated(PI * 0.5 * side)
			return _dodge_dir
	_dodge_dir = Vector2.ZERO  # no threat — reset so next dart picks fresh side
	return Vector2.ZERO
