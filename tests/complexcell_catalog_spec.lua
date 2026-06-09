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
-- Pillar 1: STAGE_RATE is now a PER-STAGE table, not a scalar. Each stage carries a
-- distinct per-level capacity; every STAGES entry must have a rate.
check(type(catalog.STAGE_RATE) == "table", "STAGE_RATE is a per-stage table (Pillar 1)")
check(catalog.STAGE_RATE.ribosomes == 12, "ribosomes rate (high-throughput translation)")
check(catalog.STAGE_RATE.nucleus == 6, "nucleus rate")
check(catalog.STAGE_RATE.er == 4, "er rate (the classic rate-limiter)")
check(catalog.STAGE_RATE.golgi == 6, "golgi rate")
check(catalog.STAGE_RATE.transport == 8, "transport rate")
check(catalog.STAGE_RATE.membrane == 4, "membrane rate (frontier bottleneck)")
check(catalog.STAGE_BASE == 20, "STAGE_BASE")
check(approx(catalog.STAGE_GROWTH, 1.12), "STAGE_GROWTH")
check(catalog.MITO_BASE == 25, "MITO_BASE")
check(approx(catalog.MITO_GROWTH, 1.12), "MITO_GROWTH")
check(catalog.STAB_BASE == 60, "STAB_BASE")
check(approx(catalog.STAB_GROWTH, 1.18), "STAB_GROWTH")
check(catalog.FORK_AT == 180000, "FORK_AT")
-- Pillar 2/3: the ROS pendulum + balance-cut constants.
check(catalog.BALANCE_LO == 1.0, "BALANCE_LO")
check(catalog.BALANCE_HI == 1.6, "BALANCE_HI")
check(catalog.ROS_RATIO_CAP == 3.0, "ROS_RATIO_CAP")
check(catalog.ROS_LETHAL == 0.8, "ROS_LETHAL")
check(catalog.STAB_TOLERANCE == 0.15, "STAB_TOLERANCE")
check(catalog.STAB_CLEAR == 0.5, "STAB_CLEAR")
check(catalog.MIN_EFF == 0.4, "MIN_EFF")
-- Every STAGES entry has a rate (the single lookup point must never miss).
for _, id in ipairs(catalog.STAGES) do
  check(type(catalog.STAGE_RATE[id]) == "number", "STAGE_RATE has a number for " .. id)
end

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
  -- One mito, ribosomes at level 1: power = 10*1, throughput = ribosomes_rate(12)*1, no
  -- excess, upkeep = 0.25 * (mito 1 + levels 1) = 0.5. Pass-throughs carry the constants.
  local r = catalog.fold(state())
  check(approx(r.power, 10), "fold power = POWER_PER_MITO * mito * fuel")
  check(
    approx(r.throughput, catalog.STAGE_RATE.ribosomes),
    "fold throughput = stage_rate[id] * level (single stage, per-stage rate)"
  )
  check(approx(r.excess, 0), "fold excess 0 with no overbuilt stage")
  check(approx(r.upkeep, 0.5), "fold upkeep = UPKEEP_PER_MACHINE * (mito + levelsum)")
  check(approx(r.waste_coef, catalog.WASTE_COEF), "fold passes waste_coef")
  check(approx(r.e_per_output, catalog.E_PER_OUTPUT), "fold passes e_per_output")
  check(approx(r.buffer_max, catalog.BUFFER_MAX), "fold passes buffer_max")
  check(approx(r.brownout_reserve, catalog.BROWNOUT_RESERVE), "fold passes brownout_reserve")
  -- Pillar 2/3 fields: with no stab, the safe ceiling is the bare BALANCE_HI and ROS
  -- clearance is the bare 1x; the ROS constants pass through for the sim.
  check(approx(r.balance_lo, catalog.BALANCE_LO), "fold passes balance_lo")
  check(approx(r.balance_hi_eff, catalog.BALANCE_HI), "fold balance_hi_eff = BALANCE_HI at stab 0")
  check(approx(r.stab_clear, 1), "fold stab_clear = 1 at stab 0")
  check(approx(r.ros_ratio_cap, catalog.ROS_RATIO_CAP), "fold passes ros_ratio_cap")
  check(approx(r.min_eff, catalog.MIN_EFF), "fold passes min_eff")
end

do
  -- STABILIZATION folds into the safe ceiling, ROS clearance, AND the upkeep machine
  -- count. stab 3: balance_hi_eff = BALANCE_HI + 3*STAB_TOLERANCE; stab_clear = 1 +
  -- 3*STAB_CLEAR; upkeep counts mito + levelsum + stab.
  local s = state()
  s.stab = 3
  local r = catalog.fold(s)
  check(
    approx(r.balance_hi_eff, catalog.BALANCE_HI + 3 * catalog.STAB_TOLERANCE),
    "stab lifts balance_hi_eff by STAB_TOLERANCE per level"
  )
  check(
    approx(r.stab_clear, 1 + 3 * catalog.STAB_CLEAR),
    "stab speeds ros clearance by STAB_CLEAR per level"
  )
  check(
    approx(r.upkeep, catalog.UPKEEP_PER_MACHINE * (1 + 1 + 3)),
    "stab counts as a machine in upkeep (mito + levelsum + stab)"
  )
end

do
  -- Power scales with mito: 4 mitochondria -> 40 ATP/sec.
  local r = catalog.fold(state({ mito = 4 }))
  check(approx(r.power, 40), "fold power scales with mito count")
  check(approx(r.upkeep, 0.25 * (4 + 1)), "fold upkeep counts every mito + level")
end

do
  -- Throughput is the MIN over unlocked; excess is the sum above that min. Two unlocked
  -- stages (ribosomes lvl 4, nucleus lvl 1): caps = rate*level. nucleus pins the line
  -- (its cap < ribosomes' cap), ribosomes is excess above it. Derived from the per-stage
  -- rates so the check isn't a magic number. levelsum = 5 -> upkeep = 0.25*(1+5) = 1.5.
  local rib_cap = catalog.STAGE_RATE.ribosomes * 4
  local nuc_cap = catalog.STAGE_RATE.nucleus * 1
  local bottleneck = math.min(rib_cap, nuc_cap)
  local s = state({
    mito = 1,
    unlocked = { ribosomes = true, nucleus = true },
    stages = { ribosomes = 4, nucleus = 1 },
  })
  local r = catalog.fold(s)
  check(approx(r.throughput, bottleneck), "throughput = min capacity over unlocked stages")
  check(
    approx(r.excess, (rib_cap - bottleneck) + (nuc_cap - bottleneck)),
    "excess = sum above the bottleneck"
  )
  check(approx(r.upkeep, 1.5), "upkeep folds the full level sum")
end

do
  -- A LOCKED stage with a level does NOT count toward throughput/excess (only unlocked
  -- stages do), but its level STILL counts toward upkeep (levelsum sums all stages).
  -- Here only ribosomes is unlocked.
  local s = state({
    mito = 1,
    unlocked = { ribosomes = true },
    stages = { ribosomes = 2, er = 9 },
  })
  local r = catalog.fold(s)
  check(
    approx(r.throughput, catalog.STAGE_RATE.ribosomes * 2),
    "locked stage ignored for throughput"
  )
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
-- stabilization_cost: geometric in the stab count already owned (stab 0 -> base).
check(approx(catalog.stabilization_cost(0), 60), "stabilization_cost(0) = STAB_BASE")
check(approx(catalog.stabilization_cost(1), 60 * 1.18), "stabilization_cost(1) = base * growth^1")
check(
  approx(catalog.stabilization_cost(4), 60 * 1.18 ^ 4),
  "stabilization_cost(4) = base * growth^4"
)

-- ---------------------------------------------------------------------------
-- discover_gates: DISCOVER (not unlock) stages at thresholds, return new ids. The
-- discovery is step ONE of two -- it flags availability, but never unlocks or seeds
-- a level (that is unlock_stage, paid via stage_unlock_cost by the orchestrator).
-- ---------------------------------------------------------------------------
do
  -- Below the first gate: nothing discovers.
  local s = state({ built = 49 })
  local newly = catalog.discover_gates(s)
  check(#newly == 0, "discover_gates below the first gate discovers nothing")
  check(not s.discovered.nucleus, "nucleus stays undiscovered below built 50")
end

do
  -- STAIR-STEP: only the nucleus gate (50, no predecessor) discovers on built alone --
  -- even at a built far past every threshold. The er gate sits at built 1000 AND
  -- requires the nucleus INTEGRATED, so a high built can never reveal it on its own;
  -- the later beats stay walled behind their predecessor.
  local s = state({ built = 5000 })
  local newly = catalog.discover_gates(s)
  check(#newly == 1 and newly[1] == "nucleus", "only nucleus discovers on built alone")
  check(s.discovered.nucleus, "nucleus is flagged discovered")
  check(not s.discovered.er, "er stays hidden until the nucleus is INTEGRATED (prereq)")
  check(not s.unlocked.nucleus, "discovery does NOT integrate (a separate paid step)")
  check(s.stages.nucleus == nil, "discovery does NOT seed a stage level")
  check(not s.discovered.transport and not s.discovered.membrane, "later gates stay undiscovered")
  -- Idempotent at the same state: a second pass discovers nothing new.
  check(#catalog.discover_gates(s) == 0, "discover_gates is idempotent at the same state")
  check(catalog.is_discovered(s, "nucleus"), "is_discovered true for a crossed gate")
  check(not catalog.is_discovered(s, "er"), "is_discovered false for a still-walled gate")

  -- Integrate the nucleus: er's prereq is now met and built (5000) is past er's gate
  -- (1000), so the NEXT discover reveals er -- and ONLY er (golgi needs er integrated).
  catalog.unlock_stage(s, "nucleus")
  local newly2 = catalog.discover_gates(s)
  check(#newly2 == 1 and newly2[1] == "er", "integrating nucleus reveals er (and only er)")
  check(not s.discovered.golgi, "golgi stays hidden until er is integrated (the next rung)")
end

do
  -- The chain opens ONE rung at a time: even at a built past every threshold, each beat
  -- waits on its predecessor's integration. Walk it and expect exactly the next id each
  -- time -- never two at once.
  local order = { "nucleus", "er", "golgi", "transport", "membrane" }
  local s = state({ built = 999999 })
  for i = 1, #order do
    local newly = catalog.discover_gates(s)
    check(#newly == 1 and newly[1] == order[i], "rung " .. i .. " reveals only " .. order[i])
    catalog.unlock_stage(s, order[i]) -- integrate, satisfying the next gate's prereq
  end
  check(#catalog.discover_gates(s) == 0, "nothing left to discover once the chain is open")
end

-- ---------------------------------------------------------------------------
-- stage_unlock_cost: a STEEP, pipeline-ordered ATP price per stage.
-- ---------------------------------------------------------------------------
do
  check(catalog.stage_unlock_cost("nucleus") == 150, "nucleus integration cost")
  check(catalog.stage_unlock_cost("er") == 300, "er integration cost")
  check(catalog.stage_unlock_cost("golgi") == 300, "golgi integration cost")
  check(catalog.stage_unlock_cost("transport") == 800, "transport integration cost")
  check(catalog.stage_unlock_cost("membrane") == 2000, "membrane integration cost")
  -- Steep relative to the geometric stage-level cost (a real save-up commitment).
  check(
    catalog.stage_unlock_cost("nucleus") > catalog.stage_cost(0),
    "integration cost dwarfs a single stage level (it is the steep gate)"
  )
  -- Non-decreasing down the pipeline: each named beat is a bigger commitment.
  check(
    catalog.stage_unlock_cost("nucleus") <= catalog.stage_unlock_cost("er"),
    "costs rise (or hold) down the pipeline: nucleus <= er"
  )
  check(
    catalog.stage_unlock_cost("er") <= catalog.stage_unlock_cost("transport"),
    "costs rise down the pipeline: er <= transport"
  )
  check(
    catalog.stage_unlock_cost("transport") < catalog.stage_unlock_cost("membrane"),
    "membrane is the steepest integration"
  )
  -- All integration costs fit inside the ATP buffer ceiling (so they're saveable).
  for _, g in ipairs(catalog.GATES) do
    check(
      catalog.stage_unlock_cost(g.id) <= catalog.BUFFER_MAX,
      g.id .. " integration cost is inside BUFFER_MAX (saveable)"
    )
  end
end

-- ---------------------------------------------------------------------------
-- unlock_stage: only works AFTER discovery; brings the stage online SEEDED NEAR THE
-- LINE (integration_seed_level: ~INTEGRATION_SEED_FRACTION of the current throughput,
-- floored at 1) so a late unlock dips the line modestly instead of cratering it to a
-- level-1 grind; idempotent. Never touches energy (the orchestrator deducts ATP first).
-- ---------------------------------------------------------------------------
do
  -- Un-discovered: unlock is a safe no-op.
  local s = state({ built = 0 })
  check(catalog.unlock_stage(s, "nucleus") == false, "unlock_stage refuses an un-discovered stage")
  check(not s.unlocked.nucleus, "the un-discovered stage stays locked")

  -- Discovered on an EARLY line (ribosomes lvl 1, throughput = ribosomes_rate): the seed
  -- floors at 1, so the first unlock still opens at level 1 (the seed fraction of one
  -- ribosome level, divided by the nucleus rate, rounds below 1 -> floor to 1).
  s = state({ built = 50 })
  catalog.discover_gates(s)
  check(catalog.unlock_stage(s, "nucleus") == true, "unlock_stage integrates a discovered stage")
  check(s.unlocked.nucleus == true, "the integrated stage is flagged unlocked")
  check(s.stages.nucleus == 1, "on an early line the seed floors to level 1")
  -- Idempotent: a second integration is a safe no-op (no double-unlock).
  check(catalog.unlock_stage(s, "nucleus") == false, "unlock_stage is idempotent (no double-buy)")
  check(s.stages.nucleus == 1, "a repeat integration does not bump the level")

  -- An already-leveled discovered stage keeps its higher level (math.max with the seed).
  local s2 = state({ built = 50, stages = { ribosomes = 1, nucleus = 3 } })
  catalog.discover_gates(s2)
  catalog.unlock_stage(s2, "nucleus")
  check(s2.stages.nucleus == 3, "unlock_stage keeps an existing higher level (math.max)")
end

do
  -- SOFTEN THE COLLAPSE: on a BUILT-UP line, a freshly integrated stage seeds NEAR the
  -- line (a modest dip) instead of cratering to level 1. The seed is
  -- floor(INTEGRATION_SEED_FRACTION * line / nucleus_rate + 0.5); its cap = seed *
  -- nucleus_rate lands near INTEGRATION_SEED_FRACTION of the line, so the line dips
  -- modestly. Derived from the constants (no magic numbers) so it holds under re-tuning.
  local rib_level = 20
  local line = catalog.STAGE_RATE.ribosomes * rib_level
  local nuc_rate = catalog.STAGE_RATE.nucleus
  local seed = math.floor((catalog.INTEGRATION_SEED_FRACTION * line) / nuc_rate + 0.5)
  local s =
    state({ built = 50, unlocked = { ribosomes = true }, stages = { ribosomes = rib_level } })
  catalog.discover_gates(s)
  check(catalog.fold(s).throughput == line, "pre-integration line throughput is the ribosomes cap")
  catalog.unlock_stage(s, "nucleus")
  check(s.stages.nucleus == seed, "integration seeds near the line (seed-fraction / stage rate)")
  check(catalog.fold(s).throughput == seed * nuc_rate, "the line dips to the new bottleneck cap")
  check(seed * nuc_rate < line, "the new stage still opens BELOW the line (a dip, not a crater)")
  -- And the dip is MODEST: the new bottleneck holds at least ~half the line (forgiving).
  check(seed * nuc_rate >= line * 0.4, "the dip is modest (recoverable, not a crater)")
end

-- ---------------------------------------------------------------------------
-- INTEGRATION VALUE (the carrot): a discovered-but-unintegrated stage NEVER throttles
-- the line (no crippling while merely available); integrating stages instead RAISES the
-- value_mult that multiplies built per unit of throughput. value_mult applies to built
-- only, not to the power cost (e*T), so brownout/stress are unaffected.
-- ---------------------------------------------------------------------------
do
  -- One unlocked stage (ribosomes): value_mult is the neutral 1.0; a discovered-but-
  -- unintegrated stage does NOT change throughput -- the line runs at full rate.
  local rib_full = catalog.STAGE_RATE.ribosomes * 4
  local s = state({ built = 50, unlocked = { ribosomes = true }, stages = { ribosomes = 4 } })
  check(approx(catalog.fold(s).value_mult, 1), "value_mult is 1 with only ribosomes")
  check(approx(catalog.fold(s).throughput, rib_full), "full throughput (rate*level) with one stage")

  catalog.discover_gates(s) -- discovers nucleus; it is available but NOT integrated
  check(catalog.has_pending_integration(s), "the discovered stage is pending integration")
  check(
    approx(catalog.fold(s).throughput, rib_full),
    "an available-but-unintegrated stage does NOT throttle the line (no crippling)"
  )
  check(approx(catalog.fold(s).value_mult, 1), "an unintegrated stage earns no value bonus")

  check(catalog.unlock_stage(s, "nucleus"), "integrate the discovered stage")
  check(
    approx(catalog.fold(s).value_mult, 1 + catalog.VALUE_PER_STAGE),
    "integrating a second stage raises value_mult by VALUE_PER_STAGE"
  )
  -- More integrated stages -> more value. Two extra stages = 1 + 2*VALUE_PER_STAGE.
  local s3 = state({
    unlocked = { ribosomes = true, nucleus = true, er = true },
    stages = { ribosomes = 4, nucleus = 4, er = 4 },
  })
  check(
    approx(catalog.fold(s3).value_mult, 1 + 2 * catalog.VALUE_PER_STAGE),
    "value_mult scales with the count of integrated stages"
  )
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
  -- Tie at the lowest CAP breaks by STAGES order (ribosomes before nucleus). With per-stage
  -- rates the EQUAL-cap levels differ: pick levels so the caps match (rate*level equal).
  -- ribosomes rate 12 at lvl 1 == nucleus rate 6 at lvl 2 == cap 12.
  local tie = state({
    unlocked = { ribosomes = true, nucleus = true },
    stages = { ribosomes = 1, nucleus = 2 },
  })
  check(
    catalog.STAGE_RATE.ribosomes * 1 == catalog.STAGE_RATE.nucleus * 2,
    "the tie setup really has equal caps"
  )
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
  -- STAIR-STEP reveal: an explicit unmet prereq forces hidden no matter how high built.
  check(
    catalog.reveal(state({ built = 9000 }), 1000, false) == "hidden",
    "reveal is hidden while the predecessor is un-integrated"
  )
  check(
    catalog.reveal(state({ built = 1000 }), 1000, true) == "ready",
    "reveal resolves normally once the prereq is met"
  )
end

do
  -- is_gate_prereq_met: nil predecessor is always satisfied; otherwise it tracks the
  -- predecessor's UNLOCKED (integrated) flag.
  check(
    catalog.is_gate_prereq_met(state(), { requires = nil }) == true,
    "a gate with no predecessor always has its prereq met"
  )
  check(
    catalog.is_gate_prereq_met(state(), { requires = "nucleus" }) == false,
    "prereq unmet while the predecessor is still locked"
  )
  local s = state({ unlocked = { ribosomes = true, nucleus = true } })
  check(
    catalog.is_gate_prereq_met(s, { requires = "nucleus" }) == true,
    "prereq met once the predecessor is integrated"
  )
end

do
  -- next_gate points at the soonest still-undiscovered beat and carries its stair-step
  -- prereq id. With only the nucleus revealed, that is er (requires nucleus).
  local s = state({ built = 999999 })
  catalog.discover_gates(s)
  local g = catalog.next_gate(s)
  check(g and g.id == "er", "next_gate is the soonest still-locked beat (er)")
  check(g.requires == "nucleus", "next_gate carries the stair-step prereq id")
  -- next_gate walks to nil only once the WHOLE chain is discovered (each integration
  -- opens the next rung -- see the stair-step discovery walk above).
  for _, id in ipairs({ "nucleus", "er", "golgi", "transport", "membrane" }) do
    catalog.discover_gates(s)
    catalog.unlock_stage(s, id)
  end
  catalog.discover_gates(s)
  check(catalog.next_gate(s) == nil, "next_gate is nil once the full chain is discovered")
end

-- ---------------------------------------------------------------------------
-- reached_fork: built >= FORK_AT.
-- ---------------------------------------------------------------------------
check(not catalog.reached_fork(state({ built = 179999 })), "not at fork below FORK_AT")
check(catalog.reached_fork(state({ built = 180000 })), "fork reached at FORK_AT")
check(catalog.reached_fork(state({ built = 250000 })), "fork reached past FORK_AT")

-- ---------------------------------------------------------------------------
-- stage_snapshot: ordered display rows with cap / unlocked / bottleneck / congestion.
-- ---------------------------------------------------------------------------
do
  local s = state({
    mito = 1,
    unlocked = { ribosomes = true, nucleus = true },
    stages = { ribosomes = 4, nucleus = 1 },
  })
  local rib_cap = catalog.STAGE_RATE.ribosomes * 4
  local nuc_cap = catalog.STAGE_RATE.nucleus * 1
  local rows = catalog.stage_snapshot(s)
  check(#rows == #catalog.STAGES, "stage_snapshot has one row per stage, in order")
  check(rows[1].id == "ribosomes" and rows[2].id == "nucleus", "rows preserve STAGES order")
  check(rows[1].cap == rib_cap and rows[2].cap == nuc_cap, "row cap = stage_rate[id] * level")
  check(rows[1].unlocked and rows[2].unlocked, "unlocked flag set for online stages")
  check(rows[3].unlocked == false, "locked stage row reads unlocked=false")
  -- nucleus (smaller cap) is the bottleneck; ribosomes (larger cap) is above it.
  check(nuc_cap < rib_cap, "the snapshot setup really has nucleus below ribosomes")
  check(
    rows[2].is_bottleneck and not rows[1].is_bottleneck,
    "is_bottleneck marks the pinning stage"
  )
  -- congestion: ribosomes (rib_cap - nuc_cap)/max(nuc_cap,1) is well above 1 -> clamps to
  -- 1; the bottleneck reads 0.
  check(approx(rows[1].congestion, 1), "an overbuilt stage congestion clamps to 1")
  check(approx(rows[2].congestion, 0), "the bottleneck stage has 0 congestion")
  -- A modestly-overbuilt stage gives a fractional, unclamped congestion. Pick a ribosomes
  -- level whose cap sits exactly 20% above the nucleus bottleneck: cap = 1.2 * nuc_cap.
  local rib_level_mod = (1.2 * nuc_cap) / catalog.STAGE_RATE.ribosomes
  local s2 = state({
    unlocked = { ribosomes = true, nucleus = true },
    stages = { ribosomes = rib_level_mod, nucleus = 1 },
  })
  local rows2 = catalog.stage_snapshot(s2)
  check(approx(rows2[1].congestion, 0.2), "congestion is fractional below the clamp")
end

-- ---------------------------------------------------------------------------
-- END-TO-END determinism: drive the REAL sim.step with catalog.fold + a balanced
-- buyer that (a) integrates the soonest discovered stage the moment it can afford the
-- STEEP one-time cost, then (b) buys the cheaper of a mitochondrion vs. the bottleneck
-- stage. This guards the live fold (the paid two-step unlock + the integration-value
-- carrot + FORK_AT) from drifting. The full-pipeline build path FORKs in ~10 min; a wide
-- 8-13 min band catches a real fold regression without being brittle to buy cadence, and
-- the skip-the-pipeline guard below pins the carrot's intent (building beats skipping).
-- ---------------------------------------------------------------------------
do
  local s = sim.new()
  s.unlocked.ribosomes = true -- ribosomes online from t=0...
  s.stages.ribosomes = 1 -- ...at level 1, so the line produces from the start

  local dt = 0.5
  local max_t = 60 * 30 -- 30 min hard cap (FORK should land well inside)
  local t = 0
  local fork_time = nil

  -- Integrate the soonest discovered-but-unlocked stage if the buffer can afford its
  -- steep one-time cost. Mirrors a player saving up to open the next named beat; the
  -- orchestrator deducts the ATP, then calls unlock_stage. Returns true if it spent.
  local function try_integrate(st)
    for _, g in ipairs(catalog.GATES) do
      if catalog.is_discovered(st, g.id) and not st.unlocked[g.id] then
        local cost = catalog.stage_unlock_cost(g.id)
        if cost <= st.energy then
          st.energy = st.energy - cost
          catalog.unlock_stage(st, g.id)
          return true
        end
        return false -- can't yet afford the soonest beat; don't skip ahead
      end
    end
    return false
  end

  while t < max_t do
    local rates = catalog.fold(s)
    sim.step(s, dt, rates)
    t = t + dt
    catalog.discover_gates(s)
    if not fork_time and catalog.reached_fork(s) then
      fork_time = t
      break
    end
    -- The `balanced` buy (mirrors the lab's reference policy): integrate the next beat
    -- when affordable, else take the cheaper of a mitochondrion vs. the bottleneck -- BUT
    -- never buy more power while the line is already OVER the safe band (balance_ratio >
    -- balance_hi_eff), since idle over-power leaks ROS and bleeds output (Pillar 2/3).
    -- Running hot, feed the bottleneck instead (raising demand pulls the ratio back into
    -- band). This is the sensible player reading the ROS gauge -- the GOOD play under test.
    local buys = 0
    while buys < 50 do
      if try_integrate(s) then
        buys = buys + 1
      else
        local id = catalog.bottleneck_id(s)
        local mc = catalog.mito_cost(s.mito)
        local sc = id and catalog.stage_cost(s.stages[id] or 0) or math.huge
        local r = catalog.fold(s)
        local demand = r.e_per_output * r.throughput + r.upkeep
        local over_band = demand > 0 and (r.power / demand) > r.balance_hi_eff
        local mito_first = (mc <= sc) and not (over_band and id)
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
  end

  check(fork_time ~= nil, "end-to-end: the balanced buyer reaches FORK")
  check(
    fork_time >= 8 * 60 and fork_time <= 13 * 60,
    "end-to-end FORK time is ~8-13 min (paid unlock + integration-value carrot; balanced ~10.3)"
  )

  -- REGRESSION GUARD for the integration-value carrot: a player who SKIPS the pipeline
  -- (only ribosomes + mitochondria, never integrating a discovered stage) must be SLOWER
  -- than the balanced buyer -- building the cell out earns the value_mult, so it wins on
  -- merit, NOT because skipping is actively crippled. (Balanced ~10.3 min vs skip ~15.)
  local function run_skip()
    local sk = sim.new()
    sk.unlocked.ribosomes = true
    sk.stages.ribosomes = 1
    local tt = 0
    while tt < max_t do
      sim.step(sk, dt, catalog.fold(sk))
      tt = tt + dt
      catalog.discover_gates(sk) -- discovers, but the skipper never integrates
      if catalog.reached_fork(sk) then
        return tt
      end
      -- Only ever buy the cheaper of a mitochondrion vs. another ribosome level.
      local buys = 0
      while buys < 50 do
        local mc = catalog.mito_cost(sk.mito)
        local sc = catalog.stage_cost(sk.stages.ribosomes or 0)
        local cost = math.min(mc, sc)
        if cost > sk.energy then
          break
        end
        sk.energy = sk.energy - cost
        if mc <= sc then
          sk.mito = sk.mito + 1
        else
          sk.stages.ribosomes = (sk.stages.ribosomes or 0) + 1
        end
        buys = buys + 1
      end
    end
    return nil
  end
  local skip_time = run_skip()
  check(
    skip_time == nil or skip_time > fork_time,
    "skipping the pipeline is SLOWER than building it (the discovery choke has teeth)"
  )
end

-- ---------------------------------------------------------------------------
-- efficiency (Pillar 3): the PEAK-IN-BAND balance scalar in [0,1]. It is the byte-for-
-- byte mirror of sim.balance_scalar(fold(state), state.ros); it PEAKS inside the safe
-- band and falls off BOTH sides (deficit AND surplus), unlike the old one-sided clamp.
-- ---------------------------------------------------------------------------

-- Helper: build a single-ribosomes-stage state at level L with M mitochondria, so
-- throughput = ribosomes_rate*L (no excess), and we can place balance_ratio precisely.
local function single_stage(M, L)
  return state({ mito = M, unlocked = { ribosomes = true }, stages = { ribosomes = L } })
end

do
  -- IN-BAND: choose mito so balance_ratio = power/demand lands inside [BALANCE_LO,
  -- BALANCE_HI]. With ribosomes lvl 4 (cap 48), demand = 48 + 0.25*(M+4). Solve for M so
  -- the ratio sits mid-band (~1.3): scan M and assert we found an in-band one at eff == 1.
  local L = 4
  local in_band_state = nil
  for M = 1, 200 do
    local r = catalog.fold(single_stage(M, L))
    local demand = r.e_per_output * r.throughput + r.upkeep
    local ratio = r.power / demand
    if ratio >= catalog.BALANCE_LO and ratio <= catalog.BALANCE_HI then
      in_band_state = single_stage(M, L)
      break
    end
  end
  check(in_band_state ~= nil, "an in-band mito count exists for the test line")
  local eff_band = catalog.efficiency(in_band_state)
  check(approx(eff_band, 1), "efficiency PEAKS at 1.0 inside the safe band (no excess, ros 0)")

  -- DEFICIT: fewer mitochondria -> ratio below BALANCE_LO -> deficit slope < 1.
  local deficit = single_stage(1, L) -- 1 mito, demand ~49 -> ratio ~0.2
  local eff_def = catalog.efficiency(deficit)
  check(eff_def >= 0 and eff_def < 1, "a power deficit pulls efficiency below the peak")

  -- SURPLUS / OVER-POWER (the NEW two-sided behaviour): pile on mitochondria so the ratio
  -- climbs PAST BALANCE_HI -> the surplus slope drops efficiency. This is what makes
  -- over-building power visible -- the old clamp hid it entirely.
  local over = single_stage(40, L) -- power 400 vs demand ~59 -> ratio ~6.8 >> ROS_RATIO_CAP
  local eff_over = catalog.efficiency(over)
  check(eff_over >= 0 and eff_over < 1, "OVER-power pulls efficiency below the peak (two-sided)")
  check(
    approx(eff_over, 0),
    "past ROS_RATIO_CAP the power side hits 0 (massive idle over-capacity)"
  )
  check(eff_band > eff_over, "the in-band state out-mints a wildly over-powered one")

  -- EXCESS (flow imbalance): overbuild one stage far above the bottleneck -> flow_balance
  -- falls even when power is in band. ribosomes lvl 20 (cap 240) vs nucleus lvl 1 (cap 6):
  -- throughput 6, big excess. Power chosen in-band for the tiny throughput.
  local s_excess = state({
    mito = 1,
    unlocked = { ribosomes = true, nucleus = true },
    stages = { ribosomes = 20, nucleus = 1 },
  })
  local eff_excess = catalog.efficiency(s_excess)
  check(eff_excess >= 0 and eff_excess < 1, "overbuilding above the bottleneck lowers efficiency")

  -- ROS DRAG: the same state with accumulated ros mints strictly less than with ros 0.
  local s_ros_lo = single_stage(2, L)
  local s_ros_hi = single_stage(2, L)
  s_ros_hi.ros = 0.5
  check(
    catalog.efficiency(s_ros_hi) < catalog.efficiency(s_ros_lo) + 1e-12,
    "accumulated ros drags efficiency down (the soft cut)"
  )
  check(
    approx(catalog.efficiency(s_ros_hi), catalog.efficiency(s_ros_lo) * 0.5),
    "ros drag scales the scalar by exactly (1 - ros)"
  )

  -- EMPTY: no unlocked stages -> throughput 0 -> flow_balance 0 -> efficiency 0.
  local s_empty = sim.load({})
  check(catalog.efficiency(s_empty) == 0, "efficiency is 0 when throughput is 0 (no stages)")
end

-- THE MIRROR: catalog.efficiency(state) must EQUAL sim.balance_scalar(fold(state),
-- state.ros) for every state -- the live readout and the sim's built-yield cut can never
-- drift (the same discipline that keeps fold mirrored to the lab). Check across deficit,
-- in-band, surplus, overbuilt, and ros-loaded states.
do
  local cases = {
    single_stage(1, 4), -- deficit
    single_stage(5, 4), -- near/in band
    single_stage(40, 4), -- wild surplus
    state({ -- overbuilt flow imbalance
      mito = 3,
      unlocked = { ribosomes = true, nucleus = true },
      stages = { ribosomes = 20, nucleus = 1 },
    }),
  }
  -- A ros-loaded variant of each, and a stabilized variant (stab raises the ceiling).
  for i = 1, #cases do
    cases[#cases + 1] = (function()
      local c = cases[i]
      local d = sim.load(sim.serialize(c))
      d.ros = 0.37
      d.stab = 2
      return d
    end)()
  end
  for idx, c in ipairs(cases) do
    local eff = catalog.efficiency(c)
    local scalar = sim.balance_scalar(catalog.fold(c), c.ros or 0)
    check(approx(eff, scalar), "efficiency mirrors sim.balance_scalar exactly (case " .. idx .. ")")
    check(eff >= 0 and eff <= 1, "efficiency stays in [0,1] (case " .. idx .. ")")
  end
end

print("all tests passed (" .. checks .. " checks)")
