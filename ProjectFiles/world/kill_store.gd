extends StaticBody3D
class_name KillStore

## Kill-currency store placed in the world. Players press B to open the store UI.
## Server-authoritative: the server validates proximity before opening the UI.
## The store itself has no server state — it's just a physical location marker.

const STORE_INTERACT_RANGE := 4.0   ## B key works within this distance
const STORE_POPUP_RANGE := 8.0      ## "[B] STORE" label appears within this distance

## Bonus catalog — shared data for all stores and the purchase UI.
## Each entry: { id: int, name: String, desc: String, cost: int }
static var BONUS_CATALOG: Array[Dictionary] = [
	# Tier 1 — 1 Token
	{ "id": 0,  "name": "Iron Lungs",      "desc": "+100 starting fuel on respawn",         "cost": 1 },
	{ "id": 1,  "name": "Steady Hand",     "desc": "-15% weapon spread",                    "cost": 1 },
	{ "id": 2,  "name": "Thick Skin",      "desc": "+15 max HP",                            "cost": 1 },
	{ "id": 3,  "name": "Scavenger",       "desc": "+50% scrap fuel from X key",            "cost": 1 },
	# Tier 2 — 2 Tokens
	{ "id": 4,  "name": "Quick Hands",     "desc": "-20% fire rate cooldown",               "cost": 2 },
	{ "id": 5,  "name": "Adrenaline Rush", "desc": "+10% move speed",                       "cost": 2 },
	{ "id": 6,  "name": "Blast Padding",   "desc": "-20% damage taken",                     "cost": 2 },
	{ "id": 7,  "name": "Extended Mags",   "desc": "+40% burn timer on item pickup",        "cost": 2 },
	# Tier 3 — 3 Tokens
	{ "id": 8,  "name": "Heat Sink",       "desc": "Heat decays 50% slower",                "cost": 3 },
	{ "id": 9,  "name": "Phoenix Fuel",    "desc": "+500 fuel on respawn",                   "cost": 3 },
	{ "id": 10, "name": "Vulture",         "desc": "Kills drop a fuel canister",            "cost": 3 },
	# Tier 4 — 5 Tokens
	{ "id": 11, "name": "Juggernaut",      "desc": "+40 max HP and +10% damage",            "cost": 5 },
	{ "id": 12, "name": "Second Wind",     "desc": "5s speed boost on respawn",             "cost": 1 },
]

## Visual nodes (built in _ready)
var _body_mesh: MeshInstance3D = null
var _glow_light: OmniLight3D = null
var _prompt_proximity: ProximityLabel = null


func _ready() -> void:
	collision_layer = CollisionLayers.WORLD
	collision_mask = 0
	_build_visuals()


func _build_visuals() -> void:
	# Hexagonal pillar body
	_body_mesh = MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.6
	cyl.bottom_radius = 0.6
	cyl.height = 1.5
	cyl.radial_segments = 6  # Hexagonal shape
	_body_mesh.mesh = cyl
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.25, 0.1, 0.45)
	mat.emission_enabled = true
	mat.emission = Color(0.15, 0.05, 0.3)
	mat.emission_energy_multiplier = 0.5
	_body_mesh.material_override = mat
	_body_mesh.position.y = 0.75
	add_child(_body_mesh)

	# Collision shape
	var col := CollisionShape3D.new()
	var col_shape := CylinderShape3D.new()
	col_shape.radius = 0.6
	col_shape.height = 1.5
	col.shape = col_shape
	col.position.y = 0.75
	add_child(col)

	# Cyan glow light
	_glow_light = OmniLight3D.new()
	_glow_light.light_color = Color(0.3, 0.85, 1.0)
	_glow_light.light_energy = 2.5
	_glow_light.omni_range = 6.0
	_glow_light.position.y = 2.0
	add_child(_glow_light)

	# Prompt label (proximity-based, participates in unified closest-interactable system)
	_prompt_proximity = ProximityLabel.new()
	_prompt_proximity.popup_range = STORE_POPUP_RANGE
	_prompt_proximity.label_offset = Vector3(0, 2.2, 0)
	_prompt_proximity.label_color = Color(0.3, 0.85, 1.0)
	_prompt_proximity.use_visibility_toggle = true
	_prompt_proximity.update_callback = _on_prompt_label_update
	_prompt_proximity.interactable_group = "interact"
	add_child(_prompt_proximity)


func get_interact_distance(player_pos: Vector3) -> float:
	## Unified interactable interface — stores always compete for the [E] prompt.
	var d: float = global_position.distance_to(player_pos)
	if d < STORE_POPUP_RANGE:
		return d
	return INF


func _on_prompt_label_update(lbl: Label3D, player_node: Node, _dist: float) -> void:
	var inv = player_node.get_node_or_null("Inventory")
	var tokens: int = int(inv.kill_currency) if inv else 0
	lbl.text = "[E] STORE (%d tokens)" % tokens
	lbl.modulate = Color(0.3, 0.85, 1.0)
