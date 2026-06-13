-- Standalone spec for lib/engine/progression_tree.lua, the pure prestige-tree core.
-- Plain Lua 5.1, no framework. Run from the repo root: lua tests/progression_tree_spec.lua
--
-- Asserts the core's INVARIANTS -- requires-by-MAXED gating, tier-multiplied
-- geometric cost, currency conservation on buy, effect summation, the peak/bank
-- high-water loop, and load tolerance -- all derived from the in-spec defs and the
-- module's documented formulas, never hardcoded outputs.
local root = (arg and arg[0] or ""):match("^(.*)/tests/[^/]*$") or "."
package.path = root .. "/?.lua;" .. package.path

local progression_tree = require("lib.engine.progression_tree")

local checks = 0

local function check(condition, label)
  checks = checks + 1
  if not condition then
    error("FAILED: " .. label, 2)
  end
end

local function approx(a, b) return math.abs(a - b) < 1e-9 end

-- The core's documented cost formula, re-derived here from the def so the cost
-- guards assert the SHAPE (ceil(base * growth^level) * tier_mult^tier) rather than a
-- pre-computed magic number.
local function expected_cost(def, level, tier_mult)
  return math.ceil(def.cost_base * def.cost_growth ^ level) * tier_mult ^ (def.tier or 0)
end

-- A minimal but complete tree: a tier-0 root (cap 1, no requires), two tier-1 branch
-- nodes (cap 2) each requiring the root maxed, and a tier-2 capstone (cap 1) requiring
-- BOTH branches maxed. effects let us exercise effect_total across keys/tiers.
local ROOT, BRANCH_A, BRANCH_B, CAPSTONE = "root", "branch_a", "branch_b", "capstone"
local CURRENCY, TIER_MULT = "points", 10

local function defs()
  return {
    {
      id = ROOT,
      label = "Root",
      tier = 0,
      cap = 1,
      cost_base = 5,
      cost_growth = 1.5,
      effects = { yield = 0.1 },
    },
    {
      id = BRANCH_A,
      label = "Branch A",
      tier = 1,
      cap = 2,
      cost_base = 3,
      cost_growth = 1.4,
      requires = { ROOT },
      effects = { yield = 0.2, speed = 0.5 },
    },
    {
      id = BRANCH_B,
      label = "Branch B",
      tier = 1,
      cap = 2,
      cost_base = 7,
      cost_growth = 1.3,
      requires = { ROOT },
      effects = { speed = 0.25 },
    },
    {
      id = CAPSTONE,
      label = "Capstone",
      tier = 2,
      cap = 1,
      cost_base = 2,
      cost_growth = 2.0,
      requires = { BRANCH_A, BRANCH_B },
      effects = { yield = 1.0 },
    },
  }
end

-- A fully-funded fresh instance: lots of currency so buys are limited only by gating.
local function rich_tree()
  local t = progression_tree.new(defs(), { currency = CURRENCY, tier_mult = TIER_MULT })
  t.currency = 1e9
  return t
end

local function def_by_id(d, id)
  for _, node in ipairs(d) do
    if node.id == id then
      return node
    end
  end
  error("no def for " .. id)
end

-- Max a node out by repeated buys, driven by its cap from the defs.
local function max_node(t, id)
  local d = def_by_id(defs(), id)
  for _ = 1, d.cap do
    assert(t:buy(id), "max_node: buy should succeed for " .. id)
  end
end

-- ============================================================================
-- 1. GATING: requires-by-MAXED. The root is open from the start; branches wait on
-- the root being MAXED (not merely leveled); the capstone waits on BOTH branches.
-- ============================================================================
do
  local d = defs()
  local root_def = def_by_id(d, ROOT)
  local t = rich_tree()

  check(t:is_unlocked(ROOT), "root (no requires) is unlocked from the start")
  check(t:can_buy(ROOT), "root is buyable when affordable and unlocked")
  check(not t:is_unlocked(BRANCH_A), "branch is locked while root is unmaxed")
  check(not t:is_unlocked(CAPSTONE), "capstone is locked while branches are unmaxed")
  check(not t:can_buy(BRANCH_A), "can_buy fails closed on a locked node")

  -- Buy the root up to but NOT including its cap: still unmaxed, branch still locked.
  for _ = 1, root_def.cap - 1 do
    check(t:buy(ROOT), "buy root toward cap")
  end
  if root_def.cap > 1 then
    check(not t:is_maxed(ROOT), "root not maxed before its cap")
    check(not t:is_unlocked(BRANCH_A), "branch stays locked until root is fully maxed")
  end

  -- Maxing the root unlocks the branches (but not yet the capstone).
  check(t:buy(ROOT), "final root buy reaches the cap")
  check(t:is_maxed(ROOT), "root is maxed at its cap")
  check(t:is_unlocked(BRANCH_A), "maxing the root unlocks branch A")
  check(t:is_unlocked(BRANCH_B), "maxing the root unlocks branch B")
  check(t:can_buy(BRANCH_A), "an unlocked, affordable branch is buyable")
  check(not t:is_unlocked(CAPSTONE), "capstone still locked with branches unmaxed")

  -- Maxing only ONE branch is not enough for the capstone (AND across requires).
  max_node(t, BRANCH_A)
  check(t:is_maxed(BRANCH_A), "branch A reaches its cap")
  check(not t:is_unlocked(CAPSTONE), "capstone locked until EVERY required node is maxed")

  -- Maxing the second branch opens the capstone.
  max_node(t, BRANCH_B)
  check(t:is_maxed(BRANCH_B), "branch B reaches its cap")
  check(t:is_unlocked(CAPSTONE), "capstone unlocks once both branches are maxed")
  check(t:can_buy(CAPSTONE), "the unlocked capstone is buyable")

  -- A maxed node is no longer buyable.
  check(t:buy(CAPSTONE), "capstone buy succeeds")
  check(t:is_maxed(CAPSTONE), "capstone maxed at cap 1")
  check(not t:can_buy(CAPSTONE), "a maxed node is not buyable")
end

-- ============================================================================
-- 2. COST MATH: ceil(cost_base * cost_growth^level) * tier_mult^tier, checked at
-- level 0 of a tier-1 node and again after one buy (level 1), versus the re-derived
-- formula -- and the tier_mult^tier factor versus a tier-0 node.
-- ============================================================================
do
  local d = defs()
  local branch_def = def_by_id(d, BRANCH_A)
  local root_def = def_by_id(d, ROOT)
  local t = rich_tree()

  -- Tier-1 node at level 0: full formula including tier_mult^1.
  check(
    approx(t:node_cost(BRANCH_A), expected_cost(branch_def, 0, TIER_MULT)),
    "node_cost at level 0 matches ceil(base*growth^0)*tier_mult^tier"
  )
  -- The tier factor really applies: a tier-1 cost carries the tier_mult^1 factor a
  -- same-formula tier-0 evaluation would lack.
  check(
    approx(
      t:node_cost(BRANCH_A),
      math.ceil(branch_def.cost_base * branch_def.cost_growth ^ 0) * TIER_MULT
    ),
    "tier-1 node cost is scaled by tier_mult^1"
  )
  check(
    approx(t:node_cost(ROOT), math.ceil(root_def.cost_base * root_def.cost_growth ^ 0)),
    "tier-0 node cost carries no tier_mult factor (tier_mult^0 = 1)"
  )

  -- After one buy the level is 1, so the geometric term advances.
  max_node(t, ROOT) -- unlock the branch (cap 1) so it is buyable
  check(t:buy(BRANCH_A), "buy branch A once")
  check(
    approx(t:node_cost(BRANCH_A), expected_cost(branch_def, 1, TIER_MULT)),
    "node_cost after one buy matches the formula at level 1"
  )

  -- An unknown id fails closed at math.huge.
  check(t:node_cost("ghost") == math.huge, "unknown node id costs math.huge (fails closed)")
end

-- ============================================================================
-- 3. CURRENCY CONSERVATION on buy: a successful buy deducts EXACTLY node_cost and
-- raises the level by 1; an unaffordable buy is a no-op returning false; buying a
-- maxed or locked node returns false.
-- ============================================================================
do
  local t = progression_tree.new(defs(), { currency = CURRENCY, tier_mult = TIER_MULT })

  -- Locked node buy is a no-op even with infinite currency.
  t.currency = 1e9
  local before_locked = t.currency
  check(not t:buy(BRANCH_A), "buying a locked node returns false")
  check(t.currency == before_locked, "a locked buy spends nothing")
  check(t:level_of(BRANCH_A) == 0, "a locked buy raises no level")

  -- Exact deduction on a successful buy.
  local cost = t:node_cost(ROOT)
  local before = t.currency
  local lvl_before = t:level_of(ROOT)
  check(t:buy(ROOT), "affordable buy succeeds")
  check(approx(t.currency, before - cost), "buy deducts EXACTLY node_cost")
  check(t:level_of(ROOT) == lvl_before + 1, "buy raises the level by exactly 1")

  -- Unaffordable buy: set currency just below the next cost -> no-op false.
  local fresh = progression_tree.new(defs(), { currency = CURRENCY, tier_mult = TIER_MULT })
  local next_cost = fresh:node_cost(ROOT)
  fresh.currency = next_cost - 1
  local c0, l0 = fresh.currency, fresh:level_of(ROOT)
  check(not fresh:buy(ROOT), "an unaffordable buy returns false")
  check(fresh.currency == c0, "an unaffordable buy spends nothing")
  check(fresh:level_of(ROOT) == l0, "an unaffordable buy raises no level")

  -- Maxed node buy returns false.
  local maxed = rich_tree()
  max_node(maxed, ROOT)
  check(maxed:is_maxed(ROOT), "root maxed for the maxed-buy guard")
  local mc = maxed.currency
  check(not maxed:buy(ROOT), "buying a maxed node returns false")
  check(maxed.currency == mc, "a maxed buy spends nothing")
end

-- ============================================================================
-- 4. effect_total: leveling a node raises effect_total(key) by exactly the node's
-- per-level magnitude x its level; an unknown key totals 0.
-- ============================================================================
do
  local d = defs()
  local root_def = def_by_id(d, ROOT)
  local branch_def = def_by_id(d, BRANCH_A)
  local t = rich_tree()

  check(t:effect_total("yield") == 0, "no levels -> effect_total is 0")
  check(t:effect_total("ghost_key") == 0, "an unknown effect key totals 0")

  -- One node leveled: total is level x per-level magnitude.
  max_node(t, ROOT) -- root cap drives the level
  check(
    approx(t:effect_total("yield"), root_def.cap * root_def.effects.yield),
    "effect_total = level x per-level magnitude for one node"
  )

  -- Leveling a second contributor to the same key SUMS across nodes.
  check(t:buy(BRANCH_A), "level branch A once for the summation guard")
  local branch_level = t:level_of(BRANCH_A)
  check(
    approx(
      t:effect_total("yield"),
      root_def.cap * root_def.effects.yield + branch_level * branch_def.effects.yield
    ),
    "effect_total sums each node's level x its per-level magnitude across the tree"
  )
  -- A key only one of the leveled nodes carries reflects only that node.
  check(
    approx(t:effect_total("speed"), branch_level * branch_def.effects.speed),
    "effect_total for a key isolates the carrying node's contribution"
  )
end

-- ============================================================================
-- 5. PEAK / BANKING. observe ratchets UP only; bankable reads floor(peak*penalty)
-- without mutating; collapse banks floor(peak) into BOTH currency and lifetime and
-- zeroes the peak; a second collapse banks 0; penalty 0.5 banks floor(peak*0.5).
-- ============================================================================
do
  local PENALTY_FULL, PENALTY_HALF = 1, 0.5
  local t = progression_tree.new(defs(), { currency = CURRENCY, tier_mult = TIER_MULT })

  -- observe(a); observe(b<a); observe(c>a) leaves the peak at the high-water c.
  local a, b, c = 100.7, 40.2, 250.9
  t:observe(a)
  t:observe(b)
  check(t.peak == a, "observe only ratchets UP (a lower observation can't lower the peak)")
  t:observe(c)
  check(t.peak == c, "observe ratchets the peak up to a higher observation")
  check(t:bankable(PENALTY_FULL) == math.floor(c), "bankable(1) == floor(peak)")
  check(t.peak == c, "bankable is a pure read (does not mutate the peak)")

  -- collapse banks floor(peak) into currency AND lifetime, then zeroes the peak.
  local cur0, life0 = t.currency, t.lifetime
  local banked = t:collapse(PENALTY_FULL)
  check(banked == math.floor(c), "collapse(1) banks floor(peak)")
  check(t.currency == cur0 + math.floor(c), "collapse adds floor(peak) to currency")
  check(t.lifetime == life0 + math.floor(c), "collapse adds floor(peak) to lifetime")
  check(t.peak == 0, "collapse zeroes the peak")

  -- A second collapse with no fresh observation banks nothing.
  local cur1, life1 = t.currency, t.lifetime
  check(t:collapse(PENALTY_FULL) == 0, "a second collapse banks 0 (peak was zeroed)")
  check(t.currency == cur1, "the no-op collapse adds nothing to currency")
  check(t.lifetime == life1, "the no-op collapse adds nothing to lifetime")

  -- The HALF relationship: collapsing the SAME peak at 0.5 banks floor(peak*0.5).
  local peak_value = 333.9
  local full = progression_tree.new(defs(), { currency = CURRENCY, tier_mult = TIER_MULT })
  full:observe(peak_value)
  local half = progression_tree.new(defs(), { currency = CURRENCY, tier_mult = TIER_MULT })
  half:observe(peak_value)
  check(
    half:collapse(PENALTY_HALF) == math.floor(peak_value * PENALTY_HALF),
    "a peak collapsed at penalty 0.5 banks floor(peak*0.5)"
  )
  check(
    full:collapse(PENALTY_FULL) == math.floor(peak_value),
    "the same peak collapsed at penalty 1 banks floor(peak)"
  )
end

-- ============================================================================
-- 6. SAVE TOLERANCE: serialize/load round-trips currency/lifetime/peak/levels; a
-- saved level above a node's cap clamps to cap; an unknown saved id is dropped;
-- missing fields keep fresh defaults.
-- ============================================================================
do
  -- Build a non-trivial state, round-trip it, and confirm every mutable field returns.
  local t = rich_tree()
  max_node(t, ROOT)
  t:buy(BRANCH_A)
  t:observe(123.4)
  t.lifetime = 77
  local data = t:serialize()
  local loaded = progression_tree.load(defs(), { currency = CURRENCY, tier_mult = TIER_MULT }, data)
  check(loaded.currency == t.currency, "round-trip currency")
  check(loaded.lifetime == t.lifetime, "round-trip lifetime")
  check(loaded.peak == t.peak, "round-trip peak")
  check(loaded:level_of(ROOT) == t:level_of(ROOT), "round-trip a maxed node's level")
  check(loaded:level_of(BRANCH_A) == t:level_of(BRANCH_A), "round-trip a partial node's level")
  check(loaded:level_of(BRANCH_B) == 0, "round-trip an untouched node stays 0")

  -- A saved level ABOVE the node's cap clamps to cap on load.
  local branch_def = def_by_id(defs(), BRANCH_A)
  local over = progression_tree.load(defs(), { currency = CURRENCY, tier_mult = TIER_MULT }, {
    levels = { [BRANCH_A] = branch_def.cap + 5 },
  })
  check(over:level_of(BRANCH_A) == branch_def.cap, "a saved level above cap clamps to cap on load")

  -- An unknown node id in saved levels is dropped (not resurrected as a node).
  local stale = progression_tree.load(defs(), { currency = CURRENCY, tier_mult = TIER_MULT }, {
    levels = { ghost = 3 },
  })
  check(stale.levels.ghost == nil, "an unknown saved node id is dropped")
  check(stale.node_by_id.ghost == nil, "the dropped id never becomes a real node")

  -- Missing fields keep fresh defaults.
  local fresh = progression_tree.load(defs(), { currency = CURRENCY, tier_mult = TIER_MULT }, nil)
  check(fresh.currency == 0, "load nil data: currency defaults to 0")
  check(fresh.lifetime == 0, "load nil data: lifetime defaults to 0")
  check(fresh.peak == 0, "load nil data: peak defaults to 0")
  check(fresh:level_of(ROOT) == 0, "load nil data: levels default to 0")
  local partial = progression_tree.load(defs(), { currency = CURRENCY, tier_mult = TIER_MULT }, {
    currency = 42,
  })
  check(partial.currency == 42, "partial load: provided field restored")
  check(partial.lifetime == 0, "partial load: missing field keeps the default")
end

print("all tests passed (" .. checks .. " checks)")
