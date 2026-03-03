extends RigidBody3D

## Cosmetic debris cube with angle-dependent friction.
## Frictionless physics material lets debris slide off walls/ceilings.
## This script adds friction back for floor-like contacts only:
##   - Contact normal ≤50° from up → full friction
##   - 50°–90° → friction fades to zero
##   - ≥90° (ceiling) → no friction

const FRICTION_DECEL := 8.0  ## m/s² deceleration at full friction
const _COS_FULL := 0.6427876  ## cos(50°) — full friction threshold
## cos(90°) = 0.0 — zero friction threshold

# ---- Debug tracking (read by DebrisManager on release) ----
var dbg_had_floor_contact := false  ## True if any contact had up_dot > 0.3
var dbg_had_any_contact := false    ## True if any contact at all
var dbg_spawn_y := 0.0              ## Y position when spawned
var dbg_lowest_y := 999.0           ## Lowest Y reached during lifetime
var dbg_spawn_speed := 0.0          ## Speed at spawn
var dbg_contact_speed := 0.0        ## Speed at first floor contact
var dbg_frame_count := 0            ## Physics frames active


func _integrate_forces(state: PhysicsDirectBodyState3D) -> void:
	dbg_frame_count += 1
	var cur_y := state.transform.origin.y
	if cur_y < dbg_lowest_y:
		dbg_lowest_y = cur_y

	var count := state.get_contact_count()
	if count == 0:
		return

	if not dbg_had_any_contact:
		dbg_had_any_contact = true

	# Find strongest floor-like friction across all contacts.
	var best := 0.0
	for i in count:
		var up_dot := state.get_contact_local_normal(i).dot(Vector3.UP)
		if up_dot <= 0.0:
			continue
		if not dbg_had_floor_contact and up_dot > 0.3:
			dbg_had_floor_contact = true
			dbg_contact_speed = state.linear_velocity.length()
		if up_dot >= _COS_FULL:
			best = 1.0
			break
		best = maxf(best, up_dot / _COS_FULL)

	if best <= 0.0:
		return

	var decel := best * FRICTION_DECEL * state.step

	var vel := state.linear_velocity
	var speed := vel.length()
	if speed > 0.01:
		state.linear_velocity = vel * maxf((speed - decel) / speed, 0.0)

	var ang := state.angular_velocity
	var ang_speed := ang.length()
	if ang_speed > 0.01:
		state.angular_velocity = ang * maxf((ang_speed - decel) / ang_speed, 0.0)
