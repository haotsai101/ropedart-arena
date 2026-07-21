extends CanvasLayer
## HUD: player panels (lives + round-win pips) and center overlay labels.
## All UI nodes are created in code so no separate scene editor is needed.

const MAX_PLAYERS := 6

# Per-player panel references (indexed by player_index)
var _panels: Array = []
var _name_labels: Array = []
var _dots_containers: Array = []
var _pips_containers: Array = []
var _life_dots: Array = []   # Array of Array[ColorRect]
var _win_pips: Array = []    # Array of Array[ColorRect]
var _player_colors: Dictionary = {}

var _overlay: Label
var _subtitle: Label
var _root: Control


func _ready() -> void:
	layer = 10
	_build_skeleton()
	GameManager.state_changed.connect(_on_state_changed)
	GameManager.round_ended.connect(_on_round_ended)
	GameManager.match_ended.connect(_on_match_ended)
	call_deferred("_setup_player_panels")


func _build_skeleton() -> void:
	_root = Control.new()
	_root.name = "HUDRoot"
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_root)

	# Panel anchor regions: [left, top, right, bottom] as fractions
	var anchor_regions := [
		[0.0, 0.0, 0.18, 0.22],   # Player 0: top-left
		[0.82, 0.0, 1.0, 0.22],   # Player 1: top-right
		[0.0, 0.78, 0.18, 1.0],   # Player 2: bottom-left
		[0.82, 0.78, 1.0, 1.0],   # Player 3: bottom-right
		[0.41, 0.0, 0.59, 0.16],  # Player 4: top-center
		[0.41, 0.84, 0.59, 1.0],  # Player 5: bottom-center
	]

	_panels.resize(MAX_PLAYERS)
	_name_labels.resize(MAX_PLAYERS)
	_dots_containers.resize(MAX_PLAYERS)
	_pips_containers.resize(MAX_PLAYERS)
	_life_dots.resize(MAX_PLAYERS)
	_win_pips.resize(MAX_PLAYERS)

	for i in MAX_PLAYERS:
		_life_dots[i] = []
		_win_pips[i] = []

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

		var vbox := VBoxContainer.new()
		vbox.set_anchors_preset(Control.PRESET_FULL_RECT)
		vbox.offset_left = 6; vbox.offset_top = 4
		vbox.offset_right = -6; vbox.offset_bottom = -4
		vbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
		panel.add_child(vbox)

		var lbl := Label.new()
		lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		lbl.add_theme_font_size_override("font_size", 16)
		vbox.add_child(lbl)
		_name_labels[i] = lbl

		var dots_row := HBoxContainer.new()
		dots_row.alignment = BoxContainer.ALIGNMENT_CENTER
		dots_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
		dots_row.add_theme_constant_override("separation", 4)
		vbox.add_child(dots_row)
		_dots_containers[i] = dots_row

		var pips_row := HBoxContainer.new()
		pips_row.alignment = BoxContainer.ALIGNMENT_CENTER
		pips_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
		pips_row.add_theme_constant_override("separation", 4)
		vbox.add_child(pips_row)
		_pips_containers[i] = pips_row

	# Center overlay label
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
	_overlay.visible = false
	_root.add_child(_overlay)

	# Subtitle below overlay
	_subtitle = Label.new()
	_subtitle.set_anchors_preset(Control.PRESET_CENTER)
	_subtitle.offset_left = -300; _subtitle.offset_right = 300
	_subtitle.offset_top = 50;  _subtitle.offset_bottom = 100
	_subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_subtitle.add_theme_font_size_override("font_size", 26)
	_subtitle.add_theme_color_override("font_color", Color(0.9, 0.9, 0.9, 1.0))
	_subtitle.visible = false
	_root.add_child(_subtitle)


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

		# Life dots — rounded panels so they feel impactful and read against bright arena.
		# Each dot stores its StyleBoxFlat in metadata for quick color updates on kill/reset.
		for _i in GameManager.lives_per_round:
			var dot := Panel.new()
			dot.custom_minimum_size = Vector2(14, 14)
			dot.mouse_filter = Control.MOUSE_FILTER_IGNORE
			var dot_style := StyleBoxFlat.new()
			dot_style.bg_color = color
			dot_style.corner_radius_top_left    = 7
			dot_style.corner_radius_top_right   = 7
			dot_style.corner_radius_bottom_left = 7
			dot_style.corner_radius_bottom_right = 7
			dot_style.shadow_color = Color(0.0, 0.0, 0.0, 0.30)
			dot_style.shadow_size = 2
			dot.add_theme_stylebox_override("panel", dot_style)
			dot.set_meta("style", dot_style)
			dot.set_meta("alive_color", color)
			_dots_containers[idx].add_child(dot)
			_life_dots[idx].append(dot)

		# Win pips — same rounded approach, dim until earned.
		var pip_dim := Color(color.r, color.g, color.b, 0.22)
		for _i in GameManager.rounds_to_win:
			var pip := Panel.new()
			pip.custom_minimum_size = Vector2(10, 10)
			pip.mouse_filter = Control.MOUSE_FILTER_IGNORE
			var pip_style := StyleBoxFlat.new()
			pip_style.bg_color = pip_dim
			pip_style.corner_radius_top_left    = 5
			pip_style.corner_radius_top_right   = 5
			pip_style.corner_radius_bottom_left = 5
			pip_style.corner_radius_bottom_right = 5
			pip.add_theme_stylebox_override("panel", pip_style)
			pip.set_meta("style", pip_style)
			pip.set_meta("alive_color", color)
			pip.set_meta("dim_color", pip_dim)
			_pips_containers[idx].add_child(pip)
			_win_pips[idx].append(pip)

		p.player_killed.connect(_on_player_killed)
		p.player_eliminated.connect(_on_player_eliminated)


func _process(_delta: float) -> void:
	match GameManager.current_state:
		GameManager.RoundState.COUNTDOWN:
			var t := ceili(GameManager.get_countdown_remaining())
			_overlay.text = "GO!" if t <= 0 else str(t)
			_overlay.add_theme_font_size_override("font_size", 96)
			_overlay.visible = true
			_subtitle.visible = false
		GameManager.RoundState.PLAYING:
			_overlay.visible = false
			_subtitle.visible = false
		GameManager.RoundState.MATCH_END:
			if Input.is_action_just_pressed("ui_cancel"):
				get_tree().quit()


func _on_player_killed(player: Variant) -> void:
	var idx: int = player.player_index
	var remaining: int = player.lives
	# Grey out spent lives rather than hiding them — keeps the "total lives" count visible.
	for i in _life_dots[idx].size():
		var dot = _life_dots[idx][i]
		var dot_style := dot.get_meta("style") as StyleBoxFlat
		if i < remaining:
			dot_style.bg_color = dot.get_meta("alive_color")
		else:
			dot_style.bg_color = Color(0.45, 0.45, 0.45, 0.30)


func _on_player_eliminated(player: Variant) -> void:
	_panels[player.player_index].modulate.a = 0.3


func _on_state_changed(new_state: int) -> void:
	if new_state == GameManager.RoundState.COUNTDOWN:
		_reset_panels_for_round()


func _on_round_ended(winner_index: int) -> void:
	if winner_index >= 0:
		var color: Color = _player_colors.get(winner_index, Color.WHITE)
		var wins: int = GameManager.round_wins.get(winner_index, 0)
		_overlay.text = "P%d WINS!" % (winner_index + 1)
		_overlay.add_theme_font_size_override("font_size", 72)
		_overlay.add_theme_color_override("font_color", color)
		_subtitle.text = "Round wins: %d / %d" % [wins, GameManager.rounds_to_win]
		_subtitle.visible = true
		# Light up a win pip — set the stylebox bg_color directly.
		var pip_idx := wins - 1
		if pip_idx >= 0 and pip_idx < _win_pips[winner_index].size():
			var pip = _win_pips[winner_index][pip_idx]
			var pip_style := pip.get_meta("style") as StyleBoxFlat
			pip_style.bg_color = color
	else:
		_overlay.text = "DRAW"
		_overlay.add_theme_color_override("font_color", Color.WHITE)
		_subtitle.visible = false
	_overlay.visible = true


func _reset_panels_for_round() -> void:
	for idx: int in _player_colors.keys():
		_panels[idx].modulate.a = 1.0
		for i in _life_dots[idx].size():
			var dot = _life_dots[idx][i]
			var dot_style := dot.get_meta("style") as StyleBoxFlat
			dot_style.bg_color = dot.get_meta("alive_color")


func _on_match_ended(winner_index: int) -> void:
	_overlay.text = "PLAYER %d\nVICTORY!" % (winner_index + 1)
	_overlay.add_theme_font_size_override("font_size", 64)
	_overlay.add_theme_color_override("font_color", _player_colors.get(winner_index, Color.WHITE))
	_overlay.visible = true
	_subtitle.text = "Thanks for playing — press Escape to quit"
	_subtitle.visible = true
