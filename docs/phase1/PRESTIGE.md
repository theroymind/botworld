# Phase 1 — cell layer: prestige

Phase 1 prestige is a **within-phase Spore loop** (grow → collapse → spend → regrow,
faster) that climbs a permanent skill tree to its peak — **Mitochondria** — which makes the
**endosymbiosis proc** reliable. The proc is the climax: a kept engulf that resolves the run
and zooms *into* the triggering cell, the seam into phase 2. Inherits the master prestige &
zoom model ([`../../GAME_PLAN.md`](../../GAME_PLAN.md)).

There are **two** prestige layers and they nest: the *within-phase* Spore loop runs many
generations inside phase 1; the *cross-phase* seam fires once, when Mitochondria carries the
endosymbiosis proc, and collapses all of phase 1 into a single number for phase 2. The Spore
loop is **strictly within-phase**: it owns the per-generation prestige and nothing crossing
the seam — the cross-phase carry below is its own, separate system.

## Within-phase prestige — the Spore loop

**Status: in design.** The named spend model for the cell layer (each later phase gets its
own; see [`../../GAME_PLAN.md`](../../GAME_PLAN.md)). A generation grows under the age-ramped
pressures (competition + predation, [FAILURE.md](FAILURE.md)); the player banks it into
**Spores** by sporulating, then spends them on a permanent tree. Each regrowth re-climbs
faster and peaks higher — the compounding ramp that gives the phase its playtime.

### The currency: Spores

Bacterial endospores — the dormant survival capsule a colony forms under hostile conditions,
then germinates into a fitter generation; the reset *is* the metaphor.

Spores reward the generation's **peak**, not a cash-out snapshot. The colony has an
instantaneous **spore value** = `health × growth`, folded from population, the toxicity
health factor, and a per-capita vitality term (formula and constants in
[BALANCE.md](BALANCE.md)). The loop tracks the running **high-water peak** of that value
across the generation — the peak only ratchets up, never down, so a colony banks its best
moment even if it sickens afterward.

Banking comes in two grades: **sporulating manually banks the full peak**; a **full collapse
(extinction) banks half the peak** — the reset still pays, just at a discount for letting it
die. The peak resets each generation. Spores are **spent** on the tree, with a small always-on
global intake bonus per lifetime Spore so a weak run still counts.

### Two compounding layers

- **In-run (biomass, resets every generation).** The five direct traits ([DESIGN.md](DESIGN.md))
  level fast, then plateau at the pressure ramp — the fast curve re-run every loop.
- **Meta (Spores, permanent).** The tree raises the floor *and* the ceiling, so each fresh
  climb starts steeper and peaks higher. A couple of nodes (Mitotic Speed, Metabolic Mastery)
  specifically speed up *re-leveling the in-run traits*, so a reset feels like skipping the
  early game, never re-grinding it.

The two branches are the plateau levers: **Growth** reaches the plateau faster (intake /
speed / sense / division); **Resilience** raises it (toxicity / predation / competition
counters — the three pressures in [FAILURE.md](FAILURE.md)).

### The tree

A fixed spine, not a free-form tree (keeps the engulf→absorb narrative and the anti-overwhelm
pillar): a **Photosynthesis** root opens both branches; each branch fills, then a capstone;
both capstones **maxed** unlock **Engulf**; Engulf **maxed** unlocks **Mitochondria**. Node
effects, level caps, and gate prereqs live in [BALANCE.md](BALANCE.md).

```
                         MITOCHONDRIA  (→ phase 2)
                               |
                            ENGULF              (gate · maxed → Mitochondria)
                          /        \
            Metabolic Mastery    Homeostasis    (capstones · both maxed → Engulf)
                  |                   |
         GROWTH branch          RESILIENCE branch
       (reach plateau faster)  (raise the plateau)
                  \                   /
                   Photosynthesis (root)
```

**Engulf is the accelerator.** Once unlocked, engulfing prey feeds the run's health +
reproduction progress directly — the same two terms that pay out Spores — and each of its
levels makes that dump bigger, collapsing loop time toward the short end of the budget.
Maxing it is also the *only* path to Mitochondria.

### The reset beat

Collapse is **manual only** — a player-clicked **sporulate**. Nothing in the sim ever forces
it. The age-ramped pressures are pure *texture*: a generation gets more contested as
`state.age` climbs ([FAILURE.md](FAILURE.md)), and since banking takes the running peak, the
decision is "sporulate now and pocket the full peak, or push for a higher peak and risk
letting the colony slide into a half-paying extinction." No hard force and no artificial
decay — the teeth already in the sim do the work.

## The evolve-gate / climax

**Endosymbiosis is the climax, and Mitochondria makes it reliable.** A prey engulf can keep
the partner and resolve the run. The per-engulf chance is `ENDO_BASE_CHANCE` plus a ramp,
but the dominant lever is now the **Mitochondria** node, whose levels drive the chance toward
near-certain — so the gate is **deterministic within the ~15-minute budget** instead of left
to a vanishingly-rare proc. (Constants in [BALANCE.md](BALANCE.md).)

When the proc fires, the cinematic in `transition.lua` plays (the `"dive"` style): the dish
dissolves to isolate the lone winning cell, the camera plunges *into* it, and a teal
isolation fade carries the frame across the seam — the zoom itself is the bridge into phase
2, with no white-out wipe.

## The end-of-phase choice

None in phase 1 — the run resolves on the endosymbiosis proc with no ascension-defining
fork. The Spore tree is the standing build choice; it carries forward as the seam multiplier
below.

## The seam out

**This is the seam into phase 2** ([`../phase2/DESIGN.md`](../phase2/DESIGN.md)). The zoom-in
continues *inside* the engulfing cell: the bacterium it just kept becomes its first
**mitochondrion**, and the collapsed colony carries forward as a **single number** — the
"becomes a statistic" beat. The carried multiplier is framed off the run's meta progress
(peak Spores / tree depth at the seam), so phase 2 starts richer for a deeper phase-1 climb.
Phase 2 is a *complex single cell*, **not** multicellular — going multicellular is a **later**
phase ([`../../GAME_PLAN.md`](../../GAME_PLAN.md)).

The seam itself — its cinematic and the lineage handoff — stays exactly as built
(`lib/layers/cell/transition.lua` + the lineage transition). The seam multiplier / cross-phase
carry is **not** designed or built by the Spore loop; that within-phase prestige engine stops
at the seam and owns no part of the cross-phase number.

## The seam in

None — phase 1 is the first phase; it receives no handoff.

## Current state

The endosymbiosis seam is **built**: at the deepest point of the teal dive
(`begin_lineage_transition` → `complexcell.enter_from_seam` + `layers.switch("complexcell")`),
phase 1 is retired — its sim freezes at the snapshotted statistic — and the complex-cell
layer opens out of the same teal isolation fade (no flash, no cut). The engulfed bacterium
becomes the new cell's first mitochondrion. (`[r]` still wipes to a fresh founder for
debugging.)

The **Spore loop is in design** — until it ships, the run resolves on the existing
size-ramped endosymbiosis proc (the Mitochondria node folds into that same chance once built).

## Open questions

- **Capstone strictness:** both capstones require their branch **fully maxed** to unlock
  Engulf (the standing call); revisit if the loop runs long against the ~15-min budget.
- **Spore payout shape:** the exact spore-value weighting (population exponent, vitality
  weight) and the full-vs-half banking split (tuning — see [BALANCE.md](BALANCE.md)).
- **Seam multiplier framing:** how peak Spores / tree depth maps to phase 2's starting state
  (ties into [DESIGN.md](DESIGN.md)'s trait/catalog-cap question).
