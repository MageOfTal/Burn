extends Node3D

# One-off forensic probe: the player logged an unexplained upward bump while
# running on visually-smooth ground near (37.48, 21.86, 111.19) heading
# (0.849, 0, 0.528). The CV contact dump showed a 33° facet (cn = sn =
# (-0.387, 0.837, -0.387)) and a down-cast hit a 54.7° facet, while the SDF
# ground truth claims ~16°. Terrain is fixed-seed, so this probes the exact
# spot: (A) collision-ray grid → real facet normals, (B) SDF heights → smooth
# truth, (C) a CV oracle retracing the logged path → exactly what the
# controller saw.
#
# Run headless: Godot --headless res://tests/test_terrain_probe.tscn

const CENTER := Vector3(37.478, 21.858, 111.190)
const HEADING := Vector3(0.849, 0.0, 0.528)

var _map: Node = null
var _frames := 0
var _terrain_ready := false

func _ready() -> void:
	_map = load("res://world/blockout_map.tscn").instantiate()
	add_child(_map)
	# Terrain + structures build only when the network flow asks for it —
	# drive it directly so the probe sees the user's exact world (fixed seed).
	var sw: Node = _map.get_node_or_null("SeedWorld")
	if sw == null:
		sw = _map.find_child("SeedWorld", true, false)
	if sw != null and sw.has_method("_spawn_heavy_structures"):
		sw.call_deferred("_spawn_heavy_structures")


func _physics_process(_delta: float) -> void:
	_frames += 1
	if _frames < 10:
		return
	if not _terrain_ready:
		# Wait for the FULL initial build (so _save_full_bake runs and the
		# bake regenerates), not just terrain under the probe point.
		var sw0: Node = _map.find_child("SeedWorld", true, false)
		var ts: Node = sw0.get_node_or_null("TerrainSystem") if sw0 else null
		if ts == null or not ts._initial_load_done:
			if _frames > 3600:
				print("[PROBE] FAIL: terrain build incomplete after %d frames" % _frames)
				get_tree().quit(1)
			return
		_terrain_ready = true
		_frames = 0
		return
	if _frames < 30:
		return  # settle a little more
	_run_probe()
	get_tree().quit(0)


func _ray(from: Vector3) -> Dictionary:
	var q := PhysicsRayQueryParameters3D.new()
	q.from = from
	q.to = from + Vector3(0, -40, 0)
	q.collision_mask = 1  # WORLD / terrain
	return get_world_3d().direct_space_state.intersect_ray(q)


func _run_probe() -> void:
	var sw: Node = _map.get_node_or_null("SeedWorld")
	if sw == null:
		sw = _map.find_child("SeedWorld", true, false)
	print("[PROBE] SeedWorld=%s  has_noise_height=%s" % [str(sw), str(sw != null and sw.has_method("get_height_from_noise"))])

	# ── A: collision facet grid ─────────────────────────────────────────
	var bins := {}
	var steep: Array = []
	var n_hits := 0
	var x := CENTER.x - 1.2
	while x <= CENTER.x + 1.6:
		var z := CENTER.z - 1.2
		while z <= CENTER.z + 1.6:
			var hit := _ray(Vector3(x, CENTER.y + 5.0, z))
			if not hit.is_empty():
				n_hits += 1
				var ang := rad_to_deg((hit.normal as Vector3).angle_to(Vector3.UP))
				var bin := int(ang / 5.0) * 5
				bins[bin] = int(bins.get(bin, 0)) + 1
				if ang > 25.0 and steep.size() < 24:
					steep.append("    (%.2f, %.2f) y=%.3f n=(%.3f,%.3f,%.3f) θ=%.1f° collider=%s" % [
						x, z, hit.position.y, hit.normal.x, hit.normal.y, hit.normal.z, ang,
						(hit.collider.name if hit.collider else "?")])
			z += 0.06
		x += 0.06
	var keys := bins.keys()
	keys.sort()
	var hist := ""
	for k in keys:
		hist += "  %d-%d°:%d" % [k, k + 5, bins[k]]
	print("[PROBE] A: %d ray hits, facet-angle histogram:%s" % [n_hits, hist])
	print("[PROBE] A: facets steeper than 25° (max 24 shown):")
	for s in steep:
		print(s)

	# ── B: SDF smooth truth on the same patch ──────────────────────────
	if sw != null and sw.has_method("get_height_from_noise"):
		var max_sdf := 0.0
		var eps := 0.05
		x = CENTER.x - 1.2
		while x <= CENTER.x + 1.6:
			var z := CENTER.z - 1.2
			while z <= CENTER.z + 1.6:
				var h: float = sw.get_height_from_noise(x, z)
				var dx: float = (sw.get_height_from_noise(x + eps, z) - h) / eps
				var dz: float = (sw.get_height_from_noise(x, z + eps) - h) / eps
				var ang := rad_to_deg(Vector3(-dx, 1, -dz).normalized().angle_to(Vector3.UP))
				max_sdf = maxf(max_sdf, ang)
				z += 0.12
			x += 0.12
		var h0: float = sw.get_height_from_noise(CENTER.x, CENTER.z)
		print("[PROBE] B: SDF height at center = %.3f (logged terrain hit y=21.02); max SDF slope in patch = %.1f°" % [h0, max_sdf])

	# ── D: wide-area sliver census — where do steep facets live? ────────
	# Hypothesis: mesher slivers form where the smooth surface height grazes
	# a voxel layer boundary (height ≈ integer), i.e. along specific contour
	# bands — which is why the glitches cluster at "certain spots".
	var mod_bins := {}
	var sliver_count := 0
	var total := 0
	var sdf_dev_sum := 0.0
	var sample_lines: Array = []
	var wx := CENTER.x - 24.0
	while wx <= CENTER.x + 24.0:
		var wz := CENTER.z - 24.0
		while wz <= CENTER.z + 24.0:
			var hit := _ray(Vector3(wx, CENTER.y + 25.0, wz))
			if not hit.is_empty() and hit.collider != null and String(hit.collider.name) == "TerrainBody":
				total += 1
				var ang := rad_to_deg((hit.normal as Vector3).angle_to(Vector3.UP))
				# Smooth truth at this point:
				var sdf_ang := 0.0
				if sw != null and sw.has_method("get_height_from_noise"):
					var hh: float = sw.get_height_from_noise(wx, wz)
					var ddx: float = (sw.get_height_from_noise(wx + 0.05, wz) - hh) / 0.05
					var ddz: float = (sw.get_height_from_noise(wx, wz + 0.05) - hh) / 0.05
					sdf_ang = rad_to_deg(Vector3(-ddx, 1, -ddz).normalized().angle_to(Vector3.UP))
				if ang > sdf_ang + 15.0:
					sliver_count += 1
					sdf_dev_sum += ang - sdf_ang
					var ymod: float = fposmod((hit.position as Vector3).y, 1.0)
					var mbin := int(ymod * 10.0)
					mod_bins[mbin] = int(mod_bins.get(mbin, 0)) + 1
					if sample_lines.size() < 12:
						sample_lines.append("    (%.1f, %.1f) y=%.3f (y mod 1 = %.3f) facet=%.1f° sdf=%.1f°" % [
							wx, wz, hit.position.y, ymod, ang, sdf_ang])
			wz += 0.35
		wx += 0.35
	var mkeys := mod_bins.keys()
	mkeys.sort()
	var mhist := ""
	for k in mkeys:
		mhist += "  .%d:%d" % [k, mod_bins[k]]
	print("[PROBE] D: %d terrain samples over 48×48 m, %d sliver hits (facet > sdf+15°), avg excess %.1f°" % [
		total, sliver_count, (sdf_dev_sum / maxf(1.0, float(sliver_count)))])
	print("[PROBE] D: sliver hit-y mod 1.0 histogram (tenths):%s" % mhist)
	print("[PROBE] D: samples:")
	for s in sample_lines:
		print(s)

	# ── C: CV oracle retracing the logged path ──────────────────────────
	var cv := JoltCharacterVirtual3D.new()
	cv.capsule_radius = 0.4
	cv.capsule_height = 1.8
	cv.inner_body = false
	cv.collision_layer = 0
	cv.collision_mask = 1
	cv.predictive_contact_distance = 0.2
	cv.enhanced_internal_edge_removal = true
	add_child(cv)
	cv.update(Vector3.ZERO, 1.0 / 60.0, Vector3(0, -24, 0))  # force creation
	print("[PROBE] C: contacts along the logged path (capsule centers):")
	for i in range(13):
		var t := (float(i) - 6.0) * 0.12
		var p := CENTER + HEADING * t
		# Seat the capsule on the collision surface at this XZ.
		var ground := _ray(Vector3(p.x, CENTER.y + 5.0, p.z))
		if ground.is_empty():
			continue
		var center := Vector3(p.x, (ground.position as Vector3).y + 0.901, p.z)
		cv.global_position = center
		cv.refresh_contacts()
		var cs: Array = cv.get_contacts()
		var desc := ""
		for c in cs:
			var cn: Vector3 = c.get("contact_normal", Vector3.ZERO)
			var sn: Vector3 = c.get("surface_normal", Vector3.ZERO)
			desc += " [cn θ=%.1f° sn θ=%.1f° d=%.4f]" % [
				rad_to_deg(cn.angle_to(Vector3.UP)), rad_to_deg(sn.angle_to(Vector3.UP)),
				float(c.get("distance", 9.0))]
		print("    t=%+.2f (%.2f, %.2f, %.2f): %d contact(s)%s" % [t, center.x, center.y, center.z, cs.size(), desc])
