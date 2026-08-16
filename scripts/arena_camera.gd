extends Camera3D
## Dynamic orthographic camera. Pans and zooms to keep all alive players in frame.

@export var base_size: float = 14.0
@export var max_size: float = 26.0
@export var lerp_speed: float = 3.5
@export var margin: float = 4.5
@export var arena_clamp: float = 13.0

# Isometric offset from the ground look-at center.
# Computed from the initial camera transform in _ready().
var _offset: Vector3 = Vector3(0, 14, 12)

## Screen shake (Task #34 -- kill/death feedback, GDD Audio's "heavy impacts
## have stronger feedback" extended to VFX). _base_position is the camera's
## own real pan/zoom target position (the value _process()'s existing
## lerp-toward-target_pos logic used to write straight into global_position),
## tracked SEPARATELY from global_position so a shake offset can be layered on
## top of it every frame WITHOUT ever feeding back into the pan lerp itself --
## writing the shaken position directly into global_position and then reading
## it back next frame as the lerp's "current" value would let the shake's own
## random jitter permanently drift the camera's real pan target over
## consecutive shakes, which is not the intended effect (a shake should
## visibly settle back to exactly where the camera actually was panned/zoomed
## to, not to a randomly-drifted nearby point).
## _shake_duration counts down to 0; _shake_duration_total is the ORIGINAL
## requested duration (fixed for the life of one shake), used only to compute
## a 1.0->0.0 falloff ratio so the shake amplitude tapers out smoothly instead
## of cutting off abruptly at zero.
var _base_position: Vector3
var _shake_intensity: float = 0.0
var _shake_duration: float = 0.0
var _shake_duration_total: float = 0.0

## Touch/mobile follow camera (Task #45, direct user request). On a small
## phone screen, the AABB-fit-all-players logic in _process_desktop_fit_all()
## below shrinks the local player's own character whenever other
## players/bots are far apart, since the camera has to zoom OUT to keep
## everyone in frame -- that's exactly the complaint. On touch
## (DisplayServer.is_touchscreen_available()) we instead follow only the
## local human player (player_index == 0, this project's existing convention
## for "the local player" -- see hud.gd/virtual_controls.gd/player.gd itself)
## at a tight, mostly-fixed zoom, gated so desktop's existing behavior above
## is completely unaffected (additive branch, not a replacement).
##
## "Should not be completely centered on the character" (direct user
## request, deliberately open-ended -- this is this file's design call):
## rather than a rigid 1:1 center-lock, two techniques are combined --
##   1) A soft dead-zone: the camera's follow center only starts moving once
##      the player drifts touch_dead_zone world-units away from where the
##      camera is CURRENTLY centered, and then only catches up by the
##      overflow amount, not a snap-to. This means small wiggles/strafing
##      near the current center don't move the camera at all, while sustained
##      movement in one direction is still tracked -- a common
##      "camera lags slightly behind the player" feel.
##   2) A forward lead bias toward the player's current aim_dir, smoothly
##      lerped so it doesn't snap on every direction change. This gives a
##      mobile player a bit more visible space ahead of/where they're aiming
##      to throw, rather than equal framing on all sides regardless of facing.
## touch_size (9.0) is deliberately BELOW base_size (14.0) per the user's
## "closer to or below base_size" guidance -- tight enough that the character
## reads clearly larger on a small screen without needing to scale toward
## max_size for far-apart bots (touch mode never scales size by span at all).
@export var touch_size: float = 9.0
@export var touch_dead_zone: float = 2.0
@export var touch_aim_lead: float = 2.5
@export var touch_lead_lerp_speed: float = 2.5

var _touch_follow_center: Vector2 = Vector2.ZERO
var _touch_follow_initialized: bool = false
var _touch_lead_offset: Vector2 = Vector2.ZERO


func _ready() -> void:
	projection = PROJECTION_ORTHOGONAL
	size = base_size
	# Derive the ground look-at point and compute offset
	var fwd := -global_transform.basis.z
	if abs(fwd.y) > 0.001:
		var t := -global_position.y / fwd.y
		var ground_hit := global_position + fwd * t
		_offset = global_position - ground_hit
	else:
		_offset = Vector3(0, 14, 12)
	_base_position = global_position


## Public: request a brief screen shake. A shake already in progress is only
## ever made STRONGER/LONGER (maxf, not overwrite) -- so a rapid double-kill
## can't have its second, later shake() call cut the first one's remaining
## duration short.
func shake(intensity: float, duration: float) -> void:
	_shake_intensity = maxf(_shake_intensity, intensity)
	if duration > _shake_duration:
		_shake_duration = duration
		_shake_duration_total = duration


func _process(delta: float) -> void:
	# Task #45: touch/mobile gets a tight follow camera on the local player
	# instead of desktop's zoom-to-fit-everyone AABB. Gated on
	# DisplayServer.is_touchscreen_available() so desktop is unaffected --
	# _process_desktop_fit_all() below is the exact, unmodified pre-Task-#45
	# logic.
	if DisplayServer.is_touchscreen_available():
		_process_touch_follow(delta)
	else:
		_process_desktop_fit_all(delta)

	var shake_offset := Vector3.ZERO
	if _shake_duration > 0.0:
		_shake_duration = maxf(_shake_duration - delta, 0.0)
		var falloff: float = _shake_duration / _shake_duration_total if _shake_duration_total > 0.0 else 0.0
		var mag: float = _shake_intensity * falloff
		shake_offset = Vector3(randf_range(-1.0, 1.0), 0.0, randf_range(-1.0, 1.0)) * mag
		if _shake_duration <= 0.0:
			_shake_intensity = 0.0
	global_position = _base_position + shake_offset


## Desktop (and touch-unavailable) camera logic -- byte-for-byte the same
## behavior as before Task #45, just extracted into its own function so the
## new touch branch above can sit alongside it without touching this code.
func _process_desktop_fit_all(delta: float) -> void:
	## WEAPON/COMBAT SYSTEM REMOVED (branch remove-weapon-system): players no
	## longer have a lives/is_dead concept (see player.gd's own header
	## comment) and there are no rope darts left to fly out of frame -- every
	## player in the "players" group is simply always in-frame now.
	var active := get_tree().get_nodes_in_group("players")
	if active.is_empty():
		return

	var min_x := INF; var max_x := -INF
	var min_z := INF; var max_z := -INF
	for p in active:
		var pos: Vector2 = p.get_pos_2d()
		min_x = minf(min_x, pos.x); max_x = maxf(max_x, pos.x)
		min_z = minf(min_z, pos.y); max_z = maxf(max_z, pos.y)

	min_x = maxf(min_x - margin, -arena_clamp)
	max_x = minf(max_x + margin,  arena_clamp)
	min_z = maxf(min_z - margin, -arena_clamp)
	max_z = minf(max_z + margin,  arena_clamp)

	var cx: float = (min_x + max_x) * 0.5
	var cz: float = (min_z + max_z) * 0.5
	var span: float = maxf(max_x - min_x, max_z - min_z)

	var target_size: float = clamp(remap(span, 6.0, 24.0, base_size, max_size), base_size, max_size)
	size = lerpf(size, target_size, lerp_speed * delta)

	var target_pos: Vector3 = Vector3(cx, 0.0, cz) + _offset
	_base_position = _base_position.lerp(target_pos, lerp_speed * delta)


## Touch/mobile camera logic -- see the _touch_* var block's header comment
## above for the dead-zone + aim-lead design rationale.
func _process_touch_follow(delta: float) -> void:
	var local_player: Node = null
	for p in get_tree().get_nodes_in_group("players"):
		if p.player_index == 0 and not p.is_bot:
			local_player = p
			break
	if local_player == null:
		# No local human player found this frame (e.g. a pure-bot test scene)
		# -- leave the camera exactly where it already was rather than
		# snapping to origin.
		return

	var player_pos: Vector2 = local_player.get_pos_2d()
	if not _touch_follow_initialized:
		_touch_follow_center = player_pos
		_touch_follow_initialized = true

	# Dead-zone follow: only drag the follow center toward the player once
	# they've moved outside touch_dead_zone from where the camera is
	# currently centered, and then only by the overflow amount -- this is
	# what keeps the camera from being rigidly pixel-locked to the character
	# (see the var block's header comment).
	var to_player: Vector2 = player_pos - _touch_follow_center
	var dist: float = to_player.length()
	if dist > touch_dead_zone:
		_touch_follow_center += to_player.normalized() * (dist - touch_dead_zone)

	# Aim-direction lead: bias the framing slightly toward where the player
	# is currently facing/aiming, smoothly lerped so it doesn't snap on every
	# direction change.
	var aim: Vector2 = local_player.aim_dir
	if aim.length() < 0.01:
		aim = Vector2(0, 1)
	var lead_target: Vector2 = aim.normalized() * touch_aim_lead
	_touch_lead_offset = _touch_lead_offset.lerp(lead_target, touch_lead_lerp_speed * delta)

	var center: Vector2 = _touch_follow_center + _touch_lead_offset
	center.x = clamp(center.x, -arena_clamp, arena_clamp)
	center.y = clamp(center.y, -arena_clamp, arena_clamp)

	# Fixed tight zoom -- deliberately does NOT scale toward max_size for
	# far-apart players/bots the way the desktop AABB branch does; that
	# scaling-to-fit-everyone behavior is exactly what shrinks the character
	# on a phone screen in the first place.
	size = lerpf(size, touch_size, lerp_speed * delta)

	var target_pos: Vector3 = Vector3(center.x, 0.0, center.y) + _offset
	_base_position = _base_position.lerp(target_pos, lerp_speed * delta)
