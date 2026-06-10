# Phase 2 — economy model (implementation spec)

Working spec for the phase-2 closed-form economy, 2026-06-08. Turns the prose in
`docs/PHASE_2.md` into concrete math we can put numbers to in a headless lab —
the same way `docs/CELL_GROWTH.md` + `tools/sim_lab.lua` back phase 1.

This is the **target the lab tunes against**. Constants here are first guesses;
the lab (`tools/phase2_lab.lua`) is where they get pinned.

> **Balance & biology redesign — LANDED (see `docs/PHASE_2_BALANCE.md`).** The
> redesign proposed in that doc is now implemented in the pure core. It supersedes
> three decisions below, folded into this spec:
> 1. **Per-stage rates (Pillar 1).** Uniform `STAGE_RATE = 5` is gone; each stage
>    carries a distinct per-level capacity (a real recipe ratio). Single lookup
>    point: `catalog.stage_rate(id)`.
> 2. **The ROS pendulum (Pillar 2).** Oxidative stress is now two-sided: idle
>    over-power leaks reactive oxygen species (`ros` ∈ [0,1]) — a real ceiling, not
>    just the deficit floor. A buyable **stabilization** track (`state.stab`) is the
>    counter-lever (raise the safe ceiling + speed ROS clearance).
> 3. **Balance cuts real output (Pillar 3).** The efficiency scalar is no longer
>    cosmetic: it peaks inside a band, falls off BOTH sides, and multiplies minted
>    `built` (down to `MIN_EFF`). The ATP cost `e*O` is unchanged, so the
>    brownout/stress closed form is untouched — only the reward bends.
>
> The constants, fold, and the shared `sim.balance_scalar` math are mirrored
> byte-for-byte across `catalog.lua`, `tools/phase2_lab.lua`, and the LOCKED table
> below. The "Known open tuning task" at the bottom (uniform rates) is now CLOSED.

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

-- THE ROS PENDULUM (Pillar 2) -- integrated FIRST so the built cut below sees it.
demand    = e*T + upkeep
ratio     = power / demand                                   -- the balance ratio
leak      = clamp((ratio - BALANCE_HI_eff)/(ROS_RATIO_CAP - BALANCE_HI_eff), 0, 1)
ros      += (leak>0 ?  ROS_RISE*leak  :  -ROS_FALL*stab_clear) * dt   -- clamp [0,1]

-- THE BALANCE SCALAR (shared by sim + catalog.efficiency, byte-for-byte):
flow_balance  = T>0 ? T/(T+excess) : 0
power_balance = 1                              if BALANCE_LO <= ratio <= BALANCE_HI_eff
              = ratio / BALANCE_LO             if ratio < BALANCE_LO     (deficit slope)
              = 1 - leak                       if ratio > BALANCE_HI_eff (surplus slope)
balance       = flow_balance * power_balance * (1 - ros)     -- clamp [0,1]

-- PILLAR 3: balance cuts real output. The ATP cost (e*O) above is UNCHANGED.
efficiency_factor = MIN_EFF + (1 - MIN_EFF) * balance
state.built  = state.built + O * value_mult * efficiency_factor * dt
state.output = O                      -- readout for the view (swarm intensity)
state.brownout = (O < T - 1e-9)       -- power deficit tell

-- LETHAL coupling (LIVE ONLY -- the forgiveness guard, set by sim.tick, NOT sim.offline):
if lethal_ros and ros > ROS_LETHAL:  stress += ROS_LETHAL_RISE * (ros-ROS_LETHAL)/(1-ROS_LETHAL) * dt
-- plus the existing deficit half (stress_rise*severity); decays at stress_fall when calm.
```

`BALANCE_HI_eff = BALANCE_HI + STAB_TOLERANCE * stab` and
`stab_clear = 1 + STAB_CLEAR * stab` — the **stabilization** counter-lever. `stab`
also counts as a machine in `upkeep` (it has a running cost).

**The ROS pendulum is the missing ceiling.** Idle over-power (ratio past
`BALANCE_HI_eff`) leaks `ros`, which (a) drags `built` via the balance scalar — the
**soft cut**, felt as falling output before anything dies — and (b) only when
*sustained* past `ROS_LETHAL` feeds the existing lethal `stress`. **Soft first, lethal
only on extreme, sustained imbalance.**

**Forgiveness guard (online/offline divergence — intentional).** The surplus-ROS
lethal term accrues **live only**: `sim.tick` sets `rates.lethal_ros`; `sim.offline`
does not. So a hot cell left running offline only **dims** (the soft cut, which IS
shared and deterministic) and can never **lyse** from idle surplus while you are away.
The soft built-cut and the `ros` integral are byte-identical online vs offline; only
the lethal tail differs. The deficit half keeps its existing recoverable-by-reserve
guarantee in both paths. Everything else stays deterministic (no rng).

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
- stabilization: `STAB_BASE * STAB_GROWTH ^ stab` (steeper — it is potent)
- stage *integration* (one-time, to bring a discovered stage online):
  `STAGE_UNLOCK_COST[id]` — `nucleus 150 · er 300 · golgi 300 · transport 800 ·
  membrane 2000`.

The self-revealing catalog (reveal at ~50% banked) is **UI only** — it does not
touch the economy. The lab ignores it.

## LOCKED constants (tuned in the lab, 2026-06-09 — balance & biology redesign)

These live in `tools/phase2_lab.lua` DEFAULTS and `lib/layers/complexcell/catalog.lua`,
mirrored byte-for-byte, and are the values the orchestrator folds from:

```
POWER_PER_MITO    = 10        E_PER_OUTPUT     = 1.0
UPKEEP_PER_MACHINE= 0.25      WASTE_COEF       = 0.0   (penalty carried by upkeep)
BUFFER_MAX        = 5000      BROWNOUT_RESERVE = 0.3
fuel_factor       = 1.0 (neutral)
mito start        = 1         MITO_BASE  = 25  MITO_GROWTH  = 1.12
                              STAGE_BASE = 20  STAGE_GROWTH = 1.12
                              STAB_BASE  = 60  STAB_GROWTH  = 1.18

PER-STAGE rates (Pillar 1; the "golden ratio"):
  ribosomes 12 · nucleus 6 · er 4 · golgi 6 · transport 8 · membrane 4

ROS pendulum (Pillar 2):
  BALANCE_LO = 1.0   BALANCE_HI = 1.6   ROS_RATIO_CAP = 3.0
  ROS_RISE = 1/40    ROS_FALL = 1/8     ROS_LETHAL = 0.8   ROS_LETHAL_RISE = 1/30
  STAB_TOLERANCE = 0.15   STAB_CLEAR = 0.5

Imbalance cuts built (Pillar 3):  MIN_EFF = 0.4

Oxidative stress (the deficit failure half):  STRESS_RISE = 1/27  STRESS_FALL = 1/5
```
`built` gate thresholds (unlock order): `nucleus 50 · er 5000 · golgi 30000 ·
transport 50000 · membrane 105000 · FORK 180000`.

Gentle (×1.12) cost growth is deliberate: it makes the phase a long climb of *many*
small purchases (a deep catalog) with numbers that keep rising, instead of a
geometric wall after a handful of buys.

## What the lab found (goals → results, 2026-06-09)

Five policies vs. the real economy (`lua tools/phase2_lab.lua`). The lab drives the
**soft** path (`sim.step`, no lethal-ROS) so it measures pacing + the soft ceilings;
the live-only lethal coupling is verified in the specs.

| goal | result |
|---|---|
| **Length** ~10–13 min competent | `balanced` reaches FORK in **11.8 min**, peak ROS **0.42** (warning zone, never lethal) ✅ |
| **Forgiving / no brick** | `maxall` floor still clears (**20.3 min**); no policy bricks ✅ |
| **The deficit verb matters** | `throughput!` (chase output, ignore power) sinks to **100% brownout**, never FORKs — the deficit floor is load-bearing ✅ |
| **The new CEILING matters** | `overpower!` (chase power, ignore demand) **stays alive but STALLS** at **20.1 min** — peak ROS **1.0**, build-efficiency floored at **0.0**: idle over-power is no longer free ✅ |
| **Stabilization is a real lever** | `stabilized` (defend a surplus with the counter-lever) FORKs in **11.2 min** with **9** stab levels, holding peak ROS to **0.06** — a legitimate alternative strategy, not a tax ✅ |
| **Legible knobs** | `POWER 9→13` ⇒ FORK 12.4→13.5 min with the ROS ceiling biting at the high end (the band is visible in pacing) ✅ |

## Closed: the uniform-stage tuning task (resolved by Pillar 1)

The original open task — *uniform stage rates make "buy the cheapest" auto-balance the
pipeline, so reading which stage is the bottleneck doesn't matter* — is **closed**.
Pillar 1 gives every stage a distinct per-level rate (`ribosomes 12 · nucleus 6 · er 4 ·
golgi 6 · transport 8 · membrane 4`), so the level mix that equalises every stage's cap
is the inverse of the rates (≈ `1 : 2 : 3 : 2 : 1.5 : 3`). The slow stage (ER, membrane)
genuinely pins the line and must be read and fed — bottleneck reading is now a live
decision, and `er`/`membrane` are the biological rate-limiters that bite.

## Known open tuning tasks (post-redesign)

- **Oxygen as a managed input (deferred).** The oxygen/respiration gauge ships as a
  *displayed* metric only (proposal §7). Turning it into a real managed input is a
  natural extension that maps onto the plant/animal fork (`fuel_factor`) — noted, not
  scheduled.
- **Per-stage run-cost (`e_per_output[id]`) (deferred).** A slow stage could also be
  power-hungry, layering a power-stoichiometry on the throughput one (proposal §3
  optional depth). Ship rate-differentiation first and measure before adding.
- **Stabilization vs. matching power — long-run A/B.** Both `balanced` (~11.8 min) and
  `stabilized` (~11.2 min) clear cleanly today; watch playtest for whether the
  defended-surplus path wants a cost nudge so neither strictly dominates.
