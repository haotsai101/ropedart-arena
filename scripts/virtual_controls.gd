extends CanvasLayer
## Virtual on-screen joystick overlay for touch devices.
## Left stick: movement (bottom-left), Right stick: aim (bottom-right),
## Throw button: above right stick.
## Exposed API: get_move() -> Vector2, get_aim() -> Vector2, get_throw_held() -> bool.

const BASE_RADIUS  := 110.0
const KNOB_RADIUS  :=  40.0
const THROW_RADIUS :=  55.0
const MARGIN       :=  30.0
const THROW_GAP    :=  20.0   # px gap between right stick top and throw button bottom

const COLOR_BASE         := Color(0.1, 0.1, 0.1, 0.4)
const COLOR_KNOB         := Color(0.8, 0.8, 0.8, 0.6)
const COLOR_THROW        := Color(0.9, 0.4, 0.1, 0.7)
const COLOR_THROW_ACTIVE := Color(1.0, 0.6, 0.2, 0.9)

# Computed screen positions
var _left_base:    Vector2 = Vector2.ZERO
var _right_base:   Vector2 = Vector2.ZERO
var _throw_center: Vector2 = Vector2.ZERO

# Touch state
var _left_knob_offset:  Vector2 = Vector2.ZERO
var _right_knob_offset: Vector2 = Vector2.ZERO
var _throw_held:        bool    = false

# Finger ID tracking (-1 = not claimed)
var _left_finger:  int = -1
var _right_finger: int = -1
var _throw_finger: int = -1

var _canvas: Control = null


func _ready() -> void:
	layer = 20  # above game HUD (hud.gd uses layer = 10)
	_canvas = Control.new()
	_canvas.name = "VCDrawSurface"
	_canvas.set_anchors_preset(Control.PRESET_FULL_RECT)
	_canvas.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_canvas.draw.connect(_on_canvas_draw)
	add_child(_canvas)
	get_viewport().size_changed.connect(_update_layout)
	_update_layout()


func _update_layout() -> void:
	var sz: Vector2 = get_viewport().get_visible_rect().size
	_left_base    = Vector2(MARGIN + BASE_RADIUS, sz.y - MARGIN - BASE_RADIUS)
	_right_base   = Vector2(sz.x - MARGIN - BASE_RADIUS, sz.y - MARGIN - BASE_RADIUS)
	# Throw button sits above right joystick with a small gap
	_throw_center = Vector2(
		sz.x - MARGIN - BASE_RADIUS,
		sz.y - MARGIN - BASE_RADIUS * 2.0 - THROW_GAP - THROW_RADIUS
	)
	if _canvas != null:
		_canvas.queue_redraw()


func _on_canvas_draw() -> void:
	# --- Left joystick ---
	_canvas.draw_circle(_left_base, BASE_RADIUS, COLOR_BASE)
	_canvas.draw_circle(_left_base + _left_knob_offset, KNOB_RADIUS, COLOR_KNOB)

	# --- Right joystick ---
	_canvas.draw_circle(_right_base, BASE_RADIUS, COLOR_BASE)
	_canvas.draw_circle(_right_base + _right_knob_offset, KNOB_RADIUS, COLOR_KNOB)

	# --- Throw button ---
	var btn_color: Color = COLOR_THROW_ACTIVE if _throw_held else COLOR_THROW
	_canvas.draw_circle(_throw_center, THROW_RADIUS, btn_color)
	var fallback_font: Font = ThemeDB.fallback_font
	if fallback_font != null:
		# draw_string pos is the baseline; offset upward by half font size to center
		var label_pos: Vector2 = _throw_center + Vector2(0.0, 10.0)
		_canvas.draw_string(
			fallback_font,
			label_pos,
			"●",
			HORIZONTAL_ALIGNMENT_CENTER,
			-1,
			28,
			Color.WHITE
		)


func _input(event: InputEvent) -> void:
	if event is InputEventScreenTouch:
		_handle_touch(event as InputEventScreenTouch)
	elif event is InputEventScreenDrag:
		_handle_drag(event as InputEventScreenDrag)


func _handle_touch(event: InputEventScreenTouch) -> void:
	var pos: Vector2 = event.position
	if event.pressed:
		# Priority: left stick, then throw button, then right stick
		# (throw button overlaps right-base zone so check it before right stick)
		if _left_finger == -1 and pos.distance_to(_left_base) <= BASE_RADIUS:
			_left_finger = event.index
			_left_knob_offset = (pos - _left_base).limit_length(BASE_RADIUS)
			get_viewport().set_input_as_handled()
		elif _throw_finger == -1 and pos.distance_to(_throw_center) <= THROW_RADIUS + 20.0:
			_throw_finger = event.index
			_throw_held = true
			get_viewport().set_input_as_handled()
		elif _right_finger == -1 and pos.distance_to(_right_base) <= BASE_RADIUS:
			_right_finger = event.index
			_right_knob_offset = (pos - _right_base).limit_length(BASE_RADIUS)
			get_viewport().set_input_as_handled()
	else:
		# Finger lifted — release whichever zone it owned
		if event.index == _left_finger:
			_left_finger = -1
			_left_knob_offset = Vector2.ZERO
			get_viewport().set_input_as_handled()
		if event.index == _right_finger:
			_right_finger = -1
			_right_knob_offset = Vector2.ZERO
			get_viewport().set_input_as_handled()
		if event.index == _throw_finger:
			_throw_finger = -1
			_throw_held = false
			get_viewport().set_input_as_handled()
	if _canvas != null:
		_canvas.queue_redraw()


func _handle_drag(event: InputEventScreenDrag) -> void:
	if event.index == _left_finger:
		_left_knob_offset = (event.position - _left_base).limit_length(BASE_RADIUS)
		get_viewport().set_input_as_handled()
	elif event.index == _right_finger:
		_right_knob_offset = (event.position - _right_base).limit_length(BASE_RADIUS)
		get_viewport().set_input_as_handled()
	if _canvas != null:
		_canvas.queue_redraw()


## Returns normalised movement vector in [-1,1] range; Vector2.ZERO when idle.
func get_move() -> Vector2:
	if _left_knob_offset.length() < 0.1:
		return Vector2.ZERO
	return _left_knob_offset / BASE_RADIUS


## Returns normalised aim vector in [-1,1] range; Vector2.ZERO when idle.
func get_aim() -> Vector2:
	if _right_knob_offset.length() < 0.1:
		return Vector2.ZERO
	return _right_knob_offset / BASE_RADIUS


## Returns true while the throw button is held by a finger.
func get_throw_held() -> bool:
	return _throw_held
