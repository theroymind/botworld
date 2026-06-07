# botworld — game plan

Distilled brainstorm, 2026-06-07.

## Vision

An idle/incremental game about life scaling up: single cell → tribes → gathering
societies → planetary resource exploitation → solar system → galaxies. The player
zooms between scales, watching the thing they grew at one scale become a statistic
at the next.

## Pillars

- **No art pipeline.** Everything is programmatic: shapes, abnormal/organic shapes,
  particles, shaders. Monochrome or a 2-3 color palette.
- **Idle/incremental core.** Numbers grow over time; upgrades and scale-ups are the
  strategic choices. Advancing to a new scale is the prestige beat.
- **Zoom is the fantasy.** Pulling back from cell to galaxy (and diving back in) is
  the signature moment. Lower scales keep living when you zoom out.
- **Cheap simulation, expensive-looking visuals.** Aggregate numbers drive the sim;
  swarms render deterministically on the GPU from those numbers (validated by
  benchmark #2: 1M+ instanced drones, flat CPU cost).

## Scale layers (game progression)

Discrete layers, each its own sim, joined by zoom transitions. Output of each layer
becomes an input/multiplier for the next.

| # | Layer | Player grows | Currency idea | Visual language |
|---|-------|--------------|---------------|-----------------|
| 1 | Cell | Single cell → colony | biomass | soft blobs, membranes, particle food |
| 2 | Organism/Tribe | Animal packs → tribes | population | small shape-creatures, flocking |
| 3 | Society | Gathering → industry | resources/tech | settlements, trade lines |
| 4 | Planet | Global exploitation | energy/extraction | hex/region shading, swarm haulers |
| 5 | Solar system | Multi-planet expansion | mass/logistics | orbits, drone swarms (current demo) |
| 6 | Galaxy+ | Star-to-star spread | stars colonized | point fields, slow-burning light |

Advancing a layer = prestige: the previous layer collapses into a single producing
number with multipliers earned there.

## Zoom model

- Camera zoom is continuous *within* a layer (already works: wheel zoom, drag pan).
- Crossing a threshold triggers a layer transition — a stylized cross-fade/scale
  morph, not a literal continuous sim. Sell continuity visually, not literally.
- Lower layers tick as background math (offline-progress style), not live sims.

## Development phases

### Phase 0 — Core systems
The skeleton everything hangs on, with placeholder visuals:

- **Incremental tick system** — fixed-timestep sim tick decoupled from render.
- **Incremental increase** — a flat placeholder: button click adds to a counter,
  counter displayed. No curves, no generators yet.
- **Layer swapping** — a layer/scene abstraction; switch between two stub layers,
  each owning its own state and update/draw.

Done when: two stub layers, a working counter in each, ticking continues while
swapped away. (Rendering/perf groundwork already exists from the benchmarks: GPU
swarms, camera zoom/pan, tooling.)

### Phase 1 — Incremental depth
Turn the placeholder into a game: generators producing per tick, upgrades,
cost/growth curves, offline progress, save/load. UI as programmatic shapes/text.
One layer (cell) playable end to end with a prestige stub.

### Phase 2 — One beautiful layer
Make the cell layer feel alive: metaball/blob rendering, particle food, organic
motion driven by the same aggregate-number trick. Tune the loop until it's fun for
15 minutes. This is the go/no-go checkpoint for the concept.

### Phase 3 — Second layer + zoom transition
Add tribe/organism layer. Build the layer-transition zoom (the riskiest novel
piece). Prestige from layer 1 into layer 2 with carried multipliers. Two layers
prove the pattern; remaining layers are content.

### Phase 4 — The ladder
Layers 3-6 using the established pattern. Reuse the swarm renderer at every scale
(haulers, migrating tribes, colony ships are all the same instancing trick).
Balance pass on the full progression curve.

### Phase 5 — Polish & ship a demo
Palette/shader cohesion, audio (procedural/synth to match the no-asset ethos),
juice on prestige moments, settings, itch.io build.

## Open questions

- Smallest scale: stop at cell, or go subcellular/molecular?
- Player agency per layer: pure idle, or light placement/steering decisions?
- One palette for the whole game vs. one hue per layer?
- Time scale fiction: do lower layers run "millions of years" while you watch?
- Multiplayer/server ambitions (README hints at server-synced aggregates) — in or
  out for the prototype?
