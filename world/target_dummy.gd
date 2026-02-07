extends StaticBody3D

## Target dummy for testing weapons. Takes damage, shows health, respawns.

const MAX_HEALTH := 100.0
const RESPAWN_DELAY := 3.0

var health: float = MAX_HEALTH
var is_alive: bool = true
var _respawn_timer: float = 0.0

@onready var label: Label3D = $Label3D
@onready var body_mesh: MeshInstance3D = $MeshInstance3D


func _process(delta: float) -> void:
	# Update health label
	if label:
		if is_alive:
			label.text = "HP: %d / %d" % [ceili(health), int(MAX_HEALTH)]
		else:
			label.text = "DEAD (%.1fs)" % _respawn_timer

	# Handle respawn on server
	if not is_alive and multiplayer.is_server():
		_respawn_timer -= delta
		if _respawn_timer <= 0.0:
			_do_respawn()


func take_damage(amount: float, _attacker_id: int) -> void:
	## Server-only: apply damage to this dummy.
	if not multiplayer.is_server() or not is_alive:
		return

	health -= amount
	if health <= 0.0:
		health = 0.0
		_die()


func _die() -> void:
	is_alive = false
	_respawn_timer = RESPAWN_DELAY
	if body_mesh:
		body_mesh.transparency = 0.7
	# Disable collision while dead
	$CollisionShape3D.set_deferred("disabled", true)
	print("Target dummy destroyed!")


func _do_respawn() -> void:
	is_alive = true
	health = MAX_HEALTH
	if body_mesh:
		body_mesh.transparency = 0.0
	$CollisionShape3D.set_deferred("disabled", false)
