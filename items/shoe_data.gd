extends ItemData
class_name ShoeData

## Shoe-specific item data. Shoes provide a speed bonus and have an
## inverted rarity/burn relationship: rarer shoes last longer.

@export_group("Shoe Stats")
## Percentage speed bonus (e.g. 0.05 = +5%).
@export var speed_bonus: float = 0.05
