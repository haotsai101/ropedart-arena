extends Control
## Lobby: multi-screen online match-setup UI built entirely in code.
## Screens: "username" → "browser" → "waiting"
## _set_screen() transitions between them by rebuilding all child nodes.

const DIFFICULTY_LABELS: Array = ["Easy", "Medium", "Hard"]
const DIFF_LABEL_UPPER: Array = ["EASY", "MEDIUM", "HARD"]

const MAP_LABELS: Array = ["Desert", "Forest"]
const MAP_SCENES: Array = ["res://scenes/main.tscn", "res://scenes/main_forest.tscn"]

# Colors — warm cheerful palette inspired by couch-coop party aesthetics
# Background is a soft sage field; panels are warm cream cards on top.
# All text is dark-on-light (contrast flipped from the old dark-tech scheme).
const COLOR_BG             := Color(0.86, 0.90, 0.78, 1.0)  # warm sage field
const COLOR_PANEL_BG       := Color(0.98, 0.96, 0.90, 1.0)  # cream card
const COLOR_PANEL_BORDER   := Color(0.58, 0.68, 0.46, 0.65) # sage-green border
const COLOR_ROW_NORMAL     := Color(0.93, 0.91, 0.84, 1.0)  # warm cream row
const COLOR_ROW_FOCUSED    := Color(0.78, 0.91, 0.72, 1.0)  # soft sage when active
const COLOR_BORDER_NORMAL  := Color(0.58, 0.64, 0.44, 0.45) # warm tan outline
const COLOR_BORDER_FOCUSED := Color(0.18, 0.65, 0.36, 0.90) # vivid green focus ring
const COLOR_TITLE          := Color(0.88, 0.36, 0.07, 1.0)  # warm tomato-orange (party logo energy)
const COLOR_TEXT           := Color(0.14, 0.11, 0.09, 1.0)  # near-black warm brown
const COLOR_DIM            := Color(0.40, 0.37, 0.30, 1.0)  # warm grey for hints/labels
const COLOR_VALUE          := Color(0.08, 0.40, 0.62, 1.0)  # teal-blue for values
const COLOR_PROMPT         := Color(0.08, 0.36, 0.60, 1.0)  # deeper teal for prompts
const COLOR_ACCENT         := Color(0.88, 0.36, 0.07, 1.0)  # orange accent (selected text)
const COLOR_ROW_SELECTED   := Color(0.74, 0.90, 0.68, 1.0)  # sage green highlight
const COLOR_HOST_TAG       := Color(0.84, 0.50, 0.08, 1.0)  # warm amber for host crown

# ---------------------------------------------------------------------------
# Persistent state (survives _rebuild_ui)
# ---------------------------------------------------------------------------

var _screen: String = "username"

# Username screen
var _typed_username: String = ""
var _cursor_timer: float = 0.0
var _cursor_blink: bool = true

# Browser screen
var _browser_rooms: Array = []
var _browser_selected: int = 0
var _browser_loading: bool = false
var _browser_refresh_timer: float = 0.0

# Waiting screen (host settings)
var _wait_settings_focus: int = 0   # 0 = max_players row, 1 = bot_difficulty row, 2 = map row
var _lives_value: int = 3
var _rounds_value: int = 3

# Local config screen
var _local_total_players: int = 4
var _local_bot_difficulty: int = 0
var _local_map_id: int = 0
var _local_focus: int = 0   # 0 = total players, 1 = difficulty, 2 = map

# Character selection — local game
var _char_cursor: int = 0       # index into GameManager.CHARACTER_DEFS
var _headwear_cursor: int = 0   # index into GameManager.HEADWEAR_DEFS
var _cloth_cursor: int = 0      # index into GameManager.CLOTH_DEFS
var _char_slot: int = 0         # which cycler row L/R affects: 0=base 1=headwear 2=cloth

# Character selection — online waiting lobby
var _wait_char_cursor: int = 0       # index into GameManager.CHARACTER_DEFS
var _wait_headwear_cursor: int = 0   # index into GameManager.HEADWEAR_DEFS
var _wait_cloth_cursor: int = 0      # index into GameManager.CLOTH_DEFS
var _wait_char_slot: int = 0      # which cycler row L/R affects within the char area: 0=base 1=headwear 2=cloth
var _wait_area: int = 0           # 0=settings area (host), 1=char-picker area

# Error/transition timer
var _error_timer: float = 0.0
var _error_message: String = ""

# ---------------------------------------------------------------------------
# Live-update label references (set during _rebuild_ui, nulled before rebuild)
# ---------------------------------------------------------------------------
var _username_input_lbl: Label = null      # username screen input display

var _browser_status_lbl: Label = null      # "Loading..." or ""
var _browser_rooms_vbox: VBoxContainer = null

var _wait_players_vbox: VBoxContainer = null
var _wait_settings_max_lbl: Label = null
var _wait_settings_diff_lbl: Label = null
var _wait_settings_map_lbl: Label = null
var _wait_code_lbl: Label = null
var _wait_prompt_lbl: Label = null
var _wait_error_lbl: Label = null

var _local_total_lbl: Label = null
var _local_diff_lbl: Label = null
var _local_map_lbl: Label = null


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_process_input(true)
	set_process_unhandled_input(true)


	# Connect NetworkManager signals once; callbacks check _screen
	NetworkManager.rooms_fetched.connect(_on_rooms_fetched)
	NetworkManager.connected_to_room.connect(_on_connected_to_room)
	NetworkManager.player_list_updated.connect(_on_player_list_updated)
	NetworkManager.settings_updated.connect(_on_settings_updated)
	NetworkManager.game_starting.connect(_on_game_starting)
	NetworkManager.host_disconnected.connect(_on_host_disconnected)
	NetworkManager.peer_disconnected.connect(_on_peer_disconnected)
	NetworkManager.connection_failed.connect(_on_connection_failed)
	NetworkManager.character_chosen.connect(_on_character_chosen)
	NetworkManager.headwear_chosen.connect(_on_character_chosen)
	NetworkManager.cloth_chosen.connect(_on_character_chosen)

	if UsernameManager.has_username():
		_set_screen("browser")
	else:
		_set_screen("username")


func _exit_tree() -> void:
	if NetworkManager.rooms_fetched.is_connected(_on_rooms_fetched):
		NetworkManager.rooms_fetched.disconnect(_on_rooms_fetched)
	if NetworkManager.connected_to_room.is_connected(_on_connected_to_room):
		NetworkManager.connected_to_room.disconnect(_on_connected_to_room)
	if NetworkManager.player_list_updated.is_connected(_on_player_list_updated):
		NetworkManager.player_list_updated.disconnect(_on_player_list_updated)
	if NetworkManager.settings_updated.is_connected(_on_settings_updated):
		NetworkManager.settings_updated.disconnect(_on_settings_updated)
	if NetworkManager.game_starting.is_connected(_on_game_starting):
		NetworkManager.game_starting.disconnect(_on_game_starting)
	if NetworkManager.host_disconnected.is_connected(_on_host_disconnected):
		NetworkManager.host_disconnected.disconnect(_on_host_disconnected)
	if NetworkManager.peer_disconnected.is_connected(_on_peer_disconnected):
		NetworkManager.peer_disconnected.disconnect(_on_peer_disconnected)
	if NetworkManager.connection_failed.is_connected(_on_connection_failed):
		NetworkManager.connection_failed.disconnect(_on_connection_failed)
	if NetworkManager.character_chosen.is_connected(_on_character_chosen):
		NetworkManager.character_chosen.disconnect(_on_character_chosen)
	if NetworkManager.headwear_chosen.is_connected(_on_character_chosen):
		NetworkManager.headwear_chosen.disconnect(_on_character_chosen)
	if NetworkManager.cloth_chosen.is_connected(_on_character_chosen):
		NetworkManager.cloth_chosen.disconnect(_on_character_chosen)


# ---------------------------------------------------------------------------
# Screen management
# ---------------------------------------------------------------------------

func _set_screen(screen_name: String) -> void:
	_screen = screen_name
	_rebuild_ui()


func _rebuild_ui() -> void:
	# Null out all live-update refs before freeing children
	_username_input_lbl = null
	_browser_status_lbl = null
	_browser_rooms_vbox = null
	_wait_players_vbox = null
	_wait_settings_max_lbl = null
	_wait_settings_diff_lbl = null
	_wait_settings_map_lbl = null
	_wait_code_lbl = null
	_wait_prompt_lbl = null
	_wait_error_lbl = null
	_local_total_lbl = null
	_local_diff_lbl = null
	_local_map_lbl = null

	for child in get_children():
		child.queue_free()

	# Background
	var bg := ColorRect.new()
	bg.color = COLOR_BG
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)

	match _screen:
		"username":
			_build_username_screen()
		"browser":
			_build_browser_screen()
		"waiting":
			_build_waiting_screen()
		"local_config":
			_build_local_config_screen()
		"char_select_local":
			_build_char_select_local_screen()


# ---------------------------------------------------------------------------
# _process — timers for cursor, auto-refresh, error delay
# ---------------------------------------------------------------------------

func _process(delta: float) -> void:
	match _screen:
		"username":
			_cursor_timer += delta
			if _cursor_timer >= 0.5:
				_cursor_timer = 0.0
				_cursor_blink = not _cursor_blink
				_update_username_cursor()
		"browser":
			if not _browser_loading:
				_browser_refresh_timer += delta
				if _browser_refresh_timer >= 5.0:
					_browser_refresh_timer = 0.0
					_do_fetch_rooms()
		"waiting":
			if _error_timer > 0.0:
				_error_timer -= delta
				if _error_timer <= 0.0:
					_error_message = ""
					_set_screen("browser")


# ===========================================================================
# SCREEN 1: USERNAME
# ===========================================================================

func _build_username_screen() -> void:
	_add_title("ROPE DART ARENA", 80)
	_add_subtitle("Enter your username", 20)

	var vp_size: Vector2 = get_viewport_rect().size
	var vw: float = vp_size.x
	var vh: float = vp_size.y
	var panel_w: float = vw * 0.52
	var panel_h: float = vh * 0.28

	var panel := _make_panel(int(panel_w), int(panel_h), 0)
	add_child(panel)

	var inset: float = vw * 0.03
	var vbox := VBoxContainer.new()
	vbox.set_anchors_preset(Control.PRESET_FULL_RECT)
	vbox.offset_left = inset
	vbox.offset_top = vh * 0.03
	vbox.offset_right = -inset
	vbox.offset_bottom = -(vh * 0.03)
	vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_theme_constant_override("separation", 16)
	vbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(vbox)

	var hint := Label.new()
	hint.text = "A-Z  0-9  _   Backspace to delete   Enter to confirm"
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.add_theme_font_size_override("font_size", _fs(15))
	hint.add_theme_color_override("font_color", COLOR_DIM)
	vbox.add_child(hint)

	_username_input_lbl = Label.new()
	_username_input_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_username_input_lbl.add_theme_font_size_override("font_size", _fs(36))
	_username_input_lbl.add_theme_color_override("font_color", COLOR_VALUE)
	vbox.add_child(_username_input_lbl)

	var min_hint := Label.new()
	min_hint.text = "2 – 16 characters"
	min_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	min_hint.add_theme_font_size_override("font_size", _fs(14))
	min_hint.add_theme_color_override("font_color", COLOR_DIM)
	vbox.add_child(min_hint)

	_update_username_cursor()


func _update_username_cursor() -> void:
	if _username_input_lbl == null:
		return
	var cursor: String = "_" if _cursor_blink else " "
	_username_input_lbl.text = "> " + _typed_username + cursor


# ===========================================================================
# SCREEN 2: BROWSER
# ===========================================================================

func _build_browser_screen() -> void:
	_add_title("ROPE DART ARENA", 80)
	_add_subtitle("Welcome,  " + UsernameManager.username, 20)

	var vp_size: Vector2 = get_viewport_rect().size
	var vw: float = vp_size.x
	var vh: float = vp_size.y
	var panel_w: float = vw * 0.72
	var panel_h: float = vh * 0.62

	var panel := _make_panel(int(panel_w), int(panel_h), 0)
	add_child(panel)

	var root_vbox := VBoxContainer.new()
	root_vbox.set_anchors_preset(Control.PRESET_FULL_RECT)
	root_vbox.offset_left = 0
	root_vbox.offset_top = 0
	root_vbox.offset_right = 0
	root_vbox.offset_bottom = 0
	root_vbox.add_theme_constant_override("separation", 0)
	root_vbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(root_vbox)

	# Header row
	var header := _make_browser_row_label("  ROOM CODE        HOST              PLAYERS     DIFFICULTY", false)
	header.add_theme_color_override("font_color", COLOR_DIM)
	header.add_theme_font_size_override("font_size", _fs(15))
	header.custom_minimum_size = Vector2(0, vh * 0.05)
	root_vbox.add_child(header)

	# Separator
	var sep := HSeparator.new()
	sep.add_theme_color_override("color", COLOR_PANEL_BORDER)
	sep.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root_vbox.add_child(sep)

	# Status label (loading / empty)
	_browser_status_lbl = Label.new()
	_browser_status_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_browser_status_lbl.add_theme_font_size_override("font_size", _fs(20))
	_browser_status_lbl.add_theme_color_override("font_color", COLOR_DIM)
	_browser_status_lbl.custom_minimum_size = Vector2(0, vh * 0.055)
	_browser_status_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root_vbox.add_child(_browser_status_lbl)

	# Scrollable rooms list
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root_vbox.add_child(scroll)

	_browser_rooms_vbox = VBoxContainer.new()
	_browser_rooms_vbox.set_anchors_preset(Control.PRESET_FULL_RECT)
	_browser_rooms_vbox.add_theme_constant_override("separation", 2)
	_browser_rooms_vbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_browser_rooms_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_browser_rooms_vbox)

	# Bottom actions bar
	var bottom := _make_browser_row_label("[R] Refresh     [N] New Game     [B] Play with Bots     [Enter/A] Join", false)
	bottom.add_theme_color_override("font_color", COLOR_PROMPT)
	bottom.add_theme_font_size_override("font_size", _fs(16))
	bottom.custom_minimum_size = Vector2(0, vh * 0.065)
	root_vbox.add_child(bottom)

	# Trigger initial fetch
	_browser_loading = true
	_browser_status_lbl.text = "Loading..."
	_browser_refresh_timer = 0.0
	NetworkManager.fetch_rooms()

	_refresh_browser_list()


func _make_browser_row_label(text: String, _centered: bool) -> Label:
	var lbl := Label.new()
	lbl.text = text
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	lbl.add_theme_font_size_override("font_size", _fs(18))
	lbl.add_theme_color_override("font_color", COLOR_TEXT)
	lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return lbl


func _refresh_browser_list() -> void:
	if _browser_rooms_vbox == null:
		return
	for child in _browser_rooms_vbox.get_children():
		child.queue_free()

	if _browser_loading:
		return

	if _browser_rooms.is_empty():
		if _browser_status_lbl != null:
			_browser_status_lbl.text = "No open games.  Create one!"
		return

	if _browser_status_lbl != null:
		_browser_status_lbl.text = ""

	# Clamp selection
	_browser_selected = clampi(_browser_selected, 0, _browser_rooms.size() - 1)

	for i: int in _browser_rooms.size():
		var room: Dictionary = _browser_rooms[i]
		var code: String = str(room.get("code", "??????"))
		var host_name: String = str(room.get("host", "???"))
		var pc: int = int(room.get("player_count", 1))
		var mp: int = int(room.get("max_players", 4))
		var diff: int = int(room.get("bot_difficulty", 0))
		var diff_str: String = DIFFICULTY_LABELS[clampi(diff, 0, 2)]

		var row := Panel.new()
		row.custom_minimum_size = Vector2(0, get_viewport_rect().size.y * 0.065)
		row.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var row_style := StyleBoxFlat.new()
		row_style.bg_color = COLOR_ROW_SELECTED if i == _browser_selected else COLOR_ROW_NORMAL
		row_style.corner_radius_top_left = 4
		row_style.corner_radius_top_right = 4
		row_style.corner_radius_bottom_left = 4
		row_style.corner_radius_bottom_right = 4
		row.add_theme_stylebox_override("panel", row_style)
		_browser_rooms_vbox.add_child(row)

		var lbl := Label.new()
		lbl.text = "  %-10s   %-18s   %d / %-4d   %s" % [code, host_name.left(16), pc, mp, diff_str]
		lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		lbl.add_theme_font_size_override("font_size", _fs(18))
		lbl.add_theme_color_override("font_color", COLOR_ACCENT if i == _browser_selected else COLOR_TEXT)
		lbl.set_anchors_preset(Control.PRESET_FULL_RECT)
		lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(lbl)


func _do_fetch_rooms() -> void:
	_browser_loading = true
	if _browser_status_lbl != null:
		_browser_status_lbl.text = "Loading..."
	if _browser_rooms_vbox != null:
		for child in _browser_rooms_vbox.get_children():
			child.queue_free()
	NetworkManager.fetch_rooms()


# ===========================================================================
# SCREEN 3: WAITING LOBBY
# ===========================================================================

func _build_waiting_screen() -> void:
	# Smaller title than other screens -- this screen grew a 3-row accessory
	# customizer + live preview on top of an already-tall settings/players
	# layout, and there isn't enough vertical room in the default 1152x648
	# window for both a full-size title and zero content clipping.
	_add_title("ROPE DART ARENA", 44)

	var vp_size: Vector2 = get_viewport_rect().size
	var vw: float = vp_size.x
	var vh: float = vp_size.y
	var panel_w: float = vw * 0.76
	var panel_h: float = vh * 0.885
	var v_offset: float = vh * 0.05

	var panel := _make_panel(int(panel_w), int(panel_h), int(v_offset))
	add_child(panel)

	var inset: float = vw * 0.03
	var root_vbox := VBoxContainer.new()
	root_vbox.set_anchors_preset(Control.PRESET_FULL_RECT)
	root_vbox.offset_left = inset
	root_vbox.offset_top = vh * 0.015
	root_vbox.offset_right = -inset
	root_vbox.offset_bottom = -(vh * 0.015)
	root_vbox.add_theme_constant_override("separation", 6)
	root_vbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(root_vbox)

	# Room code row
	var code_hbox := HBoxContainer.new()
	code_hbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root_vbox.add_child(code_hbox)

	_wait_code_lbl = Label.new()
	_wait_code_lbl.text = "Room: " + NetworkManager.room_code
	_wait_code_lbl.add_theme_font_size_override("font_size", _fs(22))
	_wait_code_lbl.add_theme_color_override("font_color", COLOR_ACCENT)
	_wait_code_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_wait_code_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	code_hbox.add_child(_wait_code_lbl)

	var copy_hint := Label.new()
	copy_hint.text = "[share this code]"
	copy_hint.add_theme_font_size_override("font_size", _fs(14))
	copy_hint.add_theme_color_override("font_color", COLOR_DIM)
	copy_hint.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	copy_hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	code_hbox.add_child(copy_hint)

	# Players section
	var player_count: int = NetworkManager.room_settings.get("max_players", 4)
	var players_header := Label.new()
	players_header.text = "PLAYERS  (%d / %d)" % [NetworkManager.room_players.size(), player_count]
	players_header.add_theme_font_size_override("font_size", _fs(16))
	players_header.add_theme_color_override("font_color", COLOR_DIM)
	players_header.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root_vbox.add_child(players_header)

	_wait_players_vbox = VBoxContainer.new()
	_wait_players_vbox.add_theme_constant_override("separation", 4)
	_wait_players_vbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root_vbox.add_child(_wait_players_vbox)
	_rebuild_player_list()

	# Separator
	var sep := HSeparator.new()
	sep.add_theme_color_override("color", COLOR_PANEL_BORDER)
	sep.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root_vbox.add_child(sep)

	# Settings section
	var settings_header := Label.new()
	settings_header.text = "SETTINGS" + ("" if NetworkManager.is_host else "  (host controls)")
	settings_header.add_theme_font_size_override("font_size", _fs(16))
	settings_header.add_theme_color_override("font_color", COLOR_DIM)
	settings_header.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root_vbox.add_child(settings_header)

	_build_settings_rows(root_vbox)

	# Separator
	var sep2 := HSeparator.new()
	sep2.add_theme_color_override("color", COLOR_PANEL_BORDER)
	sep2.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root_vbox.add_child(sep2)

	# Character picker — all players (host navigates here with Down from settings).
	# Three cyclable rows (base/headwear/cloth) side-by-side with a live preview --
	# _wait_char_slot picks which row is highlighted/active when _wait_area == 1.
	var char_header := Label.new()
	char_header.text = "YOUR CHARACTER"
	char_header.add_theme_font_size_override("font_size", _fs(16))
	char_header.add_theme_color_override("font_color", COLOR_DIM)
	char_header.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root_vbox.add_child(char_header)

	var char_body_hbox := HBoxContainer.new()
	char_body_hbox.add_theme_constant_override("separation", 16)
	char_body_hbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root_vbox.add_child(char_body_hbox)

	var char_rows_vbox := VBoxContainer.new()
	char_rows_vbox.add_theme_constant_override("separation", 6)
	char_rows_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	char_rows_vbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	char_body_hbox.add_child(char_rows_vbox)

	var char_area_focused: bool = (_wait_area == 1)
	var my_char_def: Dictionary = GameManager.CHARACTER_DEFS[_wait_char_cursor]
	var my_char_id: String = str(my_char_def.get("id", "char_barbarian"))
	var my_headwear_def: Dictionary = GameManager.HEADWEAR_DEFS[_wait_headwear_cursor]
	var my_cloth_def: Dictionary = GameManager.CLOTH_DEFS[_wait_cloth_cursor]
	var is_taken: bool = _is_char_taken_by_other(my_char_id)
	var char_value_text: String = str(my_char_def.get("display_name", "?")) + (" (taken!)" if is_taken else "")

	var base_row := _make_settings_row("Character", char_value_text, char_area_focused and _wait_char_slot == 0, true, 0.042)
	char_rows_vbox.add_child(base_row)
	var headwear_row := _make_settings_row("Headwear", str(my_headwear_def.get("display_name", "?")), char_area_focused and _wait_char_slot == 1, true, 0.042)
	char_rows_vbox.add_child(headwear_row)
	var cloth_row := _make_settings_row("Cloth / Cape", str(my_cloth_def.get("display_name", "?")), char_area_focused and _wait_char_slot == 2, true, 0.042)
	char_rows_vbox.add_child(cloth_row)

	var preview_size := Vector2(vw * 0.11, vh * 0.135)
	var char_preview := _make_character_preview(
		my_char_id,
		str(my_headwear_def.get("id", "none")),
		str(my_cloth_def.get("id", "none")),
		preview_size
	)
	char_body_hbox.add_child(char_preview)

	var nav_hint := Label.new()
	nav_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	nav_hint.add_theme_font_size_override("font_size", _fs(14))
	nav_hint.add_theme_color_override("font_color", COLOR_DIM)
	nav_hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	nav_hint.text = "◀ ▶ = cycle     Up/Down = switch row" + ("   (Down from settings enters here)" if NetworkManager.is_host else "")
	root_vbox.add_child(nav_hint)

	# Separator
	var sep3 := HSeparator.new()
	sep3.add_theme_color_override("color", COLOR_PANEL_BORDER)
	sep3.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root_vbox.add_child(sep3)

	# Prompt / action hint
	_wait_prompt_lbl = Label.new()
	_wait_prompt_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_wait_prompt_lbl.add_theme_font_size_override("font_size", _fs(19))
	_wait_prompt_lbl.add_theme_color_override("font_color", COLOR_PROMPT)
	_wait_prompt_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root_vbox.add_child(_wait_prompt_lbl)

	_wait_error_lbl = Label.new()
	_wait_error_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_wait_error_lbl.add_theme_font_size_override("font_size", _fs(17))
	_wait_error_lbl.add_theme_color_override("font_color", Color(0.9, 0.3, 0.3, 1.0))
	_wait_error_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root_vbox.add_child(_wait_error_lbl)

	if _error_message != "":
		_wait_error_lbl.text = _error_message

	var leave_lbl := Label.new()
	leave_lbl.text = "[Esc / B] Leave room"
	leave_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	leave_lbl.add_theme_font_size_override("font_size", _fs(15))
	leave_lbl.add_theme_color_override("font_color", COLOR_DIM)
	leave_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root_vbox.add_child(leave_lbl)

	_update_wait_prompt()


func _build_settings_rows(parent: VBoxContainer) -> void:
	var is_host: bool = NetworkManager.is_host
	var max_p: int = NetworkManager.room_settings.get("max_players", 4)
	var diff: int = NetworkManager.room_settings.get("bot_difficulty", 0)
	var map_id: int = NetworkManager.room_settings.get("map_id", 0)

	# Row 0: max_players
	var row0 := _make_settings_row(
		"Total Players",
		str(max_p),
		_wait_settings_focus == 0 and is_host,
		false, 0.052
	)
	_wait_settings_max_lbl = row0.get_node_or_null("ValueLabel")
	parent.add_child(row0)

	# Row 1: bot_difficulty
	var row1 := _make_settings_row(
		"Bot Difficulty",
		DIFFICULTY_LABELS[clampi(diff, 0, 2)],
		_wait_settings_focus == 1 and is_host,
		false, 0.052
	)
	_wait_settings_diff_lbl = row1.get_node_or_null("ValueLabel")
	parent.add_child(row1)

	# Row 2: map
	var row2 := _make_settings_row(
		"Map",
		MAP_LABELS[clampi(map_id, 0, MAP_LABELS.size() - 1)],
		_wait_settings_focus == 2 and is_host,
		false, 0.052
	)
	_wait_settings_map_lbl = row2.get_node_or_null("ValueLabel")
	parent.add_child(row2)


func _make_settings_row(label_text: String, value_text: String, focused: bool, force_arrows: bool = false, height_ratio: float = 0.065) -> Panel:
	var row := Panel.new()
	row.custom_minimum_size = Vector2(0, get_viewport_rect().size.y * height_ratio)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var style := StyleBoxFlat.new()
	style.bg_color = COLOR_ROW_FOCUSED if focused else COLOR_ROW_NORMAL
	style.border_color = COLOR_BORDER_FOCUSED if focused else COLOR_BORDER_NORMAL
	style.border_width_left = 2
	style.border_width_right = 2
	style.border_width_top = 1
	style.border_width_bottom = 1
	style.corner_radius_top_left = 4
	style.corner_radius_top_right = 4
	style.corner_radius_bottom_left = 4
	style.corner_radius_bottom_right = 4
	row.add_theme_stylebox_override("panel", style)

	var hbox := HBoxContainer.new()
	hbox.set_anchors_preset(Control.PRESET_FULL_RECT)
	hbox.offset_left = 16
	hbox.offset_top = 0
	hbox.offset_right = -16
	hbox.offset_bottom = 0
	hbox.alignment = BoxContainer.ALIGNMENT_CENTER
	hbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(hbox)

	var name_lbl := Label.new()
	name_lbl.text = label_text
	name_lbl.add_theme_font_size_override("font_size", _fs(18))
	name_lbl.add_theme_color_override("font_color", COLOR_TEXT)
	name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	name_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hbox.add_child(name_lbl)

	if NetworkManager.is_host or force_arrows:
		var arrow_l := Label.new()
		arrow_l.text = "◀"
		arrow_l.add_theme_font_size_override("font_size", _fs(18))
		arrow_l.add_theme_color_override("font_color", COLOR_DIM if not focused else COLOR_VALUE)
		arrow_l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		arrow_l.mouse_filter = Control.MOUSE_FILTER_IGNORE
		hbox.add_child(arrow_l)

	var val_lbl := Label.new()
	val_lbl.name = "ValueLabel"
	val_lbl.text = value_text
	val_lbl.custom_minimum_size = Vector2(get_viewport_rect().size.x * 0.1, 0)
	val_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	val_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	val_lbl.add_theme_font_size_override("font_size", _fs(22))
	val_lbl.add_theme_color_override("font_color", COLOR_VALUE)
	val_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hbox.add_child(val_lbl)

	if NetworkManager.is_host or force_arrows:
		var arrow_r := Label.new()
		arrow_r.text = "▶"
		arrow_r.add_theme_font_size_override("font_size", _fs(18))
		arrow_r.add_theme_color_override("font_color", COLOR_DIM if not focused else COLOR_VALUE)
		arrow_r.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		arrow_r.mouse_filter = Control.MOUSE_FILTER_IGNORE
		hbox.add_child(arrow_r)

	return row


func _rebuild_player_list() -> void:
	if _wait_players_vbox == null:
		return
	for child in _wait_players_vbox.get_children():
		child.queue_free()

	var max_p: int = NetworkManager.room_settings.get("max_players", 4)
	var players: Array = NetworkManager.room_players

	for i: int in max_p:
		var row_hbox := HBoxContainer.new()
		row_hbox.add_theme_constant_override("separation", 8)
		row_hbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
		if i < players.size():
			var pd: Dictionary = players[i]
			var uname: String = str(pd.get("username", "Player"))
			var pid: int = int(pd.get("peer_id", i + 1))
			var is_host_player: bool = pid == 1
			var name_lbl := Label.new()
			name_lbl.add_theme_font_size_override("font_size", _fs(18))
			name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			name_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
			name_lbl.text = ("► " if i == 0 else "  ") + uname + (" (Host)" if is_host_player else "")
			name_lbl.add_theme_color_override("font_color", COLOR_HOST_TAG if is_host_player else COLOR_TEXT)
			row_hbox.add_child(name_lbl)

			var char_id: String = str(NetworkManager.peer_characters.get(pid, ""))
			var char_display: String = _char_display_name(char_id)
			var char_lbl := Label.new()
			char_lbl.add_theme_font_size_override("font_size", _fs(15))
			char_lbl.add_theme_color_override("font_color", COLOR_VALUE if char_id != "" else COLOR_DIM)
			char_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
			char_lbl.text = char_display
			row_hbox.add_child(char_lbl)
		else:
			var empty_lbl := Label.new()
			empty_lbl.add_theme_font_size_override("font_size", _fs(18))
			empty_lbl.add_theme_color_override("font_color", COLOR_DIM)
			empty_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
			empty_lbl.text = "  [waiting...]"
			empty_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			row_hbox.add_child(empty_lbl)
		_wait_players_vbox.add_child(row_hbox)


func _char_display_name(char_id: String) -> String:
	if char_id == "":
		return "[choosing...]"
	for def in GameManager.CHARACTER_DEFS:
		if (def as Dictionary).get("id", "") == char_id:
			return (def as Dictionary).get("display_name", char_id)
	return char_id


func _update_wait_prompt() -> void:
	if _wait_prompt_lbl == null:
		return
	if NetworkManager.is_host:
		if _wait_area == 0:
			_wait_prompt_lbl.text = "Enter = START     Up/Down = settings     Down from last = char picker"
		else:
			_wait_prompt_lbl.text = "◀ ▶ = pick character     Up = back to settings     Enter = START"
	else:
		_wait_prompt_lbl.text = "◀ ▶ = pick character     Waiting for host to start..."


func _is_char_taken_by_other(char_id: String) -> bool:
	var my_pid: int = NetworkManager.my_peer_id
	for pid: int in NetworkManager.peer_characters.keys():
		if pid != my_pid and str(NetworkManager.peer_characters[pid]) == char_id:
			return true
	return false


# ===========================================================================
# Shared UI helpers
# ===========================================================================

func _fs(base: int) -> int:
	return maxi(base, int(base * get_viewport_rect().size.x / 1280.0))


func _add_title(text: String, font_size: int) -> void:
	var vh: float = get_viewport_rect().size.y
	var lbl := Label.new()
	lbl.text = text
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.add_theme_font_size_override("font_size", font_size)
	lbl.add_theme_color_override("font_color", COLOR_TITLE)
	lbl.add_theme_color_override("font_shadow_color", Color(0.40, 0.16, 0.02, 0.65))
	lbl.add_theme_constant_override("shadow_offset_x", 3)
	lbl.add_theme_constant_override("shadow_offset_y", 4)
	lbl.set_anchor(SIDE_LEFT, 0.0)
	lbl.set_anchor(SIDE_RIGHT, 1.0)
	lbl.offset_top = vh * 0.04
	lbl.offset_bottom = vh * 0.04 + font_size + vh * 0.02
	lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(lbl)


func _add_subtitle(text: String, font_size: int) -> void:
	var vh: float = get_viewport_rect().size.y
	var lbl := Label.new()
	lbl.text = text
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.add_theme_font_size_override("font_size", font_size)
	lbl.add_theme_color_override("font_color", COLOR_DIM)
	lbl.set_anchor(SIDE_LEFT, 0.0)
	lbl.set_anchor(SIDE_RIGHT, 1.0)
	lbl.offset_top = vh * 0.16
	lbl.offset_bottom = vh * 0.20
	lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(lbl)


func _make_panel(w: int, h: int, v_offset: int) -> Panel:
	var panel := Panel.new()
	var style := StyleBoxFlat.new()
	style.bg_color = COLOR_PANEL_BG
	style.border_color = COLOR_PANEL_BORDER
	style.border_width_left = 2
	style.border_width_right = 2
	style.border_width_top = 2
	style.border_width_bottom = 2
	style.corner_radius_top_left = 10
	style.corner_radius_top_right = 10
	style.corner_radius_bottom_left = 10
	style.corner_radius_bottom_right = 10
	panel.add_theme_stylebox_override("panel", style)
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.set_anchor(SIDE_LEFT, 0.5)
	panel.set_anchor(SIDE_RIGHT, 0.5)
	panel.set_anchor(SIDE_TOP, 0.5)
	panel.set_anchor(SIDE_BOTTOM, 0.5)
	panel.offset_left = -w / 2.0
	panel.offset_right = w / 2.0
	panel.offset_top = -h / 2.0 + v_offset
	panel.offset_bottom = h / 2.0 + v_offset
	return panel


func _make_character_preview(base_id: String, headwear_id: String, cloth_id: String, preview_size: Vector2) -> Control:
	## Live 3D preview of the assembled character (base + headwear + cloth),
	## used by both the local and online character customizer screens.
	## Rebuilt from scratch on every call -- callers already do a full
	## _rebuild_ui() on any cursor move, so this matches that brute-force
	## pattern rather than trying to update an existing SubViewport in place.
	var frame := PanelContainer.new()
	frame.custom_minimum_size = preview_size
	var frame_style := StyleBoxFlat.new()
	frame_style.bg_color = Color(0.90, 0.93, 0.84, 1.0)
	frame_style.border_color = COLOR_PANEL_BORDER
	frame_style.border_width_left = 2
	frame_style.border_width_right = 2
	frame_style.border_width_top = 2
	frame_style.border_width_bottom = 2
	frame_style.corner_radius_top_left = 8
	frame_style.corner_radius_top_right = 8
	frame_style.corner_radius_bottom_left = 8
	frame_style.corner_radius_bottom_right = 8
	frame.add_theme_stylebox_override("panel", frame_style)
	frame.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var container := SubViewportContainer.new()
	container.stretch = true
	container.mouse_filter = Control.MOUSE_FILTER_IGNORE
	frame.add_child(container)

	var vp := SubViewport.new()
	vp.size = Vector2i(maxi(int(preview_size.x), 1), maxi(int(preview_size.y), 1))
	vp.transparent_bg = false
	vp.own_world_3d = true
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	container.add_child(vp)

	var world := Node3D.new()
	vp.add_child(world)

	var env_node := WorldEnvironment.new()
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color(0.90, 0.93, 0.84, 1.0)
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color(1.0, 1.0, 1.0)
	environment.ambient_light_energy = 0.7
	env_node.environment = environment
	world.add_child(env_node)

	var key_light := DirectionalLight3D.new()
	key_light.rotation_degrees = Vector3(-40.0, -35.0, 0.0)
	key_light.light_energy = 1.2
	world.add_child(key_light)

	var char_visual: Node3D = CharacterBuilder.build_character_visual(base_id, headwear_id, cloth_id)
	if char_visual != null:
		char_visual.scale = Vector3(0.85, 0.85, 0.85)
		char_visual.position = Vector3(0.0, -0.7, 0.0)
		# KayKit's modeled forward is +Z after import (see player.gd's facing
		# comment) -- the preview camera sits on +Z looking back toward the
		# origin, so leaving rotation at identity already faces the character
		# toward it; a slight yaw just reads as a more natural 3/4 pose.
		char_visual.rotation_degrees.y = -20.0
		world.add_child(char_visual)

	var cam := Camera3D.new()
	# look_at_from_position() (rather than setting .position then calling
	# .look_at()) works before the node is added to the tree -- Node3D.look_at()
	# needs a valid global_transform, which requires tree membership first.
	cam.look_at_from_position(Vector3(0.0, 0.85, 2.6), Vector3(0.0, 0.75, 0.0), Vector3.UP)
	cam.current = true
	world.add_child(cam)

	return frame


# ===========================================================================
# INPUT
# ===========================================================================

func _input(event: InputEvent) -> void:
	if not (event is InputEventKey and (event as InputEventKey).pressed):
		return
	var ke := event as InputEventKey
	# Browser letter keys only — these are never consumed by any GUI node
	if _screen == "browser":
		match ke.keycode:
			KEY_B: _begin_local_game()
			KEY_N: _begin_host()
			KEY_R:
				_browser_refresh_timer = 0.0
				_do_fetch_rooms()


func _unhandled_input(event: InputEvent) -> void:
	match _screen:
		"username":
			_input_username(event)
		"browser":
			_input_browser(event)
		"waiting":
			_input_waiting(event)
		"local_config":
			_input_local_config(event)
		"char_select_local":
			_input_char_select_local(event)


func _input_username(event: InputEvent) -> void:
	if not event is InputEventKey:
		return
	var ke := event as InputEventKey
	if not ke.pressed:
		return

	match ke.keycode:
		KEY_ENTER, KEY_KP_ENTER:
			if _typed_username.strip_edges().length() >= 2:
				UsernameManager.save(_typed_username.strip_edges())
				_set_screen("browser")
		KEY_BACKSPACE:
			if _typed_username.length() > 0:
				_typed_username = _typed_username.left(_typed_username.length() - 1)
			_update_username_cursor()
		_:
			if _typed_username.length() < 16 and ke.unicode > 0:
				var ch: String = char(ke.unicode).to_upper()
				var code: int = ch.unicode_at(0)
				var valid: bool = (
					(code >= 65 and code <= 90) or  # A-Z
					(code >= 48 and code <= 57) or  # 0-9
					code == 95                       # _
				)
				if valid:
					_typed_username += ch
					_update_username_cursor()


func _input_browser(event: InputEvent) -> void:
	if event.is_action_pressed("ui_up"):
		if _browser_rooms.size() > 0:
			_browser_selected = (_browser_selected - 1 + _browser_rooms.size()) % _browser_rooms.size()
			_refresh_browser_list()
	elif event.is_action_pressed("ui_down"):
		if _browser_rooms.size() > 0:
			_browser_selected = (_browser_selected + 1) % _browser_rooms.size()
			_refresh_browser_list()
	elif event.is_action_pressed("ui_accept"):
		_browser_try_join()
	elif event is InputEventKey and (event as InputEventKey).pressed:
		var ke := event as InputEventKey
		match ke.keycode:
			KEY_R:
				_browser_refresh_timer = 0.0
				_do_fetch_rooms()
			KEY_N:
				_begin_host()
			KEY_B:
				_begin_local_game()
	elif event is InputEventJoypadButton and (event as InputEventJoypadButton).pressed:
		var jb := event as InputEventJoypadButton
		match jb.button_index:
			JOY_BUTTON_Y:   # Y = refresh
				_browser_refresh_timer = 0.0
				_do_fetch_rooms()
			JOY_BUTTON_X:   # X = new game
				_begin_host()
			JOY_BUTTON_A:   # A = join
				_browser_try_join()


func _input_waiting(event: InputEvent) -> void:
	# Esc / B = leave
	var is_escape := (event is InputEventKey and (event as InputEventKey).pressed
			and (event as InputEventKey).keycode == KEY_ESCAPE)
	var is_b := (event is InputEventJoypadButton and (event as InputEventJoypadButton).pressed
			and (event as InputEventJoypadButton).button_index == JOY_BUTTON_B)
	if is_escape or is_b:
		NetworkManager.disconnect_from_room()
		_error_timer = 0.0
		_error_message = ""
		_set_screen("browser")
		return

	if NetworkManager.is_host:
		_input_waiting_host(event)
	else:
		# Non-host: Up/Down switches which of the 3 rows is active, Left/Right
		# cycles that row's value (mirrors the host's char-area controls below).
		if event.is_action_pressed("ui_up"):
			_wait_char_slot = (_wait_char_slot - 1 + 3) % 3
			_rebuild_ui()
		elif event.is_action_pressed("ui_down"):
			_wait_char_slot = (_wait_char_slot + 1) % 3
			_rebuild_ui()
		elif event.is_action_pressed("ui_left"):
			_cycle_wait_slot(-1)
		elif event.is_action_pressed("ui_right"):
			_cycle_wait_slot(1)


func _cycle_wait_slot(delta: int) -> void:
	## Left/Right cycles whichever of the 3 rows (_wait_char_slot) is active,
	## broadcasting the change to other peers via NetworkManager -- mirrors
	## _cycle_local_slot()'s single-player equivalent.
	match _wait_char_slot:
		0:
			var char_count: int = GameManager.CHARACTER_DEFS.size()
			_wait_char_cursor = (_wait_char_cursor + delta + char_count) % char_count
			_sync_wait_accessory_defaults()
			var char_id: String = (GameManager.CHARACTER_DEFS[_wait_char_cursor] as Dictionary).get("id", "char_barbarian")
			NetworkManager.send_character_choice(char_id)
			NetworkManager.send_headwear_choice(str((GameManager.HEADWEAR_DEFS[_wait_headwear_cursor] as Dictionary).get("id", "none")))
			NetworkManager.send_cloth_choice(str((GameManager.CLOTH_DEFS[_wait_cloth_cursor] as Dictionary).get("id", "none")))
		1:
			var headwear_count: int = GameManager.HEADWEAR_DEFS.size()
			_wait_headwear_cursor = (_wait_headwear_cursor + delta + headwear_count) % headwear_count
			NetworkManager.send_headwear_choice(str((GameManager.HEADWEAR_DEFS[_wait_headwear_cursor] as Dictionary).get("id", "none")))
		2:
			var cloth_count: int = GameManager.CLOTH_DEFS.size()
			_wait_cloth_cursor = (_wait_cloth_cursor + delta + cloth_count) % cloth_count
			NetworkManager.send_cloth_choice(str((GameManager.CLOTH_DEFS[_wait_cloth_cursor] as Dictionary).get("id", "none")))
	_rebuild_ui()


func _sync_wait_accessory_defaults() -> void:
	var char_def: Dictionary = GameManager.CHARACTER_DEFS[_wait_char_cursor]
	_wait_headwear_cursor = _index_of_def_id(GameManager.HEADWEAR_DEFS, str(char_def.get("native_headwear", "none")))
	_wait_cloth_cursor = _index_of_def_id(GameManager.CLOTH_DEFS, str(char_def.get("native_cloth", "none")))


func _input_waiting_host(event: InputEvent) -> void:
	if event.is_action_pressed("ui_up"):
		if _wait_area == 1:
			if _wait_char_slot == 0:
				# Move from char area back to settings
				_wait_area = 0
				_wait_settings_focus = 2
			else:
				_wait_char_slot -= 1
		else:
			_wait_settings_focus = (_wait_settings_focus - 1 + 3) % 3
		_rebuild_settings_only()
	elif event.is_action_pressed("ui_down"):
		if _wait_area == 0:
			if _wait_settings_focus < 2:
				_wait_settings_focus += 1
			else:
				# Move from last settings row down into char area
				_wait_area = 1
				_wait_char_slot = 0
		else:
			_wait_char_slot = mini(_wait_char_slot + 1, 2)
		_rebuild_settings_only()
	elif event.is_action_pressed("ui_left"):
		if _wait_area == 0:
			_change_wait_setting(-1)
		else:
			_cycle_wait_slot(-1)
	elif event.is_action_pressed("ui_right"):
		if _wait_area == 0:
			_change_wait_setting(1)
		else:
			_cycle_wait_slot(1)
	elif event.is_action_pressed("ui_accept"):
		_start_online_game()


func _change_wait_setting(delta: int) -> void:
	var max_p: int = NetworkManager.room_settings.get("max_players", 4)
	var diff: int = NetworkManager.room_settings.get("bot_difficulty", 0)
	var map_id: int = NetworkManager.room_settings.get("map_id", 0)
	var human_count: int = NetworkManager.room_players.size()

	if _wait_settings_focus == 0:
		var min_p: int = maxi(2, human_count)
		max_p = clampi(max_p + delta, min_p, 6)
	elif _wait_settings_focus == 1:
		diff = clampi(diff + delta, 0, 2)
	else:
		map_id = clampi(map_id + delta, 0, MAP_LABELS.size() - 1)

	NetworkManager.update_settings(max_p, diff, map_id)
	_rebuild_settings_only()


func _rebuild_settings_only() -> void:
	# Find the settings rows container and rebuild just those rows in-place.
	# Since _make_settings_row nodes are direct children of root_vbox inside the panel,
	# the cleanest approach for this live-update is a targeted rebuild of the waiting screen.
	# We only do a full waiting screen rebuild when settings change to keep it simple.
	_build_waiting_screen_in_place()


func _build_waiting_screen_in_place() -> void:
	# Rather than rebuilding everything, re-trigger the full waiting screen rebuild.
	# This is called only on host key presses, so it's not per-frame.
	_rebuild_ui()


# ===========================================================================
# Browser actions
# ===========================================================================

func _browser_try_join() -> void:
	if _browser_rooms.is_empty():
		return
	if _browser_selected >= _browser_rooms.size():
		return
	var room: Dictionary = _browser_rooms[_browser_selected]
	var code: String = str(room.get("code", ""))
	if code.length() == 6:
		NetworkManager.join_room(code)


func _begin_host() -> void:
	var max_p: int = NetworkManager.room_settings.get("max_players", 4)
	var diff: int = NetworkManager.room_settings.get("bot_difficulty", 0)
	var map_id: int = NetworkManager.room_settings.get("map_id", 0)
	NetworkManager.create_room(max_p, diff, map_id)
	if _browser_status_lbl != null:
		_browser_status_lbl.text = "Creating room..."


# ===========================================================================
# NetworkManager signal callbacks
# ===========================================================================

func _on_rooms_fetched(rooms_array: Array) -> void:
	_browser_loading = false
	_browser_rooms = rooms_array
	if _screen == "browser":
		if _browser_status_lbl != null:
			_browser_status_lbl.text = ""
		_refresh_browser_list()


func _on_connected_to_room(_code: String, _peer_id: int) -> void:
	if _screen == "browser" or _screen == "waiting":
		# Non-hosts start directly in the char-picker area; hosts start in settings area.
		_wait_area = 0 if NetworkManager.is_host else 1
		_wait_char_cursor = 0
		_wait_char_slot = 0
		_sync_wait_accessory_defaults()
		_set_screen("waiting")


func _on_player_list_updated(_players: Array) -> void:
	if _screen != "waiting":
		return
	_rebuild_player_list()
	# Also update the player count in the header — simplest to do a full rebuild
	# but to avoid recursion we update just the vbox
	# The header label is a sibling — find it by re-querying root_vbox children
	# Simpler: just do a full rebuild since player list changes are infrequent
	_rebuild_ui()


func _on_settings_updated(_settings: Dictionary) -> void:
	if _screen != "waiting":
		return
	_rebuild_ui()


func _on_game_starting() -> void:
	_start_online_game()


func _on_host_disconnected() -> void:
	if _screen != "waiting":
		return
	_error_message = "Host left the game. Returning to browser..."
	_error_timer = 2.0
	NetworkManager.disconnect_from_room()
	# Stay on waiting screen but show error; _process will transition after 2s
	if _wait_error_lbl != null:
		_wait_error_lbl.text = _error_message
	else:
		# Rebuild now so error label appears
		_rebuild_ui()


func _on_peer_disconnected(_peer_id: int) -> void:
	if _screen != "waiting":
		return
	# room_players is already updated by player_list_updated; just rebuild
	_rebuild_player_list()


func _on_connection_failed(reason: String) -> void:
	if _screen == "browser":
		if _browser_status_lbl != null:
			_browser_status_lbl.text = "Connection failed: " + reason
	elif _screen == "waiting":
		if _wait_error_lbl != null:
			_wait_error_lbl.text = "Error: " + reason


# ===========================================================================
# LOCAL PLAY — config screen and game start
# ===========================================================================

func _begin_local_game() -> void:
	_set_screen("local_config")


func _build_local_config_screen() -> void:
	_add_title("PLAY WITH BOTS", 56)

	var vp_size: Vector2 = get_viewport_rect().size
	var vw: float = vp_size.x
	var vh: float = vp_size.y
	var panel_w: float = vw * 0.60
	var panel_h: float = vh * 0.44
	var v_offset: float = vh * 0.025

	var panel := _make_panel(int(panel_w), int(panel_h), int(v_offset))
	add_child(panel)

	var inset: float = vw * 0.03
	var root_vbox := VBoxContainer.new()
	root_vbox.set_anchors_preset(Control.PRESET_FULL_RECT)
	root_vbox.offset_left = inset
	root_vbox.offset_top = vh * 0.025
	root_vbox.offset_right = -inset
	root_vbox.offset_bottom = -(vh * 0.025)
	root_vbox.add_theme_constant_override("separation", 14)
	root_vbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(root_vbox)

	var settings_header := Label.new()
	settings_header.text = "SETTINGS"
	settings_header.add_theme_font_size_override("font_size", _fs(16))
	settings_header.add_theme_color_override("font_color", COLOR_DIM)
	settings_header.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root_vbox.add_child(settings_header)

	var row0 := _make_settings_row(
		"Total Players",
		str(_local_total_players),
		_local_focus == 0,
		true
	)
	_local_total_lbl = row0.get_node_or_null("HBoxContainer/ValueLabel")
	root_vbox.add_child(row0)

	var row1 := _make_settings_row(
		"Bot Difficulty",
		DIFFICULTY_LABELS[clampi(_local_bot_difficulty, 0, 2)],
		_local_focus == 1,
		true
	)
	_local_diff_lbl = row1.get_node_or_null("HBoxContainer/ValueLabel")
	root_vbox.add_child(row1)

	var row2 := _make_settings_row(
		"Map",
		MAP_LABELS[clampi(_local_map_id, 0, MAP_LABELS.size() - 1)],
		_local_focus == 2,
		true
	)
	_local_map_lbl = row2.get_node_or_null("HBoxContainer/ValueLabel")
	root_vbox.add_child(row2)

	var sep := HSeparator.new()
	sep.add_theme_color_override("color", COLOR_PANEL_BORDER)
	sep.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root_vbox.add_child(sep)

	var prompt_lbl := Label.new()
	prompt_lbl.text = "Enter = Start   Esc = Back"
	prompt_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	prompt_lbl.add_theme_font_size_override("font_size", _fs(19))
	prompt_lbl.add_theme_color_override("font_color", COLOR_PROMPT)
	prompt_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root_vbox.add_child(prompt_lbl)


func _change_local_setting(delta: int) -> void:
	if _local_focus == 0:
		# Minimum of 1 (not 2) so solo test mode is reachable — 1 player, 0
		# bots, useful for testing dagger mechanics without interference.
		_local_total_players = clampi(_local_total_players + delta, 1, 6)
	elif _local_focus == 1:
		_local_bot_difficulty = clampi(_local_bot_difficulty + delta, 0, 2)
	else:
		_local_map_id = clampi(_local_map_id + delta, 0, MAP_LABELS.size() - 1)
	_rebuild_ui()


func _input_local_config(event: InputEvent) -> void:
	if event.is_action_pressed("ui_up"):
		_local_focus = (_local_focus - 1 + 3) % 3
		_rebuild_ui()
	elif event.is_action_pressed("ui_down"):
		_local_focus = (_local_focus + 1) % 3
		_rebuild_ui()
	elif event.is_action_pressed("ui_left"):
		_change_local_setting(-1)
	elif event.is_action_pressed("ui_right"):
		_change_local_setting(1)
	elif event.is_action_pressed("ui_accept"):
		_start_local_game()
	elif event is InputEventKey and (event as InputEventKey).pressed:
		var ke := event as InputEventKey
		if ke.keycode == KEY_ESCAPE:
			_set_screen("browser")


func _start_local_game() -> void:
	# Show character selection before launching — config settings stay in _local_* vars
	_char_cursor = randi() % GameManager.CHARACTER_DEFS.size()
	_char_slot = 0
	_sync_local_accessory_defaults()
	_set_screen("char_select_local")


# ===========================================================================
# LOCAL — character selection screen
# ===========================================================================

func _build_char_select_local_screen() -> void:
	_add_title("CUSTOMIZE YOUR FIGHTER", 52)

	var vp_size: Vector2 = get_viewport_rect().size
	var vw: float = vp_size.x
	var vh: float = vp_size.y
	var panel_w: float = vw * 0.72
	var panel_h: float = vh * 0.70
	var v_offset: float = vh * 0.025

	var panel := _make_panel(int(panel_w), int(panel_h), int(v_offset))
	add_child(panel)

	var inset: float = vw * 0.03
	var root_vbox := VBoxContainer.new()
	root_vbox.set_anchors_preset(Control.PRESET_FULL_RECT)
	root_vbox.offset_left = inset
	root_vbox.offset_top = vh * 0.025
	root_vbox.offset_right = -inset
	root_vbox.offset_bottom = -(vh * 0.025)
	root_vbox.add_theme_constant_override("separation", 14)
	root_vbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(root_vbox)

	var hint := Label.new()
	hint.text = "No two fighters can share the same base character (headwear/cloth may repeat)"
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.add_theme_font_size_override("font_size", _fs(16))
	hint.add_theme_color_override("font_color", COLOR_DIM)
	hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root_vbox.add_child(hint)

	# Split body: cycler rows on the left, live 3D preview on the right.
	var body_hbox := HBoxContainer.new()
	body_hbox.add_theme_constant_override("separation", 20)
	body_hbox.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body_hbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root_vbox.add_child(body_hbox)

	var rows_vbox := VBoxContainer.new()
	rows_vbox.add_theme_constant_override("separation", 12)
	rows_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	rows_vbox.size_flags_vertical = Control.SIZE_EXPAND_FILL
	rows_vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	rows_vbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	body_hbox.add_child(rows_vbox)

	var base_def: Dictionary = GameManager.CHARACTER_DEFS[_char_cursor]
	var headwear_def: Dictionary = GameManager.HEADWEAR_DEFS[_headwear_cursor]
	var cloth_def: Dictionary = GameManager.CLOTH_DEFS[_cloth_cursor]

	var base_row := _make_settings_row("Character", str(base_def.get("display_name", "?")), _char_slot == 0, true)
	rows_vbox.add_child(base_row)
	var headwear_row := _make_settings_row("Headwear", str(headwear_def.get("display_name", "?")), _char_slot == 1, true)
	rows_vbox.add_child(headwear_row)
	var cloth_row := _make_settings_row("Cloth / Cape", str(cloth_def.get("display_name", "?")), _char_slot == 2, true)
	rows_vbox.add_child(cloth_row)

	var slot_hint := Label.new()
	slot_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	slot_hint.add_theme_font_size_override("font_size", _fs(15))
	slot_hint.add_theme_color_override("font_color", COLOR_PROMPT)
	slot_hint.text = "Up/Down = switch slot     Left/Right = cycle"
	slot_hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	rows_vbox.add_child(slot_hint)

	var preview_size := Vector2(vw * 0.22, vh * 0.42)
	var preview := _make_character_preview(
		str(base_def.get("id", "char_barbarian")),
		str(headwear_def.get("id", "none")),
		str(cloth_def.get("id", "none")),
		preview_size
	)
	body_hbox.add_child(preview)

	var sep := HSeparator.new()
	sep.add_theme_color_override("color", COLOR_PANEL_BORDER)
	sep.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root_vbox.add_child(sep)

	# Bottom: navigation hints
	var action_hbox := HBoxContainer.new()
	action_hbox.alignment = BoxContainer.ALIGNMENT_CENTER
	action_hbox.add_theme_constant_override("separation", 40)
	action_hbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root_vbox.add_child(action_hbox)

	var back_lbl := Label.new()
	back_lbl.text = "[Esc] Back"
	back_lbl.add_theme_font_size_override("font_size", _fs(16))
	back_lbl.add_theme_color_override("font_color", COLOR_DIM)
	back_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	action_hbox.add_child(back_lbl)

	var nav_lbl := Label.new()
	nav_lbl.text = "Enter to start the match"
	nav_lbl.add_theme_font_size_override("font_size", _fs(16))
	nav_lbl.add_theme_color_override("font_color", COLOR_PROMPT)
	nav_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	action_hbox.add_child(nav_lbl)


func _input_char_select_local(event: InputEvent) -> void:
	if event.is_action_pressed("ui_up"):
		_char_slot = (_char_slot - 1 + 3) % 3
		_rebuild_ui()
	elif event.is_action_pressed("ui_down"):
		_char_slot = (_char_slot + 1) % 3
		_rebuild_ui()
	elif event.is_action_pressed("ui_left"):
		_cycle_local_slot(-1)
	elif event.is_action_pressed("ui_right"):
		_cycle_local_slot(1)
	elif event.is_action_pressed("ui_accept"):
		_commit_local_char_select()
	elif event is InputEventKey and (event as InputEventKey).pressed:
		var ke := event as InputEventKey
		if ke.keycode == KEY_ESCAPE:
			_set_screen("local_config")
	elif event is InputEventJoypadButton and (event as InputEventJoypadButton).pressed:
		var jb := event as InputEventJoypadButton
		if jb.button_index == JOY_BUTTON_B:
			_set_screen("local_config")


func _cycle_local_slot(delta: int) -> void:
	## Left/Right cycles whichever of the 3 rows (_char_slot) is active.
	## Changing the base character resets headwear/cloth to ITS native picks
	## (see _sync_local_accessory_defaults()) rather than leaving a mismatched
	## accessory choice hanging over from a previous base character.
	match _char_slot:
		0:
			var char_count: int = GameManager.CHARACTER_DEFS.size()
			_char_cursor = (_char_cursor + delta + char_count) % char_count
			_sync_local_accessory_defaults()
		1:
			var headwear_count: int = GameManager.HEADWEAR_DEFS.size()
			_headwear_cursor = (_headwear_cursor + delta + headwear_count) % headwear_count
		2:
			var cloth_count: int = GameManager.CLOTH_DEFS.size()
			_cloth_cursor = (_cloth_cursor + delta + cloth_count) % cloth_count
	_rebuild_ui()


func _sync_local_accessory_defaults() -> void:
	var char_def: Dictionary = GameManager.CHARACTER_DEFS[_char_cursor]
	_headwear_cursor = _index_of_def_id(GameManager.HEADWEAR_DEFS, str(char_def.get("native_headwear", "none")))
	_cloth_cursor = _index_of_def_id(GameManager.CLOTH_DEFS, str(char_def.get("native_cloth", "none")))


func _index_of_def_id(defs_pool: Array, def_id: String) -> int:
	for i: int in defs_pool.size():
		if (defs_pool[i] as Dictionary).get("id", "") == def_id:
			return i
	return 0


func _commit_local_char_select() -> void:
	var human_char: String = (GameManager.CHARACTER_DEFS[_char_cursor] as Dictionary).get("id", "char_barbarian")
	var human_headwear: String = (GameManager.HEADWEAR_DEFS[_headwear_cursor] as Dictionary).get("id", "none")
	var human_cloth: String = (GameManager.CLOTH_DEFS[_cloth_cursor] as Dictionary).get("id", "none")

	# Assign human slot, then fill bots with remaining characters in order.
	# Bots' headwear/cloth are left unset ("") so they default to each bot's
	# own native accessory rather than forcing everything to none.
	GameManager.player_characters.clear()
	GameManager.player_headwear.clear()
	GameManager.player_cloth.clear()
	GameManager.player_characters[0] = human_char
	GameManager.player_headwear[0] = human_headwear
	GameManager.player_cloth[0] = human_cloth

	var remaining: Array = []
	for def in GameManager.CHARACTER_DEFS:
		var cid: String = (def as Dictionary).get("id", "")
		if cid != human_char:
			remaining.append(cid)

	for i: int in range(1, _local_total_players):
		var bot_slot: int = i - 1
		if bot_slot < remaining.size():
			GameManager.player_characters[i] = remaining[bot_slot]
		else:
			GameManager.player_characters[i] = (GameManager.CHARACTER_DEFS[i % GameManager.CHARACTER_DEFS.size()] as Dictionary).get("id", "char_barbarian")

	# Apply match config and change scene
	GameManager.is_online = false
	GameManager.lobby_mode = false
	GameManager.total_players = _local_total_players
	GameManager.human_count = 1
	GameManager.bot_difficulty = _local_bot_difficulty
	GameManager.lives_per_round = 3
	GameManager.rounds_to_win = 3
	GameManager.selected_map_scene = MAP_SCENES[clampi(_local_map_id, 0, MAP_SCENES.size() - 1)]
	get_tree().change_scene_to_file(GameManager.selected_map_scene)
	GameManager.call_deferred("_init_game")


# ===========================================================================
# Game start
# ===========================================================================

func _start_online_game() -> void:
	GameManager.is_online = true
	GameManager.total_players = NetworkManager.room_settings.get("max_players", 4)
	GameManager.bot_difficulty = NetworkManager.room_settings.get("bot_difficulty", 0)
	GameManager.human_count = NetworkManager.room_players.size()
	GameManager.lives_per_round = _lives_value
	GameManager.rounds_to_win = _rounds_value
	GameManager.lobby_mode = false
	var map_id: int = NetworkManager.room_settings.get("map_id", 0)
	GameManager.selected_map_scene = MAP_SCENES[clampi(map_id, 0, MAP_SCENES.size() - 1)]
	# Assign characters from peer choices with conflict resolution, then sync.
	_assign_online_characters()
	GameManager.sync_characters_rpc()
	# Headwear/cloth allow duplicates across players, so no conflict resolution
	# is needed here -- just carry each peer's raw pick straight through.
	_assign_online_accessories()
	GameManager.sync_accessories_rpc()
	get_tree().change_scene_to_file(GameManager.selected_map_scene)
	GameManager.call_deferred("_init_game")


func _assign_online_characters() -> void:
	## Map peer character choices onto player slots, resolving duplicates first-wins.
	GameManager.assign_default_characters()
	var used: Array = []
	var total: int = GameManager.total_players

	# First pass: apply each peer's choice if available, in player-index order.
	for i: int in total:
		var peer_id: int = i + 1
		if NetworkManager.peer_characters.has(peer_id):
			var choice: String = str(NetworkManager.peer_characters[peer_id])
			if not used.has(choice):
				GameManager.player_characters[i] = choice
				used.append(choice)
			# else: conflict — keep the default assigned by assign_default_characters()
		else:
			# No peer choice: register the default to block it from others
			var default_char: String = str(GameManager.player_characters.get(i, "char_barbarian"))
			if not used.has(default_char):
				used.append(default_char)

	# Second pass: fix any defaults that collide with chosen chars.
	for i: int in total:
		var peer_id: int = i + 1
		if not NetworkManager.peer_characters.has(peer_id):
			var current: String = str(GameManager.player_characters.get(i, "char_barbarian"))
			if used.count(current) > 1:
				# Find next available character
				for def in GameManager.CHARACTER_DEFS:
					var cid: String = (def as Dictionary).get("id", "")
					if not used.has(cid):
						GameManager.player_characters[i] = cid
						used.append(cid)
						break


func _assign_online_accessories() -> void:
	## Map peer headwear/cloth choices onto player slots -- no conflict
	## resolution needed since accessories may duplicate across players (see
	## CLAUDE.md's uniqueness note, scoped to the base character only).
	var total: int = GameManager.total_players
	for i: int in total:
		var peer_id: int = i + 1
		if NetworkManager.peer_headwear.has(peer_id):
			GameManager.player_headwear[i] = str(NetworkManager.peer_headwear[peer_id])
		if NetworkManager.peer_cloth.has(peer_id):
			GameManager.player_cloth[i] = str(NetworkManager.peer_cloth[peer_id])


func _on_character_chosen(_peer_id: int, _char_id: String) -> void:
	if _screen == "waiting":
		_rebuild_ui()
