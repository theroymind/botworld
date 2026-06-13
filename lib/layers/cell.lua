-- Cell layer: the first playable scale -- a living micro-world. Drift a colony of
-- cells through a nutrient medium, level concrete traits, click nutrient blooms to
-- feed the reserve, and grow the colony toward its carrying capacity. This file is
-- the ORCHESTRATOR: it owns only the wiring. It folds the pure economy core
-- (metabolism + traits + organelles) into an INTAKE table -- the photosynthesis
-- light, the per-cell foraging and its finite-food saturation, the per-cell
-- upkeep, and the overall multiplier -- which sim.tick/sim.offline run the shared
-- economy step on, so idle/offline math never depends on the live agents. The live
-- world (world.lua) is a cosmetic skin over that baseline, driven only in update()
-- (never backgrounded, so offline stays pure), with exactly TWO real couplings
-- back to the economy: a nutrient-bloom click -> sim.feed_burst, and a rare prey
-- engulf -> keep an organelle (organelles.acquire + the intake fold). Predation is
-- NOT a coupling: it is single-sourced through the closed-form pred_cull_frac in
-- sim.step (folded by intake_for, runs live AND offline) -- live predators are
-- cosmetic. The pure modules know nothing of each other or of love.*; they
-- meet only here. Economy runs at a fixed sweet-spot base rate (no dial).
local save = require("lib.engine.save")
local fx = require("lib.engine.fx")
local sound = require("lib.engine.sound")
local music = require("lib.engine.music")
local format = require("lib.engine.format")
local metabolism = require("lib.layers.cell.metabolism")
local traits = require("lib.layers.cell.traits")
local sim = require("lib.layers.cell.sim")
local pressures = require("lib.layers.cell.pressures")
local organelles = require("lib.layers.cell.organelles")
local world = require("lib.layers.cell.world")
local view = require("lib.layers.cell.view")
local transition = require("lib.layers.cell.transition")
-- The Endospore prestige loop: the generic leveled-tree core, the phase-1 data over it,
-- and the confirm modal. The tree's meta-currency survives the within-phase reset
-- (reincarnate / extinction bank into it); endospores.fold mixes its node levels into the
-- intake (neutral at level 0, so a fresh game is unchanged); reincarnate.lua is the
-- voluntary cash-out card.
local progression_tree = require("lib.engine.progression_tree")
local endospores = require("lib.layers.cell.endospores")
local reincarnate = require("lib.layers.cell.reincarnate")
-- Phase-2 seam: the endosymbiosis finale no longer restarts phase 1 -- it zooms
-- INTO the cell and hands off to the complex-cell layer (see begin_lineage_transition).
local layers = require("lib.engine.layers")
local complexcell = require("lib.layers.complexcell")

-- Canonical UI kit (lib/love-ui submodule): retained-mode layout tree + renderer,
-- themed primitives, fonts, interaction. The panel below is a declarative node tree.
local ui = require("lib.love-ui")
local layout = ui.layout
local renderer = ui.renderer
local primitives = ui.primitives
-- Colors come through the game facade (NOT ui.colors): requiring it applies the
-- botworld token overrides before any value below is captured at load time.
local colors = require("lib.engine.colors")
local theme = ui.theme
local interaction = ui.interaction
local tween = ui.tween
local toast = ui.toast
local rect = ui.primitives.rect
local text = ui.primitives.text
local button = ui.primitives.button

local cell = {}

local SAVE_NAME = "cell"
local SAVE_INTERVAL = 5 -- seconds between autosaves (active layer only)
local OFFLINE_CAP = 8 * 3600 -- credit at most 8h of time away
-- DEV: ignore any existing save on boot, so every launch starts a fresh lineage
-- (a single founder cell) -- resume + offline catch-up kept getting in the way
-- while tuning. Autosaves still write during play (harmlessly unread). Flip to
-- false to restore the real idle behaviour: resume the saved colony and credit
-- up to OFFLINE_CAP of away-time growth.
local DEV_FRESH_START = true

-- Economy intake tuning (folded into sim's intake table). The colony forages
-- ambient motes per cell, but the food supply SATURATES past FORAGE_CAP cells --
-- the finite carrying capacity that makes a colony outgrow its food and starve.
-- Photosynthesis (unlocked at colony 5) opens a flat light income; predation and
-- the organelles lift the cap further.
local FORAGE_CAP = 5 -- foraging income saturates past this many cells (carrying cap)
local UPKEEP_SCALE = 1.3 -- per-cell upkeep multiplier (lowers K, slows growth, sharpens deficit)
local PHOTO_LIGHT = 30 -- flat light income once photosynthesis is unlocked (x photo_mult)
-- OPEN-ENDED COMPOUNDING growth. Each cell adds a tiny per-cell income that does
-- NOT saturate, so income scales with the colony and population climbs
-- exponentially WITHOUT BOUND -- no carrying-capacity wall and no hard population
-- cap. GROWTH_RATE is the net compounding surplus per cell (x the
-- income mult) -- the master pacing knob: higher = a steeper climb, sooner to the
-- millions. It's added ON TOP of foraging exactly covering upkeep, so the colony
-- never starves under it. Phase 1 is a ~5-minute sprint: at 0.1 the colony rockets
-- past a million cells in well under 5 min. Validate with `lua tools/sim_lab.lua growth`.
local GROWTH_RATE = 0.1

-- WASTE / TOXICITY -- the failure pressure (see sim.lua). The dish fouls at a flat
-- TOX_PROD units/sec; the colony clears waste at intake.tox_clear (the cleanup
-- traits + feeding). When fouling outruns clearance toxicity climbs and throttles
-- intake (health = TOX_HALF / (TOX_HALF + toxicity)) until upkeep outruns the
-- choked intake and the colony starves back toward the founder. A bare founder's
-- clearance (traits CLEAN_BASE) sits BELOW TOX_PROD, so an UNTOUCHED colony
-- is doomed to choke within a minute or two -- the "do nothing and you survive"
-- hole is closed. Leveling Digestion/Evasion/Photosynthesis (or feeding blooms)
-- lifts clearance past fouling and the colony thrives. Tuned via sim_lab survival.
local TOX_PROD = 0.5 -- waste produced per second (flat; the fouling rate to out-clear)
local TOX_HALF = 10 -- toxicity at which intake is throttled to half (slows growth as it fouls)
local FEED_TOX_CLEAR = 5 -- waste a single bloom feed flushes (feeding is a survival lever)
-- The cull: once toxicity passes TOX_TOLERANCE the medium KILLS cells directly
-- (sim.lua), at TOX_KILL_K of the colony per second per unit of overage. This is
-- the failure -- the colony visibly dies off, cell by cell, and (unlike ordinary
-- starvation) can reach EXTINCTION. There is NO aggregate game-over trigger: the
-- run ends only when the population actually hits 0. With the defaults an untended
-- founder grows briefly, then the cull thins it to extinction in ~1.5-2 min;
-- feeding or ~2 cleanup levels hold toxicity below tolerance and it never culls.
-- Tune via `lua tools/sim_lab.lua survival`. SOFTENED to the lab's locked, validated
-- values (was tolerance 8 / kill_k 0.035) so toxicity is co-dominant with the two new
-- pressures below rather than the sole, too-fast killer -- the lab is the source of truth.
local TOX_TOLERANCE = 26 -- toxicity below which the dish is harmless (no cull) [lab-locked]
local TOX_KILL_K = 0.005 -- fraction of the colony killed per second per unit of overage [lab-locked]

-- COMPETITION + PREDATION -- the two NEW failure pressures ported from the locked
-- sim_lab harness (tools/sim_lab.lua "PROTOTYPE -- TUNE ME" block; these values are
-- the lab's validated numbers, MIRRORED exactly so the lab stays a regression ref).
-- Both ramps are keyed on the lineage clock state.age (seconds since lineage start),
-- so they replay byte-identically offline (sim.offline advances age every sub-step).
-- Both fold into intake_for's `mult`, throttling ALL gain channels (photo + foraging
-- + the compounding climb), the way the toxicity health factor does -- so they keep
-- biting at millions-scale where raw forage is negligible.
--
-- COMPETITION (nutrient rivals): your_share = 1/(1 + comp_frac(age)*(1-counter)),
-- where comp_frac(age) = COMP_FRAC_MAX*(1 - exp(-age/COMP_TAU)) is a saturating
-- time ramp and counter = clamp((forage_mult-1)*COMP_COUNTER_GAIN, 0, 1) -- a strong
-- forager (sensing + motility) keeps its share near 1; a non-forager eats the full
-- crowding tax. It NEVER kills directly; it tips a throttled colony over its carrying
-- capacity so it STARVES (the starvation column is competition's fingerprint).
-- Retuned 2026-06-08 to bite a touch harder (a 1-level-per-trait dish was coasting
-- well past the 2-minute mark): the crowding ceiling rose 0.6 -> 0.68 and the ramp
-- TAU dropped 50 -> 42 so competition saturates sooner. MIRRORED in tools/sim_lab.lua
-- and tests/cell_pressures_spec.lua (the lab regression ref) -- keep the three in sync.
local COMP_FRAC_MAX = 0.68 -- crowding share ceiling (rivals eventually take ~40% of an uncountered colony's food)
local COMP_TAU = 42 -- time scale (s) for the rival ramp to reach ~63% of the ceiling
local COMP_COUNTER_GAIN = 2.0 -- how strongly (forage_mult-1) restores your_share (0 = uncounterable)
-- Motility is now the DOMINANT, explicit competition counter: a faster colony reaches
-- food before the rivals do, so each Motility level restores this much of your food
-- share ON TOP of its forage_mult contribution. Leaning into the "outrun rivals" verb
-- makes speed THE answer to crowding while Chemotaxis (via forage_mult) stays a helper.
-- Starting value; lab-tuned so a few levels visibly relieve the tax yet an IMMOBILE
-- colony still pays the full crowding cost. [tune via sim_lab counters/survsweep]
local COMP_MOTILITY_COUNTER = 0.05 -- share restored per Motility level (added to the forage counter)

-- PREDATION (ramping cull + a fear/harassment intake throttle -- the death-spiral):
--   pred_pressure(age) = clamp(PRED_BASE + PRED_RAMP*(age/PRED_TAU), .., PRED_MAX)
--   evasion_mit        = 1 - min(PRED_MIT_CAP, evasion*PRED_EVASION_GAIN)  -- surviving fraction
--   pred_cull_frac     = pred_pressure(age) * evasion_mit                  -- the real cull (sim.step)
--   fear               = clamp(1 - PRED_FEAR*pred_cull_frac, FEAR_FLOOR, 1) -- intake suppression
-- A high-evasion build feels almost no fear (income intact -> still climbs to the
-- millions); a ZERO-evasion build's births are suppressed AND the floorless cull runs
-- -> deaths beat births -> spiral to literal 0 (predation is SOLO-LETHAL). PRED_EVASION_GAIN
-- is the lab-side amplifier turning the shipped (weak ~0.20 maxed) evasion stat into a
-- real mitigator; PRED_MIT_CAP keeps a maxed build slightly contested (never immune).
-- SINGLE-SOURCED through the closed-form cull now that the live predator kills no longer
-- debit the population (that double-counted the cull), so the closed form carries the
-- WHOLE predation pressure. A first pass tripled these (0.004->0.012 / 0.010->0.034) to
-- "compensate" for the removed live kill -- but that OVERSHOT and broke the rhythm: feed/
-- digestion builds that used to survive collapsed to predation in ~99s and vitality
-- (net_rate) spiralled between negative and positive. Retuned 2026-06-11 via sim_lab
-- survsweep to a MODERATE bump over the old lab-only floor/ramp (0.004/0.010): predation
-- still bites harder than lab-only -- partially standing in for the removed live kill --
-- but a founder that feeds + levels Digestion now survives ~2.6 min before it MUST invest
-- Evasion, a neglected founder still spirals (~90s), and a maxed colony still sprints to
-- the 1M exit. MIRRORED in tools/sim_lab.lua and tests/cell_pressures_spec.lua -- keep the
-- three in sync.
local PRED_BASE = 0.006 -- floor cull fraction/sec at age 0 (small but nonzero)
local PRED_RAMP = 0.014 -- added rate over time (the ramping threat)
local PRED_TAU = 42 -- time scale (s) of the predation ramp
local PRED_MAX = 0.25 -- safety clamp on the per-second cull fraction (never an instant wipe)
local PRED_EVASION_GAIN = 8.0 -- amplifies the shipped evasion stat into real predation mitigation
local PRED_MIT_CAP = 0.97 -- max fraction of predation a high-evasion build can neutralize (<1: maxed stays contested)
local PRED_FEAR = 8.0 -- intake suppression per unit effective predation pressure (the fear gain) [lab-locked; softened from 18 in the lab's pop re-key so a neglected founder still grows enough for toxicity+competition to stay co-dominant]
local FEAR_FLOOR = 0.0 -- min surviving fraction of intake under max fear (0 -> fear can fully starve income)

-- Endospore Homeostasis (the resilience capstone) DAMPENS the competition + predation
-- ramps by its folded pressure_damp, but it can never FULLY neutralize a pressure --
-- a colony that buys infinite Homeostasis must still face some crowding and some
-- predation, or the late game becomes unloseable. Cap the dampening at this fraction.
local PRESSURE_DAMP_CAP = 0.9 -- max fraction of a pressure ramp Homeostasis can cancel (<1: never immune)

-- Endosymbiosis (phase 1's climax) is an RNG event possible at ANY colony size, but
-- the per-engulf chance starts vanishingly small and only begins to RAMP once the
-- colony crosses ENDO_RAMP_START cells, then climbs by ENDO_RAMP_PER_STEP for every
-- further ENDO_STEP cells -- so an early keep is *possible* but statistically very
-- rare, and the run almost always resolves once the colony is well into the millions.
-- ENDO_BASE_CHANCE is the floor below the ramp start (tiny, never zero); clamped to 1.
-- Tuned harder than the first pass (a smaller floor + gentler ramp) so the proc no
-- longer lands too soon; the ramp deliberately starts at the first 100k milestone.
local ENDO_RAMP_START = 100000 -- no ramp below this colony size -- just the floor
local ENDO_STEP = 100000 -- past the start, the chance ramps once per this many cells
local ENDO_BASE_CHANCE = 0.000004 -- per-engulf floor before the ramp (possible but very rare)
local ENDO_RAMP_PER_STEP = 0.0006 -- added to the chance per ENDO_STEP cells past the ramp start
local FEED_ENERGY = 40 -- nutrient reserve a bloom feed credits
-- ENGULF ACCELERATOR burst magnitudes (PRESTIGE.md). A completed prey engulf dumps a
-- burst of reproduction (energy reserve) + health (waste cleared) into the run, EACH
-- scaled by the Engulf tree level via endospores' engulf_progress per-level scalar -- so
-- climbing Engulf visibly speeds regrowth and collapses loop time (the accelerator). The
-- same kind of live burst as a bloom feed (FEED_ENERGY / FEED_TOX_CLEAR), per engulf, so
-- the magnitudes sit a touch below a bloom. FIRST-PASS values -- tune in the balance-lab
-- against the engulf_progress per-level scalar (deferred).
local ENGULF_ENERGY = 30 -- reproduction (energy reserve) per engulf, x engulf_progress
local ENGULF_TOX_CLEAR = 4 -- waste flushed (health) per engulf, x engulf_progress

-- The metabolism dial has been removed; the economy runs at the sweet-spot base
-- rate baked in here so offline / online math never diverges.
local FIXED_TEMPO = metabolism.optimum()

local PANEL_MARGIN = 16 -- gap from the window edge (panel x is computed each frame)
local PANEL_Y = 16
local PANEL_W = 320
local PANEL_H = 502
local PAD = 16
local BTN_W = 96 -- fixed-width trait button, pinned right by the fill label column
local TRAIT_BTN_H = 40
local TOGGLE_BTN_W = 26 -- square minimize/expand toggle pinned to the title row's right
local ENDOSPORE_TREE_BTN_W = 92 -- the "endospore tree" header button that opens the prestige modal
local ENDOSPORE_TREE_GROUP_GAP = 44 -- px between the Growth / Resilience blocks in the tree modal

-- Panel collapse: when true the panel shrinks to just its title row (the toggle
-- stays reachable so it can be expanded again). In-memory only -- a fresh launch
-- opens expanded.
local panel_collapsed = false

-- Reincarnate confirm modal: true while the player is being asked to confirm the
-- voluntary prestige cash-out. In-memory only (a fresh launch opens with no modal).
-- While true, cell.draw stamps the modal and cell.mousepressed hit-tests it first.
local reincarnate_confirming = false

-- Endospore tree modal: true while the prestige-tree surface is open (opened from the
-- header button, the only place the endospore nodes are spent now). In-memory only. While
-- true, cell.draw stamps the modal under any reincarnate confirm and cell.mousepressed
-- hit-tests it (after the confirm, which sits on top).
local endospore_tree_open = false

-- VITALITY BAND thresholds -- a qualitative weak->strong read driven by PER-CAPITA
-- net replication (net_rate / population), so it's SCALE-INVARIANT: the same per-cell
-- growth reads identically at 100 cells and at a million. net_rate folds ALL three
-- pressures (births minus toxicity+competition+predation deaths), so the band is the
-- whole colony's health, not just waste. Above THRIVING per-capita -> Thriving;
-- down through Stable/Strained; any negative net -> Failing, deeply negative ->
-- Collapsing. Tune these (they map directly to the bands).
local VIT_THRIVING = 0.05 -- per-capita net/s at/above which the colony is Thriving
local VIT_STABLE = 0.01 -- per-capita net/s above which it's comfortably Stable
local VIT_STRAINED = 0.0 -- at/above 0 (but below STABLE) it's Strained; below 0 it's failing
local VIT_COLLAPSING = -0.02 -- per-capita net/s at/below which decline is Collapsing

cell.state = nil

local world_state
local view_state
local save_accum = 0
-- The end-of-phase-1 transition cinematic (armed by the endosymbiosis proc).
-- While active the orchestrator FREEZES the live sim and hands the frame to it.
local transition_state = transition.new()
-- Once the endosymbiosis finale hands off into phase 2, phase 1 is RETIRED: its
-- final metrics are snapshotted into the carry and its sim is frozen, so the colony
-- you left behind becomes a fixed statistic instead of quietly ticking on in the
-- background. Reset on a fresh load ([r] / boot) so a new lineage runs normally.
local retired = false

-- COLLAPSE -- the lose state. Failure is purely extinction (is_extinct): once the
-- toxicity/predation cull drives the population to 0 the run ENDS -- a short
-- game-over beat plays, then a fresh lineage seeds (same wipe+reload as [r]).
-- collapse_anim runs the death overlay before the reload fires.
local collapsing = false -- true while the game-over overlay plays (freezes the sim)
local collapse_anim = 0 -- remaining seconds of the death overlay
local COLLAPSE_ANIM = 2.6 -- length of the game-over beat before the fresh reload
-- The pressure that drove THIS extinction (pressures.WASTE/RIVALS/PREDATORS),
-- captured at the moment of collapse from the trailing death-attribution read so the
-- game-over copy names what actually happened. Defaults to the historical waste copy.
local collapse_cause = pressures.DEFAULT

-- TRAILING DEATH ATTRIBUTION: a per-tick decomposition of the colony's deaths into
-- the three failure pressures, EMA-smoothed, mirroring the lab harness's per-source
-- split (tools/sim_lab.lua survival_run). At extinction the largest recent
-- contribution names the dominant cause. These are a SHORT trailing read, not a
-- lifetime accumulator -- the death-spiral's FINAL pressure is what the copy reflects.
local death_attrib = { waste = 0, rivals = 0, predators = 0 }
local DEATH_ATTRIB_TAU = 8 -- EMA horizon (s) for the trailing per-source death read

-- Game-over CAUSE copy, keyed by the dominant pressure id (pressures.*). Each entry
-- is the terse death CLAUSE the toast and overlay subline share -- the message names
-- what actually killed the colony (waste / rivals / predators) instead of always
-- blaming toxicity. The toast prefixes "The colony "; the overlay subline uses the
-- bare clause. Both end with COLLAPSE_TAIL (the "a new lineage begins" reseed tell).
local COLLAPSE_CAUSE = {
  [pressures.WASTE] = "choked on its own waste",
  [pressures.RIVALS] = "was crowded out by rivals",
  [pressures.PREDATORS] = "was hunted to extinction",
}
local COLLAPSE_TAIL = " — a new lineage begins"
-- Extinction is the INVOLUNTARY collapse: it banks only HALF the endospore peak (a
-- voluntary reincarnate banks the full peak). The lost generation still pays forward.
local EXTINCTION_PENALTY = 0.5

-- The saturating COMPETITION ramp (mirrors sim_lab.comp_frac): rivals take a
-- growing share of the food as the lineage ages, climbing toward COMP_FRAC_MAX with
-- time scale COMP_TAU, then saturating (it never re-caps the millions climb). Pure;
-- keyed on the lineage clock so offline replays the same ramp position.
local function comp_frac(age) return COMP_FRAC_MAX * (1 - math.exp(-(age or 0) / COMP_TAU)) end

-- The ramping PREDATION pressure (mirrors sim_lab.pred_pressure): the per-second
-- cull fraction climbs LINEARLY with elapsed lineage time (a rising clock is what
-- lets the unevaded death-spiral reach literal 0 and keeps late game contested),
-- clamped at PRED_MAX so it can never instant-wipe. Evasion mitigation is applied
-- by the caller (evasion_mit below). Pure.
local function pred_pressure(age)
  local p = PRED_BASE + PRED_RAMP * (math.max(age or 0, 0) / PRED_TAU)
  if p > PRED_MAX then
    p = PRED_MAX
  end
  return p
end

-- The evasion COUNTER-GATE (mirrors sim_lab.evasion_mitigation): turn the weak
-- shipped evasion stat into a real predation mitigation via PRED_EVASION_GAIN,
-- capped at PRED_MIT_CAP so a maxed colony stays slightly contested. Returns the
-- SURVIVING fraction the cull applies to: 1 at evasion 0 (full cull -> spiral),
-- -> (1-PRED_MIT_CAP) at high evasion (cull all but neutralized -> the colony climbs).
local function evasion_mit(evasion)
  local m = (evasion or 0) * PRED_EVASION_GAIN
  if m > PRED_MIT_CAP then
    m = PRED_MIT_CAP
  end
  return 1 - m
end

-- The INTAKE fold: the one place the pure modules meet. Assemble the table the
-- sim's shared economy step runs on -- the photosynthesis light (opened by the
-- unlock, lifted by the trait and the chloroplast), the per-cell foraging and its
-- finite-food saturation, the per-cell upkeep (shrunk by evasion), and the
-- overall multiplier (yield x unlocked income channels x the organelle boost).
-- Recomputed wherever the economy is run; never depends on the live swarm.
local function intake_for(state)
  local stats = traits.stats(state.traits)
  local set = state.sim.organelles
  -- The endospore tree's folded economy modifiers (NEUTRAL at level 0: multipliers 1,
  -- additive terms 0), threaded into the existing fold below. A fresh game (empty
  -- tree) leaves every term identity, so the intake is byte-identical to pre-endospore.
  local sp = endospores.fold(state.endospores)
  -- The endospore tree's capability gates (photosynthesis / phagocytosis) + the
  -- flat-on-unlock income multiplier. Single source for the milestone gates the
  -- in-run biomass unlocks used to own (gating on level_of >= 1, i.e. BOUGHT).
  local caps = endospores.capabilities(state.endospores)
  local photo = 0
  if caps.photosynthesis then
    photo = PHOTO_LIGHT * stats.photo_mult * sp.photo_mult
  end
  photo = photo + organelles.photo_bonus(set)
  local upkeep = metabolism.loss(FIXED_TEMPO) * stats.upkeep_mult * UPKEEP_SCALE
  local mult = caps.unlock_income * organelles.intake_mult(set) * sp.all_intake

  -- The lineage clock the two age-keyed pressures ramp on (seconds since lineage
  -- start; ticked by sim.step, so it advances identically online and offline).
  local age = state.sim.age or 0

  -- COMPETITION throttle (mirrors sim_lab intake_for): rivals thin your share of
  -- the food as the lineage ages. Applied to `mult` so it scales ALL gain channels
  -- (photo + foraging + the compounding climb), keeping it biting at millions-scale.
  -- COUNTER-GATE: Motility is the dominant lever -- a faster colony reaches food first,
  -- so COMP_MOTILITY_COUNTER per Motility level restores your share directly. Chemotaxis
  -- (and motility's own forage gain) still help via forage_mult x COMP_COUNTER_GAIN. A
  -- mobile forager keeps your_share near 1 while an immobile colony eats the full
  -- crowding tax. counter in [0,1]; tax = comp_frac*(1-counter).
  local motility = traits.level_of(state.traits, "motility")
  local counter = COMP_MOTILITY_COUNTER * motility
    + (stats.forage_mult - 1) * COMP_COUNTER_GAIN
    + sp.comp_counter
    + sp.sense_bonus -- the Chemotactic Reach (chemo) node: sharper sensing holds your food share
  if counter < 0 then
    counter = 0
  elseif counter > 1 then
    counter = 1
  end
  -- Endospore Homeostasis DAMPENS both age-ramped pressures (competition + predation) by
  -- the folded pressure_damp, capped at PRESSURE_DAMP_CAP so a maxed tree never fully
  -- cancels a pressure. damp_factor scales the two ramps DOWN below.
  local damp_factor = 1 - math.min(sp.pressure_damp, PRESSURE_DAMP_CAP)
  local your_share = 1 / (1 + comp_frac(age) * damp_factor * (1 - counter))
  mult = mult * your_share

  -- PREDATION fear/harassment throttle (mirrors sim_lab intake_for): heavy predation
  -- makes cells FLEE instead of feed, so income (and thus births) collapses. Applied
  -- to the SAME mult. pred_cull_frac already folds in evasion mitigation, so a
  -- high-evasion build feels almost no fear (income intact -> it still reaches the
  -- millions) while a zero-evasion build's births are suppressed AND the floorless
  -- cull (sim.step) runs -> deaths beat births -> spiral to literal 0. Clamped to
  -- [FEAR_FLOOR, 1]. The cull fraction itself is forwarded as pred_cull_frac for sim.step.
  local pred_mit = evasion_mit(stats.evasion + sp.evasion_add)
  local pred_cull_frac = pred_pressure(age) * damp_factor * pred_mit
  local fear = 1 - PRED_FEAR * pred_cull_frac
  if fear < FEAR_FLOOR then
    fear = FEAR_FLOOR
  elseif fear > 1 then
    fear = 1
  end
  mult = mult * fear

  -- Compounding income per cell: enough to cover its own upkeep (upkeep/mult) plus
  -- the GROWTH_RATE surplus, so the net per-cell contribution is GROWTH_RATE x mult
  -- -- a small positive that compounds the colony exponentially. Scaling the
  -- surplus by mult means unlocks/organelles also steepen the climb.
  --
  -- NOTE: upkeep/mult uses the THROTTLED mult, so as competition/predation/fear bite
  -- the per-cell income falls below upkeep (net per cell drops below GROWTH_RATE),
  -- which is exactly what tips a harassed colony into the starvation cull -- mirroring
  -- the lab, where the same throttled mult divides the compounding channel.
  local growth_per_cell = upkeep / mult + GROWTH_RATE
  return {
    photo = photo,
    forage_per_cell = metabolism.gain(FIXED_TEMPO) * stats.forage_mult * sp.forage_mult,
    forage_cap = FORAGE_CAP * stats.forage_cap_mult, -- reach synergy lifts the saturation cap
    upkeep_per_cell = upkeep,
    growth_per_cell = growth_per_cell, -- the open-ended compounding channel (-> millions)
    mult = mult,
    div_mult = stats.div_mult * sp.div_mult, -- digestion + Mitotic Speed: < 1 cheapens every division
    -- Toxicity model (the failure pressure): the dish fouls at TOX_PROD and the
    -- colony clears at stats.cleanup (cleanup traits). Net waste throttles intake
    -- (TOX_HALF) and, past TOX_TOLERANCE, CULLS cells (TOX_KILL_K) toward extinction.
    tox_prod = TOX_PROD,
    tox_clear = stats.cleanup + sp.cleanup,
    tox_half = TOX_HALF,
    tox_tolerance = TOX_TOLERANCE,
    tox_kill_k = TOX_KILL_K,
    -- Predation: the per-second cull fraction (already evasion-mitigated) sim.step
    -- applies as a floorless, ramping cull -- the closed-form home for predation.
    pred_cull_frac = pred_cull_frac,
    -- Death-attribution diagnostics (sim.step ignores them): the competition + predation-
    -- fear throttle factors this fold applied (each <= 1), so the orchestrator can charge
    -- the carrying-cap STARVATION each throttle caused to the right pressure (rivals vs
    -- predator fear) when picking the dominant cause of an extinction. Mirrors sim_lab's
    -- comp_factor / fear_factor. NOT a gameplay field.
    comp_factor = your_share,
    fear_factor = fear,
  }
end

-- The VISIBLE swarm is a logarithmic SAMPLE of the (now millions-scale) colony, so
-- the dish keeps visibly filling without ever becoming an unreadable blur. The
-- mapping + its tuning knobs live in world.sample_count. This count drives the GPU
-- procedural field (view -> cell_field) and the field's tier SIZE, but NOT how many
-- cells world.lua actually steps -- that's bounded by SIM_CAP below.
local function target_population(state) return world.sample_count(state.sim.population) end

-- How many cells world.lua actually SIMULATES (the invisible CPU set that drives
-- the gameplay events -- predator kills, prey engulfs, starvation/feed bursts). The
-- teeming visible swarm is the GPU field, so this stays small: it restores the
-- cheap ~original agent count regardless of how large the colony (and the field)
-- grows. Generous enough that a predator incursion always has cells to hunt.
local SIM_CAP = 200

-- The panel hugs its content and rides the RIGHT edge: cell.draw stamps the
-- resolved tree height and the frame's computed left x here so the hit-test region
-- matches the themed backing exactly (PANEL_H / right-edge x are the pre-draw
-- fallbacks for a mousepressed that lands before the first draw).
cell._panel_h = PANEL_H
cell._panel_x = PANEL_MARGIN

local function in_panel(x, y)
  return x >= cell._panel_x
    and x < cell._panel_x + PANEL_W
    and y >= PANEL_Y
    and y < PANEL_Y + cell._panel_h
end

local function persist()
  save.write(SAVE_NAME, {
    traits = traits.serialize(cell.state.traits),
    sim = sim.serialize(cell.state.sim),
    endospores = cell.state.endospores:serialize(), -- the prestige tree (survives the reset)
    stamp = os.time(),
    -- legacy `genome` and `dial` keys (old systems) are intentionally not written.
  })
end

-- Feed a nutrient bloom: credit the energy reserve -- the burst the colony spends
-- on divisions -- scatter motes for the cells to chase, and play a GENTLE feedback
-- beat (a brief flash, a small shake, a ripple at the bloom) composed from
-- reusable fx effect entities spawned onto the view.
local function feed_bloom(b)
  -- Pentatonic pitch set (root, 2nd, 3rd, 5th, 6th): every variation stays
  -- consonant with the Cmaj BGM, where free jitter would read as detuned.
  sound.play("bloom", { volume = 0.9, pitches = { 1.0, 9 / 8, 5 / 4, 3 / 2, 5 / 3 } })
  sim.feed_burst(cell.state.sim, FEED_ENERGY, FEED_TOX_CLEAR)
  world.add_food_burst(world_state, b.x, b.y)
  view.spawn(view_state, fx.pulse({ x = b.x, y = b.y }))
  view.spawn(view_state, fx.flash({ color = colors.secondary_bright, alpha = 0.18, life = 0.2 }))
  view.spawn(view_state, fx.shake({ mag = 4, life = 0.26, seed = b.x + b.y }))
end

-- The colony has FAILED only when it is EXTINCT -- one (or a mix) of the three
-- pressures (toxicity cull, rival competition, predation) has killed every last cell.
-- No aggregate trigger, no vitality threshold: the run ends purely because the
-- population reached 0, the natural end of the die-off. As long as a single cell
-- survives, feeding or leveling the right traits can still turn it around. Returns
-- true the moment the colony is wiped out.
local function is_extinct() return cell.state.sim.population <= 0 end

-- Begin the game-over beat: freeze the sim, shake + flash red, toast the cause.
-- The overlay runs for COLLAPSE_ANIM, then cell.update reloads a fresh lineage.
local function begin_collapse()
  collapsing = true
  collapse_anim = COLLAPSE_ANIM
  -- Name the DOMINANT recent pressure (the trailing per-source death read), so the
  -- copy matches what actually drove the extinction -- not always the waste default.
  collapse_cause =
    pressures.dominant(death_attrib.waste, death_attrib.rivals, death_attrib.predators)
  -- The colony still BANKS half its endospore peak on extinction (the collapse itself
  -- fires later, in cell.update's collapsing branch -- so read the bankable amount
  -- NOW, before the peak is zeroed, to name it in the death toast).
  local banked = cell.state.endospores:bankable(EXTINCTION_PENALTY)
  toast.show(
    "The colony "
      .. COLLAPSE_CAUSE[collapse_cause]
      .. COLLAPSE_TAIL
      .. " — banked "
      .. format.number(banked)
      .. " endospores (½)"
  )
  sound.play("pop", { volume = 1.0, pitch_spread = 0.2 })
  view.spawn(view_state, fx.flash({ color = colors.quaternary, alpha = 0.4, life = 0.6 }))
  view.spawn(view_state, fx.shake({ mag = 10, life = 0.7, seed = cell.state.sim.population }))
  persist()
end

-- Arm the end-of-phase-1 transition cinematic on the cell at (cx, cy) -- the one
-- whose engulf triggered endosymbiosis, the culminating beat of the cell layer.
-- The timeline owns the clock and the overlay; we bind its three side effects
-- here: the camera push-in onto the cell, the build-up/detonation shakes, and -- at
-- the white peak -- the HAND-OFF INTO PHASE 2. Instead of restarting phase 1, the
-- reset punches through the white-out into the cytoplasm: the engulfed bacterium
-- becomes the first mitochondrion, the colony carries forward as a single statistic,
-- and we switch to the complex-cell layer. The colony population is captured NOW
-- (before the reset fires) so it survives the cinematic. base_zoom is captured NOW
-- so the focus pushes in relative to the camera's current settled fit.
local function begin_lineage_transition(cx, cy)
  local base_zoom = view_state.camera.zoom
  -- The victory beat has just sounded (sound.play("endosymbiosis") at the call site):
  -- duck the phase-1 BGM out and PAUSE it, clearing the floor for phase 2's layered
  -- score to fade up at the seam (complexcell.enter_from_seam, fired by on_reset).
  music.fade_out_pause("bgm", 0.6)
  -- Snapshot phase 1's final metrics NOW (before the reset) -- the figures the
  -- colony "becomes" as a single statistic carried into phase 2.
  local stats = {
    colony = cell.state.sim.population,
    divisions = cell.state.sim.total_divisions,
    biomass = cell.state.sim.biomass,
    organelles = #organelles.acquired_list(cell.state.sim.organelles),
  }
  transition.begin(transition_state, {
    x = cx,
    y = cy,
    -- The "dive" finale: dissolve the dish to the lone winner, brighten it into a hero,
    -- and plunge the camera into it -- the zoom itself is the bridge into phase 2 (no
    -- white-out wipe). The matching teal isolation fade is driven from cell.draw.
    style = "dive",
    -- Phase-2 seam text: the zoom-into-the-cell, not a fresh soup.
    title = "A CELL WITHIN A CELL",
    kicker = "endosymbiosis",
    subtitle = "zoom in",
    on_focus = function(x, y, mult) view.focus(view_state, x, y, base_zoom * mult) end,
    on_shake = function(mag, life, seed)
      view.spawn(view_state, fx.shake({ mag = mag, life = life, seed = seed }))
    end,
    on_reset = function()
      -- Cross the seam into phase 2 at the deepest point of the dive: initialize a fresh
      -- complex cell (the engulfed bacterium is its first mitochondrion), carrying phase
      -- 1's snapshotted metrics as its statistic, then switch layers behind the teal
      -- engulf (phase 2 opens out of the same teal via its intro fade -- no flash, no
      -- cut). RETIRE phase 1 so its sim freezes at the snapshot rather than ticking on.
      retired = true
      complexcell.enter_from_seam({ stats = stats })
      layers.switch("complexcell")
    end,
  })
end

-- The per-engulf endosymbiosis chance at the current colony size: the tiny
-- ENDO_BASE_CHANCE floor until the colony reaches ENDO_RAMP_START, then a slight
-- ramp for every further ENDO_STEP cells (clamped to 1). Nonzero from the first
-- cell -- so a keep is possible at any size -- but held at the floor below the
-- ramp start and only climbing once the swarm crosses 100k, so it almost always
-- lands once the swarm is into the millions rather than too soon.
local function endo_chance(population)
  local steps = math.floor(math.max(0, population - ENDO_RAMP_START) / ENDO_STEP)
  local chance = ENDO_BASE_CHANCE + ENDO_RAMP_PER_STEP * steps
  if chance > 1 then
    return 1
  end
  return chance
end

-- Phase 1's CLIMAX. Each completed prey engulf has the ramped endo_chance() to KEEP
-- the partner as an organelle and resolve the run into a new lineage via the
-- end-of-phase-1 cinematic -- possible at any colony size, but vanishingly rare
-- until the swarm is huge. Gated on predation being unlocked (prey -- the partners
-- -- exist) and an organelle still being available. At most one keep per frame; the
-- transition then freezes the sim so it can't re-enter. engulf_points centres the
-- cinematic on the cell that actually triggered. Live-only (prey are live-only), so
-- it never fires offline -- a moment to witness.
local function roll_endosymbiosis(engulfs, engulf_points, predation)
  if transition.active(transition_state) then
    return
  end
  -- The endosymbiosis proc is IMPOSSIBLE until the Mitochondria node is bought: the jump
  -- to phase 2 is "the capability to absorb the mitochondrion", earned by maxing Engulf
  -- and then buying Mitochondria. Below level 1 no engulf can ever keep the partner.
  if cell.state.endospores:level_of("mitochondria") < 1 then
    return
  end
  local s = cell.state.sim
  -- The endospore Mitochondria node lifts the per-engulf keep chance toward near-certain.
  -- Folded in here (not threaded through the stateless endo_chance) and re-clamped <= 1.
  local chance = endo_chance(s.population) + endospores.fold(cell.state.endospores).endo_chance_add
  if chance > 1 then
    chance = 1
  end
  for i = 1, engulfs do
    local def = organelles.next_eligible(s.organelles, s.total_divisions, predation)
    if def and love.math.random() < chance then
      organelles.acquire(s.organelles, def.id)
      toast.show(string.format("Endosymbiosis! %s kept — %s", def.label, def.boon))
      local p = engulf_points and engulf_points[i]
      local cx, cy = world.swarm_center(world_state)
      if p then
        cx, cy = p.x, p.y
      end
      sound.play("endosymbiosis")
      view.endosymbiosis_beat(view_state, { x = cx, y = cy })
      begin_lineage_transition(cx, cy)
      persist()
      return
    end
  end
end

-- Seed the live world + view for a fresh founder colony: a new cosmetic swarm over
-- the current sim baseline. Factored out of cell.load so the in-run reseed (after a
-- reincarnate / a half-bank extinction) rebuilds the SAME founder world without touching
-- the prestige tree or the save. Reads love.graphics for the aspect (1280x720 headless).
local function seed_world()
  view_state = view.new()
  local width, height = 1280, 720
  if love and love.graphics then
    width, height = love.graphics.getDimensions()
  end
  world_state = world.new({
    rng = function() return love.math.random() end,
    aspect = width / height,
  })
end

-- Reset the IN-RUN state for a fresh generation but KEEP the prestige tree (the
-- banked endospores survive the within-phase reset, per the endospore loop's whole point).
-- The traits + sim reset to the founder; the world/view reseed. Does NOT remove the
-- save and does NOT rebuild cell.state.endospores. Persists the fresh generation.
local function reseed_in_run()
  collapsing = false
  collapse_anim = 0
  collapse_cause = pressures.DEFAULT
  death_attrib.waste, death_attrib.rivals, death_attrib.predators = 0, 0, 0
  cell.state.traits = traits.new()
  cell.state.sim = sim.load(nil)
  seed_world()
  persist()
end

-- Open the reincarnate confirm modal -- the voluntary prestige cash-out gate. A no-op
-- unless a full collapse would actually bank something (a peak above 0), so the
-- button never opens an empty "bank 0 endospores" card.
local REINCARNATE_PENALTY = 1 -- voluntary cash-out banks the FULL peak (extinction banks half)
local function open_reincarnate()
  if cell.state.endospores:bankable(REINCARNATE_PENALTY) > 0 then
    reincarnate_confirming = true
  end
end

-- Confirm the reincarnate: close the modal and arm the "white" collapse cinematic on
-- the swarm centre. The actual bank + in-run reseed fire at the white peak (on_reset),
-- so the colony you banked dissolves into the flash and the fresh founder emerges out
-- of it. Style "white" (vs the endosymbiosis finale's "dive") so the two read apart.
local function do_reincarnate()
  reincarnate_confirming = false
  endospore_tree_open = false -- the tree modal opened it; close it behind the cinematic
  local base_zoom = view_state.camera.zoom
  local cx, cy = world.swarm_center(world_state)
  transition.begin(transition_state, {
    style = "white",
    x = cx,
    y = cy,
    title = "REINCARNATION",
    kicker = "collapse",
    subtitle = "regrow",
    on_focus = function(x, y, mult) view.focus(view_state, x, y, base_zoom * mult) end,
    on_shake = function(mag, life, seed)
      view.spawn(view_state, fx.shake({ mag = mag, life = life, seed = seed }))
    end,
    on_reset = function()
      local gained = cell.state.endospores:collapse(REINCARNATE_PENALTY)
      toast.show("Reincarnated — banked " .. format.number(gained) .. " endospores")
      reseed_in_run()
    end,
  })
end

function cell.load()
  retired = false -- a fresh lineage runs live again (clears any prior phase-2 hand-off)
  collapsing = false -- clear any prior game-over state (a fresh founder runs normally)
  collapse_anim = 0
  collapse_cause = pressures.DEFAULT -- reset the captured death cause for the new lineage
  death_attrib.waste, death_attrib.rivals, death_attrib.predators = 0, 0, 0
  sound.load("pop", "assets/sounds/pop.ogg")
  sound.load("bloom", "assets/sounds/bloom.ogg")
  sound.load("endosymbiosis", "assets/sounds/endosymbiosis.ogg")
  local data = DEV_FRESH_START and {} or (save.read(SAVE_NAME) or {})
  cell.state = {
    traits = traits.load(data.traits),
    sim = sim.load(data.sim),
    -- The prestige tree loads from its own save slice (tolerant of a missing/changed
    -- tree). Neutral until spent, so a fresh game behaves identically.
    endospores = progression_tree.load(endospores.defs(), endospores.tree_opts(), data.endospores),
  }
  seed_world()

  -- Offline catch-up from a wall-clock stamp (closed-form rate only -- no
  -- predators, no agent dependency). Swallow the division pulses; the live
  -- swarm rebuilds from population and fills in smoothly on its own.
  if type(data.stamp) == "number" then
    local seconds = math.min(os.time() - data.stamp, OFFLINE_CAP)
    if seconds > 0 then
      -- Pass intake_for as a PROVIDER (a closure over the live state) rather than a
      -- single precomputed table: the competition/predation ramps are keyed on
      -- state.sim.age, which sim.step advances every sub-step, so offline must
      -- recompute the fold each sub-step to stay byte-identical to the live per-frame
      -- path (which already rebuilds intake every tick). This is the determinism hinge.
      sim.offline(cell.state.sim, seconds, function() return intake_for(cell.state) end)
      sim.take_divisions(cell.state.sim)
    end
  end
end

-- Fold ONE tick's deaths into the trailing per-source death attribution (EMA), so
-- that at extinction the dominant recent pressure names the cause of death. Deaths
-- this step are births minus the net population change (the same accounting sim.step
-- uses for net_rate); the pure pressures.attribute splits them across waste / rivals /
-- predators using the toxicity, the forwarded pred cull, and the throttle factors the
-- intake fold applied. An event-rate EMA (decays over DEATH_ATTRIB_TAU) keeps it a
-- SHORT trailing read of the die-off's final pressure, not a lifetime tally. Called
-- only on the LIVE tick (not offline) -- it drives view copy, never the economy.
local function track_death_attrib(intake, pop_before, div_before, dt)
  if dt <= 0 then
    return
  end
  local sim_state = cell.state.sim
  local births = sim_state.total_divisions - div_before
  local deaths = math.max(0, births - (sim_state.population - pop_before))
  local d_waste, d_rivals, d_predators = pressures.attribute(deaths, pop_before, dt, {
    toxicity = sim_state.toxicity,
    tox_tolerance = intake.tox_tolerance,
    pred_cull_frac = intake.pred_cull_frac,
    comp_factor = intake.comp_factor,
    fear_factor = intake.fear_factor,
  })
  local alpha = 1 - math.exp(-dt / DEATH_ATTRIB_TAU)
  death_attrib.waste = death_attrib.waste + (d_waste / dt - death_attrib.waste) * alpha
  death_attrib.rivals = death_attrib.rivals + (d_rivals / dt - death_attrib.rivals) * alpha
  death_attrib.predators = death_attrib.predators
    + (d_predators / dt - death_attrib.predators) * alpha
end

-- Fixed sim tick (runs even while backgrounded). Pure sim: no love.*, no world.
-- FROZEN while the end-of-phase-1 cinematic is mid-build (up to its reset): the
-- economy must not mint/starve under the freeze frame. Once the reset has fired
-- the fresh colony ticks normally beneath the fading white-out.
function cell.tick(tick_dt)
  if not cell.state then
    return
  end
  if retired then
    return -- phase 1 handed off to phase 2: frozen at its snapshot, no longer ticking
  end
  if transition.active(transition_state) and not transition_state.reset_done then
    return
  end
  if collapsing then
    return -- the colony has failed: freeze the sim under the game-over overlay
  end
  local intake = intake_for(cell.state)
  local pop_before = cell.state.sim.population
  local div_before = cell.state.sim.total_divisions
  sim.tick(cell.state.sim, tick_dt, intake)
  -- Ratchet the prestige peak from this tick's instantaneous endospore-value (health x
  -- growth). Live economy path only (past the retired/transition/collapsing guards
  -- above), so the peak reflects an actually-running colony at its healthiest.
  cell.state.endospores:observe(endospores.value(cell.state.sim, { tox_half = TOX_HALF }))
  track_death_attrib(intake, pop_before, div_before, tick_dt)
end

function cell.update(dt)
  -- The end-of-phase-1 transition takes over the frame. Until its reset fires the live
  -- sim is FROZEN (freeze frame -> camera push-in -> charge -> white-out): advance
  -- only the cinematic and the view (so the camera glides + the fx play), then
  -- bail before world.update so cells hold still under the lingering camera. After
  -- the reset we fall through to the normal update so the fresh founder emerges as
  -- the white fades.
  if transition.active(transition_state) and not transition_state.reset_done then
    transition.update(transition_state, dt)
    view.update(view_state, dt)
    toast.update(dt)
    return
  end
  if transition.active(transition_state) then
    transition.update(transition_state, dt) -- post-reset: tick the white-out fade to its end
  end

  -- The colony has FAILED: the game-over beat owns the frame. Advance only the
  -- view (so the red flash + shake play) and the overlay clock, then -- when it
  -- elapses -- wipe the save and seed a fresh lineage (the same reset as [r]).
  if collapsing then
    view.update(view_state, dt)
    toast.update(dt)
    collapse_anim = collapse_anim - dt
    if collapse_anim <= 0 then
      -- Half-bank the endospore peak and reseed the IN-RUN state -- the prestige tree
      -- survives, so this is NOT a wipe. ([r] remains the true full wipe.) The death
      -- toast (begin_collapse) already named the banked amount before the peak zeroed.
      cell.state.endospores:collapse(EXTINCTION_PENALTY)
      reseed_in_run() -- fresh founder; clears collapsing
    end
    return
  end

  tween.update(dt) -- advance the UI kit's hover/press lighten transitions
  local width, height = love.graphics.getDimensions()
  local aspect = width / height

  -- SAFE ZONE for the nutrient bloom: the bloom is the world's only click
  -- target and the panel eats any click landing on it, so a bloom that spawns
  -- behind the panel is unclickable. Project the panel's screen rect into world
  -- space -- padded by the bloom's drawn extent (glow reaches ~1.7r, the timer
  -- bar hangs below) -- and hand it to the world as a no-spawn rect. Skipped
  -- before the camera's first-draw snap (init=false), when screen_to_world has
  -- no meaningful basis yet; no bloom can spawn that early anyway.
  local bloom_exclude
  if view_state.camera.init then
    local panel_x = width - PANEL_W - PANEL_MARGIN
    local x1, y1 = view.screen_to_world(view_state, panel_x, PANEL_Y)
    local x2, y2 = view.screen_to_world(view_state, panel_x + PANEL_W, PANEL_Y + cell._panel_h)
    local pad = view.bloom_radius(view_state) * 1.8
    bloom_exclude = { x = x1 - pad, y = y1 - pad, w = (x2 - x1) + pad * 2, h = (y2 - y1) + pad * 2 }
  end

  -- CONFINE blooms to the founder-lock frame: while the camera is locked on the
  -- lone founder it only shows part of the field, so a bloom spawned anywhere in
  -- the dish can land off-screen. Project the window corners into world space and
  -- inset by the bloom's drawn extent so the whole clickable sits inside the
  -- tracked view ("within view or right on the edge"). Only while locked -- once
  -- the colony splits this is nil and blooms use the full field interior again.
  local bloom_confine
  if view_state.camera.init and view_state.locked then
    local x1, y1 = view.screen_to_world(view_state, 0, 0)
    local x2, y2 = view.screen_to_world(view_state, width, height)
    local r = view.bloom_radius(view_state) * 1.7 -- glow reach: keep the disk fully framed
    bloom_confine = { x = x1 + r, y = y1 + r, w = (x2 - x1) - r * 2, h = (y2 - y1) - r * 2 }
  end

  -- Phagocytosis is a tree capability now (Engulf level >= 1), so the world's prey +
  -- cosmetic predators key off the endospore capability gate, not an in-run unlock.
  local predation = endospores.capabilities(cell.state.endospores).predation
  -- The leading return is the COSMETIC predator-strike count; it is intentionally
  -- discarded -- predation is single-sourced through the closed-form cull (sim.step),
  -- so a live strike must NOT debit the colony (that would double-count the deaths).
  local _, engulfs, deaths, kill_points, engulf_points = world.update(world_state, dt, {
    stats = traits.stats(cell.state.traits),
    competition = comp_frac(cell.state.sim.age), -- 0..1 rival intensity -> competitor-cell skin
    dial_tempo = FIXED_TEMPO,
    aspect = aspect,
    target_population = target_population(cell.state),
    sim_cap = SIM_CAP, -- bound the CPU-simulated set; the visible swarm is the GPU field
    unlocked = { predation = predation }, -- world only reads .predation (prey/predators)
    threats_enabled = predation,
    bloom_exclude = bloom_exclude,
    bloom_confine = bloom_confine,
  })
  -- PREDATION is SINGLE-SOURCED through the closed-form cull in sim.step (the
  -- age-ramped pred_cull_frac the intake fold forwards), which runs live AND offline.
  -- The live predators are pure cosmetic theatre: they roam, lunge, and burst their
  -- victims into red particles (kill_points below), but they DO NOT debit the
  -- authoritative population -- that would double-count the deaths the closed-form
  -- cull already takes. world.update still reports kill_points so the kills read on
  -- screen, scaled to the same predator pressure; the population math owns the rest.
  -- Starvation deaths cover both reconcile's economy cull and the world's
  -- low-cadence starvation turnover; each bursts into recycled food in the world,
  -- so echo it with a view death-fx -- the cell exploding into its OWN color,
  -- recycled bits of itself -- at the reported position.
  if deaths then
    for i = 1, #deaths do
      local p = deaths[i]
      view.spawn(
        view_state,
        fx.burst({ x = p.x, y = p.y, color = colors.primary, seed = p.x + p.y })
      )
    end
  end
  -- A predator KILL bursts the victim into RED particles -- a violent death,
  -- visually distinct from the cell-colored starvation burst above.
  if kill_points then
    for i = 1, #kill_points do
      local p = kill_points[i]
      view.spawn(
        view_state,
        fx.burst({ x = p.x, y = p.y, color = colors.quaternary, seed = p.x + p.y })
      )
    end
  end
  -- Any cell death this frame -- starvation or kill -- gets ONE pop (not one per
  -- death, so a simultaneous cull doesn't stack into a blast), pitch-jittered.
  local death_count = (deaths and #deaths or 0) + (kill_points and #kill_points or 0)
  if death_count > 0 then
    sound.play("pop", { volume = 0.8, pitch_spread = 0.12 })
  end
  -- A completed PREY engulf plays a REVERSE burst -- prey-colored particles
  -- converging INTO the feeding cell (the death burst backwards: matter drawn in,
  -- not scattered); the cell itself swells via the entity-level fed pulse the
  -- view draws.
  if engulf_points then
    for i = 1, #engulf_points do
      local p = engulf_points[i]
      view.spawn(
        view_state,
        fx.implode({ x = p.x, y = p.y, color = colors.tertiary, seed = p.x + p.y })
      )
    end
  end
  if engulfs and engulfs > 0 then
    -- ENGULF ACCELERATOR (PRESTIGE.md): each prey engulf dumps reproduction (energy ->
    -- divisions) + health (waste cleared) into the run, scaled by the Engulf tree level
    -- via engulf_progress -- so each Engulf level visibly speeds regrowth and collapses
    -- loop time. Reuses sim.feed_burst (energy = reproduction, tox_clear = health). Live-
    -- only (engulfs never occur offline, like the bloom-feed coupling), so the
    -- deterministic offline core is untouched. Neutral until Engulf is bought (progress 0).
    local progress = cell.state.endospores:effect_total("engulf_progress")
    if progress > 0 then
      sim.feed_burst(
        cell.state.sim,
        engulfs * ENGULF_ENERGY * progress,
        engulfs * ENGULF_TOX_CLEAR * progress
      )
    end
    -- Phase 1's climax: a prey engulf may keep the partner (endo_chance ramps with colony
    -- size, gated on Mitochondria), ending the run into a new lineage -- rare even then.
    roll_endosymbiosis(engulfs, engulf_points, predation)
  end

  -- Failure: the pressures (toxicity / competition / predation) have driven the colony
  -- to extinction. End the run into a fresh lineage (game-over beat). begin_collapse
  -- names the dominant cause. Nothing fires while a cell still lives.
  if is_extinct() then
    begin_collapse()
  end
  sim.take_divisions(cell.state.sim) -- drain; the swarm reconciles off population
  view.update(view_state, dt)

  toast.update(dt)

  save_accum = save_accum + dt
  if save_accum >= SAVE_INTERVAL then
    save_accum = 0
    persist()
  end
end

local TRAIT_IDS = { "photosynthesis", "motility", "sensing", "digestion", "evasion" }

-- A themed action button carrying a dim cost/flavor sublabel and an affordability
-- gate -- the copied button-node has neither, so we compose the decoration
-- (primitives.button) with two stacked text lines in a custom draw_fn node, and
-- only register the hover zone + on_click when enabled.
local function action_button_node(opts)
  local enabled = opts.enabled
  return {
    type = "node",
    w = opts.w,
    h = opts.h,
    draw_fn = function(r)
      local tcol = enabled and colors.ui.white or colors.with_alpha(colors.ui.text, 0.35)
      button.draw(r, "", {
        font = "hud_small",
        id = enabled and opts.id or nil,
        opacity = enabled and nil or 0.18,
      })
      local label_y = r.y + math.max(2, math.floor((r.h - 28) / 2))
      text(
        rect(r.x, label_y, r.w, 14),
        opts.label,
        { font = "hud", color = tcol, align = "center" }
      )
      if opts.sublabel then
        text(rect(r.x, r.y + r.h - 16, r.w, 12), opts.sublabel, {
          font = "hud_small",
          color = colors.with_alpha(tcol, 0.6),
          align = "center",
        })
      end
    end,
    on_click = enabled and opts.on_click or nil,
    resolved_rect = nil,
  }
end

-- The title-row minimize/expand toggle: a small square button pinned to the right
-- of the "biomass" line. Shows "−" while expanded (click to collapse) and "+" while
-- collapsed (click to restore). h = "fill" so it centres against the lg title line.
local function toggle_button_node()
  return {
    type = "node",
    w = TOGGLE_BTN_W,
    h = "fill",
    draw_fn = function(r)
      button.draw(r, panel_collapsed and "+" or "−", {
        font = "hud",
        id = "panel_toggle",
      })
    end,
    on_click = function() panel_collapsed = not panel_collapsed end,
    resolved_rect = nil,
  }
end

-- The title-row "endospore tree" button: opens the prestige-tree modal (the only surface that
-- spends endospores now -- the panel no longer lists the nodes). Pinned to the title row left
-- of the minimize toggle, so it stays reachable even when the panel is collapsed.
local function endospore_tree_button_node()
  return {
    type = "node",
    w = ENDOSPORE_TREE_BTN_W,
    h = "fill",
    draw_fn = function(r)
      button.draw(r, "endospore tree", { font = "hud_small", id = "open_endospore_tree" })
    end,
    on_click = function() endospore_tree_open = true end,
    resolved_rect = nil,
  }
end

-- One trait row: a fill-width label column (name + level over a concrete hint) and a
-- right-pinned level-up button. Built ONLY for AVAILABLE traits -- the panel skips a
-- trait still gated behind a capability, so the Photosynthesis trait stays out of this
-- list until the Photosynthesis root is bought on the endospore tree (then it appears
-- here as a normal levelable row -- the capability "becomes" the trait, never a gate).
local function trait_row(state, id)
  local def = traits.def(id)
  local level = state.traits.levels[id]

  local label_col = layout.vstack({
    layout.text(string.format("%s   Lv %d", def.label, level), { color = colors.ui.text }),
    layout.text(traits.hint(id), { color = colors.ui.text_faint }),
  }, { gap = 2 })

  local cost = traits.cost(state.traits, id)
  local affordable = sim.can_spend(state.sim, cost)
  local right = action_button_node({
    label = "level up",
    sublabel = format.number(cost) .. " bm",
    enabled = affordable,
    w = BTN_W,
    h = TRAIT_BTN_H,
    id = "trait_" .. id,
    on_click = function()
      if sim.spend(state.sim, cost) then
        traits.level(state.traits, id)
        persist()
      end
    end,
  })

  return layout.hstack({ label_col, right }, { gap = theme.spacing.sm })
end

-- The organelles section: the acquired organelles (label + boon, with the lore as
-- a faint line) and, once predation is unlocked but not everything is held, a dim
-- hint that an engulfed microbe may rarely become one. Empty before predation, so
-- the section only appears once the rare event is reachable.
local function organelle_children(state)
  local held = organelles.acquired_list(state.sim.organelles)
  local predation = endospores.capabilities(state.endospores).predation
  if #held == 0 and not predation then
    return nil
  end
  local children = { layout.text("organelles", { color = colors.ui.text_dim }) }
  for _, def in ipairs(held) do
    table.insert(
      children,
      layout.vstack({
        layout.text(string.format("%s — %s", def.label, def.boon), { color = colors.ui.text }),
        layout.text(def.lore, { color = colors.with_alpha(colors.ui.text_faint, 0.7) }),
      }, { gap = 2 })
    )
  end
  if predation and organelles.next_eligible(state.sim.organelles, math.huge, true) then
    table.insert(
      children,
      layout.text("rare: an engulfed microbe may become an organelle", {
        color = colors.with_alpha(colors.ui.text_muted, 0.6),
      })
    )
  end
  return children
end

-- The VITALITY BAND: classify the colony's health from its SCALE-INVARIANT per-capita
-- net replication (net_rate / population). Returns the label, its color token, a trend
-- arrow (sign of net_rate), and an analog 0..1 fraction for the thin backing bar.
-- Color ramps secondary (good) -> tertiary -> quaternary (bad) across the bands.
local function vitality_band(state)
  local pop = math.max(state.sim.population, 1)
  local net = state.sim.net_rate or 0
  local per_cap = net / pop

  local label, color
  if per_cap >= VIT_THRIVING then
    label, color = "thriving", colors.secondary
  elseif per_cap >= VIT_STABLE then
    label, color = "stable", colors.secondary
  elseif per_cap >= VIT_STRAINED then
    label, color = "strained", colors.tertiary
  elseif per_cap > VIT_COLLAPSING then
    label, color = "failing", colors.quaternary
  else
    label, color = "collapsing", colors.quaternary
  end

  -- Trend arrow from the sign of net_rate (rising / falling / level).
  local arrow = "▶"
  if net > 0 then
    arrow = "▲"
  elseif net < 0 then
    arrow = "▼"
  end

  -- Analog backing: map per-capita net across [VIT_COLLAPSING, VIT_THRIVING] to 0..1
  -- so the thin bar fills as the band climbs (clamped at the ends).
  local span = VIT_THRIVING - VIT_COLLAPSING
  local frac = span > 0 and (per_cap - VIT_COLLAPSING) / span or 0
  if frac < 0 then
    frac = 0
  elseif frac > 1 then
    frac = 1
  end
  return label, color, arrow, frac
end

-- The whole panel as a declarative node tree, rebuilt each frame so dynamic values
-- and the on_click closures capture the current state. Stacked groups (header /
-- traits / organelles / footer) inside a PAD-padded vstack.
local function build_panel(state)
  local pop = state.sim.population

  -- Title row: the "biomass N" headline (fill width) pushes the minimize/expand
  -- toggle to the right edge. Collapsed, this row is the whole panel.
  local title_row = layout.hstack({
    layout.text(
      "biomass  " .. format.number(state.sim.biomass),
      { size = "lg", color = colors.ui.text }
    ),
    endospore_tree_button_node(),
    toggle_button_node(),
  }, { gap = theme.spacing.sm })

  if panel_collapsed then
    return layout.vstack({ title_row }, { padding = PAD, gap = theme.spacing.md })
  end

  local header = { title_row }
  table.insert(
    header,
    layout.text(string.format("colony  %d", pop), { color = colors.ui.text_dim })
  )
  -- Compact prestige read: the banked endospore currency and the bankable peak, so the
  -- at-a-glance number stays visible even when the endospore tree section is empty/hidden.
  table.insert(
    header,
    layout.text(
      string.format(
        "endospores  %s  (+%s)",
        format.number(state.endospores:currency_amount()),
        format.number(state.endospores:bankable(1))
      ),
      { color = colors.secondary }
    )
  )
  -- NET REPLICATION headline: births minus ALL deaths, per MINUTE, SIGNED -- the
  -- single most honest "are you winning" number. It goes red and negative BEFORE
  -- the colony visibly slides, the leading indicator the vitality band follows.
  -- Measured (EMA of net mints in sim.step), so it doesn't whipsaw on the integer
  -- population wobble; format.number handles the magnitude, we own the +/- sign.
  local net_min = (state.sim.net_rate or 0) * 60
  local net_sign = net_min < 0 and "−" or "+"
  local net_arrow = net_min < 0 and "▼" or "▲"
  local net_color = net_min < 0 and colors.quaternary or colors.secondary
  table.insert(
    header,
    layout.text(
      string.format("%s %s%s /min", net_arrow, net_sign, format.number(math.abs(net_min))),
      { size = "lg", color = net_color }
    )
  )
  -- Dish VITALITY: a qualitative weak->strong BAND (not a percent-to-zero), derived
  -- from per-capita net replication so it reflects ALL three pressures at once and
  -- reads the same at 100 cells or a million. The LABEL is the read; a trend arrow
  -- shows direction; the thin bar is analog backing. Color ramps green->amber->red.
  local band, band_color, band_arrow, band_frac = vitality_band(state)
  table.insert(
    header,
    layout.text(string.format("vitality  %s %s", band, band_arrow), { color = band_color })
  )
  table.insert(
    header,
    layout.bar(band_frac, {
      h = 8,
      color = band_color,
      bg_color = colors.with_alpha(colors.ui.white, 0.12),
    })
  )

  -- Trait list: concrete, direct levels. No slots, no splicing. The endospore tree's
  -- capability gates decide which gated rows appear (the Photosynthesis row only once the
  -- Photosynthesis root is bought) -- the capability "becomes" the trait, never a "needs X" gate.
  local caps = endospores.capabilities(state.endospores)
  local trait_children = { layout.text("traits", { color = colors.ui.text_dim }) }
  for _, id in ipairs(TRAIT_IDS) do
    if traits.is_available(state.traits, id, caps) then
      table.insert(trait_children, trait_row(state, id))
    end
  end

  local groups = {
    layout.vstack(header, { gap = theme.spacing.xs }),
    layout.vstack(trait_children, { gap = theme.spacing.sm }),
  }

  local organelle_group = organelle_children(state)
  if organelle_group then
    table.insert(groups, layout.vstack(organelle_group, { gap = theme.spacing.xs }))
  end

  return layout.vstack(groups, { padding = PAD, gap = theme.spacing.md })
end

-- Map the endospore tree's live state onto the generic love-ui tree_modal config. The widget
-- owns NO endospore semantics -- we compute each node's accent (teal maxed / green buyable /
-- grey held / faint locked), dim flag, and pre-formatted Lv + cost lines here, plus the header
-- title, currency subtitle, the reincarnate action, and the buy / cash-out / close callbacks.
local function build_endospore_tree_config(state)
  local tree = state.endospores
  local nodes = {}
  for _, def in ipairs(endospores.defs()) do
    local unlocked = tree:is_unlocked(def.id)
    local maxed = tree:is_maxed(def.id)
    local can_buy = tree:can_buy(def.id)
    local accent
    if maxed then
      accent = colors.primary
    elseif can_buy then
      accent = colors.secondary
    elseif unlocked then
      accent = colors.ui.border
    else
      accent = colors.ui.border_dim
    end
    local lines
    if not unlocked then
      lines = { { text = "locked", color = colors.ui.text_muted } }
    elseif maxed then
      lines = {
        {
          text = string.format("Lv %d/%d", tree:level_of(def.id), def.cap),
          color = colors.ui.text_dim,
        },
        { text = "MAX", color = colors.primary },
      }
    else
      lines = {
        {
          text = string.format("Lv %d/%d", tree:level_of(def.id), def.cap),
          color = colors.ui.text_dim,
        },
        {
          text = format.number(tree:node_cost(def.id)) .. " esp",
          color = can_buy and colors.secondary or colors.quaternary,
        },
      }
    end
    nodes[#nodes + 1] = {
      id = def.id,
      label = def.short or def.label,
      tier = def.tier,
      requires = def.requires,
      accent = accent,
      dim = not unlocked,
      lines = lines,
      can_click = can_buy,
    }
  end

  local bankable = tree:bankable(REINCARNATE_PENALTY)
  return {
    nodes = nodes,
    title = "ENDOSPORE TREE",
    title_color = colors.secondary,
    subtitle = "endospores  " .. format.number(tree:currency_amount()),
    action = {
      label = "reincarnate (+" .. format.number(bankable) .. ")",
      enabled = bankable > 0,
    },
    footer = "click a node to grow it  ·  banked endospores are permanent",
    group_gap = ENDOSPORE_TREE_GROUP_GAP,
    edge_color = colors.with_alpha(colors.secondary, 0.5),
    edge_dim_color = colors.with_alpha(colors.ui.border_dim, 0.7),
    on_node = function(id)
      if state.endospores:buy(id) then
        persist()
      end
    end,
    on_action = open_reincarnate,
    on_close = function() endospore_tree_open = false end,
  }
end

-- Centered footer help line, a direct text overlay (not part of the panel tree).
local function draw_help(width)
  text(
    rect(0, love.graphics.getHeight() - 44, width, 16),
    "click a bloom to feed   ·   level traits (biomass)   ·   keep net replication positive or the colony fails   ·   [r] new lineage",
    { color = colors.with_alpha(colors.ui.text_faint, 0.7), align = "center" }
  )
end

-- The game-over overlay: a darkening red wash with the cause of death, drawn over
-- the frozen dish for COLLAPSE_ANIM before the fresh lineage reloads.
local function draw_collapse(width)
  local height = love.graphics.getHeight()
  local progress = 1 - math.max(0, math.min(collapse_anim / COLLAPSE_ANIM, 1)) -- 0 -> 1
  local dim = math.min(0.82, 0.2 + progress * 0.8)
  love.graphics.setColor(0.06, 0.0, 0.0, dim)
  love.graphics.rectangle("fill", 0, 0, width, height)
  love.graphics.setColor(1, 1, 1, 1)
  text(rect(0, height / 2 - 32, width, 30), "THE COLONY COLLAPSED", {
    font = "hud_lg",
    color = colors.quaternary,
    align = "center",
  })
  text(rect(0, height / 2 + 8, width, 18), COLLAPSE_CAUSE[collapse_cause] .. COLLAPSE_TAIL, {
    font = "hud",
    color = colors.with_alpha(colors.ui.text, 0.85),
    align = "center",
  })
end

function cell.draw()
  local state = cell.state
  local width = love.graphics.getWidth()

  -- The end-of-phase-1 dive DISSOLVES the dish to isolate the winning cell: hand the
  -- view the triggering cell + the transition's world-fade so everything but the winner
  -- fades out as the camera plunges in. Absent in normal play (isolate = nil -> the
  -- dish renders exactly as before).
  local isolate
  if transition.active(transition_state) then
    isolate = {
      x = transition_state.x,
      y = transition_state.y,
      fade = transition.world_fade(transition_state),
    }
  end

  view.draw_world(view_state, world.snapshot(world_state), {
    mito = organelles.has(state.sim.organelles, "mitochondrion"),
    swarm_count = target_population(state), -- the colony's visible sample size
    sim_cap = SIM_CAP, -- cells the real boids cover; the field only draws ABOVE this
    stats = traits.stats(cell.state.traits), -- folded trait levels -> view trait visuals
    isolate = isolate, -- the dive's "fade everything but the winner" (nil in normal play)
  })

  -- During the end-of-phase-1 cinematic the world is drawn (frozen) beneath the
  -- overlay, but the panel / help / toast are suppressed -- the screen belongs to
  -- the transition. The triggering cell is projected each frame so the core + text
  -- ride it as the camera pushes in.
  if transition.active(transition_state) then
    local sx, sy = view.world_to_screen(view_state, transition_state.x, transition_state.y)
    transition.draw(transition_state, sx, sy)
    return
  end

  -- The colony has failed: the game-over wash owns the screen (panel suppressed),
  -- drawn over the frozen dish until the fresh lineage reloads.
  if collapsing then
    draw_collapse(width)
    toast.draw(width)
    return
  end

  -- The panel rides the RIGHT edge: its left x is computed from the window width
  -- each frame (the panel hugs its content height, so only x moves with resize).
  local panel_x = width - PANEL_W - PANEL_MARGIN
  cell._panel_x = panel_x

  -- Build + resolve the panel tree into the right-edge panel rect, draw its themed
  -- backing, then render it -- keeping this frame's click map on the module so
  -- mousepressed can hit-test it (one-frame lag is standard and harmless).
  interaction.begin_frame()
  local tree = build_panel(state)
  layout.resolve(tree, rect(panel_x, PANEL_Y, PANEL_W, PANEL_H))
  cell._panel_h = tree.resolved_rect.h
  primitives.container(rect(panel_x, PANEL_Y, PANEL_W, cell._panel_h), "content")
  cell._click_map = renderer.draw(tree, nil)
  local mx, my = love.mouse.getPosition()
  interaction.commit_frame(mx, my, love.mouse.isDown(1))

  draw_help(width)
  toast.draw(width)

  -- The endospore tree modal overlays the panel (its own UI-kit frame). Drawn BEFORE the
  -- reincarnate confirm so that, when reincarnate is invoked from inside it, the confirm
  -- card stacks on top. Stash its click map for mousepressed.
  if endospore_tree_open then
    cell._endospore_tree_click_map = ui.tree_modal.draw(build_endospore_tree_config(state))
  else
    cell._endospore_tree_click_map = nil
  end

  -- The reincarnate confirm modal overlays the panel (its own UI-kit frame, drawn last
  -- so it sits on top). Stash its click map so mousepressed can hit-test it FIRST and
  -- swallow clicks behind it. Suppressed while a cinematic owns the screen (the early
  -- returns above never reach here then).
  if reincarnate_confirming then
    cell._reincarnate_click_map = reincarnate.draw({
      amount = state.endospores:bankable(REINCARNATE_PENALTY),
      on_confirm = do_reincarnate,
      on_cancel = function() reincarnate_confirming = false end,
    })
  else
    cell._reincarnate_click_map = nil
  end
end

function cell.keypressed(key)
  -- The cinematic / game-over beat owns the screen: swallow gameplay input until
  -- it finishes (the [r] new-lineage hatch still works through it, handled below).
  if transition.active(transition_state) or collapsing then
    if key == "r" then
      save.remove(SAVE_NAME)
      cell.load()
    end
    return
  end
  if key == "space" then
    local b = world.any_bloom(world_state)
    if b then
      world.hit_bloom(world_state, b.x, b.y, view.bloom_radius(view_state))
      feed_bloom(b)
    end
  elseif key == "m" then
    -- DEV: force the end-of-phase-1 transition (endosymbiosis is ~0.1%/engulf, so
    -- the real proc is rare to witness). Centres on the live swarm.
    local cx, cy = world.swarm_center(world_state)
    sound.play("endosymbiosis")
    view.endosymbiosis_beat(view_state, { x = cx, y = cy })
    begin_lineage_transition(cx, cy)
  elseif key == "r" then
    -- New lineage: wipe the save and reload a fresh single founder. The escape
    -- hatch from a stale grown colony restored off an old save -- instant fresh
    -- start, the true ~20-30s solo-cell open.
    save.remove(SAVE_NAME)
    cell.load()
  end
end

function cell.mousepressed(x, y, button_index)
  if button_index ~= 1 then
    return
  end
  -- The cinematic / game-over beat owns the screen: ignore clicks until it ends.
  if transition.active(transition_state) or collapsing then
    return
  end
  -- The reincarnate modal is MODAL: while open, hit-test its card first and swallow the
  -- click (a hit fires confirm/cancel; a miss is absorbed so the panel/blooms behind
  -- the scrim stay inert).
  if reincarnate_confirming then
    local sb = cell._reincarnate_click_map and renderer.hit_test(cell._reincarnate_click_map, x, y)
    if sb then
      sb()
    end
    return
  end
  -- The endospore tree modal is MODAL too (one layer below the confirm): hit-test its zones
  -- and swallow everything else so the panel/blooms behind the scrim stay inert. A miss
  -- inside the card hits its swallow zone; a miss outside hits the close zone.
  if endospore_tree_open then
    local sb = cell._endospore_tree_click_map
      and renderer.hit_test(cell._endospore_tree_click_map, x, y)
    if sb then
      sb()
    end
    return
  end
  -- A widget hit fires its on_click closure; anything else outside the panel
  -- feeds a nutrient bloom if it landed on one (the blooms are the only other
  -- clickable). in_panel is screen space; the bloom hit-test is world space.
  local cb = cell._click_map and renderer.hit_test(cell._click_map, x, y)
  if cb then
    cb()
    return
  end
  if not in_panel(x, y) then
    local wx, wy = view.screen_to_world(view_state, x, y)
    local b = world.hit_bloom(world_state, wx, wy, view.bloom_radius(view_state))
    if b then
      feed_bloom(b)
    end
  end
end

-- ============================================================================
-- DEBUG SEAM (agent connector). The opt-in JSON-over-TCP connector (tools/automation)
-- drives this layer through here and ONLY here -- it never pokes cell.state directly.
-- Every mutation is documented/clamped to the field's invariant and then persist()ed,
-- so the change survives a reload and the backgrounded/offline math sees it. Guarded
-- against an unloaded layer (state == nil -> false, "layer not loaded"). Pure routing;
-- no love.* beyond the existing persist() write.
-- ============================================================================

-- The canonical fixed sim dt (clock.tick_dt) a debug step advances by, so a connector
-- "step" walks the economy exactly one authoritative tick -- identical to the live
-- backgrounded path -- rather than an arbitrary made-up dt.
local DEBUG_FIXED_DT = require("lib.engine.clock").tick_dt
-- The error string returned by every seam when the layer has not been load()ed yet
-- (cell.state is nil), so the connector gets one stable, machine-readable reason.
local DEBUG_NOT_LOADED = "layer not loaded"
-- Field-name sets the seam recognises, named so the routing branches carry no inline
-- string literals. NON-NEGATIVE: clamped to >= 0. LEVELABLE traits: integer level >= 0.
-- UNLOCKABLE ids grant a capability via debug_unlock (NOT debug_set, which returns
-- unknown for them). Sim fields with bespoke clamps (population, toxicity) are handled
-- explicitly below rather than via a set.
local DEBUG_SIM_NONNEGATIVE = { biomass = true, energy = true, age = true }
local DEBUG_TRAIT_LEVELS =
  { photosynthesis = true, motility = true, sensing = true, digestion = true, evasion = true }
-- The console capability shortcuts map onto endospore tree NODES now (capabilities moved
-- off the in-run unlock system): `unlock photosynthesis` grants the root, `unlock predation`
-- grants Engulf (the phagocytosis gate). debug_unlock sets the mapped node to level 1.
local DEBUG_UNLOCK_IDS = { photosynthesis = "photosynthesis", predation = "engulf" }

-- Explicit min/max clamp (no math.clamp in Lua 5.1 / LuaJIT). Pure.
local function clamp(v, lo, hi)
  if v < lo then
    return lo
  elseif v > hi then
    return hi
  end
  return v
end

-- The live state table (for reads). nil until load(); the connector guards on it.
function cell.debug_state() return cell.state end

-- A plain JSON-able snapshot of the whole layer, reusing the existing serialize
-- functions in scope (traits + sim), for query_state.
function cell.debug_serialize()
  if not cell.state then
    return nil
  end
  return {
    traits = traits.serialize(cell.state.traits),
    sim = sim.serialize(cell.state.sim),
  }
end

-- Read a single field by name. Returns its value, or nil if the layer is unloaded
-- or the name is unrecognised (the connector reports unknown for nil).
function cell.debug_get(field)
  if not cell.state then
    return nil
  end
  local s = cell.state.sim
  if DEBUG_SIM_NONNEGATIVE[field] or field == "population" or field == "toxicity" then
    return s[field]
  end
  if DEBUG_TRAIT_LEVELS[field] then
    return cell.state.traits.levels[field]
  end
  return nil
end

-- Ordered snapshot of this layer's leveled traits with their CURRENT levels, for the
-- console `trait list`. nil when the layer is unloaded (the list command reports
-- not-loaded). Reuses traits.list() for the canonical panel order so a new trait
-- shows up here for free.
function cell.debug_traits()
  if not cell.state then
    return nil
  end
  local levels = cell.state.traits.levels
  local out = {}
  for _, def in ipairs(traits.list()) do
    out[#out + 1] = { id = def.id, level = levels[def.id] or 0 }
  end
  return out
end

-- Set a single numeric/level field, APPLYING the documented clamp, then persist().
-- Unlock ids are NOT handled here (use debug_unlock); they return unknown. Returns
-- true on success, or false + a reason on an unloaded layer / unrecognised field.
function cell.debug_set(field, value)
  if not cell.state then
    return false, DEBUG_NOT_LOADED
  end
  local s = cell.state.sim
  value = tonumber(value) or 0
  if DEBUG_SIM_NONNEGATIVE[field] then
    s[field] = math.max(0, value)
  elseif field == "population" then
    -- Population is an integer >= 1 (the founder never fully dies).
    s.population = math.max(1, math.floor(value))
  elseif field == "toxicity" then
    -- Toxicity rides in [0, TOX_MAX] (the sim's safety clamp; mirrored here).
    s.toxicity = clamp(value, 0, 10000)
  elseif DEBUG_TRAIT_LEVELS[field] then
    cell.state.traits.levels[field] = math.max(0, math.floor(value))
  else
    return false, "unknown field: " .. tostring(field)
  end
  persist()
  return true
end

-- Grant a capability by force (photosynthesis -> the tree root, predation -> Engulf), then
-- persist(). Sets the mapped endospore node to level 1 (capabilities now live on the tree),
-- bypassing cost/requires -- a debug shortcut. Returns true, or false + a reason on an
-- unloaded layer / unrecognised id.
function cell.debug_unlock(id)
  if not cell.state then
    return false, DEBUG_NOT_LOADED
  end
  local node = DEBUG_UNLOCK_IDS[id]
  if not node then
    return false, "unknown unlock: " .. tostring(id)
  end
  cell.state.endospores.levels[node] = 1
  persist()
  return true
end

-- Grant an organelle (mitochondrion / chloroplast) by id, then persist(). A nice-to-have
-- for the connector; the sim tolerates an unknown id (organelles is a free set).
function cell.debug_acquire_organelle(id)
  if not cell.state then
    return false, DEBUG_NOT_LOADED
  end
  cell.state.sim.organelles[tostring(id)] = true
  persist()
  return true
end

-- Advance the pure sim exactly `steps` authoritative ticks (DEBUG_FIXED_DT each),
-- the same step the backgrounded clock runs. Returns the number of steps advanced.
function cell.debug_step(steps)
  if not cell.state then
    return false, DEBUG_NOT_LOADED
  end
  local n = math.max(0, math.floor(tonumber(steps) or 1))
  for _ = 1, n do
    cell.tick(DEBUG_FIXED_DT)
  end
  return n
end

return cell
