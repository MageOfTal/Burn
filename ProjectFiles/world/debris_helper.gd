extends RefCounted
class_name DebrisHelper

## Static utility for spawning small cosmetic debris cubes (client-side only).
## Used by DestructibleBlockStructure for wall/ramp debris.
## All debris uses collision layer 32 (layer 6) and mask 2049 (world + smooth wall collision).
##
## Performance notes:
##   - Debris is purely cosmetic: spawned on clients, NOT on the server.
##   - Uses plain RigidBody3D (NOT PhysicsBodyBase) — no overlap checks.
##   - Collision shape is shared (not duplicated per debris cube).
##   - No Timer node: uses SceneTreeTimer for auto-cleanup (saves 1 node each).
##   - Freezes when velocity drops below threshold (removes from solver).
##   - Global budget cap via DebrisManager autoload.

## Base max debris launch speed (m/s). Hitscans cap here with no overkill.
const MAX_DEBRIS_SPEED := 8.0
## Absolute max when overkill_frac = 1.0 (excess damage = full block HP).
const OVERKILL_MAX_SPEED := 15.0
## Fraction of impact speed transferred to debris.
const SPEED_TRANSFER := 0.7

## Spawn small debris cubes flying toward the shot origin.
## Parameters:
##   parent_node: Node to add debris children to
##   block_pos: world position of the destroyed block
##   blast_center: world position of the shot origin (debris flies TOWARD this)
##   count: number of debris cubes to spawn
##   material: StandardMaterial3D to apply to debris meshes
##   impact_speed: speed of the projectile that hit (m/s). INF = hitscan (caps to max).
##   overkill_frac: 0.0–1.0, how much excess damage beyond block HP. Raises cap from 8→15 m/s.
##   config: Dictionary with keys:
##     "size"     (float)  — cube edge length
##     "lifetime" (float)  — seconds before auto-delete
##     "mass"     (float)  — RigidBody3D mass
##     "name"     (String) — node name for the debris

## Velocity below which debris freezes to static (removes from solver).
const FREEZE_SPEED := 0.3
## How often to check for freeze eligibility (seconds).
const FREEZE_CHECK_INTERVAL := 0.5

static func spawn_debris(
	parent_node: Node,
	block_pos: Vector3,
	blast_center: Vector3,
	count: int,
	material: StandardMaterial3D,
	impact_speed: float,
	overkill_frac: float,
	config: Dictionary,
) -> void:
	if GameManager.disable_debris:
		return

	var size: float = config.get("size", 0.15)
	var lifetime: float = config.get("lifetime", 5.0)
	var mass_val: float = config.get("mass", 0.5)
	var debris_name: String = config.get("name", "Debris")

	# Debris speed = impact_speed * 0.7, capped at 8 m/s base (up to 15 with overkill).
	var effective_max: float = lerpf(MAX_DEBRIS_SPEED, OVERKILL_MAX_SPEED, clampf(overkill_frac, 0.0, 1.0))
	var debris_speed: float = minf(impact_speed * SPEED_TRANSFER, effective_max)
	var impulse: float = debris_speed * mass_val

	var debris_mesh := BoxMesh.new()
	debris_mesh.size = Vector3.ONE * size
	# Shared collision shape — all debris cubes use the same shape resource.
	var debris_shape := BoxShape3D.new()
	debris_shape.size = Vector3.ONE * size

	# Debris launches TOWARD the shot origin, scattered within 35 degrees.
	var toward := (blast_center - block_pos)
	if toward.length() < 0.1:
		toward = Vector3(randf_range(-1, 1), 1, randf_range(-1, 1))
	toward = toward.normalized()

	var cone_cos := cos(deg_to_rad(35.0))

	for i in count:
		var debris := RigidBody3D.new()
		debris.name = debris_name
		debris.mass = mass_val
		debris.collision_layer = CollisionLayers.DEBRIS
		debris.collision_mask = CollisionLayers.SURFACE
		debris.contact_monitor = false
		debris.can_sleep = true  # Let Jolt auto-sleep when velocity drops

		# Single shared collision shape (Godot duplicates internally per body).
		var col := CollisionShape3D.new()
		col.shape = debris_shape
		debris.add_child(col)

		var mesh_inst := MeshInstance3D.new()
		mesh_inst.mesh = debris_mesh
		mesh_inst.material_override = material
		debris.add_child(mesh_inst)

		parent_node.add_child(debris, true)
		debris.global_position = block_pos + Vector3(
			randf_range(-0.2, 0.2),
			randf_range(-0.2, 0.2),
			randf_range(-0.2, 0.2),
		)

		# Random direction within a 35-degree cone toward the shot origin.
		var scatter := Vector3(randf_range(-1, 1), randf_range(-1, 1), randf_range(-1, 1)).normalized()
		var impulse_dir := (toward + scatter * (1.0 - cone_cos)).normalized()
		impulse_dir.y = maxf(impulse_dir.y, 0.15)
		debris.apply_central_impulse(impulse_dir * impulse)
		debris.apply_torque_impulse(Vector3(
			randf_range(-2, 2), randf_range(-2, 2), randf_range(-2, 2)
		))

		# Register with global budget manager.
		DebrisManager.register(debris)

		# Auto-cleanup via SceneTreeTimer (no Timer node needed).
		var tree := parent_node.get_tree()
		if tree:
			var actual_lifetime := lifetime + randf_range(0, 1.0)
			tree.create_timer(actual_lifetime).timeout.connect(
				func(): _cleanup_debris(debris)
			)


static func _cleanup_debris(debris: RigidBody3D) -> void:
	if is_instance_valid(debris):
		DebrisManager.unregister(debris)
		debris.queue_free()
