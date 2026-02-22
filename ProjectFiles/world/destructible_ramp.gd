extends DestructibleBlockStructure

## Destructible ramp — thin subclass providing ramp-specific tier data and
## debris parameters. All block grid, damage, meshing, and debris logic
## lives in the DestructibleBlockStructure base class.

enum RampTier { WOOD, STONE, METAL, REINFORCED }

const TIER_DATA := {
	RampTier.WOOD:       { "color": Color(0.50, 0.38, 0.20), "block_hp": 12.0 },
	RampTier.STONE:      { "color": Color(0.50, 0.52, 0.48), "block_hp": 28.0 },
	RampTier.METAL:      { "color": Color(0.42, 0.48, 0.52), "block_hp": 55.0 },
	RampTier.REINFORCED: { "color": Color(0.28, 0.28, 0.32), "block_hp": 110.0 },
}

@export var ramp_tier: RampTier = RampTier.STONE

## Compatibility alias — seed_world.gd sets ramp.ramp_size
var ramp_size: Vector3:
	get: return structure_size
	set(v): structure_size = v


func _get_tier_info() -> Dictionary:
	return TIER_DATA[ramp_tier]


func _get_debris_config() -> Dictionary:
	return {
		"size": 0.12,
		"per_block": 2,
		"impulse": 3.0,
		"lifetime": 5.0,
		"max_total": 30,
		"mass": 0.4,
		"name": "RampDebris",
	}
