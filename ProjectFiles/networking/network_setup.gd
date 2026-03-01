class_name NetworkSetup
extends Node

## Automatic network configuration for online play.
## Handles Windows Firewall rules (UAC-elevated) and UPnP port mapping.
## Added as a child of NetworkManager — call setup_for_hosting() when hosting.

signal setup_progress(step: String, detail: String)
signal setup_complete(result: SetupResult)

enum SetupResult { SUCCESS, PARTIAL, FAILED }
enum FirewallStatus { UNKNOWN, ALREADY_EXISTS, CREATED, DENIED, ERROR }
enum UPNPStatus { UNKNOWN, DISCOVERING, MAPPED, NO_GATEWAY, FAILED }

const FIREWALL_RULE_NAME := "Burn Royale"
const UPNP_DISCOVER_TIMEOUT_MS := 3000
const EXTERNAL_IP_FALLBACK_URL := "https://api.ipify.org"

var firewall_status := FirewallStatus.UNKNOWN
var upnp_status := UPNPStatus.UNKNOWN
var external_ip := ""

var _upnp: UPNP = null
var _mapped_port := 0
var _setup_thread: Thread = null
var _is_setup_running := false
var _firewall_done := false
var _upnp_done := false


func setup_for_hosting(port: int) -> void:
	if _is_setup_running:
		return
	_is_setup_running = true
	_firewall_done = false
	_upnp_done = false
	_mapped_port = port
	firewall_status = FirewallStatus.UNKNOWN
	upnp_status = UPNPStatus.UNKNOWN
	external_ip = ""

	# Firewall: check/create rule (async coroutine with polling)
	_ensure_firewall_rule(port)

	# UPnP: run in a thread (discovery is blocking)
	upnp_status = UPNPStatus.DISCOVERING
	setup_progress.emit("upnp", "Discovering router...")
	_setup_thread = Thread.new()
	_setup_thread.start(_upnp_thread_work.bind(port))


func _process(_delta: float) -> void:
	if _setup_thread == null or _setup_thread.is_alive():
		return

	# Thread finished — harvest result on main thread
	_setup_thread.wait_to_finish()
	_setup_thread = null
	_upnp_done = true

	match upnp_status:
		UPNPStatus.MAPPED:
			setup_progress.emit("upnp", "Port forwarded via UPnP")
		UPNPStatus.NO_GATEWAY:
			setup_progress.emit("upnp", "No UPnP gateway found")
		UPNPStatus.FAILED:
			setup_progress.emit("upnp", "UPnP port mapping failed")

	if not external_ip.is_empty():
		setup_progress.emit("external_ip", external_ip)
	else:
		# Fallback: fetch external IP via HTTP
		_fetch_external_ip_http()

	_try_emit_complete()


# ======================================================================
#  Firewall
# ======================================================================

func _ensure_firewall_rule(port: int) -> void:
	if OS.get_name() != "Windows":
		print("[NetworkSetup] Not Windows — skipping firewall setup")
		firewall_status = FirewallStatus.ALREADY_EXISTS
		_firewall_done = true
		setup_progress.emit("firewall", "N/A (not Windows)")
		_try_emit_complete()
		return

	setup_progress.emit("firewall", "Checking Windows Firewall...")

	# Check if rule already exists (non-elevated, fast)
	var output: Array = []
	var exit_code := OS.execute("netsh", PackedStringArray([
		"advfirewall", "firewall", "show", "rule",
		"name=" + FIREWALL_RULE_NAME
	]), output, true)

	var output_text := "\n".join(output)
	if exit_code == 0 and "UDP" in output_text and str(port) in output_text:
		firewall_status = FirewallStatus.ALREADY_EXISTS
		_firewall_done = true
		setup_progress.emit("firewall", "Firewall rule already exists")
		print("[NetworkSetup] Firewall rule '%s' already exists for UDP %d" % [FIREWALL_RULE_NAME, port])
		_try_emit_complete()
		return

	# Rule missing — create with UAC elevation
	print("[NetworkSetup] Firewall rule not found — requesting elevation (UAC)...")
	setup_progress.emit("firewall", "Requesting permission (UAC)...")

	var netsh_add := "netsh advfirewall firewall add rule name='%s' dir=in action=allow protocol=UDP localport=%d" % [FIREWALL_RULE_NAME, port]
	var ps_args := PackedStringArray([
		"-NoProfile", "-ExecutionPolicy", "Bypass", "-Command",
		"Start-Process powershell -Verb RunAs -Wait -ArgumentList '-NoProfile -Command \"%s\"'" % netsh_add
	])

	var pid := OS.create_process("powershell.exe", ps_args)
	if pid == -1:
		firewall_status = FirewallStatus.ERROR
		_firewall_done = true
		setup_progress.emit("firewall", "Failed to launch firewall setup")
		push_error("[NetworkSetup] OS.create_process failed for firewall elevation")
		_try_emit_complete()
		return

	# Poll until the rule appears or we time out
	_poll_firewall_rule(port)


func _poll_firewall_rule(port: int) -> void:
	for i in 60:  # 60 * 0.5s = 30s max
		await get_tree().create_timer(0.5).timeout
		if _check_firewall_rule_exists(port):
			firewall_status = FirewallStatus.CREATED
			_firewall_done = true
			setup_progress.emit("firewall", "Firewall rule created!")
			print("[NetworkSetup] Firewall rule created successfully")
			_try_emit_complete()
			return

	# Timed out — user probably denied UAC or closed the prompt
	firewall_status = FirewallStatus.DENIED
	_firewall_done = true
	setup_progress.emit("firewall", "Firewall setup timed out (UAC denied?)")
	print("[NetworkSetup] Firewall rule creation timed out")
	_try_emit_complete()


func _check_firewall_rule_exists(port: int) -> bool:
	var output: Array = []
	var exit_code := OS.execute("netsh", PackedStringArray([
		"advfirewall", "firewall", "show", "rule",
		"name=" + FIREWALL_RULE_NAME
	]), output, true)
	var output_text := "\n".join(output)
	return exit_code == 0 and "UDP" in output_text and str(port) in output_text


# ======================================================================
#  UPnP (runs in thread)
# ======================================================================

func _upnp_thread_work(port: int) -> void:
	_upnp = UPNP.new()

	# Discover UPnP devices on the network
	var discover_result := _upnp.discover(UPNP_DISCOVER_TIMEOUT_MS)
	if discover_result != UPNP.UPNP_RESULT_SUCCESS:
		upnp_status = UPNPStatus.FAILED
		print("[NetworkSetup] UPnP discover failed (code %d)" % discover_result)
		return

	# Verify we found a valid Internet Gateway Device
	var gateway := _upnp.get_gateway()
	if gateway == null or not gateway.is_valid_gateway():
		upnp_status = UPNPStatus.NO_GATEWAY
		print("[NetworkSetup] No valid UPnP gateway found")
		return

	# Query external IP before port mapping (in case mapping fails)
	external_ip = _upnp.query_external_address()
	if external_ip.is_empty():
		print("[NetworkSetup] UPnP external IP query returned empty")
	else:
		print("[NetworkSetup] External IP via UPnP: %s" % external_ip)

	# Add port mapping
	var map_result := _upnp.add_port_mapping(port, port, "Burn Royale", "UDP", 0)
	if map_result == UPNP.UPNP_RESULT_SUCCESS:
		upnp_status = UPNPStatus.MAPPED
		print("[NetworkSetup] UPnP port mapping created: UDP %d" % port)
	else:
		upnp_status = UPNPStatus.FAILED
		print("[NetworkSetup] UPnP port mapping failed (code %d)" % map_result)


# ======================================================================
#  External IP fallback (HTTP)
# ======================================================================

func _fetch_external_ip_http() -> void:
	var http := HTTPRequest.new()
	add_child(http)
	http.request_completed.connect(_on_external_ip_response.bind(http))
	var err := http.request(EXTERNAL_IP_FALLBACK_URL)
	if err != OK:
		print("[NetworkSetup] HTTP external IP request failed: %s" % error_string(err))
		http.queue_free()


func _on_external_ip_response(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray, http: HTTPRequest) -> void:
	http.queue_free()
	if result == HTTPRequest.RESULT_SUCCESS and response_code == 200:
		external_ip = body.get_string_from_utf8().strip_edges()
		print("[NetworkSetup] External IP via HTTP: %s" % external_ip)
		setup_progress.emit("external_ip", external_ip)
	else:
		print("[NetworkSetup] HTTP external IP fallback failed (result=%d, code=%d)" % [result, response_code])


# ======================================================================
#  Completion + Cleanup
# ======================================================================

func _try_emit_complete() -> void:
	if not _firewall_done or not _upnp_done:
		return
	_is_setup_running = false

	var fw_ok := firewall_status in [FirewallStatus.ALREADY_EXISTS, FirewallStatus.CREATED]
	var upnp_ok := upnp_status == UPNPStatus.MAPPED

	var result: SetupResult
	if fw_ok and upnp_ok:
		result = SetupResult.SUCCESS
	elif fw_ok or upnp_ok:
		result = SetupResult.PARTIAL
	else:
		result = SetupResult.FAILED

	setup_complete.emit(result)


func cleanup() -> void:
	# Wait for thread if it's still running
	if _setup_thread != null:
		_setup_thread.wait_to_finish()
		_setup_thread = null

	# Remove UPnP port mapping (firewall rule intentionally persists)
	if _upnp != null and upnp_status == UPNPStatus.MAPPED and _mapped_port > 0:
		var result := _upnp.delete_port_mapping(_mapped_port, "UDP")
		if result == UPNP.UPNP_RESULT_SUCCESS:
			print("[NetworkSetup] UPnP port mapping removed for UDP %d" % _mapped_port)
		else:
			print("[NetworkSetup] UPnP port mapping removal failed (code %d)" % result)

	_upnp = null
	_mapped_port = 0
	upnp_status = UPNPStatus.UNKNOWN
	external_ip = ""


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		cleanup()
