extends RigidBody3D

## Cosmetic debris cube with angle-dependent friction.
## Frictionless physics material lets debris slide off walls/ceilings.
## This script adds friction back for floor-like contacts only:
##   - Contact normal ≤50° from up → full friction
##   - 50°–90° → friction fades to zero
##   - ≥90° (ceiling) → no friction
##
## Pool lifecycle (never-freeze architecture):
##   Pool bodies are always DYNAMIC with can_sleep=true, gravity_scale=0.
##   They sleep at (0, -10000, 0) with zero cost.  At spawn, C++ sets
##   gravity_scale=1 + transform + velocity via direct PhysicsServer API.
##   _integrate_forces auto-detects the gravity transition and initializes
##   debug tracking on the first active frame (zero C++ property sets needed).

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


## Holds a GDScript reference to the material so the Resource stays alive
## (and its RenderingServer RID remains valid) for the debris lifetime.
## Without this, if the source structure is freed, the RS material RID
## becomes invalid and debris falls back to the default gray BoxMesh.
var material_ref: Material = null

var _dbg_trace_frames := 0  ## How many frames to print trace logs (set at spawn)

func _integrate_forces(state: PhysicsDirectBodyState3D) -> void:
	# Auto-detect pool→active transition via gravity.
	# Pool bodies have gravity_scale=0 (total_gravity≈zero).
	# C++ spawn sets gravity_scale=1 → first active frame has real gravity.
	var grav_sq := state.total_gravity.length_squared()
	if grav_sq < 0.01:
		if dbg_frame_count > 0:
			# Was active, now gravity is zero — log the transition
			print("[DebrisPhys] GRAVITY ZEROED on frame %d: vel=%s pos=%s gravity=%s sleeping=%s" % [
				dbg_frame_count, str(state.linear_velocity), str(state.transform.origin),
				str(state.total_gravity), str(sleeping)])
		# Pool body settling after deactivation — reset counter and skip.
		dbg_frame_count = 0
		return

	dbg_frame_count += 1

	# Log first 3 active frames to trace velocity/gravity/position.
	if dbg_frame_count <= 3:
		print("[DebrisPhys] frame=%d vel=%s (spd=%.2f) pos=%s gravity=%s sleeping=%s" % [
			dbg_frame_count, str(state.linear_velocity), state.linear_velocity.length(),
			str(state.transform.origin), str(state.total_gravity), str(sleeping)])

	# Auto-init debug vars on first active frame.
	if dbg_frame_count == 1:
		dbg_had_floor_contact = false
		dbg_had_any_contact = false
		dbg_spawn_y = state.transform.origin.y
		dbg_lowest_y = dbg_spawn_y
		dbg_spawn_speed = state.linear_velocity.length()
		dbg_contact_speed = 0.0

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
