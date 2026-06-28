extends Control
## Lobby: full-screen match-setup UI built entirely in code (mirrors hud.gd style).
## Navigate rows with Up/Down arrows or D-pad; change values with Left/Right or D-pad;
## confirm with Enter / Space / gamepad A.

const DIFFICULTY_LABELS: Array = ["EASY", "MEDIUM", "HARD"]

## Each entry: [setting_key, display_name, min_value, max_value]
const ROW_DEFS: Array = [
	["total_players",   "TOTAL PLAYERS",   2, 6],
	["human_count",     "HUMAN PLAYERS",   1, 6],
	["bot_difficulty",  "BOT DIFFICULTY",  0, 2],
	["lives_per_round", "LIVES PER ROUND", 1, 5],
	["rounds_to_win",   "ROUNDS TO WIN",   1, 5],
]

const COLOR_BG             := Color(0.04, 0.04, 0.07, 1.0)
const COLOR_PANEL_BG       := Color(0.06, 0.06, 0.10, 1.0)
const COLOR_PANEL_BORDER   := Color(0.18, 0.18, 0.28, 0.7)
const COLOR_ROW_NORMAL     := Color(0.07, 0.07, 0.11, 1.0)
const COLOR_ROW_FOCUSED    := Color(0.10, 0.17, 0.32, 1.0)
const COLOR_BORDER_NORMAL  := Color(0.12, 0.12, 0.20, 0.5)
const COLOR_BORDER_FOCUSED := Color(0.28, 0.50, 0.85, 0.9)
const COLOR_TITLE          := Color(0.30, 0.60, 0.90, 1.0)
const COLOR_TEXT           := Color(0.90, 0.90, 0.90, 1.0)
const COLOR_DIM            := Color(0.45, 0.45, 0.55, 1.0)
const COLOR_VALUE          := Color(0.30, 0.60, 0.90, 1.0)
const COLOR_PROMPT         := Color(0.70, 0.80, 1.00, 1.0)

var _total_players:   int = 4
var _human_count:     int = 1
var _bot_difficulty:  int = 0
var _lives_per_round: int = 3
var _rounds_to_win:   int = 3

var _focused_row:  int   = 0
var _value_labels: Array = []   # Array of Label nodes, one per row
var _row_panels:   Array = []   # Array of Panel nodes, one per row


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	# Seed from GameManager defaults so re-entering the lobby keeps last values
	_total_players   = GameManager.total_players
	_human_count     = GameManager.human_count
	_bot_difficulty  = GameManager.bot_difficulty
	_lives_per_round = GameManager.lives_per_round
	_rounds_to_win   = GameManager.rounds_to_win
	_build_ui()


func _build_ui() -> void:
	# --- Background ---
	var bg := ColorRect.new()
	bg.color = COLOR_BG
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)

	# --- Title ---
	var title := Label.new()
	title.text = "DARTROPE ARENA"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 64)
	title.add_theme_color_override("font_color", COLOR_TITLE)
	title.add_theme_color_override("font_shadow_color", Color(0.0, 0.15, 0.5, 0.75))
	title.add_theme_constant_override("shadow_offset_x", 3)
	title.add_theme_constant_override("shadow_offset_y", 3)
	title.set_anchor(SIDE_LEFT,  0.0)
	title.set_anchor(SIDE_RIGHT, 1.0)
	title.offset_top    = 44
	title.offset_bottom = 124
	add_child(title)

	# --- Subtitle ---
	var subtitle := Label.new()
	subtitle.text = "MATCH SETUP"
	subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	subtitle.add_theme_font_size_override("font_size", 20)
	subtitle.add_theme_color_override("font_color", COLOR_DIM)
	subtitle.set_anchor(SIDE_LEFT,  0.0)
	subtitle.set_anchor(SIDE_RIGHT, 1.0)
	subtitle.offset_top    = 122
	subtitle.offset_bottom = 152
	add_child(subtitle)

	# --- Settings panel (centered) ---
	const ROW_H:    int = 64
	const PANEL_W:  int = 620
	const PANEL_PAD: int = 10
	var panel_h: int = ROW_DEFS.size() * ROW_H + PANEL_PAD * 2

	var settings_panel := Panel.new()
	var panel_style := StyleBoxFlat.new()
	panel_style.bg_color      = COLOR_PANEL_BG
	panel_style.border_color  = COLOR_PANEL_BORDER
	panel_style.border_width_left   = 2
	panel_style.border_width_right  = 2
	panel_style.border_width_top    = 2
	panel_style.border_width_bottom = 2
	panel_style.corner_radius_top_left     = 10
	panel_style.corner_radius_top_right    = 10
	panel_style.corner_radius_bottom_left  = 10
	panel_style.corner_radius_bottom_right = 10
	settings_panel.add_theme_stylebox_override("panel", panel_style)
	settings_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	settings_panel.set_anchor(SIDE_LEFT,   0.5)
	settings_panel.set_anchor(SIDE_RIGHT,  0.5)
	settings_panel.set_anchor(SIDE_TOP,    0.5)
	settings_panel.set_anchor(SIDE_BOTTOM, 0.5)
	settings_panel.offset_left   = -PANEL_W / 2.0
	settings_panel.offset_right  =  PANEL_W / 2.0
	settings_panel.offset_top    = -panel_h / 2.0
	settings_panel.offset_bottom =  panel_h / 2.0
	add_child(settings_panel)

	var rows_vbox := VBoxContainer.new()
	rows_vbox.set_anchors_preset(Control.PRESET_FULL_RECT)
	rows_vbox.offset_left   = PANEL_PAD
	rows_vbox.offset_top    = PANEL_PAD
	rows_vbox.offset_right  = -PANEL_PAD
	rows_vbox.offset_bottom = -PANEL_PAD
	rows_vbox.add_theme_constant_override("separation", 0)
	rows_vbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	settings_panel.add_child(rows_vbox)

	for i in ROW_DEFS.size():
		var row_panel := Panel.new()
		row_panel.custom_minimum_size = Vector2(0, ROW_H)
		row_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
		rows_vbox.add_child(row_panel)
		_row_panels.append(row_panel)

		var row_hbox := HBoxContainer.new()
		row_hbox.set_anchors_preset(Control.PRESET_FULL_RECT)
		row_hbox.offset_left   = 20
		row_hbox.offset_top    = 0
		row_hbox.offset_right  = -20
		row_hbox.offset_bottom = 0
		row_hbox.alignment = BoxContainer.ALIGNMENT_CENTER
		row_hbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row_panel.add_child(row_hbox)

		var def: Array = ROW_DEFS[i]
		var name_lbl := Label.new()
		name_lbl.text = def[1]
		name_lbl.add_theme_font_size_override("font_size", 20)
		name_lbl.add_theme_color_override("font_color", COLOR_TEXT)
		name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		name_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		row_hbox.add_child(name_lbl)

		var arrow_l := Label.new()
		arrow_l.text = "◀"
		arrow_l.add_theme_font_size_override("font_size", 20)
		arrow_l.add_theme_color_override("font_color", COLOR_DIM)
		arrow_l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		row_hbox.add_child(arrow_l)

		var val_lbl := Label.new()
		val_lbl.custom_minimum_size = Vector2(160, 0)
		val_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		val_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		val_lbl.add_theme_font_size_override("font_size", 24)
		val_lbl.add_theme_color_override("font_color", COLOR_VALUE)
		row_hbox.add_child(val_lbl)
		_value_labels.append(val_lbl)

		var arrow_r := Label.new()
		arrow_r.text = "▶"
		arrow_r.add_theme_font_size_override("font_size", 20)
		arrow_r.add_theme_color_override("font_color", COLOR_DIM)
		arrow_r.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		row_hbox.add_child(arrow_r)

	# --- Start prompt at the bottom ---
	var prompt := Label.new()
	prompt.text = "PRESS ENTER / A TO START"
	prompt.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	prompt.add_theme_font_size_override("font_size", 22)
	prompt.add_theme_color_override("font_color", COLOR_PROMPT)
	prompt.set_anchor(SIDE_LEFT,   0.0)
	prompt.set_anchor(SIDE_RIGHT,  1.0)
	prompt.set_anchor(SIDE_TOP,    1.0)
	prompt.set_anchor(SIDE_BOTTOM, 1.0)
	prompt.offset_top    = -68
	prompt.offset_bottom = -30
	add_child(prompt)

	_refresh_all_rows()


# --- Value accessors -------------------------------------------------------

func _get_value(key: String) -> int:
	match key:
		"total_players":   return _total_players
		"human_count":     return _human_count
		"bot_difficulty":  return _bot_difficulty
		"lives_per_round": return _lives_per_round
		"rounds_to_win":   return _rounds_to_win
	return 0


func _set_value(key: String, v: int) -> void:
	match key:
		"total_players":
			_total_players = v
			# Clamp human_count so it never exceeds total_players
			_human_count = mini(_human_count, _total_players)
		"human_count":
			_human_count = v
		"bot_difficulty":
			_bot_difficulty = v
		"lives_per_round":
			_lives_per_round = v
		"rounds_to_win":
			_rounds_to_win = v


func _value_display(key: String, v: int) -> String:
	if key == "bot_difficulty":
		return DIFFICULTY_LABELS[v] as String
	return str(v)


# --- Row display -----------------------------------------------------------

func _refresh_all_rows() -> void:
	for i in ROW_DEFS.size():
		var def: Array   = ROW_DEFS[i]
		var key: String  = def[0]
		var lbl: Label   = _value_labels[i]
		lbl.text = _value_display(key, _get_value(key))
		_apply_row_style(i)


func _apply_row_style(i: int) -> void:
	var row_panel: Panel = _row_panels[i]
	var style := StyleBoxFlat.new()
	if i == _focused_row:
		style.bg_color     = COLOR_ROW_FOCUSED
		style.border_color = COLOR_BORDER_FOCUSED
	else:
		style.bg_color     = COLOR_ROW_NORMAL
		style.border_color = COLOR_BORDER_NORMAL
	style.border_width_left   = 2
	style.border_width_right  = 2
	style.border_width_top    = 1
	style.border_width_bottom = 1
	style.corner_radius_top_left     = 4
	style.corner_radius_top_right    = 4
	style.corner_radius_bottom_left  = 4
	style.corner_radius_bottom_right = 4
	row_panel.add_theme_stylebox_override("panel", style)


# --- Input -----------------------------------------------------------------

func _input(event: InputEvent) -> void:
	# Cache viewport early: change_scene_to_file synchronously detaches this node
	# from the viewport chain, so get_viewport() returns null after _start_game().
	var vp: Viewport = get_viewport()
	if event.is_action_pressed("ui_up"):
		_focused_row = (_focused_row - 1 + ROW_DEFS.size()) % ROW_DEFS.size()
		_refresh_all_rows()
		if vp:
			vp.set_input_as_handled()
	elif event.is_action_pressed("ui_down"):
		_focused_row = (_focused_row + 1) % ROW_DEFS.size()
		_refresh_all_rows()
		if vp:
			vp.set_input_as_handled()
	elif event.is_action_pressed("ui_left"):
		_change_focused_value(-1)
		if vp:
			vp.set_input_as_handled()
	elif event.is_action_pressed("ui_right"):
		_change_focused_value(1)
		if vp:
			vp.set_input_as_handled()
	elif event.is_action_pressed("ui_accept"):
		# Consume BEFORE _start_game so the viewport is still valid.
		if vp:
			vp.set_input_as_handled()
		_start_game()


func _change_focused_value(delta: int) -> void:
	var def: Array  = ROW_DEFS[_focused_row]
	var key: String = def[0]
	var min_v: int  = def[2]
	var max_v: int  = def[3]
	# human_count ceiling is dynamic: may not exceed current total_players
	if key == "human_count":
		max_v = _total_players
	var new_v: int = clamp(_get_value(key) + delta, min_v, max_v)
	_set_value(key, new_v)
	_refresh_all_rows()


# --- Scene transition ------------------------------------------------------

func _start_game() -> void:
	GameManager.total_players   = _total_players
	GameManager.human_count     = _human_count
	GameManager.bot_difficulty  = _bot_difficulty
	GameManager.lives_per_round = _lives_per_round
	GameManager.rounds_to_win   = _rounds_to_win
	GameManager.lobby_mode      = false
	# change_scene_to_file queues a deferred _change_scene call internally.
	# We then queue _init_game so it processes AFTER the scene swap completes.
	# The safety re-defer inside _init_game catches any ordering edge cases.
	get_tree().change_scene_to_file("res://scenes/main.tscn")
	GameManager.call_deferred("_init_game")
