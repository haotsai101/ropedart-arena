extends Node
## Headless probe for Task #40: auto-generated guest username on first
## launch + the "edit username later" flow (see lobby.gd's
## _generate_guest_username() / _open_username_edit() /
## _add_username_subtitle_button() / _build_username_screen()'s is_editing
## branch / _input_username()).
##
## Mirrors test_username_keypad.gd's approach: drives the REAL lobby.tscn
## scene and fires real signals/callbacks (Button.pressed.emit(), the real
## text_changed path, the real custom keypad) rather than reimplementing the
## logic under test. UsernameManager is a persistent autoload (user://prefs.cfg)
## so this probe carefully saves/restores whatever username existed before it
## ran, exactly like test_username_keypad.gd's confirm-flow test does, to
## avoid clobbering a developer's real saved name on disk.
##
## IMPORTANT: every sub-test below is `await`-ed from _run() -- each sub-test
## itself uses `await get_tree().process_frame` internally, and calling an
## async function WITHOUT awaiting it at the call site only runs it up to its
## OWN first await before control returns, letting sub-tests race each other
## on the shared UsernameManager singleton. Keep every call below `await`-ed.
##
## Run this scene directly (F6 in the editor) any time lobby.gd's onboarding
## or username-edit flow changes.

var any_failure := false


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	var prev_username: String = UsernameManager.username

	await _test_fresh_launch_auto_generates()

	# Tests B-E reuse a SINGLE lobby instance (one real "open the app, edit
	# your name a couple of times" session) rather than each spinning up a
	# fresh lobby -- that keeps NetworkManager.fetch_rooms() (triggered once
	# per browser-screen build) from firing repeatedly in quick succession
	# across unrelated sub-tests, which isn't what's under test here.
	UsernameManager.save("TESTUSER1")
	var lobby_scene: PackedScene = load("res://scenes/lobby.tscn")
	var lobby = lobby_scene.instantiate()
	add_child(lobby)
	await get_tree().process_frame
	lobby._set_screen("browser")
	await get_tree().process_frame

	await _test_welcome_row_reopens_prefilled(lobby)
	await _test_confirm_via_line_edit_path(lobby)
	await _test_confirm_via_keypad_path(lobby)
	await _test_cancel_discards_changes(lobby)

	lobby.queue_free()
	await get_tree().process_frame

	# Restore whatever username (if any) existed before this probe ran.
	if prev_username != "":
		UsernameManager.save(prev_username)
	else:
		UsernameManager.username = ""

	print("[username onboarding test] %s" % ("ALL PASSED" if not any_failure else "FAILURES FOUND -- see above"))
	print("USERNAME_ONBOARDING_TEST_DONE")


## A: fresh launch (no saved username) skips straight to "browser" with an
## auto-generated placeholder name that passes the existing charset/length
## validation -- no typing required.
func _test_fresh_launch_auto_generates() -> void:
	var label := "A: fresh launch auto-generates a valid guest username and skips to browser"
	# Simulate "no saved username" WITHOUT touching disk -- UsernameManager
	# .has_username() only reads the in-memory `username` var.
	UsernameManager.username = ""

	var lobby_scene: PackedScene = load("res://scenes/lobby.tscn")
	var lobby = lobby_scene.instantiate()
	add_child(lobby)
	await get_tree().process_frame

	var screen_ok: bool = lobby._screen == "browser"
	var name_now: String = UsernameManager.username
	var regex := RegEx.new()
	regex.compile("^GUEST[0-9]{4}$")
	var format_ok: bool = regex.search(name_now) != null
	var len_ok: bool = name_now.length() >= 2 and name_now.length() <= 16

	if screen_ok and format_ok and len_ok:
		_pass(label, "screen=%s username=%s" % [lobby._screen, name_now])
	else:
		any_failure = true
		print("[username onboarding test] %s: FAIL -- screen=%s username='%s' (format_ok=%s len_ok=%s)" % [label, lobby._screen, name_now, format_ok, len_ok])

	lobby.queue_free()
	await get_tree().process_frame


## B: tapping the browser screen's "Welcome, X" row reopens the username
## screen pre-filled with the CURRENT username (native LineEdit path).
func _test_welcome_row_reopens_prefilled(lobby) -> void:
	var label := "B: Welcome row reopens username screen pre-filled with current name"

	# Find the tappable "Welcome, ... ✎" Button -- _add_username_subtitle_button()
	# adds it as a direct child of the lobby Control itself.
	var welcome_btn: Button = null
	for child in lobby.get_children():
		var btn := child as Button
		if btn != null and btn.text.begins_with("Welcome"):
			welcome_btn = btn
			break

	if welcome_btn == null:
		any_failure = true
		print("[username onboarding test] %s: FAIL -- no tappable 'Welcome, ...' Button found on browser screen" % label)
		return

	welcome_btn.pressed.emit()
	await get_tree().process_frame

	var screen_ok: bool = lobby._screen == "username"
	var typed_ok: bool = lobby._typed_username == "TESTUSER1"
	var line_edit_ok: bool = lobby._username_line_edit != null and lobby._username_line_edit.text == "TESTUSER1"

	if screen_ok and typed_ok and line_edit_ok:
		_pass(label, "_typed_username=%s line_edit.text=%s" % [lobby._typed_username, lobby._username_line_edit.text if lobby._username_line_edit != null else "<null>"])
	else:
		any_failure = true
		print("[username onboarding test] %s: FAIL -- screen=%s typed=%s line_edit_ok=%s" % [label, lobby._screen, lobby._typed_username, line_edit_ok])


## C: editing via the native LineEdit's text_changed path and confirming
## saves the new name and returns to the browser screen.
func _test_confirm_via_line_edit_path(lobby) -> void:
	var label := "C: LineEdit path types + confirms a new username"
	# lobby is left on the "username" screen (pre-filled "TESTUSER1") by test B.

	# Simulate real typing through the exact signal the native LineEdit fires.
	lobby._username_line_edit.text = "NEWNAME1"
	lobby._on_username_text_changed("NEWNAME1")
	lobby._try_confirm_username()
	await get_tree().process_frame

	var ok: bool = UsernameManager.username == "NEWNAME1" and lobby._screen == "browser"
	if ok:
		_pass(label, "UsernameManager.username=%s screen=%s" % [UsernameManager.username, lobby._screen])
	else:
		any_failure = true
		print("[username onboarding test] %s: FAIL -- username=%s screen=%s" % [label, UsernameManager.username, lobby._screen])


## D: editing via the custom on-screen keypad path and confirming saves the
## new name -- exercises the exact same touch fallback test_username_keypad.gd
## covers, but starting from a PRE-FILLED edit (not a blank first-time field).
func _test_confirm_via_keypad_path(lobby) -> void:
	var label := "D: custom keypad path types + confirms a new username from a pre-filled edit"

	lobby._open_username_edit()  # re-opens, pre-filled with "NEWNAME1" from test C
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

	# Clear the pre-filled text first (backspace x8 for "NEWNAME1"), then type
	# a fresh name -- proves the keypad path works starting from a non-empty
	# pre-filled edit, not just a blank field.
	for i in 8:
		var bs: Button = keys_by_label.get("⌫", null)
		if bs != null:
			bs.pressed.emit()
	for ch in "KEYNAME2":
		var btn: Button = keys_by_label.get(ch, null)
		if btn != null:
			btn.pressed.emit()

	lobby._try_confirm_username()
	await get_tree().process_frame

	var ok: bool = UsernameManager.username == "KEYNAME2" and lobby._screen == "browser"
	if ok:
		_pass(label, "UsernameManager.username=%s screen=%s" % [UsernameManager.username, lobby._screen])
	else:
		any_failure = true
		print("[username onboarding test] %s: FAIL -- username=%s screen=%s typed=%s" % [label, UsernameManager.username, lobby._screen, lobby._typed_username])

	keypad.queue_free()
	await get_tree().process_frame


## E: CANCEL (Esc) backs out to the browser screen WITHOUT saving whatever
## was typed -- no dead ends, and no accidental overwrite.
func _test_cancel_discards_changes(lobby) -> void:
	var label := "E: Esc/CANCEL discards in-progress edits and returns to browser"

	lobby._open_username_edit()  # re-opens, pre-filled with "KEYNAME2" from test D
	await get_tree().process_frame

	# Type something different but do NOT confirm.
	lobby._username_line_edit.text = "SHOULDNOTSAVE"
	lobby._on_username_text_changed("SHOULDNOTSAVE")

	# Simulate Esc through the real _input_username() handler.
	var esc_event := InputEventKey.new()
	esc_event.keycode = KEY_ESCAPE
	esc_event.pressed = true
	lobby._input_username(esc_event)
	await get_tree().process_frame

	var ok: bool = UsernameManager.username == "KEYNAME2" and lobby._screen == "browser"
	if ok:
		_pass(label, "UsernameManager.username=%s (unchanged) screen=%s" % [UsernameManager.username, lobby._screen])
	else:
		any_failure = true
		print("[username onboarding test] %s: FAIL -- username=%s screen=%s" % [label, UsernameManager.username, lobby._screen])


func _pass(label: String, detail: String = "") -> void:
	print("[username onboarding test] %s: PASS%s" % [label, (" -- " + detail) if detail != "" else ""])
