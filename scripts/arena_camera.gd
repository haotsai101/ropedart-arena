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

	var shake_offset := Vector3.ZERO
	if _shake_duration > 0.0:
		_shake_duration = maxf(_shake_duration - delta, 0.0)
		var falloff: float = _shake_duration / _shake_duration_total if _shake_duration_total > 0.0 else 0.0
		var mag: float = _shake_intensity * falloff
		shake_offset = Vector3(randf_range(-1.0, 1.0), 0.0, randf_range(-1.0, 1.0)) * mag
		if _shake_duration <= 0.0:
			_shake_intensity = 0.0
	global_position = _base_position + shake_offset
