# Cell layer — economy, harness & balance

Working notes, 2026-06-07 (rev. 2026-06-08). Companion to `docs/CELL_LAYER.md`.
Covers the shipped compounding economy, the headless harness for testing balance
changes on paper, and trait synergy (shipped).

> Trimmed 2026-06-08: the historical "plateau at ~91 / old logistic model" analysis and
> the unbuilt, over-tuned **biofilm network stage** proposal were removed — the plateau no
> longer exists (the economy compounds; see below) and biofilm was never built. The
> evergreen parts (current economy, the harness, shipped synergy) are kept.

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

## 1. The shipped economy — open-ended compounding

The economy is not logistic — it **compounds**. Each cell adds a per-cell income that
does **not** saturate (`cell.lua GROWTH_RATE` → `sim` `intake.growth_per_cell`), so
income scales with the colony and population climbs **exponentially into the millions**
instead of walling at a carrying capacity. Phase 1 is a **~5-minute sprint**:

| time | colony (maxed, GROWTH_RATE 0.1) |
|---|---|
| 30 s | ~950 |
| 1 min | ~3k |
| 2 min | ~16k |
| 5 min | ~1.3M |

`lua tools/sim_lab.lua growth` reproduces this from the real `sim.step`.

**Endosymbiosis is the climax, and it's RNG.** A prey engulf can keep the partner and
resolve the run. The per-engulf chance is `ENDO_BASE_CHANCE` plus `ENDO_RAMP_PER_STEP`
per `ENDO_STEP` (100k) cells — **possible at any size but vanishingly rare early,
near-certain once the swarm is in the millions** — so the run almost always ends
somewhere in the low millions, with variance, never on a fixed threshold.

**Rendering samples logarithmically.** A millions-cell colony would be an unreadable
blur, so `world.sample_count(pop)` draws 1:1 up to `RENDER_KNEE` (250), then adds
`RENDER_LOG_SLOPE` agents per e-fold, capped at `MAX_AGENTS` (1500): ~458 dots at 1k,
~874 at 16k, ~1494 at 1M. The dish keeps visibly filling but stays readable. All three
constants are meant to be tuned by eye in play.

---

## 2. The testing harness (`tools/sim_lab.lua`)

The point: stop guessing at balance. The economy is pure, deterministic Lua, so we can
load `sim` + `metabolism` + `traits` + `organelles`, rebuild the same `intake` fold
`cell.lua` uses, and measure the exact growth curve any config produces — **before**
touching the game.

```
lua tools/sim_lab.lua                          # scenario comparison table
lua tools/sim_lab.lua sweep forage_cap 2 30 4  # one knob across a range
lua tools/sim_lab.lua sweep upkeep_scale 0.5 2 0.25
lua tools/sim_lab.lua curve "maxed colony (synergy)" out.csv   # growth curve -> CSV
```

It reports, per config: **K** (steady-state population), **time-to-50%/90%** of K, and
**peak divisions/min**. It loads the *real* `traits`/`sim`/`metabolism`/`organelles`
modules, so shipped trait synergy comes through automatically — the harness mirrors the
live game (sanity: the maxed colony prints `K = 110`). If that number drifts, the
harness's copy of the `cell.lua` tuning constants has fallen out of sync with the game.

To tune synergy, edit `SYN_REACH` / `SYN_THRIFT` in `traits.lua` and re-run.

This is the tool we'll lean on to take **phase 2** from prose to numbers — add phase-2
scenarios and balance the energy economy here first, the same way (see `docs/PHASE_2.md`).

---

## 3. Trait synergy ("synergy with skills") — **SHIPPED**

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

Gentle by design — synergy is a *reshaping* lever, not a multiplier blowout. It buys
~20–35% and, more importantly, gives leveling a reason to continue past "all maxed."
Bump `SYN_REACH` in `traits.lua` and re-run the harness if you want it to carry more
weight.

**Next (UI):** surface synergy in the trait panel — e.g. a "reach +X% (Motility ×
Chemotaxis)" line that updates live as you level either partner — so the player can
*see* the pairing. The economy is done; this is presentation only.

---

## 4. Open balance tasks

- **Organelle gates.** The 350 / 1000 lifetime-division gates on the mitochondrion /
  chloroplast were set against the old curve; check they still pace well now that the
  economy compounds (use the harness `curve` mode to read time-to-K).
- **Synergy surfacing (UI).** Show synergy as its own panel rows, or as live deltas on
  the existing trait rows when a partner is leveled?
