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
## Phase 5 turned that into a real lives/round-outcome system: take_dart_hit()
## now decrements `lives` and only teleports-to-spawn_pos (the old
## unconditional Phase 2 behavior) while lives remain; hitting 0 eliminates
## the player for the rest of the round instead (_eliminate() — model hidden,
## collision disabled, input stopped) until GameManager.start_round()'s
## reset_for_round() call revives them for the next round. See take_dart_hit()
## and _eliminate()'s own comments, and game_manager.gd's header comment for
## the round/match state machine this feeds into.
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

## Task #38 (Mobility -- Grapple/Pendulum Swing/Slingshot, docs/project.md):
## while EMBEDDED, the shared Dash button is repointed to a "momentum
## release" instead of a ground burst -- capture whatever velocity the
## player already has (tangential from circling the anchor == Pendulum
## Swing, radial-outward from running straight against the taut rope ==
## Slingshot, same underlying mechanism either way per the GDD) and boost
## its magnitude by this multiplier rather than snapping to a fixed
## direction/speed the way a normal ground dash does. Reuses the existing
## DASH_SPEED/_DURATION/_COOLDOWN system wholesale (see the dash-activation
## block in _physics_process()) -- only the captured direction and the
## resulting speed differ from a normal dash.
const MOMENTUM_RELEASE_BOOST_MULT: float = 1.8
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
const MELEE_RANGE: float = 1.8
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

## Task #34: kill/death screen shake tuning (see _trigger_kill_vfx() below and
## arena_camera.gd's own shake()) -- picked by eye via run_project, aiming for
## "clearly readable" without being disorienting given the camera's own fairly
## wide orthographic framing of the whole arena.
const KILL_SHAKE_INTENSITY: float = 0.35
const KILL_SHAKE_DURATION: float = 0.22


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
##
## Task #26 correction: the original 0.1s (100ms) value was measured, via a
## direct user bug report ("I was trying to retrieve the dart but it thinks I
## was trying to redirect and snapped to halfway") plus a headless probe
## driving the real _handle_dart_away_input() across a range of press
## durations through real Input.parse_input_event() KEY_SPACE press/release
## (see this task's own verification), to be far tighter than any realistic
## human "quick tap" -- a deliberate tap commonly measures 150-300ms+
## depending on input device/reflexes/frame timing, and at the old 0.1s
## threshold every one of those legitimate taps already qualified as a "hold"
## (crossing SWING_REDIRECT_PICKUP_HOLD_TIME too, by ~200ms, producing a real
## partial-charge redirect -- exactly the reported "snapped to halfway").
## _embedded_hold_time itself was audited and found to be an accurate
## same-tick measurement of real hold duration (starts at exactly 0.0 on the
## first held tick rather than double-counting, _prev_recall_held's
## rising/falling edges track a real single continuous press correctly, no
## stale-state leakage across EMBEDDED transitions) -- this was a pure tuning
## gap, not a mechanical bug. Raised to 0.25s (250ms): comfortably above the
## whole realistic "quick tap" range (confirmed by the same probe: 80-200ms
## presses all resolve to Recall at this value) while still small relative to
## SWING_REDIRECT_MAX_CHARGE_TIME (0.6s) and rope_dart.gd's own
## max_charge_time (0.7s, the original throw's full charge-up) -- a 250ms
## press is still clearly a "snap decision", not a full charge, consistent
## with this constant's own original design intent above.
const SWING_REDIRECT_HOLD_THRESHOLD: float = 0.25

## Task #18/#20 (SUPERSEDED by Task #30 -- kept as history, see below):
## originally a charge-scaled max DISTANCE FROM THE OWNER for a redirect leg.
## Task #18 first tried mirroring the ORIGINAL throw's own charge
## (release_throw()'s charge_ratio, which scales SPEED) and found it doesn't
## work for a range-capped leg: the redirect reuses rope_dart.gd's
## _process_flying(), the same range-capped travel logic FLYING already
## uses -- a faster dart launched into that same range-bounded endpoint just
## reaches it sooner, not further. So Task #18/#20 scaled the dart's
## range-cap-from-owner budget directly instead, via a helper
## (_compute_redirect_travel_distance(), since removed) that lerped a
## SWING_REDIRECT_MIN_DISTANCE floor up to the dart's own rope_length as
## _embedded_hold_time approached SWING_REDIRECT_MAX_CHARGE_TIME.
##
## Task #30 (design pivot, direct user request -- docs/project.md's Swinging
## section, "hold increase[s] swing speed but not the distance"): this whole
## distance-scaling model is now REVERSED. Distance for a redirect leg is no
## longer charge-dependent at all -- it's always the full owner-relative
## range (rope_length, or wherever obstacle/wrap routing stops it first),
## the same range logic a plain FLYING throw already uses (player.gd no
## longer computes or passes a distance budget to begin_swing_redirect() at
## all). Hold duration now scales SPEED instead, exactly mirroring how
## release_throw()'s own charge_ratio already works -- see rope_dart.gd's
## begin_swing_redirect()/swing_speed_min_mult/swing_speed_max_mult for the
## receiving side. SWING_REDIRECT_MAX_CHARGE_TIME below is reused, unchanged
## in value, as the ceiling for THIS new charge_ratio-on-speed computation
## (see _compute_redirect_charge_ratio()) -- the original Task #18/#20
## irony (that the SPEED-scaling approach "doesn't work" for a range-capped
## leg) no longer applies now that speed scaling is applied to a full-range
## leg rather than a range-capped-by-charge one: a faster dart still
## reaches the SAME (now charge-independent) endpoint sooner, which is
## exactly the intended effect this time, not the dead end Task #18 found it
## to be under the old distance-scaling model.
## Deliberately shorter than CHARGING's own max_charge_time (0.7s, in
## rope_dart.gd) -- same "a redirect-hold is a snap mid-fight decision, not a
## full charge-up" reasoning SWING_REDIRECT_HOLD_THRESHOLD's own comment
## already gives for the (much smaller) tap/hold disambiguation threshold.
const SWING_REDIRECT_MAX_CHARGE_TIME: float = 0.6

## Task #20: a hold that's technically past SWING_REDIRECT_HOLD_THRESHOLD
## (so NOT a tap -- Recall doesn't apply) but still short enough that it
## doesn't read as a deliberate charge for a real redirect. See
## _redirect_is_pointless_micro_hop().
##
## Task #26 correction: raised from 0.18s to 0.4s alongside
## SWING_REDIRECT_HOLD_THRESHOLD's own 0.1s->0.25s raise (see that constant's
## comment for the full user-report/probe-measurement reasoning -- both
## constants were too tight for realistic press-release timing, not just this
## one). Kept as a fixed ~150ms buffer above the (now much larger) hold
## threshold rather than preserving the old ~1.8x multiplicative ratio --
## multiplying 0.25s by 1.8 would land at 0.45s, leaving almost no
## SWING_REDIRECT_MAX_CHARGE_TIME (0.6s) headroom for the charge_ratio lerp
## (as of Task #30, _compute_redirect_charge_ratio() -- speed-scaling; was
## _compute_redirect_travel_distance() when this scaled distance instead) to
## actually distinguish a "just past pointless" redirect from a max-charge
## one. A fixed 150ms gap is still far
## more than enough headroom above the tap/hold boundary to absorb any
## realistic input-polling jitter (a single physics tick is ~16ms) while
## leaving a genuine 200ms window (0.4s-0.6s) for the charge scale to matter.
const SWING_REDIRECT_PICKUP_HOLD_TIME: float = 0.4

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

## Task #28's SWING_REDIRECT_FULL_CHARGE_RATIO constant/exemption (a special
## case letting a near-max-charge hold skip _redirect_is_pointless_micro_hop()'s
## distance check entirely) is REMOVED as of Task #30, not just renamed:
## that exemption existed specifically because, under the old
## charge-scales-DISTANCE model, a max-charge hold aimed the same direction
## as a dart already sitting near rope_length could still compute a
## near-zero predicted_travel (the charge-scaled request and the dart's
## existing position converged at the same ceiling) and get wrongly vetoed
## to a pickup despite being the most deliberate possible input -- see
## _redirect_is_pointless_micro_hop()'s own header comment (git history) for
## the full original bug report. As of Task #30, effective_range for the
## distance check is always the full rope_length for EVERY hold long enough
## to not be an unconditional pickup (SWING_REDIRECT_PICKUP_HOLD_TIME) --
## there's no longer a "short-hold-computed-a-small-request" case for a
## bigger charge to be wrongly caught by, so the exemption has nothing left
## to guard against. The one real edge case that survives is now a fixed
## geometric fact independent of hold length -- see
## _redirect_is_pointless_micro_hop()'s current header comment.

# Combat (Phase 2 -- see rope_dart.gd's _check_player_hits()). Dart contact
# is always lethal in every away-state; rope-line contact only trips/slows.
# Phase 5 (docs/implementation-plan.md) turned that into a real lives/round
# system: take_dart_hit() decrements `lives` (reset each round by
# reset_for_round()) and only respawns-to-spawn_pos if lives remain --
# reaching 0 eliminates the player for the rest of the round (see
# _eliminate()) instead. GameManager._check_round_win() discovers "how many
# players still have lives > 0" by directly reading this duck-typed `lives`
# field off each of its _all_players entries every PLAYING frame (a group
# query + a lives>0 check, per this task's own suggested wiring) -- no signal
# needed, matching this file's existing "GameManager polls player state"
# convention rather than inventing a push-based one.
var is_dead: bool = false
## Round-scoped, reset to GameManager.lives_per_round by reset_for_round().
## Defaults to a nonzero value here (not 0) so ad hoc player nodes
## instantiated directly by regression tests -- which construct player.tscn
## by hand and never call reset_for_round() (see tests/test_dart_phase2_combat.gd's
## _make_player()) -- still show the exact same single-hit "kill ->
## teleport-to-spawn_pos" behavior those tests already assert, rather than
## being instantly eliminated on their very first hit.
var lives: int = 3
## True once `lives` reaches 0 this round -- no more respawn until the next
## reset_for_round() revives this player. See _eliminate().
var is_eliminated: bool = false
const RESPAWN_INVULN_TIME: float = 1.2  ## brief window after ANY spawn (round
## start via reset_for_round(), or a mid-round respawn via take_dart_hit())
## where this player is both untouchable -- is_dead stays true so every
## existing "skip dead players" guard (Slash/Kick targeting, apply_kick_
## knockback(), take_dart_hit() itself, apply_rope_trip()) already treats
## them as untargetable, same mechanism that originally guarded the
## degenerate case of spawn_pos sitting inside a still-lethal dart's hit/trip
## radius the instant a player teleports in -- and unmovable, via
## _physics_process()'s own early-return for this window, so they can't be
## displaced (or act) until it expires.
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

# Online multiplayer (host-authoritative -- see GameManager's "Online match
# sync" block). The host simulates every player; guests only render the host's
# snapshots and send their own player's input.
var player_peer_id: int = 1          # which multiplayer peer owns this player

## Bitfield for the buttons half of a guest's per-tick input packet.
const NET_BTN_DASH := 1
const NET_BTN_ACTION := 2
const NET_BTN_MELEE := 4
## Snapshot flags bitfield (see get_net_snapshot()).
const NET_FLAG_DEAD := 1
const NET_FLAG_ELIMINATED := 2
const NET_FLAG_DASHING := 4
## One-off cosmetic events mirrored host -> guests (see _fx()/play_fx()).
enum Fx { DASH, SLASH, KICK, KILL, TRIP, FALL }
## Host-side cap on queued guest input frames (~100ms at 60Hz): frames are
## consumed one per physics tick so short taps survive network bunching, but
## a backlog beyond this is dropped oldest-first to keep input latency bounded.
const NET_INPUT_MAX_QUEUE := 6
## Guest-side: how fast a rendered player closes the gap to the latest host
## snapshot position, and the gap beyond which it snaps instead (respawns,
## round resets -- anything that's a teleport on the host).
const NET_INTERP_RATE := 25.0
const NET_SNAP_DISTANCE := 2.5

# Dash state
var _dash_timer: float = 0.0
var _dash_cooldown_timer: float = 0.0
var _is_dashing: bool = false
var _dash_dir: Vector2 = Vector2.ZERO
var _prev_dash: bool = false
## Speed used by the dash-active velocity branch below -- DASH_SPEED for a
## normal ground dash, or a per-launch boosted value for a Task #38 momentum
## release (see MOMENTUM_RELEASE_BOOST_MULT's own comment). Reset to
## DASH_SPEED at the top of every fresh dash activation so a normal dash
## right after a momentum release never inherits a stale boosted value.
var _dash_speed: float = DASH_SPEED
## Task #34: brief trail/streak VFX while dashing -- a continuous (one_shot =
## false) GPUParticles3D toggled on/off around the dash's own DASH_DURATION
## window (see the dash-activation and dash-duration-countdown blocks in
## _physics_process()) rather than a fresh one-shot burst per dash, so the
## particles read as a streak trailing the whole burst rather than a single
## puff at the start. Built once in _ready() (_setup_dash_trail()) as a CHILD
## of this CharacterBody3D (unlike rope_dart.gd's one-shot impact sparks,
## which are deliberately NOT parented to the moving dart -- this one SHOULD
## follow the player around, that's the whole point of a trail).
var _dash_trail: GPUParticles3D = null

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

# Host-side: a remote human's queued input frames ([move, aim, buttons]),
# filled by push_net_input() and consumed one per tick into _net_frame, which
# the _get_*_input() getters read instead of local devices.
var _net_queue: Array = []
var _net_frame: Array = [Vector2.ZERO, Vector2.ZERO, 0]
# Guest-side: latest host snapshot position this player is gliding toward.
var _net_target_pos: Vector3 = Vector3.ZERO
var _has_net_target: bool = false


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
	_setup_dash_trail()
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
	if is_primary_local_player() and DisplayServer.is_touchscreen_available():
		var vc: Node = load("res://scripts/virtual_controls.gd").new()
		vc.name = "VirtualControls"
		get_tree().root.add_child(vc)
		_virtual_controls = vc
		# Off-screen enemy pins (Task #45) -- same touch-only gate, since
		# arena_camera.gd's tight touch follow zoom (see that script) is what
		# makes off-screen enemies possible in the first place.
		var pins: Node = load("res://scripts/enemy_pins.gd").new()
		pins.name = "EnemyPins"
		get_tree().root.add_child(pins)


# ---------------------------------------------------------------------------
# Online roles
# ---------------------------------------------------------------------------

func _is_online() -> bool:
	return GameManager.is_online and multiplayer.multiplayer_peer != null


## True on the peer that runs this player's real simulation: always offline,
## and only the host online.
func is_sim_authority() -> bool:
	return not _is_online() or multiplayer.is_server()


## The player driven by THIS device's own keyboard/mouse/touch: slot 0
## offline (other local slots use gamepads), or whichever human slot this
## peer owns online. Also what the camera/enemy pins treat as "me".
func is_primary_local_player() -> bool:
	if is_bot:
		return false
	if _is_online():
		return player_peer_id == multiplayer.get_unique_id()
	return player_index == 0


## Host-side: a remote guest's human player, driven by its queued input.
func _uses_net_input() -> bool:
	return _is_online() and multiplayer.is_server() and not is_bot \
		and player_peer_id != multiplayer.get_unique_id()


## Which input branch the _get_*_input() getters take for a human: the
## primary device (keyboard/mouse/touch) online -- a guest only ever reads
## its own player -- or offline slot 0; gamepad `player_index - 1` otherwise.
func _reads_primary_input() -> bool:
	return _is_online() or player_index == 0


func push_net_input(move: Vector2, aim: Vector2, buttons: int) -> void:
	_net_queue.append([move, aim, buttons])
	while _net_queue.size() > NET_INPUT_MAX_QUEUE:
		_net_queue.pop_front()


func clear_net_input() -> void:
	_net_queue.clear()
	_net_frame = [Vector2.ZERO, Vector2.ZERO, 0]


func _consume_net_input() -> void:
	# An empty queue keeps the previous frame -- a late packet then reads as
	# "still holding the same input", not a spurious release.
	if not _net_queue.is_empty():
		_net_frame = _net_queue.pop_front()


func _net_button(bit: int) -> bool:
	return (int(_net_frame[2]) & bit) != 0


## Guest-side physics tick: no simulation at all (the host's snapshots drive
## this player), just ship this device's input for our own player.
func _net_guest_tick() -> void:
	if not is_primary_local_player():
		return
	var move_in: Vector2 = _get_move_input()
	var aim_in: Vector2 = _get_aim_input()
	var buttons: int = 0
	if _get_dash_pressed():
		buttons |= NET_BTN_DASH
	if _get_action_held():
		buttons |= NET_BTN_ACTION
	if _get_melee_action_held():
		buttons |= NET_BTN_MELEE
	GameManager.send_local_input(move_in, aim_in, buttons)
	# Aim locally right away instead of waiting a round trip for the host's
	# snapshot (apply_net_snapshot() skips aim_dir for our own player) -- same
	# rule as _physics_process's own aim block.
	if aim_in.length() > DEADZONE:
		aim_dir = aim_in.normalized()
	elif move_in.length() > DEADZONE:
		aim_dir = move_in.normalized()
	if aim_indicator != null:
		aim_indicator.position = Vector3(aim_dir.x, 0.0, aim_dir.y) * 1.2


## Host-side: this player's replicated state, one entry of GameManager's
## per-tick snapshot.
func get_net_snapshot() -> Array:
	var flags: int = 0
	if is_dead:
		flags |= NET_FLAG_DEAD
	if is_eliminated:
		flags |= NET_FLAG_ELIMINATED
	if _is_dashing:
		flags |= NET_FLAG_DASHING
	var dart_ok: bool = dart != null and is_instance_valid(dart)
	return [
		global_position, velocity, aim_dir, lives, flags,
		dart.state if dart_ok else -1,
		dart.pos_2d if dart_ok else Vector2.ZERO,
		dart.dir_2d if dart_ok else Vector2.ZERO,
		dart.get_charge_time() if dart_ok else 0.0,
	]


## Guest-side: apply one host snapshot entry (see get_net_snapshot()).
func apply_net_snapshot(snap: Array) -> void:
	var pos: Vector3 = snap[0]
	_net_target_pos = pos
	if not _has_net_target or global_position.distance_to(pos) > NET_SNAP_DISTANCE:
		global_position = pos
	_has_net_target = true
	velocity = snap[1]
	if not is_primary_local_player():
		aim_dir = snap[2]
		if aim_indicator != null:
			aim_indicator.position = Vector3(aim_dir.x, 0.0, aim_dir.y) * 1.2
	lives = int(snap[3])
	var flags: int = int(snap[4])
	is_dead = (flags & NET_FLAG_DEAD) != 0
	if (flags & NET_FLAG_ELIMINATED) != 0 and not is_eliminated:
		_eliminate()
	var dashing: bool = (flags & NET_FLAG_DASHING) != 0
	if dashing != _is_dashing:
		_is_dashing = dashing
		if not dashing and _dash_trail != null:
			_dash_trail.emitting = false
	if dart != null and is_instance_valid(dart) and int(snap[5]) >= 0:
		dart.apply_net_state(int(snap[5]), snap[6], snap[7], float(snap[8]))


## Plays a one-off cosmetic event locally and, on an online host, mirrors it
## to every guest (GameManager._rpc_player_fx -> play_fx() there).
func _fx(kind: int, pos_2d: Vector2 = Vector2.ZERO) -> void:
	play_fx(kind, pos_2d)
	GameManager.broadcast_player_fx(player_index, kind, pos_2d)


func play_fx(kind: int, pos_2d: Vector2 = Vector2.ZERO) -> void:
	match kind:
		Fx.DASH:
			Sfx.play_dash()
			if _dash_trail != null:
				_dash_trail.emitting = true
		Fx.SLASH:
			_trigger_slash_vfx()
		Fx.KICK:
			_trigger_kick_vfx()
		Fx.KILL:
			Sfx.play_kill()
			_trigger_kill_vfx(pos_2d)
		Fx.TRIP:
			Sfx.play_trip()
		Fx.FALL:
			_start_fall()


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


## Task #34: builds this player's own dash-trail particle emitter once, as a
## child of this CharacterBody3D (see _dash_trail's own header comment for why
## this one, unlike rope_dart.gd's impact sparks, SHOULD be parented and move
## with the owner). Colored via player_color (already resolved above in
## _ready(), before this is called) so each player's own trail is visually
## identifiable, matching this project's existing player-color-as-identity
## convention (_reset_player_tint's own emission tint). Starts with
## emitting = false -- toggled on/off by the dash-activation/dash-duration
## blocks in _physics_process(), never emits outside an actual dash.
func _setup_dash_trail() -> void:
	var particles := GPUParticles3D.new()
	particles.name = "DashTrail"
	particles.amount = 24
	particles.lifetime = 0.35
	particles.one_shot = false
	particles.emitting = false
	particles.local_coords = false
	var mesh := SphereMesh.new()
	mesh.radius = 0.07
	mesh.height = 0.14
	particles.draw_pass_1 = mesh
	var mat := ParticleProcessMaterial.new()
	mat.direction = Vector3(0.0, 1.0, 0.0)
	mat.spread = 180.0
	mat.gravity = Vector3.ZERO
	mat.initial_velocity_min = 0.3
	mat.initial_velocity_max = 1.0
	mat.damping_min = 2.0
	mat.damping_max = 3.0
	mat.scale_min = 0.4
	mat.scale_max = 0.9
	mat.color = player_color
	particles.process_material = mat
	add_child(particles)
	particles.position = Vector3(0.0, _mesh_ground_offset + 0.3, 0.0)
	_dash_trail = particles


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
	# Online guest: glide toward the latest host snapshot position (see
	# apply_net_snapshot(), which snaps instead for teleport-sized gaps).
	if _has_net_target and not is_sim_authority():
		global_position = global_position.lerp(_net_target_pos, clampf(NET_INTERP_RATE * delta, 0.0, 1.0))
	# Smooth speed ratio toward current velocity magnitude (0.0–1.0)
	var speed_ratio: float = velocity.length() / move_speed
	_move_speed_smooth = lerp(_move_speed_smooth, speed_ratio, 10.0 * delta)

	if player_mesh == null:
		return
	if is_falling:
		return
	if is_eliminated:
		# Out for the rest of the round -- player_mesh is hidden (see
		# _eliminate()), so there's nothing useful for this frame's
		# locomotion-animation/facing/bob logic to do until reset_for_round()
		# revives this player.
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

	# Facing: smoothly turn the mesh to face the AIM direction (Task #44 --
	# previously this tracked movement velocity, so standing still while
	# aiming did nothing visually; aim_dir is the existing, continuously
	# updated direction already driving throw/redirect across mouse/gamepad/
	# touch input -- see _get_aim_input()/_get_mouse_aim() and the aim_dir
	# update block in _physics_process -- and it already falls back to the
	# movement direction when there's no live aim input, e.g. gamepad/touch
	# with the aim stick neutral, so normal "face the way you're walking"
	# behavior is preserved for those inputs; only mouse (which always has a
	# live aim reading toward the cursor) and explicit stick aim actually
	# decouple facing from movement now, which is the intended behavior
	# change here. KayKit's modeled forward is actually +Z after import (same
	# as the old fruit models needed, confirmed visually), opposite of
	# Basis.looking_at()'s -Z convention, so look toward the reverse vector.
	if aim_dir.length() > 0.01:
		_facing_dir = aim_dir.normalized()
		var dir3 := Vector3(_facing_dir.x, 0.0, _facing_dir.y)
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
	if not is_sim_authority():
		_net_guest_tick()
		return
	if _uses_net_input():
		# Consume every tick, even through the early-returns below, so a
		# backlog never builds up while this player can't act.
		_consume_net_input()
	if is_falling:
		return
	if is_eliminated:
		# Out for the rest of the round (see _eliminate()) -- stop processing
		# input entirely, same "scripted state overrides the normal per-tick
		# pipeline" shape is_falling's own early-return above already uses.
		# Collision is disabled (_eliminate()) so move_and_slide() here is a
		# harmless no-op, kept only so the physics engine still registers this
		# body each tick like every other early-return branch below does.
		velocity = Vector3.ZERO
		move_and_slide()
		return
	if GameManager.current_state != GameManager.RoundState.PLAYING:
		velocity = Vector3.ZERO
		move_and_slide()
		return

	# --- Spawn/respawn protection window (see RESPAWN_INVULN_TIME's own
	# comment) -- unmovable: early-return before any input is read, same
	# "scripted state overrides the normal per-tick pipeline" shape
	# is_eliminated/is_falling above already use.
	if _invuln_timer > 0.0:
		_invuln_timer -= delta
		if _invuln_timer <= 0.0:
			is_dead = false
		velocity = Vector3.ZERO
		move_and_slide()
		return

	var move_input: Vector2 = _get_move_input()
	var aim_input: Vector2 = _get_aim_input()

	# --- Rope-trip countdown ---
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
			if _dash_trail != null:
				_dash_trail.emitting = false

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
			# Task #38: while EMBEDDED, Dash is repointed to a momentum
			# release (Pendulum Swing / Slingshot) instead of a normal ground
			# burst -- same shared button, disambiguated by dart.state, same
			# pattern as Throw/Recall/Redirect and Slash/Kick elsewhere in
			# this project. _movement_locked_now above already excludes
			# CHARGING and holding-to-redirect, so this only ever fires while
			# genuinely EMBEDDED and not mid-hold, per the GDD.
			var dart_embedded_now: bool = dart != null and is_instance_valid(dart) and dart.state == DART_STATE_EMBEDDED
			if dart_embedded_now:
				# `velocity` here is left over from the END of the PREVIOUS
				# physics tick, already run through
				# _apply_rope_leash_velocity_clamp() -- for the tangential/
				# circling (Pendulum) case this is exactly right and MUST be
				# preferred: the leash only ever strips the outward-radial
				# component, so as the player sweeps around the anchor
				# `velocity`'s direction correctly curves to track the true
				# instantaneous tangent, which a fixed/raw held-input
				# direction alone would NOT (measured: after a 40-tick
				# circling sweep with a constant world-space move_input, the
				# true post-clamp velocity direction had already rotated
				# ~30deg off the original input direction -- using raw input
				# instead of measured velocity would launch the player off at
				# a stale angle, not the direction they're actually curving
				# along).
				#
				# BUT for the radial/straight-out (Slingshot) case -- the
				# GDD's own DoD explicitly requires this to work ("run
				# straight out against the taut rope, then Dash") -- a
				# headless probe driving the real player/dart state machine
				# (pure radial-outward move_input held against a taut
				# EMBEDDED anchor for 20+ ticks) measured `velocity` settling
				# to a *persistent* exact zero from the second tick onward:
				# once at/beyond rope_length, the leash cancels the ENTIRE
				# freshly-commanded outward velocity every tick (it's 100%
				# radial, so "the outward component" being projected out IS
				# the whole vector) -- so by the time a player has been
				# holding straight into the taut rope for more than an
				# instant, `velocity` alone reads 0 and this mechanic would
				# silently do nothing.
				#
				# Fix: prefer measured `velocity` whenever it's meaningfully
				# non-zero (the correct, curve-accurate answer for circling,
				# and for any other case where the player still has real
				# motion); fall back to the CURRENT tick's freshly-computed
				# commanded velocity (mirrors the "--- Velocity ---" block's
				# own move_input -> velocity formula below) only in the
				# specific degenerate case the leash has fully zeroed actual
				# velocity but the player is still actively pushing outward --
				# exactly the sustained-slingshot steady state, and nothing
				# else.
				var actual_vel2d := Vector2(velocity.x, velocity.z)
				var actual_speed: float = actual_vel2d.length()
				var release_vel2d: Vector2 = actual_vel2d
				if actual_speed <= 0.1:
					var commanded_move: Vector2 = move_input
					if commanded_move.length() > 1.0:
						commanded_move = commanded_move.normalized()
					var trip_mult_now: float = TRIP_SPEED_MULT if _trip_timer > 0.0 else 1.0
					release_vel2d = commanded_move * move_speed * trip_mult_now
				var current_speed: float = release_vel2d.length()
				# Falls back to facing direction only in the fully degenerate
				# case of releasing from a genuine standstill (no velocity
				# AND no movement input at all at the instant of release).
				var release_dir: Vector2 = release_vel2d / current_speed if current_speed > 0.1 else _facing_dir
				_dash_dir = release_dir.normalized()
				_dash_speed = current_speed * MOMENTUM_RELEASE_BOOST_MULT
				# Unanchor the dart into RETURNING NOW, same tick, so the
				# leash's outward-radial clamp (_apply_rope_leash_velocity_
				# clamp(), gated on dart.state == EMBEDDED) stops running
				# starting next tick and this boosted velocity is actually
				# free to carry the player away instead of being immediately
				# capped back to the rope's radius.
				dart.begin_recall()
			else:
				var dash_dir: Vector2 = move_input if move_input.length() > 0.1 else _facing_dir
				_dash_dir = dash_dir.normalized()
				_dash_speed = DASH_SPEED
			_is_dashing = true
			_dash_timer = DASH_DURATION
			_dash_cooldown_timer = DASH_COOLDOWN
			_fx(Fx.DASH)
		_prev_dash = dash_held

	# --- Velocity ---
	if _is_dashing:
		velocity = Vector3(_dash_dir.x, 0.0, _dash_dir.y) * _dash_speed
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
	if _uses_net_input():
		return _net_button(NET_BTN_DASH)
	if _reads_primary_input():
		# Virtual Dash button takes priority, same pattern as
		# _get_move_input()/_get_aim_input()/_get_throw_held() above --
		# see virtual_controls.gd's Phase 4.5 header comment.
		if _virtual_controls != null and _virtual_controls.get_dash_held():
			return true
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
	if _uses_net_input():
		return _net_button(NET_BTN_ACTION)
	if _reads_primary_input():
		if _virtual_controls != null and _virtual_controls.get_throw_held():
			return true
		# Task #43 fix: once a touch device's virtual overlay is active, do NOT
		# also fall back to Input.is_mouse_button_pressed() below. Godot's
		# default project setting input_devices/pointing/emulate_mouse_from_touch
		# is true and unset/unoverridden in this project's project.godot --
		# every real touch ALSO synthesizes a mouse click/drag event, so
		# Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT) reads true for ANY
		# touch anywhere on screen (e.g. dragging the movement stick), not just
		# a tap on the actual Throw button. That's what made the movement
		# stick spuriously "trigger" Throw. KEY_SPACE is deliberately still
		# checked even with the overlay active -- a physical/bluetooth keyboard
		# attached to a touch device is a legitimate (if rare) input source
		# that keyboard emulation from touch does not spuriously trigger, so
		# there's no equivalent bug to guard against there.
		if _virtual_controls != null:
			return Input.is_key_pressed(KEY_SPACE)
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
##     case it resolves to a Recall (dart.begin_recall(), Task #29 -- was an
##     instant dart.force_holster() pickup, which direct playtesting still
##     read as an unwanted hard "snap" even after Task #27/#28's geometric
##     fixes; the instant nature of force_holster() itself, not just which
##     threshold triggered it, was the remaining issue) instead of attempting
##     the tiny swing. A hold too short/pointless to redirect is now treated
##     exactly like a tap-Recall -- both travel back smoothly through
##     RETURNING, no separate instant-pickup outcome remains.
## _embedded_hold_active gates on "was this hold already being tracked", not
## strictly a rising edge of the physical button -- deliberately, so a player
## who never lets go of the button across a whole SWINGING flight (held
## through the redirect that launched it, still held when it lands back into
## EMBEDDED) starts a FRESH trackable hold the instant it lands, rather than
## that continued-held press being silently ignored until the next distinct
## press. Both _embedded_hold_time/_embedded_hold_active are reset whenever
## the dart isn't EMBEDDED so a hold that started before a state change never
## leaks into a decision it shouldn't govern.
## Task #30 (replaces Task #18/#20's _compute_redirect_travel_distance(),
## which lerped a DISTANCE budget -- see SWING_REDIRECT_MAX_CHARGE_TIME's own
## comment above for why that model was reversed): returns the charge
## fraction (0.0-1.0) this hold maps to for rope_dart.gd's
## begin_swing_redirect() SPEED lerp, exactly the same shape release_throw()
## already uses for its own charge_ratio (_charge_time / max_charge_time,
## clamped) -- just reading player.gd's own _embedded_hold_time/
## SWING_REDIRECT_MAX_CHARGE_TIME instead of rope_dart.gd's _charge_time/
## max_charge_time, since a redirect hold is tracked here (see
## _embedded_hold_time's own header comment for why). charge_ratio is
## deliberately NOT re-based off SWING_REDIRECT_HOLD_THRESHOLD (i.e. not
## `(hold_time - threshold) / (max - threshold)`) -- a plain
## `hold_time / SWING_REDIRECT_MAX_CHARGE_TIME` already starts near the
## MINIMUM at the tap/hold boundary (threshold=0.25 is well under
## max_charge_time=0.6), which is the intended "just barely a hold" read,
## without needing a second derived constant.
func _compute_redirect_charge_ratio() -> float:
	return clampf(_embedded_hold_time / SWING_REDIRECT_MAX_CHARGE_TIME, 0.0, 1.0)


## Task #20: true if a hold-then-release redirect attempt at EMBEDDED would
## resolve to a near-zero-distance, pointless micro-hop rather than a
## meaningful swing -- either because:
##   - the hold itself barely cleared the tap/hold boundary
##     (SWING_REDIRECT_HOLD_THRESHOLD) without ever becoming a real charge
##     (< SWING_REDIRECT_PICKUP_HOLD_TIME), regardless of geometry; or
##   - the predicted landing point for this leg (dart.
##     predict_redirect_landing_point(), given aim_dir and the dart's own
##     rope_length -- see the Task #30 note below) sits too close to the
##     dart's CURRENT position -- i.e. rope_dart.gd's own owner-relative
##     range_cap for this leg would immediately re-embed the dart within a
##     step or two of its existing anchor.
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
##
## Task #28 (now REMOVED, not just superseded -- see SWING_REDIRECT_FULL_
## CHARGE_RATIO's own comment above for why its exemption no longer applies)
## fixed a bug where a max-charge hold aimed at a dart already parked near
## rope_length still read as "pointless" and got wrongly force_holster()'d,
## because under the OLD charge-scales-DISTANCE model a max-charge hold's
## own REQUESTED range could itself converge on the dart's current position
## (both approaching the same rope_length ceiling), producing a near-zero
## predicted_travel purely as an artifact of the charge-scaled request, not
## a real "nowhere to go" situation.
##
## Task #30 fix/simplification: distance is no longer charge-scaled at all
## -- effective_range for the distance check below is now always the dart's
## own rope_length (the same full range every real redirect always targets),
## for every hold long enough to clear SWING_REDIRECT_PICKUP_HOLD_TIME. That
## means the Task #28 bug's root cause (a charge-DEPENDENT requested range
## converging on the dart's position) can no longer happen -- there is no
## more "short-hold-computed-a-smaller-request" case for a longer hold to be
## wrongly compared against. What remains is a fixed geometric fact
## independent of hold length: if the dart is already sitting at/near
## rope_length from the owner in very nearly the aimed direction, EVERY
## qualifying hold (any length >= SWING_REDIRECT_PICKUP_HOLD_TIME) predicts
## the same near-zero travel, and it's correct for all of them to fall
## through to a pickup-via-Recall rather than a redirect -- there's
## genuinely nowhere further to go, which is exactly what this whole
## function exists to detect. No charge-ratio exemption is needed to
## special-case a "should have been let through" hold, because there no
## longer is one: the geometric fact is the same regardless of how long the
## button was held.
func _redirect_is_pointless_micro_hop() -> bool:
	if _embedded_hold_time < SWING_REDIRECT_PICKUP_HOLD_TIME:
		return true
	if dart == null or not is_instance_valid(dart):
		return true
	var landing: Vector2 = dart.predict_redirect_landing_point(get_pos_2d(), aim_dir, dart.rope_length)
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
			if _redirect_is_pointless_micro_hop():
				# Task #29: was dart.force_holster() -- an instant, snap-like
				# teleport straight to HOLSTERED with no travel time. Direct
				# user report: "It might be when the hold is too short, it
				# should be retrieve instead of snap back in hand." A hold
				# that doesn't clear _redirect_is_pointless_micro_hop()'s bar
				# (threshold/geometry logic unchanged by this fix) should
				# read exactly like a quick-tap Recall -- a smooth pull
				# through RETURNING -- not a hard instant pickup.
				# begin_recall() already accepts EMBEDDED as a valid starting
				# state (checked at its own top), so this is a straight
				# call-site swap.
				dart.begin_recall()
			else:
				# Task #30: distance is no longer charge-scaled -- this leg
				# always targets the dart's own full owner-relative range
				# (begin_swing_redirect()'s default max_travel_distance <= 0.0
				# already resolves to rope_length, so nothing is passed for
				# it here). Hold duration instead scales SPEED, via
				# charge_ratio -- see _compute_redirect_charge_ratio()'s own
				# comment and rope_dart.gd's begin_swing_redirect()/
				# swing_speed_min_mult/swing_speed_max_mult for the receiving
				# side of this lerp.
				dart.begin_swing_redirect(aim_dir, -1.0, _compute_redirect_charge_ratio())
		else:
			dart.begin_recall()


func _get_melee_action_held() -> bool:
	## Physical Slash/Kick input signal (Face Button Secondary / E / right
	## mouse button / touch Slash button, per the GDD Controls section) --
	## humans/gamepad/touch only, same split as _get_action_held() above vs.
	## _get_throw_held()/_get_recall_held(): bots go through their own
	## get_desired_melee() AI decision in _get_melee_held() below instead of
	## this shared physical signal.
	if _uses_net_input():
		return _net_button(NET_BTN_MELEE)
	if _reads_primary_input():
		if _virtual_controls != null and _virtual_controls.get_slash_held():
			return true
		# Task #43 fix: same bug/fix shape as _get_action_held() above -- once
		# the touch overlay is active, don't also fall back to
		# Input.is_mouse_button_pressed(), since emulate_mouse_from_touch (the
		# project's unoverridden default) makes ANY touch read as a right
		# mouse-button press too. KEY_E is left in for the same
		# bluetooth-keyboard-on-touch-device reasoning as _get_action_held().
		if _virtual_controls != null:
			return Input.is_key_pressed(KEY_E)
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
	_fx(Fx.SLASH)
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
	_fx(Fx.KICK)
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
	Sfx.play_slash()


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
	Sfx.play_kick()


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


## Task #34: kill/death VFX on the KILLED player -- a particle burst at their
## own death position plus a brief screen shake on whichever camera the
## viewport is currently using (arena_camera.gd's own shake(), added this same
## task -- this was flagged as pending work early in this project's history
## and never built). Called from take_dart_hit() BEFORE that function
## overwrites global_position with spawn_pos, so get_pos_2d() here still reads
## the real death location, not the respawn point.
## Camera lookup is duck-typed (has_method("shake")) rather than a hard cast
## to ArenaCamera's own script type -- this project has no shared base
## class/interface for Camera3D scripts, and a duck-typed check is the same
## pattern already used throughout this file for the dart/bot_controller duck
## typing (see this file's own header comment).
func _trigger_kill_vfx(pos_2d: Vector2) -> void:
	_spawn_death_particles(pos_2d)
	var cam := get_viewport().get_camera_3d()
	if cam != null and cam.has_method("shake"):
		cam.shake(KILL_SHAKE_INTENSITY, KILL_SHAKE_DURATION)


## One-shot particle burst at a fixed world point, colored via this player's
## OWN player_color (the "who died" read) -- spawned as a sibling in the
## current scene, same "don't parent a one-shot VFX to something that will
## keep moving/teleporting after this call" reasoning rope_dart.gd's own
## _spawn_impact_sparks() uses (this player's own global_position is about to
## be overwritten to spawn_pos by take_dart_hit(), right after this call
## returns). Self-frees via a one-shot SceneTreeTimer, mirroring that same
## function's cleanup shape.
func _spawn_death_particles(pos_2d: Vector2) -> void:
	var particles := GPUParticles3D.new()
	particles.amount = 28
	particles.one_shot = true
	particles.explosiveness = 1.0
	particles.lifetime = 0.5
	particles.emitting = false
	var mesh := SphereMesh.new()
	mesh.radius = 0.09
	mesh.height = 0.18
	particles.draw_pass_1 = mesh
	var mat := ParticleProcessMaterial.new()
	mat.direction = Vector3(0.0, 1.0, 0.0)
	mat.spread = 180.0
	mat.gravity = Vector3(0.0, -9.0, 0.0)
	mat.initial_velocity_min = 2.5
	mat.initial_velocity_max = 6.0
	mat.scale_min = 0.6
	mat.scale_max = 1.3
	mat.color = player_color
	particles.process_material = mat
	get_tree().current_scene.add_child(particles)
	particles.global_position = Vector3(pos_2d.x, 1.0, pos_2d.y)
	particles.emitting = true
	get_tree().create_timer(particles.lifetime + 0.15).timeout.connect(particles.queue_free)


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
## Swinging, Returning"). Phase 5: this is now lives-gated rather than an
## unconditional respawn -- decrements `lives`; if any remain, teleports back
## to spawn_pos exactly as before (Phase 2's original minimal behavior,
## unchanged for that case -- see this task's own definition of done); once
## `lives` hits 0, the player is eliminated for the rest of the round instead
## (see _eliminate()), no teleport.
##
## Guarded on GameManager.current_state == PLAYING, same "only meaningful
## while the round is actually live" convention _check_boundary_fall() already
## uses -- without this, a dart still mid-flight/EMBEDDED into the brief
## ROUND_END pause (rope_dart.gd's own _physics_process is NOT itself
## state-gated -- only player.gd's input handlers are) could register a kill
## against a round that's already been decided.
##
## Task #10: the teleport alone used to leave the player's OWN dart (this
## player's persistent rope_dart.gd instance, referenced by `dart`) exactly
## wherever it was at the moment of death -- e.g. still EMBEDDED across the
## map, or mid-FLYING/RETURNING -- now completely disconnected from the
## player who just reappeared at spawn. global_position is set BEFORE
## _reset_movement_and_dart_state() so the dart's force_holster() snaps to
## the NEW spawn-local hand position, not the pre-death one.
func take_dart_hit() -> void:
	if is_dead or is_eliminated:
		return
	if GameManager.current_state != GameManager.RoundState.PLAYING:
		return
	is_dead = true
	_trip_timer = 0.0
	lives -= 1
	# Task #34: kill/lethal-hit SFX + a particle burst + brief screen shake --
	# fires HERE, before the teleport-to-spawn_pos below, so the burst spawns
	# at the actual death POSITION (this player's current global_position),
	# not the respawn point. Every take_dart_hit() call is a real lethal hit
	# (GDD Combat's "Dart Contact" section -- it always costs a life), whether
	# or not it happens to also result in full elimination this time, so this
	# fires unconditionally here rather than only inside the lives<=0 branch
	# below -- distinct from and stronger than apply_rope_trip()'s own much
	# smaller play_trip() cue (GDD Audio: "heavy impacts have stronger
	# feedback").
	_fx(Fx.KILL, get_pos_2d())
	if lives <= 0:
		_eliminate()
		return
	_invuln_timer = RESPAWN_INVULN_TIME
	global_position = spawn_pos
	_reset_movement_and_dart_state()


## Phase 5: `lives` reached 0 -- out for the rest of the round, no more
## respawn until the next reset_for_round() revives this player. Deliberately
## leaves `is_dead` == true (set by the caller, take_dart_hit(), before this
## runs) rather than adding a second flag every OTHER "skip dead players" call
## site would need to also check -- every existing is_dead == true guard
## (bot_controller.gd's target-skip/dodge, _perform_slash()/_perform_kick()'s
## own is_dead checks above) already correctly treats an eliminated player as
## untargetable with zero further changes. Hides the character model and
## disables collision (task's own "visual eliminated state" requirement) and
## stops processing input via _physics_process()/_process()'s own
## is_eliminated early-returns above, rather than doing that here.
func _eliminate() -> void:
	is_eliminated = true
	_invuln_timer = 0.0
	if player_mesh != null:
		player_mesh.visible = false
	if aim_indicator != null:
		aim_indicator.visible = false
	collision_shape.disabled = true
	_reset_movement_and_dart_state()
	# The dart is a sibling in the scene tree, not a child of this
	# CharacterBody3D (see the dart-instantiation comment in _ready()), so
	# hiding player_mesh above does nothing to it -- without this, an
	# eliminated player's dart is left floating visibly in place, holstered
	# at their now-invisible hand, for the rest of the round. Re-shown by
	# _reset_movement_and_dart_state() on the next reset_for_round() -- which is
	# also why this runs AFTER the reset call above, not before it.
	if dart != null and is_instance_valid(dart):
		dart.visible = false


## Called by rope_dart.gd's _check_player_hits() when the ROPE LINE (not the
## dart head) overlaps this player -- never lethal, just a brief movement
## debuff (GDD Combat: "Rope Contact ... trips and slows -- never lethal").
func apply_rope_trip() -> void:
	if is_dead or is_eliminated:
		return
	_trip_timer = TRIP_DURATION
	_fx(Fx.TRIP)


func _get_move_input() -> Vector2:
	if is_bot and bot_controller != null:
		# Bots reason entirely in world-space (to_target = target_pos - my_pos,
		# both already world XZ -- see bot_controller.gd's _physics_process),
		# so their output must NOT be rotated by the camera-relative offset
		# below; only raw human input (keyboard/gamepad/touch) needs it.
		return bot_controller.get_desired_move()
	if _uses_net_input():
		return _net_frame[0]
	if _reads_primary_input():
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


## Task #42 (touch control redesign, direct user request): the standalone
## touch aim stick is gone -- _virtual_controls no longer exposes get_aim()
## at all (see virtual_controls.gd's own header comment). Touch aim is now
## derived here instead:
##   - Default (not CHARGING, not holding-to-redirect): aim tracks wherever
##     the player is currently moving, falling back to _facing_dir (last real
##     movement direction) when the left stick is neutral -- exactly the
##     brief's "wherever they're currently facing/moving".
##   - While CHARGING (dart.state == HOLSTERED->CHARGING) or while holding to
##     redirect (dart.state == EMBEDDED with _embedded_hold_active) --
##     _movement_locked_now already zeroes the left stick's CONTRIBUTION TO
##     VELOCITY in _physics_process's velocity block, but leaves the raw
##     _get_move_input() reading itself untouched -- so re-reading that same
##     raw stick here for aim is free and matches the brief word-for-word:
##     "pinned in place, but the same stick now steers where you're aiming."
## Returning the raw stick reading (or _facing_dir when neutral) as THIS
## function's own result means the existing shared aim_dir update block in
## _physics_process (`if aim_input.length() > DEADZONE: aim_dir =
## aim_input.normalized() ...`) already does the right thing with zero
## further changes there -- that block, _get_mouse_aim(), and the gamepad
## branch below are all completely untouched by this.
func _get_aim_input() -> Vector2:
	if is_bot and bot_controller != null:
		# Same world-space reasoning as _get_move_input() above -- don't rotate.
		return bot_controller.get_desired_aim()
	if _uses_net_input():
		return _net_frame[1]
	if _reads_primary_input():
		if _virtual_controls != null:
			var raw_move: Vector2 = _get_move_input()
			return raw_move if raw_move.length() > DEADZONE else _facing_dir
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
		_fx(Fx.FALL)


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
	# Task #36: this ring-out respawn path (walking off the platform edge, a
	# separate/older path from take_dart_hit()'s dart-kill respawn) used to
	# only reset is_falling/global_position/collision_shape.disabled -- a
	# player whose dart was still FLYING/EMBEDDED/SWINGING/RETURNING
	# elsewhere on the map respawned here with it left exactly where it was,
	# completely disconnected from the player who just reappeared at spawn.
	# take_dart_hit()/reset_for_round() both already guard against this same
	# class of bug via this exact call, in this exact order (teleport to
	# spawn_pos FIRST, then reset, so force_holster() below reads the NEW
	# spawn-local hand position) -- see _reset_movement_and_dart_state()'s
	# own header comment.
	_reset_movement_and_dart_state()


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
	##
	## Phase 5: this is also the ONLY place `lives`/is_eliminated get reset
	## (take_dart_hit() only ever decrements/eliminates, never revives) --
	## called once per round by GameManager.start_round(), so an eliminated
	## player from the PREVIOUS round comes back with a full life count and
	## their model/collision restored for the new one. GameManager.lives_per_round
	## is read fresh here (not cached) so a mid-session config change would
	## take effect starting next round.
	if is_falling:
		is_falling = false
		_reset_fall_visual()
	spawn_pos = start_pos
	global_position = start_pos
	_net_target_pos = start_pos
	collision_shape.disabled = false
	is_dead = true  # cleared by the spawn-invuln countdown once it expires -- see RESPAWN_INVULN_TIME
	is_eliminated = false
	lives = GameManager.lives_per_round
	if player_mesh != null:
		player_mesh.visible = true
	if aim_indicator != null:
		aim_indicator.visible = true
	_invuln_timer = RESPAWN_INVULN_TIME
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
	_dash_speed = DASH_SPEED
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
		# Undoes _eliminate()'s dart.visible = false -- harmless no-op when
		# called from take_dart_hit() (mid-round respawn), where the dart was
		# never hidden in the first place; matters when called from
		# reset_for_round() reviving a player who was eliminated last round.
		dart.visible = true
