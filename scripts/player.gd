extends CharacterBody3D
## Player controller — 2D logic on XZ plane, 3D rendering.
## Supports keyboard (player_index=0), gamepads (player_index>=1), and AI bots.
##
## Post-GDD-rewrite rebuild status (see docs/implementation-plan.md): the
## weapon/combat system was intentionally stripped to bare movement ahead of
## the GDD rewrite, then rebuilt phase by phase. Phase 1 re-added the
## persistent rope_dart.gd instance (HOLSTERED/CHARGING/FLYING/EMBEDDED) and
## its leash velocity clamp (_apply_rope_leash_velocity_clamp). Phase 2 adds
## RETURNING and combat: is_dead + take_dart_hit() (dart contact, lethal in
## every away-state except EMBEDDED — a stationary anchored dart is not
## lethal to touch, see rope_dart.gd's _check_player_hits() `dart_lethal`
## param, Task #16) and _trip_timer + apply_rope_trip() (rope-line contact,
## movement debuff only, never lethal, unaffected by the EMBEDDED exception)
## — both called from rope_dart.gd's own _check_player_hits(), not from here.
## No lives/round-outcome tracking exists yet (Phase 5) — a "kill" is just an
## instant teleport to spawn_pos, same minimal shape the ring-out fall
## already used (_start_fall/_on_fall_finished) before this rebuild, just
## without the fall animation.
##
## Phase 4 (this pass) adds SWINGING: _handle_dart_away_input() below is the
## single place that disambiguates the unified Throw/Recall button's meaning
## while the dart is away (see _get_action_held()'s own comment for why one
## physical signal covers all of this) — a quick tap always means Recall; a
## hold-then-release while EMBEDDED means redirect (rope_dart.gd's
## begin_swing_redirect(), into SWINGING), tracked via its own
## _embedded_hold_time/_embedded_hold_active (deliberately separate from
## rope_dart.gd's own CHARGING-only _charge_time, since EMBEDDED isn't
## CHARGING and this disambiguation is an input-layer decision made here,
## before either begin_recall() or begin_swing_redirect() is ever called).
##
## KNOWN GAP: bot_controller.gd was intentionally left mostly untouched
## through Phase 2 (per explicit direction — full bot rework is Phase 6) and
## still has some rough/dead logic (e.g. its "darts" group dodge loop is a
## silent no-op since rope_dart.gd is deliberately not added to that group —
## see rope_dart.gd's own header comment). It was patched just enough this
## phase to not crash against the new dart/is_dead shape. Bots still only
## ever tap-recall (their own get_desired_recall() is a one-shot pulse, never
## a sustained hold — see bot_controller.gd's own comment on that contract),
## so they never trigger a redirect; per docs/implementation-plan.md's Phase
## 6 section, bot-initiated redirects are an explicit later judgment call,
## not part of this pass.

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

## Slash/Kick (Phase 3 -- see this file's header comment and _handle_melee_input()
## below). Same button, context-sensitive on dart.state: Slash (dart in hand)
## always kills on contact just like the thrown dart; Kick (dart away) only
## knocks back. MELEE_RANGE is duck-typed-mirrored in bot_controller.gd (that
## file has no static access to this script's consts across the duck-typed
## `player` reference used elsewhere there -- same hand-mirroring convention
## already used for DART_STATE_* in that file) -- keep both in sync if this
## ever gets tuned.
const MELEE_RANGE: float = 1.4
## Rising-edge-gated, not held-to-repeat: one press = one Slash/Kick attempt,
## then a brief cooldown before the next press can trigger another -- without
## this a held button (or a bot's continuously-true in-range decision) would
## melee every single physics tick.
const MELEE_COOLDOWN: float = 0.4
const KICK_KNOCKBACK_SPEED: float = 14.0
const KICK_KNOCKBACK_DURATION: float = 0.25

## Task #15: Slash/Kick VFX -- the attacker previously had ZERO visual cue on
## a Slash/Kick beyond the target's own reaction (an instant respawn-teleport
## for a kill, a knockback slide for a kick), which read as "nothing is
## happening" even though the range check/hit logic fired correctly. Slash
## reuses "Throw" (Rig_Medium_General.glb) -- the KayKit clip libraries have
## no dedicated slash/kick/punch clip (confirmed in-engine: General.glb's
## combat-relevant set is Use_Item/Throw/Hit_A/Hit_B/Death_A/Death_B/PickUp/
## Interact/Spawn_*, MovementBasic.glb is locomotion+jump only -- Hit_A/B are
## REACTION clips, meant for the player getting hit, not the one attacking)
## -- "Throw" is the closest match: an aggressive one-armed overhand swing,
## which reads fine as "swinging the dart at someone" even though its literal
## authored intent was a throwing motion. Kick has no comparable clip at all,
## so it's a lightweight procedural lunge+flash instead (see
## _play_lunge_tween/_flash_materials below) -- this project's established
## house style already leans on Tween-driven VFX over needing new art assets
## (see _start_fall's sink/spin/shrink tween for the ring-out fall).
const SLASH_ANIM_NAME: String = "Throw"
## Raw "Throw" clip is 1.37s -- much too slow a windup for a melee hit that
## resolves instantly and is gated by a 0.4s MELEE_COOLDOWN; played back
## sped-up (see _trigger_slash_vfx's dynamic speed calc against the clip's
## OWN queried length, not a hardcoded ratio, so this stays correct if the
## source clip is ever swapped) to fit this duration instead.
const SLASH_ANIM_DURATION: float = 0.35
## Kick has no skeletal clip of its own -- locomotion is held on "Idle_A"
## (force-replayed, see _play_anim's `force` param) for this same window
## while the procedural lunge (_play_lunge_tween) plays out, so the lunge
## isn't fighting a walk-cycle's own leg motion underneath it.
const KICK_ANIM_DURATION: float = 0.25
const KICK_LUNGE_DISTANCE: float = 0.35
const KICK_LUNGE_OUT_TIME: float = 0.08
const KICK_LUNGE_BACK_TIME: float = 0.17
## Nice-to-have (Task #15): distinct flash colors so a player watching from a
## distance gets some read on which one just happened even without seeing the
## swing/lunge itself clearly -- red-hot for the lethal Slash, a duller
## orange for the non-lethal Kick.
const SLASH_FLASH_COLOR: Color = Color(1.0, 0.15, 0.1)
const KICK_FLASH_COLOR: Color = Color(1.0, 0.6, 0.05)
const MELEE_FLASH_DURATION: float = 0.15


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
# header comment): HOLSTERED/CHARGING/FLYING/EMBEDDED/SWINGING are all states
# of this SAME node, never null, so "is the dart out" is read from
# dart.state, not from dart being present. Mirrors rope_dart.gd's State enum
# ordinals by hand (no shared constant between the two scripts -- same
# convention this project used before the weapon-system removal).
const DART_STATE_HOLSTERED := 0
const DART_STATE_CHARGING := 1
const DART_STATE_FLYING := 2
const DART_STATE_EMBEDDED := 3
const DART_STATE_SWINGING := 4
const DART_STATE_RETURNING := 5
var dart: Node = null
var _prev_throw_held: bool = false
var _prev_recall_held: bool = false

## Phase 4: hold-duration tracking for the EMBEDDED-state Recall-vs-Redirect
## gesture (see _handle_dart_away_input() below) -- starts counting on the
## rising edge of the shared Throw/Recall signal while dart.state ==
## EMBEDDED, and is read back on the falling edge (release) to decide which
## of begin_recall()/begin_swing_redirect() to call. Deliberately separate
## from rope_dart.gd's own _charge_time (that field only ever advances while
## dart.state == CHARGING, i.e. dart-in-hand; this tracks a hold that happens
## entirely while EMBEDDED, a different state with no charge concept of its
## own) -- this disambiguation is an input-layer decision made here, before
## rope_dart.gd's own methods are ever called, not something rope_dart.gd
## needs to know how to do itself.
var _embedded_hold_time: float = 0.0
var _embedded_hold_active: bool = false

## How long the shared button must be held (while EMBEDDED) before a release
## counts as "redirect" rather than "tap-recall". Deliberately much shorter
## than rope_dart.gd's own max_charge_time (CHARGING's full charge-up
## duration, the tuning precedent named in this task's own design doc) --
## per docs/project.md's Throw/Recall/Redirect section, a redirect-hold is a
## snap mid-fight decision, not a full charge-up, so even a small nonzero
## hold should already read as "holding to redirect" rather than "tapped".
const SWING_REDIRECT_HOLD_THRESHOLD: float = 0.1

## Task #18/#20: charge-scaled max DISTANCE FROM THE OWNER for a redirect leg
## (docs/project.md's Swinging section -- "the hold is a charge ... the
## longer the hold, the further the dart travels once released"). Mirroring
## the ORIGINAL throw's own charge (release_throw()'s charge_ratio, which
## scales SPEED) does NOT work here: the redirect leg reuses rope_dart.gd's
## _process_flying(), the same range-capped travel logic FLYING already uses
## -- a faster dart launched into that same range-bounded endpoint just
## reaches it sooner, not further (measured/confirmed during Task #18, see
## rope_dart.gd's begin_swing_redirect() header comment). So instead of
## scaling speed, this scales the dart's own range-cap-from-owner budget
## directly, passed into begin_swing_redirect() and enforced by
## rope_dart.gd's own _process_flying() as this leg's own range_cap (the
## SMALLER of rope_length and this value), reusing the exact same
## owner-relative "flying_clamp" wrap-aware constraint FLYING itself always
## uses -- see that function's own comment.
##
## Task #20 correction: this used to be measured from the dart's OWN launch
## position (Task #18's original design) rather than the owner -- flagged by
## direct user report as inconsistent with every OTHER distance constraint in
## this system (FLYING's clamp, the EMBEDDED leash, rope_length itself), all
## of which are owner-relative. Fixed by having rope_dart.gd apply this value
## as an owner-relative range cap instead of a separate launch-point-relative
## one -- see rope_dart.gd's _swing_effective_range and _process_flying()'s
## range_cap for the receiving side of this change.
##
## _compute_redirect_travel_distance() lerps SWING_REDIRECT_MIN_DISTANCE (a
## quick hold right at SWING_REDIRECT_HOLD_THRESHOLD -- "hold" as opposed to
## "tap" -- caps this leg to only this far from the owner) up to the dart's
## own full rope_length (a max-charge hold) as _embedded_hold_time approaches
## SWING_REDIRECT_MAX_CHARGE_TIME. rope_length is deliberately used as the
## ceiling rather than some smaller number: _process_flying()'s existing
## owner-relative rope_length clamp is enforced unconditionally regardless of
## what's passed here, so a max-charge redirect never travels further than
## that budget already would have allowed anyway -- this cap only ever
## actually BITES (i.e. is smaller than plain rope_length) for a
## short-to-medium hold, exactly the intended "quick hold = short reach,
## longer hold = full reach" curve.
const SWING_REDIRECT_MIN_DISTANCE: float = 2.0
## Deliberately shorter than CHARGING's own max_charge_time (0.7s, in
## rope_dart.gd) -- same "a redirect-hold is a snap mid-fight decision, not a
## full charge-up" reasoning SWING_REDIRECT_HOLD_THRESHOLD's own comment
## already gives for the (much smaller) tap/hold disambiguation threshold.
const SWING_REDIRECT_MAX_CHARGE_TIME: float = 0.6

## Task #20: a hold that's technically past SWING_REDIRECT_HOLD_THRESHOLD
## (so NOT a tap -- Recall doesn't apply) but still short enough that it
## doesn't read as a deliberate charge for a real redirect. Set to roughly
## 1.8x the tap/hold threshold -- enough headroom above it that this can't be
## crossed by input-polling jitter around the tap/hold boundary itself, while
## still being a small fraction of SWING_REDIRECT_MAX_CHARGE_TIME (0.6s), so
## it only catches genuinely brief holds, not ordinary short-to-medium ones.
## See _redirect_is_pointless_micro_hop().
const SWING_REDIRECT_PICKUP_HOLD_TIME: float = 0.18

## Task #20: minimum forward progress -- how far this leg's predicted
## landing point (see _redirect_is_pointless_micro_hop(), Task #21) sits from
## the dart's CURRENT position -- required to bother actually swinging.
## Below this, _process_flying()'s owner-relative range_cap would force an
## almost-immediate re-embed within a step or two of the dart's existing
## anchor: a "redirect" that's visually indistinguishable from not having
## moved. Chosen relative to rope_dart.gd's own dart_hit_radius (0.55) --
## anything smaller than roughly 1.5x that radius of actual new travel isn't
## a meaningfully different anchor point. See _redirect_is_pointless_micro_hop().
##
## Task #21 correction: this constant itself didn't change, only what it's
## compared against -- see that function's own header comment for the fixed
## quantity (a real predicted travel DISTANCE, not the flawed owner-relative
## subtraction Task #20 originally used).
const SWING_REDIRECT_MIN_TRAVEL: float = 0.75

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

# Slash/Kick (Phase 3 -- see MELEE_RANGE's own comment above and
# _handle_melee_input() below). _knockback_timer/_knockback_dir mirror the
# same "scripted state overrides normal movement input for a short window"
# shape _is_dashing/_dash_dir already use, just driven externally by whoever
# kicked this player (apply_kick_knockback()) instead of this player's own
# input.
var _prev_melee_held: bool = false
var _melee_cooldown_timer: float = 0.0
var _knockback_timer: float = 0.0
var _knockback_dir: Vector2 = Vector2.ZERO

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

## Task #19: cached hand-bone lookup, populated once in _setup_animation()
## (which already finds this character's Skeleton3D) -- see
## get_hand_world_position() below. "handslot.r"/"hand.r" is this rig's real
## throwing/swinging arm, confirmed by direct in-engine measurement (a temp
## probe played the "Throw" clip and compared per-frame bone displacement
## against idle: hand.r moved up to 0.806 units from rest vs. hand.l's 0.335,
## a clear, un-ambiguous right-arm swing), not assumed from the "right-handed"
## convention alone.
var _hand_skeleton: Skeleton3D = null
var _hand_bone_idx: int = -1

# Slash/Kick VFX (Task #15 -- see SLASH_ANIM_NAME's own comment above).
# _combat_anim_active/_combat_anim_timer briefly override _process()'s normal
# Idle/Walking/Running locomotion selection, the same "scripted state wins
# over normal per-frame logic for a short window" shape _knockback_timer/
# _is_dashing already use for movement -- just applied to animation selection
# instead of velocity. _lunge_tween is Kick's own procedural forward-and-back
# punch (tracked so a rapid-fire re-kick kills any still-running tween rather
# than fighting it for control of player_mesh.position).
var _combat_anim_active: bool = false
var _combat_anim_timer: float = 0.0
var _lunge_tween: Tween = null

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
	# Task #19: cache the hand-bone lookup for get_hand_world_position() below
	# -- prefer "handslot.r" (a dedicated, zero-length weapon-mount bone this
	# rig already provides as a child of hand.r), falling back to "hand.r"
	# itself if the slot bone is ever absent for any reason.
	_hand_skeleton = skeleton
	_hand_bone_idx = skeleton.find_bone("handslot.r")
	if _hand_bone_idx < 0:
		_hand_bone_idx = skeleton.find_bone("hand.r")
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


func _play_anim(anim_name: String, speed: float = 1.0, force: bool = false) -> void:
	## `force` (Task #15): normally a no-op if this clip is already the
	## current one (avoids restarting Idle/Walking every single frame), but a
	## Slash re-triggered while "Throw" is still the current anim from a
	## PREVIOUS Slash (e.g. two quick slashes back to back, once cooldown
	## allows) needs to actually restart the clip from frame 0, not silently
	## no-op because the name didn't change.
	if _anim_player == null:
		return
	if not force and _current_anim == anim_name:
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
	# Task #15: a Slash/Kick briefly wins over locomotion selection here (see
	# _combat_anim_active's own comment) -- _trigger_slash_vfx()/
	# _trigger_kick_vfx() already started the actual clip (force=true), this
	# just needs to NOT immediately stomp it back to Idle/Walking/Running the
	# very next frame, and to count down until it's safe to resume normal
	# selection.
	if _combat_anim_active:
		_combat_anim_timer -= delta
		if _combat_anim_timer <= 0.0:
			_combat_anim_active = false
	elif _is_dashing:
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

	# --- Slash/Kick cooldown / knockback countdowns ---
	if _melee_cooldown_timer > 0.0:
		_melee_cooldown_timer -= delta
	if _knockback_timer > 0.0:
		_knockback_timer -= delta

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
	# Task #17/#18: Dash is itself a movement burst, so while movement is
	# otherwise locked (CHARGING -- dart in hand -- or, as of Task #18, HOLDING
	# TO REDIRECT -- EMBEDDED with the shared button currently held, the
	# hold-to-charge window before a redirect release -- see docs/project.md's
	# "movement is restricted during committed dart actions") a NEW dash may
	# not be triggered either -- letting a lock-committed player dash-cancel
	# the lock would defeat the whole point of committing to the charge/hold.
	# An ALREADY-in-flight dash (started before the lock began) is
	# deliberately left alone: the velocity branch below still gives it full
	# DASH_SPEED regardless of dart.state, so it finishes naturally rather
	# than being awkwardly cancelled mid-burst. _prev_dash is still updated
	# every frame (even while blocked) so a press-and-hold that started during
	# a lock doesn't "queue" a surprise dash the instant the lock ends via a
	# stale edge.
	#
	# _movement_locked_now covers both lock windows with one shared boolean
	# (see its own comment below, at the point it's actually consumed by the
	# velocity block) -- computed here, ahead of that block, purely because
	# dash activation also needs to read it and happens first in frame order.
	var _charging_now: bool = dart != null and is_instance_valid(dart) and dart.state == DART_STATE_CHARGING
	# Task #18: reads _embedded_hold_active, which player.gd's own
	# _handle_dart_away_input() (called later THIS SAME physics tick, near the
	# bottom of this function) sets/clears -- so this frame's read is actually
	# last frame's value, one tick stale. This exactly mirrors _charging_now's
	# own pre-existing timing above (dart.begin_charge() is likewise called
	# later in _handle_throw_input(), so the very first frame CHARGING/holding
	# begins also reads stale HOLSTERED/inactive here) -- same established
	# one-frame-lag precedent, not a new inconsistency introduced by this task.
	var _redirect_holding_now: bool = dart != null and is_instance_valid(dart) and dart.state == DART_STATE_EMBEDDED and _embedded_hold_active
	var _movement_locked_now: bool = _charging_now or _redirect_holding_now
	if not _is_dashing and _dash_cooldown_timer <= 0.0:
		var dash_held: bool = _get_dash_pressed()
		if dash_held and not _prev_dash and not _movement_locked_now:
			var dash_dir: Vector2 = move_input if move_input.length() > 0.1 else _facing_dir
			_is_dashing = true
			_dash_timer = DASH_DURATION
			_dash_cooldown_timer = DASH_COOLDOWN
			_dash_dir = dash_dir.normalized()
		_prev_dash = dash_held

	# --- Velocity ---
	if _is_dashing:
		velocity = Vector3(_dash_dir.x, 0.0, _dash_dir.y) * DASH_SPEED
	elif _knockback_timer > 0.0:
		# Kick knockback: same "scripted state overrides normal input" shape
		# as dash above, just driven by apply_kick_knockback() instead of this
		# player's own input -- see that function's own comment.
		velocity = Vector3(_knockback_dir.x, 0.0, _knockback_dir.y) * KICK_KNOCKBACK_SPEED
	else:
		if move_input.length() > 1.0:
			move_input = move_input.normalized()
		# Task #17 (CHARGING) / Task #18 (holding to redirect, EMBEDDED +
		# _embedded_hold_active): both are a FULL translation lock -- turning
		# via aim_dir is NOT locked in either case (that update a few lines
		# below reads aim_input/move_input directly, untouched by this). Only
		# move_input's CONTRIBUTION TO VELOCITY is zeroed here; move_input
		# itself stays intact so the aim_dir fallback below still works off
		# it. See _movement_locked_now's own comment above (dash activation
		# block) for why this is one shared boolean rather than two duplicated
		# checks.
		var effective_move_input: Vector2 = Vector2.ZERO if _movement_locked_now else move_input
		# Rope-trip debuff: a brief movement slow, never lethal (see
		# apply_rope_trip()) -- does not affect dash, which stays at full
		# DASH_SPEED above so a tripped player can still burst free.
		var trip_mult: float = TRIP_SPEED_MULT if _trip_timer > 0.0 else 1.0
		velocity = Vector3(effective_move_input.x, 0.0, effective_move_input.y) * move_speed * trip_mult
	_apply_rope_leash_velocity_clamp()
	_apply_swing_forward_lock()
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
	# --- Rope dart Recall/Redirect: same shared button, dart.state == EMBEDDED
	# disambiguates tap (Recall, pulls the dart back at increasing speed --
	# rope_dart.gd's begin_recall()/_process_returning()) vs hold-then-release
	# (Redirect -- rope_dart.gd's begin_swing_redirect(), into SWINGING).
	# FLYING/SWINGING stay tap-only immediate Recall (no anchor to redirect
	# from) ---
	_handle_dart_away_input(delta)
	# --- Slash/Kick: same button, context-sensitive on dart.state (see
	# _handle_melee_input() below) ---
	_handle_melee_input()


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
	## Throw and Recall/Redirect are one button, gated by dart.state (see
	## _get_action_held()'s comment and _handle_dart_away_input() below).
	## Bots are the one exception: they keep an independent
	## get_desired_recall() AI decision, since a bot has no single physical
	## "button" whose state can double for both intents. That decision is
	## always a one-shot pulse (see bot_controller.gd's own comment on that
	## contract), which _handle_dart_away_input()'s hold-duration tracking
	## below naturally reads as a tap (no sustained hold ever happens), so
	## bots always Recall, never Redirect -- see this file's own header
	## comment on that being an explicit later (Phase 6) judgment call.
	if is_bot and bot_controller != null:
		return bot_controller.get_desired_recall()
	return _get_action_held()


## Disambiguates the shared Throw/Recall button's meaning while the dart is
## away, per docs/project.md's Throw/Recall/Redirect section:
##   - FLYING or SWINGING (dart mid-flight, no anchor to redirect from):
##     tap-only immediate Recall on press, unchanged from before this phase.
##   - EMBEDDED (dart anchored, a real redirect target): a quick tap (press
##     then release before SWING_REDIRECT_HOLD_THRESHOLD elapses) still means
##     Recall -- an explicit no-regression requirement (see this task's own
##     definition of done); a hold-then-release aiming a direction normally
##     means Redirect (begin_swing_redirect(aim_dir), into SWINGING) -- UNLESS
##     (Task #20) the hold/resulting redirect would be a near-zero-distance,
##     pointless micro-hop (see _redirect_is_pointless_micro_hop()), in which
##     case it resolves to an instant pickup (dart.force_holster()) instead of
##     attempting the tiny swing. This is deliberately a THIRD outcome,
##     distinct from tap-Recall -- Recall travels back over time through
##     RETURNING; this pickup is an immediate hard snap to HOLSTERED, for a
##     hold that was clearly an attempted (if pointless) Redirect, not a
##     Recall gesture.
## _embedded_hold_active gates on "was this hold already being tracked", not
## strictly a rising edge of the physical button -- deliberately, so a player
## who never lets go of the button across a whole SWINGING flight (held
## through the redirect that launched it, still held when it lands back into
## EMBEDDED) starts a FRESH trackable hold the instant it lands, rather than
## that continued-held press being silently ignored until the next distinct
## press. Both _embedded_hold_time/_embedded_hold_active are reset whenever
## the dart isn't EMBEDDED so a hold that started before a state change never
## leaks into a decision it shouldn't govern.
## Task #18: see SWING_REDIRECT_MIN_DISTANCE/SWING_REDIRECT_MAX_CHARGE_TIME's
## own comments above for the full reasoning -- this just evaluates the lerp.
## charge_ratio is deliberately NOT re-based off SWING_REDIRECT_HOLD_THRESHOLD
## (i.e. not `(hold_time - threshold) / (max - threshold)`) -- a plain
## `hold_time / SWING_REDIRECT_MAX_CHARGE_TIME` already starts near the
## MINIMUM at the tap/hold boundary (threshold=0.1 is small relative to
## max_charge_time=0.6, so ratio~0.17 there), which is the intended "just
## barely a hold" read, without needing a second derived constant.
## Task #20: this now returns a max distance FROM THE OWNER for this leg
## (not from the dart's own current/launch position -- see
## SWING_REDIRECT_MIN_DISTANCE's own comment for the full correction
## reasoning), handed to rope_dart.gd's begin_swing_redirect() as
## max_travel_distance and applied there as an owner-relative range_cap.
func _compute_redirect_travel_distance() -> float:
	var ceiling: float = dart.rope_length if (dart != null and is_instance_valid(dart)) else SWING_REDIRECT_MIN_DISTANCE
	var charge_ratio: float = clampf(_embedded_hold_time / SWING_REDIRECT_MAX_CHARGE_TIME, 0.0, 1.0)
	return lerp(SWING_REDIRECT_MIN_DISTANCE, ceiling, charge_ratio)


## Task #20: true if a hold-then-release redirect attempt at EMBEDDED would
## resolve to a near-zero-distance, pointless micro-hop rather than a
## meaningful swing -- either because:
##   - the hold itself barely cleared the tap/hold boundary
##     (SWING_REDIRECT_HOLD_THRESHOLD) without ever becoming a real charge
##     (< SWING_REDIRECT_PICKUP_HOLD_TIME), regardless of geometry; or
##   - the predicted landing point for this leg (dart.
##     predict_redirect_landing_point(), given aim_dir and this leg's
##     charge-scaled owner-relative effective_range -- see
##     _compute_redirect_travel_distance()) sits too close to the dart's
##     CURRENT position -- i.e. rope_dart.gd's own owner-relative range_cap
##     for this leg would immediately re-embed the dart within a step or two
##     of its existing anchor.
##
## Task #21 fix: the second condition above used to subtract the dart's
## CURRENT owner-relative distance from effective_range (this leg's FINAL
## owner-relative range budget) and call that "predicted travel" -- two
## different owner-relative quantities that only coincidentally resemble
## "how far will this leg travel" when the dart starts close to the owner.
## Once the dart is already sitting anywhere near its normal, far-from-owner
## resting distance (the common case after any real throw or prior
## redirect), that subtraction is small or often negative, wrongly tripping
## this pointless-micro-hop path for ordinary, meaningfully-charged
## redirects -- exactly the reported "redirect snaps the dart back to hand"
## bug. Fixed by measuring the actual displacement this leg would travel:
## dart.predict_redirect_landing_point() reuses rope_dart.gd's own
## wrap-aware _clamp_along_wrap_path() (the same clamp _process_flying()'s
## SWINGING branch itself applies) to find where the dart would land, then
## this compares THAT against the dart's CURRENT position -- a real
## displacement, not a subtraction of two unrelated owner-relative ranges.
func _redirect_is_pointless_micro_hop(effective_range: float) -> bool:
	if _embedded_hold_time < SWING_REDIRECT_PICKUP_HOLD_TIME:
		return true
	if dart == null or not is_instance_valid(dart):
		return true
	var landing: Vector2 = dart.predict_redirect_landing_point(get_pos_2d(), aim_dir, effective_range)
	var predicted_travel: float = dart.pos_2d.distance_to(landing)
	return predicted_travel < SWING_REDIRECT_MIN_TRAVEL


func _handle_dart_away_input(delta: float) -> void:
	if dart == null or not is_instance_valid(dart):
		return
	var held: bool = _get_recall_held()
	var rising_edge: bool = held and not _prev_recall_held
	_prev_recall_held = held

	if dart.state == DART_STATE_FLYING or dart.state == DART_STATE_SWINGING:
		_embedded_hold_active = false
		if rising_edge:
			dart.begin_recall()
		return

	if dart.state != DART_STATE_EMBEDDED:
		_embedded_hold_active = false
		return

	if held:
		if not _embedded_hold_active:
			_embedded_hold_active = true
			_embedded_hold_time = 0.0
		else:
			_embedded_hold_time += delta
	elif _embedded_hold_active:
		_embedded_hold_active = false
		if _embedded_hold_time >= SWING_REDIRECT_HOLD_THRESHOLD:
			var effective_range: float = _compute_redirect_travel_distance()
			if _redirect_is_pointless_micro_hop(effective_range):
				dart.force_holster()
			else:
				dart.begin_swing_redirect(aim_dir, effective_range)
		else:
			dart.begin_recall()


func _get_melee_action_held() -> bool:
	## Physical Slash/Kick input signal (Face Button Secondary / E / right
	## mouse button / touch Slash button, per the GDD Controls section) --
	## humans/gamepad/touch only, same split as _get_action_held() above vs.
	## _get_throw_held()/_get_recall_held(): bots go through their own
	## get_desired_melee() AI decision in _get_melee_held() below instead of
	## this shared physical signal.
	if player_index == 0:
		if _virtual_controls != null and _virtual_controls.get_slash_held():
			return true
		return Input.is_key_pressed(KEY_E) or Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT)
	return Input.is_joy_button_pressed(player_index - 1, JOY_BUTTON_B)


func _get_melee_held() -> bool:
	if is_bot and bot_controller != null:
		return bot_controller.get_desired_melee()
	return _get_melee_action_held()


## Same button, context-sensitive on dart.state (GDD Controls: "Slash / Kick
## ... same pattern as Throw/Recall"): dart in hand (HOLSTERED/CHARGING) ->
## Slash; dart away (FLYING/EMBEDDED/SWINGING/RETURNING, the `else` branch
## below) -> Kick. Rising-edge + cooldown gated (see MELEE_COOLDOWN's own
## comment), unlike Throw/Recall's hold-to-charge/press-to-recall shape,
## since melee resolves instantly in a single tick rather than spanning a
## charge or a multi-tick travel.
func _handle_melee_input() -> void:
	if dart == null or not is_instance_valid(dart):
		return
	var held: bool = _get_melee_held()
	var is_rising_edge: bool = held and not _prev_melee_held
	_prev_melee_held = held
	if not is_rising_edge or _melee_cooldown_timer > 0.0:
		return
	_melee_cooldown_timer = MELEE_COOLDOWN
	if dart.state == DART_STATE_HOLSTERED or dart.state == DART_STATE_CHARGING:
		_perform_slash()
	else:
		_perform_kick()


## Dart in hand -- melee with the dart itself. Reuses the exact same
## dart-contact-kill path rope_dart.gd's own _check_player_hits() already
## uses for the thrown dart (GDD Combat's "Dart Contact" section: lethal
## whenever the dart is actively moving or wielded -- Flying, Swinging,
## Returning, or a melee Slash while still in hand, Holstered/Charging --
## take_dart_hit() itself doesn't care who/what called it, so no separate
## kill path is needed here, just a melee-range trigger for the same one.
## Unaffected by the Task #16 EMBEDDED-not-lethal exception: that exception
## only scopes down rope_dart.gd's own AWAY-state dart, not this in-hand
## melee, which is a wholly separate call site. Range check only, no facing
## cone -- matches the task's own "player-vs-player melee (a range check
## against nearby players)" scope.
func _perform_slash() -> void:
	# Task #15: fire the attacker's own swing VFX regardless of whether it
	# actually connects -- a whiffed Slash still needs to visibly READ as a
	# Slash, same as the target's own reaction (teleport/knockback) already
	# only fires when it connects, but the ATTACKER'S half of the feedback
	# loop shouldn't depend on hitting something.
	_trigger_slash_vfx()
	var my_pos: Vector2 = get_pos_2d()
	for p in get_tree().get_nodes_in_group("players"):
		if p == self or not is_instance_valid(p):
			continue
		if p.get("is_dead") == true:
			continue
		if my_pos.distance_to(p.get_pos_2d()) <= MELEE_RANGE:
			p.take_dart_hit()


## Dart away -- unarmed melee. Knockback only, never lethal (GDD Combat:
## "Kick ... Knockback only, never lethal. Only usable while the dart is not
## in hand").
func _perform_kick() -> void:
	# Task #15: same "fire the attacker's own VFX unconditionally" reasoning
	# as _perform_slash() above.
	_trigger_kick_vfx()
	var my_pos: Vector2 = get_pos_2d()
	for p in get_tree().get_nodes_in_group("players"):
		if p == self or not is_instance_valid(p):
			continue
		if p.get("is_dead") == true:
			continue
		if my_pos.distance_to(p.get_pos_2d()) <= MELEE_RANGE:
			p.apply_kick_knockback(my_pos)


## Task #15: Slash's own visual feedback on the ATTACKER -- plays the "Throw"
## clip sped up to fit SLASH_ANIM_DURATION (see SLASH_ANIM_NAME's own header
## comment on why that clip specifically), briefly overriding locomotion via
## _combat_anim_active (consumed by _process(), see that block's own
## comment), plus a bright red flash for the "this was lethal" read. Falls
## back to the same procedural lunge Kick uses if the skeletal clip is
## unavailable for any reason (e.g. mesh/animation setup failed) so a Slash
## NEVER goes out with zero visual feedback.
func _trigger_slash_vfx() -> void:
	var played_clip := false
	if _anim_player != null and _anim_player.has_animation(SLASH_ANIM_NAME):
		var clip: Animation = _anim_player.get_animation(SLASH_ANIM_NAME)
		var speed: float = (clip.length / SLASH_ANIM_DURATION) if clip.length > 0.0 else 1.0
		_play_anim(SLASH_ANIM_NAME, speed, true)
		_combat_anim_active = true
		_combat_anim_timer = SLASH_ANIM_DURATION
		played_clip = true
	if not played_clip:
		_play_lunge_tween(1.2)
	_flash_materials(SLASH_FLASH_COLOR)


## Task #15: Kick's own visual feedback on the ATTACKER -- no suitable
## skeletal clip exists (see SLASH_ANIM_NAME's own header comment), so this
## is a lightweight procedural forward lunge (_play_lunge_tween) plus a
## duller orange flash for the "this was knockback, not lethal" read (see
## SLASH_FLASH_COLOR/KICK_FLASH_COLOR's own comment).
func _trigger_kick_vfx() -> void:
	_play_anim("Idle_A", 1.0, true)
	_combat_anim_active = true
	_combat_anim_timer = KICK_ANIM_DURATION
	_play_lunge_tween(1.0)
	_flash_materials(KICK_FLASH_COLOR)


## Shared procedural "punch forward, snap back" used by Kick always and by
## Slash as its no-skeletal-clip fallback -- a quick positional offset on
## player_mesh (never touched by anything else on the X/Z axes: _process()
## only ever writes player_mesh.position.y for the run-bob/ground-offset, so
## this can't fight that) in the attacker's current aim direction (falls back
## to _facing_dir if aim_dir is degenerate), eased out fast and back slower
## for a snappy "impact" read. distance_mult scales the reach so Slash's
## fallback (a weapon swing) can read as slightly bigger than Kick's own
## use (an unarmed jab).
func _play_lunge_tween(distance_mult: float = 1.0) -> void:
	if player_mesh == null:
		return
	if _lunge_tween != null and _lunge_tween.is_valid():
		_lunge_tween.kill()
	var dir2: Vector2 = aim_dir if aim_dir.length() > 0.01 else _facing_dir
	var lunge: Vector3 = Vector3(dir2.x, 0.0, dir2.y).normalized() * KICK_LUNGE_DISTANCE * distance_mult
	player_mesh.position.x = 0.0
	player_mesh.position.z = 0.0
	var tw := create_tween()
	tw.set_parallel(true)
	tw.tween_property(player_mesh, "position:x", lunge.x, KICK_LUNGE_OUT_TIME)\
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tw.tween_property(player_mesh, "position:z", lunge.z, KICK_LUNGE_OUT_TIME)\
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tw.chain().set_parallel(true)
	tw.tween_property(player_mesh, "position:x", 0.0, KICK_LUNGE_BACK_TIME)\
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	tw.tween_property(player_mesh, "position:z", 0.0, KICK_LUNGE_BACK_TIME)\
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	_lunge_tween = tw


## Brief emission-color flash layered on top of the normal player-color tint
## (_reset_player_tint) -- reverts automatically after MELEE_FLASH_DURATION.
## Reuses _player_materials, the same per-mesh-part duplicated-material list
## _reset_player_tint already tints for player-color identification, so this
## doesn't need its own material bookkeeping.
func _flash_materials(color: Color) -> void:
	for mat in _player_materials:
		mat.emission = color
	var tw := create_tween()
	tw.tween_interval(MELEE_FLASH_DURATION)
	tw.tween_callback(_reset_player_tint)


## Called by another player's _perform_kick() -- never by this player's own
## input. Overrides this player's movement for KICK_KNOCKBACK_DURATION, the
## same "scripted state wins over normal input" shape _is_dashing already
## uses for its own duration (see the velocity block in _physics_process),
## just driven externally by the kicker instead of this player's own input.
## Never lethal, and a no-op against an already-dead/respawning player --
## same is_dead guard shape as apply_rope_trip() below.
func apply_kick_knockback(from_pos: Vector2) -> void:
	if is_dead:
		return
	var away: Vector2 = get_pos_2d() - from_pos
	_knockback_dir = away.normalized() if away.length() > 0.01 else Vector2(0.0, 1.0)
	_knockback_timer = KICK_KNOCKBACK_DURATION


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


## Task #17: while SWINGING (mid-redirect -- see docs/project.md's "movement
## is restricted during committed dart actions"), the player can still move
## backward or strafe sideways but cannot advance forward. Same
## directional-component-projection technique as
## _apply_rope_leash_velocity_clamp() above (called just before this, applied
## before move_and_slide() so the player's own canonical position is never
## discontinuously moved) -- decompose velocity into a component along a
## reference "forward" axis and a perpendicular component, then clamp only
## the forward component (here: to non-positive, i.e. block ADVANCING, not
## retreating), leaving the perpendicular component completely untouched.
##
## Reference axis is aim_dir, not _facing_dir: aim_dir is the live,
## continuously-updated camera-relative "which way am I currently pointing"
## value (same one release_throw()/begin_swing_redirect() themselves use as
## "forward" -- the whole SWINGING state exists because of an aim_dir-aimed
## redirect), decoupled from this frame's own movement outcome. _facing_dir
## by contrast only updates from actual velocity direction (see _process()'s
## "Facing" block) and would freeze or drift the instant forward movement
## gets clamped toward zero here -- i.e. using it as the reference axis for
## THIS clamp would create a feedback loop between the axis and the very
## velocity component it's clamping. aim_dir has no such dependency.
func _apply_swing_forward_lock() -> void:
	if dart == null or not is_instance_valid(dart) or dart.state != DART_STATE_SWINGING:
		return
	if aim_dir.length() < 0.0001:
		return
	var forward_dir: Vector2 = aim_dir.normalized()
	var vel2d := Vector2(velocity.x, velocity.z)
	var forward_component: float = vel2d.dot(forward_dir)
	if forward_component > 0.0:
		vel2d -= forward_dir * forward_component
		velocity.x = vel2d.x
		velocity.z = vel2d.y


## Called by rope_dart.gd's _check_player_hits() when the dart HEAD overlaps
## this player in any away-state -- always lethal (GDD Combat: "Dart Contact
## ... Always lethal. Applies in every dart state: Flying, Embedded landing,
## Swinging, Returning"). Minimal Phase 2 kill: teleport to spawn_pos, no
## VFX/lives/round tracking (that's Phase 5 -- see this file's header
## comment and docs/implementation-plan.md's Phase 2 section).
##
## Task #10: the teleport alone used to leave the player's OWN dart (this
## player's persistent rope_dart.gd instance, referenced by `dart`) exactly
## wherever it was at the moment of death -- e.g. still EMBEDDED across the
## map, or mid-FLYING/RETURNING -- now completely disconnected from the
## player who just reappeared at spawn. global_position is set BEFORE
## _reset_movement_and_dart_state() so the dart's force_holster() snaps to
## the NEW spawn-local hand position, not the pre-death one.
func take_dart_hit() -> void:
	if is_dead:
		return
	is_dead = true
	_invuln_timer = RESPAWN_INVULN_TIME
	_trip_timer = 0.0
	global_position = spawn_pos
	_reset_movement_and_dart_state()


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


## Task #19: live world-space position of the character's real, currently
## ANIMATED hand (handslot.r bone -- see _hand_bone_idx's own comment for why
## this specific bone). Used by rope_dart.gd's _hand_attach_pos_3d() while the
## dart is HOLSTERED/CHARGING so it visually tracks idle sway/walk-cycle arm
## swing/Slash windup instead of a fixed hand-forward-offset approximation.
## Falls back to this player's own global_position (no forward offset at all)
## if the skeleton/bone lookup never resolved for any reason -- callers should
## treat a result equal (or very close) to global_position as "unavailable"
## and use their own fallback instead, since a raw equal-to-body position
## would otherwise visibly clip a held object into the character's torso.
func get_hand_world_position() -> Vector3:
	if _hand_skeleton == null or not is_instance_valid(_hand_skeleton) or _hand_bone_idx < 0:
		return global_position
	return (_hand_skeleton.global_transform * _hand_skeleton.get_bone_global_pose(_hand_bone_idx)).origin


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
	## Round-start reset: reposition at the given spawn point and clear any
	## in-progress fall/dash/combat/dart state. Task #10: this header comment
	## used to claim "No lives/dart/combat state exists any more to reset" --
	## stale since Phase 2 added is_dead/_trip_timer/dart back; a round that
	## starts (or restarts) with a player mid-death-invuln, mid-trip, or with
	## their dart still away from a previous life would otherwise carry that
	## state across the round boundary. global_position is set BEFORE
	## _reset_movement_and_dart_state() for the same reason as
	## take_dart_hit() -- so the dart force_holsters to the NEW spawn point.
	if is_falling:
		is_falling = false
		_reset_fall_visual()
	spawn_pos = start_pos
	global_position = start_pos
	collision_shape.disabled = false
	is_dead = false
	_invuln_timer = 0.0
	_trip_timer = 0.0
	_reset_movement_and_dart_state()


## Shared by take_dart_hit() (death/respawn) and reset_for_round() (round
## start) -- Task #10: guarantees every teleport-to-spawn also leaves the
## player with a clean movement state (no residual velocity, no in-progress
## dash carrying through the teleport) and a clean dart (snapped back to
## HOLSTERED at the new spawn point, never left behind wherever it was).
## Callers must set global_position to the new spawn point BEFORE calling
## this, since force_holster() below reads the owner's CURRENT position.
##
## Also clears the Slash/Kick knockback state (_knockback_timer/_dir,
## _melee_cooldown_timer/_prev_melee_held -- see MELEE_RANGE's own comment
## above and apply_kick_knockback()) for the same "residual movement state"
## reason as dash: an in-progress knockback carrying through a teleport would
## be the same class of glitch as a residual dash.
func _reset_movement_and_dart_state() -> void:
	velocity = Vector3.ZERO
	_is_dashing = false
	_dash_timer = 0.0
	_dash_cooldown_timer = 0.0
	_prev_dash = false
	_knockback_timer = 0.0
	_knockback_dir = Vector2.ZERO
	_melee_cooldown_timer = 0.0
	_prev_melee_held = false
	# Phase 4: an in-progress EMBEDDED hold-for-redirect is exactly the same
	# class of "residual scripted-input state that must not carry through a
	# teleport" as dash/knockback/melee cooldown above -- a player who
	# dies/respawns mid-hold must not have that hold silently resolve into a
	# Redirect (or Recall) against their NEW post-teleport dart position/
	# state on some later tick. force_holster() below already flips
	# dart.state away from EMBEDDED, which would self-correct this on the
	# very next _handle_dart_away_input() call regardless, but clearing it
	# explicitly here (rather than relying on that) matches this function's
	# own existing convention for every other residual timer/flag.
	_embedded_hold_active = false
	_embedded_hold_time = 0.0
	if dart != null and is_instance_valid(dart) and dart.has_method("force_holster"):
		dart.force_holster()
