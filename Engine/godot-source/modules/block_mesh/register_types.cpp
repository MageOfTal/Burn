#include "register_types.h"

#include "block_mesh_builder.h"

#include "core/config/engine.h"

static BlockMeshBuilder *block_mesh_builder = nullptr;

void initialize_block_mesh_module(ModuleInitializationLevel p_level) {
	if (p_level != MODULE_INITIALIZATION_LEVEL_SCENE) {
		return;
	}

	GDREGISTER_CLASS(BlockMeshBuilder);
	block_mesh_builder = memnew(BlockMeshBuilder);
	Engine::get_singleton()->add_singleton(Engine::Singleton("BlockMeshBuilder", BlockMeshBuilder::get_singleton()));
}

void uninitialize_block_mesh_module(ModuleInitializationLevel p_level) {
	if (p_level != MODULE_INITIALIZATION_LEVEL_SCENE) {
		return;
	}

	if (block_mesh_builder) {
		memdelete(block_mesh_builder);
		block_mesh_builder = nullptr;
	}
}
