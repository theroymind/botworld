# Cell layer — breaking the plateau (growth, synergy, biofilm)

Working plan, 2026-06-07 (rev. 2026-06-08). Companion to `docs/CELL_LAYER.md`.
Covers why the colony stalls at ~91, a headless harness for testing balance changes,
and two levers — **trait synergy** (now shipped) and a **biofilm network stage**
(proposed) — to push the cell layer from a loose swarm into a dense, busy network.

**Scope note:** **phase 1 (this doc) is built; phase 2 — the *complex cell* — is now in
design** (`docs/PHASE_2.md`). The endosymbiosis proc that ends phase 1 (`transition.lua`)
is the **seam into phase 2** (zoom inside one cell); until phase 2 ships it still resets
into a new lineage as a placeholder. Note phase 2 is a *complex single cell*, **not**
multicellular — going multicellular is a later phase whose mechanics are open
(`GAME_PLAN.md`).

All numbers below come from `tools/sim_lab.lua`, which runs the *real* economy
modules headless. Run it yourself: `lua tools/sim_lab.lua` (or `luajit`, same as the
test runner picks).

---

## 0. SHIPPED (2026-06-08): open-ended compounding economy

The plateau is gone. The economy is no longer logistic — it **compounds**. Each cell
now adds a per-cell income that does **not** saturate (`cell.lua GROWTH_RATE` →
`sim` `intake.growth_per_cell`), so income scales with the colony and population
climbs **exponentially into the millions** instead of walling at a carrying capacity.
Phase 1 is now a **~5-minute sprint**:

| time | colony (maxed, GROWTH_RATE 0.1) |
|---|---|
| 30 s | ~950 |
| 1 min | ~3k |
| 2 min | ~16k |
| 5 min | ~1.3M |

`lua tools/sim_lab.lua growth` reproduces this from the real `sim.step`.

**Endosymbiosis is the climax, and it's RNG.** A prey engulf can keep the partner and
resolve the run into a new lineage. The per-engulf chance is `ENDO_BASE_CHANCE` plus
`ENDO_RAMP_PER_STEP` per `ENDO_STEP` (100k) cells — **possible at any size but
vanishingly rare early, near-certain once the swarm is in the millions** — so the run
almost always ends somewhere in the low millions, with variance, never on a fixed
threshold.

**Rendering samples logarithmically.** A millions-cell colony would be an unreadable
blur, so `world.sample_count(pop)` draws 1:1 up to `RENDER_KNEE` (250), then adds
`RENDER_LOG_SLOPE` agents per e-fold, capped at `MAX_AGENTS` (1500): ~458 dots at 1k,
~874 at 16k, ~1494 at 1M. The dish keeps visibly filling but stays readable. All three
constants are meant to be tuned by eye in play.

The sections below are the **history and the still-open ideas**: §1–2 explain the old
logistic wall and the harness; §3 (trait synergy) is shipped and still relevant (it
shapes the early climb); §4 (biofilm) is now **optional** — the compounding economy
already delivers the "busy network," so biofilm would be a *visual/structural* layer,
not the growth fix it was first proposed as.

---

## 1. Why it plateaued — the old logistic model (historical)

The economy is a closed form: each cell forages a little, photosynthesis adds a flat
light income, and every cell pays upkeep. The colony grows until the saturated intake
exactly meets upkeep — that crossover is the carrying capacity **K** (`sim.capacity`):

```
K = (photo + forage_per_cell × FORAGE_CAP) × mult / upkeep_per_cell
```

With the screenshot's maxed colony (Photo 5 / Motility 4 / Chemotaxis 5 / Digestion 4
/ Evasion 5, both unlocks fired, no organelles):

| term | value | where it comes from |
|---|---|---|
| `photo` | 57 | `PHOTO_LIGHT 30 × photo_mult 1.9` |
| `forage_per_cell` | 6.85 | `gain(optimum) 5.61 × forage_mult 1.22` |
| `FORAGE_CAP` | 5 | the fixed food-saturation point in `cell.lua` |
| `mult` | 2.1 | `income_mult` = 1 + photosynthesis 0.3 + predation 0.8 |
| `upkeep_per_cell` | 2.09 | `loss(optimum) 2.01 × upkeep_mult 0.8 × UPKEEP_SCALE 1.3` |

→ `K = (57 + 6.85×5) × 2.1 / 2.09 ≈ **91**` — exactly the "cap 91" on screen.

The plateau is *designed*: `FORAGE_CAP = 5` means foraging income stops scaling past a
handful of cells, so K is fixed no matter how big the swarm gets. Three things are
true at once in the screenshot, which is why it feels like a wall:

- **All five traits are near their useful ceiling** — leveling them further barely
  moves K (each trait is a small linear multiplier on one term).
- **Both milestone unlocks have already fired** (`income_mult` is maxed at 2.1).
- **The only remaining designed headroom is the two organelles**, and they're gated
  behind 350 / 1000 *lifetime* divisions — a slow drip, and rare on top (0.1% per
  engulf).

### Current designed ceiling

What the shipping game can reach today, per the harness (trait synergy is now folded
in — see §3 — which lifted the maxed baseline from the pre-synergy 91 to 110):

| state | K |
|---|---|
| maxed colony (synergy, now) | **110** |
| + mitochondrion (×2 intake) | 220 |
| + chloroplast (+40 light) | 307 |

After ~307 the colony is at its current ceiling, and **phase 1 ends** when an
endosymbiosis proc fires the new-lineage finale. The renderer also caps the visible
swarm at `MAX_AGENTS = 300` regardless — so even at the organelle ceiling the dish
never looks like a *network*, just a fuller swarm. To get the busy-network fantasy we
need both a higher K **and** a higher visual sample (that's lever B).

---

## 2. The testing harness (`tools/sim_lab.lua`)

The point of this pass: stop guessing at balance. The economy is pure, deterministic
Lua, so we can load `sim` + `metabolism` + `traits` + `organelles`, rebuild the same
`intake` fold `cell.lua` uses, and measure the exact growth curve any config
produces — **before** touching the game.

```
lua tools/sim_lab.lua                          # scenario comparison table
lua tools/sim_lab.lua sweep forage_cap 2 30 4  # one knob across a range
lua tools/sim_lab.lua sweep upkeep_scale 0.5 2 0.25
lua tools/sim_lab.lua curve "maxed colony (synergy)" out.csv   # growth curve -> CSV
```

It reports, per config: **K** (steady-state population), **time-to-50%/90%** of K,
and **peak divisions/min**. It loads the *real* `traits`/`sim`/`metabolism`/
`organelles` modules, so shipped trait synergy comes through automatically — the
harness mirrors the live game (sanity: the maxed colony prints `K = 110`). If that
number drifts, the harness's copy of the `cell.lua` tuning constants has fallen out
of sync with the game.

The still-proposed biofilm mechanic is wired in behind a `biofilm` config flag,
**off by default**, so you can A/B it against the shipping numbers. To tune synergy,
edit `SYN_REACH` / `SYN_THRIFT` in `traits.lua`; for biofilm, `BIOFILM_LINK` /
`BIOFILM_DIFFUSION` at the top of `sim_lab.lua`.

It already earned its keep — biofilm is currently *over*-tuned and its per-stage
scaling is inverted (see §4).

---

## 3. Lever A — trait synergy ("synergy with skills") — **SHIPPED**

The five traits were deliberately independent (the old adjacency strand was cut for
legibility — see `CELL_LAYER.md`). That kept each row honest but meant a build was just
"level everything," with no interaction and no fresh headroom once each row was high.
Synergy re-introduces *build* depth **without** bringing back hidden adjacency: two
trait *pairs* now multiply, each with a one-line in-fiction story, each fully readable.

Implemented in `lib/layers/cell/traits.lua` (`traits.stats`), applied in `cell.lua`'s
`intake_for`:

- **Reach = Motility × Chemotaxis → raises `FORAGE_CAP`.** Mobile, sensing cells reach
  food the colony otherwise outgrew, so the *saturation point itself climbs*. This is
  the important one: it attacks the term that pins K. `stats.forage_cap_mult =
  1 + SYN_REACH·√(motility·sensing)`, and `intake_for` does
  `forage_cap = FORAGE_CAP × forage_cap_mult`.
- **Thrift = Digestion × Evasion → extra upkeep cut.** A lean, efficient cell wastes
  less; lowers K's denominator. Folded into `stats.upkeep_mult`:
  `÷ (1 + SYN_THRIFT·√(digestion·evasion))`.

The `√(a·b)` shape rewards *balanced* investment (a one-trait spike gets little), which
is exactly the "synergy" feel — and it's neutral at level 0, so the all-zero stats stay
unchanged and every existing test still passes. Constants: `SYN_REACH = 0.06`,
`SYN_THRIFT = 0.02`.

Harness impact on the maxed colony (synergy now in the baseline):

| config | K | vs. pre-synergy |
|---|---|---|
| maxed colony, pre-synergy | 91 | — |
| maxed colony, **with synergy** | **110** | +21% |
| with synergy + both organelles | **307** | vs. 264 |

Gentle by design — synergy is a *reshaping* lever, not a multiplier blowout. It buys
~20–35% and, more importantly, gives leveling a reason to continue past "all maxed."
It is **not** enough on its own to make a network; that's lever B. Bump `SYN_REACH` in
`traits.lua` and re-run the harness if you want it to carry more weight.

**Next (UI):** surface synergy in the trait panel — e.g. a "reach +X% (Motility ×
Chemotaxis)" line that updates live as you level either partner — so the player can
*see* the pairing. The economy is done; this is presentation only.

---

## 4. Lever B — the biofilm network stage (the "busy network") — proposed

This is the headline, and still unbuilt. A biofilm is *literally* a busy network:
cells stop drifting as a loose swarm and link into a connected mat that shares
nutrients. That shared transport is the mechanic that breaks the plateau, and a dense
mat is the visual the layer is missing. It slots in as the **capstone of phase 1's
growth** — the colony climbs into a teeming network, and the endosymbiosis proc then
fires over that mat — the **seam into phase 2** (`docs/PHASE_2.md`). (Going
multicellular remains a later, open phase in `GAME_PLAN.md`.)

**Core idea:** in a biofilm the food cap is no longer fixed at 5 — the network shares
nutrients, so the saturation point *tracks the population* (`cap_eff = base + LINK·pop`).
That removes the ceiling that pins K. Left there it would run away, so it gets the core
verb's self-defeating counter: a super-linear **diffusion penalty** — denser mats
choke on their own waste, so `upkeep ×= 1 + DIFFUSION·pop`. Linear benefit vs.
quadratic cost ⇒ a **new, far larger interior K** in the hundreds-to-thousands, and a
dense network on screen, not an explosion.

This is a *new optimization family* layered on the same engine — it fits the ladder's
"rotate a different shape each phase" pillar. It's the densest, busiest the dish gets
before the run's endosymbiosis finale.

### Companion changes the harness makes obvious

1. **Raise the visual sample.** `MAX_AGENTS = 300` in `world.lua` must climb (or the
   "1 rendered agent = N colony cells" sampling must scale) or a K of thousands still
   renders as 300 dots. The swarm renderer was benchmarked at 1M instanced, so the
   ceiling is a policy choice, not a tech limit. Bump it in step with the biofilm K.
2. **Render the edges.** "Busy network" = nodes **and links**. Draw connection lines /
   a relaxed graph between nearby cells once biofilm is active — that's the visual
   payload that turns a denser swarm into a *network*.

### Harness results — and two balance findings

| config | K | peak div/min |
|---|---|---|
| maxed + synergy | 110 | 308 |
| + biofilm stage 1 | **5,430** | 22,232 |
| + biofilm stage 2 | 2,719 | 11,150 |
| biofilm s2 + organelles | 4,734 | 87,102 |

K jumps into the thousands — the network fantasy is reachable. But the harness
immediately flags two problems to fix before this ships:

- **It's wildly over-paced.** 22k+ divisions/min means the colony hits a K of
  thousands in *seconds* (`t→90%` ≈ 8s). That's not idle progression, it's an
  explosion. The biofilm benefit needs to be gated behind a slowly-accruing "biofilm
  maturity" resource (so the network *grows in* over minutes/hours), and/or
  `BIOFILM_LINK` cut hard. This is the single most important tuning task.
- **Stage 2 gives a *lower* K than stage 1** (2,719 < 5,430). The per-stage diffusion
  penalty currently outscales the per-stage benefit, so "advancing" the biofilm makes
  it worse. The stage scaling needs the benefit to grow at least as fast as the
  penalty — fix the ratio of `BIOFILM_LINK` to `BIOFILM_DIFFUSION` per stage and
  re-sweep.

Both are exactly the kind of thing the harness exists to catch on paper instead of in
playtesting.

---

## 5. Recommended sequence

1. **Ship the harness** — done (`tools/sim_lab.lua`). The balance source of truth;
   add a scenario whenever a new lever is proposed.
2. **Trait synergy** — done (`traits.lua` + `cell.lua`); maxed K 91 → 110, all tests
   green. Remaining: the trait-panel line that surfaces each pairing (presentation).
3. **Re-tune the organelle gates** — the 350 / 1000 lifetime-division gates were set
   against the old K; check they still pace well now that the curve shifted (use the
   harness `curve` mode to read time-to-K).
4. **Then the biofilm stage**, in order:
   a. Fix the two balance findings in the harness (pace + stage scaling) until a stage
      climbs to a *chosen* K (e.g. ~1,500) over a *chosen* time (e.g. tens of minutes),
      monotonic across stages.
   b. Raise `MAX_AGENTS` / the visual sample to match.
   c. Add edge rendering (the network look).
   d. Wire biofilm as a milestone unlock (like predation), gated by colony size +
      a maturity accrual — the capstone the endosymbiosis finale fires over.

Every step is checkable in the harness before it's coded: change the model or a
constant, run `lua tools/sim_lab.lua`, and read the new K / pacing / per-stage curve.

---

## 6. Open questions

- **Biofilm pacing resource:** what does "biofilm maturity" accrue from — time,
  cumulative divisions, or feed events? (Leaning: a slow passive accrual that feed
  blooms nudge, so it stays idle-first but rewards attention.)
- **Visual sample policy:** raise `MAX_AGENTS` outright, or switch fully to
  "1 sprite = N cells" weighting so a 5,000-cell film and a 90-cell swarm both read
  honestly?
- **Synergy surfacing:** show synergy as its own panel rows, or as live deltas on the
  existing trait rows when a partner is leveled?
- **Where biofilm sits vs. organelles:** parallel tracks, or does biofilm gate behind
  the organelles (so endosymbiosis → bigger cells → they form the mat)?
