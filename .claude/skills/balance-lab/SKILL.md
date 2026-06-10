---
name: balance-lab
description: Run and interpret the cell-layer balance harness (tools/sim_lab.lua) and port a tuning change across its mirrored files safely. Use for any cell-economy balancing — running the lab, sweeping a knob, tuning the toxicity / competition / predation / growth pressures, or changing any constant that affects carrying capacity K, survival/extinction timing, or the time-to-1M phase-1 exit.
---

# Cell-layer balance lab

`tools/sim_lab.lua` is a headless (no love2d) harness over the **pure** cell economy
(`lib/layers/cell/sim.lua` + `metabolism` + `traits` + `organelles`). It rebuilds the same
`intake` fold `cell.lua` runs on, so it measures the *exact* curve a config produces and lets
you A/B a tuning change before touching the game.

This file is the **map and the cross-file discipline** — not the mechanics. The lab's own
top-of-file comments and per-constant notes are the source of truth for *why* each value is
what it is, and they drift constantly (re-tune notes are dated inline). **Never copy constant
values or numeric targets into this skill** — read them from source, and read PASS/FAIL from
the lab's own printed output. If you find yourself wanting to quote a number here, link to the
file instead.

## Modes — run from the repo root

```bash
lua tools/sim_lab.lua                          # scenario table: K, t->50%, t->90%, peak/min per build
lua tools/sim_lab.lua sweep <param> lo hi step # how one DEFAULTS param (forage_cap/upkeep_scale/photo_light) moves K
lua tools/sim_lab.lua curve <scenario> [out.csv]   # full pop/rate/biomass curve for one scenario (stdout or CSV)
lua tools/sim_lab.lua growth                    # compounding climb + time-to-1,000,000 at several GROWTH_RATE values
lua tools/sim_lab.lua survival                  # EMERGENT failure (tox+comp+pred ON): extinction timing, co-dominance check, time-to-1M race
lua tools/sim_lab.lua counters                  # each trait vs ITS pressure in isolation (LOW vs HIGH counter build)
lua tools/sim_lab.lua survsweep <KNOB> lo hi step  # sweep one pressure knob on a knife-edge ref build -> time-to-extinction
```

`<scenario>` names come from the `SCENARIOS` table (run with no args to see them — e.g.
`"maxed colony (synergy)"`). `survsweep <KNOB>` knobs are the `SWEEPABLE` set near the bottom
(`COMP_*`, `PRED_*`, `TOX_KILL_K`, `TOX_TOLERANCE`); run it with a bad knob to print the list.

`sweep` mutates a per-config `DEFAULTS` field; `survsweep` mutates a module-level pressure
constant in-process for the sweep only — neither writes anything back. To make a change stick
you port it by hand (below).

## The mirror set — the #1 footgun

The pressure/economy constants are **duplicated by hand across three files**, and the lab only
warns you about it once you're already reading it. Changing balance means changing **all the
places a constant lives**, then running the spec:

| File | Role |
|---|---|
| `lib/layers/cell.lua` | **Source of truth** — the shipped game. Some are tagged `[lab-locked]` (the lab found them; don't drift them casually). |
| `tools/sim_lab.lua` | The harness — mirrors cell.lua so its numbers equal the game's. |
| `tests/cell_pressures_spec.lua` | Re-implements the pressure formulas with the constants inlined at the top; the regression guard. |

Mirrored groups: toxicity (`TOX_PROD/HALF/TOLERANCE/KILL_K`, `FEED_*`), growth (`GROWTH_RATE`),
economy defaults (`FORAGE_CAP/UPKEEP_SCALE/PHOTO_LIGHT`), competition (`COMP_FRAC_MAX/TAU/
COUNTER_GAIN/MOTILITY_COUNTER`), predation (`PRED_BASE/RAMP/TAU/MAX/EVASION_GAIN/MIT_CAP/FEAR`,
`FEAR_FLOOR`). **Before editing any of these, grep the name across all three files and update
every hit** — a value that exists in cell.lua but not the lab silently makes the lab lie:

```bash
grep -rn 'PRED_FEAR' lib/layers/cell.lua tools/sim_lab.lua tests/cell_pressures_spec.lua
```

## Tuning loop

1. **Read** — pick the mode that answers the question (`survsweep`/`sweep` to find a winning
   value; `survival`/`counters`/`growth` to judge an outcome).
2. **Port** — write the winner into **cell.lua first** (source of truth), then mirror into the
   lab and the spec via the grep above. Each constant keeps a comment on *why* that value.
3. **Verify** — `make test` (runs `cell_pressures_spec` among others). stylua/luacheck fire on
   save via the hook; don't run them by hand.
4. **Confirm** — re-run the lab mode and check its printed **PASS/FAIL** line, not a number you
   remembered.

## Reading the output

- `survival` prints a **co-dominance check** for the neglected founder (no single death source
  may dominate) and a **time-to-1M race** — both label themselves PASS/FAIL or
  survives/spirals/plateaus. Trust that line.
- `counters` prints a **toxicity-alone extinction** band check and proves each trait
  (digestion→toxicity, evasion→predation, sense+motility→competition) outlasts its pressure.
- Toxicity is the only solo-lethal pressure (it reaches literal extinction); predation and
  competition alone are survivable by design, so their counters read as a higher trough / a
  less-negative worst net/min, not extinction.
- `K` above `MAX_AGENTS` (the render cap) only matters for the visual sample, not the economy.

## Guardrails

- The pure core stays pure — the lab loads the real modules but never `love.*`. Keep it that
  way; offline/idle math depends on it.
- `competition`/`predation` are still partly **prototype** (modelled in the lab, ported into
  cell.lua incrementally). Don't assume a lab knob is live in `sim.step` — check cell.lua.
- Don't add a constant to one file "for now." If it's in the mirror set, it's in all three.
