-- Cell death-pressure attribution: the pure, love-free decision of WHICH of the
-- three failure pressures (toxicity waste, rival competition, predation) drove the
-- colony to extinction. The orchestrator (cell.lua) accumulates a trailing read of
-- each pressure's recent contribution to the die-off -- mirroring the lab harness's
-- per-source death decomposition (tools/sim_lab.lua survival_run / fmt_attrib) -- and
-- asks this module, at the moment of extinction, which pressure dominated. The
-- WINNER selects the game-over copy (the player-facing strings live in cell.lua, the
-- view side; this module only resolves the pure id). Pure Lua 5.1, no love.*, so the
-- selection is unit-testable headless.
local pressures = {}

-- The three pressure ids. The toxicity cull (waste over tolerance), the competition
-- intake throttle (rivals crowding out your food share), and the predation cull +
-- fear-starvation. These are the dispatch keys the orchestrator maps to copy.
pressures.WASTE = "waste"
pressures.RIVALS = "rivals"
pressures.PREDATORS = "predators"

-- The default attributed pressure when nothing distinguishable drove the die-off
-- (no recorded contributions, or an exact tie). Waste is the original, ever-present
-- failure pressure -- the safe fallback that matches the historical copy.
pressures.DEFAULT = pressures.WASTE

-- Decompose ONE step's deaths into the three pressures, mirroring the lab harness's
-- per-source attribution (tools/sim_lab.lua survival_run): predation is SINGLE-SOURCED
-- through the closed-form cull, so its direct share is the evasion-mitigated cull this
-- step (pred_cull_frac * dt * pop_before, clamped to the deaths that occurred). The
-- REMAINING (non-direct-cull) deaths are charged to TOXICITY when waste is over its
-- lethal tolerance (the toxicity cull is active), else to carrying-cap STARVATION --
-- which BOTH the rival competition throttle AND the predation-fear throttle drive, so
-- that starvation is split between rivals and predators in proportion to how hard each
-- factor bit the intake mult this step (bite = 1 - factor). Charging fear-starvation to
-- predators gives predation its FULL footprint (direct cull + fear), not just the cull.
--
-- Inputs are plain numbers (no love.*, no sim state): deaths_total this step,
-- pop_before, dt, the toxicity vs its tolerance, the forwarded pred_cull_frac, and the
-- comp_factor / fear_factor the intake fold applied (each <= 1; default 1 = no bite).
-- Returns three non-negative magnitudes { waste, rivals, predators } summing to
-- deaths_total. Pure.
function pressures.attribute(deaths_total, pop_before, dt, opts)
  if not deaths_total or deaths_total <= 0 then
    return 0, 0, 0
  end
  opts = opts or {}
  local pred_cull_frac = opts.pred_cull_frac or 0
  -- Predation's DIRECT cull share this step (the closed-form cull), clamped to the
  -- deaths that actually happened. Mirrors sim.lua's pred_death_debt spend per step.
  local pred_direct = pred_cull_frac * (dt or 0) * (pop_before or 0)
  if pred_direct < 0 then
    pred_direct = 0
  end
  if pred_direct > deaths_total then
    pred_direct = deaths_total
  end
  local remaining = deaths_total - pred_direct
  local toxicity = opts.toxicity or 0
  local tolerance = opts.tox_tolerance
  if tolerance and toxicity > tolerance then
    -- Lethal toxicity cull active: the non-direct deaths are the waste cull's.
    return remaining, 0, pred_direct
  end
  -- Carrying-cap starvation: split between rivals (competition bite) and predator fear.
  local comp_bite = 1 - (opts.comp_factor or 1)
  local fear_bite = 1 - (opts.fear_factor or 1)
  if comp_bite < 0 then
    comp_bite = 0
  end
  if fear_bite < 0 then
    fear_bite = 0
  end
  local total_bite = comp_bite + fear_bite
  if total_bite > 0 then
    local fear_share = remaining * (fear_bite / total_bite)
    return 0, remaining - fear_share, pred_direct + fear_share
  end
  -- Neither throttle bit (no rivals, no fear): the starvation is rivals' by default --
  -- carrying-cap thinning with no predator pressure reads as crowding/scarcity.
  return 0, remaining, pred_direct
end

-- Pick the DOMINANT pressure from the three recent contributions (each a non-negative
-- magnitude -- e.g. the orchestrator's trailing per-source death reads). Returns the
-- id of the single largest. Degenerate guard: if all three are <= 0 (no deaths
-- recorded yet), or the top is not a STRICT winner (a tie at the maximum), fall back
-- to DEFAULT rather than letting float-order decide -- so the copy is stable and
-- never arbitrary. Pure; no state, no love.*.
function pressures.dominant(waste, rivals, predators)
  waste = waste or 0
  rivals = rivals or 0
  predators = predators or 0
  local top = math.max(waste, rivals, predators)
  if top <= 0 then
    return pressures.DEFAULT
  end
  -- Count how many sources sit at the maximum; a strict winner is exactly one.
  local at_top = 0
  if waste == top then
    at_top = at_top + 1
  end
  if rivals == top then
    at_top = at_top + 1
  end
  if predators == top then
    at_top = at_top + 1
  end
  if at_top > 1 then
    return pressures.DEFAULT -- a tie at the top: don't let order decide
  end
  if waste == top then
    return pressures.WASTE
  elseif rivals == top then
    return pressures.RIVALS
  end
  return pressures.PREDATORS
end

return pressures
