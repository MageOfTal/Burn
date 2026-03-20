#pragma once

#include "core/object/ref_counted.h"
#include "core/variant/variant.h"
#include "core/math/vector3i.h"
#include "modules/noise/fastnoise_lite.h"

class TerrainFill : public RefCounted {
	GDCLASS(TerrainFill, RefCounted)

	static void _bind_methods();

public:
	void fill_buffer(
		Object *p_buffer,
		const Dictionary &p_chunks,
		Vector3i p_region_min,
		Vector3i p_buf_size,
		Ref<FastNoiseLite> p_noise,
		float p_height_range,
		int p_chunk_size);

	PackedFloat32Array generate_chunk(
		Vector3i p_block_pos,
		Ref<FastNoiseLite> p_noise,
		float p_height_range,
		int p_chunk_size);
};
