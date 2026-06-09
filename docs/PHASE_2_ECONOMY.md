# Phase 2 — economy model (implementation spec)

Working spec for the phase-2 closed-form economy, 2026-06-08. Turns the prose in
`docs/PHASE_2.md` into concrete math we can put numbers to in a headless lab —
the same way `docs/CELL_GROWTH.md` + `tools/sim_lab.lua` back phase 1.

This is the **target the lab tunes against**. Constants here are first guesses;
the lab (`tools/phase2_lab.lua`) is where they get pinned.

## The shape (mirrors phase 1's architecture)

- **`lib/layers/complexcell/sim.lua`** — the pure, deterministic, closed-form
  economy. No `love.*`, no RNG. One `sim.step(state, dt, rates)` shared by live
  tick + offline, exactly like the cell layer. The internal swarm (organelles,
  ribosomes, vesicles, motors) is a **cosmetic skin** over this — never the
  source of truth (so offline progress holds).
- The orchestrator folds levels/counts into a **`rates`** table (the analogue of
  phase 1's `intake`); `sim.step` only ever sees `rates`.

## Currency & state

- **ATP / energy** is the single currency: net energy/sec banks into a buffer;
  every upgrade is bought with banked energy.
- **`built`** is the headline growth number — cumulative structure the assembly
  line has produced ("growth is detail"). Drives swarm density and the
  progression gates. Monotonic, like phase-1 `total_divisions`.

`state` = `{ energy, built, mito, stages = {id->level}, unlocked = {id->true} }`.
`mito` starts at **1** (the bacterium engulfed at the phase-1 finale — the first
power plant carried across the seam).

## The pipeline (the bottleneck verb)

Ordered stages, each with an integer `level` and a per-level rate `stage_rate`:

```
ribosomes → nucleus → ER → Golgi → transport → membrane
```

- **Throughput** `T = min over UNLOCKED stages of (stage_rate[s] * level[s])`.
  Output is capped by the **slowest stage**. The skill is reading the bottleneck
  and feeding *that*.
- **Excess** `X = Σ over unlocked stages of max(0, stage_rate[s]*level[s] - T)`
  — capacity built above the bottleneck. Idle, backed-up machinery.

`ribosomes` is unlocked at start (so output > 0 from t=0). The rest unlock as
`built` crosses gate thresholds — these are the **science-ordered named beats**
(Nucleus, Endomembrane = ER+Golgi, Cytoskeleton = transport, Membrane/Genome). The names
here are the internal stage ids; for the player-facing labels these surface as (ER (Folding),
Golgi (Packing), Cytoskeleton (Delivery), Membrane (Wall)) see the glossary in
`docs/PHASE_2.md` → "Player-facing language."

## The fold → `rates`

The orchestrator/lab computes, from state + constants:

```
power      = POWER_PER_MITO * mito * fuel_factor   -- gross ATP/sec
throughput = min over unlocked (stage_rate[s] * level[s])
excess     = Σ max(0, stage_rate[s]*level[s] - throughput)
upkeep     = UPKEEP_PER_MACHINE * (mito + Σ level[s])   -- energy-per-gene idle cost
```
plus pass-through constants `WASTE_COEF`, `E_PER_OUTPUT`, `BUFFER_MAX`.

`fuel_factor` is the **plant/animal mix** parameter — neutral baseline **1.0**
through the whole phase; the end-of-phase fork slams it to a pole. One economy to
tune; the fork is one knob on top.

## The step (the closed form) — as built & tuned

```
avail = power - upkeep - WASTE_COEF * excess      -- ATP/sec free to run the line
T     = throughput ;  e = E_PER_OUTPUT ; cost_full = e * T
if avail >= cost_full then            -- fully powered: O = T, the surplus banks
  O = T
elseif avail > 0 then                 -- underpowered: THROTTLE (brownout), but hold
  O = (avail / e) * (1 - BROWNOUT_RESERVE)   -- back a reserve so net stays POSITIVE
else                                  -- power can't cover upkeep: line stops
  O = 0
end
N = avail - e * O                     -- net ATP/sec (>0 in a reserved brownout)
state.energy = clamp(state.energy + N*dt, 0, BUFFER_MAX)
state.built  = state.built + O*dt
state.output = O                      -- readout for the view (swarm intensity)
state.brownout = (O < T - 1e-9)       -- power deficit tell
```

**The buffer is a pure SAVINGS account** — it grows from net ATP and shrinks only
when the orchestrator spends it on upgrades; it is *never* drained to prop up an
over-built line. **A brownout reserves a slice of power** (`BROWNOUT_RESERVE`) for
the buffer, so net stays positive in a deficit and the cell always banks its way
back to the mitochondrion that fixes it. (Two earlier models — draining the buffer
to sustain over-capacity, and running output at exactly `avail/e` — both pinned net
energy at zero and created an *unrecoverable death-spiral*; that broke the
forgiveness pillar, so both were removed in favor of the savings + reserve model.)

The **surplus** you spend on upgrades is `avail - e*T` when fully powered. To make
progress, power must exceed upkeep + assembly cost. More machines → more upkeep →
less surplus → must build more mitochondria. **That power-vs-throughput balance is
the verb** — the energy-per-gene self-regulation, stated as math.

**Self-defeating overbuild = idle-machine upkeep.** Over-level a non-bottleneck
stage and you pay its buy-cost *and* ongoing upkeep for **zero** throughput gain
(it's above the bottleneck) — pure loss, dominated by feeding the bottleneck or
buying power. This carries the penalty without an explicit waste term: `WASTE_COEF`
is shipped at **0** because measuring excess against the global bottleneck made it
spike catastrophically at every gate-unlock (a new level-1 stage briefly makes all
prior capacity "excess"). The sim still supports `waste_coef` for a future,
non-spiking imbalance penalty if playtest wants more bite.

**Readouts** still map to the flow language: `excess>0` on a stage = **congestion**;
a stage below another's cap = **vacancy** downstream; `brownout` = the dimming power
deficit (now meaningful — see the `throughput!` trap below).

## Costs (spending energy) — orchestrator/catalog, not sim

Geometric, like phase 1 (`COST_GROWTH`):
- stage level: `STAGE_BASE * STAGE_GROWTH ^ level`
- mitochondrion: `MITO_BASE * MITO_GROWTH ^ (mito-1)`

The self-revealing catalog (reveal at ~50% banked) is **UI only** — it does not
touch the economy. The lab ignores it.

## LOCKED constants (tuned in the lab, 2026-06-08)

These live in `tools/phase2_lab.lua` DEFAULTS and are the values the first-draft
orchestrator should fold from:

```
POWER_PER_MITO    = 10        E_PER_OUTPUT     = 1.0
UPKEEP_PER_MACHINE= 0.25      WASTE_COEF       = 0.0   (penalty carried by upkeep)
BUFFER_MAX        = 5000      BROWNOUT_RESERVE = 0.3
fuel_factor       = 1.0 (neutral)
stage_rate (all)  = 5         STAGE_BASE = 20  STAGE_GROWTH = 1.12
mito start        = 1         MITO_BASE  = 25  MITO_GROWTH  = 1.12
```
`built` gate thresholds (unlock order): `nucleus 50 · er 200 · golgi 200 ·
transport 600 · membrane 1500 · FORK 50000`.

Gentle (×1.12) cost growth is deliberate: it makes the phase a long climb of *many*
small purchases (a deep catalog, ~300 buys) with numbers that keep rising, instead
of a geometric wall after a handful of buys.

## What the lab found (goals → results)

| goal | result |
|---|---|
| **Length** ~10–15 min competent | `balanced` reaches FORK in **10.3 min** ✅ |
| **Forgiving / no brick** | `maxall` floor also clears (~10.3 min); even the `throughput!` trap never bricks ✅ |
| **The verb matters** | `throughput!` (chase output, ignore power) sinks to **99% brownout** and never reaches FORK — power-vs-throughput balance is load-bearing ✅ |
| **Deep catalog, climbing numbers** | ~**300** purchases; throughput climbs past **145**, built ~275k by 30 min ✅ |
| **Brownout reachable & recoverable** | trips on under-power, recovers via the reserve; sensible play sits ~0–1% ✅ |
| **Legible knobs** | `UPKEEP 0.15→0.45` ⇒ FORK 9.4→13.2 min; `POWER 8→14` ⇒ FORK 15.9→7.3 min (monotone) ✅ |

The lab drives buyer **policies** against the real `sim.step`: `balanced` (good
play), `throughput!` (the trap), `maxall` (the floor). Run `lua tools/phase2_lab.lua`.

## Known open tuning task (post-first-draft)

With **uniform** stage rates/costs, the only load-bearing decision is power vs.
throughput; "buy the cheapest" already keeps the pipeline balanced, so reading
*which stage* is the bottleneck doesn't yet matter. **Differentiating stage rates
and/or costs** (a real ER ≠ a real ribosome) would make inter-stage bottleneck
reading a genuine decision and deepen the verb. Deferred — it's a depth refinement,
not a blocker for a playable first draft.
