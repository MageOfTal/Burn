#include "register_types.h"
#include "terrain_fill.h"
#include "core/object/class_db.h"

void initialize_terrain_fill_module(ModuleInitializationLevel p_level) {
	if (p_level != MODULE_INITIALIZATION_LEVEL_SCENE) {
		return;
	}
	GDREGISTER_CLASS(TerrainFill);
}

void uninitialize_terrain_fill_module(ModuleInitializationLevel p_level) {
	if (p_level != MODULE_INITIALIZATION_LEVEL_SCENE) {
		return;
	}
}
