extends CharacterBody3D
## Player controller — 2D logic on XZ plane, 3D rendering.
## Supports keyboard (player_index=0), gamepads (player_index>=1), and AI bots.

signal player_killed(player: Node)
signal player_eliminated(player: Node)

## Loaded via explicit preload() (not the bare class_name RopeChainPBD global
## symbol rope_chain_pbd.gd also declares for editor convenience) so this
## script never depends on Godot's global script class cache having already
## been rebuilt -- that cache is only refreshed by the editor scanning the
## project, which a fresh headless test run (this project's own primary
## verification method, see CLAUDE.md) does not do, and referencing the bare
## global name in that situation is a hard parse error, not a runtime one.
const RopeChainPBDScript: Script = preload("res://scripts/rope_chain_pbd.gd")

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
## Winding up a throw: the dart head orbits the hand on a short taut rope --
## see _update_charge_spin(). Speed ramps from MIN at the start of a charge
## up to MAX at a full charge (matching the same charge_ratio that scales
## the eventual throw's speed/range in _throw()), so a harder-charged throw
## visibly winds up faster.
const CHARGE_SPIN_RADIUS: float = 0.35
const CHARGE_SPIN_SPEED_MIN: float = TAU * 3.0  # ~3 rev/sec at the start of a charge
const CHARGE_SPIN_SPEED_MAX: float = TAU * 7.0  # ~7 rev/sec at a full charge
## dart_head.glb's own local geometry, measured directly off its exported
## glTF vertex data (NOT by re-importing into Blender, which silently
## converts back from glTF's Y-up to Blender's Z-up and hides the real
## axes): blade tip at local Z=-0.55, pommel at local Z=+0.315 -- so "blade
## forward" is local -Z, and a rope should attach at the pommel end
## (DAGGER_POMMEL_OFFSET), not the model's origin. Duplicated from
## rope_dart.gd's own copy of this same constant/comment rather than shared
## across the two scripts -- see HITBOX_DEBUG_RADIUS for this codebase's
## existing precedent on tolerating small hand-synced duplication like this.
const DAGGER_POMMEL_OFFSET: float = 0.315
## Once a charge hits MAX_CHARGE_TIME, "Sword_Idle" is already holding its
## final frame (it's a one-shot clip, not looped -- see LOOPING_CLIPS'
## comment) -- a small fast tremble on top of that held pose reads as
## "straining at max power" and gives a clear release-now cue.
const CHARGE_SHAKE_AMPLITUDE: float = 0.025
const CHARGE_SHAKE_FREQUENCY: float = TAU * 18.0
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

## Mirrors rope_dart.gd's State.ANCHORED ordinal — no shared constant between
## the two scripts (see HITBOX_DEBUG_RADIUS's comment above), so keep this in
## sync by hand if it changes. Used by _clamp_to_rope_leash() to keep the
## owner from wandering past the tether's reach once the dart is anchored.
const DART_STATE_ANCHORED: int = 1

## ROUND 15 (2026-07-25) RESIZE, per explicit user direction: "The rope is
## supposed to be 6 times the character's height." Character height was
## originally derived from GameManager.PLAYER_HALF_HEIGHT (0.7 -> 1.4 full
## height) rather than the raw scenes/player.tscn CapsuleShape3D.height (1.2),
## on the reasoning that two other real gameplay systems (spawn positioning's
## ground-offset math and rope_dart.gd's own capsule_height export) already
## agreed on 1.4.
##
## ROUND 16 (2026-07-25) CORRECTION, per direct user instruction: ROUND 15's
## own pick of 1.4 actually made the rope LONGER (6x1.4=8.4) than its
## pre-ROUND-15 value (8.0) -- which contradicted the user's actual stated
## goal that round, "the rope is currently too long." Flagged this
## contradiction and asked whether the raw physics capsule height (1.2,
## giving 6x1.2=7.2 -- genuinely shorter, as the user wanted) was intended
## instead. User's reply, verbatim: "Change to 1.2." Now derived from
## GameManager.PLAYER_CAPSULE_HEIGHT (see that constant's own comment for why
## it has to be a hand-mirrored value rather than read from the .tscn
## directly) instead of PLAYER_HALF_HEIGHT*2.0 -- referenced directly, not a
## bare magic literal, so this stays correct if the character's size is ever
## retuned again.
const DART_ROPE_LENGTH: float = 6.0 * GameManager.PLAYER_CAPSULE_HEIGHT

## Rope visual radius -- the physics segments' own capsule collision radius
## AND the rendered chain-link mesh's tube radius (see _build_chain_link_mesh()) share this
## single constant. ROUND (full architecture reset, see CLAUDE.md): the old
## separate idle-coil visual (ROPE_SEGMENTS cheap kinematic MeshInstance3D
## cylinders, redrawn as a spiral while dart == null) is GONE -- per direct
## user mandate ("I want the rope to be a physic object just like the
## character, tree, or pillar... When held, all segments collapse into the
## character's hand"), the idle look is now just this same persistent
## 32-segment physics chain (see ROPE_PHYSICS_SEGMENTS below) resting bunched
## at the hand, not a separate rendering system.
const ROPE_RADIUS: float = 0.035

## --- PBD/Verlet rope chain: ONE persistent object per player, created once
## in _ready() and never torn down/rebuilt per-throw -- see
## scripts/rope_chain_pbd.gd (RopeChainPBD) for the full simulation itself,
## and CLAUDE.md's dated "PBD/Verlet rope rewrite" round entry for why this
## replaced the prior RigidBody3D + PhysicsServer3D pin-joint chain (three
## separate joint-tuning attempts across earlier rounds all failed to make
## that chain's segments never separate, with real measured regressions each
## time -- see that file's own history for the full writeup). The user's own
## words this round: "There shouldn't be any radius to compute. Regardless of
## anchored or not, the rope bar should be attached to the next rope bar and
## never separate. When the rope bars are stretched completely, character
## cannot move further."
##
## Mechanism: _rope_chain (a RopeChainPBD instance) holds ROPE_PHYSICS_SEGMENTS
## + 1 points on the XZ plane. points[0] (hand) and points[last] (tip) are
## driven kinematically every physics tick by _update_physics_rope_anchors()
## -- get_hand_world_position() whenever dart == null (the tip COINCIDES with
## the hand), the dart's own live position otherwise -- exactly mirroring the
## old chain's kinematic hand/tip anchor bodies. Every interior point is
## Verlet-integrated and iteratively constrained (RopeChainPBD.step()) so
## that NO consecutive pair can ever end up farther apart than
## ROPE_PHYSICS_SEGMENT_LENGTH -- a hard, exact, every-tick guarantee, not a
## soft joint approximation. "Collapse at the hand" / "unfold on throw" /
## "fold on retrieve" all still fall directly out of this one mechanism with
## no separate pacing logic: see RopeChainPBD's own class doc comment for why
## a one-sided (<=) distance constraint alone produces exactly this behavior.
##
## Y-PLANE LOCK (non-negotiable, unchanged from every earlier round -- per
## explicit user requirement, "I want the rope to disregard gravity and live
## on a plane"): the whole chain is simulated in 2D (Vector2 on the XZ plane)
## in the first place -- there is no Y coordinate to drift, gravity to
## disregard, or per-step correction needed at all. This is a direct, load-
## bearing consequence of moving the simulation into this project's own
## "gameplay math runs on the XZ plane as Vector2" architecture invariant,
## not a separate mechanism layered on top of a 3D physics body the way the
## old rope_segment_body.gd's per-tick Y-clamp was.
##
## COLLISION against obstacle geometry (pillars, tree/cactus scatter boxes)
## is real, direct per-point correction against every "obstacles" group
## member's own get_rect_2d() (see RopeChainPBD._resolve_collisions()) --
## the same real, authoritative 2D obstacle data this project's own
## architecture already treats as the ground truth for XZ-plane gameplay
## math, not synthetic/invented geometry and not a from-scratch "compute
## where the rope should route" correction.
const ROPE_PHYSICS_SEGMENTS: int = 24
## Total simulated chain length always equals DART_ROPE_LENGTH (the dart's
## own fixed max range) regardless of the CURRENT hand-to-dart distance --
## each of ROPE_PHYSICS_SEGMENTS links has this as its own fixed, individual
## maximum length (see RopeChainPBD.segment_max_length).
const ROPE_PHYSICS_SEGMENT_LENGTH: float = DART_ROPE_LENGTH / float(ROPE_PHYSICS_SEGMENTS)

## Per-interior-point XZ speed clamp during Verlet integration -- a
## legitimate physical damping-style bound (how fast any ONE point can move
## in a single tick), not a position/path clamp deciding where a point
## "should" be. Kept from the old chain's own MAX_SEGMENT_SPEED at the same
## value/reasoning: comfortably above the dart's own fastest legitimate
## speed (recall_speed 24.0, travel_speed up to 36.0 at full charge) so a
## point can keep pace with a real thrown/recalled dart, while still bounding
## any solver-driven single-tick spike (e.g. a kinematic endpoint snapping a
## large distance) from compounding across ticks. Unlike the old RigidBody3D
## chain, THIS clamp is now a secondary safety net rather than the primary
## rigidity guarantee -- the hard one-sided distance constraint in
## RopeChainPBD.step() is what actually makes segments never separate, at
## every tick, regardless of this clamp's value.
const ROPE_INTERIOR_MAX_SPEED: float = 45.0

## Iterations of (distance constraint sweep + collision correction) run every
## physics tick -- see RopeChainPBD.step(). Higher = tighter convergence
## (both for the "never separate" distance guarantee under a same-tick
## cascading correction, and for real obstacle collision), at a linear CPU
## cost (O(segments) per iteration, all plain Vector2 math -- cheap even at
## this count for the handful of chains a real match ever has active).
## An upper CAP, not a fixed cost -- RopeChainPBD._converge_distance() exits
## early the moment every consecutive pair is within CONVERGENCE_EPS of its
## own segment_max_length, so a typical at-rest tick converges in only a
## couple of iterations regardless of this cap; this value only matters on
## the (rare) ticks that genuinely need many sweeps to resolve a fresh
## perturbation cascading through an already-slack chain. Sized generously
## (200) based on direct measurement -- see rope_chain_pbd.gd's own step()
## doc comment for the specific probe and numbers this was verified against.
const ROPE_SOLVER_ITERATIONS: int = 600

## Same root cause and fix as the old chain's own ROPE_ANCHOR_MAX_SPEED --
## _play_anim() cuts between animation clips with no cross-fade, so the
## ANIMATED hand bone _get_rope_hand_anchor_pos() reads every physics tick
## can pop by up to ~0.9 units in a single tick whenever a bot (or player)
## switches locomotion/action clips (Idle_A <-> Walking_A <-> Running_A <->
## Punch_Jab, etc). Left completely unclamped, that pop would be fed straight
## into the chain's kinematic hand point every tick -- caps how fast
## _update_physics_rope_anchors() is allowed to MOVE that kinematic target
## per tick (Vector2.move_toward(), a plain step-size clamp, not a position
## computed from geometry). Comfortably above DASH_SPEED's own real 20.0
## units/sec ceiling (so every legitimate continuous root-motion case passes
## through unclamped) but well below the measured ~0.65-0.92-unit clip-switch
## jumps.
const ROPE_ANCHOR_MAX_SPEED: float = 26.0

## A large, genuinely-discrete target jump (a real teleport, e.g. the
## _ready()-time default position vs. the real post-spawn position, before
## reset_for_round() has run even once yet) SNAPS instantly instead of being
## rate-limited by ROPE_ANCHOR_MAX_SPEED above -- rate-limiting a jump this
## large would drag the whole chain across the map over real time, sweeping
## through obstacles on the way. Sized well above the largest legitimate
## small-scale animation clip-switch pop (~0.92 units) and well below any
## real spawn-point-to-spawn-point distance on this arena.
const ROPE_ANCHOR_SNAP_THRESHOLD: float = 2.0

## --- Chain-of-rings mesh rendering for the rope (visual only -- traces the
## real physics chain's own control points, see above). 2026-07-31: replaced
## the old single smooth Catmull-Rom tube with a real chain of separate oval
## ring links, one per PBD segment (control_points[i] -> control_points[i+1]),
## per explicit user request ("update the rope bar to ring, make joints
## visible for better testing") -- see _build_chain_link_mesh(). Smoothing a
## spline through the real control points was exactly what HID each
## segment's own true endpoint from view; a chain of rings makes every real
## joint directly visible as the boundary between two links, with no
## obstacle-awareness or correction of any kind added (same standing
## constraint as the old tube renderer -- if a ring ever visibly clips a
## pillar, the real PBD segment it traces is itself inside the obstacle,
## a physics bug to fix in rope_chain_pbd.gd, not something to mask here).
## Radial cross-section resolution of the tube extruded around each ring's
## own oval outline -- 8-sided reads as round at this game's camera distance
## without excessive triangle count.
const ROPE_TUBE_RADIAL_SEGMENTS: int = 8
## Points per semicircular end-cap of each ring's stadium/racetrack outline
## (two straight sides + two caps = 2*ROPE_CHAIN_CAP_SEGMENTS + 2 points per
## ring). 6 reads as a smooth curve at this game's camera distance.
const ROPE_CHAIN_CAP_SEGMENTS: int = 6
## Short-axis width of each ring link -- a few multiples of ROPE_RADIUS
## (the tube's own thickness), same proportion a real chain link's width
## bears to its own wire gauge.
const ROPE_CHAIN_LINK_WIDTH: float = 0.16


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
## The handslot.r BoneAttachment3D itself -- stays visible=true always;
## _static_dagger_mesh and the charge-spin visuals (its children) each
## control their own visibility independently.
var _dagger_in_hand: Node3D = null
## The actual held-dagger mesh, a child of _dagger_in_hand -- see
## _setup_dagger_in_hand(); visible while (dart == null and not charging),
## since the charge-spin visuals take over depicting the weapon while
## winding up a throw.
var _static_dagger_mesh: Node3D = null
## Shared material for the physics-rope tube mesh -- stored here (rather than
## only as a local in _setup_dagger_in_hand()) so _build_chain_link_mesh() can reuse
## the exact same look without duplicating the material setup.
var _rope_material: StandardMaterial3D = null
## The real PBD/Verlet rope chain (see scripts/rope_chain_pbd.gd and the
## ROPE_PHYSICS_* consts' comment above) -- ONE PERSISTENT object per player,
## created once in _init_rope_chain() (called from _ready()) and simply
## dropped (no RID/resource cleanup needed -- it's plain Vector2 data, not a
## physics-server object) in _exit_tree(). NOT rebuilt per-throw -- its "idle
## collapsed at the hand" / "thrown, unfolding" / "retrieving, folding" looks
## are all just this one chain's own live, continuously-simulated
## configuration, driven purely by where its tip point is currently being
## told to go (see _get_rope_tip_target()).
var _rope_chain: RefCounted = null
## True once _init_rope_chain() has built _rope_chain -- guards against a
## double-init; never goes back to false during a player's lifetime.
var _physics_rope_active: bool = false
## Cached once per player (obstacles are static StaticBody3D nodes that never
## move mid-match) rather than re-querying the "obstacles" group every solver
## iteration of every physics tick -- see _rope_obstacle_rects().
var _rope_obstacle_rects_cache: Array = []
var _rope_obstacle_rects_cached: bool = false
## Persisted smoothed hand/tip anchor targets (see _step_or_snap_2d()) --
## these used to live as an actual RigidBody3D's own global_position; now
## they're just the last value handed to RopeChainPBD.step(), remembered here
## so the ROPE_ANCHOR_MAX_SPEED ramp has something to step FROM each tick.
var _hand_anchor_smoothed_2d: Vector2 = Vector2.ZERO
var _tip_anchor_smoothed_2d: Vector2 = Vector2.ZERO
## The single continuous tube MeshInstance3D that visually replaces the
## per-segment CylinderMesh/capsule rendering -- see this file's
## ROPE_TUBE_RADIAL_SEGMENTS doc comment and _update_rope_tube_mesh(). Rebuilt
## (not just repositioned) every _process() frame the physics chain is
## active, since the curve it traces changes shape continuously as the
## simulated points move.
var _physics_rope_tube_mesh: MeshInstance3D = null
## Dart head that orbits the hand on a taut rope while charging, depicting
## winding up the throw -- see _update_charge_spin().
var _charge_spin_dart: Node3D = null
var _charge_spin_rope: MeshInstance3D = null
var _charge_spin_angle: float = 0.0
## Elapsed time at max charge -- drives the tremble in the bob/shake block of
## _process(); see CHARGE_SHAKE_AMPLITUDE's comment.
var _charge_shake_time: float = 0.0

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
## True for the duration of an active rope dart recall -- see the throw-again
## branch in _physics_process() and _on_dart_returned(). Drives the "Push"
## animation override in _process() (a looping clip -- note the imported name
## has its "_Loop" suffix stripped by Godot's glTF importer, same as it does
## for KayKit's own clips, see ANIM_SOURCES' comment -- so unlike the one-shot
## action clips it needs an explicit end condition rather than relying on
## AnimationPlayer.is_playing() going false on its own).
var _is_recalling: bool = false
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
	# see _player_materials' declaration for why trip()/spawn-invincibility
	# need direct handles to these rather than re-deriving them each time.
	_player_materials.clear()
	if player_mesh != null:
		for mi in CharacterBuilder.find_mesh_instances(player_mesh):
			var mat: StandardMaterial3D = mi.get_active_material(0) as StandardMaterial3D
			if mat != null:
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


func _exit_tree() -> void:
	## The persistent PBD rope chain (see _init_rope_chain()) is no longer
	## freed between throws or rounds -- it now only ever needs cleanup once,
	## when this player node itself is actually leaving the tree for good
	## (round-transition scene teardown, match end, etc.). Unlike the old
	## RigidBody3D + PhysicsServer3D chain, there's no RID to explicitly free
	## here -- _free_physics_rope() just drops the reference.
	_free_physics_rope()


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
## spell_cast.glb is the same technique applied to 3 more UAL clips --
## Spell_Simple_Enter/Spell_Simple_Idle_Loop/Spell_Simple_Exit -- retargeted
## in a separate Blender pass (headless `blender --background --python`, not
## the interactive MCP bridge, which crashed on this project's UAL1_Standard
## import; see the retargeting commit for the reconstructed 16-bone map:
## hips/spine/chest/head + both arms + both legs) and exported as its own
## small glb rather than appended into the already-working combat_moves.glb,
## so the two throw/melee clips already retargeted there are never touched.
## Drives the throw's Enter->Idle->Exit sequence in _process() (see
## ThrowAnimPhase) -- Spell_Simple_Shoot itself (still in combat_moves.glb)
## is no longer played; the 3-phase sequence replaces it entirely per
## explicit user direction ("Use Spell Simple Enter, idle, and exit").
const ANIM_SOURCES: Array[String] = [
	"res://assets/kaykit_adventurers/animations/Rig_Medium_MovementBasic.glb",
	"res://assets/kaykit_adventurers/animations/Rig_Medium_General.glb",
	"res://assets/animations/combat_moves.glb",
	"res://assets/animations/spell_cast.glb",
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

## One-shot action clips triggered from gameplay code (slash/kick) --
## _process()'s per-frame locomotion selection must not stomp these mid-play,
## see the action_playing guard there. Throw/recall are NOT one-shot clips
## any more -- see ThrowAnimPhase/RecallAnimPhase below for their own
## Enter->Hold->Exit sequencing, which is driven by elapsed time rather than
## AnimationPlayer.is_playing() (see _advance_throw_anim()'s comment for why).
const ONE_SHOT_ACTION_CLIPS: Array[String] = ["Sword_Attack", "Punch_Jab"]

## Throw and recall are each a 3-phase Enter -> Hold -> Exit sequence built
## from the same two bookend clips (Spell_Simple_Enter/Spell_Simple_Exit,
## see spell_cast.glb's own doc comment above) around a different Hold clip
## per action -- Spell_Simple_Idle_Loop for the throw's brief "cast held"
## moment, the pre-existing "Push" loop for the recall's actual reel-in
## motion (unchanged from before this feature; CLAUDE.md's own move-design
## notes already call this "Retrieval (Reel In)" and Push_Loop already reads
## as pulling something back, so it stays the Hold clip rather than being
## replaced).
##
## Phase advancement is driven by ELAPSED TIME (per-phase timers below,
## ticked every _process() frame in _advance_throw_anim()/
## _advance_recall_anim()), not by AnimationPlayer.is_playing() -- unlike
## the melee ONE_SHOT_ACTION_CLIPS guard above. This is deliberate: per this
## feature's hard requirement, movement must be able to instantly cut the
## DISPLAYED clip to Walking_A/Running_A mid-sequence (see _process()'s
## selection chain), which means the AnimationPlayer itself may be showing a
## movement clip instead of the sequence's own clip for a stretch of real
## time -- so is_playing()/is the-sequence-clip-still-current can't be relied
## on to track sequence progress, since the sequence's own clip may not be
## the one actually loaded into the (single, shared) AnimationPlayer at all
## right then. A plain elapsed-time timer against each clip's own real
## Animation.length (see _anim_clip_length()) advances correctly regardless
## of what's currently being displayed, then resumes displaying whatever
## phase is current the moment movement stops -- at the cost of not
## resuming mid-clip (a fresh movement interruption always restarts the
## current phase's clip from frame 0 once movement stops), a deliberate,
## documented trade-off for correctness+simplicity over frame-perfect
## resumption.
enum ThrowAnimPhase { NONE, ENTER, HOLD, EXIT }
var _throw_anim_phase: int = ThrowAnimPhase.NONE
var _throw_anim_timer: float = 0.0
var _recall_anim_phase: int = ThrowAnimPhase.NONE
var _recall_anim_timer: float = 0.0
## Mirrors rope_dart.gd's State.FLYING ordinal -- see DART_STATE_ANCHORED's
## own comment above for why this is duplicated by hand rather than shared.
## Drives the throw sequence's HOLD->EXIT transition: held for as long as
## the just-thrown dart is still actually flying (a fast point-blank hit
## exits almost immediately; a full-range throw that anchors at max
## ROPE_LENGTH holds noticeably longer), matching the real weapon behavior
## instead of a fixed timer.
const DART_STATE_FLYING: int = 0
## Mirrors rope_dart.gd's State.RECALLING ordinal -- same hand-synced
## duplication as DART_STATE_ANCHORED/DART_STATE_FLYING above. Used by
## _physics_process()'s recall-anim sync check so the Enter->Push->Exit
## sequence and _is_recalling stay in step with the dart's REAL state
## regardless of what triggered RECALLING -- an explicit throw-again press
## (which already sets these directly) or rope_dart.gd's own walk-to-pickup
## path (see rope_dart.gd's ANCHORED branch), which transitions the dart into
## RECALLING internally with no player.gd involvement at all.
const DART_STATE_RECALLING: int = 2

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
	## its rest transform) -- exactly what BoneAttachment3D needs for the
	## dart head (reuses rope_dart.gd's own dart_head.glb so the in-hand and
	## in-flight weapon look identical).
	##
	## The held dagger's visibility is kept in sync with (dart == null) in
	## _process() rather than at each of _throw()/_on_dart_returned()/kill()/
	## reset_for_round(), so there's a single source of truth for it. The
	## persistent PBD rope chain (see _init_rope_chain(), called at the
	## end of this function) is a completely separate object that always
	## exists regardless of (dart == null) -- its own configuration (collapsed
	## at the hand vs. unfolded) is what changes, not its presence.
	##
	## Also builds the charge-spin visuals (a second dart-head instance plus
	## a short rope) as extra children of the same handslot.r attachment --
	## they inherit the exact same hand tracking with no extra bone lookups,
	## and stay hidden except while _is_charging (see _update_charge_spin()).
	if player_mesh == null:
		return
	var skeleton: Skeleton3D = _find_skeleton(player_mesh)
	if skeleton == null:
		return

	var dagger_attachment := BoneAttachment3D.new()
	dagger_attachment.name = "DaggerAttachment"
	dagger_attachment.bone_name = "handslot.r"
	skeleton.add_child(dagger_attachment)
	_dagger_in_hand = dagger_attachment

	var dagger_scene: PackedScene = load("res://assets/characters/dart_head.glb")
	if dagger_scene != null:
		var dagger_instance: Node3D = dagger_scene.instantiate()
		dagger_instance.name = "DaggerInHand"
		dagger_attachment.add_child(dagger_instance)
		_static_dagger_mesh = dagger_instance

		var spin_instance: Node3D = dagger_scene.instantiate()
		spin_instance.name = "ChargeSpinDart"
		spin_instance.visible = false
		dagger_attachment.add_child(spin_instance)
		_charge_spin_dart = spin_instance

	# Rope material/mesh duplicated here rather than shared with
	# rope_dart.tscn's sub-resources -- see HITBOX_DEBUG_RADIUS's comment for
	# this codebase's existing precedent of tolerating a small hand-synced
	# duplication over loading/instancing a whole separate scene just to
	# borrow two resources.
	var spin_rope_mat := StandardMaterial3D.new()
	spin_rope_mat.albedo_color = Color(0.22, 0.16, 0.12)
	spin_rope_mat.metallic = 0.1
	spin_rope_mat.roughness = 0.75
	spin_rope_mat.emission_enabled = true
	spin_rope_mat.emission = Color(0.1, 0.07, 0.05)
	var spin_rope_shape := CylinderMesh.new()
	spin_rope_shape.top_radius = 0.02
	spin_rope_shape.bottom_radius = 0.02
	spin_rope_shape.height = 1.0
	var spin_rope := MeshInstance3D.new()
	spin_rope.name = "ChargeSpinRope"
	spin_rope.mesh = spin_rope_shape
	spin_rope.set_surface_override_material(0, spin_rope_mat)
	spin_rope.visible = false
	dagger_attachment.add_child(spin_rope)
	_charge_spin_rope = spin_rope

	# Rope tube material -- shared by _build_chain_link_mesh() every frame the
	# persistent physics chain's tube mesh is rebuilt (see
	# _update_rope_tube_mesh()). Stored once here rather than duplicated per
	# rebuild.
	var rope_mat := StandardMaterial3D.new()
	rope_mat.albedo_color = Color(0.22, 0.16, 0.12)
	rope_mat.metallic = 0.1
	rope_mat.roughness = 0.75
	rope_mat.emission_enabled = true
	rope_mat.emission = Color(0.1, 0.07, 0.05)
	_rope_material = rope_mat

	# Build the persistent PBD rope chain now -- _dagger_in_hand (the real
	# hand attachment get_hand_world_position() reads) is set above. See
	# _init_rope_chain()'s own doc comment for why this happens exactly ONCE
	# per player instead of per-throw.
	_init_rope_chain()


func _update_charge_spin(delta: float) -> void:
	## Winding up: the dart orbits the hand on a short taut rope while
	## charging. The spin's plane is parallel to the character -- built from
	## world UP and the character's own facing direction (_facing_dir) in
	## world space, rather than the hand bone's local axes, so the circle
	## stays aligned with the character's body/facing regardless of whatever
	## arm angle the "Sword_Idle" charge pose happens to hold (which isn't
	## necessarily facing-aligned itself). This needs global positions/
	## transforms rather than the attachment's local space, unlike most of
	## this codebase's other per-bone visual code. Speed ramps up with
	## charge progress so a fuller charge visibly winds up faster, matching
	## the harder throw it produces (see _throw()'s own charge_ratio use).
	## Depicts "spinning the rope" during the windup, distinct from the
	## Wrap/Grapple-Bind design note in CLAUDE.md (that's about the thrown
	## dart's arc, not this pre-throw animation).
	if _charge_spin_dart == null or _charge_spin_rope == null:
		return
	if not _is_charging:
		_charge_spin_dart.visible = false
		_charge_spin_rope.visible = false
		return

	var charge_ratio: float = clampf(_charge_time / MAX_CHARGE_TIME, 0.0, 1.0)
	var spin_speed: float = lerp(CHARGE_SPIN_SPEED_MIN, CHARGE_SPIN_SPEED_MAX, charge_ratio)
	_charge_spin_angle = fmod(_charge_spin_angle + spin_speed * delta, TAU)

	var forward_3d: Vector3 = Vector3(_facing_dir.x, 0.0, _facing_dir.y)
	var offset: Vector3 = forward_3d * (cos(_charge_spin_angle) * CHARGE_SPIN_RADIUS) \
		+ Vector3.UP * (sin(_charge_spin_angle) * CHARGE_SPIN_RADIUS)
	var pivot: Vector3 = _dagger_in_hand.global_position
	var dart_world: Vector3 = pivot + offset
	_charge_spin_dart.visible = true
	_charge_spin_dart.global_position = dart_world

	var length: float = offset.length()
	if length < 0.001:
		_charge_spin_rope.visible = false
		return
	var out_dir: Vector3 = offset / length
	# Blade points radially outward (away from the pivot, the same direction
	# the dart is currently orbiting toward) -- local -Z, per
	# DAGGER_POMMEL_OFFSET's comment on the model's own axes.
	var z_axis: Vector3 = -out_dir
	var basis_seed: Vector3 = Vector3.RIGHT if absf(z_axis.dot(Vector3.UP)) > 0.99 else Vector3.UP
	var x_axis: Vector3 = basis_seed.cross(z_axis).normalized()
	var y_axis: Vector3 = z_axis.cross(x_axis).normalized()
	_charge_spin_dart.global_transform.basis = Basis(x_axis, y_axis, z_axis)

	# Rope attaches at the pommel (opposite end from the outward-pointing
	# blade), not the dart's origin -- pommel sits DAGGER_POMMEL_OFFSET back
	# toward the pivot along the same radial line.
	var pommel_world: Vector3 = dart_world - out_dir * DAGGER_POMMEL_OFFSET
	var rope_length: float = pivot.distance_to(pommel_world)
	if rope_length < 0.001:
		_charge_spin_rope.visible = false
		return
	_charge_spin_rope.visible = true
	var rope_y_axis: Vector3 = (pommel_world - pivot) / rope_length
	var rope_seed: Vector3 = Vector3.RIGHT if absf(rope_y_axis.dot(Vector3.UP)) > 0.99 else Vector3.UP
	var rope_x_axis: Vector3 = rope_seed.cross(rope_y_axis).normalized()
	var rope_z_axis: Vector3 = rope_x_axis.cross(rope_y_axis).normalized()
	_charge_spin_rope.global_transform = Transform3D(
		Basis(rope_x_axis, rope_y_axis * rope_length, rope_z_axis), pivot + (pommel_world - pivot) * 0.5
	)


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


## Real length of an imported clip, or a short fallback if the clip is
## missing (e.g. the Blender retarget didn't produce it) -- see
## ThrowAnimPhase's doc comment for why phase advancement is timed against
## this instead of AnimationPlayer.is_playing(). Godot's glTF importer
## strips a "_Loop"/"-loop" suffix and marks the result as looping (see
## LOOPING_CLIPS' own comment on this codebase's existing precedent with
## "Push_Loop" -> "Push") -- callers pass the POST-STRIP name, matching
## every other clip-name reference in this file.
func _anim_clip_length(clip_name: String, fallback: float = 0.3) -> float:
	if _anim_player != null and _anim_player.has_animation(clip_name):
		return maxf(_anim_player.get_animation(clip_name).length, 0.05)
	return fallback


## Advances the throw sequence's own phase/timer state every _process()
## frame, independent of whether that phase's clip is actually the one
## loaded in the (single, shared) AnimationPlayer right now -- see
## ThrowAnimPhase's doc comment. No-op once the phase is NONE (nothing
## thrown, or the previous sequence already finished).
func _advance_throw_anim(delta: float) -> void:
	if _throw_anim_phase == ThrowAnimPhase.NONE:
		return
	_throw_anim_timer += delta
	match _throw_anim_phase:
		ThrowAnimPhase.ENTER:
			if _throw_anim_timer >= _anim_clip_length("Spell_Simple_Enter"):
				_throw_anim_phase = ThrowAnimPhase.HOLD
				_throw_anim_timer = 0.0
		ThrowAnimPhase.HOLD:
			# Held for as long as the dart is still actually FLYING -- see
			# DART_STATE_FLYING's own comment for why this (not a fixed
			# timer) drives the HOLD->EXIT transition.
			var dart_flying: bool = dart != null and is_instance_valid(dart) and dart.state == DART_STATE_FLYING
			if not dart_flying:
				_throw_anim_phase = ThrowAnimPhase.EXIT
				_throw_anim_timer = 0.0
		ThrowAnimPhase.EXIT:
			if _throw_anim_timer >= _anim_clip_length("Spell_Simple_Exit"):
				_throw_anim_phase = ThrowAnimPhase.NONE
				_throw_anim_timer = 0.0


## Same shape as _advance_throw_anim() but for the recall/retrieval
## sequence -- HOLD lasts for as long as _is_recalling stays true (cleared
## in _on_dart_returned() the instant the dart is actually back in hand),
## then EXIT plays out on its own real length before returning to NONE.
func _advance_recall_anim(delta: float) -> void:
	if _recall_anim_phase == ThrowAnimPhase.NONE:
		return
	_recall_anim_timer += delta
	match _recall_anim_phase:
		ThrowAnimPhase.ENTER:
			if _recall_anim_timer >= _anim_clip_length("Spell_Simple_Enter"):
				_recall_anim_phase = ThrowAnimPhase.HOLD
				_recall_anim_timer = 0.0
		ThrowAnimPhase.HOLD:
			if not _is_recalling:
				_recall_anim_phase = ThrowAnimPhase.EXIT
				_recall_anim_timer = 0.0
		ThrowAnimPhase.EXIT:
			if _recall_anim_timer >= _anim_clip_length("Spell_Simple_Exit"):
				_recall_anim_phase = ThrowAnimPhase.NONE
				_recall_anim_timer = 0.0


func _throw_anim_clip() -> String:
	match _throw_anim_phase:
		ThrowAnimPhase.ENTER: return "Spell_Simple_Enter"
		ThrowAnimPhase.HOLD: return "Spell_Simple_Idle"
		ThrowAnimPhase.EXIT: return "Spell_Simple_Exit"
	return ""


func _recall_anim_clip() -> String:
	match _recall_anim_phase:
		ThrowAnimPhase.ENTER: return "Spell_Simple_Enter"
		ThrowAnimPhase.HOLD: return "Push"
		ThrowAnimPhase.EXIT: return "Spell_Simple_Exit"
	return ""


func _process(delta: float) -> void:
	# Smooth speed ratio toward current velocity magnitude (0.0–1.0)
	var speed_ratio: float = velocity.length() / move_speed
	_move_speed_smooth = lerp(_move_speed_smooth, speed_ratio, 10.0 * delta)

	if player_mesh == null:
		return
	if _static_dagger_mesh != null:
		_static_dagger_mesh.visible = (dart == null and not _is_charging)
	_update_persistent_rope()
	_update_charge_spin(delta)
	if is_dead or is_falling:
		return

	var is_moving: bool = _move_speed_smooth > 0.1 and not _is_dashing

	# Advance both sequences' own phase/timer state every frame regardless of
	# what's actually selected for display below -- see ThrowAnimPhase's doc
	# comment for why this has to be decoupled from AnimationPlayer.is_playing().
	_advance_throw_anim(delta)
	_advance_recall_anim(delta)

	# Skeletal locomotion animation, using KayKit's actual clip names
	# (Idle_A from Rig_Medium_General.glb, Walking_A/Running_A from
	# Rig_Medium_MovementBasic.glb — see _setup_animation()'s ANIM_SOURCES).
	# A one-shot melee clip (slash/kick) gets to finish playing first --
	# otherwise this per-frame selection would stomp it within a single frame
	# of it starting, since nothing here else calls _play_anim(). Charging
	# needs its own override even though "Sword_Idle" is NOT looping (plays
	# once and holds its last frame, deliberately -- see
	# _update_charge_shake() for the tremble once that held pose means "max
	# charge"): without this branch, once is_playing() goes false on its own
	# at the end, the elif chain below would fall through to Idle_A/Walking_A
	# and stomp the held pose. Neither of these two can actually coincide
	# with movement in practice (melee is gated off during a dash/charge, and
	# charging itself zeroes velocity), so their position relative to
	# dash/is_moving below is moot either way -- left exactly where they were
	# before this feature to minimize the diff.
	#
	# Movement (dash/walk) comes next and, per this feature's hard
	# requirement, ALWAYS wins over the throw/recall Enter->Hold->Exit
	# sequences below it -- if the player starts moving mid-sequence, the
	# displayed clip cuts straight to Running_A/Walking_A; the sequence's own
	# phase timers keep advancing in the background regardless (see
	# _advance_throw_anim()/_advance_recall_anim() above) and pick back up
	# displaying correctly the moment movement stops. This is a deliberate
	# reversal from the OLD behavior, where recall's "Push" sat ABOVE
	# movement in this same chain (a player could walk around freely while
	# "Push" kept looping the whole time, unbroken) -- per explicit user
	# direction this session, movement must now always take visible priority.
	# Melee's one-shot clips keep their OLD relative position (above
	# movement, via action_playing below) since that's out of scope for this
	# feature and wasn't reported as an issue.
	var action_playing: bool = _anim_player != null and _current_anim in ONE_SHOT_ACTION_CLIPS and _anim_player.is_playing()
	if _is_charging:
		_play_anim("Sword_Idle")
	elif action_playing:
		pass
	elif _is_dashing:
		_play_anim("Running_A")
	elif is_moving:
		_play_anim("Walking_A", WALK_ANIM_SPEED)
	elif _recall_anim_phase != ThrowAnimPhase.NONE:
		_play_anim(_recall_anim_clip())
	elif _throw_anim_phase != ThrowAnimPhase.NONE:
		_play_anim(_throw_anim_clip())
	else:
		_play_anim("Idle_A")

	# Facing: smoothly turn the mesh to face the movement direction -- or,
	# while charging a throw, the aim direction instead. Charging zeroes
	# velocity (movement_blocked), so the vel2d-based facing below would
	# otherwise just freeze on whatever direction was last faced before the
	# charge started; aiming should still visibly reorient you toward your
	# throw target even though you can't move. KayKit's modeled forward is
	# actually +Z after import (same as the old fruit models needed,
	# confirmed visually — the glTF/Godot -Z-forward assumption in a prior
	# version of this comment was wrong), opposite of Basis.looking_at()'s
	# -Z convention, so look toward the reverse vector.
	var vel2d := Vector2(velocity.x, velocity.z)
	var facing_target: Vector2 = aim_dir if _is_charging else vel2d
	if facing_target.length() > 0.5:
		_facing_dir = facing_target.normalized()
		var dir3 := Vector3(facing_target.x, 0.0, facing_target.y).normalized()
		var desired_quat: Quaternion = Basis.looking_at(-dir3, Vector3.UP).get_rotation_quaternion()
		player_mesh.quaternion = player_mesh.quaternion.slerp(desired_quat, clampf(12.0 * delta, 0.0, 1.0))

	# The held dagger's blade points outward along the character's current
	# facing, computed fresh in world space every frame rather than as a
	# fixed rotation on the handslot.r attachment -- the hand bone's own
	# world orientation constantly changes as Idle_A/Walking_A/Sword_Idle
	# each pose the arm differently, so any single baked-in local rotation
	# would only look right in whichever pose it was tuned against. See
	# DAGGER_POMMEL_OFFSET's comment for the model's own local -Z = "blade
	# forward" axis.
	if _static_dagger_mesh != null:
		var dagger_forward: Vector3 = Vector3(_facing_dir.x, 0.0, _facing_dir.y)
		if dagger_forward.length() > 0.001:
			var dz_axis: Vector3 = -dagger_forward.normalized()
			var d_seed: Vector3 = Vector3.RIGHT if absf(dz_axis.dot(Vector3.UP)) > 0.99 else Vector3.UP
			var dx_axis: Vector3 = d_seed.cross(dz_axis).normalized()
			var dy_axis: Vector3 = dz_axis.cross(dx_axis).normalized()
			_static_dagger_mesh.global_transform.basis = Basis(dx_axis, dy_axis, dz_axis)

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

	# Max-charge tremble on top of "Sword_Idle"'s held final pose -- see
	# CHARGE_SHAKE_AMPLITUDE's comment. X/Z only; bob/ground-offset above
	# already owns Y, so this can't fight with it.
	if _is_charging and _charge_time >= MAX_CHARGE_TIME:
		_charge_shake_time += delta
		player_mesh.position.x = sin(_charge_shake_time * CHARGE_SHAKE_FREQUENCY) * CHARGE_SHAKE_AMPLITUDE
		player_mesh.position.z = cos(_charge_shake_time * CHARGE_SHAKE_FREQUENCY * 1.3) * CHARGE_SHAKE_AMPLITUDE
	else:
		_charge_shake_time = 0.0
		player_mesh.position.x = 0.0
		player_mesh.position.z = 0.0


func _physics_process(delta: float) -> void:
	# Drive the physics rope chain's two kinematic endpoints in sync with the
	# physics tick (not _process()) -- unconditional/no-op-safe regardless of
	# state below, see _update_physics_rope_anchors()'s own comment.
	_update_physics_rope_anchors()
	# Keep _is_recalling / the recall Enter->Push->Exit sequence in sync with
	# the dart's OWN state, not just the explicit throw-again button press
	# further below -- rope_dart.gd's walk-to-pickup path now also transitions
	# ANCHORED -> RECALLING internally (see DART_STATE_RECALLING's comment),
	# and this is what makes that path play the same reel-in animation
	# instead of silently retracting with no arm motion. A one-tick lag
	# behind the actual dart transition (this runs before the throw-again
	# branch fires on a fresh manual press, and before rope_dart.gd's own
	# _physics_process on a walk-to-pickup trigger) is inaudible/invisible at
	# 60Hz and not worth fighting node-processing order for.
	if dart != null and is_instance_valid(dart) and dart.state == DART_STATE_RECALLING and not _is_recalling:
		_is_recalling = true
		_recall_anim_phase = ThrowAnimPhase.ENTER
		_recall_anim_timer = 0.0
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
	# TELEPORT-FREE LEASH REDESIGN (2026-07-28, see _apply_rope_leash_velocity_
	# clamp()'s own doc comment): the leash is now enforced by projecting
	# VELOCITY before move_and_slide() runs, not by snapping global_position
	# afterward -- must run before move_and_slide(), not after (the old
	# _clamp_to_rope_leash() ran post-hoc and directly wrote global_position).
	_apply_rope_leash_velocity_clamp(delta)
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

	# --- Throw / charge / recall logic ---
	# The rope dart stays tethered: pressing throw again while it's still out
	# (flying or anchored) recalls it instead of doing nothing, on top of the
	# existing walk-over-to-pick-up (see rope_dart.gd's recall()/pickup_radius).
	if is_bot and bot_controller != null:
		# Bots use a one-shot flag; throw immediately at difficulty-based ratio.
		# Bots don't actively recall -- they retrieve by walking over it, same
		# as before, keeping their AI simple.
		if bot_controller.get_desired_throw() and dart == null:
			var diff: int = clamp(bot_controller.difficulty, 0, BOT_CHARGE_RATIOS.size() - 1)
			var bot_ratio: float = float(BOT_CHARGE_RATIOS[diff])
			_throw(bot_ratio)
	else:
		# Human players: hold to charge, release to fire; a tap while the dart
		# is already out recalls it instead.
		var throw_just_pressed: bool = throw_held and not _prev_throw
		var throw_just_released: bool = not throw_held and _prev_throw
		_prev_throw = throw_held

		if throw_just_pressed:
			if dart == null:
				_is_charging = true
				_charge_time = 0.0
			elif dart.has_method("recall"):
				dart.recall()
				_is_recalling = true
				_recall_anim_phase = ThrowAnimPhase.ENTER
				_recall_anim_timer = 0.0

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
	# Enter->Hold->Exit sequence (see ThrowAnimPhase) replaces the old single
	# "Spell_Simple_Shoot" one-shot clip -- _process()'s _advance_throw_anim()
	# drives the phase forward every frame from here.
	_throw_anim_phase = ThrowAnimPhase.ENTER
	_throw_anim_timer = 0.0


func get_pos_2d() -> Vector2:
	return Vector2(global_position.x, global_position.z)


func get_hand_world_position() -> Vector3:
	## The actual tracked handslot.r attachment position (see
	## _setup_dagger_in_hand()) -- used by rope_dart.gd to draw the rope's
	## near end from the real hand instead of a guessed height offset above
	## the capsule center, which was never actually calibrated against the
	## real hand height and was drawing it up near head/shoulder height.
	## Falls back to a rough approximation if the attachment isn't set up
	## (e.g. player_mesh failed to load) rather than erroring.
	if _dagger_in_hand != null:
		return _dagger_in_hand.global_position
	return global_position + Vector3.UP * 1.0


func _update_persistent_rope() -> void:
	## The physics chain is persistent (created once in _ready(), see
	## _init_rope_chain()) -- this just keeps the render in sync every
	## _process() frame. Defensive re-init if somehow not built yet (should
	## only ever happen for one frame at most, if player_mesh/skeleton setup
	## failed and _setup_dagger_in_hand() never called _init_rope_chain()).
	if not _physics_rope_active:
		_init_rope_chain()
	if is_dead:
		if _physics_rope_tube_mesh != null:
			_physics_rope_tube_mesh.visible = false
		return
	_update_rope_tube_mesh()


func _get_rope_tip_target() -> Vector3:
	## The single point _update_physics_rope_anchors() (every-tick tracking)
	## treats as
	## "where the far end of the rope should be": the dart's actual rendered
	## pommel position while one is out, or -- critically, per the user's
	## explicit "collapse into the hand" idle spec -- the hand's OWN position
	## whenever dart == null. Returning the hand position here (not some
	## other idle pose) is precisely what makes the persistent chain's idle
	## resting configuration a real physics collapse rather than a separately
	## authored visual: with the tip anchor pinned to the same point as the
	## hand anchor, the chain has nowhere to go but stay bunched there.
	if dart != null and is_instance_valid(dart) and dart.head_mesh != null:
		return dart.head_mesh.global_transform * Vector3(0.0, 0.0, DAGGER_POMMEL_OFFSET)
	return get_hand_world_position()


func _get_rope_plane_y() -> float:
	## The one fixed horizontal-plane height every physics-rope segment for
	## the CURRENT dart is locked to (see rope_segment_body.gd's locked_y) --
	## read directly from the owning rope_dart.gd instance's own plane_y
	## (duck-typed) while a dart is out. Falls back to the current hand height
	## while idle (dart == null) -- there is no dart.plane_y to read then, and
	## the chain is collapsed at the hand anyway so the exact plane barely
	## matters visually, but it still needs to be plane_y-shaped (fixed for
	## the whole idle stretch, not recomputed every tick) once a throw
	## eventually starts -- rope_dart.gd's launch() re-derives its own fresh
	## plane_y from the hand at that moment regardless, so this idle fallback
	## only affects the brief idle-collapsed look, not any real throw.
	if dart != null and is_instance_valid(dart):
		return dart.plane_y
	return get_hand_world_position().y


func _get_rope_hand_anchor_pos() -> Vector3:
	## The hand end of the rope, X/Z from the real (animated, bobbing) hand
	## bone but Y hard-clamped to _get_rope_plane_y() -- the whole PBD chain is
	## simulated in 2D (see RopeChainPBD), so this Y value is only used for
	## reconstructing the tube mesh's 3D render positions, never fed into the
	## simulation itself.
	var hand_pos: Vector3 = get_hand_world_position()
	return Vector3(hand_pos.x, _get_rope_plane_y(), hand_pos.z)


func _init_rope_chain() -> void:
	## Creates the persistent RopeChainPBD ONCE per player (called from
	## _setup_dagger_in_hand(), itself called once from _ready()) -- see this
	## file's ROPE_PHYSICS_* consts' doc comment and rope_chain_pbd.gd's own
	## class doc comment for the full architecture. Collapsed onto the hand's
	## own current position at creation -- exactly the same "idle collapse"
	## rest configuration reset_to_point() re-establishes at every later
	## teleport (see _reset_rope_chain_to_hand()).
	if _rope_chain != null:
		return
	_rope_chain = RopeChainPBDScript.new()
	_rope_chain.configure(ROPE_PHYSICS_SEGMENTS, ROPE_PHYSICS_SEGMENT_LENGTH)
	var hand_pos: Vector3 = _get_rope_hand_anchor_pos()
	var hand_2d := Vector2(hand_pos.x, hand_pos.z)
	_rope_chain.reset_to_point(hand_2d)
	_hand_anchor_smoothed_2d = hand_2d
	_tip_anchor_smoothed_2d = hand_2d
	_physics_rope_active = true


func _rope_obstacle_rects() -> Array:
	## Real obstacle geometry (pillars, tree/cactus scatter boxes) read from
	## the "obstacles" group's own get_rect_2d() -- the same authoritative 2D
	## data this project's own architecture already treats as ground truth
	## for XZ-plane gameplay math (see arena_obstacle.gd). Cached once per
	## player instance since these are all static StaticBody3D nodes that
	## never move mid-match -- avoids re-querying the whole group every
	## solver iteration of every physics tick.
	if not _rope_obstacle_rects_cached:
		_rope_obstacle_rects_cache.clear()
		for o in get_tree().get_nodes_in_group("obstacles"):
			if o.has_method("get_rect_2d"):
				_rope_obstacle_rects_cache.append(o.get_rect_2d())
		_rope_obstacle_rects_cached = true
	return _rope_obstacle_rects_cache


func _step_or_snap_2d(current: Vector2, target: Vector2, delta: float) -> Vector2:
	## See ROPE_ANCHOR_MAX_SPEED/ROPE_ANCHOR_SNAP_THRESHOLD's own doc
	## comments. A genuinely large gap (a real teleport, or the brief
	## _ready()-vs-reset_for_round() ordering gap) SNAPS instantly; only a
	## small gap (an animation clip-switch pop) gets rate-limited.
	var gap: float = current.distance_to(target)
	if gap > ROPE_ANCHOR_SNAP_THRESHOLD:
		return target
	return current.move_toward(target, ROPE_ANCHOR_MAX_SPEED * delta)


func _update_physics_rope_anchors() -> void:
	## Drives the chain's two kinematic endpoints and advances its solver by
	## one physics tick -- called from _physics_process() unconditionally.
	## The hand end tracks _get_rope_hand_anchor_pos(); the tip end tracks
	## _get_rope_tip_target(), whatever the dart's current state
	## (FLYING/ANCHORED/RECALLING) or, while idle, the hand itself -- so the
	## chain is simulated continuously for the player's entire lifetime, not
	## just while a dart is out.
	##
	## The TIP anchor is deliberately only speed-clamped while dart == null
	## (idle): _get_rope_tip_target() falls back to the same raw animated
	## hand-bone position while idle, sharing the exact same clip-switch-pop
	## vulnerability the hand anchor has -- but while a dart is actually
	## thrown, the tip must keep tracking the dart's own real (already
	## smooth, already fast-by-design) flight/recall position with zero added
	## lag: rope_dart.gd's own travel_speed can legitimately reach
	## BASE_SPEED*2.0=36 units/sec at a full-charge throw and recall_speed is
	## 24 units/sec, both already above ROPE_ANCHOR_MAX_SPEED -- clamping
	## those would reintroduce visible throw/recall tracking lag.
	if not _physics_rope_active or _rope_chain == null:
		return
	var delta: float = get_physics_process_delta_time()

	var hand_pos_3d: Vector3 = _get_rope_hand_anchor_pos()
	var hand_target: Vector2 = Vector2(hand_pos_3d.x, hand_pos_3d.z)
	_hand_anchor_smoothed_2d = _step_or_snap_2d(_hand_anchor_smoothed_2d, hand_target, delta)

	var tip_pos_3d: Vector3 = _get_rope_tip_target()
	var tip_target: Vector2 = Vector2(tip_pos_3d.x, tip_pos_3d.z)
	if dart == null:
		_tip_anchor_smoothed_2d = _step_or_snap_2d(_tip_anchor_smoothed_2d, tip_target, delta)
	else:
		_tip_anchor_smoothed_2d = tip_target

	_rope_chain.step(delta, _hand_anchor_smoothed_2d, _tip_anchor_smoothed_2d,
		_rope_obstacle_rects(), ROPE_RADIUS, ROPE_INTERIOR_MAX_SPEED, ROPE_SOLVER_ITERATIONS)


func get_rope_polyline_2d() -> Array[Vector2]:
	## Ordered hand -> tip control points of the REAL, currently-simulated
	## PBD chain -- the exact same points _update_rope_tube_mesh() draws a
	## curve through -- exposed for rope_dart.gd's own use during RECALLING
	## (see its _get_hand_rope_path_2d()), so a returning dart can retrace the
	## rope's real live shape (obstacle wrap included) instead of cutting a
	## straight line back to wherever the owner currently stands.
	## Deliberately does NOT include the tip/dart's own position -- rope_dart.gd
	## already knows its own head_2d with zero extra lag (this function's own
	## tip point, by contrast, tracks the dart one physics tick behind), so
	## callers that want the full hand -> ... -> dart path append their own
	## current position themselves.
	var points: Array[Vector2] = []
	if _rope_chain != null:
		for p in _rope_chain.get_polyline_no_tip():
			points.append(p as Vector2)
	return points


func _free_physics_rope() -> void:
	## Only ever called from _exit_tree() now -- the chain is persistent for
	## the whole lifetime of a player node. Unlike the old RigidBody3D +
	## PhysicsServer3D chain, there is no RID/resource to explicitly free
	## here -- RopeChainPBD is plain script data (Vector2 arrays), reclaimed
	## by the garbage collector like any other object once _rope_chain is
	## dropped.
	_rope_chain = null
	_physics_rope_active = false
	if _physics_rope_tube_mesh != null:
		_physics_rope_tube_mesh.visible = false


func _reset_rope_chain_to_hand() -> void:
	## Must be called from EVERY real discrete player teleport -- confirmed to
	## be exactly two production call sites, reset_for_round() and _respawn()
	## (ring-outs/_start_fall() already funnel into kill()->_respawn(), and
	## game_manager.gd's start_round() is the only caller of reset_for_round()
	## in both local and online flow, so there is no third path).
	##
	## Collapses the chain into the exact same "every point coincides with
	## the hand" configuration _init_rope_chain() already uses for a brand
	## new chain -- this is the chain's own natural idle-collapsed rest
	## shape, not a newly-invented pose. Unlike the old RigidBody3D chain,
	## there is no joint/impulse solver state that can go stale across a
	## reset (see rope_chain_pbd.gd's own class doc comment for why a PBD
	## chain has no such state at all) -- a plain reset_to_point() is the
	## whole fix, with none of the old chain's own "must also destroy and
	## recreate every joint RID or the solver's warm-start history reproduces
	## the bug on a SECOND reset" follow-up complexity.
	if not _physics_rope_active or _rope_chain == null:
		return
	var hand_pos_3d: Vector3 = _get_rope_hand_anchor_pos()
	var hand_2d := Vector2(hand_pos_3d.x, hand_pos_3d.z)
	_rope_chain.reset_to_point(hand_2d)
	_hand_anchor_smoothed_2d = hand_2d
	_tip_anchor_smoothed_2d = hand_2d



func _update_rope_tube_mesh() -> void:
	## Rebuilds one combined ArrayMesh every _process() frame: a real chain of
	## oval ring links, one per REAL PBD segment (control_points[i] ->
	## control_points[i+1], in RopeChainPBD.points order -- [hand, every
	## interior point, tip]), via _build_chain_link_mesh() below. The
	## underlying chain and its real obstacle-collision correction are
	## completely unchanged by this -- only what gets DRAWN from its
	## positions changed, from a smoothed spline to N distinct rings. NO
	## obstacle-awareness or correction happens in this function or in
	## _build_chain_link_mesh() -- that all already happened inside
	## RopeChainPBD.step() itself.
	if _rope_chain == null or _rope_chain.points.size() != ROPE_PHYSICS_SEGMENTS + 1:
		return

	if _physics_rope_tube_mesh == null:
		var mi := MeshInstance3D.new()
		mi.name = "RopeChainLinksMesh"
		# top_level = true: every control point below comes from a 2D chain
		# point reconstructed into WORLD-space Vector3 -- a non-top_level
		# MeshInstance3D would render that already-global vertex data through
		# its own parent-derived global_transform too, double-transforming it
		# (see git history for the original root-caused bug this fixed: a
		# rope-shaped mesh floating disconnected from the character, reshaping
		# every frame in lockstep with the player's own rotation). top_level
		# = true makes this node's global_transform NOT inherit from its
		# parent at all, so the already-global vertices render correctly with
		# no further transform needed.
		mi.top_level = true
		# Material is applied AFTER _build_chain_link_mesh() gives this mesh
		# its first real surface (below) -- set_surface_override_material(0,
		# ...) errors ("Index p_surface = 0 is out of bounds") on a
		# MeshInstance3D whose mesh has zero surfaces yet.
		add_child(mi)
		_physics_rope_tube_mesh = mi

	var plane_y: float = _get_rope_plane_y()
	var control_points: Array[Vector3] = []
	for p in _rope_chain.points:
		var p2: Vector2 = p
		control_points.append(Vector3(p2.x, plane_y, p2.y))

	_build_chain_link_mesh(_physics_rope_tube_mesh, control_points, ROPE_RADIUS, ROPE_TUBE_RADIAL_SEGMENTS)
	_physics_rope_tube_mesh.visible = true


func _build_chain_link_mesh(mi: MeshInstance3D, control_points: Array[Vector3], tube_radius: float, radial_segments: int) -> void:
	## Renders the rope as a real chain of oval ring links, one per REAL PBD
	## segment (control_points[i] -> control_points[i+1]) -- 2026-07-31,
	## replacing the old single smooth Catmull-Rom tube per explicit user
	## request ("update the rope bar to ring, make joints visible for better
	## testing"). Each segment's own true endpoints are what a spline used to
	## blend away; here every real joint is directly visible as the shared
	## boundary between two rings, and a segment that stretches past
	## ROPE_PHYSICS_SEGMENT_LENGTH (a real PBD constraint violation -- see
	## RopeChainPBD.max_link_gap_violation()) shows up on screen as a
	## visibly larger ring than its neighbors, not just a number in a test
	## log. Every link is baked into ONE ArrayMesh (one SurfaceTool, one
	## commit) for a single draw call, not N separate MeshInstance3D nodes.
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	var n: int = control_points.size()
	var built_any: bool = false
	for i in range(n - 1):
		var p_a: Vector3 = control_points[i]
		var p_b: Vector3 = control_points[i + 1]
		var seg_vec: Vector3 = p_b - p_a
		var link_length: float = seg_vec.length()
		if link_length < 0.001:
			continue
		var tangent: Vector3 = seg_vec / link_length
		# Alternate the ring's flatten axis every other link, the same way a
		# real chain's own links alternate a 90-degree twist to interlock --
		# purely cosmetic, carries no physics meaning of its own.
		var basis_seed: Vector3 = Vector3.RIGHT if absf(tangent.dot(Vector3.UP)) > 0.99 else Vector3.UP
		var perp_a: Vector3 = basis_seed.cross(tangent).normalized()
		var perp_b: Vector3 = tangent.cross(perp_a).normalized()
		var flatten_axis: Vector3 = perp_a if (i % 2 == 0) else perp_b
		var ring_normal: Vector3 = tangent.cross(flatten_axis).normalized()
		var mid: Vector3 = (p_a + p_b) * 0.5
		var loop_points: Array[Vector3] = _stadium_loop_points(mid, tangent, flatten_axis, link_length, ROPE_CHAIN_LINK_WIDTH)
		_append_closed_tube(st, loop_points, tube_radius, radial_segments, ring_normal)
		built_any = true

	if not built_any:
		mi.mesh = null
		return

	st.generate_normals()
	mi.mesh = st.commit()
	# Must be applied AFTER mi.mesh is assigned -- set_surface_override_material
	# errors on a MeshInstance3D whose mesh has no surfaces yet, which every
	# call before this line's mi.mesh assignment would still be.
	if _rope_material != null:
		mi.set_surface_override_material(0, _rope_material)


func _stadium_loop_points(center: Vector3, tangent: Vector3, flatten_axis: Vector3, link_length: float, link_width: float) -> Array[Vector3]:
	## A closed "stadium" (racetrack) outline -- two straight sides plus two
	## semicircular end caps -- lying entirely in the plane spanned by
	## `tangent` (its long axis, oriented along the real segment direction)
	## and `flatten_axis` (its short axis), centered at `center`. This is
	## the classic flattened-oval shape of a real chain link. Floors the
	## straight-side length at a small positive minimum so a near-collapsed
	## segment (consecutive PBD points nearly coincident, e.g. deep in the
	## idle coil near the hand) still degenerates gracefully to a small
	## round-ish ring instead of an inverted/degenerate outline.
	var cap_radius: float = link_width * 0.5
	var half_straight: float = maxf(link_length * 0.5 - cap_radius, 0.01)
	var pts: Array[Vector3] = []

	# Straight side at v = -cap_radius, u: -half_straight -> +half_straight.
	pts.append(center + tangent * (-half_straight) + flatten_axis * (-cap_radius))
	pts.append(center + tangent * half_straight + flatten_axis * (-cap_radius))

	# Right end cap: semicircle centered at u=+half_straight, sweeping
	# angle -90deg -> +90deg (toward +u), excluding both endpoints since
	# they're already the straight sides' own shared corners.
	for k in range(1, ROPE_CHAIN_CAP_SEGMENTS):
		var t: float = float(k) / float(ROPE_CHAIN_CAP_SEGMENTS)
		var angle: float = -PI * 0.5 + t * PI
		var u: float = half_straight + cos(angle) * cap_radius
		var v: float = sin(angle) * cap_radius
		pts.append(center + tangent * u + flatten_axis * v)

	# Straight side at v = +cap_radius, u: +half_straight -> -half_straight.
	pts.append(center + tangent * half_straight + flatten_axis * cap_radius)
	pts.append(center + tangent * (-half_straight) + flatten_axis * cap_radius)

	# Left end cap: semicircle centered at u=-half_straight, sweeping
	# angle +90deg -> +270deg (toward -u).
	for k in range(1, ROPE_CHAIN_CAP_SEGMENTS):
		var t: float = float(k) / float(ROPE_CHAIN_CAP_SEGMENTS)
		var angle: float = PI * 0.5 + t * PI
		var u: float = -half_straight + cos(angle) * cap_radius
		var v: float = sin(angle) * cap_radius
		pts.append(center + tangent * u + flatten_axis * v)

	return pts


func _append_closed_tube(st: SurfaceTool, loop_points: Array[Vector3], radius: float, radial_segments: int, loop_normal: Vector3) -> void:
	## Extrudes a round tube of constant `radius` around a CLOSED loop (the
	## last point connects back to the first) into the given, already-begun
	## SurfaceTool -- lets _build_chain_link_mesh() bake every ring into one
	## shared mesh instead of committing N separate ones. `loop_normal` is
	## the fixed axis perpendicular to the whole loop's own plane (see
	## _stadium_loop_points()) -- since every point on the loop's own path
	## tangent is, by construction, always perpendicular to loop_normal,
	## there's no degenerate parallel-tangent case to guard against here,
	## unlike a tube built along an arbitrary 3D curve.
	var point_count: int = loop_points.size()
	if point_count < 3:
		return

	var rings: Array[PackedVector3Array] = []
	rings.resize(point_count)
	for i in range(point_count):
		var prev_pt: Vector3 = loop_points[(i - 1 + point_count) % point_count]
		var next_pt: Vector3 = loop_points[(i + 1) % point_count]
		var path_tangent: Vector3 = (next_pt - prev_pt).normalized()
		var cross_axis: Vector3 = loop_normal.cross(path_tangent).normalized()
		var ring := PackedVector3Array()
		ring.resize(radial_segments)
		for j in range(radial_segments):
			var angle: float = TAU * float(j) / float(radial_segments)
			ring[j] = loop_points[i] + (cross_axis * cos(angle) + loop_normal * sin(angle)) * radius
		rings[i] = ring

	for i in range(point_count):
		var ring_a: PackedVector3Array = rings[i]
		var ring_b: PackedVector3Array = rings[(i + 1) % point_count]
		for j in range(radial_segments):
			var j_next: int = (j + 1) % radial_segments
			var a0: Vector3 = ring_a[j]
			var a1: Vector3 = ring_a[j_next]
			var b0: Vector3 = ring_b[j]
			var b1: Vector3 = ring_b[j_next]
			# Two triangles per quad, wound so the outward-facing normal
			# points away from the ring's own centerline (consistent with
			# SurfaceTool.generate_normals()'s face-winding expectations).
			st.add_vertex(a0)
			st.add_vertex(b0)
			st.add_vertex(a1)
			st.add_vertex(a1)
			st.add_vertex(b0)
			st.add_vertex(b1)


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


func _apply_rope_leash_velocity_clamp(delta: float) -> void:
	## NO PIVOT, NO RADIUS, NO CIRCLE -- per the user's own exact, direct
	## requirement this round: "There shouldn't be any radius to compute.
	## Regardless of anchored or not, the rope bar should be attached to the
	## next rope bar and never separate. When the rope bars are stretched
	## completely, character cannot move further." This replaces the old
	## _rope_leash_pivot_and_radius()'s synthetic pivot+radius circle (and its
	## own special-cased "is a segment resting on real obstacle contact"
	## wrap-aware branch) with a DIRECT measurement of the real, already-
	## simulated PBD chain.
	##
	## USED LENGTH (how much of the fixed DART_ROPE_LENGTH budget is
	## currently spent) is the LARGER (more restrictive -- i.e. less
	## remaining slack) of two independent, real, non-invented measurements:
	##  1. RopeChainPBD.total_extension_2d() -- the chain's own real,
	##     currently-simulated total path length, hand to tip. Correctly
	##     wrap-aware (routing around a real obstacle corner consumes more of
	##     the chain's own real length, which shows up here directly, no
	##     special-cased branch) -- but DEPENDS on the solver having fully
	##     converged this exact tick.
	##  2. The straight-line distance from the hand to the dart's own real
	##     anchor point -- always exact and instant (two point positions, no
	##     solver/convergence involved), and mathematically guaranteed to
	##     never exceed the chain's true total capacity for any valid rope
	##     configuration -- not itself wrap-aware, so only used as a
	##     convergence-independent SAFETY FLOOR, not the primary signal.
	## FOUND via a dedicated isolated diagnostic this round (a sustained,
	## continuous outward push, not a one-off nudge): using
	## total_extension_2d() ALONE let a genuine, severe runaway feedback loop
	## through -- under CONTINUOUS outward pushing, the chain's own solver,
	## perpetually catching up to a hand target that keeps moving every
	## single tick, can under-report its true extension for many consecutive
	## ticks (see rope_chain_pbd.gd's own "KNOWN, DISCLOSED RESIDUAL" doc
	## comment on convergence lag under sustained forcing), which read as
	## MORE slack than physically real and let the player run to 15+ units
	## from a 7.2-unit-max anchor within one second. The straight-line floor
	## fixes this because it can never itself accumulate a lag-driven error.
	##
	## PULL DIRECTION -- also corrected this round, after TWO separate wrong
	## attempts each caught by the same isolated diagnostic: (1) an initial
	## `points[0] - points[1]` (single adjacent link) direction was
	## unreliable whenever that ONE link specifically still had slack even
	## while the chain overall read as taut; (2) a follow-up "direction to
	## the chain's own farthest point from the hand" was WRONG-SIGNED (and,
	## worse, wrong-signed in a way that only surfaces once a player has been
	## pushed PAST the anchor and kept going, since up to that point the
	## farthest chain point and the real anchor happen to point the same
	## way) -- once the hand has traveled far past the rest of the chain,
	## the "farthest point from hand" is the anchor END of the chain, so
	## `farthest_point - hand` points BACK toward the anchor (inward), the
	## opposite of the player's real outward direction of travel. The
	## correct, general, always-valid pull direction is simply the gradient
	## of "distance from the real anchor point" -- `hand - dart.head_2d`,
	## normalized -- which is unambiguous and correct in every configuration
	## (taut, slack, wrapped, or a player who has already overshot past the
	## anchor and kept moving in the same direction), since dart.head_2d is
	## a single real point at whatever instant it's read, not something that
	## can flip sides the way a chain-shape-derived point can. Wrap-awareness
	## is carried entirely by the MAGNITUDE side (used_length/slack) above, not
	## by this direction -- a real, disclosed simplification: a player moving
	## purely TANGENTIALLY around a wrap corner (not increasing straight-line
	## hand-to-anchor distance) won't have that specific tangential motion
	## restricted by this direction alone, even if it's consuming real wrap
	## slack. Not observed as a problem in this round's own soak, but worth
	## revisiting if a future report specifically describes "sliding along a
	## wrapped corner past where the rope should stop it."
	##
	## ENFORCEMENT MECHANISM is UNCHANGED from the prior design (ROUND 19,
	## 2026-07-28): velocity is projected BEFORE move_and_slide() runs, never
	## a position snap after the fact -- decomposes the player's already-
	## computed velocity into a component along the outward direction and a
	## perpendicular component; only the outward component is ever reduced,
	## and only down to the exact amount of remaining slack budget this tick,
	## never below zero and never touching the perpendicular component at
	## all -- so pushing straight out against a taut rope smoothly
	## decelerates to a dead stop exactly at the boundary, while pushing at
	## an angle keeps sliding freely. Inward motion (slackening) is never
	## touched at all.
	##
	## ROUND 30 (2026-07-31) FIX -- no longer gated on dart.state ==
	## DART_STATE_ANCHORED. Root-caused from a direct user report ("the
	## segments are pulled apart when the max rope length is exceeded"):
	## this clamp used to return immediately for FLYING and RECALLING,
	## meaning the player had ZERO movement restriction while a dart was in
	## flight or being reeled in -- but RopeChainPBD's two endpoints
	## (hand/tip) are driven KINEMATICALLY every tick regardless of state,
	## and a kinematic pair pinned farther apart than the chain's own total
	## capacity (segment_count * segment_max_length == DART_ROPE_LENGTH) is a
	## mathematically infeasible configuration for a one-sided <= distance
	## constraint (see rope_chain_pbd.gd's own _satisfy_distance -- by the
	## triangle inequality, if the two fixed endpoints are farther apart than
	## the sum of every link's own max length, AT LEAST ONE link must exceed
	## its max length; no amount of solver iteration can fix that, it's not a
	## convergence problem). rope_dart.gd's own FLYING max-range check used to
	## be measured from the dart's FIXED throw origin (origin_2d, itself just
	## the owner's BODY position at throw-instant), not the player's own
	## (moving) hand -- so a player who ran AWAY from their own just-thrown
	## dart (DASH_SPEED=20 u/s, dart travel_speed up to 36 u/s -- either
	## alone, let alone combined, closes DART_ROPE_LENGTH's 7.2-unit budget in
	## well under a second) could push hand-to-dart distance past the chain's
	## real capacity with nothing to stop it on EITHER side: this clamp only
	## ever throttles the PLAYER's own contribution, and the dart's own
	## independent, much-faster FLYING motion was never itself bounded
	## relative to the hand at all -- so fixing only this ANCHORED-only gate
	## was measured (via tests/test_rope_flee_during_flight.gd) to be
	## insufficient by itself (max_hand_to_dart still reached 10.04 against a
	## 7.2 capacity, max_link_gap_violation 0.21). The actual close is in
	## rope_dart.gd's own FLYING branch (see its own ROUND 30 doc comment),
	## which now anchors the instant real hand-to-head distance reaches
	## ROPE_LENGTH, measured from the owner's CURRENT hand every tick -- this
	## clamp here remains necessary too, both for the ANCHORED case (unchanged
	## from before) and to stop the player once the dart anchors mid-flight
	## from this same fix. Together these close the gap from both sides: the
	## dart can't be driven farther from the hand than capacity, and the
	## player can't walk farther from a now-fixed anchor than capacity. This
	## also directly matches this mechanism's own ROUND 12 origin, quoted
	## verbatim in CLAUDE.md: "REGARDLESS OF ANCHORED OR NOT, the rope bar
	## should be attached to the next rope bar and never separate" -- the
	## ANCHORED-only gate was never the intended scope, just an
	## implementation gap. dart.head_2d is read live every tick regardless of
	## state (FLYING: the dart's own current flight position; RECALLING: its
	## current retraction-sample position; ANCHORED: unchanged from before),
	## so the same slack/pull-direction math applies unmodified in every
	## state -- nothing else in this function changed.
	if dart == null or not is_instance_valid(dart):
		return
	if _rope_chain == null or _rope_chain.points.size() < 2:
		return
	if delta <= 0.0:
		return

	var hand_2d: Vector2 = _rope_chain.points[0]
	var chain_extension: float = _rope_chain.total_extension_2d()
	var straight_line_used: float = hand_2d.distance_to(dart.head_2d)
	var used_length: float = maxf(chain_extension, straight_line_used)
	var slack: float = DART_ROPE_LENGTH - used_length

	var pull_vec: Vector2 = hand_2d - dart.head_2d
	if pull_vec.length() < 0.0001:
		return  # degenerate: hand exactly coincides with the anchor
	var pull_dir: Vector2 = pull_vec.normalized()

	var vel_2d: Vector2 = Vector2(velocity.x, velocity.z)
	var radial_component: float = vel_2d.dot(pull_dir)
	if radial_component <= 0.0:
		return  # moving inward (slackening) or purely tangential -- never restricted
	var max_radial_component: float = maxf(slack, 0.0) / delta
	if radial_component > max_radial_component:
		vel_2d -= pull_dir * (radial_component - max_radial_component)
		velocity.x = vel_2d.x
		velocity.z = vel_2d.y



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
	# Force-freeing the dart above bypasses _on_dart_returned() (only called
	# from rope_dart.gd's own _pick_up(), which never runs here) -- without
	# this, a kill mid-recall would leave _is_recalling/_recall_anim_phase
	# permanently stuck true, so after respawning the recall Hold phase
	# ("Push") would loop forever with no dart and no way to clear it. Same
	# reasoning applies to a kill mid-throw-sequence (_throw_anim_phase).
	_is_recalling = false
	_throw_anim_phase = ThrowAnimPhase.NONE
	_throw_anim_timer = 0.0
	_recall_anim_phase = ThrowAnimPhase.NONE
	_recall_anim_timer = 0.0
	player_killed.emit(self)
	if lives > 0:
		_respawn_timer = get_tree().create_timer(1.5)
		_respawn_timer.timeout.connect(_respawn)
	else:
		player_eliminated.emit(self)
		set_physics_process(false)


func _respawn() -> void:
	global_position = spawn_pos
	# ROUND 24 (2026-07-29): dart is already null here -- kill() clears it
	# synchronously, well before this timer-deferred respawn fires -- see
	# _reset_rope_chain_to_hand()'s own doc comment for why this teleport
	# site needs the chain snapped to the new position too.
	_reset_rope_chain_to_hand()
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
	_charge_shake_time = 0.0
	_is_recalling = false
	_throw_anim_phase = ThrowAnimPhase.NONE
	_throw_anim_timer = 0.0
	_recall_anim_phase = ThrowAnimPhase.NONE
	_recall_anim_timer = 0.0
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
	# ROUND 24 (2026-07-29): must run AFTER dart is cleared above (so the
	# tip-anchor branch below correctly sees dart == null) and after
	# global_position has already been teleported to start_pos -- see
	# _reset_rope_chain_to_hand()'s own doc comment for the full root-cause
	# writeup this fixes (persistent chain segments left behind at the stale
	# pre-teleport position, getting dragged through obstacles over real
	# time).
	_reset_rope_chain_to_hand()
	_start_spawn_invincibility()


func _start_spawn_invincibility() -> void:
	_spawn_invincible_timer = SPAWN_INVINCIBLE_DURATION
	if not _player_materials.is_empty():
		var c: Color = character_color
		c.a = 0.5
		_apply_player_tint(c, BaseMaterial3D.TRANSPARENCY_ALPHA)


func _on_dart_returned() -> void:
	dart = null
	_is_recalling = false
