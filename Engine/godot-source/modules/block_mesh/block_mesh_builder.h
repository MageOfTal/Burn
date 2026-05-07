#ifndef BLOCK_MESH_BUILDER_H
#define BLOCK_MESH_BUILDER_H

#include "core/object/object.h"
#include "scene/resources/material.h"
#include "scene/resources/mesh.h"
#include "servers/physics_3d/physics_server_3d.h"

class BlockMeshBuilder : public Object {
	GDCLASS(BlockMeshBuilder, Object);

	static BlockMeshBuilder *singleton;

	// Diagnostic logging toggle. When false, the stress solver suppresses its
	// per-call [StressIntegrity_*] prints. Off by default — enable from
	// GDScript when debugging.
	static bool s_stress_debug_print;

protected:
	static void _bind_methods();

public:
	static BlockMeshBuilder *get_singleton() { return singleton; }

	/// Enable/disable the stress solver's per-call debug logging. Off by default.
	void set_stress_debug_print(bool p_enabled) { s_stress_debug_print = p_enabled; }
	bool get_stress_debug_print() const { return s_stress_debug_print; }

	/// Build an ArrayMesh from a flat occupancy grid.
	/// block_grid: PackedByteArray of size num_x * num_y * num_z (1 = occupied, 0 = empty).
	/// Indexing: bx * num_y * num_z + by * num_z + bz.
	/// block_size: side length of each cube.
	/// centroid: offset subtracted from all vertex positions (centers the mesh).
	/// include_uvs: if true, default 0-1 UVs are emitted per face.
	/// Returns a new ArrayMesh with one surface (PRIMITIVE_TRIANGLES), or null if empty.
	Ref<ArrayMesh> build_block_mesh(
			const PackedByteArray &p_block_grid,
			int p_num_x, int p_num_y, int p_num_z,
			float p_block_size,
			const Vector3 &p_centroid,
			bool p_include_uvs = true);

	/// Build flat occupancy grid + centroid from a Dictionary[Vector3i -> float].
	/// Returns Dictionary with "block_grid" (PackedByteArray) and "centroid" (Vector3).
	Dictionary init_block_grid(
			const Dictionary &p_block_hp,
			int p_num_x, int p_num_y, int p_num_z,
			float p_block_size);

	/// Compute per-column contiguous-Y-run box shapes from a flat occupancy grid.
	/// Returns Array of Dictionary with "position" (Vector3) and "size" (Vector3).
	/// Positions are relative to centroid.
	TypedArray<Dictionary> compute_column_shapes(
			const PackedByteArray &p_block_grid,
			int p_num_x, int p_num_y, int p_num_z,
			float p_block_size,
			const Vector3 &p_centroid);

	/// Add N copies of the same shape to a body at different positions.
	/// Used for compound hit bodies where all blocks share one BoxShape3D.
	void bulk_add_shapes(
			const RID &p_body,
			const RID &p_shape,
			const PackedVector3Array &p_positions);

	/// Create N box shapes with individual sizes, add them to a body.
	/// Returns Array of BoxShape3D resources (caller must hold references).
	Array bulk_add_box_shapes(
			const RID &p_body,
			const PackedVector3Array &p_positions,
			const PackedVector3Array &p_sizes);

	/// All-in-one cluster initialization: grid + mesh + collision shapes + hit body.
	/// Takes the block_hp Dictionary, grid dimensions, and body RIDs.
	/// Returns Dictionary with:
	///   "block_grid": PackedByteArray (flat occupancy)
	///   "centroid": Vector3
	///   "mesh": ArrayMesh
	///   "col_shapes": Array of BoxShape3D (caller must hold refs)
	///   "col_count": int
	///   "shape_to_key": Array of Vector3i (hit body shape index -> grid key)
	Dictionary build_cluster(
			const Dictionary &p_block_hp,
			int p_num_x, int p_num_y, int p_num_z,
			float p_block_size,
			const RID &p_cluster_body,
			const RID &p_hit_body,
			const RID &p_hit_shape,
			bool p_include_uvs = true,
			bool p_manage_bulk_mode = true);

	/// Batch version: build N clusters in one call.
	/// Wraps ALL bodies in bulk mode before any shapes are added, commits at end.
	/// p_block_hp_array: Array of Dictionary (one per cluster)
	/// p_cluster_bodies / p_hit_bodies: Array of RID (one per cluster)
	/// p_hit_shape: shared BoxShape3D RID (same block size for all clusters)
	/// Returns Array of Dictionary (same format as build_cluster).
	Array build_clusters_batch(
			const Array &p_block_hp_array,
			int p_num_x, int p_num_y, int p_num_z,
			float p_block_size,
			const Array &p_cluster_bodies,
			const Array &p_hit_bodies,
			const RID &p_hit_shape,
			bool p_include_uvs = true);

	/// Find all connected components in a flat occupancy grid via 6-neighbor BFS.
	/// Returns Array of TypedArray<Vector3i> (one component per connected group).
	/// Uses direct array indexing — much faster than GDScript Dictionary-based BFS.
	Array find_connected_components(
			const PackedByteArray &p_block_grid,
			int p_num_x, int p_num_y, int p_num_z);

	/// Combined ground-BFS + component finding for structural integrity.
	/// Performs BFS from y=0 ground blocks to find all supported blocks.
	/// If unsupported blocks exist, groups them into connected components.
	/// Returns Array of TypedArray<Vector3i> (one component per disconnected group).
	/// Returns empty Array if all blocks are ground-connected (common case).
	/// Single C++ call replaces: calc_structural_integrity + triplet parsing + find_connected_components.
	Array calc_integrity_components(
			const PackedByteArray &p_block_grid,
			int p_num_x, int p_num_y, int p_num_z,
			int p_total_blocks);

	/// Force-equilibrium structural stress solver + connectivity check.
	/// Runs iterative Gauss-Seidel: each block distributes gravity through contacts
	/// (compression, tension, shear), bounded by material limits from p_max_load.
	/// p_ground_mask: same size as p_block_grid. 1 = block is terrain-supported
	///   (provides unlimited reaction force). If empty, falls back to y=0 as ground.
	/// p_external_load: same size as p_block_grid. Extra downward force per block
	///   in block-weights (e.g. player mass / block_mass on contact blocks).
	///   If empty, only self-weight (1.0 per block) is used.
	/// p_max_load: max compression per face in block-weights (tensile=30%, shear=40%).
	/// p_horizontal_transfer: lateral load distribution factor (0=vertical only, 1=full).
	Array calc_stress_integrity_components(
			const PackedByteArray &p_block_grid,
			const PackedByteArray &p_ground_mask,
			const PackedFloat32Array &p_external_load,
			int p_num_x, int p_num_y, int p_num_z,
			int p_total_blocks,
			float p_max_load,
			float p_horizontal_transfer);

	/// Localized variant of the stress solver. Reuses persistent state from a prior
	/// full solve and only re-propagates from blocks adjacent to recent destruction.
	/// Falls back to a full solve when persistent state is empty/stale OR when the
	/// active set exceeds half the grid (catastrophic event).
	///
	/// p_dirty_seed_indices: flat indices of blocks that were destroyed this tick
	///   (gone from p_block_grid). Used to seed the localized propagation.
	/// p_persistent_state: Dictionary containing
	///     "contact_compression": PackedFloat32Array(grid_size * 6)
	///     "contact_shear":       PackedFloat32Array(grid_size * 6)
	///     "visited":             PackedByteArray(grid_size)
	///     "last_block_count":    int — last total_blocks count, for staleness check
	///   Empty Dictionary triggers a full solve.
	///
	/// Returns Dictionary:
	///     "components":         Array of TypedArray<Vector3i> (same as full solver)
	///     "persistent_state":   Dictionary with updated contact/visited arrays + count
	///     "used_full_resolve":  bool — true if fell back to full solve
	///     "active_set_size":    int — peak active block count during propagation
	Dictionary calc_stress_integrity_localized(
			const PackedByteArray &p_block_grid,
			const PackedByteArray &p_ground_mask,
			const PackedFloat32Array &p_external_load,
			int p_num_x, int p_num_y, int p_num_z,
			int p_total_blocks,
			float p_max_load,
			float p_horizontal_transfer,
			const PackedInt32Array &p_dirty_seed_indices,
			const Dictionary &p_persistent_state);

	/// Terrain streaming: compute which chunks to load/unload.
	/// All math done natively — no GDScript Dictionary overhead.
	/// p_player_positions: world positions of all players.
	/// p_loaded_chunks: Vector3i array of currently loaded chunk positions.
	/// Returns Dictionary { "to_load": Array[Vector3i], "to_unload": Array[Vector3i] }
	Dictionary calc_streaming_update(
			const PackedVector3Array &p_player_positions,
			const Array &p_loaded_chunks,
			float p_view_distance,
			int p_chunk_size,
			int p_min_by, int p_max_by);

	/// Build collision triangle faces from a flat occupancy grid.
	/// For each occupied cell, emits triangles for exposed faces (neighbor check).
	/// Returns PackedVector3Array of triangle vertices (3 per tri, 2 tris per quad).
	/// Centroid is zero (grid-centered coordinates).
	PackedVector3Array build_collision_faces(
			const PackedByteArray &p_block_grid,
			int p_num_x, int p_num_y, int p_num_z,
			float p_block_size);

	/// Bulk-configure pre-popped debris pool nodes in one native call.
	/// p_nodes: Array of RigidBody3D (pre-popped from pool, sum of p_counts entries).
	/// p_block_positions: per-block world position.
	/// p_blast_centers: per-block direction target (debris flies toward this).
	/// p_counts: per-block debris count.
	/// p_speeds: per-block launch speed.
	/// p_mass: shared mass for all debris.
	/// p_material: shared material for all debris mesh children (child index 1).
	void bulk_configure_debris(
			const Array &p_nodes,
			const PackedVector3Array &p_block_positions,
			const PackedVector3Array &p_blast_centers,
			const PackedInt32Array &p_counts,
			const PackedFloat32Array &p_speeds,
			real_t p_mass,
			const Ref<Material> &p_material);

	/// Create debris as raw server RIDs (no Godot nodes). Returns Dictionary:
	///   "body_rids": Array of RID (PhysicsServer3D bodies)
	///   "instance_rids": Array of RID (RenderingServer visual instances)
	/// Caller is responsible for freeing RIDs when debris expires.
	Dictionary bulk_spawn_debris(
			const PackedVector3Array &p_block_positions,
			const PackedVector3Array &p_blast_centers,
			const PackedInt32Array &p_counts,
			const PackedFloat32Array &p_speeds,
			real_t p_mass,
			const Ref<Material> &p_material,
			const RID &p_shape,
			const RID &p_mesh,
			const RID &p_space,
			const RID &p_scenario,
			int p_collision_layer,
			int p_collision_mask);

	/// Force integration callback for debris bodies — angle-dependent friction.
	/// Registered automatically by bulk_spawn_debris on each created body.
	void debris_friction_callback(PhysicsDirectBodyState3D *p_state, const Variant &p_userdata);

	BlockMeshBuilder();
	~BlockMeshBuilder();
};

#endif // BLOCK_MESH_BUILDER_H
