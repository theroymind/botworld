-- Generic incremental economy: resources accrue from owned generators, scaled
-- by one-shot upgrade multipliers. Layer-agnostic and pure Lua 5.1 (no love.*)
-- so it runs headless under plain lua for tests. One instance per game layer.
--
-- defs shape (read-only; never mutated, safe to share across instances):
-- {
--   resources = { biomass = 0 },  -- name -> initial amount
--   generators = {  -- ordered array
--     { id = "...", name = "...", resource = "biomass",
--       base_rate = 0.5,  -- units/sec each
--       base_cost = 15, cost_growth = 1.15, cost_resource = "biomass" },
--   },
--   upgrades = {  -- ordered array, one-shot purchases
--     { id = "...", name = "...", cost = 100, cost_resource = "biomass",
--       target = "<generator id>" or "global", multiplier = 2,
--       unlock_at = { resource = "biomass", amount = 50 } },  -- visible once LIFETIME reached
--   },
-- }
--
-- Lifetime totals count everything ever gained and never drop when spending;
-- upgrade visibility keys off lifetime. eco.global_multiplier (default 1) is a
-- public field scaling every rate -- prestige writes it.
local economy = {}

local eco = {}
eco.__index = eco

local function copy(t)
  local out = {}
  for key, value in pairs(t) do
    out[key] = value
  end
  return out
end

local function generator_def(self, id)
  return assert(self.generator_by_id[id], "unknown generator: " .. tostring(id))
end

local function upgrade_def(self, id)
  return assert(self.upgrade_by_id[id], "unknown upgrade: " .. tostring(id))
end

-- Product of purchased multipliers that apply to one generator (its own + "global").
local function purchased_multiplier(self, generator_id)
  local product = 1
  for _, upgrade in ipairs(self.defs.upgrades) do
    local targeted = upgrade.target == generator_id or upgrade.target == "global"
    if targeted and self.purchased[upgrade.id] then
      product = product * upgrade.multiplier
    end
  end
  return product
end

-- Apply rate * seconds to every resource; optionally record gains per resource.
local function accrue(self, seconds, gains)
  for resource in pairs(self.defs.resources) do
    local gain = self:rate(resource) * seconds
    self.amounts[resource] = self.amounts[resource] + gain
    if gain > 0 then
      self.lifetimes[resource] = self.lifetimes[resource] + gain
    end
    if gains then
      gains[resource] = gain
    end
  end
end

function economy.new(defs)
  local self = setmetatable({}, eco)
  self.defs = {
    resources = defs.resources or {},
    generators = defs.generators or {},
    upgrades = defs.upgrades or {},
  }
  self.amounts = {}
  self.lifetimes = {}
  for resource, initial in pairs(self.defs.resources) do
    self.amounts[resource] = initial
    self.lifetimes[resource] = initial
  end
  self.owned = {}
  self.generator_by_id = {}
  for _, generator in ipairs(self.defs.generators) do
    self.owned[generator.id] = 0
    self.generator_by_id[generator.id] = generator
  end
  self.purchased = {}
  self.upgrade_by_id = {}
  for _, upgrade in ipairs(self.defs.upgrades) do
    self.upgrade_by_id[upgrade.id] = upgrade
  end
  self.global_multiplier = 1
  return self
end

function eco.tick(self, dt)
  accrue(self, dt)
end

-- Units/sec of `resource` across all generators, with upgrade and prestige multipliers.
function eco.rate(self, resource)
  local total = 0
  for _, generator in ipairs(self.defs.generators) do
    local owned = self.owned[generator.id]
    if owned > 0 and generator.resource == resource then
      total = total + owned * generator.base_rate * purchased_multiplier(self, generator.id)
    end
  end
  return total * self.global_multiplier
end

function eco.amount(self, resource) return self.amounts[resource] or 0 end

function eco.lifetime(self, resource) return self.lifetimes[resource] or 0 end

-- Manual gain (e.g. a click); positive gains count toward lifetime.
function eco.add(self, resource, n)
  self.amounts[resource] = (self.amounts[resource] or 0) + n
  if n > 0 then
    self.lifetimes[resource] = (self.lifetimes[resource] or 0) + n
  end
end

function eco.generator_cost(self, id)
  local generator = generator_def(self, id)
  return math.ceil(generator.base_cost * generator.cost_growth ^ self.owned[id])
end

function eco.can_buy_generator(self, id)
  local generator = generator_def(self, id)
  return self:amount(generator.cost_resource) >= self:generator_cost(id)
end

-- Deducts the cost (lifetime untouched) and adds one owned. Returns success.
function eco.buy_generator(self, id)
  if not self:can_buy_generator(id) then
    return false
  end
  local generator = generator_def(self, id)
  local cost = self:generator_cost(id)
  self.amounts[generator.cost_resource] = self.amounts[generator.cost_resource] - cost
  self.owned[id] = self.owned[id] + 1
  return true
end

function eco.generator_owned(self, id) return self.owned[id] or 0 end

-- Visible once the unlock_at LIFETIME threshold is met (or absent); purchases stick.
function eco.upgrade_visible(self, id)
  if self.purchased[id] then
    return true
  end
  local unlock = upgrade_def(self, id).unlock_at
  if not unlock then
    return true
  end
  return self:lifetime(unlock.resource) >= unlock.amount
end

function eco.upgrade_purchased(self, id) return self.purchased[id] == true end

function eco.can_buy_upgrade(self, id)
  if self.purchased[id] or not self:upgrade_visible(id) then
    return false
  end
  local upgrade = upgrade_def(self, id)
  return self:amount(upgrade.cost_resource) >= upgrade.cost
end

function eco.buy_upgrade(self, id)
  if not self:can_buy_upgrade(id) then
    return false
  end
  local upgrade = upgrade_def(self, id)
  self.amounts[upgrade.cost_resource] = self.amounts[upgrade.cost_resource] - upgrade.cost
  self.purchased[id] = true
  return true
end

-- Lump-sum catch-up for time away; returns gains as { resource = amount }.
function eco.offline(self, seconds)
  local gains = {}
  accrue(self, seconds, gains)
  return gains
end

-- Plain-data snapshot of mutable state (no defs, no metatable) for saving.
function eco.serialize(self)
  return {
    amounts = copy(self.amounts),
    lifetime = copy(self.lifetimes),
    owned = copy(self.owned),
    purchased = copy(self.purchased), -- set of upgrade ids
    global_multiplier = self.global_multiplier,
  }
end

-- Rebuild an instance from defs + serialize() data. Missing fields keep fresh
-- defaults and unknown ids are dropped, so saves survive def changes.
function economy.load(defs, data)
  local self = economy.new(defs)
  data = data or {}
  local amounts = data.amounts or {}
  local lifetime = data.lifetime or {}
  for resource in pairs(self.defs.resources) do
    if amounts[resource] ~= nil then
      self.amounts[resource] = amounts[resource]
    end
    if lifetime[resource] ~= nil then
      self.lifetimes[resource] = lifetime[resource]
    end
  end
  local owned = data.owned or {}
  for id in pairs(self.generator_by_id) do
    if owned[id] ~= nil then
      self.owned[id] = owned[id]
    end
  end
  local purchased = data.purchased or {}
  for id in pairs(self.upgrade_by_id) do
    if purchased[id] then
      self.purchased[id] = true
    end
  end
  if data.global_multiplier ~= nil then
    self.global_multiplier = data.global_multiplier
  end
  return self
end

return economy
