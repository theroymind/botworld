# Cell layer — failure, pressures & readouts (design)

Working plan, 2026-06-08. Companion to `docs/CELL_LAYER.md`. This doc owns the
**failure model rework** and the systems it pulls in: an honest vitality readout, a
prominent replication-rate readout, a real nutrient competitor, a ramping predator
threat, and trait levels that actually read (in the sim *and* on screen).

It is a **plan, not a spec-in-stone** — the constants below are starting points to
tune in `tools/sim_lab.lua survival`, and the build order is the recommended path,
not a contract. Where a decision is still open it's called out under *Open
decisions*.

---

## Why we're reworking this

The original ask was two things: **a real failure capability**, and **traits whose
levels visibly matter** (on screen and in the sim). The first pass delivered a
failure mechanic but on a shaky foundation, and that's what this doc corrects.

What's actually in the code today (so we're course-correcting from facts, not
memory):

- **Failure = the toxicity cull.** The dish fouls at a flat `TOX_PROD = 0.5`/s
  (`cell.lua`). If clearance (`stats.cleanup`) can't keep up, `toxicity` climbs, a
  health factor `TOX_HALF / (TOX_HALF + toxicity)` throttles *all* intake
  (`sim.health`), and past `TOX_TOLERANCE = 8` the medium kills cells directly
  (`TOX_KILL_K`) until population hits 0. `is_extinct()` is the only run-ender —
  there's no aggregate threshold anymore. That part is fine.
- **"Vitality" is that health factor rendered as a raw `%`.** `cell.lua` ~line 730
  prints `vitality  NN%` and a bar. This is the poor design: a single percent that
  reads as a fuel gauge to zero, implying "0% = death" when the actual failure is
  the downstream population die-off. One pressure (toxicity) masquerades as the
  whole health of the colony.
- **Replication rate exists but is buried.** `sim.div_rate` is a real EMA of
  divisions/sec; `cell.lua` ~line 722 shows `division N /min` as one quiet line. It
  is *not* tied to the failure read, and it never goes negative (it only measures
  births, not net of deaths).
- **Predators are live-only theatre.** `world.step_predators` runs only when
  `threats_enabled`, caps kills per incursion (`PREDATOR_MAX_KILLS = 6`), and the
  kills route through `sim.kill` as a live debit. **They never run offline** and
  can't, by construction, be a real failure driver while you're away.
- **No neutral cells exist.** Only `prey` (you eat) and `predators` (eat you).
- **Traits barely read on screen.** `view.lua` (line 6) states the per-cell
  "flagella/membrane/speckle" visuals were *dropped*: the swarm is now a GPU
  procedural field driven by *count* + bloom/predator positions, drawing a uniform
  body color. So leveling Motility or Photosynthesis changes numbers but the dish
  looks the same. The economic side of traits is real; the visual side is missing.

There's also a small piece of dead wiring to sweep up: `collapse_watch` is assigned
in `cell.lua` (lines 277, 380) but never declared `local` — a leftover of the old
grace-timer threshold, now silently writing a global. It goes when the readout is
reworked.

---

## Design principles we are NOT breaking

These are load-bearing; the rework lives inside them.

1. **The economy is an authoritative closed form; the live world is a cosmetic
   skin.** `sim.lua` is the truth; `world.lua` agents are decoration. The *only*
   couplings back are `feed_burst`, `kill`, and the endosymbiosis organelle keep.
   **Every new failure pressure that must matter offline has to live in the closed
   form** (the `intake_for` fold + `sim.step`), with live agents as its visible
   skin — exactly how the cell swarm is the skin over `population`.
2. **Offline replays the live step deterministically.** `sim.offline` re-runs the
   same `sim.step` in capped sub-steps with no rng. Anything that drives the
   authoritative population must be pure and deterministic.
3. **No art pipeline.** Visual impact comes from driving shader uniforms / shape
   params from aggregate stats, not new sprites. Palette stays 2–3 tokens.
4. **Anti-overwhelm still holds.** We are adding *readouts*, not knobs. Active knobs
   on screen stay ≤3–4 (currently ~0 — the metabolism dial was removed). Failure
   must be something the player can *see coming and avert*, never a surprise wipe.

---

## The new failure model: emergent decline from three real pressures

**Decision (this session): failure is emergent, driven by a mix — predators killing
cells, nutrient scarcity from competition, and toxicity — not any single threshold.**

The reframe: stop treating "vitality" as the fail trigger. The real quantity is
**net replication** — births per second minus deaths per second. Each of the three
pressures pushes that number down. When net replication stays negative, population
declines; sustained, it reaches extinction (the existing `is_extinct()` end). The
player reads the coming failure through two honest gauges (vitality + replication),
and counters it with traits and feeding. Nothing about the run ends on a magic
number — it ends because the colony genuinely couldn't sustain itself.

### Net replication as the master quantity

In closed form, per second:

```
net_repro_rate  =  birth_rate(intake, pop)  −  death_rate(pressures, pop)

birth_rate   = (energy surplus) / (avg division cost)        -- existing economy
death_rate   = toxicity_cull + predation_deaths + (starvation when intake < upkeep)
```

`birth_rate` is today's economy (intake → energy → divisions). `death_rate`
aggregates the three pressures as explicit, separately-attributable terms so the HUD
can say *which* pressure is winning. All three are computed in `sim.step` (or folded
in via `intake`), so offline replays them identically.

This is a refactor of `sim.step`'s death side: today there's `toxicity cull` +
`carrying-capacity starvation`. We add **predation_deaths** as a sibling term and
route **competition** through the intake side (it suppresses `birth_rate` rather than
adding deaths — see below). The three remain individually legible for the readout.

### The three pressures

**1. Toxicity (reframe the existing system — keep it, demote its visual role).**
Mechanically unchanged: `TOX_PROD` fouling vs `stats.cleanup` clearance, throttling
intake and culling past tolerance. The change is *framing*: toxicity is now **one of
three** contributors to the death/throttle side, not "vitality" itself. Its counters
stay Digestion / Evasion / Photosynthesis + feeding blooms (`FEED_TOX_CLEAR`).

**2. Nutrient competition (new — real economic rival).**
A competitor population shares the finite food supply. It enters the closed form on
the **intake** side as a contention factor on foraging:

```
your_share   = pop / (pop + competitor_pop)
forage_eff   = forage_per_cell * your_share        -- competitors thin your foraging
```

(Or, equivalently, competitors draw down `forage_cap` — the saturation ceiling. The
share form is cleaner and self-balancing.) `competitor_pop` is itself a closed-form
aggregate that **ramps** — it grows over time / with field tier, so the dish gets
more crowded as the run matures and late game stays contested. Counters: Chemotaxis
(sense food first) and Motility (reach it first) lift your effective share;
out-breeding raises `pop` and thus `your_share`. The live skin: neutral
other-colored cells in `world.lua` (cosmetic), their on-screen count driven by
`competitor_pop` the same way your swarm is driven by `population`. They drift and
nibble motes but never interact with your cells (no eat, no get-eaten).

**3. Predation (promote to a real, ramping, offline-valid pressure).**
Today predators are live-only and capped — they can't end a run, especially offline.
Move the *authoritative* predation into the closed form as a death term:

```
predation_deaths = predator_pressure * (1 − evasion) * f(pop) * dt
```

`predator_pressure` **ramps** with colony size / time (the "ramping threat"
decision). `evasion` (the trait) is the direct mitigator; Motility contributes
(flee speed). `f(pop)` keeps it proportional so it scales as a *fraction* of the
colony, never a flat number that's trivial when large and lethal when small. The
live predators in `world.lua` become the **skin**: spawn rate / count scaled to
`predator_pressure`, and their visible kill bursts are cosmetic theatre over the
authoritative term. The existing live `sim.kill` debit is either retired or
reconciled so we don't double-count (decision below).

**Why this composition works:** each pressure has a distinct shape — toxicity is a
neglect tax (do nothing → choke), competition is a crowding tax (scales with the
world maturing), predation is a risk tax (scales with how juicy the colony is). A
healthy build beats all three; neglecting any *one* is survivable; neglecting the
mix is what tips you into net-negative replication and, eventually, out.

---

## The readouts (the heart of the player's ask)

### Vitality: weak → strong, not a percent-to-zero

Replace the `NN%` bar with a **qualitative band** plus color, derived from net
replication headroom (how far `net_repro_rate` is above/below zero), not from
toxicity alone:

| Band | Meaning | Color token |
|---|---|---|
| Thriving | strong positive net replication | `secondary` (nourishment green) |
| Stable | comfortably positive | `secondary` |
| Strained | thin margin; one pressure dominant | `tertiary` |
| Failing | net replication negative; population sliding | `quaternary` |
| Collapsing | deep negative; extinction approaching | `quaternary`, pulsing |

Keep a bar as the analog backing, but the **label is the read**, and it reflects the
whole colony's health (all three pressures), not just waste. Add a **trend arrow**
(▲ rising / ▼ falling) so the player sees direction, which is what "is this run okay"
actually depends on.

### Replication rate: prominent, signed, and *net*

Promote replication to a headline readout, and make it **net** (births − deaths) so
it can go negative — the single most honest "are you winning" number:

```
+1,240 /min   (green, ▲)        -- thriving
   −340 /min   (red,   ▼)        -- dying; vitality will follow
```

This requires extending `sim.div_rate` (births-only EMA today) with a deaths EMA, or
tracking a `net_repro_rate` EMA directly in `sim.step`. The number IS the leading
indicator: it goes red *before* vitality sinks, giving the player the "see it coming"
beat.

### Optional: a compact pressure breakdown ("accurate representation")

To make *why* legible without clutter, a small three-segment indicator showing which
pressure is eating your growth right now — e.g. `waste 60% · rivals 30% · predators
10%` of the current death/throttle, as a thin stacked bar or one muted line under
the replication readout. Keeps anti-overwhelm (it's a readout, not a knob) while
answering "accurate representation of what's happening." **Open: include in v1 or
defer to a polish pass.**

---

## Trait impact: make every level a visible counter to a pressure

The second half of the original ask. Two fronts: **sim impact** (mostly there;
sharpen the pressure-counter mapping) and **visual impact** (largely missing).

### Sim side — each trait clearly answers a pressure

The mapping is already most of the way there in `traits.stats`; we make it explicit
and make sure each level moves a pressure the player can feel:

| Trait | Primary pressure it counters | Lever (existing constant) |
|---|---|---|
| Photosynthesis | growth vs all (more birth headroom) + toxicity (oxygenation) | `PHOTO_PER`, `CLEAN_PER_PHOTO` |
| Motility | competition (reach food first) + predation (flee) | `FORAGE_MOTILITY_PER`, `SPEED_PER` |
| Chemotaxis | competition (out-sense rivals for scarce food) | `SENSE_PER`, `FORAGE_SENSING_PER` |
| Digestion | toxicity (primary clearance) + birth rate (cheaper divisions) | `CLEAN_PER_DIGESTION`, `DIV_FACTOR` |
| Evasion | predation (dodge) + toxicity (lean metabolism) | `EVASION_K`, `CLEAN_PER_EVASION` |

Net effect: there's no longer a "useless" trait under any failure mode — whichever
pressure is winning, *some* trait is the answer, and the breakdown readout points at
it. The synergies (`SYN_REACH`, `SYN_THRIFT`) keep rewarding a balanced build.

### Visual side — drive the GPU field from the folded stats

Because the swarm is a GPU procedural field (`cell_field.lua`) with global uniforms,
trait levels can recolor/animate the *whole* field cheaply — no per-cell features, no
art. Proposed uniform drives (all from `traits.stats`, sent once per frame):

- **Photosynthesis → body hue.** Shift `body_color` toward green / raise pigment
  saturation per level. The dish visibly greens as you invest. (New uniform or a
  shift on the existing `body_color`.)
- **Motility → swim/weave rate + streak.** Drive `SWIM_RATE` and a slight motion
  stretch from `stats.speed`, so a motile colony visibly darts where a sluggish one
  drifts.
- **Evasion → body size / membrane firmness.** Scale instance size / rim from the
  evasion fold, so a nimble colony reads as tighter, firmer cells.
- **Chemotaxis → sense halo.** A faint radius ring or reach shimmer scaled by
  `sense_range` (cheap additive pass), so the "wider hunt" is visible.
- **Energy/agitation → wobble** (already partly there) for the alive feel.

This turns "the dish visibly answers your mutation" (the 15-minute promise in
`CELL_LAYER.md`) from aspiration into fact, within the GPU-field architecture.

---

## Build sequence (recommended)

Each phase is shippable and independently verifiable. Earlier phases de-risk the
framing before we touch balance.

**Phase A — Readout reframe (no balance change).** Replace `vitality NN%` with the
weak→strong band + trend arrow; promote replication to a signed, net headline
number; delete the `collapse_watch` dead wiring. Pure presentation over the existing
toxicity model — immediately fixes the "0% = death" framing. *Verify: HUD reads
sensibly across a clean run and a neglected die-off; no economy/offline change.*

**Phase B — Net-replication & pressure decomposition in the closed form.** Refactor
`sim.step`'s death/throttle side into explicit, separately-attributable terms
(toxicity, predation, starvation) and track a `net_repro_rate` EMA. Wire the new
readouts to it. No new pressures yet — just make the math legible and the readouts
honest. *Verify: `sim_lab survival` shows the same time-to-extinction as today;
offline determinism preserved (re-run = identical).*

**Phase C — Nutrient competition.** Add `competitor_pop` (ramping closed-form
aggregate) and the `your_share` foraging contention to `intake_for`; add neutral
colored competitor cells to `world.lua` as the cosmetic skin (count ∝
`competitor_pop`). *Verify: `sim_lab survival` with competition on/off; confirm a
mid-game colony feels the squeeze but a strong forager (Motility/Chemotaxis) holds
share.*

**Phase D — Predator ramp.** Promote predation to the closed-form
`predation_deaths` term with `predator_pressure` ramping; scale live predator spawns
to it; reconcile/retire the live `sim.kill` debit to avoid double-counting; confirm
Evasion/Motility are real counters. *Verify: `sim_lab survival` predator curves; a
low-evasion colony gets thinned, an evasive one shrugs; offline die-off is now
possible from predation, deterministically.*

**Phase E — Trait visual impact.** Drive `cell_field` uniforms (hue, swim rate,
size, sense halo) from `traits.stats`. *Verify: by eye — level each trait and watch
the dish change; screenshot diffs.*

**Phase F — Balance & verification pass.** Tune the whole failure curve in
`sim_lab survival` so: a neglected founder dies in a sensible window (~current
~1.5–2 min feel), a lightly-tended colony survives, several *distinct* builds all
survive (no single dominant trait), and late game stays contested by the
competition+predation ramps. Extend `tests/cell_sim_spec.lua`, `traits_spec.lua`,
`world_spec.lua` for the new terms. *Verify: full `make test` green; sim_lab tables
reviewed.*

---

## Verification strategy

- **`tools/sim_lab.lua survival`** is the balance harness (it already drives
  toxicity on, photosynthesis+predation unlocked, and measures time-to-collapse).
  Extend it with competition and the ramping-predation terms so the whole failure
  curve is tuned on paper before the live game. **Mirror every constant change in
  both `cell.lua`/`traits.lua` and the harness** (the doc's standing rule).
- **Unit tests** (`tests/`, run via `make test`): the new closed-form terms get
  spec coverage in `cell_sim_spec.lua` (death decomposition, net_repro_rate,
  offline determinism with all pressures), `traits_spec.lua` (each pressure-counter
  fold), `world_spec.lua` (competitor skin spawns/clears, predator scaling).
- **Offline-determinism guard:** a test that runs N live steps vs one `sim.offline`
  of the same duration and asserts identical state, *with all three pressures
  active* — the load-bearing invariant.
- **By-eye visual pass** for Phase E (screenshots before/after each trait level).

---

## Open decisions (yours to call before / during build)

1. **Predation double-count:** when predation becomes a closed-form term, do we
   *retire* the live `sim.kill` debit entirely (live predators become pure
   theatre), or keep a small live debit and have the closed-form term cover only the
   offline/aggregate share? Recommendation: **retire the live debit; closed-form is
   authoritative, live is skin** — cleanest, matches the swarm model.
2. **Competition coupling:** `your_share` contention (recommended, self-balancing)
   vs competitors drawing down `forage_cap`. Both are closed-form; share is tidier.
3. **Competitor ramp shape:** time-based, field-tier-based, or colony-size-based?
   (Tier-based ties it to the same beats as the zoom-outs.)
4. **Pressure-breakdown readout:** ship in v1 (Phase B) or defer to polish?
5. **Vitality source:** derive purely from `net_repro_rate` headroom (recommended,
   reflects all pressures) vs a weighted composite that also weights raw toxicity.
6. **Palette for competitors:** within the 2–3 token discipline, a desaturated
   neutral of an existing token vs introducing one more muted hue.

---

## One-line summary

Stop calling toxicity "vitality." Make failure the honest outcome of net replication
going negative under three real, closed-form pressures — waste, competition,
predation — surface it as a weak→strong vitality band plus a signed replication/min
headline, give every trait a visible job countering a pressure, and tune the whole
curve in `sim_lab` before it touches the live dish.
