class_name CollisionLayers

## Centralized collision layer/mask constants for the entire project.
## Use CollisionLayers.WORLD, CollisionLayers.SURFACE, etc. from any script.
## No autoload needed — class_name makes all constants globally accessible.

# ======================================================================
#  Layer bits (one per physics layer)
# ======================================================================

const WORLD        := 1       ## Layer 1  — terrain, static geometry, chests
const ITEMS        := 2       ## Layer 2  — world pickups, tower topple bodies
const BUBBLES      := 4       ## Layer 3  — bubble projectiles
const RUBBER_BALLS := 8       ## Layer 4  — rubber ball projectiles
const TOAD_WALLS   := 16      ## Layer 5  — toad dimension walls
const DEBRIS       := 32      ## Layer 6  — cosmetic wall fragments (client-side)
const TOAD_RAIN    := 64      ## Layer 7  — toad rain bodies (4 kg RigidBody3D)
const PLAYERS_HIT  := 128     ## Layer 8  — players (targeting/damage queries)
const TOAD_PLAYERS := 256     ## Layer 9  — toad dimension players
const PLAYERS_PUSH := 512     ## Layer 10 — players (physics push, Jolt native)
const WALL_BLOCKS  := 1024    ## Layer 11 — per-block StaticBody3D (weapon raycasts)
const WALL_SMOOTH  := 2048    ## Layer 12 — smooth wall body (player/object physics)

# ======================================================================
#  Common composite masks (reused across many files)
# ======================================================================

## Solid world surfaces for raycasts — terrain + smooth walls.
## Used by: camera, gadget crosshair, grapple aim, compass, weapon safe-spawn,
## bubble collision, debris collision, kamikaze ground check.
const SURFACE := WORLD | WALL_SMOOTH  # 2049

## Solid surfaces WITH per-block detail — adds wall blocks for grapple obstacles.
## Used by: grapple sweep queries, rope LOS checks.
const SURFACE_DETAILED := WORLD | WALL_BLOCKS | WALL_SMOOTH  # 3073

## Standard mask for physics objects that push players via Jolt native collision.
## Used by: tower topple bodies, toad bodies, debug push boxes.
const PHYSICS_PUSH := WORLD | PLAYERS_PUSH | WALL_SMOOTH  # 2561

## Both player targeting layers (overworld + toad dimension).
const ALL_PLAYERS := PLAYERS_HIT | TOAD_PLAYERS  # 384

## Shielding raycast mask — what can absorb explosion damage.
## Used by: explosion_helper shielding queries, C++ calc_ray_shielding.
const SHIELDING := WORLD | PLAYERS_HIT | TOAD_PLAYERS | WALL_BLOCKS  # 1409

# ======================================================================
#  Player collision
# ======================================================================

## Player RigidBody3D layer — on both targeting (8) and push (10).
const PLAYER_LAYER := PLAYERS_HIT | PLAYERS_PUSH  # 640

## Player RigidBody3D mask — what the player physically collides with.
const PLAYER_MASK := WORLD | ITEMS | BUBBLES | RUBBER_BALLS | TOAD_WALLS | TOAD_RAIN | PLAYERS_HIT | WALL_SMOOTH  # 2271

## Toad dimension player layers/masks (swapped from normal).
const TOAD_PLAYER_LAYER := TOAD_PLAYERS | PLAYERS_PUSH  # 768
const TOAD_PLAYER_MASK := WORLD | TOAD_WALLS | TOAD_RAIN | TOAD_PLAYERS  # 337

# ======================================================================
#  PhysicsBodyBase masks (previously on PhysicsBodyBase)
# ======================================================================

## Default mask for solid physics objects (tower chunks, falling clusters, slabs).
## Covers: world, items, bubbles, rubber balls, player push, smooth walls.
const DEFAULT_PHYSICS := WORLD | ITEMS | BUBBLES | RUBBER_BALLS | PLAYERS_PUSH | WALL_SMOOTH  # 2575

## Mask for projectiles and projectile-like objects (rockets, bubbles, toads).
## Deliberately excludes items and rubber balls.
const PROJECTILE_PHYSICS := WORLD | BUBBLES | PLAYERS_PUSH | WALL_SMOOTH  # 2565

# ======================================================================
#  Helpers
# ======================================================================

## Returns the correct player targeting bit based on dimension.
static func player_bit(is_toad: bool) -> int:
	return TOAD_PLAYERS if is_toad else PLAYERS_HIT
