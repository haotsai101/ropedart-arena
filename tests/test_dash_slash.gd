extends Node
## Dash Slash test (headless, offline): drives the real player with injected
## Shift (dash) / E (slash) keys.
##   A: a plain slash misses a target 3.2 ahead (MELEE_RANGE is 1.8)
##   B: a dash slash toward the same target hits it -- the blade sweeps the
##      dash path instead of one instant check at the dash's start
##   C: the sweep doesn't reach a bystander 2.6 off to the side of the path
##   D: the dash slash lunges further than a plain dash (DASH_SLASH_EXTEND)
##   E: a plain slash that whiffs still starts the melee cooldown
##   F: dashing into another player never lifts either one off the floor
##      (capsule-on-capsule pushes used to stack players; with no gravity a
##      lifted player floated for good while its 2D hitbox stayed put)
##   G: a player dropped in overlapping another at floor level -- what the old
##      spawn did (every player added at the origin, y=0, then moved at round
##      start) -- must not end up stacked on top of it
##
## Run: Godot --headless --path . res://tests/test_dash_slash.tscn

var failures := 0


func _ready() -> void:
	call_deferred("_run")


func _check(label: String, ok: bool, detail: String) -> void:
	print("[dash slash test] %s: %s -- %s" % [label, "PASS" if ok else "FAIL", detail])
	if not ok:
		failures += 1


func _key(code: int, pressed: bool) -> void:
	var ev := InputEventKey.new()
	ev.keycode = code
	ev.physical_keycode = code
	ev.pressed = pressed
	Input.parse_input_event(ev)


func _frames(n: int) -> void:
	for i in n:
		await get_tree().physics_frame


## Injected keys only register at the next input flush, so a tap must be
## held across real time, not just one physics frame.
func _tap(code: int, hold: float = 0.12) -> void:
	_key(code, true)
	await get_tree().create_timer(hold).timeout
	_key(code, false)


func _player(pos: Vector3, index: int) -> Node:
	var p = (load("res://scenes/player.tscn") as PackedScene).instantiate()
	p.player_index = index  # index 0 reads the keyboard; others a (absent) gamepad
	p.position = pos  # BEFORE add_child: spawning at the origin first would overlap and shove the others
	add_child(p)
	p.spawn_pos = Vector3(40, 1, 40)
	return p


func _clear() -> void:
	for c in get_children():
		c.queue_free()
	for d in get_tree().get_nodes_in_group("players"):
		if is_instance_valid(d) and d.dart != null and is_instance_valid(d.dart):
			d.dart.queue_free()
	await _frames(2)


## Dash with S held (without a move key the dash would follow the mouse aim);
## S maps to _fwd() once the player's camera-yaw offset is applied.
## Optionally presses Slash right after the dash starts. Returns the distance
## travelled.
func _dash(me: Node, slash: bool) -> float:
	var start: Vector3 = me.global_position
	_key(KEY_S, true)
	_key(KEY_SHIFT, true)
	while not me._is_dashing:
		await get_tree().physics_frame
	_key(KEY_SHIFT, false)
	_key(KEY_S, false)
	if slash:
		await _tap(KEY_E)
	await get_tree().create_timer(0.6).timeout
	return Vector2(me.global_position.x - start.x, me.global_position.z - start.z).length()


## World position `fwd` units along the direction S dashes in, `side` units
## to its right (1 = player height above the floor).
func _along(me: Node, fwd: float, side: float) -> Vector3:
	var f: Vector2 = Vector2(0, 1).rotated(me._move_rotation_offset)  # set in the player's _ready
	var r: Vector2 = Vector2(-f.y, f.x)
	var p: Vector2 = f * fwd + r * side
	return Vector3(p.x, 1, p.y)


func _run() -> void:
	GameManager.current_state = GameManager.RoundState.PLAYING
	await _tap(KEY_F12)  # the first injected key event of a headless run can be lost

	# A
	var me = _player(Vector3(0, 1, 0), 0)
	var target = _player(_along(me, 3.2, 0.0), 3)
	await _frames(3)
	await _tap(KEY_E)
	_check("E whiff starts the cooldown", me._melee_cooldown_timer > 0.0, "cooldown %.2f" % me._melee_cooldown_timer)
	await _frames(3)
	_check("A plain slash out of range misses", target.lives == 3, "target lives %d" % target.lives)
	await _clear()

	# B + D
	me = _player(Vector3(0, 1, 0), 0)
	target = _player(_along(me, 3.2, 0.0), 3)
	await _frames(3)
	var dist_slash: float = await _dash(me, true)
	_check("B dash slash sweeps into the target", target.lives == 2, "target lives %d" % target.lives)
	await _clear()

	me = _player(Vector3(0, 1, 0), 0)
	await _frames(3)
	var dist_plain: float = await _dash(me, false)
	_check("D dash slash lunges further", dist_slash > dist_plain + 0.6,
		"dash slash %.2f vs plain dash %.2f" % [dist_slash, dist_plain])
	await _clear()

	# C
	me = _player(Vector3(0, 1, 0), 0)
	var bystander = _player(_along(me, 2.0, 2.6), 3)
	await _frames(3)
	await _dash(me, true)
	_check("C bystander off the path is safe", bystander.lives == 3, "bystander lives %d" % bystander.lives)

	await _clear()

	# F
	me = _player(Vector3(0, 1, 0), 0)
	var wall = _player(_along(me, 1.2, 0.15), 3)
	await _frames(3)
	var max_y := 0.0
	for i in 4:
		_key(KEY_S, true)
		_key(KEY_SHIFT, true)
		for f in 30:
			await get_tree().physics_frame
			max_y = maxf(max_y, maxf(me.global_position.y, wall.global_position.y))
		_key(KEY_SHIFT, false)
		_key(KEY_S, false)
		await get_tree().create_timer(0.3).timeout
	_check("F players stay on the floor", absf(max_y - GameManager.PLAYER_HALF_HEIGHT) < 0.01,
		"highest body y %.3f (floor %.1f)" % [max_y, GameManager.PLAYER_HALF_HEIGHT])

	await _clear()

	# G
	var a = _player(Vector3(0, 1, 0), 2)
	var b = _player(Vector3(0, 0, 0), 3)
	var top := 0.0
	for f in 30:
		await get_tree().physics_frame
		top = maxf(top, maxf(a.global_position.y, b.global_position.y))
	_check("G overlapping players stay on the floor", absf(top - GameManager.PLAYER_HALF_HEIGHT) < 0.01,
		"highest body y %.3f" % top)

	print("[dash slash test] %s" % ("ALL PASSED" if failures == 0 else "%d FAILED" % failures))
	get_tree().quit(1 if failures else 0)
