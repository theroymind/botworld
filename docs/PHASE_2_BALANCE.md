# Phase 2 — balance & biology redesign (proposal)

Companion to `docs/PHASE_2_ECONOMY.md` (the current closed-form spec) and
`docs/PHASE_2.md` (the design brief). This doc is a **proposal for review** — it
critiques the shipped phase-2 economy, then specifies a redesign that makes balance
a real, two-sided, biologically-grounded pendulum. No code has changed yet; the
constants below are first guesses to be pinned in `tools/phase2_lab.lua`.

When accepted, this **supersedes** the uniform-stage-rate model and the
cosmetic-only efficiency readout in `docs/PHASE_2_ECONOMY.md`.

---

## 1. The critique (what's wrong today)

### 1.1 Mitochondria are pure upside — there is no pendulum

`power = POWER_PER_MITO * mito` and `upkeep = UPKEEP_PER_MACHINE * (mito + Σlevel)`
(`lib/layers/complexcell/catalog.lua:153,196`). Each mitochondrion nets
`10 - 0.25 = +9.75` gross ATP/sec; its only cost is the gentle `MITO_GROWTH^n`
price. **Surplus power carries no penalty** — it is free headroom that prevents
brownout. The failure system (oxidative stress, `sim.lua:140-168`) only integrates
on a power *deficit*. So "buy mitochondria forever, never think about ATP" is
precisely what the math rewards. The economy has a floor (brownout) but no ceiling.

### 1.2 The "golden ratio" (efficiency) is cosmetic and toothless

`catalog.efficiency()` (`catalog.lua:374-406`) returns
`flow_balance * power_adequacy`, eased. It is **read-only** — it drives swarm speed
and brightness and nothing else. It never gates `built`, never costs ATP, never
triggers a consequence. Worse:

- `power_adequacy` is **clamped to 1** at or above demand (`catalog.lua:395`), so
  *over*-powering is completely invisible to the readout.
- Every stage shares `STAGE_RATE = 5` and `STAGE_GROWTH = 1.12`, so
  "buy the cheapest stage" already keeps the pipeline balanced. Reading *which*
  stage is the bottleneck is a no-op decision — the exact gap
  `docs/PHASE_2_ECONOMY.md:155-162` lists as the known open tuning task.

There is no recipe to hit, so there is no ratio to feel.

### 1.3 Visual count diverges from the number (the biology smell)

Visible mitochondria = `floor(MITO_BASE + MITO_SCALE * ln(1 + mito))` capped at
`MAX_MITO_EMITTERS = 6` (`view.lua:244-255,91-93`). At `mito ≥ 10` the picture is
frozen at 6 beans, so buying 10 → 30+ looks identical. The player upgrades 30 times
and sees 7-8 blobs — the number and the image disagree.

**On the biology itself:** having "many mitochondria" is *not* the inaccuracy — real
cells hold hundreds to thousands (a hepatocyte ~1000-2000), and they form a dynamic,
**fused reticulum** that splits and merges, not a fixed handful of discrete beans.
So the count axis is fine; the *rendering* is what's wrong. The fix is visual, not
economic (see §5).

---

## 2. Design goals for the redesign

1. **Two-sided pendulum.** Too little power browns out (exists); too much *idle*
   power must also hurt. The safe zone is a band, not a floor.
2. **A real recipe ratio** (Factorio 3:1 / 12:7:3 feel) between the pipeline
   stages, so reading and feeding the bottleneck is a live decision.
3. **Teeth.** The balance readout must move real numbers (built / yield), not just
   pixels.
4. **Legibility.** A few explicit, biologically-named gauges and a one-line
   "what to upgrade" nudge.
5. **Forgiveness preserved.** Soft first, lethal only on sustained *extreme*
   imbalance, and **offline/idle can never brick** the cell.

---

## 3. Pillar 1 — stoichiometric stage ratios (the "golden ratio")

### Problem
Uniform `stage_rate = 5` means the only load-bearing decision is power-vs-throughput;
the pipeline self-balances on cost alone.

### Proposal
Give each stage a **distinct per-level throughput**, so the level ratio that
equalises every stage's capacity is non-trivial. `stage_rate(_id)` in
`catalog.lua:135` is already a function, so this is a table lookup — no structural
change. Add `STAGE_DEFS[id].rate`:

| stage      | proposed rate | biology (why) |
|------------|---------------|----------------|
| ribosomes  | 12 | translation is high-throughput; ribosomes are numerous |
| nucleus    | 6  | transcription is moderate |
| er         | 4  | folding + quality-control is the classic rate-limiter |
| golgi      | 6  | sorting/packaging, moderate |
| transport  | 8  | motor highways move cargo fast |
| membrane   | 4  | export/insertion is a frontier bottleneck |

Because throughput is `min(rate * level)`, you **cannot skip the slow stage** — it
pins the line. To keep all caps equal the level ratio is the inverse of the rates,
e.g. ribosomes : er ≈ **1 : 3** (`12·1 = 4·3`), and across the line a clean
"12:7:3"-style recipe. That ratio *is* the golden ratio the player learns to hold.

### Consequences (all already wired to `stage_rate`)
- `catalog.bottleneck_id` / `catalog.stage_snapshot` congestion now point at a
  genuinely-mismatched stage — the readout becomes meaningful.
- `integration_seed_level` (`catalog.lua:280`) still seeds at a fraction of line
  throughput; no change needed.
- Re-tune so balanced play still FORKs in ~10-13 min (lab task, §7).

> Optional depth (defer): a per-stage run-cost `e_per_output[id]` so a slow stage is
> also power-hungry, layering a power-stoichiometry on top of the throughput one.
> Recommend shipping rate-differentiation first and measuring before adding this.

---

## 4. Pillar 2 — the ROS pendulum (symmetric stress + a counter-lever)

### Problem
Stress only rises on deficit; surplus is consequence-free.

### Biology
Mitochondria respiring with a high membrane potential but **low ATP demand** (the
resting "state-4" condition) leak electrons from the transport chain, producing
**reactive oxygen species (ROS)**. Matching ATP production to demand ("state-3")
minimises the leak. So *idle over-capacity literally damages the cell* — accurate
science-as-lore, and exactly the missing ceiling.

### Mechanic
With `demand = e*T + upkeep`, define the **balance ratio**

```
balance_ratio = power / demand
```

and a **safe band** `[BALANCE_LO, BALANCE_HI]`:

- `BALANCE_LO = 1.0` — below it the line can't run fully → **brownout + stress**
  (the existing deficit half, unchanged).
- `BALANCE_HI ≈ 1.6` — a healthy reserve margin (a loose nod to φ as the
  "ideal headroom"). Between `LO` and `HI` is calm.
- Above `BALANCE_HI`, idle respiratory capacity leaks → **ROS rises**, scaled by how
  far past the band you are:

```
ros_severity = clamp((balance_ratio - BALANCE_HI) / (ROS_RATIO_CAP - BALANCE_HI), 0, 1)
```

with `ROS_RATIO_CAP ≈ 3.0` (3× the needed power = max leak). ROS integrates like
stress, into a new `ros` ∈ [0,1] on `state`:

```
ros += (ros_severity > 0 ?  ROS_RISE * ros_severity
                         : -ROS_FALL * stabilization_clear) * dt   -- clamped [0,1]
```

### The counter-lever — stabilization (antioxidants)
A new buyable **stabilization** track (superoxide dismutase / catalase / glutathione
— the cell's real antioxidant defenses). Level `stab` (geometric cost, modest
upkeep) does two things:

- raises tolerance: `BALANCE_HI_eff = BALANCE_HI + STAB_TOLERANCE * stab`
  (you can run hotter before ROS starts), and
- speeds clearance: `stabilization_clear = 1 + STAB_CLEAR * stab`.

This gives a *second valid strategy*: instead of perfectly matching power, invest in
stabilization and run a surplus on purpose. It is also the lever the gauge points at
when ROS climbs (§6).

### Soft then lethal (and the forgiveness guard)
- **Soft:** `ros` scales down the balance scalar (Pillar 3), bleeding `built`. A
  player overbuilding power *feels* it as falling output before anything dies.
- **Lethal:** only when `ros` is sustained above `ROS_LETHAL ≈ 0.8` does it begin
  feeding the existing `stress` toward `STRESS_FAIL` (lysis) — a generous warning
  window, and one stabilization or a few spends pulls you back.
- **Offline never bricks:** the lethal contribution accrues **live only**. In
  `sim.offline` the surplus-ROS term is capped at the soft ceiling and never
  triggers lysis — you can leave a hot cell running and come back to a dimmed, not
  dead, cell. The deficit tail keeps its existing recoverable-by-reserve guarantee.
  This preserves the "clearable without tuning" pillar.

> Implementation note: `ros` is additive bookkeeping like `stress`
> (`sim.lua:140-168`) — it must not touch `energy`/`built`/`output` directly except
> through the balance scalar, so online == offline stays deterministic (no RNG).

---

## 5. Pillar 3 — give the balance scalar economic teeth

### Problem
`efficiency()` moves only pixels; over-power is invisible.

### Proposal
1. **Unclamp the power side into a peak.** Replace the `clamp(power/demand, 0, 1)`
   with a curve that **peaks inside the band and falls off both sides** — under-power
   (deficit) *and* over-power (toward `ROS_RATIO_CAP`) both pull it down. Concretely:

   ```
   power_balance = 1                         if BALANCE_LO ≤ ratio ≤ BALANCE_HI_eff
                 = ratio / BALANCE_LO        if ratio < BALANCE_LO        (deficit slope)
                 = 1 - ros_penalty(ratio)    if ratio > BALANCE_HI_eff    (surplus slope)
   ```

2. **Make it load-bearing.** Multiply minted `built` by an efficiency factor derived
   from the scalar, alongside the existing `value_mult`:

   ```
   built += O * value_mult * efficiency_factor * dt
   efficiency_factor = MIN_EFF + (1 - MIN_EFF) * balance_scalar      -- e.g. MIN_EFF = 0.4
   ```

   So a badly-balanced cell mints as little as 40% of its potential `built`, while a
   well-balanced one mints full value. **ATP cost (`e*O`) is left unchanged**, so the
   brownout/stress closed form is untouched — only the *reward* bends. This keeps the
   forgiveness math intact while finally giving imbalance a cost you can read on the
   headline number.

The combined scalar (`flow_balance` from stage excess × the new `power_balance` ×
`ros` drag) is what the swarm brightness/speed already visualise — now it also means
something.

---

## 6. Pillar 4 — mitochondria: keep the count, fix the picture

**No economy change.** `power = POWER_PER_MITO * mito` stays; a single count that
scales into the hundreds is biologically honest. No efficiency split, no hard cap —
`MITO_GROWTH^n` already paces purchases.

**Render fix (the actual bug).** `sample_count` caps the drawn beans at
`MAX_MITO_EMITTERS = 6` (`view.lua:91-93,244-255`), freezing the image. Rework the
mitochondria render so the picture keeps moving with the number:

- low count → discrete beans (today's look), at the fixed `MITO_ANGLES`;
- as count climbs, beans **fuse into a branched reticulum** (merged/elongated bodies
  and connecting tubules) with **denser cristae** — the real fused-network look —
  instead of clamping to 6;
- tie matrix glow to power as today.

This is **render-only**: `view.lua` `draw_mitochondria` + the `MITO_*` constants. The
sim, the fold, and offline math are untouched. (Exact reticulum thresholds are a
view-tuning detail, not an economy constant.)

---

## 7. Pillar 5 — gauges & the "what to upgrade" nudge

The interior-as-dashboard is elegant but too implicit. Add a small readout (panel
section or HUD strip), each metric biologically named and tied to a lever:

| gauge | meaning | the lever |
|-------|---------|-----------|
| **Oxidative stress (ROS)** | the new pendulum metric (§4), 0-100% | stabilization |
| **Balance ratio** | `power / demand` vs. the safe band — under / ideal / over | mitochondria ↔ pipeline |
| **Oxygen / respiration** | O₂ available to oxidative phosphorylation | (see options below) |
| **Build efficiency** | the §5 scalar as a single % ("running at 72%") | whichever is off |

**What-to-upgrade hint** — one line derived from data already computed in
`fold` / `stage_snapshot` (a read, not new sim): pick the dominant problem and name
its lever, e.g. *"ER is the bottleneck — feed it,"* *"power deficit — add a
mitochondrion,"* or *"oxidative stress rising — raise stabilization."*

### Oxygen — one open decision for sign-off
Mitochondria need O₂ for oxidative phosphorylation, so an oxygen gauge is natural.
Two ways to realise it:

- **(a) Displayed metric only (recommended first).** Oxygen is an *informational*
  reskin of respiration load — supply from mitochondria vs. the ATP draw — shown so
  the player has a named, intuitive read on "am I respiring efficiently?" No new
  economy. Smallest scope, immediate legibility.
- **(b) Managed input (depth option).** Oxygen becomes a real gated input the player
  must supply — and this is where it gets interesting: it maps straight onto the
  planned **plant/animal fork** (`docs/PHASE_2.md:106-123`), where `fuel_factor` is
  already the light-vs-eating mix. Animal = active O₂/nutrient intake; plant =
  photosynthetic supply. Oxygen-as-input could foreshadow that fork. Bigger scope and
  needs its own lab pass.

**Recommendation:** ship (a) now; keep (b) noted as the natural extension that ties
the gauge into the fork. **This is the one item I'd like signed off before
implementation.**

---

## 8. Proposed constants (first guesses — to be pinned in the lab)

```
-- Pillar 1: per-stage throughput (replaces uniform STAGE_RATE = 5)
STAGE_RATE = { ribosomes=12, nucleus=6, er=4, golgi=6, transport=8, membrane=4 }

-- Pillar 2: the ROS pendulum
BALANCE_LO      = 1.0     -- below → brownout (existing deficit half)
BALANCE_HI      = 1.6     -- top of the safe headroom band (loose φ)
ROS_RATIO_CAP   = 3.0     -- power/demand at which ROS leak maxes
ROS_RISE        = 1/40    -- ~40s of max surplus to fill ROS (gentle)
ROS_FALL        = 1/8     -- ~8s to clear once back in band
ROS_LETHAL      = 0.8     -- ROS above this starts feeding lethal stress
STAB_TOLERANCE  = 0.15    -- each stabilization level lifts BALANCE_HI
STAB_CLEAR      = 0.5     -- each level speeds ROS clearance

-- Pillar 3: teeth
MIN_EFF         = 0.4     -- worst-case built multiplier from imbalance
```

Stabilization cost curve mirrors the existing geometric shape
(`STAB_BASE`, `STAB_GROWTH ≈ 1.12`) with a small `UPKEEP_PER_MACHINE` contribution.

---

## 9. Open tuning questions (for `tools/phase2_lab.lua`)

- Exact stage-rate ratio and the resulting balanced level mix (does the recipe read
  as a clean ratio in play?).
- Band bounds `BALANCE_LO/HI` and `ROS_RATIO_CAP` — wide enough to be forgiving,
  tight enough to bite.
- ROS rise/fall and `ROS_LETHAL` — confirm the warning window is generous and a hot
  idle cell offline only dims, never dies.
- Stabilization strength/cost — a real alternative strategy, not a tax.
- Oxygen: option (a) vs (b) (the §7 sign-off).
- Re-confirm **balanced play FORKs in ~10-13 min** and **no policy bricks** (add
  `overpower!` — chase power, ignore demand — as a new trap scenario beside the
  existing `throughput!`).

## 10. Migration notes

The tuning constants are mirrored byte-for-byte across `catalog.lua` (`:14-17`),
`tools/phase2_lab.lua`, and `docs/PHASE_2_ECONOMY.md`. Any implementation of this
proposal must update all three together, and add specs for: the symmetric ROS
integration, the unclamped peak-in-band balance scalar, and the built-yield teeth.
