extends Node
## Persists the local player's chosen username to user://prefs.cfg.
## Autoloaded as "UsernameManager".

const SAVE_PATH := "user://prefs.cfg"
var username := ""


func _ready() -> void:
	_load()


func _load() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(SAVE_PATH) == OK:
		username = cfg.get_value("player", "username", "")


func save(new_name: String) -> void:
	username = new_name.strip_edges()
	var cfg := ConfigFile.new()
	cfg.set_value("player", "username", username)
	cfg.save(SAVE_PATH)


func has_username() -> bool:
	return username.strip_edges().length() > 0
