class_name TerrainGenerator
extends VoxelGeneratorScript

## Generates terrain SDF from 2D noise — same formula as the old TerrainSDFGrid.
## Used by VoxelLodTerrain for automatic threaded chunk generation.

var noise: FastNoiseLite
var height_range: float = 32.0


func _get_used_channels_mask() -> int:
	return 1 << VoxelBuffer.CHANNEL_SDF


func _generate_block(buffer: VoxelBuffer, origin: Vector3i, lod: int) -> void:
	var step: int = 1 << lod
	var size: Vector3i = buffer.get_size()

	for lz in size.z:
		var wz: float = float(origin.z + lz * step)
		for ly in size.y:
			var wy: float = float(origin.y + ly * step)
			for lx in size.x:
				var wx: float = float(origin.x + lx * step)
				var surface_y := (noise.get_noise_2d(wx, wz) + 1.0) * 0.5 * height_range
				buffer.set_voxel_f(wy - surface_y, lx, ly, lz, VoxelBuffer.CHANNEL_SDF)
