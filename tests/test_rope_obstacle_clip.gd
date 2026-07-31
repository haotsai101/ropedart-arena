extends Node
## Regression test for the rope chain visibly clipping through obstacle
## geometry (real user bug report: "when the rope cut into the pillar... it
## loses the tension again"). Deterministically forces the exact condition
## the original screenshot showed -- hand and dart tip on OPPOSITE sides of a
## real pillar, so the straight hand-to-tip line passes through solid
## geometry -- instead of relying on random bot throws to stumble into it,
## then measures every real RopeChainPBD point's XZ position directly against
## the pillar's own get_rect_2d() over a sustained multi-second hold (not
## just the first few ticks).
##
## ADAPTED for the PBD/Verlet rope chain rewrite (see scripts/rope_chain_pbd.gd) --
## reads player._rope_chain.points/.last_had_collision instead of the old
## RigidBody3D chain's _physics_rope_segments.
##
## Run this scene directly (F6 in the editor, or headless via
## res://tests/test_rope_obstacle_clip.tscn) any time the rope chain's own
## collision-correction logic changes.

const SETTLE_TICKS: int = 240  ## ~4s at 60Hz -- long enough to see a sustained
## clip/collapse, not just a transient right after the tip is forced to move.
const SAMPLE_EVERY: int = 15


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	var main_scene: Node = load("res://scenes/main.tscn").instantiate()
	add_child(main_scene)
	for i in 5:
		await get_tree().physics_frame

	var pillar_a: Node = main_scene.get_node("PillarA")
	var rect: Rect2 = pillar_a.get_rect_2d()
	print("[TEST] PillarA rect=%s (world XZ)" % [rect])

	var player_scene: PackedScene = load("res://scenes/player.tscn")
	var player = player_scene.instantiate()
	add_child(player)
	# Southwest of the pillar's near corner -- the straight line to a point
	# northeast of the pillar's far corner cuts diagonally through the box
	# (not a dead-on face hit), forcing real corner wraparound instead of
	# just "press flat against a wall," which is what the reported
	# screenshot actually showed (a line cutting through the lower portion
	# of the crate, not stopping cleanly at a face).
	# ADAPTED for the PBD chain rewrite: offset reduced from 2.5 to 1.0 on
	# each side -- at 2.5 the resulting straight-line hand-to-tip distance
	# (~9.9 units) EXCEEDS DART_ROPE_LENGTH (7.2), a configuration the real,
	# now-working leash mechanism (_apply_rope_leash_velocity_clamp()) would
	# never actually let a real player reach in the first place (that's
	# exactly what it exists to prevent) -- directly teleporting the player
	# there bypasses the leash entirely and creates a mathematically
	# IMPOSSIBLE configuration for any fixed-length chain to satisfy without
	# a real, unavoidable violation somewhere, which is a test-setup
	# artifact, not a real rope bug. At 1.0 the total span comfortably fits
	# inside the real budget, matching what a leash-respecting player could
	# actually reach.
	player.global_position = Vector3(rect.position.x - 1.0, 0.7, rect.position.y - 1.0)
	player.aim_dir = Vector2(-1, -1).normalized()  # aim away from the pillar for the initial throw
	for i in 5:
		await get_tree().physics_frame

	player._throw(0.0)
	for i in 5:
		await get_tree().physics_frame
	if player.dart == null:
		print("[TEST] FAIL: throw produced no dart")
		return

	# Force the dart to sit ANCHORED on the FAR (northeast) side of the
	# pillar, directly -- sidesteps needing to land a real raycast at exactly
	# the right angle to reproduce the same end condition the screenshot
	# showed.
	player.dart.state = 1  # State.ANCHORED (see rope_dart.gd's enum)
	player.dart.head_2d = Vector2(rect.end.x + 1.0, rect.end.y + 1.0)
	player.dart._render()  # sync head_mesh.global_transform -- _get_rope_tip_target() reads that, not head_2d directly
	print("[TEST] hand=%.2f,%.2f tip(dart.head_2d)=%.2f,%.2f -- straight line crosses PillarA rect" % [
		player.get_pos_2d().x, player.get_pos_2d().y, player.dart.head_2d.x, player.dart.head_2d.y])

	var max_pen_overall: float = 0.0
	var max_perp_overall: float = 0.0
	for tick in range(SETTLE_TICKS):
		await get_tree().physics_frame
		if tick % SAMPLE_EVERY != 0:
			continue
		var hand_pos: Vector3 = player._get_rope_hand_anchor_pos()
		var tip_pos: Vector3 = player._get_rope_tip_target()
		var hand_2d := Vector2(hand_pos.x, hand_pos.z)
		var tip_2d := Vector2(tip_pos.x, tip_pos.z)
		var line_vec: Vector2 = tip_2d - hand_2d
		var line_len: float = line_vec.length()
		var line_dir: Vector2 = line_vec / line_len if line_len > 0.01 else Vector2.ZERO
		var max_pen: float = 0.0
		var max_perp: float = 0.0
		var contact_count: int = 0
		var chain_points: PackedVector2Array = player._rope_chain.points if player._rope_chain != null else PackedVector2Array()
		var seg_count: int = chain_points.size()
		for idx in range(chain_points.size()):
			var p2: Vector2 = chain_points[idx]
			if rect.has_point(p2):
				var pen: float = minf(p2.x - rect.position.x, rect.end.x - p2.x)
				pen = minf(pen, minf(p2.y - rect.position.y, rect.end.y - p2.y))
				max_pen = maxf(max_pen, pen)
			if bool(player._rope_chain.last_had_collision[idx]):
				contact_count += 1
			if line_len > 0.01:
				var rel: Vector2 = p2 - hand_2d
				var along: float = rel.dot(line_dir)
				var perp: Vector2 = rel - line_dir * along
				max_perp = maxf(max_perp, perp.length())
		max_pen_overall = maxf(max_pen_overall, max_pen)
		max_perp_overall = maxf(max_perp_overall, max_perp)
		print("[TEST] tick=%d segs=%d contact_segs=%d max_pillar_penetration=%.3f max_perp_dev=%.2f" % [
			tick, seg_count, contact_count, max_pen, max_perp])

	print("[TEST] RESULT max_pillar_penetration_over_%dticks=%.4f max_perp_dev_over_run=%.2f" % [
		SETTLE_TICKS, max_pen_overall, max_perp_overall])
	if max_pen_overall > 0.001:
		print("[TEST] FAIL: rope segments penetrated PillarA's collision rect")
	else:
		print("[TEST] PASS: no rope segment ever entered PillarA's collision rect")
