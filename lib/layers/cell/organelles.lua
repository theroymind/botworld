-- Endosymbiosis: the cell layer's rare, permanent progression -- the engulf/keep
-- event that replaces the old evolve/prestige loop. A fully engulfed prey microbe
-- may, rarely, be KEPT rather than digested, becoming a permanent organelle that
-- reshapes the economy. This module is a dedicated, PURE concern (the composition
-- pillar, like fx): it owns the organelle DEFS and the FOLD helpers the
-- orchestrator mixes into the sim's intake; it knows nothing of love.*, the sim,
-- or the world. The acquired SET lives in sim state (persisted); the defs and
-- their boons live here. Pure Lua 5.1.
--
-- Two organelles, in order, each drawn from the real evidence for endosymbiosis
-- (its own DNA, a double membrane, division by binary fission):
--   * mitochondrion -- a captured aerobic bacterium; a big permanent ENERGY
--     multiplier (the eukaryote "energy revolution"). The first keep.
--   * chloroplast   -- a captured cyanobacterium; adds passive LIGHT income.
--     Gated behind already holding the mitochondrion (plastids are a later,
--     secondary endosymbiosis).
local organelles = {}

local DEFS = {
  {
    id = "mitochondrion",
    order = 1,
    label = "Mitochondrion",
    boon = "energy intake x2",
    lore = "A free-living bacterium, engulfed and kept -- it brought its own DNA, a "
      .. "double membrane, and divides by binary fission. The eukaryote energy revolution.",
    intake_mult = 1.0, -- +1.0 -> doubles the folded intake multiplier
    photo_bonus = 0,
    gate_div = 350, -- lifetime divisions before this may be kept
  },
  {
    id = "chloroplast",
    order = 2,
    label = "Chloroplast",
    boon = "light income +40",
    lore = "A captured cyanobacterium, still ringed by a double membrane and carrying "
      .. "its own genome -- light becomes biomass without the hunting.",
    intake_mult = 0,
    photo_bonus = 40, -- flat light income added to the intake's photo term
    gate_div = 1000,
    needs = "mitochondrion", -- a later, secondary endosymbiosis
  },
}

local BY_ID = {}
for _, def in ipairs(DEFS) do
  BY_ID[def.id] = def
end

-- The ordered organelle defs; treat as read-only.
function organelles.defs()
  return DEFS
end

function organelles.def(id)
  return BY_ID[id]
end

function organelles.has(set, id)
  return set ~= nil and set[id] == true
end

-- The next organelle the colony is eligible to keep, or nil. Eligible means:
-- predation is unlocked (prey -- the only source -- exist at all), the lifetime
-- division gate is met, every prerequisite organelle is already held, and it is
-- not already acquired. Returns the FIRST such def in order, so mitochondrion
-- always precedes chloroplast.
function organelles.next_eligible(set, total_divisions, predation_unlocked)
  if not predation_unlocked then
    return nil
  end
  set = set or {}
  local divisions = total_divisions or 0
  for _, def in ipairs(DEFS) do
    if not set[def.id] and divisions >= def.gate_div and (not def.needs or set[def.needs]) then
      return def
    end
  end
  return nil
end

-- Mark an organelle acquired in the set. Returns true if it was newly added.
function organelles.acquire(set, id)
  if not BY_ID[id] or set[id] then
    return false
  end
  set[id] = true
  return true
end

-- Fold: the multiplier the orchestrator applies to the intake's overall mult.
-- 1 with nothing held; the mitochondrion's +1.0 doubles it (the energy revolution).
function organelles.intake_mult(set)
  local mult = 1
  if set then
    for id in pairs(set) do
      local def = BY_ID[id]
      if def then
        mult = mult + def.intake_mult
      end
    end
  end
  return mult
end

-- Fold: the flat light income the orchestrator adds to the intake's photo term.
function organelles.photo_bonus(set)
  local bonus = 0
  if set then
    for id in pairs(set) do
      local def = BY_ID[id]
      if def then
        bonus = bonus + def.photo_bonus
      end
    end
  end
  return bonus
end

-- The acquired organelles as an ordered list of defs (for the panel). Tolerant of
-- unknown ids (a renamed/removed organelle in an old save is simply skipped).
function organelles.acquired_list(set)
  local out = {}
  if set then
    for _, def in ipairs(DEFS) do
      if set[def.id] then
        out[#out + 1] = def
      end
    end
  end
  return out
end

return organelles
