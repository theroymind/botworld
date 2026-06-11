# botworld — game plan

Distilled brainstorm, 2026-06-07 (rev. 2026-06-08). The cell layer's detail lives in
`docs/phase1/DESIGN.md`; the complex-cell layer (phase 2, in design) in `docs/phase2/DESIGN.md`.
Every phase follows the four-doc structure in `docs/PHASE_TEMPLATE.md` (DESIGN / BALANCE /
FAILURE / PRESTIGE).

## Status & how to read this plan

- **Phase 1 (cell colony): built and tuned** — see `docs/phase1/DESIGN.md`.
- **Phase 2 (complex cell): in design** — see `docs/phase2/DESIGN.md`.
- **Everything past phase 2 is an intentionally loose VISION, not a spec.** The scale
  progression below (organisms → animals → … → galaxy) is the north star; the *mechanics* of
  those phases are **not decided**. Each phase gets its own dedicated brainstorm — the way
  phase 2 did — when we reach it.
- **Do not treat any future phase's "how it plays" as committed.** An earlier generated draft
  of this plan pre-assigned a specific optimization mechanic and mega-project to all eleven
  phases. That over-specification caused confusion and is deliberately rolled back: future
  phases are open questions to discover, not assumptions to inherit.

## Vision

An idle/incremental game about life scaling up: single cell → complex cell → organisms →
animals → minds → planet → solar system → galaxy. You tend **one lineage** and zoom between
scales, watching the thing you grew at one scale become a statistic at the next. Spirit: a
mix of **Spore** (evolve your own thing, shaped by your choices) and **incremental** (numbers
grow; optimization is the strategy).

## Pillars

- **No art pipeline.** Everything programmatic: shapes, organic/abnormal forms, particles,
  shaders. Monochrome or a 2-3 color palette.
- **Idle/incremental core.** Numbers grow over time; the strategic choices are how you
  optimize. Advancing to a new scale is the prestige beat.
- **Zoom is the fantasy.** Pulling back from cell to galaxy (and diving back in) is the
  signature moment. Lower scales keep living when you zoom out.
- **Cheap simulation, expensive-looking visuals.** Aggregate numbers drive the sim; swarms
  render deterministically on the GPU from those numbers (benchmark #2: 1M+ instanced drones,
  flat CPU cost).
- **Dial the knobs.** The core verb is optimization-under-constraint (à la Universal
  Paperclips' probe panel): set a configuration → it sets *ratios* → the idle loop turns
  ratios into growth. Each phase rotates a *different shape* of this so it never feels like the
  same formula (per-phase specifics are designed when we reach that phase).
- **Increasingly hands-off.** Early phases are manual; later phases automate. You graduate from
  steering to overseeing.
- **One lineage, relaxing.** A single evolving thing — no avatar-juggling — and the game must
  never overwhelm.

## Core verb: dial the knobs

The thing the player actually *does* across the whole game:

- **Knobs set ratios, not resources.** A knob never grants matter directly — it sets a rate
  (survival %, yield-per-unit, spread). The idle tick multiplies ratios against your population
  over time, and accrual fills the phase's evolve-gate. You tune the slope; the loop draws the
  line. This is what makes optimization idle-compatible.
- **The self-defeating knob makes allocation a decision.** Borrow Paperclips' trick: tie a
  penalty to the same investment that grants the benefit (benefit grows linearly, the penalty
  super-linearly), so "max the obvious knob" is always a trap and there's an interior optimum.
  (cell example: grow fast → cells lyse / biomass leaks faster.)
- **Variety of *kind*, not quantity.** Each phase aims to introduce one new *optimization
  family*, building on fluency with the last — not just more sliders. Which family fits which
  phase is designed when we get there, not pre-assigned.
- **Anti-overwhelm is a hard rule.** ≤3-4 *active* knobs on screen ever; introduce them one at a
  time; forgiving plateau optima (a wide band yields ~85-95% of max; "wrong" is mildly slower,
  never a fail-state); live feedback as you drag. **Litmus test: you can clear any phase without
  ever opening the knob panel — tuning is opt-in upside.** *(Exception, decided 2026-06-08:
  phase 1 now has a real fail-state — a waste/vitality pressure that ends the run if you
  neglect the dish entirely. See `docs/phase1/FAILURE.md`. The "no fail-state" rule still governs
  the later automated phases; phase 1 wanted teeth.)*

## Scale ladder (the vision — mechanics TBD)

A loose, ordered vision of scales, **not** a mechanics spec. Only phases 1–2 have decided
gameplay; the rest name a *scale and fantasy*, with their actual optimization family and
evolve-gate to be brainstormed when we reach them.

| # | Phase | Scale / fantasy | Mechanics |
|---|-------|-----------------|-----------|
| 1 | Cell | grow a single-celled colony in a dish | **built** — see `docs/phase1/DESIGN.md` |
| 2 | Complex cell | zoom inside one cell; build its organelles | **in design** — see `docs/phase2/DESIGN.md` |
| 3+ | Organisms → animals → minds → planet → solar system → galaxy → ? | life keeps scaling up, each scale its own sim joined by a zoom transition | **open — brainstorm per phase** |

Threads to resolve for the future ladder (per phase, not now): what the core verb is at each
scale, what the evolve-gate / mega-project is, how prestige carries forward, and how many
scales there ultimately are. The existing solar/galaxy GPU-swarm demo shows the swarm renderer
already reaches those scales technically — it does **not** decide their gameplay.

## Prestige & zoom (directional)

Validated only for the phase-1 → phase-2 seam; everything else is direction, not commitment.

- **Advancing a phase = prestige:** the previous phase collapses into a single producing number
  with a carried multiplier, and its knob-screen leaves the live UI. Keeps the number of live
  concepts small.
- **Zoom sells continuity visually, not literally.** Crossing a threshold triggers a stylized
  cross-fade/scale morph between layers (the metaball threshold that animates mitosis also
  animates the zoom). Lower layers tick as background math (offline-progress style), not live
  sims.

## Co-op, automation, and later systems (directional, not committed)

Aspirations that shaped phase 1's discipline and are kept as *direction* — their concrete
mechanics are open and get designed with the phase that needs them:

- **Co-op = ambient synergy.** Distinct lineages share a world; help is subtle, bounded, mostly
  automated (proximity auras + niche construction), never a shared project or trade ledger. Solo
  is the balance baseline. (Prototype is solo; sync deferred.)
- **Automation ramp.** Manual at the start (phases 1–2), automating from there; settled
  mechanics can be handed to optional auto-tuners so a returning idle player isn't re-dialing old
  systems. This is the "graduate from steering to overseeing" arc.

## Development phases (build order)

### Phase 0 — Core systems *(done)*
Fixed-timestep clock, layer registry, generic economy (generators + upgrades + offline + save),
immediate-mode UI, GPU swarm renderer.

### Phase 1 — One playable cell layer *(done)*
A living micro-world of cells that drift, sense and eat, divide (the swarm fills as you grow),
and evolve via direct trait levels + milestone unlocks. Closed-form economy, save + offline.
See `docs/phase1/DESIGN.md` (and `docs/phase1/BALANCE.md` for the growth/balance arc,
`docs/phase1/FAILURE.md` for the fail-state, `docs/phase1/PRESTIGE.md` for the endosymbiosis seam).

### Phase 2 — The complex-cell layer *(next)*
Build the design in `docs/phase2/DESIGN.md`: the zoom-in seam, energy as the currency, a self-revealing
upgrade catalog, flow-based readouts (congestion / vacancy / brownout), and the end-of-phase
plant/animal fork (`docs/phase2/PRESTIGE.md`). Reuse the GPU swarm renderer (pointed inward)
and the `sim_lab` harness for on-paper balance. Tuning numbers live in `docs/phase2/BALANCE.md`
(two-sided ROS pendulum, stage recipe ratios, player gauges); the oxidative-stress fail-state
in `docs/phase2/FAILURE.md`.

### Beyond — open
Further layers, co-op, and the automation ramp are designed when reached, each with its own
brainstorm. No committed build order or mechanics past phase 2.

## Open questions

- **Subcellular floor:** stop at cell, or open a molecular sub-phase below it?
- **Time-scale fiction:** do lower layers run "millions of years" while you watch?
- **Co-op netcode:** the ambient-buff model is sync-friendly, but the prototype is solo; when
  does shared-world sync land?
- **The future ladder itself:** the scales above are a vision — their verbs, gates, and count
  are all still to be brainstormed.
