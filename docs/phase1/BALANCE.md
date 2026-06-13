# Phase 1 — cell layer: balance

The numbers behind the compounding economy ([DESIGN.md](DESIGN.md)) and the failure curve
([FAILURE.md](FAILURE.md)), plus the headless harness that pins them.

**Harness:** `tools/sim_lab.lua` runs the *real* economy modules headless — it loads
`sim` + `metabolism` + `traits` + `organelles`, rebuilds the same `intake` fold `cell.lua`
uses, and measures the exact growth curve any config produces, *before* touching the game.

```
lua tools/sim_lab.lua                          # scenario comparison table
lua tools/sim_lab.lua growth                   # the compounding growth table
lua tools/sim_lab.lua survival                 # the failure curve (toxicity on)
lua tools/sim_lab.lua sweep forage_cap 2 30 4  # one knob across a range
lua tools/sim_lab.lua sweep upkeep_scale 0.5 2 0.25
lua tools/sim_lab.lua curve "maxed colony (synergy)" out.csv   # growth curve -> CSV
```

It reports, per config: **K** (steady-state population), **time-to-50%/90%** of K, and
**peak divisions/min**. Because it loads the real modules, shipped trait synergy comes
through automatically.

**Mirror rule (standing):** every **economy** constant — toxicity, competition, predation,
the growth/synergy knobs in `cell.lua`/`traits.lua` — is mirrored in **both** the game and
the harness, so the lab stays a true regression ref. (The `world.lua` RENDER knobs below —
`MAX_AGENTS`/`RENDER_KNEE`/`RENDER_LOG_SLOPE` — are view-only and live in the game alone;
the headless harness never draws, so it has no copy of them.) Sanity check: the maxed colony
prints `K = 117`; if that number drifts, the harness's copy of the economy constants has
fallen out of sync with the game.

## Locked constants

| Constant | Where | Why this value |
|---|---|---|
| `GROWTH_RATE` (0.1) | `cell.lua` → `sim` `intake.growth_per_cell` | The per-cell compounding rate; sets the ~5-minute sprint to the millions. |
| `TOX_PROD` (0.5/s) | `cell.lua` | Flat dish-fouling rate; deliberately *above* the founder's intrinsic clearance floor so an untended colony is doomed. |
| `TOX_HALF` | `cell.lua` / `sim.health` | Half-throttle point of the health factor `TOX_HALF / (TOX_HALF + toxicity)`; 1 in a clean dish. |
| `TOX_TOLERANCE` (26) | `cell.lua` | Past this `toxicity`, the medium kills cells directly (`TOX_KILL_K`). |
| `TOX_KILL_K` (0.005) | `cell.lua` | Direct cull rate once tolerance is exceeded, down to extinction. |
| `CLEAN_BASE` (0.12) | `traits.lua` | Founder's intrinsic clearance floor, *below* `TOX_PROD` on purpose. |
| `FEED_TOX_CLEAR` | `cell.lua` | Waste a bloom feed flushes — the manual survival lever. |
| `SYN_REACH` (0.06) | `traits.lua` | Strength of the Motility × Chemotaxis reach synergy. |
| `SYN_THRIFT` (0.02) | `traits.lua` | Strength of the Digestion × Evasion thrift synergy. |
| `RENDER_KNEE` (250) | `world.lua` (view-only) | Below this population, draw agents 1:1. |
| `RENDER_LOG_SLOPE` (900) | `world.lua` (view-only) | Agents added per e-fold above the knee. |
| `MAX_AGENTS` (15000) | `world.lua` (view-only) | Hard cap on drawn agents. |
| `ENDO_BASE_CHANCE` / `ENDO_RAMP_PER_STEP` / `ENDO_STEP` (100k) | `cell.lua` | Endosymbiosis proc odds — see [PRESTIGE.md](PRESTIGE.md). |

Per-trait economic constants (`PHOTO_PER`, `CLEAN_PER_PHOTO`, `FORAGE_MOTILITY_PER`,
`SPEED_PER`, `SENSE_PER`, `FORAGE_SENSING_PER`, `CLEAN_PER_DIGESTION`, `DIV_FACTOR`,
`EVASION_K`, `CLEAN_PER_EVASION`) live in `traits.lua` and parameterise the per-pressure
counters mapped in [FAILURE.md](FAILURE.md).

## Spore prestige constants

**Status: in design** — the within-phase Spore loop ([PRESTIGE.md](PRESTIGE.md)) is not yet
built, so these are *placeholder* values to tune, not locked. When the loop ships they live
in a new `spores.lua` (the meta-tree defs + folds) and are **mirrored in the harness** under
the standing mirror rule; `tools/sim_lab.lua` grows a `prestige` mode that replays N
accelerating loops and reports total playtime against the ~15-min budget.

**Earning** — Spores banked on cash-out from health × growth:

```
spores_gained = floor( SPORE_EARN_K · peak_population^SPORE_GROWTH_EXP · vitality_factor )
```

| Constant | Placeholder | Why |
|---|---|---|
| `SPORE_EARN_K` | 1.0 | Payout scalar; dial so loop 1 yields enough to open one branch node. |
| `SPORE_GROWTH_EXP` | 0.5 | The `√` diminishing curve on peak population — makes the *tree*, not grinding one long run, the lever. |
| `SPORE_VITALITY_WEIGHT` | 1.0 | How hard the per-capita vitality band ([FAILURE.md](FAILURE.md)) scales payout — rewards cashing out healthy. |
| `SPORE_LIFETIME_BONUS` | 0.005 | Small always-on global bonus per lifetime Spore earned, so a weak run still counts (the "spent but not wasted" mark). |

**Tree node effects** — multiplicative, permanent across resets; level caps in parens:

| Node (cap) | Constant | Placeholder (per level) |
|---|---|---|
| Photosynthesis (1) | — | unlocks the photosynthesis income channel |
| Photosynthetic Efficiency (5) | `SPORE_PHOTO_EFF_PER` | +0.08 biomass/sec from photosynthesis |
| Flagellar Drive (5) | `SPORE_FLAGELLA_PER` | +0.06 swim speed & forage |
| Chemotactic Reach (5) | `SPORE_CHEMO_PER` | +0.07 sense range |
| Mitotic Speed (5) | `SPORE_MITOSIS_PER` | −0.05 division cost |
| Metabolic Mastery (3, capstone) | `SPORE_METABOLIC_PER` | +0.10 all intake |
| Detox Vacuoles (5) | `SPORE_DETOX_PER` | +0.10 waste cleanup |
| Membrane Integrity (5) | `SPORE_MEMBRANE_PER` | +0.08 evasion |
| Foraging Dominance (5) | `SPORE_FORAGE_DOM_PER` | +0.08 competition counter |
| Homeostasis (3, capstone) | `SPORE_HOMEO_PER` | +0.10 vitality / pressure dampening |
| Engulf (5, gate) | `SPORE_ENGULF_PROGRESS_PER` | +0.15 health & reproduction progress per engulf |
| Mitochondria (5, phase-2 gate) | `ENDO_MITO_PER` | per-level boost to the endosymbiosis chance toward near-certain |

**Costs** — Spore spend per node level:

| Constant | Placeholder | Why |
|---|---|---|
| `SPORE_COST_BASE` | 1 | Cost of the Photosynthesis root (first spend; trivial). |
| `SPORE_COST_GROWTH` | 1.6 | Geometric per-level multiplier within a node (1.5–1.7 band). |
| `SPORE_TIER_MULT` | 10 | Each tier (branch → capstone → Engulf → Mitochondria) ~10× the previous; the capstone wall enforces "master both branches first." |

**Pacing target:** ~5–7 accelerating loops totalling ~15 minutes — first loop ~4–5 min,
decaying toward ~90 s as carried Spores let later climbs blow through the early curve. Tune
`SPORE_EARN_K` / `SPORE_COST_GROWTH` / `SPORE_TIER_MULT` against the harness `prestige` mode.

## Cost curves & gates

- **Per-trait cost** rises with level (standard geometric growth) so each level is a real
  spend and "level everything" stays paced rather than instant.
- **Organelle gates:** the mitochondrion / chloroplast unlock at **350 / 1000**
  lifetime-division thresholds.
- **Endosymbiosis gate:** there is *no* fixed threshold — the run resolves on an RNG proc
  whose odds ramp with colony size, and (once the Spore loop ships) are driven toward
  near-certain by the **Mitochondria** node via `ENDO_MITO_PER` (see [PRESTIGE.md](PRESTIGE.md)
  and the Spore prestige constants below).
- **Spore tree cost:** geometric per level within a node (`SPORE_COST_GROWTH` per level) and
  each tier scaled by `SPORE_TIER_MULT` over the previous, so the path runs Photosynthesis
  (trivial) → branch fill → capstones (steep) → Engulf → Mitochondria. See the Spore prestige
  constants below.
- **Capstone / gate prereqs:** both capstones require their branch **fully maxed**; Engulf
  requires both capstones maxed; Mitochondria requires Engulf maxed (L5).

## Derived tuning

- **Trait synergy — `√(a·b)` shape.** Two pairs multiply, each fully readable and neutral
  at level 0 (so all-zero stats are unchanged and every existing test still passes):
  - **Reach = Motility × Chemotaxis → raises `FORAGE_CAP`.** Mobile, sensing cells reach
    food the colony otherwise outgrew, so the *saturation point itself climbs* — this is
    the important one, attacking the term that pins K.
    `stats.forage_cap_mult = 1 + SYN_REACH·√(motility·sensing)`, and `intake_for` does
    `forage_cap = FORAGE_CAP × forage_cap_mult`.
  - **Thrift = Digestion × Evasion → extra upkeep cut.** A lean, efficient cell wastes
    less; lowers K's denominator. Folded into `stats.upkeep_mult`:
    `÷ (1 + SYN_THRIFT·√(digestion·evasion))`.

  The `√(a·b)` shape rewards *balanced* investment (a one-trait spike gets little) — the
  "synergy" feel. Gentle by design: it buys ~20–35% and, more importantly, gives leveling a
  reason to continue past "all maxed." Bump `SYN_REACH` in `traits.lua` and re-run the
  harness to make it carry more weight.

- **Render log-sampling.** A millions-cell colony would be an unreadable blur, so
  `world.sample_count(pop)` draws 1:1 up to `RENDER_KNEE` (250), then adds `RENDER_LOG_SLOPE`
  (900) agents per natural-log e-fold, capped at `MAX_AGENTS` (15000): ~1498 dots at 1k,
  ~3993 at 16k, ~7715 at 1M. The dish keeps visibly filling but stays readable. All three
  constants are view-only (`world.lua`, never the harness) and meant to be tuned by eye in
  play.

## What the lab found

**The compounding growth table** (maxed, `GROWTH_RATE` 0.1) — reproduced by
`lua tools/sim_lab.lua growth` from the real `sim.step`:

| time | colony |
|---|---|
| 30 s | ~950 |
| 1 min | ~3k |
| 2 min | ~16k |
| 5 min | ~1.3M |

- **Phase 1 is a ~5-minute sprint** — population climbs exponentially into the low millions
  rather than walling at a carrying capacity.
- **Time-to-K / the maxed colony** prints `K = 117` (the mirror-rule sanity number).
- **Survival pacing:** an untended founder collapses in ~90s
  (`lua tools/sim_lab.lua survival`); feeding or ~2 cleanup levels keep it alive; a built
  colony thrives. See [FAILURE.md](FAILURE.md) for the failure model these numbers tune.

## Open tuning questions

- **Organelle gates.** The 350 / 1000 lifetime-division gates were set against an older
  curve; check they still pace well now that the economy compounds (use the harness `curve`
  mode to read time-to-K).
- **Synergy surfacing (UI).** Show synergy as its own panel rows, or as live deltas on the
  existing trait rows when a partner is leveled? (Economy is done; this is presentation
  only — e.g. a "reach +X% (Motility × Chemotaxis)" line updating live.)
