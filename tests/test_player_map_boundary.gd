extends Node
## Regression test for the arena ring-out boundary (player.gd's
## _check_boundary_fall / ARENA_HALF). There is no gravity or vertical
## physics in this game at all (player velocity.y is always 0 — see
## player.gd's movement code), so "the player falls through the floor" can
## only mean one thing: they walked past the intended arena edge without the
## ring-out check catching them and starting the fall/death sequence, so
## they're left standing over the void with no floor rendered under them
## instead of dying and respawning.
##
## Reported bug: this was observed happening specifically on the SOUTH side
## of the map (+Z, the side nearest the camera — see Camera3D's +Z position
## in main.tscn/main_forest.tscn). This test drives the player at full dash
## speed toward all 4 cardinal directions and the 4 diagonals through the
## real movement pipeit (velocity + move_and_slide() + _check_boundary_fall(),
## the same call order player.gd's own _physics_process uses) and records
## exactly where the ring-out fires in each direction, so any directional
## asymmetry shows up directly instead of being inferred from reading code.
##
## Run this scene directly (F6 in the editor) any time player.gd's movement
## or boundary logic changes.

const DT: float = 0.016
const ARENA_HALF: float = 15.0  ## must match player.gd's own ARENA_HALF
const DASH_SPEED: float = 20.0  ## must match player.gd's own DASH_SPEED
## How far outside ARENA_HALF the ring-out is allowed to fire late by, given
## one frame of dash movement can cover ~0.33 units. A direction that needs
## noticeably more overshoot than this to trigger (or never triggers at all)
## is the bug.
const MAX_LATE_TRIGGER: float = 0.5

var any_failure := false


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	var player_scene: PackedScene = load("res://scenes/player.tscn")
	var player = player_scene.instantiate()
	add_child(player)
	for i in 5:
		await get_tree().physics_frame

	GameManager.current_state = GameManager.RoundState.PLAYING

	var directions: Array = [
		["north (-Z)", Vector2(0, -1)],
		["south (+Z)", Vector2(0, 1)],
		["east (+X)", Vector2(1, 0)],
		["west (-X)", Vector2(-1, 0)],
		["northeast", Vector2(1, -1).normalized()],
		["northwest", Vector2(-1, -1).normalized()],
		["southeast", Vector2(1, 1).normalized()],
		["southwest", Vector2(-1, 1).normalized()],
	]

	for entry in directions:
		await _run_direction(player, entry[0], entry[1])

	# Also specifically stress the reported bad side at normal (non-dash)
	# walking speed, and from a couple of different starting offsets along
	# the boundary (not just straight out from the origin), in case the
	# issue only shows up off-center.
	for offset_x in [-8.0, 0.0, 8.0]:
		await _run_direction(player, "south (+Z) at x=%.0f, walk speed" % offset_x, Vector2(0, 1), player.move_speed, offset_x)

	# The sweeps above use an empty test environment. Also run a south-side
	# sweep with the REAL main.tscn obstacles present (instanced as a plain
	# child, not a scene swap, so it can't free this test node the way
	# change_scene_to_file would), grazing past PillarB's edge while heading
	# south — the realistic "walked near a pillar toward the south wall"
	# scenario the reported bug describes, in case a collision deflection
	# near the edge pushes the player somewhere the plain sweeps above can't
	# reach.
	var main_scene: Node = load("res://scenes/main.tscn").instantiate()
	add_child(main_scene)
	for i in 5:
		await get_tree().physics_frame
	# PillarB sits at (5, 5) with half_size 1.45 (spans x/z 3.55-6.45), so a
	# dead-center straight walk into it just gets correctly blocked -- that's
	# solid-collision working as intended, not a bug. What actually matters
	# is what happens GRAZING past its edge while still heading generally
	# south, since that's the realistic "walked near a pillar toward the
	# south wall" scenario the reported bug describes. 6.5/7.0 clear the
	# pillar's east edge (6.45); 3.4/3.0 clear its west edge (3.55).
	for offset_x in [3.0, 3.4, 6.5, 7.0]:
		await _run_direction(player, "south (+Z) grazing pillar edge at x=%.1f, walk speed" % offset_x, Vector2(0, 1), player.move_speed, offset_x)

	print("[boundary test] %s" % ("ALL PASSED" if not any_failure else "FAILURES FOUND — see above"))
	print("BOUNDARY_TEST_DONE")


func _run_direction(player, label: String, dir: Vector2, speed: float = DASH_SPEED, start_x: float = 0.0) -> void:
	# Reset any fall/death state left over from a previous direction.
	if player.is_falling:
		player._reset_fall_visual()
	player.is_falling = false
	player.is_dead = false
	player.collision_shape.disabled = false
	player.velocity = Vector3.ZERO
	player.global_position = Vector3(start_x, GameManager.PLAYER_HALF_HEIGHT, 0.0)
	player.spawn_pos = player.global_position

	var frames := 0
	var triggered := false
	var trigger_pos: Vector2 = Vector2.ZERO
	while frames < 500:
		player.velocity = Vector3(dir.x, 0.0, dir.y) * speed
		player.move_and_slide()
		player._check_boundary_fall()
		frames += 1
		if player.is_falling:
			triggered = true
			trigger_pos = player.get_pos_2d()
			break

	if not triggered:
		_fail(label, "ring-out never fired within 500 frames — the player can walk straight off the map in this direction")
		return

	# Whichever axis this direction actually moves along should have crossed
	# ARENA_HALF right around when the ring-out fired, not way past it.
	var relevant_coord: float = absf(trigger_pos.x) if absf(dir.x) > absf(dir.y) else absf(trigger_pos.y)
	if absf(dir.x) > 0.01 and absf(dir.y) > 0.01:
		relevant_coord = maxf(absf(trigger_pos.x), absf(trigger_pos.y))
	var overshoot: float = relevant_coord - ARENA_HALF

	print("[boundary test] %s: triggered at pos=%s (overshoot=%.3f, frames=%d)" % [label, trigger_pos, overshoot, frames])

	if overshoot < 0.0:
		_fail(label, "ring-out fired BEFORE reaching the boundary (pos=%s, %.3f short of ARENA_HALF=%.1f) — players can be killed inside the playable area" % [trigger_pos, -overshoot, ARENA_HALF])
	elif overshoot > MAX_LATE_TRIGGER:
		_fail(label, "ring-out fired %.3f units past the boundary (pos=%s) — more than the %.1f-unit tolerance for one frame of movement, meaning the player can stand well past the edge over the void before dying" % [overshoot, trigger_pos, MAX_LATE_TRIGGER])

	# Confirm there really is no vertical fall through physics — Y should be
	# completely unaffected by walking past the boundary (the game has no
	# gravity; "falling through the floor" is purely a boundary-check bug,
	# not a physics one, so this is really a sanity check that stays true).
	if absf(player.global_position.y - GameManager.PLAYER_HALF_HEIGHT) > 0.01:
		_fail(label, "player's Y position moved (%.3f) while walking horizontally — should be impossible, movement is XZ-only" % player.global_position.y)


func _fail(label: String, reason: String) -> void:
	any_failure = true
	print("[boundary test] %s: FAIL — %s" % [label, reason])
