-- Complex-cell catalog: ALL of phase 2's economy bookkeeping in one pure, love-free
-- module -- the eukaryotic sibling of lib/layers/cell/traits.lua. Where the sim
-- (lib/layers/complexcell/sim.lua) is the authoritative closed-form economy that
-- only ever sees a folded `rates` table, THIS module owns everything that folds
-- INTO that table: the tuning constants, the assembly-line stages and their unlock
-- gates, the geometric costs, and the self-revealing catalog UI hints. It is the
-- live analogue of tools/phase2_lab.lua -- its fold(), stage_cost(), mito_cost(),
-- apply_gates(), and constants are intentionally byte-for-byte the SAME math the
-- lab pins, so the orchestrator's live progression reproduces the lab's tuned run
-- (FORK in ~10.3 min by the balanced play). It stays headless-testable like traits:
-- no love.*, no RNG, pure Lua 5.1.
local catalog = {}

-- ===========================================================================
-- LOCKED constants -- mirror DEFAULTS in tools/phase2_lab.lua EXACTLY (and
-- docs/PHASE_2_ECONOMY.md). These are the values the fold below collapses into the
-- `rates` table the sim consumes; changing them re-tunes the whole phase.
-- ===========================================================================
catalog.POWER_PER_MITO = 10 -- gross ATP/sec per mitochondrion
catalog.UPKEEP_PER_MACHINE = 0.25 -- per-gene idle cost (mito + every stage level)
catalog.WASTE_COEF = 0.0 -- overbuild penalty carried by idle-machine upkeep (no extra waste term)
catalog.E_PER_OUTPUT = 1.0 -- ATP cost per unit of assembly-line output
catalog.BUFFER_MAX = 5000 -- ATP savings ceiling (well above any single buy through FORK; finite)
catalog.BROWNOUT_RESERVE = 0.3 -- fraction of power held for the buffer in a deficit (visible teeth + recovery)
catalog.FUEL_FACTOR = 1.0 -- plant/animal mix; neutral 1.0 through the phase

catalog.STAGE_RATE = 5 -- per-level throughput each stage contributes
catalog.STAGE_BASE = 20 -- geometric stage-level cost base
catalog.STAGE_GROWTH = 1.12 -- gentle growth: stack MANY levels (deep catalog, numbers climb)
catalog.MITO_BASE = 25 -- geometric mitochondrion cost base
catalog.MITO_GROWTH = 1.12 -- gentle growth: power keeps pace so throughput can reach the hundreds+

-- The pipeline, in unlock order. `ribosomes` is unlocked from t=0 (output > 0
-- immediately); the rest unlock as `built` crosses their gate threshold. Each
-- carries a display label and a one-line flavor -- the science-ordered named beats:
-- Ribosomes, Nucleus, Endomembrane (ER + Golgi), Cytoskeleton (transport), Membrane.
catalog.STAGES = { "ribosomes", "nucleus", "er", "golgi", "transport", "membrane" }

-- id -> { label, flavor }. The view + panel read these for per-stage rows.
catalog.STAGE_DEFS = {
  ribosomes = {
    label = "Ribosomes",
    flavor = "translate the genome -- the line's first machines",
  },
  nucleus = {
    label = "Nucleus",
    flavor = "wall off the genome; transcription gets its own room",
  },
  er = {
    label = "Endomembrane (ER)",
    flavor = "fold and thread proteins through the reticulum",
  },
  golgi = {
    label = "Golgi",
    flavor = "sort, tag, and ship the folded cargo",
  },
  transport = {
    label = "Cytoskeleton",
    flavor = "motors haul vesicles down a built road network",
  },
  membrane = {
    label = "Membrane",
    flavor = "seal the frontier; the cell becomes a fortress",
  },
}

-- Built thresholds: each gate UNLOCKS its stage once `built` crosses `at`. The
-- science-ordered named beats; mirrors GATES in tools/phase2_lab.lua exactly.
catalog.GATES = {
  { id = "nucleus", at = 50, label = "Nucleus" },
  { id = "er", at = 200, label = "Endomembrane (ER)" },
  { id = "golgi", at = 200, label = "Golgi" },
  { id = "transport", at = 600, label = "Cytoskeleton (transport)" },
  { id = "membrane", at = 1500, label = "Membrane" },
}

catalog.FORK_AT = 50000 -- end-of-phase gate (~10-13 min smart target)

-- Per-stage throughput rate. Uniform first guess; kept as a function so a future
-- tuning pass can make a stage intrinsically faster/slower (the deferred depth
-- refinement in docs/PHASE_2_ECONOMY.md).
local function stage_rate(_id) return catalog.STAGE_RATE end

-- ===========================================================================
-- COSTS (orchestrator/catalog, not the sim). Geometric, like phase 1. Buying the
-- NEXT level of a stage costs STAGE_BASE * STAGE_GROWTH ^ current_level; the NEXT
-- mitochondrion costs MITO_BASE * MITO_GROWTH ^ (mito-1). Mirrors the lab.
-- ===========================================================================
function catalog.stage_cost(level) return catalog.STAGE_BASE * catalog.STAGE_GROWTH ^ level end

function catalog.mito_cost(mito) return catalog.MITO_BASE * catalog.MITO_GROWTH ^ (mito - 1) end

-- ===========================================================================
-- THE FOLD: state + constants -> the `rates` table sim.step consumes. This is the
-- live twin of tools/phase2_lab.lua's fold(); it MUST produce identical rates for
-- the same state so the lab's tuned numbers hold. The sim never sees levels or
-- stage_rate -- everything collapses into these scalars here.
-- ===========================================================================
function catalog.fold(state)
  local power = catalog.POWER_PER_MITO * state.mito * catalog.FUEL_FACTOR

  -- Throughput is the MIN capacity over unlocked stages; excess is everything
  -- built above that bottleneck (idle, waste-generating). An unlocked stage at
  -- level 0 contributes 0 -> it pins throughput to 0 until leveled.
  local throughput, any = nil, false
  for _, id in ipairs(catalog.STAGES) do
    if state.unlocked[id] then
      any = true
      local cap = stage_rate(id) * (state.stages[id] or 0)
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
  for _, id in ipairs(catalog.STAGES) do
    local lvl = state.stages[id] or 0
    levelsum = levelsum + lvl
    if state.unlocked[id] then
      local cap = stage_rate(id) * lvl
      local over = cap - throughput
      if over > 0 then
        excess = excess + over
      end
    end
  end

  local upkeep = catalog.UPKEEP_PER_MACHINE * (state.mito + levelsum)

  return {
    power = power,
    throughput = throughput,
    excess = excess,
    upkeep = upkeep,
    waste_coef = catalog.WASTE_COEF,
    e_per_output = catalog.E_PER_OUTPUT,
    buffer_max = catalog.BUFFER_MAX,
    brownout_reserve = catalog.BROWNOUT_RESERVE,
  }
end

-- The unlocked stage that currently PINS throughput (lowest stage_rate*level) --
-- the bottleneck the view tells the player to feed. Ties break by STAGES order.
-- Mirrors bottleneck_stage() in the lab.
function catalog.bottleneck_id(state)
  local best, bestcap = nil, nil
  for _, id in ipairs(catalog.STAGES) do
    if state.unlocked[id] then
      local cap = stage_rate(id) * (state.stages[id] or 0)
      if bestcap == nil or cap < bestcap then
        best, bestcap = id, cap
      end
    end
  end
  return best
end

-- Apply newly-crossed `built` gates: unlock any stage whose threshold built has
-- passed. A freshly unlocked stage comes online at LEVEL 1 (not 0) so it doesn't
-- pin throughput to zero the instant it opens -- it still starts as the new
-- bottleneck (cap = stage_rate*1, below the stages ahead of it), the intended
-- "each beat is a new bottleneck to build up" without a hard stall. Mirrors the
-- lab's apply_gates(), but RETURNS the ids it newly unlocked (for a toast).
function catalog.apply_gates(state)
  local newly = nil
  for _, g in ipairs(catalog.GATES) do
    if not state.unlocked[g.id] and state.built >= g.at then
      state.unlocked[g.id] = true
      state.stages[g.id] = math.max(state.stages[g.id] or 0, 1)
      newly = newly or {}
      newly[#newly + 1] = g.id
    end
  end
  return newly or {}
end

-- The next still-locked gate (the upcoming named beat), or nil once all stages are
-- unlocked. Walks GATES in order, so it returns the soonest unbuilt threshold.
function catalog.next_gate(state)
  for _, g in ipairs(catalog.GATES) do
    if not state.unlocked[g.id] then
      return { id = g.id, label = g.label, at = g.at }
    end
  end
  return nil
end

-- The self-revealing catalog (UI ONLY -- does not touch the economy). Given the
-- NEXT locked gate's `built` threshold, classify how close the cell is into a
-- reveal stage: hidden (<50%), silhouette (>=50%), named (>=75%), ready (>=100%).
-- The orchestrator passes catalog.next_gate(state).at as target_built.
function catalog.reveal(state, target_built)
  if not target_built or target_built <= 0 then
    return "hidden"
  end
  local frac = state.built / target_built
  if frac >= 1.0 then
    return "ready"
  elseif frac >= 0.75 then
    return "named"
  elseif frac >= 0.5 then
    return "silhouette"
  end
  return "hidden"
end

-- Has the cell reached the end-of-phase FORK threshold (plant/animal choice)?
function catalog.reached_fork(state) return state.built >= catalog.FORK_AT end

-- An ordered list of per-stage display rows for the view + panel. Each row carries
-- its cap (stage_rate*level), whether it's unlocked, whether it's the current
-- bottleneck, and a 0..1 CONGESTION figure -- how far the stage's capacity sits
-- ABOVE the line's throughput (built-up, backed-up machinery), normalized and
-- clamped. The bottleneck itself reads 0 congestion; stages stacked above it read
-- toward 1.
function catalog.stage_snapshot(state)
  local rates = catalog.fold(state)
  local throughput = rates.throughput
  local bottleneck = catalog.bottleneck_id(state)
  local rows = {}
  for _, id in ipairs(catalog.STAGES) do
    local def = catalog.STAGE_DEFS[id] or { label = id, flavor = "" }
    local level = state.stages[id] or 0
    local cap = stage_rate(id) * level
    local unlocked = state.unlocked[id] == true
    local congestion = 0
    if unlocked then
      local over = cap - throughput
      if over > 0 then
        congestion = over / math.max(throughput, 1)
        if congestion > 1 then
          congestion = 1
        elseif congestion < 0 then
          congestion = 0
        end
      end
    end
    rows[#rows + 1] = {
      id = id,
      label = def.label,
      flavor = def.flavor,
      level = level,
      cap = cap,
      unlocked = unlocked,
      is_bottleneck = unlocked and (id == bottleneck),
      congestion = congestion,
    }
  end
  return rows
end

return catalog
