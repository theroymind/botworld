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
--   The verb under test is BALANCING power against throughput AND keeping that balance
--   inside the safe band (the ROS pendulum, Pillar 2). The `balanced` buyer (buy the
--   cheaper of a mitochondrion vs. the bottleneck, but never overbuild power past the
--   band) clears in ~10-13 min. There are now TWO traps, one on each side of the band:
--     * `throughput!` -- chase output, never build power: sinks into deep BROWNOUT (the
--       deficit floor) and crawls.
--     * `overpower!` -- chase power, ignore demand: sails PAST the band, leaks ROS, and
--       the build-efficiency cut (Pillar 3) bleeds output -- it STAYS ALIVE but STALLS
--       (the new ceiling). The lab drives the SOFT path (sim.step, no lethal-ROS), so no
--       policy lyses here; the live-only lethal coupling is verified in the specs.
--   `maxall` is the floor that proves no path bricks. Per-stage rates (Pillar 1) make
--   reading the bottleneck a real decision; stabilization is a buyable counter-lever
--   (raise the ceiling + speed ROS clearance) -- a second valid strategy.
--
--   This file MIRRORS catalog.lua byte-for-byte (constants + fold + the shared
--   sim.balance_scalar math), so the lab's tuned numbers are the live economy's numbers.
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
  UPKEEP_PER_MACHINE = 0.25, -- per-gene idle cost (mito + every stage level + stab)
  WASTE_COEF = 0.0, -- overbuild penalty carried by idle-machine upkeep (no extra waste term)
  E_PER_OUTPUT = 1.0, -- ATP cost per unit of assembly-line output
  -- ATP savings ceiling, SCALED with `built` (see buffer_max below): the cap breathes up
  -- as the cell grows so a solved cell stops pinning at a fixed wall. Mirrors catalog.
  BUFFER_BASE = 5000, -- ATP cap at built 0 (all current unlocks fit; finite)
  BUFFER_BUILT_REF = 20000, -- built per extra BUFFER_BASE of cap (~10x ceiling by the 180k FORK)
  BROWNOUT_RESERVE = 0.3, -- fraction of power held for the buffer in a deficit (visible teeth + recovery)
  FUEL_FACTOR = 1.0, -- plant/animal mix; neutral 1.0 through the phase

  STAGE_BASE = 20, -- geometric stage-level cost base
  STAGE_GROWTH = 1.12, -- gentle growth: stack MANY levels (deep catalog, numbers climb)
  MITO_BASE = 25, -- geometric mitochondrion cost base
  MITO_GROWTH = 1.12, -- gentle growth: power keeps pace so throughput can reach the hundreds+
  STAB_BASE = 60, -- geometric stabilization cost base (a real, affordable counter-lever)
  STAB_GROWTH = 1.18, -- steeper than stages: stabilization is potent

  -- Pillar 2: the ROS pendulum (symmetric stress). Idle OVER-power leaks ROS up; inside
  -- the band it decays. Sustained past ROS_LETHAL it feeds the existing lethal stress.
  BALANCE_LO = 1.0, -- power/demand below this -> brownout (the deficit half, unchanged)
  BALANCE_HI = 1.6, -- top of the safe headroom band (a loose nod to phi as ideal reserve)
  ROS_RATIO_CAP = 3.0, -- power/demand at which the ROS leak maxes (3x needed power = full leak)
  ROS_RISE = 1 / 40, -- ~40s of MAX surplus to fill ros 0->1 (gentle; a long warning)
  ROS_FALL = 1 / 8, -- ~8s to clear ros once back inside the band (forgiving recovery)
  ROS_LETHAL = 0.8, -- ros sustained above this starts feeding the lethal stress tail
  ROS_LETHAL_RISE = 1 / 30, -- past ROS_LETHAL, how fast surplus-ros drives stress->fail
  STAB_TOLERANCE = 0.15, -- each stabilization level lifts BALANCE_HI (run hotter safely)
  STAB_CLEAR = 0.5, -- each level multiplies ros clearance speed (1 + STAB_CLEAR*stab)

  -- Pillar 3: imbalance cuts built output.
  MIN_EFF = 0.4, -- worst-case built multiplier from being off-balance

  -- Failure-pressure tuning (the deficit half; mirrors catalog STRESS_*).
  STRESS_RISE = 1 / 27, -- ~27s for a full deficit to reach the fail threshold
  STRESS_FALL = 1 / 5, -- ~5s for a full surplus to clear accumulated stress
}

-- PER-STAGE throughput (Pillar 1): a DISTINCT per-level capacity per stage, so the level
-- mix that equalises every stage's cap is the inverse of the rates -- reading/feeding the
-- slow stage is a live decision. MIRRORS catalog.STAGE_RATE exactly.
local STAGE_RATE = {
  ribosomes = 12, -- translation is high-throughput; ribosomes are numerous
  nucleus = 6, -- transcription is moderate
  er = 4, -- folding + quality-control is the classic rate-limiter
  golgi = 6, -- sorting/packaging, moderate
  transport = 8, -- motor highways move cargo fast
  membrane = 4, -- export/insertion is a frontier bottleneck
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
  { id = "er", at = 5000, requires = "nucleus", label = "Endomembrane(ER)" },
  { id = "golgi", at = 30000, requires = "er", label = "Golgi" },
  { id = "transport", at = 50000, requires = "golgi", label = "Cytoskeleton(transport)" },
  { id = "membrane", at = 105000, requires = "transport", label = "Membrane" },
}
local FORK_AT = 180000 -- end-of-phase gate (~10-min smart target; mirrors catalog.FORK_AT)
local VALUE_PER_STAGE = 0.40 -- +40% built per throughput per integrated stage past the first
local STAGE_UNLOCK_COST = { -- steep one-time integration price per beat (mirrors catalog)
  nucleus = 150,
  er = 300,
  golgi = 300,
  transport = 800,
  membrane = 2000,
}

-- Per-stage throughput rate -- THE single lookup point (Pillar 1). Mirrors catalog's
-- stage_rate: a table lookup, distinct per stage.
local function stage_rate(_C, id)
  local rate = STAGE_RATE[id]
  assert(rate, "stage_rate: no rate for stage " .. tostring(id))
  return rate
end

-- Geometric costs (orchestrator/catalog, not the sim). Buying the NEXT level of a
-- stage costs STAGE_BASE * STAGE_GROWTH ^ current_level; the NEXT mitochondrion
-- costs MITO_BASE * MITO_GROWTH ^ (mito-1); the NEXT stabilization costs
-- STAB_BASE * STAB_GROWTH ^ current_stab.
local function stage_cost(C, level) return C.STAGE_BASE * C.STAGE_GROWTH ^ level end
local function mito_cost(C, mito) return C.MITO_BASE * C.MITO_GROWTH ^ (mito - 1) end
local function stab_cost(C, stab) return C.STAB_BASE * C.STAB_GROWTH ^ stab end

-- The ATP cap at this state's `built`: a gentle linear-in-built climb off BUFFER_BASE so
-- the savings ceiling breathes up as the cell grows (mirrors catalog.buffer_max). Pure +
-- state-derived, so the buffer clamp the sim applies is identical online and offline.
local function buffer_max(C, state)
  return C.BUFFER_BASE * (1 + (state.built or 0) / C.BUFFER_BUILT_REF)
end

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

  -- stab joins mito + stage levels in the upkeep machine count (Pillar 2's counter-lever
  -- has a running cost). Mirrors catalog.fold.
  local stab = state.stab or 0
  local upkeep = C.UPKEEP_PER_MACHINE * (state.mito + levelsum + stab)

  -- Stabilization-raised safe ceiling + ROS clearance multiplier (mirrors catalog.fold).
  local balance_hi_eff = C.BALANCE_HI + C.STAB_TOLERANCE * stab
  local stab_clear = 1 + C.STAB_CLEAR * stab

  return {
    power = power,
    throughput = throughput,
    excess = excess,
    upkeep = upkeep,
    waste_coef = C.WASTE_COEF,
    e_per_output = C.E_PER_OUTPUT,
    buffer_max = buffer_max(C, state),
    brownout_reserve = C.BROWNOUT_RESERVE,
    -- NOTE: stress_rise/stress_fall are intentionally OMITTED here. The lab measures
    -- PACING + the SOFT ceilings (brownout throttle, ROS build-efficiency cut), not lysis.
    -- Lethal stress (deficit + live-only surplus-ROS) is the orchestrator's kill trigger
    -- and is verified in the specs; modeling it here would conflate "stalled" with "died".
    value_mult = value_mult,
    -- ROS pendulum + balance-scalar inputs (Pillars 2 & 3); mirror catalog.fold.
    balance_lo = C.BALANCE_LO,
    balance_hi_eff = balance_hi_eff,
    ros_ratio_cap = C.ROS_RATIO_CAP,
    ros_rise = C.ROS_RISE,
    ros_fall = C.ROS_FALL,
    stab_clear = stab_clear,
    ros_lethal = C.ROS_LETHAL,
    ros_lethal_rise = C.ROS_LETHAL_RISE,
    min_eff = C.MIN_EFF,
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

local INTEGRATION_SEED_FRACTION = 0.6 -- mirror catalog: a stage integrates near the line, not level 1

-- DISCOVER newly-crossed gates (mirror catalog.discover_gates): flag a stage available to
-- integrate once `built` crosses `at` AND its predecessor is already INTEGRATED (the
-- stair-step). Discovery does NOT unlock or seed -- that is the separate, paid integrate
-- step below, so the lab's pacing matches the live two-step economy.
local function discover_gates(state)
  for _, g in ipairs(GATES) do
    local prereq_met = g.requires == nil or state.unlocked[g.requires]
    if not state.discovered[g.id] and state.built >= g.at and prereq_met then
      state.discovered[g.id] = true
    end
  end
end

-- INTEGRATE the soonest discovered-but-unintegrated stage if the buffer can afford its
-- STEEP one-time STAGE_UNLOCK_COST. Mirrors catalog: deduct ATP, then seed the stage near
-- the line (INTEGRATION_SEED_FRACTION of the current throughput, divided by the stage's
-- OWN rate, floored at 1) so a late unlock dips the line modestly instead of cratering it.
-- Returns true if it spent (so the buyer loop can chain). Never skips ahead: if it cannot
-- afford the soonest beat, it integrates nothing.
local function try_integrate(C, state)
  for _, g in ipairs(GATES) do
    if state.discovered[g.id] and not state.unlocked[g.id] then
      local cost = STAGE_UNLOCK_COST[g.id]
      if cost <= state.energy then
        local line_throughput = fold(C, state).throughput
        local seed =
          math.floor((INTEGRATION_SEED_FRACTION * line_throughput) / stage_rate(C, g.id) + 0.5)
        if seed < 1 then
          seed = 1
        end
        state.energy = state.energy - cost
        state.unlocked[g.id] = true
        state.stages[g.id] = math.max(state.stages[g.id] or 0, seed)
        return true
      end
      return false -- can't yet afford the soonest beat; don't skip ahead
    end
  end
  return false
end

-- balance_ratio = power / demand at the current fold -- the ROS pendulum's read. Used by
-- the policies that defend a surplus (buy stabilization when running hot).
local function balance_ratio(C, state)
  local r = fold(C, state)
  local demand = r.e_per_output * r.throughput + r.upkeep
  if demand <= 0 then
    return math.huge
  end
  return r.power / demand
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
  elseif act.kind == "stab" then
    return stab_cost(C, state.stab or 0)
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
-- throughput, AND keep that balance inside the safe band (Pillar 2). The rule:
--   * If the line is OVER the band (balance_ratio > BALANCE_HI_eff), do NOT buy more
--     power. Feed the bottleneck instead -- raising demand pulls the ratio back into the
--     band (and lifts output). This is the sensible player reading the ROS gauge and
--     fixing it, never blindly stacking mitochondria.
--   * Otherwise take the cheaper of a mitochondrion vs. the bottleneck stage (the
--     classic power-vs-throughput read).
-- A simple two-price + one-gauge rule, never a spreadsheet. The primary reference policy.
local function policy_balanced(C, state, _surplus)
  local id = bottleneck_stage(C, state)
  local mc = mito_cost(C, state.mito)
  local sc = id and stage_cost(C, state.stages[id] or 0) or math.huge
  local r = fold(C, state)
  local over_band = balance_ratio(C, state) > r.balance_hi_eff
  if over_band and id then
    -- Running hot: spend on throughput to consume the surplus, not on more power.
    return { kind = "stage", id = id }
  end
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
-- lower bound that proves the phase can't be bricked. (With per-stage rates "cheapest"
-- still tracks balanced play closely, since stage costs are uniform across stages.)
local function policy_maxall(C, state, _surplus)
  local act = cheapest_action(C, state)
  return act
end

-- overpower! -- the NEW Pillar-2 TRAP: chase POWER, ignore demand. Buy a mitochondrion
-- whenever you can afford one (and feed the bottleneck only when a stage happens to be
-- cheaper), never minding the safe band. The balance_ratio sails past BALANCE_HI, ROS
-- climbs, and the build-efficiency cut bleeds output -- the cell STAYS ALIVE (the lab's
-- soft path never lyses; lethal-ROS is a live-only coupling) but STALLS. The sibling of
-- throughput!: it proves the new ceiling is load-bearing, not just the floor. A player
-- could rescue it with stabilization -- this policy deliberately does not, to expose the
-- raw penalty.
local function policy_overpower(C, state, _surplus)
  local mc = mito_cost(C, state.mito)
  local id = bottleneck_stage(C, state)
  local sc = id and stage_cost(C, state.stages[id] or 0) or math.huge
  -- Strongly prefer power: only buy a stage when it is much cheaper than a mito (so the
  -- line can exist at all), otherwise pile on mitochondria past the band.
  if mc <= sc * 3 then
    return { kind = "mito" }
  end
  return { kind = "stage", id = id }
end

-- stabilized -- the SECOND valid strategy (Pillar 2's counter-lever as a play): chase
-- power like overpower!, but DEFEND the surplus with stabilization. When the line is over
-- the band, buy a stabilization level (raising the safe ceiling + ROS clearance) instead
-- of compounding the leak; otherwise build power/throughput balanced. It should run hotter
-- than balanced yet hold ROS far below the raw overpower! trap -- proving stabilization is
-- a real lever, not a tax. Reaches FORK (not the fastest, but a legitimate alternative).
local function policy_stabilized(C, state, _surplus)
  local r = fold(C, state)
  local over_band = balance_ratio(C, state) > r.balance_hi_eff
  if over_band then
    return { kind = "stab" } -- defend the surplus rather than leak harder
  end
  -- In band: a power-leaning balanced build that stabilization protects. Lean toward
  -- power (cheaper-of, with a mild power tilt) but keep feeding the bottleneck so demand
  -- rises with power and the band-holding stays affordable.
  local mc = mito_cost(C, state.mito)
  local id = bottleneck_stage(C, state)
  local sc = id and stage_cost(C, state.stages[id] or 0) or math.huge
  if mc <= sc then
    return { kind = "mito" }
  end
  return { kind = "stage", id = id }
end

local POLICIES = {
  { name = "balanced", fn = policy_balanced },
  { name = "throughput!", fn = policy_throughput },
  { name = "overpower!", fn = policy_overpower },
  { name = "stabilized", fn = policy_stabilized },
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
  local peak_ros = 0 -- highest oxidative stress (Pillar 2 readout)
  local min_eff_seen = 1 -- lowest build-efficiency scalar seen (Pillar 3 readout)

  while t < max_t do
    local rates = fold(C, state)
    -- Drive the SHARED step WITHOUT the live lethal-ROS flag, so the lab measures the SOFT
    -- ceiling (ROS bleeds build-efficiency) the same way an OFFLINE catch-up would -- no
    -- policy can lyse here. This is deliberate: the overpower! trap must STAY ALIVE and
    -- STALL (not die), proving the soft ceiling is load-bearing. The live-only lethal
    -- coupling (sim.tick) is exercised in the specs, not here.
    sim.step(state, dt, rates)
    t = t + dt
    total_steps = total_steps + 1

    discover_gates(state)
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
    if state.ros > peak_ros then
      peak_ros = state.ros
    end
    local eff = sim.balance_scalar(rates, state.ros)
    if eff < min_eff_seen then
      min_eff_seen = eff
    end

    -- BUYING: spend banked ATP per the policy. Each iteration first tries to INTEGRATE the
    -- soonest discovered beat (the steep paid unlock), then takes the policy's marginal
    -- buy. Loop so a fat buffer can chain a few buys in one step, but cap the inner loop.
    local buys = 0
    while buys < 50 do
      if try_integrate(C, state) then
        rates = fold(C, state)
        buys = buys + 1
      else
        local surplus = sim.surplus(rates)
        local act = policy_fn(C, state, surplus)
        local cost = action_cost(C, state, act)
        if not act or cost > state.energy then
          break
        end
        state.energy = state.energy - cost
        if act.kind == "mito" then
          state.mito = state.mito + 1
        elseif act.kind == "stab" then
          state.stab = (state.stab or 0) + 1
        else
          state.stages[act.id] = (state.stages[act.id] or 0) + 1
        end
        -- Re-fold so the next buy decision and surplus see the new machine.
        rates = fold(C, state)
        buys = buys + 1
      end
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
    peak_ros = peak_ros,
    min_eff = min_eff_seen,
    final_stab = state.stab or 0,
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
  print("each row drives sim.step at dt=0.5s (soft path, no lethal-ROS); buyer spends by policy.")
  print(string.rep("-", 120))
  print(
    string.format(
      "%-12s %8s %8s %7s %7s %7s %5s %6s %8s %7s %6s",
      "policy",
      "t->Nuc",
      "t->FORK",
      "T@fork",
      "mito@fk",
      "lvl@fk",
      "stab",
      "buys",
      "brownout%",
      "peakROS",
      "minEff"
    )
  )
  print(string.rep("-", 120))
  for _, p in ipairs(POLICIES) do
    local r = run_policy(C, p.fn)
    local fs = r.fork_snapshot or { mito = 0, levels = 0, T = 0 }
    print(
      string.format(
        "%-12s %8s %8s %7.0f %7d %7d %5d %6d %7.1f%% %7.2f %6.2f",
        p.name,
        fmt_time(r.gate_times.nucleus),
        fmt_time(r.fork_time),
        fs.T,
        fs.mito,
        fs.levels,
        r.final_stab,
        r.buys_total,
        r.brownout_frac * 100,
        r.peak_ros,
        r.min_eff
      )
    )
  end
  print(string.rep("-", 120))
  print("goal: balanced FORK ~10-13 min; maxall still clears; NO policy bricks.")
  print("throughput! stalls on brownout; overpower! stalls on peakROS/minEff (the new ceiling).")
  print("")
end

-- ---------------------------------------------------------------------------
-- sweep <PARAM> <lo> <hi> <step> on the balanced policy.
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
  print(string.format("sweep of '%s' on the balanced policy", param))
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
    local names = {}
    for _, p in ipairs(POLICIES) do
      names[#names + 1] = p.name
    end
    print("available: " .. table.concat(names, ", "))
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
