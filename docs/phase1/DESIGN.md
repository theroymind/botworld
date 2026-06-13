# Phase 1 — cell layer: design

The first scale of botworld (layer 1 in [`../../GAME_PLAN.md`](../../GAME_PLAN.md)) — a
living micro-world where a myriad of small cells of your design drift through a nutrient
medium, sense and chase food, divide to fill the dish, and evolve new capabilities.

**Status:** built and tuned. The closed-form compounding economy, the five direct traits +
synergy, the milestone unlock spine, and the GPU-field swarm are all shipped. The
failure-model rework (see [FAILURE.md](FAILURE.md)) and trait visual drives are in flight.

**Siblings:** [BALANCE.md](BALANCE.md) (the numbers) · [FAILURE.md](FAILURE.md) (the
fail-state) · [PRESTIGE.md](PRESTIGE.md) (the endosymbiosis seam). **Next phase:**
[`../phase2/DESIGN.md`](../phase2/DESIGN.md) (the complex cell).

## Fantasy

You don't *play* a cell — you *influence a soup*. You're a gentle hand on a shared
primordial broth, nudging single-celled life toward complexity. It's Endospore's "shape a
creature and watch it thrive," but the creature is a population and your design surface is
its biology, not its limbs. The Endospore feeling comes from editing life; the incremental
feeling comes from the soup metabolizing while you're away. A new player drops into a
living dish, taps to feed a cell, watches it divide, spends biomass to level a trait, and
*sees the dish visibly change* — more motes consumed, a flagellum sprouts, a new color
spreads.

## Pillars (cell-specific; inherits the master pillars)

- **Visuals are the progression readout.** You read your build by looking at the dish, not
  at a number. A flagellum *appears*; pigment *recolors*; the membrane *thickens*. Every
  trait level visibly changes every cell.
- **Co-op is ambient synergy, not commerce.** Distinct lineages in a shared world help each
  other through subtle, mostly-automated buffs — proximity auras + niche construction —
  never a waste/trade ledger or a shared project.
- **Manual here, automated later.** The cell layer (and the next) is the hands-on phase:
  you level traits and feed blooms yourself. From phase 3 on, interactions automate.
- **Cheap sim, alive visuals.** A handful of aggregate numbers drive metaballs and the GPU
  swarm renderer. The soup looks alive; the CPU barely works.
- **Departure — phase 1 has a fail-state.** A deliberate reversal of the master "never a
  survival tax / never a fail-state" pillar, *for phase 1 specifically* (the master pillar
  still holds for later, automated phases): the cell layer has teeth. See
  [FAILURE.md](FAILURE.md).

## Core loop & the verb

The cell layer's verbs are direct and hands-on: **feed nutrient blooms** (click), **level
the five traits**, and **buy milestone evolutions**. There is no metabolism dial — the
economy runs at a single fixed sweet-spot rate (`metabolism.optimum()`, the interior
optimum of the gain/loss curve) baked into the intake fold, so online and offline math
never diverge. The player never tunes the rate; they shape *what* the colony is (its
traits and capabilities), and the closed-form economy compounds at the sweet spot.

The self-defeating decision lives instead in the **fail-state** (see [FAILURE.md](FAILURE.md)):
three closed-form pressures push net replication down, and the player answers them by
leveling the right traits and feeding blooms. Allocation is the choice; failure is the
honest outcome of neglecting it.

### The idle loop

1. **Generate** — Foraging and (once evolved) photosynthesis produce passively at the
   fixed sweet-spot rate; the nutrient field tops up slowly. Tap-to-feed gives early-game
   agency.
2. **Divide** — The energy reserve auto-spends on cell division; the visible swarm grows.
   More cells = more passive generation (the economy compounds — see below).
3. **Level** — Spend biomass to raise trait levels and chase the two synergy pairs.
4. **Evolve** — Collapse a generation into Endospores and buy the permanent milestone unlocks
   (photosynthesis → engulf → mitochondria) on the meta-tree (see [PRESTIGE.md](PRESTIGE.md)).
5. **Drift together (co-op)** — Specialize, and your aura + niche construction quietly lift
   nearby lineages and the shared medium. Automatic; no management.
6. **Offline** — The dish keeps metabolizing as background math (aggregate-number offline
   progress), per the master plan.

**Feeding is clickable nutrient blooms.** A bloom glows for ~3s; click it to credit an
energy burst (and flush a chunk of waste) and scatter motes the cells then chase. The only
manual feed — no "dish".

## Progression

### Direct trait levels

Upgrades are direct, gamified trait levels — no slots, no splicing, no hidden synergy.
Five concrete traits, each levelled independently for a rising per-trait cost, each visibly
changing every cell; every row says exactly what it does.

| Trait | Concrete hint | Reads on the cell |
|---|---|---|
| Photosynthesis | +18% biomass/sec | greener body + pigment nucleus |
| Motility | swim speed +25%/level; +8% foraging/level | a flagellar tail, longer = faster |
| Chemotaxis | sense range +14 | reaches more food (wider hunt) |
| Digestion | division cost -8% | faster engulf; the division bar fills sooner |
| Evasion | evade +5% | a nimble cell; flees and dodges predator strikes |

Two trait *pairs* multiply via synergy (Reach = Motility × Chemotaxis; Thrift = Digestion ×
Evasion) — see [BALANCE.md](BALANCE.md) for the `√(a·b)` shape and constants.

### The milestone unlock spine

Capabilities are **permanent evolutions on the Endospore meta-tree** ([PRESTIGE.md](PRESTIGE.md)),
not in-run purchases — they're bought once with Endospores and inherited by every later
generation ("your descendants remember"). Each opens a closed-form income channel *and* world
contents *and* a visual tell. The spine is:

**Absorption** (start — ambient motes; the always-on state, not a purchase) →
**Photosynthesis** (the Endospore tree's root unlock; light → biomass, and reveals the trait) →
**Engulf / Phagocytosis** (the tree's gate node, unlocked only once both branch capstones are
maxed; your cells hunt & engulf prey — legitimate at the unicellular scale) →
**Mitochondria** (Engulf maxed; the endosymbiosis chance toward the phase-2 seam). Engulf also
`enables_predators` — the paired hazard cells that eat cells which fail to flee (Evasion
mitigates) ride on the same unlock; predators are not a separate purchase. Endospore costs and
gate prereqs in [BALANCE.md](BALANCE.md); the full tree and loop in [PRESTIGE.md](PRESTIGE.md).

Within a single generation the player still spends **biomass** on the five direct trait levels
above — that's the fast curve that resets each loop, riding on top of the permanent tree.

## The economy (closed-form spec)

The economy is an **authoritative closed form**; the swarm is a cosmetic skin. It is not
logistic — it **compounds**. Each cell adds a per-cell income that does **not** saturate
(`cell.lua GROWTH_RATE` → `sim` `intake.growth_per_cell`), so income scales with the colony
and population climbs exponentially into the millions instead of walling at a carrying
capacity:

```
net biomass/sec  =  per-cell yield × colony size   (with synergy lifting the saturation point)
```

Idle and offline run on this closed form, so they never depend on the live agents. The live
sim's only couplings back to the economy are the **bloom click** (credit) and the
**endosymbiosis organelle keep**. Predation is **not** a coupling: it is single-sourced
through the closed-form `pred_cull_frac` cull in `sim.step` (folded by `intake_for`, runs
live *and* offline), so the on-screen predators are pure cosmetic theatre — they burst their
victims on screen but never debit the authoritative population. The toxicity health factor
that gives the dish its teeth is also part of the closed form, so offline replays it
identically — see [FAILURE.md](FAILURE.md). All tuning constants live in
[BALANCE.md](BALANCE.md).

## Presentation / visual system

All programmatic, all driven by aggregate numbers, per the no-art pillar. Division, swarms,
and merges are the *same* metaball + instancing trick at different counts — which means the
layer-1→2 zoom transition reuses tech already validated in the swarm benchmark. The shipped
swarm is a GPU procedural field (`cell_field.lua`) driven by *count* + bloom/predator
positions; trait levels can recolor/animate the *whole* field cheaply via global uniforms
(hue from Photosynthesis, swim rate from Motility, size from Evasion, sense halo from
Chemotaxis), no per-cell features and no art.

| Element | Technique | Driven by |
|---|---|---|
| **Membrane / cell body** | Metaball field (sum of inverse-distance kernels) thresholded in a fragment shader → organic blob with a bright isoline rim (lipid-bilayer feel) | biomass → radius |
| **Membrane wobble** | Simplex noise displacing the SDF radius over time | energy / agitation |
| **Cytoplasm + organelles** | Interior gradient + drifting dots, **reuse the instanced swarm renderer** | gene-expressed organelle count |
| **Flagella / cilia** | Sine-driven procedural strands animated in the vertex shader | motility |
| **Nutrient motes** | The 1M-instanced swarm repurposed as Brownian food on a flow field | nutrient density |
| **Mitosis** | One metaball center splits into two, eased apart — the signature "it's alive" beat | division event |
| **Species color (co-op)** | Per-player hue within the 2–3 color palette; same art, recolored | player id |
| **Specialization aura** | Faint colored halo around a colony, tint bleeding into the shared medium | specialization depth |

## Co-op — ambient synergy

Distinct lineages share one dish; help is subtle, bounded, and mostly automatic. Two
complementary channels, no pairing UI, no ledger:

- **Auras (proximity).** Specialize deeply in an aspect and your colony radiates a faint
  field; nearby lineages get a small passive boost to *that* aspect. The photosynthesis
  specialist's neighbors metabolize a little better just by drifting close.
- **Niche construction (the shared medium).** Specialists quietly enrich the dish itself —
  a photosynthesizer raises ambient oxygen, a fixer enriches the broth — and *everyone*
  reads the richer world. The synergy flows through the commons, so no one tracks who
  helped whom; the dish simply gets better as the group diversifies.
- **Bounded + non-critical.** Buffs are small, capped, diminishing per neighbor, and
  phase-scoped. Solo is the full experience and the balance baseline; co-op just speeds
  things a little and makes a varied dish feel alive. A neglected niche only means a
  slightly poorer medium — never a fail-state.

The resource model is a soft faucet (nutrient field + photosynthesis), so co-op stays a
pure ambient *buff*, never a conserved-resource transfer. Co-op is one shared dish with
distinct lineages; sync is deferred (the prototype is solo).

## Architecture & reuse

The economy is a pure, deterministic closed form; the live swarm is a cosmetic skin over
it. Modules:

- `traits.lua` — levels + unlocks → a `stats` fold (also owns trait synergy).
- `metabolism.lua` — the pure gain/loss curve; the orchestrator pins it at
  `metabolism.optimum()` (the sweet spot) as the economy's fixed base rate.
- `organelles.lua` — the endosymbiosis organelle defs + the folds (intake mult, light
  bonus) the orchestrator mixes into intake.
- `world.lua` — the live agent sim, seeded + capped (logarithmic render sampling).
- `sim.lua` — the closed form (the authoritative economy; idle + offline run here).
- `view.lua` / `cell_field.lua` — render (the GPU procedural field).
- `cell.lua` — the orchestrator wiring the pure core into the live world.

The metaball + instancing render tech is shared with the swarm benchmark and carried
forward to the layer-1→2 zoom transition.

## Open questions

- **Strand length cap / catalog cap:** is there a fixed per-run ceiling on how far traits
  level, or does prestige raise it? Ties into how prestige multipliers are framed (see
  [PRESTIGE.md](PRESTIGE.md)).
- **Mutation randomness (if reintroduced):** hard rerolls (gamble) vs. directed mutation
  (pay to aim) — affects how punishing the sink feels (leaning directed + cheap preview for
  relaxation).
