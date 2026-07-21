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
const DASH_SPEED: float = 20.0
const DASH_DURATION: float = 0.15
const DASH_COOLDOWN: float = 0.25
const SLASH_COOLDOWN: float = 0.25
## Short-range directional melee: hits anything within MELEE_RANGE of the
## attacker AND within a MELEE_CONE_DEG half-angle of aim_dir, so it reads as
## a forward swing rather than an omnidirectional pulse.
const MELEE_RANGE: float = 1.4
const MELEE_CONE_DEG: float = 50.0
const WALK_ANIM_SPEED: float = 2.0
## Half-extent of the platform on the XZ plane — must match the ground
## PlaneMesh/BoxShape3D size (30x30) in scenes/main.tscn. Stepping past this
## on either axis triggers a fall (see _check_boundary_fall / _start_fall).
const ARENA_HALF: float = 15.0
const FALL_DURATION: float = 1.0
## How long a player is untouchable and can't throw right after spawning/respawning.
const SPAWN_INVINCIBLE_DURATION: float = 0.75

## Debug-only visualization of the dagger's hit-test radius around this player.
## Must match dagger.gd's hit_radius export — there's no shared constant
## between the two scripts, so keep these in sync by hand if either changes.
@export var show_hitbox_debug: bool = true
const HITBOX_DEBUG_RADIUS: float = 0.6

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
var _mesh_base_scale: Vector3 = Vector3.ONE
## Dagger model held in the character's hand until thrown -- see
## _setup_dagger_in_hand(); visibility mirrors (dart == null) every frame.
var _dagger_in_hand: Node3D = null

var player_color: Color
var character_color: Color = Color(0.85, 0.08, 0.04, 1.0)   # set in _ready from CHARACTER_DEFS
var aim_dir: Vector2 = Vector2(0, 1)
var _facing_dir: Vector2 = Vector2(0, 1)  # last direction the mesh visually turned to face
var dart: Node3D = null
var lives: int = 3
var is_dead: bool = false
var spawn_pos: Vector3
var bot_controller: Node = null

# Ring-out fall state — walking past the platform edge plays a short falling
# visual before funneling into the normal kill() pipeline.
var is_falling: bool = false
var _fall_tween: Tween = null
var _fall_timer: SceneTreeTimer = null

# Virtual on-screen controls — non-null only for player_index 0 on touch devices.
var _virtual_controls: Node = null

# Online multiplayer
var player_peer_id: int = 1          # which multiplayer peer owns this player
var is_network_controlled: bool = false  # true when a remote peer drives this player

var _prev_throw: bool = false
var _respawn_timer: SceneTreeTimer = null
## One duplicated material per mesh part of the character (arms/body/head/
## legs/accessories) — KayKit characters are fully textured, so player-color
## identification is layered on as an emission tint (see _reset_player_tint)
## rather than overriding albedo_color, which would blank out the texture.
## State-flash effects (trip, spawn invincibility) DO override albedo_color
## across all of them, since a full-color flash is the point there.
var _player_materials: Array[StandardMaterial3D] = []

# Charged throw state (human players only)
var _charge_time: float = 0.0
var _is_charging: bool = false

# Trip / slow state
var _trip_timer: float = 0.0
var _slow_timer: float = 0.0
var _is_tripped: bool = false

# Spawn invincibility — untouchable and can't throw for SPAWN_INVINCIBLE_DURATION
# after (re)spawning; see _respawn()/reset_for_round() and kill()/trip()/_throw().
var _spawn_invincible_timer: float = 0.0

# Dash state
var _dash_timer: float = 0.0
var _dash_cooldown_timer: float = 0.0
var _is_dashing: bool = false
var _dash_dir: Vector2 = Vector2.ZERO
var _prev_dash: bool = false

# Slash state
var _slash_cooldown_timer: float = 0.0

# Procedural animation state
var _run_bob_time: float = 0.0
var _move_speed_smooth: float = 0.0

# Skeletal locomotion animation (see _setup_animation() in _ready)
var _anim_player: AnimationPlayer = null
var _current_anim: String = ""

# Network input cache — written by _rpc_set_input, read by _physics_process
var _net_move: Vector2 = Vector2.ZERO
var _net_aim: Vector2 = Vector2.ZERO
var _net_throwing: bool = false


func _ready() -> void:
	add_to_group("players")
	player_color = PLAYER_COLORS[clamp(player_index, 0, PLAYER_COLORS.size() - 1)]
	# Load and attach character mesh dynamically
	var char_def: Dictionary = {}
	for def in GameManager.CHARACTER_DEFS:
		if def["id"] == character_id:
			char_def = def
			break
	if char_def.is_empty():
		char_def = GameManager.CHARACTER_DEFS[0]
	var char_scene: PackedScene = load(char_def["glb_path"])
	if char_scene != null:
		player_mesh = char_scene.instantiate()
		player_mesh.name = "CharacterMesh"
		# KayKit Adventurers models are realistically human-proportioned
		# (~2.4-2.5 units tall at scale 1.0) — 0.85 uniform brings them to
		# roughly the same on-screen height the old fruit characters read at
		# (~2.0 units), without the old non-uniform stretch those needed.
		player_mesh.scale = Vector3(0.85, 0.85, 0.85)
		_mesh_base_scale = player_mesh.scale
		add_child(player_mesh)
		player_mesh.position.y = _mesh_ground_offset
	# Tint every mesh part with the character color (emission layer, texture
	# stays visible underneath) — see _player_materials' declaration for why.
	character_color = char_def.get("character_color", player_color)
	_player_materials.clear()
	if player_mesh != null:
		for mi in _find_mesh_instances(player_mesh):
			var base_mat: Material = mi.get_active_material(0)
			var mat: StandardMaterial3D = (base_mat.duplicate() as StandardMaterial3D) if base_mat is StandardMaterial3D else StandardMaterial3D.new()
			mi.set_surface_override_material(0, mat)
			_player_materials.append(mat)
	_reset_player_tint()
	_setup_animation()
	_setup_dagger_in_hand()
	if show_hitbox_debug:
		_setup_hitbox_debug()
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


func _setup_hitbox_debug() -> void:
	## Flat circle outline at ground level showing dagger.gd's hit_radius,
	## so the actual dart-collision test radius can be sanity-checked visually.
	var verts := PackedVector3Array()
	const SEGMENTS := 32
	for i in range(SEGMENTS + 1):
		var angle: float = TAU * float(i) / float(SEGMENTS)
		verts.append(Vector3(cos(angle), 0.0, sin(angle)) * HITBOX_DEBUG_RADIUS)
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_LINE_STRIP, arrays)
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(1.0, 0.0, 0.0, 0.9)
	mesh.surface_set_material(0, mat)
	var mi := MeshInstance3D.new()
	mi.name = "HitboxDebugCircle"
	mi.mesh = mesh
	# _mesh_ground_offset is the local Y where player_mesh's feet actually
	# sit (true floor level) -- a tiny lift above that keeps this from
	# z-fighting the floor tiles.
	mi.position = Vector3(0.0, _mesh_ground_offset + 0.02, 0.0)
	add_child(mi)


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


## KayKit's Rig_Medium characters and both animation source files all share
## the exact same skeleton wrapper name ("Rig_Medium") and bone names, unlike
## the old fruit set (which needed each character's differently-named root
## renamed at runtime to match clips retargeted against one specific rig) —
## so the shared clips' "Rig_Medium/Skeleton3D:<bone>" track paths already
## resolve correctly against every character with no renaming at all.
## combat_moves.glb is not a KayKit source file -- it's Spell_Simple_Shoot/
## Sword_Attack/Punch_Jab from Quaternius's Universal Animation Library
## (assets/animations/UAL1_Standard.glb), retargeted onto a bare "Rig_Medium"
## armature via world-space Copy Rotation constraints in Blender (same
## technique as assets/animations/build_character_locomotion.py used for the
## old fruit rig, just with a fuller ~20-bone map and re-exported under the
## "Rig_Medium" name so its track paths resolve the same way as the two
## KayKit files below).
const ANIM_SOURCES: Array[String] = [
	"res://assets/kaykit_adventurers/animations/Rig_Medium_MovementBasic.glb",
	"res://assets/kaykit_adventurers/animations/Rig_Medium_General.glb",
	"res://assets/animations/combat_moves.glb",
]

## The old fruit-character locomotion clips were authored with a "_Loop"
## name suffix, which Godot's glTF importer strips while also using it as a
## signal to mark the imported Animation resource as looping — so those
## clips came in already set to loop automatically. KayKit's clips have no
## such suffix (they're just "Idle_A", "Walking_A", ...), so they import
## with loop_mode left at its default of LOOP_NONE: continuously-used
## locomotion clips need it set explicitly or they play once and freeze on
## the last frame instead of cycling. One-shot clips (Death/Hit/Throw/
## Jump_*/etc.) are deliberately NOT in this list — those should play once.
const LOOPING_CLIPS: Array[String] = [
	"Idle_A", "Idle_B", "Walking_A", "Walking_B", "Walking_C", "Running_A", "Running_B",
]

## One-shot action clips triggered from gameplay code (throw/slash/kick) --
## _process()'s per-frame locomotion selection must not stomp these mid-play,
## see the action_playing guard there.
const ONE_SHOT_ACTION_CLIPS: Array[String] = ["Spell_Simple_Shoot", "Sword_Attack", "Punch_Jab"]

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
	# Merge every clip from every source into ONE default ("") library rather
	# than add_animation_library() per source file — both source files import
	# their clips under the same default library name, so adding both under
	# that name directly would just overwrite the first with the second
	# instead of combining them. First source wins on any name collision
	# (only "T-Pose" collides between the two, and it's unused either way).
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


func _setup_dagger_in_hand() -> void:
	## Every character rig has a "handslot.r" bone -- a KayKit-authored
	## attachment point parented right under hand.r, positioned at the palm
	## with its local -Y axis as the grip direction (confirmed by inspecting
	## its rest transform) -- exactly what BoneAttachment3D needs. Reuses
	## dagger.gd's own dart_head.glb model so the in-hand and in-flight dagger
	## look identical. Visibility is kept in sync with (dart == null) in
	## _process() rather than at each of _throw()/_on_dart_returned()/kill()/
	## reset_for_round(), so there's a single source of truth for it.
	if player_mesh == null:
		return
	var skeleton: Skeleton3D = _find_skeleton(player_mesh)
	if skeleton == null:
		return
	var dagger_scene: PackedScene = load("res://assets/characters/dart_head.glb")
	if dagger_scene == null:
		return
	var attachment := BoneAttachment3D.new()
	attachment.name = "DaggerAttachment"
	attachment.bone_name = "handslot.r"
	skeleton.add_child(attachment)
	var dagger_instance: Node3D = dagger_scene.instantiate()
	dagger_instance.name = "DaggerInHand"
	attachment.add_child(dagger_instance)
	_dagger_in_hand = attachment


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


func _find_mesh_instances(node: Node) -> Array[MeshInstance3D]:
	var found: Array[MeshInstance3D] = []
	if node is MeshInstance3D:
		found.append(node)
	for child in node.get_children():
		found.append_array(_find_mesh_instances(child))
	return found


func _apply_player_tint(color: Color, transparency: BaseMaterial3D.Transparency = BaseMaterial3D.TRANSPARENCY_DISABLED) -> void:
	for mat in _player_materials:
		mat.albedo_color = color
		mat.transparency = transparency


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
	if _dagger_in_hand != null:
		_dagger_in_hand.visible = (dart == null)
	if is_dead or is_falling:
		return

	var is_moving: bool = _move_speed_smooth > 0.1 and not _is_dashing

	# Skeletal locomotion animation, using KayKit's actual clip names
	# (Idle_A from Rig_Medium_General.glb, Walking_A/Running_A from
	# Rig_Medium_MovementBasic.glb — see _setup_animation()'s ANIM_SOURCES).
	# Dash takes priority over the is_moving check — while dashing we're moving
	# far faster than a walk, so cut straight to the run clip regardless of the
	# (dash-excluded) is_moving state used for Walk/Idle and the procedural bob.
	# A one-shot action clip (kicking / getting kicked) gets to finish playing
	# first -- otherwise this per-frame selection would stomp it within a
	# single frame of it starting, since nothing here else calls _play_anim().
	var action_playing: bool = _anim_player != null and _current_anim in ONE_SHOT_ACTION_CLIPS and _anim_player.is_playing()
	if action_playing:
		pass
	elif _is_dashing:
		_play_anim("Running_A")
	elif is_moving:
		_play_anim("Walking_A", WALK_ANIM_SPEED)
	else:
		_play_anim("Idle_A")

	# Facing: smoothly turn the mesh to face the movement direction. KayKit's
	# modeled forward is actually +Z after import (same as the old fruit
	# models needed, confirmed visually — the glTF/Godot -Z-forward
	# assumption in a prior version of this comment was wrong), opposite of
	# Basis.looking_at()'s -Z convention, so look toward the reverse vector.
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
	if is_dead:
		_is_charging = false
		return
	if is_falling:
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
		_check_boundary_fall()
		return

	# If we are the authority peer for an online player, gather input locally
	# and send it to the host via RPC so the host can run kill logic.
	if GameManager.is_online and multiplayer.multiplayer_peer != null:
		if is_multiplayer_authority() and not multiplayer.is_server():
			var move_in := _get_move_input()
			var aim_in  := _get_aim_input()
			var throw_h := _get_throw_held()
			rpc_id(1, "_rpc_set_input", move_in, aim_in, throw_h)

	# --- Spawn invincibility countdown ---
	if _spawn_invincible_timer > 0.0:
		_spawn_invincible_timer = maxf(_spawn_invincible_timer - delta, 0.0)
		if _spawn_invincible_timer == 0.0 and not _player_materials.is_empty():
			_reset_player_tint()

	# --- Trip / slow countdown ---
	var effective_speed: float = move_speed
	# Can't move while winding up a throw -- aiming is meant to be a
	# deliberate, planted stance, not something you can reposition during.
	var movement_blocked: bool = _is_charging

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
			if not _player_materials.is_empty():
				_reset_player_tint()
		else:
			effective_speed = move_speed * 0.5

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

	# --- Dash cooldown countdown ---
	if _dash_cooldown_timer > 0.0:
		_dash_cooldown_timer -= delta

	# --- Dash duration countdown ---
	if _is_dashing:
		_dash_timer -= delta
		if _dash_timer <= 0.0:
			_is_dashing = false
			_dash_cooldown_timer = DASH_COOLDOWN

	# --- Dashing breaks out of a trip ---
	if _is_dashing and _is_tripped:
		_is_tripped = false
		_trip_timer = 0.0
		_slow_timer = 0.0

	# --- Dash activation (not while tripped) ---
	if not _is_dashing and _dash_cooldown_timer <= 0.0 and not movement_blocked:
		var dash_held: bool = _get_dash_pressed()
		if dash_held and not _prev_dash:
			var dash_dir: Vector2 = move_input if move_input.length() > 0.1 else _facing_dir
			_is_dashing = true
			_dash_timer = DASH_DURATION
			_dash_cooldown_timer = DASH_COOLDOWN
			_dash_dir = dash_dir.normalized()
		_prev_dash = dash_held

	# --- Slash cooldown countdown ---
	if _slash_cooldown_timer > 0.0:
		_slash_cooldown_timer -= delta

	# --- Slash activation: cooldown-gated only, no press-edge requirement
	# (unlike dash) -- holding the button attacks again as soon as the 0.25s
	# cooldown clears, since this is a fast repeatable melee poke rather than
	# a one-shot burst like dash. Blocked while dashing/charging/tripped so
	# the two moves stay distinct and it can't fire during spawn invincibility.
	if _slash_cooldown_timer <= 0.0 and not movement_blocked and not _is_dashing and _spawn_invincible_timer <= 0.0:
		if _get_slash_held():
			_perform_slash()
			_slash_cooldown_timer = SLASH_COOLDOWN

	# --- Velocity ---
	if _is_dashing:
		velocity = Vector3(_dash_dir.x, 0.0, _dash_dir.y) * DASH_SPEED
	elif movement_blocked:
		velocity = Vector3.ZERO
	else:
		if move_input.length() > 1.0:
			move_input = move_input.normalized()
		velocity = Vector3(move_input.x, 0.0, move_input.y) * effective_speed
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

	# --- Throw / charge logic ---
	# No rope to recall anymore: a dagger is either still in flight or lying
	# on the ground wherever it landed, and getting it back means walking
	# over to it (see dagger.gd's LANDED state) — pressing throw again while
	# dart != null just does nothing, whether it's flying or already landed.
	if is_bot and bot_controller != null:
		# Bots use a one-shot flag; throw immediately at difficulty-based ratio
		if bot_controller.get_desired_throw() and dart == null:
			var diff: int = clamp(bot_controller.difficulty, 0, BOT_CHARGE_RATIOS.size() - 1)
			var bot_ratio: float = float(BOT_CHARGE_RATIOS[diff])
			_throw(bot_ratio)
	else:
		# Human players: hold to charge, release to fire
		var throw_just_pressed: bool = throw_held and not _prev_throw
		var throw_just_released: bool = not throw_held and _prev_throw
		_prev_throw = throw_held

		if throw_just_pressed and dart == null:
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
		if _virtual_controls != null and _virtual_controls.get_throw_held():
			return true
		return Input.is_key_pressed(KEY_SPACE) or Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT)
	return Input.is_joy_button_pressed(player_index - 1, JOY_BUTTON_A)


func _get_dash_pressed() -> bool:
	if is_bot and bot_controller != null:
		return bot_controller.get_desired_dash()
	if player_index == 0:
		return Input.is_key_pressed(KEY_SHIFT)
	return Input.is_joy_button_pressed(player_index - 1, JOY_BUTTON_LEFT_SHOULDER)


func _get_slash_held() -> bool:
	if is_bot and bot_controller != null:
		return bot_controller.get_desired_slash()
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
	if _spawn_invincible_timer > 0.0:
		return
	dart = dart_scene.instantiate()
	get_parent().add_child(dart)
	dart.launch(self, get_pos_2d(), aim_dir, ratio)
	_play_anim("Spell_Simple_Shoot")


func get_pos_2d() -> Vector2:
	return Vector2(global_position.x, global_position.z)


func _perform_slash() -> void:
	## Lethal if the attacker still has their dagger in hand (dart == null) --
	## same one-hit-kill economy as a dagger throw, with Sword_Attack as the
	## swing. Otherwise (dagger thrown and unavailable) it's a non-lethal kick
	## (Punch_Jab): reuses trip()'s stagger so a disarmed player still has a
	## way to disrupt an armed opponent up close.
	_play_anim("Sword_Attack" if dart == null else "Punch_Jab")
	var my_pos: Vector2 = get_pos_2d()
	var cone_cos: float = cos(deg_to_rad(MELEE_CONE_DEG))
	for p in get_tree().get_nodes_in_group("players"):
		if p == self or p.is_dead:
			continue
		var to_target: Vector2 = p.get_pos_2d() - my_pos
		var dist: float = to_target.length()
		if dist > MELEE_RANGE or dist < 0.001:
			continue
		if to_target.normalized().dot(aim_dir) < cone_cos:
			continue
		if dart == null:
			p.kill()
		else:
			p.trip()


func _check_boundary_fall() -> void:
	## Ring-out check: called unconditionally after move_and_slide(), the same
	## way dagger.gd calls kill() locally wherever its own hit-check runs —
	## no separate networked-authority arbitration for this.
	if is_dead or is_falling:
		return
	if GameManager.current_state != GameManager.RoundState.PLAYING:
		return
	var p2d: Vector2 = get_pos_2d()
	if absf(p2d.x) > ARENA_HALF or absf(p2d.y) > ARENA_HALF:
		_start_fall()


func _start_fall() -> void:
	## Distinct "walked off the edge" death: sink/spin/shrink the mesh over
	## FALL_DURATION, then funnel into the normal kill() pipeline so lives,
	## respawn, and round-end logic are untouched.
	if is_falling or is_dead:
		return
	is_falling = true
	velocity = Vector3.ZERO
	collision_shape.disabled = true
	_is_charging = false
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
	kill()


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


func trip() -> void:
	## Apply a trip effect: freeze 0.4s then slow to 50% for 1.5s.
	## No-ops if already frozen or slowed (immunity window), or while
	## spawn-invincible.
	if _spawn_invincible_timer > 0.0:
		return
	if _is_tripped or _slow_timer > 0.0:
		return
	_is_tripped = true
	_trip_timer = 0.4
	if not _player_materials.is_empty():
		_apply_player_tint(Color(1.0, 0.5, 0.0))  # orange tint


func kill() -> void:
	if is_dead:
		return
	if _spawn_invincible_timer > 0.0:
		return
	is_dead = true
	if is_falling:
		is_falling = false
		_reset_fall_visual()
	lives -= 1
	if player_mesh != null:
		player_mesh.visible = false
	collision_shape.disabled = true
	if dart != null:
		dart.queue_free()
		dart = null
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
	if player_mesh != null:
		player_mesh.visible = true
	collision_shape.disabled = false
	_start_spawn_invincibility()


func reset_for_round(new_lives: int, start_pos: Vector3) -> void:
	if _respawn_timer != null and not _respawn_timer.is_queued_for_deletion():
		if _respawn_timer.timeout.is_connected(_respawn):
			_respawn_timer.timeout.disconnect(_respawn)
	_respawn_timer = null
	if is_falling:
		is_falling = false
		_reset_fall_visual()
	lives = new_lives
	spawn_pos = start_pos
	global_position = start_pos
	is_dead = false
	if player_mesh != null:
		player_mesh.visible = true
	collision_shape.disabled = false
	set_physics_process(true)
	_prev_throw = false
	_is_charging = false
	_charge_time = 0.0
	_trip_timer = 0.0
	_slow_timer = 0.0
	_is_tripped = false
	_is_dashing = false
	_dash_timer = 0.0
	_dash_cooldown_timer = 0.0
	_prev_dash = false
	_slash_cooldown_timer = 0.0
	if not _player_materials.is_empty():
		_reset_player_tint()
	if dart != null:
		dart.queue_free()
		dart = null
	_start_spawn_invincibility()


func _start_spawn_invincibility() -> void:
	_spawn_invincible_timer = SPAWN_INVINCIBLE_DURATION
	if not _player_materials.is_empty():
		var c: Color = character_color
		c.a = 0.5
		_apply_player_tint(c, BaseMaterial3D.TRANSPARENCY_ALPHA)


func _on_dart_returned() -> void:
	dart = null
