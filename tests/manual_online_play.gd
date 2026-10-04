extends Node
## Hands-on online test: a headless host + a windowed guest you play
## yourself, through the real signaling/relay server -- so what you feel is
## exactly what a remote player gets (client-side prediction included).
## The host's own player stands still (a target); extra slots are bots.
##
## Run via tests/run_manual_play.sh. User args:
##   --role=host|guest --url=wss://... --code-file=/path [--total=4]

const MAP := "res://scenes/main.tscn"


func _ready() -> void:
	var driver := Driver.new()
	driver.name = "ManualPlayDriver"
	get_tree().root.add_child.call_deferred(driver)


class Driver extends Node:
	var role := ""
	var url := ""
	var code_file := ""
	var total := 4
	var _started := false

	func _ready() -> void:
		for arg: String in OS.get_cmdline_user_args():
			if arg.begins_with("--role="):
				role = arg.get_slice("=", 1)
			elif arg.begins_with("--url="):
				url = arg.substr(6)
			elif arg.begins_with("--code-file="):
				code_file = arg.substr(12)
			elif arg.begins_with("--total="):
				total = int(arg.get_slice("=", 1))
		NetworkManager.set_signaling_url(url)
		NetworkManager.connection_failed.connect(func(r: String):
			print("[manual play %s] connection lost: %s" % [role, r])
			get_tree().quit(1))
		NetworkManager.host_disconnected.connect(func(): get_tree().quit(0))
		NetworkManager.game_starting.connect(_on_game_starting)
		if role == "host":
			NetworkManager.connected_to_room.connect(func(code: String, _id: int):
				var f := FileAccess.open(code_file, FileAccess.WRITE)
				f.store_string(code)
				f.close()
				print("[manual play host] room %s ready" % code))
			multiplayer.peer_connected.connect(func(_id: int):
				await get_tree().create_timer(0.5).timeout
				NetworkManager.send_start_game())
			# The guest leaving ends the session.
			multiplayer.peer_disconnected.connect(func(_id: int): get_tree().quit(0))
			NetworkManager.create_room(total, 0, 0)
		else:
			while not FileAccess.file_exists(code_file) or FileAccess.get_file_as_string(code_file).strip_edges() == "":
				await get_tree().create_timer(0.1).timeout
			NetworkManager.join_room(FileAccess.get_file_as_string(code_file).strip_edges())

	# Same steps lobby.gd's _start_online_game() takes, minus the UI.
	func _on_game_starting() -> void:
		if _started:
			return
		_started = true
		GameManager.is_online = true
		GameManager.total_players = total
		GameManager.bot_difficulty = 0
		GameManager.human_count = NetworkManager.room_players.size()
		GameManager.lobby_mode = false
		GameManager.selected_map_scene = MAP
		GameManager.rounds_to_win = 99  # keep playing instead of hitting MATCH_END
		GameManager.set_online_slots(NetworkManager.room_players)
		GameManager.assign_default_characters(hash(NetworkManager.room_code) & 0x7fffffff)
		get_tree().change_scene_to_file(MAP)
		GameManager.call_deferred("_init_game")
