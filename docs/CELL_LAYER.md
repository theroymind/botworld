# Cell layer — design brief

The first scale of botworld (layer 1 in `GAME_PLAN.md`). Companion to the master
plan; this file owns the cell layer's gameplay and visual detail. Distilled from a
design session, 2026-06-07.

## Fantasy

You don't *play* a cell — you *influence a soup*. You're a gentle hand on a shared
primordial broth, nudging single-celled life toward complexity. It's Spore's "shape a
creature and watch it thrive," but the creature is a population and your design surface
is its **genome**, not its limbs. The Spore feeling comes from editing life; the
incremental feeling comes from the soup metabolizing while you're away.

## Pillars (cell-specific; inherits the master pillars)

- **The genome strand IS the tech tree.** No abstract upgrade list — a literal,
  visible strand of genes you edit. Every gene shows on the cell.
- **Visuals are the progression readout.** You read your build by looking at the dish,
  not at a number. A flagellum *appears*; pigment *recolors*; the membrane *thickens*.
- **Co-op is symbiosis, not commerce.** Players help each other through mutualistic
  buffs that culminate in endosymbiosis — never a waste/trade ledger.
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
| **Symbiosis link** | Soft bridge of light / shared rim where two species' colonies overlap | active pairing |

---

## The genome strand (core progression)

A linear strand of **gene slots**, drawn along an edge of the screen and mirrored onto
the cell. This replaces the conventional "buy generator N" list.

- **Strand grows with you.** Slots unlock as biomass crosses thresholds — the strand
  visibly lengthens. Early game is 3–4 slots; a mature cell has many.
- **Genes are the generators/upgrades, expressed as traits.** Examples:
  - *Photosynthesis* — passive biomass faucet (the idle engine).
  - *Flagellum* — motility; reaches more of the nutrient field.
  - *Thick membrane* — retention/defense; less biomass lost to the medium.
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

## Symbiosis (co-op)

Co-op players are different species in the dish (shared or adjacent — see open
questions). Help flows as **mutual buffs**, never a waste/resource ledger.

- **Mutualism = an association buff.** While two species' colonies intermingle, *both*
  get a buff — e.g. one grants a metabolism multiplier, the other grants retention.
  It's a lichen/gut-flora relationship: the pair is stronger than either alone, with no
  bookkeeping of who fed whom. Pairing requires a *Receptor* gene, so symbiosis is
  itself a genome choice — you spend a slot to become a good partner.
- **Endosymbiosis is the payoff and the tie-back to the strand.** Sustained, deep
  symbiosis can culminate in one cell absorbing the partner's trait as a permanent
  **organelle gene** written onto its own strand — exactly how mitochondria and
  chloroplasts arose. Co-op's peak reward isn't a transient buff; it permanently
  edits the thing you're already optimizing. Visually: the partner blob is engulfed and
  becomes a glowing organelle dot inside your membrane.
- **Why this shape:** it makes co-op warm and emergent (players seek complementary
  partners) without the grim "my waste is your food" chain, and it keeps everything
  expressed through the one mechanic that matters — the genome.

---

## The core idle loop

1. **Generate** — Photosynthesis-type genes produce biomass passively; the nutrient
   field tops up slowly. (Tap-to-feed gives early-game agency; pure idle later.)
2. **Divide** — Biomass auto-spends on cell division; population (the visible swarm)
   grows. More cells = more passive generation.
3. **Mutate** — Spend biomass on the strand: unlock slots, swap genes, chase adjacency
   synergies.
4. **Pair** — Find a complementary species; intermingle for mutual buffs; pursue
   endosymbiosis for a permanent organelle gene.
5. **Offline** — The dish keeps metabolizing as background math (aggregate-number
   offline progress), per the master plan.

## Prestige — merge upward, don't wipe

You never reset to zero. When the strand is full and well-expressed, the colony goes
**multicellular**: the swarm of cells fuses into a single body at layer 2, carrying its
genome forward as inherited multipliers (endosymbiotic organelle genes included). The
thing you grew becomes one organ in the bigger thing — the master plan's "becomes a
statistic," made literal and visible, and animated by the same metaball threshold that
handled mitosis.

---

## Open questions

- **Co-op coupling:** one shared dish (max interdependence, needs server authority over
  the medium) vs. adjacent dishes whose colonies/symbionts meet at the edges (loosely
  coupled, far easier to sync as aggregate numbers)? Leaning adjacent for the prototype.
- **Resource model:** keep it a soft faucet (nutrient field + photosynthesis genes), so
  symbiosis stays a pure *buff* and never a conserved-resource transfer. (Resolved this
  way in the session — avoids the waste-reuse feel.)
- **Mutation randomness:** hard rerolls (gamble) vs. directed mutation (pay to aim)?
  Affects how punishing the sink feels.
- **Strand length cap:** fixed slot count per run, or does multicellular prestige raise
  it? Ties into how prestige multipliers are framed.

## First prototype slice (toward Phase 2)

Replace the cell-layer counter stub with the smallest end-to-end loop: metaball cell +
biomass faucet → auto-division growing an instanced swarm → a 3-slot genome strand with
2–3 genes and one adjacency synergy, each gene visibly expressed. No co-op yet. Tune
until the first mutation is a real, visible decision.
