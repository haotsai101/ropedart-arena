extends Node
## AI bot controller. Attach as child "BotController" under a Player node.
## Drives the player by feeding desired move/aim/throw inputs each frame.

enum Difficulty { EASY = 0, MEDIUM = 1, HARD = 2 }
enum BotState { CHASE, AIM, RETREAT }

@export var difficulty: int = Difficulty.EASY

const DART_STATE_FLYING = 0  # mirrors Dagger.State.FLYING ordinal
## Mirrors rope_dart.gd's State.HOLSTERED ordinal (0 in both the old deleted
## Dagger enum and the current rope_dart.gd enum, coincidentally the same
## value). Used below to tell "dart in hand" apart from "dart away" now that
## dart is a persistent node whose STATE changes on throw, not a field that
## goes null (see player.gd's own header comment on this) -- unlike
## DART_STATE_FLYING above, this one is live code, not dead/no-op code.
const DART_STATE_HOLSTERED = 0

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

# Must match player.gd's MELEE_RANGE (this file has no static access to that
# script's consts across the duck-typed `player` reference used elsewhere
# here -- same hand-mirroring convention already used for DART_STATE_* above).
const MELEE_RANGE: float = 1.4
## Must roughly match player.gd's own MELEE_COOLDOWN -- how often a bot
## re-pulses get_desired_melee() while a target stays in range. Doesn't need
## to match exactly (player.gd's own cooldown is the real gate that decides
## whether a given pulse actually lands), just needs to be >= it so this
## file isn't setting _melee_pending true on ticks player.gd would silently
## drop anyway.
const MELEE_ATTACK_INTERVAL: float = 0.4

var player  # untyped for duck-typed access to player_index, get_pos_2d(), dart, etc.
var _state: int = BotState.CHASE
var _timer: float = 0.0
var _desired_move: Vector2 = Vector2.ZERO
var _desired_aim: Vector2 = Vector2(0.0, 1.0)
var _throw_pending: bool = false
var _recall_pending: bool = false
var _dash_pending: bool = false
var _melee_pending: bool = false  # one-shot pulse, same contract as _throw_pending et al.
var _melee_cooldown_timer: float = 0.0
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

## Same one-shot "pulse, not held" contract as get_desired_throw() above --
## player.gd's _handle_recall_input() only needs a rising edge to call
## rope_dart.gd's begin_recall(), same as _handle_throw_input() does for
## begin_charge()/release_throw().
func get_desired_recall() -> bool:
	if _recall_pending:
		_recall_pending = false
		return true
	return false

## Same one-shot "pulse, not held" contract as get_desired_throw()/
## get_desired_recall() above -- player.gd's _handle_melee_input() edge-
## detects this the same way it edge-detects a human's button press, so a
## bot re-pulses this (see MELEE_ATTACK_INTERVAL) rather than holding it
## continuously true, which would only ever land ONE hit (no repeat rising
## edge while already-true). Slash vs. Kick isn't decided here at all --
## player.gd's own dart.state check at the moment this pulse is consumed
## resolves that, exactly like a human pressing the same physical button.
func get_desired_melee() -> bool:
	if _melee_pending:
		_melee_pending = false
		return true
	return false


func _physics_process(delta: float) -> void:
	if GameManager.current_state != GameManager.RoundState.PLAYING:
		_desired_move = Vector2.ZERO
		return
	# player.gd has no is_dead concept yet (removed in the weapon-system
	# strip-down, not yet restored -- see player.gd's own header comment).
	# Null-safe duck-typed read so a human-controlled test with any bots in
	# the match doesn't crash; once Phase 2 adds is_dead back this reads it
	# exactly as before with no further change needed here.
	if player.get("is_dead") == true:
		_desired_move = Vector2.ZERO
		return

	if _melee_cooldown_timer > 0.0:
		_melee_cooldown_timer -= delta

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

	# Opportunistic melee: threaten a kill at melee range whenever the target
	# is close enough, regardless of CHASE/AIM/RETREAT state -- mirrors how
	# dart-dodging overrides the state machine below. This fires the SAME
	# pulse whether the target still has their dart holstered (this bot's own
	# Slash -- kill) or has thrown it away (this bot's own Kick -- knockback
	# only): the resolution is entirely player.gd's job (its own dart.state
	# check in _handle_melee_input(), reading THIS bot's own dart, not the
	# target's), so the bot doesn't need to know or care which one it'll end
	# up being before pulsing.
	if dist <= MELEE_RANGE and _melee_cooldown_timer <= 0.0:
		_melee_pending = true
		_melee_cooldown_timer = MELEE_ATTACK_INTERVAL

	# Dodge incoming darts (medium and hard bots only)
	if difficulty >= Difficulty.MEDIUM:
		var dodge := _get_dodge_dir(my_pos)
		if dodge != Vector2.ZERO:
			_set_desired_move(my_pos, dodge * SPEED_MULT[difficulty])
			_desired_aim = dir
			return

	# "Dart in hand" now means dart.state == HOLSTERED, not dart == null --
	# see DART_STATE_HOLSTERED's comment above. player.dart itself is never
	# null once player.gd's _ready() has run (persistent instance), but the
	# null check is kept as a defensive guard in case this runs before that.
	var dart_in_hand: bool = player.dart == null or player.dart.state == DART_STATE_HOLSTERED

	match _state:
		BotState.CHASE:
			_desired_aim = dir
			if not dart_in_hand or dist > THROW_RANGE[difficulty]:
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
				if dart_in_hand:
					_throw_pending = true
				_state = BotState.RETREAT
				_timer = RETREAT_TIME[difficulty]

		BotState.RETREAT:
			_set_desired_move(my_pos, -_desired_aim * SPEED_MULT[difficulty])
			if _timer <= 0.0:
				# Recall the dart before going back to chase, mirroring how a
				# human player uses Recall after a miss (GDD Combat: "Throw ->
				# Miss -> Recall through enemies"). get_desired_recall()'s
				# pulse is consumed by player.gd's _handle_recall_input(),
				# which only acts on it while the dart is FLYING/EMBEDDED --
				# harmless no-op otherwise (dart already back in hand).
				_recall_pending = true
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
		if p == player:
			continue
		# Same null-safe duck-typed read as _physics_process() above -- lives
		# doesn't exist on player.gd yet either.
		if p.get("is_dead") == true:
			continue
		var p_lives = p.get("lives")
		if p_lives != null and p_lives <= 0:
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
