extends Node
class_name HeatSystem

## Tracks heat accumulation from combat. Server-authoritative.
## Provides multiplier getters for damage, speed, health, and burn rate.

## Current heat level (0.0 to max_heat).
var heat_level: float = 0.0
var max_heat: float = 100.0
var is_fever: bool = false

## Heat decay rate per second when out of combat.
@export var heat_decay_rate: float = 3.0
## Seconds of no combat before heat starts decaying.
@export var combat_timeout: float = 4.0
## Fever threshold.
@export var fever_threshold: float = 75.0

## Heat generation values
const HEAT_PER_DAMAGE_DEALT := 0.5  # Per HP of damage dealt
const HEAT_PER_DAMAGE_TAKEN := 0.3  # Per HP of damage taken
const HEAT_PER_KILL := 15.0
const HEAT_PER_DOWN := 8.0

## Multiplier curves (thresholds at 25, 50, 75)
const DAMAGE_MULTS := [1.0, 1.15, 1.35, 1.6]
const SPEED_MULTS := [1.0, 1.05, 1.15, 1.3]
const HEALTH_BONUSES := [0.0, 10.0, 25.0, 50.0]
const BURN_RATE_MULTS := [1.0, 1.1, 1.3, 1.8]

var _time_since_combat: float = 999.0

signal fever_started
signal fever_ended
signal heat_changed(new_heat: float)


func _physics_process(delta: float) -> void:
	if not multiplayer.is_server():
		return

	_time_since_combat += delta

	# Decay heat when out of combat
	if _time_since_combat >= combat_timeout and heat_level > 0.0:
		heat_level = maxf(heat_level - heat_decay_rate * delta, 0.0)
		heat_changed.emit(heat_level)

	# Check fever state
	var was_fever := is_fever
	is_fever = heat_level >= fever_threshold
	if is_fever and not was_fever:
		fever_started.emit()
	elif not is_fever and was_fever:
		fever_ended.emit()


func add_heat(amount: float) -> void:
	## Server-only: add heat from combat actions.
	heat_level = minf(heat_level + amount, max_heat)
	_time_since_combat = 0.0
	heat_changed.emit(heat_level)


func on_damage_dealt(damage_amount: float) -> void:
	add_heat(damage_amount * HEAT_PER_DAMAGE_DEALT)


func on_damage_taken(damage_amount: float) -> void:
	add_heat(damage_amount * HEAT_PER_DAMAGE_TAKEN)


func on_kill() -> void:
	add_heat(HEAT_PER_KILL)


func on_down() -> void:
	add_heat(HEAT_PER_DOWN)


func reset() -> void:
	heat_level = 0.0
	is_fever = false
	_time_since_combat = 999.0


## Multiplier getters — interpolated based on heat level.

func _get_tier() -> int:
	if heat_level < 25.0:
		return 0
	elif heat_level < 50.0:
		return 1
	elif heat_level < 75.0:
		return 2
	else:
		return 3


func get_damage_multiplier() -> float:
	return DAMAGE_MULTS[_get_tier()]


func get_speed_multiplier() -> float:
	return SPEED_MULTS[_get_tier()]


func get_health_bonus() -> float:
	return HEALTH_BONUSES[_get_tier()]


func get_burn_rate_multiplier() -> float:
	return BURN_RATE_MULTS[_get_tier()]
