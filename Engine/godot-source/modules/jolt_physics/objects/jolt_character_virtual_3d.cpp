/**************************************************************************/
/*  jolt_character_virtual_3d.cpp                                         */
/**************************************************************************/
/*                         This file is part of:                          */
/*                             GODOT ENGINE                               */
/*                        https://godotengine.org                         */
/**************************************************************************/

#include "jolt_character_virtual_3d.h"

#include "jolt_object_3d.h"

#include "../jolt_physics_server_3d.h"
#include "../misc/jolt_type_conversions.h"
#include "../spaces/jolt_broad_phase_layer.h"
#include "../spaces/jolt_query_collectors.h"
#include "../spaces/jolt_space_3d.h"

#include "core/io/file_access.h"
#include "core/os/os.h"
#include "core/os/time.h"
#include "core/string/print_string.h"

#include "scene/resources/3d/world_3d.h"

#include "Jolt/Physics/Body/BodyFilter.h"
#include "Jolt/Physics/Body/BodyLock.h"
#include "Jolt/Physics/Character/CharacterBase.h"
#include "Jolt/Physics/Collision/CastResult.h"
#include "Jolt/Physics/Collision/CollisionCollectorImpl.h"
#include "Jolt/Physics/Collision/Shape/CapsuleShape.h"
#include "Jolt/Physics/Collision/Shape/RotatedTranslatedShape.h"
#include "Jolt/Physics/Collision/ShapeCast.h"
#include "Jolt/Physics/PhysicsSystem.h"

JoltCharacterVirtual3D::JoltCharacterVirtual3D() {
}

JoltCharacterVirtual3D::~JoltCharacterVirtual3D() {
	_destroy_character();
}

void JoltCharacterVirtual3D::_notification(int p_what) {
	switch (p_what) {
		case NOTIFICATION_EXIT_TREE: {
			_destroy_character();
		} break;
	}
	// Creation is deferred to the first update() call: that runs from
	// _physics_process, i.e. between physics steps when the Jolt worker
	// thread is idle, so the body-creation / narrowphase calls inside
	// CharacterVirtual's constructor don't race the stepping thread.
}

JPH::RefConst<JPH::Shape> JoltCharacterVirtual3D::_build_capsule_shape() const {
	// Godot capsule convention: `capsule_height` is the full height (including
	// both hemispherical caps), `capsule_radius` the radius. The cylindrical
	// section has half-height (height/2 - radius). The shape is centered at
	// the node origin (same convention as a centered Godot CollisionShape3D).
	const float cyl_half_height = MAX(0.0f, capsule_height * 0.5f - capsule_radius);
	JPH::CapsuleShapeSettings capsule_settings(cyl_half_height, capsule_radius);
	capsule_settings.SetEmbedded();
	JPH::ShapeSettings::ShapeResult result = capsule_settings.Create();
	if (result.HasError()) {
		ERR_PRINT(vformat("JoltCharacterVirtual3D: failed to build capsule shape: %s",
				String(result.GetError().c_str())));
		return nullptr;
	}
	return result.Get();
}

void JoltCharacterVirtual3D::_create_character() {
	if (jolt_character != nullptr) {
		return;
	}

	Ref<World3D> world = get_world_3d();
	if (world.is_null()) {
		ERR_PRINT_ONCE("JoltCharacterVirtual3D: get_world_3d() is null — not in a 3D world yet.");
		return;
	}
	const RID space_rid = world->get_space();
	if (!space_rid.is_valid()) {
		ERR_PRINT_ONCE("JoltCharacterVirtual3D: world has no physics space.");
		return;
	}
	JoltPhysicsServer3D *server = JoltPhysicsServer3D::get_singleton();
	if (server == nullptr) {
		ERR_PRINT_ONCE("JoltCharacterVirtual3D: active 3D physics server is not Jolt — JoltCharacterVirtual3D requires the Jolt physics backend.");
		return;
	}
	space = server->get_space(space_rid);
	if (space == nullptr) {
		ERR_PRINT_ONCE("JoltCharacterVirtual3D: could not resolve JoltSpace3D from the world's space RID.");
		return;
	}

	JPH::RefConst<JPH::Shape> shape = _build_capsule_shape();
	if (shape == nullptr) {
		space = nullptr;
		return;
	}

	object_layer = space->map_to_object_layer(JoltBroadPhaseLayer::BODY_DYNAMIC, collision_layer, collision_mask);

	JPH::CharacterVirtualSettings settings;
	settings.mShape = shape;
	settings.mUp = to_jolt(up_direction);
	// Contacts behind this plane (below it, toward the feet) can support the
	// character. For a centered capsule the feet are at local y = -height/2;
	// anything on the lower hemisphere of the bottom cap supports.
	settings.mSupportingVolume = JPH::Plane(JPH::Vec3::sAxisY(), capsule_height * 0.5f - capsule_radius);
	settings.mMaxSlopeAngle = Math::deg_to_rad(max_slope_angle_deg);
	settings.mMass = character_mass;
	settings.mMaxStrength = max_strength;
	settings.mPredictiveContactDistance = predictive_contact_distance;
	settings.mCharacterPadding = character_padding;
	settings.mCollisionTolerance = collision_tolerance;
	settings.mPenetrationRecoverySpeed = penetration_recovery_speed;
	// Route the character's collision detection through Jolt's
	// InternalEdgeRemovingCollector — contacts whose normal disagrees with an
	// adjacent face that also contains the contact point are voided, so mesh
	// triangle seams and voxel block boundaries stop emitting spurious edge
	// normals into the constraint solver. (See header comment.)
	settings.mEnhancedInternalEdgeRemoval = enhanced_internal_edge_removal;
	if (inner_body) {
		// Kinematic inner body on `collision_layer` so weapons / raycasts /
		// sensors / other bodies can detect & hit the player. CharacterVirtual
		// keeps it glued to itself; it's never solved against, so it doesn't
		// re-introduce a second collision-response authority. The constructor
		// calls BodyInterface::CreateAndAddBody — safe here since _create_character
		// runs from update()/_physics_process, between physics steps.
		settings.mInnerBodyShape = shape;
		settings.mInnerBodyLayer = object_layer;
	}

	jolt_character = new JPH::CharacterVirtual(
			&settings,
			to_jolt_r(get_global_position()),
			JPH::Quat::sIdentity(),
			0,
			&space->get_physics_system());

	listener.up = to_jolt(up_direction);
	listener.cos_max_slope = Math::cos(Math::deg_to_rad(max_slope_angle_deg));
	jolt_character->SetListener(&listener);

	// Build stamp: stale engine copies (locked exe variants skipped by
	// build.bat, silently no-op'd build invocations) have repeatedly poisoned
	// in-game experiments. Report the running executable's own modification
	// time — unlike __DATE__/__TIME__ (which only updates when THIS file
	// recompiles), the exe mtime changes on every link, so it identifies the
	// binary unambiguously.
	{
		const String exe_path = OS::get_singleton()->get_executable_path();
		const uint64_t mtime = FileAccess::get_modified_time(exe_path);
		print_line(vformat("[CV] JoltCharacterVirtual3D ready — binary linked %s (this file compiled " __DATE__ " " __TIME__ "; eier=%d, predictive=%.2f)",
				Time::get_singleton()->get_datetime_string_from_unix_time((int64_t)mtime, true),
				(int)enhanced_internal_edge_removal, predictive_contact_distance));
	}
}

void JoltCharacterVirtual3D::ContactListener::OnContactSolve(const JPH::CharacterVirtual * /*p_character*/, const JPH::BodyID &p_body_id2, const JPH::SubShapeID &p_sub_shape_id2, JPH::RVec3Arg p_contact_position, JPH::Vec3Arg p_contact_normal, JPH::Vec3Arg p_contact_velocity, const JPH::PhysicsMaterial * /*p_contact_material*/, JPH::Vec3Arg p_character_velocity, JPH::Vec3 &p_new_character_velocity) {
	solve_calls++;
	const float in_h_len = JPH::Vec3(p_character_velocity.GetX(), 0.0f, p_character_velocity.GetZ()).Length();

	// Verbose capture: log incoming state before the listener decides what to do
	const JPH::Vec3 pre_new_vel = p_new_character_velocity;
	const bool log_this = capture_active;

	if (p_contact_normal.Dot(up) < cos_max_slope) {
		// Non-walkable contact (a wall, or a too-steep slope). JPH's default
		// already strips the velocity going into it — and SolveConstraints
		// cancelled velocity towards too-steep slopes before that — so walk-accel
		// can't climb it and per-frame gravity drags us back down the face. We add
		// one correction: if a walkable contact earlier in this same step
		// re-seated us — turning some horizontal speed into a "climb" vertical
		// (see below) — and this wall now cancels that horizontal motion, the
		// climb vertical has to be forfeited along with it. Otherwise the wall
		// takes the horizontal but leaves the vertical orphaned, and the character
		// rides straight up a ramp-into-a-corner seam. A jump is moving *away*
		// from the ramp so it never triggers a re-seat (had_walkable_reseat stays
		// false) — this leaves jumps, and any other airborne motion, untouched.
		if (had_walkable_reseat && p_new_character_velocity.GetY() > 0.0f && in_h_len > 1.0e-4f) {
			const float out_h_len = JPH::Vec3(p_new_character_velocity.GetX(), 0.0f, p_new_character_velocity.GetZ()).Length();
			const float keep = MIN(1.0f, out_h_len / in_h_len);
			p_new_character_velocity = JPH::Vec3(p_new_character_velocity.GetX(), p_new_character_velocity.GetY() * keep, p_new_character_velocity.GetZ());
		}
		if (log_this) {
			print_line(vformat("[CV-CAP-SOLVE] kind=nonwalkable in_vel=(%.3f,%.3f,%.3f) cn=(%.3f,%.3f,%.3f) cv=(%.3f,%.3f,%.3f) pre_new=(%.3f,%.3f,%.3f) post_new=(%.3f,%.3f,%.3f) in_h=%.3f hwr=%d",
					(float)p_character_velocity.GetX(), (float)p_character_velocity.GetY(), (float)p_character_velocity.GetZ(),
					(float)p_contact_normal.GetX(), (float)p_contact_normal.GetY(), (float)p_contact_normal.GetZ(),
					(float)p_contact_velocity.GetX(), (float)p_contact_velocity.GetY(), (float)p_contact_velocity.GetZ(),
					(float)pre_new_vel.GetX(), (float)pre_new_vel.GetY(), (float)pre_new_vel.GetZ(),
					(float)p_new_character_velocity.GetX(), (float)p_new_character_velocity.GetY(), (float)p_new_character_velocity.GetZ(),
					in_h_len, (int)had_walkable_reseat));
		}
		return;
	}

	// Moving away from this walkable contact (a jump, or a launch off the crest):
	// leave it — JPH won't usually even call us for that, but guard.
	const JPH::Vec3 rel = p_character_velocity - p_contact_velocity;
	if (rel.Dot(p_contact_normal) >= 0.0f) {
		if (log_this) {
			print_line(vformat("[CV-CAP-SOLVE] kind=separating in_vel=(%.3f,%.3f,%.3f) cn=(%.3f,%.3f,%.3f) rel_dot_n=%.4f",
					(float)p_character_velocity.GetX(), (float)p_character_velocity.GetY(), (float)p_character_velocity.GetZ(),
					(float)p_contact_normal.GetX(), (float)p_contact_normal.GetY(), (float)p_contact_normal.GetZ(),
					(float)rel.Dot(p_contact_normal)));
		}
		return;
	}

	// Walkable contact: re-seat the velocity so the player's intent survives the
	// per-frame gravity fold-in. Jolt's clip (`p_new_character_velocity`) removed
	// the into-plane component by adding a multiple of the contact normal — and on
	// a laterally-tilted hill the normal's horizontal part points DOWNHILL, so the
	// clipped direction is rotated off course (~1°/frame at walk speed: the
	// "redirected on hills" drift). The old magnitude-only rescale preserved that
	// rotation. Instead, build the velocity the legs would enforce:
	//   • horizontal = the velocity entering this constraint, verbatim (preserves
	//     earlier wall clips this frame, never rotates on hills);
	//   • vy = the value that makes it tangent to THIS contact relative to the
	//     contact's surface motion: (v_c·n − n.x·vx − n.z·vz)/n.y  (n.y ≥
	//     cos_max_slope > 0 here). Standing still ⇒ vy = 0 ⇒ no slide; sloped
	//     walking ⇒ slope-tangent climb at full horizontal speed; bumps/crests
	//     produce real vy that becomes a launch when the surface ends.
	// Blended by the same mass-ratio clip law SolveConstraints uses, so an
	// infinitely heavy Dynamic floor behaves exactly like Static (clip_frac → 1)
	// and a light prop yields mass-proportionally (mostly Jolt's partial clip).
	//
	// Gate: ONCE per contact per frame. The re-seat compensates the gravity
	// fold-in, which happens once per frame — and it is non-contractive, so
	// letting it fire every solver iteration removed SolveConstraints' decay
	// guarantee and produced the random zero-displacement stalls ("invisible
	// walls"). A repeat solve of the same contact passes through vanilla: the
	// residual clip drains velocity and the solver terminates. (This is also
	// what made the horizontal-tangent re-seat safe to use at all — ungated, it
	// stuck-looped the solver back in May.) If the key array is ever full we
	// also skip: conservative (a hair of speed loss for one frame, replenished
	// by walk-accel) rather than divergent.
	const uint64_t contact_key = ((uint64_t)p_body_id2.GetIndexAndSequenceNumber() << 32) | (uint64_t)p_sub_shape_id2.GetValue();
	for (uint64_t key : reseated_contacts) {
		if (key == contact_key) {
			if (log_this) {
				print_line(vformat("[CV-CAP-SOLVE] kind=walkable_skip(reseated) cn=(%.3f,%.3f,%.3f) in_h=%.3f",
						(float)p_contact_normal.GetX(), (float)p_contact_normal.GetY(), (float)p_contact_normal.GetZ(),
						in_h_len));
			}
			return;
		}
	}
	if (reseated_contacts.size() == reseated_contacts.capacity()) {
		return;
	}
	reseated_contacts.push_back(contact_key);

	const float nx = (float)p_contact_normal.GetX();
	const float ny = (float)p_contact_normal.GetY();
	const float nz = (float)p_contact_normal.GetZ();
	const float vx = (float)p_character_velocity.GetX();
	const float vz = (float)p_character_velocity.GetZ();
	const float vy_tangent = ((float)p_contact_velocity.Dot(p_contact_normal) - nx * vx - nz * vz) / ny;
	const JPH::Vec3 target(vx, vy_tangent, vz);
	// Design note: horizontal speed is preserved VERBATIM on walkable slopes —
	// |target| = h/cosθ grows with the slope angle by design ("don't slow me
	// down walking up hills"). A 3D speed budget (|target| ≤ in_h, i.e.
	// constant along-surface speed) was tried 2026-06-11 and reverted the same
	// day: the cosθ taper read as "suddenly slowed while moving up the ramp"
	// at curvature steps. The flipside — carrying h/cosθ of momentum into a
	// steeper-than-walkable transition — is intended: the steep face is a
	// plain tangent projection (no steep-slope special case, see
	// SolveConstraints), so the player slides up it on momentum, drained by
	// gravity. (A g·dt clamp on the correction VECTOR was also tried
	// 2026-06-10 and removed: no measurable effect.)
	//
	// The re-seat runs at FULL strength regardless of the support's mass (a
	// mass-ratio blend lived here until 2026-06-12). Per the design doctrine:
	// a dynamic support behaves like terrain proportional to how much it
	// pushes back, and the controller's own authority never weakens — walking
	// on a light object keeps full walk speed; the lightness is expressed by
	// the OBJECT being pushed out from under the player (HandleContact), and
	// that motion feeds back here through p_contact_velocity in the target.
	// The blend also wrongly keyed off the body's lone inertia: a 4 kg toad
	// RESTING ON THE GROUND resists like the ground itself, but got treated
	// at ~5% authority.
	p_new_character_velocity = target;
	had_walkable_reseat = true;
	solve_reseats++;
	if (log_this) {
		print_line(vformat("[CV-CAP-SOLVE] kind=walkable_reseat in_vel=(%.3f,%.3f,%.3f) cn=(%.3f,%.3f,%.3f) cv=(%.3f,%.3f,%.3f) pre_new=(%.3f,%.3f,%.3f) post_new=(%.3f,%.3f,%.3f) in_h=%.3f vy_t=%.3f",
				(float)p_character_velocity.GetX(), (float)p_character_velocity.GetY(), (float)p_character_velocity.GetZ(),
				nx, ny, nz,
				(float)p_contact_velocity.GetX(), (float)p_contact_velocity.GetY(), (float)p_contact_velocity.GetZ(),
				(float)pre_new_vel.GetX(), (float)pre_new_vel.GetY(), (float)pre_new_vel.GetZ(),
				(float)p_new_character_velocity.GetX(), (float)p_new_character_velocity.GetY(), (float)p_new_character_velocity.GetZ(),
				in_h_len, vy_tangent));
	}
}

void JoltCharacterVirtual3D::_destroy_character() {
	// JPH::Ref releases the CharacterVirtual (and its inner body) here.
	jolt_character = nullptr;
	space = nullptr;
	object_layer = 0;
}

void JoltCharacterVirtual3D::_sync_position_from_character() {
	if (jolt_character == nullptr) {
		return;
	}
	set_global_position(to_godot(jolt_character->GetPosition()));
}

void JoltCharacterVirtual3D::set_capsule_radius(float p_radius) {
	if (capsule_radius == p_radius) {
		return;
	}
	capsule_radius = p_radius;
	if (jolt_character != nullptr) {
		JPH::RefConst<JPH::Shape> shape = _build_capsule_shape();
		if (shape != nullptr) {
			jolt_character->SetShape(shape, FLT_MAX, JPH::BroadPhaseLayerFilter(), JPH::ObjectLayerFilter(), JPH::BodyFilter(), JPH::ShapeFilter(), space->get_temp_allocator());
			if (jolt_character->GetInnerBodyID().IsInvalid() == false) {
				jolt_character->SetInnerBodyShape(shape);
			}
		}
	}
}

void JoltCharacterVirtual3D::set_capsule_height(float p_height) {
	if (capsule_height == p_height) {
		return;
	}
	capsule_height = p_height;
	if (jolt_character != nullptr) {
		JPH::RefConst<JPH::Shape> shape = _build_capsule_shape();
		if (shape != nullptr) {
			jolt_character->SetShape(shape, FLT_MAX, JPH::BroadPhaseLayerFilter(), JPH::ObjectLayerFilter(), JPH::BodyFilter(), JPH::ShapeFilter(), space->get_temp_allocator());
			if (jolt_character->GetInnerBodyID().IsInvalid() == false) {
				jolt_character->SetInnerBodyShape(shape);
			}
		}
	}
}

void JoltCharacterVirtual3D::update(const Vector3 &p_velocity, float p_delta, const Vector3 &p_gravity) {
	if (jolt_character == nullptr) {
		// Space may not have been ready at ENTER_TREE; try once more.
		_create_character();
		if (jolt_character == nullptr) {
			return;
		}
	}
	ERR_FAIL_NULL(space);
	ERR_FAIL_COND_MSG(space->is_stepping(), "JoltCharacterVirtual3D.update() must not be called while the physics space is being stepped.");

	// External transform changes (teleports etc.) — push to the character.
	const JPH::RVec3 node_pos = to_jolt_r(get_global_position());
	if ((node_pos - jolt_character->GetPosition()).LengthSq() > 1.0e-8f) {
		jolt_character->SetPosition(node_pos);
	}

	jolt_character->SetLinearVelocity(to_jolt(p_velocity));

	JPH::PhysicsSystem &phys = space->get_physics_system();
	JPH::DefaultBroadPhaseLayerFilter bp_filter = phys.GetDefaultBroadPhaseLayerFilter(object_layer);
	JPH::DefaultObjectLayerFilter obj_filter = phys.GetDefaultLayerFilter(object_layer);
	JPH::IgnoreSingleBodyFilter body_filter(jolt_character->GetInnerBodyID());
	JPH::ShapeFilter shape_filter;

	listener.reset_step();

	jolt_character->Update(
			p_delta,
			to_jolt(p_gravity),
			bp_filter,
			obj_filter,
			body_filter,
			shape_filter,
			space->get_temp_allocator());

	_sync_position_from_character();
}

void JoltCharacterVirtual3D::extended_update(const Vector3 &p_velocity, float p_delta, const Vector3 &p_gravity, float p_step_up_height, float p_step_down) {
	if (jolt_character == nullptr) {
		_create_character();
		if (jolt_character == nullptr) {
			return;
		}
	}
	ERR_FAIL_NULL(space);
	ERR_FAIL_COND_MSG(space->is_stepping(), "JoltCharacterVirtual3D.extended_update() must not be called while the physics space is being stepped.");

	const JPH::RVec3 node_pos = to_jolt_r(get_global_position());
	if ((node_pos - jolt_character->GetPosition()).LengthSq() > 1.0e-8f) {
		jolt_character->SetPosition(node_pos);
	}
	jolt_character->SetLinearVelocity(to_jolt(p_velocity));

	JPH::PhysicsSystem &phys = space->get_physics_system();
	JPH::DefaultBroadPhaseLayerFilter bp_filter = phys.GetDefaultBroadPhaseLayerFilter(object_layer);
	JPH::DefaultObjectLayerFilter obj_filter = phys.GetDefaultLayerFilter(object_layer);
	JPH::IgnoreSingleBodyFilter body_filter(jolt_character->GetInnerBodyID());
	JPH::ShapeFilter shape_filter;

	JPH::CharacterVirtual::ExtendedUpdateSettings settings;
	const float step_up = MAX(0.0f, p_step_up_height);
	const float step_down_extra = MAX(0.0f, p_step_down);
	settings.mWalkStairsStepUp = to_jolt(up_direction * step_up);
	// StickToFloor: cast down by (step-up + extra), clamped to a small minimum,
	// so we re-glue after a small step or cresting a downhill ridge.
	settings.mStickToFloorStepDown = to_jolt(up_direction * -MAX(0.05f, step_up + step_down_extra));
	settings.mWalkStairsStepDownExtra = to_jolt(up_direction * -step_down_extra);
	// (mWalkStairsMinStepForward / mWalkStairsStepForwardTest /
	//  mWalkStairsCosAngleForwardContact left at JPH defaults.)

	const JPH::RVec3 pos_before = jolt_character->GetPosition();
	listener.reset_step();
	const bool capturing = (debug_capture_frames > 0);
	listener.capture_active = capturing;
	if (capturing) {
		print_line(vformat("[CV-CAP] FRAME_START remaining=%d in_vel=(%.4f,%.4f,%.4f) pos_before=(%.4f,%.4f,%.4f) dt=%.4f step_up=%.3f step_down_extra=%.3f",
				debug_capture_frames,
				p_velocity.x, p_velocity.y, p_velocity.z,
				(float)pos_before.GetX(), (float)pos_before.GetY(), (float)pos_before.GetZ(),
				p_delta, step_up, step_down_extra));
	}

	jolt_character->ExtendedUpdate(
			p_delta,
			to_jolt(p_gravity),
			settings,
			bp_filter,
			obj_filter,
			body_filter,
			shape_filter,
			space->get_temp_allocator());

	// DEBUG: if we fed a big horizontal velocity but the character barely moved,
	// dump everything — the active contact set, ground state, what the solver
	// left the velocity at, and how the OnContactSolve listener fared.
	const JPH::Vec3 moved = JPH::Vec3(jolt_character->GetPosition() - pos_before);
	const JPH::Vec3 in_h(p_velocity.x, 0.0f, p_velocity.z);
	if (in_h.LengthSq() > 4.0f && JPH::Vec3(moved.GetX(), 0.0f, moved.GetZ()).LengthSq() < 1.0e-4f) {
		const JPH::Vec3 out_v = jolt_character->GetLinearVelocity();
		print_line(vformat("[CV-STUCK] in_vel=(%.3f,%.3f,%.3f) moved=(%.5f,%.5f,%.5f) out_vel=(%.3f,%.3f,%.3f) gs=%d solve_calls=%d reseats=%d nactive=%d",
				p_velocity.x, p_velocity.y, p_velocity.z, (float)moved.GetX(), (float)moved.GetY(), (float)moved.GetZ(),
				(float)out_v.GetX(), (float)out_v.GetY(), (float)out_v.GetZ(), (int)jolt_character->GetGroundState(),
				listener.solve_calls, listener.solve_reseats, (int)jolt_character->GetActiveContacts().size()));
		int ci = 0;
		for (const JPH::CharacterVirtual::Contact &c : jolt_character->GetActiveContacts()) {
			print_line(vformat("[CV-STUCK]   c%d: cn=(%.3f,%.3f,%.3f) sn=(%.3f,%.3f,%.3f) dist=%.4f frac=%.3f had=%d disc=%d sensor=%d canpush=%d motion=%d",
					ci++, (float)c.mContactNormal.GetX(), (float)c.mContactNormal.GetY(), (float)c.mContactNormal.GetZ(),
					(float)c.mSurfaceNormal.GetX(), (float)c.mSurfaceNormal.GetY(), (float)c.mSurfaceNormal.GetZ(),
					(float)c.mDistance, (float)c.mFraction, (int)c.mHadCollision, (int)c.mWasDiscarded, (int)c.mIsSensorB,
					(int)c.mCanPushCharacter, (int)c.mMotionTypeB));
		}
	}

	// DEBUG: airborne tripwire. If the character's Y position moved upward by more
	// than ~4cm in a single frame while the input velocity wasn't already commanding
	// such an upward move (e.g., gravity-falling or walking, not jumping), dump the
	// context. This catches "I got launched" scenarios that the CV-STUCK trigger
	// misses (CV-STUCK requires horizontal motion to be near zero, which excludes
	// most real launches that also move horizontally). Threshold: input Y velocity
	// would, even with no gravity opposition, only carry you 0.0167·v.y meters in one
	// frame — so anything beyond ~3cm above that floor is unexplained-upward motion.
	{
		const float upward_moved = (float)moved.GetY();
		const float intended_y_advance = MAX(0.0f, p_velocity.y) * (float)p_delta;
		const float unexplained_up = upward_moved - intended_y_advance;
		if (unexplained_up > 0.04f) {
			const JPH::Vec3 out_v = jolt_character->GetLinearVelocity();
			print_line(vformat("[CV-LAUNCH] up=%.4f unexpl=%.4f in_vel=(%.3f,%.3f,%.3f) moved=(%.5f,%.5f,%.5f) out_vel=(%.3f,%.3f,%.3f) gs=%d solve_calls=%d reseats=%d nactive=%d",
					upward_moved, unexplained_up,
					p_velocity.x, p_velocity.y, p_velocity.z,
					(float)moved.GetX(), (float)moved.GetY(), (float)moved.GetZ(),
					(float)out_v.GetX(), (float)out_v.GetY(), (float)out_v.GetZ(),
					(int)jolt_character->GetGroundState(),
					listener.solve_calls, listener.solve_reseats, (int)jolt_character->GetActiveContacts().size()));
			int ci = 0;
			for (const JPH::CharacterVirtual::Contact &c : jolt_character->GetActiveContacts()) {
				print_line(vformat("[CV-LAUNCH]   c%d: cn=(%.3f,%.3f,%.3f) sn=(%.3f,%.3f,%.3f) dist=%.4f frac=%.3f had=%d disc=%d sensor=%d canpush=%d motion=%d",
						ci++, (float)c.mContactNormal.GetX(), (float)c.mContactNormal.GetY(), (float)c.mContactNormal.GetZ(),
						(float)c.mSurfaceNormal.GetX(), (float)c.mSurfaceNormal.GetY(), (float)c.mSurfaceNormal.GetZ(),
						(float)c.mDistance, (float)c.mFraction, (int)c.mHadCollision, (int)c.mWasDiscarded, (int)c.mIsSensorB,
						(int)c.mCanPushCharacter, (int)c.mMotionTypeB));
			}
		}
	}

	// Per-frame verbose capture dump (gated on debug_capture_frames > 0). Logs
	// the post-Update state: position delta, stored velocity, ground state,
	// listener counters, and the full contact set. Combined with the
	// [CV-CAP] FRAME_START line and [CV-CAP-SOLVE] entries from the listener,
	// this gives a complete picture of a single frame's character solve.
	if (capturing) {
		const JPH::Vec3 out_v = jolt_character->GetLinearVelocity();
		print_line(vformat("[CV-CAP] FRAME_END moved=(%.5f,%.5f,%.5f) out_vel=(%.4f,%.4f,%.4f) gs=%d solve_calls=%d reseats=%d nactive=%d had_walkable_reseat=%d",
				(float)moved.GetX(), (float)moved.GetY(), (float)moved.GetZ(),
				(float)out_v.GetX(), (float)out_v.GetY(), (float)out_v.GetZ(),
				(int)jolt_character->GetGroundState(),
				listener.solve_calls, listener.solve_reseats, (int)jolt_character->GetActiveContacts().size(),
				(int)listener.had_walkable_reseat));
		int ci = 0;
		for (const JPH::CharacterVirtual::Contact &c : jolt_character->GetActiveContacts()) {
			print_line(vformat("[CV-CAP]   c%d: cn=(%.3f,%.3f,%.3f) sn=(%.3f,%.3f,%.3f) dist=%.4f frac=%.3f had=%d disc=%d sensor=%d canpush=%d motion=%d",
					ci++, (float)c.mContactNormal.GetX(), (float)c.mContactNormal.GetY(), (float)c.mContactNormal.GetZ(),
					(float)c.mSurfaceNormal.GetX(), (float)c.mSurfaceNormal.GetY(), (float)c.mSurfaceNormal.GetZ(),
					(float)c.mDistance, (float)c.mFraction, (int)c.mHadCollision, (int)c.mWasDiscarded, (int)c.mIsSensorB,
					(int)c.mCanPushCharacter, (int)c.mMotionTypeB));
		}
		debug_capture_frames--;
		listener.capture_active = false;
	}

	_sync_position_from_character();
}

void JoltCharacterVirtual3D::teleport(const Vector3 &p_position) {
	set_global_position(p_position);
	if (jolt_character != nullptr) {
		jolt_character->SetPosition(to_jolt_r(p_position));
	}
}

void JoltCharacterVirtual3D::refresh_contacts() {
	if (jolt_character == nullptr) {
		_create_character();
		if (jolt_character == nullptr) {
			return;
		}
	}
	ERR_FAIL_NULL(space);
	ERR_FAIL_COND_MSG(space->is_stepping(), "JoltCharacterVirtual3D.refresh_contacts() must not be called while the physics space is being stepped.");

	// The owning node's transform is authoritative here — push it down.
	const JPH::RVec3 node_pos = to_jolt_r(get_global_position());
	if ((node_pos - jolt_character->GetPosition()).LengthSq() > 1.0e-8f) {
		jolt_character->SetPosition(node_pos);
	}

	JPH::PhysicsSystem &phys = space->get_physics_system();
	JPH::DefaultBroadPhaseLayerFilter bp_filter = phys.GetDefaultBroadPhaseLayerFilter(object_layer);
	JPH::DefaultObjectLayerFilter obj_filter = phys.GetDefaultLayerFilter(object_layer);
	JPH::IgnoreSingleBodyFilter body_filter(jolt_character->GetInnerBodyID());
	JPH::ShapeFilter shape_filter;

	jolt_character->RefreshContacts(bp_filter, obj_filter, body_filter, shape_filter, space->get_temp_allocator());
}

TypedArray<Dictionary> JoltCharacterVirtual3D::get_contacts() const {
	TypedArray<Dictionary> out;
	if (jolt_character == nullptr || space == nullptr) {
		return out;
	}
	const JPH::CharacterVirtual::ContactList &contacts = jolt_character->GetActiveContacts();
	for (const JPH::CharacterVirtual::Contact &c : contacts) {
		if (!c.mHadCollision) {
			continue; // predictive-only contact that never materialised
		}
		Dictionary d;
		d["position"] = to_godot(c.mPosition);
		d["surface_normal"] = to_godot(c.mSurfaceNormal);
		d["contact_normal"] = to_godot(c.mContactNormal);
		d["linear_velocity"] = to_godot(c.mLinearVelocity);
		d["distance"] = (float)c.mDistance;
		d["is_sensor"] = c.mIsSensorB;
		d["sub_shape_id"] = (int64_t)c.mSubShapeIDB.GetValue();

		Object *collider_obj = nullptr;
		RID collider_rid;
		if (!c.mBodyB.IsInvalid()) {
			const JoltObject3D *obj = space->try_get_object(c.mBodyB);
			if (obj != nullptr) {
				collider_obj = obj->get_instance();
				collider_rid = obj->get_rid();
			}
		}
		d["collider"] = collider_obj;
		d["collider_rid"] = collider_rid;
		out.push_back(d);
	}
	return out;
}

Dictionary JoltCharacterVirtual3D::cast_shape(const Transform3D &p_from, const Vector3 &p_motion, uint32_t p_mask) const {
	Dictionary out;
	if (jolt_character == nullptr || space == nullptr) {
		return out;
	}
	ERR_FAIL_COND_V_MSG(space->is_stepping(), out, "JoltCharacterVirtual3D.cast_shape() must not be called while the physics space is being stepped.");

	JPH::RefConst<JPH::Shape> shape = _build_capsule_shape();
	if (shape == nullptr) {
		return out;
	}

	const JPH::RShapeCast shape_cast = JPH::RShapeCast::sFromWorldTransform(
			shape, JPH::Vec3::sReplicate(1.0f), to_jolt_r(p_from), to_jolt(p_motion));

	JPH::ShapeCastSettings cast_settings;
	cast_settings.mReturnDeepestPoint = false;

	const JPH::ObjectLayer cast_layer = space->map_to_object_layer(JoltBroadPhaseLayer::BODY_DYNAMIC, collision_layer, p_mask);
	JPH::PhysicsSystem &phys = space->get_physics_system();
	JPH::DefaultBroadPhaseLayerFilter bp_filter = phys.GetDefaultBroadPhaseLayerFilter(cast_layer);
	JPH::DefaultObjectLayerFilter obj_filter = phys.GetDefaultLayerFilter(cast_layer);
	JPH::IgnoreSingleBodyFilter body_filter(jolt_character->GetInnerBodyID());
	JPH::ShapeFilter shape_filter;

	JoltQueryCollectorClosest<JPH::CastShapeCollector> collector;
	space->get_narrow_phase_query().CastShape(shape_cast, cast_settings, JPH::RVec3::sZero(), collector, bp_filter, obj_filter, body_filter, shape_filter);

	if (!collector.had_hit()) {
		return out;
	}

	const JPH::ShapeCastResult &hit = collector.get_hit();
	const JoltObject3D *obj = space->try_get_object(hit.mBodyID2);
	if (obj == nullptr) {
		return out;
	}

	const JPH::Vec3 contact_normal = -hit.mPenetrationAxis.Normalized();
	JPH::Vec3 surface_normal = obj->get_jolt_body()->GetWorldSpaceSurfaceNormal(hit.mSubShapeID2, hit.mContactPointOn2);
	// GetWorldSpaceSurfaceNormal only returns face normals; fall back to the
	// contact normal if it degenerated (vertex/edge hit).
	if (surface_normal.IsNearZero()) {
		surface_normal = contact_normal;
	}

	out["position"] = to_godot(hit.mContactPointOn2);
	out["surface_normal"] = to_godot(surface_normal);
	out["contact_normal"] = to_godot(contact_normal);
	out["fraction"] = (float)hit.mFraction;
	out["sub_shape_id"] = (int64_t)hit.mSubShapeID2.GetValue();
	out["collider"] = obj->get_instance();
	out["collider_rid"] = obj->get_rid();
	return out;
}

bool JoltCharacterVirtual3D::is_supported() const {
	return jolt_character != nullptr && jolt_character->IsSupported();
}

Vector3 JoltCharacterVirtual3D::get_ground_normal() const {
	if (jolt_character == nullptr) {
		return up_direction;
	}
	return to_godot(jolt_character->GetGroundNormal());
}

int JoltCharacterVirtual3D::get_ground_state() const {
	if (jolt_character == nullptr) {
		return 3; // InAir
	}
	switch (jolt_character->GetGroundState()) {
		case JPH::CharacterBase::EGroundState::OnGround:
			return 0;
		case JPH::CharacterBase::EGroundState::OnSteepGround:
			return 1;
		case JPH::CharacterBase::EGroundState::NotSupported:
			return 2;
		case JPH::CharacterBase::EGroundState::InAir:
			return 3;
	}
	return 3;
}

Vector3 JoltCharacterVirtual3D::get_ground_velocity() const {
	if (jolt_character == nullptr) {
		return Vector3();
	}
	return to_godot(jolt_character->GetGroundVelocity());
}

Vector3 JoltCharacterVirtual3D::get_character_position() const {
	if (jolt_character == nullptr) {
		return get_global_position();
	}
	return to_godot(jolt_character->GetPosition());
}

Vector3 JoltCharacterVirtual3D::get_character_velocity() const {
	if (jolt_character == nullptr) {
		return Vector3();
	}
	return to_godot(jolt_character->GetLinearVelocity());
}

void JoltCharacterVirtual3D::_bind_methods() {
	ClassDB::bind_method(D_METHOD("set_capsule_radius", "radius"), &JoltCharacterVirtual3D::set_capsule_radius);
	ClassDB::bind_method(D_METHOD("get_capsule_radius"), &JoltCharacterVirtual3D::get_capsule_radius);

	ClassDB::bind_method(D_METHOD("start_debug_capture", "frames"), &JoltCharacterVirtual3D::start_debug_capture);
	ClassDB::bind_method(D_METHOD("get_debug_capture_frames"), &JoltCharacterVirtual3D::get_debug_capture_frames);

	ClassDB::bind_method(D_METHOD("set_capsule_height", "height"), &JoltCharacterVirtual3D::set_capsule_height);
	ClassDB::bind_method(D_METHOD("get_capsule_height"), &JoltCharacterVirtual3D::get_capsule_height);

	ClassDB::bind_method(D_METHOD("set_character_mass", "mass"), &JoltCharacterVirtual3D::set_character_mass);
	ClassDB::bind_method(D_METHOD("get_character_mass"), &JoltCharacterVirtual3D::get_character_mass);

	ClassDB::bind_method(D_METHOD("set_max_strength", "strength"), &JoltCharacterVirtual3D::set_max_strength);
	ClassDB::bind_method(D_METHOD("get_max_strength"), &JoltCharacterVirtual3D::get_max_strength);

	ClassDB::bind_method(D_METHOD("set_predictive_contact_distance", "dist"), &JoltCharacterVirtual3D::set_predictive_contact_distance);
	ClassDB::bind_method(D_METHOD("get_predictive_contact_distance"), &JoltCharacterVirtual3D::get_predictive_contact_distance);

	ClassDB::bind_method(D_METHOD("set_character_padding", "pad"), &JoltCharacterVirtual3D::set_character_padding);
	ClassDB::bind_method(D_METHOD("get_character_padding"), &JoltCharacterVirtual3D::get_character_padding);

	ClassDB::bind_method(D_METHOD("set_max_slope_angle_deg", "deg"), &JoltCharacterVirtual3D::set_max_slope_angle_deg);
	ClassDB::bind_method(D_METHOD("get_max_slope_angle_deg"), &JoltCharacterVirtual3D::get_max_slope_angle_deg);

	ClassDB::bind_method(D_METHOD("set_up_direction", "up"), &JoltCharacterVirtual3D::set_up_direction);
	ClassDB::bind_method(D_METHOD("get_up_direction"), &JoltCharacterVirtual3D::get_up_direction);

	ClassDB::bind_method(D_METHOD("set_collision_layer", "layer"), &JoltCharacterVirtual3D::set_collision_layer);
	ClassDB::bind_method(D_METHOD("get_collision_layer"), &JoltCharacterVirtual3D::get_collision_layer);

	ClassDB::bind_method(D_METHOD("set_collision_mask", "mask"), &JoltCharacterVirtual3D::set_collision_mask);
	ClassDB::bind_method(D_METHOD("get_collision_mask"), &JoltCharacterVirtual3D::get_collision_mask);

	ClassDB::bind_method(D_METHOD("set_inner_body", "enabled"), &JoltCharacterVirtual3D::set_inner_body);
	ClassDB::bind_method(D_METHOD("get_inner_body"), &JoltCharacterVirtual3D::get_inner_body);

	ClassDB::bind_method(D_METHOD("set_enhanced_internal_edge_removal", "enabled"), &JoltCharacterVirtual3D::set_enhanced_internal_edge_removal);
	ClassDB::bind_method(D_METHOD("get_enhanced_internal_edge_removal"), &JoltCharacterVirtual3D::get_enhanced_internal_edge_removal);

	ClassDB::bind_method(D_METHOD("is_ready"), &JoltCharacterVirtual3D::is_ready);

	ClassDB::bind_method(D_METHOD("update", "velocity", "delta", "gravity"), &JoltCharacterVirtual3D::update);
	ClassDB::bind_method(D_METHOD("extended_update", "velocity", "delta", "gravity", "step_up_height", "step_down"), &JoltCharacterVirtual3D::extended_update);
	ClassDB::bind_method(D_METHOD("teleport", "position"), &JoltCharacterVirtual3D::teleport);
	ClassDB::bind_method(D_METHOD("refresh_contacts"), &JoltCharacterVirtual3D::refresh_contacts);
	ClassDB::bind_method(D_METHOD("get_contacts"), &JoltCharacterVirtual3D::get_contacts);
	ClassDB::bind_method(D_METHOD("cast_shape", "from", "motion", "mask"), &JoltCharacterVirtual3D::cast_shape, DEFVAL(0xFFFFFFFF));

	ClassDB::bind_method(D_METHOD("is_supported"), &JoltCharacterVirtual3D::is_supported);
	ClassDB::bind_method(D_METHOD("get_ground_normal"), &JoltCharacterVirtual3D::get_ground_normal);
	ClassDB::bind_method(D_METHOD("get_ground_state"), &JoltCharacterVirtual3D::get_ground_state);
	ClassDB::bind_method(D_METHOD("get_ground_velocity"), &JoltCharacterVirtual3D::get_ground_velocity);
	ClassDB::bind_method(D_METHOD("get_character_position"), &JoltCharacterVirtual3D::get_character_position);
	ClassDB::bind_method(D_METHOD("get_character_velocity"), &JoltCharacterVirtual3D::get_character_velocity);

	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "capsule_radius", PROPERTY_HINT_RANGE, "0.05,2.0,0.01"), "set_capsule_radius", "get_capsule_radius");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "capsule_height", PROPERTY_HINT_RANGE, "0.1,5.0,0.01"), "set_capsule_height", "get_capsule_height");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "character_mass", PROPERTY_HINT_RANGE, "0.1,500.0,0.1"), "set_character_mass", "get_character_mass");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "max_strength", PROPERTY_HINT_RANGE, "0.0,10000.0,1.0"), "set_max_strength", "get_max_strength");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "predictive_contact_distance", PROPERTY_HINT_RANGE, "0.001,1.0,0.001"), "set_predictive_contact_distance", "get_predictive_contact_distance");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "character_padding", PROPERTY_HINT_RANGE, "0.001,0.5,0.001"), "set_character_padding", "get_character_padding");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "max_slope_angle_deg", PROPERTY_HINT_RANGE, "0.0,90.0,0.5"), "set_max_slope_angle_deg", "get_max_slope_angle_deg");
	ADD_PROPERTY(PropertyInfo(Variant::VECTOR3, "up_direction"), "set_up_direction", "get_up_direction");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "collision_layer", PROPERTY_HINT_LAYERS_3D_PHYSICS), "set_collision_layer", "get_collision_layer");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "collision_mask", PROPERTY_HINT_LAYERS_3D_PHYSICS), "set_collision_mask", "get_collision_mask");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "inner_body"), "set_inner_body", "get_inner_body");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "enhanced_internal_edge_removal"), "set_enhanced_internal_edge_removal", "get_enhanced_internal_edge_removal");
}
