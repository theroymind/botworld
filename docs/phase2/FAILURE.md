# Phase 2 — failure (oxidative stress → lysis)

The phase-2 fail-state: a two-sided **oxidative stress** model. A sustained **power deficit**
(brownout) *or* sustained **idle over-power** drives a lethal `stress` term; when it crosses
its threshold the cell **lyses** — a real, terminal fail-state. This is a deliberate
**departure from the master no-fail pillar** (see `../../GAME_PLAN.md`), in the same spirit as
phase 1: the economy itself can kill you if you stop reading it.

The *soft* side of this pendulum — the ROS pendulum and the balance scalar that quietly cuts
output before anything dies — lives in `DESIGN.md` (the economy spec); this doc owns the
**lethal tail**. Tuning constants are named here and **valued in `BALANCE.md`**; companion
docs are `DESIGN.md`, `BALANCE.md`, and `PRESTIGE.md`.

## The pressures (two sides of the pendulum)

Oxidative stress is **two-sided** — both a deficit *and* idle over-power damage the cell. Each
side has a distinct shape:

- **Deficit / brownout (too little power).** When gross power can't cover upkeep + assembly
  cost, the line throttles (`brownout`) and net energy falls. Sustained, this is the
  power-deficit half: the cell is starving. *Recoverable by reserve* — a brownout always
  reserves a slice of power (`BROWNOUT_RESERVE`) so net stays positive and the cell can bank
  its way back to the mitochondrion that fixes it (the no-death-spiral guarantee, see the
  savings model in `DESIGN.md`).
- **Surplus / ROS (too much idle power).** Biology: mitochondria respiring with high membrane
  potential but low ATP demand (resting "state-4") leak electrons producing **reactive oxygen
  species (ROS)** — idle over-capacity literally damages the cell. When the balance `ratio`
  runs past `BALANCE_HI`, `ros` ∈ [0,1] accrues; only when `ros` is *sustained* past
  `ROS_LETHAL` does it feed the lethal term. The safe-power ceiling is **fixed** — nothing the
  player buys lifts it; the only fix for running hot is to ease off power.

## The master quantity (lethal `stress`)

A single closed-form `stress` decides the run. It accrues from **both** halves and decays when
the cell is calm; death fires when it crosses the lethal threshold:

```
-- deficit half (always live): accrues with brownout severity
stress += STRESS_RISE * severity * dt

-- surplus half (LIVE ONLY -- the forgiveness guard, see below):
if lethal_ros and ros > ROS_LETHAL:
  stress += ROS_LETHAL_RISE * (ros - ROS_LETHAL) / (1 - ROS_LETHAL) * dt

-- decay when calm:
stress -= STRESS_FALL * dt        -- when neither side is pressing
-- death when stress crosses the lethal threshold -> lysis
```

The surplus half only engages once `ros` is sustained above `ROS_LETHAL` — a generous warning
window: output has already visibly fallen (the soft cut, `DESIGN.md`) long before the lethal
term turns on. **Soft first, lethal only on extreme, sustained imbalance.** Constants
(`STRESS_RISE`, `STRESS_FALL`, `ROS_LETHAL`, `ROS_LETHAL_RISE`) are defined in `BALANCE.md`.

## Readouts (problem, not fix)

The player sees failure coming on the **vitals strip** — three gauges they act on:
**power balance · cell stress · efficiency.** No new knobs; readouts only (anti-overwhelm).

- **BROWNOUT** line → "not enough power, production slowed" — the deficit tell, shown the
  moment `brownout` is set.
- The **dying** warning and the **lysis** toast *state the problem only, never the fix* — the
  player reads the vitals and picks the lever. They name **which side** of the balance drove
  it:
  - deficit: **"LOW POWER — the cell is dying"**; on death **"The cell burst — low power."**
  - surplus: **"POWER OVERLOAD — the cell is dying"**; on death **"… power overload."**

These warning strings are the source of truth for failure copy (the broader display-copy rule
lives in `DESIGN.md` "Player-facing language", which points here for the death/lysis lines).

## The counters

No pressure is unanswerable; each side has a clear lever:

- **Deficit →** ease the load or **build a mitochondrion** (more power), or **feed the
  bottleneck** so power isn't wasted on idle stages.
- **Surplus →** **ease off power** — the ceiling (`BALANCE_HI`) is fixed, so the only fix for
  running hot is to stop overbuying mitochondria. ROS then clears at `ROS_FALL`.

## Determinism & offline contract

The **forgiveness guard** is an intentional online/offline divergence:

- The **surplus-ROS lethal term accrues live only.** `sim.tick` sets `rates.lethal_ros`;
  `sim.offline` does not. A hot cell left running offline only **dims** (the soft cut, which
  IS shared and deterministic) and can never **lyse** from idle surplus while away.
- The **soft built-cut and the `ros` integral are byte-identical** online vs offline; only the
  lethal tail differs.
- The **deficit half keeps its recoverable-by-reserve guarantee in both paths** — the reserve
  keeps net positive in a deficit, so the cell can never enter an unrecoverable death-spiral
  online or offline.
- Everything else stays deterministic (no RNG).

The lab drives the **soft** path (`sim.step`, no lethal-ROS) so it measures pacing and the
soft ceilings; the live-only lethal coupling is verified in the specs (see `BALANCE.md` "What
the lab found").

## Open decisions

- ROS rise/fall and `ROS_LETHAL` — confirm the warning window is generous and a hot idle cell
  offline only dims, never dies (a tuning watch tracked in `BALANCE.md`).
- Whether the deficit half ever wants its own offline forgiveness, or the reserve guarantee is
  sufficient on its own.
