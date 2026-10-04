extends Node
## Mascot character wiring test (headless):
##   A: the builder gives the mascot's body parts the picked MASCOT_COLORS
##      color, its mask the picked pattern texture, and keeps its own
##      eye/leaf colors (no white-out, no emission glow)
##   B: the roster is mascot-only (KayKit characters disabled), and a stale
##      or unknown character id falls back to the mascot
##   C: a spawned mascot player restores those colors after a hit flash
##   D: accessory rules -- leaf/none fit, unknown (disabled KayKit) hats
##      don't and fall back to the native leaf
##   E: resolve_mascot_colors() gives every mascot in a match its own color
##   F: every HEADWEAR_DEFS hat builds onto the mascot: its mesh(es) appear,
##      skinned to the mascot skeleton, the native leaf is gone, and it sits
##      on the crown (rest-pose AABB above the body's top, not floating)
##
## Run: Godot --headless --path . res://tests/test_mascot_character.tscn

var failures := 0


func _ready() -> void:
	call_deferred("_run")


func _check(label: String, ok: bool, detail: String) -> void:
	print("[mascot test] %s: %s -- %s" % [label, "PASS" if ok else "FAIL", detail])
	if not ok:
		failures += 1


func _mats(root: Node, mesh_name: String) -> Array:
	var mi: MeshInstance3D = root.find_child(mesh_name, true, false)
	if mi == null:
		return []
	var out := []
	for s in mi.mesh.get_surface_count():
		out.append(mi.get_active_material(s))
	return out


func _run() -> void:
	# A
	var v: Node3D = CharacterBuilder.build_character_visual("char_mascot", "mascot_leaf", "none", 3, "heart")
	add_child(v)
	var green: Color = GameManager.mascot_color(3)
	var body: StandardMaterial3D = _mats(v, "Mascot_Body")[0]
	var hand: StandardMaterial3D = _mats(v, "Mascot_HandLeft")[0]
	var mask: StandardMaterial3D = _mats(v, "Mascot_Mask")[0]
	var eye: StandardMaterial3D = _mats(v, "Mascot_Face")[0]
	var leaf_mats: Array = _mats(v, "Mascot_Leaf")
	_check("A1 body+hands colored", body.albedo_color.is_equal_approx(green) and hand.albedo_color.is_equal_approx(green),
		"body %s hand %s want %s" % [body.albedo_color, hand.albedo_color, green])
	_check("A2 mask pattern", mask.albedo_texture != null and mask.albedo_texture.resource_path.ends_with("mask_heart.png"),
		"texture %s" % (mask.albedo_texture.resource_path if mask.albedo_texture else "none"))
	_check("A3 eyes stay dark, no glow", eye.albedo_color.v < 0.2 and body.emission == Color.BLACK,
		"eye %s body emission %s" % [eye.albedo_color, body.emission])
	_check("A4 leaf present + green", leaf_mats.size() == 2 and (leaf_mats[1] as StandardMaterial3D).albedo_color.g > (leaf_mats[1] as StandardMaterial3D).albedo_color.r,
		"leaf surfaces %d" % leaf_mats.size())
	var v_none: Node3D = CharacterBuilder.build_character_visual("char_mascot", "none", "none", 0, "plain")
	add_child(v_none)
	_check("A5 leaf removable", v_none.find_child("Mascot_Leaf", true, false) == null, "headwear none")

	# B
	_check("B mascot-only roster", GameManager.CHARACTER_DEFS.size() == 1 and GameManager.default_character_id() == "char_mascot"
		and GameManager.get_character_def("char_knight")["id"] == "char_mascot",
		"%d character(s), default %s" % [GameManager.CHARACTER_DEFS.size(), GameManager.default_character_id()])

	# C
	GameManager.current_state = GameManager.RoundState.PLAYING
	var p = (load("res://scenes/player.tscn") as PackedScene).instantiate()
	p.character_id = "char_mascot"
	p.mascot_color_index = 5
	p.mascot_mask_id = "star"
	add_child(p)
	await get_tree().physics_frame
	var blue: Color = GameManager.mascot_color(5)
	p._flash_materials(Color(1, 0, 0))
	await get_tree().create_timer(p.MELEE_FLASH_DURATION + 0.15).timeout
	var pb: StandardMaterial3D = _mats(p.player_mesh, "Mascot_Body")[0]
	_check("C HUD/pin color = body color", p.player_color.is_equal_approx(blue),
		"player_color %s want %s" % [p.player_color, blue])
	_check("C flash restores color", pb.albedo_color.is_equal_approx(blue) and pb.emission == Color.BLACK and p.character_color.is_equal_approx(blue),
		"albedo %s emission %s" % [pb.albedo_color, pb.emission])

	# D
	_check("D accessory rules",
		GameManager.accessory_fits("char_mascot", "mascot_leaf", true)
		and GameManager.accessory_fits("char_mascot", "none", true)
		and not GameManager.accessory_fits("char_mascot", "mage_hat", true)
		and not GameManager.accessory_fits("char_mascot", "knight_cape", false)
		and GameManager.resolve_headwear_id("char_mascot", "mage_hat") == "mascot_leaf",
		"leaf/none fit, unknown hats fall back to the native leaf")

	# E
	GameManager.total_players = 4
	GameManager.player_characters = {0: "char_mascot", 1: "char_mascot", 2: "char_mascot", 3: "char_mascot"}
	GameManager.player_colors = {0: 2, 1: 2, 3: 2}
	GameManager.resolve_mascot_colors()
	var cols: Array = [GameManager.player_colors[0], GameManager.player_colors[1], GameManager.player_colors[2], GameManager.player_colors[3]]
	var unique := {}
	for c in cols:
		unique[c] = true
	_check("E unique mascot colors", cols[0] == 2 and unique.size() == 4, "colors %s" % [cols])

	# F
	var hat_count := 0
	for def: Dictionary in GameManager.HEADWEAR_DEFS:
		var hid: String = def["id"]
		if hid == "none" or hid == "mascot_leaf":
			continue
		hat_count += 1
		var hv: Node3D = CharacterBuilder.build_character_visual("char_mascot", hid, "none", 0, "plain")
		add_child(hv)
		var skel: Skeleton3D = CharacterBuilder.find_skeleton(hv)
		var ok := hv.find_child("Mascot_Leaf", true, false) == null
		var detail := ""
		for mesh_name: String in def["mesh_names"]:
			var mi: MeshInstance3D = hv.find_child(mesh_name, true, false)
			if mi == null or mi.get_node_or_null(mi.skeleton) != skel:
				ok = false
				detail += "%s missing/unskinned " % mesh_name
				continue
			var box: AABB = mi.mesh.get_aabb()
			# crown top is at y=1.85 in rest pose; a hat must reach above it and
			# its bottom must be within the head (not floating, not at the feet)
			if box.end.y < 1.9 or box.position.y > 1.85 or box.position.y < 1.4:
				ok = false
			detail += "%s y %.2f..%.2f " % [mesh_name, box.position.y, box.end.y]
		_check("F hat %s" % hid, ok, detail)
		hv.queue_free()
	_check("F hat count", hat_count == 10, "%d hats" % hat_count)

	print("[mascot test] %s" % ("ALL PASSED" if failures == 0 else "%d FAILED" % failures))
	get_tree().quit(1 if failures else 0)
