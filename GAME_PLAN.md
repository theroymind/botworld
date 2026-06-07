# botworld — game plan

Distilled brainstorm, 2026-06-07. Revised after the cell-layer + co-op + core-verb
design session (see `docs/CELL_LAYER.md` for the cell layer in depth).

## Vision

An idle/incremental game about life scaling up: single cell → complex cells → organisms
→ animals → minds → planet → solar system → galaxy. You tend **one lineage** and zoom
between scales, watching the thing you grew at one scale become a statistic at the next.
Spirit: a mix of **Spore** (evolve your own thing, shaped by your choices) and
**incremental** (numbers grow; optimization is the strategy).

## Pillars

- **No art pipeline.** Everything programmatic: shapes, organic/abnormal forms,
  particles, shaders. Monochrome or a 2-3 color palette.
- **Idle/incremental core.** Numbers grow over time; the strategic choices are how you
  optimize. Advancing to a new scale is the prestige beat.
- **Zoom is the fantasy.** Pulling back from cell to galaxy (and diving back in) is the
  signature moment. Lower scales keep living when you zoom out.
- **Cheap simulation, expensive-looking visuals.** Aggregate numbers drive the sim;
  swarms render deterministically on the GPU from those numbers (benchmark #2: 1M+
  instanced drones, flat CPU cost).
- **Dial the knobs.** The core verb is optimization-under-constraint (à la Universal
  Paperclips' probe panel): set a configuration → it sets *ratios* → the idle loop turns
  ratios into growth. Each phase rotates a *different shape* of this so it never feels
  like the same formula. See below.
- **Increasingly hands-off.** Early phases are manual; later phases automate. You
  graduate from steering to overseeing.
- **One lineage, relaxing.** A single evolving thing — no avatar-juggling — and the game
  must never overwhelm.

## Core verb: dial the knobs

The thing the player actually *does* across the whole game:

- **Knobs set ratios, not resources.** A knob never grants matter directly — it sets a
  rate (survival %, yield-per-unit, spread). The idle tick multiplies ratios against your
  population over time, and accrual fills the phase's evolve-gate. You tune the slope;
  the loop draws the line. This is what makes optimization idle-compatible.
- **The self-defeating knob makes allocation a decision.** Borrow Paperclips' trick: tie
  a penalty to the same investment that grants the benefit (benefit grows linearly, the
  penalty super-linearly), so "max the obvious knob" is always a trap and there's an
  interior optimum. (cell example: grow fast → cells lyse / biomass leaks faster.)
- **Variety of *kind*, not quantity.** Each phase introduces one new *optimization
  family*, building on fluency with the last — not just more sliders (see the ladder).
- **Anti-overwhelm is a hard rule.** ≤3-4 *active* knobs on screen ever; introduce them
  one at a time; forgiving plateau optima (a wide band yields ~85-95% of max; "wrong" is
  mildly slower, never a fail-state); live feedback as you drag. **Litmus test: you can
  clear any phase without ever opening the knob panel — tuning is opt-in upside.**

## Scale layers (11 phases)

Discrete layers, each its own sim, joined by zoom transitions. Each phase rotates the
optimization family so the core verb stays fresh; complexity tiers climb 1→5 while the
number of *live* concepts stays ~2 (older phases collapse — see Automation ramp).

| # | Phase | Optimization family (the fresh verb) | Mega-project (evolve-gate) | Tier |
|---|-------|--------------------------------------|----------------------------|------|
| 1 | Cell | Grow a colony — direct trait levels + milestone unlocks (incl. predation) | biofilm → multicellularity | 1 |
| 2 | Complex cells | Rate-balancing — match grow vs. burn to intake | organelle suite / proto-body | 2 |
| 3 | Organisms | Constrained point-buy — limbs/size/sensors under a cap | a viable body plan | 2 |
| 4 | Primitive animals/insects | Equilibrium / homeostat — set caste %s, watch it settle | the hive / nest | 3 |
| 5 | Animals | Feedback-loop taming — damp a predator/prey oscillation | a dominant species | 3 |
| 6 | Intelligent animals | Routing — allocate research across a tech graph | fire / culture | 4 |
| 7 | Orbit | The Paperclips panel — fixed budget across rocket params | first rocket | 4 |
| 8 | Moon | Network throughput — depots & routes, kill the bottleneck | lunar base | 4 |
| 9 | Solar system | Portfolio / risk-of-ruin — growth vs. variance vs. the fatal tail | Dyson swarm | 5 |
| 10 | Galaxy | Payoff-matrix strategy — best-response to what the galaxy does back | FTL gate / network | 5 |
| 11 | Transcendence | Multi-objective sculpting — weight every prior output, no single best | transcendence engine | 5 |

Advancing a phase = prestige: the previous phase collapses into a single producing number
with carried multipliers (cell colony → carried net multiplier; rocket design → launch
efficiency; etc.).

*Reconciliation note:* the original plan listed 6 layers; this is the expanded 11. The
existing solar/galaxy GPU-swarm demo serves the swarm rendering for phases 8-10 (haulers,
probes, colony ships are the same instancing trick).

## Co-op: ambient synergy

Optional, subtle, and mostly automated — a warm layer on top, never the point.

- **Distinct lineages, shared world.** Each player evolves their *own* thing; only the
  world is shared. No merging, no shared project, no shared goal — a convoy, not a fusion.
- **Synergy = specialization radiating a small bonus.** Two complementary, subtle channels:
  - **Auras (proximity).** Specialize in an aspect and you emit a faint field; nearby
    lineages get a small passive boost to *that* aspect. Deeper specialization → stronger
    aura for that one thing.
  - **Niche construction (environment).** Specialists quietly enrich the *shared
    environment* in their dimension (a photosynthesizer raises ambient oxygen); everyone
    passively reads the richer world. Synergy flows through the commons, not person-to-person.
- **Subtle but nice, and bounded.** Buffs are small, capped, diminishing per partner, and
  phase-scoped (kept for the current phase; nothing heavy compounds across transitions).
  Solo is the full experience and the **balance baseline** — co-op only speeds things a
  little and adds warmth. Drop-in/drop-out friendly.
- **Mostly automated, like everything else.** Co-op interactions run themselves; the only
  hands-on play is phases 1-2.

## Automation ramp

The defense against overwhelm and the source of the "graduate from steering to overseeing"
arc:

- **Manual only at the start.** Phases 1-2 are hands-on (tune the knob, place genes). From
  there, interactions increasingly run themselves.
- **Auto-tuners hold "good enough."** Mid game, each settled mechanic can be handed to an
  optional auto-tuner (Paperclips' AutoTourney / Factorio blueprints), so a returning idle
  player isn't re-dialing old systems.
- **Collapse-on-ascend.** When a mega-project completes, its whole knob-screen freezes at
  your final config and reduces to *one* carried multiplier feeding the next layer. The old
  panel leaves the live UI; only its result persists. Keeps live concepts ~2.

## Zoom model

- Camera zoom is continuous *within* a layer (already works: wheel zoom, drag pan).
- Crossing a threshold triggers a layer transition — a stylized cross-fade/scale morph, not
  a literal continuous sim. Sell continuity visually, not literally. (The metaball threshold
  that animates mitosis also animates cells fusing into a body — same shader.)
- Lower layers tick as background math (offline-progress style), not live sims.

## Development phases

### Phase 0 — Core systems  *(done)*
Fixed-timestep clock, layer registry, generic economy (generators + upgrades + offline +
save), immediate-mode UI, GPU swarm renderer.

### Phase 1 — One playable cell layer
Replace the cell stub with a real loop: a living micro-world of cells that drift, sense
and eat nutrient motes, divide (the swarm fills as you grow), and evolve. Upgrades are
**direct trait levels** (concrete buffs, each visibly expressed) plus **milestone
unlocks** (photosynthesis → predation); the **first knob** is a manual risk/reward
metabolism dial with the self-defeating dynamic; feeding is clickable nutrient blooms;
a colony-size evolve-gate, save + offline progress. The first test of the core verb. See
`docs/CELL_LAYER.md`.

### Phase 2 — One beautiful layer
Make the cell layer feel alive: metaball/blob rendering, particle food, organic motion
driven by the aggregate-number trick. Tune until it's fun for 15 minutes. Go/no-go
checkpoint for the concept.

### Phase 3 — Second layer + zoom transition
Add the complex-cell layer (rate-balancing — a *different* optimization family). Build the
layer-transition zoom (the riskiest novel piece). Prestige from phase 1 into phase 2 with
carried multipliers. Two layers prove the pattern.

### Phase 4 — The ladder
Phases 3-11 on the established pattern; rotate a new optimization family each phase. Reuse
the swarm renderer at every scale. Layer in ambient co-op synergy + the automation ramp.
Balance pass on the full curve.

### Phase 5 — Polish & ship a demo
Palette/shader cohesion, procedural/synth audio, juice on prestige moments, settings,
itch.io build.

## Open questions

- **Mutation randomness:** gamble rerolls vs. directed (pay-to-aim) mutation? Affects how
  punishing the sink feels (leaning directed + cheap preview for relaxation).
- **Strand length cap:** fixed slots per run, or does prestige extend it?
- **Co-op netcode:** shared-world sync is deferred — the model (capped, phase-scoped
  ambient buffs over aggregate numbers) is sync-friendly, but the prototype is solo.
- **Time-scale fiction:** do lower layers run "millions of years" while you watch?
- **Subcellular floor:** stop at cell, or open a molecular sub-phase below it?
