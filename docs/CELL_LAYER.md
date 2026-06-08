# Cell layer — design brief

The first scale of botworld (layer 1 in `GAME_PLAN.md`). Companion to the master
plan; this file owns the cell layer's gameplay and visual detail. Distilled from a
design session, 2026-06-07.

## Course-correction (2026-06-07): living micro-world + direct traits

The first prototype rendered one big blob and an abstract *genome strand* (slots +
splice + a hidden adjacency synergy). It missed the fantasy. The cell layer is now a
**living micro-world**: a *myriad* of small cells of your design drift through a
nutrient medium, sense and chase food, divide so the swarm fills as you grow, and evolve
new capabilities. The strand sections below are **superseded** by this note; the
**fantasy, the metabolism dial, the visuals-as-readout pillar, and prestige** all carry
over unchanged.

**Upgrades are direct trait levels, not a strand.** Five concrete, gamified traits, each
levelled independently for a rising per-trait cost, each visibly changing every cell:

| Trait | Concrete hint | Reads on the cell |
|---|---|---|
| Photosynthesis | +18% biomass/sec | greener body + pigment nucleus |
| Motility | swim speed +12% | a flagellar tail, longer = faster |
| Chemotaxis | sense range +14 | reaches more food (wider hunt) |
| Digestion | division cost -8% | faster engulf; the division bar fills sooner |
| Evasion | evade +5% | a nimble cell; flees and dodges predator strikes |

No slots, no splicing, no hidden synergy — every row says exactly what it does.

**Milestone unlocks are the evolution spine.** Capabilities open automatically as the
colony grows, each adding a closed-form income channel *and* world contents *and* a
visual tell: **Absorption** (start — ambient motes) → **Photosynthesis** (light →
biomass; reveals the trait) → **Phagocytosis / Predation** (your cells hunt & engulf
prey — legitimate at the unicellular scale) → **Predators** (paired hazard cells that
eat cells that fail to flee; Evasion mitigates; live-only and always healable).

**Feeding is clickable nutrient blooms.** A bloom glows for ~3s; click it to credit a
biomass burst and scatter motes the cells then chase. The only manual feed — no "dish".

**The economy is an authoritative closed form; the swarm is a cosmetic skin.** Net
biomass/sec = per-cell yield × colony size (saturating), which is what idle/offline run
on, so they never depend on the live agents. The live sim's only couplings back to the
economy are the bloom click (credit) and a predator kill (debit, live-only). Modules:
`traits.lua` (levels + unlocks → a `stats` fold), `world.lua` (the agent sim, seeded +
capped), `sim.lua` (the closed form), `view.lua` (render), `cell.lua` (orchestrator).

## Fantasy

You don't *play* a cell — you *influence a soup*. You're a gentle hand on a shared
primordial broth, nudging single-celled life toward complexity. It's Spore's "shape a
creature and watch it thrive," but the creature is a population and your design surface
is its **genome**, not its limbs. The Spore feeling comes from editing life; the
incremental feeling comes from the soup metabolizing while you're away.

## Pillars (cell-specific; inherits the master pillars)

- **The genome strand IS the tech tree.** *(Superseded — see the course-correction
  above: upgrades are now direct trait levels. The "every gene shows on the cell"
  intent carries over as "every trait level visibly changes every cell".)* No abstract
  upgrade list — a literal, visible strand of genes you edit. Every gene shows on the cell.
- **Visuals are the progression readout.** You read your build by looking at the dish,
  not at a number. A flagellum *appears*; pigment *recolors*; the membrane *thickens*.
- **Co-op is ambient synergy, not commerce.** Distinct lineages in a shared world help
  each other through subtle, mostly-automated buffs — proximity auras + niche
  construction — never a waste/trade ledger or a shared project.
- **Manual here, automated later.** The cell layer (and the next) is the hands-on phase:
  you tune the knob and place genes yourself. From phase 3 on, interactions automate.
- **Cheap sim, alive visuals.** A handful of aggregate numbers drive metaballs and the
  existing GPU swarm renderer. The soup looks alive; the CPU barely works.

## The 15-minute promise (Phase 2 go/no-go)

A new player drops into a living dish, taps to feed a cell, watches it divide, spends
biomass to mutate one gene on the strand, and *sees the dish visibly change* — more
motes consumed, a flagellum sprouts, a new color spreads. If that first mutation feels
like a real decision and the dish visibly answers it, the concept is a go.

---

## Visual system

All programmatic, all driven by aggregate numbers, per the no-art pillar. Division,
swarms, and merges are the *same* metaball + instancing trick at different counts —
which means the layer-1→2 zoom transition reuses tech already validated in the swarm
benchmark.

| Element | Technique | Driven by |
|---|---|---|
| **Membrane / cell body** | Metaball field (sum of inverse-distance kernels) thresholded in a fragment shader → organic blob with a bright isoline rim (lipid-bilayer feel) | biomass → radius |
| **Membrane wobble** | Simplex noise displacing the SDF radius over time | energy / agitation |
| **Cytoplasm + organelles** | Interior gradient + drifting dots, **reuse the instanced swarm renderer** | gene-expressed organelle count |
| **Flagella / cilia** | Sine-driven procedural strands animated in the vertex shader | motility gene |
| **Nutrient motes** | The 1M-instanced swarm repurposed as Brownian food on a flow field | nutrient density |
| **Mitosis** | One metaball center splits into two, eased apart — the signature "it's alive" beat | division event |
| **Species color (co-op)** | Per-player hue within the 2–3 color palette; same art, recolored | player id |
| **Specialization aura** | Faint colored halo around a colony, tint bleeding into the shared medium | specialization depth |

---

## The genome strand (core progression) — superseded (see course-correction above)

A linear strand of **gene slots**, drawn along an edge of the screen and mirrored onto
the cell. This replaces the conventional "buy generator N" list.

- **Strand grows with you.** Slots unlock as biomass crosses thresholds — the strand
  visibly lengthens. Early game is 3–4 slots; a mature cell has many.
- **Genes are the generators/upgrades, expressed as traits.** Examples:
  - *Photosynthesis* — passive biomass faucet (the idle engine).
  - *Flagellum* — motility; reaches more of the nutrient field.
  - *Evasion* — flees/dodges predator strikes; a leaner cell also loses less biomass to the medium.
  - *Enzyme* — faster conversion of nutrients to biomass.
  - *Pigment* — recolors the cell and grants a situational buff.
  - *Receptor* — unlocks symbiosis pairing with another species.
- **Mutation is the currency sink and the tension.** Spend biomass to roll or swap the
  gene in a slot. The idle decision: keep a safe gene, or gamble biomass on a mutation
  that might be better — or worse. Rerolls get more expensive (standard cost curve).
- **Adjacency synergies make it a *build*, not a checklist.** Genes next to each other
  on the strand combo (e.g. Enzyme beside Photosynthesis super-charges the faucet).
  *Position* on the strand matters, not just which genes you own — clever, spatial,
  and fully visible. This is the depth that keeps the loop from being a faucet.
- **The strand is the readout.** Each gene maps to a visual feature, so a glance at the
  dish tells you (and other players) the full build.

---

## The first knob (manual)

The cell layer also introduces the game's core verb in its simplest form: a single
**metabolism dial** the player drags (the only fully-manual knob in the game — phase 2
adds a second, then it automates).

- **What it trades:** push toward *growth* and division speeds up but biomass leaks
  faster (cells lyse); pull toward *thrift* and you retain more but grow slowly. It sets
  a *ratio* (net growth = gain − loss), not a resource.
- **Self-defeating by construction:** gain rises linearly with the dial, loss rises
  super-linearly, so there's an interior sweet spot and "max growth" is a trap. This is
  the Paperclips lesson as one gentle slider.
- **Forgiving + legible:** a broad band near the optimum is ~fine; the dish answers live
  as you drag (division rate, membrane wobble). You can clear the phase on the default
  setting — tuning is opt-in upside, never a survival tax.

---

## Co-op — ambient synergy

Distinct lineages share one dish; help is subtle, bounded, and mostly automatic. Two
complementary channels, no pairing UI, no ledger:

- **Auras (proximity).** Specialize deeply in an aspect and your colony radiates a faint
  field; nearby lineages get a small passive boost to *that* aspect. The photosynthesis
  specialist's neighbors metabolize a little better just by drifting close.
- **Niche construction (the shared medium).** Specialists quietly enrich the dish itself
  — a photosynthesizer raises ambient oxygen, a fixer enriches the broth — and *everyone*
  reads the richer world. The synergy flows through the commons, so no one tracks who
  helped whom; the dish simply gets better as the group diversifies.
- **Bounded + non-critical.** Buffs are small, capped, diminishing per neighbor, and
  phase-scoped. Solo is the full experience and the balance baseline; co-op just speeds
  things a little and makes a varied dish feel alive. A neglected niche only means a
  slightly poorer medium — never a fail-state.

---

## The core idle loop

1. **Generate** — Photosynthesis-type genes produce biomass passively; the nutrient
   field tops up slowly. (Tap-to-feed gives early-game agency; pure idle later.)
2. **Divide** — Biomass auto-spends on cell division; population (the visible swarm)
   grows. More cells = more passive generation.
3. **Mutate** — Spend biomass on the strand: unlock slots, swap genes, chase adjacency
   synergies.
4. **Tune** — Drag the metabolism dial for the growth/thrift trade-off; the dish answers
   live.
5. **Drift together (co-op)** — Specialize, and your aura + niche construction quietly
   lift nearby lineages and the shared medium. Automatic; no management.
6. **Offline** — The dish keeps metabolizing as background math (aggregate-number offline
   progress), per the master plan.

## End of phase 1 — the endosymbiosis seam

The cell layer ends on the **endosymbiosis proc**: a rare engulf-and-keep fires the
cinematic in `transition.lua` (the camera pushes *into* the triggering cell, then a
white-out). **Until phase 2 ships, that white-out resets into a fresh lineage** (wipe +
new founder, same as `[r]`) — a clean placeholder culmination. See `docs/CELL_GROWTH.md`
for the growth arc that leads up to it (trait synergy, the proposed biofilm stage).

**This is the seam into phase 2.** Phase 2 — the *complex cell* — is now in design; see
`docs/PHASE_2.md`. Instead of resetting, the zoom-in continues *inside* the engulfing
cell, and the bacterium it just kept becomes its first mitochondrion; the collapsed
colony carries forward as a single number (the "becomes a statistic" beat). Note phase 2
is a *complex single cell*, **not** multicellular — going multicellular (many cells
fusing into a body) is a **later** phase whose mechanics are open (`GAME_PLAN.md`).

---

## Open questions

- **Mutation randomness:** hard rerolls (gamble) vs. directed mutation (pay to aim)?
  Affects how punishing the sink feels (leaning directed + cheap preview for relaxation).
- **Strand length cap:** fixed slot count per run, or does multicellular prestige raise
  it? Ties into how prestige multipliers are framed.

*Resolved this session:* resource model is a soft faucet (nutrient field + photosynthesis
genes), so co-op stays a pure ambient *buff*, never a conserved-resource transfer. Co-op
is one shared dish with distinct lineages; sync is deferred (the prototype is solo).

## First prototype slice (toward Phase 2)

Replace the cell-layer counter stub with the smallest end-to-end loop: metaball cell +
biomass faucet → auto-division growing an instanced swarm → a 3-slot genome strand with
2–3 genes and one adjacency synergy, each gene visibly expressed. No co-op yet. Tune
until the first mutation is a real, visible decision.
