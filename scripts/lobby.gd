extends Control
## Lobby: full-screen match-setup UI built entirely in code (mirrors hud.gd style).
## Navigate rows with Up/Down arrows or D-pad; change values with Left/Right or D-pad;
## confirm with Enter / Space / gamepad A.
##
## Phase 1 online: added LOCAL / ONLINE mode selector and online flow.

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
const COLOR_MODE_ACTIVE    := Color(0.30, 0.60, 0.90, 1.0)
const COLOR_MODE_INACTIVE  := Color(0.25, 0.25, 0.35, 1.0)
const COLOR_ONLINE_LABEL   := Color(0.60, 0.85, 1.00, 1.0)

# ---- State ----------------------------------------------------------------
var _total_players:   int = 4
var _human_count:     int = 1
var _bot_difficulty:  int = 0
var _lives_per_round: int = 3
var _rounds_to_win:   int = 3

var _focused_row:  int   = 0
var _value_labels: Array = []   # Label nodes, one per row
var _row_panels:   Array = []   # Panel nodes, one per row

# Mode: 0 = LOCAL, 1 = ONLINE
var _mode: int = 0

# Online sub-screen: "select" | "url" | "host_wait" | "join_code"
var _online_screen: String = "select"

# Local copy of signaling URL (user may edit it)
var _signaling_url: String = "wss://dartrope-signaling.onrender.com"

# Room code being typed by user (join screen)
var _join_code: String = ""

# Expected peer count when host starts
var _connected_peers: int = 1

# ---- Node references set during build ------------------------------------
var _mode_btn_local:  Label = null
var _mode_btn_online: Label = null
var _settings_panel:  Panel = null
var _online_panel:    Panel = null
var _prompt_label:    Label = null

# Online sub-panel labels updated at runtime
var _online_title_lbl:    Label = null
var _online_body_lbl:     Label = null
var _online_url_lbl:      Label = null   # URL display row (select screen)
var _online_bottom_lbl:   Label = null


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
	# Connect NetworkManager signals
	if not NetworkManager.connected_to_room.is_connected(_on_connected_to_room):
		NetworkManager.connected_to_room.connect(_on_connected_to_room)
	if not NetworkManager.guest_joined.is_connected(_on_guest_joined):
		NetworkManager.guest_joined.connect(_on_guest_joined)
	if not NetworkManager.connection_failed.is_connected(_on_connection_failed):
		NetworkManager.connection_failed.connect(_on_connection_failed)
	if not NetworkManager.peer_disconnected.is_connected(_on_peer_disconnected):
		NetworkManager.peer_disconnected.connect(_on_peer_disconnected)


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

	# --- Mode selector row [ LOCAL ] [ ONLINE ] ---
	_build_mode_selector()

	# --- Settings panel (local mode) ---
	_build_settings_panel()

	# --- Online panel (online mode, hidden initially) ---
	_build_online_panel()

	# --- Start prompt ---
	_prompt_label = Label.new()
	_prompt_label.text = "PRESS ENTER / A TO START"
	_prompt_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_prompt_label.add_theme_font_size_override("font_size", 22)
	_prompt_label.add_theme_color_override("font_color", COLOR_PROMPT)
	_prompt_label.set_anchor(SIDE_LEFT,   0.0)
	_prompt_label.set_anchor(SIDE_RIGHT,  1.0)
	_prompt_label.set_anchor(SIDE_TOP,    1.0)
	_prompt_label.set_anchor(SIDE_BOTTOM, 1.0)
	_prompt_label.offset_top    = -68
	_prompt_label.offset_bottom = -30
	add_child(_prompt_label)

	_refresh_all_rows()
	_refresh_mode_ui()


func _build_mode_selector() -> void:
	# A small centered HBox with [ LOCAL ] and [ ONLINE ] labels
	var hbox := HBoxContainer.new()
	hbox.alignment = BoxContainer.ALIGNMENT_CENTER
	hbox.add_theme_constant_override("separation", 24)
	hbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hbox.set_anchor(SIDE_LEFT,   0.0)
	hbox.set_anchor(SIDE_RIGHT,  1.0)
	hbox.offset_top    = 156
	hbox.offset_bottom = 196
	add_child(hbox)

	_mode_btn_local = _make_mode_btn("[ LOCAL ]")
	_mode_btn_online = _make_mode_btn("[ ONLINE ]")
	hbox.add_child(_mode_btn_local)
	hbox.add_child(_mode_btn_online)


func _make_mode_btn(text: String) -> Label:
	var lbl := Label.new()
	lbl.text = text
	lbl.add_theme_font_size_override("font_size", 22)
	lbl.add_theme_color_override("font_color", COLOR_MODE_INACTIVE)
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.vertical_alignment   = VERTICAL_ALIGNMENT_CENTER
	lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return lbl


func _build_settings_panel() -> void:
	const ROW_H:     int = 64
	const PANEL_W:   int = 620
	const PANEL_PAD: int = 10
	var panel_h: int = ROW_DEFS.size() * ROW_H + PANEL_PAD * 2

	_settings_panel = Panel.new()
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
	_settings_panel.add_theme_stylebox_override("panel", panel_style)
	_settings_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_settings_panel.set_anchor(SIDE_LEFT,   0.5)
	_settings_panel.set_anchor(SIDE_RIGHT,  0.5)
	_settings_panel.set_anchor(SIDE_TOP,    0.5)
	_settings_panel.set_anchor(SIDE_BOTTOM, 0.5)
	_settings_panel.offset_left   = -PANEL_W / 2.0
	_settings_panel.offset_right  =  PANEL_W / 2.0
	_settings_panel.offset_top    = -panel_h / 2.0 + 24
	_settings_panel.offset_bottom =  panel_h / 2.0 + 24
	add_child(_settings_panel)

	var rows_vbox := VBoxContainer.new()
	rows_vbox.set_anchors_preset(Control.PRESET_FULL_RECT)
	rows_vbox.offset_left   = PANEL_PAD
	rows_vbox.offset_top    = PANEL_PAD
	rows_vbox.offset_right  = -PANEL_PAD
	rows_vbox.offset_bottom = -PANEL_PAD
	rows_vbox.add_theme_constant_override("separation", 0)
	rows_vbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_settings_panel.add_child(rows_vbox)

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


func _build_online_panel() -> void:
	const PANEL_W: int = 620
	_online_panel = Panel.new()
	var style := StyleBoxFlat.new()
	style.bg_color      = COLOR_PANEL_BG
	style.border_color  = COLOR_PANEL_BORDER
	style.border_width_left   = 2
	style.border_width_right  = 2
	style.border_width_top    = 2
	style.border_width_bottom = 2
	style.corner_radius_top_left     = 10
	style.corner_radius_top_right    = 10
	style.corner_radius_bottom_left  = 10
	style.corner_radius_bottom_right = 10
	_online_panel.add_theme_stylebox_override("panel", style)
	_online_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_online_panel.set_anchor(SIDE_LEFT,   0.5)
	_online_panel.set_anchor(SIDE_RIGHT,  0.5)
	_online_panel.set_anchor(SIDE_TOP,    0.5)
	_online_panel.set_anchor(SIDE_BOTTOM, 0.5)
	_online_panel.offset_left   = -PANEL_W / 2.0
	_online_panel.offset_right  =  PANEL_W / 2.0
	_online_panel.offset_top    = -160 + 24
	_online_panel.offset_bottom =  160 + 24
	_online_panel.visible = false
	add_child(_online_panel)

	var vbox := VBoxContainer.new()
	vbox.set_anchors_preset(Control.PRESET_FULL_RECT)
	vbox.offset_left   = 24
	vbox.offset_top    = 20
	vbox.offset_right  = -24
	vbox.offset_bottom = -20
	vbox.add_theme_constant_override("separation", 14)
	vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_online_panel.add_child(vbox)

	_online_title_lbl = Label.new()
	_online_title_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_online_title_lbl.add_theme_font_size_override("font_size", 26)
	_online_title_lbl.add_theme_color_override("font_color", COLOR_ONLINE_LABEL)
	vbox.add_child(_online_title_lbl)

	_online_url_lbl = Label.new()
	_online_url_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_online_url_lbl.add_theme_font_size_override("font_size", 15)
	_online_url_lbl.add_theme_color_override("font_color", COLOR_DIM)
	_online_url_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(_online_url_lbl)

	_online_body_lbl = Label.new()
	_online_body_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_online_body_lbl.add_theme_font_size_override("font_size", 22)
	_online_body_lbl.add_theme_color_override("font_color", COLOR_TEXT)
	_online_body_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(_online_body_lbl)

	_online_bottom_lbl = Label.new()
	_online_bottom_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_online_bottom_lbl.add_theme_font_size_override("font_size", 18)
	_online_bottom_lbl.add_theme_color_override("font_color", COLOR_DIM)
	vbox.add_child(_online_bottom_lbl)


# ---------------------------------------------------------------------------
# Value accessors
# ---------------------------------------------------------------------------

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


# ---------------------------------------------------------------------------
# Row display
# ---------------------------------------------------------------------------

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


# ---------------------------------------------------------------------------
# Mode UI refresh
# ---------------------------------------------------------------------------

func _refresh_mode_ui() -> void:
	var local_col  := COLOR_MODE_ACTIVE   if _mode == 0 else COLOR_MODE_INACTIVE
	var online_col := COLOR_MODE_ACTIVE   if _mode == 1 else COLOR_MODE_INACTIVE
	_mode_btn_local.add_theme_color_override("font_color", local_col)
	_mode_btn_online.add_theme_color_override("font_color", online_col)

	if _mode == 0:
		_settings_panel.visible = true
		_online_panel.visible   = false
		_prompt_label.text = "PRESS ENTER / A TO START"
	else:
		_settings_panel.visible = false
		_online_panel.visible   = true
		_refresh_online_ui()


func _refresh_online_ui() -> void:
	match _online_screen:
		"select":
			_online_title_lbl.text = "ONLINE MODE"
			_online_url_lbl.text   = "Server: " + _signaling_url
			_online_body_lbl.text  = "[ HOST GAME ]     [ JOIN GAME ]"
			_online_bottom_lbl.text = "Left/Right to choose  |  Enter to confirm"
			_prompt_label.text = ""
		"url":
			_online_title_lbl.text = "SIGNALING SERVER URL"
			_online_url_lbl.text   = ""
			_online_body_lbl.text  = _signaling_url
			_online_bottom_lbl.text = "Type URL, Enter to confirm, Esc to cancel"
			_prompt_label.text = ""
		"host_wait":
			var code_display: String = NetworkManager.room_code if NetworkManager.room_code != "" else "..."
			_online_title_lbl.text = "WAITING FOR PLAYERS"
			_online_url_lbl.text   = ""
			_online_body_lbl.text  = "ROOM CODE:  " + code_display
			_online_bottom_lbl.text = "%d / %d connected  |  Enter to start" % [_connected_peers, _total_players]
			_prompt_label.text = "ENTER = start now  |  ESC = cancel"
		"join_code":
			var display: String = ""
			for k: int in 6:
				if k < _join_code.length():
					display += _join_code[k] + " "
				else:
					display += "_ "
			_online_title_lbl.text = "ENTER ROOM CODE"
			_online_url_lbl.text   = ""
			_online_body_lbl.text  = display.strip_edges()
			_online_bottom_lbl.text = "Type 6-char code  |  Backspace to delete  |  Enter to join  |  Esc to cancel"
			_prompt_label.text = ""

# Track which button is focused on the select screen: 0=HOST, 1=JOIN
var _online_select_focus: int = 0


# ---------------------------------------------------------------------------
# Input
# ---------------------------------------------------------------------------

func _input(event: InputEvent) -> void:
	var vp: Viewport = get_viewport()

	if _mode == 0:
		_input_local(event, vp)
	else:
		_input_online(event, vp)


func _input_local(event: InputEvent, vp: Viewport) -> void:
	if event.is_action_pressed("ui_up"):
		_focused_row = (_focused_row - 1 + ROW_DEFS.size()) % ROW_DEFS.size()
		_refresh_all_rows()
		if vp: vp.set_input_as_handled()
	elif event.is_action_pressed("ui_down"):
		_focused_row = (_focused_row + 1) % ROW_DEFS.size()
		_refresh_all_rows()
		if vp: vp.set_input_as_handled()
	elif event.is_action_pressed("ui_left"):
		# On the first row (top), Left switches to ONLINE mode
		if _focused_row == 0 and false:  # keep simple: Left/Right just change values
			pass
		_change_focused_value(-1)
		if vp: vp.set_input_as_handled()
	elif event.is_action_pressed("ui_right"):
		_change_focused_value(1)
		if vp: vp.set_input_as_handled()
	elif event.is_action_pressed("ui_accept"):
		if vp: vp.set_input_as_handled()
		_start_game_local()
	# Tab / shoulder button to switch modes
	elif event is InputEventKey and (event as InputEventKey).pressed:
		var key_event := event as InputEventKey
		if key_event.keycode == KEY_TAB:
			_mode = 1 - _mode
			_refresh_mode_ui()
			if vp: vp.set_input_as_handled()


func _input_online(event: InputEvent, vp: Viewport) -> void:
	match _online_screen:
		"select":
			_input_online_select(event, vp)
		"url":
			_input_online_url(event, vp)
		"host_wait":
			_input_online_host_wait(event, vp)
		"join_code":
			_input_online_join_code(event, vp)


func _input_online_select(event: InputEvent, vp: Viewport) -> void:
	if event.is_action_pressed("ui_left"):
		_online_select_focus = 0
		_refresh_online_ui()
		if vp: vp.set_input_as_handled()
	elif event.is_action_pressed("ui_right"):
		_online_select_focus = 1
		_refresh_online_ui()
		if vp: vp.set_input_as_handled()
	elif event.is_action_pressed("ui_accept"):
		if vp: vp.set_input_as_handled()
		if _online_select_focus == 0:
			_begin_host()
		else:
			_begin_join()
	elif event is InputEventKey and (event as InputEventKey).pressed:
		var k := (event as InputEventKey).keycode
		if k == KEY_TAB:
			_mode = 0
			_refresh_mode_ui()
			if vp: vp.set_input_as_handled()
		elif k == KEY_ESCAPE:
			_mode = 0
			_refresh_mode_ui()
			if vp: vp.set_input_as_handled()
		elif k == KEY_U:
			# 'U' to edit server URL
			_online_screen = "url"
			_refresh_online_ui()
			if vp: vp.set_input_as_handled()


func _input_online_url(event: InputEvent, vp: Viewport) -> void:
	if event is InputEventKey and (event as InputEventKey).pressed:
		var k := (event as InputEventKey).keycode
		match k:
			KEY_ESCAPE:
				_online_screen = "select"
				_refresh_online_ui()
				if vp: vp.set_input_as_handled()
			KEY_ENTER, KEY_KP_ENTER:
				NetworkManager.set_signaling_url(_signaling_url)
				_online_screen = "select"
				_refresh_online_ui()
				if vp: vp.set_input_as_handled()
			KEY_BACKSPACE:
				if _signaling_url.length() > 0:
					_signaling_url = _signaling_url.left(_signaling_url.length() - 1)
				_refresh_online_ui()
				if vp: vp.set_input_as_handled()
			_:
				var ch: String = (event as InputEventKey).as_text_char()
				if ch.length() == 1 and ch.unicode_at(0) >= 32:
					_signaling_url += ch
					_refresh_online_ui()
					if vp: vp.set_input_as_handled()


func _input_online_host_wait(event: InputEvent, vp: Viewport) -> void:
	if event.is_action_pressed("ui_accept"):
		if vp: vp.set_input_as_handled()
		if _connected_peers >= 2:
			_start_game_online()
	elif event is InputEventKey and (event as InputEventKey).keycode == KEY_ESCAPE and (event as InputEventKey).pressed:
		NetworkManager.disconnect_from_room()
		_connected_peers = 1
		_online_screen = "select"
		_refresh_online_ui()
		if vp: vp.set_input_as_handled()


func _input_online_join_code(event: InputEvent, vp: Viewport) -> void:
	if event is InputEventKey and (event as InputEventKey).pressed:
		var k := (event as InputEventKey).keycode
		match k:
			KEY_ESCAPE:
				_join_code = ""
				_online_screen = "select"
				_refresh_online_ui()
				if vp: vp.set_input_as_handled()
			KEY_BACKSPACE:
				if _join_code.length() > 0:
					_join_code = _join_code.left(_join_code.length() - 1)
				_refresh_online_ui()
				if vp: vp.set_input_as_handled()
			KEY_ENTER, KEY_KP_ENTER:
				if _join_code.length() == 6:
					NetworkManager.set_signaling_url(_signaling_url)
					NetworkManager.join_room(_join_code)
				if vp: vp.set_input_as_handled()
			_:
				if _join_code.length() < 6:
					var ch: String = (event as InputEventKey).as_text_char().to_upper()
					if ch.length() == 1:
						var c: int = ch.unicode_at(0)
						if (c >= 65 and c <= 90) or (c >= 48 and c <= 57):
							_join_code += ch
							_refresh_online_ui()
				if vp: vp.set_input_as_handled()


# ---------------------------------------------------------------------------
# Online flow
# ---------------------------------------------------------------------------

func _begin_host() -> void:
	_connected_peers = 1
	NetworkManager.set_signaling_url(_signaling_url)
	NetworkManager.create_room()
	_online_screen = "host_wait"
	_refresh_online_ui()


func _begin_join() -> void:
	_join_code = ""
	_online_screen = "join_code"
	_refresh_online_ui()


func _on_connected_to_room(code: String, peer_count: int) -> void:
	if NetworkManager.is_host:
		# Already on host_wait screen; refresh to show code
		_refresh_online_ui()
	else:
		# Guest successfully joined
		_connected_peers = peer_count
		_online_screen = "host_wait"   # reuse wait screen to show "waiting for start"
		_online_title_lbl.text = "JOINED ROOM"
		_online_body_lbl.text  = "Room: " + code
		_online_bottom_lbl.text = "Waiting for host to start..."
		_prompt_label.text = ""


func _on_guest_joined(_peer_id: int) -> void:
	_connected_peers += 1
	_refresh_online_ui()


func _on_peer_disconnected(_peer_id: int) -> void:
	if _connected_peers > 1:
		_connected_peers -= 1
	_refresh_online_ui()


func _on_connection_failed(reason: String) -> void:
	_online_title_lbl.text   = "CONNECTION FAILED"
	_online_body_lbl.text    = reason
	_online_bottom_lbl.text  = "Press Esc to go back"
	_prompt_label.text       = ""


# ---------------------------------------------------------------------------
# Scene transition
# ---------------------------------------------------------------------------

func _change_focused_value(delta: int) -> void:
	var def: Array  = ROW_DEFS[_focused_row]
	var key: String = def[0]
	var min_v: int  = def[2]
	var max_v: int  = def[3]
	if key == "human_count":
		max_v = _total_players
	var new_v: int = clamp(_get_value(key) + delta, min_v, max_v)
	_set_value(key, new_v)
	_refresh_all_rows()


func _start_game_local() -> void:
	GameManager.total_players   = _total_players
	GameManager.human_count     = _human_count
	GameManager.bot_difficulty  = _bot_difficulty
	GameManager.lives_per_round = _lives_per_round
	GameManager.rounds_to_win   = _rounds_to_win
	GameManager.is_online       = false
	GameManager.lobby_mode      = false
	get_tree().change_scene_to_file("res://scenes/main.tscn")
	GameManager.call_deferred("_init_game")


func _start_game_online() -> void:
	GameManager.total_players   = _connected_peers
	GameManager.human_count     = _connected_peers  # all real humans
	GameManager.lives_per_round = _lives_per_round
	GameManager.rounds_to_win   = _rounds_to_win
	GameManager.is_online       = true
	GameManager.lobby_mode      = false
	get_tree().change_scene_to_file("res://scenes/main.tscn")
	GameManager.call_deferred("_init_game")
