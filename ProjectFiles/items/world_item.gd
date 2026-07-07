extends Area3D
class_name WorldItem

## An item lying on the ground that players can pick up.
## Server-authoritative: server manages pickup and burn timers.

@export var item_data: ItemData = null

var burn_time_remaining: float = 0.0
var _setup_called := false

## Pickup immunity: the peer_id that just dropped this item can't pick it up
## until the timer expires. Prevents drop-pickup loops.
var _immune_peer_id: int = -1
var _immune_timer: float = 0.0
const PICKUP_IMMUNITY_TIME := 2.0

## Deferred ground check: runs once on the first physics frame instead of
## call_deferred from _ready(), which is unsafe with threaded physics.
var _needs_ground_check: bool = false

const SCRAP_POPUP_RANGE := 4.0
const SCRAP_FUEL_BY_RARITY := [10.0, 30.0, 65.0, 130.0, 250.0]

## Rarity colors for world item boxes
const RARITY_COLORS := {
	ItemData.Rarity.COMMON: Color(0.6, 0.6, 0.6, 1),
	ItemData.Rarity.UNCOMMON: Color(0.2, 0.8, 0.2, 1),
	ItemData.Rarity.RARE: Color(0.3, 0.5, 1.0, 1),
	ItemData.Rarity.EPIC: Color(0.7, 0.3, 0.9, 1),
	ItemData.Rarity.LEGENDARY: Color(1.0, 0.7, 0.1, 1),
}

const PICKUP_POPUP_RANGE := 4.0

## Rarity label stacking constants
const STACK_VISIBLE_RANGE := 30.0   ## Max distance to include in stacking computation
const BASE_LABEL_Y := 1.0           ## Default rarity label Y offset
const LABEL_RELAX_ITERS := 4        ## Constraint passes per frame
const LABEL_ANCHOR_PULL := 0.3      ## Fraction of offset pulled back toward anchor per iter
const LABEL_LERP_SPEED := 15.0      ## Lerp speed toward target offset
const MAX_DISPLACEMENT_PX := 200.0  ## Max screen-pixel drift before clamping

@onready var mesh: MeshInstance3D = $MeshInstance3D
@onready var label: Label3D = $Label3D

## Proximity popup components (created in _ready, handle cached player + distance)
var _scrap_proximity: ProximityLabel = null
var _pickup_proximity: ProximityLabel = null

## Rarity label stacking — static frame cache (computed once per frame)
static var _stack_frame: int = -1

## Per-instance label offset state for smooth movement
var _label_offset_px := Vector2.ZERO  ## Current screen-space offset in pixels (lerped)



func _ready() -> void:
	# Only set burn_time if setup() wasn't already called (e.g. editor-placed items).
	# For spawner-created items, setup() runs before _ready() and the spawn function
	# may set a custom burn_time (like 999999 for permanent items) that we must preserve.
	if item_data and not _setup_called:
		burn_time_remaining = item_data.initial_burn_time
	if item_data:
		_update_visual()

	body_entered.connect(_on_body_entered)

	if multiplayer.is_server():
		_needs_ground_check = true

	_setup_proximity_labels()


func setup(data: ItemData) -> void:
	item_data = data
	burn_time_remaining = data.initial_burn_time
	_setup_called = true
	if is_inside_tree():
		_update_visual()


func set_pickup_immunity(peer_id: int) -> void:
	_immune_peer_id = peer_id
	_immune_timer = PICKUP_IMMUNITY_TIME


const PERMANENT_THRESHOLD := 999990.0  ## Items with burn_time >= this never expire

const RARITY_NAMES := ["Common", "Uncommon", "Rare", "Epic", "Legendary"]

func _process(delta: float) -> void:
	# Update floating label with rarity prefix
	if label and item_data:
		var rarity_tag: String = RARITY_NAMES[clampi(item_data.rarity, 0, 4)]
		if burn_time_remaining >= PERMANENT_THRESHOLD:
			label.text = "[%s] %s" % [rarity_tag, item_data.item_name]
		else:
			label.text = "[%s] %s [%ds]" % [rarity_tag, item_data.item_name, ceili(burn_time_remaining)]
		label.modulate = RARITY_COLORS.get(item_data.rarity, Color.WHITE)

	# Server: burn timer + immunity
	if multiplayer.is_server():
		if item_data and burn_time_remaining < PERMANENT_THRESHOLD:
			burn_time_remaining -= item_data.base_burn_rate * delta
			if burn_time_remaining <= 0.0:
				queue_free()
				return

		if _immune_timer > 0.0:
			_immune_timer -= delta
			if _immune_timer <= 0.0:
				_immune_peer_id = -1

	# Client: disable proximity popups for fuel items (auto-picked up)
	var is_fuel := item_data != null and item_data.item_type == ItemData.ItemType.FUEL
	var should_show := item_data != null and not is_fuel
	if _scrap_proximity:
		_scrap_proximity.set_process(should_show)
		if not should_show and _scrap_proximity.label:
			_scrap_proximity._hide_label()
	if _pickup_proximity:
		_pickup_proximity.set_process(should_show)
		if not should_show and _pickup_proximity.label:
			_pickup_proximity._hide_label()

	# Rarity label stacking (runs once per frame via static cache, any rendering peer)
	if label:
		_try_compute_rarity_stacking()


func _physics_process(_delta: float) -> void:
	if _needs_ground_check:
		_needs_ground_check = false
		_ensure_above_ground()


func _update_visual() -> void:
	if mesh == null or item_data == null:
		return
	var mat := StandardMaterial3D.new()
	# Box color is determined exclusively by rarity
	mat.albedo_color = RARITY_COLORS.get(item_data.rarity, Color.WHITE)
	if item_data.rarity >= ItemData.Rarity.RARE:
		mat.emission_enabled = true
		mat.emission = mat.albedo_color
		mat.emission_energy_multiplier = 0.5 + item_data.rarity * 0.4  # Rare=1.3, Epic=1.7, Legendary=2.1
	mesh.material_override = mat


func is_immune_to(peer_id: int) -> bool:
	return _immune_peer_id == peer_id and _immune_timer > 0.0


func _on_body_entered(body: Node3D) -> void:
	if not multiplayer.is_server():
		return
	if body is Player and body.has_method("_on_item_pickup"):
		if body.get("peer_id") is int:
			if is_immune_to(body.peer_id):
				return
		# Only auto-pickup fuel items — everything else requires pressing E
		if item_data and item_data.item_type == ItemData.ItemType.FUEL:
			body._on_item_pickup(self)


# ======================================================================
#  Proximity popups (client-side, via ProximityLabel components)
# ======================================================================

func get_interact_distance(player_pos: Vector3) -> float:
	## Unified interactable interface — returns distance to player, or INF if not
	## interactable (fuel items don't compete for the [E] prompt).
	if item_data == null or item_data.item_type == ItemData.ItemType.FUEL:
		return INF
	var d: float = global_position.distance_to(player_pos)
	if d < PICKUP_POPUP_RANGE:
		return d
	return INF


func _setup_proximity_labels() -> void:
	# Pickup label — create/destroy style, green text, static "[E] PICKUP" (top)
	_pickup_proximity = ProximityLabel.new()
	_pickup_proximity.popup_range = PICKUP_POPUP_RANGE
	_pickup_proximity.label_offset = Vector3(0, 1.5, 0)
	_pickup_proximity.label_color = Color(0.3, 1.0, 0.4)
	_pickup_proximity.use_visibility_toggle = false
	_pickup_proximity.update_callback = _on_pickup_label_update
	_pickup_proximity.interactable_group = "interact"
	add_child(_pickup_proximity)

	# Scrap label — create/destroy style, orange text, updates fuel value each frame (bottom)
	_scrap_proximity = ProximityLabel.new()
	_scrap_proximity.popup_range = SCRAP_POPUP_RANGE
	_scrap_proximity.label_offset = Vector3(0, 1.2, 0)
	_scrap_proximity.label_color = Color(1.0, 0.6, 0.2)
	_scrap_proximity.use_visibility_toggle = false
	_scrap_proximity.update_callback = _on_scrap_label_update
	_scrap_proximity.interactable_group = "interact"
	add_child(_scrap_proximity)


func _on_scrap_label_update(lbl: Label3D, _player: Node, _dist: float) -> void:
	## Called every frame the scrap label is visible — keep fuel value accurate.
	var max_fuel: float = SCRAP_FUEL_BY_RARITY[clampi(item_data.rarity, 0, 4)]
	var initial_time: float = maxf(item_data.initial_burn_time, 0.1)
	var time_fraction: float = clampf(burn_time_remaining / initial_time, 0.0, 1.0)
	var fuel: float = max_fuel * time_fraction
	lbl.text = "[X] SCRAP  +%.0f fuel" % fuel


func _on_pickup_label_update(lbl: Label3D, _player: Node, _dist: float) -> void:
	## Called every frame the pickup label is visible — static text.
	lbl.text = "[E] PICKUP"


# ======================================================================
#  Rarity label stacking (client-side, screen-space overlap prevention)
# ======================================================================

func _try_compute_rarity_stacking() -> void:
	## Called from each WorldItem's _process(). Static frame cache ensures
	## the expensive computation only runs once per engine frame.
	## Uses force-directed placement: spring toward anchor + repulsion from neighbors.
	var frame := Engine.get_process_frames()
	if frame == _stack_frame:
		return
	_stack_frame = frame

	# Find local player + camera
	var local_player: Node = null
	if _pickup_proximity:
		local_player = _pickup_proximity.get_local_player()
	if _scrap_proximity and local_player == null:
		local_player = _scrap_proximity.get_local_player()
	if local_player == null:
		return
	var camera: Camera3D = local_player.get("camera") as Camera3D
	if camera == null:
		return

	var player_pos: Vector3 = local_player.global_position
	var world_items := get_tree().current_scene.get_node_or_null("WorldItems")
	if world_items == null:
		return

	var vp_size: Vector2 = camera.get_viewport().get_visible_rect().size
	var vp_height: float = vp_size.y
	var half_tan_fov: float = tan(deg_to_rad(camera.fov) * 0.5)
	var cam_right: Vector3 = camera.global_transform.basis.x
	var cam_up: Vector3 = camera.global_transform.basis.y
	var dt: float = get_process_delta_time()

	# Collect visible labels with screen-space info
	var entries: Array[Dictionary] = []
	for child in world_items.get_children():
		if not child is WorldItem:
			continue
		var wi: WorldItem = child as WorldItem
		if wi.label == null or wi.item_data == null:
			continue
		var dist: float = player_pos.distance_to(wi.global_position)
		if dist > STACK_VISIBLE_RANGE:
			wi.label.position = Vector3(0, BASE_LABEL_Y, 0)
			wi._label_offset_px = Vector2.ZERO
			continue
		var world_label_pos: Vector3 = wi.global_position + Vector3(0, BASE_LABEL_Y, 0)
		if camera.is_position_behind(world_label_pos):
			wi.label.position = Vector3(0, BASE_LABEL_Y, 0)
			wi._label_offset_px = Vector2.ZERO
			continue
		var screen_anchor: Vector2 = camera.unproject_position(world_label_pos)

		# Measure screen-space label size
		var depth: float = maxf(camera.global_position.distance_to(world_label_pos), 0.1)
		var world_per_px: float = 2.0 * depth * half_tan_fov / vp_height
		var f: Font = wi.label.font if wi.label.font else ThemeDB.fallback_font
		var text_size: Vector2 = f.get_string_size(
			wi.label.text, HORIZONTAL_ALIGNMENT_CENTER, -1, wi.label.font_size
		)
		var outline_extra: float = wi.label.outline_size * 2.0
		var screen_w: float = (text_size.x + outline_extra) * wi.label.pixel_size / world_per_px
		var screen_h: float = (text_size.y + outline_extra) * wi.label.pixel_size / world_per_px

		entries.append({
			"item": wi,
			"anchor": screen_anchor,
			"half_w": screen_w * 0.5,
			"half_h": screen_h * 0.5,
			"depth": depth,
			"world_per_px": world_per_px,
		})

	if entries.is_empty():
		return

	# Iterative constraint relaxation: resolve overlaps then pull toward anchor
	# Work with target offsets, then lerp current offset toward them
	var target_offsets: Array[Vector2] = []
	target_offsets.resize(entries.size())
	for i in entries.size():
		target_offsets[i] = (entries[i]["item"] as WorldItem)._label_offset_px

	for _iter in LABEL_RELAX_ITERS:
		# Pull each label back toward its anchor (offset=0)
		for i in entries.size():
			target_offsets[i] *= (1.0 - LABEL_ANCHOR_PULL)

		# Push overlapping pairs apart along minimum separation axis
		for i in entries.size():
			var ei: Dictionary = entries[i]
			var ci: Vector2 = ei["anchor"] as Vector2 + target_offsets[i]
			var hw_i: float = ei["half_w"]
			var hh_i: float = ei["half_h"]
			for j in range(i + 1, entries.size()):
				var ej: Dictionary = entries[j]
				var cj: Vector2 = ej["anchor"] as Vector2 + target_offsets[j]
				var hw_j: float = ej["half_w"]
				var hh_j: float = ej["half_h"]
				# Overlap on each axis (with padding)
				var dx: float = absf(ci.x - cj.x)
				var dy: float = absf(ci.y - cj.y)
				var overlap_x: float = (hw_i + hw_j + 4.0) - dx
				var overlap_y: float = (hh_i + hh_j + 4.0) - dy
				if overlap_x <= 0 or overlap_y <= 0:
					continue
				# Push along axis with LEAST overlap (cheapest to resolve)
				var push: Vector2
				if overlap_y <= overlap_x:
					# Vertical push — most common for wide text labels
					var sign_y: float = 1.0 if ci.y >= cj.y else -1.0
					push = Vector2(0, sign_y * overlap_y * 0.5)
				else:
					var sign_x: float = 1.0 if ci.x >= cj.x else -1.0
					push = Vector2(sign_x * overlap_x * 0.5, 0)
				target_offsets[i] += push
				target_offsets[j] -= push
				# Update centers for subsequent pair checks this iteration
				ci += push
				# cj updated implicitly via target_offsets[j]

	# Clamp and lerp current offsets toward targets
	for i in entries.size():
		var wi: WorldItem = entries[i]["item"]
		var target: Vector2 = target_offsets[i]
		if target.length() > MAX_DISPLACEMENT_PX:
			target = target.normalized() * MAX_DISPLACEMENT_PX
		wi._label_offset_px = wi._label_offset_px.lerp(target, clampf(LABEL_LERP_SPEED * dt, 0.0, 1.0))

	# Apply offsets to label world positions
	for entry in entries:
		var wi: WorldItem = entry["item"]
		var offset_px: Vector2 = wi._label_offset_px
		if offset_px.length_squared() < 0.5:
			wi.label.position = Vector3(0, BASE_LABEL_Y, 0)
		else:
			var wpp: float = entry["world_per_px"]
			var world_offset: Vector3 = (cam_right * offset_px.x - cam_up * offset_px.y) * wpp
			wi.label.position = Vector3(0, BASE_LABEL_Y, 0) + world_offset


func _ensure_above_ground() -> void:
	var space_state := get_world_3d().direct_space_state
	if space_state == null:
		return

	var ray_start := global_position + Vector3(0, 5.0, 0)
	var ray_end := global_position - Vector3(0, 10.0, 0)
	var query := PhysicsRayQueryParameters3D.create(ray_start, ray_end)
	query.collision_mask = CollisionLayers.WORLD
	query.collide_with_areas = false

	var result := space_state.intersect_ray(query)
	if not result.is_empty():
		var surface_y: float = result.position.y
		if global_position.y < surface_y + 0.3:
			global_position.y = surface_y + 0.5
