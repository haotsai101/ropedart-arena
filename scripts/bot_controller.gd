extends Node
## AI bot controller. Attach as child "BotController" under a Player node.
## Drives the player by feeding desired move/aim/throw inputs each frame.

enum Difficulty { EASY = 0, MEDIUM = 1, HARD = 2 }
enum BotState { CHASE, AIM, RETREAT }

@export var difficulty: int = Difficulty.EASY

const DART_STATE_FLYING = 0  # mirrors Dagger.State.FLYING ordinal

const THROW_RANGE   := [4.0, 5.5, 7.0]
const AIM_DURATION  := [1.4, 0.7, 0.25]
const AIM_NOISE_DEG := [35.0, 15.0, 3.0]
const RETREAT_TIME  := [1.2, 0.9, 0.6]
const SPEED_MULT    := [0.65, 0.85, 1.0]

# Ring-out safety: must match player.gd's ARENA_HALF. Bots stop steering
# further outward once within EDGE_MARGIN of the platform edge (dodge/retreat
# can otherwise pick a direction that walks them straight off the boundary).
const ARENA_HALF: float = 15.0
const EDGE_MARGIN: float = 1.5

var player  # untyped for duck-typed access to player_index, get_pos_2d(), dart, etc.
var _state: int = BotState.CHASE
var _timer: float = 0.0
var _desired_move: Vector2 = Vector2.ZERO
var _desired_aim: Vector2 = Vector2(0.0, 1.0)
var _throw_pending: bool = false
var _dash_pending: bool = false
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

func get_desired_dash() -> bool:
	if _dash_pending:
		_dash_pending = false
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

	# Dodge incoming darts (medium and hard bots only)
	if difficulty >= Difficulty.MEDIUM:
		var dodge := _get_dodge_dir(my_pos)
		if dodge != Vector2.ZERO:
			_set_desired_move(my_pos, dodge * SPEED_MULT[difficulty])
			_desired_aim = dir
			return

	match _state:
		BotState.CHASE:
			_desired_aim = dir
			if player.dart != null or dist > THROW_RANGE[difficulty]:
				_set_desired_move(my_pos, dir * SPEED_MULT[difficulty])
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
			_set_desired_move(my_pos, -_desired_aim * SPEED_MULT[difficulty])
			if _timer <= 0.0:
				# No rope to recall anymore -- if the dagger's still out
				# (flying, or landed somewhere waiting for pickup), there's
				# nothing to do here but go back to chasing; player.dart
				# clears itself once the bot walks over its landed dagger.
				_state = BotState.CHASE


func _set_desired_move(pos: Vector2, move: Vector2) -> void:
	## Clamp outward movement once near the platform edge so dodge/retreat
	## steering can't walk a bot off the ring-out boundary. Only zeroes the
	## component pushing further out; doesn't attempt to steer back inward.
	var result: Vector2 = move
	if pos.x > ARENA_HALF - EDGE_MARGIN and result.x > 0.0:
		result.x = 0.0
	elif pos.x < -(ARENA_HALF - EDGE_MARGIN) and result.x < 0.0:
		result.x = 0.0
	if pos.y > ARENA_HALF - EDGE_MARGIN and result.y > 0.0:
		result.y = 0.0
	elif pos.y < -(ARENA_HALF - EDGE_MARGIN) and result.y < 0.0:
		result.y = 0.0
	_desired_move = result


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
		if dart.owner_player == player or dart.state != DART_STATE_FLYING:
			continue
		var to_me: Vector2 = my_pos - (dart.head_2d as Vector2)
		if to_me.length() > 8.0:
			continue
		if (dart.dir_2d as Vector2).dot(to_me.normalized()) > cos(deg_to_rad(40.0)):
			# Commit to a side on first detection; keep it until the threat clears
			if _dodge_dir == Vector2.ZERO:
				var side: float = 1.0 if randf() > 0.5 else -1.0
				_dodge_dir = (dart.dir_2d as Vector2).rotated(PI * 0.5 * side)
				_dash_pending = true  # burst out of the way instead of just sidestepping
			return _dodge_dir
	_dodge_dir = Vector2.ZERO  # no threat — reset so next dart picks fresh side
	return Vector2.ZERO
