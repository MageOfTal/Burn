extends Resource
class_name ObjStructureData

## Pre-baked voxelized representation of an OBJ mesh.
## Created by the Node.js voxelizer tool (tools/obj-voxelizer/voxelize.js),
## consumed by DestructibleObjStructure at runtime.
##
## The voxelizer converts an arbitrary .obj mesh into a set of occupied 0.5m
## grid cells. This resource stores that grid data plus a reference to the
## original texture for triplanar UV projection on the greedy mesh.

## Which grid cells are occupied (integer grid coordinates, not world units).
@export var occupied_cells: Array[Vector3i] = []

## Grid dimensions (max extent in each axis, in block count).
@export var grid_dimensions: Vector3i = Vector3i.ZERO

## The original texture from the OBJ's material.
@export var texture: Texture2D = null

## Original mesh AABB in local space (used for triplanar UV projection).
## Stored as separate vectors because AABB is not directly @export-able.
@export var mesh_aabb_position: Vector3 = Vector3.ZERO
@export var mesh_aabb_size: Vector3 = Vector3.ONE
