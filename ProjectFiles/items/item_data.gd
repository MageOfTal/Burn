extends Resource
class_name ItemData

## Base class for all item definitions. Saved as .tres files.

enum ItemType { WEAPON, CONSUMABLE, GADGET, MATERIAL, SHOE, FUEL, AMMO, TRINKET }
enum Rarity { COMMON, UNCOMMON, RARE, EPIC, LEGENDARY }

@export var item_name: String = ""
@export var item_type: ItemType = ItemType.WEAPON
@export var rarity: Rarity = Rarity.COMMON
@export var description: String = ""

## Burn system properties
@export_group("Burn Timer")
## How fast this item burns per second (base rate before multipliers).
@export var base_burn_rate: float = 0.3
## Starting timer in seconds when this item is picked up.
@export var initial_burn_time: float = 180.0
## Time currency cost to extend burn timer by 1 second.
@export var burn_cost_to_extend: float = 1.0
## How much time currency this item yields when scrapped.
@export var time_currency_value: float = 5.0

## Original .tres path — set when an ItemData is .duplicate()'d with a rarity
## override so we can still re-spawn it via MultiplayerSpawner later.
## Empty on non-duplicated (original) resources; use get_source_path() instead.
var _original_resource_path: String = ""

func get_source_path() -> String:
	## Returns the .tres resource path for spawning this item.
	## Works for both original resources (resource_path) and duplicates
	## whose resource_path is empty after .duplicate().
	if _original_resource_path != "":
		return _original_resource_path
	return resource_path

## Visual (placeholder for now)
@export_group("Visual")
@export var icon: Texture2D = null
@export var mesh_color: Color = Color.WHITE
