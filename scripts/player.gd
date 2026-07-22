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

## Mirrors rope_dart.gd's State.ANCHORED ordinal and ROPE_LENGTH — no shared
## constant between the two scripts (see HITBOX_DEBUG_RADIUS's comment
## above), so keep these in sync by hand if either changes. Used by
## _clamp_to_rope_leash() to keep the owner from wandering past the tether's
## reach once the dart is anchored.
const DART_STATE_ANCHORED: int = 1
const DART_ROPE_LENGTH: float = 8.0

## The persistent rope's idle-coil segment count and the CylinderMesh
## dimensions every rope visual (idle coil AND the physics chain further
## below) shares -- moved here from rope_dart.gd (formerly the dart's own,
## separately-spawned tether) now that the rope is one object the player
## always owns; radius matches rope_dart.tscn's old Rope mesh exactly so the
## look is unchanged. See _update_persistent_rope(). Only used for the idle
## coil now -- the thrown/extended look is the real physics chain (see
## ROPE_PHYSICS_SEGMENTS below), not these same segments reshaped, so this
## count only has to look good as a ROPE_COIL_TURNS-turn spiral (16 segments
## across 2 turns; 8 would read as an 8-pointed star rather than a coil, ~90
## deg of arc per segment).
const ROPE_SEGMENTS: int = 16
const ROPE_RADIUS: float = 0.035
## Idle coil shape: a tight spiral centered at _rope_coil_anchor, radius
## growing from inner to outer across ROPE_COIL_TURNS full turns. INNER must
## clear the actual forearm radius there (~0.09-0.15, sampled directly from
## Barbarian.glb's skinned vertices -- see _setup_dagger_in_hand()'s comment)
## or the coil clips into the arm; matches the old rope_coil.glb mesh's own
## calibrated inner/outer radii so the idle silhouette is unchanged.
const ROPE_COIL_TURNS: float = 2.0
const ROPE_COIL_RADIUS_INNER: float = 0.16
const ROPE_COIL_RADIUS_OUTER: float = 0.24

## --- Real physics rope chain (the EXTENDED/thrown look, dart != null) ---
## Per explicit user direction: three earlier attempts at a scripted
## hand-computed line (straight, then straight-with-raycast-truncation, then
## per-segment-raycast-truncation) all read as "the rope goes into the
## pillar/cactus" in real screenshots despite each one's own positional
## verification passing -- the user's actual ask is that the rope be a real
## RigidBody3D chain that Godot's own physics solver simulates and collides
## against the map's real obstacle geometry, so collision-correctness and
## draping-over-an-obstacle are emergent from simulation instead of anyone
## calculating a bend point by hand. See _spawn_physics_rope().
##
## FOLLOW-UP FIX (root-caused from a real user screenshot showing segments as
## short disconnected dashes, "each segment completely unattached"): the
## first version of this chain used Node-based PinJoint3D with its implicit
## single-global-position setup -- Godot captures ONE local anchor OFFSET per
## body, computed once from wherever the joint node's global_position and
## each body's global_transform happened to be at the moment node_a/node_b
## were assigned. That first version also spawned every body (both anchors
## AND all 8 segments) clustered within ~0.16 units of the hand, all at
## identity rotation (pointing straight up, not along the rope). Both of
## those meant the auto-captured offsets ended up close to each BODY'S OWN
## ORIGIN rather than at the true geometric ends of each 1-unit-long capsule
## -- so the "constraint" the solver was actually enforcing was closer to
## "keep body centers near each other" than "keep consecutive capsule ends
## touching". That's a real steady-state wrong-equilibrium bug, not just a
## fast-motion transient -- confirmed by the fact the user's screenshot showed
## a stationary/ANCHORED dart, not one being actively yanked around, so pure
## teleportation-lag (this session's originally-disclosed risk) can't be the
## whole story on its own.
##
## Fix: build every joint via the low-level PhysicsServer3D.joint_make_pin()
## API directly (bypassing the PinJoint3D node entirely), which takes the two
## bodies' local anchor points as EXPLICIT, INDEPENDENT arguments instead of
## deriving them implicitly from a shared setup-time position. This lets each
## body's true attachment point be declared correctly regardless of whether
## the bodies happen to coincide in world space at spawn time: every segment's
## local anchor is exactly its own capsule end (Vector3(0, ±HALF_LEN, 0), see
## _spawn_physics_rope()), and both kinematic anchor bodies' local anchor is
## always exactly their own origin (Vector3.ZERO) -- so the hand/tip anchors
## are always attached to the chain with zero baked-in error, even though (at
## the instant of a throw) the tip anchor's real position is nowhere near
## where the chain's fully-extended far end is laid out; the visible result
## is the intended "rope pays out from the hand as the dart flies away," not
## a permanent offset error. Segments are also now spawned with a correct
## initial rotation (local Y aligned along the hand->tip direction) instead of
## defaulting to identity/pointing straight up. See _join_rope_pin() and
## _spawn_physics_rope().
##
## Joint bias/damping are deliberately left at PhysicsServer3D's own defaults
## (0.3 / 1.0, matching PinJoint3D's node defaults) -- a first attempt at
## this fix tried tuning these stiffer (bias 0.9, damping 2.0) as a mitigation
## for the fast-motion risk below, and that was ACTIVELY WRONG: measured via
## a temporary per-tick probe printing the real world-space gap at every
## joint, the stiffer values caused the chain to explode -- max gap grew
## exponentially tick over tick, from single digits into the tens of
## trillions of units within a couple seconds, on an otherwise-idle chain
## with no unusual player input. Reverting to the defaults and re-measuring
## the same way showed gaps consistently settling to ~0.02-0.1 units at rest,
## with brief (few-tick) spikes up to ~10-12 units at the instant of a throw
## that reliably decayed back down rather than diverging. Do not re-attempt
## stiffening these without re-running that same gap-measurement probe.
##
## FOLLOW-UP FIX #2 (root-caused from a real user SCREEN RECORDING -- not
## just a screenshot -- so this is video-frame-confirmed, not just measured
## in the debug console): three bugs, all traced to the same underlying
## cause. (1) The rope collapsed to a tiny ~0.3-0.5 unit hanging stub right
## next to the dagger the instant the dart anchored, and stayed exactly like
## that for the rest of the clip even with the character standing 2-3 grid
## cells away -- the dominant, most severe symptom. (2) The leftover stub
## visibly drooped downward under what was clearly gravity. (3) During
## FLYING, the rope still showed the ORIGINAL "disconnected floating dash
## segments" look, i.e. FOLLOW-UP FIX #1 above (raw PhysicsServer3D pin
## joints with correct local anchors) did NOT fully fix the earlier
## complaint either.
##
## Root cause of all three: every segment RigidBody3D had normal gravity
## (default gravity_scale = 1.0, never overridden) pulling it down every
## physics step, opposed only by PIN_JOINT_BIAS/DAMPING's soft, gradual
## positional correction (deliberately left at PhysicsServer3D's own
## un-stiffened defaults -- see the note a few paragraphs up about why a
## stiffer tuning was already tried once and found to make the chain
## explode). Against a constant, continuous downward force, that soft
## correction can't keep light (ROPE_SEGMENT_MASS = 0.03) segments taut
## across a real multi-unit span -- the chain sags under its own portrayed
## weight and settles toward some other equilibrium instead, which is
## exactly "collapses toward one point" (Bug 1) combined with "visibly
## drooping" (Bug 2). This also explains why FOLLOW-UP FIX #1's own
## verification (a temporary gap probe) never caught this: that probe only
## ran for a few seconds right after a throw and only measured LOCAL gaps
## between adjacent segment ends, which stay small even while the whole
## chain is gradually sagging as a unit -- it never checked whether the
## chain's TOTAL span still matched the real hand-to-dart distance over a
## sustained multi-second anchored hold, which is what the user's recording
## actually showed failing. Bug 3 (still-disconnected during FLYING) is the
## same mechanism at a shorter timescale: gravity has less time to act
## before the dart anchors, so it reads as segments trailing behind/below
## where they should be rather than a full collapse yet.
##
## Per the user's own explicit, verbatim requirement -- "I want the rope to
## disregard gravity and live on a plane" -- this is the actual spec, not
## just a bugfix detail: every segment now (a) has gravity_scale = 0.0 (see
## _make_rope_segment_body()), the literal "disregard gravity," and (b) is
## hard-locked to the dart's own fixed plane_y height every physics step via
## a dedicated rope_segment_body.gd script's _integrate_forces() override
## (Godot's own documented, solver-safe way to override a RigidBody3D's
## transform each step -- see that script's own doc comment for why this is
## used instead of just relying on gravity_scale=0 alone, or poking
## global_position from outside physics processing the way the kinematic
## anchors are driven). The plane_y value itself is read from the owning
## rope_dart.gd instance (duck-typed off `dart.plane_y`) and passed down to
## every segment and both kinematic anchors at spawn time -- see
## _spawn_physics_rope(). This keeps real physics-driven XZ collision
## against pillars/trees/cacti (the whole reason for using RigidBody3D at
## all) while eliminating vertical sag entirely, consistent with this game's
## core 2D-XZ-plane-gameplay invariant (see CLAUDE.md) -- the rope's physics
## simulation now lives in exactly the same 2-degrees-of-freedom plane the
## rest of the rope+dart system already does.
##
## The IDLE/coiled look (dart == null, ROPE_SEGMENTS/_render_rope_coiled()
## above) deliberately stays the old cheap kinematic coil -- there's no
## obstacle to avoid while the rope is just sitting on the character's own
## arm, so full simulation there would only add jitter risk for zero visual
## benefit.
##
## VISUAL: per an explicit follow-up user request ("Can the rope be rope
## instead of segments of bars?"), the THROWN look is no longer rendered as
## ROPE_PHYSICS_SEGMENTS separate CylinderMesh/capsule pieces with visible
## seams at every joint -- see _update_rope_tube_mesh() for the single
## continuous tube mesh (SurfaceTool, Catmull-Rom-interpolated through the
## segment centers) that now renders in their place. The discrete
## RigidBody3D segments described above are UNCHANGED and still exist for
## collision purposes -- this is a pure decoupling of the rendered mesh from
## the physics representation, not a change to the simulation itself.
##
## Segment count is lower than the idle coil's 16 -- physics joint chains get
## less stable as they get longer, and 8 is enough to read as a rope at this
## game's camera distance without excess joint count per simultaneously
## thrown dart (up to ~6 at once in a full match).
const ROPE_PHYSICS_SEGMENTS: int = 8
## Total simulated chain length always equals DART_ROPE_LENGTH (the dart's
## own fixed max range), regardless of the CURRENT hand-to-dart distance --
## matches rope_dart.gd's own "fixed rope length, not charge-scaled" design.
## The chain is always LAID OUT at this full fixed length from the hand along
## the current hand->tip (or, if that span is ~0, the aim) direction, even
## when the dart's real current position is much closer -- the zero-baked-in-
## offset joint design above means this initial pose doesn't have to match
## the tip anchor's real position for correctness, only for how settled the
## very first frame or two look before the solver pulls the far end taut
## toward the real target. When the dart is anchored closer than this, the
## chain carries visible slack/sag between the two ends rather than
## stretching taut, which is actually the physically correct look for a rope
## longer than the gap it spans -- not verified visually, see this session's
## final report for the honest caveat on how a short throw's slack reads on
## screen.
const ROPE_PHYSICS_SEGMENT_LENGTH: float = DART_ROPE_LENGTH / float(ROPE_PHYSICS_SEGMENTS)
const ROPE_PHYSICS_SEGMENT_HALF_LENGTH: float = ROPE_PHYSICS_SEGMENT_LENGTH * 0.5
const ROPE_SEGMENT_MASS: float = 0.03
const ROPE_LINEAR_DAMP: float = 1.6
const ROPE_ANGULAR_DAMP: float = 2.2
## Matches arena_obstacle.gd's own copy of this same bit -- see that script's
## comment for why it's duplicated rather than shared, and for the
## one-directional layer/mask design (chain reacts to obstacles; nothing
## reacts to the chain) that keeps this simulated rope from ever pushing a
## player or interfering with the dart's own already-working flight raycast.
const ROPE_OBSTACLE_LAYER_BIT: int = 1 << 1  # layer 2

## Preloaded once at class scope (not instantiated per-dart) -- every rope
## segment body shares this same script; see rope_segment_body.gd's own doc
## comment for the plane-lock/no-gravity mechanism it implements.
const RopeSegmentBodyScript: Script = preload("res://scripts/rope_segment_body.gd")

## --- Continuous tube-mesh rendering for the thrown/physics rope (visual
## only -- see this const block's parent doc comment above) ---
## Sample count along the Catmull-Rom curve through the chain's control
## points -- deliberately much higher than ROPE_PHYSICS_SEGMENTS (8) itself,
## since this is purely a rendering smoothness knob with no physics cost
## (the curve is evaluated in plain Vector3 math, not simulated).
const ROPE_TUBE_CURVE_SAMPLES: int = 48
## Radial cross-section resolution of the extruded tube -- 8-sided reads as
## round at this game's camera distance without excessive triangle count
## (ROPE_TUBE_CURVE_SAMPLES * ROPE_TUBE_RADIAL_SEGMENTS quads per dart, up to
## ~6 simultaneous darts in a full match).
const ROPE_TUBE_RADIAL_SEGMENTS: int = 8

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
## The handslot.r BoneAttachment3D itself -- stays visible=true always;
## _static_dagger_mesh and the charge-spin visuals (its children) each
## control their own visibility independently.
var _dagger_in_hand: Node3D = null
## The actual held-dagger mesh, a child of _dagger_in_hand -- see
## _setup_dagger_in_hand(); visible while (dart == null and not charging),
## since the charge-spin visuals take over depicting the weapon while
## winding up a throw.
var _static_dagger_mesh: Node3D = null
## Reference point (lowerarm.r, not handslot.r -- same clipping-avoidance
## reasoning as the old coil mesh this replaced) for where the persistent
## rope's coiled idle shape centers -- see _render_rope_coiled().
var _rope_coil_anchor: Node3D = null
## The single rope object worn on the forearm, always present -- see
## _update_persistent_rope(). Coiled while (dart == null), it redraws as a
## straight sagging line out to the dart once thrown, using the exact same
## segment meshes for both, so it's one object changing shape rather than a
## coil mesh swapped for a separately-spawned tether.
var _rope_segments: Array[MeshInstance3D] = []
## Shared material for both the idle-coil segments above and the physics-rope
## meshes below -- stored here (rather than only as a local in
## _setup_dagger_in_hand()) so _spawn_physics_rope() can reuse the exact same
## look without duplicating the material setup.
var _rope_material: StandardMaterial3D = null
## The real physics-simulated rope chain (see the ROPE_PHYSICS_* consts'
## comment) -- only exists while dart != null; built in _spawn_physics_rope(),
## torn down in _free_physics_rope(), both driven from _update_persistent_rope().
var _physics_rope_root: Node3D = null
var _physics_rope_hand_anchor: RigidBody3D = null
var _physics_rope_tip_anchor: RigidBody3D = null
var _physics_rope_active: bool = false
## Every dynamic segment body, in hand->tip order -- kept as a flat array
## (rather than re-walking _physics_rope_root's children each frame) so
## _update_rope_tube_mesh() can cheaply build its curve control-point list
## every _process() frame.
var _physics_rope_segments: Array[RigidBody3D] = []
## Raw PhysicsServer3D joint RIDs (see _join_rope_pin()) -- these are NOT
## Node3D-owned, so unlike _physics_rope_root's children they are not freed
## automatically when the root is queue_free()'d; _free_physics_rope() must
## explicitly PhysicsServer3D.free_rid() every one of these or they leak.
var _physics_rope_joint_rids: Array[RID] = []
## The single continuous tube MeshInstance3D that visually replaces the
## per-segment CylinderMesh/capsule rendering -- see this file's
## ROPE_TUBE_CURVE_SAMPLES doc comment and _update_rope_tube_mesh(). Rebuilt
## (not just repositioned) every _process() frame the physics chain is
## active, since the curve it traces changes shape continuously as the
## simulated segments move.
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
	## its rest transform) -- exactly what BoneAttachment3D needs for the
	## dart head (reuses rope_dart.gd's own dart_head.glb so the in-hand and
	## in-flight weapon look identical).
	##
	## The rope's coiled-idle anchor is a SEPARATE attachment on "lowerarm.r"
	## instead -- sharing handslot.r with the dagger put both props in the
	## same small span of space, and a coil there would overlap/clip inside
	## the dagger's grip geometry. lowerarm.r measures 0.26 units head-to-tail
	## along its own local -Y (bone length axis), and the actual character
	## mesh's forearm radius there measures ~0.09-0.15 (sampled directly from
	## Barbarian.glb's skinned vertices) -- ROPE_COIL_RADIUS_OUTER (0.16) is
	## sized to clear that. Positioned at the bone's local half-length (-0.13)
	## to sit at the forearm's midpoint.
	##
	## The held dagger's visibility is kept in sync with (dart == null) in
	## _process() rather than at each of _throw()/_on_dart_returned()/kill()/
	## reset_for_round(), so there's a single source of truth for it. The
	## rope (see below) reads the same (dart == null) each frame in
	## _update_persistent_rope() to pick coiled vs. extended, rather than
	## toggling visibility on a second mesh.
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

	var coil_attachment := BoneAttachment3D.new()
	coil_attachment.name = "RopeCoilAttachment"
	coil_attachment.bone_name = "lowerarm.r"
	skeleton.add_child(coil_attachment)
	# A plain child, not a property on the attachment itself -- BoneAttachment3D
	# overwrites its own transform to track the bone every frame, so the local
	# offset/rotation that actually centers the coil on the forearm (same
	# values the old rope_coil.glb instance used) has to live one level down.
	var coil_anchor := Node3D.new()
	coil_anchor.name = "RopeCoilAnchor"
	coil_anchor.position = Vector3(0.0, -0.13, 0.0)
	coil_anchor.rotation_degrees = Vector3(90.0, 0.0, 0.0)
	coil_attachment.add_child(coil_anchor)
	_rope_coil_anchor = coil_anchor

	# The persistent rope itself -- ROPE_SEGMENTS short cylinders, reused for
	# both the coiled-idle shape and the thrown-extended shape (see
	# _update_persistent_rope()). Parented directly under the player rather
	# than any bone attachment, since every segment gets its global_transform
	# set explicitly each frame regardless (same technique the old
	# dart-owned rope segments used) -- only needs to be somewhere in the
	# tree to render.
	var rope_mat := StandardMaterial3D.new()
	rope_mat.albedo_color = Color(0.22, 0.16, 0.12)
	rope_mat.metallic = 0.1
	rope_mat.roughness = 0.75
	rope_mat.emission_enabled = true
	rope_mat.emission = Color(0.1, 0.07, 0.05)
	_rope_material = rope_mat
	var rope_shape := CylinderMesh.new()
	rope_shape.top_radius = ROPE_RADIUS
	rope_shape.bottom_radius = ROPE_RADIUS
	rope_shape.height = 1.0
	for i in range(ROPE_SEGMENTS):
		var seg := MeshInstance3D.new()
		seg.name = "RopeSegment%d" % i
		seg.mesh = rope_shape
		seg.set_surface_override_material(0, rope_mat)
		add_child(seg)
		_rope_segments.append(seg)


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
	if _static_dagger_mesh != null:
		_static_dagger_mesh.visible = (dart == null and not _is_charging)
	_update_persistent_rope()
	_update_charge_spin(delta)
	if is_dead or is_falling:
		return

	var is_moving: bool = _move_speed_smooth > 0.1 and not _is_dashing

	# Skeletal locomotion animation, using KayKit's actual clip names
	# (Idle_A from Rig_Medium_General.glb, Walking_A/Running_A from
	# Rig_Medium_MovementBasic.glb — see _setup_animation()'s ANIM_SOURCES).
	# Dash takes priority over the is_moving check — while dashing we're moving
	# far faster than a walk, so cut straight to the run clip regardless of the
	# (dash-excluded) is_moving state used for Walk/Idle and the procedural bob.
	# A one-shot action clip (throw/slash/kick) gets to finish playing first --
	# otherwise this per-frame selection would stomp it within a single frame
	# of it starting, since nothing here else calls _play_anim(). Recall is a
	# separate override since "Push" is a looping clip -- is_playing() never
	# goes false on its own, so it needs the explicit _is_recalling flag
	# (cleared in _on_dart_returned()) as its end condition instead. Charging
	# also needs its own override even though "Sword_Idle" is NOT looping
	# (plays once and holds its last frame, deliberately -- see
	# _update_charge_shake() for the tremble once that held pose means "max
	# charge"): without this branch, once is_playing() goes false on its own
	# at the end, the elif chain below would fall through to Idle_A/Walking_A
	# and stomp the held pose. _is_charging is cleared on throw_just_released
	# in the throw/charge block below, right as _throw() fires and plays the
	# one-shot "Spell_Simple_Shoot" -- so charging's held "Sword_Idle" pose
	# hands off to the throw clip in the same frame the button is released.
	var action_playing: bool = _anim_player != null and _current_anim in ONE_SHOT_ACTION_CLIPS and _anim_player.is_playing()
	if _is_recalling:
		_play_anim("Push")
	elif _is_charging:
		_play_anim("Sword_Idle")
	elif action_playing:
		pass
	elif _is_dashing:
		_play_anim("Running_A")
	elif is_moving:
		_play_anim("Walking_A", WALK_ANIM_SPEED)
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
	_clamp_to_rope_leash()
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
	## Idle (dart == null): the old cheap kinematic coil, drawn via the
	## ROPE_SEGMENTS MeshInstance3D array (see _render_rope_coiled()).
	## Thrown (dart != null): a real RigidBody3D chain that Godot's own
	## physics engine simulates and collides against actual obstacle geometry
	## (see _spawn_physics_rope()) -- built once per throw, torn down once
	## the dart returns. The two looks use entirely separate node sets now
	## (previously the same 16 MeshInstance3D segments were reshaped for
	## both), so the idle segments are explicitly hidden while the physics
	## chain is active rather than repurposed for it.
	if dart == null:
		if _physics_rope_active:
			_free_physics_rope()
		if not _rope_segments.is_empty():
			_render_rope_coiled()
	else:
		for seg in _rope_segments:
			seg.visible = false
		if not _physics_rope_active:
			_spawn_physics_rope()
		_update_rope_tube_mesh()


func _render_rope_coiled() -> void:
	if _rope_coil_anchor == null:
		for seg in _rope_segments:
			seg.visible = false
		return
	var center: Vector3 = _rope_coil_anchor.global_position
	var coil_basis: Basis = _rope_coil_anchor.global_transform.basis
	var n: int = _rope_segments.size()
	var points: Array[Vector3] = []
	points.resize(n + 1)
	for i in range(n + 1):
		var t: float = float(i) / float(n)
		var angle: float = t * ROPE_COIL_TURNS * TAU
		var radius: float = lerp(ROPE_COIL_RADIUS_INNER, ROPE_COIL_RADIUS_OUTER, t)
		points[i] = center + coil_basis.x * (cos(angle) * radius) + coil_basis.y * (sin(angle) * radius)
	for i in range(n):
		_render_rope_segment(_rope_segments[i], points[i], points[i + 1])


func _get_rope_tip_target() -> Vector3:
	## The single point both _spawn_physics_rope() (initial layout direction)
	## and _update_physics_rope_anchors() (every-tick tracking) treat as
	## "where the dart end of the rope should be" -- the dart's actual
	## rendered pommel position, matching exactly what the old scripted
	## renderer used as its "to" point. Falls back to the hand position (a
	## zero-length span) if there's no valid dart yet/anymore, so callers
	## don't have to null-check.
	if dart != null and is_instance_valid(dart) and dart.head_mesh != null:
		return dart.head_mesh.global_transform * Vector3(0.0, 0.0, DAGGER_POMMEL_OFFSET)
	return get_hand_world_position()


func _get_rope_plane_y() -> float:
	## The one fixed horizontal-plane height every physics-rope segment for
	## the CURRENT dart is locked to (see rope_segment_body.gd's locked_y) --
	## read directly from the owning rope_dart.gd instance's own plane_y
	## (duck-typed, matching how this file already reads dart.head_mesh
	## elsewhere), NOT recomputed from get_hand_world_position(), since the
	## hand's real animated height moves throughout a throw/charge/idle cycle
	## while rope_dart.gd's whole class doc comment is explicit that plane_y
	## itself must stay fixed for a given dart's entire lifetime. Falls back
	## to the current hand height only in the no-dart-yet edge case (there is
	## no dart.plane_y to read before launch() has set it), which in practice
	## never matters since this is only ever called while dart != null.
	if dart != null and is_instance_valid(dart):
		return dart.plane_y
	return get_hand_world_position().y


func _get_rope_hand_anchor_pos() -> Vector3:
	## The hand end of the rope, X/Z from the real (animated, bobbing) hand
	## bone but Y hard-clamped to _get_rope_plane_y() -- matching exactly
	## what the OLD scripted renderer already did (`Vector3(hand_pos.x,
	## plane_y, hand_pos.z)`), before this rope became a physics simulation.
	## This matters beyond just "the hand end should visually sit on the
	## plane too": the kinematic hand anchor is JOINTED to the first dynamic
	## segment, whose Y is hard-locked to plane_y every physics step (see
	## rope_segment_body.gd) -- if the hand anchor's own Y were left free to
	## follow the real hand bone's bob/animation instead, the joint would be
	## fighting a small constant Y mismatch between the two ends every single
	## step, which is exactly the kind of persistent unresolved joint stress
	## this whole fix is meant to eliminate.
	var hand_pos: Vector3 = get_hand_world_position()
	return Vector3(hand_pos.x, _get_rope_plane_y(), hand_pos.z)


func _spawn_physics_rope() -> void:
	## Builds the real RigidBody3D chain: a kinematic hand anchor, a kinematic
	## tip anchor (tracked toward the dart every physics tick -- see
	## _update_physics_rope_anchors(), called from _physics_process()),
	## ROPE_PHYSICS_SEGMENTS dynamic segments between them, and a raw
	## PhysicsServer3D pin joint (see _join_rope_pin()) between every
	## consecutive pair, each using EXPLICIT per-body local anchor points --
	## see the ROPE_PHYSICS_* consts' comment above for why this replaced an
	## earlier Node-based PinJoint3D version that visibly failed to hold
	## together (root cause: implicit setup-time-position offsets, not a
	## rendering bug and not purely a fast-motion issue). Godot's own solver
	## is still what keeps this off of pillars/trees/cacti -- nothing here
	## computes a bend point or reads any obstacle's rect/shape data directly.
	##
	## Parented under get_parent() (the arena root), not under self -- self is
	## a moving CharacterBody3D, and physics bodies nested under a moving
	## Node3D would need top_level=true to avoid their transforms getting
	## double-applied; simplest to just avoid the nesting entirely (same
	## parenting rope_dart.gd's own dart instance already uses from _throw()).
	if _physics_rope_root != null:
		return
	var root := Node3D.new()
	root.name = "PhysicsRopeChain_%d" % player_index
	get_parent().add_child(root)
	_physics_rope_root = root

	var plane_y: float = _get_rope_plane_y()
	# Hand end is plane-locked here too (X/Z from the real hand, Y forced to
	# plane_y) -- see _get_rope_hand_anchor_pos()'s own comment for why this
	# matters beyond just visual consistency: it keeps the joint to the first
	# dynamic segment (itself plane-locked) from fighting a constant Y
	# mismatch every physics step. tip_pos is already at plane_y on its own
	# (rope_dart.gd's _render() always sets head_mesh's Y to plane_y), so no
	# separate correction is needed there.
	var hand_pos: Vector3 = _get_rope_hand_anchor_pos()
	var tip_pos: Vector3 = _get_rope_tip_target()

	# Initial layout direction: along the current hand->tip span if it's
	# meaningful, else along the player's current aim -- purely cosmetic (see
	# the ROPE_PHYSICS_SEGMENT_LENGTH comment: correctness no longer depends
	# on this matching the tip's real position, only how settled the very
	# first frame or two look). Both endpoints already share the same Y
	# (plane_y), so this direction is naturally flat (zero Y component)
	# whenever it's derived from the real span -- the aim-direction fallback
	# is explicitly constructed flat for the same reason.
	var span: Vector3 = tip_pos - hand_pos
	var span_dir: Vector3
	if span.length() > 0.01:
		span_dir = span.normalized()
	else:
		span_dir = Vector3(aim_dir.x, 0.0, aim_dir.y).normalized()
	if span_dir.length() < 0.01:
		span_dir = Vector3.FORWARD

	var y_axis: Vector3 = span_dir
	var basis_seed: Vector3 = Vector3.RIGHT if absf(y_axis.dot(Vector3.UP)) > 0.99 else Vector3.UP
	var x_axis: Vector3 = basis_seed.cross(y_axis).normalized()
	var z_axis: Vector3 = x_axis.cross(y_axis).normalized()
	var seg_basis := Basis(x_axis, y_axis, z_axis)

	_physics_rope_hand_anchor = _make_rope_anchor_body(root, "RopeHandAnchor", hand_pos)
	_physics_rope_tip_anchor = _make_rope_anchor_body(root, "RopeTipAnchor", tip_pos)

	var local_far := Vector3(0.0, ROPE_PHYSICS_SEGMENT_HALF_LENGTH, 0.0)
	var local_near := Vector3(0.0, -ROPE_PHYSICS_SEGMENT_HALF_LENGTH, 0.0)

	_physics_rope_segments.clear()
	var prev: RigidBody3D = _physics_rope_hand_anchor
	var prev_local_far := Vector3.ZERO  # the hand anchor's own attachment point is always its own origin
	for i in range(ROPE_PHYSICS_SEGMENTS):
		# Always laid out at full segment length along span_dir, from the hand
		# outward -- NOT compressed/scaled to the current (possibly ~0 at
		# throw-instant) hand-tip distance. See the ROPE_PHYSICS_SEGMENT_LENGTH
		# comment for why that's fine now (no baked-in offset error either way).
		var seg_center: Vector3 = hand_pos + span_dir * (ROPE_PHYSICS_SEGMENT_HALF_LENGTH + float(i) * ROPE_PHYSICS_SEGMENT_LENGTH)
		var seg: RigidBody3D = _make_rope_segment_body(root, "RopeSeg%d" % i, seg_center, seg_basis, plane_y)
		_physics_rope_segments.append(seg)
		_join_rope_pin(prev, prev_local_far, seg, local_near)
		prev = seg
		prev_local_far = local_far
	_join_rope_pin(prev, prev_local_far, _physics_rope_tip_anchor, Vector3.ZERO)
	_physics_rope_active = true


func _make_rope_anchor_body(parent: Node3D, node_name: String, pos: Vector3) -> RigidBody3D:
	## A driven (kinematic-frozen) endpoint with no collision shape and no
	## mesh of its own -- purely a joint attachment point whose position is
	## overwritten every physics tick (see _update_physics_rope_anchors()).
	## collision_layer/mask both 0: it must never be detectable by, or react
	## to, anything (including the real obstacle layer the segments below
	## react to) -- it's just a moving pin, not a physical object. Its own
	## local anchor point for every joint it's part of is always exactly
	## Vector3.ZERO (its own origin) -- see _join_rope_pin()'s callers.
	var body := RigidBody3D.new()
	body.name = node_name
	body.freeze = true
	body.freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
	body.collision_layer = 0
	body.collision_mask = 0
	# Must add_child() before setting global_position -- global_position's
	# setter calls get_global_transform() internally, which errors ("Returning
	# Transform3D()") on a node that isn't inside the tree yet.
	parent.add_child(body)
	body.global_position = pos
	return body


func _make_rope_segment_body(parent: Node3D, node_name: String, pos: Vector3, orient_basis: Basis, plane_y: float) -> RigidBody3D:
	## One real physics link: a capsule collider (smoother than a cylinder for
	## sliding along an obstacle's edge/corner, same reasoning games commonly
	## use capsules for chain links) -- NO mesh/visual of its own anymore (see
	## this file's ROPE_TUBE_CURVE_SAMPLES doc comment: the thrown rope's
	## visual is one continuous tube mesh built separately in
	## _update_rope_tube_mesh(), decoupled from these discrete collision
	## bodies). `orient_basis` is the segment's initial orientation (local Y
	## aligned along the chain's layout direction, see _spawn_physics_rope())
	## -- without this every segment defaulted to identity rotation (local Y
	## = world up), forcing the solver to fight a large, unnecessary initial
	## rotation error on top of position. (Named orient_basis, not basis, to
	## avoid shadowing Node3D's own `basis` property, which GDScript warns on.)
	##
	## gravity_scale = 0.0 and the attached rope_segment_body.gd script
	## (locked_y = plane_y) are this fix's actual mechanism for the user's
	## explicit "disregard gravity and live on a plane" requirement -- see
	## that script's own doc comment and this file's ROPE_PHYSICS_SEGMENTS
	## doc comment above for the full root-cause writeup on why gravity was
	## the actual cause of the anchored-rope-collapses-to-a-stub bug.
	##
	## collision_mask = ROPE_OBSTACLE_LAYER_BIT ONLY (not the default layer):
	## reacts to real obstacle geometry, never to players/ground/the dart
	## head. collision_layer = 0: nothing else's mask can ever detect this
	## segment either -- strictly one-directional, so the chain can never
	## push a player or otherwise leak into gameplay logic.
	var body := RigidBody3D.new()
	body.name = node_name
	body.set_script(RopeSegmentBodyScript)
	body.locked_y = plane_y
	body.mass = ROPE_SEGMENT_MASS
	body.gravity_scale = 0.0
	body.linear_damp = ROPE_LINEAR_DAMP
	body.angular_damp = ROPE_ANGULAR_DAMP
	body.continuous_cd = true
	body.collision_layer = 0
	body.collision_mask = ROPE_OBSTACLE_LAYER_BIT

	var shape := CollisionShape3D.new()
	var capsule := CapsuleShape3D.new()
	capsule.radius = ROPE_RADIUS
	capsule.height = ROPE_PHYSICS_SEGMENT_LENGTH
	shape.shape = capsule
	body.add_child(shape)

	# Must add_child() before setting global_transform -- same is_inside_tree()
	# requirement as _make_rope_anchor_body() above.
	parent.add_child(body)
	body.global_transform = Transform3D(orient_basis, pos)
	return body


func _join_rope_pin(a: RigidBody3D, local_a: Vector3, b: RigidBody3D, local_b: Vector3) -> void:
	## Creates one PinJoint3D-equivalent constraint via the low-level
	## PhysicsServer3D API directly, instead of a PinJoint3D node -- see the
	## ROPE_PHYSICS_* consts' comment for why: this is what lets each body's
	## local anchor point be declared EXPLICITLY and INDEPENDENTLY
	## (`local_a`/`local_b`, in each body's own local space) rather than both
	## being implicitly derived from a single shared world position at setup
	## time, which is what let the earlier PinJoint3D-node version silently
	## bake in a wrong offset whenever the two bodies didn't already coincide
	## when the joint was created. No Node3D is created for this at all --
	## the joint exists purely as a RID on the physics server, so
	## _free_physics_rope() must explicitly free it (see
	## _physics_rope_joint_rids' own comment). Bias/damping are deliberately
	## left unset (PhysicsServer3D's own defaults apply) -- see the
	## ROPE_PHYSICS_* consts' comment for why a stiffer tuning was tried and
	## measured to actively cause the chain to explode.
	var joint_rid: RID = PhysicsServer3D.joint_create()
	PhysicsServer3D.joint_make_pin(joint_rid, a.get_rid(), local_a, b.get_rid(), local_b)
	_physics_rope_joint_rids.append(joint_rid)


func _update_physics_rope_anchors() -> void:
	## Drives the two kinematic endpoints every physics tick -- called from
	## _physics_process() unconditionally (no-ops via _physics_rope_active
	## when there's no active chain). The hand end tracks
	## _get_rope_hand_anchor_pos() (X/Z from the real hand, Y locked to
	## plane_y -- see that function's own comment for why the Y-lock matters
	## here specifically, not just at spawn time); the tip end tracks
	## _get_rope_tip_target(), whatever the dart's current state (FLYING/
	## ANCHORED/RECALLING) -- so the chain is simulated for the dart's entire
	## time out, not just while anchored. See this session's final report for
	## the explicit, known instability risk this carries during FLYING/
	## RECALLING, when the tip anchor can move at up to travel_speed/
	## recall_speed (18-36 units/sec) in a single tick -- measured via a
	## temporary gap probe to spike the real per-joint gap up to ~10-12 units
	## for a few ticks right after a throw before settling back down to
	## ~0.02-0.1 at rest (see the ROPE_PHYSICS_* consts' comment), never
	## diverging in that testing, but this remains genuinely unverified as to
	## how it actually looks on screen -- no screenshot access this session.
	if not _physics_rope_active:
		return
	if _physics_rope_hand_anchor != null:
		_physics_rope_hand_anchor.global_position = _get_rope_hand_anchor_pos()
	if _physics_rope_tip_anchor != null:
		_physics_rope_tip_anchor.global_position = _get_rope_tip_target()


func _free_physics_rope() -> void:
	# Raw PhysicsServer3D joints are independent RIDs, not owned by any node
	# -- queue_free()'ing the root below does NOT free these; must be done
	# explicitly first or they leak for the lifetime of the process.
	for joint_rid in _physics_rope_joint_rids:
		if joint_rid.is_valid():
			PhysicsServer3D.free_rid(joint_rid)
	_physics_rope_joint_rids.clear()
	if _physics_rope_root != null and is_instance_valid(_physics_rope_root):
		_physics_rope_root.queue_free()
	_physics_rope_root = null
	_physics_rope_hand_anchor = null
	_physics_rope_tip_anchor = null
	_physics_rope_segments.clear()
	_physics_rope_active = false
	if _physics_rope_tube_mesh != null:
		_physics_rope_tube_mesh.visible = false


func _update_rope_tube_mesh() -> void:
	## Per an explicit follow-up user request ("Can the rope be rope instead
	## of segments of bars?"), the thrown rope's VISUAL is decoupled from the
	## discrete RigidBody3D collision segments entirely: this rebuilds one
	## continuous ArrayMesh every _process() frame the physics chain is
	## active, tracing a smooth Catmull-Rom curve through the control points
	## [hand anchor, every dynamic segment's center, tip anchor] (in that
	## order -- matches the actual joint chain order from
	## _spawn_physics_rope()) and extruding a round tube of ROPE_RADIUS along
	## it. The underlying RigidBody3D segments and their capsule collision
	## shapes are completely unchanged by this -- they still exist, still
	## collide with real obstacle geometry, and still drive this curve's
	## shape; only what gets DRAWN from their positions changed.
	if _physics_rope_root == null or _physics_rope_hand_anchor == null or _physics_rope_tip_anchor == null:
		return
	if _physics_rope_segments.size() != ROPE_PHYSICS_SEGMENTS:
		return

	if _physics_rope_tube_mesh == null:
		var mi := MeshInstance3D.new()
		mi.name = "RopeTubeMesh"
		# Material is applied AFTER _build_tube_mesh() gives this mesh its
		# first real surface (below) -- set_surface_override_material(0, ...)
		# errors ("Index p_surface = 0 is out of bounds") on a MeshInstance3D
		# whose mesh has zero surfaces yet, which is exactly this freshly
		# created node's state until the first _build_tube_mesh() call commits
		# an ArrayMesh onto it.
		add_child(mi)
		_physics_rope_tube_mesh = mi

	var control_points: Array[Vector3] = [_physics_rope_hand_anchor.global_position]
	for seg in _physics_rope_segments:
		control_points.append((seg as RigidBody3D).global_position)
	control_points.append(_physics_rope_tip_anchor.global_position)
	var n: int = control_points.size()

	# Sample a Catmull-Rom curve through control_points at ROPE_TUBE_CURVE_SAMPLES
	# steps -- Vector3.cubic_interpolate(b, pre_a, post_b, weight) needs a
	# "before the start" and "after the end" handle for every interpolated
	# span; clamping the index at both ends (rather than requiring 4 real
	# neighbors) is what lets this work even at the very first/last span,
	# and lets the whole curve work correctly with as few as 2 control points
	# (a degenerate straight line -- possible right at throw-instant, when
	# the tip anchor and every not-yet-separated segment can start nearly
	# coincident).
	var curve_points: Array[Vector3] = []
	curve_points.resize(ROPE_TUBE_CURVE_SAMPLES + 1)
	for i in range(ROPE_TUBE_CURVE_SAMPLES + 1):
		var t: float = float(i) / float(ROPE_TUBE_CURVE_SAMPLES)
		var f: float = t * float(n - 1)
		var seg_i: int = clampi(int(f), 0, n - 2)
		var local_t: float = f - float(seg_i)
		var p0: Vector3 = control_points[clampi(seg_i - 1, 0, n - 1)]
		var p1: Vector3 = control_points[seg_i]
		var p2: Vector3 = control_points[clampi(seg_i + 1, 0, n - 1)]
		var p3: Vector3 = control_points[clampi(seg_i + 2, 0, n - 1)]
		curve_points[i] = p1.cubic_interpolate(p2, p0, p3, local_t)

	_build_tube_mesh(_physics_rope_tube_mesh, curve_points, ROPE_RADIUS, ROPE_TUBE_RADIAL_SEGMENTS)
	_physics_rope_tube_mesh.visible = true


func _build_tube_mesh(mi: MeshInstance3D, curve_points: Array[Vector3], radius: float, radial_segments: int) -> void:
	## Extrudes a round tube of constant `radius` along `curve_points` (a
	## polyline, already densely sampled by the caller -- see
	## _update_rope_tube_mesh()) via SurfaceTool, and assigns the result as
	## `mi`'s mesh. Each ring's orientation is built from the local tangent
	## (direction to the next point) with a stable perpendicular basis
	## (same RIGHT/UP basis-seed trick used elsewhere in this file for
	## building a basis from a single direction vector), so the tube doesn't
	## twist unpredictably along its length.
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	var point_count: int = curve_points.size()
	if point_count < 2:
		mi.mesh = null
		return

	var rings: Array[PackedVector3Array] = []
	rings.resize(point_count)
	for i in range(point_count):
		var tangent: Vector3
		if i == 0:
			tangent = (curve_points[1] - curve_points[0])
		elif i == point_count - 1:
			tangent = (curve_points[i] - curve_points[i - 1])
		else:
			tangent = (curve_points[i + 1] - curve_points[i - 1])
		if tangent.length() < 0.0001:
			tangent = Vector3.FORWARD
		tangent = tangent.normalized()
		var basis_seed: Vector3 = Vector3.RIGHT if absf(tangent.dot(Vector3.UP)) > 0.99 else Vector3.UP
		var right: Vector3 = basis_seed.cross(tangent).normalized()
		var up: Vector3 = tangent.cross(right).normalized()
		var ring := PackedVector3Array()
		ring.resize(radial_segments)
		for j in range(radial_segments):
			var angle: float = TAU * float(j) / float(radial_segments)
			ring[j] = curve_points[i] + (right * cos(angle) + up * sin(angle)) * radius
		rings[i] = ring

	for i in range(point_count - 1):
		var ring_a: PackedVector3Array = rings[i]
		var ring_b: PackedVector3Array = rings[i + 1]
		for j in range(radial_segments):
			var j_next: int = (j + 1) % radial_segments
			var a0: Vector3 = ring_a[j]
			var a1: Vector3 = ring_a[j_next]
			var b0: Vector3 = ring_b[j]
			var b1: Vector3 = ring_b[j_next]
			# Two triangles per quad, wound so the outward-facing normal
			# points away from the tube's own centerline (consistent with
			# SurfaceTool.generate_normals()'s face-winding expectations).
			st.add_vertex(a0)
			st.add_vertex(b0)
			st.add_vertex(a1)
			st.add_vertex(a1)
			st.add_vertex(b0)
			st.add_vertex(b1)

	st.generate_normals()
	mi.mesh = st.commit()
	# Must be applied AFTER mi.mesh is assigned -- set_surface_override_material
	# errors on a MeshInstance3D whose mesh has no surfaces yet, which every
	# call before this line's mi.mesh assignment would still be.
	if _rope_material != null:
		mi.set_surface_override_material(0, _rope_material)


func _render_rope_segment(seg: MeshInstance3D, from_pt: Vector3, to_pt: Vector3) -> void:
	var diff: Vector3 = to_pt - from_pt
	var length: float = diff.length()
	if length < 0.001:
		seg.visible = false
		return
	seg.visible = true
	var y_axis: Vector3 = diff / length
	var basis_seed: Vector3 = Vector3.RIGHT if absf(y_axis.dot(Vector3.UP)) > 0.99 else Vector3.UP
	var x_axis: Vector3 = basis_seed.cross(y_axis).normalized()
	var z_axis: Vector3 = x_axis.cross(y_axis).normalized()
	seg.global_transform = Transform3D(Basis(x_axis, y_axis * length, z_axis), (from_pt + to_pt) * 0.5)


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


func _clamp_to_rope_leash() -> void:
	## Once the rope dart is anchored, its rope is a fixed-length physical
	## tether (see rope_dart.gd's class doc comment) -- the owner shouldn't be
	## able to walk further from the anchor point than the rope allows.
	## Pulls the player back onto the circle of radius DART_ROPE_LENGTH around
	## the anchor instead of blocking movement outright, so running at an
	## angle slides along the tether's edge rather than just stopping dead.
	if dart == null or dart.state != DART_STATE_ANCHORED:
		return
	var anchor: Vector2 = dart.head_2d
	var pos: Vector2 = get_pos_2d()
	var offset: Vector2 = pos - anchor
	if offset.length() <= DART_ROPE_LENGTH:
		return
	var clamped: Vector2 = anchor + offset.normalized() * DART_ROPE_LENGTH
	global_position.x = clamped.x
	global_position.z = clamped.y


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
	_charge_shake_time = 0.0
	_is_recalling = false
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
	_is_recalling = false
