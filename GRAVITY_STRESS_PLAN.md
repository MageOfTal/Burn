# Gravity Stress Solver — Physics Design & Validation Plan

Companion to BOND_GRAPH_PLAN.md. That plan deliberately scoped out gravity ("a
wall can be too top-heavy and stay standing"). This document designs the v2
system that closes the gap: structures must fail under their own weight when
their support is inadequate — including **undamaged** structures built badly —
with no decay timers and no hand-waved "damage over time".

## Why the old solver was wrong (and why the bond model can't do it alone)

- The bond graph is bookkeeping: bonds are HP bars for glue. Nothing ever
  computes load, so gravity cannot participate.
- The rolled-back force-equilibrium solver (`calc_stress_integrity_components`)
  distributes per-block gravity residuals through face contacts with
  compression/tension/shear limits — **forces only, no torque balance, no
  bending moments**. A single block glued to the side of a wall cannot be put
  in torque equilibrium by a point force at its face center: gravity (at the
  block center) and the face force (at the face center, offset h/2) form a
  couple that only a face **moment** can close. Force-only models therefore
  get every cantilever qualitatively wrong.
- Cantilever physics: root bending moment M = w·L²/2 grows with the **square**
  of overhang length; root shear V = w·L grows linearly. Long overhangs fail
  in bending. Any model without moment transfer misses the dominant term.

## Chosen model: quasi-static elastic–brittle interface analysis

Rigid blocks joined by glued-face interfaces, solved to static elastic
equilibrium; interfaces crack when combined stress exceeds strength; cracks
redistribute load (re-solve) until stable — quasi-static brittle fracture.

Why elastic–brittle rather than plastic limit analysis (LP feasibility):
brittle glue does not redistribute plastically. It cracks at the elastic
stress peak, and the crack propagates. First-crack-at-elastic-peak plus
re-solve IS the physically correct failure sequence for this material class,
and it is numerically tractable (SPD linear solve) where the LP is not.

### Degrees of freedom

Each block: 6 DOF — small displacement u ∈ R³ and small rotation θ ∈ R³.
Rotational DOF are **required**: without them a 1-thick cantilever is a
mechanism (singular system), see above.

### Interface element (bond and terrain anchor share it)

Bond between blocks a (owner) and b along unit axis d̂; face center midway,
r_a = +d̂/2, r_b = −d̂/2 (block units, h = 1). Terrain anchors are the same
element on the block's bottom face with the far side fixed (u = θ = 0), so
anchors carry real loads and can be ripped out (top-heavy structures tear
their anchors and topple as rigid bodies — emergent overturning).

Relative face kinematics (linearized):
  δ = (u_b + θ_b × r_b) − (u_a + θ_a × r_a)   — face translation gap
  φ = θ_b − θ_a                               — face rotation gap

Interface wrench (κ = remaining bond fraction, see damage coupling):
  F = κ[k_n (δ·d̂)d̂ + k_s (δ − (δ·d̂)d̂)]      — normal + shear force
  M = κ[k_b (φ − (φ·d̂)d̂) + k_t (φ·d̂)d̂]      — bending + torsion moment

Stiffness ratios from isotropic elasticity of a glue layer of length h,
area h² (only ratios matter for force distribution; E is scale-free):
  k_n = E·A/h = E        k_s = G·A/h ≈ 0.4·E       (ν ≈ 0.25)
  k_b = E·I/h = E/12     k_t = G·J/h ≈ 0.0562·E    (I = h⁴/12, J ≈ 0.1406·h⁴)

### Units

Lengths in blocks (h = 1), forces in block-weights (W = m·g = 1 per block),
moments in W·h. Gravity enters as a unit vector in structure-local frame
(passed in), weight 1 per block, applied at block centers (zero external
torque). Material limits are tunables in block-weights.

### Failure criteria (engineering interaction, per interface)

Edge normal stress on a square face combines axial force and bending
(σ_edge = f_n/A ± m_b/Z, elastic section modulus Z = h³/6 → factor 6 at h=1);
shear combines direct shear and torsion (τ = f_s/A + m_t·c/J → factor 3.556):

  U_tension     = (max(f_n, 0) + 6·m_b) / (κ·T)
  U_compression = (max(−f_n, 0) + 6·m_b) / (κ·C)
  U_shear       = (f_s + 3.556·m_t) / (κ·S)
  U = max of the three; interface breaks when U > 1.

f_n = normal force (tension positive), f_s = |shear force|, m_b = |bending
moment|, m_t = |torsion|. T/C/S are pristine capacities in block-weights.

### Damage coupling (the bond graph feeds the physics)

κ = clamp(1 − bond_damage/bond_strength, 0, 1). Both stiffness (floored at
0.02 for conditioning) and capacity scale with κ — physical: a half-cracked
joint has roughly half the intact area, so it is both softer and weaker.
Consequence: explosions that weaken bonds without breaking them lower what an
overhang can carry, and gravity finishes the job on the next check.

### Solve

Minimize Π = ½xᵀKx − fᵀx ⇒ K x = f. K assembled matrix-free from the
interface elements (12×12 per bond, 6×6 per anchor); SPD on any component
containing an anchor. Solver: preconditioned conjugate gradient, double
precision, block-Jacobi preconditioner (per-block 6×6 inverse — handles the
translation/rotation scale disparity). Blocks not BFS-reachable from an
anchor through intact bonds are excluded (the connectivity check detaches
them; including them would make K singular).

### Break passes (crack propagation)

Loop (cap `max_break_passes`, default 6):
  1. BFS anchored-reachable set; build active DOF + interface lists.
  2. CG solve; recover per-interface (f_n, f_s, m_b, m_t); compute U.
  3. No interface with U > 1 → stable, exit.
  4. Break all interfaces with U > 1; repeat (load redistributes).
Breaking all violators per pass (rather than worst-first) over-breaks
slightly in symmetric ties but converges in few passes and errs toward
spectacle. If the cap is hit, current violators break and the connectivity
check inherits the fallout.

The kernel returns updated bond_broken / anchor_broken copies (same pattern
as damage_bonds_radial_shielded); GDScript adopts them and the EXISTING
connectivity check + cluster detach pipeline handles everything downstream.

## Integration (structures only, v1)

- `_check_structural_integrity`: run the solver **before** the connectivity
  BFS, gated on `GameManager.gravity_stress_enabled` and a dirty flag set by
  any bond/anchor damage, block destruction, or detach. Clear the flag before
  solving; a detach re-dirties and re-queues → progressive collapse spreads
  across frames and terminates (block count strictly decreases).
- Creation-time check: `_deferred_build_foundation` queues an integrity check
  once anchors exist → a freshly spawned structure with bad support collapses
  immediately, no damage required.
- Bug fix folded in: the no-expand foundation path never re-ran
  `_init_anchor_bonds()` after `_build_ground_mask()`, leaving all anchors
  pre-broken from `_ready` (whole structure would detach on first damage).
- Falling clusters: NOT wired (free-falling bodies are in free fall; settled
  clusters rest on contacts, not anchors). Future work.

## Tunables (DestructibleBlockStructure exports)

  stress_tension_blocks     = 90.0   → 1-thick cantilever n_crit = √(T/3) ≈ 5.5
                                       (≈2.7m); 1-thick both-ends-supported roof
                                       span ≈ √(8T/6) ≈ 11 blocks (5.5m). Chosen
                                       so typical existing map geometry survives
                                       the spawn check; drop toward 50 for
                                       harsher realism.
  stress_compression_blocks = 900.0  → pure-compression crush (~10× tension)
  stress_shear_blocks       = 67.5   → 0.75·T (brittle materials)
  solver: max CG iters 2000, rel tol 1e-6, max break passes 6
  (validation tests pass explicit limits, so these defaults are gameplay-only)

## Validation (headless tests, analytic targets)

| Test | Analytic expectation |
|---|---|
| Cantilever root moment | equilibrium exact: m_b(root) = n²/2 W·h (±2%) |
| Cantilever critical length | fails iff 3n² > T; n_crit = √(T/3); test T=50: n=3 stands (U=0.54), n=5 falls (U=1.5) |
| 2-thick cantilever | stands at lengths where 1-thick fails (Z ∝ depth²) |
| Pillar crush | anchor U_c = n/C; C=10: 9 stands, 11 falls; whole pillar detaches |
| Two-leg table | each leg carries ½ slab weight (±5%) |
| Undamaged bad support | pristine 6-block overhang breaks at root on first solve, no damage anywhere |
| Damage coupling | stable 3-overhang; 80% root bond damage (κ=0.2) → U=0.54/0.2>1 → falls |
| Idempotence | stable structure: zero breaks across repeated solves, identical max U |
| Convergence | CG converged flag true in all tests; iteration counts reported |

Plus `bench_gravity_stress.gd`: 320-block wall, ~1.5k hollow tower, 4k solid
cube — report solve ms + CG iters. Perf mitigations if needed (in order):
dirty-gating already limits solve frequency; warm start; 2× aggregation;
async via WorkerThreadPool.
