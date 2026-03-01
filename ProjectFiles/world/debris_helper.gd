extends RefCounted
class_name DebrisHelper

## Static utility for spawning small cosmetic debris cubes (client-side only).
## Used by DestructibleBlockStructure for wall/ramp debris.
## All debris uses collision layer 32 (layer 6) and mask 2049 (world + smooth wall collision).
##
## Performance notes:
##   - Debris is purely cosmetic: spawned on clients, NOT on the server.
##   - Uses DebrisManager object pool — no per-spawn node creation.
##   - Collision shape and mesh are shared across all pool nodes.
##   - No Timer node or SceneTreeTimer: DebrisManager expiry queue handles cleanup.
##   - can_sleep=false — prevents Jolt auto-sleep freezing debris mid-air.

## Minimum debris speed (m/s) — floor for all paths.
const MIN_SPEED := 3.0
## Max debris speed for explosions (m/s). At blast center with full overkill.
const EXPLOSION_MAX_SPEED := 15.0
## Max debris speed for hitscans with full overkill.
const HITSCAN_MAX_SPEED := 12.0
## Base debris speed for hitscans with no overkill.
const HITSCAN_BASE_SPEED := 8.0
## Fraction of impact speed transferred to debris (momentum carving path).
const SPEED_TRANSFER := 0.7

## Compute debris launch speed for an explosion using the same cubic falloff
## as damage, so blocks near the blast center produce fast debris and blocks
## at the edge produce slow debris. Overkill adds a bonus on top.
static func calc_explosion_speed(norm_dist: float, overkill_frac: float) -> float:
	var falloff := 1.0 / (1.0 + (norm_dist * 3.0) ** 3)
	return maxf(EXPLOSION_MAX_SPEED * falloff * (1.0 + overkill_frac * 0.5), MIN_SPEED)

## Compute debris launch speed for a hitscan hit. Overkill scales from base to max.
static func calc_hitscan_speed(overkill_frac: float) -> float:
	return lerpf(HITSCAN_BASE_SPEED, HITSCAN_MAX_SPEED, clampf(overkill_frac, 0.0, 1.0))

## Compute debris launch speed for momentum carving (falling cluster impacts).
static func calc_momentum_speed(impact_speed: float) -> float:
	return maxf(impact_speed * SPEED_TRANSFER, MIN_SPEED)

## Spawn small debris cubes flying toward the shot origin.
## Parameters:
##   parent_node: unused (kept for API compat — pool nodes live under DebrisManager)
##   block_pos: world position of the destroyed block
##   blast_center: world position of the shot origin (debris flies TOWARD this)
##   count: number of debris cubes to spawn
##   material: StandardMaterial3D to apply to debris meshes
##   debris_speed: pre-computed launch speed (m/s). Use calc_*_speed() helpers.
##   config: Dictionary with keys:
##     "size"     (float)  — cube edge length (currently fixed at 0.15 in pool)
##     "lifetime" (float)  — seconds before auto-release back to pool
##     "mass"     (float)  — RigidBody3D mass
##     "name"     (String) — unused with pooling

static func spawn_debris(
	parent_node: Node,
	block_pos: Vector3,
	blast_center: Vector3,
	count: int,
	material: StandardMaterial3D,
	debris_speed: float,
	config: Dictionary,
) -> void:
	if GameManager.disable_debris:
		return

	var lifetime: float = config.get("lifetime", 5.0)
	var mass_val: float = config.get("mass", 0.5)
	debris_speed = maxf(debris_speed, MIN_SPEED)

	DebrisManager.spawn_batch(
		block_pos, blast_center, count, material,
		debris_speed, mass_val, lifetime,
	)
