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
check(catalog.FORK_AT == 180000, "FORK_AT")

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

  -- Discovered on an EARLY line (ribosomes lvl 1, throughput 5): the seed floors at 1,
  -- so the first unlock still opens at level 1 (0.6 * 5 / 5 = 0.6 -> floor to 1).
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
  -- SOFTEN THE COLLAPSE: on a BUILT-UP line, a freshly integrated stage seeds near the
  -- line (a modest dip) instead of cratering to level 1. With ribosomes lvl 20 (cap 100,
  -- throughput 100), nucleus seeds at 0.6*100/5 = 12, so the line dips 100 -> 60 (12*5),
  -- not 100 -> 5. The dip is recoverable in a few levels, never a hard re-grind.
  local s = state({ built = 50, unlocked = { ribosomes = true }, stages = { ribosomes = 20 } })
  catalog.discover_gates(s)
  check(catalog.fold(s).throughput == 100, "pre-integration line throughput is 100")
  catalog.unlock_stage(s, "nucleus")
  check(s.stages.nucleus == 12, "integration seeds near the line (0.6 * 100/5 = 12), not level 1")
  check(catalog.fold(s).throughput == 60, "the line dips modestly (100 -> 60), not to a crater")
  check(s.stages.nucleus * catalog.STAGE_RATE < 100, "the new stage still opens BELOW the line")
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
  local s = state({ built = 50, unlocked = { ribosomes = true }, stages = { ribosomes = 4 } })
  check(approx(catalog.fold(s).value_mult, 1), "value_mult is 1 with only ribosomes")
  check(approx(catalog.fold(s).throughput, 20), "full throughput (5*4) with one stage")

  catalog.discover_gates(s) -- discovers nucleus; it is available but NOT integrated
  check(catalog.has_pending_integration(s), "the discovered stage is pending integration")
  check(
    approx(catalog.fold(s).throughput, 20),
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
    -- The `balanced` buy: integrate the next beat when affordable, else take the
    -- cheaper of a mitochondrion vs. the bottleneck. Loop so a fat buffer can chain a
    -- few cheap buys in one step (capped).
    local buys = 0
    while buys < 50 do
      if try_integrate(s) then
        buys = buys + 1
      else
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
-- efficiency: pure [0,1] scalar; flow_balance * power_adequacy, ease-out quad.
-- ---------------------------------------------------------------------------
do
  -- Well-matched, well-powered: all unlocked stages equal level -> no excess;
  -- plenty of power -> flow_balance = 1, power_adequacy = 1 -> efficiency ~1.
  -- State: 3 unlocked stages each at level 4 (cap 20 each), 10 mitochondria
  -- (power = 100). demand = throughput(20)*1 + upkeep(0.25*(10+12)) = 25.5;
  -- power 100 >> demand -> power_adequacy = 1; excess = 0 -> flow_balance = 1.
  local s = state({
    mito = 10,
    unlocked = { ribosomes = true, nucleus = true, er = true },
    stages   = { ribosomes = 4, nucleus = 4, er = 4 },
  })
  local eff = catalog.efficiency(s)
  check(eff >= 0 and eff <= 1, "efficiency is in [0,1] for a balanced, well-powered state")
  check(eff > 0.9, "efficiency > 0.9 for a well-matched, well-powered state")

  -- Overbuild ribosomes far above the bottleneck: excess spikes, flow_balance falls.
  -- Same mito (10), but ribosomes level 20 (cap 100) vs nucleus/er level 1 (cap 5).
  -- throughput = 5, excess = (100-5)+(5-5) = 95 -> flow_balance = 5/100 = 0.05.
  local s_over = state({
    mito = 10,
    unlocked = { ribosomes = true, nucleus = true, er = true },
    stages   = { ribosomes = 20, nucleus = 1, er = 1 },
  })
  local eff_over = catalog.efficiency(s_over)
  check(eff_over >= 0 and eff_over <= 1, "efficiency is in [0,1] for an overbuilt state")
  check(eff_over < eff, "overbuilding one stage far above the bottleneck lowers efficiency")

  -- Power-starved: throughput demand >> available power -> power_adequacy << 1.
  -- 10 unlocked stages all at level 4, only 1 mitochondrion (power = 10).
  -- throughput = 20, demand = 20*1 + upkeep(0.25*(1+6*4 or similar)) >> 10.
  -- Use a straightforward case: ribosomes level 10 (cap 50), nucleus level 10,
  -- er level 10, all unlocked -> throughput=50, demand=50+upkeep, power=10.
  local s_starved = state({
    mito = 1,
    unlocked = { ribosomes = true, nucleus = true, er = true },
    stages   = { ribosomes = 10, nucleus = 10, er = 10 },
  })
  local eff_starved = catalog.efficiency(s_starved)
  check(eff_starved >= 0 and eff_starved <= 1, "efficiency is in [0,1] for a power-starved state")
  -- demand = 50*1 + 0.25*(1+30) = 50 + 7.75 = 57.75; power = 10 -> adequacy ~0.17
  check(eff_starved < 0.5, "efficiency is clearly low in a power-starved (brownout) state")

  -- Bounds: efficiency of a completely empty/zero state (no unlocked, mito=1).
  -- throughput = 0 -> flow_balance = 0 -> raw = 0 -> eased = 0.
  local s_empty = sim.load({})   -- fresh state: mito=1, nothing unlocked
  local eff_empty = catalog.efficiency(s_empty)
  check(eff_empty >= 0 and eff_empty <= 1, "efficiency is in [0,1] for an empty state")
  check(eff_empty == 0, "efficiency is 0 when throughput is 0 (no unlocked stages)")

  -- Bounds: a state so heavily over-powered that power_adequacy would naively > 1
  -- must still clamp to [0,1].
  local s_huge = state({
    mito = 9999,
    unlocked = { ribosomes = true },
    stages   = { ribosomes = 1 },
  })
  local eff_huge = catalog.efficiency(s_huge)
  check(eff_huge >= 0 and eff_huge <= 1, "efficiency is in [0,1] even with extreme over-power")
  check(eff_huge > 0.9, "efficiency near 1 when power is massive and line is balanced")
end

print("all tests passed (" .. checks .. " checks)")
