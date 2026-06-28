extends StaticBody3D
## Registers this node in the "obstacles" group so rope_dart.gd can check dart anchoring.

@export var half_size: Vector2 = Vector2(0.75, 0.75)


func _ready() -> void:
	add_to_group("obstacles")


func get_rect_2d() -> Rect2:
	var center := Vector2(global_position.x, global_position.z)
	return Rect2(center - half_size, half_size * 2.0)
