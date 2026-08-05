extends Node
## Regression test for Phase 2 of the post-GDD-rewrite rebuild (see
## docs/implementation-plan.md's Phase 2): rope_dart.gd's RETURNING state and
## player-hit detection (dart contact = always lethal in every away-state;
## rope-LINE contact = trip/slow only, never lethal).
##
## Drives rope_dart.gd's real state machine and player.gd's real
## _physics_process through the actual scene tree (add_child + real physics
## ticks via `await get_tree().physics_frame`, not manual delta-stepping) for
## the integration-shaped checks (A-D), plus one fully deterministic
## fixed-delta check (E) that calls _process_returning() directly to pin down
## the recall-speed-ramp math precisely, independent of any frame-timing
## variability.
##
## Run this scene directly (F6 in the editor) any time rope_dart.gd's
## RETURNING/hit-detection or player.gd's take_dart_hit()/apply_rope_trip()
## changes.

const TIMEOUT_FRAMES: int = 240  ## 4s at 60fps -- generous for any of the below

var any_failure := false


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	GameManager.current_state = GameManager.RoundState.PLAYING

	await _test_flying_kills_bystander()
	await _test_embedded_kills_bystander()
	await _test_returning_kills_bystander_and_arrives()
	await _test_rope_line_trips_not_kills()
	_test_recall_speed_ramps_up()

	print("[phase2 combat test] %s" % ("ALL PASSED" if not any_failure else "FAILURES FOUND -- see above"))
	print("PHASE2_COMBAT_TEST_DONE")


func _make_player(pos: Vector3, spawn: Vector3) -> Node:
	var scene: PackedScene = load("res://scenes/player.tscn")
	var p = scene.instantiate()
	add_child(p)
	p.global_position = pos
	p.spawn_pos = spawn
	return p


func _fail(label: String, reason: String) -> void:
	any_failure = true
	print("[phase2 combat test] %s: FAIL -- %s" % [label, reason])


func _pass(label: String, detail: String = "") -> void:
	print("[phase2 combat test] %s: PASS%s" % [label, (" -- " + detail) if detail != "" else ""])


## A: a FLYING dart passing through a bystander (not the owner) kills them --
## "landing the dart kills and respawns the target instantly."
func _test_flying_kills_bystander() -> void:
	var label := "A: FLYING kills bystander in path"
	var owner_p = _make_player(Vector3(0, 0.7, 0), Vector3(0, 0.7, 0))
	var bystander = _make_player(Vector3(0, 0.7, 3.0), Vector3(40, 0.7, 40))
	owner_p.aim_dir = Vector2(0, 1)
	owner_p.dart.begin_charge()
	await get_tree().physics_frame
	owner_p.dart.release_throw(Vector2(0, 1))

	var frames := 0
	var killed := false
	while frames < TIMEOUT_FRAMES:
		await get_tree().physics_frame
		frames += 1
		if bystander.global_position.distance_to(Vector3(40, 0.7, 40)) < 0.5:
			killed = true
			break

	if killed:
		_pass(label, "respawned at spawn_pos after %d frames" % frames)
	else:
		_fail(label, "bystander was never teleported to spawn_pos -- dart contact did not register as a kill")

	owner_p.queue_free()
	bystander.queue_free()
	await get_tree().physics_frame


## B: a stationary EMBEDDED dart is still lethal on contact -- a player who
## walks (or is placed) onto a landed dart dies.
func _test_embedded_kills_bystander() -> void:
	var label := "B: EMBEDDED kills bystander on contact"
	var owner_p = _make_player(Vector3(0, 0.7, 0), Vector3(0, 0.7, 0))
	owner_p.aim_dir = Vector2(0, 1)
	owner_p.dart.begin_charge()
	await get_tree().physics_frame
	owner_p.dart.release_throw(Vector2(0, 1))

	var frames := 0
	while frames < TIMEOUT_FRAMES and owner_p.dart.state != owner_p.DART_STATE_EMBEDDED:
		await get_tree().physics_frame
		frames += 1

	if owner_p.dart.state != owner_p.DART_STATE_EMBEDDED:
		_fail(label, "dart never reached EMBEDDED within %d frames (open-air max-range embed) -- can't test contact" % TIMEOUT_FRAMES)
		owner_p.queue_free()
		await get_tree().physics_frame
		return

	var embed_pos: Vector2 = owner_p.dart.pos_2d
	var bystander = _make_player(Vector3(embed_pos.x, 0.7, embed_pos.y), Vector3(40, 0.7, 40))

	frames = 0
	var killed := false
	while frames < TIMEOUT_FRAMES:
		await get_tree().physics_frame
		frames += 1
		if bystander.global_position.distance_to(Vector3(40, 0.7, 40)) < 0.5:
			killed = true
			break

	if killed:
		_pass(label, "respawned after %d frames of standing on the embedded dart" % frames)
	else:
		_fail(label, "bystander placed exactly on the embedded dart was never killed")

	owner_p.queue_free()
	bystander.queue_free()
	await get_tree().physics_frame


## C: recalling *through* a bystander on the way back kills them too ("missing
## and recalling through a target on the way back also kills them"), and the
## dart eventually arrives back at HOLSTERED instead of never terminating.
func _test_returning_kills_bystander_and_arrives() -> void:
	var label := "C: RETURNING kills bystander + arrives at HOLSTERED"
	var owner_p = _make_player(Vector3(0, 0.7, 0), Vector3(0, 0.7, 0))
	owner_p.aim_dir = Vector2(0, 1)
	owner_p.dart.begin_charge()
	await get_tree().physics_frame
	owner_p.dart.release_throw(Vector2(0, 1))

	var frames := 0
	while frames < TIMEOUT_FRAMES and owner_p.dart.state != owner_p.DART_STATE_EMBEDDED:
		await get_tree().physics_frame
		frames += 1
	if owner_p.dart.state != owner_p.DART_STATE_EMBEDDED:
		_fail(label, "dart never embedded -- can't set up recall")
		owner_p.queue_free()
		await get_tree().physics_frame
		return

	# Bystander sits on the straight recall path (owner at z=0, dart at
	# z=embed_z, both x=0) roughly halfway back.
	var embed_z: float = owner_p.dart.pos_2d.y
	var bystander = _make_player(Vector3(0, 0.7, embed_z * 0.5), Vector3(40, 0.7, 40))

	owner_p.dart.begin_recall()

	frames = 0
	var killed := false
	var arrived := false
	while frames < TIMEOUT_FRAMES:
		await get_tree().physics_frame
		frames += 1
		if not killed and bystander.global_position.distance_to(Vector3(40, 0.7, 40)) < 0.5:
			killed = true
		if owner_p.dart.state == owner_p.DART_STATE_RETURNING:
			pass
		elif owner_p.dart.state == owner_p.DART_STATE_HOLSTERED:
			arrived = true
			break

	if not killed:
		_fail(label, "bystander on the recall path was never killed")
	if not arrived:
		_fail(label, "dart never arrived back at HOLSTERED within %d frames -- RETURNING may be stuck" % TIMEOUT_FRAMES)
	if killed and arrived:
		_pass(label, "bystander killed mid-recall, dart returned to HOLSTERED after %d frames total" % frames)

	owner_p.queue_free()
	bystander.queue_free()
	await get_tree().physics_frame


## D: brushing the ROPE LINE (not the dart head) trips/slows a bystander but
## never kills them.
func _test_rope_line_trips_not_kills() -> void:
	var label := "D: rope-line contact trips, never kills"
	var owner_p = _make_player(Vector3(0, 0.7, 0), Vector3(0, 0.7, 0))
	owner_p.aim_dir = Vector2(0, 1)
	owner_p.dart.begin_charge()
	await get_tree().physics_frame
	owner_p.dart.release_throw(Vector2(0, 1))

	var frames := 0
	while frames < TIMEOUT_FRAMES and owner_p.dart.state != owner_p.DART_STATE_EMBEDDED:
		await get_tree().physics_frame
		frames += 1
	if owner_p.dart.state != owner_p.DART_STATE_EMBEDDED:
		_fail(label, "dart never embedded -- can't set up the rope-line brush")
		owner_p.queue_free()
		await get_tree().physics_frame
		return

	# Bystander offset sideways from the rope line's midpoint: within
	# rope_trip_radius of the SEGMENT, but well outside dart_hit_radius of
	# the dart HEAD (embed_z away in Z) and outside the hand's own radius
	# (near z=0) too, so only the line-segment check can catch them.
	var embed_z: float = owner_p.dart.pos_2d.y
	var offset_x: float = owner_p.dart.rope_trip_radius * 0.6
	var bystander = _make_player(Vector3(offset_x, 0.7, embed_z * 0.5), Vector3(40, 0.7, 40))

	var trip_seen := false
	var killed := false
	frames = 0
	while frames < 30:
		await get_tree().physics_frame
		frames += 1
		if bystander._trip_timer > 0.0:
			trip_seen = true
		if bystander.is_dead or bystander.global_position.distance_to(Vector3(40, 0.7, 40)) < 0.5:
			killed = true

	if killed:
		_fail(label, "bystander near the rope LINE (not the dart head) was killed -- rope contact must never be lethal")
	elif not trip_seen:
		_fail(label, "bystander near the rope line never got _trip_timer > 0 -- rope-line detection isn't firing")
	else:
		_pass(label, "trip timer engaged (%d frames observed), bystander never killed" % frames)

	owner_p.queue_free()
	bystander.queue_free()
	await get_tree().physics_frame


## E: RETURNING speed increases over time (GDD: "Recall speed increases over
## time"). Deterministic, fixed-delta, direct calls to _process_returning()
## -- decoupled from real engine frame timing so the math itself is pinned
## down precisely rather than inferred from noisy real-tick measurements.
func _test_recall_speed_ramps_up() -> void:
	var label := "E: recall speed increases over time"
	var owner_p = _make_player(Vector3(0, 0.7, 0), Vector3(0, 0.7, 0))
	var dart = owner_p.dart
	dart.owner_player = owner_p
	dart.state = owner_p.DART_STATE_RETURNING
	dart.pos_2d = Vector2(0.0, dart.rope_length)  # far from owner, plenty of room before arrival
	dart._recall_time = 0.0

	const DT: float = 1.0 / 60.0
	var early_step: float = 0.0
	var late_step: float = 0.0
	var pos_before: Vector2

	for i in 3:
		pos_before = dart.pos_2d
		dart._process_returning(DT)
	# Measure one step near the start of the recall.
	pos_before = dart.pos_2d
	dart._process_returning(DT)
	early_step = pos_before.distance_to(dart.pos_2d)

	# Advance well into the recall (still comfortably short of arrival --
	# rope_length is ~7.2, and by t~0.25s cumulative travel is ~5 units).
	for i in 10:
		dart._process_returning(DT)

	pos_before = dart.pos_2d
	dart._process_returning(DT)
	late_step = pos_before.distance_to(dart.pos_2d)

	if dart.state != owner_p.DART_STATE_RETURNING:
		_fail(label, "dart arrived (state=%d) before the late-step measurement -- test window too wide, can't compare speeds" % dart.state)
	elif late_step > early_step * 1.05:
		_pass(label, "per-tick step distance grew from %.4f to %.4f" % [early_step, late_step])
	else:
		_fail(label, "per-tick step distance did not meaningfully increase (%.4f -> %.4f) -- recall_accel isn't ramping speed" % [early_step, late_step])

	owner_p.queue_free()
