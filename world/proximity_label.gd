extends Node
class_name ProximityLabel

## Reusable component that manages a Label3D popup based on player proximity.
## Add as a child of any Node3D-based interactable. Handles:
##   - Cached local player lookup (avoids tree traversal every frame)
##   - Distance-based label visibility
##   - Label3D creation and lifecycle
##
## The parent interactable controls behavior via:
##   - popup_range: distance threshold to show the label
##   - label_offset: local position offset for the Label3D
##   - update_callback: called every frame the player is in range, receives (label, player, dist)
##   - visibility_callback: optional, called to decide if the label should show (returns bool)

## Distance within which the label becomes visible.
@export var popup_range := 5.0

## Local position offset for the Label3D relative to the parent.
@export var label_offset := Vector3(0, 1.5, 0)

## Label3D visual properties.
@export var font_size := 48
@export var outline_size := 6
@export var label_color := Color.WHITE
@export var outline_color := Color(0, 0, 0)

## If true, the label node persists and uses .visible toggling.
## If false, the label is created/destroyed on demand (queue_free style).
@export var use_visibility_toggle := true

## Callback called every frame the player is in range.
## Signature: func(label: Label3D, player: Node, distance: float) -> void
var update_callback: Callable = Callable()

## Optional callback to control visibility beyond just distance.
## Signature: func(player: Node, distance: float) -> bool
## Return false to hide the label even when in range.
var visibility_callback: Callable = Callable()

## The managed Label3D — read-only from outside.
var label: Label3D = null

## Cached local player reference.
var _cached_local_player: Node = null
var _player_cache_timer: float = 0.0
const PLAYER_CACHE_INTERVAL := 1.0

## Reference to the parent Node3D (set in _ready).
var _parent_3d: Node3D = null


func _ready() -> void:
	_parent_3d = get_parent() as Node3D
	if _parent_3d == null:
		push_warning("ProximityLabel: parent is not a Node3D, disabling.")
		set_process(false)
		return

	if use_visibility_toggle:
		_create_label()
		label.visible = false


func _process(delta: float) -> void:
	if _parent_3d == null:
		return

	# Refresh cached player periodically
	_player_cache_timer -= delta
	if _player_cache_timer <= 0.0 or not is_instance_valid(_cached_local_player):
		_player_cache_timer = PLAYER_CACHE_INTERVAL
		_cached_local_player = _find_local_player()

	if _cached_local_player == null or not _cached_local_player.is_inside_tree():
		_hide_label()
		return

	var dist: float = _parent_3d.global_position.distance_to(
		_cached_local_player.global_position
	)

	if dist >= popup_range:
		_hide_label()
		return

	# Optional visibility gate (e.g. "am I the closest item?")
	if visibility_callback.is_valid():
		if not visibility_callback.call(_cached_local_player, dist):
			_hide_label()
			return

	_show_label()

	# Let the owner update text/color each frame
	if update_callback.is_valid() and label != null:
		update_callback.call(label, _cached_local_player, dist)


func get_local_player() -> Node:
	## Public accessor for the cached local player (useful for parent logic).
	return _cached_local_player


func _show_label() -> void:
	if use_visibility_toggle:
		if label != null:
			label.visible = true
	else:
		if label == null:
			_create_label()


func _hide_label() -> void:
	if use_visibility_toggle:
		if label != null:
			label.visible = false
	else:
		if label != null:
			label.queue_free()
			label = null


func _create_label() -> void:
	label = Label3D.new()
	label.font_size = font_size
	label.outline_size = outline_size
	label.modulate = label_color
	label.outline_modulate = outline_color
	label.position = label_offset
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_parent_3d.add_child(label)


func _find_local_player() -> Node:
	var toad_dim := get_node_or_null("/root/ToadDimension")
	if toad_dim and toad_dim.has_method("find_player_anywhere"):
		return toad_dim.find_player_anywhere(multiplayer.get_unique_id())
	var players := get_tree().current_scene.get_node_or_null("Players")
	if players == null:
		return null
	return players.get_node_or_null(str(multiplayer.get_unique_id()))
