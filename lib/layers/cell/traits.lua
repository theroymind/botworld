-- Traits: the cell layer's upgrade system, reworked from the old genome strand
-- into a flat list of direct trait LEVELS plus milestone UNLOCKS. No slots, no
-- splicing, no hidden adjacency -- every row is one concrete, gamified buff
-- ("swim speed +12%") that the player levels for a rising per-trait cost, and
-- every level visibly changes every cell. Effects are DERIVED, never stored:
-- fold the levels into a `stats` table the sim and the world both read. Unlocks
-- are colony-milestone capabilities (photosynthesis, then predation) that open
-- closed-form income channels and reveal world contents. Pure Lua 5.1 (no
-- love.*) so it runs headless under tests. Adding a trait is one TRAITS entry
-- (plus one draw fragment in view.lua); adding an unlock is one UNLOCKS entry.
local traits = {}

-- Per-trait definitions: id, label, the concrete per-level hint shown on the
-- button, the geometric base cost, and (optionally) the unlock that must fire
-- before the row is levelable. Behaviour is folded out of the magnitudes below,
-- never branched on here.
local TRAITS = {
  {
    id = "photosynthesis",
    label = "Photosynthesis",
    hint = "+18% biomass/sec",
    base_cost = 10,
    locked_until = "photosynthesis", -- revealed by the early milestone
  },
  { id = "motility", label = "Motility", hint = "swim speed +12%", base_cost = 8 },
  { id = "sensing", label = "Chemotaxis", hint = "sense range +14", base_cost = 8 },
  { id = "digestion", label = "Digestion", hint = "+15% feed speed", base_cost = 12 },
  { id = "membrane", label = "Membrane", hint = "defense +5%", base_cost = 12 },
}

-- Stable order for the panel / fold (pairs() over a keyed table is unordered).
local ORDER = { "photosynthesis", "motility", "sensing", "digestion", "membrane" }

local BY_ID = {}
for _, def in ipairs(TRAITS) do
  BY_ID[def.id] = def
end

local COST_GROWTH = 1.5 -- per-trait cost multiplier per level (independent rows)

-- Folding magnitudes. Each maps a trait's level to its stat contribution.
local PHOTO_PER = 0.18 -- +18% gain per photosynthesis level
local FORAGE_MOTILITY_PER = 0.03 -- small economic gain: reaches food faster
local FORAGE_SENSING_PER = 0.02 -- small economic gain: finds more food
local SPEED_BASE = 60 -- world units/sec at motility 0
local SPEED_PER = 0.12 -- +12% swim speed per level
local SENSE_BASE = 70 -- chemotaxis radius at sensing 0
local SENSE_PER = 14 -- +14 range per level
local FEED_PER = 0.15 -- +15% feed (consume) speed per digestion level
local YIELD_PER = 0.05 -- digestion also nudges conversion yield
local DEFENSE_K = 0.05 -- defense = 1 - 1/(1 + levels*K): bounded [0,1)
local UPKEEP_K = 0.05 -- upkeep_mult = 1/(1 + levels*K): membrane shrinks upkeep

-- Milestone unlocks, in reach order. Each fires automatically when the colony
-- crosses `pop` cells (the orchestrator drives this), opening a closed-form
-- income channel (`income`, added to the gain multiplier) and adding world
-- contents + a visual tell. Absorption (ambient motes) is the always-on start
-- state, so it is NOT a fired unlock; these two are.
local UNLOCKS = {
  {
    id = "photosynthesis",
    label = "Photosynthesis",
    pop = 5,
    income = 0.3,
    tell = "pigment blooms — light becomes biomass",
  },
  {
    id = "predation",
    label = "Phagocytosis",
    pop = 24,
    income = 0.8,
    spawns_prey = true,
    enables_predators = true,
    tell = "your cells hunt and engulf prey",
  },
}

local UNLOCK_BY_ID = {}
for _, def in ipairs(UNLOCKS) do
  UNLOCK_BY_ID[def.id] = def
end

function traits.new()
  return {
    levels = {
      photosynthesis = 0,
      motility = 0,
      sensing = 0,
      digestion = 0,
      membrane = 0,
    },
    unlocked = {}, -- id -> true once a milestone has fired
  }
end

-- Fold the levels into the stat table the sim economy and the world both read.
-- With everything at level 0 the multipliers are neutral (1) and the bases are
-- the founding-cell values.
function traits.stats(state)
  local lv = state.levels
  return {
    photo_mult = 1 + PHOTO_PER * lv.photosynthesis,
    forage_mult = 1 + FORAGE_MOTILITY_PER * lv.motility + FORAGE_SENSING_PER * lv.sensing,
    feed_rate = 1 + FEED_PER * lv.digestion,
    yield_mult = 1 + YIELD_PER * lv.digestion,
    upkeep_mult = 1 / (1 + UPKEEP_K * lv.membrane),
    speed = SPEED_BASE * (1 + SPEED_PER * lv.motility),
    sense_range = SENSE_BASE + SENSE_PER * lv.sensing,
    defense = 1 - 1 / (1 + DEFENSE_K * lv.membrane),
  }
end

-- Biomass cost of this trait's next level; geometric and independent per trait.
function traits.cost(state, id)
  local def = BY_ID[id]
  if not def then
    return math.huge
  end
  return math.ceil(def.base_cost * COST_GROWTH ^ state.levels[id])
end

-- Bump one trait a level. Spends no biomass -- the caller checks traits.cost()
-- against the sim and deducts first (mirrors the old genome.mutate contract).
-- Returns false (no change) on an unknown id.
function traits.level(state, id)
  if not BY_ID[id] then
    return false
  end
  state.levels[id] = state.levels[id] + 1
  return true
end

function traits.hint(id)
  local def = BY_ID[id]
  return def and def.hint or ""
end

-- Ordered list of trait defs for the panel; treat as read-only.
function traits.list()
  local out = {}
  for i = 1, #ORDER do
    out[i] = BY_ID[ORDER[i]]
  end
  return out
end

function traits.def(id)
  return BY_ID[id]
end

-- A trait row is available once it has no lock, or once its gating unlock has
-- fired. Locked rows show as "reach colony N" in the panel.
function traits.is_available(state, id)
  local def = BY_ID[id]
  if not def or not def.locked_until then
    return true
  end
  return state.unlocked[def.locked_until] == true
end

-- Milestone unlock defs, in reach order; treat as read-only.
function traits.unlocks()
  return UNLOCKS
end

function traits.is_unlocked(state, id)
  return state.unlocked[id] == true
end

-- Mark a milestone fired. Returns the def if this flips it on for the first
-- time (so the caller can toast + react), nil if already unlocked or unknown.
function traits.unlock(state, id)
  local def = UNLOCK_BY_ID[id]
  if not def or state.unlocked[id] then
    return nil
  end
  state.unlocked[id] = true
  return def
end

-- The next milestone the colony has not yet reached, for the panel's "next at
-- colony N" notice. nil once every unlock has fired.
function traits.next_unlock(state)
  for _, def in ipairs(UNLOCKS) do
    if not state.unlocked[def.id] then
      return def
    end
  end
  return nil
end

-- Closed-form income multiplier from fired unlocks: each opened channel is an
-- extra food source, folded into the gain side of the economy.
function traits.income_mult(state)
  local mult = 1
  for _, def in ipairs(UNLOCKS) do
    if state.unlocked[def.id] then
      mult = mult + def.income
    end
  end
  return mult
end

-- The set the world reads to decide what contents to spawn (prey, predators).
function traits.unlocked_set(state)
  return state.unlocked
end

-- Plain-data snapshot for saving (no metatable; mirrors economy.serialize).
function traits.serialize(state)
  local levels = {}
  for _, id in ipairs(ORDER) do
    levels[id] = state.levels[id] or 0
  end
  local unlocked = {}
  for id in pairs(state.unlocked) do
    unlocked[id] = true
  end
  return { levels = levels, unlocked = unlocked }
end

-- Rebuild from serialize() data, tolerant of added/removed ids: unknown trait
-- and unlock ids are dropped, missing ones keep their fresh defaults, so saves
-- survive a changed trait/unlock set.
function traits.load(data)
  local state = traits.new()
  data = data or {}
  local levels = data.levels or {}
  for _, id in ipairs(ORDER) do
    local lv = levels[id]
    if type(lv) == "number" and lv > 0 then
      state.levels[id] = math.floor(lv)
    end
  end
  local unlocked = data.unlocked or {}
  for id in pairs(unlocked) do
    if UNLOCK_BY_ID[id] then
      state.unlocked[id] = true
    end
  end
  return state
end

return traits
