# Bond Graph Destruction System — Implementation Plan

Reference doc to keep the work on track. Read top-to-bottom before starting any session; check off completed steps; do not deviate from the in-scope list without updating this doc.

## Goal

Replace the implicit-bonds-from-grid model + force-equilibrium stress solver with an **explicit bond graph** where bonds carry independent damage state, modelled after The Finals. Bonds break when accumulated damage exceeds their strength, regardless of whether the connecting blocks have full HP. Connectivity check on the (post-damage) bond graph determines what detaches.

**The user will test this with a rocket launcher when complete.** All three damage paths must work end-to-end:
- Hitscan (bullets)
- Explosions (rockets)
- Momentum (heavy/fast collisions)

## Architecture decisions (locked in)

1. **Keep block HP.** Existing per-block HP stays intact. Hitscan still damages a hit block's HP. When HP reaches 0, block destroys; all bonds touching that block become broken.
2. **Add explicit bond strengths and damage.** Per-bond state: `strength` (max damage before break), `damage` (accumulated). Stored per-block × 3 canonical directions (+X, +Y, +Z) so each bond is owned by the lower-indexed block.
3. **Drop force-equilibrium stress solver from production calls.** Existing C++ `calc_stress_integrity_localized` stays in the engine (research artifact) but is not called. Production uses a NEW connectivity check that respects broken bonds.
4. **Bond strength derived from material.** Initial strength = some factor × `_block_hp` so that "tougher" blocks have tougher bonds. Reasonable starting point; iterate later.
5. **Damage radii**:
   - Bullet: very small (only the bonds touching the hit block)
   - Explosion: radial with falloff (same energy curve as `take_damage_at`)
   - Momentum: small (only bonds near impact point)
6. **Bond breakage cascading via destruction events** (deferred). For v1, falling chunks do NOT damage adjacent bonds. Add later if "Smooth Destruction"-style cascade needed.
7. **Stress-from-gravity detection** is OUT OF SCOPE for v1. A wall can be too top-heavy and stay standing because no damage has been applied. Acceptable for FPS gameplay.
8. **Performance optimizations are deferred.** No localized solver, no SDF overlay, no async. Get the model correct, profile after, optimize later.

## In-scope for this session

| # | Task | Deliverable |
|---|---|---|
| 1 | Roll back the localized stress solver wiring (currently uses full solver — verify this is in place) | `_check_structural_integrity` calls `calc_stress_integrity_components` (existing full solver) — temporary state |
| 2 | Define bond graph storage on `DestructibleBlockStructure` | New fields: `_bond_strength: PackedFloat32Array`, `_bond_damage: PackedFloat32Array`, `_bond_broken: PackedByteArray`. Each sized `grid_size * 3` |
| 3 | Initialize bond strengths at structure creation | At `_deferred_build_foundation` time, populate `_bond_strength` from block adjacency × material factor |
| 4 | Add `damage_bonds_in_radius(world_pos, energy, radius)` method | Iterates bonds within radius, applies falloff, accumulates damage, sets `_bond_broken[i] = 1` when threshold crossed |
| 5 | Add `_check_bond_connectivity()` method (replaces `_check_structural_integrity`) | BFS from ground anchors traversing only intact bonds. Detached components become falling clusters |
| 6 | Hook explosions: in `take_damage_at`, after C++ destroys blocks, also call `damage_bonds_in_radius` | Rocket launcher will damage bonds AND blocks |
| 7 | Hook bullets: in `_damage_block`, damage all bonds touching the hit block | Bullets weaken adjacent bonds slightly |
| 8 | Hook momentum: in `take_momentum_damage_at`, damage bonds at impact | Heavy objects damage bonds locally |
| 9 | When block destroyed (HP→0), mark all 6 of its bonds as broken | Auto-cascade: destroyed block can't transmit support |
| 10 | C++: add `calc_bond_connectivity_components()` — like `calc_integrity_components` but takes broken-bonds array | Fast BFS in C++ that respects broken bonds |
| 11 | Headless test for the new connectivity logic | Test cases parallel the old ones; verify bonds break + components detach correctly |
| 12 | In-game test scaffolding | Make sure debug logging is clean, then user tests with rocket launcher |

## NOT in scope (write down so we don't drift)

- Localized incremental updates (deferred — full re-solve is fine for now)
- SDF damage overlay
- Async stress check
- Smooth Destruction (chunks-falling-damage-bonds cascade)
- Per-shape shielding HP (keeps current per-body system)
- Adjacent-hull merging for compound hit body
- Body pooling for falling clusters
- Replacing block HP entirely with bond damage (we keep both)

## Bond data model

For each block at grid index `idx`, store 3 bonds (only for the +X, +Y, +Z direction — owned by the lower-indexed block of each pair):

```
bond_idx = idx * 3 + (d / 2)
where d is in {0, 2, 4} (i.e., +X=0, +Y=1, +Z=2 in compressed form)
```

Actually use the simpler: `bond_idx = idx * 3 + axis`, with `axis ∈ {0, 1, 2}` for X, Y, Z directions.

Storage:
```gdscript
var _bond_strength: PackedFloat32Array  # size grid_size * 3
var _bond_damage:   PackedFloat32Array  # size grid_size * 3
var _bond_broken:   PackedByteArray     # size grid_size * 3 (1 if broken)
```

Bond between block `idx` and its `+X` neighbor: `idx * 3 + 0`.
Bond between block `idx` and its `+Y` neighbor: `idx * 3 + 1`.
Bond between block `idx` and its `+Z` neighbor: `idx * 3 + 2`.

Bonds at structure boundary (no neighbor in that direction) have strength 0 and are pre-marked broken; ignored.

## Bond damage flow

When a damage event occurs at world position P with energy E and radius R:

1. Compute bbox of bonds within radius R of P.
2. For each bond (idx, axis) whose midpoint is within R of P:
   a. Skip if `_bond_broken[bond_idx] != 0`.
   b. `falloff = 1.0 - (distance / R) ** 2` (or whatever curve).
   c. `_bond_damage[bond_idx] += E * falloff`.
   d. If `_bond_damage[bond_idx] >= _bond_strength[bond_idx]`, set `_bond_broken[bond_idx] = 1`.
3. After damage: run connectivity check (`_check_bond_connectivity`).
4. Detach any components no longer reachable from ground.

When a block is destroyed (HP→0):
- For each of its 6 directional bonds: mark broken.
  - For bonds at `idx * 3 + axis` (the +X/+Y/+Z bonds of this block).
  - For bonds at `neighbor_idx * 3 + axis_back` (the -X/-Y/-Z bonds, owned by the lower-indexed neighbor).

## Debug & testing strategy

- Add a debug toggle `GameManager.debug_bond_graph` that prints bond damage events.
- Keep the existing `_block_hp_dict` debug visualizations.
- Add a simple debug visualizer: in editor, draw lines between bond endpoints, colored by `damage / strength` ratio (green → red).
- Headless tests verify:
  - Single-bond damage applies correctly
  - Multiple-bond damage from explosion
  - Block destruction cascades to bond breaks
  - Connectivity check finds detached components
- In-game test (user): rocket launcher onto a wall. Observe bonds breaking, walls collapsing as expected.

## Order of operations (strict, follow this)

1. Verify rollback is in place (existing solver in production).
2. Commit to clean baseline.
3. Add bond data fields to `DestructibleBlockStructure`.
4. Initialize bonds at structure creation.
5. Add `damage_bonds_in_radius` (no callers yet).
6. Add `_check_bond_connectivity` (GDScript first; C++ if needed later).
7. Wire `damage_bonds_in_radius` into the explosion path.
8. Wire bond breakage into `_damage_block`.
9. Wire bond damage into `take_momentum_damage_at`.
10. Wire bond damage into hitscan path (`_damage_block` already covers it; verify).
11. Switch `_check_structural_integrity` to use bond connectivity (keep stress solver as fallback for now? no — drop entirely).
12. Headless tests pass.
13. Build engine if any C++ touched.
14. User tests with rocket launcher.

## Open questions to resolve as we go

- **Bond strength formula**: starting with `bond_strength = block_hp * 1.5` (just so destruction takes a bit of beating). May need tuning.
- **Explosion bond-damage scale**: explosions already have `structure_damage` value. Bond damage scale = `structure_damage` × some factor. Will tune.
- **Bullet bond-damage**: small. Maybe `damage = block_dmg × 0.5` to bonds touching the hit block. Tune later.
- **Should bonds heal over time?** No — once damaged, stays damaged. Simpler.
- **Replication**: bond damage state needs to sync to clients eventually. Defer for v1; server-only for now.

## Known limitations (acknowledged, not bugs)

- A tall narrow tower with weak materials won't auto-collapse from gravity alone — it requires explicit damage.
- Cantilevers extending too far won't auto-collapse — same reason.
- Cascading damage from falling chunks is not simulated (Smooth Destruction style). Falling chunks don't damage what they land on.

## Definition of done for this session

- [ ] Rollback verified
- [ ] Bond fields added, sized correctly
- [ ] Bonds initialized at structure creation
- [ ] `damage_bonds_in_radius` works in headless test
- [ ] Bond connectivity check finds detached components
- [ ] All three damage paths damage bonds (verified in headless tests)
- [ ] Block destruction cascades to bonds
- [ ] Engine rebuild succeeds (if C++ changed)
- [ ] User tests with rocket launcher and reports satisfactory destruction
