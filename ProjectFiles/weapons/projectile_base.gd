extends PhysicsBodyBase
class_name ProjectileBase

## Base class for all projectile types (bubbles, rubber balls, rockets, etc.).
##
## Provides a unified interface and shared lifecycle:
##   - launch(direction, shooter_id, damage): entry point called by the spawner
##   - Lifetime timer with automatic cleanup via queue_free()
##   - Server-authoritative physics process (_server_process)
##   - Server-only collision wiring (body_entered signal)
##   - Shooter immunity window
##   - Destruction VFX pattern via _on_destroyed()
##   - Ammo override system for combo weapons
##   - Mass-weighted character push via PhysicsBodyBase
##
## Subclasses override:
##   - _setup(): configure physics properties and visuals (called from _ready)
##   - _server_process(delta): subclass-specific server logic (drift, tunneling, etc.)
##   - _on_body_hit(body): collision response (pop, bounce, explode)
##   - _on_destroyed(): cleanup/VFX before queue_free
##   - get_max_lifetime() -> float: how long before auto-destruction
##
## Hierarchy: RigidBody3D → PhysicsBodyBase → ProjectileBase → BubbleProjectile etc.

# ======================================================================
#  Shared state
# ======================================================================

var _shooter_id: int = -1
var _damage: float = 0.0
var _lifetime: float = 0.0
var _is_terminated: bool = false

## Ammo override system: when set, the projectile uses alternate behavior on destruction.
## (e.g., rocket scatters ammo projectiles instead of normal AOE)
var _ammo_projectile_scene: PackedScene = null
var _ammo_explosion_spawn_count: int = 0
var _ammo_damage_mult: float = 1.0

# ======================================================================
#  Launch interface (called by MultiplayerSpawner on ALL peers)
# ======================================================================

func launch(direction: Vector3, shooter_id: int, damage: float) -> void:
	## Called by the ProjectileSpawner on ALL peers before adding to the scene tree.
	## Sets initial velocity and stores shooter/damage info.
	## Subclasses that need custom launch behavior should override and call super.
	_shooter_id = shooter_id
	_damage = damage
	linear_velocity = direction.normalized() * get_launch_speed()


## Override in subclass to set the launch speed.
func get_launch_speed() -> float:
	return 10.0


## Override in subclass to set the maximum lifetime before auto-destruction.
func get_max_lifetime() -> float:
	return 10.0


# ======================================================================
#  Ammo override system
# ======================================================================

func set_ammo_override(ammo: WeaponData) -> void:
	## Called by WeaponProjectile when ammo is slotted.
	## Subclasses interpret this however they wish (e.g., rocket scatters projectiles).
	if ammo and ammo.can_slot_as_ammo:
		_ammo_projectile_scene = ammo.projectile_scene
		_ammo_explosion_spawn_count = ammo.ammo_explosion_spawn_count
		_ammo_damage_mult = ammo.ammo_damage_mult


func has_ammo_override() -> bool:
	return _ammo_projectile_scene != null and _ammo_explosion_spawn_count > 0


# ======================================================================
#  Lifecycle
# ======================================================================

func _ready() -> void:
	# Subclass configures physics, visuals, collision layers
	_setup()

	# Wire server-only collision handling. Explicitly disable contact_monitor
	# on clients to avoid per-frame contact tracking overhead.
	if multiplayer.is_server():
		contact_monitor = true
		max_contacts_reported = 4
		body_entered.connect(_on_body_entered)
	else:
		contact_monitor = false


## Override in subclass to configure physics properties, visuals, and collision layers.
## Called from _ready() before collision wiring.
func _setup() -> void:
	pass


func _physics_process(delta: float) -> void:
	super._physics_process(delta)  # PhysicsBodyBase: mass-weighted character push
	if not multiplayer.is_server():
		return

	_lifetime += delta
	if _lifetime >= get_max_lifetime() and not _is_terminated:
		_terminate()
		return

	_server_process(delta)


## Override in subclass for per-frame server logic (brownian drift, tunneling raycast, etc.).
func _server_process(_delta: float) -> void:
	pass


# ======================================================================
#  Collision
# ======================================================================

func _on_body_entered(body: Node) -> void:
	if not multiplayer.is_server() or _is_terminated:
		return
	# Shooter immunity: skip the shooter for a brief window after launch.
	# Subclasses can override get_shooter_immunity_time() to customize.
	if _is_shooter_immune(body):
		return
	_on_body_hit(body)


## Override in subclass to handle collision with a body (pop, bounce, explode, etc.).
func _on_body_hit(_body: Node) -> void:
	pass


## Returns true if the body is the shooter and still within the immunity window.
## Subclasses can override for custom immunity logic (e.g., rubber ball clears after first bounce).
func _is_shooter_immune(body: Node) -> bool:
	if body is Player and body.peer_id == _shooter_id:
		return _lifetime < get_shooter_immunity_time()
	return false


## Duration (seconds) during which the shooter is immune to their own projectile.
func get_shooter_immunity_time() -> float:
	return 0.15


# ======================================================================
#  Termination (destruction / expiry)
# ======================================================================

func _terminate() -> void:
	## Called when the projectile should be destroyed (lifetime expired, collision, etc.).
	## Calls _on_destroyed() for subclass cleanup/VFX, then queue_free().
	if _is_terminated:
		return
	_is_terminated = true
	_on_destroyed()
	queue_free()


## Override in subclass for destruction logic and VFX (pop effect, explosion, etc.).
## Called on the server right before queue_free().
func _on_destroyed() -> void:
	pass
