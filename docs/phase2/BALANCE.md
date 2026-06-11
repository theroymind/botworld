# Phase 2 — balance & tuning

The pinned tuning numbers, curves, and pacing for the phase-2 economy. One of four sibling
docs — `DESIGN.md` (the mechanics these numbers parameterise), `FAILURE.md` (the oxidative-stress
fail-state, which references the ROS/stress constants below by name), and `PRESTIGE.md` (the
fork & seams). The economy is tuned in the headless lab (`tools/phase2_lab.lua`), the way
`../phase1/BALANCE.md` + `tools/sim_lab.lua` back phase 1.

## LOCKED constants

These live in `tools/phase2_lab.lua` DEFAULTS and `lib/layers/complexcell/catalog.lua`,
mirrored **byte-for-byte**, and are what the orchestrator folds from. Any change must update
both together (and add/adjust specs).

```
POWER_PER_MITO    = 10        E_PER_OUTPUT     = 1.0
UPKEEP_PER_MACHINE= 0.25      WASTE_COEF       = 0.0   (penalty carried by upkeep)
BUFFER_BASE       = 5000      BROWNOUT_RESERVE = 0.3
BUFFER_BUILT_REF  = 20000     (cap = BUFFER_BASE*(1+built/REF); ~10x by the FORK)
fuel_factor       = 1.0 (neutral)
mito start        = 1         MITO_BASE  = 25  MITO_GROWTH  = 1.12
                              STAGE_BASE = 20  STAGE_GROWTH = 1.12

PER-STAGE rates (Pillar 1; the "golden ratio"):
  ribosomes 12 · nucleus 6 · er 4 · golgi 6 · transport 8 · membrane 4

ROS pendulum (Pillar 2 — fixed ceiling, no counter-lever):
  BALANCE_LO = 1.0   BALANCE_HI = 1.6   ROS_RATIO_CAP = 3.0
  ROS_RISE = 1/40    ROS_FALL = 1/8     ROS_LETHAL = 0.8   ROS_LETHAL_RISE = 1/30

Imbalance cuts built (Pillar 3):  MIN_EFF = 0.4

Oxidative stress (the deficit failure half):  STRESS_RISE = 1/27  STRESS_FALL = 1/5
```

### Per-stage rates — why these (biology + recipe)

| stage      | rate | biology |
|------------|------|---------|
| ribosomes  | 12 | translation is high-throughput; ribosomes are numerous |
| nucleus    | 6  | transcription is moderate |
| er         | 4  | folding + quality-control — the classic rate-limiter |
| golgi      | 6  | sorting/packaging, moderate |
| transport  | 8  | motor highways move cargo fast |
| membrane   | 4  | export/insertion — a frontier bottleneck |

Throughput is `min(rate * level)`, so you **cannot skip the slow stage**. To keep all caps
equal the level mix is the inverse of the rates (≈ `1 : 2 : 3 : 2 : 1.5 : 3`), a clean
"12:7:3"-style recipe. ER and membrane are the rate-limiters that genuinely pin the line —
bottleneck reading is a live decision, not auto-balanced by "buy the cheapest."

### ROS pendulum — band & curve

- `BALANCE_LO = 1.0` — below it the line can't run fully → brownout + deficit stress.
- `BALANCE_HI = 1.6` — top of the safe headroom band (a loose nod to φ as ideal reserve).
  Between LO and HI is calm. **Fixed constant** — nothing the player buys lifts it.
- Above `BALANCE_HI`, idle respiratory capacity leaks ROS, scaled by how far past the band:
  `leak = clamp((ratio - BALANCE_HI)/(ROS_RATIO_CAP - BALANCE_HI), 0, 1)`,
  with `ROS_RATIO_CAP = 3.0` (3× the needed power = max leak).
- `ros += (leak>0 ? ROS_RISE*leak : -ROS_FALL) * dt`, clamped [0,1]. `ROS_RISE = 1/40`
  (~40s of max surplus to fill), `ROS_FALL = 1/8` (~8s to clear once back in band).
- **Soft then lethal:** `ros` drags the balance scalar (Pillar 3) — felt as falling output
  first. Only when `ros` is sustained above `ROS_LETHAL = 0.8` does it feed the lethal `stress`
  (at `ROS_LETHAL_RISE = 1/30`) — a generous warning window. The lethal/death mechanic these
  feed lives in `FAILURE.md`.

### Cost curves & gates

Geometric (like phase 1):
- stage level: `STAGE_BASE * STAGE_GROWTH ^ level` (`20 * 1.12^level`)
- mitochondrion: `MITO_BASE * MITO_GROWTH ^ (mito-1)` (`25 * 1.12^(mito-1)`)
- stage integration (one-time, to bring a discovered stage online), `STAGE_UNLOCK_COST[id]`:
  `nucleus 150 · er 300 · golgi 300 · transport 800 · membrane 2000`.

`built` gate thresholds (stage unlock order):
`nucleus 50 · er 5000 · golgi 30000 · transport 50000 · membrane 105000 · FORK 180000`.

Gentle (×1.12) cost growth is deliberate: it makes the phase a long climb of *many* small
purchases (a deep catalog) with numbers that keep rising, instead of a geometric wall after
a handful of buys.

## What the lab found (goals → results)

Four policies vs. the real economy (`lua tools/phase2_lab.lua`). The lab drives the **soft**
path (`sim.step`, no lethal-ROS) so it measures pacing + the soft ceilings; the live-only
lethal coupling is verified in the specs.

| goal | result |
|------|--------|
| **Length** ~10–13 min competent | `balanced` reaches FORK in **~10.3 min** (mirrors the catalog spec's end-to-end drive), peak ROS in the warning zone, never lethal ✅ |
| **Forgiving / no brick** | `maxall(floor)` still clears; no policy bricks ✅ |
| **The deficit verb matters** | `throughput!` (chase output, ignore power) sinks into deep brownout, never FORKs — the deficit floor is load-bearing ✅ |
| **The fixed CEILING matters** | `overpower!` (chase power, ignore demand) **stays alive but STALLS** — peak ROS pinned high, build-efficiency floored: idle over-power is never free, and the only fix is to ease off power ✅ |

(Re-run `lua tools/phase2_lab.lua` to refresh the exact per-policy figures — peak ROS, the `maxall`/`overpower!` minutes, the brownout fraction — whenever the catalog or its mirror moves.)

## Reward hooks

- **The ATP cap scales with `built`** so a solved cell never parks permanently at full:
  `buffer_max(built) = BUFFER_BASE * (1 + built / BUFFER_BUILT_REF)` (`BUFFER_BASE = 5000`,
  `BUFFER_BUILT_REF = 20000` → ~10× by the 180k FORK). Pure + state-derived, so online ==
  offline; `BUFFER_BASE` holds every current unlock at `built 0`.
- **The build rate is surfaced.** The headline reads `built  N  (+R /s)`, where
  `R = catalog.build_rate(state)` mirrors the sim's mint byte-for-byte
  (`output * value_mult * efficiency_factor`). Tuning a stage or trimming power moves `R`
  immediately, so the optimisation has a visible, felt payoff.

## Open tuning questions

- Band bounds `BALANCE_LO/HI` and `ROS_RATIO_CAP` — wide enough to forgive, tight enough to
  bite: a modest deliberate reserve should feel safe while a lazy "buy power forever" rush
  clearly stalls.
- ROS rise/fall and `ROS_LETHAL` — confirm the warning window is generous and a hot idle cell
  offline only dims, never dies.
- Re-confirm **balanced play FORKs in ~10–13 min** and **no policy bricks** as the catalog and
  visuals evolve.
- **Per-stage run-cost (`e_per_output[id]`) (deferred).** A slow stage could also be
  power-hungry, layering power-stoichiometry on the throughput one. Ship rate-differentiation
  first and measure before adding.
- Phase-1 unlock pricing carried into phase 2 (Photosynthesis 150 bm / Phagocytosis 2500 bm)
  is first-pass; tune later.
