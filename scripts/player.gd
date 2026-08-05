extends CharacterBody3D
## Player controller — 2D logic on XZ plane, 3D rendering.
## Supports keyboard (player_index=0), gamepads (player_index>=1), and AI bots.
##
## Post-GDD-rewrite rebuild status (see docs/implementation-plan.md): the
## weapon/combat system was intentionally stripped to bare movement ahead of
## the GDD rewrite, then rebuilt phase by phase. Phase 1 re-added the
## persistent rope_dart.gd instance (HOLSTERED/CHARGING/FLYING/EMBEDDED) and
## its leash velocity clamp (_apply_rope_leash_velocity_clamp). Phase 2 (this
## pass) adds RETURNING (_handle_recall_input/_get_recall_held) and combat:
## is_dead + take_dart_hit() (dart contact, always lethal) and _trip_timer +
## apply_rope_trip() (rope-line contact, movement debuff only, never lethal)
## — both called from rope_dart.gd's own _check_player_hits(), not from here.
## No lives/round-outcome tracking exists yet (Phase 5) — a "kill" is just an
## instant teleport to spawn_pos, same minimal shape the ring-out fall
## already used (_start_fall/_on_fall_finished) before this rebuild, just
## without the fall animation.
##
## KNOWN GAP: bot_controller.gd was intentionally left mostly untouched
## through Phase 2 (per explicit direction — full bot rework is Phase 6) and
## still has some rough/dead logic (e.g. its "darts" group dodge loop is a
## silent no-op since rope_dart.gd is deliberately not added to that group —
## see rope_dart.gd's own header comment). It was patched just enough this
## phase to not crash against the new dart/is_dead shape.

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
## Fixed rotation applied to raw human move/aim input (keyboard, gamepad
## sticks, virtual joystick) so screen-up/right consistently matches
## up/right on the isometric-yawed camera -- see _compute_camera_yaw_offset()
## below. Cached once in _ready() since the camera's yaw is a fixed constant
## (arena_camera.gd only pans/zooms, never rotates -- see its own comments).
## NOT applied to bot_controller.gd's output: bots compute their desired
## move/aim directly from world-space player positions (to_target vectors --
## see bot_controller.gd's _physics_process), so their output is already
## correct world-space and must NOT be rotated again here.
var _move_rotation_offset: float = 0.0
var aim_dir: Vector2 = Vector2(0, 1)
var _facing_dir: Vector2 = Vector2(0, 1)  # last direction the mesh visually turned to face
var spawn_pos: Vector3
var bot_controller: Node = null

# Rope dart -- one persistent instance per player (see rope_dart.gd's own
# header comment): HOLSTERED/CHARGING/FLYING/EMBEDDED are all states of this
# SAME node, never null, so "is the dart out" is read from dart.state, not
# from dart being present. Mirrors rope_dart.gd's State enum ordinals by hand
# (no shared constant between the two scripts -- same convention this
# project used before the weapon-system removal).
const DART_STATE_HOLSTERED := 0
const DART_STATE_CHARGING := 1
const DART_STATE_FLYING := 2
const DART_STATE_EMBEDDED := 3
const DART_STATE_RETURNING := 5
var dart: Node = null
var _prev_throw_held: bool = false
var _prev_recall_held: bool = false

# Combat (Phase 2 -- see rope_dart.gd's _check_player_hits()). Dart contact
# is always lethal in every away-state; rope-line contact only trips/slows.
# No lives/round tracking yet (Phase 5) -- a "kill" here is just an instant
# teleport back to spawn_pos, same minimal-consequence shape as the ring-out
# fall already uses (_start_fall/_on_fall_finished), just without the fall
# animation since a dart kill doesn't need one.
var is_dead: bool = false
const RESPAWN_INVULN_TIME: float = 0.3  ## brief window after respawn where
## this player can't be re-targeted/re-killed the same tick they teleport in
## (guards against a degenerate case where spawn_pos itself sits inside a
## still-lethal dart's hit/trip radius) -- see _physics_process()'s countdown.
var _invuln_timer: float = 0.0

const TRIP_DURATION: float = 0.6
const TRIP_SPEED_MULT: float = 0.35  ## how much rope-contact slows movement
var _trip_timer: float = 0.0

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
	_move_rotation_offset = _compute_camera_yaw_offset()
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
	# Rope dart: one persistent instance, added as a sibling in the current
	# scene (not a child of this CharacterBody3D) so it can move independently
	# once thrown -- see rope_dart.gd's own header comment.
	var dart_scene: PackedScene = load("res://scenes/rope_dart.tscn")
	dart = dart_scene.instantiate()
	dart.owner_player = self
	get_tree().current_scene.add_child(dart)
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

	# --- Respawn invuln / rope-trip countdowns ---
	if _invuln_timer > 0.0:
		_invuln_timer -= delta
		if _invuln_timer <= 0.0:
			is_dead = false
	if _trip_timer > 0.0:
		_trip_timer -= delta

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
		# Rope-trip debuff: a brief movement slow, never lethal (see
		# apply_rope_trip()) -- does not affect dash, which stays at full
		# DASH_SPEED above so a tripped player can still burst free.
		var trip_mult: float = TRIP_SPEED_MULT if _trip_timer > 0.0 else 1.0
		velocity = Vector3(move_input.x, 0.0, move_input.y) * move_speed * trip_mult
	_apply_rope_leash_velocity_clamp()
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

	# --- Rope dart throw: hold to charge, release to throw ---
	_handle_throw_input()
	# --- Rope dart recall: pulls the dart back toward this player at
	# increasing speed (see rope_dart.gd's begin_recall()/_process_returning()) ---
	_handle_recall_input()


func _get_dash_pressed() -> bool:
	if is_bot and bot_controller != null:
		return bot_controller.get_desired_dash()
	if player_index == 0:
		return Input.is_key_pressed(KEY_SHIFT)
	return Input.is_joy_button_pressed(player_index - 1, JOY_BUTTON_LEFT_SHOULDER)


func _get_action_held() -> bool:
	## Unified Throw/Recall input signal (Right Trigger / Left Mouse / Space /
	## touch Throw button, per the GDD Controls section) -- Throw and Recall
	## are now the SAME physical input everywhere (keyboard/mouse, gamepad,
	## touch), gated purely by dart.state in _handle_throw_input() (HOLSTERED/
	## CHARGING) vs _handle_recall_input() (FLYING/EMBEDDED). This does NOT
	## cover bots: see _get_throw_held()/_get_recall_held() below, which read
	## bot_controller.gd's independent get_desired_throw()/get_desired_recall()
	## AI decisions instead of this shared physical signal.
	if player_index == 0:
		if _virtual_controls != null and _virtual_controls.get_throw_held():
			return true
		return Input.is_key_pressed(KEY_SPACE) or Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT)
	var joy := player_index - 1
	if Input.is_joy_button_pressed(joy, JOY_BUTTON_RIGHT_SHOULDER):
		return true
	return Input.get_joy_axis(joy, JOY_AXIS_TRIGGER_RIGHT) > 0.3


func _get_throw_held() -> bool:
	## NOTE: bots (get_desired_throw()) return a one-shot "throw now" pulse,
	## not a true held/level signal -- bot throwing is already known-broken
	## (see this file's header comment) and out of scope this phase; this
	## just keeps that call from crashing, it doesn't make bots throw well.
	if is_bot and bot_controller != null:
		return bot_controller.get_desired_throw()
	return _get_action_held()


func _handle_throw_input() -> void:
	if dart == null or not is_instance_valid(dart):
		return
	var held: bool = _get_throw_held()
	if held and not _prev_throw_held and dart.state == DART_STATE_HOLSTERED:
		dart.begin_charge()
	elif not held and _prev_throw_held and dart.state == DART_STATE_CHARGING:
		dart.release_throw(aim_dir)
	_prev_throw_held = held


func _get_recall_held() -> bool:
	## Same physical signal as _get_throw_held() for humans/gamepad/touch --
	## Throw and Recall are one button, gated by dart.state (see
	## _get_action_held()'s comment). Bots are the one exception: they keep an
	## independent get_desired_recall() AI decision, since a bot has no single
	## physical "button" whose state can double for both intents.
	if is_bot and bot_controller != null:
		return bot_controller.get_desired_recall()
	return _get_action_held()


func _handle_recall_input() -> void:
	if dart == null or not is_instance_valid(dart):
		return
	var held: bool = _get_recall_held()
	if held and not _prev_recall_held and (dart.state == DART_STATE_FLYING or dart.state == DART_STATE_EMBEDDED):
		dart.begin_recall()
	_prev_recall_held = held


func _apply_rope_leash_velocity_clamp() -> void:
	## Once the dart is EMBEDDED (a taut, stationary anchor), keep the player
	## from walking further from it than the rope allows -- a velocity
	## projection applied BEFORE move_and_slide(), not a position snap after,
	## so the player's own canonical position is never discontinuously moved.
	##
	## Wrap-aware as of Task #7 item 4: rather than a plain circle of radius
	## dart.rope_length around the anchor, pivot on the LAST wrap point
	## between the anchor and the player (dart.get_rope_path_2d(), the exact
	## same live wrapped path the rope's own visual/FLYING-constraint/
	## hit-detection all already use -- see rope_dart.gd's own header comment
	## on that mechanism), with the allowed radius from that pivot shrunk by
	## however much of the total rope_length the wrap segments before it have
	## already consumed. In the common unobstructed case the path is just
	## [anchor, player] and this reduces exactly to the old plain-circle
	## behavior (pivot=anchor, radius=rope_length, zero behavior change).
	if dart == null or not is_instance_valid(dart) or dart.state != DART_STATE_EMBEDDED:
		return
	var player_pos: Vector2 = get_pos_2d()
	var path: PackedVector2Array = dart.get_rope_path_2d(player_pos)
	var pivot: Vector2 = dart.pos_2d
	var radius: float = dart.rope_length
	if path.size() > 2:
		var consumed := 0.0
		for i in path.size() - 2:
			consumed += path[i].distance_to(path[i + 1])
		pivot = path[path.size() - 2]
		radius = maxf(dart.rope_length - consumed, 0.0)
	var offset: Vector2 = player_pos - pivot
	var dist: float = offset.length()
	if dist <= radius or dist < 0.0001:
		return
	var radial_dir: Vector2 = offset / dist
	var vel2d := Vector2(velocity.x, velocity.z)
	var outward: float = vel2d.dot(radial_dir)
	if outward > 0.0:
		vel2d -= radial_dir * outward
		velocity.x = vel2d.x
		velocity.z = vel2d.y


## Called by rope_dart.gd's _check_player_hits() when the dart HEAD overlaps
## this player in any away-state -- always lethal (GDD Combat: "Dart Contact
## ... Always lethal. Applies in every dart state: Flying, Embedded landing,
## Swinging, Returning"). Minimal Phase 2 kill: teleport to spawn_pos, no
## VFX/lives/round tracking (that's Phase 5 -- see this file's header
## comment and docs/implementation-plan.md's Phase 2 section).
func take_dart_hit() -> void:
	if is_dead:
		return
	is_dead = true
	_invuln_timer = RESPAWN_INVULN_TIME
	_trip_timer = 0.0
	velocity = Vector3.ZERO
	_is_dashing = false
	_dash_timer = 0.0
	global_position = spawn_pos


## Called by rope_dart.gd's _check_player_hits() when the ROPE LINE (not the
## dart head) overlaps this player -- never lethal, just a brief movement
## debuff (GDD Combat: "Rope Contact ... trips and slows -- never lethal").
func apply_rope_trip() -> void:
	if is_dead:
		return
	_trip_timer = TRIP_DURATION


func _get_move_input() -> Vector2:
	if is_bot and bot_controller != null:
		# Bots reason entirely in world-space (to_target = target_pos - my_pos,
		# both already world XZ -- see bot_controller.gd's _physics_process),
		# so their output must NOT be rotated by the camera-relative offset
		# below; only raw human input (keyboard/gamepad/touch) needs it.
		return bot_controller.get_desired_move()
	if player_index == 0:
		# Virtual joystick takes priority when a finger is on it
		if _virtual_controls != null:
			var vc_move: Vector2 = _virtual_controls.get_move()
			if vc_move.length() > 0.1:
				return vc_move.rotated(_move_rotation_offset)
		var raw := Vector2(
			float(Input.is_key_pressed(KEY_D)) - float(Input.is_key_pressed(KEY_A)),
			float(Input.is_key_pressed(KEY_S)) - float(Input.is_key_pressed(KEY_W))
		)
		return raw.rotated(_move_rotation_offset)
	var joy := player_index - 1
	var v := Vector2(Input.get_joy_axis(joy, JOY_AXIS_LEFT_X),
					 Input.get_joy_axis(joy, JOY_AXIS_LEFT_Y))
	return v.rotated(_move_rotation_offset) if v.length() >= DEADZONE else Vector2.ZERO


func _get_aim_input() -> Vector2:
	if is_bot and bot_controller != null:
		# Same world-space reasoning as _get_move_input() above -- don't rotate.
		return bot_controller.get_desired_aim()
	if player_index == 0:
		# Virtual joystick takes priority when a finger is active on the right stick
		if _virtual_controls != null:
			var vc_aim: Vector2 = _virtual_controls.get_aim()
			if vc_aim.length() > 0.1:
				return vc_aim.rotated(_move_rotation_offset)
		# Mouse aim: project cursor onto the XZ gameplay plane -- already
		# camera-correct via project_ray_origin/normal, do NOT rotate this.
		return _get_mouse_aim()
	var joy := player_index - 1
	var v := Vector2(Input.get_joy_axis(joy, JOY_AXIS_RIGHT_X),
					 Input.get_joy_axis(joy, JOY_AXIS_RIGHT_Y))
	return v.rotated(_move_rotation_offset) if v.length() >= DEADZONE else Vector2.ZERO


## Fixed rotation to apply to raw human move/aim input vectors (keyboard
## D-A/S-W, gamepad left/right stick axes, virtual-joystick screen-space
## offsets) so that "up" on the input device consistently maps to "up" on
## screen under the isometric-yawed camera. Derived from the camera's actual
## ground-projected right vector rather than a hardcoded degree constant, so
## a future camera angle tweak (see arena_camera.gd) doesn't silently break
## this again. Falls back to the camera's known 45-degree yaw if no camera
## is available yet (shouldn't normally happen -- main.tscn's Camera3D is a
## sibling node already in the tree before players are added).
func _compute_camera_yaw_offset() -> float:
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return -PI / 4.0
	var right_xz := Vector2(cam.global_transform.basis.x.x, cam.global_transform.basis.x.z)
	if right_xz.length() < 0.001:
		return -PI / 4.0
	return right_xz.angle()


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
