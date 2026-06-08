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
local function early_scale(n)
  return 1 + EARLY_SLOW * math.exp(-(n - 1) / EARLY_TAU)
end

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
    organelles = {}, -- acquired organelle ids (id -> true); folded by organelles.lua
  }
end

-- The per-cell energy cost of the colony's NEXT division. Exposed for the panel's
-- "energy toward the next division" bar. div_mult is the digestion discount.
function sim.div_cost(population, div_mult)
  return spacing(population or 1, div_mult)
end

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
local function intake_rate(intake, population)
  local photo = intake.photo or 0
  local forage = intake.forage_per_cell or 0
  local cap = intake.forage_cap or population
  local upkeep = intake.upkeep_per_cell or 0
  local mult = intake.mult or 1
  local growth = intake.growth_per_cell or 0
  local saturating = forage * math.min(population, cap)
  local compounding = growth * population -- never saturates -> exponential climb
  return (photo + saturating + compounding) * mult - upkeep * population
end

function sim.net_energy(intake, population)
  return intake_rate(intake, population or 1)
end

-- THE shared economy step, run by BOTH sim.tick and sim.offline so live and
-- offline stay identical and deterministic. Folds dt of intake into the reserve,
-- MINTS a division (banked biomass + a view pulse) for each cell the reserve can
-- now afford, then STARVES cells when the reserve has gone negative (upkeep
-- outran intake past carrying capacity). Biomass is never touched by starvation;
-- population floors at 1 (the founder never fully dies).
function sim.step(state, dt, intake)
  local div_mult = intake.div_mult or 1
  state.energy = state.energy + intake_rate(intake, state.population) * dt

  local minted = 0
  while state.energy >= spacing(state.population, div_mult) and minted < MAX_MINTS_PER_STEP do
    state.energy = state.energy - spacing(state.population, div_mult)
    state.population = state.population + 1
    state.biomass = state.biomass + DIV_YIELD
    state.total_divisions = state.total_divisions + 1
    state.pending_divisions = state.pending_divisions + 1
    minted = minted + 1
  end

  if state.energy < 0 then
    local deaths = math.min(state.population - 1, math.ceil(-state.energy / DEATH_RELEASE))
    state.population = state.population - deaths
    state.energy = math.max(0, state.energy + deaths * DEATH_RELEASE)
  end

  -- Fold this step's actual mints into the measured rate (divisions/sec). An
  -- event-rate EMA: each division contributes ~1/RATE_TAU and decays over the
  -- horizon, so the readout reflects real recent throughput -- stable near
  -- carrying capacity where the instantaneous theoretical rate whipsaws.
  if dt > 0 then
    local alpha = 1 - math.exp(-dt / RATE_TAU)
    state.div_rate = (state.div_rate or 0) + (minted / dt - (state.div_rate or 0)) * alpha
  end
end

-- One sim tick (runs even while backgrounded). intake is the folded table the
-- orchestrator assembles from metabolism + traits + organelles.
function sim.tick(state, dt, intake)
  sim.step(state, dt, intake)
end

-- A nutrient-bloom feed credits the energy reserve -- one of the real live deltas
-- over the cosmetic world sim. Negatives clamp to zero. Returns the amount added.
function sim.feed_burst(state, amount)
  amount = amount or 0
  if amount < 0 then
    amount = 0
  end
  state.energy = state.energy + amount
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
function sim.offline(state, seconds, intake)
  if seconds <= 0 then
    return
  end
  local n = math.ceil(seconds / OFFLINE_DT)
  if n > OFFLINE_MAX_STEPS then
    n = OFFLINE_MAX_STEPS
  end
  local dt = seconds / n
  for _ = 1, n do
    sim.step(state, dt, intake)
  end
end

function sim.can_spend(state, cost)
  return state.biomass >= cost
end

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
function sim.division_rate(intake, population)
  local pop = population or 1
  local net = intake_rate(intake, pop)
  if net <= 0 then
    return 0
  end
  return net / ((DIV_BASE + DIV_RANGE / 2) * early_scale(pop) * (intake.div_mult or 1))
end

-- The division-cost band across the colony: floor is the asymptotic base minimum
-- (DIV_BASE); ceiling is the founder's slow-started maximum. With the defaults,
-- (8, 112). Exposed for tests.
function sim.div_bounds()
  return DIV_BASE, (DIV_BASE + DIV_RANGE) * early_scale(1)
end

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
  if type(data.organelles) == "table" then
    for id in pairs(data.organelles) do
      state.organelles[id] = true
    end
  end
  return state
end

return sim
