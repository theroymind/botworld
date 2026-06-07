-- Cell sim: the headless heart of the loop and the AUTHORITATIVE economy.
-- Biomass accrues at a net rate the orchestrator folds from metabolism (at a
-- fixed sweet-spot base rate), the traits and the unlocked income channels
-- (passed in -- this module knows nothing of metabolism or traits, so it stays
-- decoupled and testable). Lifetime totals
-- never fall when biomass is spent, so POPULATION (division events) only ever
-- climbs; MATURITY (the evolve gate) is now keyed on COLONY SIZE
-- (population / MATURITY_POP_TARGET), so "grow the colony to evolve" is literal.
--
-- The live agent sim (world.lua) is a cosmetic skin over this closed form and
-- never feeds back into it, with exactly two real live deltas routed here:
--   * feed_burst -- a nutrient-bloom click credits a biomass burst (counts as a
--     real gain, so it advances the colony).
--   * threat_loss -- a live predator kill debits biomass only; lifetime is left
--     untouched so a kill never rolls back the colony. Combat is a scare, not a
--     setback, and the always-positive baseline heals it. Predators are
--     live-only and ignored offline.
--
-- Evolve is a prestige stub: bank a carried net multiplier and reset. Patterns
-- (accrue, offline lump-sum, tolerant serialize/load) borrow from
-- lib/engine/economy.lua. Pure Lua 5.1.
local sim = {}

local TAP_BASE = 5 -- biomass per manual nutrient-bloom feed, before the feed fold
-- Division thresholds are JITTERED and SLOW-STARTED. The base lifetime cost of
-- the next cell is drawn from a deterministic band [DIV_BASE, DIV_BASE+DIV_RANGE]
-- (a hash of the cell index, not rng, so offline/load stay closed-form), then
-- multiplied by early_scale(n) -- a big factor for the founder that decays toward
-- 1 as the colony grows. So the first division idles ~20-30s and divisions
-- accelerate later: a real solo-cell open, not over in seconds.
local DIV_BASE, DIV_RANGE = 8, 8 -- base band [8,16] (avg 12) before the slow-start
local EARLY_SLOW, EARLY_TAU = 6, 6 -- slow-start: +6x at the founder, e-folding over ~6 cells
local MATURITY_POP_TARGET = 50 -- colony size that fills the evolve gate
local EVOLVE_BONUS = 1.5 -- carried net multiplier banked per evolve

local function clamp01(value)
  if value < 0 then
    return 0
  elseif value > 1 then
    return 1
  end
  return value
end

-- Deterministic [0,1) from an integer (the classic sin-fract hash). Pure, so a
-- given cell index always yields the same division spacing -- offline and load
-- replay the exact same colony as the live tick.
local function hash01(n)
  local h = math.sin(n * 12.9898 + 78.233) * 43758.5453
  return h - math.floor(h)
end

-- Slow-start multiplier on division spacing: ~(1 + EARLY_SLOW) at the founder
-- (n=1), decaying exponentially toward 1 as the colony grows. This stretches the
-- first few divisions into a real solo-cell open and lets later ones accelerate.
local function early_scale(n)
  return 1 + EARLY_SLOW * math.exp(-(n - 1) / EARLY_TAU)
end

-- Lifetime biomass the next division (reaching cell index n) costs: a jittered
-- base band scaled by the slow-start factor. Always > 0, so the running threshold
-- strictly increases; index-only, so offline/load stay closed-form.
local function spacing(n)
  return (DIV_BASE + DIV_RANGE * hash01(n)) * early_scale(n)
end

-- Refresh lifetime-derived fields; queue a pulse for each newly crossed division.
-- next_div is the lifetime threshold of the NEXT cell; each crossing bumps the
-- population and advances the threshold by that new cell's jittered spacing (the
-- post-increment index), so the band keeps marching forward. Maturity is
-- colony-size driven: it tracks population, not raw lifetime.
local function settle(state)
  while state.lifetime >= state.next_div do
    state.population = state.population + 1
    state.pending_divisions = state.pending_divisions + 1
    state.next_div = state.next_div + spacing(state.population)
  end
  state.maturity = clamp01(state.population / MATURITY_POP_TARGET)
end

-- Apply a gain to biomass + lifetime. Mirrors economy.lua: only positive gains
-- count toward lifetime, so spending never lowers it.
local function gain(state, amount)
  state.biomass = state.biomass + amount
  if amount > 0 then
    state.lifetime = state.lifetime + amount
  end
  settle(state)
end

function sim.new()
  return {
    biomass = 0,
    lifetime = 0, -- total ever gained; divisions + maturity derive from this
    population = 1, -- the colony starts as a single founder cell
    next_div = spacing(1), -- lifetime threshold of the next division
    maturity = 1 / MATURITY_POP_TARGET, -- one cell's worth of the colony gate
    pending_divisions = 0, -- new divisions awaiting a view pulse (founder fires none)
    evolve_mult = 1, -- carried net multiplier from past evolves
    generation = 0, -- evolves performed
  }
end

-- Passive accrual for one sim tick. net_rate is biomass/sec (folded outside).
function sim.tick(state, dt, net_rate)
  gain(state, net_rate * dt)
end

-- Manual nutrient-bloom feed; tap_mult is the folded feed channel (default 1).
function sim.tap(state, tap_mult)
  gain(state, TAP_BASE * (tap_mult or 1))
end

-- A nutrient-bloom click credits a biomass burst -- one of the two real live
-- deltas over the cosmetic world sim. It is a real gain, so it advances the
-- colony. Returns the amount credited.
function sim.feed_burst(state, amount)
  amount = amount or 0
  if amount < 0 then
    amount = 0
  end
  gain(state, amount)
  return amount
end

-- A live predator kill debits biomass -- the other real live delta. Lifetime is
-- left untouched (population/maturity never roll back), and the debit clamps so
-- biomass never goes negative. Live-only: never applied offline. Returns the
-- biomass actually lost.
function sim.threat_loss(state, biomass_lost)
  biomass_lost = biomass_lost or 0
  local lost = math.min(math.max(biomass_lost, 0), state.biomass)
  state.biomass = state.biomass - lost
  return lost
end

-- Lump-sum catch-up for time away; returns the biomass gained. Uses only the
-- closed-form rate -- no predators, no agent dependency, so offline stays pure.
function sim.offline(state, seconds, net_rate)
  local amount = net_rate * seconds
  if amount < 0 then
    amount = 0
  end
  gain(state, amount)
  return amount
end

function sim.can_spend(state, cost)
  return state.biomass >= cost
end

-- Deduct an upgrade cost (lifetime untouched). Returns success.
function sim.spend(state, cost)
  if state.biomass < cost then
    return false
  end
  state.biomass = state.biomass - cost
  return true
end

-- Consume and return the count of divisions queued since the last call, so the
-- view can fire that many pulses without missing or repeating any.
function sim.take_divisions(state)
  local n = state.pending_divisions
  state.pending_divisions = 0
  return n
end

function sim.can_evolve(state)
  return state.maturity >= 1
end

-- Prestige stub: bank the carried multiplier and reset the colony. No-op
-- (returns nil) unless mature; otherwise returns the new evolve_mult to toast.
function sim.evolve(state)
  if not sim.can_evolve(state) then
    return nil
  end
  state.evolve_mult = state.evolve_mult * EVOLVE_BONUS
  state.generation = state.generation + 1
  state.biomass = 0
  state.lifetime = 0
  state.population = 1
  state.next_div = spacing(1)
  state.maturity = 1 / MATURITY_POP_TARGET
  state.pending_divisions = 0
  return state.evolve_mult
end

-- Divisions/sec at a given net rate and colony size; the readout the panel shows.
-- Keyed on the AVERAGE base spacing scaled by the population's slow-start factor,
-- so the readout honestly reflects slow early divisions accelerating as the
-- colony grows. population defaults to the founder.
function sim.division_rate(net_rate, population)
  return net_rate / ((DIV_BASE + DIV_RANGE / 2) * early_scale(population or 1))
end

-- Colony size that fills the evolve gate (the maturity denominator).
function sim.maturity_pop_target()
  return MATURITY_POP_TARGET
end

-- The division-spacing band across the whole colony: the floor is the asymptotic
-- base minimum (DIV_BASE); the ceiling is the founder's slow-started maximum
-- ((DIV_BASE + DIV_RANGE) * early_scale(1)). With the defaults this is (8, 112).
function sim.div_bounds()
  return DIV_BASE, (DIV_BASE + DIV_RANGE) * early_scale(1)
end

-- Replay the colony from the founder up to the persisted lifetime WITHOUT
-- queueing view pulses -- a fresh load has no pending mitosis to animate. Used
-- only when population/next_div are absent (a legacy save); otherwise load is
-- O(1). Deterministic spacing means this reproduces the live colony exactly.
local function rebuild(state)
  state.population = 1
  state.next_div = spacing(1)
  while state.lifetime >= state.next_div do
    state.population = state.population + 1
    state.next_div = state.next_div + spacing(state.population)
  end
  state.maturity = clamp01(state.population / MATURITY_POP_TARGET)
end

-- Plain-data snapshot. population + next_div are persisted so load is O(1); the
-- rest (maturity, pending) is derived.
function sim.serialize(state)
  return {
    biomass = state.biomass,
    lifetime = state.lifetime,
    population = state.population,
    next_div = state.next_div,
    evolve_mult = state.evolve_mult,
    generation = state.generation,
  }
end

-- Rebuild from serialize() data, tolerant of missing/stale fields. When the
-- persisted colony cursor (population + next_div) is present we trust it (O(1));
-- a legacy save without it replays from lifetime via rebuild(). Either way no
-- pulses are queued.
function sim.load(data)
  local state = sim.new()
  data = data or {}
  if type(data.biomass) == "number" then
    state.biomass = data.biomass
  end
  if type(data.lifetime) == "number" then
    state.lifetime = data.lifetime
  end
  if type(data.evolve_mult) == "number" then
    state.evolve_mult = data.evolve_mult
  end
  if type(data.generation) == "number" then
    state.generation = data.generation
  end
  if type(data.population) == "number" and type(data.next_div) == "number" then
    state.population = data.population
    state.next_div = data.next_div
    state.maturity = clamp01(state.population / MATURITY_POP_TARGET)
  else
    rebuild(state)
  end
  return state
end

return sim
