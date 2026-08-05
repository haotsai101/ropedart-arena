extends CanvasLayer
## HUD: player name panels + a center countdown overlay.
## All UI nodes are created in code so no separate scene editor is needed.
##
## WEAPON/COMBAT SYSTEM REMOVED (branch remove-weapon-system): lives dots,
## round-win pips, and the round-end/match-end overlays are gone -- there is
## no combat outcome left to display (see game_manager.gd's own header
## comment: the state machine now only ever reaches PLAYING and stays there).
## What's left is just player identification panels and the COUNTDOWN "GO!"
## overlay, since GameManager.RoundState.COUNTDOWN still exists.

const MAX_PLAYERS := 6

# Per-player panel references (indexed by player_index)
var _panels: Array = []
var _name_labels: Array = []
var _player_colors: Dictionary = {}

var _overlay: Label
var _root: Control


func _ready() -> void:
	layer = 10
	_build_skeleton()
	call_deferred("_setup_player_panels")


func _build_skeleton() -> void:
	_root = Control.new()
	_root.name = "HUDRoot"
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_root)

	# Panel anchor regions: [left, top, right, bottom] as fractions
	var anchor_regions := [
		[0.0, 0.0, 0.18, 0.10],   # Player 0: top-left
		[0.82, 0.0, 1.0, 0.10],   # Player 1: top-right
		[0.0, 0.90, 0.18, 1.0],   # Player 2: bottom-left
		[0.82, 0.90, 1.0, 1.0],   # Player 3: bottom-right
		[0.41, 0.0, 0.59, 0.08],  # Player 4: top-center
		[0.41, 0.92, 0.59, 1.0],  # Player 5: bottom-center
	]

	_panels.resize(MAX_PLAYERS)
	_name_labels.resize(MAX_PLAYERS)

	for i in MAX_PLAYERS:
		var panel := Panel.new()
		var r: Array = anchor_regions[i]
		panel.set_anchor(SIDE_LEFT,   r[0])
		panel.set_anchor(SIDE_TOP,    r[1])
		panel.set_anchor(SIDE_RIGHT,  r[2])
		panel.set_anchor(SIDE_BOTTOM, r[3])
		panel.offset_left = 8.0 if r[0] == 0.0 else -8.0
		panel.offset_top  = 8.0 if r[1] == 0.0 else -8.0
		panel.offset_right  = -8.0 if r[2] == 1.0 else 8.0
		panel.offset_bottom = -8.0 if r[3] == 1.0 else 8.0
		panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
		panel.visible = false
		_root.add_child(panel)
		_panels[i] = panel

		var lbl := Label.new()
		lbl.set_anchors_preset(Control.PRESET_FULL_RECT)
		lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		lbl.add_theme_font_size_override("font_size", 16)
		lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		panel.add_child(lbl)
		_name_labels[i] = lbl

	# Center countdown overlay
	_overlay = Label.new()
	_overlay.set_anchors_preset(Control.PRESET_CENTER)
	_overlay.offset_left = -200; _overlay.offset_right = 200
	_overlay.offset_top = -60;  _overlay.offset_bottom = 60
	_overlay.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_overlay.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_overlay.add_theme_font_size_override("font_size", 96)
	_overlay.add_theme_color_override("font_color", Color.WHITE)
	_overlay.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.8))
	_overlay.add_theme_constant_override("shadow_offset_x", 3)
	_overlay.add_theme_constant_override("shadow_offset_y", 3)
	_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_overlay.visible = false
	_root.add_child(_overlay)


func _setup_player_panels() -> void:
	var players = get_tree().get_nodes_in_group("players")
	for p in players:
		var idx: int = p.player_index
		var color: Color = p.player_color
		_player_colors[idx] = color

		# Style panel background — colored tint with rounded corners and drop shadow
		# so it stays readable over the bright arena floor.
		var style := StyleBoxFlat.new()
		style.bg_color = Color(color.r, color.g, color.b, 0.55)
		style.border_width_left   = 3
		style.border_width_right  = 3
		style.border_width_top    = 3
		style.border_width_bottom = 3
		style.border_color = Color(color.r, color.g, color.b, 1.0)
		style.corner_radius_top_left    = 8
		style.corner_radius_top_right   = 8
		style.corner_radius_bottom_left = 8
		style.corner_radius_bottom_right = 8
		style.shadow_color = Color(0.0, 0.0, 0.0, 0.35)
		style.shadow_size = 5
		_panels[idx].add_theme_stylebox_override("panel", style)
		_panels[idx].visible = true

		var label: Label = _name_labels[idx]
		label.text = ("P%d" % (idx + 1)) + (" [BOT]" if p.is_bot else "")
		label.add_theme_color_override("font_color", color)


func _process(_delta: float) -> void:
	match GameManager.current_state:
		GameManager.RoundState.COUNTDOWN:
			var t := ceili(GameManager.get_countdown_remaining())
			_overlay.text = "GO!" if t <= 0 else str(t)
			_overlay.add_theme_font_size_override("font_size", 96)
			_overlay.visible = true
		GameManager.RoundState.PLAYING:
			_overlay.visible = false
