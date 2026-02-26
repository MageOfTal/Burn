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
const STACK_SPACING := 0.35         ## World units between stacked labels
const MAX_STACK := 5                ## Labels per column before wrapping
const WRAP_X_OFFSET := 1.5          ## World units horizontal offset for wrapped column
const SCREEN_OVERLAP_X := 80.0      ## Pixels — labels within this X range are "same column"
const SCREEN_OVERLAP_Y := 40.0      ## Pixels — labels within this Y range overlap
const STACK_VISIBLE_RANGE := 30.0   ## Max distance to include in stacking computation
const BASE_LABEL_Y := 1.0           ## Default rarity label Y offset

@onready var mesh: MeshInstance3D = $MeshInstance3D
@onready var label: Label3D = $Label3D

## Proximity popup components (created in _ready, handle cached player + distance)
var _scrap_proximity: ProximityLabel = null
var _pickup_proximity: ProximityLabel = null

## Rarity label stacking — static frame cache (computed once per frame)
static var _stack_frame: int = -1


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

	# Rarity label stacking (runs once per frame via static cache)
	if not multiplayer.is_server() and label:
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

	# Collect all visible rarity labels with their screen positions
	var entries: Array[Dictionary] = []
	for child in world_items.get_children():
		if not child is WorldItem:
			continue
		var wi: WorldItem = child as WorldItem
		if wi.label == null or wi.item_data == null:
			continue
		var dist: float = player_pos.distance_to(wi.global_position)
		if dist > STACK_VISIBLE_RANGE:
			# Reset far-away labels to default position
			wi.label.position = Vector3(0, BASE_LABEL_Y, 0)
			continue
		var world_label_pos: Vector3 = wi.global_position + Vector3(0, BASE_LABEL_Y, 0)
		if camera.is_position_behind(world_label_pos):
			wi.label.position = Vector3(0, BASE_LABEL_Y, 0)
			continue
		var screen_pos: Vector2 = camera.unproject_position(world_label_pos)
		entries.append({
			"item": wi,
			"screen": screen_pos,
			"dist": dist,
		})

	if entries.is_empty():
		return

	# Cluster labels by screen proximity using greedy grouping
	var clusters: Array[Array] = []
	var assigned: Array[bool] = []
	assigned.resize(entries.size())
	assigned.fill(false)

	for i in entries.size():
		if assigned[i]:
			continue
		var cluster: Array[Dictionary] = [entries[i]]
		assigned[i] = true
		# Find all unassigned entries that overlap with any member of this cluster
		var search_idx := 0
		while search_idx < cluster.size():
			var anchor: Vector2 = cluster[search_idx]["screen"]
			for j in entries.size():
				if assigned[j]:
					continue
				var other: Vector2 = entries[j]["screen"]
				if absf(anchor.x - other.x) < SCREEN_OVERLAP_X and absf(anchor.y - other.y) < SCREEN_OVERLAP_Y:
					cluster.append(entries[j])
					assigned[j] = true
			search_idx += 1
		clusters.append(cluster)

	# For each cluster, sort by distance (closest at bottom) and assign stack offsets
	for cluster in clusters:
		if cluster.size() <= 1:
			# Single item — reset to default
			var wi: WorldItem = cluster[0]["item"]
			wi.label.position = Vector3(0, BASE_LABEL_Y, 0)
			continue

		# Sort: closest items first (bottom of stack)
		cluster.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			return a["dist"] < b["dist"]
		)

		var col := 0  # Current column (0 = first, 1 = wrapped)
		var row := 0  # Row within current column
		for entry in cluster:
			var wi: WorldItem = entry["item"]
			var x_offset: float = col * WRAP_X_OFFSET
			var y_offset: float = BASE_LABEL_Y + row * STACK_SPACING
			wi.label.position = Vector3(x_offset, y_offset, 0)
			row += 1
			if row >= MAX_STACK:
				row = 0
				col += 1


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
