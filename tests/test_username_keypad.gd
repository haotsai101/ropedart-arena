extends Node
## Headless probe for Task #39's iOS on-screen-keyboard fix: lobby.gd's custom
## touch keypad for the username screen (see lobby.gd's
## _build_username_custom_keyboard() / _make_keypad_key() /
## _custom_kb_key_pressed() / _custom_kb_backspace() /
## _apply_filtered_username()).
##
## This does NOT rely on DisplayServer.is_touchscreen_available() (false in
## this sandboxed/desktop run) to decide whether to build the keypad -- it
## calls _build_username_custom_keyboard() directly so the exact same Button
## grid a real iOS device would show gets built, then fires each Button's
## real `pressed` signal (btn.pressed.emit()) to simulate a finger tap,
## exactly like a real touch would trigger the same signal. This exercises
## the REAL wiring (Button -> callback -> _apply_filtered_username ->
## _typed_username), not a reimplementation of it.
##
## Run this scene directly (F6 in the editor) any time lobby.gd's username
## screen or custom keypad changes.

var any_failure := false


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	var lobby_scene: PackedScene = load("res://scenes/lobby.tscn")
	var lobby = lobby_scene.instantiate()
	add_child(lobby)
	await get_tree().process_frame

	# Force the username screen regardless of any persisted UsernameManager
	# state, mirroring a fresh install / first launch.
	lobby._typed_username = ""
	lobby._set_screen("username")
	await get_tree().process_frame

	var keypad: Control = lobby._build_username_custom_keyboard(1280.0, 720.0)
	add_child(keypad)
	await get_tree().process_frame

	var grid: GridContainer = keypad.get_child(0)
	var keys_by_label: Dictionary = {}
	for child in grid.get_children():
		var btn := child as Button
		if btn != null:
			keys_by_label[btn.text] = btn

	_test_types_username(lobby, keys_by_label)
	_test_backspace(lobby, keys_by_label)
	_test_max_length_truncation(lobby, keys_by_label)
	_test_confirm_flow(lobby, keys_by_label)

	keypad.queue_free()
	lobby.queue_free()

	print("[username keypad test] %s" % ("ALL PASSED" if not any_failure else "FAILURES FOUND -- see above"))
	print("USERNAME_KEYPAD_TEST_DONE")


func _tap(keys_by_label: Dictionary, label: String) -> void:
	var btn: Button = keys_by_label.get(label, null)
	if btn == null:
		any_failure = true
		print("[username keypad test] FAIL -- no keypad Button found for label '%s'" % label)
		return
	btn.pressed.emit()


func _test_types_username(lobby, keys_by_label: Dictionary) -> void:
	var label := "A: tapping P1_FOO types PLAYER1FOO"
	lobby._typed_username = ""
	for ch in "PLAYER1FOO":
		_tap(keys_by_label, ch)
	_check(label, lobby._typed_username, "PLAYER1FOO")


func _test_backspace(lobby, keys_by_label: Dictionary) -> void:
	var label := "B: backspace removes last character"
	lobby._typed_username = ""
	for ch in "ABC":
		_tap(keys_by_label, ch)
	_tap(keys_by_label, "⌫")
	_check(label, lobby._typed_username, "AB")

	# Backspace on empty string must not error or go negative.
	lobby._typed_username = ""
	_tap(keys_by_label, "⌫")
	_check(label + " (on empty)", lobby._typed_username, "")


func _test_max_length_truncation(lobby, keys_by_label: Dictionary) -> void:
	var label := "C: 20 taps truncate to 16 chars (max_length)"
	lobby._typed_username = ""
	for i in 20:
		_tap(keys_by_label, "A")
	_check(label, lobby._typed_username, "AAAAAAAAAAAAAAAA")  # 16 A's
	if lobby._typed_username.length() != 16:
		any_failure = true
		print("[username keypad test] %s: FAIL -- length=%d, expected 16" % [label, lobby._typed_username.length()])
	else:
		_pass(label)


func _test_confirm_flow(lobby, keys_by_label: Dictionary) -> void:
	## Confirms the keypad's output routes through the SAME confirm path a
	## real Enter/CONTINUE press uses (_try_confirm_username -> UsernameManager
	## .save()), not a parallel/duplicated one.
	var label := "D: keypad-typed name reaches UsernameManager.save() via _try_confirm_username()"
	lobby._typed_username = ""
	for ch in "TESTER1":
		_tap(keys_by_label, ch)
	var prev_username: String = UsernameManager.username
	lobby._try_confirm_username()
	var ok: bool = UsernameManager.username == "TESTER1"
	if ok:
		_pass(label, "UsernameManager.username=%s" % UsernameManager.username)
	else:
		any_failure = true
		print("[username keypad test] %s: FAIL -- UsernameManager.username=%s, expected TESTER1" % [label, UsernameManager.username])
	# Restore whatever username (if any) existed before this test so the
	# probe doesn't clobber a developer's real saved username on disk.
	UsernameManager.save(prev_username)


func _check(label: String, actual: String, expected: String) -> void:
	if actual == expected:
		_pass(label, "got '%s'" % actual)
	else:
		any_failure = true
		print("[username keypad test] %s: FAIL -- got '%s', expected '%s'" % [label, actual, expected])


func _pass(label: String, detail: String = "") -> void:
	print("[username keypad test] %s: PASS%s" % [label, (" -- " + detail) if detail != "" else ""])
