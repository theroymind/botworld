# Phase 1 — cell layer: prestige

Phase 1 ends on the **endosymbiosis proc** — a rare engulf-and-keep that resolves the run
and zooms *into* the triggering cell, the seam into phase 2. Inherits the master prestige &
zoom model ([`../../GAME_PLAN.md`](../../GAME_PLAN.md)).

## The evolve-gate / climax

**Endosymbiosis is the climax, and it's RNG.** A prey engulf can keep the partner and
resolve the run. The per-engulf chance is `ENDO_BASE_CHANCE` plus `ENDO_RAMP_PER_STEP` per
`ENDO_STEP` (100k) cells — **possible at any size but vanishingly rare early, near-certain
once the swarm is in the millions** — so the run almost always ends somewhere in the low
millions, with variance, never on a fixed threshold. (Constants in [BALANCE.md](BALANCE.md);
the compounding arc that leads up to it is the ~5-minute sprint there.)

When the proc fires, the cinematic in `transition.lua` plays (the `"dive"` style): the dish
dissolves to isolate the lone winning cell, the camera plunges *into* it, and a teal
isolation fade carries the frame across the seam — the zoom itself is the bridge into phase
2, with no white-out wipe.

## The end-of-phase choice

None in phase 1 — the run resolves on the endosymbiosis proc with no ascension-defining
fork.

## The seam out

**This is the seam into phase 2** ([`../phase2/DESIGN.md`](../phase2/DESIGN.md)). The zoom-in
continues *inside* the engulfing cell: the bacterium it just kept becomes its first
**mitochondrion**, and the collapsed colony carries forward as a **single number** — the
"becomes a statistic" beat. Phase 2 is a *complex single cell*, **not** multicellular —
going multicellular (many cells fusing into a body) is a **later** phase whose mechanics are
open ([`../../GAME_PLAN.md`](../../GAME_PLAN.md)).

## The seam in

None — phase 1 is the first phase; it receives no handoff.

## Current state

Phase 2 has shipped, so the finale hands off live: at the deepest point of the teal dive
(`begin_lineage_transition` → `complexcell.enter_from_seam` + `layers.switch("complexcell")`),
phase 1 is **retired** — its sim freezes at the snapshotted statistic — and the complex-cell
layer opens out of the same teal isolation fade (no flash, no cut). The engulfed bacterium
becomes the new cell's first mitochondrion. (`[r]` still wipes to a fresh founder for
debugging, but it is no longer the seam's culmination.)

## Open questions

- **Prestige multiplier framing:** how the single carried-forward number is framed as a
  multiplier feeding phase 2's starting state.
- **Trait/catalog cap on prestige:** is there a fixed per-run ceiling on trait levels, or
  does prestige raise it? Ties into the multiplier framing (see also [DESIGN.md](DESIGN.md)
  open questions).
