-- Generic prestige kernel: a leveled, gated skill tree spent in a meta-currency
-- that SURVIVES the within-phase reset, plus a high-water "peak" observer that
-- decides the payout. Layer-agnostic and pure Lua 5.1 (no love.*) so it runs
-- headless under plain lua for tests and the balance harness. One instance per
-- layer that supplies node defs; the phase's data module owns the defs + the fold
-- that turns node levels into economy modifiers (this kernel knows nothing of any
-- economy). Distinct from economy.lua -- that models owned-count generators +
-- one-shot upgrades; this models leveled nodes with per-node caps, tier-multiplied
-- geometric cost, requires-by-MAXED gating, and a currency that persists across the
-- grow -> collapse -> spend -> regrow loop. It mirrors economy.lua's DNA, though:
-- read-only shareable defs, serialize() -> plain table, load() tolerant of
-- added/removed ids and changed caps.
--
-- defs shape (read-only; never mutated, safe to share across instances):
-- {
--   { id = "...", label = "...",
--     tier = 0,            -- 0 root, 1 branch, 2 capstone, ... (scales the cost)
--     cap = 5,             -- max level
--     cost_base = 1, cost_growth = 1.6,  -- geometric per-level cost (x tier_mult^tier)
--     requires = { "<node id>", ... },   -- unlocked once EVERY listed node is MAXED
--     effects = { <key> = per_level },   -- summed by effect_total; the phase fold reads these
--   },
-- }
--
-- The PEAK is a running high-water of an instantaneous "value" the orchestrator
-- feeds via observe(); collapse(penalty) banks floor(peak * penalty) into the
-- currency (and lifetime) and zeroes the peak -- penalty 1 for a voluntary cash-out,
-- 0.5 for a full collapse. lifetime never drops on spend (the always-on bonus reads it).
local spore_tree = {}

local tree = {}
tree.__index = tree

local function copy(t)
  local out = {}
  for key, value in pairs(t) do
    out[key] = value
  end
  return out
end

local function node_def(self, id)
  return assert(self.node_by_id[id], "unknown spore node: " .. tostring(id))
end

function spore_tree.new(defs, opts)
  local self = setmetatable({}, tree)
  opts = opts or {}
  self.defs = defs or {}
  self.currency_name = opts.currency or "spores"
  self.tier_mult = opts.tier_mult or 1
  self.node_by_id = {}
  self.levels = {}
  for _, node in ipairs(self.defs) do
    self.node_by_id[node.id] = node
    self.levels[node.id] = 0
  end
  self.currency = 0
  self.lifetime = 0
  self.peak = 0
  return self
end

function tree.level_of(self, id) return self.levels[id] or 0 end

function tree.is_maxed(self, id)
  local def = self.node_by_id[id]
  return def ~= nil and self:level_of(id) >= def.cap
end

-- A node is buyable-eligible once every node it REQUIRES is fully maxed (the
-- root, with no requires, is unlocked from the start). This single rule expresses
-- the whole spine: branch -> capstone (both branch nodes maxed) -> gate (both
-- capstones maxed) -> ... -- no per-tier branching here, just data.
function tree.is_unlocked(self, id)
  local def = self.node_by_id[id]
  if not def then
    return false
  end
  if def.requires then
    for _, req in ipairs(def.requires) do
      if not self:is_maxed(req) then
        return false
      end
    end
  end
  return true
end

-- Currency cost of this node's NEXT level: geometric within the node, scaled by
-- tier_mult^tier so each tier costs ~tier_mult x the previous. math.huge for an
-- unknown id, so an affordability check on a bad id always fails closed.
function tree.node_cost(self, id)
  local def = self.node_by_id[id]
  if not def then
    return math.huge
  end
  local geometric = math.ceil(def.cost_base * def.cost_growth ^ self:level_of(id))
  return geometric * self.tier_mult ^ (def.tier or 0)
end

function tree.can_buy(self, id)
  if not self:is_unlocked(id) or self:is_maxed(id) then
    return false
  end
  return self.currency >= self:node_cost(id)
end

-- Deduct the cost (the kernel owns the wallet, like economy.buy_upgrade) and add
-- one level. Returns success; the caller persists.
function tree.buy(self, id)
  if not self:can_buy(id) then
    return false
  end
  self.currency = self.currency - self:node_cost(id)
  self.levels[id] = self:level_of(id) + 1
  return true
end

-- Sum of one effect key across every node (level x per-level magnitude). The
-- phase fold calls this per key and maps the totals onto its economy terms; a key
-- no node carries totals to 0 (neutral), so the fold stays neutral until spent.
function tree.effect_total(self, key)
  local total = 0
  for _, node in ipairs(self.defs) do
    local effects = node.effects
    if effects and effects[key] then
      total = total + self:level_of(node.id) * effects[key]
    end
  end
  return total
end

function tree.currency_amount(self) return self.currency end

function tree.lifetime_amount(self) return self.lifetime end

-- Raise the running high-water mark. The peak only ratchets UP, so a colony in
-- decline simply stops raising it -- it can never depress an already-banked peak.
function tree.observe(self, value)
  if value and value > self.peak then
    self.peak = value
  end
end

-- What collapsing NOW would bank, without mutating (the HUD's "bankable" read).
function tree.bankable(self, penalty) return math.floor(self.peak * (penalty or 1)) end

-- Bank floor(peak * penalty) into the currency (and lifetime) and zero the peak
-- for the next generation. penalty 1 = voluntary sporulate (full), 0.5 = full
-- collapse / extinction (half). Returns the amount banked.
function tree.collapse(self, penalty)
  local gained = self:bankable(penalty)
  self.currency = self.currency + gained
  self.lifetime = self.lifetime + gained
  self.peak = 0
  return gained
end

-- Plain-data snapshot of mutable state (no defs, no metatable) for saving.
function tree.serialize(self)
  return {
    currency = self.currency,
    lifetime = self.lifetime,
    peak = self.peak,
    levels = copy(self.levels),
  }
end

-- Rebuild an instance from defs + serialize() data. Missing fields keep fresh
-- defaults, unknown node ids are dropped, and a saved level is clamped to the
-- def's CURRENT cap -- so saves survive a changed/reduced tree.
function spore_tree.load(defs, opts, data)
  local self = spore_tree.new(defs, opts)
  data = data or {}
  if type(data.currency) == "number" and data.currency >= 0 then
    self.currency = data.currency
  end
  if type(data.lifetime) == "number" and data.lifetime >= 0 then
    self.lifetime = data.lifetime
  end
  if type(data.peak) == "number" and data.peak >= 0 then
    self.peak = data.peak
  end
  local levels = data.levels or {}
  for id, def in pairs(self.node_by_id) do
    local lv = levels[id]
    if type(lv) == "number" and lv > 0 then
      self.levels[id] = math.min(math.floor(lv), def.cap)
    end
  end
  return self
end

return spore_tree
