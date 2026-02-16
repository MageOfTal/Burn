extends RigidBody3D
class_name ToadShadowBody

## Dynamic RigidBody3D that shadows a CharacterBody3D for native Jolt collision.
##
## Because CharacterBody3D uses kinematic move_and_slide(), it doesn't participate
## in Jolt's rigid body solver. This shadow body provides a real 80 kg dynamic
## presence so physics objects (toad rain, boulders, etc.) collide with proper
## mass-weighted momentum exchange — not infinite-mass brick-wall bounces.
##
## Uses custom_integrator to override force integration each frame:
##   - Teleports position directly via state.transform (no velocity artifact)
##   - Sets velocity to match the CharacterBody3D so the solver sees correct momentum
##
## Position is set via transform, NOT via velocity correction. This is critical:
## if we added a velocity term to correct drift, the shadow body would "chase"
## objects after collisions push it away, causing objects to phase through instead
## of bouncing off cleanly.
##
## Must be a SIBLING of the CharacterBody3D in the scene tree (not a child).
## Nesting physics bodies causes erratic transform conflicts in Godot 4.x.
##
## Push transfer uses body_entered + the collider's pre_collision_velocity
## (snapshotted before Jolt's solver runs). This avoids the known issue where
## body_entered fires with post-bounce velocities, making closing speed appear
## as separation and zeroing out the push.

const SHADOW_MASS: float = 80.0
const PUSH_RESTITUTION: float = 0.5
const MIN_CLOSING_SPEED: float = 0.3
const MAX_PUSH_SPEED: float = 15.0

## The CharacterBody3D this shadow follows. Set by player.gd on creation.
var target: CharacterBody3D = null


func _integrate_forces(state: PhysicsDirectBodyState3D) -> void:
	if target == null or not is_instance_valid(target):
		state.linear_velocity = Vector3.ZERO
		state.angular_velocity = Vector3.ZERO
		return

	# Teleport to the player's position directly via transform.
	# This avoids adding a velocity correction term that would make the shadow
	# body "chase" objects after the solver pushes it away — causing phase-through.
	var xform := state.transform
	xform.origin = target.global_position
	state.transform = xform

	# Match the CharacterBody3D's velocity so the solver sees correct momentum.
	# Only the player's actual movement velocity — no position correction added.
	state.linear_velocity = target.velocity

	# No angular motion — player rotation is not physics-driven
	state.angular_velocity = Vector3.ZERO


func _on_body_entered(body: Node) -> void:
	if target == null or not is_instance_valid(target):
		return
	if not target.get("is_alive"):
		return
	if not (body is RigidBody3D):
		return

	# Use pre-collision velocity if available (snapshotted before Jolt's solver).
	# body_entered fires post-solve, so body.linear_velocity is post-bounce and
	# useless for closing speed calculations.
	var body_vel: Vector3 = body.linear_velocity
	var pre_vel = body.get("pre_collision_velocity")
	if pre_vel != null:
		body_vel = pre_vel

	var char_center: Vector3 = target.global_position + Vector3(0, 0.9, 0)
	var to_char: Vector3 = char_center - body.global_position
	var dist: float = to_char.length()
	if dist < 0.001:
		return
	var contact_normal: Vector3 = to_char / dist

	var relative_vel: Vector3 = body_vel - target.velocity
	var closing_speed: float = relative_vel.dot(contact_normal)
	if closing_speed < MIN_CLOSING_SPEED:
		return

	var mass_other: float = body.mass
	var reduced_mass: float = (mass_other * SHADOW_MASS) / (mass_other + SHADOW_MASS)
	var impulse_magnitude: float = (1.0 + PUSH_RESTITUTION) * closing_speed * reduced_mass

	var char_push: Vector3 = contact_normal * (impulse_magnitude / SHADOW_MASS)
	if char_push.length() > MAX_PUSH_SPEED:
		char_push = char_push.normalized() * MAX_PUSH_SPEED
	target.velocity += char_push
	print("[ShadowBody] PUSH %s → %.2f m/s (closing=%.1f)" % [body.name, char_push.length(), closing_speed])
