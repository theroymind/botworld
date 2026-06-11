# Phase 1 — cell layer: failure

Phase 1 deliberately **has** a fail-state: failure is the honest outcome of **net
replication** going negative under three real, closed-form pressures — waste, competition,
predation. This is a deliberate departure from the master no-fail pillar
([`../../GAME_PLAN.md`](../../GAME_PLAN.md)), *for phase 1 specifically* — the no-fail
pillar still holds for the later, automated phases. The mechanics live in
[DESIGN.md](DESIGN.md); the constants in [BALANCE.md](BALANCE.md).

## The pressures

Failure is emergent — driven by a mix, never a single threshold. Each pressure pushes net
replication down with a distinct shape; a healthy build beats all three, neglecting any
*one* is survivable, and neglecting the mix is what tips the run net-negative and,
eventually, out. The single run-ender is `is_extinct()` (population reaches 0) — there is no
aggregate magic number.

**1. Toxicity — the neglect tax.** The dish fouls at a flat `TOX_PROD`/s; the colony clears
waste at `stats.cleanup`. Net positive waste accrues as `toxicity`, which throttles the
*whole intake side* by a health factor `TOX_HALF / (TOX_HALF + toxicity)` — 1 in a clean
dish (so a tended colony behaves exactly as the untaxed economy), falling toward 0 as waste
builds, at which point upkeep outruns the choked intake and the colony starves back down.
Past `TOX_TOLERANCE` the medium kills cells directly (`TOX_KILL_K`) down to extinction.
Counters: Digestion (primary) / Evasion (lean metabolism) / Photosynthesis (oxygenation) +
feeding a bloom (`FEED_TOX_CLEAR` flushes a chunk of waste). It is part of the closed form,
so offline replays it identically. Do nothing → choke.

**2. Nutrient competition — the crowding tax.** Rivals take a growing share of the food as
the lineage ages, entering the closed form on the **intake** side as an AGE-keyed saturating
throttle on the intake multiplier (it scales *all* gain channels, so it keeps biting at
millions-scale, never a `competitor_pop` aggregate):

```
comp_frac(age) =  COMP_FRAC_MAX * (1 − exp(−age / COMP_TAU))   -- saturating time ramp
your_share     =  1 / (1 + comp_frac(age) * (1 − counter))     -- mult *= your_share
```

`comp_frac` **ramps** with the lineage clock (`state.age`) — the dish gets more crowded as
the run matures, so late game stays contested — and saturates toward `COMP_FRAC_MAX`. It
never kills directly; it throttles intake so an over-crowded colony tips over its carrying
capacity and **starves** (the starvation column is competition's fingerprint). `counter` is
the forage/motility mitigation, clamped to [0,1]: Motility is the dominant lever
(`COMP_MOTILITY_COUNTER` per level — outswim the rivals to the food), with Chemotaxis and
motility's own forage gain helping through `forage_mult`. A mobile forager keeps
`your_share` near 1; an immobile colony eats the full crowding tax. Live skin: neutral
other-colored cells in `world.lua` whose on-screen count is driven by `comp_frac(age)`
intensity; they drift and nibble motes but never interact with your cells (no eat, no
get-eaten).

**3. Predation — the risk tax.** The *authoritative* predation lives in the closed form as
an age-ramped, floorless cull fraction **plus** a fear/harassment intake throttle:

```
pred_pressure(age) =  clamp(PRED_BASE + PRED_RAMP * (age / PRED_TAU), .., PRED_MAX)
evasion_mit        =  1 − min(PRED_MIT_CAP, evasion * PRED_EVASION_GAIN)  -- surviving fraction
pred_cull_frac     =  pred_pressure(age) * evasion_mit                    -- the per-second cull (sim.step)
fear               =  clamp(1 − PRED_FEAR * pred_cull_frac, FEAR_FLOOR, 1) -- mult *= fear
```

`pred_pressure` **ramps** with the lineage clock (`state.age`), clamped at `PRED_MAX` so it
can never instant-wipe. Mitigation is *not* a bare `1 − evasion`: the weak shipped evasion
stat is amplified by `PRED_EVASION_GAIN` and capped at `PRED_MIT_CAP`, so a maxed build stays
slightly contested (never immune). `pred_cull_frac` is removed as a fraction of the colony
each step (so it scales with size, never a flat number), and does **not** floor at 1 — an
unevaded colony decays to literal extinction. The same cull also drives the **fear**
throttle: heavy predation suppresses intake (cells flee instead of feed), so a high-evasion
build feels almost no fear and still climbs while a zero-evasion build's births collapse *and*
the cull runs — the death-spiral. The live predators in `world.lua` are the **skin**: spawn
rate / count scaled to the threat, their kill bursts cosmetic over the authoritative term.

## The master quantity

The real quantity is **net replication** — births per second minus deaths per second,
carried in `state.net_rate` (an EMA smoothed over the same horizon as the division rate). In
closed form, per step:

```
births  =  divisions minted this step      -- the existing economy: energy surplus → divisions
deaths  =  births − (population change)     -- every cell that vanished: starvation + toxicity + predation
net     =  (births − deaths) / dt           -- folds into state.net_rate (EMA)
```

`births` is the economy (intake → energy → divisions). `deaths` is recovered from the net
population change — the starvation, toxicity, and predation culls are all applied in
`sim.step`, so the signed `net_rate` reflects all three at once. Everything is computed in
`sim.step` (with the pressures folded in via `intake`), so offline replays it identically.
When net replication stays negative the population declines; sustained, it reaches
extinction. Nothing ends on a magic number — the run ends because the colony genuinely
couldn't sustain itself.

## Readouts

Anti-overwhelm holds: we add *readouts*, not knobs (active on-screen knobs stay ≤3–4).
Failure is something the player can *see coming and avert*, never a surprise wipe.

**Vitality — a weak → strong band, not a percent-to-zero.** Derived from PER-CAPITA
net-replication headroom (`net_rate / population`, so it reads the same at 100 cells or a
million), reflecting the whole colony's health across all three pressures, not toxicity
alone. A bar backs it but the **label is the read**, plus a **trend arrow** (▲ rising / ▼
falling, from the sign of `net_rate`) for direction:

| Band | Meaning | Color token |
|---|---|---|
| Thriving | strong positive net replication | `secondary` (nourishment green) |
| Stable | comfortably positive | `secondary` |
| Strained | thin margin; one pressure dominant | `tertiary` |
| Failing | net replication negative; population sliding | `quaternary` |
| Collapsing | deep negative; extinction approaching | `quaternary`, pulsing |

**Replication rate — prominent, signed, and net.** A headline number, net (births −
deaths) so it can go negative — the single most honest "are you winning" read, and the
leading indicator: it goes red *before* vitality sinks:

```
+1,240 /min   (green, ▲)        -- thriving
   −340 /min   (red,   ▼)        -- dying; vitality will follow
```

(Implemented as the `state.net_rate` EMA in `sim.step` — the signed net of births minus all
deaths, alongside the births-only `sim.division_rate` reference curve.)

**Pressure breakdown — not yet built in the HUD.** A compact three-segment indicator
showing which pressure is eating growth right now — e.g. `waste 60% · rivals 30% ·
predators 10%` of the current death/throttle — is a design goal but **not present in the
live readout**. Per-source death attribution exists only in the lab harness
(`tools/sim_lab.lua` `fmt_attrib`, which splits each step's deaths into toxicity /
competition-starvation / predation columns). Shipping it to the HUD as a thin stacked bar
or muted line under the replication readout is a polish-pass call (see Open decisions).

**Game-over copy — names the dominant pressure.** When the colony goes extinct the death
toast and the full-screen overlay name *what actually killed it* — waste, rivals, or
predators — instead of always blaming toxicity. The orchestrator keeps a short trailing
(EMA) per-source death read each live tick — the same closed-form decomposition the lab
harness uses (`tools/sim_lab.lua`): predation from its single-sourced cull, the rest charged
to toxicity when waste is over tolerance, else to carrying-cap starvation split between rivals
(competition bite) and predator fear. At extinction the largest recent contributor selects the
copy (`lib/layers/cell/pressures.lua` — a pure, headless-tested pick; the player-facing strings
live on the love side in `cell.lua`):

| Dominant pressure | Death copy |
|---|---|
| waste | "The colony choked on its own waste." |
| rivals | "The colony was crowded out by rivals." |
| predators | "The colony was hunted to extinction." |

## The counters

Every trait level visibly counters a pressure — there is no "useless" trait under any
failure mode. Synergies (`SYN_REACH`, `SYN_THRIFT`, see [BALANCE.md](BALANCE.md)) keep
rewarding a balanced build.

| Trait | Primary pressure it counters | Lever (constant) |
|---|---|---|
| Photosynthesis | growth vs all (more birth headroom) + toxicity (oxygenation) | `PHOTO_PER`, `CLEAN_PER_PHOTO` |
| Motility | competition (reach food first) + predation (flee) | `FORAGE_MOTILITY_PER`, `SPEED_PER` |
| Chemotaxis | competition (out-sense rivals for scarce food) | `SENSE_PER`, `FORAGE_SENSING_PER` |
| Digestion | toxicity (primary clearance) + birth rate (cheaper divisions) | `CLEAN_PER_DIGESTION`, `DIV_FACTOR` |
| Evasion | predation (dodge) + toxicity (lean metabolism) | `EVASION_K`, `CLEAN_PER_EVASION` |

## Determinism & offline contract

The economy is an authoritative closed form; the live world is a cosmetic skin. The *only*
couplings back are `feed_burst` (bloom credit) and the endosymbiosis organelle keep. **Every
failure pressure that must matter offline lives in the closed form** (the `intake_for` fold
+ `sim.step`), with live agents as its visible skin — exactly how the cell swarm is the skin
over `population`. So:

- **Offline replays the live step deterministically.** `sim.offline` re-runs the same
  `sim.step` in capped sub-steps with **no rng**. Anything driving the authoritative
  population must be pure and deterministic.
- **Predation is single-sourced through the closed form.** The authoritative, age-ramped
  `pred_cull_frac` cull lives entirely in `sim.step` (folded by `intake_for`), so it runs
  live *and* offline identically. The on-screen predators are **pure cosmetic theatre**:
  they roam, lunge, and burst their victims into red particles, but they do **not** debit the
  authoritative population — that is the swarm-is-skin model (predators are a skin over the
  closed-form cull, exactly as the cell swarm is a skin over `population`). `world.update`
  still reports kill positions so the kills read on screen, scaled to the same predator
  pressure; the closed-form cull owns the population math.
- **Competition** is a neutral cosmetic skin only — neutral cells never touch your cells.

**Load-bearing invariant:** N live steps vs one `sim.offline` of the same duration must
produce byte-identical state, *with all three pressures active*. `tools/sim_lab.lua
survival` tunes the whole failure curve on paper (toxicity on, photosynthesis + predation
unlocked, time-to-collapse measured), and the closed-form terms get spec coverage in
`cell_pressures_spec.lua` (the offline-determinism guard with predation active, the floorless
predation cull, evasion mitigation, the competition counter), `cell_sim_spec.lua` (death
decomposition, `net_rate`), `traits_spec.lua` (each pressure-counter fold), and
`world_spec.lua` (competitor skin spawns/clears, predator scaling, and that the live predator
kills are cosmetic — the visible swarm reconciles back to the authoritative target, never a
population debit).

## Open decisions

1. **Pressure-breakdown readout:** ship the three-segment indicator to the HUD (the
   `fmt_attrib` decomposition already exists in the lab) or leave it lab-only.
2. **Vitality source:** the band derives from per-capita `net_rate` headroom (shipped);
   open whether to weight raw toxicity into a composite for a sharper neglect signal.
3. **Palette for competitors:** within the 2–3 token discipline, a desaturated neutral of an
   existing token vs introducing one more muted hue.
