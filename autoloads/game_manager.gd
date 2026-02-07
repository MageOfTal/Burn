extends Node

## Manages high-level game state transitions.

enum GameState { MENU, LOBBY, PLAYING, GAME_OVER }

var current_state: GameState = GameState.MENU
var match_time_elapsed: float = 0.0

signal game_state_changed(new_state: GameState)
signal match_started
signal match_ended


func change_state(new_state: GameState) -> void:
	current_state = new_state
	game_state_changed.emit(new_state)
	if new_state == GameState.PLAYING:
		match_time_elapsed = 0.0
		match_started.emit()
	elif new_state == GameState.GAME_OVER:
		match_ended.emit()


func _process(delta: float) -> void:
	if current_state == GameState.PLAYING:
		match_time_elapsed += delta
