extends RefCounted
class_name ModifierBase

## Runtime behavior base class for weapon modifiers.
##
## Subclasses override hook methods to alter weapon behavior at specific points
## in the fire/hit pipeline. The weapon calls these hooks automatically.
##
## Lifecycle:
##   1. WeaponBase.add_modifier(data) creates an instance via data.modifier_script.new()
##   2. setup(data, weapon) is called — store references
##   3. on_attach() is called — apply persistent stat changes
##   4. Hooks fire during weapon use (on_fire, on_hit, on_projectile_launch, on_tick)
##   5. on_detach() is called when removed — undo persistent stat changes
##
## Hook pattern: hooks receive mutable context and return modified values.
## Multiple modifiers chain: output of one feeds into the next.

var modifier_data: ModifierData
var weapon: WeaponBase


func setup(data: ModifierData, w: WeaponBase) -> void:
	modifier_data = data
	weapon = w


# ======================================================================
#  Hook points — override in subclasses
# ======================================================================

func on_attach() -> void:
	## Called when this modifier is added to a weapon.
	## Use for persistent stat changes (e.g., +damage, -fire_rate).
	pass


func on_detach() -> void:
	## Called when this modifier is removed from a weapon.
	## Undo any persistent stat changes made in on_attach().
	pass


func on_fire(params: Dictionary) -> Dictionary:
	## Called just before the weapon fires. Receives and returns fire parameters.
	## Keys: "aim_origin" (Vector3), "aim_direction" (Vector3), "spread" (float).
	## Modify and return to alter the shot.
	return params


func on_projectile_launch(_projectile: Node3D) -> void:
	## Called after a projectile is spawned but before it's added to the scene.
	## Modify projectile properties (speed, collision, visual effects).
	pass


func on_hit(_target: Node3D, damage: float, _hit_position: Vector3) -> float:
	## Called when a weapon hit lands on a target. Returns modified damage.
	## Chain: each modifier processes damage from the previous modifier.
	return damage


func on_tick(_delta: float) -> void:
	## Called every physics frame while the modifier is attached.
	## Use for time-based effects (cooldown tracking, passive auras).
	pass
