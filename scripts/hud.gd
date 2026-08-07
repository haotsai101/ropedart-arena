extends CanvasLayer
## HUD: player name panels + a center countdown/round/match overlay.
## All UI nodes are created in code so no separate scene editor is needed.
##
## Phase 5 (docs/implementation-plan.md) restored what the weapon-system
## strip-down removed: per-player life dots (a small row of circles under each
## name, live-updated from player.gd's `lives` field every frame -- see
## _update_player_status()), round-win pips (persist across rounds within a
## match, filled from GameManager.round_wins), and center overlays for
## ROUND_END ("<name> wins the round!", brief, GameManager itself owns the
## timing/transition back to COUNTDOWN -- see game_manager.gd's ROUND_END
## _process branch) and MATCH_END ("<name> wins the match!", static -- see
## GameManager's own _apply_round_result() comment on that being a deliberate,
## flagged judgment call: no further action happens after this).

const MAX_PLAYERS := 6

# Per-player panel references (indexed by player_index)
var _panels: Array = []
var _name_labels: Array = []
var _life_dot_rows: Array = []   # Array[Array[Control]] -- one row of dot nodes per player
var _pip_rows: Array = []        # Array[Array[Control]] -- one row of pip nodes per player
var _player_colors: Dictionary = {}
var _player_refs: Array = []     # Array[Node] -- the actual player.gd node per index, for live polling
## Cached per-player dot/pip counts (built once in _setup_player_panels() off
## GameManager.lives_per_round/rounds_to_win at match start) -- see those
## exports' own comments in game_manager.gd for why this isn't re-read every
## frame (a mid-match config change isn't a supported case here).
var _life_dot_capacity: int = 3
var _pip_capacity: int = 2

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

	# Panel anchor regions: [left, top, right, bottom] as fractions. Slightly
	# taller than the pre-Phase-5 layout (0.10 -> 0.15 for the corner slots) to
	# make room for the life-dot and round-win-pip rows below the name label.
	var anchor_regions := [
		[0.0, 0.0, 0.18, 0.15],   # Player 0: top-left
		[0.82, 0.0, 1.0, 0.15],   # Player 1: top-right
		[0.0, 0.85, 0.18, 1.0],   # Player 2: bottom-left
		[0.82, 0.85, 1.0, 1.0],   # Player 3: bottom-right
		[0.41, 0.0, 0.59, 0.13],  # Player 4: top-center
		[0.41, 0.87, 0.59, 1.0],  # Player 5: bottom-center
	]

	_panels.resize(MAX_PLAYERS)
	_name_labels.resize(MAX_PLAYERS)
	_life_dot_rows.resize(MAX_PLAYERS)
	_pip_rows.resize(MAX_PLAYERS)
	_player_refs.resize(MAX_PLAYERS)

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

		var vbox := VBoxContainer.new()
		vbox.set_anchors_preset(Control.PRESET_FULL_RECT)
		vbox.offset_left = 4.0
		vbox.offset_top = 2.0
		vbox.offset_right = -4.0
		vbox.offset_bottom = -2.0
		vbox.add_theme_constant_override("separation", 2)
		vbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
		vbox.alignment = BoxContainer.ALIGNMENT_CENTER
		panel.add_child(vbox)

		var lbl := Label.new()
		lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		lbl.add_theme_font_size_override("font_size", 16)
		lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		vbox.add_child(lbl)
		_name_labels[i] = lbl

		var life_row := HBoxContainer.new()
		life_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
		life_row.alignment = BoxContainer.ALIGNMENT_CENTER
		life_row.add_theme_constant_override("separation", 3)
		vbox.add_child(life_row)
		_life_dot_rows[i] = life_row

		var pip_row := HBoxContainer.new()
		pip_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
		pip_row.alignment = BoxContainer.ALIGNMENT_CENTER
		pip_row.add_theme_constant_override("separation", 3)
		vbox.add_child(pip_row)
		_pip_rows[i] = pip_row

	# Center countdown/round/match overlay -- shared Label, text/size swapped
	# per GameManager.current_state in _process() below.
	_overlay = Label.new()
	_overlay.set_anchors_preset(Control.PRESET_CENTER)
	_overlay.offset_left = -260; _overlay.offset_right = 260
	_overlay.offset_top = -70;  _overlay.offset_bottom = 70
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
	_life_dot_capacity = maxi(GameManager.lives_per_round, 1)
	_pip_capacity = maxi(GameManager.rounds_to_win, 1)
	var players = get_tree().get_nodes_in_group("players")
	for p in players:
		var idx: int = p.player_index
		var color: Color = p.player_color
		_player_colors[idx] = color
		_player_refs[idx] = p

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

		_build_dot_row(_life_dot_rows[idx], _life_dot_capacity, color)
		_build_dot_row(_pip_rows[idx], _pip_capacity, Color(1.0, 0.85, 0.2))


## Shared builder for both the life-dot row and the round-win-pip row --
## same "row of N small colored squares, filled/empty state toggled later by
## _update_player_status()" shape for both, just a different fill color
## (player_color for lives, a shared gold for round-win pips so a pip reads
## as "trophy-like" rather than being confused for another life dot).
func _build_dot_row(row: Control, count: int, fill_color: Color) -> void:
	for child in row.get_children():
		child.queue_free()
	for i in count:
		var dot := ColorRect.new()
		dot.custom_minimum_size = Vector2(10, 10)
		dot.color = fill_color
		dot.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(dot)


## Live per-frame refresh of life dots / round-win pips / eliminated-panel
## dimming -- polls player.lives and GameManager.round_wins directly rather
## than reacting to a signal, matching this file's existing "read GameManager/
## player state every _process() tick" convention (see the COUNTDOWN branch
## below, already doing exactly this for the countdown timer).
func _update_player_status() -> void:
	for idx in MAX_PLAYERS:
		var p = _player_refs[idx]
		if p == null or not is_instance_valid(p):
			continue
		var lives: int = int(p.get("lives")) if p.get("lives") != null else _life_dot_capacity
		var dots: Array = _life_dot_rows[idx].get_children()
		for i in dots.size():
			dots[i].modulate.a = 1.0 if i < lives else 0.15

		var wins: int = int(GameManager.round_wins.get(idx, 0))
		var pips: Array = _pip_rows[idx].get_children()
		for i in pips.size():
			pips[i].modulate.a = 1.0 if i < wins else 0.15

		# Eliminated-this-round players are already visually "out" in the
		# arena itself (player.gd's _eliminate() hides their model) -- dim
		# their HUD panel too so it's clear at a glance without hunting for
		# their character on the map.
		var eliminated: bool = p.get("is_eliminated") == true
		_panels[idx].modulate.a = 0.45 if eliminated else 1.0


func _process(_delta: float) -> void:
	match GameManager.current_state:
		GameManager.RoundState.COUNTDOWN:
			var t := ceili(GameManager.get_countdown_remaining())
			_overlay.text = "GO!" if t <= 0 else str(t)
			_overlay.add_theme_font_size_override("font_size", 96)
			_overlay.visible = true
		GameManager.RoundState.PLAYING:
			_overlay.visible = false
		GameManager.RoundState.ROUND_END:
			var winner_name := _display_name_for(GameManager.last_round_winner_index)
			_overlay.text = ("%s wins the round!" % winner_name) if GameManager.last_round_winner_index >= 0 else "Round Draw!"
			_overlay.add_theme_font_size_override("font_size", 54)
			_overlay.visible = true
		GameManager.RoundState.MATCH_END:
			var match_winner_name := _display_name_for(GameManager.match_winner_index)
			_overlay.text = "%s wins the match!" % match_winner_name
			_overlay.add_theme_font_size_override("font_size", 64)
			_overlay.visible = true
	_update_player_status()


func _display_name_for(idx: int) -> String:
	if idx < 0 or idx >= _name_labels.size() or _name_labels[idx] == null:
		return "Nobody"
	var lbl: Label = _name_labels[idx]
	return lbl.text if lbl.text != "" else ("P%d" % (idx + 1))
