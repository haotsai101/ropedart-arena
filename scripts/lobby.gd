extends Control
## Lobby: multi-screen online match-setup UI built entirely in code.
## Screens: "username" → "browser" → "waiting"
## _set_screen() transitions between them by rebuilding all child nodes.

const DIFFICULTY_LABELS: Array = ["Easy", "Medium", "Hard"]
const DIFF_LABEL_UPPER: Array = ["EASY", "MEDIUM", "HARD"]

# Colors
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
const COLOR_ACCENT         := Color(0.60, 0.85, 1.00, 1.0)
const COLOR_ROW_SELECTED   := Color(0.15, 0.25, 0.45, 1.0)
const COLOR_HOST_TAG       := Color(0.90, 0.70, 0.20, 1.0)

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
var _wait_settings_focus: int = 0   # 0 = max_players row, 1 = bot_difficulty row
var _lives_value: int = 3
var _rounds_value: int = 3

# Local config screen
var _local_total_players: int = 4
var _local_bot_difficulty: int = 0
var _local_focus: int = 0   # 0 = total players, 1 = difficulty

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
var _wait_code_lbl: Label = null
var _wait_prompt_lbl: Label = null
var _wait_error_lbl: Label = null

var _local_total_lbl: Label = null
var _local_diff_lbl: Label = null


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE

	# Connect NetworkManager signals once; callbacks check _screen
	NetworkManager.rooms_fetched.connect(_on_rooms_fetched)
	NetworkManager.connected_to_room.connect(_on_connected_to_room)
	NetworkManager.player_list_updated.connect(_on_player_list_updated)
	NetworkManager.settings_updated.connect(_on_settings_updated)
	NetworkManager.game_starting.connect(_on_game_starting)
	NetworkManager.host_disconnected.connect(_on_host_disconnected)
	NetworkManager.peer_disconnected.connect(_on_peer_disconnected)
	NetworkManager.connection_failed.connect(_on_connection_failed)

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
	_wait_code_lbl = null
	_wait_prompt_lbl = null
	_wait_error_lbl = null
	_local_total_lbl = null
	_local_diff_lbl = null

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
	_add_title("DARTROPE ARENA", 64)
	_add_subtitle("Enter your username", 20)

	const PANEL_W: int = 520
	const PANEL_H: int = 180

	var panel := _make_panel(PANEL_W, PANEL_H, 0)
	add_child(panel)

	var vbox := VBoxContainer.new()
	vbox.set_anchors_preset(Control.PRESET_FULL_RECT)
	vbox.offset_left = 32
	vbox.offset_top = 24
	vbox.offset_right = -32
	vbox.offset_bottom = -24
	vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_theme_constant_override("separation", 16)
	vbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(vbox)

	var hint := Label.new()
	hint.text = "A-Z  0-9  _   Backspace to delete   Enter to confirm"
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.add_theme_font_size_override("font_size", 15)
	hint.add_theme_color_override("font_color", COLOR_DIM)
	vbox.add_child(hint)

	_username_input_lbl = Label.new()
	_username_input_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_username_input_lbl.add_theme_font_size_override("font_size", 36)
	_username_input_lbl.add_theme_color_override("font_color", COLOR_VALUE)
	vbox.add_child(_username_input_lbl)

	var min_hint := Label.new()
	min_hint.text = "2 – 16 characters"
	min_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	min_hint.add_theme_font_size_override("font_size", 14)
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
	_add_title("DARTROPE ARENA", 64)
	_add_subtitle("Welcome,  " + UsernameManager.username, 20)

	const PANEL_W: int = 720
	const PANEL_H: int = 440

	var panel := _make_panel(PANEL_W, PANEL_H, 0)
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
	header.add_theme_font_size_override("font_size", 15)
	header.custom_minimum_size = Vector2(0, 36)
	root_vbox.add_child(header)

	# Separator
	var sep := HSeparator.new()
	sep.add_theme_color_override("color", COLOR_PANEL_BORDER)
	sep.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root_vbox.add_child(sep)

	# Status label (loading / empty)
	_browser_status_lbl = Label.new()
	_browser_status_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_browser_status_lbl.add_theme_font_size_override("font_size", 20)
	_browser_status_lbl.add_theme_color_override("font_color", COLOR_DIM)
	_browser_status_lbl.custom_minimum_size = Vector2(0, 40)
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
	bottom.add_theme_font_size_override("font_size", 16)
	bottom.custom_minimum_size = Vector2(0, 44)
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
	lbl.add_theme_font_size_override("font_size", 18)
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
		row.custom_minimum_size = Vector2(0, 44)
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
		lbl.add_theme_font_size_override("font_size", 18)
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
	_add_title("DARTROPE ARENA", 56)

	const PANEL_W: int = 680
	const PANEL_H: int = 520

	var panel := _make_panel(PANEL_W, PANEL_H, 20)
	add_child(panel)

	var root_vbox := VBoxContainer.new()
	root_vbox.set_anchors_preset(Control.PRESET_FULL_RECT)
	root_vbox.offset_left = 28
	root_vbox.offset_top = 20
	root_vbox.offset_right = -28
	root_vbox.offset_bottom = -20
	root_vbox.add_theme_constant_override("separation", 14)
	root_vbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(root_vbox)

	# Room code row
	var code_hbox := HBoxContainer.new()
	code_hbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root_vbox.add_child(code_hbox)

	_wait_code_lbl = Label.new()
	_wait_code_lbl.text = "Room: " + NetworkManager.room_code
	_wait_code_lbl.add_theme_font_size_override("font_size", 22)
	_wait_code_lbl.add_theme_color_override("font_color", COLOR_ACCENT)
	_wait_code_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_wait_code_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	code_hbox.add_child(_wait_code_lbl)

	var copy_hint := Label.new()
	copy_hint.text = "[share this code]"
	copy_hint.add_theme_font_size_override("font_size", 14)
	copy_hint.add_theme_color_override("font_color", COLOR_DIM)
	copy_hint.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	copy_hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	code_hbox.add_child(copy_hint)

	# Players section
	var player_count: int = NetworkManager.room_settings.get("max_players", 4)
	var players_header := Label.new()
	players_header.text = "PLAYERS  (%d / %d)" % [NetworkManager.room_players.size(), player_count]
	players_header.add_theme_font_size_override("font_size", 16)
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
	settings_header.add_theme_font_size_override("font_size", 16)
	settings_header.add_theme_color_override("font_color", COLOR_DIM)
	settings_header.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root_vbox.add_child(settings_header)

	_build_settings_rows(root_vbox)

	# Separator
	var sep2 := HSeparator.new()
	sep2.add_theme_color_override("color", COLOR_PANEL_BORDER)
	sep2.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root_vbox.add_child(sep2)

	# Prompt / action hint
	_wait_prompt_lbl = Label.new()
	_wait_prompt_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_wait_prompt_lbl.add_theme_font_size_override("font_size", 19)
	_wait_prompt_lbl.add_theme_color_override("font_color", COLOR_PROMPT)
	_wait_prompt_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root_vbox.add_child(_wait_prompt_lbl)

	_wait_error_lbl = Label.new()
	_wait_error_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_wait_error_lbl.add_theme_font_size_override("font_size", 17)
	_wait_error_lbl.add_theme_color_override("font_color", Color(0.9, 0.3, 0.3, 1.0))
	_wait_error_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root_vbox.add_child(_wait_error_lbl)

	if _error_message != "":
		_wait_error_lbl.text = _error_message

	var leave_lbl := Label.new()
	leave_lbl.text = "[Esc / B] Leave room"
	leave_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	leave_lbl.add_theme_font_size_override("font_size", 15)
	leave_lbl.add_theme_color_override("font_color", COLOR_DIM)
	leave_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root_vbox.add_child(leave_lbl)

	_update_wait_prompt()


func _build_settings_rows(parent: VBoxContainer) -> void:
	var is_host: bool = NetworkManager.is_host
	var max_p: int = NetworkManager.room_settings.get("max_players", 4)
	var diff: int = NetworkManager.room_settings.get("bot_difficulty", 0)

	# Row 0: max_players
	var row0 := _make_settings_row(
		"Total Players",
		str(max_p),
		_wait_settings_focus == 0 and is_host
	)
	_wait_settings_max_lbl = row0.get_node_or_null("ValueLabel")
	parent.add_child(row0)

	# Row 1: bot_difficulty
	var row1 := _make_settings_row(
		"Bot Difficulty",
		DIFFICULTY_LABELS[clampi(diff, 0, 2)],
		_wait_settings_focus == 1 and is_host
	)
	_wait_settings_diff_lbl = row1.get_node_or_null("ValueLabel")
	parent.add_child(row1)


func _make_settings_row(label_text: String, value_text: String, focused: bool, force_arrows: bool = false) -> Panel:
	var row := Panel.new()
	row.custom_minimum_size = Vector2(0, 48)
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
	name_lbl.add_theme_font_size_override("font_size", 18)
	name_lbl.add_theme_color_override("font_color", COLOR_TEXT)
	name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	name_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hbox.add_child(name_lbl)

	if NetworkManager.is_host or force_arrows:
		var arrow_l := Label.new()
		arrow_l.text = "◀"
		arrow_l.add_theme_font_size_override("font_size", 18)
		arrow_l.add_theme_color_override("font_color", COLOR_DIM if not focused else COLOR_VALUE)
		arrow_l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		arrow_l.mouse_filter = Control.MOUSE_FILTER_IGNORE
		hbox.add_child(arrow_l)

	var val_lbl := Label.new()
	val_lbl.name = "ValueLabel"
	val_lbl.text = value_text
	val_lbl.custom_minimum_size = Vector2(120, 0)
	val_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	val_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	val_lbl.add_theme_font_size_override("font_size", 22)
	val_lbl.add_theme_color_override("font_color", COLOR_VALUE)
	val_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hbox.add_child(val_lbl)

	if NetworkManager.is_host or force_arrows:
		var arrow_r := Label.new()
		arrow_r.text = "▶"
		arrow_r.add_theme_font_size_override("font_size", 18)
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
		var slot := Label.new()
		slot.add_theme_font_size_override("font_size", 18)
		slot.mouse_filter = Control.MOUSE_FILTER_IGNORE
		if i < players.size():
			var pd: Dictionary = players[i]
			var uname: String = str(pd.get("username", "Player"))
			var pid: int = int(pd.get("peer_id", i + 1))
			var is_host_player: bool = pid == 1
			slot.text = ("► " if i == 0 else "  ") + uname + (" (Host)" if is_host_player else "")
			slot.add_theme_color_override("font_color", COLOR_HOST_TAG if is_host_player else COLOR_TEXT)
		else:
			slot.text = "  [waiting...]"
			slot.add_theme_color_override("font_color", COLOR_DIM)
		_wait_players_vbox.add_child(slot)


func _update_wait_prompt() -> void:
	if _wait_prompt_lbl == null:
		return
	if NetworkManager.is_host:
		_wait_prompt_lbl.text = "Enter / A  =  START GAME     Up/Down  =  navigate settings"
	else:
		_wait_prompt_lbl.text = "Waiting for host to start the game..."


# ===========================================================================
# Shared UI helpers
# ===========================================================================

func _add_title(text: String, font_size: int) -> void:
	var lbl := Label.new()
	lbl.text = text
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.add_theme_font_size_override("font_size", font_size)
	lbl.add_theme_color_override("font_color", COLOR_TITLE)
	lbl.add_theme_color_override("font_shadow_color", Color(0.0, 0.15, 0.5, 0.75))
	lbl.add_theme_constant_override("shadow_offset_x", 3)
	lbl.add_theme_constant_override("shadow_offset_y", 3)
	lbl.set_anchor(SIDE_LEFT, 0.0)
	lbl.set_anchor(SIDE_RIGHT, 1.0)
	lbl.offset_top = 36
	lbl.offset_bottom = 36 + font_size + 20
	lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(lbl)


func _add_subtitle(text: String, font_size: int) -> void:
	var lbl := Label.new()
	lbl.text = text
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.add_theme_font_size_override("font_size", font_size)
	lbl.add_theme_color_override("font_color", COLOR_DIM)
	lbl.set_anchor(SIDE_LEFT, 0.0)
	lbl.set_anchor(SIDE_RIGHT, 1.0)
	lbl.offset_top = 120
	lbl.offset_bottom = 150
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


# ===========================================================================
# INPUT
# ===========================================================================

func _input(event: InputEvent) -> void:
	var vp: Viewport = get_viewport()
	match _screen:
		"username":
			_input_username(event, vp)
		"browser":
			_input_browser(event, vp)
		"waiting":
			_input_waiting(event, vp)
		"local_config":
			_input_local_config(event, vp)


func _input_username(event: InputEvent, vp: Viewport) -> void:
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
				if vp: vp.set_input_as_handled()
		KEY_BACKSPACE:
			if _typed_username.length() > 0:
				_typed_username = _typed_username.left(_typed_username.length() - 1)
			_update_username_cursor()
			if vp: vp.set_input_as_handled()
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
					if vp: vp.set_input_as_handled()


func _input_browser(event: InputEvent, vp: Viewport) -> void:
	if event.is_action_pressed("ui_up"):
		if _browser_rooms.size() > 0:
			_browser_selected = (_browser_selected - 1 + _browser_rooms.size()) % _browser_rooms.size()
			_refresh_browser_list()
		if vp: vp.set_input_as_handled()
	elif event.is_action_pressed("ui_down"):
		if _browser_rooms.size() > 0:
			_browser_selected = (_browser_selected + 1) % _browser_rooms.size()
			_refresh_browser_list()
		if vp: vp.set_input_as_handled()
	elif event.is_action_pressed("ui_accept"):
		_browser_try_join()
		if vp: vp.set_input_as_handled()
	elif event is InputEventKey and (event as InputEventKey).pressed:
		var ke := event as InputEventKey
		match ke.keycode:
			KEY_R:
				_browser_refresh_timer = 0.0
				_do_fetch_rooms()
				if vp: vp.set_input_as_handled()
			KEY_N:
				_begin_host()
				if vp: vp.set_input_as_handled()
			KEY_B:
				_begin_local_game()
				if vp: vp.set_input_as_handled()
	elif event is InputEventJoypadButton and (event as InputEventJoypadButton).pressed:
		var jb := event as InputEventJoypadButton
		match jb.button_index:
			JOY_BUTTON_Y:   # Y = refresh
				_browser_refresh_timer = 0.0
				_do_fetch_rooms()
				if vp: vp.set_input_as_handled()
			JOY_BUTTON_X:   # X = new game
				_begin_host()
				if vp: vp.set_input_as_handled()
			JOY_BUTTON_A:   # A = join
				_browser_try_join()
				if vp: vp.set_input_as_handled()


func _input_waiting(event: InputEvent, vp: Viewport) -> void:
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
		if vp: vp.set_input_as_handled()
		return

	if NetworkManager.is_host:
		_input_waiting_host(event, vp)


func _input_waiting_host(event: InputEvent, vp: Viewport) -> void:
	if event.is_action_pressed("ui_up"):
		_wait_settings_focus = (_wait_settings_focus - 1 + 2) % 2
		_rebuild_settings_only()
		if vp: vp.set_input_as_handled()
	elif event.is_action_pressed("ui_down"):
		_wait_settings_focus = (_wait_settings_focus + 1) % 2
		_rebuild_settings_only()
		if vp: vp.set_input_as_handled()
	elif event.is_action_pressed("ui_left"):
		_change_wait_setting(-1)
		if vp: vp.set_input_as_handled()
	elif event.is_action_pressed("ui_right"):
		_change_wait_setting(1)
		if vp: vp.set_input_as_handled()
	elif event.is_action_pressed("ui_accept"):
		_start_online_game()
		if vp: vp.set_input_as_handled()


func _change_wait_setting(delta: int) -> void:
	var max_p: int = NetworkManager.room_settings.get("max_players", 4)
	var diff: int = NetworkManager.room_settings.get("bot_difficulty", 0)
	var human_count: int = NetworkManager.room_players.size()

	if _wait_settings_focus == 0:
		var min_p: int = maxi(2, human_count)
		max_p = clampi(max_p + delta, min_p, 6)
		NetworkManager.update_settings(max_p, diff)
	else:
		diff = clampi(diff + delta, 0, 2)
		NetworkManager.update_settings(max_p, diff)

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
	NetworkManager.create_room(max_p, diff)
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

	const PANEL_W: int = 580
	const PANEL_H: int = 300

	var panel := _make_panel(PANEL_W, PANEL_H, 20)
	add_child(panel)

	var root_vbox := VBoxContainer.new()
	root_vbox.set_anchors_preset(Control.PRESET_FULL_RECT)
	root_vbox.offset_left = 28
	root_vbox.offset_top = 20
	root_vbox.offset_right = -28
	root_vbox.offset_bottom = -20
	root_vbox.add_theme_constant_override("separation", 14)
	root_vbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(root_vbox)

	var settings_header := Label.new()
	settings_header.text = "SETTINGS"
	settings_header.add_theme_font_size_override("font_size", 16)
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

	var sep := HSeparator.new()
	sep.add_theme_color_override("color", COLOR_PANEL_BORDER)
	sep.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root_vbox.add_child(sep)

	var prompt_lbl := Label.new()
	prompt_lbl.text = "Enter = Start   Esc = Back"
	prompt_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	prompt_lbl.add_theme_font_size_override("font_size", 19)
	prompt_lbl.add_theme_color_override("font_color", COLOR_PROMPT)
	prompt_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root_vbox.add_child(prompt_lbl)


func _change_local_setting(delta: int) -> void:
	if _local_focus == 0:
		_local_total_players = clampi(_local_total_players + delta, 2, 6)
	else:
		_local_bot_difficulty = clampi(_local_bot_difficulty + delta, 0, 2)
	_rebuild_ui()


func _input_local_config(event: InputEvent, vp: Viewport) -> void:
	if event.is_action_pressed("ui_up"):
		_local_focus = (_local_focus - 1 + 2) % 2
		_rebuild_ui()
		if vp: vp.set_input_as_handled()
	elif event.is_action_pressed("ui_down"):
		_local_focus = (_local_focus + 1) % 2
		_rebuild_ui()
		if vp: vp.set_input_as_handled()
	elif event.is_action_pressed("ui_left"):
		_change_local_setting(-1)
		if vp: vp.set_input_as_handled()
	elif event.is_action_pressed("ui_right"):
		_change_local_setting(1)
		if vp: vp.set_input_as_handled()
	elif event.is_action_pressed("ui_accept"):
		_start_local_game()
		if vp: vp.set_input_as_handled()
	elif event is InputEventKey and (event as InputEventKey).pressed:
		var ke := event as InputEventKey
		if ke.keycode == KEY_ESCAPE:
			_set_screen("browser")
			if vp: vp.set_input_as_handled()


func _start_local_game() -> void:
	GameManager.is_online = false
	GameManager.lobby_mode = false
	GameManager.total_players = _local_total_players
	GameManager.human_count = 1
	GameManager.bot_difficulty = _local_bot_difficulty
	GameManager.lives_per_round = 3
	GameManager.rounds_to_win = 3
	get_tree().change_scene_to_file("res://scenes/main.tscn")
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
	get_tree().change_scene_to_file("res://scenes/main.tscn")
	GameManager.call_deferred("_init_game")
