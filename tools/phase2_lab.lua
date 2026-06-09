#!/usr/bin/env lua
-- phase2_lab.lua -- headless balance harness for the complex-cell (phase 2) layer.
--
-- WHY THIS EXISTS
--   The phase-2 economy (lib/layers/complexcell/sim.lua) is a pure, deterministic
--   closed form that consumes only a folded `rates` table -- the analogue of how
--   phase-1's sim consumes `intake`. The ORCHESTRATOR folds mitochondria + stage
--   levels + tuning constants into that table. So the whole layer is testable
--   WITHOUT love2d: load the real sim, rebuild the same fold here, and drive a
--   BUYER who spends banked ATP on upgrades by a policy. We can then measure the
--   exact progression any config produces -- time-to-each-gate, final built, peak
--   output, brownout incidence -- and A/B buyer policies and tuning constants.
--
--   The verb under test is BALANCING power against throughput. The `balanced` buyer
--   (buy the cheaper of a mitochondrion vs. the bottleneck) clears in ~10-13 min;
--   the `throughput!` trap (chase output, never build power) sinks into brownout and
--   crawls -- the cautionary play the energy-per-gene tension punishes; `maxall` is
--   the floor that proves no path bricks.
--
-- USAGE
--   lua tools/phase2_lab.lua                       -- policy comparison table
--   lua tools/phase2_lab.lua sweep POWER_PER_MITO 8 14 2
--   lua tools/phase2_lab.lua sweep UPKEEP_PER_MACHINE 0.15 0.45 0.1
--   lua tools/phase2_lab.lua curve balanced [out.csv]
--
-- Pure Lua 5.1. Run from the repo root.

package.path = "./?.lua;" .. package.path

local sim = require("lib.layers.complexcell.sim")

-- ===========================================================================
-- DEFAULTS -- every economy constant lives here so tuning is trivial. These are
-- the spec's first-guess values (docs/PHASE_2_ECONOMY.md). The lab pins them.
-- ===========================================================================
local DEFAULTS = {
  POWER_PER_MITO = 10, -- gross ATP/sec per mitochondrion
  UPKEEP_PER_MACHINE = 0.25, -- per-gene idle cost (mito + every stage level)
  WASTE_COEF = 0.0, -- overbuild penalty carried by idle-machine upkeep (no extra waste term)
  E_PER_OUTPUT = 1.0, -- ATP cost per unit of assembly-line output
  BUFFER_MAX = 5000, -- ATP savings ceiling (well above any single buy through FORK; finite)
  BROWNOUT_RESERVE = 0.3, -- fraction of power held for the buffer in a deficit (visible teeth + recovery)
  FUEL_FACTOR = 1.0, -- plant/animal mix; neutral 1.0 through the phase

  STAGE_RATE = 5, -- per-level throughput each stage contributes
  STAGE_BASE = 20, -- geometric stage-level cost base
  STAGE_GROWTH = 1.12, -- gentle growth: stack MANY levels (deep catalog, numbers climb)
  MITO_BASE = 25, -- geometric mitochondrion cost base
  MITO_GROWTH = 1.12, -- gentle growth: power keeps pace so throughput can reach the hundreds+
}

-- The pipeline, in unlock order. `ribosomes` is unlocked from t=0 (output > 0
-- immediately); the rest unlock as `built` crosses their gate threshold. The
-- science-ordered named beats map onto these: Nucleus, Endomembrane (ER + Golgi),
-- Cytoskeleton (transport), Membrane/Genome, then the FORK.
local STAGES = { "ribosomes", "nucleus", "er", "golgi", "transport", "membrane" }
-- Stair-step gates -- MIRROR catalog.GATES exactly. A gate unlocks only once `built`
-- crosses `at` AND its `requires` predecessor is already unlocked, so the named beats
-- arrive one at a time with widening gaps rather than in a clump. `at` rises steeply
-- down the pipeline to space the reveals across the ~10-min climb.
local GATES = {
  { id = "nucleus", at = 50, requires = nil, label = "Nucleus" },
  { id = "er", at = 1000, requires = "nucleus", label = "Endomembrane(ER)" },
  { id = "golgi", at = 15000, requires = "er", label = "Golgi" },
  { id = "transport", at = 50000, requires = "golgi", label = "Cytoskeleton(transport)" },
  { id = "membrane", at = 105000, requires = "transport", label = "Membrane" },
}
local FORK_AT = 180000 -- end-of-phase gate (~10-min smart target; mirrors catalog.FORK_AT)
local VALUE_PER_STAGE = 0.40 -- +40% built per throughput per integrated stage past the first

-- Per-stage throughput rate. Uniform first guess; kept as a function so a future
-- tuning pass can make a stage intrinsically faster/slower per the spec.
local function stage_rate(C, _id) return C.STAGE_RATE end

-- Geometric costs (orchestrator/catalog, not the sim). Buying the NEXT level of a
-- stage costs STAGE_BASE * STAGE_GROWTH ^ current_level; the NEXT mitochondrion
-- costs MITO_BASE * MITO_GROWTH ^ (mito-1).
local function stage_cost(C, level) return C.STAGE_BASE * C.STAGE_GROWTH ^ level end
local function mito_cost(C, mito) return C.MITO_BASE * C.MITO_GROWTH ^ (mito - 1) end

-- ===========================================================================
-- THE FOLD: state + constants -> the `rates` table sim.step consumes. Mirrors how
-- sim_lab rebuilds phase-1's intake fold. The sim never sees levels or stage_rate;
-- everything collapses into these scalars here.
-- ===========================================================================
local function fold(C, state)
  local power = C.POWER_PER_MITO * state.mito * C.FUEL_FACTOR

  -- Throughput is the MIN capacity over unlocked stages; excess is everything
  -- built above that bottleneck (idle, waste-generating). An unlocked stage at
  -- level 0 contributes 0 -> it pins throughput to 0 until leveled.
  local throughput, any = nil, false
  for _, id in ipairs(STAGES) do
    if state.unlocked[id] then
      any = true
      local cap = stage_rate(C, id) * (state.stages[id] or 0)
      if throughput == nil or cap < throughput then
        throughput = cap
      end
    end
  end
  if not any then
    throughput = 0
  end
  throughput = throughput or 0

  local excess = 0
  local levelsum = 0
  local unlocked_count = 0
  for _, id in ipairs(STAGES) do
    local lvl = state.stages[id] or 0
    levelsum = levelsum + lvl
    if state.unlocked[id] then
      unlocked_count = unlocked_count + 1
      local cap = stage_rate(C, id) * lvl
      local over = cap - throughput
      if over > 0 then
        excess = excess + over
      end
    end
  end

  -- INTEGRATION VALUE (the carrot): a longer integrated pipeline mints MORE built per
  -- unit of throughput. Mirrors catalog.fold's value_mult so the lab's progression
  -- matches the live economy (built, not power, so brownout/stress are unaffected).
  local value_mult = 1 + VALUE_PER_STAGE * math.max(unlocked_count - 1, 0)

  local upkeep = C.UPKEEP_PER_MACHINE * (state.mito + levelsum)

  return {
    power = power,
    throughput = throughput,
    excess = excess,
    upkeep = upkeep,
    waste_coef = C.WASTE_COEF,
    e_per_output = C.E_PER_OUTPUT,
    buffer_max = C.BUFFER_MAX,
    brownout_reserve = C.BROWNOUT_RESERVE,
    value_mult = value_mult,
  }
end

-- The unlocked stage that currently PINS throughput (lowest stage_rate*level).
-- This is the bottleneck the smart buyer feeds. Ties break by STAGES order.
local function bottleneck_stage(C, state)
  local best, bestcap = nil, nil
  for _, id in ipairs(STAGES) do
    if state.unlocked[id] then
      local cap = stage_rate(C, id) * (state.stages[id] or 0)
      if bestcap == nil or cap < bestcap then
        best, bestcap = id, cap
      end
    end
  end
  return best
end

-- Apply newly-crossed `built` gates: unlock any stage whose threshold built has
-- passed. A freshly unlocked stage comes online at LEVEL 1 (not 0) -- per the spec,
-- so it doesn't pin throughput to zero the instant it opens. It still starts as the
-- new bottleneck (cap = stage_rate*1, below the stages ahead of it), which is the
-- intended "each beat is a new bottleneck to build up" beat -- just not a hard stall.
local INTEGRATION_SEED_FRACTION = 0.6 -- mirror catalog: a stage integrates near the line, not level 1

local function apply_gates(C, state)
  for _, g in ipairs(GATES) do
    -- Stair-step: a gate fires only once `built` crosses `at` AND its predecessor is
    -- already unlocked, so the beats chain one at a time. (The live layer splits this
    -- into a discover step + a paid integrate step; the lab auto-unlocks to keep the
    -- buyer policies simple, but the SAME prereq+threshold gate governs the order.)
    local prereq_met = g.requires == nil or state.unlocked[g.requires]
    if not state.unlocked[g.id] and state.built >= g.at and prereq_met then
      -- Seed near the line (mirror catalog.unlock_stage): the new stage opens as a
      -- modest dip the player tops up, not a level-1 crater that re-grinds every level.
      local line_throughput = fold(C, state).throughput
      local seed = math.floor((INTEGRATION_SEED_FRACTION * line_throughput) / C.STAGE_RATE + 0.5)
      if seed < 1 then
        seed = 1
      end
      state.unlocked[g.id] = true
      state.stages[g.id] = math.max(state.stages[g.id] or 0, seed)
    end
  end
end

-- ===========================================================================
-- BUYER POLICIES. Each takes (C, state, surplus) and returns a buy ACTION:
--   { kind = "mito" }            -- buy one mitochondrion
--   { kind = "stage", id = ... } -- buy the next level of stage `id`
--   nil                          -- buy nothing this step
-- The driver checks affordability and applies it. Cost lookup is shared.
-- ===========================================================================
local function action_cost(C, state, act)
  if not act then
    return math.huge
  end
  if act.kind == "mito" then
    return mito_cost(C, state.mito)
  else
    return stage_cost(C, state.stages[act.id] or 0)
  end
end

-- Cheapest affordable action across all unlocked stages + mito (used by maxall and
-- as a fallback). Returns (action, cost) or (nil, huge).
local function cheapest_action(C, state)
  local best, bestcost = nil, math.huge
  local mc = mito_cost(C, state.mito)
  if mc < bestcost then
    best, bestcost = { kind = "mito" }, mc
  end
  for _, id in ipairs(STAGES) do
    if state.unlocked[id] then
      local c = stage_cost(C, state.stages[id] or 0)
      if c < bestcost then
        best, bestcost = { kind = "stage", id = id }, c
      end
    end
  end
  return best, bestcost
end

-- balanced -- GOOD PLAY, and the verb the phase teaches: balance power against
-- throughput. Each buy, take the cheaper of a mitochondrion vs. the current
-- bottleneck stage. Buying the bottleneck lifts output (and keeps the line even);
-- buying power when it's the better marginal value keeps output funded. This simple
-- cost-balanced rule is robust and near-optimal here -- a sensible player reading the
-- two prices, never opening a spreadsheet. The primary reference policy.
local function policy_balanced(C, state, _surplus)
  local id = bottleneck_stage(C, state)
  local mc = mito_cost(C, state.mito)
  local sc = id and stage_cost(C, state.stages[id] or 0) or math.huge
  if mc <= sc then
    return { kind = "mito" }
  end
  return { kind = "stage", id = id }
end

-- throughput-only -- the TRAP. Chase the visible output number: only ever feed the
-- bottleneck stage, never build power. Tempting (the swarm grows!) but it ignores
-- the energy-per-gene tension -- power stays at the starting mitochondrion while the
-- line's demand climbs, so it sinks into a deep, lasting BROWNOUT and crawls. The
-- cautionary play the brownout readout is meant to warn against; it does NOT brick
-- (the reserve keeps a trickle of progress), it's just badly slow.
local function policy_throughput(C, state, _surplus)
  local id = bottleneck_stage(C, state)
  if id then
    return { kind = "stage", id = id }
  end
  return { kind = "mito" }
end

-- maxall -- the pathological FLOOR: buy whatever costs the least right now. The
-- lower bound that proves the phase can't be bricked. (In this uniform-stage
-- economy "cheapest" happens to track the balanced play closely.)
local function policy_maxall(C, state, _surplus)
  local act = cheapest_action(C, state)
  return act
end

local POLICIES = {
  { name = "balanced", fn = policy_balanced },
  { name = "throughput!", fn = policy_throughput },
  { name = "maxall(floor)", fn = policy_maxall },
}

-- ===========================================================================
-- THE BUYER SIMULATOR. Steps the REAL sim at dt = 0.5s. Each step: fold -> step ->
-- apply gates -> let the policy spend banked ATP (possibly several buys if the
-- buffer affords a chain). Records time-to-each-gate, time-to-FORK, final built,
-- peak output, and the fraction of steps spent in brownout.
-- ===========================================================================
local function run_policy(C, policy_fn, opts)
  opts = opts or {}
  local dt = opts.dt or 0.5
  local max_t = opts.max_t or 60 * 90 -- 90 min hard cap
  local report_at = opts.report_at or 30 * 60 -- built snapshot time (default 30 min)

  local state = sim.new()
  state.unlocked.ribosomes = true -- ribosomes online from t=0...
  state.stages.ribosomes = 1 -- ...at level 1, so the line produces from the start

  local t = 0
  local peak_output = 0
  local brownout_steps, total_steps = 0, 0
  local gate_times = {} -- gate id -> seconds
  local fork_time = nil
  local report_built = nil
  local buys_total = 0 -- purchases made (catalog-depth readout)
  local fork_snapshot = nil -- {mito, levels, T} captured the step FORK is reached
  local curve = opts.curve and {} or nil

  while t < max_t do
    local rates = fold(C, state)
    sim.step(state, dt, rates)
    t = t + dt
    total_steps = total_steps + 1

    apply_gates(C, state)
    for _, g in ipairs(GATES) do
      if state.unlocked[g.id] and not gate_times[g.id] then
        gate_times[g.id] = t
      end
    end
    if not fork_time and state.built >= FORK_AT then
      fork_time = t
      local levels = 0
      for _, id in ipairs(STAGES) do
        levels = levels + (state.stages[id] or 0)
      end
      fork_snapshot = { mito = state.mito, levels = levels, T = rates.throughput }
    end

    if state.output > peak_output then
      peak_output = state.output
    end
    if state.brownout then
      brownout_steps = brownout_steps + 1
    end

    -- BUYING: spend banked ATP per the policy. Loop so a fat buffer can chain a
    -- few cheap buys in one step, but cap to avoid a runaway inner loop.
    local buys = 0
    while buys < 50 do
      local surplus = sim.surplus(rates)
      local act = policy_fn(C, state, surplus)
      local cost = action_cost(C, state, act)
      if not act or cost > state.energy then
        break
      end
      state.energy = state.energy - cost
      if act.kind == "mito" then
        state.mito = state.mito + 1
      else
        state.stages[act.id] = (state.stages[act.id] or 0) + 1
      end
      -- Re-fold so the next buy decision and surplus see the new machine.
      rates = fold(C, state)
      buys = buys + 1
    end
    buys_total = buys_total + buys

    if curve and (t % 5 < dt) then
      curve[#curve + 1] = {
        t = t,
        energy = state.energy,
        built = state.built,
        output = state.output,
        throughput = rates.throughput,
      }
    end

    if not report_built and t >= report_at then
      report_built = state.built
    end

    -- Early out once the FORK is reached AND we've taken the report snapshot.
    if fork_time and report_built then
      break
    end
  end

  report_built = report_built or state.built

  return {
    gate_times = gate_times,
    fork_time = fork_time,
    final_built = report_built,
    peak_output = peak_output,
    brownout_frac = total_steps > 0 and (brownout_steps / total_steps) or 0,
    buys_total = buys_total,
    fork_snapshot = fork_snapshot,
    curve = curve,
  }
end

-- ===========================================================================
-- Formatting.
-- ===========================================================================
local function fmt_time(s)
  if not s then
    return "   --  "
  end
  if s < 90 then
    return string.format("%6.0fs", s)
  elseif s < 5400 then
    return string.format("%6.1fm", s / 60)
  else
    return string.format("%6.1fh", s / 3600)
  end
end

local function copy_defaults()
  local C = {}
  for k, v in pairs(DEFAULTS) do
    C[k] = v
  end
  return C
end

-- ---------------------------------------------------------------------------
-- Default mode: one row per policy.
-- ---------------------------------------------------------------------------
local function comparison_table()
  local C = copy_defaults()
  print("")
  print("phase-2 balance lab -- buyer policies vs. the real complexcell economy")
  print("each row drives sim.step at dt=0.5s; the buyer spends banked ATP by policy.")
  print(string.rep("-", 108))
  print(
    string.format(
      "%-12s %8s %8s %8s %8s %8s %7s %9s",
      "policy",
      "t->Nuc",
      "t->FORK",
      "T@fork",
      "mito@fk",
      "lvl@fk",
      "buys",
      "brownout%"
    )
  )
  print(string.rep("-", 108))
  for _, p in ipairs(POLICIES) do
    local r = run_policy(C, p.fn)
    local fs = r.fork_snapshot or { mito = 0, levels = 0, T = 0 }
    print(
      string.format(
        "%-12s %8s %8s %8.0f %8d %8d %7d %8.1f%%",
        p.name,
        fmt_time(r.gate_times.nucleus),
        fmt_time(r.fork_time),
        fs.T,
        fs.mito,
        fs.levels,
        r.buys_total,
        r.brownout_frac * 100
      )
    )
  end
  print(string.rep("-", 108))
  print("goal: bottleneck FORK ~10-15 min; maxall still clears (~1.5-2.5x), moderate brownout;")
  print("deep catalog (many buys); throughput climbs into the hundreds+ by FORK.")
  print("")
end

-- ---------------------------------------------------------------------------
-- sweep <PARAM> <lo> <hi> <step> on the bottleneck policy.
-- ---------------------------------------------------------------------------
local function sweep(param, lo, hi, step)
  lo, hi, step = tonumber(lo), tonumber(hi), tonumber(step) or 1
  if DEFAULTS[param] == nil then
    print("unknown DEFAULTS param: " .. tostring(param))
    print("available:")
    for k in pairs(DEFAULTS) do
      print("  " .. k)
    end
    return
  end
  print("")
  print(string.format("sweep of '%s' on the bottleneck policy", param))
  print(string.rep("-", 56))
  print(string.format("%14s %10s %12s %10s", param, "t->FORK", "built@30m", "peakO"))
  print(string.rep("-", 56))
  for v = lo, hi, step do
    local C = copy_defaults()
    C[param] = v
    local r = run_policy(C, policy_balanced)
    print(
      string.format(
        "%14.3f %10s %12.0f %10.1f",
        v,
        fmt_time(r.fork_time),
        r.final_built,
        r.peak_output
      )
    )
  end
  print(string.rep("-", 56))
  print("")
end

-- ---------------------------------------------------------------------------
-- curve <policy> [out.csv]: t,energy,built,output,throughput per 5s.
-- ---------------------------------------------------------------------------
local function curve(name, out)
  local fn
  for _, p in ipairs(POLICIES) do
    if p.name == name then
      fn = p.fn
    end
  end
  if not fn then
    print("unknown policy: " .. tostring(name))
    print("available: bottleneck, maxall, mitoheavy")
    return
  end
  local C = copy_defaults()
  local r = run_policy(C, fn, { curve = true })
  local lines = { "t_seconds,energy,built,output,throughput" }
  for _, p in ipairs(r.curve) do
    lines[#lines + 1] =
      string.format("%.1f,%.2f,%.2f,%.3f,%.3f", p.t, p.energy, p.built, p.output, p.throughput)
  end
  local body = table.concat(lines, "\n") .. "\n"
  if out then
    local f = assert(io.open(out, "w"))
    f:write(body)
    f:close()
    print(
      string.format("wrote %d samples to %s (FORK at %s)", #r.curve, out, fmt_time(r.fork_time))
    )
  else
    io.write(body)
  end
end

-- ---------------------------------------------------------------------------
-- Entry.
-- ---------------------------------------------------------------------------
local mode = arg[1]
if mode == "sweep" then
  sweep(arg[2], arg[3], arg[4], arg[5])
elseif mode == "curve" then
  curve(arg[2], arg[3])
else
  comparison_table()
end
