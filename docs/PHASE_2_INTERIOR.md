# Phase 2 — Complex-cell interior re-architecture (deep dive)

Companion to `docs/PHASE_2.md` (the design brief) and `docs/PHASE_2_ECONOMY.md` (the
closed-form economy). Written 2026-06-08 after a first playable draft of the layer.

The bio names below (ER, Golgi, cytoskeleton, mitochondria) are how the *organelle shapes*
and the code refer to them; for the player-facing panel/label copy each pairs with a plain
factory role — see the glossary in `docs/PHASE_2.md` → "Player-facing language."

## Status & scope

The phase-2 economy is built and sound: `sim.lua` + `catalog.lua` are a closed-form,
fully-tested model (the lab pins FORK at ~10 min). **This doc does not touch that.** The
problem is the **presentation layer** — `view.lua`, `interior_swarm.lua`, and the panel.
Right now the interior reads as an undifferentiated glittering blob with no recognizable
organelles, and the bottleneck/flow language the whole phase is built around is illegible
on screen. This is a re-architecture of *how the cell looks and reads*, not how it plays.

The north star is the reference cross-section the player pictures when they hear "cell":
nucleus + nucleolus, rough ER ribbons studded with ribosomes hugging the nucleus, a Golgi
stack, bean-shaped mitochondria with cristae, a cytoskeleton of filaments, vesicles in
transit, the plasma membrane. We use that **only as inspiration** — invent sections and
connections that read well, don't replicate the diagram literally — and keep the GPU swarm
as the hero for the "growth is detail" wow.

## Decisions locked (2026-06-08)

- **Render target: a hard pixel grid.** Not smooth shapes — a chunky, low-res pixelated
  look. The clean path is rendering the whole interior to a low-resolution canvas (~1/3
  native) with nearest-neighbor filtering, then upscaling, so organelles *and* swarm
  pixelate uniformly and cheaply. (Alternative — snapping each shape/vesicle coordinate to a
  grid — is more work and less uniform; the low-res canvas is the recommendation.)
- **Mitochondria sit still.** No roaming; stable, drawn beans.
- **Cargo is typed.** Vesicles carry a cargo *type* (transcript / folded protein / secretory
  vesicle / lipid / ATP) with a fixed small palette, not a per-leg tint. Type maps naturally
  onto the leg it rides, so the cloud reads as identifiable traffic.
- **Reference fidelity: inspiration only.** Sections and connections are invented for
  legibility, not copied from the diagram.
- **Swarm: start with a handful, grow on level-up.** The phase-1 "fills as you grow" feel,
  driven by line capacity (see "The swarm" section).
- **Swarm speed/brightness = efficiency.** Balanced, well-powered ratios run fast and bright;
  imbalance or power deficit slows and dims them (see "The swarm" section).
- **Phase-1 unlock pricing (150 / 2500 bm): left as first-pass for now.** Tune later; focus
  is phase 2.

## What's wrong today (diagnosis, grounded in the code)

1. **There are no organelles.** The only drawn structures are one wobbling membrane circle
   (`draw_membrane`), one nucleus circle (`draw_nucleus`), and that's it. The ER, Golgi,
   mitochondria, and cytoskeleton — the things that make a cell legible — **do not exist as
   shapes**. Nothing on screen says "cell."

2. **Mitochondria are invisible.** They are not drawn at all — they're *emitter points*
   scattered by a hash (`build_routes`: `hash01(m * 4.7)` on `MITO_RING_FRAC`). The one
   organelle a player recognizes on sight is represented as nothing but an invisible target
   the swarm flies toward.

3. **The swarm is one homogeneous cloud on a featureless ring.** Every stage endpoint sits
   on a single `RING_FRAC` circle at evenly-spaced angles (`stage_angle`), and every vesicle
   is an identical additive white quad. There's no cargo identity and no destination
   legibility, so the cloud is a uniform smear (exactly the screenshot). The ring also
   **throws away all spatial meaning** — real anatomy is nested and zoned (nucleus centre,
   ER hugging it, Golgi adjacent, mitochondria roaming, membrane at the rim), and a circle
   of equal dots encodes none of that.

4. **State is unreadable on the body.** The flow language (congestion clump, bottleneck
   pinch, vacancy off-screen) lives entirely in subtle per-segment shader params over an
   already-illegible cloud. Brownout dims everything globally (that part reads), but
   "**which** stage is the bottleneck / congested / starved" is lost in the glitter. The
   panel computes `bottleneck_id` and never shows it on the interior.

5. **Panel and interior are disconnected.** The panel lists stages top-to-bottom; the
   interior puts them on a ring at unrelated positions; nothing (colour, position, label)
   ties "Golgi Lv 2" in the panel to a thing on screen. The two dashboards don't reference
   each other.

6. **Panel layout bugs (visible in the screenshot).** The level-up button's cost sublabel
   overlaps the stage flavor text — "translate the genome…" collides with "31.5 atp",
   "transcription gets its own ro[om]" collides with "25.1 atp". Row height / button
   placement is too tight. Standalone bug, easy fix, fold it into this pass.

## Design goals

- **Keep the swarm wow.** It stays the hero — the screen-filling teeming cloud is the
  "growth is detail" payoff. We frame and direct it, we don't replace it.
- **Recognizable structures.** Each organelle is a simple programmatic shape at an
  anatomically sensible position, drawn from the reference. Splines + simple polygons,
  low-fi, cheap.
- **The interior IS the dashboard.** You can see the bottleneck, congestion, and vacancy on
  the *body*, anchored to real organelles, without reading the panel.
- **Cheap sim, expensive visuals (unchanged pillar).** Structures are a handful of CPU
  shapes per frame; the swarm stays GPU closed-form. The authoritative path is untouched.

## The new architecture

### 1. Anatomical layout — zones, not a ring

Replace the single `RING_FRAC` ring with **stable, anatomically-anchored positions** keyed
to the reference. Suggested scheme, all relative to cell centre `(cx, cy)` and radius `r`:

| Organelle | Position | Role in the pipeline |
|-----------|----------|----------------------|
| Nucleus | centre | blueprints (hub) |
| Rough ER | band hugging the nucleus, ~`0.30–0.50 r`, biased to one side | ribosomes + fold/QC |
| Golgi | offset from the ER's outer face, ~`0.55 r` | package/sort |
| Mitochondria | roaming an inner-mid annulus, ~`0.35–0.65 r` | power (emitters) |
| Membrane | the rim, `r` | transport/export terminus |

The pipeline path (ribosomes → nucleus → ER → Golgi → transport → membrane) becomes a
**curved spline threaded through these anatomical positions** instead of a circle. The swarm
hauls along it, so the factory-flow read survives — but now on a body that looks like a
cell. The layout stays **stable**: leveling a stage never reshuffles positions (the brief's
invariant), it only grows that organelle in place.

### 2. Organelle structures — the draw list (simple shapes)

Each organelle is a recipe of splines + simple polygons, driven by its sim level/state.
These slot into a new `draw_organelles` pass between `draw_membrane` and the swarm draw in
`view.draw`. None needs an asset.

- **Nucleus** — filled disk + nucleolus dot + chromatin speckles (already have this). Level
  → speckle density. Keep, becomes the hub.
- **Rough ER** — *K* concentric quadratic/Catmull-Rom spline ribbons wrapping the nucleus on
  one side, studded with small ribosome dots along each ribbon. ER level → ribbon count /
  length; ribosomes level → dot density. Congestion → dots bunch toward the inlet.
- **Golgi** — a stack of *M* nested curved arcs (cisternae) flattening outward, with a few
  budding vesicle dots at the outer (trans) face. Golgi level → stack height.
- **Mitochondria** — **drawn objects now, not emitter points**, and **stationary**: a bean
  (squashed capsule built from two arcs / a short polygon) with 2–4 internal cristae arcs at
  fixed positions. Count = log sample of `mito` (the existing `sample_count`). A more-powered
  cell shows more beans + a brighter inner glow. Under brownout these **gutter first** (see §4).
- **Cytoskeleton (transport)** — straight tinted line segments (microtubules) radiating
  between zones. Transport level → filament count. These *are* the highways the swarm rides.
- **Membrane** — wobbling bright rim (already have this). Output → rim glow. Keep.
- **Flavor (optional, cheap)** — a lysosome/vacuole blob or two for the forgiveness buffer;
  peroxisome dots. Nice-to-have, not required for the read.

### 3. The swarm, re-pointed — keep the wow, add identity

The instancing tech (`interior_swarm.lua`) is good and stays. Two changes make the cloud
read as *directed traffic* instead of uniform glitter:

- **Roads follow the cytoskeleton.** The swarm's segment legs now connect the anatomical
  zone positions (threaded along the spline) rather than ring points. The shader already
  lerps endpoint→endpoint; for curved roads the cheap option is to **sample the spline into
  several intermediate endpoints** (we have `MAX_ENDPOINTS = 32`, plenty) so legs trace the
  filaments. No shader rewrite required.
- **Typed cargo.** Each vesicle carries a cargo *type* — transcript, folded protein,
  secretory vesicle, lipid, ATP — from a fixed small palette, not a per-leg tint. Type maps
  naturally onto the leg it rides (nucleus→ER carries transcripts, ER→Golgi folded protein,
  Golgi→membrane secretory vesicles, mitochondria→line ATP), so the cloud reads as
  identifiable streams. Cheap: a per-instance type index into a small colour-palette uniform.

Count and speed are no longer "just `built` and `output`" — they're the **swarm model**
below.

### 4. Reading state through flow — make it local and obvious

This is the core "it doesn't read well" fix. The flow math already exists in the snapshot;
we surface it **on the structures**:

- **Bottleneck spotlight.** The bottleneck stage's *organelle* gets a clear tell — an
  outline pulse / brighter halo / a small "feed me" tick — anchored on the actual shape.
  `catalog.bottleneck_id` already gives us the stage; put it on the body, not just the panel.
- **Local congestion.** An overbuilt stage's organelle visibly clogs: cargo dots pile at its
  inlet (the shader's congestion-clump now bunches at a recognizable building).
- **Local vacancy.** A starved downstream zone's roads run visibly empty beside a full
  upstream one — the *contrast between identifiable zones* is the read.
- **Staged brownout.** Keep the global dim, but sequence it: mitochondria gutter first, then
  the swarm slows, then the rim dims. A sequence reads as "losing power" far better than one
  flat global fade.
- **Shared anchor with the panel.** Tint each panel stage row to match its organelle, and
  share the bottleneck accent, so "Golgi Lv 2" in the panel and that stack on screen are
  obviously the same thing.

### 5. The swarm — population, speed, and efficiency

The swarm is the hero, so its *behaviour* carries real signal, not just decoration.

**Population: a handful at the start, growing on level-up.** Same feel as phase 1's dish
filling as the colony grows. The current draft opens with a fat cloud (`COUNT_BASE = 400`);
drop that to a handful (~8) and drive growth off the line's **capacity**, so each level-up
visibly adds cargo:

```
count = COUNT_BASE                      -- ~8: the opening handful
      + K_flow * log(1 + throughput)    -- leveling a stage adds vesicles immediately
      + K_bulk * log(1 + built)         -- the slow long-game bulk fill
```

Log-scaled and capped (the GPU ceiling is `MAX_VESICLES = 300000`), so it climbs into the
thousands without ever becoming an unreadable blur. The throughput term is what makes
leveling *feel* like growth; the `built` term is the prestige-number bulk.

**Speed + brightness = efficiency (the golden-ratio readout).** The closed-form sim already
exposes the raw material in `fold()`: `throughput` (capped by the slowest stage) and
`excess` (capacity built *above* the bottleneck — idle, wasteful machinery). Derive a pure
efficiency scalar (in `catalog`, testable, read-only — it never feeds the economy back):

```
flow_balance   = throughput / (throughput + excess)        -- 1.0 = a perfectly matched line
power_adequacy = clamp(power / (throughput*e_per_output + upkeep), 0, 1)
efficiency     = flow_balance * power_adequacy             -- 0..1, fed to the swarm
```

- **`flow_balance`** is 1.0 when every unlocked stage is matched (the "golden" balanced
  pipeline) and falls as you overbuild one stage past the bottleneck — so "max one knob"
  literally drags the cloud down, reinforcing the self-defeating dial.
- **`power_adequacy`** is <1 in a deficit; **brownout is just its extreme** (this unifies the
  brownout dim with the efficiency read rather than bolting on a second system).
- **`efficiency` → global swarm speed + brightness.** Optimal (≈1): fast, bright, streams
  flowing in smooth lockstep — a calm "this is dialed in" tell. Suboptimal: slower, dimmer,
  clumpier. Exactly the "efficient ratios move faster / inefficient slow + dim" ask.

A nice emergent beat: unlocking a new organelle opens it as the level-1 bottleneck, so
`excess` spikes and efficiency dips — the cell visibly **catches its breath**, then
accelerates as you rebuild balance. The named beat *reads* on the body for free.

Division of labour with §4: the **local** tells (bottleneck spotlight, per-stage
congestion/vacancy) say *where* the problem is; **efficiency** says *how well the whole cell
is running*. Both ride the same snapshot.

### 6. Panel readability cleanups

Fold in the standalone panel bug: the cost sublabel overlaps the stage flavor text. Fix by
raising the stage-row height (or moving the cost onto the button face / beside the label) so
the fill-column description and the button never collide. While there, confirm the
self-reveal footer ("something is forming…") and the BROWNOUT line stay as-is — those read
well already.

## Where the code changes land

The clean module separation holds; nearly all of this is in the cosmetic layer.

- **`lib/layers/complexcell/view.lua`** — the bulk. Replace `build_routes`' ring with the
  anatomical zone layout; add a `draw_organelles` pass (the §2 recipes); thread the
  bottleneck/flow tells onto the structures; set the spline-sampled endpoints; rework the
  count formula (§5: handful-base + throughput term); feed `efficiency` to swarm speed +
  brightness. Render to a **low-res canvas + nearest upscale** for the hard-pixel look.
- **`lib/layers/complexcell/interior_swarm.lua`** — small: a cargo-*type* palette uniform +
  per-instance type index; `efficiency`-driven `speed`/`brightness` uniforms (the plumbing
  exists). Legs already lerp between arbitrary endpoints, so "roads follow the cytoskeleton"
  is mostly a matter of *where view places the endpoints*.
- **`lib/layers/complexcell/catalog.lua`** — add a **pure, read-only** `efficiency(state)`
  (flow_balance × power_adequacy) onto the snapshot. Derived from the existing fold; it never
  feeds back into the economy. Unit-test it in `complexcell_catalog_spec`.
- **`lib/layers/complexcell.lua`** (panel) — the row-height/overlap fix and the
  panel↔organelle shared accent.
- **`sim.lua`** — **unchanged.** The economy is authoritative and tested; add nothing to that
  path. Structures and efficiency read *from* the snapshot, never into it.
- **`tools/phase2_lab.lua`** — unchanged; structures are cosmetic, balance stays on paper.

## Build order (each step shippable on its own)

1. **Panel overlap fix** — standalone bug, do it first.
2. **Anatomical layout** — move endpoints off the ring into zones. Immediate legibility win,
   low risk, no new shapes yet.
3. **Swarm population rework** — handful-base + throughput-driven count, so leveling visibly
   fills the cell from a sparse start.
4. **Draw the organelles** — mitochondria beans, ER ribbons, Golgi stack, cytoskeleton
   filaments. This is the "it looks like a cell" beat.
5. **`efficiency` scalar → swarm speed + brightness** — the golden-ratio readout (pure
   `catalog.efficiency`, unit-tested, wired to the swarm uniforms).
6. **Local flow tells** — bottleneck spotlight + local congestion/vacancy on the structures.
7. **Typed cargo + roads-follow-cytoskeleton** — the swarm becomes directed, identifiable
   traffic.
8. **Hard-pixel pass** — render to the low-res canvas + nearest upscale.
9. **Staged brownout + panel↔organelle shared anchor** — the polish that ties it together.

## Appendix A — Phase-1 fix shipped alongside this pass

Per the same request, the phase-1 "auto research" is removed: milestone capabilities are now
**bought**, not auto-granted by colony size.

- `check_unlocks()` (the pop-based auto-fire in `cell.lua`) is gone; the tick no longer
  grants capabilities.
- The two milestones in `traits.lua` carry a steep biomass `cost` and use `pop` only as a
  **reveal** threshold (when the buy option appears). First-pass prices: **Photosynthesis
  150 bm** (revealed at colony 5), **Phagocytosis 2500 bm** (revealed at colony 24). These
  are deliberately expensive for the phase they appear in and are tunable in `sim_lab`.
- New panel section **"evolutions"**: each unowned capability shows a buy button once
  revealed (gated on biomass), or a dim "colony N" teaser before then. Buying spends biomass
  (`sim.spend`), flips the unlock on (opening its income channel + letting the world spawn
  prey/predators), and toasts the tell. The photosynthesis *trait* still gates behind owning
  the photosynthesis evolution; its locked teaser now reads "needs Photosynthesis."
- New pure helpers `traits.unlock_cost` / `traits.is_revealed`, covered by `traits_spec`
  (66 checks, all 14 specs green).

## Resolved (see "Decisions locked")

Render = hard pixel grid · mitochondria sit still · cargo is typed · reference is inspiration
only · swarm starts small and grows on level-up · swarm speed/brightness = efficiency ·
phase-1 pricing left as first-pass.

## Still open / to settle in build

- **Efficiency curve shape:** linear `flow_balance × power_adequacy`, or ease it so the
  "optimal" band is forgiving (a wide plateau reads ~90% fast, matching the anti-overwhelm
  pillar — "clearable without tuning")? Lean: ease it.
- **Optimal tell:** what exactly "dialed in" looks like beyond fast+bright — a synchronized
  stream pulse, a steady rim, a faint chime? Pick during step 5.
- **Cargo palette:** final type set + colours (transcript / protein / secretory / lipid /
  ATP) — needs to stay legible at the pixel-grid resolution.
- **Pixel resolution:** the exact internal canvas scale (1/2? 1/3? 1/4?) — tune for the look
  vs. the swarm staying readable when dense.
