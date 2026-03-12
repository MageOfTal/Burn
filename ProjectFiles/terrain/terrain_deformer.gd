class_name TerrainDeformer
extends RefCounted

## Handles terrain deformation (craters, digging).
## Stamps the SDF grid and returns the set of chunks that need re-meshing.

const SKIRT := 0  # must match TerrainMesher.SKIRT


func deform_sphere(sdf_grid: TerrainSDFGrid, center: Vector3, radius: float) -> Array[Vector3i]:
	## Subtract a sphere from the terrain.
	## Returns all block positions that need re-meshing (including neighbors
	## whose skirt/padding region overlaps the deformed voxels).
	var directly_dirty: Array[Vector3i] = sdf_grid.stamp_sphere(center, radius)

	# Expand dirty set: any chunk whose TransVoxel padding region overlaps a
	# modified chunk also needs re-meshing (the 26 neighbors).
	var expanded: Dictionary = {}
	for bp in directly_dirty:
		for dz in range(-1, 2):
			for dy in range(-1, 2):
				for dx in range(-1, 2):
					expanded[bp + Vector3i(dx, dy, dz)] = true

	var result: Array[Vector3i] = []
	for bp: Vector3i in expanded:
		result.append(bp)
	return result
