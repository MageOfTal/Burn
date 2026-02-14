extends RigidBody3D
class_name TowerChunk

## Falling debris chunk from a collapsed spiral tower.
## Deals damage to players, terrain, and structures on first impact.
## Damage scales with velocity, mass, and impact angle.
##
## Server-authoritative: only the server runs damage logic.
## Created by spiral_tower.gd via _sync_collapse_impact RPC.

# ======================================================================
#  Constants
# ======================================================================

const MIN_DAMAGE_SPEED := 3.0          ## Minimum impact speed to deal damage (m/s)
const DAMAGE_MULTIPLIER := 1.5         ## Damage = speed * sqrt(mass_kg) * this * angle_mult
const CRATER_BASE_RADIUS := 0.5        ## Base crater radius on terrain hit
const CRATER_MASS_SCALE := 0.003       ## Extra crater radius per kg of mass
const MAX_DAMAGE_EVENTS := 3           ## Max separate damage events per chunk

# ======================================================================
#  Properties (set by spiral_tower.gd before adding to scene)
# ======================================================================

var chunk_mass: float = 200.0          ## Mass in kg for damage calculation (set by spiral_tower.gd)
var attacker_id: int = -1              ## Player who caused the collapse

# ======================================================================
#  Internal state
# ======================================================================

var _damage_events: int = 0            ## How many things we've damaged so far


func _ready() -> void:
	if not multiplayer.is_server():
		return
	body_entered.connect(_on_body_entered)


func _on_body_entered(body: Node) -> void:
	if not multiplayer.is_server():
		return
	if _damage_events >= MAX_DAMAGE_EVENTS:
		return

	var impact_speed := linear_velocity.length()
	if impact_speed < MIN_DAMAGE_SPEED:
		return

	# --- Impact angle bonus ---
	# Steeper (more vertical) impacts deal more damage, up to 1.5x
	var down_dot := absf(linear_velocity.normalized().dot(Vector3.DOWN))
	var angle_mult := 1.0 + down_dot * 0.5  # 1.0 (horizontal) to 1.5 (vertical)

	# Damage scales with speed, sqrt(mass), and impact angle.
	# Using sqrt(mass) so heavier slabs hit harder but not linearly —
	# a 1000kg slab isn't 5x deadlier than a 200kg slab, just ~2.2x.
	# Examples at vertical impact (angle_mult = 1.5):
	#   200kg slab at 10 m/s: 10 * 14.1 * 1.5 * 1.5 ≈ 318 damage (lethal)
	#   200kg slab at  5 m/s:  5 * 14.1 * 1.5 * 1.5 ≈ 159 damage (heavy hit)
	#  1000kg slab at 10 m/s: 10 * 31.6 * 1.5 * 1.5 ≈ 711 damage (overkill)
	var mass_factor: float = sqrt(chunk_mass)
	var base_damage: float = impact_speed * mass_factor * DAMAGE_MULTIPLIER * angle_mult

	# --- Damage player ---
	if body.has_method("take_damage"):
		body.take_damage(base_damage, attacker_id)
		_damage_events += 1
		print("[TowerChunk] Hit player %s for %.1f damage (speed: %.1f, mass: %.2f, angle: %.2f)" % [
			body.name, base_damage, impact_speed, chunk_mass, angle_mult])
		return

	# --- Damage destructible structure ---
	# Walk up to find damageable parent (same as rocket pattern)
	var target := _find_damageable(body)
	if target:
		if target.has_method("take_damage_at"):
			var chunk_radius: float = 1.0 + mass_factor * 0.15
			target.take_damage_at(global_position, base_damage, chunk_radius, attacker_id)
		elif target.has_method("take_damage"):
			target.take_damage(base_damage, attacker_id)
		_damage_events += 1
		return

	# --- Terrain impact (create crater) ---
	# If we hit something on layer 1 (world geometry) that isn't damageable,
	# it's likely terrain. Create a small crater.
	if body is StaticBody3D:
		var seed_world := _find_seed_world()
		if seed_world and seed_world.has_method("create_crater"):
			var crater_radius: float = CRATER_BASE_RADIUS + chunk_mass * CRATER_MASS_SCALE
			seed_world.create_crater(global_position, crater_radius, 0.3, attacker_id)
		_damage_events += 1


func _find_damageable(node: Node) -> Node:
	## Walk up the tree to find a damageable ancestor.
	var current := node
	var first_damageable: Node = null
	for _i in 4:
		if current == null:
			break
		if current.has_method("take_damage_at"):
			return current
		if first_damageable == null and current.has_method("take_damage"):
			first_damageable = current
		current = current.get_parent()
	return first_damageable


func _find_seed_world() -> Node:
	var sw := get_tree().current_scene.get_node_or_null("SeedWorld")
	if sw == null:
		sw = get_tree().current_scene.get_node_or_null("BlockoutMap/SeedWorld")
	return sw
