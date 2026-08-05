extends CharacterBody3D
## Player controller — 2D logic on XZ plane, 3D rendering.
## Supports keyboard (player_index=0), gamepads (player_index>=1), and AI bots.
##
## WEAPON/COMBAT SYSTEM REMOVED (branch remove-weapon-system): the rope dart
## throw/anchor/recall weapon, its persistent PBD/RigidBody3D rope chain, melee
## slash, kill/trip/death, lives, and the leash tether are all gone from this
## script. What's left is pure movement/locomotion: WASD/gamepad/bot move
## input, dash, aim direction (kept as a general-purpose facing/aim primitive,
## not tied to any weapon), skeletal locomotion animation, and the platform
## ring-out boundary (kept as a map/movement feature — see _check_boundary_fall
## below — but decoupled from the old kill()/lives/respawn-timer pipeline: it
## now just teleports the player back to their spawn point instead of costing
## a life, since there is no life/round-outcome system left to feed).
##
## KNOWN GAP: bot_controller.gd was intentionally left untouched (per explicit
## direction) and still references dart/lives/is_dead/get_desired_throw/
## get_desired_slash — none of which exist on this script any more. See
## CLAUDE.md's "Known gaps after the weapon-system removal" section for the
## full disclosure of what specifically breaks and why it doesn't crash the
## whole game.

@export var move_speed: float = 6.0
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
const DASH_SPEED: float = 20.0
const DASH_DURATION: float = 0.15
const DASH_COOLDOWN: float = 0.25
const WALK_ANIM_SPEED: float = 2.0
## Half-extent of the platform on the XZ plane — must match the ground
## PlaneMesh/BoxShape3D size (30x30) in scenes/main.tscn. Stepping past this
## on either axis triggers a fall (see _check_boundary_fall / _start_fall).
const ARENA_HALF: float = 15.0
const FALL_DURATION: float = 1.0


@onready var aim_indicator: Node3D = $AimIndicator
@onready var collision_shape: CollisionShape3D = $PlayerCollision
## global_position.y sits at the physics capsule's CENTER (spawn markers add
## GameManager.PLAYER_HALF_HEIGHT so the capsule doesn't clip through the
## floor) but player_mesh's own root has no offset of its own, so without
## this it renders with its feet at that same capsule-center height instead
## of at the actual floor -- confirmed by direct measurement: the floor
## tiles' highest point is world Y=0.0, but the character's feet rendered
## at world Y=0.7 (== PLAYER_HALF_HEIGHT) before this offset existed.
@onready var _mesh_ground_offset: float = -GameManager.PLAYER_HALF_HEIGHT

var player_mesh: Node3D = null
var character_id: String = "char_barbarian"
## "" means "use character_id's own native accessory" -- see
## GameManager.resolve_headwear_id/resolve_cloth_id, called in _ready() below.
## Set by GameManager before add_child(player), same as character_id.
var character_headwear_id: String = ""
var character_cloth_id: String = ""
var _mesh_base_scale: Vector3 = Vector3.ONE
## One duplicated material per mesh part of the character (arms/body/head/
## legs/accessories) — KayKit characters are fully textured, so player-color
## identification is layered on as an emission tint (see _reset_player_tint)
## rather than overriding albedo_color, which would blank out the texture.
var _player_materials: Array[StandardMaterial3D] = []

var player_color: Color
var character_color: Color = Color(0.85, 0.08, 0.04, 1.0)   # set in _ready from CHARACTER_DEFS
var aim_dir: Vector2 = Vector2(0, 1)
var _facing_dir: Vector2 = Vector2(0, 1)  # last direction the mesh visually turned to face
var spawn_pos: Vector3
var bot_controller: Node = null

# Ring-out fall state — walking past the platform edge plays a short falling
# visual, then teleports the player back to spawn_pos. No lives/death system
# is involved any more (see this file's header comment).
var is_falling: bool = false
var _fall_tween: Tween = null
var _fall_timer: SceneTreeTimer = null

# Virtual on-screen controls — non-null only for player_index 0 on touch devices.
var _virtual_controls: Node = null

# Online multiplayer
var player_peer_id: int = 1          # which multiplayer peer owns this player
var is_network_controlled: bool = false  # true when a remote peer drives this player

# Dash state
var _dash_timer: float = 0.0
var _dash_cooldown_timer: float = 0.0
var _is_dashing: bool = false
var _dash_dir: Vector2 = Vector2.ZERO
var _prev_dash: bool = false

# Procedural animation state
var _run_bob_time: float = 0.0
var _move_speed_smooth: float = 0.0

# Skeletal locomotion animation (see _setup_animation() in _ready)
var _anim_player: AnimationPlayer = null
var _current_anim: String = ""

# Network input cache — written by _rpc_set_input, read by _physics_process
var _net_move: Vector2 = Vector2.ZERO
var _net_aim: Vector2 = Vector2.ZERO


func _ready() -> void:
	add_to_group("players")
	player_color = PLAYER_COLORS[clamp(player_index, 0, PLAYER_COLORS.size() - 1)]
	# Build the assembled character mesh (base body + headwear/cloth swap +
	# color tint) via the shared builder -- see character_builder.gd's header
	# comment for why swapping parts across characters skins correctly. "" on
	# either accessory id falls back to character_id's own native pick.
	var char_def: Dictionary = GameManager.get_character_def(character_id)
	var resolved_headwear: String = GameManager.resolve_headwear_id(character_id, character_headwear_id)
	var resolved_cloth: String = GameManager.resolve_cloth_id(character_id, character_cloth_id)
	player_mesh = CharacterBuilder.build_character_visual(character_id, resolved_headwear, resolved_cloth)
	character_color = char_def.get("character_color", player_color)
	if player_mesh != null:
		# KayKit Adventurers models are realistically human-proportioned
		# (~2.4-2.5 units tall at scale 1.0) — 0.85 uniform brings them to
		# roughly the same on-screen height the old fruit characters read at
		# (~2.0 units), without the old non-uniform stretch those needed.
		player_mesh.scale = Vector3(0.85, 0.85, 0.85)
		_mesh_base_scale = player_mesh.scale
		add_child(player_mesh)
		player_mesh.position.y = _mesh_ground_offset
	# Collect references to the override materials CharacterBuilder already
	# created (one per mesh part, including any swapped-in accessories) --
	# used for player-color emission tint identification (_reset_player_tint).
	_player_materials.clear()
	if player_mesh != null:
		for mi in CharacterBuilder.find_mesh_instances(player_mesh):
			var mat: StandardMaterial3D = mi.get_active_material(0) as StandardMaterial3D
			if mat != null:
				_player_materials.append(mat)
	_reset_player_tint()
	_setup_animation()
	if is_bot:
		bot_controller = get_node_or_null("BotController")
	# Virtual controls for touch devices (player_index 0, human only)
	if player_index == 0 and not is_bot and DisplayServer.is_touchscreen_available():
		var vc: Node = load("res://scripts/virtual_controls.gd").new()
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
func _rpc_set_input(move: Vector2, aim: Vector2) -> void:
	# Only the host (server) stores the received input; the authority peer drives locally.
	if not multiplayer.is_server():
		return
	if multiplayer.get_remote_sender_id() != player_peer_id:
		return  # reject spoofed input from wrong peer
	_net_move = move
	_net_aim = aim


## KayKit's Rig_Medium characters and both animation source files all share
## the exact same skeleton wrapper name ("Rig_Medium") and bone names, unlike
## the old fruit set (which needed each character's differently-named root
## renamed at runtime to match clips retargeted against one specific rig) —
## so the shared clips' "Rig_Medium/Skeleton3D:<bone>" track paths already
## resolve correctly against every character with no renaming at all.
const ANIM_SOURCES: Array[String] = [
	"res://assets/kaykit_adventurers/animations/Rig_Medium_MovementBasic.glb",
	"res://assets/kaykit_adventurers/animations/Rig_Medium_General.glb",
]

## The old fruit-character locomotion clips were authored with a "_Loop"
## name suffix, which Godot's glTF importer strips while also using it as a
## signal to mark the imported Animation resource as looping — so those
## clips came in already set to loop automatically. KayKit's clips have no
## such suffix (they're just "Idle_A", "Walking_A", ...), so they import
## with loop_mode left at its default of LOOP_NONE: continuously-used
## locomotion clips need it set explicitly or they play once and freeze on
## the last frame instead of cycling.
const LOOPING_CLIPS: Array[String] = [
	"Idle_A", "Idle_B", "Walking_A", "Walking_B", "Walking_C", "Running_A", "Running_B",
]

func _setup_animation() -> void:
	## Attach a fresh AnimationPlayer next to this character's Skeleton3D and
	## merge in clips from every file in ANIM_SOURCES (Walking_A/Running_A/
	## Jump_* from MovementBasic, Idle_A/Hit_A/Death_A/etc. from General).
	if player_mesh == null:
		return
	var skeleton: Skeleton3D = _find_skeleton(player_mesh)
	if skeleton == null:
		return
	# The new AnimationPlayer must live at the SAME level as the skeleton's
	# "Rig_Medium" wrapper (a sibling of it, not a child of it) so its
	# default root_node ("..") resolves the "Rig_Medium/Skeleton3D:..." track
	# paths correctly.
	var anim_player := AnimationPlayer.new()
	anim_player.name = "LocomotionPlayer"
	player_mesh.add_child(anim_player)
	var merged_lib := AnimationLibrary.new()
	for source_path in ANIM_SOURCES:
		var anim_scene: PackedScene = load(source_path)
		if anim_scene == null:
			continue
		var anim_instance: Node = anim_scene.instantiate()
		var src_player: AnimationPlayer = _find_animation_player(anim_instance)
		if src_player != null:
			for lib_name in src_player.get_animation_library_list():
				var lib: AnimationLibrary = src_player.get_animation_library(lib_name)
				for clip_name in lib.get_animation_list():
					if not merged_lib.has_animation(clip_name):
						merged_lib.add_animation(clip_name, lib.get_animation(clip_name))
		anim_instance.queue_free()
	for clip_name in LOOPING_CLIPS:
		if merged_lib.has_animation(clip_name):
			merged_lib.get_animation(clip_name).loop_mode = Animation.LOOP_LINEAR
	anim_player.add_animation_library("", merged_lib)
	_anim_player = anim_player


func _find_skeleton(node: Node) -> Skeleton3D:
	if node is Skeleton3D:
		return node
	for child in node.get_children():
		var found: Skeleton3D = _find_skeleton(child)
		if found != null:
			return found
	return null


func _find_animation_player(node: Node) -> AnimationPlayer:
	if node is AnimationPlayer:
		return node
	for child in node.get_children():
		var found: AnimationPlayer = _find_animation_player(child)
		if found != null:
			return found
	return null


func _reset_player_tint() -> void:
	## Normal resting appearance: full-opacity texture (albedo left white so
	## it multiplies to the texture's own colors unmodified) with a
	## character-color emission glow layered on top for identification.
	for mat in _player_materials:
		mat.albedo_color = Color.WHITE
		mat.transparency = BaseMaterial3D.TRANSPARENCY_DISABLED
		mat.emission_enabled = true
		mat.emission = character_color * 0.4


func _play_anim(anim_name: String, speed: float = 1.0) -> void:
	if _anim_player == null or _current_anim == anim_name:
		return
	if not _anim_player.has_animation(anim_name):
		return
	_anim_player.play(anim_name, -1.0, speed)
	_current_anim = anim_name


func _process(delta: float) -> void:
	# Smooth speed ratio toward current velocity magnitude (0.0–1.0)
	var speed_ratio: float = velocity.length() / move_speed
	_move_speed_smooth = lerp(_move_speed_smooth, speed_ratio, 10.0 * delta)

	if player_mesh == null:
		return
	if is_falling:
		return

	var is_moving: bool = _move_speed_smooth > 0.1 and not _is_dashing

	# Skeletal locomotion animation, using KayKit's actual clip names
	# (Idle_A from Rig_Medium_General.glb, Walking_A/Running_A from
	# Rig_Medium_MovementBasic.glb — see _setup_animation()'s ANIM_SOURCES).
	if _is_dashing:
		_play_anim("Running_A")
	elif is_moving:
		_play_anim("Walking_A", WALK_ANIM_SPEED)
	else:
		_play_anim("Idle_A")

	# Facing: smoothly turn the mesh to face the movement direction. KayKit's
	# modeled forward is actually +Z after import (same as the old fruit
	# models needed, confirmed visually), opposite of Basis.looking_at()'s -Z
	# convention, so look toward the reverse vector.
	var vel2d := Vector2(velocity.x, velocity.z)
	if vel2d.length() > 0.5:
		_facing_dir = vel2d.normalized()
		var dir3 := Vector3(vel2d.x, 0.0, vel2d.y).normalized()
		var desired_quat: Quaternion = Basis.looking_at(-dir3, Vector3.UP).get_rotation_quaternion()
		player_mesh.quaternion = player_mesh.quaternion.slerp(desired_quat, clampf(12.0 * delta, 0.0, 1.0))

	# Subtle procedural bob for extra juice — real leg/arm swing is now
	# animation-driven, so this only needs to be a light vertical accent.
	if is_moving:
		_run_bob_time += delta * 14.0
		var bob: float = sin(_run_bob_time) * _move_speed_smooth
		player_mesh.position.y = _mesh_ground_offset + bob * 0.06
	else:
		player_mesh.position.y = lerp(player_mesh.position.y, _mesh_ground_offset, 8.0 * delta)
		if _move_speed_smooth <= 0.1:
			_run_bob_time = lerp(_run_bob_time, 0.0, 5.0 * delta)


func _physics_process(delta: float) -> void:
	if is_falling:
		return
	if GameManager.current_state != GameManager.RoundState.PLAYING:
		velocity = Vector3.ZERO
		move_and_slide()
		return

	# Network-controlled players (remote peers): position is handled by
	# MultiplayerSynchronizer; we still need move_and_slide() for the physics
	# engine to register the body, but we don't apply local input.
	if is_network_controlled:
		velocity = Vector3.ZERO
		move_and_slide()
		_check_boundary_fall()
		return

	# If we are the authority peer for an online player, gather input locally
	# and send it to the host via RPC so the host can apply it.
	if GameManager.is_online and multiplayer.multiplayer_peer != null:
		if is_multiplayer_authority() and not multiplayer.is_server():
			var move_in := _get_move_input()
			var aim_in  := _get_aim_input()
			rpc_id(1, "_rpc_set_input", move_in, aim_in)

	# --- Inputs: online host uses _net_* cache; everyone else reads locally ---
	var move_input: Vector2
	var aim_input: Vector2

	if GameManager.is_online and multiplayer.multiplayer_peer != null and multiplayer.is_server() and not is_multiplayer_authority():
		# Host driving a remote-owned player from its cached RPC input
		move_input = _net_move
		aim_input  = _net_aim
	else:
		move_input = _get_move_input()
		aim_input  = _get_aim_input()

	# --- Dash cooldown countdown ---
	if _dash_cooldown_timer > 0.0:
		_dash_cooldown_timer -= delta

	# --- Dash duration countdown ---
	if _is_dashing:
		_dash_timer -= delta
		if _dash_timer <= 0.0:
			_is_dashing = false
			_dash_cooldown_timer = DASH_COOLDOWN

	# --- Dash activation ---
	if not _is_dashing and _dash_cooldown_timer <= 0.0:
		var dash_held: bool = _get_dash_pressed()
		if dash_held and not _prev_dash:
			var dash_dir: Vector2 = move_input if move_input.length() > 0.1 else _facing_dir
			_is_dashing = true
			_dash_timer = DASH_DURATION
			_dash_cooldown_timer = DASH_COOLDOWN
			_dash_dir = dash_dir.normalized()
		_prev_dash = dash_held

	# --- Velocity ---
	if _is_dashing:
		velocity = Vector3(_dash_dir.x, 0.0, _dash_dir.y) * DASH_SPEED
	else:
		if move_input.length() > 1.0:
			move_input = move_input.normalized()
		velocity = Vector3(move_input.x, 0.0, move_input.y) * move_speed
	move_and_slide()
	_check_boundary_fall()
	if is_falling:
		return

	# --- Aim indicator ---
	if aim_input.length() > DEADZONE:
		aim_dir = aim_input.normalized()
	elif move_input.length() > DEADZONE:
		aim_dir = move_input.normalized()
	aim_indicator.position = Vector3(aim_dir.x, 0.0, aim_dir.y) * 1.2


func _get_dash_pressed() -> bool:
	if is_bot and bot_controller != null:
		return bot_controller.get_desired_dash()
	if player_index == 0:
		return Input.is_key_pressed(KEY_SHIFT)
	return Input.is_joy_button_pressed(player_index - 1, JOY_BUTTON_LEFT_SHOULDER)


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


func get_pos_2d() -> Vector2:
	return Vector2(global_position.x, global_position.z)


func _check_boundary_fall() -> void:
	## Ring-out check: called unconditionally after move_and_slide().
	if is_falling:
		return
	if GameManager.current_state != GameManager.RoundState.PLAYING:
		return
	var p2d: Vector2 = get_pos_2d()
	if absf(p2d.x) > ARENA_HALF or absf(p2d.y) > ARENA_HALF:
		_start_fall()


func _start_fall() -> void:
	## Walked off the edge: sink/spin/shrink the mesh over FALL_DURATION, then
	## teleport back to spawn_pos (see _on_fall_finished) -- no lives/death
	## system exists any more (see this file's header comment), so this is a
	## pure "stay on the platform" boundary mechanic now, not a kill.
	if is_falling:
		return
	is_falling = true
	velocity = Vector3.ZERO
	collision_shape.disabled = true
	if player_mesh != null:
		_fall_tween = create_tween()
		_fall_tween.set_parallel(true)
		_fall_tween.tween_property(player_mesh, "position:y", player_mesh.position.y - 1.6, FALL_DURATION)\
			.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
		_fall_tween.tween_property(player_mesh, "scale", _mesh_base_scale * 0.15, FALL_DURATION)\
			.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
		_fall_tween.tween_property(player_mesh, "rotation:y", player_mesh.rotation.y + TAU * 1.5, FALL_DURATION)
	_fall_timer = get_tree().create_timer(FALL_DURATION)
	_fall_timer.timeout.connect(_on_fall_finished)


func _on_fall_finished() -> void:
	_reset_fall_visual()
	is_falling = false
	global_position = spawn_pos
	collision_shape.disabled = false


func _reset_fall_visual() -> void:
	if _fall_tween != null and _fall_tween.is_valid():
		_fall_tween.kill()
	_fall_tween = null
	if _fall_timer != null and _fall_timer.timeout.is_connected(_on_fall_finished):
		_fall_timer.timeout.disconnect(_on_fall_finished)
	_fall_timer = null
	if player_mesh != null:
		player_mesh.scale = _mesh_base_scale
		player_mesh.position.y = _mesh_ground_offset
		player_mesh.rotation.y = 0.0


func reset_for_round(start_pos: Vector3) -> void:
	## The only remaining round-start reset: reposition at the given spawn
	## point and clear any in-progress fall/dash state. No lives/dart/combat
	## state exists any more to reset (see this file's header comment).
	if is_falling:
		is_falling = false
		_reset_fall_visual()
	spawn_pos = start_pos
	global_position = start_pos
	collision_shape.disabled = false
	_is_dashing = false
	_dash_timer = 0.0
	_dash_cooldown_timer = 0.0
	_prev_dash = false
