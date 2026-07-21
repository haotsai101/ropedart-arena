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

# Melee slash — short-range directional attack, independent of the dart/throw system.
const SLASH_COOLDOWN: float = 0.25
const MELEE_RANGE: float = 1.4
const MELEE_CONE_DEG: float = 50.0  # half-angle around aim_dir counted as a hit

@onready var aim_indicator: Node3D = $AimIndicator
@onready var collision_shape: CollisionShape3D = $PlayerCollision
@onready var player_mesh: Node3D = $char_fruit

var player_color: Color
var aim_dir: Vector2 = Vector2(0, 1)
var dart: Node3D = null
var lives: int = 3
var is_dead: bool = false
var spawn_pos: Vector3
var bot_controller: Node = null

# Virtual on-screen controls — non-null only for player_index 0 on touch devices.
var _virtual_controls: Node = null

# Online multiplayer
var player_peer_id: int = 1          # which multiplayer peer owns this player
var is_network_controlled: bool = false  # true when a remote peer drives this player

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

# Melee slash state
var _slash_cooldown_timer: float = 0.0
var _prev_slash: bool = false

# Network input cache — written by _rpc_set_input, read by _physics_process
var _net_move: Vector2 = Vector2.ZERO
var _net_aim: Vector2 = Vector2.ZERO
var _net_throwing: bool = false


func _ready() -> void:
	add_to_group("players")
	player_color = PLAYER_COLORS[clamp(player_index, 0, PLAYER_COLORS.size() - 1)]
	# Tint the fruit character body with player color so players are distinguishable
	var fruit_body: MeshInstance3D = find_child("CharFruit_Body", true, false) as MeshInstance3D
	if fruit_body != null:
		var fruit_mat := StandardMaterial3D.new()
		fruit_mat.albedo_color = player_color
		fruit_mat.roughness = 0.5
		fruit_body.set_surface_override_material(0, fruit_mat)
		_player_material = fruit_mat
	if is_bot:
		bot_controller = get_node_or_null("BotController")
	# Virtual controls for touch devices (player_index 0, human only)
	if player_index == 0 and not is_bot and DisplayServer.is_touchscreen_available():
		var vc := load("res://scripts/virtual_controls.gd").new()
		vc.name = "VirtualControls"
		get_tree().root.add_child(vc)
		_virtual_controls = vc
	# Online: set up authority and sync — only when multiplayer peer is active
	if GameManager.is_online and multiplayer.multiplayer_peer != null:
		set_multiplayer_authority(player_peer_id)
		_setup_multiplayer_sync()


func _setup_multiplayer_sync() -> void:
	var sync := MultiplayerSynchronizer.new()
	sync.name = "NetSync"
	sync.set_multiplayer_authority(player_peer_id)
	var config := SceneReplicationConfig.new()
	config.add_property(NodePath(".:global_position"))
	config.add_property(NodePath(".:rotation"))
	sync.replication_config = config
	add_child(sync)


# RPC: authority peer (the client that owns this player) sends its input to the host.
# The host applies it; local authority doesn't need this path.
@rpc("any_peer", "call_local", "unreliable_ordered")
func _rpc_set_input(move: Vector2, aim: Vector2, throwing: bool) -> void:
	# Only the host (server) stores the received input; the authority peer drives locally.
	if not multiplayer.is_server():
		return
	if multiplayer.get_remote_sender_id() != player_peer_id:
		return  # reject spoofed input from wrong peer
	_net_move = move
	_net_aim = aim
	_net_throwing = throwing


func _physics_process(delta: float) -> void:
	if is_dead:
		_is_charging = false
		return
	if GameManager.current_state != GameManager.RoundState.PLAYING:
		velocity = Vector3.ZERO
		move_and_slide()
		_is_charging = false
		return

	# Network-controlled players (remote peers): position is handled by
	# MultiplayerSynchronizer; we still need move_and_slide() for the physics
	# engine to register the body, but we don't apply local input.
	if is_network_controlled:
		velocity = Vector3.ZERO
		move_and_slide()
		return

	# If we are the authority peer for an online player, gather input locally
	# and send it to the host via RPC so the host can run kill logic.
	if GameManager.is_online and multiplayer.multiplayer_peer != null:
		if is_multiplayer_authority() and not multiplayer.is_server():
			var move_in := _get_move_input()
			var aim_in  := _get_aim_input()
			var throw_h := _get_throw_held()
			rpc_id(1, "_rpc_set_input", move_in, aim_in, throw_h)

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

	if _slash_cooldown_timer > 0.0:
		_slash_cooldown_timer -= delta

	# --- Inputs: online host uses _net_* cache; everyone else reads locally ---
	var move_input: Vector2
	var aim_input: Vector2
	var throw_held: bool

	if GameManager.is_online and multiplayer.multiplayer_peer != null and multiplayer.is_server() and not is_multiplayer_authority():
		# Host driving a remote-owned player from its cached RPC input
		move_input = _net_move
		aim_input  = _net_aim
		throw_held = _net_throwing
	else:
		move_input = _get_move_input()
		aim_input  = _get_aim_input()
		throw_held = _get_throw_held()

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

	# --- Melee slash ---
	if is_bot and bot_controller != null:
		if bot_controller.get_desired_slash():
			_try_slash()
	else:
		var slash_held: bool = _get_slash_held()
		var slash_just_pressed: bool = slash_held and not _prev_slash
		_prev_slash = slash_held
		if slash_just_pressed:
			_try_slash()


func _get_throw_held() -> bool:
	if player_index == 0:
		if _virtual_controls != null and _virtual_controls.get_throw_held():
			return true
		return Input.is_key_pressed(KEY_SPACE) or Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT)
	return Input.is_joy_button_pressed(player_index - 1, JOY_BUTTON_A)


func _get_slash_held() -> bool:
	if player_index == 0:
		if _virtual_controls != null and _virtual_controls.get_slash_held():
			return true
		return Input.is_key_pressed(KEY_E)
	return Input.is_joy_button_pressed(player_index - 1, JOY_BUTTON_X)


func _get_move_input() -> Vector2:
	if is_bot and bot_controller != null:
		return bot_controller.get_desired_move()
	if player_index == 0:
		# Virtual joystick takes priority when a finger is on it
		if _virtual_controls != null:
			var vc_move: Vector2 = _virtual_controls.get_move()
			if vc_move.length() > 0.1:
				return vc_move
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
		# Virtual joystick takes priority when a finger is active on the right stick
		if _virtual_controls != null:
			var vc_aim: Vector2 = _virtual_controls.get_aim()
			if vc_aim.length() > 0.1:
				return vc_aim
		# Mouse aim: project cursor onto the XZ gameplay plane
		return _get_mouse_aim()
	var joy := player_index - 1
	var v := Vector2(Input.get_joy_axis(joy, JOY_AXIS_RIGHT_X),
					 Input.get_joy_axis(joy, JOY_AXIS_RIGHT_Y))
	return v if v.length() >= DEADZONE else Vector2.ZERO


func _get_mouse_aim() -> Vector2:
	var camera := get_viewport().get_camera_3d()
	if camera == null:
		return Vector2.ZERO
	var mouse_pos := get_viewport().get_mouse_position()
	var ray_origin := camera.project_ray_origin(mouse_pos)
	var ray_dir    := camera.project_ray_normal(mouse_pos)
	# Intersect ray with the gameplay plane (y = 0)
	if absf(ray_dir.y) < 0.001:
		return Vector2.ZERO
	var t := -ray_origin.y / ray_dir.y
	var world_pos := ray_origin + ray_dir * t
	var diff := Vector2(world_pos.x - global_position.x, world_pos.z - global_position.z)
	if diff.length() < 0.1:
		return Vector2.ZERO
	return diff.normalized()


func _throw(ratio: float) -> void:
	if dart_scene == null:
		return
	dart = dart_scene.instantiate()
	get_parent().add_child(dart)
	dart.launch(self, get_pos_2d(), aim_dir, ratio)


func get_pos_2d() -> Vector2:
	return Vector2(global_position.x, global_position.z)


func _try_slash() -> void:
	## Gates a slash on the same conditions the throw/charge logic respects.
	if is_dead:
		return
	if GameManager.current_state != GameManager.RoundState.PLAYING:
		return
	if _is_charging or _is_tripped:
		return
	if _slash_cooldown_timer > 0.0:
		return
	_slash_cooldown_timer = SLASH_COOLDOWN
	_perform_slash()


func _perform_slash() -> void:
	## Short-range directional melee: hits any non-self, alive player within
	## MELEE_RANGE and inside a forward-facing cone around aim_dir (a swing,
	## not a pulse). Lethal when the dart is in hand (dart == null); otherwise
	## it's a non-lethal kick — reuses the dart's trip() stagger effect.
	var my_pos: Vector2 = get_pos_2d()
	var cone_cos: float = cos(deg_to_rad(MELEE_CONE_DEG))
	for p in get_tree().get_nodes_in_group("players"):
		if p == self or p.is_dead:
			continue
		var to_target: Vector2 = p.get_pos_2d() - my_pos
		var dist: float = to_target.length()
		if dist < 0.01 or dist > MELEE_RANGE:
			continue
		if to_target.normalized().dot(aim_dir) < cone_cos:
			continue
		if dart == null:
			p.kill()
		else:
			p.trip()


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
	_slash_cooldown_timer = 0.0
	_prev_slash = false
	if _player_material != null:
		_player_material.albedo_color = player_color
	if dart != null:
		dart.queue_free()
		dart = null


func _on_dart_returned() -> void:
	dart = null
