extends Node
## Regression/verification test for Task #42 (touch control redesign, direct
## user request): right side collapses from [aim stick + Throw + Slash] to
## exactly THREE equal-sized buttons (Dash/Throw/Slash), the standalone touch
## aim stick is removed entirely, and touch aim_dir is instead derived from
## the SAME left movement stick -- tracking movement/facing by default, and
## (since CHARGING/holding-to-redirect already zero movement's CONTRIBUTION
## to velocity while leaving the raw stick reading intact) repurposed to
## drive aim/facing rotation during those pinned windows. See
## virtual_controls.gd's and player.gd's own header/_get_aim_input() comments
## for the actual mechanism this exercises.
##
## This does NOT rely on DisplayServer.is_touchscreen_available() (false in
## this sandboxed/desktop run) -- same bypass strategy test_username_keypad.gd
## already established for this project: instantiate the real touch-UI node
## directly and drive its real methods/handlers, rather than trying to spoof
## the OS-level touchscreen flag. virtual_controls.gd instances are built
## directly here and wired onto a player via `p._virtual_controls = vc`
## (bypassing player.gd's own is_touchscreen_available() gate in _ready()),
## so every check below exercises the REAL _handle_touch()/_handle_drag()/
## _get_move_input()/_get_aim_input() wiring, not a reimplementation of it.
##
## Run this scene directly (F6 in the editor) any time virtual_controls.gd or
## player.gd's touch-aim/movement-lock logic changes.

const VCScript := preload("res://scripts/virtual_controls.gd")

var any_failure := false


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	GameManager.current_state = GameManager.RoundState.PLAYING

	_test_no_aim_stick_three_equal_buttons()
	await _test_multi_touch_simultaneity()
	await _test_default_aim_tracks_movement()
	await _test_charging_pins_movement_rotates_aim()
	await _test_redirect_hold_pins_movement_rotates_aim()
	_test_desktop_mouse_aim_unaffected()

	print("[touch controls test] %s" % ("ALL PASSED" if not any_failure else "FAILURES FOUND -- see above"))
	print("TOUCH_CONTROLS_TEST_DONE")


func _fail(label: String, reason: String) -> void:
	any_failure = true
	print("[touch controls test] %s: FAIL -- %s" % [label, reason])


func _pass(label: String, detail: String = "") -> void:
	print("[touch controls test] %s: PASS%s" % [label, (" -- " + detail) if detail != "" else ""])


func _make_vc() -> Node:
	var vc: Node = VCScript.new()
	add_child(vc)
	return vc


func _make_player(pos: Vector3) -> Node:
	var scene: PackedScene = load("res://scenes/player.tscn")
	var p = scene.instantiate()
	add_child(p)
	p.global_position = pos
	p.spawn_pos = pos
	return p


func _touch(vc: Node, idx: int, pos: Vector2, pressed: bool) -> void:
	var e := InputEventScreenTouch.new()
	e.index = idx
	e.position = pos
	e.pressed = pressed
	vc._handle_touch(e)


func _drag(vc: Node, idx: int, pos: Vector2) -> void:
	var e := InputEventScreenDrag.new()
	e.index = idx
	e.position = pos
	vc._handle_drag(e)


## A: the right side is exactly three EQUAL-SIZED buttons, and the old
## standalone aim stick (get_aim()/_right_base/_right_knob_offset) is gone.
func _test_no_aim_stick_three_equal_buttons() -> void:
	var label := "A: right side is 3 equal buttons, no aim stick"
	var vc: Node = _make_vc()
	vc._update_layout()
	if vc.has_method("get_aim"):
		_fail(label, "get_aim() still exists on virtual_controls.gd")
		vc.queue_free()
		return
	if vc.get("_right_base") != null:
		_fail(label, "_right_base still exists on virtual_controls.gd")
		vc.queue_free()
		return
	# All three buttons must share one hit-radius: touching just inside
	# BUTTON_RADIUS + the existing 20px fudge on EACH of Throw/Slash/Dash
	# must register for all three -- proving they're the same size, not
	# independently-tuned radii like before this task.
	var ok := true
	var finger := 10
	# Probe each button along an axis pointing AWAY from its neighbors in the
	# triangle cluster (Throw is the bottom-right corner -> probe further
	# right; Slash sits left of Throw -> probe further left; Dash sits above
	# both -> probe further up) so the probe point can't accidentally land in
	# an adjacent button's own (radius+20) hit region instead.
	var checks := [
		["throw", vc._throw_center, Vector2(1.0, 0.0), func(): return vc.get_throw_held()],
		["slash", vc._slash_center, Vector2(-1.0, 0.0), func(): return vc.get_slash_held()],
		["dash", vc._dash_center, Vector2(0.0, -1.0), func(): return vc.get_dash_held()],
	]
	for entry in checks:
		var key: String = entry[0]
		var c: Vector2 = entry[1]
		var away_dir: Vector2 = entry[2]
		var getter: Callable = entry[3]
		var inside: Vector2 = c + away_dir * (VCScript.BUTTON_RADIUS + 15.0)
		_touch(vc, finger, inside, true)
		if not getter.call():
			ok = false
			_fail(label, "%s button did not register a touch at radius+15 (BUTTON_RADIUS=%.1f) -- not sharing the same hit-size as the others" % [key, VCScript.BUTTON_RADIUS])
		_touch(vc, finger, inside, false)
		finger += 1
	if ok:
		_pass(label, "get_aim()/_right_base gone; Throw/Slash/Dash all share BUTTON_RADIUS=%.1f" % VCScript.BUTTON_RADIUS)
	vc.queue_free()


## B: pressing Dash/Throw/Slash must work correctly WHILE the movement stick
## is simultaneously being held in a direction -- direct multi-touch check
## against the real per-finger tracking (Task #42's own "explicitly verify
## this multi-touch simultaneity actually works" requirement).
func _test_multi_touch_simultaneity() -> void:
	var label := "B: Dash/Throw/Slash work while movement stick is held"
	var vc: Node = _make_vc()
	await get_tree().process_frame

	var stick_pos: Vector2 = vc._left_base + Vector2(60.0, 0.0)
	_touch(vc, 0, stick_pos, true)  # finger 0: left stick
	var move_while_idle: Vector2 = vc.get_move()
	_touch(vc, 1, vc._throw_center, true)  # finger 1: Throw
	_touch(vc, 2, vc._dash_center, true)   # finger 2: Dash
	_touch(vc, 3, vc._slash_center, true)  # finger 3: Slash

	var ok := true
	if move_while_idle.length() < 0.3:
		ok = false
		_fail(label, "left stick did not register movement before the other 3 presses landed")
	if not vc.get_throw_held():
		ok = false
		_fail(label, "Throw did not register while the left stick was simultaneously held")
	if not vc.get_dash_held():
		ok = false
		_fail(label, "Dash did not register while the left stick was simultaneously held")
	if not vc.get_slash_held():
		ok = false
		_fail(label, "Slash did not register while the left stick was simultaneously held")
	var move_after: Vector2 = vc.get_move()
	if move_after.length() < 0.3:
		ok = false
		_fail(label, "left stick's own movement reading was disturbed by the other 3 simultaneous presses (move=%s)" % move_after)

	_touch(vc, 0, stick_pos, false)
	_touch(vc, 1, vc._throw_center, false)
	_touch(vc, 2, vc._dash_center, false)
	_touch(vc, 3, vc._slash_center, false)
	if ok:
		_pass(label, "move=%s while Throw/Dash/Slash all held simultaneously" % move_after)
	vc.queue_free()


## C: default state (not CHARGING, not holding-to-redirect) -- touch aim_dir
## tracks current movement direction, falling back to _facing_dir when the
## stick goes neutral.
func _test_default_aim_tracks_movement() -> void:
	var label := "C: default touch aim tracks movement direction"
	var p = _make_player(Vector3(0, 0.7, 0))
	var vc: Node = _make_vc()
	p._virtual_controls = vc
	await get_tree().physics_frame

	_touch(vc, 0, vc._left_base + Vector2(100.0, 0.0), true)
	await get_tree().physics_frame

	var expected_dir: Vector2 = p._get_move_input().normalized()
	var dot: float = expected_dir.dot(p.aim_dir)
	if dot < 0.99:
		_fail(label, "aim_dir=%s did not track move dir=%s (dot=%.3f)" % [p.aim_dir, expected_dir, dot])
	else:
		_pass(label, "aim_dir tracked move_input direction (dot=%.4f)" % dot)

	# Release the stick -- aim_dir should now hold at (match) _facing_dir,
	# the "falls back to _facing_dir when neutral" case.
	_touch(vc, 0, vc._left_base + Vector2(100.0, 0.0), false)
	await get_tree().physics_frame
	var dot2: float = p._facing_dir.dot(p.aim_dir)
	if dot2 < 0.99:
		_fail(label, "aim_dir did not fall back to _facing_dir once the stick went neutral (aim_dir=%s facing=%s)" % [p.aim_dir, p._facing_dir])
	else:
		_pass(label, "aim_dir fell back to _facing_dir once neutral (dot=%.4f)" % dot2)

	p.queue_free()
	vc.queue_free()


## D: holding Throw from HOLSTERED (CHARGING) pins movement -- the left
## stick's raw input is repurposed to rotate aim_dir instead.
func _test_charging_pins_movement_rotates_aim() -> void:
	var label := "D: holding Throw from Holstered (CHARGING) pins movement, stick rotates aim"
	var p = _make_player(Vector3(0, 0.7, 0))
	var vc: Node = _make_vc()
	p._virtual_controls = vc
	await get_tree().physics_frame

	_touch(vc, 0, vc._left_base + Vector2(100.0, 0.0), true)
	await get_tree().physics_frame
	p.dart.begin_charge()
	await get_tree().physics_frame
	if p.dart.state != p.DART_STATE_CHARGING:
		_fail(label, "dart never entered CHARGING")
		p.queue_free()
		vc.queue_free()
		return

	var pos_before: Vector3 = p.global_position
	_drag(vc, 0, vc._left_base + Vector2(0.0, -100.0))  # rotate stick mid-charge
	await get_tree().physics_frame
	await get_tree().physics_frame
	var pos_after: Vector3 = p.global_position
	var moved: float = Vector2(pos_after.x, pos_after.z).distance_to(Vector2(pos_before.x, pos_before.z))
	var expected_dir: Vector2 = p._get_move_input().normalized()
	var dot: float = expected_dir.dot(p.aim_dir)

	var ok := true
	if moved > 0.05:
		ok = false
		_fail(label, "player moved %.4f units while CHARGING -- movement should be fully pinned" % moved)
	if dot < 0.99:
		ok = false
		_fail(label, "aim_dir=%s did not rotate to the new stick direction=%s while CHARGING (dot=%.3f)" % [p.aim_dir, expected_dir, dot])
	if ok:
		_pass(label, "movement pinned (moved=%.4f), aim_dir rotated with stick (dot=%.4f)" % [moved, dot])

	_touch(vc, 0, vc._left_base, false)
	p.queue_free()
	vc.queue_free()


## E: holding Throw from EMBEDDED (holding-to-redirect) -- same pin +
## stick-drives-aim behavior as D, but from the other locked state.
func _test_redirect_hold_pins_movement_rotates_aim() -> void:
	var label := "E: holding Throw from Embedded (redirect charge) pins movement, stick rotates aim"
	var p = _make_player(Vector3(0, 0.7, 0))
	var vc: Node = _make_vc()
	p._virtual_controls = vc
	await get_tree().physics_frame

	p.aim_dir = Vector2(0, 1)
	p.dart.begin_charge()
	await get_tree().physics_frame
	p.dart.release_throw(Vector2(0, 1))

	var frames := 0
	var embedded := false
	while frames < 240:
		await get_tree().physics_frame
		frames += 1
		if p.dart.state == p.DART_STATE_EMBEDDED:
			embedded = true
			break
	if not embedded:
		_fail(label, "dart never reached EMBEDDED within timeout -- cannot test redirect-hold")
		p.queue_free()
		vc.queue_free()
		return

	_touch(vc, 0, vc._left_base + Vector2(100.0, 0.0), true)
	_touch(vc, 1, vc._throw_center, true)  # hold Throw from EMBEDDED
	await get_tree().physics_frame
	if not p._embedded_hold_active:
		_fail(label, "_embedded_hold_active never became true -- holding Throw from EMBEDDED isn't being tracked")
		_touch(vc, 0, vc._left_base, false)
		_touch(vc, 1, vc._throw_center, false)
		p.queue_free()
		vc.queue_free()
		return

	var pos_before: Vector3 = p.global_position
	_drag(vc, 0, vc._left_base + Vector2(-100.0, 0.0))  # rotate stick mid-hold
	await get_tree().physics_frame
	await get_tree().physics_frame
	var pos_after: Vector3 = p.global_position
	var moved: float = Vector2(pos_after.x, pos_after.z).distance_to(Vector2(pos_before.x, pos_before.z))
	var expected_dir: Vector2 = p._get_move_input().normalized()
	var dot: float = expected_dir.dot(p.aim_dir)

	var ok := true
	if moved > 0.05:
		ok = false
		_fail(label, "player moved %.4f units while holding to redirect from EMBEDDED -- movement should be fully pinned" % moved)
	if dot < 0.99:
		ok = false
		_fail(label, "aim_dir=%s did not rotate to the new stick direction=%s while holding to redirect (dot=%.3f)" % [p.aim_dir, expected_dir, dot])
	if ok:
		_pass(label, "movement pinned (moved=%.4f), aim_dir rotated with stick (dot=%.4f)" % [moved, dot])

	_touch(vc, 0, vc._left_base, false)
	_touch(vc, 1, vc._throw_center, false)
	p.queue_free()
	vc.queue_free()


## F: desktop mouse aim is completely unaffected -- with no virtual_controls
## instance attached (the normal non-touch case), _get_aim_input() must still
## delegate straight to the pre-existing _get_mouse_aim(), unchanged.
func _test_desktop_mouse_aim_unaffected() -> void:
	var label := "F: desktop mouse aim path unaffected (no virtual_controls)"
	var p = _make_player(Vector3(0, 0.7, 0))
	await get_tree().physics_frame
	var aim_via_fn: Vector2 = p._get_aim_input()
	var aim_via_mouse: Vector2 = p._get_mouse_aim()
	if aim_via_fn != aim_via_mouse:
		_fail(label, "_get_aim_input() returned %s but _get_mouse_aim() returned %s -- desktop mouse-aim path changed" % [aim_via_fn, aim_via_mouse])
	else:
		_pass(label, "_get_aim_input() still delegates straight to _get_mouse_aim() with no virtual_controls instance")
	p.queue_free()
	# Note: the gamepad aim branch (player_index >= 1, JOY_AXIS_RIGHT_X/Y) is
	# untouched by this task's diff -- no code path leading into it was
	# modified at all, only the player_index==0 touch branch inside the same
	# function -- so it's unaffected by construction, not just by omission.
	# A real controller isn't available in this headless environment to
	# additionally exercise it live.
