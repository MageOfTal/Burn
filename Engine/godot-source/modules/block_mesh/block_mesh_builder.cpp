#include "block_mesh_builder.h"

#include "core/object/worker_thread_pool.h"
#include "core/os/os.h"
#include "scene/3d/mesh_instance_3d.h"
#include "scene/3d/physics/rigid_body_3d.h"
#include "scene/3d/visual_instance_3d.h"
#include "scene/resources/3d/box_shape_3d.h"
#include "servers/physics_3d/physics_server_3d.h"
#include "servers/rendering/rendering_server.h"

// ── Parallel batch helpers ──

struct ClusterWorkItem {
	// Input (read-only, set before dispatch).
	const Dictionary *block_hp = nullptr;
	int num_x = 0, num_y = 0, num_z = 0;
	float block_size = 0.5f;
	bool include_uvs = true;

	// Output: grid + centroid.
	PackedByteArray block_grid;
	Vector3 centroid;
	int block_count = 0;
	Array shape_to_key; // Array of Vector3i

	// Output: hit body positions (centroid-relative).
	PackedVector3Array hit_positions;

	// Output: mesh arrays (not yet uploaded to GPU).
	PackedVector3Array verts, norms;
	PackedVector2Array uvs;
	PackedInt32Array indices;
	int vi = 0, ii = 0;

	// Output: column shape positions and sizes.
	PackedVector3Array col_positions;
	PackedVector3Array col_sizes;
};

struct ClusterBatchData {
	ClusterWorkItem *items = nullptr;
	int count = 0;
};

static void _compute_cluster_work(void *p_userdata, uint32_t p_index) {
	ClusterBatchData *batch = (ClusterBatchData *)p_userdata;
	ClusterWorkItem &w = batch->items[p_index];

	const int total = w.num_x * w.num_y * w.num_z;
	const int ny_nz = w.num_y * w.num_z;
	const real_t bs = w.block_size;
	const real_t hs = bs * 0.5f;
	const real_t half_x = w.num_x * 0.5f;
	const real_t half_y = w.num_y * 0.5f;
	const real_t half_z = w.num_z * 0.5f;

	// ── Grid + centroid + shape_to_key ──

	w.block_grid.resize(total);
	memset(w.block_grid.ptrw(), 0, total);
	uint8_t *grid_w = w.block_grid.ptrw();

	Vector3 centroid_sum;
	int block_count = 0;

	w.shape_to_key.resize(w.block_hp->size());

	const Variant *key = nullptr;
	while ((key = w.block_hp->next(key))) {
		const Vector3i k = *key;
		const int bx = k.x, by = k.y, bz = k.z;

		if (bx >= 0 && bx < w.num_x && by >= 0 && by < w.num_y && bz >= 0 && bz < w.num_z) {
			grid_w[bx * ny_nz + by * w.num_z + bz] = 1;
		}

		centroid_sum.x += (bx + 0.5f - half_x) * bs;
		centroid_sum.y += (by + 0.5f - half_y) * bs;
		centroid_sum.z += (bz + 0.5f - half_z) * bs;

		w.shape_to_key[block_count] = k;
		block_count++;
	}

	w.block_count = block_count;
	w.centroid = block_count > 0 ? centroid_sum / (real_t)block_count : Vector3();

	// ── Hit body positions ──

	w.hit_positions.resize(block_count);
	Vector3 *hit_w = w.hit_positions.ptrw();
	for (int i = 0; i < block_count; i++) {
		const Vector3i k = w.shape_to_key[i];
		hit_w[i] = Vector3(
				(k.x + 0.5f - half_x) * bs - w.centroid.x,
				(k.y + 0.5f - half_y) * bs - w.centroid.y,
				(k.z + 0.5f - half_z) * bs - w.centroid.z);
	}

	// Need read-only pointer for mesh + column passes.
	const uint8_t *grid = w.block_grid.ptr();

	// ── Mesh arrays ──

	const int max_verts = block_count * 24;
	const int max_idx = block_count * 36;

	w.verts.resize(max_verts);
	w.norms.resize(max_verts);
	if (w.include_uvs) {
		w.uvs.resize(max_verts);
	}
	w.indices.resize(max_idx);

	Vector3 *verts_w = w.verts.ptrw();
	Vector3 *norms_w = w.norms.ptrw();
	Vector2 *uvs_w = w.include_uvs ? w.uvs.ptrw() : nullptr;
	int32_t *idx_w = w.indices.ptrw();

	const Vector2 uv0(0, 0), uv1(1, 0), uv2(1, 1), uv3(0, 1);
	const Vector3 n_px(1, 0, 0), n_nx(-1, 0, 0);
	const Vector3 n_py(0, 1, 0), n_ny(0, -1, 0);
	const Vector3 n_pz(0, 0, 1), n_nz(0, 0, -1);

	int vi = 0, ii = 0;

	for (int bx = 0; bx < w.num_x; bx++) {
		const int bx_ny_nz = bx * ny_nz;
		for (int by = 0; by < w.num_y; by++) {
			const int bx_ny_nz_by_nz = bx_ny_nz + by * w.num_z;
			for (int bz = 0; bz < w.num_z; bz++) {
				if (!grid[bx_ny_nz_by_nz + bz]) {
					continue;
				}

				const real_t cx = (bx + 0.5f - half_x) * bs - w.centroid.x;
				const real_t cy = (by + 0.5f - half_y) * bs - w.centroid.y;
				const real_t cz = (bz + 0.5f - half_z) * bs - w.centroid.z;

				const bool has_px = (bx + 1 < w.num_x) && grid[(bx + 1) * ny_nz + by * w.num_z + bz];
				const bool has_nx = (bx - 1 >= 0) && grid[(bx - 1) * ny_nz + by * w.num_z + bz];
				const bool has_py = (by + 1 < w.num_y) && grid[bx_ny_nz + (by + 1) * w.num_z + bz];
				const bool has_ny = (by - 1 >= 0) && grid[bx_ny_nz + (by - 1) * w.num_z + bz];
				const bool has_pz = (bz + 1 < w.num_z) && grid[bx_ny_nz_by_nz + bz + 1];
				const bool has_nz = (bz - 1 >= 0) && grid[bx_ny_nz_by_nz + bz - 1];

#define EMIT_FACE(normal, v0, v1, v2, v3)                    \
	verts_w[vi] = v0; verts_w[vi+1] = v1;                    \
	verts_w[vi+2] = v2; verts_w[vi+3] = v3;                  \
	norms_w[vi] = normal; norms_w[vi+1] = normal;            \
	norms_w[vi+2] = normal; norms_w[vi+3] = normal;          \
	if (uvs_w) { uvs_w[vi]=uv0; uvs_w[vi+1]=uv1;            \
	             uvs_w[vi+2]=uv2; uvs_w[vi+3]=uv3; }         \
	idx_w[ii]=vi; idx_w[ii+1]=vi+1; idx_w[ii+2]=vi+2;        \
	idx_w[ii+3]=vi; idx_w[ii+4]=vi+2; idx_w[ii+5]=vi+3;      \
	vi += 4; ii += 6;

				if (!has_px) { real_t x=cx+hs; EMIT_FACE(n_px, Vector3(x,cy-hs,cz-hs), Vector3(x,cy-hs,cz+hs), Vector3(x,cy+hs,cz+hs), Vector3(x,cy+hs,cz-hs)); }
				if (!has_nx) { real_t x=cx-hs; EMIT_FACE(n_nx, Vector3(x,cy-hs,cz+hs), Vector3(x,cy-hs,cz-hs), Vector3(x,cy+hs,cz-hs), Vector3(x,cy+hs,cz+hs)); }
				if (!has_py) { real_t y=cy+hs; EMIT_FACE(n_py, Vector3(cx-hs,y,cz-hs), Vector3(cx+hs,y,cz-hs), Vector3(cx+hs,y,cz+hs), Vector3(cx-hs,y,cz+hs)); }
				if (!has_ny) { real_t y=cy-hs; EMIT_FACE(n_ny, Vector3(cx-hs,y,cz+hs), Vector3(cx+hs,y,cz+hs), Vector3(cx+hs,y,cz-hs), Vector3(cx-hs,y,cz-hs)); }
				if (!has_pz) { real_t z=cz+hs; EMIT_FACE(n_pz, Vector3(cx+hs,cy-hs,z), Vector3(cx-hs,cy-hs,z), Vector3(cx-hs,cy+hs,z), Vector3(cx+hs,cy+hs,z)); }
				if (!has_nz) { real_t z=cz-hs; EMIT_FACE(n_nz, Vector3(cx-hs,cy-hs,z), Vector3(cx+hs,cy-hs,z), Vector3(cx+hs,cy+hs,z), Vector3(cx-hs,cy+hs,z)); }

#undef EMIT_FACE
			}
		}
	}

	w.vi = vi;
	w.ii = ii;

	// ── Column shapes ──

	LocalVector<Vector3> col_pos_list;
	LocalVector<Vector3> col_size_list;

	for (int bx = 0; bx < w.num_x; bx++) {
		const int bx_offset = bx * ny_nz;
		for (int bz = 0; bz < w.num_z; bz++) {
			int run_start = -1;

			for (int by = 0; by <= w.num_y; by++) {
				const bool occupied = (by < w.num_y) && grid[bx_offset + by * w.num_z + bz] != 0;

				if (occupied && run_start < 0) {
					run_start = by;
				} else if (!occupied && run_start >= 0) {
					const int run_end = by - 1;
					const int run_count = run_end - run_start + 1;
					col_size_list.push_back(Vector3(bs, run_count * bs, bs));
					col_pos_list.push_back(Vector3(
							(bx + 0.5f - half_x) * bs - w.centroid.x,
							((run_start + run_end) * 0.5f + 0.5f - half_y) * bs - w.centroid.y,
							(bz + 0.5f - half_z) * bs - w.centroid.z));
					run_start = -1;
				}
			}
		}
	}

	// Copy to packed arrays.
	w.col_positions.resize(col_pos_list.size());
	w.col_sizes.resize(col_size_list.size());
	if (!col_pos_list.is_empty()) {
		memcpy(w.col_positions.ptrw(), col_pos_list.ptr(), col_pos_list.size() * sizeof(Vector3));
		memcpy(w.col_sizes.ptrw(), col_size_list.ptr(), col_size_list.size() * sizeof(Vector3));
	}
}

BlockMeshBuilder *BlockMeshBuilder::singleton = nullptr;
bool BlockMeshBuilder::s_stress_debug_print = false;

BlockMeshBuilder::BlockMeshBuilder() {
	singleton = this;
}

BlockMeshBuilder::~BlockMeshBuilder() {
	if (singleton == this) {
		singleton = nullptr;
	}
}

void BlockMeshBuilder::_bind_methods() {
	ClassDB::bind_method(
			D_METHOD("build_block_mesh", "block_grid", "num_x", "num_y", "num_z", "block_size", "centroid", "include_uvs"),
			&BlockMeshBuilder::build_block_mesh,
			DEFVAL(true));
	ClassDB::bind_method(
			D_METHOD("init_block_grid", "block_hp", "num_x", "num_y", "num_z", "block_size"),
			&BlockMeshBuilder::init_block_grid);
	ClassDB::bind_method(
			D_METHOD("compute_column_shapes", "block_grid", "num_x", "num_y", "num_z", "block_size", "centroid"),
			&BlockMeshBuilder::compute_column_shapes);
	ClassDB::bind_method(
			D_METHOD("bulk_add_shapes", "body", "shape", "positions"),
			&BlockMeshBuilder::bulk_add_shapes);
	ClassDB::bind_method(
			D_METHOD("bulk_add_box_shapes", "body", "positions", "sizes"),
			&BlockMeshBuilder::bulk_add_box_shapes);
	ClassDB::bind_method(
			D_METHOD("find_connected_components", "block_grid", "num_x", "num_y", "num_z"),
			&BlockMeshBuilder::find_connected_components);
	ClassDB::bind_method(
			D_METHOD("calc_integrity_components", "block_grid", "num_x", "num_y", "num_z", "total_blocks"),
			&BlockMeshBuilder::calc_integrity_components);
	ClassDB::bind_method(
			D_METHOD("calc_bond_connectivity_components", "block_grid", "ground_mask",
					"bond_broken", "num_x", "num_y", "num_z", "total_blocks"),
			&BlockMeshBuilder::calc_bond_connectivity_components);
	ClassDB::bind_method(
			D_METHOD("damage_bonds_radial_shielded", "block_grid", "bond_strength",
					"bond_damage", "bond_broken", "num_x", "num_y", "num_z",
					"block_size", "hit_local", "energy", "radius", "block_hp"),
			&BlockMeshBuilder::damage_bonds_radial_shielded);
	ClassDB::bind_method(
			D_METHOD("damage_bonds_radial_shielded_batch", "clusters",
					"block_size", "energy", "radius", "block_hp"),
			&BlockMeshBuilder::damage_bonds_radial_shielded_batch);
	ClassDB::bind_method(
			D_METHOD("compute_bond_graph", "block_grid", "num_x", "num_y", "num_z", "strength"),
			&BlockMeshBuilder::compute_bond_graph);
	ClassDB::bind_method(
			D_METHOD("solve_gravity_stress", "block_grid", "ground_mask",
					"bond_strength", "bond_damage", "bond_broken",
					"anchor_strength", "anchor_damage", "anchor_broken",
					"num_x", "num_y", "num_z", "gravity_local", "params"),
			&BlockMeshBuilder::solve_gravity_stress);
	ClassDB::bind_method(
			D_METHOD("rebuild_smooth_collision_box_shapes", "body", "block_grid",
					"num_x", "num_y", "num_z", "block_size", "old_shape_rids"),
			&BlockMeshBuilder::rebuild_smooth_collision_box_shapes);
	ClassDB::bind_method(
			D_METHOD("bulk_create_fragment_bodies", "count", "space", "shape",
					"collision_layer", "collision_mask", "mass",
					"gravity_scale", "kinematic"),
			&BlockMeshBuilder::bulk_create_fragment_bodies);
	ClassDB::bind_method(
			D_METHOD("calc_stress_integrity_components", "block_grid", "ground_mask",
					"external_load", "num_x", "num_y", "num_z",
					"total_blocks", "max_load", "horizontal_transfer"),
			&BlockMeshBuilder::calc_stress_integrity_components);
	ClassDB::bind_method(
			D_METHOD("calc_stress_integrity_localized", "block_grid", "ground_mask",
					"external_load", "num_x", "num_y", "num_z",
					"total_blocks", "max_load", "horizontal_transfer",
					"dirty_seed_indices", "persistent_state"),
			&BlockMeshBuilder::calc_stress_integrity_localized);
	ClassDB::bind_method(
			D_METHOD("set_stress_debug_print", "enabled"),
			&BlockMeshBuilder::set_stress_debug_print);
	ClassDB::bind_method(
			D_METHOD("get_stress_debug_print"),
			&BlockMeshBuilder::get_stress_debug_print);
	ClassDB::bind_method(
			D_METHOD("calc_streaming_update", "player_positions", "loaded_chunks",
					"view_distance", "chunk_size", "min_by", "max_by"),
			&BlockMeshBuilder::calc_streaming_update);
	ClassDB::bind_method(
			D_METHOD("build_cluster", "block_hp", "num_x", "num_y", "num_z", "block_size", "cluster_body", "hit_body", "hit_shape", "include_uvs"),
			&BlockMeshBuilder::build_cluster,
			DEFVAL(true), DEFVAL(true));
	ClassDB::bind_method(
			D_METHOD("build_clusters_batch", "block_hp_array", "num_x", "num_y", "num_z", "block_size", "cluster_bodies", "hit_bodies", "hit_shape", "include_uvs", "cluster_dims"),
			&BlockMeshBuilder::build_clusters_batch,
			DEFVAL(true), DEFVAL(PackedInt32Array()));
	ClassDB::bind_method(
			D_METHOD("or_byte_arrays", "a", "b"),
			&BlockMeshBuilder::or_byte_arrays);
	ClassDB::bind_method(
			D_METHOD("bulk_configure_debris", "nodes", "block_positions", "blast_centers", "counts", "speeds", "mass", "material"),
			&BlockMeshBuilder::bulk_configure_debris);
	ClassDB::bind_method(
			D_METHOD("build_collision_faces", "block_grid", "num_x", "num_y", "num_z", "block_size"),
			&BlockMeshBuilder::build_collision_faces);
	ClassDB::bind_method(
			D_METHOD("bulk_spawn_debris", "block_positions", "blast_centers", "counts", "speeds",
					"mass", "material", "shape", "mesh", "space", "scenario",
					"collision_layer", "collision_mask"),
			&BlockMeshBuilder::bulk_spawn_debris);
	ClassDB::bind_method(
			D_METHOD("debris_friction_callback", "state", "userdata"),
			&BlockMeshBuilder::debris_friction_callback);
}

// Helper: check if grid cell is occupied (out-of-bounds = empty).
static _FORCE_INLINE_ bool _grid_occupied(const uint8_t *grid, int x, int y, int z, int nx, int ny, int nz) {
	if (x < 0 || x >= nx || y < 0 || y >= ny || z < 0 || z >= nz) return false;
	return grid[x * ny * nz + y * nz + z] != 0;
}

// Helper: emit a quad (4 verts, 6 indices) into the output arrays.
static _FORCE_INLINE_ void _emit_quad(
		Vector3 *verts_w, Vector3 *norms_w, Vector2 *uvs_w, int32_t *idx_w,
		int &vi, int &ii,
		const Vector3 &p0, const Vector3 &p1, const Vector3 &p2, const Vector3 &p3,
		const Vector3 &normal, real_t u_scale, real_t v_scale) {
	verts_w[vi] = p0;
	verts_w[vi + 1] = p1;
	verts_w[vi + 2] = p2;
	verts_w[vi + 3] = p3;
	norms_w[vi] = normal;
	norms_w[vi + 1] = normal;
	norms_w[vi + 2] = normal;
	norms_w[vi + 3] = normal;
	if (uvs_w) {
		uvs_w[vi] = Vector2(0, 0);
		uvs_w[vi + 1] = Vector2(u_scale, 0);
		uvs_w[vi + 2] = Vector2(u_scale, v_scale);
		uvs_w[vi + 3] = Vector2(0, v_scale);
	}
	idx_w[ii] = vi;
	idx_w[ii + 1] = vi + 1;
	idx_w[ii + 2] = vi + 2;
	idx_w[ii + 3] = vi;
	idx_w[ii + 4] = vi + 2;
	idx_w[ii + 5] = vi + 3;
	vi += 4;
	ii += 6;
}

Ref<ArrayMesh> BlockMeshBuilder::build_block_mesh(
		const PackedByteArray &p_block_grid,
		int p_num_x, int p_num_y, int p_num_z,
		float p_block_size,
		const Vector3 &p_centroid,
		bool p_include_uvs) {
	const int total = p_num_x * p_num_y * p_num_z;
	ERR_FAIL_COND_V_MSG(p_block_grid.size() != total, Ref<ArrayMesh>(),
			vformat("block_grid size %d != expected %d", p_block_grid.size(), total));
	ERR_FAIL_COND_V_MSG(p_num_x <= 0 || p_num_y <= 0 || p_num_z <= 0, Ref<ArrayMesh>(),
			"Grid dimensions must be positive.");

	const uint8_t *grid = p_block_grid.ptr();
	const int nx = p_num_x, ny = p_num_y, nz = p_num_z;

	int block_count = 0;
	for (int i = 0; i < total; i++) {
		if (grid[i]) block_count++;
	}
	if (block_count == 0) return Ref<ArrayMesh>();

	// Greedy meshing produces far fewer quads than per-block, but we still
	// allocate for worst case (per-block) and trim at the end.
	const int max_verts = block_count * 24;
	const int max_idx = block_count * 36;

	PackedVector3Array verts; verts.resize(max_verts);
	PackedVector3Array norms; norms.resize(max_verts);
	PackedVector2Array uvs;
	if (p_include_uvs) uvs.resize(max_verts);
	PackedInt32Array indices; indices.resize(max_idx);

	Vector3 *verts_w = verts.ptrw();
	Vector3 *norms_w = norms.ptrw();
	Vector2 *uvs_w = p_include_uvs ? uvs.ptrw() : nullptr;
	int32_t *idx_w = indices.ptrw();

	const real_t bs = p_block_size;
	const real_t hx = nx * bs * 0.5f + p_centroid.x;
	const real_t hy = ny * bs * 0.5f + p_centroid.y;
	const real_t hz = nz * bs * 0.5f + p_centroid.z;

	int vi = 0, ii = 0;

	// Greedy meshing: for each face direction, iterate slices perpendicular
	// to the normal. For each slice, build a 2D mask of exposed faces, then
	// sweep to find maximal rectangles. Each rectangle = one merged quad.
	//
	// Face directions are processed as (axis, sign):
	//   +X: slice along X, face mask in (Y, Z)
	//   -X: slice along X, face mask in (Y, Z)
	//   +Y: slice along Y, face mask in (X, Z)
	//   -Y: slice along Y, face mask in (X, Z)
	//   +Z: slice along Z, face mask in (X, Y)
	//   -Z: slice along Z, face mask in (X, Y)

	// Maximum slice dimensions
	const int max_dim = MAX(MAX(nx, ny), nz);
	const int max_slice = max_dim * max_dim;
	LocalVector<bool> mask;
	mask.resize(max_slice);

	// Process each of the 6 face directions
	for (int face = 0; face < 6; face++) {
		// Determine axis and dimensions for this face
		// axis: 0=X, 1=Y, 2=Z. sign: 0=positive, 1=negative.
		const int axis = face / 2;
		const int sign = face % 2; // 0 = positive normal, 1 = negative normal

		int slice_count, dim_u, dim_v;
		if (axis == 0) { slice_count = nx; dim_u = ny; dim_v = nz; }
		else if (axis == 1) { slice_count = ny; dim_u = nx; dim_v = nz; }
		else { slice_count = nz; dim_u = nx; dim_v = ny; }

		Vector3 normal;
		if (axis == 0) normal = sign ? Vector3(-1,0,0) : Vector3(1,0,0);
		else if (axis == 1) normal = sign ? Vector3(0,-1,0) : Vector3(0,1,0);
		else normal = sign ? Vector3(0,0,-1) : Vector3(0,0,1);

		for (int slice = 0; slice < slice_count; slice++) {
			// Build the 2D mask: which cells in this slice have an exposed face?
			for (int u = 0; u < dim_u; u++) {
				for (int v = 0; v < dim_v; v++) {
					int bx, by, bz, nbx, nby, nbz;
					if (axis == 0) { bx = slice; by = u; bz = v; nbx = slice + (sign ? -1 : 1); nby = u; nbz = v; }
					else if (axis == 1) { bx = u; by = slice; bz = v; nbx = u; nby = slice + (sign ? -1 : 1); nbz = v; }
					else { bx = u; by = v; bz = slice; nbx = u; nby = v; nbz = slice + (sign ? -1 : 1); }

					bool occupied = _grid_occupied(grid, bx, by, bz, nx, ny, nz);
					bool neighbor = _grid_occupied(grid, nbx, nby, nbz, nx, ny, nz);
					mask[u * dim_v + v] = occupied && !neighbor;
				}
			}

			// Greedy sweep: find maximal rectangles in the mask
			for (int u = 0; u < dim_u; u++) {
				for (int v = 0; v < dim_v; ) {
					if (!mask[u * dim_v + v]) { v++; continue; }

					// Determine width (along v)
					int w = 1;
					while (v + w < dim_v && mask[u * dim_v + v + w]) w++;

					// Determine height (along u) — all rows must have the same width
					int h = 1;
					bool done = false;
					while (u + h < dim_u && !done) {
						for (int k = 0; k < w; k++) {
							if (!mask[(u + h) * dim_v + v + k]) { done = true; break; }
						}
						if (!done) h++;
					}

					// Clear the mask for this rectangle
					for (int du = 0; du < h; du++) {
						for (int dv = 0; dv < w; dv++) {
							mask[(u + du) * dim_v + v + dv] = false;
						}
					}

					// Emit the merged quad
					// Convert (slice, u, v) + (w, h) back to world coordinates
					real_t s0, s1, u0, u1, v0, v1;
					if (axis == 0) {
						// Face normal along X. u=Y, v=Z.
						s0 = (sign ? slice : slice + 1) * bs - hx;
						u0 = u * bs - hy; u1 = (u + h) * bs - hy;
						v0 = v * bs - hz; v1 = (v + w) * bs - hz;
						if (sign) { // -X
							_emit_quad(verts_w, norms_w, uvs_w, idx_w, vi, ii,
								Vector3(s0, u0, v1), Vector3(s0, u0, v0),
								Vector3(s0, u1, v0), Vector3(s0, u1, v1),
								normal, (real_t)w, (real_t)h);
						} else { // +X
							_emit_quad(verts_w, norms_w, uvs_w, idx_w, vi, ii,
								Vector3(s0, u0, v0), Vector3(s0, u0, v1),
								Vector3(s0, u1, v1), Vector3(s0, u1, v0),
								normal, (real_t)w, (real_t)h);
						}
					} else if (axis == 1) {
						// Face normal along Y. u=X, v=Z.
						s0 = (sign ? slice : slice + 1) * bs - hy;
						u0 = u * bs - hx; u1 = (u + h) * bs - hx;
						v0 = v * bs - hz; v1 = (v + w) * bs - hz;
						if (sign) { // -Y
							_emit_quad(verts_w, norms_w, uvs_w, idx_w, vi, ii,
								Vector3(u0, s0, v1), Vector3(u1, s0, v1),
								Vector3(u1, s0, v0), Vector3(u0, s0, v0),
								normal, (real_t)h, (real_t)w);
						} else { // +Y
							_emit_quad(verts_w, norms_w, uvs_w, idx_w, vi, ii,
								Vector3(u0, s0, v0), Vector3(u1, s0, v0),
								Vector3(u1, s0, v1), Vector3(u0, s0, v1),
								normal, (real_t)h, (real_t)w);
						}
					} else {
						// Face normal along Z. u=X, v=Y.
						s0 = (sign ? slice : slice + 1) * bs - hz;
						u0 = u * bs - hx; u1 = (u + h) * bs - hx;
						v0 = v * bs - hy; v1 = (v + w) * bs - hy;
						if (sign) { // -Z
							_emit_quad(verts_w, norms_w, uvs_w, idx_w, vi, ii,
								Vector3(u0, v0, s0), Vector3(u1, v0, s0),
								Vector3(u1, v1, s0), Vector3(u0, v1, s0),
								normal, (real_t)h, (real_t)w);
						} else { // +Z
							_emit_quad(verts_w, norms_w, uvs_w, idx_w, vi, ii,
								Vector3(u1, v0, s0), Vector3(u0, v0, s0),
								Vector3(u0, v1, s0), Vector3(u1, v1, s0),
								normal, (real_t)h, (real_t)w);
						}
					}

					v += w; // Skip past the merged region
				}
			}
		}
	}

	// Trim to actual size.
	verts.resize(vi);
	norms.resize(vi);
	if (p_include_uvs) uvs.resize(vi);
	indices.resize(ii);

	Array arrays;
	arrays.resize(Mesh::ARRAY_MAX);
	arrays[Mesh::ARRAY_VERTEX] = verts;
	arrays[Mesh::ARRAY_NORMAL] = norms;
	if (p_include_uvs) arrays[Mesh::ARRAY_TEX_UV] = uvs;
	arrays[Mesh::ARRAY_INDEX] = indices;

	Ref<ArrayMesh> mesh;
	mesh.instantiate();
	if (vi > 0) {
		mesh->add_surface_from_arrays(Mesh::PRIMITIVE_TRIANGLES, arrays);
	}
	return mesh;
}

Dictionary BlockMeshBuilder::init_block_grid(
		const Dictionary &p_block_hp,
		int p_num_x, int p_num_y, int p_num_z,
		float p_block_size) {
	ERR_FAIL_COND_V_MSG(p_num_x <= 0 || p_num_y <= 0 || p_num_z <= 0, Dictionary(),
			"Grid dimensions must be positive.");

	const int total = p_num_x * p_num_y * p_num_z;
	const int ny_nz = p_num_y * p_num_z;

	// Build flat occupancy grid from dictionary keys.
	PackedByteArray block_grid;
	block_grid.resize(total);
	memset(block_grid.ptrw(), 0, total);

	uint8_t *grid_w = block_grid.ptrw();

	// Compute centroid while iterating.
	const real_t bs = p_block_size;
	const real_t half_x = p_num_x * 0.5f;
	const real_t half_y = p_num_y * 0.5f;
	const real_t half_z = p_num_z * 0.5f;

	Vector3 centroid_sum = Vector3();
	int count = 0;

	const Variant *key = nullptr;
	while ((key = p_block_hp.next(key))) {
		const Vector3i k = *key;
		const int bx = k.x;
		const int by = k.y;
		const int bz = k.z;

		if (bx >= 0 && bx < p_num_x && by >= 0 && by < p_num_y && bz >= 0 && bz < p_num_z) {
			grid_w[bx * ny_nz + by * p_num_z + bz] = 1;
		}

		// Accumulate centroid (block_local_pos_raw formula).
		centroid_sum.x += (bx + 0.5f - half_x) * bs;
		centroid_sum.y += (by + 0.5f - half_y) * bs;
		centroid_sum.z += (bz + 0.5f - half_z) * bs;
		count++;
	}

	Vector3 centroid = Vector3();
	if (count > 0) {
		centroid = centroid_sum / (real_t)count;
	}

	Dictionary result;
	result["block_grid"] = block_grid;
	result["centroid"] = centroid;
	return result;
}

TypedArray<Dictionary> BlockMeshBuilder::compute_column_shapes(
		const PackedByteArray &p_block_grid,
		int p_num_x, int p_num_y, int p_num_z,
		float p_block_size,
		const Vector3 &p_centroid) {
	TypedArray<Dictionary> result;

	const int total = p_num_x * p_num_y * p_num_z;
	ERR_FAIL_COND_V_MSG(p_block_grid.size() != total, result,
			vformat("block_grid size %d != expected %d", p_block_grid.size(), total));
	ERR_FAIL_COND_V_MSG(p_num_x <= 0 || p_num_y <= 0 || p_num_z <= 0, result,
			"Grid dimensions must be positive.");

	const uint8_t *grid = p_block_grid.ptr();
	const real_t bs = p_block_size;
	const real_t half_x = p_num_x * 0.5f;
	const real_t half_y = p_num_y * 0.5f;
	const real_t half_z = p_num_z * 0.5f;
	const int ny_nz = p_num_y * p_num_z;

	// Iterate each (x, z) column, find contiguous Y runs.
	for (int bx = 0; bx < p_num_x; bx++) {
		const int bx_offset = bx * ny_nz;
		for (int bz = 0; bz < p_num_z; bz++) {
			int run_start = -1;

			for (int by = 0; by < p_num_y; by++) {
				const bool occupied = grid[bx_offset + by * p_num_z + bz] != 0;

				if (occupied) {
					if (run_start < 0) {
						run_start = by;
					}
				} else {
					if (run_start >= 0) {
						// Emit shape for run [run_start, by-1].
						const int run_end = by - 1;
						const int run_count = run_end - run_start + 1;
						const Vector3 size(bs, run_count * bs, bs);
						const Vector3 pos(
								(bx + 0.5f - half_x) * bs - p_centroid.x,
								((run_start + run_end) * 0.5f + 0.5f - half_y) * bs - p_centroid.y,
								(bz + 0.5f - half_z) * bs - p_centroid.z);
						Dictionary shape;
						shape["position"] = pos;
						shape["size"] = size;
						result.push_back(shape);
						run_start = -1;
					}
				}
			}

			// Flush final run in this column.
			if (run_start >= 0) {
				const int run_end = p_num_y - 1;
				const int run_count = run_end - run_start + 1;
				const Vector3 size(bs, run_count * bs, bs);
				const Vector3 pos(
						(bx + 0.5f - half_x) * bs - p_centroid.x,
						((run_start + run_end) * 0.5f + 0.5f - half_y) * bs - p_centroid.y,
						(bz + 0.5f - half_z) * bs - p_centroid.z);
				Dictionary shape;
				shape["position"] = pos;
				shape["size"] = size;
				result.push_back(shape);
			}
		}
	}

	return result;
}

void BlockMeshBuilder::bulk_add_shapes(
		const RID &p_body,
		const RID &p_shape,
		const PackedVector3Array &p_positions) {
	PhysicsServer3D *ps = PhysicsServer3D::get_singleton();
	ERR_FAIL_NULL(ps);

	const int count = p_positions.size();
	const Vector3 *positions = p_positions.ptr();

	ps->body_set_shapes_bulk_mode(p_body, true);
	for (int i = 0; i < count; i++) {
		ps->body_add_shape(p_body, p_shape, Transform3D(Basis(), positions[i]));
	}
	ps->body_set_shapes_bulk_mode(p_body, false);
}

Array BlockMeshBuilder::bulk_add_box_shapes(
		const RID &p_body,
		const PackedVector3Array &p_positions,
		const PackedVector3Array &p_sizes) {
	ERR_FAIL_COND_V_MSG(p_positions.size() != p_sizes.size(), Array(),
			vformat("positions size %d != sizes size %d", p_positions.size(), p_sizes.size()));

	PhysicsServer3D *ps = PhysicsServer3D::get_singleton();
	ERR_FAIL_NULL_V(ps, Array());

	const int count = p_positions.size();
	const Vector3 *positions = p_positions.ptr();
	const Vector3 *sizes = p_sizes.ptr();

	Array shape_refs;
	shape_refs.resize(count);

	ps->body_set_shapes_bulk_mode(p_body, true);
	for (int i = 0; i < count; i++) {
		Ref<BoxShape3D> box;
		box.instantiate();
		box->set_size(sizes[i]);
		ps->body_add_shape(p_body, box->get_rid(), Transform3D(Basis(), positions[i]));
		shape_refs[i] = box;
	}
	ps->body_set_shapes_bulk_mode(p_body, false);

	return shape_refs;
}

Array BlockMeshBuilder::find_connected_components(
		const PackedByteArray &p_block_grid,
		int p_num_x, int p_num_y, int p_num_z) {
	const int total = p_num_x * p_num_y * p_num_z;
	ERR_FAIL_COND_V_MSG(p_block_grid.size() != total, Array(),
			vformat("block_grid size %d != expected %d (num_x=%d * num_y=%d * num_z=%d)",
					p_block_grid.size(), total, p_num_x, p_num_y, p_num_z));
	ERR_FAIL_COND_V_MSG(p_num_x <= 0 || p_num_y <= 0 || p_num_z <= 0, Array(),
			"Grid dimensions must be positive.");

	const uint8_t *grid = p_block_grid.ptr();
	const int ny_nz = p_num_y * p_num_z;

	// Pre-compute neighbor offsets in flat index space.
	const int offsets[6] = { ny_nz, -ny_nz, p_num_z, -p_num_z, 1, -1 };

	// Visited array — raw uint8_t for cache-friendly access.
	LocalVector<uint8_t> visited;
	visited.resize(total);
	memset(visited.ptr(), 0, total);

	// BFS queue — flat indices. Worst case: all cells in one component.
	LocalVector<int> queue;
	queue.resize(total);

	Array components;

	for (int i = 0; i < total; i++) {
		if (!grid[i] || visited[i]) {
			continue;
		}

		// Start a new component from this unvisited occupied cell.
		int head = 0;
		int tail = 0;
		queue[tail++] = i;
		visited[i] = 1;

		while (head < tail) {
			const int ci = queue[head++];

			// Decompose flat index to (bx, by, bz) for bounds checking.
			const int bx = ci / ny_nz;
			const int rem = ci % ny_nz;
			const int by = rem / p_num_z;
			const int bz = rem % p_num_z;

			// +X
			if (bx + 1 < p_num_x) {
				const int ni = ci + offsets[0];
				if (grid[ni] && !visited[ni]) {
					visited[ni] = 1;
					queue[tail++] = ni;
				}
			}
			// -X
			if (bx > 0) {
				const int ni = ci + offsets[1];
				if (grid[ni] && !visited[ni]) {
					visited[ni] = 1;
					queue[tail++] = ni;
				}
			}
			// +Y
			if (by + 1 < p_num_y) {
				const int ni = ci + offsets[2];
				if (grid[ni] && !visited[ni]) {
					visited[ni] = 1;
					queue[tail++] = ni;
				}
			}
			// -Y
			if (by > 0) {
				const int ni = ci + offsets[3];
				if (grid[ni] && !visited[ni]) {
					visited[ni] = 1;
					queue[tail++] = ni;
				}
			}
			// +Z
			if (bz + 1 < p_num_z) {
				const int ni = ci + offsets[4];
				if (grid[ni] && !visited[ni]) {
					visited[ni] = 1;
					queue[tail++] = ni;
				}
			}
			// -Z
			if (bz > 0) {
				const int ni = ci + offsets[5];
				if (grid[ni] && !visited[ni]) {
					visited[ni] = 1;
					queue[tail++] = ni;
				}
			}
		}

		// Convert flat indices in queue[0..tail) to Vector3i component.
		TypedArray<Vector3i> component;
		component.resize(tail);
		for (int j = 0; j < tail; j++) {
			const int cj = queue[j];
			const int cbx = cj / ny_nz;
			const int crem = cj % ny_nz;
			const int cby = crem / p_num_z;
			const int cbz = crem % p_num_z;
			component[j] = Vector3i(cbx, cby, cbz);
		}
		components.push_back(component);
	}

	return components;
}

Array BlockMeshBuilder::calc_integrity_components(
		const PackedByteArray &p_block_grid,
		int p_num_x, int p_num_y, int p_num_z,
		int p_total_blocks) {
	const int grid_size = p_num_x * p_num_y * p_num_z;
	ERR_FAIL_COND_V_MSG(p_block_grid.size() != grid_size, Array(),
			vformat("calc_integrity_components: block_grid size %d != expected %d (%dx%dx%d)",
					p_block_grid.size(), grid_size, p_num_x, p_num_y, p_num_z));
	ERR_FAIL_COND_V_MSG(p_num_x <= 0 || p_num_y <= 0 || p_num_z <= 0, Array(),
			"Grid dimensions must be positive.");
	ERR_FAIL_COND_V(p_total_blocks <= 0, Array());

	uint64_t t_start = OS::get_singleton()->get_ticks_usec();

	const uint8_t *grid = p_block_grid.ptr();
	const int nx = p_num_x;
	const int ny = p_num_y;
	const int nz = p_num_z;
	const int ny_nz = ny * nz;

	// Flat neighbor offsets: +X, -X, +Y, -Y, +Z, -Z.
	const int offsets[6] = { ny_nz, -ny_nz, nz, -nz, 1, -1 };

	// Visited: 0=unvisited, 1=ground-connected, 2=component-assigned.
	uint8_t *visited = (uint8_t *)memalloc(grid_size);
	memset(visited, 0, grid_size);

	// BFS queue — shared between ground BFS and component BFS.
	int *bfs_queue = (int *)memalloc(p_total_blocks * sizeof(int));
	int head = 0;
	int tail = 0;

	// ── Phase 1: Ground BFS from y=0 ──
	for (int bx = 0; bx < nx; bx++) {
		int base = bx * ny_nz;
		for (int bz = 0; bz < nz; bz++) {
			int idx = base + bz; // y=0
			if (grid[idx] == 1) {
				visited[idx] = 1;
				bfs_queue[tail++] = idx;
			}
		}
	}

	int visited_count = tail;

	while (head < tail) {
		if (visited_count == p_total_blocks) {
			break;
		}

		const int ci = bfs_queue[head++];
		const int bx = ci / ny_nz;
		const int rem = ci % ny_nz;
		const int by = rem / nz;
		const int bz = rem % nz;

		// +X
		if (bx + 1 < nx) {
			const int ni = ci + offsets[0];
			if (grid[ni] == 1 && visited[ni] == 0) {
				visited[ni] = 1;
				bfs_queue[tail++] = ni;
				visited_count++;
			}
		}
		// -X
		if (bx > 0) {
			const int ni = ci + offsets[1];
			if (grid[ni] == 1 && visited[ni] == 0) {
				visited[ni] = 1;
				bfs_queue[tail++] = ni;
				visited_count++;
			}
		}
		// +Y
		if (by + 1 < ny) {
			const int ni = ci + offsets[2];
			if (grid[ni] == 1 && visited[ni] == 0) {
				visited[ni] = 1;
				bfs_queue[tail++] = ni;
				visited_count++;
			}
		}
		// -Y
		if (by > 0) {
			const int ni = ci + offsets[3];
			if (grid[ni] == 1 && visited[ni] == 0) {
				visited[ni] = 1;
				bfs_queue[tail++] = ni;
				visited_count++;
			}
		}
		// +Z
		if (bz + 1 < nz) {
			const int ni = ci + offsets[4];
			if (grid[ni] == 1 && visited[ni] == 0) {
				visited[ni] = 1;
				bfs_queue[tail++] = ni;
				visited_count++;
			}
		}
		// -Z
		if (bz > 0) {
			const int ni = ci + offsets[5];
			if (grid[ni] == 1 && visited[ni] == 0) {
				visited[ni] = 1;
				bfs_queue[tail++] = ni;
				visited_count++;
			}
		}
	}

	uint64_t t_bfs = OS::get_singleton()->get_ticks_usec();

	// Early exit: all blocks are ground-connected.
	if (visited_count == p_total_blocks) {
		memfree(visited);
		memfree(bfs_queue);
		print_line(vformat("[IntegrityComponents_C] blocks=%d  all_connected  bfs=%dus",
				p_total_blocks, (int)(t_bfs - t_start)));
		return Array();
	}

	// ── Phase 2: Component BFS on unsupported (unvisited) occupied cells ──
	Array components;
	int unsupported_total = p_total_blocks - visited_count;

	for (int idx = 0; idx < grid_size; idx++) {
		if (grid[idx] != 1 || visited[idx] != 0) {
			continue;
		}

		// Start a new component from this unvisited occupied cell.
		head = 0;
		tail = 0;
		bfs_queue[tail++] = idx;
		visited[idx] = 2;

		while (head < tail) {
			const int ci = bfs_queue[head++];
			const int bx = ci / ny_nz;
			const int rem2 = ci % ny_nz;
			const int by = rem2 / nz;
			const int bz = rem2 % nz;

			// +X
			if (bx + 1 < nx) {
				const int ni = ci + offsets[0];
				if (grid[ni] == 1 && visited[ni] == 0) {
					visited[ni] = 2;
					bfs_queue[tail++] = ni;
				}
			}
			// -X
			if (bx > 0) {
				const int ni = ci + offsets[1];
				if (grid[ni] == 1 && visited[ni] == 0) {
					visited[ni] = 2;
					bfs_queue[tail++] = ni;
				}
			}
			// +Y
			if (by + 1 < ny) {
				const int ni = ci + offsets[2];
				if (grid[ni] == 1 && visited[ni] == 0) {
					visited[ni] = 2;
					bfs_queue[tail++] = ni;
				}
			}
			// -Y
			if (by > 0) {
				const int ni = ci + offsets[3];
				if (grid[ni] == 1 && visited[ni] == 0) {
					visited[ni] = 2;
					bfs_queue[tail++] = ni;
				}
			}
			// +Z
			if (bz + 1 < nz) {
				const int ni = ci + offsets[4];
				if (grid[ni] == 1 && visited[ni] == 0) {
					visited[ni] = 2;
					bfs_queue[tail++] = ni;
				}
			}
			// -Z
			if (bz > 0) {
				const int ni = ci + offsets[5];
				if (grid[ni] == 1 && visited[ni] == 0) {
					visited[ni] = 2;
					bfs_queue[tail++] = ni;
				}
			}
		}

		// Convert flat indices to Vector3i component.
		TypedArray<Vector3i> component;
		component.resize(tail);
		for (int j = 0; j < tail; j++) {
			const int cj = bfs_queue[j];
			const int cbx = cj / ny_nz;
			const int crem = cj % ny_nz;
			const int cby = crem / nz;
			const int cbz = crem % nz;
			component[j] = Vector3i(cbx, cby, cbz);
		}
		components.push_back(component);
	}

	memfree(visited);
	memfree(bfs_queue);

	uint64_t t_end = OS::get_singleton()->get_ticks_usec();
	print_line(vformat("[IntegrityComponents_C] blocks=%d  supported=%d  unsupported=%d  components=%d  bfs=%dus  component_bfs=%dus  total=%dus",
			p_total_blocks, visited_count, unsupported_total, components.size(),
			(int)(t_bfs - t_start), (int)(t_end - t_bfs), (int)(t_end - t_start)));

	return components;
}

// ── Terrain streaming chunk computation ──
//
// Replaces GDScript terrain_streaming.gd update() with native code.
// The GDScript version takes ~15ms due to Dictionary<Vector3i> hashing overhead.
// This version uses a flat HashSet<uint64_t> with packed integer keys: ~0.5ms.

static inline uint64_t _pack_chunk(int bx, int by, int bz) {
	// Pack 3 ints into one uint64. Offset by 1024 to handle negatives (range -1024..1023).
	return (uint64_t((bx + 1024) & 0x7FF) << 22) |
	       (uint64_t((by + 1024) & 0x7FF) << 11) |
	       uint64_t((bz + 1024) & 0x7FF);
}

Dictionary BlockMeshBuilder::calc_streaming_update(
		const PackedVector3Array &p_player_positions,
		const Array &p_loaded_chunks,
		float p_view_distance,
		int p_chunk_size,
		int p_min_by, int p_max_by) {
	uint64_t t_start = OS::get_singleton()->get_ticks_usec();

	const float cs = (float)p_chunk_size;
	const int range_blocks = (int)Math::ceil(p_view_distance / cs);
	const float vd_sq = p_view_distance * p_view_distance;
	const int n_players = p_player_positions.size();
	const Vector3 *positions = p_player_positions.ptr();

	// Build needed set using packed integer keys in a HashMap.
	HashMap<uint64_t, bool> needed;
	needed.reserve(6000);

	for (int pi = 0; pi < n_players; pi++) {
		const Vector3 &pos = positions[pi];
		const int cx = (int)Math::floor(pos.x / cs);
		const int cz = (int)Math::floor(pos.z / cs);

		for (int bx = cx - range_blocks; bx <= cx + range_blocks; bx++) {
			for (int bz = cz - range_blocks; bz <= cz + range_blocks; bz++) {
				float dx = ((float)bx + 0.5f) * cs - pos.x;
				float dz = ((float)bz + 0.5f) * cs - pos.z;
				if (dx * dx + dz * dz > vd_sq) continue;
				for (int by = p_min_by; by <= p_max_by; by++) {
					needed[_pack_chunk(bx, by, bz)] = true;
				}
			}
		}
	}

	uint64_t t_needed = OS::get_singleton()->get_ticks_usec();

	// Build loaded set from Array of Vector3i.
	HashMap<uint64_t, bool> loaded;
	loaded.reserve(p_loaded_chunks.size());
	for (int i = 0; i < p_loaded_chunks.size(); i++) {
		Vector3i bp = p_loaded_chunks[i];
		loaded[_pack_chunk(bp.x, bp.y, bp.z)] = true;
	}

	// to_load: in needed but not loaded
	Array to_load;
	for (const KeyValue<uint64_t, bool> &kv : needed) {
		if (!loaded.has(kv.key)) {
			// Unpack
			int bx = ((int)((kv.key >> 22) & 0x7FF)) - 1024;
			int by = ((int)((kv.key >> 11) & 0x7FF)) - 1024;
			int bz = ((int)(kv.key & 0x7FF)) - 1024;
			to_load.push_back(Vector3i(bx, by, bz));
		}
	}

	// to_unload: in loaded but not needed
	Array to_unload;
	for (int i = 0; i < p_loaded_chunks.size(); i++) {
		Vector3i bp = p_loaded_chunks[i];
		if (!needed.has(_pack_chunk(bp.x, bp.y, bp.z))) {
			to_unload.push_back(bp);
		}
	}

	// Sort to_load by distance to nearest player (closest first).
	if (to_load.size() > 1 && n_players > 0) {
		struct SortCtx {
			const Vector3 *positions;
			int n_players;
			float cs;
		};
		SortCtx ctx = { positions, n_players, cs };

		// Precompute distances for sort
		int n = to_load.size();
		float *dists = (float *)memalloc(n * sizeof(float));
		Vector3i *chunks = (Vector3i *)memalloc(n * sizeof(Vector3i));
		for (int i = 0; i < n; i++) {
			chunks[i] = to_load[i];
			Vector3 center(
				((float)chunks[i].x + 0.5f) * cs,
				((float)chunks[i].y + 0.5f) * cs,
				((float)chunks[i].z + 0.5f) * cs);
			float best = 1e18f;
			for (int pi = 0; pi < n_players; pi++) {
				float d = center.distance_squared_to(positions[pi]);
				if (d < best) best = d;
			}
			dists[i] = best;
		}
		// Simple insertion sort (to_load is usually small)
		for (int i = 1; i < n; i++) {
			float d = dists[i];
			Vector3i c = chunks[i];
			int j = i - 1;
			while (j >= 0 && dists[j] > d) {
				dists[j + 1] = dists[j];
				chunks[j + 1] = chunks[j];
				j--;
			}
			dists[j + 1] = d;
			chunks[j + 1] = c;
		}
		to_load.clear();
		for (int i = 0; i < n; i++) {
			to_load.push_back(chunks[i]);
		}
		memfree(dists);
		memfree(chunks);
	}

	uint64_t t_end = OS::get_singleton()->get_ticks_usec();

	Dictionary result;
	result["to_load"] = to_load;
	result["to_unload"] = to_unload;
	return result;
}

// ─────────────────────────────────────────────────────────────────────────────
// Bond-graph connectivity check.
//
// BFS from ground-anchored blocks, traversing only bonds that are not broken.
// Bonds are stored canonically: bond between block idx and its +axis neighbor
// is at p_bond_broken[idx * 3 + axis], where axis 0=X, 1=Y, 2=Z. The bond
// from idx in the -axis direction is owned by the neighbor at idx + offset
// (which is the lower-indexed block of that pair).
// ─────────────────────────────────────────────────────────────────────────────
Array BlockMeshBuilder::calc_bond_connectivity_components(
		const PackedByteArray &p_block_grid,
		const PackedByteArray &p_ground_mask,
		const PackedByteArray &p_bond_broken,
		int p_num_x, int p_num_y, int p_num_z,
		int p_total_blocks) {
	const int grid_size = p_num_x * p_num_y * p_num_z;
	ERR_FAIL_COND_V_MSG(p_block_grid.size() != grid_size, Array(),
			"calc_bond_connectivity_components: grid size mismatch");
	ERR_FAIL_COND_V_MSG(p_bond_broken.size() != grid_size * 3, Array(),
			"calc_bond_connectivity_components: bond_broken must be grid_size * 3");
	ERR_FAIL_COND_V(p_total_blocks <= 0, Array());

	uint64_t t_start = OS::get_singleton()->get_ticks_usec();

	const uint8_t *grid = p_block_grid.ptr();
	const uint8_t *bonds = p_bond_broken.ptr();
	const int nx = p_num_x;
	const int ny = p_num_y;
	const int nz = p_num_z;
	const int ny_nz = ny * nz;

	const bool has_ground_mask = p_ground_mask.size() == grid_size;
	const uint8_t *ground_mask = has_ground_mask ? p_ground_mask.ptr() : nullptr;

	uint8_t *visited = (uint8_t *)memalloc(grid_size);
	memset(visited, 0, grid_size);
	int *bfs_queue = (int *)memalloc(p_total_blocks * sizeof(int));
	int head = 0, tail = 0;

	// Seed BFS from ground-anchored blocks.
	if (has_ground_mask) {
		for (int idx = 0; idx < grid_size; idx++) {
			if (grid[idx] == 1 && ground_mask[idx] == 1) {
				visited[idx] = 1;
				bfs_queue[tail++] = idx;
			}
		}
	} else {
		for (int bx = 0; bx < nx; bx++) {
			int base = bx * ny_nz;
			for (int bz = 0; bz < nz; bz++) {
				int idx = base + bz; // y=0
				if (grid[idx] == 1) {
					visited[idx] = 1;
					bfs_queue[tail++] = idx;
				}
			}
		}
	}

	// BFS, traversing only intact bonds.
	while (head < tail) {
		const int ci = bfs_queue[head++];
		const int bx = ci / ny_nz;
		const int rem = ci % ny_nz;
		const int by = rem / nz;
		const int bz = rem % nz;

		// +X: bond owned by ci, axis 0
		if (bx + 1 < nx) {
			int ni = ci + ny_nz;
			if (grid[ni] == 1 && !visited[ni] && !bonds[ci * 3 + 0]) {
				visited[ni] = 1;
				bfs_queue[tail++] = ni;
			}
		}
		// -X: bond owned by ni (lower-indexed), axis 0
		if (bx > 0) {
			int ni = ci - ny_nz;
			if (grid[ni] == 1 && !visited[ni] && !bonds[ni * 3 + 0]) {
				visited[ni] = 1;
				bfs_queue[tail++] = ni;
			}
		}
		// +Y: bond owned by ci, axis 1
		if (by + 1 < ny) {
			int ni = ci + nz;
			if (grid[ni] == 1 && !visited[ni] && !bonds[ci * 3 + 1]) {
				visited[ni] = 1;
				bfs_queue[tail++] = ni;
			}
		}
		// -Y: bond owned by ni, axis 1
		if (by > 0) {
			int ni = ci - nz;
			if (grid[ni] == 1 && !visited[ni] && !bonds[ni * 3 + 1]) {
				visited[ni] = 1;
				bfs_queue[tail++] = ni;
			}
		}
		// +Z: bond owned by ci, axis 2
		if (bz + 1 < nz) {
			int ni = ci + 1;
			if (grid[ni] == 1 && !visited[ni] && !bonds[ci * 3 + 2]) {
				visited[ni] = 1;
				bfs_queue[tail++] = ni;
			}
		}
		// -Z: bond owned by ni, axis 2
		if (bz > 0) {
			int ni = ci - 1;
			if (grid[ni] == 1 && !visited[ni] && !bonds[ni * 3 + 2]) {
				visited[ni] = 1;
				bfs_queue[tail++] = ni;
			}
		}
	}

	uint64_t t_bfs = OS::get_singleton()->get_ticks_usec();

	// Count unreachable blocks; bail early if everything is connected.
	int unsupported = 0;
	for (int idx = 0; idx < grid_size; idx++) {
		if (grid[idx] == 1 && visited[idx] == 0) unsupported++;
	}
	if (unsupported == 0) {
		memfree(visited);
		memfree(bfs_queue);
		return Array();
	}

	// Component BFS over unreachable blocks, traversing only INTACT bonds.
	// Two blocks are in the same component iff there's a path of unbroken
	// bonds between them. This is the right answer for both structures (a
	// detached chunk that's bond-cut in half → two chunks fall) and clusters
	// (no ground anchor; pieces separated by broken bonds become separate
	// sub-clusters when re-checked).
	Array components;
	for (int idx = 0; idx < grid_size; idx++) {
		if (grid[idx] != 1 || visited[idx] != 0) continue;

		head = 0; tail = 0;
		bfs_queue[tail++] = idx;
		visited[idx] = 2;

		while (head < tail) {
			const int ci = bfs_queue[head++];
			const int cbx = ci / ny_nz;
			const int crem = ci % ny_nz;
			const int cby = crem / nz;
			const int cbz = crem % nz;
			// +X: bond owned by ci, axis 0
			if (cbx + 1 < nx) {
				int ni = ci + ny_nz;
				if (grid[ni] == 1 && visited[ni] == 0 && !bonds[ci * 3 + 0]) { visited[ni] = 2; bfs_queue[tail++] = ni; }
			}
			// -X: bond owned by ni
			if (cbx > 0) {
				int ni = ci - ny_nz;
				if (grid[ni] == 1 && visited[ni] == 0 && !bonds[ni * 3 + 0]) { visited[ni] = 2; bfs_queue[tail++] = ni; }
			}
			// +Y: bond owned by ci, axis 1
			if (cby + 1 < ny) {
				int ni = ci + nz;
				if (grid[ni] == 1 && visited[ni] == 0 && !bonds[ci * 3 + 1]) { visited[ni] = 2; bfs_queue[tail++] = ni; }
			}
			// -Y: bond owned by ni
			if (cby > 0) {
				int ni = ci - nz;
				if (grid[ni] == 1 && visited[ni] == 0 && !bonds[ni * 3 + 1]) { visited[ni] = 2; bfs_queue[tail++] = ni; }
			}
			// +Z: bond owned by ci, axis 2
			if (cbz + 1 < nz) {
				int ni = ci + 1;
				if (grid[ni] == 1 && visited[ni] == 0 && !bonds[ci * 3 + 2]) { visited[ni] = 2; bfs_queue[tail++] = ni; }
			}
			// -Z: bond owned by ni
			if (cbz > 0) {
				int ni = ci - 1;
				if (grid[ni] == 1 && visited[ni] == 0 && !bonds[ni * 3 + 2]) { visited[ni] = 2; bfs_queue[tail++] = ni; }
			}
		}

		TypedArray<Vector3i> component;
		component.resize(tail);
		for (int j = 0; j < tail; j++) {
			const int cj = bfs_queue[j];
			component[j] = Vector3i(cj / ny_nz, (cj % ny_nz) / nz, cj % nz);
		}
		components.push_back(component);
	}

	memfree(visited);
	memfree(bfs_queue);

	if (s_stress_debug_print) {
		uint64_t t_end = OS::get_singleton()->get_ticks_usec();
		print_line(vformat("[BondConnectivity] blocks=%d  detached=%d  components=%d  bfs=%dus  total=%dus",
				p_total_blocks, unsupported, components.size(),
				(int)(t_bfs - t_start), (int)(t_end - t_start)));
	}

	return components;
}


// ── Radial bond damage with DDA voxel-walk shielding ──
//
// For each bond inside the blast radius, casts a ray from the blast position
// to the bond midpoint and walks the voxel grid. Each occupied voxel along
// the path contributes (path_length_in_voxel * block_hp) to the total HP
// absorbed by the ray. The bond receives the remaining energy after subtracting
// absorption from the cubic-falloff raw energy.
//
// Falloff matches calc_structure_explosion's block-damage curve and the rigid-
// body impulse curve in explosion_helper, so all three blast effects share one
// decay shape: 1 / (1 + (3 d/r)^3).
//
// DDA reference: Amanatides & Woo (1987). The bond midpoint sits exactly on
// a voxel face, so the ray ends on a boundary; the loop terminates at t=1.
// One of the bond's two endpoint blocks (the one on the blast side) IS counted
// in the absorption — that is correct: a block between blast and bond shields
// the bond regardless of whether it owns the bond.

// Inner kernel: operates on raw pointers, modifies damage_w / broken_w in place.
// Single-call and batch paths both call this. Thread-safe (no shared state —
// each call has its own buffers).
static void _damage_bonds_radial_shielded_inner(
		const uint8_t *grid,
		const float *strength,
		float *damage_w,
		uint8_t *broken_w,
		int nx, int ny, int nz,
		float block_size,
		const Vector3 &hit_local,
		float energy,
		float radius,
		float block_hp,
		int &out_damaged_count,
		int &out_broken_count) {

	const int ny_nz = ny * nz;
	const float inv_block_size = 1.0f / block_size;
	const float radius_sq = radius * radius;
	const float inv_radius = 1.0f / radius;

	const float half_nx = nx * 0.5f;
	const float half_ny = ny * 0.5f;
	const float half_nz = nz * 0.5f;
	const float blast_gx = hit_local.x * inv_block_size + half_nx;
	const float blast_gy = hit_local.y * inv_block_size + half_ny;
	const float blast_gz = hit_local.z * inv_block_size + half_nz;

	int damaged_count = 0;
	int broken_count = 0;

	const float r_voxels = radius * inv_block_size + 1.0f;
	const int min_bx = MAX(0, (int)floorf(blast_gx - r_voxels));
	const int max_bx = MIN(nx, (int)ceilf(blast_gx + r_voxels));
	const int min_by = MAX(0, (int)floorf(blast_gy - r_voxels));
	const int max_by = MIN(ny, (int)ceilf(blast_gy + r_voxels));
	const int min_bz = MAX(0, (int)floorf(blast_gz - r_voxels));
	const int max_bz = MIN(nz, (int)ceilf(blast_gz + r_voxels));

	for (int bx = min_bx; bx < max_bx; bx++) {
		for (int by = min_by; by < max_by; by++) {
			for (int bz = min_bz; bz < max_bz; bz++) {
				const int here = bx * ny_nz + by * nz + bz;
				if (grid[here] == 0) continue;

				for (int axis = 0; axis < 3; axis++) {
					const int bi = here * 3 + axis;
					if (broken_w[bi] != 0) continue;

					float mid_lx = (bx + 0.5f - half_nx) * block_size;
					float mid_ly = (by + 0.5f - half_ny) * block_size;
					float mid_lz = (bz + 0.5f - half_nz) * block_size;
					if (axis == 0) mid_lx += 0.5f * block_size;
					else if (axis == 1) mid_ly += 0.5f * block_size;
					else mid_lz += 0.5f * block_size;

					const float dlx = mid_lx - hit_local.x;
					const float dly = mid_ly - hit_local.y;
					const float dlz = mid_lz - hit_local.z;
					const float dist_sq = dlx * dlx + dly * dly + dlz * dlz;
					if (dist_sq >= radius_sq) continue;

					const float dist = sqrtf(dist_sq);
					const float norm_dist = dist * inv_radius;
					const float scaled = norm_dist * 3.0f;
					const float falloff = 1.0f / (1.0f + scaled * scaled * scaled);
					const float raw_energy = energy * falloff;

					const float bond_gx = mid_lx * inv_block_size + half_nx;
					const float bond_gy = mid_ly * inv_block_size + half_ny;
					const float bond_gz = mid_lz * inv_block_size + half_nz;

					const float ray_dx = bond_gx - blast_gx;
					const float ray_dy = bond_gy - blast_gy;
					const float ray_dz = bond_gz - blast_gz;
					const float ray_len_sq = ray_dx * ray_dx + ray_dy * ray_dy + ray_dz * ray_dz;

					float absorbed = 0.0f;
					if (ray_len_sq > 1e-12f) {
						const float ray_len = sqrtf(ray_len_sq);
						const float abs_dx = fabsf(ray_dx);
						const float abs_dy = fabsf(ray_dy);
						const float abs_dz = fabsf(ray_dz);

						int vx = (int)floorf(blast_gx);
						int vy = (int)floorf(blast_gy);
						int vz = (int)floorf(blast_gz);

						const int step_x = (ray_dx > 0.0f) ? 1 : (ray_dx < 0.0f ? -1 : 0);
						const int step_y = (ray_dy > 0.0f) ? 1 : (ray_dy < 0.0f ? -1 : 0);
						const int step_z = (ray_dz > 0.0f) ? 1 : (ray_dz < 0.0f ? -1 : 0);

						const float BIG = 1e30f;
						const float t_delta_x = (abs_dx > 1e-9f) ? (1.0f / abs_dx) : BIG;
						const float t_delta_y = (abs_dy > 1e-9f) ? (1.0f / abs_dy) : BIG;
						const float t_delta_z = (abs_dz > 1e-9f) ? (1.0f / abs_dz) : BIG;

						float t_max_x = BIG;
						if (abs_dx > 1e-9f) {
							t_max_x = (step_x > 0) ? ((vx + 1.0f - blast_gx) / abs_dx)
													: ((blast_gx - vx) / abs_dx);
						}
						float t_max_y = BIG;
						if (abs_dy > 1e-9f) {
							t_max_y = (step_y > 0) ? ((vy + 1.0f - blast_gy) / abs_dy)
													: ((blast_gy - vy) / abs_dy);
						}
						float t_max_z = BIG;
						if (abs_dz > 1e-9f) {
							t_max_z = (step_z > 0) ? ((vz + 1.0f - blast_gz) / abs_dz)
													: ((blast_gz - vz) / abs_dz);
						}

						float t_prev = 0.0f;
						const int max_iter = (int)(abs_dx + abs_dy + abs_dz) + 4;
						for (int iter = 0; iter < max_iter; iter++) {
							float t_next = t_max_x;
							if (t_max_y < t_next) t_next = t_max_y;
							if (t_max_z < t_next) t_next = t_max_z;
							if (t_next > 1.0f) t_next = 1.0f;

							const float seg_len = (t_next - t_prev) * ray_len;

							if (vx >= 0 && vx < nx && vy >= 0 && vy < ny && vz >= 0 && vz < nz) {
								const int idx = vx * ny_nz + vy * nz + vz;
								if (grid[idx] == 1) {
									absorbed += seg_len * block_hp;
									if (absorbed >= raw_energy) {
										absorbed = raw_energy;
										break;
									}
								}
							}

							if (t_next >= 1.0f) break;

							if (t_max_x <= t_max_y && t_max_x <= t_max_z) {
								vx += step_x;
								t_max_x += t_delta_x;
							} else if (t_max_y <= t_max_z) {
								vy += step_y;
								t_max_y += t_delta_y;
							} else {
								vz += step_z;
								t_max_z += t_delta_z;
							}
							t_prev = t_next;
						}
					}

					float shielded_energy = raw_energy - absorbed;
					if (shielded_energy <= 0.0f) continue;

					damage_w[bi] += shielded_energy;
					damaged_count++;
					if (damage_w[bi] >= strength[bi]) {
						broken_w[bi] = 1;
						broken_count++;
					}
				}
			}
		}
	}

	out_damaged_count = damaged_count;
	out_broken_count = broken_count;
}

Dictionary BlockMeshBuilder::damage_bonds_radial_shielded(
		const PackedByteArray &p_block_grid,
		const PackedFloat32Array &p_bond_strength,
		const PackedFloat32Array &p_bond_damage_in,
		const PackedByteArray &p_bond_broken_in,
		int p_num_x, int p_num_y, int p_num_z,
		float p_block_size,
		const Vector3 &p_hit_local,
		float p_energy,
		float p_radius,
		float p_block_hp) {

	const int grid_size = p_num_x * p_num_y * p_num_z;
	const int bond_count = grid_size * 3;

	ERR_FAIL_COND_V_MSG(p_block_grid.size() != grid_size, Dictionary(),
			"damage_bonds_radial_shielded: block_grid size mismatch");
	ERR_FAIL_COND_V_MSG(p_bond_strength.size() != bond_count, Dictionary(),
			"damage_bonds_radial_shielded: bond_strength must be grid_size*3");
	ERR_FAIL_COND_V_MSG(p_bond_damage_in.size() != bond_count, Dictionary(),
			"damage_bonds_radial_shielded: bond_damage must be grid_size*3");
	ERR_FAIL_COND_V_MSG(p_bond_broken_in.size() != bond_count, Dictionary(),
			"damage_bonds_radial_shielded: bond_broken must be grid_size*3");

	Dictionary result;
	if (p_radius <= 0.0f || p_energy <= 0.0f || p_block_size <= 0.0f) {
		result["bond_damage"] = p_bond_damage_in;
		result["bond_broken"] = p_bond_broken_in;
		result["broken"] = 0;
		result["damaged"] = 0;
		return result;
	}

	uint64_t t_start = OS::get_singleton()->get_ticks_usec();

	// Working copies (Godot CoW makes these cheap until first write).
	PackedFloat32Array bond_damage = p_bond_damage_in;
	PackedByteArray bond_broken = p_bond_broken_in;

	int damaged_count = 0;
	int broken_count = 0;

	_damage_bonds_radial_shielded_inner(
			p_block_grid.ptr(), p_bond_strength.ptr(),
			bond_damage.ptrw(), bond_broken.ptrw(),
			p_num_x, p_num_y, p_num_z,
			p_block_size, p_hit_local,
			p_energy, p_radius, p_block_hp,
			damaged_count, broken_count);

	if (s_stress_debug_print) {
		uint64_t t_end = OS::get_singleton()->get_ticks_usec();
		print_line(vformat("[BondShielded] energy=%.1f r=%.1f  damaged=%d broken=%d  total=%dus",
				p_energy, p_radius, damaged_count, broken_count,
				(int)(t_end - t_start)));
	}

	result["bond_damage"] = bond_damage;
	result["bond_broken"] = bond_broken;
	result["broken"] = broken_count;
	result["damaged"] = damaged_count;
	return result;
}


// ── Multithreaded batch version ──
//
// Per-cluster job state. One per cluster, lifetime-managed by the batch
// caller. Worker threads write directly into damage_buf / broken_buf which
// are pre-allocated heap arrays — Godot's PackedXxxArray COW writes aren't
// thread-safe outside the main thread, so we use raw pointers.
struct BondDamageJob {
	const uint8_t *grid;
	const float *strength;
	float *damage_buf;
	uint8_t *broken_buf;
	int num_x, num_y, num_z;
	Vector3 hit_local;
	float energy;     // per-cluster: lets each cluster have its own factor
	float block_hp;   // per-cluster: shielding contribution per voxel
	int damaged_count = 0;
	int broken_count = 0;
	// Cluster-side connectivity output. After bond damage, if any bonds broke
	// AND the cluster has >=2 blocks, the worker runs component BFS over the
	// updated bond_broken buffer and stores fragments here (largest excluded).
	// Indices are flat grid indices; main thread converts them to Vector3i.
	LocalVector<LocalVector<int>> fragments;
};

struct BondDamageBatch {
	BondDamageJob *jobs;
	int count;
	float block_size;
	float radius;
};

// Cluster-side connectivity BFS. No ground anchor — clusters float free, so the
// "supported" set is empty and every block lands in some component. We then
// drop the LARGEST component (which stays in the source cluster) and return the
// rest as fragments for the caller to spawn as child clusters. Identical
// traversal rules to calc_bond_connectivity_components but specialized for the
// cluster path so we can drive it from a worker thread.
static void _bond_components_cluster(
		const uint8_t *grid,
		const uint8_t *bonds,
		int nx, int ny, int nz,
		LocalVector<LocalVector<int>> &out_fragments) {

	const int grid_size = nx * ny * nz;
	const int ny_nz = ny * nz;

	uint8_t *visited = (uint8_t *)memalloc(grid_size);
	memset(visited, 0, grid_size);
	int *bfs_queue = (int *)memalloc(grid_size * sizeof(int));

	LocalVector<LocalVector<int>> components;
	int largest_idx = -1;
	int largest_size = -1;

	for (int idx = 0; idx < grid_size; idx++) {
		if (grid[idx] != 1 || visited[idx] != 0) continue;

		int head = 0, tail = 0;
		bfs_queue[tail++] = idx;
		visited[idx] = 1;

		while (head < tail) {
			const int ci = bfs_queue[head++];
			const int cbx = ci / ny_nz;
			const int crem = ci % ny_nz;
			const int cby = crem / nz;
			const int cbz = crem % nz;
			if (cbx + 1 < nx) {
				int ni = ci + ny_nz;
				if (grid[ni] == 1 && visited[ni] == 0 && !bonds[ci * 3 + 0]) { visited[ni] = 1; bfs_queue[tail++] = ni; }
			}
			if (cbx > 0) {
				int ni = ci - ny_nz;
				if (grid[ni] == 1 && visited[ni] == 0 && !bonds[ni * 3 + 0]) { visited[ni] = 1; bfs_queue[tail++] = ni; }
			}
			if (cby + 1 < ny) {
				int ni = ci + nz;
				if (grid[ni] == 1 && visited[ni] == 0 && !bonds[ci * 3 + 1]) { visited[ni] = 1; bfs_queue[tail++] = ni; }
			}
			if (cby > 0) {
				int ni = ci - nz;
				if (grid[ni] == 1 && visited[ni] == 0 && !bonds[ni * 3 + 1]) { visited[ni] = 1; bfs_queue[tail++] = ni; }
			}
			if (cbz + 1 < nz) {
				int ni = ci + 1;
				if (grid[ni] == 1 && visited[ni] == 0 && !bonds[ci * 3 + 2]) { visited[ni] = 1; bfs_queue[tail++] = ni; }
			}
			if (cbz > 0) {
				int ni = ci - 1;
				if (grid[ni] == 1 && visited[ni] == 0 && !bonds[ni * 3 + 2]) { visited[ni] = 1; bfs_queue[tail++] = ni; }
			}
		}

		LocalVector<int> comp;
		comp.resize(tail);
		for (int j = 0; j < tail; j++) comp[j] = bfs_queue[j];
		if ((int)comp.size() > largest_size) {
			largest_size = comp.size();
			largest_idx = components.size();
		}
		components.push_back(comp);
	}

	memfree(visited);
	memfree(bfs_queue);

	if (components.size() <= 1) return;
	for (uint32_t i = 0; i < components.size(); i++) {
		if ((int)i == largest_idx) continue;
		out_fragments.push_back(components[i]);
	}
}

static void _bond_damage_worker(void *p_userdata, uint32_t p_idx) {
	BondDamageBatch *batch = (BondDamageBatch *)p_userdata;
	BondDamageJob &job = batch->jobs[p_idx];
	_damage_bonds_radial_shielded_inner(
			job.grid, job.strength,
			job.damage_buf, job.broken_buf,
			job.num_x, job.num_y, job.num_z,
			batch->block_size, job.hit_local,
			job.energy, batch->radius, job.block_hp,
			job.damaged_count, job.broken_count);

	// If any bonds broke, run component BFS in this same worker so the BFS
	// parallelizes across clusters too. Caller no longer dispatches a serial
	// GDScript pass to figure out fragments.
	if (job.broken_count > 0) {
		_bond_components_cluster(job.grid, job.broken_buf,
				job.num_x, job.num_y, job.num_z,
				job.fragments);
	}
}

Array BlockMeshBuilder::damage_bonds_radial_shielded_batch(
		const Array &p_clusters,
		float p_block_size,
		float p_energy,
		float p_radius,
		float p_block_hp) {

	const int n_clusters = p_clusters.size();
	Array results;
	if (n_clusters == 0) return results;
	if (p_radius <= 0.0f || p_block_size <= 0.0f) {
		for (int c = 0; c < n_clusters; c++) {
			Dictionary src = p_clusters[c];
			Dictionary out;
			out["bond_damage"] = src["bond_damage"];
			out["bond_broken"] = src["bond_broken"];
			out["broken"] = 0;
			out["damaged"] = 0;
			results.push_back(out);
		}
		return results;
	}

	uint64_t t_start = OS::get_singleton()->get_ticks_usec();

	// Phase 1: pull arrays out of each Dict, build per-cluster job descriptors.
	// We hold COW copies of bond_damage / bond_broken in vectors so the worker
	// threads can write into their .ptrw() buffers safely (each cluster has
	// its own buffer; no cross-job sharing).
	LocalVector<PackedByteArray> grids;
	LocalVector<PackedFloat32Array> strengths;
	LocalVector<PackedFloat32Array> damages;
	LocalVector<PackedByteArray> brokens;
	LocalVector<BondDamageJob> jobs;
	grids.resize(n_clusters);
	strengths.resize(n_clusters);
	damages.resize(n_clusters);
	brokens.resize(n_clusters);
	jobs.resize(n_clusters);

	for (int c = 0; c < n_clusters; c++) {
		Dictionary cd = p_clusters[c];
		grids[c] = cd["block_grid"];
		strengths[c] = cd["bond_strength"];
		damages[c] = cd["bond_damage"];   // CoW copy — cheap until ptrw() forces a unique buffer
		brokens[c] = cd["bond_broken"];

		const int nx = (int)cd["num_x"];
		const int ny = (int)cd["num_y"];
		const int nz = (int)cd["num_z"];
		const int gsz = nx * ny * nz;
		ERR_FAIL_COND_V_MSG(grids[c].size() != gsz, Array(),
				vformat("damage_bonds_radial_shielded_batch: cluster %d block_grid size mismatch", c));
		ERR_FAIL_COND_V_MSG(strengths[c].size() != gsz * 3, Array(),
				vformat("damage_bonds_radial_shielded_batch: cluster %d bond_strength size mismatch", c));
		ERR_FAIL_COND_V_MSG(damages[c].size() != gsz * 3, Array(),
				vformat("damage_bonds_radial_shielded_batch: cluster %d bond_damage size mismatch", c));
		ERR_FAIL_COND_V_MSG(brokens[c].size() != gsz * 3, Array(),
				vformat("damage_bonds_radial_shielded_batch: cluster %d bond_broken size mismatch", c));

		BondDamageJob &job = jobs[c];
		job.grid = grids[c].ptr();
		job.strength = strengths[c].ptr();
		// Force unique buffers BEFORE handing pointers to worker threads.
		// ptrw() may trigger a COW copy; do it on the main thread so the
		// writes inside the worker are into thread-local memory.
		job.damage_buf = damages[c].ptrw();
		job.broken_buf = brokens[c].ptrw();
		job.num_x = nx;
		job.num_y = ny;
		job.num_z = nz;
		job.hit_local = cd["hit_local"];
		// Per-cluster energy / block_hp (fall back to batch-level defaults).
		job.energy = cd.has("energy") ? (float)cd["energy"] : p_energy;
		job.block_hp = cd.has("block_hp") ? (float)cd["block_hp"] : p_block_hp;
		if (job.energy <= 0.0f) {
			// Skip clusters with zero energy: write through unchanged later.
			job.damaged_count = 0;
			job.broken_count = 0;
		}
	}

	// Phase 2: dispatch via WorkerThreadPool. Each cluster is one task — the
	// pool batches small tasks across cores automatically.
	BondDamageBatch batch;
	batch.jobs = jobs.ptr();
	batch.count = n_clusters;
	batch.block_size = p_block_size;
	batch.radius = p_radius;

	// For very small batches (1-2 clusters), the pool's overhead exceeds the
	// per-cluster cost — run inline instead.
	if (n_clusters <= 2) {
		for (int c = 0; c < n_clusters; c++) {
			_bond_damage_worker(&batch, c);
		}
	} else {
		WorkerThreadPool::GroupID group = WorkerThreadPool::get_singleton()->add_native_group_task(
				_bond_damage_worker, &batch, n_clusters, -1, false,
				String("bond_damage_batch"));
		WorkerThreadPool::get_singleton()->wait_for_group_task_completion(group);
	}

	// Phase 3: pack results. Fragments come back as flat grid indices; convert
	// them to Vector3i keys here on the main thread (Variant containers aren't
	// safe to construct from worker threads).
	int total_damaged = 0;
	int total_broken = 0;
	int total_fragments = 0;
	for (int c = 0; c < n_clusters; c++) {
		Dictionary out;
		out["bond_damage"] = damages[c];
		out["bond_broken"] = brokens[c];
		out["broken"] = jobs[c].broken_count;
		out["damaged"] = jobs[c].damaged_count;

		Array fragments_out;
		const BondDamageJob &job = jobs[c];
		if (!job.fragments.is_empty()) {
			const int ny_nz = job.num_y * job.num_z;
			const int nz = job.num_z;
			for (uint32_t f = 0; f < job.fragments.size(); f++) {
				const LocalVector<int> &frag = job.fragments[f];
				TypedArray<Vector3i> keys;
				keys.resize(frag.size());
				for (uint32_t k = 0; k < frag.size(); k++) {
					const int gi = frag[k];
					keys[k] = Vector3i(gi / ny_nz, (gi % ny_nz) / nz, gi % nz);
				}
				fragments_out.push_back(keys);
			}
			total_fragments += job.fragments.size();
		}
		out["fragments"] = fragments_out;

		results.push_back(out);
		total_damaged += jobs[c].damaged_count;
		total_broken += jobs[c].broken_count;
	}

	if (s_stress_debug_print) {
		uint64_t t_end = OS::get_singleton()->get_ticks_usec();
		print_line(vformat("[BondShieldedBatch] clusters=%d  energy=%.1f r=%.1f  damaged=%d broken=%d  fragments=%d  total=%dus",
				n_clusters, p_energy, p_radius, total_damaged, total_broken, total_fragments,
				(int)(t_end - t_start)));
	}

	return results;
}


// ── Build initial bond graph from a populated block grid ──
//
// Replaces a triple-nested GDScript loop. Walks the grid once, sets bond
// strength on every adjacent-occupied pair (axis ∈ {0=+X, 1=+Y, 2=+Z}) and
// marks everything else broken. Tens of thousands of clusters can spawn in
// a single tick after a big detach, so this hot path lives in C++ now.
Dictionary BlockMeshBuilder::compute_bond_graph(
		const PackedByteArray &p_block_grid,
		int p_num_x, int p_num_y, int p_num_z,
		float p_strength) {

	const int grid_size = p_num_x * p_num_y * p_num_z;
	const int bond_count = grid_size * 3;

	ERR_FAIL_COND_V_MSG(p_block_grid.size() != grid_size, Dictionary(),
			"compute_bond_graph: block_grid size mismatch");

	PackedFloat32Array strength;
	strength.resize(bond_count);
	PackedFloat32Array damage;
	damage.resize(bond_count);
	PackedByteArray broken;
	broken.resize(bond_count);

	float *strength_w = strength.ptrw();
	float *damage_w = damage.ptrw();
	uint8_t *broken_w = broken.ptrw();
	const uint8_t *grid = p_block_grid.ptr();

	// Default: every bond slot broken, zero strength, zero damage.
	// IMPORTANT: C++ Vector::resize() leaves trivially-constructible element
	// types UNINITIALIZED (only GDScript's resize zero-fills) — both float
	// arrays MUST be zeroed explicitly. Heap garbage in bond_damage reads as
	// pre-damaged bonds: random spurious breaks, and instant false collapse
	// under the gravity stress solver's κ = 1 − damage/strength coupling.
	memset(strength_w, 0, bond_count * sizeof(float));
	memset(damage_w, 0, bond_count * sizeof(float));
	memset(broken_w, 1, bond_count);

	const int nx = p_num_x;
	const int ny = p_num_y;
	const int nz = p_num_z;
	const int ny_nz = ny * nz;
	int live = 0;

	for (int bx = 0; bx < nx; bx++) {
		for (int by = 0; by < ny; by++) {
			for (int bz = 0; bz < nz; bz++) {
				const int here = bx * ny_nz + by * nz + bz;
				if (grid[here] == 0) continue;
				// +X
				if (bx + 1 < nx && grid[here + ny_nz] == 1) {
					const int bi = here * 3 + 0;
					strength_w[bi] = p_strength;
					broken_w[bi] = 0;
					live++;
				}
				// +Y
				if (by + 1 < ny && grid[here + nz] == 1) {
					const int bi = here * 3 + 1;
					strength_w[bi] = p_strength;
					broken_w[bi] = 0;
					live++;
				}
				// +Z
				if (bz + 1 < nz && grid[here + 1] == 1) {
					const int bi = here * 3 + 2;
					strength_w[bi] = p_strength;
					broken_w[bi] = 0;
					live++;
				}
			}
		}
	}

	Dictionary result;
	result["bond_strength"] = strength;
	result["bond_damage"] = damage;
	result["bond_broken"] = broken;
	result["live_count"] = live;
	return result;
}


// ── Gravity stress solver — quasi-static elastic-brittle interface analysis ──
//
// Physics: see GRAVITY_STRESS_PLAN.md. Each block has 6 DOF (small
// displacement u + small rotation θ). Each intact bond / terrain anchor is a
// glued-face interface transmitting force AND moment. Rotational DOF are
// mandatory: a 1-thick cantilever attached by a single face is a mechanism
// under force-only models (gravity at the block center and a point force at
// the face center form a couple only a face moment can close), and bending —
// which grows with overhang length SQUARED — is the dominant failure mode of
// overhangs. The old residual-flow solver had no moments, which is why it
// could never do cantilevers.
//
// Element (bond a→b along unit axis ê, direction d̂ = s·ê, face at midpoint):
//   δ = u_b − u_a + ½s·(ê × (θ_a + θ_b))       relative face translation
//   φ = θ_b − θ_a                               relative face rotation
//   F = κ[k_n δ_ax ê + k_s δ_perp]              normal + shear force
//   M = κ[k_t φ_ax ê + k_b φ_perp]              torsion + bending moment
// Gradient of interface energy (what the matvec accumulates, y = Kx):
//   y_a.u −= F                y_b.u += F
//   y_a.θ −= ½s(ê×F) + M      y_b.θ −= ½s(ê×F) − M
// Anchors are the same element with the far side fixed (u=θ=0), ê=ŷ, s=−1
// (bottom face) — so anchors carry real load and can be ripped out, which
// makes top-heavy structures tear free and topple as rigid bodies.
//
// Units: lengths in blocks (h=1), forces in block-weights (W=1 per block),
// moments in W·h. Stiffness ratios from an isotropic glue layer (ν≈0.25):
// k_n = E, k_s = 0.4E, k_b = E/12 (I=h⁴/12), k_t = 0.0562E (J≈0.1406h⁴).
// Only the RATIOS affect the force distribution; E is scale-free.
//
// Failure: combined edge stress on the square face (Z = h³/6 → factor 6;
// torsion c/J = 0.5/0.1406 → factor 3.556), capacity scaled by the bond's
// remaining fraction κ = 1 − damage/strength (bond graph feeds the physics —
// blast-weakened joints are softer and weaker, so explosions lower what an
// overhang can carry and gravity finishes the job).

struct GravityStressElem {
	int a_slot;          // block-side slot into the DOF vector
	int b_slot;          // neighbor slot, or -1 for terrain-anchor elements
	int grid_ref;        // bond: index into bond arrays; anchor: grid idx
	uint8_t axis;        // 0=X 1=Y 2=Z
	int8_t sign;         // +1 for bonds (d̂ = +ê), -1 for anchors (d̂ = −ŷ)
	float k_st;          // stiffness scale κ (floored for conditioning)
	float k_cap;         // capacity scale κ (unfloored)
};

// (ê_ax × v) for a coordinate axis ê_ax.
static inline void _gs_axis_cross(int ax, const double *v, double *out) {
	const int i1 = (ax + 1) % 3;
	const int i2 = (ax + 2) % 3;
	out[ax] = 0.0;
	out[i1] = -v[i2];
	out[i2] = v[i1];
}

// Interface force/moment from endpoint states. xa/xb are 6-double DOF blocks
// (u then θ); xb == nullptr means fixed ground side (anchor).
static inline void _gs_elem_wrench(const GravityStressElem &e,
		const double *xa, const double *xb,
		double k_n, double k_s, double k_b, double k_t,
		double *F, double *M, double *delta_ax_out) {
	const int ax = e.axis;
	double thsum[3], delta[3], phi[3];
	for (int i = 0; i < 3; i++) {
		const double ub = xb ? xb[i] : 0.0;
		const double tb = xb ? xb[3 + i] : 0.0;
		thsum[i] = xa[3 + i] + tb;
		delta[i] = ub - xa[i];
		phi[i] = tb - xa[3 + i];
	}
	double cr[3];
	_gs_axis_cross(ax, thsum, cr);
	for (int i = 0; i < 3; i++) {
		delta[i] += 0.5 * (double)e.sign * cr[i];
	}
	const int i1 = (ax + 1) % 3;
	const int i2 = (ax + 2) % 3;
	F[ax] = e.k_st * k_n * delta[ax];
	F[i1] = e.k_st * k_s * delta[i1];
	F[i2] = e.k_st * k_s * delta[i2];
	M[ax] = e.k_st * k_t * phi[ax];
	M[i1] = e.k_st * k_b * phi[i1];
	M[i2] = e.k_st * k_b * phi[i2];
	*delta_ax_out = delta[ax];
}

// y += K x, matrix-free over the element list.
static void _gs_matvec(const LocalVector<GravityStressElem> &elems,
		const double *x, double *y, int n_dof,
		double k_n, double k_s, double k_b, double k_t) {
	memset(y, 0, n_dof * sizeof(double));
	double F[3], M[3], crF[3], d_ax;
	for (uint32_t j = 0; j < elems.size(); j++) {
		const GravityStressElem &e = elems[j];
		const double *xa = x + e.a_slot * 6;
		const double *xb = (e.b_slot >= 0) ? x + e.b_slot * 6 : nullptr;
		_gs_elem_wrench(e, xa, xb, k_n, k_s, k_b, k_t, F, M, &d_ax);
		_gs_axis_cross(e.axis, F, crF);
		const double half_s = 0.5 * (double)e.sign;
		double *ya = y + e.a_slot * 6;
		for (int i = 0; i < 3; i++) {
			ya[i] -= F[i];
			ya[3 + i] -= half_s * crF[i] + M[i];
		}
		if (xb) {
			double *yb = y + e.b_slot * 6;
			for (int i = 0; i < 3; i++) {
				yb[i] += F[i];
				yb[3 + i] -= half_s * crF[i] - M[i];
			}
		}
	}
}

// ── Threaded matvec: slot-partitioned via a CSR incident-element table ──
//
// Each worker owns a contiguous slot range and writes ONLY its own y slots —
// no partial buffers, no reduction pass, zero contention. Elements are
// visited once per endpoint (2× wrench math total), which threads far better
// than the 1×-work-plus-reduction alternative at 100k+ DOF.

struct GsMatvecCtx {
	const GravityStressElem *elems;
	const int *inc_offsets;   // n_slots + 1
	const uint32_t *inc_entries; // elem_idx | (side << 31)
	const double *x;
	double *y;
	int n_slots;
	int slots_per_chunk;
	double k_n, k_s, k_b, k_t;
};

static void _gs_matvec_worker(void *p_userdata, uint32_t p_chunk) {
	GsMatvecCtx *ctx = (GsMatvecCtx *)p_userdata;
	const int begin = (int)p_chunk * ctx->slots_per_chunk;
	const int end = MIN(begin + ctx->slots_per_chunk, ctx->n_slots);
	double F[3], M[3], crF[3], d_ax;
	for (int s = begin; s < end; s++) {
		double *ys = ctx->y + s * 6;
		for (int i = 0; i < 6; i++) {
			ys[i] = 0.0;
		}
		for (int k = ctx->inc_offsets[s]; k < ctx->inc_offsets[s + 1]; k++) {
			const uint32_t entry = ctx->inc_entries[k];
			const GravityStressElem &e = ctx->elems[entry & 0x7FFFFFFFu];
			const bool is_b = (entry >> 31) != 0;
			const double *xa = ctx->x + e.a_slot * 6;
			const double *xb = (e.b_slot >= 0) ? ctx->x + e.b_slot * 6 : nullptr;
			_gs_elem_wrench(e, xa, xb, ctx->k_n, ctx->k_s, ctx->k_b, ctx->k_t, F, M, &d_ax);
			_gs_axis_cross(e.axis, F, crF);
			const double half_s = 0.5 * (double)e.sign;
			if (!is_b) {
				for (int i = 0; i < 3; i++) {
					ys[i] -= F[i];
					ys[3 + i] -= half_s * crF[i] + M[i];
				}
			} else {
				for (int i = 0; i < 3; i++) {
					ys[i] += F[i];
					ys[3 + i] -= half_s * crF[i] - M[i];
				}
			}
		}
	}
}

// Invert a 6x6 SPD matrix in place via Gauss-Jordan with partial pivoting.
// Returns false if singular (caller falls back to scalar jacobi for it).
static bool _gs_invert6(double *m /* 36, row-major */) {
	double inv[36];
	memset(inv, 0, sizeof(inv));
	for (int i = 0; i < 6; i++) {
		inv[i * 6 + i] = 1.0;
	}
	for (int col = 0; col < 6; col++) {
		int piv = col;
		double best = Math::abs(m[col * 6 + col]);
		for (int r = col + 1; r < 6; r++) {
			const double v = Math::abs(m[r * 6 + col]);
			if (v > best) {
				best = v;
				piv = r;
			}
		}
		if (best < 1e-30) {
			return false;
		}
		if (piv != col) {
			for (int c = 0; c < 6; c++) {
				SWAP(m[piv * 6 + c], m[col * 6 + c]);
				SWAP(inv[piv * 6 + c], inv[col * 6 + c]);
			}
		}
		const double d = 1.0 / m[col * 6 + col];
		for (int c = 0; c < 6; c++) {
			m[col * 6 + c] *= d;
			inv[col * 6 + c] *= d;
		}
		for (int r = 0; r < 6; r++) {
			if (r == col) {
				continue;
			}
			const double f = m[r * 6 + col];
			if (f == 0.0) {
				continue;
			}
			for (int c = 0; c < 6; c++) {
				m[r * 6 + c] -= f * m[col * 6 + c];
				inv[r * 6 + c] -= f * inv[col * 6 + c];
			}
		}
	}
	memcpy(m, inv, sizeof(inv));
	return true;
}

Dictionary BlockMeshBuilder::solve_gravity_stress(
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
		const Dictionary &p_params) {
	const int grid_size = p_num_x * p_num_y * p_num_z;
	Dictionary out;
	out["bond_broken"] = p_bond_broken_in;
	out["anchor_broken"] = p_anchor_broken_in;
	out["broke_bonds"] = 0;
	out["broke_anchors"] = 0;
	out["max_utilization"] = 0.0f;
	out["passes"] = 0;
	out["cg_iters"] = 0;
	out["converged"] = true;

	ERR_FAIL_COND_V_MSG(p_block_grid.size() != grid_size, out,
			"solve_gravity_stress: block_grid size mismatch");
	ERR_FAIL_COND_V_MSG(p_ground_mask.size() != grid_size, out,
			"solve_gravity_stress: ground_mask size mismatch");
	ERR_FAIL_COND_V_MSG(p_bond_strength.size() != grid_size * 3, out,
			"solve_gravity_stress: bond_strength must be grid_size*3");
	ERR_FAIL_COND_V_MSG(p_bond_damage.size() != grid_size * 3, out,
			"solve_gravity_stress: bond_damage must be grid_size*3");
	ERR_FAIL_COND_V_MSG(p_bond_broken_in.size() != grid_size * 3, out,
			"solve_gravity_stress: bond_broken must be grid_size*3");

	Vector3 g = p_gravity_local;
	if (g.length_squared() < 1e-12f) {
		return out;
	}
	g = g.normalized();

	// Tunables (block-weight units).
	const double T0 = p_params.has("tension") ? (double)p_params["tension"] : 50.0;
	const double C0 = p_params.has("compression") ? (double)p_params["compression"] : 500.0;
	const double S0 = p_params.has("shear") ? (double)p_params["shear"] : 37.5;
	const double anchor_factor = p_params.has("anchor_factor") ? (double)p_params["anchor_factor"] : 1.0;
	const int max_cg_iters = p_params.has("max_cg_iters") ? (int)p_params["max_cg_iters"] : 2000;
	const double tol = p_params.has("tolerance") ? (double)p_params["tolerance"] : 1e-6;
	const int max_passes = p_params.has("max_break_passes") ? (int)p_params["max_break_passes"] : 6;
	const bool check_symmetry = p_params.has("check_symmetry") && (bool)p_params["check_symmetry"];
	const bool debug_pass_stats = p_params.has("debug_pass_stats") && (bool)p_params["debug_pass_stats"];
	Array pass_stats;

	// Stiffness (scale-free; ratios from isotropic glue layer, ν ≈ 0.25).
	const double K_N = 100.0;
	const double K_S = 0.4 * K_N;
	const double K_B = K_N / 12.0;
	const double K_T = 0.0562 * K_N;
	const double KAPPA_FLOOR = 0.02;
	const double BEND_EDGE = 6.0;      // m_b → edge normal stress (Z = h³/6)
	const double TORS_EDGE = 3.556;    // m_t → edge shear stress (c/J)

	uint64_t t_start = OS::get_singleton()->get_ticks_usec();

	const uint8_t *grid = p_block_grid.ptr();
	const uint8_t *mask = p_ground_mask.ptr();
	const float *b_str = p_bond_strength.ptr();
	const float *b_dmg = p_bond_damage.ptr();

	// Working copies (returned).
	PackedByteArray bond_broken = p_bond_broken_in;
	PackedByteArray anchor_broken;
	if (p_anchor_broken_in.size() == grid_size) {
		anchor_broken = p_anchor_broken_in;
	} else {
		// No anchor state provided: every ground_mask block is a pristine anchor.
		anchor_broken.resize(grid_size);
		uint8_t *aw = anchor_broken.ptrw();
		for (int i = 0; i < grid_size; i++) {
			aw[i] = (grid[i] == 1 && mask[i] == 1) ? 0 : 1;
		}
	}
	uint8_t *bond_broken_w = bond_broken.ptrw();
	uint8_t *anchor_broken_w = anchor_broken.ptrw();
	const bool has_anchor_kappa = p_anchor_strength.size() == grid_size &&
			p_anchor_damage.size() == grid_size;
	const float *a_str = has_anchor_kappa ? p_anchor_strength.ptr() : nullptr;
	const float *a_dmg = has_anchor_kappa ? p_anchor_damage.ptr() : nullptr;

	const int nx = p_num_x, ny = p_num_y, nz = p_num_z;
	const int ny_nz = ny * nz;
	const double g_arr[3] = { (double)g.x, (double)g.y, (double)g.z };

	int *slot_of = (int *)memalloc(grid_size * sizeof(int));
	int *active = (int *)memalloc(grid_size * sizeof(int));
	uint8_t *visited = (uint8_t *)memalloc(grid_size);
	int *bfs_queue = (int *)memalloc(grid_size * sizeof(int));

	LocalVector<GravityStressElem> elems;
	LocalVector<double> x_v, r_v, z_v, p_v, ap_v, jinv_v;

	int broke_bonds = 0;
	int broke_anchors = 0;
	double max_util = 0.0;
	int total_cg_iters = 0;
	int passes = 0;
	bool all_converged = true;
	double sym_err = 0.0;

	for (int pass = 0; pass < max_passes; pass++) {
		// ── Anchored-reachable BFS over intact bonds ──
		// Blocks outside this set have no load path; the connectivity check
		// detaches them, and including them would make K singular.
		memset(visited, 0, grid_size);
		int head = 0, tail = 0;
		for (int i = 0; i < grid_size; i++) {
			if (grid[i] == 1 && mask[i] == 1 && anchor_broken_w[i] == 0) {
				visited[i] = 1;
				bfs_queue[tail++] = i;
			}
		}
		if (tail == 0) {
			break; // nothing anchored — connectivity check owns the outcome
		}
		while (head < tail) {
			const int ci = bfs_queue[head++];
			const int bx = ci / ny_nz;
			const int rem = ci % ny_nz;
			const int by = rem / nz;
			const int bz = rem % nz;
			if (bx + 1 < nx) { int ni = ci + ny_nz; if (grid[ni] == 1 && !visited[ni] && !bond_broken_w[ci * 3 + 0]) { visited[ni] = 1; bfs_queue[tail++] = ni; } }
			if (bx > 0)      { int ni = ci - ny_nz; if (grid[ni] == 1 && !visited[ni] && !bond_broken_w[ni * 3 + 0]) { visited[ni] = 1; bfs_queue[tail++] = ni; } }
			if (by + 1 < ny) { int ni = ci + nz;    if (grid[ni] == 1 && !visited[ni] && !bond_broken_w[ci * 3 + 1]) { visited[ni] = 1; bfs_queue[tail++] = ni; } }
			if (by > 0)      { int ni = ci - nz;    if (grid[ni] == 1 && !visited[ni] && !bond_broken_w[ni * 3 + 1]) { visited[ni] = 1; bfs_queue[tail++] = ni; } }
			if (bz + 1 < nz) { int ni = ci + 1;     if (grid[ni] == 1 && !visited[ni] && !bond_broken_w[ci * 3 + 2]) { visited[ni] = 1; bfs_queue[tail++] = ni; } }
			if (bz > 0)      { int ni = ci - 1;     if (grid[ni] == 1 && !visited[ni] && !bond_broken_w[ni * 3 + 2]) { visited[ni] = 1; bfs_queue[tail++] = ni; } }
		}

		// ── Active set + slots ──
		int n_active = 0;
		for (int i = 0; i < grid_size; i++) {
			slot_of[i] = -1;
			if (visited[i]) {
				slot_of[i] = n_active;
				active[n_active++] = i;
			}
		}
		if (n_active == 0) {
			break;
		}
		const int n_dof = n_active * 6;

		// ── Element lists (bonds between active blocks + intact anchors) ──
		elems.clear();
		for (int s = 0; s < n_active; s++) {
			const int idx = active[s];
			const int bx = idx / ny_nz;
			const int rem = idx % ny_nz;
			const int by = rem / nz;
			const int bz = rem % nz;
			for (int ax = 0; ax < 3; ax++) {
				const int bi = idx * 3 + ax;
				if (bond_broken_w[bi]) {
					continue;
				}
				int nidx = -1;
				if (ax == 0 && bx + 1 < nx) nidx = idx + ny_nz;
				else if (ax == 1 && by + 1 < ny) nidx = idx + nz;
				else if (ax == 2 && bz + 1 < nz) nidx = idx + 1;
				if (nidx < 0 || grid[nidx] != 1 || slot_of[nidx] < 0) {
					continue;
				}
				const double s_str = b_str[bi];
				double kappa = 0.0;
				if (s_str > 0.0) {
					kappa = CLAMP(1.0 - (double)b_dmg[bi] / s_str, 0.0, 1.0);
				}
				GravityStressElem e;
				e.a_slot = s;
				e.b_slot = slot_of[nidx];
				e.grid_ref = bi;
				e.axis = (uint8_t)ax;
				e.sign = 1;
				e.k_st = (float)MAX(kappa, KAPPA_FLOOR);
				e.k_cap = (float)kappa;
				elems.push_back(e);
			}
			if (mask[idx] == 1 && anchor_broken_w[idx] == 0) {
				double kappa = 1.0;
				if (has_anchor_kappa && a_str[idx] > 0.0f) {
					kappa = CLAMP(1.0 - (double)a_dmg[idx] / (double)a_str[idx], 0.0, 1.0);
				}
				GravityStressElem e;
				e.a_slot = s;
				e.b_slot = -1;
				e.grid_ref = idx;
				e.axis = 1;   // bottom face: d̂ = −ŷ
				e.sign = -1;
				e.k_st = (float)MAX(kappa, KAPPA_FLOOR);
				e.k_cap = (float)kappa;
				elems.push_back(e);
			}
		}

		// ── Block-Jacobi preconditioner: exact 6×6 diagonal blocks of K ──
		// Per endpoint of an element along axis ax with uθ-coupling sign
		// c_e = (endpoint == a ? −1 : +1)·½s:
		//   uu:  K_f = diag(k_n at ax, k_s perp)
		//   uθ:  c_e·K_f·C   (C = cross(ê_ax); couples u_i1↔θ_i2, u_i2↔θ_i1)
		//   θθ:  diag(k_t at ax, k_b + ¼k_s perp)
		// The scalar-diagonal version ignored the uθ coupling, which is what
		// made CG crawl (1400+ iters) on house-scale structures.
		jinv_v.resize(n_active * 36);
		double *binv = jinv_v.ptr();
		memset(binv, 0, n_active * 36 * sizeof(double));
		for (uint32_t j = 0; j < elems.size(); j++) {
			const GravityStressElem &e = elems[j];
			const int ax = e.axis;
			const int i1 = (ax + 1) % 3, i2 = (ax + 2) % 3;
			const double ks = e.k_st;
			const double f_n = ks * K_N;
			const double f_s = ks * K_S;
			const double t_ax = ks * K_T;
			const double t_perp = ks * (K_B + 0.25 * K_S);
			const int sides[2] = { e.a_slot, e.b_slot };
			for (int sd = 0; sd < 2; sd++) {
				if (sides[sd] < 0) {
					continue;
				}
				double *B = binv + sides[sd] * 36;
				B[ax * 6 + ax] += f_n;
				B[i1 * 6 + i1] += f_s;
				B[i2 * 6 + i2] += f_s;
				B[(3 + ax) * 6 + (3 + ax)] += t_ax;
				B[(3 + i1) * 6 + (3 + i1)] += t_perp;
				B[(3 + i2) * 6 + (3 + i2)] += t_perp;
				// uθ coupling: c_e·K_f·C has [i1][i2] = −c_e·k_s, [i2][i1] = +c_e·k_s.
				const double c_e = (sd == 0 ? -0.5 : 0.5) * (double)e.sign;
				const double v = c_e * f_s;
				B[i1 * 6 + (3 + i2)] += -v;
				B[i2 * 6 + (3 + i1)] += v;
				B[(3 + i2) * 6 + i1] += -v;
				B[(3 + i1) * 6 + i2] += v;
			}
		}
		for (int s = 0; s < n_active; s++) {
			double *B = binv + s * 36;
			if (!_gs_invert6(B)) {
				// Degenerate block (shouldn't happen — every active block has
				// ≥1 element): fall back to identity-scaled diagonal.
				memset(B, 0, 36 * sizeof(double));
				for (int i = 0; i < 6; i++) {
					B[i * 6 + i] = 1.0;
				}
			}
		}

		// ── CSR incident-element table for the threaded matvec ──
		// OPT-IN ONLY ("threaded_matvec" param): group-task dispatch per CG
		// iteration measured as a wash at 17k blocks, and the game runs
		// solves on a dedicated thread — spraying nested group tasks into the
		// shared WorkerThreadPool from there starves Jolt physics jobs and
		// terrain chunk meshing (micro-stutter + map holes).
		const bool allow_threaded = p_params.has("threaded_matvec") && (bool)p_params["threaded_matvec"];
		const bool use_threaded_matvec = allow_threaded && n_dof >= 24000;
		LocalVector<int> inc_offsets;
		LocalVector<uint32_t> inc_entries;
		if (use_threaded_matvec) {
			inc_offsets.resize(n_active + 1);
			for (int i = 0; i <= n_active; i++) {
				inc_offsets[i] = 0;
			}
			for (uint32_t j = 0; j < elems.size(); j++) {
				inc_offsets[elems[j].a_slot + 1]++;
				if (elems[j].b_slot >= 0) {
					inc_offsets[elems[j].b_slot + 1]++;
				}
			}
			for (int i = 0; i < n_active; i++) {
				inc_offsets[i + 1] += inc_offsets[i];
			}
			inc_entries.resize(inc_offsets[n_active]);
			LocalVector<int> cursor;
			cursor.resize(n_active);
			for (int i = 0; i < n_active; i++) {
				cursor[i] = inc_offsets[i];
			}
			for (uint32_t j = 0; j < elems.size(); j++) {
				inc_entries[cursor[elems[j].a_slot]++] = j;
				if (elems[j].b_slot >= 0) {
					inc_entries[cursor[elems[j].b_slot]++] = j | 0x80000000u;
				}
			}
		}

		// Optional K-symmetry self check (deterministic LCG vectors). A sign
		// error in the matvec breaks symmetry, which silently wrecks CG — this
		// is the canary for exactly that class of bug.
		if (check_symmetry && pass == 0) {
			LocalVector<double> u_v, v_v, ku_v, kv_v;
			u_v.resize(n_dof); v_v.resize(n_dof);
			ku_v.resize(n_dof); kv_v.resize(n_dof);
			uint64_t lcg = 0x9E3779B97F4A7C15ULL;
			for (int i = 0; i < n_dof; i++) {
				lcg = lcg * 6364136223846793005ULL + 1442695040888963407ULL;
				u_v[i] = (double)((lcg >> 33) & 0xFFFF) / 65536.0 - 0.5;
				lcg = lcg * 6364136223846793005ULL + 1442695040888963407ULL;
				v_v[i] = (double)((lcg >> 33) & 0xFFFF) / 65536.0 - 0.5;
			}
			_gs_matvec(elems, u_v.ptr(), ku_v.ptr(), n_dof, K_N, K_S, K_B, K_T);
			_gs_matvec(elems, v_v.ptr(), kv_v.ptr(), n_dof, K_N, K_S, K_B, K_T);
			double uKv = 0.0, vKu = 0.0;
			for (int i = 0; i < n_dof; i++) {
				uKv += u_v[i] * kv_v[i];
				vKu += v_v[i] * ku_v[i];
			}
			sym_err = Math::abs(uKv - vKu) / MAX(Math::abs(uKv), 1e-12);
		}

		// ── Preconditioned conjugate gradient on K x = f_gravity ──
		x_v.resize(n_dof); r_v.resize(n_dof); z_v.resize(n_dof);
		p_v.resize(n_dof); ap_v.resize(n_dof);
		double *x = x_v.ptr(), *r = r_v.ptr(), *z = z_v.ptr();
		double *pv = p_v.ptr(), *ap = ap_v.ptr();
		double fnorm2 = 0.0;
		for (int s = 0; s < n_active; s++) {
			double *xr = x + s * 6;
			double *rr = r + s * 6;
			for (int i = 0; i < 3; i++) {
				xr[i] = 0.0; xr[3 + i] = 0.0;
				rr[i] = g_arr[i];        // unit weight per block
				rr[3 + i] = 0.0;         // gravity acts at the center: no torque
				fnorm2 += rr[i] * rr[i];
			}
		}
		// Block-precondition apply: z_s = B_s⁻¹ r_s.
		auto apply_precond = [&](const double *rin, double *zout) {
			for (int s = 0; s < n_active; s++) {
				const double *B = binv + s * 36;
				const double *rs = rin + s * 6;
				double *zs = zout + s * 6;
				for (int row = 0; row < 6; row++) {
					const double *Br = B + row * 6;
					zs[row] = Br[0] * rs[0] + Br[1] * rs[1] + Br[2] * rs[2] +
							Br[3] * rs[3] + Br[4] * rs[4] + Br[5] * rs[5];
				}
			}
		};

		GsMatvecCtx mv_ctx;
		mv_ctx.elems = elems.ptr();
		mv_ctx.inc_offsets = use_threaded_matvec ? inc_offsets.ptr() : nullptr;
		mv_ctx.inc_entries = use_threaded_matvec ? inc_entries.ptr() : nullptr;
		mv_ctx.n_slots = n_active;
		mv_ctx.k_n = K_N;
		mv_ctx.k_s = K_S;
		mv_ctx.k_b = K_B;
		mv_ctx.k_t = K_T;
		int mv_chunks = 1;
		if (use_threaded_matvec) {
			const int threads = MAX(1, (int)WorkerThreadPool::get_singleton()->get_thread_count());
			mv_chunks = MIN(threads * 4, MAX(1, n_active / 512));
			mv_ctx.slots_per_chunk = (n_active + mv_chunks - 1) / mv_chunks;
		}
		auto run_matvec = [&](const double *xin, double *yout) {
			if (use_threaded_matvec && mv_chunks > 1) {
				mv_ctx.x = xin;
				mv_ctx.y = yout;
				WorkerThreadPool::GroupID g = WorkerThreadPool::get_singleton()->add_native_group_task(
						_gs_matvec_worker, &mv_ctx, mv_chunks, -1, false,
						String("gravity_matvec"));
				WorkerThreadPool::get_singleton()->wait_for_group_task_completion(g);
			} else {
				_gs_matvec(elems, xin, yout, n_dof, K_N, K_S, K_B, K_T);
			}
		};

		double rz = 0.0;
		apply_precond(r, z);
		for (int i = 0; i < n_dof; i++) {
			pv[i] = z[i];
			rz += r[i] * z[i];
		}
		const double tol2 = tol * tol * fnorm2;
		bool converged = false;
		int iter = 0;
		for (; iter < max_cg_iters; iter++) {
			run_matvec(pv, ap);
			double pap = 0.0;
			for (int i = 0; i < n_dof; i++) {
				pap += pv[i] * ap[i];
			}
			if (pap <= 0.0) {
				break; // SPD violated — bail with current iterate
			}
			const double alpha = rz / pap;
			double rr2 = 0.0;
			for (int i = 0; i < n_dof; i++) {
				x[i] += alpha * pv[i];
				r[i] -= alpha * ap[i];
				rr2 += r[i] * r[i];
			}
			if (rr2 <= tol2) {
				converged = true;
				iter++;
				break;
			}
			apply_precond(r, z);
			double rz_new = 0.0;
			for (int i = 0; i < n_dof; i++) {
				rz_new += r[i] * z[i];
			}
			const double beta = rz_new / rz;
			rz = rz_new;
			for (int i = 0; i < n_dof; i++) {
				pv[i] = z[i] + beta * pv[i];
			}
		}
		total_cg_iters += iter;
		if (!converged) {
			all_converged = false;
		}
		passes = pass + 1;

		// ── Recover interface loads, evaluate failure criteria, break ──
		int broke_this_pass = 0;
		double F[3], M[3], d_ax;
		max_util = 0.0;
		int worst_ref = -1;
		bool worst_is_anchor = false;
		double worst_fn = 0.0, worst_fs = 0.0, worst_mb = 0.0, worst_mt = 0.0;
		double worst_kcap = 0.0, worst_kst = 0.0;
		for (uint32_t j = 0; j < elems.size(); j++) {
			const GravityStressElem &e = elems[j];
			const double *xa = x + e.a_slot * 6;
			const double *xb = (e.b_slot >= 0) ? x + e.b_slot * 6 : nullptr;
			_gs_elem_wrench(e, xa, xb, K_N, K_S, K_B, K_T, F, M, &d_ax);
			const int ax = e.axis;
			const int i1 = (ax + 1) % 3, i2 = (ax + 2) % 3;
			const double f_n = (double)e.sign * F[ax]; // tension positive
			const double f_s = Math::sqrt(F[i1] * F[i1] + F[i2] * F[i2]);
			const double m_b = Math::sqrt(M[i1] * M[i1] + M[i2] * M[i2]);
			const double m_t = Math::abs(M[ax]);
			const double cap_scale = (double)e.k_cap * (e.b_slot < 0 ? anchor_factor : 1.0);
			double U;
			if (cap_scale < 1e-6) {
				const double load = Math::abs(f_n) + f_s + m_b + m_t;
				U = (load > 1e-9) ? 1e9 : 0.0;
			} else {
				const double u_t = (MAX(f_n, 0.0) + BEND_EDGE * m_b) / (cap_scale * T0);
				const double u_c = (MAX(-f_n, 0.0) + BEND_EDGE * m_b) / (cap_scale * C0);
				const double u_s = (f_s + TORS_EDGE * m_t) / (cap_scale * S0);
				U = MAX(u_t, MAX(u_c, u_s));
			}
			if (U > max_util) {
				max_util = U;
				worst_ref = e.grid_ref;
				worst_is_anchor = e.b_slot < 0;
				worst_fn = f_n;
				worst_fs = f_s;
				worst_mb = m_b;
				worst_mt = m_t;
				worst_kcap = e.k_cap;
				worst_kst = e.k_st;
			}
			if (U > 1.0) {
				if (e.b_slot < 0) {
					anchor_broken_w[e.grid_ref] = 1;
					broke_anchors++;
				} else {
					bond_broken_w[e.grid_ref] = 1;
					broke_bonds++;
				}
				broke_this_pass++;
			}
		}
		if (debug_pass_stats) {
			Dictionary ps;
			ps["pass"] = pass;
			ps["n_active"] = n_active;
			ps["n_elems"] = (int)elems.size();
			ps["cg_iters"] = iter;
			ps["converged"] = converged;
			ps["max_u"] = max_util;
			ps["broke"] = broke_this_pass;
			ps["worst_ref"] = worst_ref;
			ps["worst_is_anchor"] = worst_is_anchor;
			ps["worst_fn"] = worst_fn;
			ps["worst_fs"] = worst_fs;
			ps["worst_mb"] = worst_mb;
			ps["worst_mt"] = worst_mt;
			ps["worst_kcap"] = worst_kcap;
			ps["worst_kst"] = worst_kst;
			pass_stats.push_back(ps);
		}
		if (broke_this_pass == 0) {
			break; // stable — crack propagation finished
		}
	}

	memfree(slot_of);
	memfree(active);
	memfree(visited);
	memfree(bfs_queue);

	uint64_t t_end = OS::get_singleton()->get_ticks_usec();
	if (s_stress_debug_print) {
		print_line(vformat("[GravityStress] passes=%d cg_iters=%d broke_bonds=%d broke_anchors=%d maxU=%.3f converged=%s total=%dus",
				passes, total_cg_iters, broke_bonds, broke_anchors, max_util,
				all_converged ? "yes" : "no", (int)(t_end - t_start)));
	}

	out["bond_broken"] = bond_broken;
	out["anchor_broken"] = anchor_broken;
	out["broke_bonds"] = broke_bonds;
	out["broke_anchors"] = broke_anchors;
	out["max_utilization"] = (float)max_util;
	out["passes"] = passes;
	out["cg_iters"] = total_cg_iters;
	out["converged"] = all_converged;
	out["solve_us"] = (int)(t_end - t_start);
	if (check_symmetry) {
		out["symmetry_error"] = (float)sym_err;
	}
	if (debug_pass_stats) {
		out["pass_stats"] = pass_stats;
	}
	return out;
}


// ── Smooth collision rebuild via greedy box decomposition ──
//
// For each contiguous filled cuboid in the block grid, emit one BoxShape.
// Solid wall column = 1 box. Hollow tower = ~6-12 boxes. Replaces the GDScript
// triple-nested loop that was running 8-11ms per call on 4000-block structures.
//
// PhysicsServer3D body_add_shape / shape_set_data calls dominated the GDScript
// version (one binding per shape). The C++ port batches them through the
// server pointer directly with no Variant marshaling.
Array BlockMeshBuilder::rebuild_smooth_collision_box_shapes(
		const RID &p_body,
		const PackedByteArray &p_block_grid,
		int p_num_x, int p_num_y, int p_num_z,
		float p_block_size,
		const Array &p_old_shape_rids) {

	PhysicsServer3D *ps = PhysicsServer3D::get_singleton();
	ERR_FAIL_NULL_V(ps, Array());

	const int grid_size = p_num_x * p_num_y * p_num_z;
	ERR_FAIL_COND_V_MSG(p_block_grid.size() != grid_size, Array(),
			"rebuild_smooth_collision_box_shapes: block_grid size mismatch");

	// Wrap shape changes in bulk mode so the broadphase doesn't update once
	// per shape — single rebroadphase at the end of the function.
	ps->body_set_shapes_bulk_mode(p_body, true);

	// Free old shapes and clear the body's shape list before rebuilding.
	ps->body_clear_shapes(p_body);
	for (int i = 0; i < p_old_shape_rids.size(); i++) {
		RID old_rid = p_old_shape_rids[i];
		if (old_rid.is_valid()) {
			ps->free_rid(old_rid);
		}
	}

	const int ny_nz = p_num_y * p_num_z;
	const float bs = p_block_size;
	const float half_x = p_num_x * 0.5f;
	const float half_y = p_num_y * 0.5f;
	const float half_z = p_num_z * 0.5f;

	uint8_t *claimed = (uint8_t *)memalloc(grid_size);
	memset(claimed, 0, grid_size);
	const uint8_t *grid = p_block_grid.ptr();

	Array new_rids;

	for (int bx0 = 0; bx0 < p_num_x; bx0++) {
		for (int by0 = 0; by0 < p_num_y; by0++) {
			for (int bz0 = 0; bz0 < p_num_z; bz0++) {
				const int idx0 = bx0 * ny_nz + by0 * p_num_z + bz0;
				if (grid[idx0] == 0 || claimed[idx0] != 0) {
					continue;
				}

				// Greedy extend +X.
				int bx1 = bx0;
				while (bx1 + 1 < p_num_x) {
					int ni = (bx1 + 1) * ny_nz + by0 * p_num_z + bz0;
					if (grid[ni] == 0 || claimed[ni] != 0) break;
					bx1++;
				}

				// Greedy extend +Y (entire X-row must remain solid & unclaimed).
				int by1 = by0;
				while (by1 + 1 < p_num_y) {
					bool ok = true;
					for (int bx = bx0; bx <= bx1; bx++) {
						int ni = bx * ny_nz + (by1 + 1) * p_num_z + bz0;
						if (grid[ni] == 0 || claimed[ni] != 0) { ok = false; break; }
					}
					if (!ok) break;
					by1++;
				}

				// Greedy extend +Z (entire XY-slab must remain solid & unclaimed).
				int bz1 = bz0;
				while (bz1 + 1 < p_num_z) {
					bool ok = true;
					for (int bx = bx0; bx <= bx1 && ok; bx++) {
						for (int by = by0; by <= by1; by++) {
							int ni = bx * ny_nz + by * p_num_z + (bz1 + 1);
							if (grid[ni] == 0 || claimed[ni] != 0) { ok = false; break; }
						}
					}
					if (!ok) break;
					bz1++;
				}

				// Mark the cuboid claimed.
				for (int bx = bx0; bx <= bx1; bx++) {
					for (int by = by0; by <= by1; by++) {
						for (int bz = bz0; bz <= bz1; bz++) {
							claimed[bx * ny_nz + by * p_num_z + bz] = 1;
						}
					}
				}

				// Emit one BoxShape primitive at the cuboid center.
				const float size_x = (bx1 - bx0 + 1) * bs;
				const float size_y = (by1 - by0 + 1) * bs;
				const float size_z = (bz1 - bz0 + 1) * bs;
				const Vector3 origin(
						(bx0 + (bx1 - bx0 + 1) * 0.5f - half_x) * bs,
						(by0 + (by1 - by0 + 1) * 0.5f - half_y) * bs,
						(bz0 + (bz1 - bz0 + 1) * 0.5f - half_z) * bs);

				RID shape_rid = ps->box_shape_create();
				ps->shape_set_data(shape_rid, Vector3(size_x, size_y, size_z) * 0.5f);
				ps->body_add_shape(p_body, shape_rid, Transform3D(Basis(), origin));
				new_rids.push_back(shape_rid);
			}
		}
	}

	// Commit the new shape list in one broadphase update.
	ps->body_set_shapes_bulk_mode(p_body, false);

	memfree(claimed);
	return new_rids;
}


// ── Bulk fragment body creation ──
//
// Single C++ call creates N fragment bodies, sized + configured + parked
// off-world. Replaces a GDScript loop that paid GDScript→C++ marshaling
// overhead on ~10 PhysicsServer3D calls per body. For pool growth (where N
// can be hundreds), that loop was the dominant frame-time cost.
Array BlockMeshBuilder::bulk_create_fragment_bodies(
		int p_count,
		const RID &p_space,
		const RID &p_shape,
		int p_collision_layer,
		int p_collision_mask,
		float p_mass,
		float p_gravity_scale,
		bool p_kinematic) {

	PhysicsServer3D *ps = PhysicsServer3D::get_singleton();
	ERR_FAIL_NULL_V(ps, Array());
	ERR_FAIL_COND_V(p_count <= 0, Array());
	ERR_FAIL_COND_V_MSG(!p_space.is_valid(), Array(),
			"bulk_create_fragment_bodies: space RID invalid (no World3D yet?)");

	const PhysicsServer3D::BodyMode mode = p_kinematic
			? PhysicsServer3D::BODY_MODE_KINEMATIC
			: PhysicsServer3D::BODY_MODE_RIGID;

	uint64_t t_start = OS::get_singleton()->get_ticks_usec();

	// Park bodies WITHOUT collision layer/mask so they don't generate
	// broadphase pairs while idle. With 5000 fragments stacked at one
	// parking spot, Jolt's body-pair cache (default 65k) overflows
	// instantly and the game crashes. Setting layer/mask to 0 makes the
	// body "exist but ignore everything"; on acquire(), the GDScript side
	// sets the real layer/mask back.
	const Transform3D hidden_xform(Basis(), Vector3(0.0f, -100000.0f, 0.0f));

	Array rids;
	rids.resize(p_count);
	for (int i = 0; i < p_count; i++) {
		RID body = ps->body_create();
		ps->body_set_mode(body, mode);
		ps->body_set_space(body, p_space);
		ps->body_add_shape(body, p_shape, Transform3D());
		// Layer/mask = 0: parked body has no broadphase membership.
		// acquire() promotes them to the real layer/mask.
		ps->body_set_collision_layer(body, 0);
		ps->body_set_collision_mask(body, 0);
		ps->body_set_param(body, PhysicsServer3D::BODY_PARAM_MASS, p_mass);
		ps->body_set_param(body, PhysicsServer3D::BODY_PARAM_GRAVITY_SCALE, p_gravity_scale);
		// Server (RIGID) bodies sleep so the broadphase doesn't track them
		// while parked. Client (KINEMATIC) bodies don't auto-sleep.
		ps->body_set_state(body, PhysicsServer3D::BODY_STATE_CAN_SLEEP, !p_kinematic);
		ps->body_set_state(body, PhysicsServer3D::BODY_STATE_SLEEPING, true);
		ps->body_set_state(body, PhysicsServer3D::BODY_STATE_TRANSFORM, hidden_xform);
		rids[i] = body;
	}
	// Suppress unused-arg warnings for the layer/mask we deliberately ignore at
	// creation (set later by acquire()).
	(void)p_collision_layer;
	(void)p_collision_mask;
	uint64_t t_end = OS::get_singleton()->get_ticks_usec();
	print_line(vformat("[FragmentBulkCreate] count=%d  total=%dus  per_body=%.1fus",
			p_count, (int)(t_end - t_start),
			float(t_end - t_start) / float(p_count)));
	return rids;
}


// ── Force-equilibrium structural stress solver ──
//
// Physics model: each block is a rigid body subject to gravity. Adjacent blocks
// share a contact face that can transmit compression, tension, and shear forces,
// each bounded by material strength limits. Grounded blocks (marked in
// p_ground_mask) provide unlimited reaction forces — they're resting on terrain.
//
// The solver finds the force distribution satisfying Newton's first law
// (sum of forces = 0) at every block. It uses iterative Gauss-Seidel
// relaxation: each block distributes its unresolved force to its contacts,
// preferring contacts aligned with the force direction (so gravity naturally
// flows downward through compression before resorting to shear/tension).
//
// If a block's contacts cannot absorb its load (all at capacity), the block
// fails. Failed blocks can't support neighbors, triggering cascading collapse.
// Failed + disconnected blocks are grouped into components for detachment.

Array BlockMeshBuilder::calc_stress_integrity_components(
		const PackedByteArray &p_block_grid,
		const PackedByteArray &p_ground_mask,
		const PackedFloat32Array &p_external_load,
		int p_num_x, int p_num_y, int p_num_z,
		int p_total_blocks,
		float p_max_load,
		float p_horizontal_transfer) {
	const int grid_size = p_num_x * p_num_y * p_num_z;
	ERR_FAIL_COND_V_MSG(p_block_grid.size() != grid_size, Array(),
			"calc_stress_integrity_components: grid size mismatch");
	ERR_FAIL_COND_V(p_total_blocks <= 0, Array());

	// Ground mask: if provided, use it. Otherwise fall back to y=0.
	const bool has_ground_mask = p_ground_mask.size() == grid_size;
	const uint8_t *ground_mask = has_ground_mask ? p_ground_mask.ptr() : nullptr;

	// External load: extra downward force per block in block-weights.
	const bool has_external_load = p_external_load.size() == grid_size;
	const float *external_load = has_external_load ? p_external_load.ptr() : nullptr;

	uint64_t t_start = OS::get_singleton()->get_ticks_usec();

	const uint8_t *grid = p_block_grid.ptr();
	const int nx = p_num_x;
	const int ny = p_num_y;
	const int nz = p_num_z;
	const int ny_nz = ny * nz;

	// Material limits (in units of block-weight).
	// p_max_load: how many blocks of weight a single face can bear in compression.
	// Tension and shear are fractions of compressive strength (realistic for most materials).
	const float compressive_limit = p_max_load;
	const float tensile_limit = p_max_load * 0.3f;  // ~30% of compressive (concrete/stone)
	const float shear_limit = p_max_load * 0.4f;     // ~40% of compressive

	// Horizontal transfer: how readily load spreads sideways (0 = vertical only, 1 = full).
	const float h_transfer = CLAMP(p_horizontal_transfer, 0.0f, 1.0f);

	// ── Phase 1: Ground BFS — seed from terrain-contacting blocks ──
	// Marks all blocks reachable from grounded blocks as ground-connected.
	uint8_t *visited = (uint8_t *)memalloc(grid_size);
	memset(visited, 0, grid_size);

	// is_ground[idx]: true if this block is a fixed anchor (terrain contact).
	uint8_t *is_ground = (uint8_t *)memalloc(grid_size);
	memset(is_ground, 0, grid_size);

	int *bfs_queue = (int *)memalloc(p_total_blocks * sizeof(int));
	int head = 0, tail = 0;

	if (has_ground_mask) {
		// Seed from ground_mask: any occupied block marked as grounded.
		for (int idx = 0; idx < grid_size; idx++) {
			if (grid[idx] == 1 && ground_mask[idx] == 1) {
				visited[idx] = 1;
				is_ground[idx] = 1;
				bfs_queue[tail++] = idx;
			}
		}
	} else {
		// Fallback: y=0 blocks are ground (legacy behavior).
		for (int bx = 0; bx < nx; bx++) {
			int base = bx * ny_nz;
			for (int bz = 0; bz < nz; bz++) {
				int idx = base + bz; // y=0
				if (grid[idx] == 1) {
					visited[idx] = 1;
					is_ground[idx] = 1;
					bfs_queue[tail++] = idx;
				}
			}
		}
	}

	int visited_count = tail;
	while (head < tail) {
		if (visited_count == p_total_blocks) break;
		const int ci = bfs_queue[head++];
		const int bx = ci / ny_nz;
		const int rem = ci % ny_nz;
		const int by = rem / nz;
		const int bz = rem % nz;

		// 6-neighbor BFS
		if (bx + 1 < nx) { int ni = ci + ny_nz;  if (grid[ni] == 1 && !visited[ni]) { visited[ni] = 1; bfs_queue[tail++] = ni; visited_count++; } }
		if (bx > 0)      { int ni = ci - ny_nz;  if (grid[ni] == 1 && !visited[ni]) { visited[ni] = 1; bfs_queue[tail++] = ni; visited_count++; } }
		if (by + 1 < ny)  { int ni = ci + nz;     if (grid[ni] == 1 && !visited[ni]) { visited[ni] = 1; bfs_queue[tail++] = ni; visited_count++; } }
		if (by > 0)       { int ni = ci - nz;     if (grid[ni] == 1 && !visited[ni]) { visited[ni] = 1; bfs_queue[tail++] = ni; visited_count++; } }
		if (bz + 1 < nz)  { int ni = ci + 1;      if (grid[ni] == 1 && !visited[ni]) { visited[ni] = 1; bfs_queue[tail++] = ni; visited_count++; } }
		if (bz > 0)       { int ni = ci - 1;      if (grid[ni] == 1 && !visited[ni]) { visited[ni] = 1; bfs_queue[tail++] = ni; visited_count++; } }
	}

	uint64_t t_bfs = OS::get_singleton()->get_ticks_usec();

	// Blocks not reached by ground-BFS are already unsupported (disconnected).
	// The stress solver only runs on ground-connected blocks to find overloaded ones.

	// ── Phase 2: Force equilibrium solver on ground-connected blocks ──
	//
	// Each block has a residual force vector (initially gravity = (0, -1, 0) in
	// block-weight units). The solver iteratively distributes each block's residual
	// to its contacts. Ground blocks absorb unlimited force. Contacts have limits.
	//
	// Contact force decomposition per face:
	//   Face normal n (unit vector from block toward neighbor).
	//   Force F applied at contact, decomposed into:
	//     F_n = dot(F, n) * n   — normal component (compression if positive, tension if negative)
	//     F_t = F - F_n          — tangential component (shear)

	// Per-block residual force (3 floats: x, y, z).
	float *residual = (float *)memalloc(grid_size * 3 * sizeof(float));
	memset(residual, 0, grid_size * 3 * sizeof(float));

	// Per-contact accumulated force magnitude for limit checking.
	// 6 contacts per cell (±X, ±Y, ±Z). Store positive-direction contacts only
	// (each contact is stored once, on the lower-index block's side).
	// Contact indexing: for direction d (0-5), contact lives on the block with
	// the lower flat index. We track compression and shear usage per contact.
	// To keep it simple: per-block, per-direction, track how much of the limit is used.
	float *contact_compression = (float *)memalloc(grid_size * 6 * sizeof(float));
	float *contact_shear = (float *)memalloc(grid_size * 6 * sizeof(float));
	memset(contact_compression, 0, grid_size * 6 * sizeof(float));
	memset(contact_shear, 0, grid_size * 6 * sizeof(float));

	// failed[idx] = 1 if block has been marked as stress-failed.
	uint8_t *failed = (uint8_t *)memalloc(grid_size);
	memset(failed, 0, grid_size);

	// Initialize residual: gravity + external load on non-ground blocks.
	// Ground blocks (terrain-contacting) have zero residual (anchored).
	for (int idx = 0; idx < grid_size; idx++) {
		if (grid[idx] != 1 || visited[idx] != 1) continue;
		if (!is_ground[idx]) {
			float load = -1.0f; // self-weight: 1 block-weight downward
			if (has_external_load) {
				load -= external_load[idx]; // extra downward force
			}
			residual[idx * 3 + 1] = load;
		}
	}

	// Neighbor direction table: +X, -X, +Y, -Y, +Z, -Z
	// Normal vectors (from block toward neighbor):
	const float dir_normals[6][3] = {
		{ 1, 0, 0}, {-1, 0, 0}, { 0, 1, 0}, { 0,-1, 0}, { 0, 0, 1}, { 0, 0,-1}
	};
	const int dir_offsets[6] = { ny_nz, -ny_nz, nz, -nz, 1, -1 };

	// Process order: build a list of ground-connected non-ground blocks sorted
	// bottom-to-top (by Y) for faster convergence — load flows downward first.
	int *process_order = (int *)memalloc(p_total_blocks * sizeof(int));
	int process_count = 0;
	for (int by = 0; by < ny; by++) {
		for (int bx = 0; bx < nx; bx++) {
			for (int bz = 0; bz < nz; bz++) {
				int idx = bx * ny_nz + by * nz + bz;
				if (grid[idx] == 1 && visited[idx] == 1 && !is_ground[idx]) {
					process_order[process_count++] = idx;
				}
			}
		}
	}

	const int MAX_ITERATIONS = 40;
	const float RESIDUAL_EPSILON = 0.01f; // below this, block is in equilibrium

	// Active set: blocks with significant residual. Converged blocks are
	// deactivated, reactivated only if a neighbor transfers force to them.
	// This skips the majority of blocks in later iterations.
	uint8_t *active = (uint8_t *)memalloc(grid_size);
	memset(active, 0, grid_size);
	for (int pi = 0; pi < process_count; pi++) {
		active[process_order[pi]] = 1;
	}

	int solver_iters = 0;

	for (int iter = 0; iter < MAX_ITERATIONS; iter++) {
		solver_iters = iter + 1;
		bool any_change = false;

		for (int pi = 0; pi < process_count; pi++) {
			const int idx = process_order[pi];
			if (failed[idx] || !active[idx]) continue;

			float rx = residual[idx * 3 + 0];
			float ry = residual[idx * 3 + 1];
			float rz = residual[idx * 3 + 2];
			float rmag = sqrtf(rx * rx + ry * ry + rz * rz);
			if (rmag < RESIDUAL_EPSILON) {
				active[idx] = 0;
				continue;
			}

			const int bx = idx / ny_nz;
			const int rem = idx % ny_nz;
			const int by = rem / nz;
			const int bz = rem % nz;

			// Compute alignment weight for each active contact.
			// Contacts aligned with the residual direction absorb more force.
			// This ensures gravity flows downward through compression first.
			float weights[6] = {};
			int neighbor_idx[6] = {};
			bool neighbor_valid[6] = {};
			float total_weight = 0.0f;
			int active_contacts = 0;

			for (int d = 0; d < 6; d++) {
				// Bounds check
				bool in_bounds = true;
				if (d == 0 && bx + 1 >= nx) in_bounds = false;
				if (d == 1 && bx <= 0)       in_bounds = false;
				if (d == 2 && by + 1 >= ny) in_bounds = false;
				if (d == 3 && by <= 0)       in_bounds = false;
				if (d == 4 && bz + 1 >= nz) in_bounds = false;
				if (d == 5 && bz <= 0)       in_bounds = false;

				if (!in_bounds) { neighbor_valid[d] = false; continue; }

				int ni = idx + dir_offsets[d];
				if (grid[ni] != 1 || failed[ni]) { neighbor_valid[d] = false; continue; }
				// Disconnected blocks can't be supports
				if (visited[ni] != 1) { neighbor_valid[d] = false; continue; }

				neighbor_idx[d] = ni;
				neighbor_valid[d] = true;
				active_contacts++;

				// Alignment: dot(residual_dir, face_normal)
				// Positive = residual points toward neighbor (compression transfer)
				float dot = (rx * dir_normals[d][0] + ry * dir_normals[d][1] + rz * dir_normals[d][2]) / rmag;

				// Vertical contacts (±Y) get full weight.
				// Horizontal contacts are scaled by h_transfer.
				bool is_vertical = (d == 2 || d == 3);
				float dir_scale = is_vertical ? 1.0f : h_transfer;

				// Weight = max(alignment, small_base) * direction_scale
				// The small base ensures even poorly-aligned contacts participate slightly.
				weights[d] = MAX(dot, 0.05f) * dir_scale;
				total_weight += weights[d];
			}

			if (active_contacts == 0) {
				// No contacts at all — block fails.
				failed[idx] = 1;
				residual[idx * 3 + 0] = 0.0f;
				residual[idx * 3 + 1] = 0.0f;
				residual[idx * 3 + 2] = 0.0f;
				any_change = true;
				continue;
			}

			if (total_weight < 1e-6f) total_weight = 1.0f;

			// Distribute residual to contacts, proportional to weight.
			float absorbed_x = 0.0f, absorbed_y = 0.0f, absorbed_z = 0.0f;

			for (int d = 0; d < 6; d++) {
				if (!neighbor_valid[d]) continue;
				float frac = weights[d] / total_weight;

				// Force this contact should carry (fraction of residual)
				float fx = rx * frac;
				float fy = ry * frac;
				float fz = rz * frac;

				// Decompose into normal and shear relative to face.
				float nx_d = dir_normals[d][0];
				float ny_d = dir_normals[d][1];
				float nz_d = dir_normals[d][2];
				float fn = fx * nx_d + fy * ny_d + fz * nz_d; // normal component (signed)
				float sx = fx - fn * nx_d;
				float sy = fy - fn * ny_d;
				float sz = fz - fn * nz_d;
				float shear_mag = sqrtf(sx * sx + sy * sy + sz * sz);

				// Clamp normal: positive = compression, negative = tension.
				float fn_clamped = fn;
				int ci = idx * 6 + d;
				if (fn > 0.0f) {
					float remaining = compressive_limit - contact_compression[ci];
					if (remaining < 0.0f) remaining = 0.0f;
					fn_clamped = MIN(fn, remaining);
				} else {
					float remaining = tensile_limit + contact_compression[ci]; // compression is positive, tension goes negative
					if (remaining < 0.0f) remaining = 0.0f;
					fn_clamped = MAX(fn, -remaining);
				}

				// Clamp shear.
				float shear_clamped = shear_mag;
				float shear_remaining = shear_limit - contact_shear[ci];
				if (shear_remaining < 0.0f) shear_remaining = 0.0f;
				shear_clamped = MIN(shear_mag, shear_remaining);

				// Reconstruct clamped force vector.
				float tfx = fn_clamped * nx_d;
				float tfy = fn_clamped * ny_d;
				float tfz = fn_clamped * nz_d;
				if (shear_mag > 1e-6f) {
					float shear_scale = shear_clamped / shear_mag;
					tfx += sx * shear_scale;
					tfy += sy * shear_scale;
					tfz += sz * shear_scale;
				}

				// Update contact force tracking.
				if (fn_clamped > 0.0f) {
					contact_compression[ci] += fn_clamped;
				} else {
					contact_compression[ci] += fn_clamped; // goes negative for tension
				}
				contact_shear[ci] += shear_clamped;

				absorbed_x += tfx;
				absorbed_y += tfy;
				absorbed_z += tfz;

				// Transfer to neighbor (Newton's 3rd law).
				int ni = neighbor_idx[d];
				if (!is_ground[ni]) {
					residual[ni * 3 + 0] += tfx;
					residual[ni * 3 + 1] += tfy;
					residual[ni * 3 + 2] += tfz;
					active[ni] = 1; // reactivate — received new force
				}
			}

			// Subtract absorbed force from residual.
			residual[idx * 3 + 0] -= absorbed_x;
			residual[idx * 3 + 1] -= absorbed_y;
			residual[idx * 3 + 2] -= absorbed_z;

			float new_rmag = sqrtf(
					residual[idx * 3 + 0] * residual[idx * 3 + 0] +
					residual[idx * 3 + 1] * residual[idx * 3 + 1] +
					residual[idx * 3 + 2] * residual[idx * 3 + 2]);

			if (new_rmag != rmag) any_change = true;

			// If residual is still large and we couldn't absorb enough, block may fail.
			// (We give it more iterations before declaring failure.)
		}

		if (!any_change) break;
	}

	// ── Phase 3: Mark stress-failed blocks ──
	// Blocks with significant unresolved residual after solver convergence have
	// no valid force distribution — they can't be held in equilibrium.
	int stress_failed = 0;
	for (int pi = 0; pi < process_count; pi++) {
		int idx = process_order[pi];
		if (failed[idx]) { stress_failed++; continue; }
		float rx = residual[idx * 3 + 0];
		float ry = residual[idx * 3 + 1];
		float rz = residual[idx * 3 + 2];
		float rmag = sqrtf(rx * rx + ry * ry + rz * rz);
		if (rmag > 0.5f) { // >50% of a block-weight unresolved
			failed[idx] = 1;
			visited[idx] = 0; // mark as unsupported for component phase
			stress_failed++;
		}
	}

	// Also unmark any block already disconnected from ground BFS.
	// (visited[idx] == 0 for disconnected blocks is already set.)
	// Propagate: blocks above a failed block that have no other support also fail.
	// Single upward pass: if a block's only downward neighbor is failed, it fails too.
	bool cascade = true;
	while (cascade) {
		cascade = false;
		for (int pi = process_count - 1; pi >= 0; pi--) { // top-down
			int idx = process_order[pi];
			if (failed[idx]) continue;

			int bx = idx / ny_nz;
			int rem = idx % ny_nz;
			int by = rem / nz;
			int bz = rem % nz;

			// Check: does this block have at least one non-failed support below or beside?
			bool has_support = false;
			for (int d = 0; d < 6; d++) {
				bool in_bounds = true;
				if (d == 0 && bx + 1 >= nx) in_bounds = false;
				if (d == 1 && bx <= 0)       in_bounds = false;
				if (d == 2 && by + 1 >= ny) in_bounds = false;
				if (d == 3 && by <= 0)       in_bounds = false;
				if (d == 4 && bz + 1 >= nz) in_bounds = false;
				if (d == 5 && bz <= 0)       in_bounds = false;
				if (!in_bounds) continue;

				int ni = idx + dir_offsets[d];
				if (grid[ni] == 1 && visited[ni] == 1 && !failed[ni]) {
					has_support = true;
					break;
				}
			}
			if (!has_support) {
				failed[idx] = 1;
				visited[idx] = 0;
				stress_failed++;
				cascade = true;
			}
		}
	}

	uint64_t t_solver = OS::get_singleton()->get_ticks_usec();

	// If no blocks failed (stress or disconnected), early exit.
	int total_unsupported = 0;
	for (int idx = 0; idx < grid_size; idx++) {
		if (grid[idx] == 1 && visited[idx] == 0) total_unsupported++;
	}
	// Also count stress-failed blocks that were previously visited
	for (int idx = 0; idx < grid_size; idx++) {
		if (grid[idx] == 1 && failed[idx] && visited[idx] == 1) {
			visited[idx] = 0;
			total_unsupported++;
		}
	}

	if (total_unsupported == 0) {
		memfree(visited); memfree(bfs_queue); memfree(residual);
		memfree(contact_compression); memfree(contact_shear);
		memfree(failed); memfree(process_order); memfree(is_ground); memfree(active);
		if (s_stress_debug_print) {
			print_line(vformat("[StressIntegrity_C] blocks=%d  all_stable  iters=%d  bfs=%dus  solver=%dus",
					p_total_blocks, solver_iters,
					(int)(t_bfs - t_start), (int)(t_solver - t_bfs)));
		}
		return Array();
	}

	// ── Phase 4: Component BFS on unsupported blocks (visited==0, grid==1) ──
	Array components;
	head = 0; tail = 0;

	for (int idx = 0; idx < grid_size; idx++) {
		if (grid[idx] != 1 || visited[idx] != 0) continue;

		head = 0; tail = 0;
		bfs_queue[tail++] = idx;
		visited[idx] = 2;

		while (head < tail) {
			const int ci = bfs_queue[head++];
			const int cbx = ci / ny_nz;
			const int crem = ci % ny_nz;
			const int cby = crem / nz;
			const int cbz = crem % nz;

			if (cbx + 1 < nx) { int ni = ci + ny_nz; if (grid[ni] == 1 && visited[ni] == 0) { visited[ni] = 2; bfs_queue[tail++] = ni; } }
			if (cbx > 0)      { int ni = ci - ny_nz; if (grid[ni] == 1 && visited[ni] == 0) { visited[ni] = 2; bfs_queue[tail++] = ni; } }
			if (cby + 1 < ny) { int ni = ci + nz;    if (grid[ni] == 1 && visited[ni] == 0) { visited[ni] = 2; bfs_queue[tail++] = ni; } }
			if (cby > 0)      { int ni = ci - nz;    if (grid[ni] == 1 && visited[ni] == 0) { visited[ni] = 2; bfs_queue[tail++] = ni; } }
			if (cbz + 1 < nz) { int ni = ci + 1;     if (grid[ni] == 1 && visited[ni] == 0) { visited[ni] = 2; bfs_queue[tail++] = ni; } }
			if (cbz > 0)      { int ni = ci - 1;     if (grid[ni] == 1 && visited[ni] == 0) { visited[ni] = 2; bfs_queue[tail++] = ni; } }
		}

		TypedArray<Vector3i> component;
		component.resize(tail);
		for (int j = 0; j < tail; j++) {
			const int cj = bfs_queue[j];
			component[j] = Vector3i(cj / ny_nz, (cj % ny_nz) / nz, cj % nz);
		}
		components.push_back(component);
	}

	memfree(visited); memfree(bfs_queue); memfree(residual);
	memfree(contact_compression); memfree(contact_shear);
	memfree(failed); memfree(process_order); memfree(is_ground);

	uint64_t t_end = OS::get_singleton()->get_ticks_usec();
	if (s_stress_debug_print) {
		print_line(vformat("[StressIntegrity_C] blocks=%d  stress_failed=%d  disconnected=%d  components=%d  iters=%d  bfs=%dus  solver=%dus  components=%dus  total=%dus",
				p_total_blocks, stress_failed, total_unsupported - stress_failed,
				components.size(), solver_iters,
				(int)(t_bfs - t_start), (int)(t_solver - t_bfs),
				(int)(t_end - t_solver), (int)(t_end - t_start)));
	}

	return components;
}

// ─────────────────────────────────────────────────────────────────────────────
// Localized stress solver
//
// The full solver above does a Gauss-Seidel force-equilibrium pass over the
// entire structure on every call, ignoring that most of the structure was
// already in equilibrium before the latest damage event. The localized variant
// keeps the steady-state contact stress field as persistent state and re-solves
// only the perturbation that propagates outward from blocks adjacent to the
// recently destroyed seeds.
//
// Far-from-damage blocks are already in equilibrium and stay in equilibrium
// (their incoming forces don't change), so they're never touched. The active
// set is bounded by the "shadow" cast by the destruction — typically much
// smaller than the full structure.
//
// Falls back to a full solve when persistent state is missing or stale.
// Always re-runs the Phase 3 cascade-up and Phase 4 component BFS, since
// those phases must see the global topology.
// ─────────────────────────────────────────────────────────────────────────────
Dictionary BlockMeshBuilder::calc_stress_integrity_localized(
		const PackedByteArray &p_block_grid,
		const PackedByteArray &p_ground_mask,
		const PackedFloat32Array &p_external_load,
		int p_num_x, int p_num_y, int p_num_z,
		int p_total_blocks,
		float p_max_load,
		float p_horizontal_transfer,
		const PackedInt32Array &p_dirty_seed_indices,
		const Dictionary &p_persistent_state) {
	const int grid_size = p_num_x * p_num_y * p_num_z;
	ERR_FAIL_COND_V_MSG(p_block_grid.size() != grid_size, Dictionary(),
			"calc_stress_integrity_localized: grid size mismatch");
	ERR_FAIL_COND_V(p_total_blocks <= 0, Dictionary());

	uint64_t t_start = OS::get_singleton()->get_ticks_usec();

	// ── Decide: localized path or full fallback ──
	// We need: prior persistent state with matching grid size and a non-empty
	// dirty seed set (otherwise nothing to do incrementally). Empty dirty set
	// could mean "no destruction happened" (caller misuse) — fall back to full
	// solve to be safe.
	bool need_full = false;
	const char *fallback_reason = nullptr;

	if (p_persistent_state.is_empty()) {
		need_full = true;
		fallback_reason = "no_persistent_state";
	} else {
		Variant v_count = p_persistent_state.get("last_block_count", Variant());
		if (v_count.get_type() != Variant::INT) {
			need_full = true;
			fallback_reason = "missing_last_block_count";
		} else if ((int)v_count != p_total_blocks + (int)p_dirty_seed_indices.size()) {
			// last_block_count should equal current_blocks + just_destroyed.
			// If it doesn't, persistent state is stale.
			need_full = true;
			fallback_reason = "stale_block_count";
		}
	}

	if (!need_full) {
		Variant v_cc = p_persistent_state.get("contact_compression", Variant());
		Variant v_cs = p_persistent_state.get("contact_shear", Variant());
		Variant v_cf = p_persistent_state.get("contact_force", Variant());
		Variant v_vis = p_persistent_state.get("visited", Variant());
		if (v_cc.get_type() != Variant::PACKED_FLOAT32_ARRAY ||
				v_cs.get_type() != Variant::PACKED_FLOAT32_ARRAY ||
				v_cf.get_type() != Variant::PACKED_FLOAT32_ARRAY ||
				v_vis.get_type() != Variant::PACKED_BYTE_ARRAY) {
			need_full = true;
			fallback_reason = "missing_state_arrays";
		} else {
			PackedFloat32Array cc = v_cc;
			PackedFloat32Array cs = v_cs;
			PackedFloat32Array cf = v_cf;
			PackedByteArray vis = v_vis;
			if (cc.size() != grid_size * 6 || cs.size() != grid_size * 6 ||
					cf.size() != grid_size * 18 ||
					vis.size() != grid_size) {
				need_full = true;
				fallback_reason = "state_array_size_mismatch";
			}
		}
	}

	if (p_dirty_seed_indices.is_empty() && !need_full) {
		// No new damage to propagate — nothing changed. Return empty components
		// with the persistent state passed through.
		Dictionary result;
		result["components"] = Array();
		result["persistent_state"] = p_persistent_state;
		result["used_full_resolve"] = false;
		result["active_set_size"] = 0;
		uint64_t t_end_noop = OS::get_singleton()->get_ticks_usec();
		if (s_stress_debug_print) {
			print_line(vformat("[StressIntegrity_L] blocks=%d  no-op (no dirty seeds)  total=%dus",
					p_total_blocks, (int)(t_end_noop - t_start)));
		}
		return result;
	}

	// ── Setup shared state arrays ──
	const uint8_t *grid = p_block_grid.ptr();
	const int nx = p_num_x;
	const int ny = p_num_y;
	const int nz = p_num_z;
	const int ny_nz = ny * nz;

	const bool has_ground_mask = p_ground_mask.size() == grid_size;
	const uint8_t *ground_mask = has_ground_mask ? p_ground_mask.ptr() : nullptr;
	const bool has_external_load = p_external_load.size() == grid_size;
	const float *external_load = has_external_load ? p_external_load.ptr() : nullptr;

	const float compressive_limit = p_max_load;
	const float tensile_limit = p_max_load * 0.3f;
	const float shear_limit = p_max_load * 0.4f;
	const float h_transfer = CLAMP(p_horizontal_transfer, 0.0f, 1.0f);

	const float dir_normals[6][3] = {
		{1, 0, 0}, {-1, 0, 0}, {0, 1, 0}, {0, -1, 0}, {0, 0, 1}, {0, 0, -1}
	};
	const int dir_offsets[6] = {ny_nz, -ny_nz, nz, -nz, 1, -1};
	const int opposite_dir[6] = {1, 0, 3, 2, 5, 4};

	// Allocate working arrays we always need.
	uint8_t *visited = (uint8_t *)memalloc(grid_size);
	uint8_t *is_ground = (uint8_t *)memalloc(grid_size);
	uint8_t *failed = (uint8_t *)memalloc(grid_size);
	uint8_t *active = (uint8_t *)memalloc(grid_size);
	int *bfs_queue = (int *)memalloc(p_total_blocks * sizeof(int));
	float *residual = (float *)memalloc(grid_size * 3 * sizeof(float));
	// Per-contact accumulated SCALAR magnitudes — used for compression/shear
	// limit clamping inside the solver. 6 directions per block.
	float *contact_compression = (float *)memalloc(grid_size * 6 * sizeof(float));
	float *contact_shear = (float *)memalloc(grid_size * 6 * sizeof(float));
	// Per-contact accumulated FORCE VECTORS — used for exact dirty-seed
	// residual restoration in the localized path. Indexed as
	// contact_force[idx * 18 + d * 3 + axis], where axis 0=X, 1=Y, 2=Z.
	// At equilibrium, this is the force `idx` is pushing through its `d` face
	// to its neighbor in that direction. Storing the full vector (rather than
	// just compression/shear scalars) is required because shear has a
	// direction that the scalars discard.
	float *contact_force = (float *)memalloc(grid_size * 18 * sizeof(float));

	memset(visited, 0, grid_size);
	memset(is_ground, 0, grid_size);
	memset(failed, 0, grid_size);
	memset(active, 0, grid_size);
	memset(residual, 0, grid_size * 3 * sizeof(float));
	memset(contact_compression, 0, grid_size * 6 * sizeof(float));
	memset(contact_shear, 0, grid_size * 6 * sizeof(float));
	memset(contact_force, 0, grid_size * 18 * sizeof(float));

	int peak_active = 0;

	// ── Path A: full solve (fallback) ──
	if (need_full) {
		// Run the same algorithm as calc_stress_integrity_components, but write
		// our state arrays so we can hand them back as persistent_state.
		// Phase 1: Ground BFS.
		int head = 0, tail = 0;
		if (has_ground_mask) {
			for (int idx = 0; idx < grid_size; idx++) {
				if (grid[idx] == 1 && ground_mask[idx] == 1) {
					visited[idx] = 1;
					is_ground[idx] = 1;
					bfs_queue[tail++] = idx;
				}
			}
		} else {
			for (int bx = 0; bx < nx; bx++) {
				int base = bx * ny_nz;
				for (int bz = 0; bz < nz; bz++) {
					int idx = base + bz; // y=0
					if (grid[idx] == 1) {
						visited[idx] = 1;
						is_ground[idx] = 1;
						bfs_queue[tail++] = idx;
					}
				}
			}
		}
		int visited_count = tail;
		while (head < tail) {
			if (visited_count == p_total_blocks) break;
			const int ci = bfs_queue[head++];
			const int bx = ci / ny_nz;
			const int rem = ci % ny_nz;
			const int by = rem / nz;
			const int bz = rem % nz;
			if (bx + 1 < nx) { int ni = ci + ny_nz;  if (grid[ni] == 1 && !visited[ni]) { visited[ni] = 1; bfs_queue[tail++] = ni; visited_count++; } }
			if (bx > 0)      { int ni = ci - ny_nz;  if (grid[ni] == 1 && !visited[ni]) { visited[ni] = 1; bfs_queue[tail++] = ni; visited_count++; } }
			if (by + 1 < ny) { int ni = ci + nz;     if (grid[ni] == 1 && !visited[ni]) { visited[ni] = 1; bfs_queue[tail++] = ni; visited_count++; } }
			if (by > 0)      { int ni = ci - nz;     if (grid[ni] == 1 && !visited[ni]) { visited[ni] = 1; bfs_queue[tail++] = ni; visited_count++; } }
			if (bz + 1 < nz) { int ni = ci + 1;      if (grid[ni] == 1 && !visited[ni]) { visited[ni] = 1; bfs_queue[tail++] = ni; visited_count++; } }
			if (bz > 0)      { int ni = ci - 1;      if (grid[ni] == 1 && !visited[ni]) { visited[ni] = 1; bfs_queue[tail++] = ni; visited_count++; } }
		}

		// Phase 2: initialize residual = gravity + external load.
		for (int idx = 0; idx < grid_size; idx++) {
			if (grid[idx] != 1 || visited[idx] != 1) continue;
			if (!is_ground[idx]) {
				float load = -1.0f;
				if (has_external_load) load -= external_load[idx];
				residual[idx * 3 + 1] = load;
				active[idx] = 1;
			}
		}
		int active_count = 0;
		for (int idx = 0; idx < grid_size; idx++) if (active[idx]) active_count++;
		peak_active = active_count;
	} else {
		// ── Path B: localized re-solve ──
		// Copy persistent state into our working arrays.
		PackedFloat32Array cc_in = p_persistent_state.get("contact_compression", Variant());
		PackedFloat32Array cs_in = p_persistent_state.get("contact_shear", Variant());
		PackedFloat32Array cf_in = p_persistent_state.get("contact_force", Variant());
		PackedByteArray vis_in = p_persistent_state.get("visited", Variant());
		memcpy(contact_compression, cc_in.ptr(), grid_size * 6 * sizeof(float));
		memcpy(contact_shear, cs_in.ptr(), grid_size * 6 * sizeof(float));
		memcpy(contact_force, cf_in.ptr(), grid_size * 18 * sizeof(float));
		memcpy(visited, vis_in.ptr(), grid_size);

		// Reconstruct is_ground from visited + ground_mask (or y=0 fallback).
		if (has_ground_mask) {
			for (int idx = 0; idx < grid_size; idx++) {
				if (grid[idx] == 1 && ground_mask[idx] == 1) {
					is_ground[idx] = 1;
				}
			}
		} else {
			for (int bx = 0; bx < nx; bx++) {
				int base = bx * ny_nz;
				for (int bz = 0; bz < nz; bz++) {
					int idx = base + bz;
					if (grid[idx] == 1) is_ground[idx] = 1;
				}
			}
		}

		// Re-run ground BFS over the (now reduced) grid. Some blocks marked
		// visited=1 in the persistent state may have lost their connection to
		// ground via the destruction. We need a fresh visited[] for correctness.
		memset(visited, 0, grid_size);
		int head = 0, tail = 0;
		for (int idx = 0; idx < grid_size; idx++) {
			if (is_ground[idx] && grid[idx] == 1) {
				visited[idx] = 1;
				bfs_queue[tail++] = idx;
			}
		}
		while (head < tail) {
			const int ci = bfs_queue[head++];
			const int bx = ci / ny_nz;
			const int rem = ci % ny_nz;
			const int by = rem / nz;
			const int bz = rem % nz;
			if (bx + 1 < nx) { int ni = ci + ny_nz;  if (grid[ni] == 1 && !visited[ni]) { visited[ni] = 1; bfs_queue[tail++] = ni; } }
			if (bx > 0)      { int ni = ci - ny_nz;  if (grid[ni] == 1 && !visited[ni]) { visited[ni] = 1; bfs_queue[tail++] = ni; } }
			if (by + 1 < ny) { int ni = ci + nz;     if (grid[ni] == 1 && !visited[ni]) { visited[ni] = 1; bfs_queue[tail++] = ni; } }
			if (by > 0)      { int ni = ci - nz;     if (grid[ni] == 1 && !visited[ni]) { visited[ni] = 1; bfs_queue[tail++] = ni; } }
			if (bz + 1 < nz) { int ni = ci + 1;      if (grid[ni] == 1 && !visited[ni]) { visited[ni] = 1; bfs_queue[tail++] = ni; } }
			if (bz > 0)      { int ni = ci - 1;      if (grid[ni] == 1 && !visited[ni]) { visited[ni] = 1; bfs_queue[tail++] = ni; } }
		}

		// Seed the residual from the dirty seeds.
		// For each destroyed block S, each surviving neighbor N had a contact
		// (N, opposite_dir) carrying force from S. That force is now unsupported
		// — apply it to N's residual so the solver redistributes.
		const int *seeds = p_dirty_seed_indices.ptr();
		for (int si = 0; si < p_dirty_seed_indices.size(); si++) {
			int s_idx = seeds[si];
			if (s_idx < 0 || s_idx >= grid_size) continue;

			int sbx = s_idx / ny_nz;
			int srem = s_idx % ny_nz;
			int sby = srem / nz;
			int sbz = srem % nz;

			for (int d = 0; d < 6; d++) {
				bool in_bounds = true;
				if (d == 0 && sbx + 1 >= nx) in_bounds = false;
				if (d == 1 && sbx <= 0)       in_bounds = false;
				if (d == 2 && sby + 1 >= ny) in_bounds = false;
				if (d == 3 && sby <= 0)       in_bounds = false;
				if (d == 4 && sbz + 1 >= nz) in_bounds = false;
				if (d == 5 && sbz <= 0)       in_bounds = false;
				if (!in_bounds) continue;

				int ni = s_idx + dir_offsets[d];
				if (grid[ni] != 1 || visited[ni] != 1) continue;

				// At equilibrium (the persistent state we received), S was
				// pushing a force vector through its `d` face into N. That
				// vector is stored in S's contact_force[s_idx*18 + d*3 + axis].
				//
				// Sign convention: contact_force[idx, d, .] is the force that
				// idx is transferring TO its neighbor in direction d (matches
				// how the inner solver writes it: `tf` is added to neighbor's
				// residual). So at equilibrium, N's residual gained S's
				// contact force every iteration; with S removed, N's incoming
				// flow stops.
				//
				// To compute N's new residual: the previous balance had
				// 0 = gravity_N + force_S_to_N + (other inflows) - sum(N's outflows)
				// After S vanishes, force_S_to_N drops to 0. To preserve
				// balance, we'd need outflows to drop by force_S_to_N too.
				// Until they do, N has new_residual = -force_S_to_N
				// (the missing contribution shows up as residual that the
				// solver will redistribute through N's remaining contacts).
				int s_force_base = s_idx * 18 + d * 3;
				float released_x = -contact_force[s_force_base + 0];
				float released_y = -contact_force[s_force_base + 1];
				float released_z = -contact_force[s_force_base + 2];

				residual[ni * 3 + 0] += released_x;
				residual[ni * 3 + 1] += released_y;
				residual[ni * 3 + 2] += released_z;
				active[ni] = 1;

				// Also clear N's accounting on its face toward S. N's
				// contact_compression / contact_shear / contact_force on the
				// (ni, opp) face is no longer valid — that face is gone.
				int opp = opposite_dir[d];
				int n_contact_idx = ni * 6 + opp;
				contact_compression[n_contact_idx] = 0.0f;
				contact_shear[n_contact_idx] = 0.0f;
				int n_force_base = ni * 18 + opp * 3;
				contact_force[n_force_base + 0] = 0.0f;
				contact_force[n_force_base + 1] = 0.0f;
				contact_force[n_force_base + 2] = 0.0f;
			}
		}

		// Count peak active.
		for (int idx = 0; idx < grid_size; idx++) if (active[idx]) peak_active++;

		// Catastrophic-event fallback: if active set is huge, just do full solve.
		if (peak_active > grid_size / 2) {
			// Reset to clean state and switch to full path.
			memset(visited, 0, grid_size);
			memset(is_ground, 0, grid_size);
			memset(active, 0, grid_size);
			memset(residual, 0, grid_size * 3 * sizeof(float));
			memset(contact_compression, 0, grid_size * 6 * sizeof(float));
			memset(contact_shear, 0, grid_size * 6 * sizeof(float));
			memset(contact_force, 0, grid_size * 18 * sizeof(float));
			need_full = true;
			fallback_reason = "active_set_too_large";
			peak_active = 0;

			// Rerun Phase 1 (ground BFS).
			head = 0; tail = 0;
			if (has_ground_mask) {
				for (int idx = 0; idx < grid_size; idx++) {
					if (grid[idx] == 1 && ground_mask[idx] == 1) {
						visited[idx] = 1;
						is_ground[idx] = 1;
						bfs_queue[tail++] = idx;
					}
				}
			} else {
				for (int bx = 0; bx < nx; bx++) {
					int base = bx * ny_nz;
					for (int bz = 0; bz < nz; bz++) {
						int idx = base + bz;
						if (grid[idx] == 1) {
							visited[idx] = 1;
							is_ground[idx] = 1;
							bfs_queue[tail++] = idx;
						}
					}
				}
			}
			int visited_count2 = tail;
			while (head < tail) {
				if (visited_count2 == p_total_blocks) break;
				const int ci = bfs_queue[head++];
				const int bx = ci / ny_nz;
				const int rem = ci % ny_nz;
				const int by = rem / nz;
				const int bz = rem % nz;
				if (bx + 1 < nx) { int ni = ci + ny_nz;  if (grid[ni] == 1 && !visited[ni]) { visited[ni] = 1; bfs_queue[tail++] = ni; visited_count2++; } }
				if (bx > 0)      { int ni = ci - ny_nz;  if (grid[ni] == 1 && !visited[ni]) { visited[ni] = 1; bfs_queue[tail++] = ni; visited_count2++; } }
				if (by + 1 < ny) { int ni = ci + nz;     if (grid[ni] == 1 && !visited[ni]) { visited[ni] = 1; bfs_queue[tail++] = ni; visited_count2++; } }
				if (by > 0)      { int ni = ci - nz;     if (grid[ni] == 1 && !visited[ni]) { visited[ni] = 1; bfs_queue[tail++] = ni; visited_count2++; } }
				if (bz + 1 < nz) { int ni = ci + 1;      if (grid[ni] == 1 && !visited[ni]) { visited[ni] = 1; bfs_queue[tail++] = ni; visited_count2++; } }
				if (bz > 0)      { int ni = ci - 1;      if (grid[ni] == 1 && !visited[ni]) { visited[ni] = 1; bfs_queue[tail++] = ni; visited_count2++; } }
			}
			for (int idx = 0; idx < grid_size; idx++) {
				if (grid[idx] != 1 || visited[idx] != 1) continue;
				if (!is_ground[idx]) {
					float load = -1.0f;
					if (has_external_load) load -= external_load[idx];
					residual[idx * 3 + 1] = load;
					active[idx] = 1;
					peak_active++;
				}
			}
		}
	}

	uint64_t t_setup = OS::get_singleton()->get_ticks_usec();

	// ── Phase 2: solver iterations (shared by full and localized paths) ──
	// Build process order — bottom-to-top by Y for faster convergence.
	int *process_order = (int *)memalloc(p_total_blocks * sizeof(int));
	int process_count = 0;
	for (int by = 0; by < ny; by++) {
		for (int bx = 0; bx < nx; bx++) {
			for (int bz = 0; bz < nz; bz++) {
				int idx = bx * ny_nz + by * nz + bz;
				if (grid[idx] == 1 && visited[idx] == 1 && !is_ground[idx]) {
					process_order[process_count++] = idx;
				}
			}
		}
	}

	const int MAX_ITERATIONS = 40;
	const float RESIDUAL_EPSILON = 0.01f;
	int solver_iters = 0;

	for (int iter = 0; iter < MAX_ITERATIONS; iter++) {
		solver_iters = iter + 1;
		bool any_change = false;

		for (int pi = 0; pi < process_count; pi++) {
			const int idx = process_order[pi];
			if (failed[idx] || !active[idx]) continue;

			float rx = residual[idx * 3 + 0];
			float ry = residual[idx * 3 + 1];
			float rz = residual[idx * 3 + 2];
			float rmag = sqrtf(rx * rx + ry * ry + rz * rz);
			if (rmag < RESIDUAL_EPSILON) {
				active[idx] = 0;
				continue;
			}

			const int bx = idx / ny_nz;
			const int rem = idx % ny_nz;
			const int by = rem / nz;
			const int bz = rem % nz;

			float weights[6] = {};
			int neighbor_idx[6] = {};
			bool neighbor_valid[6] = {};
			float total_weight = 0.0f;
			int active_contacts = 0;

			for (int d = 0; d < 6; d++) {
				bool in_bounds = true;
				if (d == 0 && bx + 1 >= nx) in_bounds = false;
				if (d == 1 && bx <= 0)       in_bounds = false;
				if (d == 2 && by + 1 >= ny) in_bounds = false;
				if (d == 3 && by <= 0)       in_bounds = false;
				if (d == 4 && bz + 1 >= nz) in_bounds = false;
				if (d == 5 && bz <= 0)       in_bounds = false;
				if (!in_bounds) { neighbor_valid[d] = false; continue; }

				int ni = idx + dir_offsets[d];
				if (grid[ni] != 1 || failed[ni]) { neighbor_valid[d] = false; continue; }
				if (visited[ni] != 1) { neighbor_valid[d] = false; continue; }

				neighbor_idx[d] = ni;
				neighbor_valid[d] = true;
				active_contacts++;

				float dot = (rx * dir_normals[d][0] + ry * dir_normals[d][1] + rz * dir_normals[d][2]) / rmag;
				bool is_vertical = (d == 2 || d == 3);
				float dir_scale = is_vertical ? 1.0f : h_transfer;
				weights[d] = MAX(dot, 0.05f) * dir_scale;
				total_weight += weights[d];
			}

			if (active_contacts == 0) {
				failed[idx] = 1;
				residual[idx * 3 + 0] = 0.0f;
				residual[idx * 3 + 1] = 0.0f;
				residual[idx * 3 + 2] = 0.0f;
				any_change = true;
				continue;
			}
			if (total_weight < 1e-6f) total_weight = 1.0f;

			float absorbed_x = 0.0f, absorbed_y = 0.0f, absorbed_z = 0.0f;
			for (int d = 0; d < 6; d++) {
				if (!neighbor_valid[d]) continue;
				float frac = weights[d] / total_weight;
				float fx = rx * frac;
				float fy = ry * frac;
				float fz = rz * frac;

				float nx_d = dir_normals[d][0];
				float ny_d = dir_normals[d][1];
				float nz_d = dir_normals[d][2];
				float fn = fx * nx_d + fy * ny_d + fz * nz_d;
				float sx = fx - fn * nx_d;
				float sy = fy - fn * ny_d;
				float sz = fz - fn * nz_d;
				float shear_mag = sqrtf(sx * sx + sy * sy + sz * sz);

				float fn_clamped = fn;
				int ci = idx * 6 + d;
				if (fn > 0.0f) {
					float remaining = compressive_limit - contact_compression[ci];
					if (remaining < 0.0f) remaining = 0.0f;
					fn_clamped = MIN(fn, remaining);
				} else {
					float remaining = tensile_limit + contact_compression[ci];
					if (remaining < 0.0f) remaining = 0.0f;
					fn_clamped = MAX(fn, -remaining);
				}

				float shear_clamped = shear_mag;
				float shear_remaining = shear_limit - contact_shear[ci];
				if (shear_remaining < 0.0f) shear_remaining = 0.0f;
				shear_clamped = MIN(shear_mag, shear_remaining);

				float tfx = fn_clamped * nx_d;
				float tfy = fn_clamped * ny_d;
				float tfz = fn_clamped * nz_d;
				if (shear_mag > 1e-6f) {
					float shear_scale = shear_clamped / shear_mag;
					tfx += sx * shear_scale;
					tfy += sy * shear_scale;
					tfz += sz * shear_scale;
				}

				contact_compression[ci] += fn_clamped;
				contact_shear[ci] += shear_clamped;
				// Accumulate full force vector for exact dirty-seed restoration
				// in subsequent localized solves.
				int cf_base = ci * 3;
				contact_force[cf_base + 0] += tfx;
				contact_force[cf_base + 1] += tfy;
				contact_force[cf_base + 2] += tfz;

				absorbed_x += tfx;
				absorbed_y += tfy;
				absorbed_z += tfz;

				int ni = neighbor_idx[d];
				if (!is_ground[ni]) {
					residual[ni * 3 + 0] += tfx;
					residual[ni * 3 + 1] += tfy;
					residual[ni * 3 + 2] += tfz;
					bool was_active = (active[ni] != 0);
					active[ni] = 1;
					if (!was_active && peak_active < grid_size) peak_active++;
				}
			}

			residual[idx * 3 + 0] -= absorbed_x;
			residual[idx * 3 + 1] -= absorbed_y;
			residual[idx * 3 + 2] -= absorbed_z;

			float new_rmag = sqrtf(
					residual[idx * 3 + 0] * residual[idx * 3 + 0] +
					residual[idx * 3 + 1] * residual[idx * 3 + 1] +
					residual[idx * 3 + 2] * residual[idx * 3 + 2]);
			if (new_rmag != rmag) any_change = true;
		}

		if (!any_change) break;
	}

	// ── Phase 3: stress-failed marking + cascade up ──
	int stress_failed = 0;
	for (int pi = 0; pi < process_count; pi++) {
		int idx = process_order[pi];
		if (failed[idx]) { stress_failed++; continue; }
		float rx = residual[idx * 3 + 0];
		float ry = residual[idx * 3 + 1];
		float rz = residual[idx * 3 + 2];
		float rmag = sqrtf(rx * rx + ry * ry + rz * rz);
		if (rmag > 0.5f) {
			failed[idx] = 1;
			visited[idx] = 0;
			stress_failed++;
		}
	}
	bool cascade = true;
	while (cascade) {
		cascade = false;
		for (int pi = process_count - 1; pi >= 0; pi--) {
			int idx = process_order[pi];
			if (failed[idx]) continue;
			int bx = idx / ny_nz;
			int rem = idx % ny_nz;
			int by = rem / nz;
			int bz = rem % nz;
			bool has_support = false;
			for (int d = 0; d < 6; d++) {
				bool in_bounds = true;
				if (d == 0 && bx + 1 >= nx) in_bounds = false;
				if (d == 1 && bx <= 0)       in_bounds = false;
				if (d == 2 && by + 1 >= ny) in_bounds = false;
				if (d == 3 && by <= 0)       in_bounds = false;
				if (d == 4 && bz + 1 >= nz) in_bounds = false;
				if (d == 5 && bz <= 0)       in_bounds = false;
				if (!in_bounds) continue;
				int ni = idx + dir_offsets[d];
				if (grid[ni] == 1 && visited[ni] == 1 && !failed[ni]) {
					has_support = true;
					break;
				}
			}
			if (!has_support) {
				failed[idx] = 1;
				visited[idx] = 0;
				stress_failed++;
				cascade = true;
			}
		}
	}

	uint64_t t_solver = OS::get_singleton()->get_ticks_usec();

	// ── Phase 4: component BFS over unsupported blocks ──
	int total_unsupported = 0;
	for (int idx = 0; idx < grid_size; idx++) {
		if (grid[idx] == 1 && visited[idx] == 0) total_unsupported++;
	}
	for (int idx = 0; idx < grid_size; idx++) {
		if (grid[idx] == 1 && failed[idx] && visited[idx] == 1) {
			visited[idx] = 0;
			total_unsupported++;
		}
	}

	Array components;
	if (total_unsupported > 0) {
		int head = 0, tail = 0;
		for (int idx = 0; idx < grid_size; idx++) {
			if (grid[idx] != 1 || visited[idx] != 0) continue;
			head = 0; tail = 0;
			bfs_queue[tail++] = idx;
			visited[idx] = 2;
			while (head < tail) {
				const int ci = bfs_queue[head++];
				const int cbx = ci / ny_nz;
				const int crem = ci % ny_nz;
				const int cby = crem / nz;
				const int cbz = crem % nz;
				if (cbx + 1 < nx) { int ni = ci + ny_nz; if (grid[ni] == 1 && visited[ni] == 0) { visited[ni] = 2; bfs_queue[tail++] = ni; } }
				if (cbx > 0)      { int ni = ci - ny_nz; if (grid[ni] == 1 && visited[ni] == 0) { visited[ni] = 2; bfs_queue[tail++] = ni; } }
				if (cby + 1 < ny) { int ni = ci + nz;    if (grid[ni] == 1 && visited[ni] == 0) { visited[ni] = 2; bfs_queue[tail++] = ni; } }
				if (cby > 0)      { int ni = ci - nz;    if (grid[ni] == 1 && visited[ni] == 0) { visited[ni] = 2; bfs_queue[tail++] = ni; } }
				if (cbz + 1 < nz) { int ni = ci + 1;     if (grid[ni] == 1 && visited[ni] == 0) { visited[ni] = 2; bfs_queue[tail++] = ni; } }
				if (cbz > 0)      { int ni = ci - 1;     if (grid[ni] == 1 && visited[ni] == 0) { visited[ni] = 2; bfs_queue[tail++] = ni; } }
			}
			TypedArray<Vector3i> component;
			component.resize(tail);
			for (int j = 0; j < tail; j++) {
				const int cj = bfs_queue[j];
				component[j] = Vector3i(cj / ny_nz, (cj % ny_nz) / nz, cj % nz);
			}
			components.push_back(component);
		}
	}

	// ── Build the updated persistent state to return ──
	// Restore visited[] to 1-or-0 (we set some to 2 during component BFS,
	// and zeroed some during cascade — we want the steady-state ground mask).
	// We need to re-derive what's still ground-connected AFTER components are
	// extracted, since detached components are about to be removed by caller.
	// Easiest: re-run a quick BFS over remaining (visited != 2 AND not failed).
	// Actually for persistent state purposes, what matters is "which blocks
	// are part of the still-attached structure." We rebuild visited[] from
	// is_ground BFS, EXCLUDING failed blocks (caller will erase them).
	memset(visited, 0, grid_size);
	{
		int head2 = 0, tail2 = 0;
		for (int idx = 0; idx < grid_size; idx++) {
			if (is_ground[idx] && grid[idx] == 1 && !failed[idx]) {
				visited[idx] = 1;
				bfs_queue[tail2++] = idx;
			}
		}
		while (head2 < tail2) {
			const int ci = bfs_queue[head2++];
			const int bx = ci / ny_nz;
			const int rem = ci % ny_nz;
			const int by = rem / nz;
			const int bz = rem % nz;
			if (bx + 1 < nx) { int ni = ci + ny_nz; if (grid[ni] == 1 && !failed[ni] && !visited[ni]) { visited[ni] = 1; bfs_queue[tail2++] = ni; } }
			if (bx > 0)      { int ni = ci - ny_nz; if (grid[ni] == 1 && !failed[ni] && !visited[ni]) { visited[ni] = 1; bfs_queue[tail2++] = ni; } }
			if (by + 1 < ny) { int ni = ci + nz;    if (grid[ni] == 1 && !failed[ni] && !visited[ni]) { visited[ni] = 1; bfs_queue[tail2++] = ni; } }
			if (by > 0)      { int ni = ci - nz;    if (grid[ni] == 1 && !failed[ni] && !visited[ni]) { visited[ni] = 1; bfs_queue[tail2++] = ni; } }
			if (bz + 1 < nz) { int ni = ci + 1;     if (grid[ni] == 1 && !failed[ni] && !visited[ni]) { visited[ni] = 1; bfs_queue[tail2++] = ni; } }
			if (bz > 0)      { int ni = ci - 1;     if (grid[ni] == 1 && !failed[ni] && !visited[ni]) { visited[ni] = 1; bfs_queue[tail2++] = ni; } }
		}
	}

	// Pack persistent state into Dictionary.
	PackedFloat32Array out_cc;
	PackedFloat32Array out_cs;
	PackedFloat32Array out_cf;
	PackedByteArray out_visited;
	out_cc.resize(grid_size * 6);
	out_cs.resize(grid_size * 6);
	out_cf.resize(grid_size * 18);
	out_visited.resize(grid_size);
	memcpy(out_cc.ptrw(), contact_compression, grid_size * 6 * sizeof(float));
	memcpy(out_cs.ptrw(), contact_shear, grid_size * 6 * sizeof(float));
	memcpy(out_cf.ptrw(), contact_force, grid_size * 18 * sizeof(float));
	memcpy(out_visited.ptrw(), visited, grid_size);

	// New last_block_count = total currently-existing blocks MINUS the dirty
	// seeds that are about to be erased by the caller's component split.
	// Actually: total_blocks param is the count BEFORE this stress check
	// erases anything. After caller erases the components we returned, the
	// new block count will be total_blocks - sum(component.size()).
	int blocks_in_components = 0;
	for (int i = 0; i < components.size(); i++) {
		TypedArray<Vector3i> c = components[i];
		blocks_in_components += c.size();
	}
	int next_block_count = p_total_blocks - blocks_in_components;

	Dictionary new_state;
	new_state["contact_compression"] = out_cc;
	new_state["contact_shear"] = out_cs;
	new_state["contact_force"] = out_cf;
	new_state["visited"] = out_visited;
	new_state["last_block_count"] = next_block_count;

	memfree(visited); memfree(is_ground); memfree(failed); memfree(active);
	memfree(bfs_queue); memfree(residual);
	memfree(contact_compression); memfree(contact_shear); memfree(contact_force);
	memfree(process_order);

	uint64_t t_end = OS::get_singleton()->get_ticks_usec();
	const char *path_label = need_full ? "FULL" : "LOCAL";
	const char *fb_str = fallback_reason ? fallback_reason : "-";
	if (s_stress_debug_print) {
	print_line(vformat("[StressIntegrity_L %s] blocks=%d  active=%d  failed=%d  components=%d  iters=%d  setup=%dus  solver=%dus  total=%dus  fb=%s",
			path_label, p_total_blocks, peak_active, stress_failed,
			components.size(), solver_iters,
			(int)(t_setup - t_start), (int)(t_solver - t_setup),
			(int)(t_end - t_start), fb_str));
	}

	Dictionary result;
	result["components"] = components;
	result["persistent_state"] = new_state;
	result["used_full_resolve"] = need_full;
	result["active_set_size"] = peak_active;
	return result;
}

Dictionary BlockMeshBuilder::build_cluster(
		const Dictionary &p_block_hp,
		int p_num_x, int p_num_y, int p_num_z,
		float p_block_size,
		const RID &p_cluster_body,
		const RID &p_hit_body,
		const RID &p_hit_shape,
		bool p_include_uvs,
		bool p_manage_bulk_mode) {
	ERR_FAIL_COND_V_MSG(p_num_x <= 0 || p_num_y <= 0 || p_num_z <= 0, Dictionary(),
			"Grid dimensions must be positive.");

	PhysicsServer3D *ps = PhysicsServer3D::get_singleton();
	ERR_FAIL_NULL_V(ps, Dictionary());

	const int total = p_num_x * p_num_y * p_num_z;
	const int ny_nz = p_num_y * p_num_z;
	const real_t bs = p_block_size;
	const real_t hs = bs * 0.5f;
	const real_t half_x = p_num_x * 0.5f;
	const real_t half_y = p_num_y * 0.5f;
	const real_t half_z = p_num_z * 0.5f;

	// ── Pass 1: Iterate block_hp dict → build flat grid, centroid, hit body shapes ──

	PackedByteArray block_grid;
	block_grid.resize(total);
	memset(block_grid.ptrw(), 0, total);
	uint8_t *grid_w = block_grid.ptrw();

	Vector3 centroid_sum;
	int block_count = 0;

	// Also build hit body shapes and shape_to_key mapping in this pass.
	Array shape_to_key;
	shape_to_key.resize(p_block_hp.size());

	const Variant *key = nullptr;
	while ((key = p_block_hp.next(key))) {
		const Vector3i k = *key;
		const int bx = k.x;
		const int by = k.y;
		const int bz = k.z;

		if (bx >= 0 && bx < p_num_x && by >= 0 && by < p_num_y && bz >= 0 && bz < p_num_z) {
			grid_w[bx * ny_nz + by * p_num_z + bz] = 1;
		}

		// Centroid accumulation (block_local_pos_raw).
		centroid_sum.x += (bx + 0.5f - half_x) * bs;
		centroid_sum.y += (by + 0.5f - half_y) * bs;
		centroid_sum.z += (bz + 0.5f - half_z) * bs;

		shape_to_key[block_count] = k;
		block_count++;
	}

	Vector3 centroid;
	if (block_count > 0) {
		centroid = centroid_sum / (real_t)block_count;
	}

	// Now add hit body shapes (needs centroid computed first).
	// Bulk mode: suppress compound shape rebuilds until all shapes are added.
	if (p_manage_bulk_mode) {
		ps->body_set_shapes_bulk_mode(p_hit_body, true);
	}
	for (int i = 0; i < block_count; i++) {
		const Vector3i k = shape_to_key[i];
		const Vector3 local_pos(
				(k.x + 0.5f - half_x) * bs - centroid.x,
				(k.y + 0.5f - half_y) * bs - centroid.y,
				(k.z + 0.5f - half_z) * bs - centroid.z);
		ps->body_add_shape(p_hit_body, p_hit_shape, Transform3D(Basis(), local_pos));
	}
	if (p_manage_bulk_mode) {
		ps->body_set_shapes_bulk_mode(p_hit_body, false);
	}

	// Need read-only pointer for passes 2 & 3 (ptrw() may have COW'd).
	const uint8_t *grid = block_grid.ptr();

	// ── Pass 2: Build mesh from flat grid (same as build_block_mesh) ──

	const int max_verts = block_count * 24;
	const int max_idx = block_count * 36;

	PackedVector3Array verts;
	verts.resize(max_verts);
	PackedVector3Array norms;
	norms.resize(max_verts);
	PackedVector2Array uvs;
	if (p_include_uvs) {
		uvs.resize(max_verts);
	}
	PackedInt32Array indices;
	indices.resize(max_idx);

	Vector3 *verts_w = verts.ptrw();
	Vector3 *norms_w = norms.ptrw();
	Vector2 *uvs_w = p_include_uvs ? uvs.ptrw() : nullptr;
	int32_t *idx_w = indices.ptrw();

	const Vector2 uv0(0, 0), uv1(1, 0), uv2(1, 1), uv3(0, 1);
	const Vector3 n_px(1, 0, 0), n_nx(-1, 0, 0);
	const Vector3 n_py(0, 1, 0), n_ny(0, -1, 0);
	const Vector3 n_pz(0, 0, 1), n_nz(0, 0, -1);

	int vi = 0, ii = 0;

	for (int bx = 0; bx < p_num_x; bx++) {
		const int bx_ny_nz = bx * ny_nz;
		for (int by = 0; by < p_num_y; by++) {
			const int bx_ny_nz_by_nz = bx_ny_nz + by * p_num_z;
			for (int bz = 0; bz < p_num_z; bz++) {
				if (!grid[bx_ny_nz_by_nz + bz]) {
					continue;
				}

				const real_t cx = (bx + 0.5f - half_x) * bs - centroid.x;
				const real_t cy = (by + 0.5f - half_y) * bs - centroid.y;
				const real_t cz = (bz + 0.5f - half_z) * bs - centroid.z;

				const bool has_px = (bx + 1 < p_num_x) && grid[(bx + 1) * ny_nz + by * p_num_z + bz];
				const bool has_nx = (bx - 1 >= 0) && grid[(bx - 1) * ny_nz + by * p_num_z + bz];
				const bool has_py = (by + 1 < p_num_y) && grid[bx_ny_nz + (by + 1) * p_num_z + bz];
				const bool has_ny = (by - 1 >= 0) && grid[bx_ny_nz + (by - 1) * p_num_z + bz];
				const bool has_pz = (bz + 1 < p_num_z) && grid[bx_ny_nz_by_nz + bz + 1];
				const bool has_nz = (bz - 1 >= 0) && grid[bx_ny_nz_by_nz + bz - 1];

#define EMIT_FACE(normal, v0, v1, v2, v3)                    \
	verts_w[vi] = v0; verts_w[vi+1] = v1;                    \
	verts_w[vi+2] = v2; verts_w[vi+3] = v3;                  \
	norms_w[vi] = normal; norms_w[vi+1] = normal;            \
	norms_w[vi+2] = normal; norms_w[vi+3] = normal;          \
	if (uvs_w) { uvs_w[vi]=uv0; uvs_w[vi+1]=uv1;            \
	             uvs_w[vi+2]=uv2; uvs_w[vi+3]=uv3; }         \
	idx_w[ii]=vi; idx_w[ii+1]=vi+1; idx_w[ii+2]=vi+2;        \
	idx_w[ii+3]=vi; idx_w[ii+4]=vi+2; idx_w[ii+5]=vi+3;      \
	vi += 4; ii += 6;

				if (!has_px) { real_t x=cx+hs; EMIT_FACE(n_px, Vector3(x,cy-hs,cz-hs), Vector3(x,cy-hs,cz+hs), Vector3(x,cy+hs,cz+hs), Vector3(x,cy+hs,cz-hs)); }
				if (!has_nx) { real_t x=cx-hs; EMIT_FACE(n_nx, Vector3(x,cy-hs,cz+hs), Vector3(x,cy-hs,cz-hs), Vector3(x,cy+hs,cz-hs), Vector3(x,cy+hs,cz+hs)); }
				if (!has_py) { real_t y=cy+hs; EMIT_FACE(n_py, Vector3(cx-hs,y,cz-hs), Vector3(cx+hs,y,cz-hs), Vector3(cx+hs,y,cz+hs), Vector3(cx-hs,y,cz+hs)); }
				if (!has_ny) { real_t y=cy-hs; EMIT_FACE(n_ny, Vector3(cx-hs,y,cz+hs), Vector3(cx+hs,y,cz+hs), Vector3(cx+hs,y,cz-hs), Vector3(cx-hs,y,cz-hs)); }
				if (!has_pz) { real_t z=cz+hs; EMIT_FACE(n_pz, Vector3(cx+hs,cy-hs,z), Vector3(cx-hs,cy-hs,z), Vector3(cx-hs,cy+hs,z), Vector3(cx+hs,cy+hs,z)); }
				if (!has_nz) { real_t z=cz-hs; EMIT_FACE(n_nz, Vector3(cx-hs,cy-hs,z), Vector3(cx+hs,cy-hs,z), Vector3(cx+hs,cy+hs,z), Vector3(cx-hs,cy+hs,z)); }

#undef EMIT_FACE
			}
		}
	}

	verts.resize(vi);
	norms.resize(vi);
	if (p_include_uvs) { uvs.resize(vi); }
	indices.resize(ii);

	Ref<ArrayMesh> mesh;
	mesh.instantiate();
	if (vi > 0) {
		Array arrays;
		arrays.resize(Mesh::ARRAY_MAX);
		arrays[Mesh::ARRAY_VERTEX] = verts;
		arrays[Mesh::ARRAY_NORMAL] = norms;
		if (p_include_uvs) { arrays[Mesh::ARRAY_TEX_UV] = uvs; }
		arrays[Mesh::ARRAY_INDEX] = indices;
		mesh->add_surface_from_arrays(Mesh::PRIMITIVE_TRIANGLES, arrays);
	}

	// ── Pass 3: Column shapes → create boxes and add to cluster body ──

	Array col_shapes;
	int col_count = 0;

	if (p_manage_bulk_mode) {
		ps->body_set_shapes_bulk_mode(p_cluster_body, true);
	}
	for (int bx = 0; bx < p_num_x; bx++) {
		const int bx_offset = bx * ny_nz;
		for (int bz = 0; bz < p_num_z; bz++) {
			int run_start = -1;

			for (int by = 0; by <= p_num_y; by++) {
				const bool occupied = (by < p_num_y) && grid[bx_offset + by * p_num_z + bz] != 0;

				if (occupied && run_start < 0) {
					run_start = by;
				} else if (!occupied && run_start >= 0) {
					const int run_end = by - 1;
					const int run_count = run_end - run_start + 1;
					const Vector3 size(bs, run_count * bs, bs);
					const Vector3 pos(
							(bx + 0.5f - half_x) * bs - centroid.x,
							((run_start + run_end) * 0.5f + 0.5f - half_y) * bs - centroid.y,
							(bz + 0.5f - half_z) * bs - centroid.z);

					Ref<BoxShape3D> box;
					box.instantiate();
					box->set_size(size);
					ps->body_add_shape(p_cluster_body, box->get_rid(), Transform3D(Basis(), pos));
					col_shapes.push_back(box);
					col_count++;
					run_start = -1;
				}
			}
		}
	}
	if (p_manage_bulk_mode) {
		ps->body_set_shapes_bulk_mode(p_cluster_body, false);
	}

	// ── Return everything ──

	Dictionary result;
	result["block_grid"] = block_grid;
	result["centroid"] = centroid;
	result["mesh"] = mesh;
	result["col_shapes"] = col_shapes;
	result["col_count"] = col_count;
	result["shape_to_key"] = shape_to_key;
	return result;
}

PackedByteArray BlockMeshBuilder::or_byte_arrays(
		const PackedByteArray &p_a,
		const PackedByteArray &p_b) {
	ERR_FAIL_COND_V_MSG(p_a.size() != p_b.size(), p_a,
			"or_byte_arrays: size mismatch");
	PackedByteArray out = p_a;
	uint8_t *w = out.ptrw();
	const uint8_t *b = p_b.ptr();
	const int n = out.size();
	for (int i = 0; i < n; i++) {
		w[i] |= b[i];
	}
	return out;
}

Array BlockMeshBuilder::build_clusters_batch(
		const Array &p_block_hp_array,
		int p_num_x, int p_num_y, int p_num_z,
		float p_block_size,
		const Array &p_cluster_bodies,
		const Array &p_hit_bodies,
		const RID &p_hit_shape,
		bool p_include_uvs,
		const PackedInt32Array &p_cluster_dims) {
	const int n_clusters = p_block_hp_array.size();
	ERR_FAIL_COND_V_MSG(p_cluster_bodies.size() != n_clusters, Array(),
			vformat("cluster_bodies size %d != block_hp_array size %d", p_cluster_bodies.size(), n_clusters));
	ERR_FAIL_COND_V_MSG(p_hit_bodies.size() != n_clusters, Array(),
			vformat("hit_bodies size %d != block_hp_array size %d", p_hit_bodies.size(), n_clusters));

	PhysicsServer3D *ps = PhysicsServer3D::get_singleton();
	ERR_FAIL_NULL_V(ps, Array());

	if (n_clusters == 0) {
		return Array();
	}

	const bool has_dims = p_cluster_dims.size() == n_clusters * 3;
	ERR_FAIL_COND_V_MSG(!has_dims && p_cluster_dims.size() != 0, Array(),
			"build_clusters_batch: cluster_dims must be empty or 3 per cluster");

	// For a single cluster, skip threading overhead and use the direct path.
	if (n_clusters == 1) {
		Array results;
		results.resize(1);
		results[0] = build_cluster(
				(Dictionary)p_block_hp_array[0],
				has_dims ? p_cluster_dims[0] : p_num_x,
				has_dims ? p_cluster_dims[1] : p_num_y,
				has_dims ? p_cluster_dims[2] : p_num_z,
				p_block_size,
				(RID)p_cluster_bodies[0],
				(RID)p_hit_bodies[0],
				p_hit_shape,
				p_include_uvs,
				true);
		return results;
	}

	// ── Phase 1: Parallel computation (grid, mesh arrays, column shapes) ──

	// Keep Dictionary references alive for the duration of the parallel work.
	LocalVector<Dictionary> dict_refs;
	dict_refs.resize(n_clusters);
	for (int c = 0; c < n_clusters; c++) {
		dict_refs[c] = (Dictionary)p_block_hp_array[c];
	}

	LocalVector<ClusterWorkItem> items;
	items.resize(n_clusters);
	for (int c = 0; c < n_clusters; c++) {
		items[c].block_hp = &dict_refs[c];
		items[c].num_x = has_dims ? p_cluster_dims[c * 3 + 0] : p_num_x;
		items[c].num_y = has_dims ? p_cluster_dims[c * 3 + 1] : p_num_y;
		items[c].num_z = has_dims ? p_cluster_dims[c * 3 + 2] : p_num_z;
		items[c].block_size = p_block_size;
		items[c].include_uvs = p_include_uvs;
	}

	ClusterBatchData batch_data;
	batch_data.items = items.ptr();
	batch_data.count = n_clusters;

	WorkerThreadPool::GroupID group = WorkerThreadPool::get_singleton()->add_native_group_task(
			_compute_cluster_work, &batch_data, n_clusters, -1, false,
			String("build_clusters_batch"));
	WorkerThreadPool::get_singleton()->wait_for_group_task_completion(group);

	// ── Phase 2: Engine API calls (main thread) — meshes + physics shapes ──

	// Enable bulk mode on ALL bodies before any shapes are added.
	for (int c = 0; c < n_clusters; c++) {
		ps->body_set_shapes_bulk_mode((RID)p_cluster_bodies[c], true);
		ps->body_set_shapes_bulk_mode((RID)p_hit_bodies[c], true);
	}

	Array results;
	results.resize(n_clusters);

	for (int c = 0; c < n_clusters; c++) {
		ClusterWorkItem &w = items[c];
		const RID cluster_body = (RID)p_cluster_bodies[c];
		const RID hit_body = (RID)p_hit_bodies[c];

		// Hit body shapes.
		const Vector3 *hit_pos = w.hit_positions.ptr();
		for (int i = 0; i < w.block_count; i++) {
			ps->body_add_shape(hit_body, p_hit_shape, Transform3D(Basis(), hit_pos[i]));
		}

		// Build ArrayMesh from pre-computed arrays.
		w.verts.resize(w.vi);
		w.norms.resize(w.vi);
		if (w.include_uvs) {
			w.uvs.resize(w.vi);
		}
		w.indices.resize(w.ii);

		Ref<ArrayMesh> mesh;
		mesh.instantiate();
		if (w.vi > 0) {
			Array arrays;
			arrays.resize(Mesh::ARRAY_MAX);
			arrays[Mesh::ARRAY_VERTEX] = w.verts;
			arrays[Mesh::ARRAY_NORMAL] = w.norms;
			if (w.include_uvs) {
				arrays[Mesh::ARRAY_TEX_UV] = w.uvs;
			}
			arrays[Mesh::ARRAY_INDEX] = w.indices;
			mesh->add_surface_from_arrays(Mesh::PRIMITIVE_TRIANGLES, arrays);
		}

		// Column shapes — create BoxShape3D and add to cluster body.
		Array col_shapes;
		const int col_count = w.col_positions.size();
		col_shapes.resize(col_count);
		const Vector3 *cpos = w.col_positions.ptr();
		const Vector3 *csz = w.col_sizes.ptr();
		for (int i = 0; i < col_count; i++) {
			Ref<BoxShape3D> box;
			box.instantiate();
			box->set_size(csz[i]);
			ps->body_add_shape(cluster_body, box->get_rid(), Transform3D(Basis(), cpos[i]));
			col_shapes[i] = box;
		}

		// Pack result.
		Dictionary result;
		result["block_grid"] = w.block_grid;
		result["centroid"] = w.centroid;
		result["mesh"] = mesh;
		result["col_shapes"] = col_shapes;
		result["col_count"] = col_count;
		result["shape_to_key"] = w.shape_to_key;
		results[c] = result;
	}

	// Commit all bodies — one compound rebuild each.
	for (int c = 0; c < n_clusters; c++) {
		ps->body_set_shapes_bulk_mode((RID)p_cluster_bodies[c], false);
		ps->body_set_shapes_bulk_mode((RID)p_hit_bodies[c], false);
	}

	return results;
}

// ── Debris bulk configuration ──
//
// Uses direct PhysicsServer3D + RenderingServer API to bypass the Node3D
// notification chain (~1.5μs/body saved) and the freeze/unfreeze cycle
// (~0.8μs/body saved).  Pool bodies are always DYNAMIC with can_sleep=true
// and gravity_scale=0 when idle.  Waking a sleeping dynamic body via
// body_set_state(TRANSFORM) costs ~0.1μs vs. SetMotionType at ~0.8μs.

void BlockMeshBuilder::bulk_configure_debris(
		const Array &p_nodes,
		const PackedVector3Array &p_block_positions,
		const PackedVector3Array &p_blast_centers,
		const PackedInt32Array &p_counts,
		const PackedFloat32Array &p_speeds,
		real_t p_mass,
		const Ref<Material> &p_material) {
	const int n_blocks = p_block_positions.size();
	ERR_FAIL_COND_MSG(p_blast_centers.size() != n_blocks, "blast_centers size mismatch");
	ERR_FAIL_COND_MSG(p_counts.size() != n_blocks, "counts size mismatch");
	ERR_FAIL_COND_MSG(p_speeds.size() != n_blocks, "speeds size mismatch");

	int total_count = 0;
	const int32_t *counts = p_counts.ptr();
	for (int i = 0; i < n_blocks; i++) {
		total_count += counts[i];
	}
	ERR_FAIL_COND_MSG(p_nodes.size() < total_count,
			vformat("nodes size %d < total debris count %d", p_nodes.size(), total_count));

	PhysicsServer3D *ps = PhysicsServer3D::get_singleton();
	RenderingServer *rs = RenderingServer::get_singleton();
	ERR_FAIL_NULL(ps);
	ERR_FAIL_NULL(rs);

	const RID mat_rid = p_material.is_valid() ? p_material->get_rid() : RID();
	const bool has_mat = mat_rid.is_valid();
	const bool set_mass = !Math::is_equal_approx(p_mass, (real_t)0.5);

	const real_t cone_cos = Math::cos(Math::deg_to_rad((real_t)35.0));
	const real_t scatter_scale = (real_t)1.0 - cone_cos;

	const Vector3 *block_pos_ptr = p_block_positions.ptr();
	const Vector3 *blast_ptr = p_blast_centers.ptr();
	const real_t *speeds_ptr = p_speeds.ptr();

	int node_idx = 0;
	for (int b = 0; b < n_blocks; b++) {
		const Vector3 &block_pos = block_pos_ptr[b];
		const Vector3 &blast_center = blast_ptr[b];
		const int count = counts[b];
		const real_t speed = speeds_ptr[b];

		// Compute toward direction for this block.
		Vector3 toward = blast_center - block_pos;
		if (toward.length_squared() < (real_t)0.01) {
			toward = Vector3(Math::randf() * 2.0f - 1.0f, 1.0f, Math::randf() * 2.0f - 1.0f);
		}
		toward.normalize();

		for (int i = 0; i < count; i++) {
			Node3D *node = Object::cast_to<Node3D>((Object *)(p_nodes[node_idx]));
			node_idx++;
			if (unlikely(!node)) {
				continue;
			}

			// Extract server RIDs — bypass node property system entirely.
			RigidBody3D *rb = Object::cast_to<RigidBody3D>(node);
			if (unlikely(!rb)) {
				continue;
			}
			RID body_rid = rb->get_rid();

			VisualInstance3D *vi = Object::cast_to<VisualInstance3D>(node->get_child(1));
			RID vi_rid = vi ? vi->get_instance() : RID();

			// Random scatter within 35-degree cone, biased upward.
			Vector3 scatter = Vector3(
					Math::randf() * 2.0f - 1.0f,
					Math::randf() * 2.0f - 1.0f,
					Math::randf() * 2.0f - 1.0f)
									 .normalized();
			Vector3 impulse_dir = (toward + scatter * scatter_scale).normalized();
			impulse_dir.y = MAX(impulse_dir.y, (real_t)0.15);

			// Spawn offset: small random jitter + push along launch direction
			// so debris starts outside adjacent wall geometry (prevents Jolt
			// depenetration from killing velocity).
			Vector3 spawn_pos = block_pos + impulse_dir * 0.2f + Vector3(
					Math::randf() * 0.2f - 0.1f,
					Math::randf() * 0.2f - 0.1f,
					Math::randf() * 0.2f - 0.1f);

			Transform3D xform(Basis(), spawn_pos);

			// ── Direct PhysicsServer3D ──
			// Restore gravity (pool bodies have gravity_scale=0).
			ps->body_set_param(body_rid, PhysicsServer3D::BODY_PARAM_GRAVITY_SCALE, 1.0);
			if (set_mass) {
				ps->body_set_param(body_rid, PhysicsServer3D::BODY_PARAM_MASS, p_mass);
			}
			// Set transform — wakes sleeping body via _transform_changed→wake_up.
			// Cost: ~0.2μs (vs ~1.5μs for Node3D::set_position notification chain).
			ps->body_set_state(body_rid, PhysicsServer3D::BODY_STATE_TRANSFORM, xform);
			// Set velocity on now-active body.
			ps->body_set_state(body_rid, PhysicsServer3D::BODY_STATE_LINEAR_VELOCITY,
					Variant(impulse_dir * speed));
			ps->body_set_state(body_rid, PhysicsServer3D::BODY_STATE_ANGULAR_VELOCITY,
					Variant(Vector3(
							Math::randf() * 8.0f - 4.0f,
							Math::randf() * 8.0f - 4.0f,
							Math::randf() * 8.0f - 4.0f)));

			// ── Direct RenderingServer ──
			if (vi_rid.is_valid()) {
				rs->instance_set_transform(vi_rid, xform);
				rs->instance_set_visible(vi_rid, true);
				if (has_mat) {
					rs->instance_geometry_set_material_override(vi_rid, mat_rid);
				}
			}

			// No debug var init needed — _integrate_forces auto-inits when
			// gravity transitions from 0→nonzero (first active physics frame).
		}
	}
}

// ── Debris angle-dependent friction callback ──
// Matches debris_body.gd: full friction on floors (≤50° from up),
// fading to zero at 90°, none on ceilings.

void BlockMeshBuilder::debris_friction_callback(PhysicsDirectBodyState3D *p_state, const Variant &p_userdata) {
	// Sync visual instance transform to physics body (raw RIDs have no auto-sync).
	RID instance = p_userdata;
	if (instance.is_valid()) {
		RenderingServer::get_singleton()->instance_set_transform(instance, p_state->get_transform());
	}

	static constexpr real_t FRICTION_DECEL = 8.0f;
	static constexpr real_t COS_FULL = 0.6427876f; // cos(50°)

	int count = p_state->get_contact_count();
	if (count == 0) {
		return;
	}

	real_t best = 0.0f;
	for (int i = 0; i < count; i++) {
		real_t up_dot = p_state->get_contact_local_normal(i).dot(Vector3(0, 1, 0));
		if (up_dot <= 0.0f) {
			continue;
		}
		if (up_dot >= COS_FULL) {
			best = 1.0f;
			break;
		}
		best = MAX(best, up_dot / COS_FULL);
	}

	if (best <= 0.0f) {
		return;
	}

	real_t decel = best * FRICTION_DECEL * p_state->get_step();

	Vector3 vel = p_state->get_linear_velocity();
	real_t speed = vel.length();
	if (speed > 0.01f) {
		p_state->set_linear_velocity(vel * MAX((speed - decel) / speed, 0.0f));
	}

	Vector3 ang = p_state->get_angular_velocity();
	real_t ang_speed = ang.length();
	if (ang_speed > 0.01f) {
		p_state->set_angular_velocity(ang * MAX((ang_speed - decel) / ang_speed, 0.0f));
	}
}

// ── Spawn debris as raw server RIDs (no Godot nodes) ──

Dictionary BlockMeshBuilder::bulk_spawn_debris(
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
		int p_collision_mask) {
	const int n_blocks = p_block_positions.size();
	ERR_FAIL_COND_V_MSG(p_blast_centers.size() != n_blocks, Dictionary(), "blast_centers size mismatch");
	ERR_FAIL_COND_V_MSG(p_counts.size() != n_blocks, Dictionary(), "counts size mismatch");
	ERR_FAIL_COND_V_MSG(p_speeds.size() != n_blocks, Dictionary(), "speeds size mismatch");

	int total_count = 0;
	const int32_t *counts = p_counts.ptr();
	for (int i = 0; i < n_blocks; i++) {
		total_count += counts[i];
	}

	Dictionary result;
	Array body_rids;
	Array instance_rids;
	if (total_count == 0) {
		result["body_rids"] = body_rids;
		result["instance_rids"] = instance_rids;
		return result;
	}

	body_rids.resize(total_count);
	instance_rids.resize(total_count);

	PhysicsServer3D *ps = PhysicsServer3D::get_singleton();
	RenderingServer *rs = RenderingServer::get_singleton();
	ERR_FAIL_NULL_V(ps, result);
	ERR_FAIL_NULL_V(rs, result);

	const RID mat_rid = p_material.is_valid() ? p_material->get_rid() : RID();
	const bool has_mat = mat_rid.is_valid();

	const real_t cone_cos = Math::cos(Math::deg_to_rad((real_t)35.0));
	const real_t scatter_scale = (real_t)1.0 - cone_cos;

	const Vector3 *block_pos_ptr = p_block_positions.ptr();
	const Vector3 *blast_ptr = p_blast_centers.ptr();
	const real_t *speeds_ptr = p_speeds.ptr();

	int idx = 0;
	for (int b = 0; b < n_blocks; b++) {
		const Vector3 &block_pos = block_pos_ptr[b];
		const Vector3 &blast_center = blast_ptr[b];
		const int count = counts[b];
		const real_t speed = speeds_ptr[b];

		Vector3 toward = blast_center - block_pos;
		if (toward.length_squared() < (real_t)0.01) {
			toward = Vector3(Math::randf() * 2.0f - 1.0f, 1.0f, Math::randf() * 2.0f - 1.0f);
		}
		toward.normalize();

		for (int i = 0; i < count; i++) {
			// Random scatter within 35-degree cone, biased upward.
			Vector3 scatter = Vector3(
					Math::randf() * 2.0f - 1.0f,
					Math::randf() * 2.0f - 1.0f,
					Math::randf() * 2.0f - 1.0f)
									 .normalized();
			Vector3 impulse_dir = (toward + scatter * scatter_scale).normalized();
			impulse_dir.y = MAX(impulse_dir.y, (real_t)0.15);

			Vector3 spawn_pos = block_pos + impulse_dir * 0.2f + Vector3(
					Math::randf() * 0.2f - 0.1f,
					Math::randf() * 0.2f - 0.1f,
					Math::randf() * 0.2f - 0.1f);

			Transform3D xform(Basis(), spawn_pos);

			// ── Create physics body ──
			// Order matters for Jolt: configure params before adding to space,
			// set transform + velocity after, then force-wake.
			RID body = ps->body_create();
			ps->body_set_mode(body, PhysicsServer3D::BODY_MODE_RIGID);
			ps->body_set_collision_layer(body, p_collision_layer);
			ps->body_set_collision_mask(body, p_collision_mask);
			ps->body_set_param(body, PhysicsServer3D::BODY_PARAM_MASS, p_mass);
			ps->body_set_param(body, PhysicsServer3D::BODY_PARAM_GRAVITY_SCALE, 1.0);
			ps->body_set_param(body, PhysicsServer3D::BODY_PARAM_LINEAR_DAMP, 0.0);
			ps->body_set_param(body, PhysicsServer3D::BODY_PARAM_ANGULAR_DAMP, 0.0);
			ps->body_add_shape(body, p_shape);

			// ── Create visual instance (before callback registration — needs RID) ──
			RID instance = rs->instance_create();
			rs->instance_set_base(instance, p_mesh);
			rs->instance_set_scenario(instance, p_scenario);
			rs->instance_set_transform(instance, xform);
			rs->instance_set_visible(instance, true);
			if (has_mat) {
				rs->instance_geometry_set_material_override(instance, mat_rid);
			}
			rs->instance_geometry_set_cast_shadows_setting(instance,
					RenderingServer::SHADOW_CASTING_SETTING_OFF);

			// Enable contact reporting for friction callback.
			ps->body_set_max_contacts_reported(body, 3);
			// Register angle-dependent friction callback.
			// Pass instance RID as userdata for visual sync.
			ps->body_set_force_integration_callback(body,
					Callable(this, "debris_friction_callback"), instance);
			// Add to space, then set state (Jolt ignores state on spaceless bodies).
			ps->body_set_space(body, p_space);
			ps->body_set_state(body, PhysicsServer3D::BODY_STATE_TRANSFORM, xform);
			ps->body_set_state(body, PhysicsServer3D::BODY_STATE_LINEAR_VELOCITY,
					Variant(impulse_dir * speed));
			ps->body_set_state(body, PhysicsServer3D::BODY_STATE_ANGULAR_VELOCITY,
					Variant(Vector3(
							Math::randf() * 8.0f - 4.0f,
							Math::randf() * 8.0f - 4.0f,
							Math::randf() * 8.0f - 4.0f)));
			// Force-wake so Jolt doesn't auto-sleep before first step.
			ps->body_set_state(body, PhysicsServer3D::BODY_STATE_SLEEPING, false);

			body_rids[idx] = body;
			instance_rids[idx] = instance;
			idx++;
		}
	}

	result["body_rids"] = body_rids;
	result["instance_rids"] = instance_rids;
	return result;
}

// ── Build collision triangle faces from flat occupancy grid ──
// Matches the GDScript _build_faces_from_grid() output exactly.
// Centroid is zero (grid-centered).

PackedVector3Array BlockMeshBuilder::build_collision_faces(
		const PackedByteArray &p_block_grid,
		int p_num_x, int p_num_y, int p_num_z,
		float p_block_size) {
	const int total = p_num_x * p_num_y * p_num_z;
	ERR_FAIL_COND_V(p_block_grid.size() != total, PackedVector3Array());

	const uint8_t *grid = p_block_grid.ptr();
	const int nx = p_num_x, ny = p_num_y, nz = p_num_z;
	const int ny_nz = ny * nz;
	const real_t bs = p_block_size;
	const real_t hs = bs * 0.5f;
	const real_t hx = nx * bs * 0.5f;
	const real_t hy = ny * bs * 0.5f;
	const real_t hz = nz * bs * 0.5f;

	// Count occupied for allocation.
	int block_count = 0;
	for (int i = 0; i < total; i++) {
		if (grid[i]) {
			block_count++;
		}
	}
	if (block_count == 0) {
		return PackedVector3Array();
	}

	PackedVector3Array faces;
	faces.resize(block_count * 36); // worst case: 6 faces * 2 tris * 3 verts
	Vector3 *w = faces.ptrw();
	int fi = 0;

	for (int bx = 0; bx < nx; bx++) {
		for (int by = 0; by < ny; by++) {
			for (int bz = 0; bz < nz; bz++) {
				if (!grid[bx * ny_nz + by * nz + bz]) {
					continue;
				}

				const real_t cx = (bx + 0.5f) * bs - hx;
				const real_t cy = (by + 0.5f) * bs - hy;
				const real_t cz = (bz + 0.5f) * bs - hz;

				// +X
				if (!_grid_occupied(grid, bx + 1, by, bz, nx, ny, nz)) {
					const real_t x = cx + hs;
					w[fi]     = Vector3(x, cy - hs, cz - hs);
					w[fi + 1] = Vector3(x, cy - hs, cz + hs);
					w[fi + 2] = Vector3(x, cy + hs, cz + hs);
					w[fi + 3] = Vector3(x, cy - hs, cz - hs);
					w[fi + 4] = Vector3(x, cy + hs, cz + hs);
					w[fi + 5] = Vector3(x, cy + hs, cz - hs);
					fi += 6;
				}
				// -X
				if (!_grid_occupied(grid, bx - 1, by, bz, nx, ny, nz)) {
					const real_t x = cx - hs;
					w[fi]     = Vector3(x, cy - hs, cz + hs);
					w[fi + 1] = Vector3(x, cy - hs, cz - hs);
					w[fi + 2] = Vector3(x, cy + hs, cz - hs);
					w[fi + 3] = Vector3(x, cy - hs, cz + hs);
					w[fi + 4] = Vector3(x, cy + hs, cz - hs);
					w[fi + 5] = Vector3(x, cy + hs, cz + hs);
					fi += 6;
				}
				// +Y
				if (!_grid_occupied(grid, bx, by + 1, bz, nx, ny, nz)) {
					const real_t y = cy + hs;
					w[fi]     = Vector3(cx - hs, y, cz - hs);
					w[fi + 1] = Vector3(cx + hs, y, cz - hs);
					w[fi + 2] = Vector3(cx + hs, y, cz + hs);
					w[fi + 3] = Vector3(cx - hs, y, cz - hs);
					w[fi + 4] = Vector3(cx + hs, y, cz + hs);
					w[fi + 5] = Vector3(cx - hs, y, cz + hs);
					fi += 6;
				}
				// -Y
				if (!_grid_occupied(grid, bx, by - 1, bz, nx, ny, nz)) {
					const real_t y = cy - hs;
					w[fi]     = Vector3(cx - hs, y, cz + hs);
					w[fi + 1] = Vector3(cx + hs, y, cz + hs);
					w[fi + 2] = Vector3(cx + hs, y, cz - hs);
					w[fi + 3] = Vector3(cx - hs, y, cz + hs);
					w[fi + 4] = Vector3(cx + hs, y, cz - hs);
					w[fi + 5] = Vector3(cx - hs, y, cz - hs);
					fi += 6;
				}
				// +Z
				if (!_grid_occupied(grid, bx, by, bz + 1, nx, ny, nz)) {
					const real_t z = cz + hs;
					w[fi]     = Vector3(cx + hs, cy - hs, z);
					w[fi + 1] = Vector3(cx - hs, cy - hs, z);
					w[fi + 2] = Vector3(cx - hs, cy + hs, z);
					w[fi + 3] = Vector3(cx + hs, cy - hs, z);
					w[fi + 4] = Vector3(cx - hs, cy + hs, z);
					w[fi + 5] = Vector3(cx + hs, cy + hs, z);
					fi += 6;
				}
				// -Z
				if (!_grid_occupied(grid, bx, by, bz - 1, nx, ny, nz)) {
					const real_t z = cz - hs;
					w[fi]     = Vector3(cx - hs, cy - hs, z);
					w[fi + 1] = Vector3(cx + hs, cy - hs, z);
					w[fi + 2] = Vector3(cx + hs, cy + hs, z);
					w[fi + 3] = Vector3(cx - hs, cy - hs, z);
					w[fi + 4] = Vector3(cx + hs, cy + hs, z);
					w[fi + 5] = Vector3(cx - hs, cy + hs, z);
					fi += 6;
				}
			}
		}
	}

	faces.resize(fi);
	return faces;
}
