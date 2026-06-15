/**************************************************************************/
/*  jolt_character_virtual_3d.h                                           */
/**************************************************************************/
/*                         This file is part of:                          */
/*                             GODOT ENGINE                               */
/*                        https://godotengine.org                         */
/**************************************************************************/

#pragma once

#include "core/object/object.h"
#include "core/templates/local_vector.h"
#include "scene/3d/node_3d.h"

#include "Jolt/Jolt.h"

#include "Jolt/Core/StaticArray.h"
#include "Jolt/Physics/Character/CharacterVirtual.h"
#include "Jolt/Physics/Collision/Shape/Shape.h"

class JoltSpace3D;

// Scene-tree node that wraps a JPH::CharacterVirtual. Designed as a contact
// oracle and a place to host custom wall-collision response: the player drives
// its own velocity through this node, and reads back contacts with both the
// averaged manifold normal (mContactNormal) and the real triangle face normal
// (mSurfaceNormal), the latter resolved through the sub-shape ID into the
// compound's leaf shape. Unlike Godot's per-frame `_contacts` snapshot of a
// RigidBody's manifold, CharacterVirtual's contact set is sweep-based — it
// sees both faces of a corner in a single cast, so it doesn't flicker as you
// slide into the seam.
//
// Threading: update() / cast_shape() / get_contacts() must be called from the
// main thread between physics steps (i.e. from _physics_process / _process),
// never from _integrate_forces. During _physics_process the Jolt worker thread
// is idle, so these synchronous queries against the PhysicsSystem are safe.
class JoltCharacterVirtual3D : public Node3D {
	GDCLASS(JoltCharacterVirtual3D, Node3D);

private:
	// Custom contact-solve behaviour, so the CharacterVirtual stays the SINGLE
	// collision authority (no script-side wall/slope projection needed):
	//   • walkable contact  — re-seat the velocity onto the surface plane while
	//     keeping its horizontal velocity VERBATIM (direction and magnitude):
	//     vy is recomputed for tangency to this contact relative to its surface
	//     motion, blended by the solver's mass-ratio clip law for Dynamic
	//     floors. So we follow slopes without bleeding speed, without the
	//     per-frame gravity term creeping us downhill, and without the gravity
	//     clip rotating our heading downhill on laterally-tilted hills. Fires
	//     at most once per contact per frame (see reseated_contacts). A jump
	//     (moving away from the contact) is left alone.
	//   • non-walkable contact — keep JPH's default. JPH's SolveConstraints
	//     already cancels velocity *towards* a too-steep slope before this is
	//     called, so walk-accel can't climb it; gravity (re-applied each frame)
	//     drags us down the face.
	struct ContactListener : public JPH::CharacterContactListener {
		JPH::Vec3 up = JPH::Vec3(0.0f, 1.0f, 0.0f);
		float cos_max_slope = 0.6427876f; // cos(50°); set from max_slope_angle_deg at creation
		bool had_walkable_reseat = false; // set when a walkable contact re-seated us this step; tells a later wall contact to forfeit the orphaned climb-vertical
		int solve_calls = 0;       // DEBUG: how many times OnContactSolve fired in the current ExtendedUpdate
		int solve_reseats = 0;     // DEBUG: how many of those actually re-seated the velocity
		bool capture_active = false; // DEBUG: when true, log every OnContactSolve call with full state under [CV-CAP-SOLVE]

		// Contacts that already received the walkable speed-restore this frame,
		// keyed by (body id << 32 | sub-shape id). The restore compensates the
		// per-frame gravity fold-in, which is added ONCE per frame — so each
		// supporting contact may restore speed at most ONCE per frame. Without
		// this gate the rescale fired on every solver iteration, feeding energy
		// back faster than SolveConstraints could drain it: on frames with
		// several flush walkable contacts whose normals disagree (mesh seams,
		// terrain triangle fans) the solver ping-ponged at TOI=0 until the
		// 15-iteration cap and returned ZERO displacement — the random
		// "invisible wall" stalls. Gated, a repeat solve of the same contact
		// passes through vanilla (velocity decays), restoring the solver's
		// termination guarantee. Cleared at the start of every update.
		JPH::StaticArray<uint64_t, 32> reseated_contacts;

		void reset_step() {
			had_walkable_reseat = false;
			solve_calls = 0;
			solve_reseats = 0;
			reseated_contacts.clear();
		}

		void OnContactSolve(const JPH::CharacterVirtual *p_character, const JPH::BodyID &p_body_id2, const JPH::SubShapeID &p_sub_shape_id2, JPH::RVec3Arg p_contact_position, JPH::Vec3Arg p_contact_normal, JPH::Vec3Arg p_contact_velocity, const JPH::PhysicsMaterial *p_contact_material, JPH::Vec3Arg p_character_velocity, JPH::Vec3 &p_new_character_velocity) override;
	};
	ContactListener listener;

	// Verbose debug capture countdown — when > 0, move() dumps full per-frame state
	// and decrements. Triggered via start_debug_capture() from GDScript so a brief
	// keyboard-driven 1-second window of [CV-CAP] log can be collected.
	int debug_capture_frames = 0;

	JPH::Ref<JPH::CharacterVirtual> jolt_character;
	JoltSpace3D *space = nullptr;
	JPH::ObjectLayer object_layer = 0;

	// Geometry — we accept capsule dimensions directly. A future revision can
	// take a Ref<Shape3D> and reuse the JoltShape3D conversion path.
	float capsule_radius = 0.4f;
	float capsule_height = 1.8f;

	// Character config mirrored from JPH::CharacterVirtualSettings.
	float character_mass = 70.0f;
	float max_strength = 100.0f;
	float predictive_contact_distance = 0.1f;
	float character_padding = 0.02f;
	float collision_tolerance = 1.0e-3f;
	float penetration_recovery_speed = 1.0f;
	float max_slope_angle_deg = 50.0f;
	Vector3 up_direction = Vector3(0, 1, 0);
	uint32_t collision_layer = 1;
	uint32_t collision_mask = 1;

	// When true, the CharacterVirtual creates a kinematic "inner body" on
	// `collision_layer` that follows the character — so weapons, raycasts,
	// sensors and other bodies can detect/hit the player. The inner body is
	// kinematic (driven by the character, never solved against), so it does
	// not re-introduce a second collision-response authority. Must be set
	// before the character is created (i.e. before the first update()).
	bool inner_body = true;

	// When true, the character's collision queries run through Jolt's
	// InternalEdgeRemovingCollector: contacts whose normal disagrees with the
	// face normal of an adjacent triangle / sub-shape that also contains the
	// point are voided. This kills the spurious edge normals produced at mesh
	// triangle seams and voxel-structure block boundaries — the disagreeing
	// constraint planes that make SolveConstraints ping-pong (random stalls)
	// and that read as corner jitter. Rigid bodies in this project already
	// run with the equivalent setting on (see jolt_body_3d.cpp). Must be set
	// before the character is created.
	bool enhanced_internal_edge_removal = true;

	JPH::RefConst<JPH::Shape> _build_capsule_shape() const;
	void _create_character();
	void _destroy_character();
	void _sync_position_from_character();

protected:
	static void _bind_methods();
	void _notification(int p_what);

public:
	JoltCharacterVirtual3D();
	~JoltCharacterVirtual3D();

	// --- Configuration ----------------------------------------------------

	void set_capsule_radius(float p_radius);
	float get_capsule_radius() const { return capsule_radius; }

	void set_capsule_height(float p_height);
	float get_capsule_height() const { return capsule_height; }

	void set_character_mass(float p_mass) { character_mass = p_mass; }
	float get_character_mass() const { return character_mass; }

	void set_max_strength(float p_strength) { max_strength = p_strength; }
	float get_max_strength() const { return max_strength; }

	void set_predictive_contact_distance(float p_dist) { predictive_contact_distance = p_dist; }
	float get_predictive_contact_distance() const { return predictive_contact_distance; }

	void set_character_padding(float p_pad) { character_padding = p_pad; }
	float get_character_padding() const { return character_padding; }

	void set_max_slope_angle_deg(float p_deg) { max_slope_angle_deg = p_deg; }
	float get_max_slope_angle_deg() const { return max_slope_angle_deg; }

	void set_up_direction(Vector3 p_up) { up_direction = p_up.normalized(); }
	Vector3 get_up_direction() const { return up_direction; }

	void set_collision_layer(uint32_t p_layer) { collision_layer = p_layer; }
	uint32_t get_collision_layer() const { return collision_layer; }

	void set_collision_mask(uint32_t p_mask) { collision_mask = p_mask; }
	uint32_t get_collision_mask() const { return collision_mask; }

	void set_inner_body(bool p_enabled) { inner_body = p_enabled; }
	bool get_inner_body() const { return inner_body; }

	void set_enhanced_internal_edge_removal(bool p_enabled) { enhanced_internal_edge_removal = p_enabled; }
	bool get_enhanced_internal_edge_removal() const { return enhanced_internal_edge_removal; }

	// True once the JPH::CharacterVirtual exists (space was available).
	bool is_ready() const { return jolt_character != nullptr; }

	// --- Debug capture ---------------------------------------------------
	// Enable verbose per-frame logging for the next N frames. Each frame the
	// move() call dumps input vel, output vel, position delta, ground state,
	// listener counters, and the full contact set under the [CV-CAP] tag. The
	// counter auto-decrements per frame and stops logging when it hits 0.
	void start_debug_capture(int p_frames) { debug_capture_frames = MAX(0, p_frames); }
	int get_debug_capture_frames() const { return debug_capture_frames; }

	// --- Movement ---------------------------------------------------------

	// Sets the character's linear velocity to p_velocity, then runs
	// JPH::CharacterVirtual::Update for p_delta seconds with p_gravity. After
	// return, the character's position is integrated, the Node3D transform is
	// synced, and the active contact list is fresh.
	void update(const Vector3 &p_velocity, float p_delta, const Vector3 &p_gravity);

	// Like update(), but runs JPH::CharacterVirtual::ExtendedUpdate — i.e.
	// Update followed by StickToFloor (a bounded down-cast that re-glues you to
	// the ground after small steps / cresting a downhill ridge) and WalkStairs
	// (cast up / forward / down to step over stair-height obstacles). This is
	// the recommended driver for a player character: collide-and-slide + ground
	// snap + stair-step, all inside the one collision authority.
	//   p_step_up_height  — max height of an obstacle WalkStairs will step over
	//                       (0 disables stair-stepping)
	//   p_step_down       — extra down distance for StickToFloor on top of the
	//                       step-up height (0 = just the step-up height down)
	void extended_update(const Vector3 &p_velocity, float p_delta, const Vector3 &p_gravity, float p_step_up_height, float p_step_down);

	// Teleport: sets both the JPH character's position and the Node3D transform.
	// (Named `teleport` rather than `set_position` to avoid clashing with the
	// inherited Node3D::set_position.)
	void teleport(const Vector3 &p_position);

	// Contact-oracle mode: pushes the Node3D's current global position into the
	// JPH character, re-runs collision detection at that position (no motion,
	// no penetration recovery), and refreshes get_contacts(). Use this when
	// another body (e.g. a RigidBody3D player) owns the transform and you only
	// want CharacterVirtual's sweep-based, true-face-normal contact set. Unlike
	// update(), this does NOT sync the Node3D transform back.
	void refresh_contacts();

	// --- Contact oracle ---------------------------------------------------

	// One Dictionary per active contact (only contacts that actually collided
	// — predictive-only contacts are skipped). Keys:
	//   position           Vector3  world-space contact point
	//   surface_normal     Vector3  TRUE triangle face normal (sub-shape resolved)
	//   contact_normal     Vector3  GJK/EPA penetration axis (averaged at seams)
	//   linear_velocity    Vector3  contact-point velocity of the other body
	//   collider           Object   the colliding body, or null
	//   collider_rid       RID
	//   sub_shape_id       int      JPH SubShapeID raw bits (diagnostics)
	//   distance           float    <= 0 actual contact, > 0 predictive
	//   is_sensor          bool
	TypedArray<Dictionary> get_contacts() const;

	// Single-hit shape cast for collide-and-slide. Sweeps the character's
	// shape from p_from along p_motion. Returns {} on miss, otherwise:
	//   { position, surface_normal, contact_normal, collider, collider_rid,
	//     sub_shape_id, fraction }
	Dictionary cast_shape(const Transform3D &p_from, const Vector3 &p_motion, uint32_t p_mask = 0xFFFFFFFF) const;

	// --- State readers ----------------------------------------------------

	bool is_supported() const;
	Vector3 get_ground_normal() const;
	// JPH::EGroundState as an int: 0 = OnGround, 1 = OnSteepGround,
	// 2 = NotSupported, 3 = InAir. (Matches the order of the JPH enum.)
	int get_ground_state() const;
	// Velocity of the surface the character is standing on (moving platforms);
	// zero on static ground or in air.
	Vector3 get_ground_velocity() const;
	Vector3 get_character_position() const;
	Vector3 get_character_velocity() const;
};
