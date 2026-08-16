extends CanvasLayer
## Off-screen enemy directional pins (Task #45, touch/mobile only, direct
## user request).
##
## arena_camera.gd's new touch follow mode (_process_touch_follow()) uses a
## tight, mostly-fixed zoom centered on the local player instead of
## desktop's zoom-to-fit-everyone AABB -- great for making the character
## read larger on a phone screen, but it means other players/bots now
## easily fall outside the visible frame. This overlay restores situational
## awareness: every frame, for each OTHER alive player, project their world
## position to screen space via the active camera's own
## unproject_position() and, if they're currently off-screen, draw a small
## directional pin clamped to the screen edge, pointing toward their actual
## direction.
##
## Gated the same touch-only condition as virtual_controls.gd, and
## instantiated the same way, right alongside it -- see player.gd's
## _ready(), the "Virtual controls for touch devices" block.
##
## All UI is code-built (draw calls on a plain Control), matching this
## project's existing hud.gd/virtual_controls.gd convention -- no separate
## scene file.

const EDGE_MARGIN: float = 40.0    # px kept clear from the actual screen edge
const PIN_SIZE: float = 14.0       # px, arrow tip-to-base length
const FADE_NEAR: float = 4.0       # world units -- opacity starts fading in below this
const FADE_FAR: float = 20.0       # world units -- opacity bottoms out at this distance
const MIN_ALPHA: float = 0.45

var _local_player: Node = null
var _canvas: Control = null


func _ready() -> void:
	layer = 15  # above HUD (hud.gd uses 10), below VirtualControls (uses 20)
	_canvas = Control.new()
	_canvas.name = "EnemyPinsDrawSurface"
	_canvas.set_anchors_preset(Control.PRESET_FULL_RECT)
	_canvas.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_canvas.draw.connect(_on_canvas_draw)
	add_child(_canvas)


func _process(_delta: float) -> void:
	# Enemy positions/camera framing change every frame -- simplest correct
	# approach is to just redraw every frame (mirrors virtual_controls.gd's
	# queue_redraw()-on-state-change pattern, except here the "state" is
	# continuous player motion rather than discrete touch events).
	if _canvas != null:
		_canvas.queue_redraw()


func _find_local_player() -> Node:
	for p in get_tree().get_nodes_in_group("players"):
		if p.player_index == 0 and not p.is_bot:
			return p
	return null


func _on_canvas_draw() -> void:
	var cam: Camera3D = get_viewport().get_camera_3d()
	if cam == null:
		return
	if _local_player == null or not is_instance_valid(_local_player):
		_local_player = _find_local_player()
	if _local_player == null:
		return

	var vp_size: Vector2 = get_viewport().get_visible_rect().size
	var center: Vector2 = vp_size * 0.5
	var local_pos: Vector2 = _local_player.get_pos_2d()

	for p in get_tree().get_nodes_in_group("players"):
		if p == _local_player:
			continue
		if p.is_eliminated or p.is_dead:
			continue

		var screen_pos: Vector2 = cam.unproject_position(p.global_position)
		var on_screen: bool = (
			not cam.is_position_behind(p.global_position)
			and screen_pos.x >= 0.0 and screen_pos.x <= vp_size.x
			and screen_pos.y >= 0.0 and screen_pos.y <= vp_size.y
		)
		if on_screen:
			continue

		var dir: Vector2 = screen_pos - center
		if dir.length() < 0.01:
			dir = Vector2(0.0, -1.0)
		dir = dir.normalized()

		# Clamp the projected (off-screen) point to the viewport edge along
		# `dir`, staying EDGE_MARGIN clear of the actual border.
		var half: Vector2 = center - Vector2(EDGE_MARGIN, EDGE_MARGIN)
		var scale_x: float = (half.x / absf(dir.x)) if absf(dir.x) > 0.0001 else INF
		var scale_y: float = (half.y / absf(dir.y)) if absf(dir.y) > 0.0001 else INF
		var pin_pos: Vector2 = center + dir * minf(scale_x, scale_y)

		var dist: float = local_pos.distance_to(p.get_pos_2d())
		var alpha: float = clamp(remap(dist, FADE_NEAR, FADE_FAR, 1.0, MIN_ALPHA), MIN_ALPHA, 1.0)
		var color: Color = p.player_color
		color.a = alpha

		_draw_pin(pin_pos, dir, color)


## Simple triangular arrow at `pos`, rotated to point along `dir`.
func _draw_pin(pos: Vector2, dir: Vector2, color: Color) -> void:
	var ang: float = dir.angle()
	var tip: Vector2   = pos + Vector2(PIN_SIZE, 0.0).rotated(ang)
	var base_a: Vector2 = pos + Vector2(-PIN_SIZE * 0.5,  PIN_SIZE * 0.5).rotated(ang)
	var base_b: Vector2 = pos + Vector2(-PIN_SIZE * 0.5, -PIN_SIZE * 0.5).rotated(ang)
	_canvas.draw_colored_polygon(PackedVector2Array([tip, base_a, base_b]), color)
	_canvas.draw_circle(pos, 3.0, Color(0.0, 0.0, 0.0, 0.4 * color.a))
