extends CharacterBody3D
## Player controller — 2D logic on XZ plane, 3D rendering.
## Supports keyboard (player_index=0), gamepads (player_index>=1), and AI bots.

signal player_killed(player: Node)
signal player_eliminated(player: Node)

@export var move_speed: float = 6.0
@export var dart_scene: PackedScene
@export var player_index: int = 0
@export var is_bot: bool = false

const PLAYER_COLORS := [
	Color(0.3, 0.6, 0.9),   # 0: blue  (keyboard)
	Color(0.9, 0.2, 0.2),   # 1: red
	Color(0.2, 0.8, 0.3),   # 2: green
	Color(0.9, 0.8, 0.1),   # 3: yellow
	Color(0.9, 0.4, 0.8),   # 4: pink
	Color(0.4, 0.9, 0.9),   # 5: cyan
]
const DEADZONE := 0.2
const MAX_CHARGE_TIME := 1.5
# Bot charge ratios indexed by difficulty: Easy=0.3, Medium=0.6, Hard=1.0
const BOT_CHARGE_RATIOS := [0.3, 0.6, 1.0]

@onready var aim_indicator: Node3D = $AimIndicator
@onready var player_mesh: MeshInstance3D = $PlayerMeshInstance
@onready var collision_shape: CollisionShape3D = $PlayerCollision

var player_color: Color
var aim_dir: Vector2 = Vector2(0, 1)
var dart: Node3D = null
var lives: int = 3
var is_dead: bool = false
var spawn_pos: Vector3
var bot_controller: Node = null

var _prev_throw: bool = false
var _respawn_timer: SceneTreeTimer = null
var _player_material: StandardMaterial3D = null

# Charged throw state (human players only)
var _charge_time: float = 0.0
var _is_charging: bool = false

# Trip / slow state
var _trip_timer: float = 0.0
var _slow_timer: float = 0.0
var _is_tripped: bool = false


func _ready() -> void:
	add_to_group("players")
	player_color = PLAYER_COLORS[clamp(player_index, 0, PLAYER_COLORS.size() - 1)]
	var mat := StandardMaterial3D.new()
	mat.albedo_color = player_color
	mat.roughness = 0.5
	player_mesh.set_surface_override_material(0, mat)
	_player_material = mat
	if is_bot:
		bot_controller = get_node_or_null("BotController")


func _physics_process(delta: float) -> void:
	if is_dead:
		_is_charging = false
		return
	if GameManager.current_state != GameManager.RoundState.PLAYING:
		velocity = Vector3.ZERO
		move_and_slide()
		_is_charging = false
		return

	# --- Trip / slow countdown ---
	var effective_speed: float = move_speed
	var movement_blocked: bool = false

	if _trip_timer > 0.0:
		_trip_timer -= delta
		if _trip_timer <= 0.0:
			_trip_timer = 0.0
			_slow_timer = 1.5
			_is_tripped = false
		movement_blocked = true
	elif _slow_timer > 0.0:
		_slow_timer -= delta
		if _slow_timer <= 0.0:
			_slow_timer = 0.0
			if _player_material != null:
				_player_material.albedo_color = player_color
		else:
			effective_speed = move_speed * 0.5

	# --- Inputs ---
	var move_input := _get_move_input()
	var aim_input := _get_aim_input()

	# --- Velocity ---
	if movement_blocked:
		velocity = Vector3.ZERO
	else:
		if move_input.length() > 1.0:
			move_input = move_input.normalized()
		velocity = Vector3(move_input.x, 0.0, move_input.y) * effective_speed
	move_and_slide()

	# --- Aim indicator ---
	if aim_input.length() > DEADZONE:
		aim_dir = aim_input.normalized()
	elif move_input.length() > DEADZONE:
		aim_dir = move_input.normalized()
	aim_indicator.position = Vector3(aim_dir.x, 0.0, aim_dir.y) * 1.2

	# --- Throw / charge logic ---
	if is_bot and bot_controller != null:
		# Bots use a one-shot flag; throw immediately at difficulty-based ratio
		if bot_controller.get_desired_throw():
			if dart == null:
				var diff: int = clamp(bot_controller.difficulty, 0, BOT_CHARGE_RATIOS.size() - 1)
				var bot_ratio: float = float(BOT_CHARGE_RATIOS[diff])
				_throw(bot_ratio)
			else:
				dart.recall()
	else:
		# Human players: hold to charge, release to fire
		var throw_held: bool = _get_throw_held()
		var throw_just_pressed: bool = throw_held and not _prev_throw
		var throw_just_released: bool = not throw_held and _prev_throw
		_prev_throw = throw_held

		if throw_just_pressed:
			if dart != null:
				dart.recall()
			else:
				_is_charging = true
				_charge_time = 0.0

		if _is_charging:
			if throw_held:
				_charge_time = minf(_charge_time + delta, MAX_CHARGE_TIME)
			if throw_just_released:
				var ratio: float = _charge_time / MAX_CHARGE_TIME
				_throw(ratio)
				_is_charging = false


func _get_throw_held() -> bool:
	if player_index == 0:
		return Input.is_key_pressed(KEY_SPACE)
	return Input.is_joy_button_pressed(player_index - 1, JOY_BUTTON_A)


func _get_move_input() -> Vector2:
	if is_bot and bot_controller != null:
		return bot_controller.get_desired_move()
	if player_index == 0:
		return Vector2(
			float(Input.is_key_pressed(KEY_D)) - float(Input.is_key_pressed(KEY_A)),
			float(Input.is_key_pressed(KEY_S)) - float(Input.is_key_pressed(KEY_W))
		)
	var joy := player_index - 1
	var v := Vector2(Input.get_joy_axis(joy, JOY_AXIS_LEFT_X),
					 Input.get_joy_axis(joy, JOY_AXIS_LEFT_Y))
	return v if v.length() >= DEADZONE else Vector2.ZERO


func _get_aim_input() -> Vector2:
	if is_bot and bot_controller != null:
		return bot_controller.get_desired_aim()
	if player_index == 0:
		return Vector2(
			float(Input.is_key_pressed(KEY_RIGHT)) - float(Input.is_key_pressed(KEY_LEFT)),
			float(Input.is_key_pressed(KEY_DOWN))  - float(Input.is_key_pressed(KEY_UP))
		)
	var joy := player_index - 1
	var v := Vector2(Input.get_joy_axis(joy, JOY_AXIS_RIGHT_X),
					 Input.get_joy_axis(joy, JOY_AXIS_RIGHT_Y))
	return v if v.length() >= DEADZONE else Vector2.ZERO


func _throw(ratio: float) -> void:
	if dart_scene == null:
		return
	dart = dart_scene.instantiate()
	get_parent().add_child(dart)
	dart.launch(self, get_pos_2d(), aim_dir, ratio)


func get_pos_2d() -> Vector2:
	return Vector2(global_position.x, global_position.z)


func trip() -> void:
	## Apply a trip effect: freeze 0.4s then slow to 50% for 1.5s.
	## No-ops if already frozen or slowed (immunity window).
	if _is_tripped or _slow_timer > 0.0:
		return
	_is_tripped = true
	_trip_timer = 0.4
	if _player_material != null:
		_player_material.albedo_color = Color(1.0, 0.5, 0.0)  # orange tint


func kill() -> void:
	if is_dead:
		return
	is_dead = true
	lives -= 1
	player_mesh.visible = false
	collision_shape.disabled = true
	if dart != null:
		dart.recall()
	player_killed.emit(self)
	if lives > 0:
		_respawn_timer = get_tree().create_timer(1.5)
		_respawn_timer.timeout.connect(_respawn)
	else:
		player_eliminated.emit(self)
		set_physics_process(false)


func _respawn() -> void:
	global_position = spawn_pos
	is_dead = false
	_prev_throw = false
	player_mesh.visible = true
	collision_shape.disabled = false


func reset_for_round(new_lives: int, start_pos: Vector3) -> void:
	if _respawn_timer != null and not _respawn_timer.is_queued_for_deletion():
		if _respawn_timer.timeout.is_connected(_respawn):
			_respawn_timer.timeout.disconnect(_respawn)
	_respawn_timer = null
	lives = new_lives
	spawn_pos = start_pos
	global_position = start_pos
	is_dead = false
	player_mesh.visible = true
	collision_shape.disabled = false
	set_physics_process(true)
	_prev_throw = false
	_is_charging = false
	_charge_time = 0.0
	_trip_timer = 0.0
	_slow_timer = 0.0
	_is_tripped = false
	if _player_material != null:
		_player_material.albedo_color = player_color
	if dart != null:
		dart.queue_free()
		dart = null


func _on_dart_returned() -> void:
	dart = null
