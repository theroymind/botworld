-- Cell layer: the first playable scale -- a living micro-world. Drift a colony of
-- cells through a nutrient medium, level concrete traits, click nutrient blooms to
-- feed the reserve, and grow the colony toward its carrying capacity. This file is
-- the ORCHESTRATOR: it owns only the wiring. It folds the pure economy core
-- (metabolism + traits + organelles) into an INTAKE table -- the photosynthesis
-- light, the per-cell foraging and its finite-food saturation, the per-cell
-- upkeep, and the overall multiplier -- which sim.tick/sim.offline run the shared
-- economy step on, so idle/offline math never depends on the live agents. The live
-- world (world.lua) is a cosmetic skin over that baseline, driven only in update()
-- (never backgrounded, so offline stays pure), with exactly THREE real couplings
-- back to the economy: a nutrient-bloom click -> sim.feed_burst, a predator kill
-- -> sim.kill, and a rare prey engulf -> keep an organelle (organelles.acquire +
-- the intake fold). The pure modules know nothing of each other or of love.*; they
-- meet only here. Economy runs at a fixed sweet-spot base rate (no dial).
local save = require("lib.engine.save")
local fx = require("lib.engine.fx")
local sound = require("lib.engine.sound")
local music = require("lib.engine.music")
local format = require("lib.engine.format")
local metabolism = require("lib.layers.cell.metabolism")
local traits = require("lib.layers.cell.traits")
local sim = require("lib.layers.cell.sim")
local organelles = require("lib.layers.cell.organelles")
local world = require("lib.layers.cell.world")
local view = require("lib.layers.cell.view")
local transition = require("lib.layers.cell.transition")
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
-- clearance (traits CLEAN_BASE = 0.15) sits BELOW TOX_PROD, so an UNTOUCHED colony
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
-- Retuned 2026-06-08 alongside competition (above): the predation ramp climbs faster
-- (PRED_RAMP 0.008 -> 0.010, PRED_TAU 50 -> 42) so a neglected dish feels the cull
-- sooner. MIRRORED in tools/sim_lab.lua and tests/cell_pressures_spec.lua.
local PRED_BASE = 0.004 -- floor cull fraction/sec at age 0 (small but nonzero)
local PRED_RAMP = 0.010 -- added rate over time (the ramping threat)
local PRED_TAU = 42 -- time scale (s) of the predation ramp
local PRED_MAX = 0.25 -- safety clamp on the per-second cull fraction (never an instant wipe)
local PRED_EVASION_GAIN = 8.0 -- amplifies the shipped evasion stat into real predation mitigation
local PRED_MIT_CAP = 0.97 -- max fraction of predation a high-evasion build can neutralize (<1: maxed stays contested)
local PRED_FEAR = 8.0 -- intake suppression per unit effective predation pressure (the fear gain) [lab-locked; softened from 18 in the lab's pop re-key so a neglected founder still grows enough for toxicity+competition to stay co-dominant]
local FEAR_FLOOR = 0.0 -- min surviving fraction of intake under max fear (0 -> fear can fully starve income)

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

-- Panel collapse: when true the panel shrinks to just its title row (the toggle
-- stays reachable so it can be expanded again). In-memory only -- a fresh launch
-- opens expanded.
local panel_collapsed = false

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
  local photo = 0
  if traits.is_unlocked(state.traits, "photosynthesis") then
    photo = PHOTO_LIGHT * stats.photo_mult
  end
  photo = photo + organelles.photo_bonus(set)
  local upkeep = metabolism.loss(FIXED_TEMPO) * stats.upkeep_mult * UPKEEP_SCALE
  local mult = traits.income_mult(state.traits) * organelles.intake_mult(set)

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
  local counter = COMP_MOTILITY_COUNTER * motility + (stats.forage_mult - 1) * COMP_COUNTER_GAIN
  if counter < 0 then
    counter = 0
  elseif counter > 1 then
    counter = 1
  end
  local your_share = 1 / (1 + comp_frac(age) * (1 - counter))
  mult = mult * your_share

  -- PREDATION fear/harassment throttle (mirrors sim_lab intake_for): heavy predation
  -- makes cells FLEE instead of feed, so income (and thus births) collapses. Applied
  -- to the SAME mult. pred_cull_frac already folds in evasion mitigation, so a
  -- high-evasion build feels almost no fear (income intact -> it still reaches the
  -- millions) while a zero-evasion build's births are suppressed AND the floorless
  -- cull (sim.step) runs -> deaths beat births -> spiral to literal 0. Clamped to
  -- [FEAR_FLOOR, 1]. The cull fraction itself is forwarded as pred_cull_frac for sim.step.
  local pred_mit = evasion_mit(stats.evasion)
  local pred_cull_frac = pred_pressure(age) * pred_mit
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
    forage_per_cell = metabolism.gain(FIXED_TEMPO) * stats.forage_mult,
    forage_cap = FORAGE_CAP * stats.forage_cap_mult, -- reach synergy lifts the saturation cap
    upkeep_per_cell = upkeep,
    growth_per_cell = growth_per_cell, -- the open-ended compounding channel (-> millions)
    mult = mult,
    div_mult = stats.div_mult, -- digestion: < 1 cheapens every division
    -- Toxicity model (the failure pressure): the dish fouls at TOX_PROD and the
    -- colony clears at stats.cleanup (cleanup traits). Net waste throttles intake
    -- (TOX_HALF) and, past TOX_TOLERANCE, CULLS cells (TOX_KILL_K) toward extinction.
    tox_prod = TOX_PROD,
    tox_clear = stats.cleanup,
    tox_half = TOX_HALF,
    tox_tolerance = TOX_TOLERANCE,
    tox_kill_k = TOX_KILL_K,
    -- Predation: the per-second cull fraction (already evasion-mitigated) sim.step
    -- applies as a floorless, ramping cull -- the closed-form home for predation.
    pred_cull_frac = pred_cull_frac,
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

-- Buy a milestone capability (photosynthesis, phagocytosis): the player spends
-- biomass to EVOLVE it, replacing the old auto-fire. Guarded on the reveal gate
-- (colony must have reached the capability's `pop`) and affordability; on success
-- it deducts the cost, flips the unlock on (opening its closed-form income channel
-- and letting the world spawn its contents), toasts the tell, and persists. A
-- no-op if already owned, not yet revealed, or unaffordable.
local function buy_unlock(id)
  local pop = cell.state.sim.population
  if traits.is_unlocked(cell.state.traits, id) then
    return
  end
  if not traits.is_revealed(cell.state.traits, id, pop) then
    return
  end
  local cost = traits.unlock_cost(id)
  if not sim.spend(cell.state.sim, cost) then
    return
  end
  local fired = traits.unlock(cell.state.traits, id)
  if fired then
    toast.show(string.format("Evolved %s — %s", fired.label, fired.tell))
    view.spawn(view_state, fx.flash({ color = colors.secondary_bright, alpha = 0.22, life = 0.4 }))
    persist()
  end
end

-- The colony has FAILED only when it is EXTINCT -- the toxicity cull (sim.lua) has
-- killed every last cell. No aggregate trigger, no vitality threshold: the run
-- ends purely because the population reached 0, the natural end of the die-off. As
-- long as a single cell survives, feeding or leveling cleanup can still turn it
-- around. Returns true the moment the colony is wiped out.
local function is_extinct() return cell.state.sim.population <= 0 end

-- Begin the game-over beat: freeze the sim, shake + flash red, toast the cause.
-- The overlay runs for COLLAPSE_ANIM, then cell.update reloads a fresh lineage.
local function begin_collapse()
  collapsing = true
  collapse_anim = COLLAPSE_ANIM
  toast.show("The colony choked on its own waste — a new lineage begins")
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
  local s = cell.state.sim
  local chance = endo_chance(s.population)
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

function cell.load()
  retired = false -- a fresh lineage runs live again (clears any prior phase-2 hand-off)
  collapsing = false -- clear any prior game-over state (a fresh founder runs normally)
  collapse_anim = 0
  sound.load("pop", "assets/sounds/pop.ogg")
  sound.load("bloom", "assets/sounds/bloom.ogg")
  sound.load("endosymbiosis", "assets/sounds/endosymbiosis.ogg")
  local data = DEV_FRESH_START and {} or (save.read(SAVE_NAME) or {})
  cell.state = {
    traits = traits.load(data.traits),
    sim = sim.load(data.sim),
  }
  view_state = view.new()
  local width, height = 1280, 720
  if love and love.graphics then
    width, height = love.graphics.getDimensions()
  end
  world_state = world.new({
    rng = function() return love.math.random() end,
    aspect = width / height,
  })

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
  sim.tick(cell.state.sim, tick_dt, intake_for(cell.state))
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
      save.remove(SAVE_NAME)
      cell.load() -- fresh founder; clears collapsing via the load reset below
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

  local predation = traits.is_unlocked(cell.state.traits, "predation")
  local killed, engulfs, deaths, kill_points, engulf_points = world.update(world_state, dt, {
    stats = traits.stats(cell.state.traits),
    competition = comp_frac(cell.state.sim.age), -- 0..1 rival intensity -> competitor-cell skin
    dial_tempo = FIXED_TEMPO,
    aspect = aspect,
    target_population = target_population(cell.state),
    sim_cap = SIM_CAP, -- bound the CPU-simulated set; the visible swarm is the GPU field
    unlocked = traits.unlocked_set(cell.state.traits),
    threats_enabled = predation,
    bloom_exclude = bloom_exclude,
    bloom_confine = bloom_confine,
  })
  -- A live predator kill removes cells from the colony (a population setback the
  -- energy economy regrows; biomass -- the banked currency -- is untouched).
  if killed > 0 then
    sim.kill(cell.state.sim, killed)
  end
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
  -- Phase 1's climax: a prey engulf may keep the partner (endo_chance ramps with
  -- colony size), ending the run into a new lineage -- rare early, near-certain huge.
  if engulfs and engulfs > 0 then
    roll_endosymbiosis(engulfs, engulf_points, predation)
  end

  -- (Milestone capabilities are no longer auto-granted by colony size -- they are
  -- bought from the panel; see buy_unlock. Nothing to check on the tick.)
  -- Failure: the toxicity cull has driven the colony to extinction. End the run
  -- into a fresh lineage (game-over beat). Nothing fires while a cell still lives.
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

-- One trait row: a fill-width label column (name + level over a concrete hint) and a
-- right-pinned level-up button. Built ONLY for AVAILABLE traits -- the panel skips a
-- trait still gated behind an unfired evolution, so the Photosynthesis trait stays out
-- of this list until the Photosynthesis capability is evolved (then it appears here as
-- a normal levelable row -- the evolution "becomes" the trait, never a "needs X" gate).
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
  local predation = traits.is_unlocked(state.traits, "predation")
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

-- The EVOLUTIONS section: the milestone capabilities the player BUYS (formerly
-- auto-granted). One row per REVEALED-but-unbought capability -- a buy button gated
-- on biomass once the colony has grown enough to REVEAL it. A capability the colony
-- has not yet revealed is NOT listed here (no spoiler); it is teased only by the
-- self-revealing footer until it reveals. Owned capabilities drop out of this section
-- (photosynthesis becomes a normal levelable trait; phagocytosis just switches hunting
-- on). nil while nothing is revealed and once every capability is evolved, so the
-- section appears only when there is a capability to buy.
local function capability_children(state)
  local pop = state.sim.population
  local rows = {}
  for _, def in ipairs(traits.unlocks()) do
    -- Only REVEALED-but-unbought capabilities show as rows. A not-yet-revealed
    -- capability is no longer dumped here (no "colony N" spoiler) -- it is teased
    -- only by the self-revealing footer until the colony reaches its gate.
    if
      not traits.is_unlocked(state.traits, def.id) and traits.is_revealed(state.traits, def.id, pop)
    then
      local label_col = layout.vstack({
        layout.text(def.label, { color = colors.ui.text }),
        layout.text(def.tell, { color = colors.ui.text_faint }),
      }, { gap = 2 })

      local cost = traits.unlock_cost(def.id)
      local affordable = sim.can_spend(state.sim, cost)
      local right = action_button_node({
        label = "evolve",
        sublabel = format.number(cost) .. " bm",
        enabled = affordable,
        w = BTN_W,
        h = TRAIT_BTN_H,
        id = "unlock_" .. def.id,
        on_click = function() buy_unlock(def.id) end,
      })
      table.insert(rows, layout.hstack({ label_col, right }, { gap = theme.spacing.sm }))
    end
  end
  if #rows == 0 then
    return nil
  end
  table.insert(rows, 1, layout.text("evolutions", { color = colors.ui.text_dim }))
  return rows
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

  -- Trait list: concrete, direct levels. No slots, no splicing.
  local trait_children = { layout.text("traits", { color = colors.ui.text_dim }) }
  for _, id in ipairs(TRAIT_IDS) do
    -- Skip a trait still gated behind an unfired evolution (the Photosynthesis trait
    -- until the Photosynthesis capability is evolved): it shows in the evolutions
    -- section as an "evolve" purchase, then appears here as a levelable row -- never as
    -- a "needs Photosynthesis" gate in this list.
    if traits.is_available(state.traits, id) then
      table.insert(trait_children, trait_row(state, id))
    end
  end

  local groups = {
    layout.vstack(header, { gap = theme.spacing.xs }),
    layout.vstack(trait_children, { gap = theme.spacing.sm }),
  }

  local capability_group = capability_children(state)
  if capability_group then
    table.insert(groups, layout.vstack(capability_group, { gap = theme.spacing.sm }))
  end

  local organelle_group = organelle_children(state)
  if organelle_group then
    table.insert(groups, layout.vstack(organelle_group, { gap = theme.spacing.xs }))
  end

  -- Self-revealing teaser for the next capability the colony has not yet revealed:
  -- a silhouette as the colony grows toward the gate, then the named capability just
  -- before it reveals (where it becomes a real "evolve" row above). No spoiler cost,
  -- no "next:" -- and a fresh tiny colony (still hidden) or a fully-evolved one (nil)
  -- simply gets no footer line. Mirrors phase 2's self-revealing footer.
  local nxt = traits.next_teaser(state.traits, state.sim.population)
  local stage = nxt and traits.reveal_stage(state.sim.population, nxt)
  local tease
  if stage == "named" then
    tease = string.format("%s — almost ready", nxt.label)
  elseif stage == "silhouette" then
    tease = "something is forming in the colony…"
  end
  if tease then
    table.insert(groups, layout.text(tease, { color = colors.ui.text_muted }))
  end

  return layout.vstack(groups, { padding = PAD, gap = theme.spacing.md })
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
  text(rect(0, height / 2 + 8, width, 18), "choked on its own waste — a new lineage begins", {
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

return cell
