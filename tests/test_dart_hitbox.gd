extends Node
## Dart hitbox regression test: throws a FLYING dart straight past a
## stationary target at a range of sideways offsets (center-to-flight-line
## distance), at both an uncharged and a fully charged throw speed, and
## records which offsets kill.
##
## Visual contact starts at ~0.54 (player capsule radius 0.4 + dart head
## 0.14). The hit must be reliable everywhere inside dart_hit_radius -- the
## check is a swept segment test, so a fast dart can't step over a target's
## edge between two physics ticks -- and must not reach targets clearly off
## the line.
##
## Run: Godot --headless --path . res://tests/test_dart_hitbox.tscn

const OFFSETS := [0.0, 0.3, 0.5, 0.6, 0.7, 0.74, 0.8, 1.0, 1.3]
const TARGET_Z := 3.1  # flight distance to the target's row (not a multiple of a tick's step)
const FRAMES := 90

var any_failure := false


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	GameManager.current_state = GameManager.RoundState.PLAYING
	for charged: bool in [false, true]:
		var row := []
		for off: float in OFFSETS:
			var hit: bool = await _trial(off, charged)
			row.append("%.2f:%s" % [off, "HIT" if hit else "miss"])
			var radius: float = load("res://scripts/rope_dart.gd").new().dart_hit_radius
			var expect_hit: bool = off <= radius - 0.01
			var expect_miss: bool = off >= radius + 0.2
			if (expect_hit and not hit) or (expect_miss and hit):
				any_failure = true
				print("[dart hitbox test] FAIL -- %s throw at offset %.2f: %s (dart_hit_radius %.2f)" % [
					"charged" if charged else "uncharged", off, "hit" if hit else "missed", radius])
		print("[dart hitbox test] %s: %s" % ["charged  " if charged else "uncharged", "  ".join(row)])
	print("[dart hitbox test] %s" % ("ALL PASSED" if not any_failure else "FAILURES FOUND"))
	get_tree().quit(1 if any_failure else 0)


func _trial(offset: float, charged: bool) -> bool:
	var scene: PackedScene = load("res://scenes/player.tscn")
	var thrower = scene.instantiate()
	add_child(thrower)
	thrower.global_position = Vector3(0, 0.7, 0)
	thrower.spawn_pos = thrower.global_position
	var target = scene.instantiate()
	add_child(target)
	target.global_position = Vector3(offset, 0.7, TARGET_Z)
	target.spawn_pos = Vector3(40, 0.7, 40)
	await get_tree().physics_frame
	thrower.aim_dir = Vector2(0, 1)
	thrower.dart.begin_charge()
	if charged:
		thrower.dart._charge_time = thrower.dart.max_charge_time
	thrower.dart.release_throw(Vector2(0, 1))
	var hit := false
	for i in FRAMES:
		await get_tree().physics_frame
		if target.lives < 3 or target.global_position.distance_to(Vector3(40, 0.7, 40)) < 0.5:
			hit = true
			break
	var dart = thrower.dart
	thrower.queue_free()
	target.queue_free()
	if is_instance_valid(dart):
		dart.queue_free()
	await get_tree().physics_frame
	return hit
