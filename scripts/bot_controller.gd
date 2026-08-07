extends Node
## AI bot controller. Attach as child "BotController" under a Player node.
## Drives the player by feeding desired move/aim/throw inputs each frame.

enum Difficulty { EASY = 0, MEDIUM = 1, HARD = 2 }
enum BotState { CHASE, AIM, RETREAT }

@export var difficulty: int = Difficulty.EASY

## Task #31: mirrors rope_dart.gd's real State enum ordinals (HOLSTERED=0,
## CHARGING=1, FLYING=2, EMBEDDED=3, SWINGING=4, RETURNING=5), cross-checked
## against player.gd's own DART_STATE_* consts (which mirror the same enum
## by hand for the same duck-typing reason) rather than assumed. The old
## DART_STATE_FLYING=0 here was a stale leftover from the pre-rebuild deleted
## Dagger enum -- harmless while _get_dodge_dir() read the dead "darts" group
## (see that function's own header comment, superseded below), but wrong
## against the CURRENT rope_dart.gd (FLYING is ordinal 2, not 0) and would
## have silently never matched anything once dodge started reading real dart
## state. Used below to tell "dart in hand" apart from "dart away".
const DART_STATE_HOLSTERED = 0
const DART_STATE_FLYING = 2
const DART_STATE_EMBEDDED = 3
const DART_STATE_SWINGING = 4
const DART_STATE_RETURNING = 5

const THROW_RANGE   := [4.0, 5.5, 7.0]
const AIM_DURATION  := [1.4, 0.7, 0.25]
const AIM_NOISE_DEG := [35.0, 15.0, 3.0]
const RETREAT_TIME  := [1.2, 0.9, 0.6]
const SPEED_MULT    := [0.65, 0.85, 1.0]

## Task #32: Hard-bot swing-redirect. Per docs/implementation-plan.md's
## Phase 6 note ("Hard bots attempt redirects, Easy/Medium don't -- flag as a
## judgment call"), only Difficulty.HARD ever triggers this.
##
## player.gd's _handle_dart_away_input() disambiguates the shared Throw/
## Recall/Redirect button purely by hold DURATION while dart.state ==
## EMBEDDED: a quick tap (button false again before
## SWING_REDIRECT_HOLD_THRESHOLD, 0.25s) is Recall; a sustained hold that
## clears SWING_REDIRECT_PICKUP_HOLD_TIME (0.4s) before release is Redirect
## (anything held past the 0.25s threshold but short of 0.4s resolves to a
## "pointless micro-hop" recall instead -- see that function's own comment).
## A bot's normal get_desired_recall() is a ONE-SHOT pulse (true for exactly
## one tick, then consumed) specifically so it always reads as a tap -- see
## that function's own header comment -- so it can never clear either
## threshold on its own. REDIRECT_HOLD_DURATION is simulated separately (see
## _redirect_hold_active below) and picked to clear BOTH thresholds with a
## real margin (0.1s / 6 physics ticks past the 0.4s floor, well past the
## 0.25s tap boundary) without going all the way to player.gd's own 0.6s
## max-charge ceiling (SWING_REDIRECT_MAX_CHARGE_TIME) -- charge_ratio for
## this hold works out to 0.5 / 0.6 ~= 0.83, a strong, decisive redirect
## speed without needing to tune a full max-charge hold on every attempt.
const REDIRECT_HOLD_DURATION: float = 0.5

# Ring-out safety: must match player.gd's ARENA_HALF. Bots stop steering
# further outward once within EDGE_MARGIN of the platform edge (dodge/retreat
# can otherwise pick a direction that walks them straight off the boundary).
const ARENA_HALF: float = 15.0
const EDGE_MARGIN: float = 1.5

# Must match player.gd's MELEE_RANGE (this file has no static access to that
# script's consts across the duck-typed `player` reference used elsewhere
# here -- same hand-mirroring convention already used for DART_STATE_* above).
const MELEE_RANGE: float = 1.4
## Must roughly match player.gd's own MELEE_COOLDOWN -- how often a bot
## re-pulses get_desired_melee() while a target stays in range. Doesn't need
## to match exactly (player.gd's own cooldown is the real gate that decides
## whether a given pulse actually lands), just needs to be >= it so this
## file isn't setting _melee_pending true on ticks player.gd would silently
## drop anyway.
const MELEE_ATTACK_INTERVAL: float = 0.4

var player  # untyped for duck-typed access to player_index, get_pos_2d(), dart, etc.
var _state: int = BotState.CHASE
var _timer: float = 0.0
var _desired_move: Vector2 = Vector2.ZERO
var _desired_aim: Vector2 = Vector2(0.0, 1.0)
var _throw_pending: bool = false
var _recall_pending: bool = false
var _dash_pending: bool = false
var _melee_pending: bool = false  # one-shot pulse, same contract as _throw_pending et al.
var _melee_cooldown_timer: float = 0.0
var _dodge_dir: Vector2 = Vector2.ZERO  # committed dodge direction; reset when threat clears
## Task #32: true while this (Hard-only) bot is simulating a sustained
## button hold to trigger a swing-redirect -- see REDIRECT_HOLD_DURATION's
## own header comment for the whole mechanism this drives. Read directly by
## get_desired_recall() below (returns true every tick this stays active,
## unlike the one-shot _recall_pending pulse), and ticked down once per
## physics frame in _physics_process(), which also re-aims at the live
## target and fully owns the tick (skips melee/dodge/the CHASE-AIM-RETREAT
## state machine) for as long as this stays true -- mirrors a real player's
## own full movement lock while holding to redirect (docs/project.md:
## "movement is restricted during committed dart actions").
var _redirect_hold_active: bool = false
var _redirect_hold_timer: float = 0.0
## Task #23: AIM's own aim-imperfection offset, rolled ONCE when entering
## BotState.AIM (see the CHASE->AIM transition below) and held fixed for the
## whole AIM_DURATION window, rather than re-rolled from scratch every single
## physics tick. Confirmed by a headless probe driving a real bot_controller
## through CHASE->AIM against a stationary target and sampling
## owner_player.aim_dir every physics tick: the old per-tick reroll (fresh
## randf_range(-1,1)*AIM_NOISE_DEG every tick, snapped straight into
## _desired_aim/aim_dir with no smoothing) produced a real angle delta EVERY
## SINGLE TICK for the whole sustained AIM window (non-zero every tick, not
## just a one-time settle) -- exactly the visible dart spin/jitter reported:
## rope_dart.gd's _process() tracks owner_player.aim_dir live every frame
## while HOLSTERED/CHARGING, so a re-randomized aim_dir each tick reads as
## the held dart spinning in the bot's hand. With this fix, the same probe
## shows a per-tick angle delta of 0.0000 deg for the rest of a sustained AIM
## window (after the state settles) -- rolling once per AIM cycle keeps the
## intentional aim-imperfection (still fully in play at throw time) but the
## noise itself no longer changes tick-to-tick.
var _aim_noise: float = 0.0


func _ready() -> void:
	player = get_parent()
	player.bot_controller = self
	_timer = randf_range(0.2, 1.2)  # stagger initial activation


func get_desired_move() -> Vector2:
	return _desired_move

func get_desired_aim() -> Vector2:
	return _desired_aim

func get_desired_throw() -> bool:
	if _throw_pending:
		_throw_pending = false
		return true
	return false

func get_desired_dash() -> bool:
	if _dash_pending:
		_dash_pending = false
		return true
	return false

## Two different contracts depending on what this bot is currently doing,
## both consumed by the SAME call site (player.gd's _get_recall_held(), one
## level up from _handle_dart_away_input()'s hold-duration tracking):
##  - Plain recall: one-shot "pulse, not held", same contract as
##    get_desired_throw() above -- player.gd's _handle_dart_away_input()
##    only needs a press-then-release-next-tick to read as a tap and call
##    rope_dart.gd's begin_recall(), same as _handle_throw_input() does for
##    begin_charge()/release_throw().
##  - Task #32 redirect-hold: while _redirect_hold_active is true (see its
##    own header comment), this returns true continuously, tick after tick,
##    for as long as that flag stays set -- a genuine sustained "held" signal
##    rather than a pulse. _physics_process() flips the flag back to false
##    on the tick the simulated hold should end, so the very next call here
##    naturally reads as the falling edge (button released) player.gd's own
##    hold-then-release gesture detection needs, with no separate "release"
##    signal required.
func get_desired_recall() -> bool:
	if _redirect_hold_active:
		return true
	if _recall_pending:
		_recall_pending = false
		return true
	return false

## Same one-shot "pulse, not held" contract as get_desired_throw()/
## get_desired_recall() above -- player.gd's _handle_melee_input() edge-
## detects this the same way it edge-detects a human's button press, so a
## bot re-pulses this (see MELEE_ATTACK_INTERVAL) rather than holding it
## continuously true, which would only ever land ONE hit (no repeat rising
## edge while already-true). Slash vs. Kick isn't decided here at all --
## player.gd's own dart.state check at the moment this pulse is consumed
## resolves that, exactly like a human pressing the same physical button.
func get_desired_melee() -> bool:
	if _melee_pending:
		_melee_pending = false
		return true
	return false


func _physics_process(delta: float) -> void:
	if GameManager.current_state != GameManager.RoundState.PLAYING:
		_desired_move = Vector2.ZERO
		return
	# player.gd has no is_dead concept yet (removed in the weapon-system
	# strip-down, not yet restored -- see player.gd's own header comment).
	# Null-safe duck-typed read so a human-controlled test with any bots in
	# the match doesn't crash; once Phase 2 adds is_dead back this reads it
	# exactly as before with no further change needed here.
	if player.get("is_dead") == true:
		_desired_move = Vector2.ZERO
		return

	if _melee_cooldown_timer > 0.0:
		_melee_cooldown_timer -= delta

	var target = _find_target()
	if target == null:
		_desired_move = Vector2.ZERO
		return

	var my_pos: Vector2 = player.get_pos_2d()
	var target_pos: Vector2 = target.get_pos_2d()
	var to_target: Vector2 = target_pos - my_pos
	var dist: float = to_target.length()
	var dir: Vector2 = to_target.normalized() if dist > 0.01 else Vector2.ZERO

	_timer -= delta

	# Task #32: a redirect-hold in progress fully owns this and every
	# subsequent tick until it releases -- see _redirect_hold_active's own
	# header comment for why (mirrors a real player's full movement lock
	# while holding to redirect). Keep re-aiming at the target's live
	# position every tick (same target-direction logic BotState.AIM already
	# uses below) so the eventual release throws toward where the target
	# actually is, not a stale snapshot from the tick the hold started.
	# get_desired_recall() reads _redirect_hold_active directly and returns
	# true every tick this stays active; flipping it false here on the
	# release tick is what produces the falling edge player.gd's
	# _handle_dart_away_input() needs to resolve the sustained hold into an
	# actual Redirect instead of a tap Recall.
	if _redirect_hold_active:
		_redirect_hold_timer -= delta
		_desired_move = Vector2.ZERO
		_desired_aim = dir
		if _redirect_hold_timer <= 0.0:
			_redirect_hold_active = false
			# Back to RETREAT (not CHASE): the dart just landed at a fresh
			# EMBEDDED anchor via the redirect leg that just completed, so
			# the SAME RETREAT-exit decision below (chain another redirect
			# vs. fall back to a plain recall) is exactly what should
			# re-evaluate next, based on whatever the game state actually
			# looks like once this new RETREAT_TIME window elapses --
			# mirrors the GDD's own "chainable: hold+release again redirects
			# into another swing" framing for a human player. Landing this
			# in CHASE instead would strand the bot: CHASE only ever moves
			# toward dart_in_hand, and nothing here recalls the dart on its
			# own outside of RETREAT's own exit branch -- the bot would just
			# walk around with an embedded dart forever, never attacking
			# again.
			_state = BotState.RETREAT
			_timer = RETREAT_TIME[difficulty]
		return

	# Opportunistic melee: threaten a kill at melee range whenever the target
	# is close enough, regardless of CHASE/AIM/RETREAT state -- mirrors how
	# dart-dodging overrides the state machine below. This fires the SAME
	# pulse whether the target still has their dart holstered (this bot's own
	# Slash -- kill) or has thrown it away (this bot's own Kick -- knockback
	# only): the resolution is entirely player.gd's job (its own dart.state
	# check in _handle_melee_input(), reading THIS bot's own dart, not the
	# target's), so the bot doesn't need to know or care which one it'll end
	# up being before pulsing.
	if dist <= MELEE_RANGE and _melee_cooldown_timer <= 0.0:
		_melee_pending = true
		_melee_cooldown_timer = MELEE_ATTACK_INTERVAL

	# Dodge incoming darts (medium and hard bots only)
	if difficulty >= Difficulty.MEDIUM:
		var dodge := _get_dodge_dir(my_pos)
		if dodge != Vector2.ZERO:
			_set_desired_move(my_pos, dodge * SPEED_MULT[difficulty])
			_desired_aim = dir
			return

	# "Dart in hand" now means dart.state == HOLSTERED, not dart == null --
	# see DART_STATE_HOLSTERED's comment above. player.dart itself is never
	# null once player.gd's _ready() has run (persistent instance), but the
	# null check is kept as a defensive guard in case this runs before that.
	var dart_in_hand: bool = player.dart == null or player.dart.state == DART_STATE_HOLSTERED

	match _state:
		BotState.CHASE:
			_desired_aim = dir
			if not dart_in_hand or dist > THROW_RANGE[difficulty]:
				_set_desired_move(my_pos, dir * SPEED_MULT[difficulty])
			else:
				_desired_move = Vector2.ZERO
				_state = BotState.AIM
				_timer = AIM_DURATION[difficulty]
				# Roll the aim-imperfection offset once per AIM cycle -- see
				# _aim_noise's own header comment for why this moved out of
				# the per-tick branch below.
				_aim_noise = randf_range(-1.0, 1.0) * deg_to_rad(AIM_NOISE_DEG[difficulty])

		BotState.AIM:
			_desired_move = Vector2.ZERO
			_desired_aim = Vector2.from_angle(dir.angle() + _aim_noise)
			if _timer <= 0.0:
				if dart_in_hand:
					_throw_pending = true
				_state = BotState.RETREAT
				_timer = RETREAT_TIME[difficulty]

		BotState.RETREAT:
			_set_desired_move(my_pos, -_desired_aim * SPEED_MULT[difficulty])
			if _timer <= 0.0:
				# Task #32: Hard bots with an EMBEDDED dart and a live target
				# still in range prefer redirecting straight at the target
				# over the plain recall-then-rethrow cycle below -- swinging
				# from an existing anchor is faster/more aggressive than a
				# full recall-recharge-rethrow loop (per this task's own
				# framing). THROW_RANGE[difficulty] reuses the same
				# per-difficulty range tuning CHASE already uses to decide
				# "close enough to throw" -- no point committing a hold-based
				# gesture at a target so far the redirect leg (which always
				# targets the dart's full rope_length, see player.gd's
				# _compute_redirect_charge_ratio()/Task #30 comment) couldn't
				# meaningfully close on anyway. Easy/Medium never take this
				# branch (difficulty check below), matching the plan's
				# original Hard-only suggestion -- they always fall through
				# to the pre-existing plain recall pulse, unchanged.
				var dart_embedded: bool = player.dart != null and is_instance_valid(player.dart) and player.dart.state == DART_STATE_EMBEDDED
				if difficulty == Difficulty.HARD and dart_embedded and dist <= THROW_RANGE[difficulty]:
					_redirect_hold_active = true
					_redirect_hold_timer = REDIRECT_HOLD_DURATION
					_desired_aim = dir
					_desired_move = Vector2.ZERO
				else:
					# Recall the dart before going back to chase, mirroring how
					# a human player uses Recall after a miss (GDD Combat:
					# "Throw -> Miss -> Recall through enemies").
					# get_desired_recall()'s pulse is consumed by player.gd's
					# _handle_recall_input(), which only acts on it while the
					# dart is FLYING/EMBEDDED -- harmless no-op otherwise (dart
					# already back in hand).
					_recall_pending = true
					_state = BotState.CHASE


func _set_desired_move(pos: Vector2, move: Vector2) -> void:
	## Clamp outward movement once near the platform edge so dodge/retreat
	## steering can't walk a bot off the ring-out boundary. Only zeroes the
	## component pushing further out; doesn't attempt to steer back inward.
	var result: Vector2 = move
	if pos.x > ARENA_HALF - EDGE_MARGIN and result.x > 0.0:
		result.x = 0.0
	elif pos.x < -(ARENA_HALF - EDGE_MARGIN) and result.x < 0.0:
		result.x = 0.0
	if pos.y > ARENA_HALF - EDGE_MARGIN and result.y > 0.0:
		result.y = 0.0
	elif pos.y < -(ARENA_HALF - EDGE_MARGIN) and result.y < 0.0:
		result.y = 0.0
	_desired_move = result


func _find_target():  # returns untyped player node for duck-typed access
	var closest = null
	var best_dist := INF
	for p in get_tree().get_nodes_in_group("players"):
		if p == player:
			continue
		# Same null-safe duck-typed read as _physics_process() above -- lives
		# doesn't exist on player.gd yet either.
		if p.get("is_dead") == true:
			continue
		var p_lives = p.get("lives")
		if p_lives != null and p_lives <= 0:
			continue
		var d: float = player.get_pos_2d().distance_to(p.get_pos_2d())
		if d < best_dist:
			best_dist = d
			closest = p
	return closest


## Task #31 rewrite: the old version iterated get_tree().get_nodes_in_group
## ("darts"), which rope_dart.gd deliberately never joins (see that file's
## own header comment) -- a permanent no-op, not a real dodge. Real threats
## now come from every OTHER player's own persistent `dart` reference
## (player.gd's `dart` field, never null once that player's _ready() has run
## -- same pattern _find_target() already uses to walk the "players" group).
##
## Per this task's own correction to docs/implementation-plan.md's Phase 6
## framing: EMBEDDED is deliberately NOT treated as a threat here (a
## stationary anchored dart is non-lethal to touch, docs/project.md's Combat
## "Dart Contact" section) -- only FLYING, SWINGING, and RETURNING are real,
## contact-lethal threats worth committing a dodge to. dart.pos_2d/dir_2d
## (rope_dart.gd's real fields) stand in for the old dead code's
## head_2d/dir_2d -- rope_dart.gd never exposed head_2d at all, pos_2d is the
## dart's actual gameplay position (dart-contact hit detection itself
## measures against pos_2d, see rope_dart.gd's _check_player_hits()).
func _get_dodge_dir(my_pos: Vector2) -> Vector2:
	for p in get_tree().get_nodes_in_group("players"):
		if p == player:
			continue
		var threat_dart = p.get("dart")
		if threat_dart == null or not is_instance_valid(threat_dart):
			continue
		var threat_state: int = threat_dart.state
		if threat_state != DART_STATE_FLYING and threat_state != DART_STATE_SWINGING and threat_state != DART_STATE_RETURNING:
			continue
		var dart_pos: Vector2 = threat_dart.pos_2d
		var dart_dir: Vector2 = threat_dart.dir_2d
		var to_me: Vector2 = my_pos - dart_pos
		if to_me.length() > 8.0:
			continue
		if dart_dir.dot(to_me.normalized()) > cos(deg_to_rad(40.0)):
			# Commit to a side on first detection; keep it until the threat clears
			if _dodge_dir == Vector2.ZERO:
				var side: float = 1.0 if randf() > 0.5 else -1.0
				_dodge_dir = dart_dir.rotated(PI * 0.5 * side)
				_dash_pending = true  # burst out of the way instead of just sidestepping
			return _dodge_dir
	_dodge_dir = Vector2.ZERO  # no threat — reset so next dart picks fresh side
	return Vector2.ZERO
