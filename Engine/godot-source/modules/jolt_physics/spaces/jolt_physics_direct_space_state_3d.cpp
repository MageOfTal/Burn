/**************************************************************************/
/*  jolt_physics_direct_space_state_3d.cpp                                */
/**************************************************************************/
/*                         This file is part of:                          */
/*                             GODOT ENGINE                               */
/*                        https://godotengine.org                         */
/**************************************************************************/
/* Copyright (c) 2014-present Godot Engine contributors (see AUTHORS.md). */
/* Copyright (c) 2007-2014 Juan Linietsky, Ariel Manzur.                  */
/*                                                                        */
/* Permission is hereby granted, free of charge, to any person obtaining  */
/* a copy of this software and associated documentation files (the        */
/* "Software"), to deal in the Software without restriction, including    */
/* without limitation the rights to use, copy, modify, merge, publish,    */
/* distribute, sublicense, and/or sell copies of the Software, and to     */
/* permit persons to whom the Software is furnished to do so, subject to  */
/* the following conditions:                                              */
/*                                                                        */
/* The above copyright notice and this permission notice shall be         */
/* included in all copies or substantial portions of the Software.        */
/*                                                                        */
/* THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,        */
/* EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF     */
/* MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. */
/* IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY   */
/* CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,   */
/* TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE      */
/* SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.                 */
/**************************************************************************/

#include "jolt_physics_direct_space_state_3d.h"

#include "../jolt_physics_server_3d.h"
#include "../jolt_project_settings.h"
#include "../misc/jolt_math_funcs.h"
#include "../misc/jolt_type_conversions.h"
#include "../objects/jolt_area_3d.h"
#include "../objects/jolt_body_3d.h"
#include "../objects/jolt_object_3d.h"
#include "../shapes/jolt_custom_motion_shape.h"
#include "../shapes/jolt_shape_3d.h"
#include "jolt_motion_filter_3d.h"
#include "jolt_query_collectors.h"
#include "jolt_query_filter_3d.h"
#include "jolt_space_3d.h"

#include "scene/3d/physics/static_body_3d.h"

#include "core/object/worker_thread_pool.h"
#include "core/os/os.h"

#include "Jolt/Geometry/GJKClosestPoint.h"
#include "Jolt/Physics/Body/Body.h"
#include "Jolt/Physics/Body/BodyFilter.h"
#include "Jolt/Physics/Collision/BroadPhase/BroadPhaseQuery.h"
#include "Jolt/Physics/Collision/CastResult.h"
#include "Jolt/Physics/Collision/CollidePointResult.h"
#include "Jolt/Physics/Collision/NarrowPhaseQuery.h"
#include "Jolt/Physics/Collision/RayCast.h"
#include "Jolt/Physics/Collision/Shape/MeshShape.h"
#include "Jolt/Physics/PhysicsSystem.h"

// Comparator for sorting RayCastResult by fraction (closest first).
struct _RayCastFractionCompare {
	bool operator()(const JPH::RayCastResult &a, const JPH::RayCastResult &b) const {
		return a.mFraction < b.mFraction;
	}
};

// Context struct for passing shared data to worker threads in calc_ray_shielding_batch.
struct ShieldingBatchContext {
	const JPH::NarrowPhaseQuery *narrow_phase;
	const JoltSpace3D *space;
	const JoltQueryFilter3D *query_filter;
	JPH::RayCastSettings ray_settings;
	JPH::RVec3 jolt_from;
	const Vector3 *to_points;      // PackedVector3Array::ptr()
	const RID *target_rids;        // Pre-extracted from TypedArray
	const float *max_absorptions;  // PackedFloat32Array::ptr()
	float *results;                // PackedFloat32Array::ptrw()
};

// Classify a hit body and return its shielding absorption. Uses the shielding_tag
// field on JoltBody3D for fast O(1) classification. Tagged bodies (wall blocks,
// players, damageables) skip all Object::get() probes. Untagged bodies (terrain,
// unknown) fall back to Object::cast_to / Object::get() checks.
//
// Tag values: 0=none, 1=wall_block, 2=player, 3=terrain, 4=damageable
// Returns: absorption amount, or -1.0 to skip (no absorption), or 99999.0 for terrain.
static float _classify_shielding_hit(const JoltObject3D *jolt_object) {
	const JoltBody3D *jolt_body = jolt_object->as_body();
	if (!jolt_body) {
		return -1.0f; // Not a body (area/soft body) — skip.
	}

	uint8_t tag = jolt_body->get_shielding_tag();

	switch (tag) {
		case 1: // WALL_BLOCK — cached HP, zero Object::get() calls.
			return jolt_body->get_shielding_hp();

		case 2: { // PLAYER — read health via Object::get (changes every frame).
			static const StringName sn_health("health");
			Object *instance = jolt_object->get_instance();
			if (!instance) {
				return -1.0f;
			}
			bool valid = false;
			Variant v_health = instance->get(sn_health, &valid);
			if (valid && (v_health.get_type() == Variant::FLOAT || v_health.get_type() == Variant::INT)) {
				return (float)v_health;
			}
			return -1.0f;
		}

		case 3: // TERRAIN — infinite absorption.
			return 99999.0f;

		case 4: // DAMAGEABLE — cached HP, zero Object::get() calls.
			return jolt_body->get_shielding_hp();

		default: // NONE (0) — fallback to Object::get() chain for untagged bodies.
			break;
	}

	// Fallback for untagged bodies (tag 0): only absorb if they have "_hp".
	// Terrain must be explicitly tagged (tag=3) to block — untagged bodies
	// never classify as terrain, preventing misclassification of wall blocks
	// or other StaticBody3D objects that happen to lack a tag.
	Object *instance = jolt_object->get_instance();
	if (!instance) {
		return -1.0f;
	}

	static const StringName sn_hp("_hp");
	bool valid = false;
	Variant v_hp = instance->get(sn_hp, &valid);
	if (valid && (v_hp.get_type() == Variant::FLOAT || v_hp.get_type() == Variant::INT)) {
		return (float)v_hp;
	}

	return -1.0f; // Untagged body without HP — skip, no absorption.
}

// Worker function called per ray element by WorkerThreadPool.
static void _shielding_batch_worker(void *p_userdata, uint32_t p_index) {
	ShieldingBatchContext *ctx = (ShieldingBatchContext *)p_userdata;

	const JPH::RVec3 jolt_to = to_jolt_r(ctx->to_points[p_index]);
	const JPH::Vec3 vector = JPH::Vec3(jolt_to - ctx->jolt_from);
	const JPH::RRayCast ray(ctx->jolt_from, vector);

	JoltQueryCollectorAll<JPH::CastRayCollector, 32> collector;
	ctx->narrow_phase->CastRay(ray, ctx->ray_settings, collector,
		*ctx->query_filter, *ctx->query_filter, *ctx->query_filter);

	int hit_count = collector.get_hit_count();
	if (hit_count == 0) {
		ctx->results[p_index] = 0.0f;
		return;
	}

	// Sort hits by fraction (closest first).
	LocalVector<JPH::RayCastResult> sorted_hits;
	sorted_hits.resize(hit_count);
	for (int i = 0; i < hit_count; ++i) {
		sorted_hits[i] = collector.get_hit(i);
	}
	sorted_hits.sort_custom<_RayCastFractionCompare>();

	float absorbed = 0.0f;
	const RID target_rid = ctx->target_rids[p_index];
	const float max_abs = ctx->max_absorptions[p_index];
	JPH::BodyID last_absorbed_body; // Tracks last body that contributed shielding.

	for (int i = 0; i < hit_count; ++i) {
		const JPH::RayCastResult &hit = sorted_hits[i];

		// Skip hits beyond the target position (fraction 1.0 = target point).
		// Without this, rays extend past the target and hit terrain (99999 absorption).
		if (hit.mFraction > 1.0f) {
			break; // Sorted — all remaining hits are also beyond target.
		}

		const JPH::BodyID &body_id = hit.mBodyID;

		const JoltObject3D *jolt_object = ctx->space->try_get_object(body_id);
		if (!jolt_object) {
			continue;
		}

		// Stop at the target body (don't count it as shielding).
		if (target_rid.is_valid() && jolt_object->get_rid() == target_rid) {
			break;
		}

		// Deduplicate same-body hits (front face + back face of convex shapes).
		// With hit_back_faces=true, a ray through a box produces 2 hits on the
		// same body. Without this, each block double-counts its HP as shielding.
		// Hits are sorted by fraction, so same-body hits are adjacent.
		if (body_id == last_absorbed_body) {
			continue;
		}

		float absorption = _classify_shielding_hit(jolt_object);
		if (absorption < 0.0f) {
			continue; // Skip — no absorption.
		}
		last_absorbed_body = body_id;
		if (absorption >= 99999.0f) {
			ctx->results[p_index] = 99999.0f;
			return; // Terrain — fully blocked.
		}
		absorbed += absorption;
		if (absorbed >= max_abs) {
			ctx->results[p_index] = absorbed;
			return;
		}
	}

	ctx->results[p_index] = absorbed;
}

bool JoltPhysicsDirectSpaceState3D::_cast_motion_impl(const JPH::Shape &p_jolt_shape, const Transform3D &p_transform_com, const Vector3 &p_scale, const Vector3 &p_motion, bool p_use_edge_removal, bool p_ignore_overlaps, const JPH::CollideShapeSettings &p_settings, const JPH::BroadPhaseLayerFilter &p_broad_phase_layer_filter, const JPH::ObjectLayerFilter &p_object_layer_filter, const JPH::BodyFilter &p_body_filter, const JPH::ShapeFilter &p_shape_filter, real_t &r_closest_safe, real_t &r_closest_unsafe) const {
	r_closest_safe = 1.0f;
	r_closest_unsafe = 1.0f;

	ERR_FAIL_COND_V_MSG(p_jolt_shape.GetType() != JPH::EShapeType::Convex, false, "Shape-casting with non-convex shapes is not supported.");

	const float motion_length = (float)p_motion.length();

	if (p_ignore_overlaps && motion_length == 0.0f) {
		return false;
	}

	const JPH::RMat44 transform_com = to_jolt_r(p_transform_com);
	const JPH::Vec3 scale = to_jolt(p_scale);
	const JPH::Vec3 motion = to_jolt(p_motion);
	const JPH::Vec3 motion_local = transform_com.Multiply3x3Transposed(motion);

	JPH::AABox aabb = p_jolt_shape.GetWorldSpaceBounds(transform_com, scale);
	JPH::AABox aabb_translated = aabb;
	aabb_translated.Translate(motion);
	aabb.Encapsulate(aabb_translated);

	JoltQueryCollectorAnyMulti<JPH::CollideShapeBodyCollector, 1024> aabb_collector;
	space->get_broad_phase_query().CollideAABox(aabb, aabb_collector, p_broad_phase_layer_filter, p_object_layer_filter);

	if (!aabb_collector.had_hit()) {
		return false;
	}

	const JPH::RVec3 base_offset = transform_com.GetTranslation();

	JoltCustomMotionShape motion_shape(static_cast<const JPH::ConvexShape &>(p_jolt_shape));

	auto collides = [&](const JPH::Body &p_other_body, float p_fraction) {
		motion_shape.set_motion(motion_local * p_fraction);

		const JPH::TransformedShape other_shape = p_other_body.GetTransformedShape();

		JoltQueryCollectorAny<JPH::CollideShapeCollector> collector;

		if (p_use_edge_removal) {
			JPH::CollideShapeSettings eier_settings = p_settings;
			eier_settings.mActiveEdgeMode = JPH::EActiveEdgeMode::CollideWithAll;
			eier_settings.mCollectFacesMode = JPH::ECollectFacesMode::CollectFaces;

			JPH::InternalEdgeRemovingCollector eier_collector(collector);
			other_shape.CollideShape(&motion_shape, scale, transform_com, eier_settings, base_offset, eier_collector, p_shape_filter);
			eier_collector.Flush();
		} else {
			other_shape.CollideShape(&motion_shape, scale, transform_com, p_settings, base_offset, collector, p_shape_filter);
		}

		return collector.had_hit();
	};

	// Figure out the number of steps we need in our binary search in order to achieve millimeter precision, within reason.
	const int step_count = CLAMP(int(std::log(1000.0f * motion_length) / (float)Math::LN2), 4, 16);

	bool collided = false;

	for (int i = 0; i < aabb_collector.get_hit_count(); ++i) {
		const JPH::BodyID other_jolt_id = aabb_collector.get_hit(i);
		if (!p_body_filter.ShouldCollide(other_jolt_id)) {
			continue;
		}

		const JPH::Body *other_jolt_body = space->try_get_jolt_body(other_jolt_id);
		if (!p_body_filter.ShouldCollideLocked(*other_jolt_body)) {
			continue;
		}

		if (!collides(*other_jolt_body, 1.0f)) {
			continue;
		}

		if (p_ignore_overlaps && collides(*other_jolt_body, 0.0f)) {
			continue;
		}

		float lo = 0.0f;
		float hi = 1.0f;
		float coeff = 0.5f;

		for (int j = 0; j < step_count; ++j) {
			const float fraction = lo + (hi - lo) * coeff;

			if (collides(*other_jolt_body, fraction)) {
				collided = true;

				hi = fraction;

				if (j == 0 || lo > 0.0f) {
					coeff = 0.5f;
				} else {
					coeff = 0.25f;
				}
			} else {
				lo = fraction;

				if (j == 0 || hi < 1.0f) {
					coeff = 0.5f;
				} else {
					coeff = 0.75f;
				}
			}
		}

		if (lo < r_closest_safe) {
			r_closest_safe = lo;
			r_closest_unsafe = hi;
		}
	}

	return collided;
}

bool JoltPhysicsDirectSpaceState3D::_body_motion_recover(const JoltBody3D &p_body, const Transform3D &p_transform, float p_margin, const HashSet<RID> &p_excluded_bodies, const HashSet<ObjectID> &p_excluded_objects, Vector3 &r_recovery) const {
	const JPH::Shape *jolt_shape = p_body.get_jolt_shape();

	const Vector3 com_scaled = to_godot(jolt_shape->GetCenterOfMass());
	Transform3D transform_com = p_transform.translated_local(com_scaled);

	JPH::CollideShapeSettings settings;
	settings.mMaxSeparationDistance = p_margin;

	const Vector3 &base_offset = transform_com.origin;

	const JoltMotionFilter3D motion_filter(p_body, p_excluded_bodies, p_excluded_objects);
	JoltQueryCollectorAnyMulti<JPH::CollideShapeCollector, 32> collector;

	bool recovered = false;

	for (int i = 0; i < JoltProjectSettings::motion_query_recovery_iterations; ++i) {
		collector.reset();

		_collide_shape_kinematics(jolt_shape, JPH::Vec3::sOne(), to_jolt_r(transform_com), settings, to_jolt_r(base_offset), collector, motion_filter, motion_filter, motion_filter, motion_filter);

		if (!collector.had_hit()) {
			break;
		}

		const int hit_count = collector.get_hit_count();

		float combined_priority = 0.0;

		for (int j = 0; j < hit_count; j++) {
			const JPH::CollideShapeResult &hit = collector.get_hit(j);
			const JoltBody3D *other_body = space->try_get_body(hit.mBodyID2);
			ERR_CONTINUE(other_body == nullptr);

			combined_priority += other_body->get_collision_priority();
		}

		const float average_priority = MAX(combined_priority / (float)hit_count, (float)CMP_EPSILON);

		recovered = true;

		Vector3 recovery;

		for (int j = 0; j < hit_count; ++j) {
			const JPH::CollideShapeResult &hit = collector.get_hit(j);

			const Vector3 penetration_axis = to_godot(hit.mPenetrationAxis.Normalized());
			const Vector3 margin_offset = penetration_axis * p_margin;

			const Vector3 point_on_1 = base_offset + to_godot(hit.mContactPointOn1) + margin_offset;
			const Vector3 point_on_2 = base_offset + to_godot(hit.mContactPointOn2);

			const real_t distance_to_1 = penetration_axis.dot(point_on_1 + recovery);
			const real_t distance_to_2 = penetration_axis.dot(point_on_2);

			const float penetration_depth = float(distance_to_1 - distance_to_2);

			if (penetration_depth <= 0.0f) {
				continue;
			}

			const JoltBody3D *other_body = space->try_get_body(hit.mBodyID2);
			ERR_CONTINUE(other_body == nullptr);

			const float recovery_distance = penetration_depth * JoltProjectSettings::motion_query_recovery_amount;
			const float other_priority = other_body->get_collision_priority();
			const float other_priority_normalized = other_priority / average_priority;
			const float scaled_recovery_distance = recovery_distance * other_priority_normalized;

			recovery -= penetration_axis * scaled_recovery_distance;
		}

		if (recovery == Vector3()) {
			break;
		}

		r_recovery += recovery;
		transform_com.origin += recovery;
	}

	return recovered;
}

bool JoltPhysicsDirectSpaceState3D::_body_motion_cast(const JoltBody3D &p_body, const Transform3D &p_transform, const Vector3 &p_scale, const Vector3 &p_motion, bool p_collide_separation_ray, const HashSet<RID> &p_excluded_bodies, const HashSet<ObjectID> &p_excluded_objects, real_t &r_safe_fraction, real_t &r_unsafe_fraction) const {
	const Transform3D body_transform = p_transform.scaled_local(p_scale);

	const JPH::CollideShapeSettings settings;
	const JoltMotionFilter3D motion_filter(p_body, p_excluded_bodies, p_excluded_objects, p_collide_separation_ray);

	bool collided = false;

	for (int i = 0; i < p_body.get_shape_count(); ++i) {
		if (p_body.is_shape_disabled(i)) {
			continue;
		}

		JoltShape3D *shape = p_body.get_shape(i);

		if (!shape->is_convex()) {
			continue;
		}

		const JPH::ShapeRefC jolt_shape = shape->try_build();
		if (unlikely(jolt_shape == nullptr)) {
			return false;
		}

		const Vector3 com_scaled = to_godot(jolt_shape->GetCenterOfMass());
		const Transform3D transform_local = p_body.get_shape_transform_scaled(i);
		const Transform3D transform_com_local = transform_local.translated_local(com_scaled);
		Transform3D transform_com = body_transform * transform_com_local;

		Vector3 scale;
		JoltMath::decompose(transform_com, scale);
		JOLT_ENSURE_SCALE_VALID(jolt_shape, scale, "body_test_motion was passed an invalid transform along with body '%s'. This results in invalid scaling for shape at index %d.");

		real_t shape_safe_fraction = 1.0;
		real_t shape_unsafe_fraction = 1.0;

		collided |= _cast_motion_impl(*jolt_shape, transform_com, scale, p_motion, JoltProjectSettings::use_enhanced_internal_edge_removal_for_motion_queries, false, settings, motion_filter, motion_filter, motion_filter, motion_filter, shape_safe_fraction, shape_unsafe_fraction);

		r_safe_fraction = MIN(r_safe_fraction, shape_safe_fraction);
		r_unsafe_fraction = MIN(r_unsafe_fraction, shape_unsafe_fraction);
	}

	return collided;
}

bool JoltPhysicsDirectSpaceState3D::_body_motion_collide(const JoltBody3D &p_body, const Transform3D &p_transform, const Vector3 &p_motion, float p_margin, int p_max_collisions, const HashSet<RID> &p_excluded_bodies, const HashSet<ObjectID> &p_excluded_objects, PhysicsServer3D::MotionResult *p_result) const {
	if (p_max_collisions == 0) {
		return false;
	}

	const JPH::Shape *jolt_shape = p_body.get_jolt_shape();

	const Vector3 com_scaled = to_godot(jolt_shape->GetCenterOfMass());
	const Transform3D transform_com = p_transform.translated_local(com_scaled);

	JPH::CollideShapeSettings settings;
	settings.mCollectFacesMode = JPH::ECollectFacesMode::CollectFaces;
	settings.mMaxSeparationDistance = p_margin;

	const Vector3 &base_offset = transform_com.origin;

	const JoltMotionFilter3D motion_filter(p_body, p_excluded_bodies, p_excluded_objects);
	JoltQueryCollectorClosestMulti<JPH::CollideShapeCollector, 32> collector(p_max_collisions);
	_collide_shape_kinematics(jolt_shape, JPH::Vec3::sOne(), to_jolt_r(transform_com), settings, to_jolt_r(base_offset), collector, motion_filter, motion_filter, motion_filter, motion_filter);

	if (!collector.had_hit() || p_result == nullptr) {
		return collector.had_hit();
	}

	int count = 0;

	for (int i = 0; i < collector.get_hit_count(); ++i) {
		const JPH::CollideShapeResult &hit = collector.get_hit(i);

		const float penetration_depth = hit.mPenetrationDepth + p_margin;

		if (penetration_depth <= 0.0f) {
			continue;
		}

		const Vector3 normal = to_godot(-hit.mPenetrationAxis.Normalized());

		if (p_motion.length_squared() > 0) {
			const Vector3 direction = p_motion.normalized();

			if (direction.dot(normal) >= -CMP_EPSILON) {
				continue;
			}
		}

		JPH::ContactPoints contact_points1;
		JPH::ContactPoints contact_points2;

		if (p_max_collisions > 1) {
			_generate_manifold(hit, contact_points1, contact_points2 JPH_IF_DEBUG_RENDERER(, to_jolt_r(base_offset)));
		} else {
			contact_points2.push_back(hit.mContactPointOn2);
		}

		const JoltShapedObject3D *collider = space->try_get_shaped(hit.mBodyID2);
		ERR_FAIL_NULL_V(collider, false);

		const int local_shape = p_body.find_shape_index(hit.mSubShapeID1);
		ERR_FAIL_COND_V(local_shape == -1, false);

		const int collider_shape = collider->find_shape_index(hit.mSubShapeID2);
		ERR_FAIL_COND_V(collider_shape == -1, false);

		for (JPH::Vec3 contact_point : contact_points2) {
			const Vector3 position = base_offset + to_godot(contact_point);

			PhysicsServer3D::MotionCollision &collision = p_result->collisions[count++];

			collision.position = position;
			collision.normal = normal;
			collision.collider_velocity = collider->get_velocity_at_position(position);
			collision.collider_angular_velocity = collider->get_angular_velocity();
			collision.depth = penetration_depth;
			collision.local_shape = local_shape;
			collision.collider_id = collider->get_instance_id();
			collision.collider = collider->get_rid();
			collision.collider_shape = collider_shape;

			if (count == p_max_collisions) {
				break;
			}
		}

		if (count == p_max_collisions) {
			break;
		}
	}

	p_result->collision_count = count;

	return count > 0;
}

int JoltPhysicsDirectSpaceState3D::_try_get_face_index(const JPH::Body &p_body, const JPH::SubShapeID &p_sub_shape_id) {
	if (!JoltProjectSettings::enable_ray_cast_face_index) {
		return -1;
	}

	const JPH::Shape *root_shape = p_body.GetShape();
	JPH::SubShapeID sub_shape_id_remainder;
	const JPH::Shape *leaf_shape = root_shape->GetLeafShape(p_sub_shape_id, sub_shape_id_remainder);

	if (leaf_shape->GetType() != JPH::EShapeType::Mesh) {
		return -1;
	}

	const JPH::MeshShape *mesh_shape = static_cast<const JPH::MeshShape *>(leaf_shape);
	return (int)mesh_shape->GetTriangleUserData(sub_shape_id_remainder);
}

void JoltPhysicsDirectSpaceState3D::_generate_manifold(const JPH::CollideShapeResult &p_hit, JPH::ContactPoints &r_contact_points1, JPH::ContactPoints &r_contact_points2 JPH_IF_DEBUG_RENDERER(, JPH::RVec3Arg p_center_of_mass)) const {
	const JPH::PhysicsSystem &physics_system = space->get_physics_system();
	const JPH::PhysicsSettings &physics_settings = physics_system.GetPhysicsSettings();
	const JPH::Vec3 penetration_axis = p_hit.mPenetrationAxis.Normalized();

	JPH::ManifoldBetweenTwoFaces(p_hit.mContactPointOn1, p_hit.mContactPointOn2, penetration_axis, physics_settings.mManifoldTolerance, p_hit.mShape1Face, p_hit.mShape2Face, r_contact_points1, r_contact_points2 JPH_IF_DEBUG_RENDERER(, p_center_of_mass));

	if (r_contact_points1.size() > 4) {
		JPH::PruneContactPoints(penetration_axis, r_contact_points1, r_contact_points2 JPH_IF_DEBUG_RENDERER(, p_center_of_mass));
	}
}

void JoltPhysicsDirectSpaceState3D::_collide_shape_queries(
		const JPH::Shape *p_shape,
		JPH::Vec3Arg p_scale,
		JPH::RMat44Arg p_transform_com,
		const JPH::CollideShapeSettings &p_settings,
		JPH::RVec3Arg p_base_offset,
		JPH::CollideShapeCollector &p_collector,
		const JPH::BroadPhaseLayerFilter &p_broad_phase_layer_filter,
		const JPH::ObjectLayerFilter &p_object_layer_filter,
		const JPH::BodyFilter &p_body_filter,
		const JPH::ShapeFilter &p_shape_filter) const {
	if (JoltProjectSettings::use_enhanced_internal_edge_removal_for_queries) {
		space->get_narrow_phase_query().CollideShapeWithInternalEdgeRemoval(p_shape, p_scale, p_transform_com, p_settings, p_base_offset, p_collector, p_broad_phase_layer_filter, p_object_layer_filter, p_body_filter, p_shape_filter);
	} else {
		space->get_narrow_phase_query().CollideShape(p_shape, p_scale, p_transform_com, p_settings, p_base_offset, p_collector, p_broad_phase_layer_filter, p_object_layer_filter, p_body_filter, p_shape_filter);
	}
}

void JoltPhysicsDirectSpaceState3D::_collide_shape_kinematics(
		const JPH::Shape *p_shape,
		JPH::Vec3Arg p_scale,
		JPH::RMat44Arg p_transform_com,
		const JPH::CollideShapeSettings &p_settings,
		JPH::RVec3Arg p_base_offset,
		JPH::CollideShapeCollector &p_collector,
		const JPH::BroadPhaseLayerFilter &p_broad_phase_layer_filter,
		const JPH::ObjectLayerFilter &p_object_layer_filter,
		const JPH::BodyFilter &p_body_filter,
		const JPH::ShapeFilter &p_shape_filter) const {
	if (JoltProjectSettings::use_enhanced_internal_edge_removal_for_motion_queries) {
		space->get_narrow_phase_query().CollideShapeWithInternalEdgeRemoval(p_shape, p_scale, p_transform_com, p_settings, p_base_offset, p_collector, p_broad_phase_layer_filter, p_object_layer_filter, p_body_filter, p_shape_filter);
	} else {
		space->get_narrow_phase_query().CollideShape(p_shape, p_scale, p_transform_com, p_settings, p_base_offset, p_collector, p_broad_phase_layer_filter, p_object_layer_filter, p_body_filter, p_shape_filter);
	}
}

JoltPhysicsDirectSpaceState3D::JoltPhysicsDirectSpaceState3D(JoltSpace3D *p_space) :
		space(p_space) {
}

bool JoltPhysicsDirectSpaceState3D::intersect_ray(const RayParameters &p_parameters, RayResult &r_result) {
	ERR_FAIL_COND_V_MSG(space->is_stepping(), false, "intersect_ray must not be called while the physics space is being stepped.");

	space->flush_pending_objects();

	const JoltQueryFilter3D query_filter(*this, p_parameters.collision_mask, p_parameters.collide_with_bodies, p_parameters.collide_with_areas, p_parameters.exclude, p_parameters.pick_ray);

	const JPH::RVec3 from = to_jolt_r(p_parameters.from);
	const JPH::RVec3 to = to_jolt_r(p_parameters.to);
	const JPH::Vec3 vector = JPH::Vec3(to - from);
	const JPH::RRayCast ray(from, vector);

	const JPH::EBackFaceMode back_face_mode = p_parameters.hit_back_faces ? JPH::EBackFaceMode::CollideWithBackFaces : JPH::EBackFaceMode::IgnoreBackFaces;

	JPH::RayCastSettings settings;
	settings.mTreatConvexAsSolid = p_parameters.hit_from_inside;
	settings.mBackFaceModeTriangles = back_face_mode;

	JoltQueryCollectorClosest<JPH::CastRayCollector> collector;
	space->get_narrow_phase_query().CastRay(ray, settings, collector, query_filter, query_filter, query_filter);

	if (!collector.had_hit()) {
		return false;
	}

	const JPH::RayCastResult &hit = collector.get_hit();

	const JPH::BodyID &body_id = hit.mBodyID;
	const JPH::SubShapeID &sub_shape_id = hit.mSubShapeID2;

	const JoltObject3D *object = space->try_get_object(body_id);
	ERR_FAIL_NULL_V(object, false);

	const JPH::RVec3 position = ray.GetPointOnRay(hit.mFraction);

	JPH::Vec3 normal = JPH::Vec3::sZero();

	if (!p_parameters.hit_from_inside || hit.mFraction > 0.0f) {
		normal = object->get_jolt_body()->GetWorldSpaceSurfaceNormal(sub_shape_id, position);

		// If we got a back-face normal we need to flip it.
		if (normal.Dot(vector) > 0) {
			normal = -normal;
		}
	}

	r_result.position = to_godot(position);
	r_result.normal = to_godot(normal);
	r_result.rid = object->get_rid();
	r_result.collider_id = object->get_instance_id();
	r_result.collider = object->get_instance();
	r_result.shape = 0;

	if (const JoltShapedObject3D *shaped_object = object->as_shaped()) {
		const int shape_index = shaped_object->find_shape_index(sub_shape_id);
		ERR_FAIL_COND_V(shape_index == -1, false);
		r_result.shape = shape_index;
		r_result.face_index = _try_get_face_index(*object->get_jolt_body(), sub_shape_id);
	}

	return true;
}

int JoltPhysicsDirectSpaceState3D::intersect_ray_all(const RayParameters &p_parameters, RayResult *r_results, int p_result_max) {
	ERR_FAIL_COND_V_MSG(space->is_stepping(), 0, "intersect_ray_all must not be called while the physics space is being stepped.");

	if (p_result_max == 0) {
		return 0;
	}

	space->flush_pending_objects();

	const JoltQueryFilter3D query_filter(*this, p_parameters.collision_mask, p_parameters.collide_with_bodies, p_parameters.collide_with_areas, p_parameters.exclude, p_parameters.pick_ray);

	const JPH::RVec3 from = to_jolt_r(p_parameters.from);
	const JPH::RVec3 to = to_jolt_r(p_parameters.to);
	const JPH::Vec3 vector = JPH::Vec3(to - from);
	const JPH::RRayCast ray(from, vector);

	const JPH::EBackFaceMode back_face_mode = p_parameters.hit_back_faces ? JPH::EBackFaceMode::CollideWithBackFaces : JPH::EBackFaceMode::IgnoreBackFaces;

	JPH::RayCastSettings settings;
	settings.mTreatConvexAsSolid = p_parameters.hit_from_inside;
	settings.mBackFaceModeTriangles = back_face_mode;
	settings.mBackFaceModeConvex = back_face_mode;

	// Use AllHit collector to avoid any broad-phase early-out pruning issues.
	// ClosestMulti's sorted insertion could interact with the broad-phase tree
	// walk in ways that cause directional bias. Collect everything, sort after.
	JoltQueryCollectorAll<JPH::CastRayCollector, 32> collector;
	space->get_narrow_phase_query().CastRay(ray, settings, collector, query_filter, query_filter, query_filter);

	int hit_count = collector.get_hit_count();
	if (hit_count == 0) {
		return 0;
	}

	// Gather hits into a sortable array.
	LocalVector<JPH::RayCastResult> sorted_hits;
	sorted_hits.resize(hit_count);
	for (int i = 0; i < hit_count; ++i) {
		sorted_hits[i] = collector.get_hit(i);
	}

	// Sort by fraction (closest first).
	sorted_hits.sort_custom<_RayCastFractionCompare>();

	// Cap at max results.
	if (hit_count > p_result_max) {
		hit_count = p_result_max;
	}

	// Populate output results from sorted hits.
	// Use a separate output counter so that null objects (orphan Jolt bodies from
	// streaming terrain chunks mid-removal, etc.) are skipped instead of truncating
	// all remaining results. This matches calc_ray_shielding / _shielding_batch_worker
	// which also use `continue` on null objects.
	int output_count = 0;
	for (int i = 0; i < hit_count; ++i) {
		const JPH::RayCastResult &hit = sorted_hits[i];

		const JPH::BodyID &body_id = hit.mBodyID;
		const JPH::SubShapeID &sub_shape_id = hit.mSubShapeID2;

		const JoltObject3D *object = space->try_get_object(body_id);
		if (!object) {
			continue; // Skip orphan Jolt bodies — don't truncate remaining hits.
		}

		RayResult &result = r_results[output_count];

		const JPH::RVec3 position = ray.GetPointOnRay(hit.mFraction);

		JPH::Vec3 normal = JPH::Vec3::sZero();

		if (!p_parameters.hit_from_inside || hit.mFraction > 0.0f) {
			normal = object->get_jolt_body()->GetWorldSpaceSurfaceNormal(sub_shape_id, position);

			if (normal.Dot(vector) > 0) {
				normal = -normal;
			}
		}

		result.position = to_godot(position);
		result.normal = to_godot(normal);
		result.rid = object->get_rid();
		result.collider_id = object->get_instance_id();
		result.collider = object->get_instance();
		result.shape = 0;

		if (const JoltShapedObject3D *shaped_object = object->as_shaped()) {
			const int shape_index = shaped_object->find_shape_index(sub_shape_id);
			if (shape_index == -1) {
				continue; // Skip hits with invalid shape index — don't truncate.
			}
			result.shape = shape_index;
			result.face_index = _try_get_face_index(*object->get_jolt_body(), sub_shape_id);
		}

		output_count++;
	}

	return output_count;
}

float JoltPhysicsDirectSpaceState3D::calc_ray_shielding(const RayParameters &p_parameters, RID p_target_body, float p_max_absorption) {
	ERR_FAIL_COND_V_MSG(space->is_stepping(), 0.0f, "calc_ray_shielding must not be called while the physics space is being stepped.");

	space->flush_pending_objects();

	const JoltQueryFilter3D query_filter(*this, p_parameters.collision_mask, p_parameters.collide_with_bodies, p_parameters.collide_with_areas, p_parameters.exclude, p_parameters.pick_ray);

	const JPH::RVec3 from = to_jolt_r(p_parameters.from);
	const JPH::RVec3 to = to_jolt_r(p_parameters.to);
	const JPH::Vec3 vector = JPH::Vec3(to - from);
	const JPH::RRayCast ray(from, vector);

	const JPH::EBackFaceMode back_face_mode = p_parameters.hit_back_faces ? JPH::EBackFaceMode::CollideWithBackFaces : JPH::EBackFaceMode::IgnoreBackFaces;

	JPH::RayCastSettings settings;
	settings.mTreatConvexAsSolid = p_parameters.hit_from_inside;
	settings.mBackFaceModeTriangles = back_face_mode;
	settings.mBackFaceModeConvex = back_face_mode;

	JoltQueryCollectorAll<JPH::CastRayCollector, 32> collector;
	space->get_narrow_phase_query().CastRay(ray, settings, collector, query_filter, query_filter, query_filter);

	int hit_count = collector.get_hit_count();
	if (hit_count == 0) {
		return 0.0f;
	}

	// Sort hits by fraction (closest first).
	LocalVector<JPH::RayCastResult> sorted_hits;
	sorted_hits.resize(hit_count);
	for (int i = 0; i < hit_count; ++i) {
		sorted_hits[i] = collector.get_hit(i);
	}
	sorted_hits.sort_custom<_RayCastFractionCompare>();

	// Uses the shared _classify_shielding_hit() for tag-based classification.
	float absorbed = 0.0f;
	JPH::BodyID last_absorbed_body; // Tracks last body that contributed shielding.

	for (int i = 0; i < hit_count; ++i) {
		const JPH::RayCastResult &hit = sorted_hits[i];
		const JPH::BodyID &body_id = hit.mBodyID;

		const JoltObject3D *jolt_object = space->try_get_object(body_id);
		if (!jolt_object) {
			continue;
		}

		// Stop at the target body (don't count it as shielding).
		if (p_target_body.is_valid() && jolt_object->get_rid() == p_target_body) {
			break;
		}

		// Deduplicate same-body hits (front face + back face of convex shapes).
		if (body_id == last_absorbed_body) {
			continue;
		}

		float absorption = _classify_shielding_hit(jolt_object);
		if (absorption < 0.0f) {
			continue; // Skip — no absorption.
		}
		last_absorbed_body = body_id;
		if (absorption >= 99999.0f) {
			// DIAGNOSTIC: identify what body is being classified as terrain.
			const JoltBody3D *diag_body = jolt_object->as_body();
			Object *diag_inst = jolt_object->get_instance();
			print_line(vformat("[SHIELD 99999 DIAG] tag=%d fraction=%.4f layer=%d class=%s name=%s body_idx=%d",
				diag_body ? diag_body->get_shielding_tag() : -1,
				hit.mFraction,
				diag_body ? diag_body->get_collision_layer() : 0,
				diag_inst ? diag_inst->get_class() : "null",
				diag_inst ? String(diag_inst->call("get_name")) : "null",
				(int)body_id.GetIndex()));
			return 99999.0f; // Terrain — fully blocked.
		}
		absorbed += absorption;
		if (absorbed >= p_max_absorption) {
			return absorbed;
		}
	}

	return absorbed;
}

PackedFloat32Array JoltPhysicsDirectSpaceState3D::calc_ray_shielding_batch(
		const RayParameters &p_base_params,
		const PackedVector3Array &p_to_points,
		const TypedArray<RID> &p_target_bodies,
		const PackedFloat32Array &p_max_absorptions) {
	int ray_count = p_to_points.size();
	ERR_FAIL_COND_V(ray_count != p_target_bodies.size(), PackedFloat32Array());
	ERR_FAIL_COND_V(ray_count != p_max_absorptions.size(), PackedFloat32Array());
	ERR_FAIL_COND_V_MSG(space->is_stepping(), PackedFloat32Array(),
		"calc_ray_shielding_batch must not be called while the physics space is being stepped.");

	if (ray_count == 0) {
		return PackedFloat32Array();
	}

	uint64_t t_start = OS::get_singleton()->get_ticks_usec();

	space->flush_pending_objects();

	uint64_t t_flush = OS::get_singleton()->get_ticks_usec();

	// Shared filter (immutable — safe across threads).
	const JoltQueryFilter3D query_filter(*this, p_base_params.collision_mask,
		p_base_params.collide_with_bodies, p_base_params.collide_with_areas,
		p_base_params.exclude, p_base_params.pick_ray);

	// Ray settings.
	JPH::RayCastSettings settings;
	settings.mTreatConvexAsSolid = p_base_params.hit_from_inside;
	const auto bfm = p_base_params.hit_back_faces
		? JPH::EBackFaceMode::CollideWithBackFaces
		: JPH::EBackFaceMode::IgnoreBackFaces;
	settings.mBackFaceModeTriangles = bfm;
	settings.mBackFaceModeConvex = bfm;

	// Pre-extract target RIDs from TypedArray (avoid Variant boxing in hot loop).
	Vector<RID> target_rids;
	target_rids.resize(ray_count);
	for (int i = 0; i < ray_count; i++) {
		target_rids.write[i] = p_target_bodies[i];
	}

	// Output array.
	PackedFloat32Array results;
	results.resize(ray_count);

	// Build context for workers.
	ShieldingBatchContext ctx;
	ctx.narrow_phase = &space->get_narrow_phase_query();
	ctx.space = space;
	ctx.query_filter = &query_filter;
	ctx.ray_settings = settings;
	ctx.jolt_from = to_jolt_r(p_base_params.from);
	ctx.to_points = p_to_points.ptr();
	ctx.target_rids = target_rids.ptr();
	ctx.max_absorptions = p_max_absorptions.ptr();
	ctx.results = results.ptrw();

	uint64_t t_setup = OS::get_singleton()->get_ticks_usec();

	const int MIN_PARALLEL = 32;
	if (ray_count < MIN_PARALLEL) {
		// Sequential — overhead not worth it for few rays.
		for (int i = 0; i < ray_count; i++) {
			_shielding_batch_worker(&ctx, i);
		}
	} else {
		// Parallel — split across available worker threads.
		WorkerThreadPool::GroupID group =
			WorkerThreadPool::get_singleton()->add_native_group_task(
				_shielding_batch_worker, &ctx, ray_count, -1, true,
				SNAME("ShieldingBatch"));
		WorkerThreadPool::get_singleton()->wait_for_group_task_completion(group);
	}

	uint64_t t_rays = OS::get_singleton()->get_ticks_usec();

	print_line(vformat("[ShieldingBatch] rays=%d  flush=%dus  setup=%dus  raycasts=%dus  total=%dus",
		ray_count,
		(int)(t_flush - t_start),
		(int)(t_setup - t_flush),
		(int)(t_rays - t_setup),
		(int)(t_rays - t_start)));

	return results;
}

Dictionary JoltPhysicsDirectSpaceState3D::calc_structure_explosion(
		const RayParameters &p_base_params,
		const Dictionary &p_blocks,
		const PackedByteArray &p_block_grid,
		const Transform3D &p_structure_transform,
		float p_block_size,
		int p_num_x, int p_num_y, int p_num_z,
		float p_blast_radius,
		float p_damage_amount,
		float p_block_hp) {
	ERR_FAIL_COND_V_MSG(space->is_stepping(), Dictionary(),
		"calc_structure_explosion must not be called while the physics space is being stepped.");

	if (p_blocks.is_empty()) {
		return Dictionary();
	}

	uint64_t t_start = OS::get_singleton()->get_ticks_usec();

	space->flush_pending_objects();

	// --- Phase 1: Iterate block_grid, compute positions, filter by distance_squared ---
	// Iterates flat byte array instead of Dictionary.keys() — avoids Variant boxing overhead.
	// Uses distance_squared for the initial range check — avoids sqrt per block.
	static const StringName sn_body("body");
	static const StringName sn_hp("hp");

	const float half_x = p_num_x * 0.5f;
	const float half_y = p_num_y * 0.5f;
	const float half_z = p_num_z * 0.5f;
	const Vector3 hit_pos = p_base_params.from;
	const float blast_radius_sq = p_blast_radius * p_blast_radius;

	Vector<Vector3i> in_range_keys;
	PackedVector3Array to_points;
	Vector<RID> target_rids;
	PackedFloat32Array raw_damages;
	PackedFloat32Array block_hps;

	const int grid_size = p_num_x * p_num_y * p_num_z;
	ERR_FAIL_COND_V_MSG(p_block_grid.size() != grid_size, Dictionary(),
		vformat("calc_structure_explosion: block_grid size %d != expected %d (%dx%dx%d)",
			p_block_grid.size(), grid_size, p_num_x, p_num_y, p_num_z));
	const uint8_t *grid_ptr = p_block_grid.ptr();
	int total_blocks = p_blocks.size();

	int skip_dist = 0;
	int skip_body = 0;
	int skip_cast = 0;
	int skip_grid = 0;

	// Iterate flat grid: index = bx * num_y * num_z + by * num_z + bz
	for (int bx = 0; bx < p_num_x; bx++) {
		const float local_x = (bx + 0.5f - half_x) * p_block_size;
		for (int by = 0; by < p_num_y; by++) {
			const float local_y = (by + 0.5f - half_y) * p_block_size;
			for (int bz = 0; bz < p_num_z; bz++) {
				int idx = bx * p_num_y * p_num_z + by * p_num_z + bz;
				if (grid_ptr[idx] != 1) {
					continue; // empty cell
				}

				const float local_z = (bz + 0.5f - half_z) * p_block_size;
				Vector3 local_offset(local_x, local_y, local_z);
				Vector3 world_pos = p_structure_transform.xform(local_offset);

				float dist_sq = hit_pos.distance_squared_to(world_pos);
				if (dist_sq > blast_radius_sq) {
					skip_dist++;
					continue;
				}

				// Only look up Dictionary for in-range blocks.
				Vector3i key(bx, by, bz);
				if (!p_blocks.has(key)) {
					skip_grid++;
					continue;
				}

				Dictionary block_dict = p_blocks[key];
				Variant v_body = block_dict[sn_body];
				Object *body_obj = v_body.get_validated_object();
				if (!body_obj) {
					skip_body++;
					continue;
				}

				CollisionObject3D *col_obj = Object::cast_to<CollisionObject3D>(body_obj);
				if (!col_obj) {
					skip_cast++;
					continue;
				}
				RID rid = col_obj->get_rid();
				float hp = float(block_dict[sn_hp]);

				// Compute actual distance for falloff (only for in-range blocks).
				float dist = Math::sqrt(dist_sq);
				float norm_dist = dist / p_blast_radius;
				float nd3 = norm_dist * 3.0f;
				float falloff = 1.0f / (1.0f + nd3 * nd3 * nd3);
				float dmg = p_damage_amount * falloff;

				in_range_keys.push_back(key);
				to_points.push_back(world_pos);
				target_rids.push_back(rid);
				raw_damages.push_back(dmg);
				block_hps.push_back(hp);
			}
		}
	}

	int ray_count = to_points.size();

	uint64_t t_collect = OS::get_singleton()->get_ticks_usec();

	if (ray_count == 0) {
		print_line(vformat("[StructureExplosion] blocks=%d  in_range=0  collect=%dus  total=%dus",
			total_blocks, (int)(t_collect - t_start), (int)(t_collect - t_start)));
		return Dictionary();
	}

	// --- Phase 2: Multi-threaded shielding raycasts ---
	// Reuses existing ShieldingBatchContext + _shielding_batch_worker.
	const JoltQueryFilter3D query_filter(*this, p_base_params.collision_mask,
		p_base_params.collide_with_bodies, p_base_params.collide_with_areas,
		p_base_params.exclude, p_base_params.pick_ray);

	JPH::RayCastSettings settings;
	settings.mTreatConvexAsSolid = p_base_params.hit_from_inside;
	const auto bfm = p_base_params.hit_back_faces
		? JPH::EBackFaceMode::CollideWithBackFaces
		: JPH::EBackFaceMode::IgnoreBackFaces;
	settings.mBackFaceModeTriangles = bfm;
	settings.mBackFaceModeConvex = bfm;

	PackedFloat32Array absorptions;
	absorptions.resize(ray_count);

	ShieldingBatchContext ctx;
	ctx.narrow_phase = &space->get_narrow_phase_query();
	ctx.space = space;
	ctx.query_filter = &query_filter;
	ctx.ray_settings = settings;
	ctx.jolt_from = to_jolt_r(hit_pos);
	ctx.to_points = to_points.ptr();
	ctx.target_rids = target_rids.ptr();
	ctx.max_absorptions = raw_damages.ptr(); // max_absorption = raw_damage (early-out)
	ctx.results = absorptions.ptrw();

	const int MIN_PARALLEL = 32;
	if (ray_count < MIN_PARALLEL) {
		for (int i = 0; i < ray_count; i++) {
			_shielding_batch_worker(&ctx, i);
		}
	} else {
		WorkerThreadPool::GroupID group =
			WorkerThreadPool::get_singleton()->add_native_group_task(
				_shielding_batch_worker, &ctx, ray_count, -1, true,
				SNAME("StructureExplosion"));
		WorkerThreadPool::get_singleton()->wait_for_group_task_completion(group);
	}

	uint64_t t_rays = OS::get_singleton()->get_ticks_usec();

	// --- Phase 3: Apply damage, collect destroyed/survived blocks ---
	const float *abs_ptr = absorptions.ptr();
	const float *dmg_ptr = raw_damages.ptr();
	const float *hp_ptr = block_hps.ptr();

	Array destroyed_keys;
	PackedVector3Array destroyed_positions;
	PackedFloat32Array destroyed_overkill;
	Array survived_keys;
	PackedFloat32Array survived_hps;
	TypedArray<RID> survived_rids;

	int shielded_out = 0;
	for (int i = 0; i < ray_count; i++) {
		float final_dmg = MAX(dmg_ptr[i] - abs_ptr[i], 0.0f);
		if (final_dmg < 0.5f) {
			shielded_out++;
			continue;
		}
		float new_hp = hp_ptr[i] - final_dmg;
		if (new_hp <= 0.0f) {
			destroyed_keys.push_back(in_range_keys[i]);
			destroyed_positions.push_back(to_points[i]);
			float overkill = CLAMP(-new_hp / p_block_hp, 0.0f, 1.0f);
			destroyed_overkill.push_back(overkill);
		} else {
			survived_keys.push_back(in_range_keys[i]);
			survived_hps.push_back(new_hp);
			survived_rids.push_back(target_rids[i]);
		}
	}

	Dictionary result;
	result["destroyed_keys"] = destroyed_keys;
	result["destroyed_positions"] = destroyed_positions;
	result["destroyed_overkill"] = destroyed_overkill;
	result["survived_keys"] = survived_keys;
	result["survived_hps"] = survived_hps;
	result["survived_rids"] = survived_rids;

	uint64_t t_end = OS::get_singleton()->get_ticks_usec();

	print_line(vformat("[StructureExplosion] blocks=%d  in_range=%d  destroyed=%d  survived=%d  shielded=%d  skip(dist=%d grid=%d body=%d cast=%d)  collect=%dus  raycasts=%dus  result=%dus  total=%dus",
		total_blocks, ray_count, destroyed_keys.size(), survived_keys.size(), shielded_out,
		skip_dist, skip_grid, skip_body, skip_cast,
		(int)(t_collect - t_start),
		(int)(t_rays - t_collect),
		(int)(t_end - t_rays),
		(int)(t_end - t_start)));

	return result;
}

PackedInt32Array JoltPhysicsDirectSpaceState3D::calc_structural_integrity(
		const PackedByteArray &p_block_grid,
		int p_num_x, int p_num_y, int p_num_z,
		int p_total_blocks) {
	int grid_size = p_num_x * p_num_y * p_num_z;
	ERR_FAIL_COND_V_MSG(p_block_grid.size() != grid_size, PackedInt32Array(),
		vformat("calc_structural_integrity: block_grid size %d != expected %d (%dx%dx%d)",
			p_block_grid.size(), grid_size, p_num_x, p_num_y, p_num_z));
	ERR_FAIL_COND_V(p_total_blocks <= 0, PackedInt32Array());

	uint64_t t_start = OS::get_singleton()->get_ticks_usec();

	const uint8_t *grid = p_block_grid.ptr();
	const int nx = p_num_x;
	const int ny = p_num_y;
	const int nz = p_num_z;
	const int ny_nz = ny * nz;

	// Allocate visited array and BFS queue with raw pointers for max speed.
	uint8_t *visited = (uint8_t *)memalloc(grid_size);
	memset(visited, 0, grid_size);

	int *bfs_queue = (int *)memalloc(p_total_blocks * sizeof(int));
	int head = 0;
	int tail = 0;

	// Seed: all blocks at y=0 (ground row).
	for (int bx = 0; bx < nx; bx++) {
		int base = bx * ny_nz;
		for (int bz = 0; bz < nz; bz++) {
			int idx = base + bz; // y=0 → by*nz = 0
			if (grid[idx] == 1) {
				visited[idx] = 1;
				bfs_queue[tail++] = idx;
			}
		}
	}

	int visited_count = tail;

	// BFS expansion with early exit.
	while (head < tail) {
		if (visited_count == p_total_blocks) {
			break;
		}

		int ci = bfs_queue[head++];

		// Decompose flat index → (bx, by, bz) for bounds checking.
		int bx = ci / ny_nz;
		int rem = ci % ny_nz;
		int by = rem / nz;
		int bz = rem % nz;

		// +X
		if (bx + 1 < nx) {
			int ni = ci + ny_nz;
			if (grid[ni] == 1 && visited[ni] == 0) {
				visited[ni] = 1;
				bfs_queue[tail++] = ni;
				visited_count++;
			}
		}
		// -X
		if (bx > 0) {
			int ni = ci - ny_nz;
			if (grid[ni] == 1 && visited[ni] == 0) {
				visited[ni] = 1;
				bfs_queue[tail++] = ni;
				visited_count++;
			}
		}
		// +Y
		if (by + 1 < ny) {
			int ni = ci + nz;
			if (grid[ni] == 1 && visited[ni] == 0) {
				visited[ni] = 1;
				bfs_queue[tail++] = ni;
				visited_count++;
			}
		}
		// -Y
		if (by > 0) {
			int ni = ci - nz;
			if (grid[ni] == 1 && visited[ni] == 0) {
				visited[ni] = 1;
				bfs_queue[tail++] = ni;
				visited_count++;
			}
		}
		// +Z
		if (bz + 1 < nz) {
			int ni = ci + 1;
			if (grid[ni] == 1 && visited[ni] == 0) {
				visited[ni] = 1;
				bfs_queue[tail++] = ni;
				visited_count++;
			}
		}
		// -Z
		if (bz > 0) {
			int ni = ci - 1;
			if (grid[ni] == 1 && visited[ni] == 0) {
				visited[ni] = 1;
				bfs_queue[tail++] = ni;
				visited_count++;
			}
		}
	}

	uint64_t t_bfs = OS::get_singleton()->get_ticks_usec();

	// Collect unsupported blocks as coordinate triplets (bx, by, bz, ...).
	PackedInt32Array result;
	if (visited_count < p_total_blocks) {
		int unsupported_count = p_total_blocks - visited_count;
		result.resize(unsupported_count * 3);
		int *result_ptr = result.ptrw();
		int out = 0;

		for (int idx = 0; idx < grid_size; idx++) {
			if (grid[idx] == 1 && visited[idx] == 0) {
				int rbx = idx / ny_nz;
				int rrem = idx % ny_nz;
				int rby = rrem / nz;
				int rbz = rrem % nz;
				result_ptr[out++] = rbx;
				result_ptr[out++] = rby;
				result_ptr[out++] = rbz;
			}
		}

		if (out < unsupported_count * 3) {
			result.resize(out);
		}
	}

	memfree(visited);
	memfree(bfs_queue);

	uint64_t t_end = OS::get_singleton()->get_ticks_usec();

	print_line(vformat("[StructuralIntegrity_C] blocks=%d  visited=%d  unsupported=%d  bfs=%dus  collect=%dus  total=%dus%s",
		p_total_blocks, visited_count, result.size() / 3,
		(int)(t_bfs - t_start),
		(int)(t_end - t_bfs),
		(int)(t_end - t_start),
		visited_count == p_total_blocks ? String(" (early-exit)") : String("")));

	return result;
}

int JoltPhysicsDirectSpaceState3D::intersect_point(const PointParameters &p_parameters, ShapeResult *r_results, int p_result_max) {
	ERR_FAIL_COND_V_MSG(space->is_stepping(), false, "intersect_point must not be called while the physics space is being stepped.");

	if (p_result_max == 0) {
		return 0;
	}

	space->flush_pending_objects();

	const JoltQueryFilter3D query_filter(*this, p_parameters.collision_mask, p_parameters.collide_with_bodies, p_parameters.collide_with_areas, p_parameters.exclude);
	JoltQueryCollectorAnyMulti<JPH::CollidePointCollector, 32> collector(p_result_max);
	space->get_narrow_phase_query().CollidePoint(to_jolt_r(p_parameters.position), collector, query_filter, query_filter, query_filter);

	const int hit_count = collector.get_hit_count();

	for (int i = 0; i < hit_count; ++i) {
		const JPH::CollidePointResult &hit = collector.get_hit(i);
		const JoltObject3D *object = space->try_get_object(hit.mBodyID);
		ERR_FAIL_NULL_V(object, 0);

		ShapeResult &result = *r_results++;

		result.shape = 0;

		if (const JoltShapedObject3D *shaped_object = object->as_shaped()) {
			const int shape_index = shaped_object->find_shape_index(hit.mSubShapeID2);
			ERR_FAIL_COND_V(shape_index == -1, 0);
			result.shape = shape_index;
		}

		result.rid = object->get_rid();
		result.collider_id = object->get_instance_id();
		result.collider = object->get_instance();
	}

	return hit_count;
}

int JoltPhysicsDirectSpaceState3D::intersect_shape(const ShapeParameters &p_parameters, ShapeResult *r_results, int p_result_max) {
	ERR_FAIL_COND_V_MSG(space->is_stepping(), false, "intersect_shape must not be called while the physics space is being stepped.");

	if (p_result_max == 0) {
		return 0;
	}

	space->flush_pending_objects();

	JoltShape3D *shape = JoltPhysicsServer3D::get_singleton()->get_shape(p_parameters.shape_rid);
	ERR_FAIL_NULL_V(shape, 0);

	const JPH::ShapeRefC jolt_shape = shape->try_build();
	ERR_FAIL_NULL_V(jolt_shape, 0);

	Transform3D transform = p_parameters.transform;
	JOLT_ENSURE_SCALE_NOT_ZERO(transform, "intersect_shape was passed an invalid transform.");

	Vector3 scale;
	JoltMath::decompose(transform, scale);
	JOLT_ENSURE_SCALE_VALID(jolt_shape, scale, "intersect_shape was passed an invalid transform.");

	const Vector3 com_scaled = to_godot(jolt_shape->GetCenterOfMass());
	const Transform3D transform_com = transform.translated_local(com_scaled);

	JPH::CollideShapeSettings settings;
	settings.mMaxSeparationDistance = (float)p_parameters.margin;

	const JoltQueryFilter3D query_filter(*this, p_parameters.collision_mask, p_parameters.collide_with_bodies, p_parameters.collide_with_areas, p_parameters.exclude);
	JoltQueryCollectorAnyMulti<JPH::CollideShapeCollector, 32> collector(p_result_max);
	_collide_shape_queries(jolt_shape, to_jolt(scale), to_jolt_r(transform_com), settings, to_jolt_r(transform_com.origin), collector, query_filter, query_filter, query_filter);

	const int hit_count = collector.get_hit_count();

	for (int i = 0; i < hit_count; ++i) {
		const JPH::CollideShapeResult &hit = collector.get_hit(i);
		const JoltObject3D *object = space->try_get_object(hit.mBodyID2);
		ERR_FAIL_NULL_V(object, 0);

		ShapeResult &result = *r_results++;

		result.shape = 0;

		if (const JoltShapedObject3D *shaped_object = object->as_shaped()) {
			const int shape_index = shaped_object->find_shape_index(hit.mSubShapeID2);
			ERR_FAIL_COND_V(shape_index == -1, 0);
			result.shape = shape_index;
		}

		result.rid = object->get_rid();
		result.collider_id = object->get_instance_id();
		result.collider = object->get_instance();
	}

	return hit_count;
}

bool JoltPhysicsDirectSpaceState3D::cast_motion(const ShapeParameters &p_parameters, real_t &r_closest_safe, real_t &r_closest_unsafe, ShapeRestInfo *r_info) {
	ERR_FAIL_COND_V_MSG(space->is_stepping(), false, "cast_motion must not be called while the physics space is being stepped.");
	ERR_FAIL_COND_V_MSG(r_info != nullptr, false, "Providing rest info as part of cast_motion is not supported when using Jolt Physics.");

	space->flush_pending_objects();

	JoltShape3D *shape = JoltPhysicsServer3D::get_singleton()->get_shape(p_parameters.shape_rid);
	ERR_FAIL_NULL_V(shape, false);

	const JPH::ShapeRefC jolt_shape = shape->try_build();
	ERR_FAIL_NULL_V(jolt_shape, false);

	Transform3D transform = p_parameters.transform;
	JOLT_ENSURE_SCALE_NOT_ZERO(transform, "cast_motion (maybe from ShapeCast3D?) was passed an invalid transform.");

	Vector3 scale;
	JoltMath::decompose(transform, scale);
	JOLT_ENSURE_SCALE_VALID(jolt_shape, scale, "cast_motion (maybe from ShapeCast3D?) was passed an invalid transform.");

	const Vector3 com_scaled = to_godot(jolt_shape->GetCenterOfMass());
	Transform3D transform_com = transform.translated_local(com_scaled);

	JPH::CollideShapeSettings settings;
	settings.mMaxSeparationDistance = (float)p_parameters.margin;

	const JoltQueryFilter3D query_filter(*this, p_parameters.collision_mask, p_parameters.collide_with_bodies, p_parameters.collide_with_areas, p_parameters.exclude);
	_cast_motion_impl(*jolt_shape, transform_com, scale, p_parameters.motion, JoltProjectSettings::use_enhanced_internal_edge_removal_for_queries, true, settings, query_filter, query_filter, query_filter, JPH::ShapeFilter(), r_closest_safe, r_closest_unsafe);

	return true;
}

bool JoltPhysicsDirectSpaceState3D::collide_shape(const ShapeParameters &p_parameters, Vector3 *r_results, int p_result_max, int &r_result_count) {
	r_result_count = 0;

	ERR_FAIL_COND_V_MSG(space->is_stepping(), false, "collide_shape must not be called while the physics space is being stepped.");

	if (p_result_max == 0) {
		return false;
	}

	space->flush_pending_objects();

	JoltShape3D *shape = JoltPhysicsServer3D::get_singleton()->get_shape(p_parameters.shape_rid);
	ERR_FAIL_NULL_V(shape, false);

	const JPH::ShapeRefC jolt_shape = shape->try_build();
	ERR_FAIL_NULL_V(jolt_shape, false);

	Transform3D transform = p_parameters.transform;
	JOLT_ENSURE_SCALE_NOT_ZERO(transform, "collide_shape was passed an invalid transform.");

	Vector3 scale;
	JoltMath::decompose(transform, scale);
	JOLT_ENSURE_SCALE_VALID(jolt_shape, scale, "collide_shape was passed an invalid transform.");

	const Vector3 com_scaled = to_godot(jolt_shape->GetCenterOfMass());
	const Transform3D transform_com = transform.translated_local(com_scaled);

	JPH::CollideShapeSettings settings;
	settings.mCollectFacesMode = JPH::ECollectFacesMode::CollectFaces;
	settings.mMaxSeparationDistance = (float)p_parameters.margin;

	const Vector3 &base_offset = transform_com.origin;

	const JoltQueryFilter3D query_filter(*this, p_parameters.collision_mask, p_parameters.collide_with_bodies, p_parameters.collide_with_areas, p_parameters.exclude);
	JoltQueryCollectorAnyMulti<JPH::CollideShapeCollector, 32> collector(p_result_max);
	_collide_shape_queries(jolt_shape, to_jolt(scale), to_jolt_r(transform_com), settings, to_jolt_r(base_offset), collector, query_filter, query_filter, query_filter);

	if (!collector.had_hit()) {
		return false;
	}

	const int max_points = p_result_max * 2;

	int point_count = 0;

	for (int i = 0; i < collector.get_hit_count(); ++i) {
		const JPH::CollideShapeResult &hit = collector.get_hit(i);

		const Vector3 penetration_axis = to_godot(hit.mPenetrationAxis.Normalized());
		const Vector3 margin_offset = penetration_axis * (float)p_parameters.margin;

		JPH::ContactPoints contact_points1;
		JPH::ContactPoints contact_points2;

		_generate_manifold(hit, contact_points1, contact_points2 JPH_IF_DEBUG_RENDERER(, to_jolt_r(base_offset)));

		for (JPH::uint j = 0; j < contact_points1.size(); ++j) {
			r_results[point_count++] = base_offset + to_godot(contact_points1[j]) + margin_offset;
			r_results[point_count++] = base_offset + to_godot(contact_points2[j]);

			if (point_count >= max_points) {
				break;
			}
		}

		if (point_count >= max_points) {
			break;
		}
	}

	r_result_count = point_count / 2;

	return true;
}

bool JoltPhysicsDirectSpaceState3D::rest_info(const ShapeParameters &p_parameters, ShapeRestInfo *r_info) {
	ERR_FAIL_COND_V_MSG(space->is_stepping(), false, "get_rest_info must not be called while the physics space is being stepped.");

	space->flush_pending_objects();

	JoltShape3D *shape = JoltPhysicsServer3D::get_singleton()->get_shape(p_parameters.shape_rid);
	ERR_FAIL_NULL_V(shape, false);

	const JPH::ShapeRefC jolt_shape = shape->try_build();
	ERR_FAIL_NULL_V(jolt_shape, false);

	Transform3D transform = p_parameters.transform;
	JOLT_ENSURE_SCALE_NOT_ZERO(transform, "get_rest_info (maybe from ShapeCast3D?) was passed an invalid transform.");

	Vector3 scale;
	JoltMath::decompose(transform, scale);
	JOLT_ENSURE_SCALE_VALID(jolt_shape, scale, "get_rest_info (maybe from ShapeCast3D?) was passed an invalid transform.");

	const Vector3 com_scaled = to_godot(jolt_shape->GetCenterOfMass());
	const Transform3D transform_com = transform.translated_local(com_scaled);

	JPH::CollideShapeSettings settings;
	settings.mMaxSeparationDistance = (float)p_parameters.margin;

	const Vector3 &base_offset = transform_com.origin;

	const JoltQueryFilter3D query_filter(*this, p_parameters.collision_mask, p_parameters.collide_with_bodies, p_parameters.collide_with_areas, p_parameters.exclude);
	JoltQueryCollectorClosest<JPH::CollideShapeCollector> collector;
	_collide_shape_queries(jolt_shape, to_jolt(scale), to_jolt_r(transform_com), settings, to_jolt_r(base_offset), collector, query_filter, query_filter, query_filter);

	if (!collector.had_hit()) {
		return false;
	}

	const JPH::CollideShapeResult &hit = collector.get_hit();
	const JoltObject3D *object = space->try_get_object(hit.mBodyID2);
	ERR_FAIL_NULL_V(object, false);

	r_info->shape = 0;

	if (const JoltShapedObject3D *shaped_object = object->as_shaped()) {
		const int shape_index = shaped_object->find_shape_index(hit.mSubShapeID2);
		ERR_FAIL_COND_V(shape_index == -1, false);
		r_info->shape = shape_index;
	}

	const Vector3 hit_point = base_offset + to_godot(hit.mContactPointOn2);

	r_info->point = hit_point;
	r_info->normal = to_godot(-hit.mPenetrationAxis.Normalized());
	r_info->rid = object->get_rid();
	r_info->collider_id = object->get_instance_id();
	r_info->linear_velocity = object->get_velocity_at_position(hit_point);

	return true;
}

Vector3 JoltPhysicsDirectSpaceState3D::get_closest_point_to_object_volume(RID p_object, Vector3 p_point) const {
	ERR_FAIL_COND_V_MSG(space->is_stepping(), Vector3(), "get_closest_point_to_object_volume must not be called while the physics space is being stepped.");

	space->flush_pending_objects();

	JoltPhysicsServer3D *physics_server = JoltPhysicsServer3D::get_singleton();
	JoltObject3D *object = physics_server->get_area(p_object);

	if (object == nullptr) {
		object = physics_server->get_body(p_object);
	}

	ERR_FAIL_NULL_V(object, Vector3());
	ERR_FAIL_COND_V(object->get_space() != space, Vector3());

	JoltQueryCollectorAll<JPH::TransformedShapeCollector, 32> collector;
	const JPH::TransformedShape root_shape = object->get_jolt_body()->GetTransformedShape();
	root_shape.CollectTransformedShapes(object->get_jolt_body()->GetWorldSpaceBounds(), collector);

	const JPH::RVec3 point = to_jolt_r(p_point);

	float closest_distance_sq = FLT_MAX;
	JPH::RVec3 closest_point = JPH::RVec3::sZero();

	bool found_point = false;

	for (int i = 0; i < collector.get_hit_count(); ++i) {
		const JPH::TransformedShape &shape_transformed = collector.get_hit(i);
		const JPH::Shape &shape = *shape_transformed.mShape;

		if (shape.GetType() != JPH::EShapeType::Convex) {
			continue;
		}

		const JPH::ConvexShape &shape_convex = static_cast<const JPH::ConvexShape &>(shape);

		JPH::GJKClosestPoint gjk;

		JPH::ConvexShape::SupportBuffer shape_support_buffer;
		const JPH::ConvexShape::Support *shape_support = shape_convex.GetSupportFunction(JPH::ConvexShape::ESupportMode::IncludeConvexRadius, shape_support_buffer, shape_transformed.GetShapeScale());

		const JPH::RMat44 shape_rotation = JPH::RMat44::sRotation(shape_transformed.mShapeRotation);
		const JPH::Vec3 shape_com = shape_rotation.Multiply3x3(shape.GetCenterOfMass());
		const JPH::RVec3 shape_pos = shape_transformed.mShapePositionCOM - JPH::RVec3(shape_com);
		const JPH::RMat44 shape_xform = shape_rotation.PostTranslated(shape_pos);
		const JPH::RMat44 shape_xform_inv = shape_xform.InversedRotationTranslation();

		JPH::PointConvexSupport point_support;
		point_support.mPoint = JPH::Vec3(shape_xform_inv * point);

		JPH::Vec3 separating_axis = JPH::Vec3::sAxisX();
		JPH::Vec3 point_on_a = JPH::Vec3::sZero();
		JPH::Vec3 point_on_b = JPH::Vec3::sZero();

		const float distance_sq = gjk.GetClosestPoints(*shape_support, point_support, JPH::cDefaultCollisionTolerance, FLT_MAX, separating_axis, point_on_a, point_on_b);

		if (distance_sq == 0.0f) {
			closest_point = point;
			found_point = true;
			break;
		}

		if (distance_sq < closest_distance_sq) {
			closest_distance_sq = distance_sq;
			closest_point = shape_xform * point_on_a;
			found_point = true;
		}
	}

	if (found_point) {
		return to_godot(closest_point);
	} else {
		return to_godot(object->get_jolt_body()->GetPosition());
	}
}

bool JoltPhysicsDirectSpaceState3D::body_test_motion(const JoltBody3D &p_body, const PhysicsServer3D::MotionParameters &p_parameters, PhysicsServer3D::MotionResult *r_result) const {
	ERR_FAIL_COND_V_MSG(space->is_stepping(), false, "body_test_motion (maybe from move_and_slide?) must not be called while the physics space is being stepped.");

	if (!p_body.in_space()) {
		return false;
	}

	space->flush_pending_objects();

	const float margin = MAX((float)p_parameters.margin, 0.0001f);
	const int max_collisions = MIN(p_parameters.max_collisions, 32);

	Transform3D transform = p_parameters.from;
	JOLT_ENSURE_SCALE_NOT_ZERO(transform, vformat("body_test_motion (maybe from move_and_slide?) was passed an invalid transform along with body '%s'.", p_body.to_string()));

	Vector3 scale;
	JoltMath::decompose(transform, scale);

	Vector3 recovery;
	const bool recovered = _body_motion_recover(p_body, transform, margin, p_parameters.exclude_bodies, p_parameters.exclude_objects, recovery);

	transform.origin += recovery;

	real_t safe_fraction = 1.0;
	real_t unsafe_fraction = 1.0;

	const bool hit = _body_motion_cast(p_body, transform, scale, p_parameters.motion, p_parameters.collide_separation_ray, p_parameters.exclude_bodies, p_parameters.exclude_objects, safe_fraction, unsafe_fraction);

	bool collided = false;

	if (hit || (recovered && p_parameters.recovery_as_collision)) {
		collided = _body_motion_collide(p_body, transform.translated(p_parameters.motion * unsafe_fraction), p_parameters.motion, margin, max_collisions, p_parameters.exclude_bodies, p_parameters.exclude_objects, r_result);
	}

	if (r_result == nullptr) {
		return collided;
	}

	if (collided) {
		const PhysicsServer3D::MotionCollision &deepest = r_result->collisions[0];

		r_result->travel = recovery + p_parameters.motion * safe_fraction;
		r_result->remainder = p_parameters.motion - p_parameters.motion * safe_fraction;
		r_result->collision_depth = deepest.depth;
		r_result->collision_safe_fraction = safe_fraction;
		r_result->collision_unsafe_fraction = unsafe_fraction;
	} else {
		r_result->travel = recovery + p_parameters.motion;
		r_result->remainder = Vector3();
		r_result->collision_depth = 0.0f;
		r_result->collision_safe_fraction = 1.0f;
		r_result->collision_unsafe_fraction = 1.0f;
		r_result->collision_count = 0;
	}

	return collided;
}
