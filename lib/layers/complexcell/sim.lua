-- Complex-cell sim: the headless heart of phase 2 and the AUTHORITATIVE economy.
-- This is the eukaryotic sequel to lib/layers/cell/sim.lua. Where phase 1 banked
-- ENERGY from intake and minted DIVISIONS, phase 2 banks ENERGY (ATP) from
-- MITOCHONDRIA and spends it running an ASSEMBLY LINE whose output mints BUILT --
-- the cumulative structure the cell has produced ("growth is detail"). Same closed
-- form, same discipline: pure, deterministic, no love.*, no rng.
--
-- The verb is BALANCING power against throughput. Output is capped by the slowest
-- unlocked stage (throughput T) and costs ATP to run, so more throughput demands
-- more mitochondria -- overreach power and the line BROWNS OUT. Every machine also
-- burns upkeep just idling, so over-leveling a non-bottleneck stage is pure loss
-- (upkeep + buy-cost, zero throughput gain) -- the phase-1 dial trap re-shaped as
-- flow balance. That energy-per-gene self-regulation is stated here as pure math.
-- (The sim still supports an explicit `waste_coef * excess` drain for a future
-- imbalance penalty, but it ships at 0 -- the upkeep carries the overbuild cost.)
--
-- The whole internal swarm (organelles, ribosomes, vesicles, motors) is a COSMETIC
-- skin over this closed form, so offline progress holds. The orchestrator/lab
-- folds levels + counts + tuning constants into a `rates` table (the analogue of
-- phase 1's `intake`); sim.step ONLY ever sees `rates` -- it knows nothing of
-- stage_rate or levels, exactly as phase-1 sim.step only saw the folded intake.
--
-- tick and offline share ONE step(state, dt, rates) so live and offline stay
-- identical and deterministic. Pure Lua 5.1.
local sim = {}

-- Offline relaxation: replay the shared step in fixed sub-steps so a long absence
-- converges instead of folding one giant dt (the energy buffer clamps, so a single
-- huge step would lose the integral). Mirrors phase-1 sim.offline.
local OFFLINE_DT = 2 -- target sub-step seconds
local OFFLINE_MAX_STEPS = 2000 -- cap the loop regardless of time away

-- A fresh complex cell: the bacterium engulfed at the phase-1 finale is the first
-- mitochondrion (mito = 1), the power plant carried across the seam. Nothing is
-- built yet, the buffer is empty, and only the orchestrator's starting stage
-- (ribosomes) will be unlocked -- but the sim itself stays agnostic about which
-- stages exist; it just carries the bookkeeping tables.
function sim.new()
  return {
    energy = 0, -- banked ATP: net power/sec banks here, spent on every upgrade
    built = 0, -- headline growth: cumulative structure produced (monotonic)
    mito = 1, -- mitochondria count; the first is the engulfed bacterium
    stages = {}, -- id -> integer level (the assembly-line stages)
    unlocked = {}, -- id -> true (which stages are online; INTEGRATED, bought with ATP)
    discovered = {}, -- id -> true (a stage whose built gate was crossed; awaits integration)
    output = 0, -- last step's assembly-line output O (swarm intensity readout)
    brownout = false, -- true when output throttled below T by a power deficit
    stress = 0, -- 0..1 oxidative stress: a SUSTAINED power/ROS extreme drives it toward lysis (the failure pressure)
    ros = 0, -- 0..1 reactive-oxygen species (Pillar 2): idle OVER-power leaks it; it cuts built and, sustained past ROS_LETHAL, feeds lethal stress
  }
end

-- The bankable SURPLUS at a folded `rates`: net ATP/sec left over when the line
-- runs fully powered. This is `avail - e*T` -- power minus upkeep minus waste minus
-- the cost of running the bottleneck. Positive surplus is what you spend on
-- upgrades; driving it negative (overbuild -> waste, or too few mitochondria) is
-- the brownout trap. Pure helper for the lab/tests; sim.step recomputes inline.
function sim.surplus(rates)
  local power = rates.power or 0
  local upkeep = rates.upkeep or 0
  local excess = rates.excess or 0
  local waste_coef = rates.waste_coef or 0
  local throughput = rates.throughput or 0
  local e = rates.e_per_output or 1
  local avail = power - upkeep - waste_coef * excess
  return avail - e * throughput
end

-- THE BALANCE SCALAR (Pillars 2 & 3), in [0,1]: the single number that drives both the
-- swarm readout AND the built-yield cut. Pure: a function of a folded `rates` table and
-- the current `ros` only, no state mutation, no rng. catalog.efficiency() is its
-- BYTE-FOR-BYTE MIRROR (it calls this), so the live readout and the economic cut can
-- never drift. Three factors:
--
--   flow_balance  = T / (T + excess)         -- pipeline match; 1 when nothing is idle.
--   power_balance = PEAK-IN-BAND over balance_ratio = power / demand
--                   (demand = e*T + upkeep): 1 inside [BALANCE_LO, BALANCE_HI_eff];
--                   a DEFICIT slope below LO (ratio/LO) and a SURPLUS slope above HI_eff
--                   (1 - severity toward ROS_RATIO_CAP). Two-sided -- over-power bites.
--   ros_drag      = 1 - ros                  -- accumulated oxidative stress bleeds it.
--
-- Returns flow_balance * power_balance * ros_drag, clamped to [0,1].
function sim.balance_scalar(rates, ros)
  local power = rates.power or 0
  local upkeep = rates.upkeep or 0
  local excess = rates.excess or 0
  local throughput = rates.throughput or 0
  local e = rates.e_per_output or 1
  local balance_lo = rates.balance_lo or 1
  local balance_hi_eff = rates.balance_hi_eff or balance_lo
  local ros_ratio_cap = rates.ros_ratio_cap or balance_hi_eff

  -- flow_balance: 1.0 on a perfectly matched pipeline; degrades with idle excess.
  local flow_balance = 0
  if throughput > 0 then
    flow_balance = throughput / (throughput + excess)
  end

  -- power_balance: the peak-in-band curve. demand = e*T + upkeep is always > 0 here
  -- (upkeep counts mito >= 1), so balance_ratio is well-defined.
  local demand = e * throughput + upkeep
  local power_balance
  if demand <= 0 then
    power_balance = 1
  else
    local ratio = power / demand
    if ratio < balance_lo then
      -- DEFICIT slope: linear from 0 (no power) up to 1 at the band floor.
      power_balance = ratio / balance_lo
    elseif ratio <= balance_hi_eff then
      -- Inside the safe band: full efficiency.
      power_balance = 1
    else
      -- SURPLUS slope: idle over-power. Severity rises from 0 at the band ceiling to 1
      -- at ROS_RATIO_CAP; power_balance falls 1 -> 0 across that span.
      local span = ros_ratio_cap - balance_hi_eff
      local severity
      if span <= 0 then
        severity = 1
      else
        severity = (ratio - balance_hi_eff) / span
      end
      if severity < 0 then
        severity = 0
      elseif severity > 1 then
        severity = 1
      end
      power_balance = 1 - severity
    end
  end

  local ros_drag = 1 - (ros or 0)
  if ros_drag < 0 then
    ros_drag = 0
  end

  local scalar = flow_balance * power_balance * ros_drag
  if scalar < 0 then
    scalar = 0
  elseif scalar > 1 then
    scalar = 1
  end
  return scalar
end

-- The SURPLUS-ROS leak severity (Pillar 2): how hard idle over-power is leaking ROS
-- right now, in [0,1]. 0 inside/below the safe band; rises from the band ceiling
-- (BALANCE_HI_eff) to full at ROS_RATIO_CAP. Pure; shared by sim.step's ROS integration
-- so the rise math is stated once.
local function ros_leak_severity(rates)
  local power = rates.power or 0
  local upkeep = rates.upkeep or 0
  local throughput = rates.throughput or 0
  local e = rates.e_per_output or 1
  local balance_hi_eff = rates.balance_hi_eff or (rates.balance_lo or 1)
  local ros_ratio_cap = rates.ros_ratio_cap or balance_hi_eff
  local demand = e * throughput + upkeep
  if demand <= 0 then
    return 0
  end
  local ratio = power / demand
  if ratio <= balance_hi_eff then
    return 0
  end
  local span = ros_ratio_cap - balance_hi_eff
  local severity
  if span <= 0 then
    severity = 1
  else
    severity = (ratio - balance_hi_eff) / span
  end
  if severity < 0 then
    return 0
  elseif severity > 1 then
    return 1
  end
  return severity
end

-- THE shared economy step, run by BOTH sim.tick and sim.offline so live and
-- offline stay identical. Folds dt of the folded `rates` into the ATP buffer and
-- the built total. The closed form (see docs/phase2/DESIGN.md):
--
--   avail = power - upkeep - waste_coef * excess   -- ATP/sec free to run the line
--   cost_full = e * T
--   fully powered (avail >= cost_full): O = T, the surplus banks
--   underpowered (avail <  cost_full): O = (avail/e)*(1-reserve)  -- THROTTLE (brownout)
--   N = avail - e*O                     -- net ATP/sec this step (> 0 in brownout)
--   energy = clamp(energy + N*dt, 0, buffer_max)
--   built += O*dt
--   output = O ; brownout = (O < T)
--
-- The ATP buffer is a pure SAVINGS account: it grows only from net ATP/sec and
-- shrinks only when the orchestrator spends it on upgrades; it is never drained to
-- prop up an over-built line.
--
-- A power deficit THROTTLES output (brownout) -- but it RESERVES a slice of power
-- (brownout_reserve) for the buffer instead of spending every last ATP on output,
-- so net energy stays POSITIVE in a brownout and the cell always banks its way back
-- (toward the mitochondrion that fixes it). This is the forgiveness guarantee: a
-- deficit dims and slows the cell but can never hard-lock it. (Earlier models that
-- ran output at exactly avail/e pinned net energy at zero -> an unrecoverable
-- death-spiral if you couldn't already afford a power plant.)
function sim.step(state, dt, rates)
  local power = rates.power or 0
  local upkeep = rates.upkeep or 0
  local excess = rates.excess or 0
  local waste_coef = rates.waste_coef or 0
  local throughput = rates.throughput or 0
  local e = rates.e_per_output or 1
  local buffer_max = rates.buffer_max or math.huge
  local reserve = rates.brownout_reserve or 0
  local stress_rise = rates.stress_rise or 0
  local stress_fall = rates.stress_fall or 0
  local ros_rise = rates.ros_rise or 0
  local ros_fall = rates.ros_fall or 0
  local ros_lethal = rates.ros_lethal or 1
  local ros_lethal_rise = rates.ros_lethal_rise or 0
  local min_eff = rates.min_eff or 1

  local avail = power - upkeep - waste_coef * excess
  local T = throughput
  local cost_full = e * T

  local O
  if avail >= cost_full then
    -- Fully powered: the line runs at the bottleneck and the surplus banks.
    O = T
  elseif avail > 0 then
    -- Underpowered: THROTTLE to what power can run, holding back `reserve` of it so
    -- the buffer still banks (a brownout is always recoverable).
    O = (avail / e) * (1 - reserve)
  else
    -- Power can't even cover upkeep+waste: the line stops; the buffer drains the
    -- shortfall until savings or upgrades restore power.
    O = 0
  end

  local N = avail - e * O
  local energy = state.energy + N * dt
  if energy < 0 then
    energy = 0
  elseif energy > buffer_max then
    energy = buffer_max
  end
  state.energy = energy

  -- THE ROS PENDULUM (Pillar 2) -- integrate FIRST so the efficiency cut below sees this
  -- step's ros. Idle OVER-power (balance_ratio past BALANCE_HI) leaks ROS up, scaled by
  -- ros_leak_severity; inside/below the band it DECAYS at ros_fall. Additive bookkeeping in
  -- [0,1], deterministic (no rng), IDENTICAL online vs offline -- only the LETHAL coupling
  -- below diverges. The soft cut (via the balance scalar) is therefore the same whether you
  -- were away or watching.
  local leak = ros_leak_severity(rates)
  local ros_rate = (leak > 0) and (ros_rise * leak) or -ros_fall
  local ros = (state.ros or 0) + ros_rate * dt
  if ros < 0 then
    ros = 0
  elseif ros > 1 then
    ros = 1
  end
  state.ros = ros

  -- built is minted at O * value_mult * efficiency_factor. value_mult is the integrated-
  -- pipeline carrot (longer line refines each unit into more structure). efficiency_factor
  -- is Pillar 3's load-bearing balance cut: a badly-balanced cell mints as little as
  -- MIN_EFF of its potential, a well-balanced one mints full value. Both multiply BUILT
  -- only -- the power cost (e*O) is UNCHANGED above, so the brownout/stress closed form is
  -- untouched and only the REWARD bends. balance_scalar uses the just-updated ros, so the
  -- soft ROS cut is baked in here and is identical online vs offline.
  local value_mult = rates.value_mult or 1
  local balance = sim.balance_scalar(rates, ros)
  local efficiency_factor = min_eff + (1 - min_eff) * balance
  state.built = state.built + O * value_mult * efficiency_factor * dt
  state.output = O
  state.brownout = (O < T - 1e-9)

  -- OXIDATIVE STRESS -- the failure pressure (phase 1's toxicity cull re-shaped for
  -- the eukaryote). A SUSTAINED power deficit poisons the cell: stress integrates
  -- toward 1 (lysis, triggered by the orchestrator at STRESS_FAIL) and decays back
  -- toward 0 the moment power is restored, so it is always RECOVERABLE -- a generous
  -- warning window, never an instant kill. Severity is how far `avail` falls short of
  -- the cost of running the line fully (0 when fully powered, ->1 as avail hits/passes
  -- 0). This is additive bookkeeping ONLY: it never touches energy/built/output, so
  -- the closed form stays intact and online == offline (deterministic, no rng).
  local severity = 0
  if avail < cost_full then
    local denom = cost_full
    if denom < 1e-9 then
      denom = 1e-9
    end
    severity = (cost_full - avail) / denom
    if severity < 0 then
      severity = 0
    elseif severity > 1 then
      severity = 1
    end
  end

  -- SURPLUS-ROS LETHAL coupling (Pillar 2) -- the SOFT-THEN-LETHAL ceiling. Only when ros
  -- is SUSTAINED past ROS_LETHAL does over-power begin feeding the SAME lethal stress the
  -- deficit half uses; scaled by how far past ROS_LETHAL we are (0 at the threshold, 1 at
  -- full ros). A generous warning window -- a few power-trims (let demand catch up to power)
  -- pull you back well before STRESS_FAIL.
  --
  -- FORGIVENESS GUARD: this term accrues LIVE ONLY. sim.tick sets rates.lethal_ros;
  -- sim.offline does NOT, so an idle/backgrounded hot cell can only DIM (the soft built
  -- cut above, which IS shared) and can never LYSE from surplus while you are away. This
  -- is the one INTENTIONAL online/offline divergence in the stress tail -- documented in
  -- docs/phase2/FAILURE.md. The deficit half keeps its existing recoverable-by-reserve
  -- guarantee in both paths.
  local lethal_ros_input = 0
  if rates.lethal_ros and ros > ros_lethal and ros_lethal < 1 then
    lethal_ros_input = (ros - ros_lethal) / (1 - ros_lethal)
    if lethal_ros_input > 1 then
      lethal_ros_input = 1
    end
  end

  -- Stress rate combines the deficit half and the (live-only) surplus-ROS half. When
  -- BOTH are quiet, stress DECAYS at stress_fall (always recoverable). When either bites,
  -- stress rises; the deficit term reuses stress_rise, the surplus term uses
  -- ros_lethal_rise so the two ceilings can be tuned independently.
  local rate
  if severity > 0 or lethal_ros_input > 0 then
    rate = stress_rise * severity + ros_lethal_rise * lethal_ros_input
  else
    rate = -stress_fall
  end
  local stress = (state.stress or 0) + rate * dt
  if stress < 0 then
    stress = 0
  elseif stress > 1 then
    stress = 1
  end
  state.stress = stress
end

-- One sim tick (the LIVE/foreground path; also runs while backgrounded as a clock
-- tick). rates is the folded table the orchestrator assembles each tick from mito +
-- stage levels + tuning constants. tick SETS rates.lethal_ros so the surplus-ROS lethal
-- coupling accrues here -- the FORGIVENESS GUARD: only the live path can lyse from a
-- sustained idle surplus; sim.offline (catch-up) never sets it, so coming back to a hot
-- cell finds it dimmed, not dead. Everything else (incl. the soft ROS built cut) is
-- identical online vs offline. Mutating the per-tick rates table is safe: fold() rebuilds
-- it every tick, so the flag never leaks across calls.
function sim.tick(state, dt, rates)
  rates.lethal_ros = true
  sim.step(state, dt, rates)
end

-- Lump-sum catch-up for time away: replay the shared step in fixed sub-steps so
-- the buffer integrates correctly across the clamp (one giant dt would overshoot
-- and lose the surplus). The sub-step count is capped, so any duration resolves in
-- bounded work. Mirrors phase-1 sim.offline.
function sim.offline(state, seconds, rates)
  if seconds <= 0 then
    return
  end
  local n = math.ceil(seconds / OFFLINE_DT)
  if n > OFFLINE_MAX_STEPS then
    n = OFFLINE_MAX_STEPS
  end
  local dt = seconds / n
  for _ = 1, n do
    sim.step(state, dt, rates)
  end
end

-- Plain-data snapshot. Persists the buffer, the headline built total, the
-- mitochondria count, and copies of the stage-level and unlocked sets (no shared
-- references, mirroring phase-1's organelle-set copy).
function sim.serialize(state)
  local stages = {}
  for id, level in pairs(state.stages) do
    stages[id] = level
  end
  local unlocked = {}
  for id in pairs(state.unlocked) do
    unlocked[id] = true
  end
  local discovered = {}
  for id in pairs(state.discovered) do
    discovered[id] = true
  end
  return {
    energy = state.energy,
    built = state.built,
    mito = state.mito,
    output = state.output,
    brownout = state.brownout,
    stress = state.stress,
    ros = state.ros,
    stages = stages,
    unlocked = unlocked,
    discovered = discovered,
  }
end

-- Rebuild from serialize() data, tolerant of missing/legacy/wrong-typed fields.
-- A fresh state supplies every default (incl. mito = 1), so a partial blob still
-- loads to a sane complex cell.
function sim.load(data)
  local state = sim.new()
  data = data or {}
  if type(data.energy) == "number" and data.energy >= 0 then
    state.energy = data.energy
  end
  if type(data.built) == "number" and data.built >= 0 then
    state.built = data.built
  end
  if type(data.mito) == "number" and data.mito >= 1 then
    state.mito = math.floor(data.mito)
  end
  if type(data.output) == "number" and data.output >= 0 then
    state.output = data.output
  end
  if data.brownout ~= nil then
    state.brownout = data.brownout and true or false
  end
  if type(data.stress) == "number" and data.stress >= 0 then
    state.stress = data.stress > 1 and 1 or data.stress
  end
  if type(data.ros) == "number" and data.ros >= 0 then
    state.ros = data.ros > 1 and 1 or data.ros
  end
  if type(data.stages) == "table" then
    for id, level in pairs(data.stages) do
      if type(level) == "number" and level >= 0 then
        state.stages[id] = math.floor(level)
      end
    end
  end
  if type(data.unlocked) == "table" then
    for id, on in pairs(data.unlocked) do
      if on then
        state.unlocked[id] = true
      end
    end
  end
  if type(data.discovered) == "table" then
    for id, on in pairs(data.discovered) do
      if on then
        state.discovered[id] = true
      end
    end
  end
  return state
end

return sim
