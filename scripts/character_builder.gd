class_name CharacterBuilder
extends RefCounted
## Shared character-mesh assembly: base body + optional headwear/cloth swap.
## Used by both the live player (player.gd, one build per spawn) and the
## lobby's live 3D preview (lobby.gd, rebuilt on every cursor move) -- see
## GameManager's CHARACTER_DEFS/HEADWEAR_DEFS/CLOTH_DEFS for the data pools
## this consumes, and GameManager.resolve_headwear_id/resolve_cloth_id for
## turning a player's raw ("" = unset) choice into the concrete id this
## expects.
##
## Mix-and-match works because every KayKit Adventurers character glb shares
## one identical skeleton ("Rig_Medium", same bone names across all six) --
## skin binding in glTF/Godot is by bone NAME, not node index, so a
## MeshInstance3D pulled from one character's glb reparents cleanly under a
## different character's Skeleton3D and still skins correctly. Godot's own
## glTF import convention puts every skinned MeshInstance3D as a direct child
## of its Skeleton3D with `skeleton = NodePath("..")` -- this is what lets
## _apply_accessory_slot() just re-home the mesh node and reset that one
## NodePath, with no manual bone/weight rebinding needed.

const NONE_ID := "none"


static func build_character_visual(base_id: String, headwear_id: String, cloth_id: String) -> Node3D:
	var char_def: Dictionary = GameManager.get_character_def(base_id)
	var base_scene: PackedScene = load(str(char_def.get("glb_path", "")))
	if base_scene == null:
		return null
	var root: Node3D = base_scene.instantiate()
	root.name = "CharacterMesh"

	var skeleton: Skeleton3D = find_skeleton(root)
	if skeleton != null:
		var native_headwear: String = str(char_def.get("native_headwear", NONE_ID))
		var native_cloth: String = str(char_def.get("native_cloth", NONE_ID))
		_apply_accessory_slot(root, skeleton, native_headwear, headwear_id, GameManager.HEADWEAR_DEFS)
		_apply_accessory_slot(root, skeleton, native_cloth, cloth_id, GameManager.CLOTH_DEFS)

	# Tint every mesh part with the character color (emission layer, texture
	# stays visible underneath) -- mirrors player.gd's _reset_player_tint();
	# applied here too so swapped-in accessory parts get the same treatment
	# as the base body, and so the lobby preview matches in-game appearance.
	var character_color: Color = char_def.get("character_color", Color.WHITE)
	for mi: MeshInstance3D in find_mesh_instances(root):
		var base_mat: Material = mi.get_active_material(0)
		var mat: StandardMaterial3D = (base_mat.duplicate() as StandardMaterial3D) if base_mat is StandardMaterial3D else StandardMaterial3D.new()
		mat.albedo_color = Color.WHITE
		mat.transparency = BaseMaterial3D.TRANSPARENCY_DISABLED
		mat.emission_enabled = true
		mat.emission = character_color * 0.4
		mi.set_surface_override_material(0, mat)

	return root


static func _apply_accessory_slot(root: Node3D, base_skeleton: Skeleton3D, native_id: String, resolved_id: String, defs_pool: Array) -> void:
	if resolved_id == native_id:
		return  # base character's own native accessory (or lack of one) is already correct

	# Remove the base character's own native accessory mesh(es), if any --
	# either being replaced by a different pick, or explicitly set to "none".
	if native_id != NONE_ID:
		var native_def: Dictionary = _find_def(defs_pool, native_id)
		for mesh_name: String in (native_def.get("mesh_names", []) as Array):
			var native_mesh: Node = root.find_child(str(mesh_name), true, false)
			if native_mesh != null:
				native_mesh.get_parent().remove_child(native_mesh)
				native_mesh.queue_free()

	if resolved_id == NONE_ID:
		return

	# Pull the picked accessory's mesh(es) out of its source character's own
	# glb and reparent them under the base character's skeleton -- see this
	# file's header comment for why this skins correctly.
	var resolved_def: Dictionary = _find_def(defs_pool, resolved_id)
	var source_char_id: String = str(resolved_def.get("source_char_id", ""))
	if source_char_id == "":
		return
	var source_char_def: Dictionary = GameManager.get_character_def(source_char_id)
	var source_scene: PackedScene = load(str(source_char_def.get("glb_path", "")))
	if source_scene == null:
		return
	var temp_instance: Node3D = source_scene.instantiate()
	for mesh_name: String in (resolved_def.get("mesh_names", []) as Array):
		var part: Node = temp_instance.find_child(str(mesh_name), true, false)
		if part == null:
			continue
		part.get_parent().remove_child(part)
		# Clear the owner inherited from temp_instance's packed scene BEFORE
		# reparenting -- otherwise Godot warns the owner is "inconsistent"
		# (it still points at the temp instance's root, which gets queue_free'd
		# right after this loop) every single time a part is swapped in.
		part.owner = null
		base_skeleton.add_child(part)
		if part is MeshInstance3D:
			(part as MeshInstance3D).skeleton = part.get_path_to(base_skeleton)
	temp_instance.queue_free()


static func _find_def(defs_pool: Array, def_id: String) -> Dictionary:
	for def: Dictionary in defs_pool:
		if def.get("id", "") == def_id:
			return def
	return {}


static func find_skeleton(node: Node) -> Skeleton3D:
	if node is Skeleton3D:
		return node
	for child in node.get_children():
		var found: Skeleton3D = find_skeleton(child)
		if found != null:
			return found
	return null


static func find_mesh_instances(node: Node) -> Array[MeshInstance3D]:
	var found: Array[MeshInstance3D] = []
	if node is MeshInstance3D:
		found.append(node)
	for child in node.get_children():
		found.append_array(find_mesh_instances(child))
	return found
