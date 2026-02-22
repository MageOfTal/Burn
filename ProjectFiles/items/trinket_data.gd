extends ItemData
class_name TrinketData

## Trinket item data. Trinkets are attachable modifiers that can be slotted
## into shoes (and eventually other equipment) to grant bonus effects.
## Unlike ammo merging, trinkets are removable — they can be detached
## and returned to the player's trinket bag.

@export_group("Trinket Stats")
## Number of extra air-jumps granted when attached to a shoe (e.g. 1 = double jump).
@export var extra_jumps: int = 0

@export_group("Trinket Attachment")
## Can this trinket be attached to shoes?
@export var attach_to_shoes: bool = true
