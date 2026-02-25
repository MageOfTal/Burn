extends WeaponBase
class_name WeaponLagger

## Debug weapon with two modes, toggled via GameManager.debug_lagger_overhead_mode:
##
## 1. **Overhead mode** (default): Busy-waits every physics tick while equipped.
##    Simulates sustained per-tick overhead (like expensive structure processing).
##    Because each catch-up tick also stalls, Godot can never catch up — the player
##    freezes in midair, exactly like real sustained physics overhead.
##
## 2. **One-off mode**: Busy-waits once when fired, then does nothing until next fire.
##    Simulates a single expensive spike (like an explosion). With max_physics_steps
##    = 120, Godot runs catch-up ticks after the stall, so the player teleports to
##    the ground — exactly like a real one-off spike.
##
## max_physics_steps_per_frame is set to 120 while equipped. This allows aggressive
## catch-up in one-off mode (matching real behavior) while overhead mode naturally
## prevents catch-up because every tick gets stalled.

const LAGGER_MAX_PHYSICS_STEPS := 120
const DEFAULT_MAX_PHYSICS_STEPS := 8  # Godot default, restored on exit

var _log_cooldown: float = 0.0


func _enter_tree() -> void:
	Engine.max_physics_steps_per_frame = LAGGER_MAX_PHYSICS_STEPS


func _physics_process(delta: float) -> void:
	super._physics_process(delta)

	if not GameManager.debug_lagger_overhead_mode:
		return  # One-off mode — stall happens in _do_fire() only

	var delay_ms: float = GameManager.debug_lagger_delay_ms
	if delay_ms <= 0.0:
		return

	_busy_wait(delay_ms, delta)


func _do_fire(_shooter: Player, _aim_origin: Vector3, _aim_direction: Vector3) -> Dictionary:
	if GameManager.debug_lagger_overhead_mode:
		return {}  # Overhead mode — stall happens in _physics_process

	var delay_ms: float = GameManager.debug_lagger_delay_ms
	if delay_ms > 0.0:
		_busy_wait(delay_ms, 0.0)
	return {}


func _busy_wait(delay_ms: float, delta: float) -> void:
	var delay_us: int = int(delay_ms * 1000.0)
	var start_us := Time.get_ticks_usec()
	while (Time.get_ticks_usec() - start_us) < delay_us:
		pass
	var actual_us := Time.get_ticks_usec() - start_us
	GameManager.tick_add("lagger", actual_us)

	# Log once per second to avoid console spam
	_log_cooldown -= delta if delta > 0.0 else 0.1
	if _log_cooldown <= 0.0:
		var mode := "overhead" if GameManager.debug_lagger_overhead_mode else "one-off"
		print("[Lagger] %s: stalling %.1f ms (actual %.1f ms)" % [mode, delay_ms, actual_us / 1000.0])
		_log_cooldown = 1.0


func _exit_tree() -> void:
	Engine.max_physics_steps_per_frame = DEFAULT_MAX_PHYSICS_STEPS
