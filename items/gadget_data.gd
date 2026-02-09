extends ItemData
class_name GadgetData

## Gadget-specific item data. Multi-use items that stay in inventory until burn timer expires.
## Unlike ConsumableData (single-use), gadgets persist across activations.

@export_group("Gadget")
## Which gadget type this item represents.
@export_enum("GRAPPLING_HOOK") var gadget_type: int = 0
