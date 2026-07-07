extends SceneTree

# Measure VoxelBuffer's SDF quantization: write precise floats, read them
# back, find the step size near zero — the suspect behind terrain slivers
# along integer-height contour lines (corners within a half-quantum of the
# surface snap to coarse values → degenerate Transvoxel cells).
#
# Run: Godot --headless --script res://tests/test_sdf_quantization.gd

func _init() -> void:
	var b := VoxelBuffer.new()
	b.create(4, 4, 4)
	b.set_channel_depth(VoxelBuffer.CHANNEL_SDF, VoxelBuffer.DEPTH_16_BIT)
	var values := [0.0, 0.0005, 0.001, 0.002, 0.004, 0.008, 0.016, 0.05, 0.2, 1.0, 5.0, 30.0, -0.004, -0.05, -1.0, -30.0]
	print("[QUANT] 16-bit SDF channel write→read:")
	for v in values:
		b.set_voxel_f(v, 0, 0, 0, VoxelBuffer.CHANNEL_SDF)
		var r := b.get_voxel_f(0, 0, 0, VoxelBuffer.CHANNEL_SDF)
		print("  wrote %+.6f  read %+.6f  (err %+.6f)" % [v, r, r - v])
	# Find the quantum: smallest positive value that reads back nonzero.
	var lo := 0.0
	var hi := 0.1
	for i in range(40):
		var mid := (lo + hi) * 0.5
		b.set_voxel_f(mid, 0, 0, 0, VoxelBuffer.CHANNEL_SDF)
		if b.get_voxel_f(0, 0, 0, VoxelBuffer.CHANNEL_SDF) > 0.0:
			hi = mid
		else:
			lo = mid
	print("[QUANT] smallest write that reads back > 0: ~%.6f" % hi)
	quit(0)
