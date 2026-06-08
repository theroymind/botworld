-- Standalone spec for lib/layers/complexcell/catalog.lua (phase-2 economy
-- bookkeeping). Plain Lua 5.1, no framework. Run from the repo root:
--   lua tests/complexcell_catalog_spec.lua
--
-- The catalog is the live twin of tools/phase2_lab.lua: it owns the LOCKED tuning
-- constants, the geometric costs, the state -> `rates` FOLD the sim consumes, the
-- built-gated stage unlocks, and the self-revealing-catalog UI hints. These checks
-- pin the fold to the documented math (so it can't silently drift from the lab) and
-- close with an end-to-end FORK-time sanity drive against the real sim.step.
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

-- A hand-built phase-2 state. The fresh sim seeds mito = 1; the orchestrator brings
-- ribosomes online at level 1. Override per test.
local function state(o)
  o = o or {}
  local s = sim.new()
  s.mito = o.mito or 1
  s.built = o.built or 0
  s.unlocked = o.unlocked or { ribosomes = true }
  s.stages = o.stages or { ribosomes = 1 }
  return s
end

-- The LOCKED constants mirror tools/phase2_lab.lua DEFAULTS exactly.
check(catalog.POWER_PER_MITO == 10, "POWER_PER_MITO")
check(catalog.UPKEEP_PER_MACHINE == 0.25, "UPKEEP_PER_MACHINE")
check(catalog.WASTE_COEF == 0, "WASTE_COEF")
check(catalog.E_PER_OUTPUT == 1.0, "E_PER_OUTPUT")
check(catalog.BUFFER_MAX == 5000, "BUFFER_MAX")
check(catalog.BROWNOUT_RESERVE == 0.3, "BROWNOUT_RESERVE")
check(catalog.FUEL_FACTOR == 1.0, "FUEL_FACTOR")
check(catalog.STAGE_RATE == 5, "STAGE_RATE")
check(catalog.STAGE_BASE == 20, "STAGE_BASE")
check(approx(catalog.STAGE_GROWTH, 1.12), "STAGE_GROWTH")
check(catalog.MITO_BASE == 25, "MITO_BASE")
check(approx(catalog.MITO_GROWTH, 1.12), "MITO_GROWTH")
check(catalog.FORK_AT == 50000, "FORK_AT")

-- STAGES order matches the science-ordered pipeline.
do
  local want = { "ribosomes", "nucleus", "er", "golgi", "transport", "membrane" }
  for i, id in ipairs(want) do
    check(catalog.STAGES[i] == id, "STAGES order [" .. i .. "] == " .. id)
    check(catalog.STAGE_DEFS[id] ~= nil, "STAGE_DEFS has " .. id)
    check(type(catalog.STAGE_DEFS[id].label) == "string", id .. " has a label")
    check(type(catalog.STAGE_DEFS[id].flavor) == "string", id .. " has a flavor")
  end
end

-- ---------------------------------------------------------------------------
-- fold: power, throughput (min over unlocked), excess, upkeep, pass-through.
-- ---------------------------------------------------------------------------
do
  -- One mito, ribosomes at level 1: power = 10*1, throughput = 5*1, no excess,
  -- upkeep = 0.25 * (mito 1 + levels 1) = 0.5. Pass-throughs carry the constants.
  local r = catalog.fold(state())
  check(approx(r.power, 10), "fold power = POWER_PER_MITO * mito * fuel")
  check(approx(r.throughput, 5), "fold throughput = stage_rate * level (single stage)")
  check(approx(r.excess, 0), "fold excess 0 with no overbuilt stage")
  check(approx(r.upkeep, 0.5), "fold upkeep = UPKEEP_PER_MACHINE * (mito + levelsum)")
  check(approx(r.waste_coef, catalog.WASTE_COEF), "fold passes waste_coef")
  check(approx(r.e_per_output, catalog.E_PER_OUTPUT), "fold passes e_per_output")
  check(approx(r.buffer_max, catalog.BUFFER_MAX), "fold passes buffer_max")
  check(approx(r.brownout_reserve, catalog.BROWNOUT_RESERVE), "fold passes brownout_reserve")
end

do
  -- Power scales with mito: 4 mitochondria -> 40 ATP/sec.
  local r = catalog.fold(state({ mito = 4 }))
  check(approx(r.power, 40), "fold power scales with mito count")
  check(approx(r.upkeep, 0.25 * (4 + 1)), "fold upkeep counts every mito + level")
end

do
  -- Throughput is the MIN over unlocked; excess is the sum above that min. Two
  -- unlocked stages (ribosomes lvl 4, nucleus lvl 1): caps 20 and 5, throughput 5,
  -- excess = (20 - 5) = 15. levelsum = 5 -> upkeep = 0.25*(1+5) = 1.5.
  local s = state({
    mito = 1,
    unlocked = { ribosomes = true, nucleus = true },
    stages = { ribosomes = 4, nucleus = 1 },
  })
  local r = catalog.fold(s)
  check(approx(r.throughput, 5), "throughput = min capacity over unlocked stages")
  check(approx(r.excess, 15), "excess = sum of capacity above the bottleneck")
  check(approx(r.upkeep, 1.5), "upkeep folds the full level sum")
end

do
  -- A LOCKED stage with a level does NOT count toward throughput/excess (only
  -- unlocked stages do), but its level STILL counts toward upkeep (per the lab fold:
  -- levelsum sums all stages). Here only ribosomes is unlocked.
  local s = state({
    mito = 1,
    unlocked = { ribosomes = true },
    stages = { ribosomes = 2, er = 9 },
  })
  local r = catalog.fold(s)
  check(approx(r.throughput, 10), "locked stage ignored for throughput")
  check(approx(r.excess, 0), "locked stage ignored for excess")
  check(approx(r.upkeep, 0.25 * (1 + 11)), "every stage level counts toward upkeep")
end

-- ---------------------------------------------------------------------------
-- stage_cost / mito_cost: the geometric formulas.
-- ---------------------------------------------------------------------------
check(approx(catalog.stage_cost(0), 20), "stage_cost(0) = STAGE_BASE")
check(approx(catalog.stage_cost(1), 20 * 1.12), "stage_cost(1) = base * growth^1")
check(approx(catalog.stage_cost(5), 20 * 1.12 ^ 5), "stage_cost(5) = base * growth^5")
check(approx(catalog.mito_cost(1), 25), "mito_cost(1) = MITO_BASE (growth^0)")
check(approx(catalog.mito_cost(2), 25 * 1.12), "mito_cost(2) = base * growth^1")
check(approx(catalog.mito_cost(6), 25 * 1.12 ^ 5), "mito_cost(6) = base * growth^(mito-1)")

-- ---------------------------------------------------------------------------
-- apply_gates: unlock stages at thresholds, online at level 1, return new ids.
-- ---------------------------------------------------------------------------
do
  -- Below the first gate: nothing unlocks.
  local s = state({ built = 49 })
  local newly = catalog.apply_gates(s)
  check(#newly == 0, "apply_gates below the first gate unlocks nothing")
  check(not s.unlocked.nucleus, "nucleus stays locked below built 50")
end

do
  -- At built 200, three gates have passed (nucleus 50, er 200, golgi 200). Each
  -- comes online at level 1; transport (600) and membrane (1500) stay locked.
  local s = state({ built = 200 })
  local newly = catalog.apply_gates(s)
  check(#newly == 3, "apply_gates at built 200 unlocks nucleus + er + golgi")
  local got = {}
  for _, id in ipairs(newly) do
    got[id] = true
  end
  check(got.nucleus and got.er and got.golgi, "the three newly-unlocked ids are returned")
  check(
    s.unlocked.nucleus and s.unlocked.er and s.unlocked.golgi,
    "the stages are flagged unlocked"
  )
  check(
    s.stages.nucleus == 1 and s.stages.er == 1 and s.stages.golgi == 1,
    "newly unlocked stages come online at level 1"
  )
  check(not s.unlocked.transport and not s.unlocked.membrane, "later gates remain locked")
  -- A second pass unlocks nothing new (idempotent at the same built).
  check(#catalog.apply_gates(s) == 0, "apply_gates is idempotent at the same built")
end

do
  -- An already-leveled stage is brought online without losing its level.
  local s = state({ built = 50, stages = { ribosomes = 1, nucleus = 3 } })
  catalog.apply_gates(s)
  check(s.stages.nucleus == 3, "apply_gates keeps an existing level (math.max with 1)")
end

-- ---------------------------------------------------------------------------
-- bottleneck_id: the lowest-capacity unlocked stage (ties by STAGES order).
-- ---------------------------------------------------------------------------
do
  local s = state({
    unlocked = { ribosomes = true, nucleus = true, er = true },
    stages = { ribosomes = 5, nucleus = 2, er = 3 },
  })
  check(catalog.bottleneck_id(s) == "nucleus", "bottleneck is the lowest stage_rate*level")
  -- Tie at the lowest cap breaks by STAGES order (ribosomes before nucleus).
  local tie = state({
    unlocked = { ribosomes = true, nucleus = true },
    stages = { ribosomes = 2, nucleus = 2 },
  })
  check(catalog.bottleneck_id(tie) == "ribosomes", "bottleneck ties break by STAGES order")
  check(catalog.bottleneck_id(state()) == "ribosomes", "single unlocked stage is the bottleneck")
end

-- ---------------------------------------------------------------------------
-- reveal: hidden / silhouette / named / ready at the right built fractions.
-- next_gate: the soonest still-locked gate.
-- ---------------------------------------------------------------------------
do
  local g = catalog.next_gate(state())
  check(g and g.id == "nucleus" and g.at == 50, "next_gate is the soonest locked gate (nucleus 50)")
  -- Reveal against the nucleus gate (at = 50): 24 -> hidden (<50%), 25 ->
  -- silhouette (>=50%), 38 -> named (>=75%), 50 -> ready (>=100%).
  check(catalog.reveal(state({ built = 24 }), 50) == "hidden", "reveal hidden below 50%")
  check(catalog.reveal(state({ built = 25 }), 50) == "silhouette", "reveal silhouette at 50%")
  check(catalog.reveal(state({ built = 38 }), 50) == "named", "reveal named at 75%")
  check(catalog.reveal(state({ built = 50 }), 50) == "ready", "reveal ready at 100%")
  check(catalog.reveal(state({ built = 9000 }), 50) == "ready", "reveal ready well past the gate")
end

do
  -- Once every stage is unlocked, next_gate is nil.
  local s = state({ built = 99999 })
  catalog.apply_gates(s)
  check(catalog.next_gate(s) == nil, "next_gate is nil with all stages unlocked")
end

-- ---------------------------------------------------------------------------
-- reached_fork: built >= FORK_AT.
-- ---------------------------------------------------------------------------
check(not catalog.reached_fork(state({ built = 49999 })), "not at fork below FORK_AT")
check(catalog.reached_fork(state({ built = 50000 })), "fork reached at FORK_AT")
check(catalog.reached_fork(state({ built = 80000 })), "fork reached past FORK_AT")

-- ---------------------------------------------------------------------------
-- stage_snapshot: ordered display rows with cap / unlocked / bottleneck / congestion.
-- ---------------------------------------------------------------------------
do
  local s = state({
    mito = 1,
    unlocked = { ribosomes = true, nucleus = true },
    stages = { ribosomes = 4, nucleus = 1 },
  })
  local rows = catalog.stage_snapshot(s)
  check(#rows == #catalog.STAGES, "stage_snapshot has one row per stage, in order")
  check(rows[1].id == "ribosomes" and rows[2].id == "nucleus", "rows preserve STAGES order")
  check(rows[1].cap == 20 and rows[2].cap == 5, "row cap = stage_rate * level")
  check(rows[1].unlocked and rows[2].unlocked, "unlocked flag set for online stages")
  check(rows[3].unlocked == false, "locked stage row reads unlocked=false")
  -- nucleus (cap 5) is the bottleneck (throughput 5); ribosomes (cap 20) is above.
  check(
    rows[2].is_bottleneck and not rows[1].is_bottleneck,
    "is_bottleneck marks the pinning stage"
  )
  -- congestion: ribosomes (20 - 5)/max(5,1) = 3 -> clamped to 1; bottleneck = 0.
  check(approx(rows[1].congestion, 1), "an overbuilt stage congestion clamps to 1")
  check(approx(rows[2].congestion, 0), "the bottleneck stage has 0 congestion")
  -- A modestly-overbuilt stage gives a fractional, unclamped congestion: ribosomes
  -- cap 6 over throughput 5 -> (6-5)/5 = 0.2.
  local s2 = state({
    unlocked = { ribosomes = true, nucleus = true },
    stages = { ribosomes = 6 / 5, nucleus = 1 },
  })
  local rows2 = catalog.stage_snapshot(s2)
  check(approx(rows2[1].congestion, 0.2), "congestion is fractional below the clamp")
end

-- ---------------------------------------------------------------------------
-- END-TO-END determinism: drive the REAL sim.step with catalog.fold + a simple
-- buyer (the cheaper of a mitochondrion vs. the bottleneck stage), exactly as the
-- lab's `balanced` policy. This guards the live fold from drifting away from the
-- lab's tuned ~10.3-min FORK; a wide 9-13 min band catches a real regression
-- without being brittle to incidental drift.
-- ---------------------------------------------------------------------------
do
  local s = sim.new()
  s.unlocked.ribosomes = true -- ribosomes online from t=0...
  s.stages.ribosomes = 1 -- ...at level 1, so the line produces from the start

  local dt = 0.5
  local max_t = 60 * 30 -- 30 min hard cap (FORK should land well inside)
  local t = 0
  local fork_time = nil

  while t < max_t do
    local rates = catalog.fold(s)
    sim.step(s, dt, rates)
    t = t + dt
    catalog.apply_gates(s)
    if not fork_time and catalog.reached_fork(s) then
      fork_time = t
      break
    end
    -- The `balanced` buy: take the cheaper of a mitochondrion vs. the bottleneck.
    -- Loop so a fat buffer can chain a few cheap buys in one step (capped).
    local buys = 0
    while buys < 50 do
      local id = catalog.bottleneck_id(s)
      local mc = catalog.mito_cost(s.mito)
      local sc = id and catalog.stage_cost(s.stages[id] or 0) or math.huge
      local mito_first = mc <= sc
      local cost = mito_first and mc or sc
      if cost > s.energy then
        break
      end
      s.energy = s.energy - cost
      if mito_first then
        s.mito = s.mito + 1
      else
        s.stages[id] = (s.stages[id] or 0) + 1
      end
      buys = buys + 1
    end
  end

  check(fork_time ~= nil, "end-to-end: the balanced buyer reaches FORK")
  check(
    fork_time >= 9 * 60 and fork_time <= 13 * 60,
    "end-to-end FORK time is ~9-13 min (lab tuned ~10.3)"
  )
end

print("all tests passed (" .. checks .. " checks)")
