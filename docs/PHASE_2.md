# Phase 2 — Complex cell (design brief)

Companion to `docs/CELL_LAYER.md`. Distilled from the phase-2 brainstorm, 2026-06-08,
grounded in real eukaryotic-cell biology (organelles, endosymbiosis, the energetics of
complexity) and the existing phase-1 code.

## Status

Phase 1 (the cell colony) is built and tuned. **Phase 2 is the next layer to build; this
doc is its design target — it is not yet implemented.** Everything past phase 2 is
deliberately left open (see `GAME_PLAN.md`).

> **Balance/biology revision LANDED — see `docs/PHASE_2_BALANCE.md` and
> `docs/PHASE_2_ECONOMY.md`.** A first playable draft surfaced that mitochondria are
> pure upside and the balance readout is cosmetic. The revision makes balance a
> two-sided pendulum (idle over-power leaks ROS), gives stages distinct rates (a real
> recipe ratio), and surfaces player-facing gauges. A later pass **removed** the
> stabilization/antioxidant counter-lever and the oxygen gauge (they made over-power
> never bite and read as clutter) and **fixed** the safe-power ceiling, so running hot
> is now a real cost with the honest fix being to ease off power. Read it alongside
> this brief.

## The fantasy

You grew a colony in phase 1. At the endosymbiosis victory you **zoom INTO a single cell**
and play on *inside* it: you are now one **complex (eukaryotic) cell**, building out its
internal machinery. Growth is no longer "more cells fill the dish" — it's **detail**. The
interior fills with organelles, ribosomes, vesicles, and cargo-hauling motor proteins until
it's a teeming **internal swarm**: the same screen-filling dopamine as phase 1, one scale
down.

This phase is still a *single* cell. Going **multicellular** is a *later* phase, not this
one.

## The seam (reuse what's built)

Phase 1's endosymbiosis cinematic already pushes the camera *into* the triggering cell and
white-outs before resetting (`transition.lua`). Phase 2 hooks here: instead of resetting,
punch through the white-out and land in the cytoplasm. The bacterium you just engulfed *is*
your first mitochondrion — seamless continuity. The collapsed colony carries forward as a
single number (the "becomes a statistic" beat).

## Energy is the currency

- **ATP (energy) is the single currency** — both income and what every upgrade costs.
- **The tension (real science — Lane & Martin, "energy per gene"):** every piece of
  machinery you build also *burns* energy to run. Overbuild relative to your power and *net*
  energy falls. So the loop is: grow power plants (mitochondria) → the surplus is what lets
  you afford complexity → complexity demands more power. Energy gates everything, which makes
  it a self-regulating economy — you can't spam upgrades you can't power.
- **Shape:** an energy/sec rate plus a modest, upgradeable buffer. Keep the economy an
  authoritative **closed form** (like phase-1 `sim.lua`); the internal swarm is a cosmetic
  skin on top, never the source of truth (preserves offline progress).

## Core loop: balance the factory

The cell is a factory + logistics network, which makes the rate-balancing verb concrete:

```
Nucleus (blueprints) → Ribosomes (build) → ER (fold/QC) → Golgi (package) →
    vesicles hauled along microtubule highways → membrane/export
                  (all powered by ATP from mitochondria)
```

- Output is capped by the **slowest stage**. The skill is reading the bottleneck and feeding
  *that* — not maxing everything.
- **Overbuild a stage → backlog → waste** (misfolded protein, oxidative stress) → upkeep
  rises faster than the benefit. Phase 1's self-defeating dial, re-shaped as flow balancing.
- **Forgiveness lever:** the lysosome/vacuole buffer smooths mismatches; leveling it widens
  the "ignore the panel and still be fine" band. The phase must be clearable without tuning.

## Reading state through flow (not bars, not red)

The interior *is* the dashboard:

- **Congestion** — an overbuilt/backed-up stage: cargo piles up and clumps (a jam at the
  Golgi, ribosomes bunching idle). Crowding = waste.
- **Vacancy** — a starved stage downstream of a bottleneck: sparse, idle machines, empty
  highways.
- **Brownout** — energy deficit: everything slows and dims, motors walk sluggishly. The
  on-theme tell for "complexity you can't power."
- Balanced = calm, even flow.

Red-pulsing is held in reserve as an accessibility accent **only** if the flow-language
isn't legible enough in playtest.

## Upgrades: a self-revealing catalog (no auto-milestones)

Phase 1 auto-fired milestones; phase 2 replaces that with a **deep catalog you buy from**,
where each entry **reveals as you approach its cost**:

- Hidden until ~50% banked → **emerges as a faint, unnamed silhouette** ("something is
  forming…") → ~75%, the name and effect sharpen → 100%, it lights up as affordable.
- Effect: a half-visible carrot is always just ahead, and the reveal pacing means the player
  is never dumped the whole list at once — anti-overwhelm, automatically.
- Implication: this *wants* a **large catalog** — granular per-organelle levels *and* the big
  named beats, all in one self-unfolding list.
- "Halfway" measured against the **banked pool** (simple, legible) to start; income-projection
  is an alternative to test.

## The upgrade spine (science-ordered named beats)

Milestone-flavored entries threaded through the catalog, in true evolutionary order:

1. **The Power Plant** — mitochondrion (carried in from the engulf). The energy unlock.
2. **Compartmentalization → The Nucleus** — walls off the blueprints; unlocks "research"
   (new buildable machinery).
3. **The Endomembrane System** — ER + Golgi; the production pipeline (and the balancing verb)
   switches on.
4. **The Cytoskeleton & Highways** — centrosome + microtubule roads + motor proteins; the
   moving internal swarm and the logistics layer appear.
5. **The Big Genome** — raises ceilings; the energy-per-gene payoff (more power → more
   recipes you can run).
6. **[end-of-phase fork — below]**

## Player-facing language (the gamer-friendly layer)

The brief above is grounded in real biology on purpose — but a player should never need that
background to read the cell. **Shipped rule** (in `lib/layers/complexcell/catalog.lua`,
`lib/layers/complexcell.lua`, `lib/layers/complexcell/fork.lua`): spell the **full organelle
name** out as the label (the player asked "what is ER?" — no abbreviations), and pair each
with a **short active-verb role** shown right on the buy row. That verb is the only guidance:
it names the step the stage owns, so a backed-up line maps to its organelle without a "this
increases X" hand-hold. The whole cell reads as one assembly line — **build → direct → fold →
pack → deliver → ship** — so "feed the slowest stage" is intuitive.

Stage glossary (bio term → in-game label → role line shown on the row):

| Bio term | In-game label | Role line |
|----------|---------------|-----------|
| Ribosomes | Ribosomes | assemble the cell's parts |
| Nucleus | Nucleus | direct the whole assembly line |
| Endoplasmic reticulum | **Endoplasmic Reticulum** | fold raw parts into working shape |
| Golgi apparatus | **Golgi Body** | pack and label each finished part |
| Cytoskeleton | **Cytoskeleton** | haul cargo across the cell |
| Plasma membrane | **Cell Membrane** | export the product and seal the cell |
| Mitochondria | Mitochondria | power plants — make the ATP that runs everything |

Readouts & warnings, in plain terms:

- `throughput` → **"line speed"** (the line's max rate); `output` → **"making … /s"** (what
  it's actually producing now). `ATP` is labelled **"ATP energy."**
- **BROWNOUT** → "not enough power, production slowed." The **dying** warning and the **lysis**
  toast *state the problem only, never the fix* (the player reads the vitals and picks the
  lever): they name which side of the balance drove it — **"LOW POWER — the cell is dying"**
  vs **"POWER OVERLOAD — the cell is dying"**, and on death "The cell burst — low power" vs
  "… power overload." (Oxidative stress is two-sided now — a deficit *or* idle over-power —
  so the old deficit-only "restore power" copy was dropped.) The vitals strip is trimmed to
  the three gauges the player acts on: **power balance · cell stress · efficiency.** (The
  earlier "oxygen use" row was demand/power — a restatement of power balance that barely
  moved — so it was dropped as noise.)
- The self-reveal teaser drops raw `built` targets for plain "something is forming…" →
  "almost ready" → "ready to build!"; the finale reads **"PATH CHOICE — become a plant or an
  animal."** The fork cards trade "sessile/motility" for "root down and grow" / "always on
  the move."

Internal terms (`built`, `throughput`, `excess`, `brownout`, `fold`) stay as-is in code and in
the economy/interior specs — they're identifiers, not player copy. This section is the source
of truth for the *display* copy; hold new catalog entries to the same pattern.

## The plant/animal fork (end-of-phase, ascension-defining)

- Energy generation is **one parameterized system** with a *fuel-source mix*: light
  (chloroplast, passive) vs. eating (phagocytosis, active intake). Through the whole phase it
  sits at a **neutral baseline** — one economy to design, balance, and tune in the harness.
- At the **finale**, a defining choice slams that mix to one pole and shapes the **ascension
  into phase 3**:
  - **Plant** — light-fed, self-sufficient, idle-friendly; the interior fills green; biases
    toward structure / sessile growth.
  - **Animal** — eating-fed, active intake, higher ceiling but needs feeding; biases toward
    motility / sensing.
- Made at the end so it's an *informed* choice (you've seen the phase) and still genuinely
  retunes generation going forward. Because the system is just one parameter, the fork can be
  moved *earlier* if playtest wants the paths to color the whole phase — the architecture
  supports both; end-of-phase is the safer default.
- **Scope:** within phase 2 the fork only defines the ascension. Cross-run permanence —
  choosing both paths over many runs, permanent tech — is an **overarching meta we are NOT
  designing here** (see `GAME_PLAN.md`).

## Visuals & architecture (reuse)

- The **GPU swarm renderer** (validated at ~millions of instances, currently unused by the
  cell layer) renders the interior swarm — ribosomes, vesicles, mitochondria, motors on
  highways — pointed *inward* this time.
- Reuse: the **transition seam**, the **layer registry** (register a `complexcell` layer,
  switch on endosymbiosis), the **closed-form sim** pattern, and the **`sim_lab` harness**
  (add phase-2 scenarios; balance the energy economy on paper first, as with phase 1).
- Honest scale to aim the swarm at: a real cell holds ~10 billion proteins, 1–10 million
  ribosomes, hundreds–thousands of mitochondria, and burns ~10 million ATP/sec. The big
  numbers are accurate, not inflation.

## Science-as-lore (optional, cheap credibility)

Real, unsettled debates make good in-world *mysteries* rather than flattened facts:
nucleus-first vs. mitochondria-first; whether energy truly drove complexity (Lane vs.
Lynch). A codex that says "the record is ambiguous here" is both more accurate and more
interesting than overstating consensus.

## Open questions

- Energy buffer size: spiky (small pool, rewards attention) vs. generous (smooth, idle-first)?
- Reveal threshold: banked-pool 50% vs. income-projection?
- How explicit is the pipeline UI vs. read purely from the cell's flow visuals?
- Exact placement of the named beats within the granular catalog (pacing).
- Does the plant/animal interior diverge only at the finale, or progressively?
