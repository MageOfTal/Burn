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
	/// p_cluster_dims: optional per-cluster grid dims (3 ints per cluster:
	/// nx, ny, nz). Empty → all clusters use the shared num_x/y/z. Used by
	/// tight-AABB cluster rebasing so a 20-block chunk doesn't carry a
	/// full-structure-sized grid through every downstream kernel.
	Array build_clusters_batch(
			const Array &p_block_hp_array,
			int p_num_x, int p_num_y, int p_num_z,
			float p_block_size,
			const Array &p_cluster_bodies,
			const Array &p_hit_bodies,
			const RID &p_hit_shape,
			bool p_include_uvs = true,
			const PackedInt32Array &p_cluster_dims = PackedInt32Array());

	/// Returns a | b element-wise for two same-sized byte arrays. Used to
	/// merge async gravity-solve break results into live bond state without
	/// a per-element GDScript loop.
	PackedByteArray or_byte_arrays(
			const PackedByteArray &p_a,
			const PackedByteArray &p_b);

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

	/// Bond-graph connectivity check. BFS from ground anchors, traversing only
	/// bonds that are not broken. Returns disconnected components.
	///
	/// p_bond_broken: PackedByteArray of size grid_size * 3, where index
	///   `block_idx * 3 + axis` is 1 if the bond from this block to its
	///   +axis neighbor (axis 0=X, 1=Y, 2=Z) is broken. Bonds in -X/-Y/-Z
	///   are owned by the lower-indexed block in the same canonical scheme.
	///   Bonds at the structure boundary or where a neighbor is absent must
	///   be pre-marked broken (1).
	///
	/// Returns Array of TypedArray<Vector3i> — one per detached component.
	/// Empty array if everything is still connected.
	Array calc_bond_connectivity_components(
			const PackedByteArray &p_block_grid,
			const PackedByteArray &p_ground_mask,
			const PackedByteArray &p_bond_broken,
			int p_num_x, int p_num_y, int p_num_z,
			int p_total_blocks);

	/// Radial bond damage with DDA voxel-walk shielding.
	/// For every live bond inside the blast radius, casts a ray from the blast
	/// to the bond midpoint, walks the voxel grid via Amanatides-Woo DDA, and
	/// subtracts cumulative block-HP-along-path from the incoming bond energy.
	/// Same cubic falloff as the explosion's block-damage path.
	///
	/// p_hit_local: blast position in the structure's LOCAL coordinates.
	/// p_block_hp: per-block HP (uniform across the grid in bonds-only mode).
	/// p_bond_strength / p_bond_damage / p_bond_broken: same layout as the
	///   bond connectivity kernel — sized grid_size * 3.
	///
	/// Returns Dictionary {
	///   "bond_damage":  PackedFloat32Array (updated, replaces caller's),
	///   "bond_broken":  PackedByteArray   (updated, replaces caller's),
	///   "broken":       int — count of bonds newly broken this call,
	///   "damaged":      int — count of bonds that took non-zero damage,
	/// }
	Dictionary damage_bonds_radial_shielded(
			const PackedByteArray &p_block_grid,
			const PackedFloat32Array &p_bond_strength,
			const PackedFloat32Array &p_bond_damage_in,
			const PackedByteArray &p_bond_broken_in,
			int p_num_x, int p_num_y, int p_num_z,
			float p_block_size,
			const Vector3 &p_hit_local,
			float p_energy,
			float p_radius,
			float p_block_hp);

	/// Batch version: process N clusters in parallel via WorkerThreadPool.
	/// Identical math to damage_bonds_radial_shielded — same DDA shielded
	/// kernel, same falloff. Removes 790×GDScript→C++ binding overhead and
	/// scales near-linearly with cores.
	///
	/// p_clusters: Array of Dictionary, each with keys:
	///   "block_grid":     PackedByteArray
	///   "bond_strength":  PackedFloat32Array
	///   "bond_damage":    PackedFloat32Array  (input, copied)
	///   "bond_broken":    PackedByteArray     (input, copied)
	///   "num_x":          int
	///   "num_y":          int
	///   "num_z":          int
	///   "hit_local":      Vector3 (blast position in this cluster's local coords)
	///
	/// Returns Array of Dictionary, one per cluster, each with:
	///   "bond_damage":  PackedFloat32Array (updated)
	///   "bond_broken":  PackedByteArray   (updated)
	///   "broken":       int
	///   "damaged":      int
	///   "fragments":    Array of TypedArray<Vector3i> — fragment components
	///                   (excluding the largest, which stays in the source cluster).
	///                   Empty array when no bonds broke or cluster is still connected.
	///                   Lets the caller skip the serial GDScript→C++ BFS round-trip
	///                   per cluster — BFS runs on the same WorkerThreadPool job.
	Array damage_bonds_radial_shielded_batch(
			const Array &p_clusters,
			float p_block_size,
			float p_energy,
			float p_radius,
			float p_block_hp);

	/// Bulk-create N fragment bodies in one C++ call. Each body is a sleeping
	/// dynamic rigid body with one box shape attached, configured with the
	/// given collision layer/mask/mass/gravity_scale. Returns an Array of RIDs.
	///
	/// Replaces a per-body GDScript loop that made ~10 GDScript→C++ binding
	/// calls per body. For 2000 bodies, the GDScript path was ~60ms; the C++
	/// path is ~5ms — same per-body work, no per-call marshaling overhead.
	///
	/// p_kinematic: if true, bodies are KINEMATIC (clients use this — server
	///   sets transforms via sync RPC; client doesn't simulate physics).
	///   Otherwise RIGID (server runs full physics).
	Array bulk_create_fragment_bodies(
			int p_count,
			const RID &p_space,
			const RID &p_shape,
			int p_collision_layer,
			int p_collision_mask,
			float p_mass,
			float p_gravity_scale,
			bool p_kinematic);

	/// Greedy axis-aligned box decomposition of the block grid, applied
	/// directly to a PhysicsServer3D body's shape list. Frees old shape RIDs,
	/// rebuilds from scratch, returns new shape RIDs.
	///
	/// Replaces an equivalent triple-nested GDScript loop. Hot path during
	/// detach events — every structure that loses blocks rebuilds smooth
	/// collision once per detach, and the GDScript version was 8-11ms per
	/// 4000-block structure. C++ port is ~10x faster and skips per-shape
	/// PhysicsServer3D binding overhead.
	///
	/// p_body: RID of the StaticBody3D / RigidBody3D to attach shapes to.
	/// p_old_shape_rids: previous shape RIDs to free (typically the caller's
	///   _smooth_shape_rids cache from the prior call).
	/// Returns: Array of newly-created shape RIDs (caller should keep this
	///   reference; the next call will free them).
	Array rebuild_smooth_collision_box_shapes(
			const RID &p_body,
			const PackedByteArray &p_block_grid,
			int p_num_x, int p_num_y, int p_num_z,
			float p_block_size,
			const Array &p_old_shape_rids);

	/// Build the initial bond graph from a populated block_grid. Returns a
	/// Dictionary with three pre-sized arrays:
	///   "bond_strength": PackedFloat32Array(grid_size * 3) — full strength on
	///       every adjacent-occupied pair, zero elsewhere
	///   "bond_damage":   PackedFloat32Array(grid_size * 3) — all zeros
	///   "bond_broken":   PackedByteArray(grid_size * 3) — 1 wherever there's
	///       no live bond (block missing, neighbor missing, boundary)
	///   "live_count":    int — number of live bonds (for diagnostics)
	///
	/// Replaces a triple-nested GDScript loop that becomes very expensive
	/// when many clusters spawn simultaneously (post-explosion fragmentation).
	Dictionary compute_bond_graph(
			const PackedByteArray &p_block_grid,
			int p_num_x, int p_num_y, int p_num_z,
			float p_strength);

	/// Gravity stress solver — quasi-static elastic-brittle interface analysis.
	/// See GRAVITY_STRESS_PLAN.md for the full physics derivation.
	///
	/// Each block gets 6 DOF (small displacement + rotation); each intact bond
	/// and terrain anchor is a glued-face interface transmitting normal/shear
	/// force AND bending/torsion moment (rotational DOF are required — without
	/// them a 1-thick cantilever is a mechanism and bending, the dominant
	/// failure mode of overhangs, cannot exist). Solves K x = f_gravity via
	/// preconditioned conjugate gradient on blocks BFS-reachable from intact
	/// anchors, recovers per-interface forces/moments, and breaks interfaces
	/// whose combined edge stress exceeds capacity:
	///   U_tension     = (max(f_n,0) + 6·m_b) / (κ·T)
	///   U_compression = (max(−f_n,0) + 6·m_b) / (κ·C)
	///   U_shear       = (f_s + 3.556·m_t)     / (κ·S)
	/// κ = 1 − bond_damage/bond_strength couples the bond graph to the physics:
	/// damaged bonds are softer AND weaker. Breaking redistributes load, so the
	/// solve repeats (crack propagation) up to max_break_passes.
	///
	/// p_gravity_local: unit gravity direction in the structure's LOCAL frame.
	/// p_anchor_*: per-block terrain anchor arrays (sized grid_size); pass
	///   empty arrays to treat every ground_mask block as a pristine anchor.
	/// p_params keys (all optional): "tension" (50), "compression" (500),
	///   "shear" (37.5), "anchor_factor" (1.0), "max_cg_iters" (2000),
	///   "tolerance" (1e-6), "max_break_passes" (6), "check_symmetry" (false).
	///
	/// Returns Dictionary {
	///   "bond_broken":   PackedByteArray (updated copy),
	///   "anchor_broken": PackedByteArray (updated copy; created if input empty),
	///   "broke_bonds":   int, "broke_anchors": int,
	///   "max_utilization": float (worst U seen in the final pass),
	///   "passes": int, "cg_iters": int, "converged": bool,
	///   "symmetry_error": float (only when check_symmetry),
	/// }
	Dictionary solve_gravity_stress(
			const PackedByteArray &p_block_grid,
			const PackedByteArray &p_ground_mask,
			const PackedFloat32Array &p_bond_strength,
			const PackedFloat32Array &p_bond_damage,
			const PackedByteArray &p_bond_broken_in,
			const PackedFloat32Array &p_anchor_strength,
			const PackedFloat32Array &p_anchor_damage,
			const PackedByteArray &p_anchor_broken_in,
			int p_num_x, int p_num_y, int p_num_z,
			const Vector3 &p_gravity_local,
			const Dictionary &p_params);

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
