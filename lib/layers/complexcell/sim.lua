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
    stress = 0, -- 0..1 oxidative stress: a SUSTAINED power deficit drives it toward lysis (the failure pressure)
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

-- THE shared economy step, run by BOTH sim.tick and sim.offline so live and
-- offline stay identical. Folds dt of the folded `rates` into the ATP buffer and
-- the built total. The closed form (see docs/PHASE_2_ECONOMY.md):
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

  -- built is minted at O * value_mult: a longer INTEGRATED pipeline refines each unit of
  -- throughput into more structure (the carrot for building the cell out). value_mult
  -- multiplies BUILT only -- the power cost (e*O) is unchanged, so it never shifts the
  -- brownout/stress balance. Defaults to 1 (a bare ribosomes-only line).
  local value_mult = rates.value_mult or 1
  state.built = state.built + O * value_mult * dt
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
  local rate = (severity > 0) and (stress_rise * severity) or (-stress_fall)
  local stress = (state.stress or 0) + rate * dt
  if stress < 0 then
    stress = 0
  elseif stress > 1 then
    stress = 1
  end
  state.stress = stress
end

-- One sim tick (runs even while backgrounded). rates is the folded table the
-- orchestrator assembles from mito + stage levels + tuning constants.
function sim.tick(state, dt, rates) sim.step(state, dt, rates) end

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
