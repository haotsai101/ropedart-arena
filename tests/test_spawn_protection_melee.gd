extends Node
## Regression test for the spawn-protection / melee-range / eliminated-dart
## tuning pass:
##   - RESPAWN_INVULN_TIME (1.2s) now also applies at round start via
##     reset_for_round(), not only after a mid-round take_dart_hit() respawn,
##     and the player is unmovable (not just untargetable) for that window.
##   - MELEE_RANGE widened 1.4 -> 1.8 (mirrored in bot_controller.gd).
##   - An eliminated player's dart (a scene-tree sibling, not a child) is
##     hidden on _eliminate() and re-shown by the next reset_for_round().
##   - A network-controlled player's invuln window still expires (it early-
##     returns out of _physics_process() before local input is read).
##
## Drives player.gd's real _physics_process through the actual scene tree,
## same approach as test_dart_phase2_combat.gd. Run this scene directly (F6)
## any time the respawn/melee/elimination code in player.gd changes.

const SETTLE_FRAMES: int = 90  ## 1.5s at 60fps -- comfortably > RESPAWN_INVULN_TIME

var any_failure := false


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	GameManager.current_state = GameManager.RoundState.PLAYING

	await _test_round_start_protection()
	await _test_midround_respawn_protection()
	await _test_melee_range()
	await _test_eliminated_dart_hidden_then_restored()
	await _test_network_controlled_invuln_expires()
	_test_bot_melee_range_mirrors_player()

	print("[spawn protection test] %s" % ("ALL PASSED" if not any_failure else "FAILURES FOUND -- see above"))
	print("SPAWN_PROTECTION_TEST_DONE")
	get_tree().quit(1 if any_failure else 0)


func _make_player(pos: Vector3) -> Node:
	var scene: PackedScene = load("res://scenes/player.tscn")
	var p = scene.instantiate()
	add_child(p)
	p.global_position = pos
	p.spawn_pos = pos
	return p


func _frames(n: int) -> void:
	for i in n:
		await get_tree().physics_frame


func _fail(label: String, reason: String) -> void:
	any_failure = true
	print("[spawn protection test] %s: FAIL -- %s" % [label, reason])


func _pass(label: String, detail: String = "") -> void:
	print("[spawn protection test] %s: PASS%s" % [label, (" -- " + detail) if detail != "" else ""])


## A: right after reset_for_round() the player is untargetable (dart hit and
## kick both ignored) and unmovable (injected knockback doesn't displace
## them); once the window expires they're hittable again.
func _test_round_start_protection() -> void:
	var label := "A: round-start spawn protection"
	var p = _make_player(Vector3(0, 0.7, 0))
	p.reset_for_round(Vector3(0, 0.7, 0))
	await _frames(2)
	if not p.is_dead:
		_fail(label, "is_dead should be true right after reset_for_round()")
		p.queue_free()
		return
	var lives_before: int = p.lives
	p.take_dart_hit()
	if p.lives != lives_before:
		_fail(label, "take_dart_hit() cost a life during spawn protection")
	# Unmovable: force a knockback directly (apply_kick_knockback() itself is
	# already gated by is_dead) and check position doesn't drift.
	var start: Vector3 = p.global_position
	p._knockback_dir = Vector2(1, 0)
	p._knockback_timer = 0.3
	await _frames(15)
	var drift: float = Vector2(p.global_position.x - start.x, p.global_position.z - start.z).length()
	if drift > 0.01:
		_fail(label, "player moved %.3f during spawn protection" % drift)
	await _frames(SETTLE_FRAMES)
	if p.is_dead:
		_fail(label, "is_dead still true %d frames after reset -- window never expired" % (SETTLE_FRAMES + 17))
	else:
		p.take_dart_hit()
		if p.lives != lives_before - 1:
			_fail(label, "take_dart_hit() didn't land after window expired")
		else:
			_pass(label, "ignored hit + knockback, drift %.3f, hittable after window" % drift)
	p.queue_free()
	await _frames(1)


## B: a mid-round take_dart_hit() respawn gets the same (longer) window --
## a second hit during it is ignored.
func _test_midround_respawn_protection() -> void:
	var label := "B: mid-round respawn protection"
	var p = _make_player(Vector3(0, 0.7, 0))
	p.reset_for_round(Vector3(0, 0.7, 0))
	await _frames(SETTLE_FRAMES)
	var lives_before: int = p.lives
	p.take_dart_hit()
	await _frames(30)  # 0.5s -- was already outside the old 0.3s window
	p.take_dart_hit()
	if p.lives != lives_before - 1:
		_fail(label, "second hit 0.5s after respawn landed (lives %d -> %d)" % [lives_before, p.lives])
	else:
		_pass(label, "second hit at 0.5s ignored")
	p.queue_free()
	await _frames(1)


## C: Slash lands at 1.7 (outside the old 1.4 range) and misses at 1.9.
func _test_melee_range() -> void:
	var label := "C: melee range 1.8"
	var attacker = _make_player(Vector3(0, 0.7, 0))
	var near = _make_player(Vector3(1.7, 0.7, 0))
	var far = _make_player(Vector3(0, 0.7, 1.9))
	for p in [attacker, near, far]:
		p.reset_for_round(p.global_position)
	await _frames(SETTLE_FRAMES)
	var near_lives: int = near.lives
	var far_lives: int = far.lives
	attacker._perform_slash()
	var ok := true
	if near.lives != near_lives - 1:
		_fail(label, "Slash at 1.7 did not land")
		ok = false
	if far.lives != far_lives:
		_fail(label, "Slash at 1.9 landed (should be out of range)")
		ok = false
	if ok:
		_pass(label, "hit at 1.7, miss at 1.9")
	for p in [attacker, near, far]:
		p.queue_free()
	await _frames(1)


## D: losing the last life hides the dart; the next reset_for_round() shows it.
func _test_eliminated_dart_hidden_then_restored() -> void:
	var label := "D: eliminated player's dart hidden, restored next round"
	var p = _make_player(Vector3(0, 0.7, 0))
	p.reset_for_round(Vector3(0, 0.7, 0))
	await _frames(SETTLE_FRAMES)
	p.lives = 1
	p.take_dart_hit()
	await _frames(2)
	if not p.is_eliminated:
		_fail(label, "player not eliminated after losing last life")
	elif p.dart.visible:
		_fail(label, "dart still visible after elimination")
	else:
		p.reset_for_round(Vector3(0, 0.7, 0))
		await _frames(2)
		if not p.dart.visible:
			_fail(label, "dart still hidden after reset_for_round()")
		else:
			_pass(label)
	p.queue_free()
	await _frames(1)


## E: a network-controlled player (e.g. a remote human on the host) must
## still come out of spawn protection -- otherwise they'd be untargetable
## for the whole online round.
func _test_network_controlled_invuln_expires() -> void:
	var label := "E: network-controlled player's protection expires"
	var p = _make_player(Vector3(0, 0.7, 0))
	p.is_network_controlled = true
	p.reset_for_round(Vector3(0, 0.7, 0))
	await _frames(SETTLE_FRAMES)
	if p.is_dead:
		_fail(label, "is_dead still true after %d frames -- permanently untargetable" % SETTLE_FRAMES)
	else:
		_pass(label)
	p.queue_free()
	await _frames(1)


## F: bot_controller.gd hand-mirrors player.gd's MELEE_RANGE.
func _test_bot_melee_range_mirrors_player() -> void:
	var label := "F: bot MELEE_RANGE mirrors player"
	var player_range: float = load("res://scripts/player.gd").MELEE_RANGE
	var bot_range: float = load("res://scripts/bot_controller.gd").MELEE_RANGE
	if is_equal_approx(player_range, bot_range):
		_pass(label, "both %.1f" % player_range)
	else:
		_fail(label, "player %.2f vs bot %.2f" % [player_range, bot_range])
