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
## AND the rendered tube mesh's radius (see _build_tube_mesh()) share this
## single constant. ROUND (full architecture reset, see CLAUDE.md): the old
## separate idle-coil visual (ROPE_SEGMENTS cheap kinematic MeshInstance3D
## cylinders, redrawn as a spiral while dart == null) is GONE -- per direct
## user mandate ("I want the rope to be a physic object just like the
## character, tree, or pillar... When held, all segments collapse into the
## character's hand"), the idle look is now just this same persistent
## 32-segment physics chain (see ROPE_PHYSICS_SEGMENTS below) resting bunched
## at the hand, not a separate rendering system.
const ROPE_RADIUS: float = 0.035

## --- Real physics rope chain: ONE persistent object per player, spawned
## once in _ready() and never torn down/rebuilt per-throw -- see
## _spawn_physics_rope(). Full architecture reset (see CLAUDE.md's dated
## entry) per direct, explicit user mandate rejecting every earlier round's
## shortest-path/visibility-graph render-side routing: "Why are we computing
## the shortest path???? It doesn't work like that. I want the rope to be a
## physic object just like the character, tree, or pillar... The rope is 32
## segments of bar. When held, all segments collapse into the character's
## hand. When the dart is thrown, the rope unfold segment by segment and when
## retrieving, the rope fold segment by segment as well."
##
## Mechanism: a kinematic hand anchor and a kinematic tip anchor, joined by
## ROPE_PHYSICS_SEGMENTS dynamic RigidBody3D capsule links via raw
## PhysicsServer3D pin joints (_join_rope_pin() -- explicit, independent
## per-body local anchor points; NOT PinJoint3D nodes, whose implicit
## shared-setup-position offsets were found, in an earlier round, to bake in
## a wrong "hold body centers together" constraint instead of "hold capsule
## ends together" whenever bodies don't already coincide at spawn -- see git
## history for the original root-cause writeup). The tip anchor tracks
## _get_rope_tip_target() every physics tick (player.gd's
## _update_physics_rope_anchors(), called from _physics_process()) --
## get_hand_world_position() (i.e. the tip COINCIDES with the hand) whenever
## dart == null, and the dart's own live position otherwise. Segments are
## spawned bunched near the hand (ROPE_BUNCH_SPACING) and STAY there at rest
## since the tip anchor never moves away while idle -- this is what makes
## "collapse into the hand" the chain's natural resting configuration rather
## than a separately-authored idle visual, and what makes "unfold
## segment-by-segment on throw" / "fold segment-by-segment on retrieve" fall
## directly out of real joint-constraint propagation as the tip anchor moves
## away/back, with NO separate pacing mechanism dictating it (see
## ROPE_PHYSICS_SEGMENTS' own comment below for why the old growing-leash
## max_reach_from_hand position clamp was deleted, not reused, for this).
##
## Y-PLANE LOCK (non-negotiable, unchanged from every earlier round -- per
## explicit user requirement, "I want the rope to disregard gravity and live
## on a plane"): every segment has gravity_scale = 0.0 AND is hard-locked to
## the dart's fixed plane_y every physics step via rope_segment_body.gd's
## _integrate_forces() override (Godot's own documented, solver-safe way to
## correct a RigidBody3D's transform each step -- poking global_position from
## outside physics processing is explicitly discouraged by Godot's docs).
## Real collision against obstacle geometry (pillars/trees/cacti) is
## Godot's own solver reacting to each segment's capsule CollisionShape3D on
## ROPE_OBSTACLE_LAYER_BIT -- see arena_obstacle.gd's matching layer bit --
## with collision_layer left at 0 so the chain can never push a player or
## leak into any other gameplay system.
##
## WHAT WAS DELETED THIS ROUND, AND WHY: every render-side "compute where the
## rope SHOULD be based on geometry, then draw that" correction layer --
## the visibility-graph + Dijkstra shortest path
## (_visibility_graph_route()/_segment_crosses_rect_interior()), the
## corner-selection heuristics it had itself replaced
## (_corner_route_waypoints()/_rect_nearest_edge_index()/
## _rect_shared_corner()), and the per-sample obstacle-clamp fallbacks
## (_point_inside_any_obstacle()/_nearest_point_outside_obstacles()/
## _route_through_polyline()) -- plus BOTH of rope_segment_body.gd's
## synthetic position clamps (max_reach_from_hand's growing-leash sphere and
## max_perp_from_line's taut-line tube, see that script's own doc comment).
## Per the user's own explicit framing: real objects like the character or a
## pillar don't need a computed path to avoid each other, their real
## collision shapes just physically can't occupy the same space -- so the
## rope must work the same way, and _compute_rope_tube_curve_points() now
## does nothing but trace a smooth Catmull-Rom curve through wherever the
## REAL RigidBody3D segments actually are, full stop. If the rendered rope
## ever clips a pillar now, that means the real physics chain clipped it --
## a genuine collision bug to fix at the physics/collision level (segment
## count, capsule radius, collision margins, joint config), never something
## to paper over in the render.
## ROUND 15 (2026-07-25): 32 -> 24, per explicit user direction ("Let's try
## 24 joints"), alongside the DART_ROPE_LENGTH resize above.
const ROPE_PHYSICS_SEGMENTS: int = 24
## Total simulated chain length always equals DART_ROPE_LENGTH (the dart's
## own fixed max range) regardless of the CURRENT hand-to-dart distance.
const ROPE_PHYSICS_SEGMENT_LENGTH: float = DART_ROPE_LENGTH / float(ROPE_PHYSICS_SEGMENTS)
const ROPE_PHYSICS_SEGMENT_HALF_LENGTH: float = ROPE_PHYSICS_SEGMENT_LENGTH * 0.5
## Total span of the whole initial bunch laid out at _ready()-time
## construction (see _spawn_physics_rope()) -- a small, FIXED length
## independent of ROPE_PHYSICS_SEGMENTS (segments are spaced out evenly
## across this fixed total, not by a fixed per-segment gap -- see
## _spawn_physics_rope()'s own comment for why that distinction matters at
## 32 segments), so the very first render frame reads as "collapsed at the
## hand" (per the user's literal spec) regardless of segment count, rather
## than sitting exactly on top of the hand anchor's own point.
const ROPE_BUNCH_SPACING: float = 0.4
## Mass per unit of segment length (a linear density), not a bare per-segment
## mass -- this is what actually stayed constant across every prior
## segment-count resize (ROUND 12: 8 segments @ 1.0 length-per-segment @ 0.03
## mass; ROUND 12->15: 32 segments @ 0.25 length-per-segment @ 0.0075 mass;
## every one of those ratios is 0.03/1.0=0.03). ROUND 15 itself only
## re-derived mass for a segment-COUNT change (32->24) at a fixed total
## length (8.4), so it approximated this via "keep the whole chain's total
## mass at the original 0.24" -- equivalent to this density only because the
## length didn't change that round. ROUND 16 (2026-07-25) changes the LENGTH
## too (8.4 -> 7.2, see DART_ROPE_LENGTH above), so per the task's own
## instruction to re-derive mass proportionally to the new total length, this
## is now expressed directly as density * current segment length, which
## automatically scales total chain mass down with a shorter rope (0.24 ->
## 0.216) rather than holding it artificially fixed.
const ROPE_SEGMENT_LINEAR_MASS_DENSITY: float = 0.03
const ROPE_SEGMENT_MASS: float = ROPE_SEGMENT_LINEAR_MASS_DENSITY * ROPE_PHYSICS_SEGMENT_LENGTH
## ROUND 17 (2026-07-26) -- raised from 1.6/2.2 (present since the very first
## physics-chain commit, 2026-07-22, and never previously singled out as its
## own lever) per direct user report ("why is the rope shaking without the
## character moving") of a genuinely different configuration than any prior
## round measured: a dart that has been ANCHORED and stationary for several
## seconds, not mid-throw/mid-retrieve. See tests/test_rope_physics_chain_
## settle.gd's own new "5. ANCHORED STEADY-STATE JITTER" section for the
## measurement this was tuned against. Real numbers, not assumed: at the OLD
## 1.6/2.2 damping, three of four realistic settled-anchor configs (open-air
## slack, corner-wrap, a REAL throw-to-anchor at a pillar) already measured
## tiny (seg_max_step 0.0007-0.006 units/tick over a 6s window, several
## seconds after the anchor transition) -- i.e. even the OLD damping was
## nowhere near the scale of a bug that would read as "visibly, measurably
## changes shape" on screen. Raising damping to 3.0/4.0 still measurably
## helped those three configs further (seg_max_step down to ~0.0002-0.002,
## amplification vs. the hand's own tiny animated-idle motion often dropping
## BELOW 1.0, i.e. the chain now damps out noise faster than the driving
## hand bone introduces it) with zero measured regression: the full
## regression suite (idle collapse, 8-config settled-obstacle sweep, throw
## unfold/retrieve fold) and a 50-second 4-hard-bot soak were re-run at the
## new damping and showed the same pass/fail pattern (including the same
## already-documented ROUND 9/11/12/15/16 settled-config-sweep flakiness --
## which config flakes shifts run to run, but the flake RATE did not
## increase) as an identical run at the old damping via git-stash A/B.
## HONEST, DISCLOSED LIMITATION -- the fourth config, "open_air_taut" (a
## dart anchored at/near max ROPE_LENGTH range in open air, i.e. ZERO slack
## -- the common real case per rope_dart.gd's own "anchor at max range if
## nothing was hit" behavior), was NOT fixed by this change: it showed the
## same bimodal ~0.0002-0.03 seg_max_step / ~0.004-0.04 joint_gap_max range
## at BOTH 1.6/2.2 and 3.0/4.0 damping, across repeated runs. Root cause,
## reasoned from the numbers (a fully-taut, zero-slack chain sitting exactly
## at its own total physical capacity has no slack left to silently absorb
## any tiny per-joint numerical residual -- unlike every other config, which
## has real spare capacity to fold into): this reads as a genuine solver
## degenerate-case sensitivity specific to zero slack, not a "too much
## kinetic energy" problem body damping (which drains existing motion, not
## a geometric constraint at its limit) can address -- consistent with
## ROUND 13/14's separate finding that JOINT-level (not body-level) stiffness
## tuning is the dangerous, already-rejected lever for problems in this
## family. Left as an open, disclosed item, not attempted further this round
## (out of scope for "try body damping" specifically).
## SEPARATE, DIRECTLY-MEASURED FINDING FROM THIS SAME ROUND, kept here since
## it changes where to look next if the user's NEXT report is still "the
## rope shakes": arena_camera.gd's own _process() recomputes camera position
## AND orthographic size every frame from the AABB of ALL alive players plus
## ALL active darts -- not just the one player/dart on screen. A scratch
## probe (2-player real match, one player force-anchored and never touched
## again, one hard bot left to roam) measured the camera's own per-frame
## position/size step (~0.019 / ~0.025 units/frame, driven purely by the
## OTHER bot moving elsewhere) as COMPARABLE TO OR LARGER than this file's
## own worst-case rope-chain jitter number above -- i.e. in any real match
## with more than one active player (the normal case), continuous camera
## re-centering/re-zooming is a real, measured, competing explanation for
## "things on screen visibly reshape even though nothing near them moved,"
## entirely independent of the rope's own physics and NOT addressed by this
## round's damping change. Flagged for the user's own judgment, not fixed
## here (out of this round's explicit scope) -- if reported again with
## confirmation that OTHER players/bots were active/moving in the same clip,
## this is the first place to look, not the rope chain again.
const ROPE_LINEAR_DAMP: float = 3.0
const ROPE_ANGULAR_DAMP: float = 4.0
## Matches arena_obstacle.gd's own copy of this same bit -- see that script's
## comment for why it's duplicated rather than shared, and for the
## one-directional layer/mask design (chain reacts to obstacles; nothing
## reacts to the chain) that keeps this simulated rope from ever pushing a
## player or interfering with the dart's own already-working flight raycast.
const ROPE_OBSTACLE_LAYER_BIT: int = 1 << 1  # layer 2

## Preloaded once at class scope (not instantiated per-dart) -- every rope
## segment body shares this same script; see rope_segment_body.gd's own doc
## comment for the plane-lock/no-gravity/speed-clamp mechanism it implements.
const RopeSegmentBodyScript: Script = preload("res://scripts/rope_segment_body.gd")

## --- Continuous tube-mesh rendering for the rope (visual only -- traces the
## real physics chain's own control points with a plain Catmull-Rom curve,
## no obstacle awareness or correction of any kind, see above) ---
## Sample count along the curve -- deliberately higher than
## ROPE_PHYSICS_SEGMENTS itself, since this is purely a rendering smoothness
## knob with no physics cost (plain Vector3 math, not simulated).
const ROPE_TUBE_CURVE_SAMPLES: int = 48
## Radial cross-section resolution of the extruded tube -- 8-sided reads as
## round at this game's camera distance without excessive triangle count.
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
## only as a local in _setup_dagger_in_hand()) so _build_tube_mesh() can reuse
## the exact same look without duplicating the material setup.
var _rope_material: StandardMaterial3D = null
## The real physics-simulated rope chain (see the ROPE_PHYSICS_* consts'
## comment above) -- ONE PERSISTENT object per player, built once in
## _spawn_physics_rope() (called from _ready()) and only ever torn down in
## _exit_tree() (freeing raw PhysicsServer3D joint RIDs, which are not
## Node3D-owned and would otherwise leak across round/scene transitions --
## see _physics_rope_joint_rids' own comment). NOT rebuilt per-throw any
## more -- its "idle collapsed at the hand" / "thrown, unfolding" /
## "retrieving, folding" looks are all just this one chain's own live,
## continuously-simulated configuration, driven purely by where its tip
## anchor is currently being told to go (see _get_rope_tip_target()).
var _physics_rope_root: Node3D = null
var _physics_rope_hand_anchor: RigidBody3D = null
var _physics_rope_tip_anchor: RigidBody3D = null
## True once _spawn_physics_rope() has built the chain -- guards against a
## double-spawn; never goes back to false during a player's lifetime (the
## chain is not freed between throws or rounds any more, only in _exit_tree()).
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
	## The persistent physics rope chain (see _spawn_physics_rope()) is no
	## longer freed between throws or rounds -- it now only ever needs
	## cleanup once, when this player node itself is actually leaving the
	## tree for good (round-transition scene teardown, match end, etc.).
	## Raw PhysicsServer3D joint RIDs (see _physics_rope_joint_rids) are NOT
	## owned by any Node3D, so without this they would leak silently for the
	## rest of the process's lifetime every time a match's scene is torn down
	## -- _exit_tree() is called for every node as it's removed from the
	## SceneTree, which reliably covers that regardless of whether the whole
	## scene is freed at once or just this node is.
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
	## persistent physics rope chain (see _spawn_physics_rope(), called at the
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

	# Rope tube material -- shared by _build_tube_mesh() every frame the
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

	# Build the persistent physics rope chain now -- _dagger_in_hand (the real
	# hand attachment get_hand_world_position() reads) is set above, and this
	# node is already inside the tree by the time _ready() reaches this call,
	# so _spawn_physics_rope()'s get_parent().add_child() is valid. See
	# _spawn_physics_rope()'s own doc comment for why this now happens exactly
	# ONCE per player instead of per-throw.
	_spawn_physics_rope()


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
	## The physics chain is persistent (spawned once in _ready(), see
	## _spawn_physics_rope()) -- this just keeps the render in sync every
	## _process() frame. Defensive respawn if somehow not built yet (should
	## only ever happen for one frame at most, if player_mesh/skeleton setup
	## failed and _setup_dagger_in_hand() never called _spawn_physics_rope()).
	if not _physics_rope_active:
		_spawn_physics_rope()
	if is_dead:
		if _physics_rope_tube_mesh != null:
			_physics_rope_tube_mesh.visible = false
		return
	_update_rope_tube_mesh()


func _get_rope_tip_target() -> Vector3:
	## The single point both _spawn_physics_rope() (initial layout direction)
	## and _update_physics_rope_anchors() (every-tick tracking) treat as
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
	## bone but Y hard-clamped to _get_rope_plane_y() -- the kinematic hand
	## anchor is JOINTED to the first dynamic segment, whose Y is hard-locked
	## to plane_y every physics step (see rope_segment_body.gd) -- if the hand
	## anchor's own Y were left free to follow the real hand bone's bob
	## instead, the joint would fight a small constant Y mismatch every step.
	var hand_pos: Vector3 = get_hand_world_position()
	return Vector3(hand_pos.x, _get_rope_plane_y(), hand_pos.z)


func _spawn_physics_rope() -> void:
	## Builds the real RigidBody3D chain ONCE per player (called from
	## _setup_dagger_in_hand(), itself called once from _ready()) -- see this
	## file's ROPE_PHYSICS_* consts' doc comment for the full architecture.
	## A kinematic hand anchor, a kinematic tip anchor (tracked toward
	## _get_rope_tip_target() every physics tick -- see
	## _update_physics_rope_anchors(), called from _physics_process()),
	## ROPE_PHYSICS_SEGMENTS dynamic segments between them, and a raw
	## PhysicsServer3D pin joint (see _join_rope_pin()) between every
	## consecutive pair, each using EXPLICIT per-body local anchor points.
	## Godot's own solver is what keeps this off of pillars/trees/cacti --
	## nothing here computes a bend point or reads any obstacle's rect/shape
	## data directly.
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
	# mismatch every physics step. At spawn time (always right at _ready(),
	# before any throw), the tip coincides with the hand -- see
	# _get_rope_tip_target()'s own "idle collapse" comment -- so the chain's
	# very first configuration IS the collapsed-at-the-hand rest state.
	var hand_pos: Vector3 = _get_rope_hand_anchor_pos()
	var tip_pos: Vector3 = _get_rope_tip_target()

	# Initial layout direction: along the current hand->tip span if it's
	# meaningful, else along the player's current aim -- purely cosmetic (a
	# tiny fan-out for the very first render frame, see ROPE_BUNCH_SPACING).
	# Both endpoints already share the same Y (plane_y), so this direction is
	# naturally flat (zero Y component) whenever it's derived from the real
	# span -- the aim-direction fallback is explicitly constructed flat too.
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
	var denom: float = float(maxi(ROPE_PHYSICS_SEGMENTS - 1, 1))
	# ROPE_BUNCH_SPACING is the WHOLE bunch's total span, not a per-segment
	# gap -- spacing between consecutive segments is derived by dividing that
	# fixed total by (segment_count - 1), so the bunch's own footprint stays
	# small and CONSTANT regardless of segment count. (An earlier version of
	# this file used a per-segment gap instead, i.e. total span = N *
	# ROPE_BUNCH_SPACING -- at 8 segments that was a barely-noticeable 0.48
	# units, but scaled to 32 segments it laid the chain out across ~1.9
	# units in a dead-straight line: not "collapsed into the hand" as the
	# user's spec requires, and left the joint solver needing real seconds to
	# reel that whole layout back in even while idle, since nothing but the
	# solver's own soft correction was pulling it in. A SPIRAL layout was
	# tried and measured, via this round's own regression test,
	# tests/test_rope_physics_chain_settle.gd, to be WORSE, not better --
	# curling the segment CENTERS into a tight coil while every segment's
	# ORIENTATION stayed uniformly aligned along span_dir left each capsule's
	# real END POINTS (offset ±HALF_LENGTH along ITS OWN local Y, i.e. along
	# span_dir, not tangent to the spiral) badly misaligned with where the
	# joint chain actually needed them -- a large initial violation that
	# released outward like an over-wound spring, measured to grow the max
	# reach from ~1.2 (straight line at old spacing) to ~1.4. A straight line
	# with UNIFORM span_dir orientation is the joint-consistent configuration
	# for this body layout -- consecutive segment ends genuinely do line up
	# along that direction -- so the only real fix needed was making the
	# LINE's own total length small and segment-count-independent, not
	# changing its shape.
	var spacing: float = ROPE_BUNCH_SPACING / denom
	for i in range(ROPE_PHYSICS_SEGMENTS):
		var seg_center: Vector3 = hand_pos + span_dir * (float(i) * spacing)
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
	## use capsules for chain links) -- NO mesh/visual of its own (the rope's
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
	## (locked_y = plane_y) are the mechanism for the user's explicit
	## "disregard gravity and live on a plane" requirement -- see that
	## script's own doc comment for the full writeup.
	##
	## collision_mask = ROPE_OBSTACLE_LAYER_BIT ONLY (not the default layer):
	## reacts to real obstacle geometry, never to players/ground/the dart
	## head. collision_layer = 0: nothing else's mask can ever detect this
	## segment either -- strictly one-directional, so the chain can never
	## push a player or otherwise leak into gameplay logic.
	##
	## contact_monitor / max_contacts_reported: lets rope_segment_body.gd know,
	## per tick, whether THIS segment is actually touching real obstacle
	## geometry right now (state.get_contact_count() > 0) -- since this body's
	## collision_mask only ever matches ROPE_OBSTACLE_LAYER_BIT (never another
	## segment, a player, or the ground), any contact reported here is
	## unambiguously "resting against a real obstacle." Consumed by
	## player.gd's _clamp_to_rope_leash() (the wrap-aware leash pivot).
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
	body.contact_monitor = true
	body.max_contacts_reported = 4

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


## STILL UNFIXED as of ROUND 14 -- both of ROUND 13's own untried leads were
## run to completion this round (ROUND 13 itself was blocked mid-session by
## Godot MCP connection instability, not by running out of approaches). Left
## at PhysicsServer3D's own documented defaults (0.3 / 1.0) -- functionally a
## NO-OP vs. the previously-uncalled default, re-verified this round to still
## reproduce the exact same baseline joint-gap numbers (max_joint_gap=1.8345
## @ joint 28, tick 0, on a full-charge throw) as before this const/API call
## existed.
##
## ROUND 14 LEAD 1 (damping tuning, isolated from bias) -- RUN TO COMPLETION,
## CONCLUSIVELY FAILED, in the WORSE direction, not just "didn't help":
## damping=2.0 (bias left at default 0.3) measured max_joint_gap=6.6527 --
## 3.6x WORSE than the 1.0-baseline's 1.8345, not an improvement. damping=4.0
## went further and caused a full numerical explosion within the first few
## ticks (segment positions/reach going to NaN, matching the exact failure
## signature ROUND 1 already found for bias=0.9/damping=2.0). Both measured
## via the same per-tick _joint_gaps() probe, tests/test_rope_physics_chain_
## settle.gd. Damping tuning on the pin joint is not a viable lever at any
## value tried above the existing default -- do not retry without a
## fundamentally different starting point than "just raise damping further."
const ROPE_JOINT_BIAS: float = 0.3
const ROPE_JOINT_DAMPING: float = 1.0

## ROUND 14 LEAD 2 -- RUN TO COMPLETION, CONCLUSIVELY FAILED. Swaps
## _join_rope_pin() for _join_rope_6dof() (PhysicsServer3D.joint_make_
## generic_6dof(), near-zero linear limits on all 3 axes, angular left fully
## free to match a pin joint's own free rotation) -- kept in the codebase,
## DISABLED, as a permanent "already tried, don't retry blindly" record, per
## this project's own standing convention (see e.g. ROUND 1's rejected
## PIN_JOINT_IMPULSE_CLAMP/lower-bias notes). Do not flip this back to true
## without a genuinely new idea, not just a different tuning of the same
## three params already swept below.
##
## Real API confirmed against Godot 4.3's servers/physics_server_3d.h (not
## assumed -- the task's own suggested method name,
## joint_set_generic_6dof_axis_param, does not exist; the real methods are
## generic_6dof_joint_set_param()/generic_6dof_joint_set_flag()).
##
## THREE STIFFNESS LEVELS MEASURED, all via the same _joint_gaps() probe on
## the same full-charge-throw scenario the pin-joint baseline used:
##   1. Engine defaults (softness=0.7, damping=1.0, restitution=0.5, per
##      servers/physics_3d/joints/godot_generic_6dof_joint_3d.h's own struct
##      init) with only the linear limit range set to +-0.02: max_joint_gap
##      =9.6505 -- already ~5x WORSE than the pin joint's 1.8345 baseline,
##      before any deliberate stiffening.
##   2. Moderate (softness=1.0, restitution=1.0, damping=1.0, a mild bump off
##      default): max_joint_gap=8.9473 -- still ~5x worse than baseline, only
##      a marginal improvement over the engine defaults above.
##   3. Aggressive (softness=4.0, restitution=4.0, damping=2.0): catastrophic,
##      immediate explosion -- max_joint_gap=276121696.0 (276 MILLION units)
##      already by tick 0, growing to ~1.68e18 by the fold phase, with 8602
##      real "Object went too far away" engine errors logged. The dart never
##      even returned within the test's own 240-tick timeout.
##
## ROOT CAUSE for why this joint type underperforms a pin joint at ANY
## setting tried, confirmed by reading the engine's own C++ source (servers/
## physics_3d/joints/godot_generic_6dof_joint_3d.cpp), not assumed from the
## numbers alone: line 59 of that file is a hardcoded compile-time macro,
## `#define GENERIC_D6_DISABLE_WARMSTARTING 1` -- Godot's generic 6DOF joint
## has warm-starting (carrying the previous step's accumulated impulse
## forward as a head start for the next step's iterative solve, standard
## practice for fast constraint convergence) explicitly DISABLED in this
## engine version, unlike whatever internal path PIN_JOINT uses. This isn't
## adjustable from script/PhysicsServer3D at all -- it's baked into the
## engine binary this project runs against. Separately, its own linear-limit
## correction formula (solveLinearAxis(), line 202) uses `restitution` as the
## de-facto positional-error-correction term (`limitSoftness * (restitution *
## depth / timeStep - damping * rel_vel)`) since there is no dedicated linear
## ERP parameter exposed at all (only angular axes have
## G6DOF_JOINT_ANGULAR_ERP) -- a structurally different, and per the measured
## numbers above, less effective correction path than whatever the pin
## joint's own PIN_JOINT_BIAS/PIN_JOINT_DAMPING drive internally.
const ROPE_USE_6DOF_JOINT: bool = false
const ROPE_6DOF_LINEAR_SLACK: float = 0.02


func _join_rope_pin(a: RigidBody3D, local_a: Vector3, b: RigidBody3D, local_b: Vector3) -> void:
	## Creates one PinJoint3D-equivalent constraint via the low-level
	## PhysicsServer3D API directly, instead of a PinJoint3D node -- lets each
	## body's local anchor point be declared EXPLICITLY and INDEPENDENTLY
	## (`local_a`/`local_b`, in each body's own local space) rather than both
	## being implicitly derived from a single shared world position at setup
	## time (see this file's ROPE_PHYSICS_* consts' doc comment for the full
	## root-cause history on why that matters). No Node3D is created for this
	## at all -- the joint exists purely as a RID on the physics server, so
	## _free_physics_rope() must explicitly free it (see
	## _physics_rope_joint_rids' own comment).
	if ROPE_USE_6DOF_JOINT:
		_join_rope_6dof(a, local_a, b, local_b)
		return
	var joint_rid: RID = PhysicsServer3D.joint_create()
	PhysicsServer3D.joint_make_pin(joint_rid, a.get_rid(), local_a, b.get_rid(), local_b)
	PhysicsServer3D.pin_joint_set_param(joint_rid, PhysicsServer3D.PIN_JOINT_BIAS, ROPE_JOINT_BIAS)
	PhysicsServer3D.pin_joint_set_param(joint_rid, PhysicsServer3D.PIN_JOINT_DAMPING, ROPE_JOINT_DAMPING)
	_physics_rope_joint_rids.append(joint_rid)


func _join_rope_6dof(a: RigidBody3D, local_a: Vector3, b: RigidBody3D, local_b: Vector3) -> void:
	## ROUND 14 lead 2: same "each body's local anchor point declared
	## independently" principle as _join_rope_pin(), but via
	## PhysicsServer3D.joint_make_generic_6dof() (real API confirmed against
	## Godot 4.3's servers/physics_server_3d.h, not assumed) instead of
	## joint_make_pin() -- stays inside Godot's own iterative constraint
	## solver (collision-aware, unlike a from-scratch position correction),
	## but exposes a per-axis linear limit RANGE instead of a single
	## bias/damping pair. Each axis is given a tiny (not exactly zero) linear
	## limit range around 0 (ROPE_6DOF_LINEAR_SLACK) with
	## G6DOF_JOINT_FLAG_ENABLE_LINEAR_LIMIT on -- angular flags are left OFF
	## (their default), so rotation stays fully free at every joint, same as
	## a pin joint. local_frame_a/b use Basis.IDENTITY (aligned with each
	## body's OWN local axes, which is where local_a/local_b -- e.g.
	## Vector3(0, +-HALF_LEN, 0) -- already live) so the joint's axes track
	## each capsule's own orientation as it rotates, not a world-fixed frame.
	var joint_rid: RID = PhysicsServer3D.joint_create()
	var frame_a := Transform3D(Basis.IDENTITY, local_a)
	var frame_b := Transform3D(Basis.IDENTITY, local_b)
	PhysicsServer3D.joint_make_generic_6dof(joint_rid, a.get_rid(), frame_a, b.get_rid(), frame_b)
	for axis in [Vector3.AXIS_X, Vector3.AXIS_Y, Vector3.AXIS_Z]:
		PhysicsServer3D.generic_6dof_joint_set_flag(joint_rid, axis, PhysicsServer3D.G6DOF_JOINT_FLAG_ENABLE_LINEAR_LIMIT, true)
		PhysicsServer3D.generic_6dof_joint_set_param(joint_rid, axis, PhysicsServer3D.G6DOF_JOINT_LINEAR_LOWER_LIMIT, -ROPE_6DOF_LINEAR_SLACK)
		PhysicsServer3D.generic_6dof_joint_set_param(joint_rid, axis, PhysicsServer3D.G6DOF_JOINT_LINEAR_UPPER_LIMIT, ROPE_6DOF_LINEAR_SLACK)
		# TEMP-TESTING: engine source (servers/physics_3d/joints/godot_generic_6dof_joint_3d.cpp,
		# solveLinearAxis()) shows the position-correction term is
		# `limitSoftness * (restitution * depth / timeStep - damping * rel_vel)` --
		# i.e. `restitution` (NOT a dedicated ERP param -- none exists for the
		# linear axes, only angular has G6DOF_JOINT_ANGULAR_ERP) is what scales
		# how much of the positional error gets corrected per tick. Defaults
		# (softness 0.7 / damping 1.0 / restitution 0.5) measured far worse than
		# the pin joint baseline -- pushing all three well above default here to
		# test whether it can be made competitively stiff at all.
		PhysicsServer3D.generic_6dof_joint_set_param(joint_rid, axis, PhysicsServer3D.G6DOF_JOINT_LINEAR_LIMIT_SOFTNESS, 1.0)
		PhysicsServer3D.generic_6dof_joint_set_param(joint_rid, axis, PhysicsServer3D.G6DOF_JOINT_LINEAR_RESTITUTION, 1.0)
		PhysicsServer3D.generic_6dof_joint_set_param(joint_rid, axis, PhysicsServer3D.G6DOF_JOINT_LINEAR_DAMPING, 1.0)
	_physics_rope_joint_rids.append(joint_rid)


func _update_physics_rope_anchors() -> void:
	## Drives the two kinematic endpoints every physics tick -- called from
	## _physics_process() unconditionally. The hand end tracks
	## _get_rope_hand_anchor_pos(); the tip end tracks _get_rope_tip_target(),
	## whatever the dart's current state (FLYING/ANCHORED/RECALLING) or, while
	## idle, the hand itself -- so the chain is simulated continuously for the
	## player's entire lifetime, not just while a dart is out.
	##
	## No separate pacing/clamp mechanism drives how fast the chain unfolds or
	## folds any more (the old ROPE_UNSPOOL_SLACK growing-leash sphere clamp
	## and ROPE_TAUT_PERP_RADIUS taut-line tube clamp, both in
	## rope_segment_body.gd, were deleted this round -- see this file's
	## ROPE_PHYSICS_* consts' doc comment for why: they were exactly the kind
	## of "compute where the rope should be, then force it there" correction
	## the user's full architecture reset explicitly rejected). The chain's
	## unfold/fold rate is now purely emergent from real joint-constraint
	## propagation as the tip anchor moves; rope_segment_body.gd's
	## MAX_SEGMENT_SPEED clamp (a per-body XZ speed cap, a legitimate
	## physical-damping-style limit, not a position/path clamp) is the only
	## remaining stability mechanism beyond the Y-plane lock.
	if not _physics_rope_active:
		return
	var hand_pos: Vector3 = _get_rope_hand_anchor_pos()
	if _physics_rope_hand_anchor != null:
		_physics_rope_hand_anchor.global_position = hand_pos
	var tip_pos: Vector3 = _get_rope_tip_target()
	if _physics_rope_tip_anchor != null:
		_physics_rope_tip_anchor.global_position = tip_pos


func get_rope_polyline_2d() -> Array[Vector2]:
	## Ordered hand -> tip control points of the REAL, currently-simulated
	## physics rope chain -- the exact same points _update_rope_tube_mesh()
	## draws a curve through -- exposed for rope_dart.gd's own use during
	## RECALLING (see its _get_hand_rope_path_2d()), so a returning dart can
	## retrace the rope's real live shape (obstacle wrap included) instead of
	## cutting a straight line back to wherever the owner currently stands.
	## Deliberately does NOT include the tip/dart's own position -- rope_dart.gd
	## already knows its own head_2d with zero extra lag (this function's own
	## tip anchor, by contrast, tracks the dart one physics tick behind), so
	## callers that want the full hand -> ... -> dart path append their own
	## current position themselves.
	var points: Array[Vector2] = []
	var hand_pos: Vector3 = _get_rope_hand_anchor_pos()
	points.append(Vector2(hand_pos.x, hand_pos.z))
	for seg in _physics_rope_segments:
		var p3: Vector3 = (seg as RigidBody3D).global_position
		points.append(Vector2(p3.x, p3.z))
	return points


func _rope_chain_rest_length_2d(tip_2d: Vector2) -> float:
	## Used by _clamp_to_rope_leash(): the real chain's own already-committed
	## length from its FIRST dynamic segment (the link nearest the hand)
	## through every remaining segment to the tip/anchor -- i.e. how much of
	## the chain's fixed DART_ROPE_LENGTH capacity is already spent on
	## whatever's happening between the first segment and the dart (a corner
	## wrap, typically), leaving the rest as budget for the hand-to-first-
	## segment span specifically. Deliberately excludes the hand->seg[0] leg
	## (the caller supplies its own live hand position for that part).
	## Returns 0.0 if there's no chain yet.
	if _physics_rope_segments.is_empty():
		return 0.0
	var total: float = 0.0
	var prev_pos: Vector3 = (_physics_rope_segments[0] as RigidBody3D).global_position
	for i in range(1, _physics_rope_segments.size()):
		var p3: Vector3 = (_physics_rope_segments[i] as RigidBody3D).global_position
		total += Vector2(prev_pos.x, prev_pos.z).distance_to(Vector2(p3.x, p3.z))
		prev_pos = p3
	var prev_2d := Vector2(prev_pos.x, prev_pos.z)
	total += prev_2d.distance_to(tip_2d)
	return total


func _free_physics_rope() -> void:
	## Only ever called from _exit_tree() now -- the chain is persistent for
	## the whole lifetime of a player node (see this file's ROPE_PHYSICS_*
	## consts' doc comment), not freed between throws or rounds. Raw
	## PhysicsServer3D joints are independent RIDs, not owned by any node --
	## queue_free()'ing the root below does NOT free these; must be done
	## explicitly first or they leak for the lifetime of the process.
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
	## Rebuilds one continuous ArrayMesh every _process() frame, tracing a
	## smooth Catmull-Rom curve through the REAL physics chain's own control
	## points [hand anchor, every dynamic segment's center, tip anchor] (in
	## that order -- matches the actual joint chain order from
	## _spawn_physics_rope()) and extruding a round tube of ROPE_RADIUS along
	## it (see _build_tube_mesh()). The underlying RigidBody3D segments and
	## their capsule collision shapes are completely unchanged by this -- they
	## still exist, still collide with real obstacle geometry, and still
	## drive this curve's shape; only what gets DRAWN from their positions
	## changed, from N disjoint capsule meshes to one smooth surface. NO
	## obstacle-awareness or correction happens in this function or in
	## _compute_rope_tube_curve_points() below -- see this file's
	## ROPE_PHYSICS_* consts' doc comment for why that was deleted wholesale
	## this round.
	if _physics_rope_root == null or _physics_rope_hand_anchor == null or _physics_rope_tip_anchor == null:
		return
	if _physics_rope_segments.size() != ROPE_PHYSICS_SEGMENTS:
		return

	if _physics_rope_tube_mesh == null:
		var mi := MeshInstance3D.new()
		mi.name = "RopeTubeMesh"
		# top_level = true: every control point below comes from
		# .global_position reads (already WORLD space) -- a non-top_level
		# MeshInstance3D would render that already-global vertex data through
		# its own parent-derived global_transform too, double-transforming it
		# (see git history for the original root-caused bug this fixed: a
		# rope-shaped mesh floating disconnected from the character, reshaping
		# every frame in lockstep with the player's own rotation). top_level
		# = true makes this node's global_transform NOT inherit from its
		# parent at all, so the already-global vertices render correctly with
		# no further transform needed.
		mi.top_level = true
		# Material is applied AFTER _build_tube_mesh() gives this mesh its
		# first real surface (below) -- set_surface_override_material(0, ...)
		# errors ("Index p_surface = 0 is out of bounds") on a MeshInstance3D
		# whose mesh has zero surfaces yet.
		add_child(mi)
		_physics_rope_tube_mesh = mi

	var control_points: Array[Vector3] = [_physics_rope_hand_anchor.global_position]
	for seg in _physics_rope_segments:
		control_points.append((seg as RigidBody3D).global_position)
	control_points.append(_physics_rope_tip_anchor.global_position)

	var curve_points: Array[Vector3] = _compute_rope_tube_curve_points(control_points)
	_build_tube_mesh(_physics_rope_tube_mesh, curve_points, ROPE_RADIUS, ROPE_TUBE_RADIAL_SEGMENTS)
	_physics_rope_tube_mesh.visible = true


func _compute_rope_tube_curve_points(control_points: Array[Vector3]) -> Array[Vector3]:
	## Pure Catmull-Rom sampling through the REAL physics chain's own control
	## points, at ROPE_TUBE_CURVE_SAMPLES steps -- Vector3.cubic_interpolate(b,
	## pre_a, post_b, weight) needs a "before the start" and "after the end"
	## handle for every interpolated span; clamping the index at both ends
	## (rather than requiring 4 real neighbors) is what lets this work even at
	## the very first/last span, and lets the whole curve work correctly with
	## as few as 2 control points (a degenerate straight line -- possible
	## right at throw-instant, when the tip anchor and every not-yet-separated
	## segment can start nearly coincident).
	##
	## NO OBSTACLE AWARENESS, NO CORRECTION, NO FALLBACK PATH COMPUTATION OF
	## ANY KIND -- this is the whole point of this round's full architecture
	## reset (see this file's ROPE_PHYSICS_* consts' doc comment, and
	## CLAUDE.md's dated entry for the full writeup of what used to live here:
	## a visibility-graph + Dijkstra shortest path, and before that a series
	## of case-by-case corner-selection heuristics, all now deleted). If this
	## curve ever visibly clips a pillar, that means the REAL RigidBody3D
	## segments it's sampled through are themselves inside the pillar's
	## collision geometry -- a genuine physics/collision bug to fix at the
	## segment/joint/collision level (see rope_segment_body.gd), not
	## something to detect-and-reroute here.
	var n: int = control_points.size()
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
	return curve_points


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


func _rope_leash_pivot_and_radius() -> Array:
	## Returns [pivot: Vector2, radius: float] describing the current tether
	## boundary circle, or [] if no leash constraint applies this tick (no
	## dart, or not ANCHORED). Pure read -- computes but never applies
	## anything; see _apply_rope_leash_velocity_clamp() for the caller that
	## actually acts on this.
	##
	## Two possible bounds, same as this codebase's prior (now superseded --
	## see that function's own doc comment) position-clamp design:
	## 1. WRAP-AWARE: while at least one segment is genuinely resting against
	##    real obstacle contact (rope_segment_body.gd's own
	##    `_debug_last_has_contact`, an unambiguous "the solver actually put
	##    this segment here" signal -- see ROUND 5's clipping fix), pivot on
	##    the chain's own first dynamic segment (always topologically nearest
	##    the hand) with the radius shrunk by _rope_chain_rest_length_2d() --
	##    the REAL, already-simulated remaining chain length from that
	##    segment to the tip, wrap included. This reads real physics state,
	##    not a computed corner/route: a segment resting against real contact
	##    is exactly where the solver put it.
	## 2. FALLBACK: a plain circle of radius DART_ROPE_LENGTH around the
	##    anchor itself -- covers the tick(s) before the physics chain
	##    exists/settles, and by the triangle inequality is always at least
	##    as permissive as bound 1, so returning bound 1 alone (when it
	##    applies) is always the stricter, correct choice -- no need to
	##    intersect both.
	if dart == null or dart.state != DART_STATE_ANCHORED:
		return []
	var anchor: Vector2 = dart.head_2d

	if _physics_rope_active and not _physics_rope_segments.is_empty():
		var any_obstacle_contact: bool = false
		for seg in _physics_rope_segments:
			if bool((seg as RigidBody3D).get("_debug_last_has_contact")):
				any_obstacle_contact = true
				break
		if any_obstacle_contact:
			var first_seg_pos: Vector3 = (_physics_rope_segments[0] as RigidBody3D).global_position
			var first_2d := Vector2(first_seg_pos.x, first_seg_pos.z)
			var rest_len: float = _rope_chain_rest_length_2d(anchor)
			if rest_len < DART_ROPE_LENGTH:
				return [first_2d, DART_ROPE_LENGTH - rest_len]

	return [anchor, DART_ROPE_LENGTH]


func _apply_rope_leash_velocity_clamp(delta: float) -> void:
	## TELEPORT-FREE LEASH REDESIGN (2026-07-28, direct, explicit user
	## requirement: "The max length of the rope shouldn't be computed between
	## the dart and the character" -- confirmed via clarifying question to
	## mean this function's PREDECESSOR, the old _clamp_to_rope_leash(), which
	## every round from ROUND 6 onward (see git history/CLAUDE.md) had
	## computed a pivot+radius exactly as _rope_leash_pivot_and_radius() above
	## still does, then SNAPPED global_position onto that circle's boundary
	## whenever the player's real position was found to be outside it --
	## instant, discontinuous, once per violating tick). The user's own
	## standing, repeated preference across this whole rope saga (going back
	## to the very first "I want it to be a physics object" round) is no
	## computed-formula-then-force-it correction of anything the real
	## simulation is supposed to be authoritative over -- and unlike the
	## rope's OWN rendering/shape (already fully real-physics-driven since the
	## ROUND 12 architecture reset), the player's canonical position was still
	## being teleported by a plain distance formula every time it happened to
	## be found on the wrong side of a computed boundary.
	##
	## HYPOTHESIS TESTED FIRST, DIRECTLY, BEFORE CHANGING ANYTHING (per this
	## round's own explicit verification protocol): does the old position-snap
	## itself explain the still-unsolved ROUND 17/18 anchored steady-state
	## jitter (rope visibly reshaping while the player stands still near a
	## pillar)? A new instrumented run of
	## tests/test_rope_physics_chain_settle.gd's own steady-state jitter probe
	## (see that file's own "LEASH-CLAMP-FIRING" instrumentation, added this
	## round) -- with GameManager.current_state ALSO corrected to PLAYING for
	## the first time in that test file's history (previously LOBBY the whole
	## run, which meant the old clamp's own call site in _physics_process()
	## was UNREACHABLE the entire time ROUND 17/18 were measuring "steady-
	## state jitter," a genuine methodology gap this round found and fixed) --
	## measured `player_pos_fire_events = 0/360` in EVERY one of the 5 real
	## configs, including `corner_wrap_anchor` (100% real obstacle contact the
	## whole window) and `open_air_taut` (zero-slack, right at the boundary),
	## even while those same two configs' own segment jitter stayed at their
	## already-known-and-still-unexplained ~0.06-0.075 units/tick. **The old
	## clamp never fired even once during this specific stationary-near-a-
	## pillar reproduction** -- a stationary player who starts within their
	## own tether radius stays there forever with zero input, so there was
	## nothing for a position-snap to correct in that scenario. HYPOTHESIS
	## REFUTED for the passive-standing-still bug report specifically -- the
	## still-open ROUND 17/18 jitter has some other, still-unknown cause. (A
	## DIFFERENT, still-real scenario where the old clamp WAS proven to fire
	## repeatedly: tests/test_rope_leash_corner_wrap.gd's own adversarial
	## sweep, where a player actively pushes outward against the tether every
	## tick -- that test's own historical fold-jump numbers are exactly what a
	## repeatedly-firing position snap looks like. This redesign still fixes
	## that mechanism even though it wasn't the passive-jitter bug's own
	## cause -- see the re-measurement in this round's own final report.)
	##
	## THE REDESIGN: instead of correcting POSITION after move_and_slide(),
	## this projects VELOCITY before it -- called from _physics_process()
	## right before move_and_slide(), never after. Decomposes the player's
	## already-computed velocity into a radial component (along the line from
	## the tether pivot to the player's CURRENT, real position) and a
	## tangential component; only the OUTWARD radial component is ever
	## reduced, and only down to the exact amount of remaining budget this
	## tick (`(radius - cur_dist) / delta`), never below zero and never touching
	## the tangential component at all -- so pushing straight out against a
	## taut tether smoothly decelerates to a dead stop exactly at the
	## boundary (never overshoots, never needs correcting after the fact,
	## because it was never allowed to move past the boundary to begin with),
	## while pushing at an angle keeps sliding freely along the boundary, the
	## same "run at an angle along the tether's edge" feel the old function's
	## own doc comment described -- just achieved by never letting the
	## over-limit motion happen, instead of happening then being undone.
	## Inward motion (radial_component <= 0) is never touched at all.
	##
	## Known, disclosed limitation: this clamps velocity based on the
	## PREDICTED tick, but move_and_slide() can itself still reduce the
	## actual travel distance below that prediction (sliding against an
	## obstacle collision elsewhere) -- in principle a tick could therefore
	## still end up compounding with the next tick's own fresh radial budget
	## in a way that's not bit-for-bit identical to a perfect continuous
	## constraint. This is the same class of small, bounded, per-tick
	## tolerance this codebase already accepts elsewhere (e.g. the corner-wrap
	## fix's own MAX_ACCEPTABLE_OVERSHOOT), not a new category of risk, and
	## unlike the old design it can never manifest as a discontinuous jump --
	## only, at most, a few extra ticks to fully settle at the boundary.
	var bound: Array = _rope_leash_pivot_and_radius()
	if bound.is_empty():
		return
	var pivot: Vector2 = bound[0]
	var radius: float = bound[1]
	var pos: Vector2 = get_pos_2d()
	var cur_offset: Vector2 = pos - pivot
	var cur_dist: float = cur_offset.length()
	if cur_dist < 0.0001 or delta <= 0.0:
		return  # degenerate (at the pivot, or a zero/negative delta) -- nothing to project
	var radial_dir: Vector2 = cur_offset / cur_dist
	var vel_2d: Vector2 = Vector2(velocity.x, velocity.z)
	var radial_component: float = vel_2d.dot(radial_dir)
	if radial_component <= 0.0:
		return  # moving inward or purely tangential -- never restricted
	var max_radial_component: float = maxf((radius - cur_dist) / delta, 0.0)
	if radial_component > max_radial_component:
		vel_2d -= radial_dir * (radial_component - max_radial_component)
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
