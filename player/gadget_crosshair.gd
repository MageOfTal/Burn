extends Control
class_name GadgetCrosshair

## Grapple aim preview — X crosshair showing where the hook would land.
##
## Two-step aim (matches grapple_system.try_fire()):
##   1. Camera ray finds the world point the white dot crosshair is hitting.
##   2. Hand ray fires from chest height toward that point.
##
## If the hand path is clear, the X overlaps the white dot (both hit the same
## spot).  If terrain blocks the hand, the X separates to show the actual
## impact point.
##
## White X = grapple would connect.  Gray X = target is out of range.
##
## The hand ray extends well past grapple range (500m) so it almost always hits
## terrain.  We then check whether the hit is within 60m for color.  This avoids
## the flickering caused by rays that barely miss at the edge of range.

const X_SIZE := 6.0        ## Half-length of each X arm (pixels)
const X_THICKNESS := 2.0   ## Line width
const X_COLOR_HIT := Color(1.0, 1.0, 1.0, 0.8)    ## White — grapple would connect
const X_COLOR_NO_HIT := Color(0.55, 0.55, 0.55, 0.4)  ## Gray — out of range

## Matches grapple_system.gd constants
const GRAPPLE_RANGE := 60.0
const HAND_HEIGHT := 1.2
const EXTENDED_RAY := 500.0  ## Cast well past range to always hit terrain

var _player: CharacterBody3D = null

## Cached results from _physics_process, consumed by _draw.
var _draw_offset: Vector2 = Vector2.ZERO
var _has_hit: bool = false  ## True = hit is within grapple range (white)
var _has_target: bool = false  ## True = ray hit something at all (show X)
var _should_show: bool = false
var _needs_redraw: bool = false


func setup(player: CharacterBody3D) -> void:
	_player = player
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	visible = false
	set_anchors_preset(Control.PRESET_CENTER)
	pivot_offset = Vector2.ZERO


func _physics_process(_delta: float) -> void:
	## Raycast in physics step where the world state is consistent.
	if _player == null:
		_should_show = false
		return

	_should_show = _is_gadget_equipped()
	if not _should_show:
		return

	_update_grapple_preview()
	_needs_redraw = true


func _process(_delta: float) -> void:
	## Apply cached physics results to visuals.
	if not _should_show or not _has_target:
		visible = false
		return

	visible = true
	if _needs_redraw:
		_needs_redraw = false
		queue_redraw()


func _is_gadget_equipped() -> bool:
	var inventory: Node = _player.get_node_or_null("Inventory")
	if inventory == null:
		return false
	if inventory.equipped_index < 0 or inventory.equipped_index >= inventory.items.size():
		return false
	var equipped: ItemStack = inventory.items[inventory.equipped_index]
	if equipped == null or equipped.item_data == null:
		return false
	return equipped.item_data is GadgetData or equipped.item_data is ConsumableData


func _update_grapple_preview() -> void:
	## Two-step aim (matches grapple_system.try_fire()):
	## 1. Camera ray finds the world point the white dot is hitting.
	## 2. Single long hand ray (500m) fires toward that point.
	## 3. Check hit distance to determine color (white ≤ 60m, gray > 60m).
	##
	## Using one long ray instead of a clamped ray eliminates flickering caused
	## by voxel terrain raycasts being unreliable at the exact range boundary.
	## The hit position within grapple range is identical either way because the
	## ray travels in the same direction — the only difference is what happens
	## when nothing is within 60m, and there we show a gray X at the actual hit.
	var cam: Camera3D = _player.camera
	if cam == null or not cam.is_inside_tree():
		_draw_offset = Vector2.ZERO
		_has_hit = false
		_has_target = false
		return

	var hand_origin: Vector3 = _player.global_position + Vector3(0, HAND_HEIGHT, 0)
	var cam_origin: Vector3 = cam.global_position
	var cam_forward: Vector3 = -cam.global_transform.basis.z

	var space_state := _player.get_world_3d().direct_space_state

	# Step 1: Where is the camera (white dot) looking?
	var cam_far := cam_origin + cam_forward * 1000.0
	var cam_query := PhysicsRayQueryParameters3D.create(cam_origin, cam_far)
	cam_query.exclude = [_player.get_rid()]
	cam_query.collision_mask = 1
	var cam_result := space_state.intersect_ray(cam_query)

	var aim_target: Vector3
	if not cam_result.is_empty():
		aim_target = cam_result.position
	else:
		aim_target = hand_origin + cam_forward * GRAPPLE_RANGE

	# Step 2: Aim direction from hand to camera target
	var to_target: Vector3 = aim_target - hand_origin
	var aim_dist: float = to_target.length()
	if aim_dist < 0.1:
		_draw_offset = Vector2.ZERO
		_has_hit = false
		_has_target = false
		return
	var aim_dir: Vector3 = to_target / aim_dist

	# Step 3: Single extended ray — always hits terrain, no edge-of-range flicker
	var extended_far := hand_origin + aim_dir * EXTENDED_RAY
	var query := PhysicsRayQueryParameters3D.create(hand_origin, extended_far)
	query.exclude = [_player.get_rid()]
	query.collision_mask = 1

	var result := space_state.intersect_ray(query)

	if result.is_empty():
		_has_hit = false
		_has_target = false
		return

	# Check distance from hand to hit for white/gray color
	var hit_dist: float = hand_origin.distance_to(result.position)
	_has_hit = hit_dist <= GRAPPLE_RANGE
	_has_target = true
	_set_screen_offset(cam, result.position)


func _set_screen_offset(cam: Camera3D, world_pos: Vector3) -> void:
	if cam.is_position_behind(world_pos):
		_draw_offset = Vector2.ZERO
		return
	var screen_pos: Vector2 = cam.unproject_position(world_pos)
	var screen_center: Vector2 = get_viewport_rect().size * 0.5
	_draw_offset = screen_pos - screen_center


func _draw() -> void:
	if not visible:
		return
	var color: Color = X_COLOR_HIT if _has_hit else X_COLOR_NO_HIT
	var center := _draw_offset
	draw_line(center + Vector2(-X_SIZE, -X_SIZE), center + Vector2(X_SIZE, X_SIZE), color, X_THICKNESS, true)
	draw_line(center + Vector2(-X_SIZE, X_SIZE), center + Vector2(X_SIZE, -X_SIZE), color, X_THICKNESS, true)
