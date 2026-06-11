-- Standalone spec for the DEATH-PRESSURE ATTRIBUTION used to name the game-over copy
-- (lib/layers/cell/pressures.lua). At extinction the orchestrator (cell.lua) asks this
-- pure module which of the three failure pressures -- toxicity WASTE, rival RIVALS,
-- PREDATORS -- dominated the colony's recent deaths, and maps the winner to copy. The
-- load-bearing logic here is (a) the per-step decomposition that splits a step's deaths
-- across the three sources (mirroring tools/sim_lab.lua survival_run / fmt_attrib) and
-- (b) the dominant-pick that selects the largest with a stable tie/degenerate guard.
-- Plain Lua 5.1, no framework, no love.*. Run from the repo root:
--   lua tests/cell_pressures_attribution_spec.lua
local root = (arg and arg[0] or ""):match("^(.*)/tests/[^/]*$") or "."
package.path = root .. "/?.lua;" .. package.path

local pressures = require("lib.layers.cell.pressures")

local checks = 0
local function check(condition, label)
  checks = checks + 1
  if not condition then
    error("FAILED: " .. label, 2)
  end
end
local function approx(a, b) return math.abs(a - b) < 1e-9 end

-- ----------------------------------------------------------------------------
-- DOMINANT pick: the single largest contribution wins; ties and the all-zero
-- degenerate case fall back to the default (so float-order never decides).
-- ----------------------------------------------------------------------------
do
  check(
    pressures.dominant(10, 1, 1) == pressures.WASTE,
    "the largest of three -> WASTE wins when waste dominates"
  )
  check(
    pressures.dominant(1, 10, 1) == pressures.RIVALS,
    "RIVALS wins when competition dominates the recent deaths"
  )
  check(
    pressures.dominant(1, 1, 10) == pressures.PREDATORS,
    "PREDATORS wins when predation dominates the recent deaths"
  )
  -- Degenerate: no deaths recorded -> the default (waste, the historical copy).
  check(pressures.dominant(0, 0, 0) == pressures.DEFAULT, "no deaths -> the default cause")
  check(pressures.DEFAULT == pressures.WASTE, "the default cause is waste (the historical copy)")
  check(pressures.dominant(nil, nil, nil) == pressures.DEFAULT, "nil contributions -> the default")
  -- Tie at the top -> the default, never an order-dependent pick.
  check(pressures.dominant(5, 5, 1) == pressures.DEFAULT, "a tie at the maximum -> the default")
  check(pressures.dominant(5, 5, 5) == pressures.DEFAULT, "a three-way tie -> the default")
  -- A strict winner just over a near-tie still resolves to that winner.
  check(
    pressures.dominant(5, 5.0001, 1) == pressures.RIVALS,
    "a strict (non-tied) maximum still wins, however narrow"
  )
end

-- ----------------------------------------------------------------------------
-- DECOMPOSITION: split one step's deaths across the three sources. Shares are
-- non-negative and SUM to the total deaths (conservation). Derived from the
-- attribution rules, not magic numbers.
-- ----------------------------------------------------------------------------
local function sums_to(total, w, r, p, label)
  check(w >= 0 and r >= 0 and p >= 0, label .. ": shares are non-negative")
  check(approx(w + r + p, total), label .. ": shares conserve the total deaths")
end

do
  -- No deaths -> all zero (and no division by zero).
  local w, r, p = pressures.attribute(0, 100, 1, { pred_cull_frac = 0.5 })
  check(w == 0 and r == 0 and p == 0, "zero deaths -> zero attribution on every source")
end

do
  -- TOXICITY-ONLY death: waste over its lethal tolerance, no predation cull, no
  -- throttles. All deaths charge to WASTE; the dominant pick is WASTE.
  local total = 20
  local w, r, p = pressures.attribute(total, 200, 1, {
    toxicity = 40,
    tox_tolerance = 26, -- waste is over tolerance -> the lethal cull is active
    pred_cull_frac = 0,
    comp_factor = 1, -- no rival throttle
    fear_factor = 1, -- no predator fear
  })
  sums_to(total, w, r, p, "toxicity-only")
  check(w == total and r == 0 and p == 0, "all deaths over tolerance with no predation -> WASTE")
  check(pressures.dominant(w, r, p) == pressures.WASTE, "a toxicity-only death attributes to WASTE")
end

do
  -- PREDATION-DOMINATED death: a heavy closed-form cull below toxicity tolerance.
  -- The direct cull (pred_cull_frac * dt * pop_before) is the predation share; any
  -- remainder splits via the throttles. Here the cull alone covers most deaths and
  -- the fear throttle is the only one biting, so PREDATORS dominates.
  local pop_before, dt = 100, 1
  local cull_frac = 0.12 -- direct cull ~= 12 of the deaths this step
  local total = 16
  local w, r, p = pressures.attribute(total, pop_before, dt, {
    toxicity = 5,
    tox_tolerance = 26, -- below tolerance -> no waste cull; remainder is starvation
    pred_cull_frac = cull_frac,
    comp_factor = 1, -- rivals not biting
    fear_factor = 0.6, -- predator fear suppresses intake -> its starvation is predation's
  })
  sums_to(total, w, r, p, "predation-dominated")
  check(w == 0, "below tolerance -> no WASTE share")
  -- Predation's share is its DIRECT cull PLUS the fear-starvation (fear the only
  -- throttle biting, so all of the non-cull starvation is predation's too).
  check(approx(p, total), "direct cull + fear-only starvation -> all deaths are predation's")
  check(r == 0, "with no rival throttle the carrying-cap starvation is not charged to RIVALS")
  check(
    pressures.dominant(w, r, p) == pressures.PREDATORS,
    "a predation-dominated death -> PREDATORS"
  )
end

do
  -- COMPETITION-DOMINATED death: below tolerance, no predation cull, rivals are the
  -- only throttle biting -> the carrying-cap starvation is all RIVALS.
  local total = 14
  local w, r, p = pressures.attribute(total, 100, 1, {
    toxicity = 8,
    tox_tolerance = 26, -- below tolerance -> starvation, not the waste cull
    pred_cull_frac = 0, -- no predation cull at all
    comp_factor = 0.5, -- rivals throttle the intake mult
    fear_factor = 1, -- no predator fear
  })
  sums_to(total, w, r, p, "competition-dominated")
  check(w == 0 and p == 0, "no waste cull and no predation -> WASTE and PREDATORS are zero")
  check(approx(r, total), "rivals as the sole throttle take all the carrying-cap starvation")
  check(pressures.dominant(w, r, p) == pressures.RIVALS, "a competition-dominated death -> RIVALS")
end

do
  -- MIXED starvation: BOTH rivals and predator-fear throttle the intake. The
  -- starvation splits in proportion to each factor's BITE (1 - factor), so the harder
  -- bite takes the larger share. comp_bite 0.4 vs fear_bite 0.2 -> rivals get 2/3.
  local total = 30
  local comp_factor, fear_factor = 0.6, 0.8 -- bites 0.4 and 0.2
  local w, r, p = pressures.attribute(total, 100, 1, {
    toxicity = 5,
    tox_tolerance = 26,
    pred_cull_frac = 0,
    comp_factor = comp_factor,
    fear_factor = fear_factor,
  })
  sums_to(total, w, r, p, "mixed-starvation")
  local comp_bite, fear_bite = 1 - comp_factor, 1 - fear_factor
  local expect_r = total * (comp_bite / (comp_bite + fear_bite))
  check(approx(r, expect_r), "starvation splits by each throttle's bite (rivals' share)")
  check(r > p, "the harder bite (rivals) takes the larger share of the starvation")
  check(pressures.dominant(w, r, p) == pressures.RIVALS, "the harder-biting throttle dominates")
end

do
  -- The direct predation cull is CLAMPED to the deaths that actually happened (it can
  -- never exceed the step's total deaths, so shares stay conserved and non-negative).
  local total = 5
  local w, r, p = pressures.attribute(total, 1000, 1, {
    toxicity = 5,
    tox_tolerance = 26,
    pred_cull_frac = 0.9, -- 0.9 * 1 * 1000 = 900, far over the 5 deaths -> clamp to 5
    comp_factor = 1,
    fear_factor = 1,
  })
  sums_to(total, w, r, p, "clamped-cull")
  check(p == total, "the direct predation cull clamps to the deaths that actually occurred")
end

print("all tests passed (" .. checks .. " checks)")
