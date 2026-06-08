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
(Nucleus, Endomembrane = ER+Golgi, Cytoskeleton = transport, Membrane/Genome).

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

## The step (the closed form)

```
avail = power - upkeep - WASTE_COEF * excess      -- ATP/sec free to run the line
T     = throughput
e     = E_PER_OUTPUT
cost_full = e * T
if avail >= cost_full then            -- fully powered: surplus banks
  O = T
elseif state.energy > 0 then          -- draw the buffer to sustain (brownout pending)
  O = T
else                                  -- buffer empty: power-limited
  O = max(0, avail / e)
end
N = avail - e * O                     -- net ATP/sec
state.energy = clamp(state.energy + N*dt, 0, BUFFER_MAX)
state.built  = state.built + O*dt
state.output = O                      -- readout for the view (swarm intensity)
state.brownout = (O < T - 1e-9)       -- power deficit tell
```

The **surplus** you spend on upgrades is `avail - e*T` when fully powered. To make
progress you need surplus > 0 → power must exceed upkeep + waste + assembly cost.
More machines → more upkeep → less surplus → must build more mitochondria. That
is the energy-per-gene self-regulation, stated as math.

**Self-defeating overbuild:** leveling a non-bottleneck stage raises `excess` →
raises `waste` → cuts surplus, with no gain to `T`. Linear benefit (only the
bottleneck stage raises T), super-linear-feeling cost (waste compounds with every
mismatched level). The phase-1 dial trap, re-shaped as flow balance.

**Readouts** map straight to the doc's flow language: `excess>0` on a stage =
**congestion**; a stage at capacity below another's = **vacancy** downstream;
`brownout` = the dimming power deficit.

## Costs (spending energy) — orchestrator/catalog, not sim

Geometric, like phase 1 (`COST_GROWTH`):
- stage level: `STAGE_BASE * STAGE_GROWTH ^ level`
- mitochondrion: `MITO_BASE * MITO_GROWTH ^ (mito-1)`

The self-revealing catalog (reveal at ~50% banked) is **UI only** — it does not
touch the economy. The lab ignores it.

## First-guess constants (the lab pins these)

```
POWER_PER_MITO    = 10        E_PER_OUTPUT   = 1.0
UPKEEP_PER_MACHINE= 0.5       WASTE_COEF     = 0.3
BUFFER_MAX        = 200       fuel_factor    = 1.0 (neutral)
stage_rate (all)  = 5         STAGE_BASE=20  STAGE_GROWTH=1.5
mito start        = 1         MITO_BASE =30  MITO_GROWTH =1.6
```
`built` gate thresholds (unlock order, first guess):
`nucleus 50 · er 200 · golgi 200 · transport 600 · membrane 1500 · FORK 4000`.

## What the lab must answer (tuning goals)

1. **Skill is rewarded:** a *feed-the-bottleneck* buyer reaches the FORK gate
   meaningfully faster than a *max-everything* buyer.
2. **Forgiving / clearable without the panel:** the naive max-everything buyer
   still reaches FORK — slower (target ~1.5–2×), never hard-stuck. (The
   anti-overwhelm hard rule: any phase clearable without tuning.)
3. **Length:** a competent player reaches FORK in ~**10–15 min** active (phase 2
   is deeper than phase-1's ~5-min sprint), and idle (positive surplus, walk
   away) keeps `built` climbing.
4. **Brownout is reachable and recoverable:** overbuilding into a power deficit
   triggers `brownout`, and buying mitochondria pulls back out.

The lab simulates buyer **policies** against the real `sim.step` and prints
time-to-each-gate, final built, peak output, and brownout incidence per policy —
then sweeps the constants above to hit the goals.
