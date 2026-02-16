extends DestructibleBlockStructure

## Destructible wall — thin subclass providing wall-specific tier data and
## debris parameters. All block grid, damage, meshing, and debris logic
## lives in the DestructibleBlockStructure base class.

enum WallTier { WOOD, STONE, METAL, REINFORCED }

const TIER_DATA := {
	WallTier.WOOD:       { "color": Color(0.55, 0.35, 0.15), "block_hp": 15.0 },
	WallTier.STONE:      { "color": Color(0.55, 0.55, 0.50), "block_hp": 35.0 },
	WallTier.METAL:      { "color": Color(0.45, 0.50, 0.55), "block_hp": 70.0 },
	WallTier.REINFORCED: { "color": Color(0.30, 0.30, 0.35), "block_hp": 140.0 },
}

@export var wall_tier: WallTier = WallTier.STONE

## Compatibility alias — seed_world.gd sets wall.wall_size
var wall_size: Vector3:
	get: return structure_size
	set(v): structure_size = v


func _get_tier_info() -> Dictionary:
	return TIER_DATA[wall_tier]


func _get_debris_config() -> Dictionary:
	return {
		"size": 0.15,
		"per_block": 2,
		"impulse": 3.5,
		"lifetime": 5.0,
		"max_total": 40,
		"mass": 0.5,
		"name": "WallDebris",
	}
