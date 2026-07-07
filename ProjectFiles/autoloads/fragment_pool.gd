extends Node3D

## Pool of single-block fragment entities — full game-world objects (bullets
## hit them, they have HP, server-authoritative physics) but with no Godot
## node per instance. Saves 50–80us of per-spawn node allocation × hundreds
## of fragments per detach event.
##
## Architecture
## ------------
## Each fragment is:
##   - One PhysicsServer3D body RID (created lazily, recycled).
##     Server: BODY_MODE_RIGID — runs physics, gravity, impulses.
##     Client: BODY_MODE_KINEMATIC — transform set by server sync, no sim.
##   - One slot in a shared MultiMesh (one draw call for all fragments).
##   - Slot index in flat arrays for HP, attacker, alive flag, color.
##
## Routing
## -------
##   - Bullets (raycast hits): result["rid"] → _rid_to_slot lookup → damage()
##     player_combat.gd checks FragmentPool when collider is null.
##   - Explosions: apply_radial_impulse() (server only) loops slots, applies
##     PhysicsServer3D.body_apply_central_impulse on each in-radius body.
##   - Sync: server's _physics_process collects moving (non-sleeping) slot
##     transforms and broadcasts via _sync_fragment_transforms RPC.
##
## Damage / death
## --------------
##   - HP starts at the original block_hp. Damage decrements, on <=0 the slot
##     is released and a small debris burst spawns at its last position.
##   - Indestructible-by-impulse — explosion impulse pushes but doesn't damage.
##     (Bond damage doesn't apply: a single block has no bonds to break.)

const INITIAL_SIZE := 0      ## No pre-warm. The C++ bulk kernel creates bodies
                              ## at ~1us/body, so a 1000-fragment apocalyptic
                              ## event spawns in ~1ms via lazy growth. Pre-warming
                              ## 5000 bodies bloated Jolt's broadphase BVH (all
                              ## bodies stacked at one parking position) and hurt
                              ## physics-query performance for the entire scene.
const GROW_CHUNK := 256      ## On-demand grow chunk size. Small enough to keep
                              ## the broadphase tree balanced if growth happens
                              ## incrementally.
const FRAGMENT_MASS := 5.0
const MAX_IMPULSE_VELOCITY := 250.0  ## Mirrors ExplosionHelper

# ── Per-slot state (parallel arrays, sized to current pool size) ────────────
var _body_rids: Array = []           ## PhysicsServer3D body RIDs
var _slot_alive: PackedByteArray = PackedByteArray()
var _slot_hp: PackedFloat32Array = PackedFloat32Array()
var _slot_attacker: PackedInt32Array = PackedInt32Array()
var _free_indices: Array[int] = []
var _rid_to_slot: Dictionary = {}    ## RID → slot index for hit routing

# ── Shared resources ─────────────────────────────────────────────────────────
var _shared_shape_rid: RID
var _shared_shape: BoxShape3D
var _multimesh: MultiMesh
var _multimesh_instance: MultiMeshInstance3D

# ── World rids (resolved lazily after first scene mounts) ───────────────────
var _space_rid: RID
var _scenario_rid: RID

# ── Render / sync ────────────────────────────────────────────────────────────
var _live_count: int = 0
const SYNC_TICK_INTERVAL := 2  ## Server→client transform RPC every N physics ticks
var _ticks_since_sync := 0

## One-shot warning gate: log the first acquire failure loudly so silent
## fragment-drop is visible. Subsequent failures are silent to avoid spam.
var _acquire_failure_logged: bool = false

## Active layer/mask applied to a fragment body on acquire(), zeroed on
## release(). Set in _grow() from the same constants the C++ kernel used
## to use, so we keep parked bodies out of the broadphase.
var _active_layer: int = 0
var _active_mask: int = 0


func _ready() -> void:
	# Shared collision shape — one box per fragment, all fragments share it.
	var shape := BoxShape3D.new()
	shape.size = Vector3.ONE * BlockGridManager.BLOCK_SIZE
	_shared_shape = shape
	_shared_shape_rid = shape.get_rid()

	# Shared visual mesh — single cube. Per-instance color via MultiMesh,
	# which only takes effect when the material reads vertex color as albedo.
	# Without this flag every fragment renders with the same default albedo
	# regardless of set_instance_color().
	var mesh := BoxMesh.new()
	mesh.size = Vector3.ONE * BlockGridManager.BLOCK_SIZE
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.albedo_color = Color.WHITE  # white base, instance color modulates it

	_multimesh = MultiMesh.new()
	_multimesh.transform_format = MultiMesh.TRANSFORM_3D
	_multimesh.use_colors = true
	_multimesh.mesh = mesh
	_multimesh.instance_count = 0
	_multimesh.visible_instance_count = 0

	_multimesh_instance = MultiMeshInstance3D.new()
	_multimesh_instance.name = "FragmentMultiMesh"
	_multimesh_instance.multimesh = _multimesh
	_multimesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# Material on the instance node guarantees the MultiMesh draw-path uses it
	# (PrimitiveMesh.material can be ignored by some renderers when used with
	# MultiMesh).
	_multimesh_instance.material_override = mat
	add_child(_multimesh_instance)

	# No pre-warm. Pool grows on demand via ensure_capacity()/acquire(). See
	# INITIAL_SIZE comment above.


func _ensure_world_rids() -> bool:
	## Resolve World3D's RIDs once a scene is mounted. Autoloads can't rely
	## on get_world_3d() at _ready time.
	if _space_rid.is_valid():
		return true
	var vp := get_viewport()
	if vp == null:
		return false
	var w3d := vp.find_world_3d()
	if w3d == null:
		return false
	_space_rid = w3d.space
	_scenario_rid = w3d.scenario
	return _space_rid.is_valid()


func _grow(count: int) -> void:
	## Allocate `count` fresh bodies. Server: RIGID (full physics).
	## Client: KINEMATIC (transform set by server sync, no local sim).
	## Body creation runs entirely in C++ via bulk_create_fragment_bodies —
	## one binding crossing instead of ~10 per body.
	if not _ensure_world_rids():
		return
	var old_size := _body_rids.size()
	var new_size := old_size + count

	_slot_alive.resize(new_size)
	_slot_hp.resize(new_size)
	_slot_attacker.resize(new_size)
	_body_rids.resize(new_size)
	_multimesh.instance_count = new_size

	var is_server := multiplayer.is_server()
	# WALL_BLOCKS: bullet & projectile raycasts find fragments (PROJECTILE_PHYSICS
	# now includes WALL_BLOCKS, so rockets detonate via forward raycast).
	# ITEMS: explosion sphere queries find them (FragmentPool also has its
	# own apply_radial_impulse, so this is a belt-and-suspenders.)
	# Deliberately NOT WALL_SMOOTH: hundreds of small fragments on the
	# player-physics layer caused the player to slide on debris piles, and
	# raw bodies can't fire body_entered (rockets bounced without detonating).
	var fragment_layer := CollisionLayers.WALL_BLOCKS | CollisionLayers.ITEMS
	var fragment_mask := CollisionLayers.DEFAULT_PHYSICS | CollisionLayers.DEBRIS
	# Cache for acquire/release: parked bodies have layer/mask = 0 so they
	# don't generate broadphase pairs. acquire() promotes back to these.
	_active_layer = fragment_layer
	_active_mask = fragment_mask
	var grav: float = 2.25 if is_server else 0.0

	# Runtime dispatch (rather than direct call) so a stale engine binary
	# without bulk_create_fragment_bodies doesn't cascade into a full project
	# compile failure. If the kernel is missing, fragments simply don't spawn.
	var bm: Object = BlockMeshBuilder
	if not bm.has_method("bulk_create_fragment_bodies"):
		push_warning("[FragmentPool] Engine binary is missing bulk_create_fragment_bodies kernel — rebuild required. Skipping pool growth.")
		# Trim back the resizes so the pool stays consistent.
		_slot_alive.resize(old_size)
		_slot_hp.resize(old_size)
		_slot_attacker.resize(old_size)
		_body_rids.resize(old_size)
		_multimesh.instance_count = old_size
		return
	var new_rids: Array = bm.call("bulk_create_fragment_bodies",
		count, _space_rid, _shared_shape_rid,
		fragment_layer, fragment_mask, FRAGMENT_MASS, grav, not is_server)

	var hidden_xform := Transform3D(Basis(), Vector3(0, -100000, 0))
	for i in count:
		var slot: int = old_size + i
		_body_rids[slot] = new_rids[i]
		_slot_alive[slot] = 0
		_free_indices.append(slot)
		_multimesh.set_instance_transform(slot, hidden_xform)
		_multimesh.set_instance_color(slot, Color.WHITE)


func ensure_capacity(needed: int) -> void:
	## Caller knows it's about to spawn `needed` fragments; grow the pool
	## NOW so the per-spawn loop doesn't trigger a mid-loop grow. Useful for
	## big detach events (a 2000-block tower toppling, etc.) where the count
	## is known up front.
	var deficit := needed - _free_indices.size()
	if deficit > 0:
		_grow(deficit)


func acquire(world_pos: Vector3, velocity: Vector3, color: Color,
		hp: float, attacker_id: int) -> int:
	## Reserve a slot, place the body, register RID for hit routing.
	## Returns slot index or -1 if pool failed to grow (no world yet).
	if _free_indices.is_empty():
		_grow(GROW_CHUNK)
	if _free_indices.is_empty():
		# Silent failure here is what causes "blocks disappear instead of
		# spawning fragments" — call sites already erased the source block
		# from the structure, so a -1 return drops the fragment on the floor.
		# Log loudly the FIRST time so the cause is visible.
		if not _acquire_failure_logged:
			_acquire_failure_logged = true
			push_warning("[FragmentPool] acquire failed — pool empty and _grow couldn't allocate. " +
				"world_rids_valid=%s body_rids_size=%d. Check that FragmentPool's _ensure_world_rids() succeeded; " +
				"if the World3D wasn't ready at autoload _ready, the _physics_process retry should have warmed it." % [
				str(_space_rid.is_valid()), _body_rids.size()])
		return -1
	var slot: int = _free_indices.pop_back()
	_slot_alive[slot] = 1
	_slot_hp[slot] = hp
	_slot_attacker[slot] = attacker_id
	_live_count += 1

	var body: RID = _body_rids[slot]
	_rid_to_slot[body] = slot
	var ps := PhysicsServer3D
	var xform := Transform3D(Basis(), world_pos)
	ps.body_set_state(body, PhysicsServer3D.BODY_STATE_TRANSFORM, xform)
	ps.body_set_state(body, PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY, velocity)
	ps.body_set_state(body, PhysicsServer3D.BODY_STATE_ANGULAR_VELOCITY, Vector3.ZERO)
	ps.body_set_state(body, PhysicsServer3D.BODY_STATE_SLEEPING, false)
	# Promote the body into the broadphase: bulk_create_fragment_bodies parks
	# bodies with layer/mask = 0 so 5000 stacked fragments don't blow Jolt's
	# body-pair cache. We set the real values here on acquisition.
	ps.body_set_collision_layer(body, _active_layer)
	ps.body_set_collision_mask(body, _active_mask)

	_multimesh.set_instance_transform(slot, xform)
	_multimesh.set_instance_color(slot, color)
	if slot + 1 > _multimesh.visible_instance_count:
		_multimesh.visible_instance_count = slot + 1
	return slot


func release(slot: int) -> void:
	if slot < 0 or slot >= _slot_alive.size() or _slot_alive[slot] == 0:
		return
	_slot_alive[slot] = 0
	_live_count -= 1
	var body: RID = _body_rids[slot]
	_rid_to_slot.erase(body)
	var ps := PhysicsServer3D
	var hidden_xform := Transform3D(Basis(), Vector3(0, -100000, 0))
	ps.body_set_state(body, PhysicsServer3D.BODY_STATE_TRANSFORM, hidden_xform)
	ps.body_set_state(body, PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY, Vector3.ZERO)
	ps.body_set_state(body, PhysicsServer3D.BODY_STATE_SLEEPING, true)
	# Demote the body out of the broadphase to free up body-pair slots while
	# parked. Re-promoted on next acquire().
	ps.body_set_collision_layer(body, 0)
	ps.body_set_collision_mask(body, 0)
	_multimesh.set_instance_transform(slot, hidden_xform)
	_free_indices.append(slot)


# ── Hit routing ──────────────────────────────────────────────────────────────

func slot_for_rid(rid: RID) -> int:
	## Look up the slot index owning `rid`. Returns -1 if not a fragment body.
	## Used by player_combat to detect bullets hitting raw-body fragments.
	return _rid_to_slot.get(rid, -1)


func damage_fragment(slot: int, amount: float, attacker_id: int) -> void:
	## Server-only. Apply HP damage; release the slot (and sync to clients) on death.
	if not multiplayer.is_server():
		return
	if slot < 0 or slot >= _slot_alive.size() or _slot_alive[slot] == 0:
		return
	_slot_hp[slot] -= amount
	if _slot_hp[slot] <= 0.0:
		_slot_attacker[slot] = attacker_id
		_sync_fragment_kill.rpc(slot)
		# call_local handles the local release inside the RPC.


@rpc("authority", "call_local", "reliable")
func _sync_fragment_kill(slot: int) -> void:
	## All peers: the fragment at `slot` is dead. Release the slot. Optional
	## debris/sound spawn could go here.
	release(slot)


# ── Server → client transform sync ──────────────────────────────────────────

func _physics_process(_delta: float) -> void:
	if _live_count == 0:
		return
	# Always update local visuals from physics (server sims; client follows
	# server-authored kinematic transforms set by _sync_fragment_transforms).
	_sync_visuals_from_physics()
	# Server: periodically broadcast active transforms to clients.
	if multiplayer.is_server():
		_ticks_since_sync += 1
		if _ticks_since_sync >= SYNC_TICK_INTERVAL:
			_ticks_since_sync = 0
			_broadcast_transforms()


func _sync_visuals_from_physics() -> void:
	## Push the current physics body transform into the corresponding multimesh
	## slot so the visual cube tracks the body. Skips sleeping bodies.
	var ps := PhysicsServer3D
	var n: int = _multimesh.visible_instance_count
	for i in n:
		if _slot_alive[i] == 0:
			continue
		var body: RID = _body_rids[i]
		if ps.body_get_state(body, PhysicsServer3D.BODY_STATE_SLEEPING):
			continue
		var xform: Transform3D = ps.body_get_state(body, PhysicsServer3D.BODY_STATE_TRANSFORM)
		_multimesh.set_instance_transform(i, xform)


func _broadcast_transforms() -> void:
	## Server: pack the transforms of moving (non-sleeping) fragments into a
	## single RPC for all clients. Sleeping fragments don't move so we don't
	## sync them (clients see the last sync'd position, which is correct).
	if multiplayer.get_peers().is_empty():
		return
	var ps := PhysicsServer3D
	var slots := PackedInt32Array()
	var origins := PackedVector3Array()
	var quats := PackedFloat32Array()  # x,y,z,w per slot
	var n: int = _multimesh.visible_instance_count
	for i in n:
		if _slot_alive[i] == 0:
			continue
		var body: RID = _body_rids[i]
		if ps.body_get_state(body, PhysicsServer3D.BODY_STATE_SLEEPING):
			continue
		var xform: Transform3D = ps.body_get_state(body, PhysicsServer3D.BODY_STATE_TRANSFORM)
		slots.append(i)
		origins.append(xform.origin)
		var q := xform.basis.get_rotation_quaternion()
		quats.append(q.x); quats.append(q.y); quats.append(q.z); quats.append(q.w)
	if slots.is_empty():
		return
	_sync_fragment_transforms.rpc(slots, origins, quats)


@rpc("authority", "call_remote", "unreliable_ordered")
func _sync_fragment_transforms(slots: PackedInt32Array,
		origins: PackedVector3Array, quats: PackedFloat32Array) -> void:
	## Clients: apply server's transform updates to local kinematic bodies.
	## call_remote because the server already has the authoritative state.
	var ps := PhysicsServer3D
	var n: int = slots.size()
	for k in n:
		var slot: int = slots[k]
		if slot < 0 or slot >= _slot_alive.size() or _slot_alive[slot] == 0:
			continue
		var origin := origins[k]
		var qi: int = k * 4
		var q := Quaternion(quats[qi], quats[qi + 1], quats[qi + 2], quats[qi + 3])
		var xform := Transform3D(Basis(q), origin)
		var body: RID = _body_rids[slot]
		ps.body_set_state(body, PhysicsServer3D.BODY_STATE_TRANSFORM, xform)


# ── Explosion impulse ────────────────────────────────────────────────────────

func apply_radial_impulse(blast_pos: Vector3, radius: float, impulse_strength: float) -> int:
	## Server-only. Push every live fragment within `radius` outward.
	## Server's physics handles the resulting motion; clients see the change
	## via the next _broadcast_transforms call.
	if not multiplayer.is_server():
		return 0
	if _live_count == 0 or impulse_strength <= 0.0 or radius <= 0.0:
		return 0
	var ps := PhysicsServer3D
	var n: int = _multimesh.visible_instance_count
	var inv_radius := 1.0 / radius
	var max_mag: float = MAX_IMPULSE_VELOCITY * FRAGMENT_MASS
	var impulse_count := 0
	for i in n:
		if _slot_alive[i] == 0:
			continue
		var body: RID = _body_rids[i]
		var xform: Transform3D = ps.body_get_state(body, PhysicsServer3D.BODY_STATE_TRANSFORM)
		var pos: Vector3 = xform.origin
		var dist: float = blast_pos.distance_to(pos)
		if dist > radius:
			continue
		var norm_d: float = dist * inv_radius
		var falloff: float = 1.0 / (1.0 + (norm_d * 3.0) ** 3)
		var dir: Vector3 = pos - blast_pos
		if dir.length_squared() < 0.01:
			dir = Vector3.UP
		else:
			dir = dir.normalized()
			dir.y = maxf(dir.y, 0.3)
			dir = dir.normalized()
		var mag: float = minf(impulse_strength * falloff, max_mag)
		ps.body_set_state(body, PhysicsServer3D.BODY_STATE_SLEEPING, false)
		ps.body_apply_central_impulse(body, dir * mag)
		impulse_count += 1
	return impulse_count


func get_stats() -> Dictionary:
	return {
		"pool_size": _body_rids.size(),
		"live": _live_count,
		"free": _free_indices.size(),
	}
