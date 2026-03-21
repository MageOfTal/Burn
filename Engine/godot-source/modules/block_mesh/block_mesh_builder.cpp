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
			D_METHOD("build_cluster", "block_hp", "num_x", "num_y", "num_z", "block_size", "cluster_body", "hit_body", "hit_shape", "include_uvs"),
			&BlockMeshBuilder::build_cluster,
			DEFVAL(true), DEFVAL(true));
	ClassDB::bind_method(
			D_METHOD("build_clusters_batch", "block_hp_array", "num_x", "num_y", "num_z", "block_size", "cluster_bodies", "hit_bodies", "hit_shape", "include_uvs"),
			&BlockMeshBuilder::build_clusters_batch,
			DEFVAL(true));
	ClassDB::bind_method(
			D_METHOD("bulk_configure_debris", "nodes", "block_positions", "blast_centers", "counts", "speeds", "mass", "material"),
			&BlockMeshBuilder::bulk_configure_debris);
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

Array BlockMeshBuilder::build_clusters_batch(
		const Array &p_block_hp_array,
		int p_num_x, int p_num_y, int p_num_z,
		float p_block_size,
		const Array &p_cluster_bodies,
		const Array &p_hit_bodies,
		const RID &p_hit_shape,
		bool p_include_uvs) {
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

	// For a single cluster, skip threading overhead and use the direct path.
	if (n_clusters == 1) {
		Array results;
		results.resize(1);
		results[0] = build_cluster(
				(Dictionary)p_block_hp_array[0],
				p_num_x, p_num_y, p_num_z,
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
		items[c].num_x = p_num_x;
		items[c].num_y = p_num_y;
		items[c].num_z = p_num_z;
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
