extends CanvasLayer
## Virtual on-screen control overlay for touch devices.
## Left: a single stick controlling movement (bottom-left).
## Right: three EQUAL-SIZED buttons in a triangle cluster (bottom-right) --
## Dash (top), Throw/Redirect (bottom-right), Slash/Kick (bottom-left).
##
## Task #42 (touch control redesign, direct user request): the old separate
## aim stick on the right side is REMOVED entirely -- there is no
## `get_aim()`/`_right_base`/`_right_knob_offset` any more. Touch aim is no
## longer a distinct input at all: player.gd's own _get_aim_input() now
## derives aim_dir from the SAME left movement stick this file already
## exposes via get_move() -- tracking current movement/facing by default, and
## (since CHARGING/holding-to-redirect already zero movement's CONTRIBUTION
## to velocity but leave the raw stick reading intact) repurposed to drive
## aim/facing rotation during those pinned windows instead. See player.gd's
## _get_aim_input() for the actual mechanism; nothing here needs to know
## about dart.state to make that work.
##
## Throw and Recall are the SAME input everywhere (keyboard/mouse, gamepad,
## touch) -- see player.gd's _get_action_held() -- so there is deliberately
## no separate Recall button here; get_recall_held() is a thin alias of
## get_throw_held() kept only so player.gd doesn't need a touch-specific
## special case.
##
## Phase 3: the Slash button is likewise repointed to the unified Slash/Kick
## input (player.gd's _get_melee_action_held()) rather than getting its own
## new button -- get_slash_held() itself, and the button's screen position/
## visuals, are unchanged; only what player.gd DOES with the signal changed
## (Slash with the dart in hand, Kick with it away, same context-sensitive
## pattern as Throw/Recall). No touch-side code needed for that repoint.
##
## Phase 4: the Throw button is ALSO how a touch player redirects a swing
## (tap while EMBEDDED = Recall, hold-then-release aiming = Redirect -- see
## player.gd's _handle_dart_away_input()). The raw held/not-held signal this
## file exposes is mechanically identical for touch and desktop (both just
## feed the same level signal into player.gd's own hold-duration tracking),
## so no new input plumbing is needed here -- but unlike a mouse click, a
## touch player gets no natural physical "click"/"hold" feedback from the
## hardware itself, and this button doubles as BOTH Throw-charge and
## Recall/Redirect depending on dart state, so a clear in-UI affordance for
## "you have now held long enough that releasing will redirect, not
## tap-recall" matters more here than on desktop, given how often this fires
## mid-fight. _throw_held_time/HOLD_REDIRECT_THRESHOLD below drive a third,
## distinct button color once held past that point -- purely cosmetic,
## mirrors (not reads) player.gd's own SWING_REDIRECT_HOLD_THRESHOLD so what
## the player SEES matches what actually happens on release without this
## file needing to know anything about dart.state itself.
##
## Phase 4.5: Dash button, following the exact same finger-tracking/drawing
## pattern as Throw/Slash above -- a plain level signal (held/not-held), no
## tap-vs-hold distinction needed since player.gd's own _get_dash_pressed()
## already does simple rising-edge detection on whatever level signal it
## receives (see that function + _prev_dash in player.gd).
##
## Priority / multi-touch: Dash/Throw/Slash all track their own finger id
## independently of the left stick's (_left_finger/_throw_finger/
## _dash_finger/_slash_finger below), and _handle_touch()'s press branch
## checks each zone independently rather than gating on "is the left stick
## currently idle" -- so pressing any right-side button while the left stick
## is simultaneously held down works correctly (verified live, Task #42).
##
## Exposed API: get_move() -> Vector2, get_throw_held() -> bool,
## get_slash_held() -> bool, get_recall_held() -> bool, get_dash_held() -> bool.

const BASE_RADIUS   := 110.0
const KNOB_RADIUS   :=  40.0
## All three right-side buttons share this one radius (Task #42: "same size
## as the other two" applies uniformly to Dash/Throw/Slash, not just
## Throw/Slash as before).
const BUTTON_RADIUS :=  52.0
const MARGIN        :=  30.0
const BUTTON_GAP     :=  18.0   # px gap between adjacent right-side buttons

const COLOR_BASE          := Color(0.1, 0.1, 0.1, 0.4)
const COLOR_KNOB          := Color(0.8, 0.8, 0.8, 0.6)
const COLOR_THROW         := Color(0.9, 0.4, 0.1, 0.7)
const COLOR_THROW_ACTIVE  := Color(1.0, 0.6, 0.2, 0.9)
## Distinct third color once a held press has crossed HOLD_REDIRECT_THRESHOLD
## -- see this file's own header comment on why touch needs this cue that
## desktop doesn't. Deliberately a different hue (yellow-white), not just a
## brighter/darker version of COLOR_THROW_ACTIVE, so it reads as a distinct
## MODE rather than "the same button pressed harder".
const COLOR_THROW_HOLDING := Color(1.0, 0.9, 0.15, 0.95)
const COLOR_SLASH         := Color(0.2, 0.6, 0.9, 0.7)
const COLOR_SLASH_ACTIVE  := Color(0.3, 0.75, 1.0, 0.9)
const COLOR_DASH          := Color(0.2, 0.8, 0.3, 0.7)
const COLOR_DASH_ACTIVE   := Color(0.3, 0.95, 0.4, 0.9)

## Mirrors player.gd's own SWING_REDIRECT_HOLD_THRESHOLD constant BY VALUE
## (hand-kept in sync, same convention already used elsewhere in this project
## for cross-script constants -- e.g. MELEE_RANGE between player.gd and
## bot_controller.gd) -- used ONLY to decide when to swap this button's own
## drawn color below. Never gates any real gameplay decision itself; the
## actual tap-vs-hold call is made in player.gd from the plain held signal
## this file already exposes via get_throw_held()/get_recall_held().
const HOLD_REDIRECT_THRESHOLD: float = 0.1

# Computed screen positions
var _left_base:     Vector2 = Vector2.ZERO
var _throw_center:  Vector2 = Vector2.ZERO
var _slash_center:  Vector2 = Vector2.ZERO
var _dash_center:   Vector2 = Vector2.ZERO

# Touch state
var _left_knob_offset:  Vector2 = Vector2.ZERO
var _throw_held:        bool    = false
var _slash_held:        bool    = false
var _dash_held:         bool    = false

## How long the throw button has been continuously held, in seconds --
## purely for the COLOR_THROW_HOLDING cosmetic swap in _on_canvas_draw()
## (see HOLD_REDIRECT_THRESHOLD's own comment); reset to 0 the instant the
## finger lifts (_handle_touch()'s release branch below).
var _throw_held_time: float = 0.0

# Finger ID tracking (-1 = not claimed)
var _left_finger:   int = -1
var _throw_finger:  int = -1
var _slash_finger:  int = -1
var _dash_finger:   int = -1

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


## Advances _throw_held_time while the button is held, purely to drive the
## COLOR_THROW_HOLDING cosmetic threshold crossing in _on_canvas_draw() (see
## that const's own comment) -- queues a redraw right when the color would
## actually change, not every frame, since draw_circle's own color otherwise
## only needs to change once per press/release cycle.
func _process(delta: float) -> void:
	if _throw_held:
		var was_past: bool = _throw_held_time >= HOLD_REDIRECT_THRESHOLD
		_throw_held_time += delta
		if not was_past and _throw_held_time >= HOLD_REDIRECT_THRESHOLD and _canvas != null:
			_canvas.queue_redraw()


func _update_layout() -> void:
	var sz: Vector2 = get_viewport().get_visible_rect().size
	_left_base    = Vector2(MARGIN + BASE_RADIUS, sz.y - MARGIN - BASE_RADIUS)
	# Task #42: no more right stick -- the three equal-sized buttons form a
	# triangle cluster in the bottom-right corner instead (Throw at the
	# corner, Slash to its left at the same height, Dash centered above the
	# two). All three use the same BUTTON_RADIUS/BUTTON_GAP.
	_throw_center = Vector2(
		sz.x - MARGIN - BUTTON_RADIUS,
		sz.y - MARGIN - BUTTON_RADIUS
	)
	_slash_center = Vector2(
		_throw_center.x - BUTTON_RADIUS * 2.0 - BUTTON_GAP,
		_throw_center.y
	)
	_dash_center = Vector2(
		(_throw_center.x + _slash_center.x) / 2.0,
		_throw_center.y - BUTTON_RADIUS * 2.0 - BUTTON_GAP
	)
	if _canvas != null:
		_canvas.queue_redraw()


func _on_canvas_draw() -> void:
	# --- Left joystick ---
	_canvas.draw_circle(_left_base, BASE_RADIUS, COLOR_BASE)
	_canvas.draw_circle(_left_base + _left_knob_offset, KNOB_RADIUS, COLOR_KNOB)

	# --- Throw button --- (see HOLD_REDIRECT_THRESHOLD's own comment: the
	# distinct COLOR_THROW_HOLDING tint is purely cosmetic feedback for "held
	# long enough that releasing now will Redirect, not tap-Recall")
	var btn_color: Color = COLOR_THROW
	if _throw_held:
		btn_color = COLOR_THROW_HOLDING if _throw_held_time >= HOLD_REDIRECT_THRESHOLD else COLOR_THROW_ACTIVE
	_canvas.draw_circle(_throw_center, BUTTON_RADIUS, btn_color)
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

	# --- Slash button ---
	var slash_color: Color = COLOR_SLASH_ACTIVE if _slash_held else COLOR_SLASH
	_canvas.draw_circle(_slash_center, BUTTON_RADIUS, slash_color)
	if fallback_font != null:
		var slash_label_pos: Vector2 = _slash_center + Vector2(0.0, 8.0)
		_canvas.draw_string(
			fallback_font,
			slash_label_pos,
			"✕",
			HORIZONTAL_ALIGNMENT_CENTER,
			-1,
			22,
			Color.WHITE
		)

	# --- Dash button ---
	var dash_color: Color = COLOR_DASH_ACTIVE if _dash_held else COLOR_DASH
	_canvas.draw_circle(_dash_center, BUTTON_RADIUS, dash_color)
	if fallback_font != null:
		var dash_label_pos: Vector2 = _dash_center + Vector2(0.0, 7.0)
		_canvas.draw_string(
			fallback_font,
			dash_label_pos,
			"»",
			HORIZONTAL_ALIGNMENT_CENTER,
			-1,
			22,
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
		# Priority: left stick, then Throw, then Slash, then Dash. Each zone
		# tracks its own finger id independently (Task #42: this is exactly
		# what makes Dash/Throw/Slash work correctly while the left stick is
		# simultaneously held -- a press landing in one zone never depends on
		# any other zone's current finger state).
		if _left_finger == -1 and pos.distance_to(_left_base) <= BASE_RADIUS:
			_left_finger = event.index
			_left_knob_offset = (pos - _left_base).limit_length(BASE_RADIUS)
			get_viewport().set_input_as_handled()
		elif _throw_finger == -1 and pos.distance_to(_throw_center) <= BUTTON_RADIUS + 20.0:
			_throw_finger = event.index
			_throw_held = true
			_throw_held_time = 0.0
			get_viewport().set_input_as_handled()
		elif _slash_finger == -1 and pos.distance_to(_slash_center) <= BUTTON_RADIUS + 20.0:
			_slash_finger = event.index
			_slash_held = true
			get_viewport().set_input_as_handled()
		elif _dash_finger == -1 and pos.distance_to(_dash_center) <= BUTTON_RADIUS + 20.0:
			_dash_finger = event.index
			_dash_held = true
			get_viewport().set_input_as_handled()
	else:
		# Finger lifted — release whichever zone it owned
		if event.index == _left_finger:
			_left_finger = -1
			_left_knob_offset = Vector2.ZERO
			get_viewport().set_input_as_handled()
		if event.index == _throw_finger:
			_throw_finger = -1
			_throw_held = false
			_throw_held_time = 0.0
			get_viewport().set_input_as_handled()
		if event.index == _slash_finger:
			_slash_finger = -1
			_slash_held = false
			get_viewport().set_input_as_handled()
		if event.index == _dash_finger:
			_dash_finger = -1
			_dash_held = false
			get_viewport().set_input_as_handled()
	if _canvas != null:
		_canvas.queue_redraw()


func _handle_drag(event: InputEventScreenDrag) -> void:
	if event.index == _left_finger:
		_left_knob_offset = (event.position - _left_base).limit_length(BASE_RADIUS)
		get_viewport().set_input_as_handled()
	if _canvas != null:
		_canvas.queue_redraw()


## Returns normalised movement vector in [-1,1] range; Vector2.ZERO when idle.
func get_move() -> Vector2:
	if _left_knob_offset.length() < 0.1:
		return Vector2.ZERO
	return _left_knob_offset / BASE_RADIUS


## Returns true while the throw button is held by a finger.
func get_throw_held() -> bool:
	return _throw_held


## Returns true while the Slash/Kick button is held by a finger -- read by
## player.gd's unified _get_melee_action_held() (Slash with the dart in
## hand, Kick with it away, see this file's own header comment).
func get_slash_held() -> bool:
	return _slash_held


## Returns true while the throw button is held -- Throw and Recall share the
## same touch button now (see this file's header comment), so this is a thin
## alias kept for player.gd call-site symmetry with get_throw_held().
func get_recall_held() -> bool:
	return _throw_held


## Returns true while the Dash button is held by a finger -- read by
## player.gd's _get_dash_pressed() (see this file's header comment, Phase 4.5).
func get_dash_held() -> bool:
	return _dash_held
