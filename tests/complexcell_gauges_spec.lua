-- Standalone spec for the Pillar-5 GAUGE helpers in lib/layers/complexcell/catalog.lua
-- (the biologically-named readouts the orchestrator's panel surfaces). Plain Lua 5.1, no
-- framework. Run from the repo root:
--   lua tests/complexcell_gauges_spec.lua
--
-- These pin the PURE derived math behind the gauges -- demand, balance_ratio, the fixed
-- safe-band ceiling, and the under/ideal/over band classification -- so the renderer stays
-- logic-free and the numbers can't drift from the economy. Every expected value is DERIVED
-- from the catalog's source constants (no magic numbers), and the gauges are asserted to
-- AGREE with the fold/balance-scalar the sim itself runs on.
local root = (arg and arg[0] or ""):match("^(.*)/tests/[^/]*$") or "."
package.path = root .. "/?.lua;" .. package.path

local catalog = require("lib.layers.complexcell.catalog")
local sim = require("lib.layers.complexcell.sim")

local checks = 0

local function check(condition, label)
  checks = checks + 1
  if not condition then
    error("FAILED: " .. label, 2)
  end
end

local function approx(a, b) return math.abs(a - b) < 1e-9 end

-- A hand-built phase-2 state (mirrors the catalog spec's helper): fresh sim seeds
-- mito = 1; ribosomes online at level 1 unless overridden.
local function state(o)
  o = o or {}
  local s = sim.new()
  s.mito = o.mito or 1
  s.built = o.built or 0
  s.unlocked = o.unlocked or { ribosomes = true }
  s.stages = o.stages or { ribosomes = 1 }
  s.ros = o.ros or 0
  return s
end

-- ---------------------------------------------------------------------------
-- demand: e*throughput + upkeep -- the SAME demand the sim's balance scalar uses.
-- ---------------------------------------------------------------------------
do
  -- mito 1, ribosomes lvl 1: throughput = ribosomes_rate*1, upkeep = UPKEEP*(mito+levels).
  local s = state()
  local rates = catalog.fold(s)
  local want = rates.e_per_output * rates.throughput + rates.upkeep
  check(approx(catalog.demand(s), want), "demand = e*throughput + upkeep (folded once)")
  -- It is strictly positive even on a minimal line (upkeep counts mito >= 1), so the
  -- ratio divides below can never blow up.
  check(catalog.demand(s) > 0, "demand is strictly positive (upkeep floor)")
end

-- ---------------------------------------------------------------------------
-- balance_ratio: power / demand -- the same ratio the ROS pendulum keys off.
-- ---------------------------------------------------------------------------
do
  local s = state()
  local rates = catalog.fold(s)
  check(
    approx(catalog.balance_ratio(s), rates.power / catalog.demand(s)),
    "balance_ratio = power / demand"
  )
  -- More mitochondria with the SAME line raises the ratio (more power over fixed-ish
  -- demand) -- the over-power direction the gauge must show.
  local lo = catalog.balance_ratio(state({ mito = 1 }))
  local hi = catalog.balance_ratio(state({ mito = 8 }))
  check(hi > lo, "adding power raises the balance ratio (over-power direction)")
end

-- ---------------------------------------------------------------------------
-- balance_hi_eff: the safe-band ceiling, now the FIXED BALANCE_HI (no antioxidant lever
-- lifts it). The view classes the ratio under/ideal/over against [BALANCE_LO, BALANCE_HI].
-- ---------------------------------------------------------------------------
do
  check(
    approx(catalog.balance_hi_eff(state()), catalog.BALANCE_HI),
    "balance_hi_eff is the fixed BALANCE_HI"
  )
  -- It is constant across states (it no longer varies with anything the player buys), and it
  -- mirrors the fold the sim consumes -- so the gauge band can never drift from the economy's
  -- actual ROS threshold.
  check(
    approx(catalog.balance_hi_eff(state({ mito = 8 })), catalog.BALANCE_HI),
    "balance_hi_eff does not vary with the cell's build"
  )
  local s = state()
  check(
    approx(catalog.balance_hi_eff(s), catalog.fold(s).balance_hi_eff),
    "balance_hi_eff mirrors fold().balance_hi_eff"
  )
end

-- ---------------------------------------------------------------------------
-- balance_band: under / ideal / over, classed against [BALANCE_LO, balance_hi_eff].
-- The boundaries MUST line up with sim.balance_scalar's power_balance branches so the
-- gauge's verdict matches the economy that actually browns out / leaks ROS.
-- ---------------------------------------------------------------------------
do
  -- A deep power deficit (many ribosome levels, one mito) sits below BALANCE_LO -> UNDER.
  local deficit = state({ mito = 1, unlocked = { ribosomes = true }, stages = { ribosomes = 50 } })
  check(catalog.balance_ratio(deficit) < catalog.BALANCE_LO, "deficit line is below BALANCE_LO")
  check(catalog.balance_band(deficit) == catalog.BAND_UNDER, "below BALANCE_LO classes UNDER")

  -- Piling on mitochondria past the safe ceiling (with a fixed minimal line) classes OVER.
  local over = state({ mito = 20 })
  check(
    catalog.balance_ratio(over) > catalog.balance_hi_eff(over),
    "over-powered line is above balance_hi_eff"
  )
  check(catalog.balance_band(over) == catalog.BAND_OVER, "above balance_hi_eff classes OVER")

  -- A ratio sitting inside the band classes IDEAL. Find a mito count whose ratio lands in
  -- [BALANCE_LO, balance_hi_eff] for the minimal line, then assert the verdict.
  local ideal = nil
  for mito = 1, 20 do
    local s = state({ mito = mito })
    local ratio = catalog.balance_ratio(s)
    if ratio >= catalog.BALANCE_LO and ratio <= catalog.balance_hi_eff(s) then
      ideal = s
      break
    end
  end
  check(ideal ~= nil, "some mito count lands the minimal line inside the safe band")
  check(catalog.balance_band(ideal) == catalog.BAND_IDEAL, "inside the band classes IDEAL")

  -- The ceiling is fixed, so the ONLY way out of OVER is to lower the ratio (ease off power
  -- or raise demand). A hot line stays OVER until power comes down -- there is no lever that
  -- moves the band out from under it.
  local hot = state({ mito = 20 })
  check(catalog.balance_band(hot) == catalog.BAND_OVER, "an over-powered line classes OVER")
  local eased = state({ mito = 2 })
  check(catalog.balance_band(eased) ~= catalog.BAND_OVER, "easing power pulls the line out of OVER")
end

print("all tests passed (" .. checks .. " checks)")
