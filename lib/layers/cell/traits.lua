-- Traits: the cell layer's upgrade system, reworked from the old genome strand
-- into a flat list of direct trait LEVELS. No slots, no splicing, no hidden
-- adjacency -- every row is one concrete, gamified buff ("swim speed +12%") that
-- the player levels for a rising per-trait cost, and every level visibly changes
-- every cell. Effects are DERIVED, never stored: fold the levels into a `stats`
-- table the sim and the world both read. Pure Lua 5.1 (no love.*) so it runs
-- headless under tests. Adding a trait is one TRAITS entry (plus one draw fragment
-- in view.lua).
--
-- The milestone CAPABILITIES (photosynthesis, phagocytosis, the endosymbiosis proc)
-- no longer live here -- they were retired from the in-run biomass-unlock system and
-- now live on the permanent endospore tree (lib/layers/cell/endospores.lua). A trait
-- row may still be GATED behind a capability via `locked_until` (the Photosynthesis
-- row appears only once the Photosynthesis root is bought); is_available reads that
-- gate from the capability set the orchestrator folds out of endospores.capabilities.
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
    locked_until = "photosynthesis", -- capability key: revealed once the Photosynthesis root is bought
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

function traits.new()
  return {
    levels = {
      photosynthesis = 0,
      motility = 0,
      sensing = 0,
      digestion = 0,
      evasion = 0,
    },
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

-- The current level of one trait (0 if unleveled / unknown). A read accessor so
-- callers (e.g. the competition counter) can key on a raw level without reaching
-- into the state's internal `levels` table.
function traits.level_of(state, id) return state.levels[id] or 0 end

-- A trait row is available once it has no capability lock, or once the capability
-- gating it has been bought on the endospore tree. `caps` is the orchestrator's
-- capability set (endospores.capabilities): caps[def.locked_until] is true once the
-- gating node is bought. A nil caps (or a missing capability) keeps a gated row hidden,
-- so the Photosynthesis row stays out of the panel until the Photosynthesis root is bought.
function traits.is_available(_state, id, caps)
  local def = BY_ID[id]
  if not def or not def.locked_until then
    return true
  end
  return caps ~= nil and caps[def.locked_until] == true
end

-- Plain-data snapshot for saving (no metatable; mirrors economy.serialize). Capabilities
-- live on the endospore tree now, so only the trait levels are persisted here.
function traits.serialize(state)
  local levels = {}
  for _, id in ipairs(ORDER) do
    levels[id] = state.levels[id] or 0
  end
  return { levels = levels }
end

-- Rebuild from serialize() data, tolerant of added/removed ids: unknown trait ids are
-- dropped, missing ones keep their fresh defaults, so saves survive a changed trait set.
-- An old save's `traits.unlocked` slice is silently ignored -- the capabilities migrated
-- to the endospore tree, so a resumed lineage simply starts climbing it.
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
  return state
end

return traits
