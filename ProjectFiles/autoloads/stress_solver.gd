extends Node

## Dedicated worker thread for gravity stress solves.
##
## WHY NOT WorkerThreadPool: solves are long CPU-bound tasks (100-400ms on
## big structures). The engine's WorkerThreadPool is shared with Jolt physics
## jobs and terrain chunk meshing (terrain_system.gd) — parking gravity
## solves there starved both: physics ticks jittered (micro-stutter, choppy
## player-Y) and terrain chunks stopped loading. One dedicated OS thread
## keeps the pool clean and naturally serializes collapse cascades map-wide.
##
## Jobs carry ONLY data (arrays are COW snapshots) and never reference the
## requesting node; results are stored by id and polled. A structure that
## frees mid-solve just cancels — the worker's result is discarded, and
## nothing ever touches a freed object from the worker thread.

var _thread: Thread
var _mutex := Mutex.new()
var _semaphore := Semaphore.new()
var _queue: Array = []           ## of { "id": int, "args": Dictionary }
var _results: Dictionary = {}    ## id -> result Dictionary
var _cancelled: Dictionary = {}  ## id -> true
var _next_id: int = 1
var _exit: bool = false


func _ready() -> void:
	_thread = Thread.new()
	_thread.start(_worker)


func _exit_tree() -> void:
	_mutex.lock()
	_exit = true
	_mutex.unlock()
	_semaphore.post()
	if _thread and _thread.is_started():
		_thread.wait_to_finish()


func submit_solve(args: Dictionary) -> int:
	## Queue a gravity solve. `args` keys mirror solve_gravity_stress params:
	## grid, mask, bond_strength, bond_damage, bond_broken, anchor_strength,
	## anchor_damage, anchor_broken, nx, ny, nz, gravity, params.
	## Returns a job id for take_result()/cancel().
	_mutex.lock()
	var id := _next_id
	_next_id += 1
	_queue.append({ "id": id, "args": args })
	_mutex.unlock()
	_semaphore.post()
	return id


func take_result(id: int) -> Dictionary:
	## Returns the solve result once ready and forgets it; {} while pending.
	_mutex.lock()
	var res: Variant = _results.get(id)
	if res != null:
		_results.erase(id)
	_mutex.unlock()
	return res if res != null else {}


func cancel(id: int) -> void:
	## Drop a queued job, or mark a running/finished one so its result is
	## discarded. Safe to call for already-consumed ids.
	_mutex.lock()
	var found_queued := false
	for i in _queue.size():
		if _queue[i]["id"] == id:
			_queue.remove_at(i)
			found_queued = true
			break
	if not found_queued and not _results.erase(id):
		_cancelled[id] = true
	_mutex.unlock()


func _worker() -> void:
	while true:
		_semaphore.wait()
		_mutex.lock()
		if _exit:
			_mutex.unlock()
			return
		var item: Variant = _queue.pop_front()
		_mutex.unlock()
		if item == null:
			continue
		var a: Dictionary = item["args"]
		var res: Dictionary = BlockMeshBuilder.solve_gravity_stress(
			a["grid"], a["mask"],
			a["bond_strength"], a["bond_damage"], a["bond_broken"],
			a["anchor_strength"], a["anchor_damage"], a["anchor_broken"],
			a["nx"], a["ny"], a["nz"], a["gravity"], a["params"])
		_mutex.lock()
		var id: int = item["id"]
		if _cancelled.erase(id):
			pass  # requester is gone — discard
		else:
			_results[id] = res
		_mutex.unlock()


func get_stats() -> Dictionary:
	_mutex.lock()
	var s := {
		"queued": _queue.size(),
		"pending_results": _results.size(),
		"next_id": _next_id,
	}
	_mutex.unlock()
	return s
