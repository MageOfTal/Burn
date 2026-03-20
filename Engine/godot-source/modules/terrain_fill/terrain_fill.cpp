#include "terrain_fill.h"
#include "core/object/class_db.h"

void TerrainFill::_bind_methods() {
	ClassDB::bind_method(D_METHOD("fill_buffer", "buffer", "chunks", "region_min", "buf_size", "noise", "height_range", "chunk_size"),
			&TerrainFill::fill_buffer);
	ClassDB::bind_method(D_METHOD("generate_chunk", "block_pos", "noise", "height_range", "chunk_size"),
			&TerrainFill::generate_chunk);
}

void TerrainFill::fill_buffer(
		Object *p_buffer,
		const Dictionary &p_chunks,
		Vector3i p_region_min,
		Vector3i p_buf_size,
		Ref<FastNoiseLite> p_noise,
		float p_height_range,
		int p_chunk_size) {
	ERR_FAIL_NULL(p_buffer);

	const int CS = p_chunk_size;
	const int sdf_channel = 1;

	int region_max_x = p_region_min.x + p_buf_size.x;
	int region_max_y = p_region_min.y + p_buf_size.y;
	int region_max_z = p_region_min.z + p_buf_size.z;

	int bmin_x = (int)Math::floor((double)p_region_min.x / CS);
	int bmin_y = (int)Math::floor((double)p_region_min.y / CS);
	int bmin_z = (int)Math::floor((double)p_region_min.z / CS);
	int bmax_x = (int)Math::floor((double)(region_max_x - 1) / CS);
	int bmax_y = (int)Math::floor((double)(region_max_y - 1) / CS);
	int bmax_z = (int)Math::floor((double)(region_max_z - 1) / CS);

	const StringName method = "set_voxel_f";

	for (int cbz = bmin_z; cbz <= bmax_z; cbz++) {
		for (int cby = bmin_y; cby <= bmax_y; cby++) {
			for (int cbx = bmin_x; cbx <= bmax_x; cbx++) {
				Vector3i bp(cbx, cby, cbz);
				int co_x = cbx * CS;
				int co_y = cby * CS;
				int co_z = cbz * CS;

				int omin_x = MAX(co_x, p_region_min.x);
				int omin_y = MAX(co_y, p_region_min.y);
				int omin_z = MAX(co_z, p_region_min.z);
				int omax_x = MIN(co_x + CS, region_max_x);
				int omax_y = MIN(co_y + CS, region_max_y);
				int omax_z = MIN(co_z + CS, region_max_z);

				if (p_chunks.has(bp)) {
					PackedFloat32Array sdf = p_chunks[bp];
					const float *sdf_ptr = sdf.ptr();
					int sdf_size = sdf.size();

					for (int wz = omin_z; wz < omax_z; wz++) {
						int lz_c = wz - co_z;
						int lz_b = wz - p_region_min.z;
						for (int wy = omin_y; wy < omax_y; wy++) {
							int ly_c = wy - co_y;
							int ly_b = wy - p_region_min.y;
							int row_c = lz_c * CS * CS + ly_c * CS;
							for (int wx = omin_x; wx < omax_x; wx++) {
								int lx_c = wx - co_x;
								int lx_b = wx - p_region_min.x;
								int idx = row_c + lx_c;
								double val = (idx >= 0 && idx < sdf_size) ? (double)sdf_ptr[idx] : 1.0;
								p_buffer->call(method, val, lx_b, ly_b, lz_b, sdf_channel);
							}
						}
					}
				} else if (p_noise.is_valid()) {
					for (int wz = omin_z; wz < omax_z; wz++) {
						real_t fwz = (real_t)wz;
						int lz_b = wz - p_region_min.z;
						for (int wy = omin_y; wy < omax_y; wy++) {
							real_t fwy = (real_t)wy;
							int ly_b = wy - p_region_min.y;
							for (int wx = omin_x; wx < omax_x; wx++) {
								real_t fwx = (real_t)wx;
								int lx_b = wx - p_region_min.x;
								double sy = (double)(p_noise->get_noise_2d(fwx, fwz) + 1.0) * 0.5 * (double)p_height_range;
								p_buffer->call(method, (double)fwy - sy, lx_b, ly_b, lz_b, sdf_channel);
							}
						}
					}
				}
			}
		}
	}
}

PackedFloat32Array TerrainFill::generate_chunk(
		Vector3i p_block_pos,
		Ref<FastNoiseLite> p_noise,
		float p_height_range,
		int p_chunk_size) {
	ERR_FAIL_COND_V(p_noise.is_null(), PackedFloat32Array());

	const int CS = p_chunk_size;
	const int volume = CS * CS * CS;

	PackedFloat32Array sdf;
	sdf.resize(volume);
	float *ptr = sdf.ptrw();

	int ox = p_block_pos.x * CS;
	int oy = p_block_pos.y * CS;
	int oz = p_block_pos.z * CS;

	int idx = 0;
	for (int lz = 0; lz < CS; lz++) {
		real_t wz = (real_t)(oz + lz);
		for (int ly = 0; ly < CS; ly++) {
			real_t wy = (real_t)(oy + ly);
			for (int lx = 0; lx < CS; lx++) {
				real_t wx = (real_t)(ox + lx);
				real_t surface_y = (p_noise->get_noise_2d(wx, wz) + (real_t)1.0) * (real_t)0.5 * (real_t)p_height_range;
				ptr[idx] = (float)(wy - surface_y);
				idx++;
			}
		}
	}

	return sdf;
}
