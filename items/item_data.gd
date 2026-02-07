extends Resource
class_name ItemData

## Base class for all item definitions. Saved as .tres files.

enum ItemType { WEAPON, CONSUMABLE, GADGET, MATERIAL }
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

## Visual (placeholder for now)
@export_group("Visual")
@export var icon: Texture2D = null
@export var mesh_color: Color = Color.WHITE
