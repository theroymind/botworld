#!/usr/bin/env lua
-- sim_lab.lua -- headless balance harness for the cell layer.
--
-- WHY THIS EXISTS
--   The cell economy (lib/layers/cell/sim.lua) is a pure, deterministic closed
--   form, and the orchestrator (cell.lua) folds traits + organelles + tuning
--   constants into the `intake` table the economy runs on. That makes the whole
--   layer testable WITHOUT love2d: load the real modules, rebuild the same
--   intake fold here, and we can measure the exact growth curve any config
--   produces -- carrying capacity K, time-to-K, division rate -- and A/B two
--   configs to see the IMPACT of a change before touching the game.
--
--   Trait SYNERGY is now SHIPPED (folded into traits.stats: reach -> forage cap,
--   thrift -> upkeep), so it comes through automatically -- the harness mirrors
--   the live game (sanity: the maxed colony now prints K = 117 -- up from 110
--   after Motility's forage gain was strengthened). BIOFILM is still a PROPOSED
--   mechanic, gated behind a config
--   flag and off by default: a network stage where cells share nutrients so the
--   food cap tracks colony size (the "busy network").
--
-- USAGE
--   lua tools/sim_lab.lua                 -- scenario comparison table
--   lua tools/sim_lab.lua sweep forage_cap 1 40 1
--   lua tools/sim_lab.lua curve <scenario> [out.csv]
--   lua tools/sim_lab.lua survival       -- the failure-pressure table (tox+comp+pred)
--   lua tools/sim_lab.lua counters       -- each trait vs its pressure + tox-alone + maxed
--   lua tools/sim_lab.lua survsweep COMP_FRAC_MAX 0.2 1.4 0.2
--
-- Pure Lua 5.1. Run from the repo root.

package.path = "./?.lua;" .. package.path

local sim = require("lib.layers.cell.sim")
local metabolism = require("lib.layers.cell.metabolism")
local traits = require("lib.layers.cell.traits")
local organelles = require("lib.layers.cell.organelles")

-- ---------------------------------------------------------------------------
-- Game constants, mirrored from lib/layers/cell.lua. Kept here as the BASELINE
-- defaults; a config can override any of them to test a tuning change. If these
-- drift from cell.lua the scenario table's K (founder 29 / maxed 117) will shift.
-- ---------------------------------------------------------------------------
local DEFAULTS = {
  forage_cap = 5, -- FORAGE_CAP   : foraging saturates past this many cells
  upkeep_scale = 1.3, -- UPKEEP_SCALE : per-cell upkeep multiplier
  photo_light = 30, -- PHOTO_LIGHT  : flat light income once photosynthesis unlocks
}
local FIXED_TEMPO = metabolism.optimum() -- the baked-in metabolism dial position

-- TOXICITY (the failure pressure), mirrored from lib/layers/cell.lua. Off by
-- default in the scenario table / sweeps (so the logistic K sanity checks are
-- unchanged); the `survival` mode turns it on so the REAL toxicity cull (sim.step)
-- runs and the colony can die out to extinction. ALL these MIRROR cell.lua -- edit
-- both together (verified 2026-06-08: TOX_HALF was 5 here, 10 in the game; fixed).
local TOX_PROD = 0.5 -- waste produced per second (the fouling rate to out-clear)
local TOX_HALF = 10 -- toxicity at which intake is throttled to half (cell.lua TOX_HALF)
-- RE-TUNED (co-dominance pass, 2026-06-08): toxicity was a SOLO killer -- a neglected
-- founder choked to extinction in ~48s, long before competition/predation (tau=120)
-- ever ramped in. Softened so toxicity-ALONE kills the founder in ~120-150s (it crosses
-- a HIGHER tolerance late, then culls at a LOWER per-unit rate), making room for the
-- pulled-in competition + predation ramps to share the kill. Tolerance up 8 -> 26,
-- kill rate down 0.035 -> 0.005. Verified: tox-alone founder extinction = 133s.
local TOX_TOLERANCE = 26 -- toxicity below which the dish is harmless -- no cull (cell.lua)
local TOX_KILL_K = 0.005 -- fraction of the colony culled/sec per unit of overage (cell.lua)
local FEED_ENERGY = 40 -- energy a bloom feed credits (cell.lua FEED_ENERGY)
local FEED_TOX_CLEAR = 5 -- waste a bloom feed flushes (cell.lua FEED_TOX_CLEAR)
local BLOOM_INTERVAL = 6.5 -- seconds between blooms (a diligent player feeds each one)

-- Trait synergy is SHIPPED in lib/layers/cell/traits.lua (reach = Motility x
-- Chemotaxis -> forage_cap_mult; thrift = Digestion x Evasion -> upkeep_mult), so
-- it arrives through traits.stats() below -- nothing to model here. To tune it,
-- edit SYN_REACH / SYN_THRIFT in traits.lua and re-run this harness.

-- ---------------------------------------------------------------------------
-- PROPOSED MECHANIC: biofilm. A late milestone where the colony stops being a
-- loose swarm and becomes a connected NETWORK. Mechanically the network shares
-- nutrients, so the forage cap is no longer fixed at 5 -- it tracks population
-- (cap_eff = base + LINK * pop). That removes the saturation that pins K. To
-- keep it idle-safe and self-defeating (the core verb), a super-linear DIFFUSION
-- penalty grows upkeep with density (upkeep *= 1 + DIFFUSION * pop). Linear
-- benefit vs. quadratic cost -> a NEW, far larger interior K (hundreds-to-
-- thousands), and a dense, busy network on screen, not a runaway.
-- `stage` scales both knobs so the biofilm itself is a progression track.
-- ---------------------------------------------------------------------------
local BIOFILM_LINK = 1.0 -- per-stage: cap gains this many slots per cell
local BIOFILM_DIFFUSION = 0.0012 -- per-stage: upkeep penalty per cell (the self-defeat)

-- ---------------------------------------------------------------------------
-- OPEN-ENDED COMPOUNDING growth (the `growth` mode), now SHIPPED. The old economy
-- was LOGISTIC: population grew only until per-cell intake met upkeep, then
-- starved back to a fixed carrying capacity K -- an S-curve that flattens, which
-- is why the colony felt walled at ~110. The shipped fix adds a per-cell income
-- that does NOT saturate (cell.lua GROWTH_RATE -> intake.growth_per_cell), so
-- income scales with the colony and population climbs EXPONENTIALLY toward the
-- millions-scale HARD_CAP. The `growth` mode drives the REAL sim.step with this
-- intake, so it mirrors the game exactly. GROWTH_RATE here mirrors cell.lua; edit
-- both together (or, better, read curves here and copy the value over).
-- ---------------------------------------------------------------------------
local GROWTH_RATE = 0.1 -- MIRRORS cell.lua: compounding surplus per cell (x mult)

-- ===========================================================================
-- PROTOTYPE -- TUNE ME. The two NEW failure pressures from FAILURE_PRESSURES.md,
-- modelled in the LAB ONLY (no sim.step change yet). They are gated behind the
-- cfg.competition / cfg.predation flags so the scenario/growth/sweep tables stay
-- byte-identical; only the `survival` / `survsweep` modes turn them on. Sweep
-- these with `survsweep <KNOB> ...`, then port the winners into the closed form.
-- ===========================================================================

-- COMPETITION (Pressure #2: nutrient rivals -- a crowding tax). A rival population
-- crowds in as YOUR colony grows and thins your share of the finite food. RE-KEYED
-- from elapsed time to colony POPULATION (no clock -> offline replay is deterministic
-- for free). Modelled as an intake THROTTLE on the mult (so it scales ALL gain
-- channels -- photo + foraging + the compounding climb -- exactly like the toxicity
-- health factor, staying relevant at millions-scale where raw forage is negligible):
--   comp_frac(t) = COMP_FRAC_MAX * (1 - exp(-t / COMP_TAU))  -- TIME-keyed saturating ramp
--   counter        = min(1, (forage_mult-1) * COMP_COUNTER_GAIN)     -- sense+moto restore share
--   your_share     = 1 / (1 + comp_frac * (1 - counter))             -- mult *= your_share
-- COMP_FRAC_MAX is the crowding ceiling (0.6 -> rivals eventually take ~37% of your
-- intake); COMP_POP_TAU is the population scale of the ramp (cells). It SATURATES:
-- the ramp reaches ~its ceiling by a few hundred cells and stays FLAT thereafter --
-- it does NOT keep growing with population (that would re-cap the millions climb,
-- the lesson that retired PRED_LOG_POP). COMP_POP_TAU is kept SMALL (tens of cells)
-- so a barely-growing neglected founder (peaks ~pop 15-20) is ALREADY deep in the
-- meaningful part of the ramp and feels real competition before it dies.
-- COUNTER-GATE (re-tune, sharper target): Chemotaxis + Motility lift forage_mult
-- (1.0 at zero, up to ~1.5 maxed). COMP_COUNTER_GAIN turns that lift into share
-- RESTORATION: at gain 2.0 a maxed forager (forage_mult 1.5 -> counter 1.0) fully
-- shrugs off the rival throttle, while a non-forager (forage_mult 1.0 -> counter 0)
-- eats the full crowding tax. This is what makes sensing+motility a REAL competition
-- counter (vs the old flat throttle that no build could escape).
local COMP_FRAC_MAX = 0.68 -- crowding share ceiling (0 = no competition) [retuned 2026-06-08 0.6->0.68; mirrored in cell.lua + cell_pressures_spec.lua]
local COMP_TAU = 42 -- TIME scale (seconds) for the rival ramp to reach ~63% of the ceiling (keyed on elapsed run time; a persisted state.age replays it offline) [retuned 2026-06-08 50->42]
local COMP_COUNTER_GAIN = 2.0 -- how strongly (forage_mult-1) restores your_share (0 = uncounterable)
-- Motility is now the DOMINANT, explicit competition counter (a faster colony reaches
-- food before the rivals do): each Motility level restores this much of your share ON
-- TOP of its forage_mult contribution, so speed is THE answer to crowding while
-- Chemotaxis stays a helper. Mirrored in cell.lua + cell_pressures_spec.lua.
local COMP_MOTILITY_COUNTER = 0.05 -- share restored per Motility level (added to the forage counter)

-- PREDATION (Pressure #3: a RAMPING threat -- a risk tax). A fractional cull applied
-- AFTER each sim.step in the survival runs (a lab-only death term -- the closed-form
-- port lands later). RE-KEYED from elapsed time to colony POPULATION (no clock ->
-- offline replay is deterministic for free): a bigger colony draws more predators.
-- Mitigated directly by Evasion:
--   pred_pressure(t) = clamp(PRED_BASE + PRED_RAMP*(t/PRED_TAU), .., PRED_MAX)  -- TIME-keyed linear ramp
--   evasion_mit        = 1 - min(PRED_MIT_CAP, evasion * PRED_EVASION_GAIN)
--   deaths             = pred_pressure * evasion_mit * pop * dt  (fractional-death accumulator)
-- PRED_BASE is the floor hazard rate (fraction/sec at pop 1); PRED_RAMP is how much the
-- saturating ramp adds on top; PRED_POP_TAU is the population scale (cells) of the ramp.
-- It SATURATES at PRED_BASE+PRED_RAMP by a few hundred cells and stays FLAT -- it does
-- NOT keep climbing with population (the lesson that retired PRED_LOG_POP: a size-growing
-- threat re-caps the millions climb). PRED_POP_TAU is kept SMALL (tens of cells) so the
-- neglected founder (peaks ~pop 15-20) is ALREADY well up the ramp and feels predation.
--
-- COUNTER-GATE (re-tune, sharper target -- the heart of this pass): the shipped
-- traits.stats().evasion is WEAK (evasion 5 = only 0.20), so a raw (1-evasion) cull
-- hard-caps even a maxed colony in the low thousands -- it can NEVER reach the millions
-- finish. PRED_EVASION_GAIN is a LAB-SIDE amplifier on evasion's effectiveness: at
-- gain 8 a maxed colony (evasion 0.20 -> mitigation 0.97, capped by PRED_MIT_CAP) drives
-- effective predation low enough to stay NET-POSITIVE all the way to 1,000,000, while a
-- ZERO-evasion build (evasion 0 -> mitigation 0) eats the full ramping cull and SPIRALS.
-- The gate is the counter, not a global weakening -- an uncountered colony still dies.
-- PRED_LOG_POP was RETIRED entirely: the old size-amplification made the threat grow with
-- the colony WITHOUT saturating, which hard-capped the late/high-pop end so no build could
-- climb. The saturating pop ramp replaces it -- pressure plateaus at PRED_BASE+PRED_RAMP
-- (<= PRED_MAX) and stops chasing size, so a fully-countered colony is not capped.
local PRED_BASE = 0.004 -- floor cull fraction/sec at t=0 (mitigation 1) -- small but nonzero
local PRED_RAMP = 0.010 -- the ramp's added rate over time (the ramping threat) [retuned 2026-06-08 0.008->0.010; mirrored in cell.lua + cell_pressures_spec.lua]
local PRED_TAU = 42 -- TIME scale (seconds) of the predation ramp (keyed on elapsed run time; a persisted state.age replays it offline) [retuned 2026-06-08 50->42]
-- (PRED_LOG_POP RETIRED entirely: the saturating pop ramp above subsumes it -- a
-- non-saturating size-amplification hard-capped the millions climb, so it is gone.)
local PRED_MAX = 0.25 -- safety clamp on the per-second cull fraction (never instant wipe)
local PRED_EVASION_GAIN = 8.0 -- LAB-SIDE: amplifies evasion's predation mitigation (the counter-gate)
local PRED_MIT_CAP = 0.97 -- max fraction of predation a high-evasion build can neutralize (<1: maxed stays contested)

-- PREDATION HARASSMENT / FEAR (NEW this pass -- what makes predation SOLO-LETHAL).
-- A purely fractional cull has a non-zero equilibrium: a clean-water colony just
-- out-breeds it, so predation could thin/contest but never drag a fed colony to
-- literal 0 -- only the floorless toxicity cull reached extinction. The fix is a
-- FORAGING-SUPPRESSION feedback: under heavy predation the cells FLEE instead of
-- feed, so income (births) collapses. Modelled as an intake-mult throttle
--   fear_factor = 1 - PRED_FEAR * effective_pred_pressure   (clamped to [FEAR_FLOOR,1])
-- where effective_pred_pressure = pred_pressure(pop) * pred_survive ALREADY carries
-- the evasion mitigation, so a high-evasion build feels almost no fear (its income is
-- intact and it still climbs to the millions) while a ZERO-evasion build has BOTH its
-- births suppressed AND the full floorless cull running -> deaths > births at the
-- operating scale -> the colony decays EXPONENTIALLY to literal 0 even on clean water.
-- That is the death-spiral. It is fully counter-gated (evasion neutralises both the
-- cull and the fear) and ONLY active when cfg.predation is on AND a time t is supplied
-- (the survival/survsweep callers), so scenario/growth/sweep stay byte-identical.
-- PRED_FEAR chosen so an UNEVADED colony's suppressed births fall below the cull
-- EARLY in the pop ramp (so predation is solo-lethal on a ~5-min timescale, not ~20):
-- fear zeroes intake once PRED_FEAR * effective_pred_pressure >= 1, i.e. at
-- effective_pred ~= 1/18 ~= 0.056 -- reached well before the ramp saturates -- after
-- which income and re-minting STOP (clamped at FEAR_FLOOR=0) and the floorless cull
-- takes the last cells to literal 0 (the spiral). Evasion mitigation (~0.97) drops the
-- maxed build's effective pressure by 0.03x, so its fear stays ~1 (negligible) and it
-- still climbs to the millions -- PRED_FEAR is a clean lever that mostly bites unevaded
-- builds. FEAR_FLOOR=0 is what lets the unevaded spiral reach 0 (a positive floor leaves
-- residual income the founder re-mints from, stalling the decay at pop 1).
local PRED_FEAR = 8.0 -- intake suppression per unit effective predation pressure (the fear gain). High enough that an UNEVADED colony's feeding collapses as the pop ramp climbs (births -> 0, the floorless cull then decays it to literal extinction -- predation is SOLO-LETHAL); a high-evasion build's ~0.03 effective factor makes fear negligible, so it still climbs to millions. Softened from 18 in the population re-key so the neglected founder still GROWS enough (~pop 25-35) for toxicity to build and the competition throttle to bite -- keeping the founder kill co-dominant rather than pure predation.
local FEAR_FLOOR = 0.0 -- min surviving fraction of intake under max fear (0 -> max fear can fully starve income, enabling the spiral to literal 0)

-- Build the intake fold for a config at a given population. Population matters
-- only when biofilm is on (cap + upkeep become pop-dependent); the base game is
-- pop-independent and this returns the same table every call.
-- The saturating competitor ramp: rivals take a growing share of the food as YOUR
-- colony grows. 0 at pop 0, climbing toward COMP_FRAC_MAX with population scale
-- COMP_POP_TAU, then SATURATING (flat past a few hundred cells so it never re-caps
-- the millions climb). Pure; only used when cfg.competition is set (else never called).
local function comp_frac(t) return COMP_FRAC_MAX * (1 - math.exp(-(t or 0) / COMP_TAU)) end

-- Forward declarations: the ramping predation pressure and the evasion mitigation
-- are defined in the SURVIVAL section below (with the cull that uses them), but
-- intake_for needs them NOW for the FEAR throttle -- the harassment feedback that
-- suppresses income under predation. Declared local here so intake_for closes over
-- the same upvalues the later definitions assign. (Runtime-only calls, so the
-- later assignment is in place before any survival/survsweep run invokes them.)
local pred_pressure, evasion_mitigation

-- The effective predation pressure a colony actually feels at colony size `pop`:
-- the saturating pop-ramp pressure AFTER evasion mitigation (so a high-evasion build
-- feels a tiny fraction). This is the same quantity the cull scales by, reused for FEAR
-- so evasion counters the harassment exactly as it counters the kill. cfg carries the
-- build (its evasion level). The `t` arg is the gate flag ONLY (survival/survsweep pass
-- a time; scenario/growth omit it) -- the pressure itself is now keyed on population.
-- Returns 0 when predation is off / no time supplied.
local function effective_pred_pressure(cfg, _population, t)
  if not (cfg.predation and t) then
    return 0
  end
  local evasion = traits.stats({ levels = cfg.levels, unlocked = cfg.unlocked }).evasion or 0
  return pred_pressure(t or 0) * evasion_mitigation(evasion)
end

-- intake_for now takes an optional time `t` used ONLY as the pressure GATE FLAG:
-- when cfg.competition is on AND t is supplied (the survival/survsweep callers),
-- rivals throttle the intake mult by your_share = 1/(1+comp_frac(population)) -- the
-- ramp is keyed on POPULATION, not the clock. Every OTHER caller omits t (or leaves
-- cfg.competition false), so the scenario/growth/sweep folds are byte-identical.
local function intake_for(cfg, population, t)
  local tstate = { levels = cfg.levels, unlocked = cfg.unlocked }
  local stats = traits.stats(tstate)
  local set = cfg.organelles or {}

  local photo = 0
  if cfg.unlocked.photosynthesis then
    photo = cfg.photo_light * stats.photo_mult
  end
  photo = photo + organelles.photo_bonus(set)

  -- Synergy is already folded into stats (forage_cap_mult + upkeep_mult), so it
  -- comes through here automatically -- the harness mirrors the shipped game.
  local forage_cap = cfg.forage_cap * stats.forage_cap_mult
  local upkeep = metabolism.loss(FIXED_TEMPO) * stats.upkeep_mult * cfg.upkeep_scale

  -- Biofilm overlay (proposed): cap tracks pop, upkeep gains a density penalty.
  if cfg.biofilm and cfg.biofilm > 0 then
    local s = cfg.biofilm
    forage_cap = forage_cap + BIOFILM_LINK * s * (population or 1)
    upkeep = upkeep * (1 + BIOFILM_DIFFUSION * s * (population or 1))
  end

  local mult = traits.income_mult(tstate) * organelles.intake_mult(set)
  -- COMPETITION throttle (prototype): rivals thin your share of the food. Applied
  -- to the mult so it scales ALL gain channels (photo + foraging + compounding),
  -- mirroring how the toxicity health factor throttles the whole intake side --
  -- this keeps it biting at millions-scale where raw forage is negligible.
  -- COUNTER-GATE: Motility is the dominant lever (out-swim the rivals to the food),
  -- restoring COMP_MOTILITY_COUNTER per level directly; Chemotaxis (and motility's own
  -- forage gain) still help via forage_mult x COMP_COUNTER_GAIN. A mobile forager keeps
  -- your_share near 1 while an immobile colony eats the full crowding tax. counter in
  -- [0,1]; effective tax = comp_frac * (1-counter).
  if cfg.competition and t then
    local motility = traits.level_of(tstate, "motility")
    local counter = COMP_MOTILITY_COUNTER * motility + (stats.forage_mult - 1) * COMP_COUNTER_GAIN
    if counter < 0 then
      counter = 0
    elseif counter > 1 then
      counter = 1
    end
    mult = mult * (1 / (1 + comp_frac(t or 0) * (1 - counter)))
  end
  -- PREDATION FEAR / HARASSMENT throttle (prototype) -- the death-spiral driver.
  -- Heavy predation makes cells FLEE instead of feed, so income (and thus births)
  -- collapses. Applied to the SAME mult so it scales all gain channels (the
  -- compounding climb included). effective_pred_pressure already folds in evasion
  -- mitigation, so a high-evasion build feels almost no fear (income intact -> it
  -- still reaches the millions) while a ZERO-evasion build's births are suppressed
  -- AND the floorless cull runs -> deaths beat births -> spiral to literal 0 even on
  -- clean water. Clamped to [FEAR_FLOOR, 1] so fear can never zero income on its own.
  if cfg.predation and t then
    local fear = 1 - PRED_FEAR * effective_pred_pressure(cfg, population, t)
    if fear < FEAR_FLOOR then
      fear = FEAR_FLOOR
    elseif fear > 1 then
      fear = 1
    end
    mult = mult * fear
  end
  -- Compounding channel, mirroring cell.lua: per-cell income that covers upkeep
  -- plus the growth_rate surplus, so net per cell is growth_rate x mult (-> the
  -- exponential climb). growth_rate defaults to 0, which leaves the scenario table
  -- and sweeps on the legacy logistic model (K stays meaningful, maxed ~= 117).
  local growth_per_cell = 0
  if cfg.growth_rate and cfg.growth_rate > 0 then
    growth_per_cell = upkeep / mult + cfg.growth_rate
  end
  local tox_prod, tox_clear, tox_half, tox_tolerance, tox_kill_k
  if cfg.toxicity then
    -- Mirror cell.lua's intake fold: the dish fouls at TOX_PROD; clearance is the
    -- cleanup stat (cleanup traits). When clearance < fouling, waste climbs and
    -- chokes intake (sim.lua health factor); past TOX_TOLERANCE the REAL toxicity
    -- cull (sim.step) kills cells at TOX_KILL_K of the colony per unit of overage,
    -- to EXTINCTION -- the honest failure, replacing the old health-threshold proxy.
    tox_prod = TOX_PROD
    tox_clear = stats.cleanup
    tox_half = TOX_HALF
    tox_tolerance = TOX_TOLERANCE
    tox_kill_k = TOX_KILL_K
  end
  return {
    photo = photo,
    forage_per_cell = metabolism.gain(FIXED_TEMPO) * stats.forage_mult,
    forage_cap = forage_cap,
    upkeep_per_cell = upkeep,
    growth_per_cell = growth_per_cell,
    mult = mult,
    div_mult = stats.div_mult,
    tox_prod = tox_prod,
    tox_clear = tox_clear,
    tox_half = tox_half,
    tox_tolerance = tox_tolerance,
    tox_kill_k = tox_kill_k,
  }
end

-- Run the REAL economy step forward and report the growth curve. Recomputes
-- intake each tick so pop-dependent (biofilm) models are handled exactly; for
-- the base game intake is constant so this matches sim.capacity to the integer.
-- Returns: K (steady-state pop), t50/t90 (seconds to 50%/90% of K), peak rate,
-- and the curve samples for CSV.
local function run(cfg, opts)
  opts = opts or {}
  local dt = opts.dt or 0.5
  local max_t = opts.max_t or 60 * 60 * 6 -- 6h cap
  local state = sim.new()
  state.organelles = cfg.organelles or {}

  local curve = {}
  local t = 0
  local peak_rate, stable_for, last_pop = 0, 0, 1
  local K
  while t < max_t do
    local intake = intake_for(cfg, state.population)
    sim.step(state, dt, intake)
    t = t + dt
    if state.div_rate > peak_rate then
      peak_rate = state.div_rate
    end
    if t % 5 < dt then
      curve[#curve + 1] =
        { t = t, pop = state.population, rate = state.div_rate, biomass = state.biomass }
    end
    -- Steady state: population has not changed for a sustained window.
    if state.population == last_pop then
      stable_for = stable_for + dt
      if stable_for >= 120 then
        K = state.population
        break
      end
    else
      stable_for = 0
      last_pop = state.population
    end
  end
  K = K or state.population

  -- Second pass for t50/t90 now that K is known.
  local s2 = sim.new()
  s2.organelles = cfg.organelles or {}
  local t2, t50, t90 = 0, nil, nil
  while t2 < max_t and not (t50 and t90) do
    local intake = intake_for(cfg, s2.population)
    sim.step(s2, dt, intake)
    t2 = t2 + dt
    if not t50 and s2.population >= 0.5 * K then
      t50 = t2
    end
    if not t90 and s2.population >= 0.9 * K then
      t90 = t2
    end
  end

  return {
    K = K,
    t50 = t50,
    t90 = t90,
    peak_rate = peak_rate,
    closed_form_K = sim.capacity(intake_for(cfg, 1)), -- exact for non-biofilm
    curve = curve,
  }
end

-- ---------------------------------------------------------------------------
-- Config builders.
-- ---------------------------------------------------------------------------
local function base_cfg(overrides)
  local cfg = {
    levels = { photosynthesis = 0, motility = 0, sensing = 0, digestion = 0, evasion = 0 },
    unlocked = {},
    organelles = {},
    forage_cap = DEFAULTS.forage_cap,
    upkeep_scale = DEFAULTS.upkeep_scale,
    photo_light = DEFAULTS.photo_light,
    growth_rate = 0, -- 0 = legacy logistic; > 0 = open-ended compounding (the `growth` mode sets it)
    biofilm = 0,
    toxicity = false, -- false = clean dish (K stays meaningful); the `survival` mode sets true
    competition = false, -- PROTOTYPE: rival intake throttle (survival/survsweep only)
    predation = false, -- PROTOTYPE: ramping predator cull (survival/survsweep only)
  }
  if overrides then
    for k, v in pairs(overrides) do
      cfg[k] = v
    end
  end
  return cfg
end

-- The colony in the screenshot: photo5 / motility4 / chemotaxis5 / digestion4 /
-- evasion5, both unlocks fired, no organelles yet.
local function maxed_cfg(overrides)
  local cfg = base_cfg({
    levels = { photosynthesis = 5, motility = 4, sensing = 5, digestion = 4, evasion = 5 },
    unlocked = { photosynthesis = true, predation = true },
  })
  if overrides then
    for k, v in pairs(overrides) do
      cfg[k] = v
    end
  end
  return cfg
end

-- Synergy is shipped, so every maxed_cfg scenario already includes it.
local SCENARIOS = {
  { name = "founder (all Lv0)", cfg = base_cfg({ unlocked = { photosynthesis = true } }) },
  { name = "maxed colony (synergy)", cfg = maxed_cfg() },
  { name = "+ mitochondrion", cfg = maxed_cfg({ organelles = { mitochondrion = true } }) },
  {
    name = "+ chloroplast",
    cfg = maxed_cfg({ organelles = { mitochondrion = true, chloroplast = true } }),
  },
  { name = "+ BIOFILM stage 1", cfg = maxed_cfg({ biofilm = 1 }) },
  { name = "+ BIOFILM stage 2", cfg = maxed_cfg({ biofilm = 2 }) },
  {
    name = "biofilm s2 + organelles",
    cfg = maxed_cfg({
      biofilm = 2,
      organelles = { mitochondrion = true, chloroplast = true },
    }),
  },
}

local function find_scenario(name)
  for _, s in ipairs(SCENARIOS) do
    if s.name == name then
      return s.cfg
    end
  end
  return nil
end

-- ---------------------------------------------------------------------------
-- Formatting.
-- ---------------------------------------------------------------------------
local function fmt_time(s)
  if not s then
    return "  --  "
  end
  if s < 90 then
    return string.format("%5.0fs", s)
  elseif s < 5400 then
    return string.format("%5.1fm", s / 60)
  else
    return string.format("%5.1fh", s / 3600)
  end
end

local function scenario_table()
  print("")
  print("cell-layer balance lab -- carrying capacity & growth per config")
  print(string.rep("-", 78))
  print(
    string.format("%-30s %8s %9s %9s %10s", "scenario", "K (pop)", "t->50%", "t->90%", "peak/min")
  )
  print(string.rep("-", 78))
  for _, s in ipairs(SCENARIOS) do
    local r = run(s.cfg)
    print(
      string.format(
        "%-30s %8d %9s %9s %10.1f",
        s.name,
        r.K,
        fmt_time(r.t50),
        fmt_time(r.t90),
        r.peak_rate * 60
      )
    )
  end
  print(string.rep("-", 78))
  print("note: render cap is MAX_AGENTS=300; K above that needs a higher visual sample.")
  print("")
end

local function sweep(param, lo, hi, step)
  lo, hi, step = tonumber(lo), tonumber(hi), tonumber(step) or 1
  print("")
  print(string.format("sweep of '%s' on the maxed colony (synergy on, biofilm off)", param))
  print(string.rep("-", 50))
  print(string.format("%12s %10s %10s %10s", param, "K (pop)", "t->90%", "peak/min"))
  print(string.rep("-", 50))
  for v = lo, hi, step do
    local cfg = maxed_cfg({ [param] = v })
    local r = run(cfg)
    print(string.format("%12.3f %10d %10s %10.1f", v, r.K, fmt_time(r.t90), r.peak_rate * 60))
  end
  print(string.rep("-", 50))
  print("")
end

local function curve(name, out)
  local cfg = find_scenario(name)
  if not cfg then
    print("unknown scenario: " .. tostring(name))
    print("available:")
    for _, s in ipairs(SCENARIOS) do
      print("  " .. s.name)
    end
    return
  end
  local r = run(cfg)
  local lines = { "t_seconds,population,div_per_min,biomass" }
  for _, p in ipairs(r.curve) do
    lines[#lines + 1] = string.format("%.1f,%d,%.2f,%.1f", p.t, p.pop, p.rate * 60, p.biomass)
  end
  local body = table.concat(lines, "\n") .. "\n"
  if out then
    local f = assert(io.open(out, "w"))
    f:write(body)
    f:close()
    print(string.format("wrote %d samples to %s (K=%d)", #r.curve, out, r.K))
  else
    io.write(body)
  end
end

-- ---------------------------------------------------------------------------
-- Open-ended growth prototype. Drives the REAL sim.step with the REAL intake fold
-- (compounding included when cfg.growth_rate > 0), so the numbers ARE the game's.
-- ---------------------------------------------------------------------------

-- Population at each checkpoint time (seconds), stepping the real economy.
local function growth_curve(cfg, checkpoints)
  local state = sim.new()
  state.organelles = cfg.organelles or {}
  local dt = 1
  local out, ci, t = {}, 1, 0
  local last = checkpoints[#checkpoints]
  while t < last and ci <= #checkpoints do
    sim.step(state, dt, intake_for(cfg, state.population))
    t = t + dt
    while ci <= #checkpoints and t >= checkpoints[ci] do
      out[ci] = state.population
      ci = ci + 1
    end
  end
  while ci <= #checkpoints do
    out[ci] = state.population
    ci = ci + 1
  end
  return out
end

local function fmt_pop(n)
  if n >= 1000000 then
    return string.format("%5.2fM", n / 1000000)
  elseif n >= 1000 then
    return string.format("%5.0fk", n / 1000)
  else
    return string.format("%6d", n)
  end
end

local function fmt_t(s)
  if not s then
    return " >limit"
  elseif s < 120 then
    return string.format("%4.0f s", s)
  else
    return string.format("%4.1f m", s / 60)
  end
end

-- Seconds for a config (real economy) to first cross a target population.
local function time_to(cfg, target, max_t)
  local state = sim.new()
  state.organelles = cfg.organelles or {}
  local dt, t = 1, 0
  while t < max_t do
    sim.step(state, dt, intake_for(cfg, state.population))
    t = t + dt
    if state.population >= target then
      return t
    end
  end
  return nil
end

-- A maxed colony at a given compounding GROWTH_RATE.
local function compounding_cfg(rate, extra_photo)
  local cfg = maxed_cfg({ growth_rate = rate })
  if extra_photo then
    cfg.levels.photosynthesis = cfg.levels.photosynthesis + extra_photo
  end
  return cfg
end

local function growth()
  -- Phase 1 is a ~5-minute sprint: the colony should rocket to the millions and
  -- the endo proc ends the run around then. These checkpoints zoom in on that.
  local checkpoints = { 30, 60, 120, 300, 600 }
  local labels = { "30 s", "1 min", "2 min", "5 min", "10 min" }

  local rows = {
    { "logistic (old, walls)", maxed_cfg() },
    { "compounding (shipped)", compounding_cfg(GROWTH_RATE) },
    { "compounding +1 Photo", compounding_cfg(GROWTH_RATE, 1) },
  }

  print("")
  print("growth -- COLONY POPULATION over time (maxed colony, GROWTH_RATE=" .. GROWTH_RATE .. ")")
  print(string.rep("-", 72))
  io.write(string.format("%-24s", "model"))
  for _, l in ipairs(labels) do
    io.write(string.format("%8s", l))
  end
  print("")
  print(string.rep("-", 72))
  for _, row in ipairs(rows) do
    local pops = growth_curve(row[2], checkpoints)
    io.write(string.format("%-24s", row[1]))
    for i = 1, #checkpoints do
      io.write(fmt_pop(pops[i]) .. "  ")
    end
    print("")
  end
  print(string.rep("-", 72))
  print("time-to-1,000,000 cells at a few GROWTH_RATE values (the phase-1 pacing knob):")
  for _, rate in ipairs({ 0.0016, 0.01, 0.03, 0.06, 0.1 }) do
    print(
      string.format(
        "  GROWTH_RATE %-7s -> 1M in %s",
        tostring(rate),
        fmt_t(time_to(compounding_cfg(rate), 1000000, 3600))
      )
    )
  end
  print(string.rep("-", 72))
  print("pick the rate that lands 1M ~<= 5 min, set GROWTH_RATE in cell.lua + here.")
  print("the endo proc should fire on hitting the millions target to end phase 1.")
  print("")
end

-- ---------------------------------------------------------------------------
-- SURVIVAL -- the failure-pressure harness. Drives the REAL sim.step with the three
-- pressures available (toxicity's real cull + the prototype competition throttle +
-- the prototype ramping-predation cull) and the compounding GROWTH_RATE, optionally
-- feeding a bloom every BLOOM_INTERVAL. The master quantity is NET replication
-- (births - deaths per minute); failure is the HONEST outcome -- the colony actually
-- dies out to EXTINCTION (pop 0), not a health-threshold proxy. The goal: an
-- UNTENDED founder reaches extinction in ~1-2 min, feeding / cleanup / evasion
-- builds survive, and the maxed colony sprints with all three pressures on.
-- ---------------------------------------------------------------------------

-- The ramping predation pressure (prototype): a per-second cull FRACTION that grows
-- with colony POPULATION (a bigger colony draws more predators), SATURATING toward
-- PRED_BASE+PRED_RAMP with population scale PRED_POP_TAU. Clamped to PRED_MAX so it can
-- never instant-wipe. The saturating form (1 - exp(-pop/PRED_POP_TAU)) reaches ~its
-- ceiling by a few hundred cells then stays FLAT -- it does NOT keep chasing size (the
-- lesson that retired the non-saturating PRED_LOG_POP, which hard-capped the climb), so
-- a fully-countered colony is not re-capped at high pop. The small PRED_POP_TAU puts the
-- neglected founder (~pop 15-20) already well up the ramp. Evasion is applied by caller.
function pred_pressure(t) -- assigns the forward-declared local (used by FEAR in intake_for)
  -- TIME-keyed ramp: pressure climbs LINEARLY with elapsed run time (it does NOT
  -- saturate -- a rising clock is what lets the death-spiral reach literal 0 for an
  -- unevaded colony and keeps late game contested), clamped at PRED_MAX so it can
  -- never instant-wipe. Evasion mitigation is applied by the caller.
  local p = PRED_BASE + PRED_RAMP * (math.max(t or 0, 0) / PRED_TAU)
  if p > PRED_MAX then
    p = PRED_MAX
  end
  return p
end

-- The Evasion COUNTER-GATE: turn the (weak) shipped evasion stat into a real predation
-- mitigation via the lab-side PRED_EVASION_GAIN amplifier, capped at PRED_MIT_CAP so a
-- maxed colony stays slightly contested (never fully immune). Returns the SURVIVING
-- fraction the cull applies to: 1 at evasion 0 (full cull -> spiral), -> (1-PRED_MIT_CAP)
-- at high evasion (cull all but neutralized -> the colony climbs to the millions).
function evasion_mitigation(evasion) -- assigns the forward-declared local (used by FEAR in intake_for)
  local m = (evasion or 0) * PRED_EVASION_GAIN
  if m > PRED_MIT_CAP then
    m = PRED_MIT_CAP
  end
  return 1 - m
end

-- Run a config forward second-by-second with the real cull(s) live. cfg flags pick
-- the pressures (cfg.toxicity / cfg.competition / cfg.predation). feed_each =>
-- sim.feed_burst every BLOOM_INTERVAL. Tracks births (minted divisions) and ALL
-- deaths (starvation + the real toxicity cull, both inside sim.step, recovered by
-- diffing population; plus the lab-only predation cull applied here) so we can
-- report NET replication per minute -- the number the whole feature is designed
-- around.
--
-- PER-PRESSURE DEATH ATTRIBUTION (re-tune pass). The deaths sim.step folds in are
-- two kinds: carrying-capacity STARVATION (energy went negative) and the TOXICITY
-- CULL (waste past tolerance). They are split here by the only signal we have from
-- outside the step: when toxicity is over TOX_TOLERANCE the lethal cull is active,
-- so this step's sim_deaths are charged to TOXICITY; otherwise to STARVATION. The
-- lab-only PREDATION cull is already separate (applied here). NOTE on competition:
-- it is an intake THROTTLE, not a direct cull -- it never kills a cell by itself.
-- Its fingerprint is the STARVATION column: while rivals choke the intake mult the
-- throttled colony tips over its carrying capacity and starves, so the starvation
-- deaths under an active competition ramp ARE competition's contribution. The
-- returned stats carry comp_active so the caller can flag this.
--
-- Returns: samples, time-to-extinction (nil if it survives), worst (most negative)
-- net/min after first growth, and a stats table:
--   { d_tox, d_starv, d_pred, deaths, peak, trough, comp_active }
-- where deaths is the total, trough is the POST-PEAK minimum (late-game low), and
-- the three shares answer "no single source > 55%" for the co-dominance check.
local function survival_run(cfg, feed_each, checkpoints, max_t)
  local state = sim.new()
  state.organelles = cfg.organelles or {}
  -- Evasion folds from the build -- the direct predation mitigator. The (weak) shipped
  -- stat is amplified by PRED_EVASION_GAIN into a real surviving-fraction (the gate).
  local evasion = traits.stats({ levels = cfg.levels, unlocked = cfg.unlocked }).evasion or 0
  local pred_survive = evasion_mitigation(evasion)
  local dt, t = 1, 0
  local samples, ci = {}, 1
  local extinct_t = nil
  local feed_timer = BLOOM_INTERVAL
  -- Fractional-death accumulator for the smooth predation cull (mirrors sim.lua's
  -- tox_death_debt pattern -- accumulate the fractional kill, spend whole cells).
  local pred_debt = 0
  -- Net-replication readout: births and deaths PER STEP -> a per-minute net rate,
  -- EMA-smoothed so the column is stable, and a worst-case (min) tracker.
  local net_per_min, min_net = 0, nil
  local grew = false
  -- Death attribution accumulators + the peak / post-peak-trough population trackers.
  local d_tox, d_starv, d_pred = 0, 0, 0
  local peak, trough = 1, nil
  -- Optional time-to-target tracker (cfg.reach_target): the first moment the colony
  -- crosses a population, e.g. the 1,000,000 phase-1 exit. nil if never reached.
  local reach_target, reach_t = cfg.reach_target, nil
  while t < max_t do
    local pop_before = state.population
    local div_before = state.total_divisions
    sim.step(state, dt, intake_for(cfg, state.population, t))
    -- Births this step = divisions minted; sim.step deaths = the (births - net pop
    -- change) the economy culled (carrying-capacity starvation + the toxicity cull).
    local births = state.total_divisions - div_before
    local sim_deaths = math.max(0, births - (state.population - pop_before))
    -- ATTRIBUTE the step's sim deaths: the lethal toxicity cull is active iff waste
    -- is over tolerance, so charge those deaths to TOXICITY; otherwise STARVATION
    -- (the carrying-cap trim, which an active competition throttle drives).
    if cfg.toxicity and (state.toxicity or 0) > TOX_TOLERANCE then
      d_tox = d_tox + sim_deaths
    else
      d_starv = d_starv + sim_deaths
    end
    t = t + dt
    if feed_each then
      feed_timer = feed_timer - dt
      if feed_timer <= 0 then
        feed_timer = feed_timer + BLOOM_INTERVAL
        sim.feed_burst(state, FEED_ENERGY, FEED_TOX_CLEAR)
      end
    end
    -- RAMPING PREDATION (prototype, lab-only death term) -- applied AFTER sim.step,
    -- as a fraction of the surviving colony, mitigated by evasion. Floors at 0
    -- (extinction allowed); a fractional-death debt keeps it smooth.
    local pred_deaths = 0
    if cfg.predation and state.population > 0 then
      local frac = pred_pressure(t) * pred_survive * dt
      pred_debt = pred_debt + frac * state.population
      pred_deaths = math.floor(pred_debt)
      if pred_deaths > 0 then
        if pred_deaths > state.population then
          pred_deaths = state.population
        end
        state.population = state.population - pred_deaths
        pred_debt = pred_debt - pred_deaths
      end
    else
      pred_debt = 0
    end
    d_pred = d_pred + pred_deaths
    -- NET replication per minute (births - all deaths), EMA-smoothed over ~12s.
    local net_step = (births - sim_deaths - pred_deaths) / dt * 60
    local alpha = 1 - math.exp(-dt / 12)
    net_per_min = net_per_min + (net_step - net_per_min) * alpha
    if state.population > 1 then
      grew = true
    end
    -- Peak, and the POST-PEAK trough (the late-game low the colony dips to AFTER its
    -- high-water mark). A new peak RESETS the trough so it only ever measures the
    -- decline that follows the final peak -- not the founder's pre-growth pop of 1.
    if state.population > peak then
      peak = state.population
      trough = state.population
    elseif state.population < (trough or peak) then
      trough = state.population
    end
    -- Only track the worst net AFTER the colony has grown (ignore the founder's
    -- pre-first-division flat start), and only while at least one cell lives.
    if grew and state.population > 0 and (not min_net or net_per_min < min_net) then
      min_net = net_per_min
    end
    -- Real failure: the colony has actually died out. Record the first moment.
    if not extinct_t and state.population <= 0 then
      extinct_t = t
    end
    -- Time-to-1M (the tended-colony success): first crossing of the target pop. When
    -- cfg.stop_at_reach is set the run ends here (the time-to-1M table only needs the
    -- crossing time -- no point minting tens of millions more cells per step after).
    if reach_target and not reach_t and state.population >= reach_target then
      reach_t = t
      if cfg.stop_at_reach then
        break
      end
    end
    while ci <= #checkpoints and t >= checkpoints[ci] do
      samples[ci] = {
        pop = state.population,
        tox = state.toxicity,
        health = sim.health(state.toxicity, TOX_HALF),
        net = net_per_min,
      }
      ci = ci + 1
    end
  end
  while ci <= #checkpoints do
    samples[ci] = {
      pop = state.population,
      tox = state.toxicity,
      health = sim.health(state.toxicity, TOX_HALF),
      net = net_per_min,
    }
    ci = ci + 1
  end
  local stats = {
    d_tox = d_tox,
    d_starv = d_starv,
    d_pred = d_pred,
    deaths = d_tox + d_starv + d_pred,
    peak = peak,
    trough = trough or state.population,
    comp_active = cfg.competition or false,
    reach_t = reach_t,
  }
  return samples, extinct_t, min_net or net_per_min, stats
end

-- Signed net/min, compactly: +12k / -340 / etc.
local function fmt_net(n)
  local sign = n >= 0 and "+" or "-"
  local a = math.abs(n)
  if a >= 1000000 then
    return string.format("%s%.1fM", sign, a / 1000000)
  elseif a >= 1000 then
    return string.format("%s%.0fk", sign, a / 1000)
  else
    return string.format("%s%.0f", sign, a)
  end
end

-- A founder config (bare single cell, photosynthesis milestone fired) with all
-- three pressures available; overrides layer trait levels / unlocks / flags.
local function survivor_cfg(overrides)
  return base_cfg((function()
    local o = {
      toxicity = true,
      competition = true,
      predation = true,
      growth_rate = GROWTH_RATE,
      unlocked = { photosynthesis = true },
    }
    if overrides then
      for k, v in pairs(overrides) do
        o[k] = v
      end
    end
    return o
  end)())
end

-- Per-pressure death-share string: "tox40/comp31/pred29" where comp is the
-- STARVATION column (competition is an intake throttle whose deaths land as
-- carrying-cap starvation -- see survival_run). "--" when nothing died.
local function fmt_attrib(st)
  if st.deaths <= 0 then
    return "      no deaths      "
  end
  local function p(x) return math.floor(100 * x / st.deaths + 0.5) end
  return string.format("tox%2d/comp%2d/pred%2d", p(st.d_tox), p(st.d_starv), p(st.d_pred))
end

-- The single biggest death-source share (%). The co-dominance test wants this <= 55
-- for the neglected founder ("no source dominates").
local function dominant_share(st)
  if st.deaths <= 0 then
    return 0
  end
  local m = math.max(st.d_tox, st.d_starv, st.d_pred)
  return math.floor(100 * m / st.deaths + 0.5)
end

local function survival()
  local checkpoints = { 30, 60, 90, 120, 180, 300 }
  local labels = { "30s", "60s", "90s", "120s", "180s", "300s" }
  -- Each row: name, cfg, whether the player feeds blooms. ALL THREE pressures
  -- (toxicity + competition + predation) are on for every row so the table shows
  -- the EMERGENT failure across builds. The pairs isolate a single pressure's
  -- counter: low/high evasion isolates predation; low/high sensing+motility
  -- isolates competition (better foragers hold their share against rivals).
  local lv = function(p, m, s, d, e)
    return { photosynthesis = p, motility = m, sensing = s, digestion = d, evasion = e }
  end
  local rows = {
    { "founder, no action", survivor_cfg(), false },
    { "founder, feeds blooms", survivor_cfg(), true },
    { "founder +2 digestion", survivor_cfg({ levels = lv(0, 0, 0, 2, 0) }), false },
    { "low-evasion (eva0)", survivor_cfg({ levels = lv(0, 0, 0, 3, 0) }), false },
    { "high-evasion (eva5)", survivor_cfg({ levels = lv(0, 0, 0, 3, 5) }), false },
    { "low-sense/moto", survivor_cfg({ levels = lv(0, 0, 0, 3, 2) }), false },
    { "high-sense/moto", survivor_cfg({ levels = lv(0, 5, 5, 3, 2) }), false },
    {
      "maxed colony",
      maxed_cfg({
        toxicity = true,
        competition = true,
        predation = true,
        growth_rate = GROWTH_RATE,
      }),
      false,
    },
  }

  print("")
  print(
    "survival -- EMERGENT FAILURE (toxicity + competition + predation ON, GROWTH_RATE="
      .. GROWTH_RATE
      .. ")"
  )
  print("each cell:  pop / health%   ;   net/min = worst net replication /min (signed)")
  print("deaths = per-source SHARE of total deaths -- tox cull / comp (=starvation while")
  print("rivals throttle intake) / predation cull. extinction = pop hit 0; else 'survives'")
  print(string.rep("-", 116))
  io.write(string.format("%-22s", "config"))
  for _, l in ipairs(labels) do
    io.write(string.format("%9s", l))
  end
  io.write(string.format("%9s%11s%22s", "net/min", "extinction", "deaths(share)"))
  print("")
  print(string.rep("-", 116))
  local founder_check
  for _, row in ipairs(rows) do
    local samples, extinct_t, min_net, st = survival_run(row[2], row[3], checkpoints, 360)
    if row[1] == "founder, no action" then
      founder_check = { st = st, extinct = extinct_t }
    end
    io.write(string.format("%-22s", row[1]))
    for i = 1, #checkpoints do
      local s = samples[i]
      io.write(
        string.format(
          "%9s",
          string.format("%s/%d%%", fmt_pop(s.pop), math.floor(s.health * 100 + 0.5))
        )
      )
    end
    io.write(
      string.format(
        "%9s%11s%22s",
        fmt_net(min_net),
        extinct_t and fmt_t(extinct_t) or "survives",
        fmt_attrib(st)
      )
    )
    print("")
  end
  print(string.rep("-", 116))
  print("net/min is the WORST (most negative) net replication after the colony first grew.")
  print("comp share = starvation deaths logged WHILE the rival ramp is throttling intake")
  print("(competition is an intake throttle, never a direct cull -- this is its footprint).")
  -- The co-dominance check, readable at a glance: no source > 55% for the founder.
  if founder_check then
    local share = dominant_share(founder_check.st)
    print("")
    print(
      string.format(
        "CO-DOMINANCE CHECK (founder, no action):  %s  -> biggest source = %d%%  [%s]",
        fmt_attrib(founder_check.st),
        share,
        share <= 55 and "PASS (<=55%)" or "FAIL (>55%)"
      )
    )
  end

  -- =========================================================================
  -- TIME-TO-1,000,000 -- the COUNTER-GATE proof. A tended, well-countered colony
  -- out-runs the ramping pressures to the phase-1 exit (1M); an under-countered /
  -- unfed one loses the race -- it spirals to extinction or plateaus far short. The
  -- DIFFERENCE is the player's investment in counters (evasion / sense+moto) + feeding.
  -- =========================================================================
  local TARGET = 1000000
  -- Outcome for a build x feeding: 1M time, or 'spirals @ Ns (extinct)', or 'plateaus'.
  local function one_m_outcome(cfg, feed)
    cfg.reach_target = TARGET
    cfg.stop_at_reach = true -- winners end at the 1M crossing (no point minting past it)
    -- 30 min ceiling: enough for any winning build to land 1M (they break early at the
    -- crossing) and any loser to fully resolve (spiral to extinction). Losers stay small
    -- (peak in the hundreds) so the full run is cheap even at this ceiling.
    local _, extinct_t, _, st = survival_run(cfg, feed, { 1800 }, 1800)
    if st.reach_t then
      return string.format("1M in %s", fmt_t(st.reach_t)), st
    elseif extinct_t then
      return string.format("spirals @ %s (extinct, pk %s)", fmt_t(extinct_t), fmt_pop(st.peak)), st
    else
      return string.format("plateaus @ %s (pk %s)", fmt_pop(st.trough), fmt_pop(st.peak)), st
    end
  end
  -- Build set for the race table. maxed = fully countered; mid = partial; founder = none.
  local function maxed_surv()
    return maxed_cfg({
      toxicity = true,
      competition = true,
      predation = true,
      growth_rate = GROWTH_RATE,
    })
  end
  -- A tended MID build: partial counters across the board, both milestones unlocked
  -- (it has long since passed the phagocytosis pop gate, so it earns that income).
  local mid_cfg = survivor_cfg({
    levels = lv(3, 2, 2, 3, 3),
    unlocked = { photosynthesis = true, predation = true },
  })
  -- The LOST RACE build: strong forager (so it GROWS large early) but ZERO evasion and
  -- ZERO waste clearance -- no predation counter, no toxicity counter. Unfed, both
  -- milestones unlocked (it grew past the gates before the ramp caught it).
  local lost_cfg = survivor_cfg({
    levels = lv(3, 5, 5, 0, 0),
    unlocked = { photosynthesis = true, predation = true },
  })
  local race_rows = {
    { "maxed + feed", maxed_surv(), true },
    { "maxed + NO feed", maxed_surv(), false },
    { "mid-build + feed", mid_cfg, true },
    { "founder + feed", survivor_cfg(), true },
    { "under-countered + NO feed", lost_cfg, false },
  }
  print("")
  print("TIME-TO-1,000,000 (the phase-1 exit) -- builds x feeding, all 3 pressures ON")
  print(string.rep("-", 78))
  print(string.format("%-28s %-8s %-40s", "build", "feeds?", "outcome"))
  print(string.rep("-", 78))
  for _, r in ipairs(race_rows) do
    local outcome = one_m_outcome(r[2], r[3])
    print(string.format("%-28s %-8s %-40s", r[1], r[3] and "yes" or "no", outcome))
  end
  print(string.rep("-", 78))
  print("the GATE: only builds that invest counters (evasion vs predation, sense+moto vs")
  print("competition) AND feed (vs toxicity) out-run the ramp to 1M. Neglect = lost race.")
  print("")
end

-- ---------------------------------------------------------------------------
-- COUNTERS -- prove each trait counters ITS pressure. For one pressure ON at a time,
-- run a LOW vs a HIGH counter build and report the delta. Toxicity solo-extinguishes,
-- so its counter (digestion) reads as time-to-extinction (LOW dies / HIGH survives).
-- Predation and competition ALONE are survivable against the compounding economy (a
-- healthy colony out-breeds a fractional cull / an intake throttle), so their counters
-- (evasion; sensing+motility) read as how much DEEPER the LOW build's trough sinks and
-- how much more negative its worst net/min gets -- the honest "outlast" signal when
-- nothing goes extinct. This also prints the toxicity-ALONE founder extinction time
-- (the softening check, target ~120-150s) and the maxed colony's peak/trough/net.
-- ---------------------------------------------------------------------------

-- A single-pressure founder cfg: only the named flag on (others forced off). Used to
-- isolate one pressure so its counter trait is the only thing that moves the number.
local function isolate_cfg(which, levels)
  local cfg = survivor_cfg({ levels = levels })
  cfg.toxicity = (which == "toxicity")
  cfg.competition = (which == "competition")
  cfg.predation = (which == "predation")
  return cfg
end

local function counters()
  local lv = function(p, m, s, d, e)
    return { photosynthesis = p, motility = m, sensing = s, digestion = d, evasion = e }
  end
  local cps = { 60, 180, 300 }
  -- Run an isolated build to 600s; return extinction, worst net, and stats.
  local function trial(which, levels, max_t)
    local _, ext, mn, st = survival_run(isolate_cfg(which, levels), false, cps, max_t or 600)
    return ext, mn, st
  end

  print("")
  print("counters -- each trait vs ITS pressure, in isolation (LOW vs HIGH counter build)")
  print(string.rep("-", 92))
  print(
    string.format(
      "%-12s %-22s %-22s %-30s",
      "pressure",
      "LOW build",
      "HIGH build",
      "result (HIGH outlasts LOW)"
    )
  )
  print(string.rep("-", 92))

  -- TOXICITY: digestion 0 vs 3 (digestion is the primary waste-clearance trait).
  local t_lo_e = trial("toxicity", lv(0, 0, 0, 0, 0), 600)
  local t_hi_e = trial("toxicity", lv(0, 0, 0, 3, 0), 600)
  print(
    string.format(
      "%-12s %-22s %-22s %-30s",
      "toxicity",
      "digestion 0  ext=" .. (t_lo_e and fmt_t(t_lo_e) or "survives"),
      "digestion 3  ext=" .. (t_hi_e and fmt_t(t_hi_e) or "survives"),
      (t_lo_e and not t_hi_e) and "LOW dies, HIGH SURVIVES (clears waste)"
        or (t_lo_e and t_hi_e and ("+" .. (t_hi_e - t_lo_e) .. "s longer") or "n/a")
    )
  )

  -- PREDATION: evasion 0 vs 5. Neither extinguishes -> compare trough + worst net.
  local _, p_lo_mn, p_lo = trial("predation", lv(0, 0, 0, 0, 0), 360)
  local _, p_hi_mn, p_hi = trial("predation", lv(0, 0, 0, 0, 5), 360)
  print(
    string.format(
      "%-12s %-22s %-22s %-30s",
      "predation",
      string.format("evasion 0  tr=%d", p_lo.trough),
      string.format("evasion 5  tr=%d", p_hi.trough),
      string.format(
        "trough +%d  (net %s->%s)",
        p_hi.trough - p_lo.trough,
        fmt_net(p_lo_mn),
        fmt_net(p_hi_mn)
      )
    )
  )

  -- COMPETITION: sensing+motility 0/0 vs 5/5. Throttle only -> compare trough + net.
  local _, c_lo_mn, c_lo = trial("competition", lv(0, 0, 0, 0, 0), 360)
  local _, c_hi_mn, c_hi = trial("competition", lv(0, 5, 5, 0, 0), 360)
  print(
    string.format(
      "%-12s %-22s %-22s %-30s",
      "competition",
      string.format("sense/moto 0/0 tr=%s", fmt_pop(c_lo.trough)),
      string.format("sense/moto 5/5 tr=%s", fmt_pop(c_hi.trough)),
      string.format(
        "trough +%s  (net %s->%s)",
        fmt_pop(c_hi.trough - c_lo.trough),
        fmt_net(c_lo_mn),
        fmt_net(c_hi_mn)
      )
    )
  )
  print(string.rep("-", 92))
  print("toxicity solo-kills (extinction); predation/competition alone are survivable by")
  print("design -- a compounding colony out-breeds the cull/throttle, so HIGH 'outlasts' LOW")
  print("by holding a higher trough population and a less-negative worst net/min.")

  -- TOXICITY-ALONE softening check: neglected founder, ONLY toxicity on.
  local tox_ext = trial("toxicity", lv(0, 0, 0, 0, 0), 600)
  print("")
  print(
    string.format(
      "TOXICITY-ALONE founder extinction (comp+pred OFF): %s   [target ~120-150s; %s]",
      tox_ext and fmt_t(tox_ext) or "survives",
      (tox_ext and tox_ext >= 110 and tox_ext <= 155) and "PASS" or "out of band"
    )
  )

  -- MAXED colony, all three pressures: peak / post-peak trough / trough net/min.
  local _, m_ext, m_mn, m_st = survival_run(
    maxed_cfg({ toxicity = true, competition = true, predation = true, growth_rate = GROWTH_RATE }),
    false,
    cps,
    360
  )
  print(
    string.format(
      "MAXED colony (all 3 ON): peak=%s  post-peak trough=%s  trough net/min=%s  -> %s",
      fmt_pop(m_st.peak),
      fmt_pop(m_st.trough),
      fmt_net(m_mn),
      m_ext and ("EXTINCT @ " .. fmt_t(m_ext)) or "SURVIVES (contested but alive)"
    )
  )
  print(
    "contested = trough net/min goes NEGATIVE (late game is a fight); survives = no extinction."
  )
  print("")
end

-- ---------------------------------------------------------------------------
-- SURVSWEEP -- sweep one of the new pressure knobs on a FIXED reference config so we
-- can read how each knob moves time-to-extinction (the tuning lever). The reference
-- is a barely-tended founder (+1 digestion, +1 evasion) with all three pressures on
-- -- a build deliberately near the survival KNIFE-EDGE, where toxicity is still the
-- binding pressure (clearance only just outruns fouling), so the toxicity knobs bite
-- and the predation/competition knobs can tip it over into extinction.
-- ---------------------------------------------------------------------------
local SWEEPABLE = {
  COMP_FRAC_MAX = function(v) COMP_FRAC_MAX = v end,
  COMP_TAU = function(v) COMP_TAU = v end, -- time scale (s) of the competition ramp
  COMP_COUNTER_GAIN = function(v) COMP_COUNTER_GAIN = v end, -- the competition counter-gate
  COMP_MOTILITY_COUNTER = function(v) COMP_MOTILITY_COUNTER = v end, -- Motility's dedicated counter (needs a motility-bearing ref to bite)
  PRED_BASE = function(v) PRED_BASE = v end,
  PRED_RAMP = function(v) PRED_RAMP = v end,
  PRED_TAU = function(v) PRED_TAU = v end, -- time scale (s) of the predation ramp
  PRED_EVASION_GAIN = function(v) PRED_EVASION_GAIN = v end, -- the predation counter-gate
  PRED_MIT_CAP = function(v) PRED_MIT_CAP = v end,
  TOX_KILL_K = function(v) TOX_KILL_K = v end,
  TOX_TOLERANCE = function(v) TOX_TOLERANCE = v end,
}

local function survival_sweep(knob, lo, hi, step)
  local setter = SWEEPABLE[knob]
  if not setter then
    print("unknown knob: " .. tostring(knob))
    print(
      "sweepable: COMP_FRAC_MAX COMP_TAU COMP_COUNTER_GAIN COMP_MOTILITY_COUNTER "
        .. "PRED_BASE PRED_RAMP PRED_TAU PRED_EVASION_GAIN PRED_MIT_CAP TOX_KILL_K TOX_TOLERANCE"
    )
    return
  end
  lo, hi, step = tonumber(lo), tonumber(hi), tonumber(step) or 1
  -- The fixed reference build: a barely-tended founder on the survival KNIFE-EDGE.
  -- +1 digestion only -> cleanup 0.36 < TOX_PROD 0.5, so toxicity IS the binding
  -- pressure (it slowly climbs), making the toxicity knobs (TOX_KILL_K / TOLERANCE)
  -- live levers AND leaving headroom for predation/competition to tip the timing.
  local REF_LABEL = "founder +1 digestion"
  local ref = function()
    return survivor_cfg({
      levels = { photosynthesis = 0, motility = 0, sensing = 0, digestion = 1, evasion = 0 },
    })
  end
  local checkpoints = { 60, 180, 300 }
  print("")
  print(
    string.format("survsweep '%s' on the reference build (%s; tox+comp+pred ON)", knob, REF_LABEL)
  )
  print(string.rep("-", 56))
  print(string.format("%14s %14s %14s", knob, "extinction", "min net/min"))
  print(string.rep("-", 56))
  for v = lo, hi + 1e-9, step do
    setter(v)
    local _, extinct_t, min_net = survival_run(ref(), false, checkpoints, 600)
    print(
      string.format(
        "%14.4g %14s %14s",
        v,
        extinct_t and fmt_t(extinct_t) or "survives",
        fmt_net(min_net)
      )
    )
  end
  print(string.rep("-", 56))
  print(
    "lower extinction time / more-negative net = the knob is pushing the colony toward failure."
  )
  print("")
end

-- ---------------------------------------------------------------------------
-- Entry.
-- ---------------------------------------------------------------------------
local mode = arg[1]
if mode == "sweep" then
  sweep(arg[2], arg[3], arg[4], arg[5])
elseif mode == "curve" then
  curve(arg[2], arg[3])
elseif mode == "growth" then
  growth()
elseif mode == "survival" then
  survival()
elseif mode == "counters" then
  counters()
elseif mode == "survsweep" then
  survival_sweep(arg[2], arg[3], arg[4], arg[5])
else
  scenario_table()
end
