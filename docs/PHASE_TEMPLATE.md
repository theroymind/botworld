# Phase doc template

The canonical shape for every phase's design docs. Each phase lives in `docs/phaseN/`
and is described by **exactly four documents** with the same section skeleton, so any
phase reads the same way. Distilled from phase 1 (cell colony) and phase 2 (complex
cell); carry it forward to every future phase.

```
docs/phaseN/
  DESIGN.md     -- what the phase is and how it plays
  BALANCE.md    -- the numbers and how they're tuned
  FAILURE.md    -- the fail-state (or its deliberate absence) and its readouts
  PRESTIGE.md   -- how the phase ends and hands off to the next
```

Rules of the road:

- **One concern per doc.** Mechanics → DESIGN. Tuned constants → BALANCE. Decline /
  fail-state → FAILURE. End-of-phase + seams → PRESTIGE. When a topic spans two, the
  *shape* goes in its home doc and the *numbers* go in BALANCE.
- **Cross-link, don't duplicate.** A constant is defined in one place and referenced
  elsewhere (`see BALANCE.md`). Two docs must never restate the same fact.
- **State the current design, not its history.** No "was X, now Y", no "removed lever",
  no changelog prose. If a decision was reversed, document only the decision that stands.
- **Inherit, then specialise.** The master pillars, prestige model, and core verb live in
  `../../GAME_PLAN.md`. Each doc says how *this* phase specialises them and flags any
  deliberate departure — it doesn't re-derive the master plan.
- **Every section is optional if empty.** A phase with no co-op or no end-of-phase choice
  simply omits that subsection — but keep the four files and the section order, so the
  skeleton stays recognisable.
- **Voice:** terse design-doc markdown. Prose over bullet-walls where it reads better.

---

## DESIGN.md — what the phase is and how it plays

The brief. The authoritative description of the phase's fantasy, verb, economy, and
presentation. Constants are named here but valued in BALANCE.

1. **Header & status** — one line on what this phase is; status (in design / built /
   tuned); links to `../../GAME_PLAN.md`, the previous/next phase, and the three sibling
   docs. What's built vs. open.
2. **Fantasy** — the player feeling and the scale: what you're tending, what growth *looks*
   like at this scale, the spirit. The one-paragraph pitch.
3. **Pillars** — the phase-specific pillars (inherits the master pillars in GAME_PLAN).
   Call out any deliberate departure from a master pillar and why.
4. **Core loop & the verb** — the central optimization verb (the dial / balance / knob this
   phase rotates in), the self-defeating mechanic that makes allocation a decision, and the
   numbered idle loop (generate → spend → tune → offline).
5. **Progression** — the upgrade surface (catalog / strand / spine): how the player spends,
   the named milestone beats in order, and how new content reveals/unlocks.
6. **The economy (closed-form spec)** — currency and `state`; the pure, deterministic step
   (throughput, costs, the fold into a `rates`/`intake` table); the live-skin-over-pure-core
   split. Equations live here; their constants live in BALANCE.
7. **Player-facing language** — in-game labels and readout copy, and the rule mapping
   internal identifiers (code terms) to display text. Source of truth for display copy.
8. **Presentation / visual system** — the cosmetic skin: programmatic visuals driven by
   aggregate numbers, what each element is driven by, what reads on screen. No art pipeline.
9. **Co-op** — ambient synergy for this phase, if any (omit if solo-only).
10. **Architecture & reuse** — the modules and their boundaries, the pure-core / live-skin
    split, and what engine tech / prior-phase patterns are reused.
11. **Open questions** — undecided design calls (not tuning — those go in BALANCE).

## BALANCE.md — the numbers and how they're tuned

Every value with semantic weight, and the harness that pins it. The target the lab tunes
against; DESIGN carries the mechanics these numbers parameterise.

1. **Header** — what this owns; the headless harness used (`tools/sim_lab.lua`,
   `tools/phase2_lab.lua`, …) and how to run it; the rule that any constant is mirrored in
   both code and harness.
2. **Locked constants** — the tuned values, grouped, with a one-line *why* on each tuning
   constant. Note where each is mirrored (code module ↔ harness).
3. **Cost curves & gates** — the cost formulas (geometric growth, etc.) and the unlock /
   gate thresholds, with the reasoning for the curve shape.
4. **Derived tuning** — recipe ratios, synergy multipliers, render sampling, anything
   computed from the constants that shapes pacing.
5. **What the lab found (goals → results)** — the scenario/policy comparison table: each
   design goal and the measured result that confirms it (length, forgiveness, the verb
   biting).
6. **Open tuning questions** — knobs still to dial and what to watch when dialing them.

## FAILURE.md — the fail-state and its readouts

How (or whether) the player can lose, as an honest outcome of the economy — never a magic
threshold. For an automated phase with no fail-state, this doc is short: state that it
inherits the master no-fail pillar and why.

1. **Header** — the failure model in one line, or "no fail-state — inherits the master
   no-fail pillar (see `../../GAME_PLAN.md`)" with the reasoning.
2. **The pressures** — the forces that push toward decline (e.g. toxicity / competition /
   predation; or an over-/under-balance pendulum). Each pressure's distinct shape.
3. **The master quantity** — the single closed-form number whose sign/level decides the run
   (net replication; sustained stress → death), and the equation that drives it.
4. **Readouts** — how the player sees failure coming: the gauge, label, or trend that
   communicates it before it's terminal. Anti-overwhelm: readouts, not new knobs.
5. **The counters** — what the player does to avert it (which traits / levers answer which
   pressure), so no pressure is unanswerable and no trait is useless.
6. **Determinism & offline contract** — how failure behaves live vs. offline; any
   forgiveness guard (e.g. a lethal term that accrues live-only) and what stays byte-identical.
7. **Open decisions** — unresolved calls on the failure model.

## PRESTIGE.md — how the phase ends and hands off

The end-of-phase beat: the climax that resolves the run, the choice (if any) that shapes
ascension, and the zoom seams in and out. Inherits the master prestige model in GAME_PLAN.

1. **Header** — the prestige beat for this phase in one line; inherits the master prestige
   & zoom model (`../../GAME_PLAN.md`).
2. **The evolve-gate / climax** — what triggers end-of-phase (a proc, a gate threshold, a
   mega-project) and the math/conditions behind it.
3. **The end-of-phase choice** — the ascension-defining decision, if any (e.g. a fork), and
   how it retunes what carries forward. Omit if the phase has no branch.
4. **The seam out** — the zoom transition into the next phase: what collapses into a single
   producing number + carried multiplier ("becomes a statistic"), and what the next phase
   inherits as its starting state.
5. **The seam in** — how this phase received the handoff from the previous one (the reused
   transition tech, the carried-forward state). Omit for phase 1.
6. **Placeholder / current state** — what happens at the seam until the next phase ships
   (e.g. reset as a stand-in).
7. **Open questions** — cross-run permanence, multiplier framing, and other unresolved
   prestige calls.
