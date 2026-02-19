extends RigidBody3D
class_name ToadShadowBody

## Dynamic RigidBody3D that shadows a CharacterBody3D for native Jolt collision.
##
## Because CharacterBody3D uses kinematic move_and_slide(), it doesn't participate
## in Jolt's rigid body solver. This shadow body provides a real 80 kg dynamic
## presence so physics objects (toad rain, boulders, etc.) collide with proper
## mass-weighted momentum exchange.
##
## How it works:
##   1. Jolt's solver runs from the previous step, applying collision impulses.
##   2. _integrate_forces (next step): Read state.linear_velocity BEFORE overriding.
##      The difference from what we set last frame IS the solver's impulse.
##      Store it in _pending_push for transfer to the player.
##      Then override velocity to: target.velocity + positional correction.
##      Jolt's integrator applies this velocity, moving the shadow to the player.
##   3. _physics_process: Transfer _pending_push to the player's _external_push.
##
## Position correction is done entirely through velocity — NEVER by setting
## state.transform (Jolt treats that as externally controlled = infinite mass)
## and NEVER by teleporting global_position (bypasses CCD broadphase state).
## The only exception is large discontinuities (>5m, e.g. respawn) where a
## one-time teleport in _physics_process is unavoidable.
##
## Must be a SIBLING of the CharacterBody3D in the scene tree (not a child).
## Nesting physics bodies causes erratic transform conflicts in Godot 4.x.

const SHADOW_MASS: float = 80.0
const DEBUG_COLOR: Color = Color(0.2, 0.5, 1.0, 0.3)  ## Transparent blue

## The CharacterBody3D this shadow follows. Set by player.gd on creation.
var target: CharacterBody3D = null

## What we set velocity to last frame in _integrate_forces.
## Compared against the velocity at the START of the next _integrate_forces call
## to extract what the solver changed.
var _velocity_we_set: Vector3 = Vector3.ZERO

## Solver impulse captured in _integrate_forces, waiting to be transferred
## to the player in _physics_process. We can't write to target._external_push
## from _integrate_forces because it runs on the physics thread (threaded physics).
var _pending_push: Vector3 = Vector3.ZERO

## Set to true by _physics_process when a large-distance teleport is needed.
## _integrate_forces reads this flag and skips the solver-delta capture for
## one frame, since the velocity after a teleport is meaningless.
var _skip_next_delta: bool = false

var _debug_timer: float = 0.0


func _ready() -> void:
	contact_monitor = true
	max_contacts_reported = 8


func take_damage(amount: float, from_attacker_id: int = -1) -> void:
	## Proxy damage to the player this shadow body represents.
	if target != null and is_instance_valid(target) and target.has_method("take_damage"):
		target.take_damage(amount, from_attacker_id)


func _integrate_forces(state: PhysicsDirectBodyState3D) -> void:
	if target == null or not is_instance_valid(target):
		state.linear_velocity = Vector3.ZERO
		state.angular_velocity = Vector3.ZERO
		_velocity_we_set = Vector3.ZERO
		return

	# --- Solver impulse capture ---
	# We set velocity to _velocity_we_set last frame. If the solver applied any
	# collision impulses since then, state.linear_velocity will differ.
	# That difference IS the push we want to transfer to the player.
	if _skip_next_delta:
		_skip_next_delta = false
	else:
		var vel_from_jolt: Vector3 = state.linear_velocity
		var solver_delta: Vector3 = vel_from_jolt - _velocity_we_set

		if solver_delta.length() > 0.01:
			_pending_push += solver_delta
			print("[ShadowBody] IMPULSE captured: delta=%s (len=%.3f) vel_from_jolt=%s we_set=%s pending=%s" % [
				solver_delta, solver_delta.length(), vel_from_jolt, _velocity_we_set, _pending_push])

		# DEBUG: Log contact info to verify mass-ratio scaling is active
		var contact_count_now: int = state.get_contact_count()
		if contact_count_now > 0 and solver_delta.length() > 0.5:
			for i in contact_count_now:
				var collider = state.get_contact_collider_object(i)
				var collider_name: String = collider.name if collider else "null"
				var collider_vel: Vector3 = state.get_contact_collider_velocity_at_position(i)
				var impulse: Vector3 = state.get_contact_impulse(i)
				var normal: Vector3 = state.get_contact_local_normal(i)
				print("[ShadowBody] CONTACT[%d]: collider=%s normal=%s impulse=%s (len=%.3f) collider_vel=%s" % [
					i, collider_name, normal, impulse, impulse.length(), collider_vel])

	# --- Velocity override with positional correction ---
	# Jolt integrates: new_pos = old_pos + velocity * dt.
	# We want the shadow to arrive at target.global_position after this step.
	# So: velocity = target.velocity + (target_pos - current_pos) / dt.
	# This closes any drift from solver pushback or floating-point accumulation
	# while keeping motion smooth for CCD.
	var dt: float = state.step
	var pos_error: Vector3 = target.global_position - state.transform.origin
	var correction: Vector3 = pos_error / dt if dt > 0.0 else Vector3.ZERO
	var final_velocity: Vector3 = target.velocity + correction

	state.linear_velocity = final_velocity
	state.angular_velocity = Vector3.ZERO
	_velocity_we_set = final_velocity


func _physics_process(delta: float) -> void:
	if target == null or not is_instance_valid(target):
		return
	if not multiplayer.is_server():
		return

	# Transfer any pending push from _integrate_forces to the player.
	if _pending_push.length_squared() > 0.0001:
		target._external_push += _pending_push
		print("[ShadowBody] PUSH transferred: push=%s (len=%.3f) total_external=%s" % [
			_pending_push, _pending_push.length(), target._external_push])
		_pending_push = Vector3.ZERO

	# Large-distance safety teleport (respawn, initialization, etc.).
	# After a teleport the velocity-based delta is meaningless, so we flag
	# _integrate_forces to skip one frame of solver-delta capture.
	var offset: Vector3 = target.global_position - global_position
	if offset.length_squared() > 25.0:  # >5m
		global_position = target.global_position
		_velocity_we_set = target.velocity
		_skip_next_delta = true

	# Periodic status
	_debug_timer += delta
	if _debug_timer >= 2.0:
		_debug_timer = 0.0
		print("[ShadowBody] pos=%s player_pos=%s offset=%.4f player_vel=%s layer=%d mask=%d" % [
			global_position, target.global_position, offset.length(), target.velocity, collision_layer, collision_mask])
