-- Standalone spec for the Pillar-5 GAUGE helpers in lib/layers/complexcell/catalog.lua
-- (the biologically-named readouts the orchestrator's panel surfaces). Plain Lua 5.1, no
-- framework. Run from the repo root:
--   lua tests/complexcell_gauges_spec.lua
--
-- These pin the PURE derived math behind the gauges -- demand, balance_ratio, the
-- stabilization-raised safe ceiling, and the oxygen/respiration load -- so the renderer
-- stays logic-free and the numbers can't drift from the economy. Every expected value is
-- DERIVED from the catalog's source constants (no magic numbers), and the gauges are
-- asserted to AGREE with the fold/balance-scalar the sim itself runs on.
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
  s.stab = o.stab or 0
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
  -- ratio/oxygen divides below can never blow up.
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
-- balance_hi_eff: the safe-band ceiling, lifted by stabilization. The view classes
-- the ratio under/ideal/over against [BALANCE_LO, balance_hi_eff].
-- ---------------------------------------------------------------------------
do
  check(
    approx(catalog.balance_hi_eff(state({ stab = 0 })), catalog.BALANCE_HI),
    "balance_hi_eff = BALANCE_HI at stab 0"
  )
  check(
    approx(
      catalog.balance_hi_eff(state({ stab = 4 })),
      catalog.BALANCE_HI + 4 * catalog.STAB_TOLERANCE
    ),
    "stabilization lifts the safe ceiling by STAB_TOLERANCE per level"
  )
  -- It mirrors the fold (the same number the sim consumes), so the gauge band can never
  -- drift from the economy's actual ROS threshold.
  local s = state({ stab = 3 })
  check(
    approx(catalog.balance_hi_eff(s), catalog.fold(s).balance_hi_eff),
    "balance_hi_eff mirrors fold().balance_hi_eff"
  )
end

-- ---------------------------------------------------------------------------
-- oxygen: respiration LOAD = demand/power clamped to [0,1]. Low load = idle
-- respiratory capacity (state-4, the ROS-leak danger); ~1 = matched (state-3).
-- ---------------------------------------------------------------------------
do
  -- It is exactly the reciprocal of the balance ratio while that ratio is >= 1 (so the
  -- clamp doesn't bite): demand/power == 1 / (power/demand).
  local s = state({ mito = 4 }) -- power 40, small demand -> ratio > 1 -> load < 1, unclamped
  local ratio = catalog.balance_ratio(s)
  check(ratio > 1, "the oxygen test line really is over-powered (ratio > 1)")
  check(approx(catalog.oxygen(s), 1 / ratio), "oxygen load = demand/power = 1/balance_ratio")

  -- OVER-POWER drives respiration load DOWN (idle capacity -> the leak condition). The
  -- ROS gauge and the balance ratio confirm the same imbalance from the other side.
  local matched = catalog.oxygen(state({ mito = 1 }))
  local flooded = catalog.oxygen(state({ mito = 20 }))
  check(flooded < matched, "piling on power lowers respiration load (idle O2 capacity)")

  -- CLAMP: a deep power DEFICIT (demand >> power) would push load past 1; it clamps to 1
  -- (you can't draw more O2 than the mitochondria can ever supply -- a displayed metric).
  local deficit = state({ mito = 1, unlocked = { ribosomes = true }, stages = { ribosomes = 50 } })
  check(catalog.balance_ratio(deficit) < 1, "the deficit test line is under-powered (ratio < 1)")
  check(catalog.oxygen(deficit) == 1, "respiration load clamps to 1 in a power deficit")
  check(catalog.oxygen(deficit) >= 0 and catalog.oxygen(deficit) <= 1, "oxygen stays in [0,1]")
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

  -- Stabilization lifts the ceiling, so a line that read OVER at stab 0 can read IDEAL once
  -- enough stab is bought -- the counter-lever moving the band, surfaced by the gauge.
  local hot = state({ mito = 20, stab = 0 })
  check(catalog.balance_band(hot) == catalog.BAND_OVER, "hot line classes OVER at stab 0")
  local defended = state({ mito = 20, stab = 40 })
  check(
    catalog.balance_band(defended) ~= catalog.BAND_OVER,
    "enough stabilization lifts the same hot line out of OVER"
  )
end

print("all tests passed (" .. checks .. " checks)")
