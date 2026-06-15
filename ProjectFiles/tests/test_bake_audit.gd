extends SceneTree

# Audit terrain_bake.bin: find chunks with collision faces but no render
# mesh (would be invisible-but-solid), or vice versa.

func _init() -> void:
	var f := FileAccess.open("res://terrain/terrain_bake.bin", FileAccess.READ)
	if f == null:
		print("[AUDIT] no bake file")
		quit(1)
		return
	var d: Dictionary = f.get_var(true)
	f.close()
	var chunk_data: Dictionary = d.get("chunk_data", {})
	var n_faces_no_verts := 0
	var n_verts_no_faces := 0
	for bp in chunk_data:
		var e: Dictionary = chunk_data[bp]
		var has_verts: bool = e.has("verts") and not (e["verts"] as PackedVector3Array).is_empty()
		var faces: PackedVector3Array = e.get("faces", PackedVector3Array())
		if not has_verts and not faces.is_empty():
			n_faces_no_verts += 1
			print("[AUDIT] chunk %s: %d collision faces but NO render verts (invisible collision!)" % [str(bp), faces.size() / 3])
		elif has_verts and faces.is_empty():
			n_verts_no_faces += 1
			print("[AUDIT] chunk %s: render verts but no collision faces" % str(bp))
	print("[AUDIT] %d chunks total, %d faces-without-mesh, %d mesh-without-faces" % [
		chunk_data.size(), n_faces_no_verts, n_verts_no_faces])
	quit(0)
