-- Standalone spec for lib/engine/economy.lua.
-- Plain Lua 5.1, no framework. Run from the repo root: lua tests/economy_spec.lua
-- (Number-formatting lives in its own tests/format_spec.lua.)
local root = (arg and arg[0] or ""):match("^(.*)/tests/[^/]*$") or "."
package.path = root .. "/?.lua;" .. package.path

local economy = require("lib.engine.economy")

local checks = 0

local function check(condition, label)
  checks = checks + 1
  if not condition then
    error("FAILED: " .. label, 2)
  end
end

local function approx(a, b) return math.abs(a - b) < 1e-9 end

-- Fresh defs per test so instances can't share state through them.
local function defs()
  return {
    resources = { biomass = 0 },
    generators = {
      {
        id = "cell",
        name = "Cell",
        resource = "biomass",
        base_rate = 0.5,
        base_cost = 15,
        cost_growth = 1.15,
        cost_resource = "biomass",
      },
      {
        id = "colony",
        name = "Colony",
        resource = "biomass",
        base_rate = 4,
        base_cost = 100,
        cost_growth = 1.2,
        cost_resource = "biomass",
      },
    },
    upgrades = {
      {
        id = "cilia",
        name = "Cilia",
        cost = 50,
        cost_resource = "biomass",
        target = "cell",
        multiplier = 2,
        unlock_at = { resource = "biomass", amount = 30 },
      },
      {
        id = "mitochondria",
        name = "Mitochondria",
        cost = 80,
        cost_resource = "biomass",
        target = "global",
        multiplier = 3,
        unlock_at = { resource = "biomass", amount = 60 },
      },
      {
        id = "spores",
        name = "Spores",
        cost = 10,
        cost_resource = "biomass",
        target = "global",
        multiplier = 1.5,
        unlock_at = { resource = "biomass", amount = 1000 },
      },
    },
  }
end

-- Fresh state + manual add.
local eco = economy.new(defs())
check(eco:amount("biomass") == 0, "fresh amount is 0")
check(eco:lifetime("biomass") == 0, "fresh lifetime is 0")
check(eco:rate("biomass") == 0, "fresh rate is 0")
check(eco:amount("nope") == 0, "unknown resource reads as 0")
eco:tick(1)
check(eco:amount("biomass") == 0, "tick with nothing owned adds nothing")
eco:add("biomass", 10)
check(eco:amount("biomass") == 10, "add raises amount")
check(eco:lifetime("biomass") == 10, "add counts toward lifetime")

-- Cost growth + buying deducts amount but not lifetime.
eco = economy.new(defs())
check(eco:generator_cost("cell") == 15, "base cost at 0 owned")
eco:add("biomass", 200)
check(eco:can_buy_generator("cell"), "can buy when affordable")
check(eco:buy_generator("cell"), "buy succeeds")
check(eco:generator_owned("cell") == 1, "buy adds one owned")
check(eco:amount("biomass") == 185, "buy deducts cost")
check(eco:lifetime("biomass") == 200, "spending leaves lifetime untouched")
check(eco:generator_cost("cell") == 18, "cost grows: ceil(15 * 1.15)")
check(eco:buy_generator("cell"), "second buy succeeds")
check(eco:generator_cost("cell") == 20, "cost grows: ceil(15 * 1.15^2)")
check(eco:buy_generator("colony"), "buy second generator type")
check(eco:amount("biomass") == 67, "amount after three buys")
check(not eco:can_buy_generator("colony"), "cannot afford grown cost")
check(not eco:buy_generator("colony"), "failed buy returns false")
check(eco:generator_owned("colony") == 1, "failed buy adds nothing")
check(eco:amount("biomass") == 67, "failed buy deducts nothing")

-- Tick accrual: 2 cells + 1 colony = 2 * 0.5 + 4 = 5/sec.
check(approx(eco:rate("biomass"), 5), "rate sums owned * base_rate")
eco:tick(2)
check(approx(eco:amount("biomass"), 77), "tick adds rate * dt")
check(approx(eco:lifetime("biomass"), 210), "ticked gains count toward lifetime")

-- Upgrade visibility keys off lifetime, purchases stick.
eco = economy.new(defs())
check(not eco:upgrade_visible("cilia"), "locked upgrade hidden")
check(not eco:can_buy_upgrade("cilia"), "hidden upgrade not buyable")
check(not eco:buy_upgrade("cilia"), "hidden upgrade buy fails")
eco:add("biomass", 30)
check(eco:upgrade_visible("cilia"), "upgrade visible at lifetime threshold")
check(not eco:can_buy_upgrade("cilia"), "visible but unaffordable")
eco:add("biomass", 30)
check(eco:can_buy_upgrade("cilia"), "visible and affordable")
check(not eco:can_buy_upgrade("spores"), "affordable but locked stays unbuyable")
check(not eco:buy_upgrade("spores"), "locked upgrade buy fails")
check(eco:buy_upgrade("cilia"), "upgrade buy succeeds")
check(eco:amount("biomass") == 10, "upgrade buy deducts cost")
check(eco:upgrade_purchased("cilia"), "purchase recorded")
check(not eco:buy_upgrade("cilia"), "one-shot: cannot buy twice")
check(eco:upgrade_visible("cilia"), "purchased upgrade stays visible")
check(eco:upgrade_visible("mitochondria"), "visibility uses lifetime, not current amount")

-- Generator + global upgrade multipliers stack, with prestige global_multiplier.
eco = economy.new(defs())
eco:add("biomass", 300)
check(eco:buy_generator("cell"), "stack test: buy cell")
check(eco:buy_generator("colony"), "stack test: buy colony")
check(eco:buy_upgrade("cilia"), "stack test: buy cell upgrade")
check(eco:buy_upgrade("mitochondria"), "stack test: buy global upgrade")
check(eco:amount("biomass") == 55, "stack test: spend tally")
-- (0.5 * 2 + 4) * 3 = 15: cilia doubles cells only, mitochondria triples all.
check(approx(eco:rate("biomass"), 15), "generator + global upgrades stack")
eco.global_multiplier = 2
check(approx(eco:rate("biomass"), 30), "prestige global_multiplier scales rate")

-- Offline lump sum equals rate * seconds.
local expected = eco:rate("biomass") * 10
local gains = eco:offline(10)
check(approx(gains.biomass, expected), "offline returns rate * seconds")
check(approx(eco:amount("biomass"), 55 + expected), "offline applies gains")
check(approx(eco:lifetime("biomass"), 300 + expected), "offline gains count toward lifetime")

-- Serialize -> load round-trip preserves state and rates.
local data = eco:serialize()
local loaded = economy.load(defs(), data)
check(approx(loaded:amount("biomass"), eco:amount("biomass")), "round-trip amount")
check(approx(loaded:lifetime("biomass"), eco:lifetime("biomass")), "round-trip lifetime")
check(loaded:generator_owned("cell") == 1, "round-trip owned cell")
check(loaded:generator_owned("colony") == 1, "round-trip owned colony")
check(loaded:upgrade_purchased("cilia"), "round-trip purchased upgrade")
check(loaded:upgrade_purchased("mitochondria"), "round-trip purchased global upgrade")
check(not loaded:upgrade_purchased("spores"), "round-trip unpurchased upgrade")
check(loaded.global_multiplier == 2, "round-trip global_multiplier")
check(approx(loaded:rate("biomass"), eco:rate("biomass")), "round-trip rate")
check(loaded:generator_cost("cell") == eco:generator_cost("cell"), "round-trip cost curve")

-- Load tolerates missing/partial/stale data.
local fresh = economy.load(defs(), nil)
check(fresh:amount("biomass") == 0, "load nil data: fresh amounts")
check(fresh:generator_owned("cell") == 0, "load nil data: fresh owned")
check(fresh.global_multiplier == 1, "load nil data: fresh multiplier")
local partial = economy.load(defs(), { owned = { cell = 3 } })
check(partial:amount("biomass") == 0, "partial load: missing amounts default")
check(approx(partial:rate("biomass"), 1.5), "partial load: owned restored")
local stale = economy.load(defs(), {
  amounts = { biomass = 5, krypton = 9 },
  owned = { ghost = 2 },
  purchased = { phantom = true },
})
check(stale:amount("biomass") == 5, "stale load: known resource kept")
check(stale:amount("krypton") == 0, "stale load: unknown resource dropped")
check(stale:generator_owned("ghost") == 0, "stale load: unknown generator dropped")
check(not stale:upgrade_purchased("phantom"), "stale load: unknown upgrade dropped")

print("all tests passed (" .. checks .. " checks)")
