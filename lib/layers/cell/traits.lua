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
--
-- Two trait PAIRS also synergize (see SYN_* below): the cross-terms are explicit
-- and legible (not the old hidden strand adjacency), and reward a balanced build
-- over spiking one trait -- this is what gives "all maxed" a reason to keep going.
local traits = {}

-- Per-trait definitions: id, label, the concrete per-level hint shown on the
-- button, the geometric base cost, and (optionally) the unlock that must fire
-- before the row is levelable. Behaviour is folded out of the magnitudes below,
-- never branched on here.
local TRAITS = {
  {
    id = "photosynthesis",
    label = "Photosynthesis",
    hint = "+18% biomass/sec, oxygenates",
    base_cost = 10,
    locked_until = "photosynthesis", -- revealed by the early milestone
  },
  { id = "motility", label = "Motility", hint = "swim speed +25%, +8% forage", base_cost = 8 },
  { id = "sensing", label = "Chemotaxis", hint = "sense range +14", base_cost = 8 },
  { id = "digestion", label = "Digestion", hint = "division -8%, clears waste", base_cost = 12 },
  { id = "evasion", label = "Evasion", hint = "evade +5%, clears waste", base_cost = 12 },
}

-- Stable order for the panel / fold (pairs() over a keyed table is unordered).
local ORDER = { "photosynthesis", "motility", "sensing", "digestion", "evasion" }

local BY_ID = {}
for _, def in ipairs(TRAITS) do
  BY_ID[def.id] = def
end

local COST_GROWTH = 1.5 -- per-trait cost multiplier per level (independent rows)

-- Folding magnitudes. Each maps a trait's level to its stat contribution.
local PHOTO_PER = 0.18 -- +18% gain per photosynthesis level
-- Motility now pulls real economic weight (not just a cosmetic tail): a leveled
-- swimmer reaches food the colony has thinned, so each level is a meaningful
-- +8% foraging income AND a clearly visible +25% swim speed (the on-screen tell).
local FORAGE_MOTILITY_PER = 0.08 -- economic gain per motility level: reaches food faster
local FORAGE_SENSING_PER = 0.02 -- small economic gain: finds more food
local SPEED_BASE = 30 -- world units/sec at motility 0 (a slow drift; motility upgrades earn their keep)
local SPEED_PER = 0.25 -- +25% swim speed per level (a big, legible jump -- the upgrade reads on screen)
local SENSE_BASE = 70 -- chemotaxis radius at sensing 0
local SENSE_PER = 14 -- +14 range per level
local FEED_PER = 0.15 -- +15% feed (consume) speed per digestion level (cosmetic flavor)
local DIV_FACTOR = 0.92 -- division energy cost x0.92 per digestion level (-8%, compounding)
local EVASION_K = 0.05 -- evasion = 1 - 1/(1 + levels*K): bounded [0,1) flee/dodge chance
local UPKEEP_K = 0.05 -- upkeep_mult = 1/(1 + levels*K): a leaner, nimbler cell also trims upkeep

-- WASTE CLEARANCE (tox_clear, units/sec) -- the survival lever the failure pressure
-- is balanced against. The dish fouls at a fixed rate (cell.lua TOX_PROD); the
-- colony must clear at least that fast or toxicity climbs and chokes intake (see
-- sim.lua). CLEAN_BASE is what a bare founder manages on its own -- deliberately
-- BELOW the fouling rate, so an UNTENDED colony is doomed to choke (the failure
-- condition). The player buys headroom by leveling the cleanup traits: Digestion
-- (the primary -- processing waste), Evasion (a lean, efficient metabolism), and
-- Photosynthesis (oxygenation). A couple of cleanup levels, or steady feeding,
-- tips clearance above fouling and the colony survives.
local CLEAN_BASE = 0.12 -- founder's intrinsic clearance (below TOX_PROD on purpose)
local CLEAN_PER_DIGESTION = 0.24 -- digestion is the primary waste-processing trait
local CLEAN_PER_EVASION = 0.16 -- a lean metabolism wastes less
local CLEAN_PER_PHOTO = 0.12 -- photosynthesis oxygenates the medium

-- Trait SYNERGY magnitudes. Paired traits multiply, so a BALANCED build beats a
-- one-trait spike and "all maxed" keeps a reason to keep leveling. The sqrt(a*b)
-- shape only pays out when BOTH partners are high. Each pairing is fully legible
-- (no hidden adjacency -- the panel can name the partner). Tune here, then re-run
-- tools/sim_lab.lua to read the new carrying-capacity curve.
local SYN_REACH = 0.06 -- Motility x Chemotaxis: forage cap x (1 + this * sqrt(motility*sensing))
local SYN_THRIFT = 0.02 -- Digestion x Evasion:   upkeep   / (1 + this * sqrt(digestion*evasion))

-- Milestone unlocks, in reach order. These are EVOLUTIONS THE PLAYER BUYS, not
-- auto-fired research: `pop` is now only the colony size at which the option
-- REVEALS in the panel (so the pacing/teaser still tracks colony growth), and
-- `cost` is the biomass the player must spend to evolve it. Each opens a
-- closed-form income channel (`income`, added to the gain multiplier) and adds
-- world contents + a visual tell. Costs are deliberately STEEP for the phase the
-- capability appears in -- a real save-up, the "expensive research" beat -- and
-- are first-pass values to tune in tools/sim_lab.lua against the biomass curve.
-- Absorption (ambient motes) is the always-on start state, so it is NOT a buyable
-- unlock; these two are.
local UNLOCKS = {
  {
    id = "photosynthesis",
    label = "Photosynthesis",
    pop = 5, -- reveals (becomes buyable) once the colony reaches this size
    cost = 150, -- biomass to evolve it -- a steep early save-up
    income = 0.3,
    tell = "pigment blooms — light becomes biomass",
  },
  {
    id = "predation",
    label = "Phagocytosis",
    pop = 24, -- reveals once the colony reaches this size
    cost = 2500, -- biomass to evolve it -- a steep mid-phase gate
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
      evasion = 0,
    },
    unlocked = {}, -- id -> true once a milestone has fired
  }
end

-- Fold the levels into the stat table the sim economy and the world both read.
-- With everything at level 0 the multipliers are neutral (1) and the bases are
-- the founding-cell values.
function traits.stats(state)
  local lv = state.levels
  -- Synergy factors (>= 1; exactly 1 until both partners are leveled, so all-zero
  -- stats stay neutral). reach lifts the forage CAP (mobile, sensing cells reach
  -- food the colony outgrew -> higher carrying capacity); thrift trims upkeep (a
  -- lean, efficient cell wastes less -> lower K denominator).
  local reach_syn = 1 + SYN_REACH * math.sqrt(lv.motility * lv.sensing)
  local thrift_syn = 1 + SYN_THRIFT * math.sqrt(lv.digestion * lv.evasion)
  return {
    photo_mult = 1 + PHOTO_PER * lv.photosynthesis,
    forage_mult = 1 + FORAGE_MOTILITY_PER * lv.motility + FORAGE_SENSING_PER * lv.sensing,
    forage_cap_mult = reach_syn, -- synergy: multiplies the food-saturation cap (cell.lua applies it)
    feed_rate = 1 + FEED_PER * lv.digestion,
    div_mult = DIV_FACTOR ^ lv.digestion,
    upkeep_mult = 1 / ((1 + UPKEEP_K * lv.evasion) * thrift_syn), -- evasion base x thrift synergy
    speed = SPEED_BASE * (1 + SPEED_PER * lv.motility),
    sense_range = SENSE_BASE + SENSE_PER * lv.sensing,
    evasion = 1 - 1 / (1 + EVASION_K * lv.evasion),
    -- Waste clearance (units/sec): the founder's intrinsic floor plus the cleanup
    -- traits. The orchestrator passes this as intake.tox_clear; when it beats the
    -- dish's fouling rate, toxicity falls and the colony stays healthy.
    cleanup = CLEAN_BASE
      + CLEAN_PER_DIGESTION * lv.digestion
      + CLEAN_PER_EVASION * lv.evasion
      + CLEAN_PER_PHOTO * lv.photosynthesis,
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

function traits.def(id) return BY_ID[id] end

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
function traits.unlocks() return UNLOCKS end

function traits.is_unlocked(state, id) return state.unlocked[id] == true end

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

-- The next milestone the colony has not yet evolved, for the panel's "next at
-- colony N" notice. nil once every unlock has been bought.
function traits.next_unlock(state)
  for _, def in ipairs(UNLOCKS) do
    if not state.unlocked[def.id] then
      return def
    end
  end
  return nil
end

-- Biomass cost to evolve a milestone capability. math.huge for an unknown id, so
-- an affordability check on a bad id always fails closed.
function traits.unlock_cost(id)
  local def = UNLOCK_BY_ID[id]
  return def and def.cost or math.huge
end

-- Has the colony grown enough for this capability to REVEAL (become buyable)?
-- Below its `pop` the panel shows a dim "colony N" teaser instead of a buy button;
-- at/above it the player may spend the biomass cost to evolve it. This replaces
-- the old auto-fire: reaching `pop` only OFFERS the purchase, never grants it.
function traits.is_revealed(_state, id, pop)
  local def = UNLOCK_BY_ID[id]
  if not def then
    return false
  end
  return (pop or 0) >= def.pop
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
function traits.unlocked_set(state) return state.unlocked end

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
  -- Migration: the "membrane" trait was renamed to "evasion". Carry an old
  -- save's membrane level over unless the new key is already present.
  if levels.membrane ~= nil and levels.evasion == nil then
    levels.evasion = levels.membrane
  end
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
