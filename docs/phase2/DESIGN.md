# Phase 2 — Complex cell (design)

The design for the phase-2 (complex/eukaryotic cell) layer: the brief, the closed-form
economy spec, and the interior presentation. One of four sibling docs — `BALANCE.md` (the
tuning numbers), `FAILURE.md` (oxidative stress → lysis), and `PRESTIGE.md` (the
plant/animal fork & seams). Grounded in real eukaryotic-cell biology (organelles,
endosymbiosis, the energetics of complexity) and the phase-1 code.

Phase 1 (the cell colony, `../phase1/DESIGN.md`) is built and tuned. The phase-2
economy (`sim.lua` + `catalog.lua`) is built, tested, and lab-tuned, and the interior
presentation (`view.lua` + `interior_swarm.lua`) is largely built — anatomical zones,
the organelle draw pass, typed cargo, and efficiency-driven swarm liveliness all ship.
Everything past phase 2 is deliberately left open (see `../../GAME_PLAN.md`).

## The fantasy

At the phase-1 endosymbiosis victory you **zoom INTO a single cell** and play *inside*
it: you are now one **complex (eukaryotic) cell**, building out its internal machinery.
Growth is no longer "more cells fill the dish" — it's **detail**. The interior fills with
organelles, ribosomes, vesicles, and cargo-hauling motor proteins until it's a teeming
**internal swarm**: the same screen-filling dopamine as phase 1, one scale down.

This phase is still a *single* cell. Going **multicellular** is a *later* phase.

The phase-1 → 2 seam (the endosymbiosis zoom-in handoff) lives in `PRESTIGE.md`.

## Core loop: balance the factory

The cell is a factory + logistics network, which makes the rate-balancing verb concrete:

```
Nucleus (blueprints) → Ribosomes (build) → ER (fold/QC) → Golgi (package) →
    vesicles hauled along microtubule highways → membrane/export
                  (all powered by ATP from mitochondria)
```

- **ATP (energy) is the single currency** — both income and what every upgrade costs.
- Output is capped by the **slowest stage**. The skill is reading the bottleneck and
  feeding *that* — not maxing everything.
- **The tension (real science — Lane & Martin, "energy per gene"):** every piece of
  machinery also *burns* energy to run. Overbuild relative to your power and *net* energy
  falls. Loop: grow power plants (mitochondria) → the surplus lets you afford complexity →
  complexity demands more power. Energy gates everything — a self-regulating economy.
- **Overbuild a stage → backlog → waste** → upkeep rises faster than the benefit. Phase
  1's self-defeating dial, re-shaped as flow balancing.
- **Forgiveness lever:** the lysosome/vacuole buffer smooths mismatches; leveling it widens
  the "ignore the panel and still be fine" band. The phase must be clearable without tuning.

## The upgrade catalog

Phase 1 auto-fired milestones; phase 2 replaces that with a **deep catalog you buy from**,
where each entry **reveals as you approach its cost**:

- Hidden until ~50% banked → emerges as a faint, unnamed silhouette ("something is
  forming…") → ~75%, name and effect sharpen → 100%, lights up as affordable.
- A half-visible carrot is always just ahead, and the reveal pacing means the player is
  never dumped the whole list at once — anti-overwhelm, automatically.
- This *wants* a **large catalog** — granular per-organelle levels *and* the big named
  beats, all in one self-unfolding list.
- "Halfway" measured against the **banked pool** to start (simple, legible);
  income-projection is an alternative to test.
- The self-revealing catalog is **UI only** — it does not touch the economy.

### The upgrade spine (science-ordered named beats)

Milestone-flavored entries threaded through the catalog, in true evolutionary order:

1. **The Power Plant** — mitochondrion (carried in from the engulf). The energy unlock.
2. **Compartmentalization → The Nucleus** — walls off the blueprints; unlocks "research"
   (new buildable machinery).
3. **The Endomembrane System** — ER + Golgi; the production pipeline (the balancing verb)
   switches on.
4. **The Cytoskeleton & Highways** — centrosome + microtubule roads + motor proteins; the
   moving internal swarm and the logistics layer appear.
5. **The Big Genome** — raises ceilings; the energy-per-gene payoff (more power → more
   recipes).
6. **The plant/animal fork** — end-of-phase (see `PRESTIGE.md`).

## Player-facing language

The design is grounded in real biology on purpose, but a player should never need that
background to read the cell. **Shipped rule** (in `catalog.lua`, `complexcell.lua`,
`fork.lua`): spell the **full organelle name** as the label (no abbreviations) and pair
each with a **short active-verb role** shown on the buy row. That verb is the only guidance:
it names the step the stage owns. The whole cell reads as one assembly line —
**build → direct → fold → pack → deliver → ship** — so "feed the slowest stage" is intuitive.

| Bio term | In-game label | Role line shown on the row |
|----------|---------------|----------------------------|
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
- The **death/failure copy** — the BROWNOUT line, the vitals strip (**power balance ·
  cell stress · efficiency**), and the dying/lysis warnings ("LOW POWER / POWER OVERLOAD —
  the cell is dying") — lives in `FAILURE.md`, which is the source of truth for that copy.
- The self-reveal teaser drops raw `built` targets for plain "something is forming…" →
  "almost ready" → "ready to build!"; the finale reads **"Choose your kingdom"** with
  **"this choice shapes the ascension into phase 3."** The fork cards read **PLANT** ("feeds
  on light · self-reliant · steady builder") and **ANIMAL** ("eats to grow · fast · always
  on the move"). See `PRESTIGE.md`.

Internal terms (`built`, `throughput`, `excess`, `brownout`, `fold`) stay as-is in code and
in this spec — they're identifiers, not player copy. This section is the source of truth for
*display* copy; hold new catalog entries to the same pattern.

The end-of-phase **plant/animal fork** (the ascension-defining choice) lives in `PRESTIGE.md`.

---

# The economy (closed-form spec)

`lib/layers/complexcell/sim.lua` is the pure, deterministic, closed-form economy — no
`love.*`, no RNG — mirroring phase 1's architecture. One `sim.step(state, dt, rates)` shared
by live tick + offline. The internal swarm (organelles, ribosomes, vesicles, motors) is a
**cosmetic skin** over this, never the source of truth (so offline progress holds). The
orchestrator folds levels/counts into a **`rates`** table (the analogue of phase 1's
`intake`); `sim.step` only ever sees `rates`. The economy is the **target the lab
(`tools/phase2_lab.lua`) tunes against** — constants live in `BALANCE.md`.

## Currency & state

- **ATP / energy** is the single currency: net energy/sec banks into a buffer; every upgrade
  is bought with banked energy.
- **`built`** is the headline growth number — cumulative structure the assembly line has
  produced ("growth is detail"). Drives swarm density and the progression gates. Monotonic,
  like phase-1 `total_divisions`.

`state` = `{ energy, built, mito, stages = {id->level}, unlocked = {id->true} }`.
`mito` starts at **1** (the bacterium engulfed at the phase-1 finale — the first power plant
carried across the seam).

## The pipeline (the bottleneck verb)

Ordered stages, each with an integer `level` and a per-level rate `stage_rate` (single
lookup point: `catalog.stage_rate(id)`):

```
ribosomes → nucleus → ER → Golgi → transport → membrane
```

- **Throughput** `T = min over UNLOCKED stages of (stage_rate[s] * level[s])` — output is
  capped by the slowest stage.
- **Excess** `X = Σ over unlocked stages of max(0, stage_rate[s]*level[s] - T)` — capacity
  built above the bottleneck. Idle, backed-up machinery.

`ribosomes` is unlocked at start (so output > 0 from t=0). The rest unlock as `built` crosses
gate thresholds — the science-ordered named beats (Nucleus, Endomembrane = ER+Golgi,
Cytoskeleton = transport, Membrane/Genome). These ids are the internal stage names; for the
player-facing labels see "Player-facing language" above.

## The fold → `rates`

The orchestrator/lab computes, from state + constants:

```
power      = POWER_PER_MITO * mito * fuel_factor   -- gross ATP/sec
throughput = min over unlocked (stage_rate[s] * level[s])
excess     = Σ max(0, stage_rate[s]*level[s] - throughput)
upkeep     = UPKEEP_PER_MACHINE * (mito + Σ level[s])   -- energy-per-gene idle cost
```

plus pass-through constants `WASTE_COEF`, `E_PER_OUTPUT`, and `buffer_max`. The ATP cap
**scales with `built`** rather than pinning at a fixed wall:
`buffer_max(built) = BUFFER_BASE * (1 + built / BUFFER_BUILT_REF)`, so a *solved* cell never
parks permanently at full and meticulous tuning keeps a felt payoff. It stays pure +
state-derived, so the buffer clamp is identical online and offline.

`fuel_factor` is the **plant/animal mix** parameter — neutral baseline **1.0** through the
phase; the end-of-phase fork slams it to a pole. One economy to tune; the fork is one knob.

## The step (the closed form) — as built & tuned

```
avail = power - upkeep - WASTE_COEF * excess      -- ATP/sec free to run the line
T     = throughput ;  e = E_PER_OUTPUT ; cost_full = e * T
if avail >= cost_full then            -- fully powered: O = T, the surplus banks
  O = T
elseif avail > 0 then                 -- underpowered: THROTTLE (brownout), but hold
  O = (avail / e) * (1 - BROWNOUT_RESERVE)   -- back a reserve so net stays POSITIVE
else                                  -- power can't cover upkeep: line stops
  O = 0
end
N = avail - e * O                     -- net ATP/sec (>0 in a reserved brownout)
state.energy = clamp(state.energy + N*dt, 0, buffer_max(built))   -- cap scales with built

-- THE ROS PENDULUM -- integrated FIRST so the built cut below sees it.
demand    = e*T + upkeep
ratio     = power / demand                                   -- the balance ratio
leak      = clamp((ratio - BALANCE_HI)/(ROS_RATIO_CAP - BALANCE_HI), 0, 1)
ros      += (leak>0 ?  ROS_RISE*leak  :  -ROS_FALL) * dt     -- clamp [0,1]

-- THE BALANCE SCALAR (shared by sim + catalog.efficiency, byte-for-byte):
flow_balance  = T>0 ? T/(T+excess) : 0
power_balance = 1                              if BALANCE_LO <= ratio <= BALANCE_HI
              = ratio / BALANCE_LO             if ratio < BALANCE_LO     (deficit slope)
              = 1 - leak                       if ratio > BALANCE_HI     (surplus slope)
balance       = flow_balance * power_balance * (1 - ros)     -- clamp [0,1]

-- BALANCE CUTS REAL OUTPUT. The ATP cost (e*O) above is UNCHANGED.
efficiency_factor = MIN_EFF + (1 - MIN_EFF) * balance
state.built  = state.built + O * value_mult * efficiency_factor * dt
state.output = O                      -- readout for the view (swarm intensity)
state.brownout = (O < T - 1e-9)       -- power deficit tell
```

The lethal coupling that turns sustained imbalance into death (the live-only `stress` term fed
by surplus `ros` and the deficit half) lives in `FAILURE.md` — it reads `ros` and `brownout`
from this step but never feeds back into it.

## The three balance pillars

Three pillars give the economy a two-sided, biologically grounded pendulum.

**Pillar 1 — per-stage rates (the "golden ratio").** Each stage carries a distinct per-level
capacity (a real recipe ratio), not a uniform rate. Because throughput is
`min(rate*level)`, you **cannot skip the slow stage** — it pins the line. The level mix that
equalises every stage's cap is the inverse of the rates (≈ `1 : 2 : 3 : 2 : 1.5 : 3`), a
clean "12:7:3"-style recipe. ER and membrane are the biological rate-limiters that bite, so
bottleneck reading is a live decision. (See `BALANCE.md` for the rate table.)

**Pillar 2 — the ROS pendulum (the surplus ceiling).** Oxidative stress is two-sided.
*Biology:* mitochondria respiring with high membrane potential but low ATP demand (resting
"state-4") leak electrons producing **reactive oxygen species (ROS)**; matching production to
demand ("state-3") minimises the leak. So idle over-capacity literally damages the cell.
Idle over-power (ratio past `BALANCE_HI`) leaks `ros` ∈ [0,1], which drags `built` via the
balance scalar — the **soft cut**, felt as falling output before anything dies. The safe-power
ceiling `BALANCE_HI` is a **fixed constant** — nothing the player buys lifts it; the only fix
for running hot is to ease off power. ROS clears at the bare `ROS_FALL`. **The lethal coupling
that turns sustained imbalance into death** (surplus `ros` past `ROS_LETHAL` feeding a live-only
`stress` term, plus the deficit half) **lives in `FAILURE.md`** — soft first, lethal only on
extreme, sustained imbalance.

**Pillar 3 — balance cuts real output.** The efficiency scalar peaks inside the band, falls
off BOTH sides, and multiplies minted `built` (down to `MIN_EFF`). The ATP cost `e*O` is
**unchanged**, so the brownout/stress closed form holds — only the reward bends. This keeps
the forgiveness math intact while giving imbalance a cost you can read on the headline number.

### Determinism (online/offline)

The soft built-cut and the `ros` integral are **byte-identical online vs offline**, so
backgrounded and offline progression stay deterministic (no RNG). The intentional divergence —
the **forgiveness guard** that makes the *lethal* surplus term accrue live-only — lives in
`FAILURE.md` (it omits the lethal tail offline; the soft economy above is unaffected).

### The buffer is a pure SAVINGS account

It grows from net ATP and shrinks only when the orchestrator spends it on upgrades; it is
*never* drained to prop up an over-built line. A brownout reserves a slice of power
(`BROWNOUT_RESERVE`) for the buffer, so net stays positive in a deficit and the cell always
banks its way back to the mitochondrion that fixes it. The reserve keeps net positive in a
deficit, so the cell can never enter an unrecoverable death-spiral.

The **surplus** you spend on upgrades is `avail - e*T` when fully powered. To progress, power
must exceed upkeep + assembly cost. More machines → more upkeep → less surplus → must build
more mitochondria. **That power-vs-throughput balance is the verb** — the energy-per-gene
self-regulation, stated as math.

### Self-defeating overbuild = idle-machine upkeep

Over-level a non-bottleneck stage and you pay its buy-cost *and* ongoing upkeep for **zero**
throughput gain (it's above the bottleneck) — pure loss. This carries the penalty without an
explicit waste term, so `WASTE_COEF` ships at **0** (measuring excess against the global
bottleneck spikes at every gate-unlock, as a new level-1 stage briefly makes all prior
capacity "excess"). The sim still supports `waste_coef` for a future, non-spiking imbalance
penalty if playtest wants more bite.

**Readouts** map to the flow language: `excess>0` on a stage = **congestion**; a stage below
another's cap = **vacancy** downstream; `brownout` = the dimming power deficit.

## Costs (spending energy) — orchestrator/catalog, not sim

Geometric, like phase 1 (`COST_GROWTH`):

- stage level: `STAGE_BASE * STAGE_GROWTH ^ level`
- mitochondrion: `MITO_BASE * MITO_GROWTH ^ (mito-1)`
- stage *integration* (one-time, to bring a discovered stage online): `STAGE_UNLOCK_COST[id]`
  — see `BALANCE.md`.

## Mitochondria — keep the count, fix the picture

**No economy change.** `power = POWER_PER_MITO * mito` stays; a single count scaling into the
hundreds is biologically honest (real cells hold hundreds to thousands — a hepatocyte
~1000–2000 — forming a dynamic **fused reticulum**, not a fixed handful of beans). The fix is
visual: `sample_count` caps drawn beans at `MAX_MITO_EMITTERS = 6`, freezing the image past
~10 mitochondria. Rework the render so the picture keeps moving with the number — low count →
discrete beans at the fixed `MITO_ANGLES`; as count climbs, beans **fuse into a branched
reticulum** (merged/elongated bodies + connecting tubules, denser cristae); matrix glow tied
to power. Render-only: `view.lua` `draw_mitochondria` + the `MITO_*` constants. (Exact
reticulum thresholds are a view-tuning detail, not an economy constant.)

---

# The interior (presentation)

The economy is the source of truth (`sim.lua` + `catalog.lua` are a closed-form, fully-tested
model; the lab pins FORK at ~10 min). **The presentation never touches that** — it is the
cosmetic skin in `view.lua`, `interior_swarm.lua`, and the panel, reading from a per-frame
snapshot. The interior frames the GPU swarm with recognizable organelles at anatomical
positions and surfaces the bottleneck/flow language on the body itself.

The north star is the reference cross-section the player pictures when they hear "cell":
nucleus + nucleolus, rough ER ribbons studded with ribosomes hugging the nucleus, a Golgi
stack, bean-shaped mitochondria with cristae, a cytoskeleton of filaments, vesicles in
transit, the plasma membrane. It is **inspiration only** — the view invents sections and
connections that read well rather than replicating the diagram — and keeps the GPU swarm as
the hero for the "growth is detail" wow.

## Decisions locked

- **Mitochondria sit still.** No roaming; stable, drawn beans.
- **Cargo is typed.** Vesicles carry a cargo *type* (transcript / folded protein / secretory
  vesicle / lipid / ATP) with a fixed small palette, not a per-leg tint. Type maps onto the
  leg it rides, so the cloud reads as identifiable traffic.
- **Reference fidelity: inspiration only.**
- **Swarm: start with a handful, grow on level-up** (the phase-1 "fills as you grow" feel,
  driven by line capacity).
- **Swarm speed/brightness = efficiency.** Balanced, well-powered ratios run fast and bright;
  imbalance or power deficit slows and dims them.
- **Phase-1 unlock pricing (150 / 2500 bm): first-pass for now.** Tune later.
- **No bottleneck spotlight (rejected).** The player reads the choke from the swarm's own
  flow — congestion clumps, the bottleneck lane constricts, downstream lanes thin out — never
  from a halo pointing at "feed this one" (`view.lua` `draw_organelles`). The "feed me" halo
  that *does* exist is the separate manual-ATP-tap cue pulsing on one mitochondrion, not a
  bottleneck pointer.

### Not built (future / open)

- **Hard-pixel canvas.** Rendering the whole interior to a low-resolution canvas (~1/3 native)
  with nearest-neighbor upscale, so organelles and swarm pixelate uniformly, is **not built** —
  `view.draw` renders directly to the screen, no canvas. Whether to add it (and at what scale)
  is an open question below.

## Design goals

- **Keep the swarm wow** — frame and direct it, don't replace it.
- **Recognizable structures** — each organelle a simple programmatic shape (splines + simple
  polygons, low-fi, cheap) at an anatomically sensible position.
- **The interior IS the dashboard** — see the bottleneck, congestion, and vacancy on the
  *body*, anchored to real organelles, without reading the panel.
- **Cheap sim, expensive visuals (unchanged pillar)** — structures are a handful of CPU
  shapes per frame; the swarm stays GPU closed-form. The authoritative path is untouched.

## The architecture

### 1. Anatomical layout — zones, not a ring

Each stage sits at a stable, anatomically-anchored position relative to cell centre
`(cx, cy)` and radius `r` (the `ZONE` table + `zone_pos`/`build_routes` in `view.lua`):

| Organelle | Position | Role |
|-----------|----------|------|
| Nucleus | centre | blueprints (hub) |
| Rough ER | band hugging the nucleus, ~`0.30–0.50 r`, biased to one side | ribosomes + fold/QC |
| Golgi | offset from the ER's outer face, ~`0.55 r` | package/sort |
| Mitochondria | inner-mid annulus, ~`0.35–0.65 r` | power (emitters) |
| Membrane | the rim, `r` | transport/export terminus |

The swarm's segment legs connect these zone positions in pipeline order
(ribosomes → nucleus → ER → Golgi → transport → membrane), so the factory-flow read survives —
on a body that looks like a cell. The layout stays **stable**: leveling a stage never
reshuffles positions, it only grows that organelle in place.

### 2. Organelle structures — the draw list (simple shapes)

Each organelle is a recipe of splines + simple polygons, driven by its sim level/state. They
draw in the `draw_organelles` pass (`view.lua`) between `draw_membrane` and the swarm draw.
None needs an asset.

- **Nucleus** — filled disk + nucleolus dot + chromatin speckles (have this). Level → speckle
  density. The hub.
- **Rough ER** — *K* concentric quadratic/Catmull-Rom spline ribbons wrapping the nucleus on
  one side, studded with small ribosome dots. ER level → ribbon count/length; ribosomes level
  → dot density. Congestion → dots bunch toward the inlet.
- **Golgi** — a stack of *M* nested curved arcs (cisternae) flattening outward, with a few
  budding vesicle dots at the trans face. Golgi level → stack height.
- **Mitochondria** — **drawn objects now, stationary**: a bean (squashed capsule from two arcs
  / a short polygon) with 2–4 internal cristae arcs. Count = log sample of `mito`. More power
  → more beans + brighter inner glow. Under brownout these gutter first (see §4). At high
  counts, fuse into a reticulum (see the mitochondria render note in the economy section).
- **Cytoskeleton (transport)** — straight tinted line segments (microtubules) radiating between
  zones. Transport level → filament count. These *are* the highways the swarm rides.
- **Membrane** — wobbling bright rim (have this). Output → rim glow. Keep.
- **Flavor (optional)** — a lysosome/vacuole blob or two for the forgiveness buffer; peroxisome
  dots. Nice-to-have, not required for the read.

### 3. The swarm — directed, identified traffic

The instancing tech (`interior_swarm.lua`) is the hero and stays. Two things make the cloud
read as *directed traffic*:

- **Legs connect the zones.** The swarm's segment legs connect the anatomical zone positions
  in pipeline order rather than ring points (the shader lerps endpoint→endpoint;
  `MAX_ENDPOINTS = 32` holds the stage endpoints plus the mitochondria emitters). The
  mitochondria emitters sit at the exact positions the beans are drawn, so vesicles land on
  the visible power plants.
- **Typed cargo.** Each vesicle carries a cargo *type* from a fixed small palette
  (`CARGO_PALETTE` in `view.lua` → the `cargo_palette` shader uniform). Type maps onto the
  leg it rides (ribosomes→nucleus/nucleus→ER transcripts, ER→Golgi folded protein,
  Golgi→transport/transport→membrane secretory vesicles, mitochondria→line ATP), so the
  cloud reads as identifiable streams.

### 4. Reading state through flow — local and obvious

The flow math lives in the snapshot; the view surfaces it **on the swarm's segments** (per-leg
shader readouts in `interior_swarm.lua`, built in `build_routes`):

- **Local choke.** The bottleneck's segment constricts into a tight thread and piles cargo up
  at it, scaled by how hard it pins the line (`1 - flow_balance`) — so a balanced cell reads
  uniform, with no false choke on the nominal-minimum lane. No spotlight halo (see *Decisions
  locked*).
- **Local congestion.** An overbuilt stage's segment bows fatter, clumps, and dims (over-stuffed
  idle surplus, not a hot lane).
- **Local vacancy.** Segments downstream of the bottleneck thin out (vesicles parked off-screen)
  beside a full upstream one — the *contrast between identifiable lanes* is the read.
- **Staged brownout.** The global dim is sequenced: the mitochondria gutter first (drawn dim
  under brownout), then the swarm slows and dims. A sequence reads as "losing power" far better
  than one flat global fade.

### 5. The swarm — population, speed, and efficiency

**Population: a handful at the start, growing on level-up** (same feel as phase 1's dish
filling). The live count opens as a handful and grows off the line's **capacity** (`view.lua`):

```
count = COUNT_BASE                      -- 4: the opening handful
      + K_FLOW * log(1 + throughput)    -- leveling a stage adds vesicles immediately
      + K_BULK * sqrt(built)            -- the slow long-game bulk fill (keeps climbing)
```

Capped at the view's live cap (`MAX_LIVE_VESICLES = 4000`, well below the swarm's
`MAX_VESICLES = 300000` GPU buffer ceiling in `interior_swarm.lua`), so it climbs into the
low thousands without becoming an unreadable blur. The throughput term makes leveling *feel*
like growth; the `sqrt(built)` term is the prestige-number bulk that keeps filling the
cytoplasm late (a `log(1+built)` term flattened too early).

**Speed + brightness = efficiency.** The pure, read-only `catalog.efficiency(state)` (derived
from the existing fold, never feeding back into the economy) is the **same balance scalar the
sim uses** (`flow_balance × power_balance × (1 - ros)`):

- **`flow_balance`** is 1.0 when every unlocked stage is matched and falls as you overbuild one
  stage past the bottleneck — so "max one knob" literally drags the cloud down.
- The power side is the §Pillar-2/3 `power_balance`, which is <1 in a deficit *and* in idle
  over-power; brownout is just its deficit extreme.
- **`efficiency` → global swarm speed + brightness.** Optimal (≈1): fast, bright, streams in
  smooth lockstep — a calm "dialed in" tell. Suboptimal: slower, dimmer, clumpier.

A nice emergent beat: unlocking a new organelle opens it as the level-1 bottleneck, so `excess`
spikes and efficiency dips — the cell visibly **catches its breath**, then accelerates as you
rebuild balance. The named beat reads on the body for free.

Division of labour with §4: the **local** tells say *where* the problem is; **efficiency** says
*how well the whole cell is running*. Both ride the same snapshot.

### 6. Panel readability

The self-reveal footer ("something is forming…") and the BROWNOUT line read well and stay as-is.

## Where the code lives

The clean module separation holds; the presentation is all in the cosmetic layer.

- **`view.lua`** — the bulk. The anatomical zone layout (`ZONE`/`zone_pos`/`build_routes`); the
  `draw_organelles` pass; the per-segment bottleneck/flow tells; the zone endpoints; the count
  formula; `efficiency` → swarm speed+brightness. (Renders directly to the screen — no canvas;
  the hard-pixel canvas is unbuilt, see *Not built*.)
- **`interior_swarm.lua`** — the GPU swarm: the cargo-*type* palette uniform + per-instance type
  index, and the `efficiency`/brownout-driven brightness + integrated flow-speed. Legs lerp
  between arbitrary endpoints, so the roads are simply *where view places the endpoints*.
- **`catalog.lua`** — `efficiency(state)` is pure, read-only, derived from the fold; never
  feeds back. Unit-tested in `complexcell_catalog_spec`.
- **`complexcell.lua`** (panel) — the panel/HUD, drawn on top of the view.
- **`sim.lua`** — **never touched by the view.** Structures and efficiency read *from* the
  snapshot, never into it.
- **`tools/phase2_lab.lua`** — economy-only; structures are cosmetic, balance stays on paper.

---

# Visuals & architecture (reuse)

- The **GPU swarm renderer** (validated at ~millions of instances) renders the interior swarm
  — ribosomes, vesicles, mitochondria, motors on highways — pointed *inward*.
- Reuse: the **transition seam**, the **layer registry** (register a `complexcell` layer,
  switch on endosymbiosis), the **closed-form sim** pattern, and the **`sim_lab` harness** (add
  phase-2 scenarios; balance the energy economy on paper first, as with phase 1).
- Honest scale to aim the swarm at: a real cell holds ~10 billion proteins, 1–10 million
  ribosomes, hundreds–thousands of mitochondria, and burns ~10 million ATP/sec. The big numbers
  are accurate, not inflation.

## Science-as-lore (optional, cheap credibility)

Real, unsettled debates make good in-world *mysteries* rather than flattened facts:
nucleus-first vs. mitochondria-first; whether energy truly drove complexity (Lane vs. Lynch).
A codex that says "the record is ambiguous here" is more accurate and more interesting than
overstating consensus.

---

# Open questions

- Energy buffer size: spiky (small pool, rewards attention) vs. generous (smooth, idle-first)?
  (The build-scaling buffer cap addresses the "solved cell parks at full" half; the base-pool
  feel is still a tuning call.)
- Reveal threshold: banked-pool 50% vs. income-projection?
- How explicit is the pipeline UI vs. read purely from the cell's flow visuals?
- Exact placement of the named beats within the granular catalog (pacing).
- Does the plant/animal interior diverge only at the finale, or progressively? (Also a
  `PRESTIGE.md` open question.)
- **Efficiency curve shape:** linear, or eased so the "optimal" band is forgiving (a wide
  plateau reads ~90% fast, matching the anti-overwhelm pillar)? Lean: ease it.
- **Optimal tell:** what "dialed in" looks like beyond fast+bright — a synchronized stream
  pulse, a steady rim, a faint chime?
- **Cargo palette:** final type set + colours (transcript / protein / secretory / lipid / ATP).
- **Hard-pixel canvas:** whether to add the unbuilt low-res canvas + nearest upscale (see
  *Not built*) at all, and if so the internal scale (1/2? 1/3? 1/4?) — tune for the look vs.
  the swarm staying readable when dense.
(Tuning-side open questions — the over-power ceiling bite, ROS rise/fall, and per-stage
run-cost — live in `BALANCE.md` "Open tuning questions.")
