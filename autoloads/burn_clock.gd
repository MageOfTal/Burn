extends Node

## Global burn rate multiplier that escalates over match time.
## All BurnTimerManagers read from this.

## Multiplier starts at 1.0 and increases to max_multiplier over the match.
var global_burn_multiplier: float = 1.0

## How fast the multiplier escalates per second.
@export var escalation_rate: float = 0.005
## Maximum burn multiplier cap.
@export var max_multiplier: float = 3.0

var _active: bool = false


func start() -> void:
	_active = true
	global_burn_multiplier = 1.0


func stop() -> void:
	_active = false


func get_burn_multiplier() -> float:
	return global_burn_multiplier


func _physics_process(delta: float) -> void:
	if not _active:
		return
	if not multiplayer.is_server():
		return

	global_burn_multiplier = minf(
		global_burn_multiplier + escalation_rate * delta,
		max_multiplier
	)
