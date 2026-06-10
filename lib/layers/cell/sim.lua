-- Cell sim: the headless heart of the loop and the AUTHORITATIVE economy.
-- The economy is INVERTED from the old passive-accrual model: biomass is no
-- longer a stream that accrues over time -- it is a BANKED CURRENCY minted purely
-- by successful DIVISIONS, spent by traits, and never touched by death. What
-- accrues now is an ENERGY reserve, folded from the colony's intake (photosynthesis
-- light + per-cell foraging, saturating at a finite food supply) minus per-cell
-- upkeep. When the reserve covers the next cell's energy cost a division mints a
-- cell + a chunk of biomass; when the reserve goes NEGATIVE (upkeep outruns intake
-- past carrying capacity) cells STARVE and the population falls -- but biomass is
-- kept. The colony floors at 1 (the founder never fully dies), so idle is gentle.
--
-- The live agent sim (world.lua) is a cosmetic skin over this closed form, with
-- exactly THREE real live deltas routed in by the orchestrator:
--   * feed_burst -- a nutrient-bloom click credits the energy reserve;
--   * kill       -- a live predator removes cells (population setback the energy
--                   economy regrows; biomass untouched -- never a currency loss);
--   * (endosymbiosis lives in organelles.lua + the orchestrator: a rare prey
--      engulf keeps an organelle, folded into intake -- the sim only banks the
--      acquired-organelle SET and total_divisions that gate it).
--
-- tick and offline share ONE step(state, dt, intake) so live and offline stay
-- identical and deterministic (no rng anywhere -- division-cost jitter is a pure
-- index hash; offline replays the same step in capped sub-steps). Pure Lua 5.1.
local sim = {}

-- Division ENERGY cost: a JITTERED, SLOW-STARTED band. The next cell's cost is a
-- deterministic draw in [DIV_BASE, DIV_BASE+DIV_RANGE] (a hash of the cell index,
-- not rng, so offline/load stay closed-form), scaled by early_scale(n) -- a big
-- factor for the founder decaying toward 1 as the colony grows. So the first
-- division idles ~20-30s on the founder's intake and divisions accelerate later.
local DIV_BASE, DIV_RANGE = 8, 8
local EARLY_SLOW, EARLY_TAU = 6, 6

local DIV_YIELD = 2 -- banked biomass minted by each successful division
-- Smoothing horizon (seconds) for the MEASURED division-rate readout: div_rate
-- is an exponential moving average of actual divisions minted per second, so the
-- panel shows real throughput instead of the instantaneous theoretical rate
-- (which whipsaws near carrying capacity as the integer population wobbles).
local RATE_TAU = 12
local DEATH_RELEASE = 3 -- energy a starvation death refunds (each deficit unit culls more cells)
-- There is NO population ceiling: with the open-ended COMPOUNDING economy the
-- colony climbs without bound (the old 8M wall is gone -- both as a mechanic and
-- as a HUD readout). The mint loop is instead bounded PER STEP by MAX_MINTS_PER_STEP
-- -- a pure safety guard so a single step (e.g. a long offline sub-step folding a
-- huge reserve) can never spin unboundedly; population itself keeps growing across
-- steps. Live ticks mint a tiny fraction of this each frame, so it never binds play.
local MAX_MINTS_PER_STEP = 200000

-- WASTE / TOXICITY -- the failure pressure. Metabolising cells foul their medium
-- over time; if the colony cannot CLEAR that waste as fast as it accrues, toxicity
-- climbs and CHOKES intake. The whole intake side (photosynthesis + foraging + the
-- compounding surplus) is scaled by a HEALTH factor tox_half / (tox_half + toxicity)
-- -- 1 in a clean dish (so a tended colony behaves EXACTLY as before), falling
-- toward 0 as waste builds, at which point upkeep outruns the throttled intake and
-- the colony starves back toward the founder. Toxicity is part of the closed form
-- (folded in sim.step from intake.tox_prod - intake.tox_clear), so offline replays
-- it identically. tox_prod/tox_clear/tox_half are supplied by the orchestrator's
-- intake fold (cleanup rises with the digestion/evasion/photosynthesis traits and
-- with feeding); when they are absent (e.g. the headless specs' bare intake) the
-- system is inert and the economy is the pure pre-toxicity model. TOX_MAX is a
-- safety clamp so a long offline sub-step can't blow the number up unboundedly.
local TOX_MAX = 10000

-- Offline relaxation: replay the shared step in fixed sub-steps so leaving and
-- returning converges the colony toward carrying capacity instead of crashing.
local OFFLINE_DT = 2 -- target sub-step seconds
local OFFLINE_MAX_STEPS = 2000 -- cap the loop regardless of time away

-- Deterministic [0,1) from an integer (the classic sin-fract hash). Pure, so a
-- given cell index always yields the same division cost -- offline and load
-- replay the exact same colony as the live tick.
local function hash01(n)
  local h = math.sin(n * 12.9898 + 78.233) * 43758.5453
  return h - math.floor(h)
end

-- Slow-start multiplier on the division cost: ~(1 + EARLY_SLOW) at the founder
-- (n=1), decaying exponentially toward 1 as the colony grows.
local function early_scale(n) return 1 + EARLY_SLOW * math.exp(-(n - 1) / EARLY_TAU) end

-- Energy the next division (reaching cell index n) costs: a jittered base band
-- scaled by the slow-start factor, then by the digestion div_mult (< 1 once the
-- trait is leveled). Always > 0; index + a folded stat, so still closed-form.
local function spacing(n, mult)
  return (DIV_BASE + DIV_RANGE * hash01(n)) * early_scale(n) * (mult or 1)
end

function sim.new()
  return {
    biomass = 0, -- banked currency: minted per division, spent by traits, never lost to death
    energy = 0, -- nutrient reserve: drives growth and starvation
    population = 1, -- the colony starts as a single founder cell (floors here)
    total_divisions = 0, -- lifetime divisions ever (gates endosymbiosis)
    pending_divisions = 0, -- new divisions awaiting a view pulse
    div_rate = 0, -- measured divisions/sec, EMA-smoothed over RATE_TAU (the panel readout)
    toxicity = 0, -- accumulated waste; throttles intake AND culls cells (the failure pressure)
    tox_death_debt = 0, -- fractional-death accumulator for the smooth toxicity cull (transient)
    -- AGE -- seconds since this lineage began. The competition and predation ramps
    -- are keyed on this clock (mirroring the lab harness's elapsed-time `t`), so a
    -- persisted age lets offline replay the SAME ramp position the live run reached.
    -- Ticked in sim.step; because sim.offline replays sim.step in sub-steps, age
    -- advances identically offline -- that is the whole point of persisting it.
    age = 0,
    pred_death_debt = 0, -- fractional-death accumulator for the smooth predation cull (transient)
    net_rate = 0, -- measured NET replication/sec (births - all deaths), EMA-smoothed over RATE_TAU
    organelles = {}, -- acquired organelle ids (id -> true); folded by organelles.lua
  }
end

-- The per-cell energy cost of the colony's NEXT division. Exposed for the panel's
-- "energy toward the next division" bar. div_mult is the digestion discount.
function sim.div_cost(population, div_mult) return spacing(population or 1, div_mult) end

-- Net energy/sec at a colony size, from the folded intake. Foraging saturates at
-- forage_cap cells (a finite food supply); upkeep scales with every cell. Below
-- the cap the colony grows; once upkeep outruns the saturated intake it starves.
-- Net energy/sec. Three channels, all scaled by mult: the population-independent
-- light income (photo), the per-cell foraging that SATURATES past forage_cap (the
-- legacy logistic faucet), and -- the open-ended part -- a per-cell COMPOUNDING
-- income (growth_per_cell) that does NOT saturate, so income scales with the
-- colony and growth becomes exponential. Linear upkeep is the only drain. When
-- growth_per_cell == 0 this is exactly the old logistic model (carrying capacity
-- K); when growth_per_cell*mult exceeds upkeep the colony climbs without a finite
-- cap, growing without bound.
-- The HEALTH factor that toxicity imposes on the intake side: 1 in a clean dish
-- (toxicity 0 or no tox model supplied), falling toward 0 as waste builds. With
-- tox_half waste the intake is throttled to half. Pure; no state.
function sim.health(toxicity, tox_half)
  if not tox_half or tox_half <= 0 or not toxicity or toxicity <= 0 then
    return 1
  end
  return tox_half / (tox_half + toxicity)
end

local function intake_rate(intake, population, toxicity)
  local photo = intake.photo or 0
  local forage = intake.forage_per_cell or 0
  local cap = intake.forage_cap or population
  local upkeep = intake.upkeep_per_cell or 0
  local mult = intake.mult or 1
  local growth = intake.growth_per_cell or 0
  local saturating = forage * math.min(population, cap)
  local compounding = growth * population -- never saturates -> exponential climb
  -- Toxicity throttles the WHOLE intake side (light + foraging + compounding); the
  -- upkeep drain is unchanged, so a fouled dish tips net-negative and starves.
  local health = sim.health(toxicity, intake.tox_half)
  return (photo + saturating + compounding) * mult * health - upkeep * population
end

function sim.net_energy(intake, population, toxicity)
  return intake_rate(intake, population or 1, toxicity)
end

-- THE shared economy step, run by BOTH sim.tick and sim.offline so live and
-- offline stay identical and deterministic. Folds dt of intake into the reserve,
-- MINTS a division (banked biomass + a view pulse) for each cell the reserve can
-- now afford, then STARVES cells when the reserve has gone negative (upkeep
-- outran intake past carrying capacity). Biomass is never touched by starvation;
-- population floors at 1 (the founder never fully dies).
function sim.step(state, dt, intake)
  local div_mult = intake.div_mult or 1
  local pop_before = state.population
  local div_before = state.total_divisions

  -- Waste accrues (tox_prod) and is cleared (tox_clear, from cleanup traits +
  -- feeding); the net moves toxicity each step. Absent a tox model both default to
  -- 0 and toxicity holds at its initial 0, so the economy is the clean-dish form.
  -- Updated BEFORE the energy fold so this step's intake feels the current waste.
  local tox = (state.toxicity or 0) + ((intake.tox_prod or 0) - (intake.tox_clear or 0)) * dt
  if tox < 0 then
    tox = 0
  elseif tox > TOX_MAX then
    tox = TOX_MAX
  end
  state.toxicity = tox

  state.energy = state.energy + intake_rate(intake, state.population, tox) * dt

  local minted = 0
  -- pop >= 1 guard: an EXTINCT colony (0 cells, after a toxic die-off) never
  -- spontaneously mints a cell back -- extinction is final until the orchestrator
  -- seeds a fresh lineage.
  while
    state.population >= 1
    and state.energy >= spacing(state.population, div_mult)
    and minted < MAX_MINTS_PER_STEP
  do
    state.energy = state.energy - spacing(state.population, div_mult)
    state.population = state.population + 1
    state.biomass = state.biomass + DIV_YIELD
    state.total_divisions = state.total_divisions + 1
    state.pending_divisions = state.pending_divisions + 1
    minted = minted + 1
  end

  -- Carrying-capacity starvation: an over-cap colony trims back toward K. This is
  -- the GENTLE pressure -- it floors at 1 (the founder never dies of ordinary
  -- hunger), so idle is forgiving.
  if state.energy < 0 then
    local deaths = math.min(state.population - 1, math.ceil(-state.energy / DEATH_RELEASE))
    state.population = state.population - deaths
    state.energy = math.max(0, state.energy + deaths * DEATH_RELEASE)
  end

  -- TOXICITY CULL: the LETHAL pressure (the failure condition). Once waste passes
  -- intake.tox_tolerance the fouled medium kills cells directly -- a fraction of the
  -- colony per second, rising with the overage. Unlike starvation this does NOT
  -- floor at 1: a neglected dish kills cells one by one to EXTINCTION (0), and the
  -- orchestrator ends the run there. A fractional-death accumulator keeps the cull
  -- smooth and frame-rate independent (no "at least one per tick" boundary spike),
  -- and deterministic so offline replays the same die-off.
  local tol = intake.tox_tolerance
  if tol and tox > tol and state.population > 0 then
    local frac = (tox - tol) * (intake.tox_kill_k or 0) * dt -- fraction of the colony this step
    state.tox_death_debt = (state.tox_death_debt or 0) + frac * state.population
    local deaths = math.floor(state.tox_death_debt)
    if deaths > 0 then
      if deaths > state.population then
        deaths = state.population
      end
      state.population = state.population - deaths
      state.tox_death_debt = state.tox_death_debt - deaths
    end
  else
    state.tox_death_debt = 0 -- below tolerance: clear any partial debt (recovery)
  end

  -- PREDATION CULL: the ramping, FLOORLESS pressure (the death-spiral kill), now a
  -- real closed-form term (the lab proved it out as a post-step cull in survival_run;
  -- here it lives inside the shared step so live AND offline replay it identically).
  -- intake.pred_cull_frac is the per-second fraction of the surviving colony removed,
  -- ALREADY folded with evasion mitigation by the orchestrator (cell.lua intake_for).
  -- Absent/0 by default, so the headless specs and any caller that omits it are
  -- byte-identical to before. Unlike starvation it does NOT floor at 1: an unevaded,
  -- harassed colony decays cell by cell to literal EXTINCTION (0). A fractional-death
  -- accumulator (mirroring tox_death_debt) keeps the cull smooth and deterministic.
  local pcf = intake.pred_cull_frac
  if pcf and pcf > 0 and state.population > 0 then
    state.pred_death_debt = (state.pred_death_debt or 0) + pcf * dt * state.population
    local deaths = math.floor(state.pred_death_debt)
    if deaths > 0 then
      if deaths > state.population then
        deaths = state.population
      end
      state.population = state.population - deaths
      state.pred_death_debt = state.pred_death_debt - deaths
    end
  else
    state.pred_death_debt = 0 -- no predation this step: clear any partial debt
  end

  -- AGE: advance the lineage clock AFTER the folds (the competition/predation ramps
  -- this step felt were keyed on the age the caller's intake was built from -- the
  -- PRE-step age -- so age advances here for the NEXT step). Because sim.offline
  -- replays this same step in sub-steps, age accrues identically offline.
  state.age = (state.age or 0) + dt

  -- Fold this step's actual mints into the measured rate (divisions/sec). An
  -- event-rate EMA: each division contributes ~1/RATE_TAU and decays over the
  -- horizon, so the readout reflects real recent throughput -- stable near
  -- carrying capacity where the instantaneous theoretical rate whipsaws.
  if dt > 0 then
    local alpha = 1 - math.exp(-dt / RATE_TAU)
    state.div_rate = (state.div_rate or 0) + (minted / dt - (state.div_rate or 0)) * alpha
    -- NET replication/sec = births minus ALL deaths this step (starvation +
    -- toxicity + predation), EMA-smoothed over the same horizon. Births this step
    -- are the mints (total_divisions - div_before); every cell that vanished
    -- (births minus the net population change) is a death. So the net replication
    -- rate collapses cleanly to (population change) / dt -- births - deaths/sec.
    local births = state.total_divisions - div_before
    local deaths = births - (state.population - pop_before)
    local net_step = (births - deaths) / dt
    state.net_rate = (state.net_rate or 0) + (net_step - (state.net_rate or 0)) * alpha
  end
end

-- One sim tick (runs even while backgrounded). intake is the folded table the
-- orchestrator assembles from metabolism + traits + organelles.
function sim.tick(state, dt, intake) sim.step(state, dt, intake) end

-- A nutrient-bloom feed credits the energy reserve -- one of the real live deltas
-- over the cosmetic world sim. Negatives clamp to zero. Returns the amount added.
-- A feed is also a FLUSH: the optional tox_clear scrubs that much accumulated
-- waste (floored at 0), so diligent feeding is a second survival lever alongside
-- leveling the cleanup traits. Omitted tox_clear leaves toxicity untouched.
function sim.feed_burst(state, amount, tox_clear)
  amount = amount or 0
  if amount < 0 then
    amount = 0
  end
  state.energy = state.energy + amount
  if tox_clear and tox_clear > 0 then
    state.toxicity = math.max(0, (state.toxicity or 0) - tox_clear)
  end
  return amount
end

-- A live predator kill removes cells from the colony. Population floors at 1;
-- biomass is untouched (a kill is a population setback the energy economy regrows,
-- never a currency loss). Live-only: never applied offline. Returns cells lost.
function sim.kill(state, n)
  n = n or 0
  local lost = math.min(math.max(math.floor(n), 0), state.population - 1)
  state.population = state.population - lost
  return lost
end

-- Lump-sum catch-up for time away: replay the shared step in fixed sub-steps so
-- the colony relaxes toward carrying capacity (never a crash to zero). The
-- sub-step count is capped, so any duration is covered in bounded work.
--
-- intake may be EITHER a plain folded table (the legacy form -- a single static
-- intake replayed every sub-step, used by complexcell and the headless specs) OR
-- a PROVIDER function intake_fn(state) returning the intake table for the colony's
-- CURRENT state. The provider form is required now that the cell economy's
-- competition + predation ramps are keyed on state.age (which sim.step advances
-- every sub-step): a single precomputed table would freeze the ramp at t=0, so the
-- caller passes a closure over intake_for and we recompute the fold each sub-step.
-- This is exactly what keeps offline byte-identical to the live per-frame path
-- (which already recomputes intake every tick). Passing a table stays inert/static
-- as before, so other callers are unaffected.
function sim.offline(state, seconds, intake)
  if seconds <= 0 then
    return
  end
  local n = math.ceil(seconds / OFFLINE_DT)
  if n > OFFLINE_MAX_STEPS then
    n = OFFLINE_MAX_STEPS
  end
  local dt = seconds / n
  local is_provider = type(intake) == "function"
  for _ = 1, n do
    sim.step(state, dt, is_provider and intake(state) or intake)
  end
end

function sim.can_spend(state, cost) return state.biomass >= cost end

-- Deduct an upgrade cost from the banked biomass. Returns success.
function sim.spend(state, cost)
  if state.biomass < cost then
    return false
  end
  state.biomass = state.biomass - cost
  return true
end

-- Consume and return the divisions queued since the last call, so the view can
-- fire that many mitosis pulses without missing or repeating any.
function sim.take_divisions(state)
  local n = state.pending_divisions
  state.pending_divisions = 0
  return n
end

-- Carrying capacity K: the colony size at which the saturated intake exactly
-- meets upkeep -- the population the food supply can sustain. No longer surfaced in
-- the HUD; kept as the closed-form reference (and for tests) on the legacy logistic
-- economy. Floors at 1.
function sim.capacity(intake)
  local photo = intake.photo or 0
  local forage = intake.forage_per_cell or 0
  local cap = intake.forage_cap or 0
  local upkeep = intake.upkeep_per_cell or 0
  local mult = intake.mult or 1
  local growth = intake.growth_per_cell or 0
  -- The compounding income offsets upkeep per cell. Once it covers upkeep the
  -- colony has NO finite carrying capacity -- it grows without bound.
  local eff_upkeep = upkeep - growth * mult
  if eff_upkeep <= 0 then
    return math.huge
  end
  local k = (photo + forage * cap) * mult / eff_upkeep
  if k < 1 then
    return 1
  end
  return k
end

-- THEORETICAL divisions/sec at a folded intake and colony size: net energy
-- divided by the AVERAGE division cost at this size. Zero once the colony is at
-- or past its cap (net energy <= 0). The panel readout uses the MEASURED
-- state.div_rate instead (this whipsaws near capacity as the integer population
-- wobbles); kept for tests and as the closed-form reference curve.
function sim.division_rate(intake, population, toxicity)
  local pop = population or 1
  local net = intake_rate(intake, pop, toxicity)
  if net <= 0 then
    return 0
  end
  return net / ((DIV_BASE + DIV_RANGE / 2) * early_scale(pop) * (intake.div_mult or 1))
end

-- The division-cost band across the colony: floor is the asymptotic base minimum
-- (DIV_BASE); ceiling is the founder's slow-started maximum. With the defaults,
-- (8, 112). Exposed for tests.
function sim.div_bounds() return DIV_BASE, (DIV_BASE + DIV_RANGE) * early_scale(1) end

-- Plain-data snapshot. Persists the banked currency, the reserve, the colony
-- size, the lifetime division count, and the acquired organelles.
function sim.serialize(state)
  local organelles = {}
  for id in pairs(state.organelles) do
    organelles[id] = true
  end
  return {
    biomass = state.biomass,
    energy = state.energy,
    population = state.population,
    total_divisions = state.total_divisions,
    div_rate = state.div_rate,
    net_rate = state.net_rate,
    toxicity = state.toxicity,
    age = state.age, -- the lineage clock that re-keys the competition/predation ramps offline
    organelles = organelles,
  }
end

-- Rebuild from serialize() data, tolerant of missing/legacy fields. Legacy saves
-- (lifetime/next_div/evolve_mult/generation) are simply ignored; a present
-- population is trusted (floored at 1). No view pulses are queued.
function sim.load(data)
  local state = sim.new()
  data = data or {}
  if type(data.biomass) == "number" then
    state.biomass = data.biomass
  end
  if type(data.energy) == "number" then
    state.energy = data.energy
  end
  if type(data.population) == "number" and data.population >= 1 then
    state.population = math.floor(data.population)
  end
  if type(data.total_divisions) == "number" and data.total_divisions >= 0 then
    state.total_divisions = math.floor(data.total_divisions)
  end
  if type(data.div_rate) == "number" and data.div_rate >= 0 then
    state.div_rate = data.div_rate
  end
  if type(data.net_rate) == "number" then
    state.net_rate = data.net_rate -- may be negative (a dying colony); no floor
  end
  if type(data.toxicity) == "number" and data.toxicity >= 0 then
    state.toxicity = data.toxicity
  end
  if type(data.age) == "number" and data.age >= 0 then
    state.age = data.age
  end
  if type(data.organelles) == "table" then
    for id in pairs(data.organelles) do
      state.organelles[id] = true
    end
  end
  return state
end

return sim
