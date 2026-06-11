# Phase 2 — prestige (the plant/animal fork & seams)

How phase 2 ends and hands off. The climax is the **plant/animal fork** at the end of a long
build-out; the seams reuse the master zoom/prestige model (see `../../GAME_PLAN.md`). Companion
docs: `DESIGN.md` (mechanics), `BALANCE.md` (the gate numbers), `FAILURE.md` (the fail-state).

## The evolve-gate / climax

End-of-phase triggers at the **FORK gate** — `built` crossing the top gate threshold
(**~180k**, the last entry in the `built` gate list in `BALANCE.md`; pull the exact value from
there). It is the final beat of the science-ordered upgrade spine (`DESIGN.md`): you've stood
up every stage of the assembly line, and the cell is ready to commit to a lineage.

## The end-of-phase choice (the plant/animal fork)

The ascension-defining decision. Energy generation is **one parameterized system** with a
*fuel-source mix*: light (chloroplast, passive) vs. eating (phagocytosis, active intake).
Through the whole phase it sits at a **neutral baseline** (`fuel_factor = 1.0`) — one economy
to design, balance, and tune. At the **finale** a defining choice slams the mix to one pole and
shapes the ascension into phase 3:

- **Plant** — light-fed, self-sufficient, idle-friendly; interior fills green; biases toward
  structure / sessile growth. "Root down and grow."
- **Animal** — eating-fed, active intake, higher ceiling but needs feeding; biases toward
  motility / sensing. "Always on the move."

Made **at the end** so it's an *informed* choice (you've seen the phase) and still genuinely
retunes generation going forward. The finale modal (`fork.lua`) reads **"Choose your kingdom"**
with **"this choice shapes the ascension into phase 3."** The two cards are **PLANT** ("feeds on
light · self-reliant · steady builder") and **ANIMAL** ("eats to grow · fast · always on the
move"). Because the system is one parameter, the fork **can move earlier** if playtest wants the
paths to color the whole phase — end-of-phase is the safer default.

## The seam out (ascension into phase 3)

The zoom transition into the next phase is **open** (everything past phase 2 is deliberately
left open, see `../../GAME_PLAN.md`). `fuel_factor` — slammed to a pole at the fork — is the
knob that shapes what carries forward into phase 3 generation.

**Scope:** within phase 2 the fork only defines the ascension. **Cross-run permanence**
(choosing both paths over many runs, permanent tech) is an overarching meta we are **NOT
designing here** (see `../../GAME_PLAN.md`).

## The seam in (the phase-1 → 2 handoff)

Phase 1's endosymbiosis cinematic pushes the camera *into* the triggering cell as a **teal
dive** (no white-out wipe), ending on a full-screen teal flood — the cell's own colour as the
camera plunges inside. Phase 2 hooks here: `complexcell.enter_from_seam` opens straight out of
that same teal flood (fading it out over `INTRO_FADE`), so the hand-off is one continuous teal
with no flash or black gap, landing in the cytoplasm. The bacterium you just engulfed *is* your
first mitochondrion (`mito` starts at **1**) — seamless continuity. The collapsed phase-1 colony
carries forward as a single number — the **"becomes a statistic"** beat.

See `../phase1/DESIGN.md` for the phase-1 side of this transition.

## Placeholder / current state

The seam *in* is built (the phase-1 endosymbiosis transition lands in the cytoplasm with
`mito = 1`). The seam *out* and phase 3 are unbuilt; until phase 3 ships the fork records the
choice and shapes `fuel_factor`, with the onward ascension left open.

## Open questions

- Does the plant/animal interior diverge only at the **finale**, or **progressively** through
  the phase? (Cross-listed in `DESIGN.md` open questions.)
- Cross-run permanence / multiplier framing for the seam out — deferred to the overarching meta
  (`../../GAME_PLAN.md`), not designed in phase 2.
