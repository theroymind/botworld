-- Standalone spec for the PHASE-1 endospore dataset (lib/layers/cell/endospores.lua) over the generic
-- prestige core (lib/engine/progression_tree.lua). Plain Lua 5.1, no framework. Run from the repo
-- root: lua tests/endospores_spec.lua
--
-- Guards the two PURE folds the orchestrator depends on: endospores.value() (the health x growth
-- value the core observes -- must be deterministic and monotonic so the banked peak means
-- something) and endospores.fold() (node levels -> economy modifiers -- must be neutral until
-- endospores are spent, so the prestige tree never silently buffs a fresh colony). Expectations
-- are derived from the source constants, never magic outputs.
local root = (arg and arg[0] or ""):match("^(.*)/tests/[^/]*$") or "."
package.path = root .. "/?.lua;" .. package.path

local endospores = require("lib.layers.cell.endospores")
local progression_tree = require("lib.engine.progression_tree")

local checks = 0
local function check(condition, label)
  checks = checks + 1
  if not condition then
    error("FAILED: " .. label, 2)
  end
end
local function approx(a, b) return math.abs(a - b) < 1e-9 end

local C = endospores.constants

-- ============================================================================
-- endospores.value(): determinism + monotonicity. Expectations come from the formula
-- value = EARN_K * pop^GROWTH_EXP * health * (1 + VITALITY_WEIGHT * max(net/pop, 0)),
-- with health = tox_half / (tox_half + toxicity) -- never from a baked number.
-- ============================================================================
do
  local consts = { tox_half = 10 }

  -- Deterministic: the same state yields an identical value twice (pure, no mutation).
  local s = { population = 100, toxicity = 5, net_rate = 20 }
  local v1 = endospores.value(s, consts)
  local v2 = endospores.value(s, consts)
  check(v1 == v2, "value() is deterministic for the same state")
  check(
    s.population == 100 and s.toxicity == 5 and s.net_rate == 20,
    "value() does not mutate state"
  )

  -- Higher population -> higher value (pop^GROWTH_EXP rises, GROWTH_EXP > 0).
  local small = endospores.value({ population = 50, toxicity = 0, net_rate = 0 }, consts)
  local big = endospores.value({ population = 500, toxicity = 0, net_rate = 0 }, consts)
  check(big > small, "more population -> higher value")

  -- Higher toxicity -> lower health -> lower value (all else equal).
  local clean = endospores.value({ population = 100, toxicity = 0, net_rate = 0 }, consts)
  local fouled = endospores.value({ population = 100, toxicity = 40, net_rate = 0 }, consts)
  check(fouled < clean, "more toxicity (lower health) -> lower value")

  -- A clean, still colony reduces to EARN_K * pop^GROWTH_EXP (health 1, vit 1).
  check(
    approx(clean, C.ENDOSPORE_EARN_K * 100 ^ C.ENDOSPORE_GROWTH_EXP),
    "clean, still colony equals EARN_K * pop^GROWTH_EXP"
  )

  -- A growing colony (positive net_rate) is worth strictly more than a still one of the
  -- same size, and a death-spiral (negative net_rate) is clamped to the still value (the
  -- vitality term can never DROP the value below the no-growth baseline).
  local still = endospores.value({ population = 100, toxicity = 0, net_rate = 0 }, consts)
  local growing = endospores.value({ population = 100, toxicity = 0, net_rate = 30 }, consts)
  local dying = endospores.value({ population = 100, toxicity = 0, net_rate = -30 }, consts)
  check(growing > still, "positive net_rate raises value (vitality bonus)")
  check(approx(dying, still), "negative net_rate is clamped -- a death-spiral can't lower value")
  -- Exact vitality magnitude: vit = 1 + WEIGHT * net/pop -> value scales by that factor.
  check(
    approx(growing, still * (1 + C.ENDOSPORE_VITALITY_WEIGHT * (30 / 100))),
    "vitality factor is 1 + VITALITY_WEIGHT * net/pop"
  )
end

-- ============================================================================
-- endospores.fold(): neutral at level 0. A fresh tree must leave the economy untouched.
-- ============================================================================
do
  local tree = progression_tree.load(endospores.defs(), endospores.tree_opts(), nil)
  local f = endospores.fold(tree)
  check(f.photo_mult == 1, "fresh: photo_mult neutral (1)")
  check(f.forage_mult == 1, "fresh: forage_mult neutral (1)")
  check(f.all_intake == 1, "fresh: all_intake neutral (1)")
  check(f.div_mult == 1, "fresh: div_mult neutral (1)")
  check(f.cleanup == 0, "fresh: cleanup neutral (0)")
  check(f.evasion_add == 0, "fresh: evasion_add neutral (0)")
  check(f.comp_counter == 0, "fresh: comp_counter neutral (0)")
  check(f.pressure_damp == 0, "fresh: pressure_damp neutral (0)")
  check(f.endo_chance_add == 0, "fresh: endo_chance_add neutral (0)")
  check(f.sense_bonus == 0, "fresh: sense_bonus neutral (0)")
  check(f.engulf_progress == 0, "fresh: engulf_progress neutral (0)")
end

-- ============================================================================
-- endospores.fold(): the two now-CONSUMED terms rise with their node levels. sense_bonus
-- (the chemo node) is wired into the cell layer's competition counter; engulf_progress
-- (the Engulf node) is the per-engulf burst multiplier. Both must scale linearly with
-- level off their source per-level magnitudes.
-- ============================================================================
do
  -- chemo node -> sense_bonus = level * ENDOSPORE_CHEMO_PER (consumed by the competition counter).
  local tree = progression_tree.load(endospores.defs(), endospores.tree_opts(), nil)
  tree.levels.chemo = 3
  check(
    approx(endospores.fold(tree).sense_bonus, 3 * C.ENDOSPORE_CHEMO_PER),
    "chemo level 3 -> sense_bonus == 3 * ENDOSPORE_CHEMO_PER"
  )

  -- Engulf node -> engulf_progress = level * ENDOSPORE_ENGULF_PROGRESS_PER (the per-engulf burst).
  local tree2 = progression_tree.load(endospores.defs(), endospores.tree_opts(), nil)
  tree2.levels.engulf = 4
  check(
    approx(endospores.fold(tree2).engulf_progress, 4 * C.ENDOSPORE_ENGULF_PROGRESS_PER),
    "engulf level 4 -> engulf_progress == 4 * ENDOSPORE_ENGULF_PROGRESS_PER"
  )
end

-- ============================================================================
-- endospores.capabilities(): the bridge mapping tree state -> the milestone gates the
-- orchestrator reads. Gates on level_of(id) >= 1 (BOUGHT), and unlock_income is the
-- flat-on-unlock multiplier (1 + PHOTO_INCOME + ENGULF_INCOME), derived from the source
-- constants -- never magic numbers.
-- ============================================================================
do
  -- Fresh tree: no capability bought.
  local tree = progression_tree.load(endospores.defs(), endospores.tree_opts(), nil)
  local caps = endospores.capabilities(tree)
  check(caps.photosynthesis == false, "fresh: photosynthesis capability off")
  check(caps.predation == false, "fresh: phagocytosis capability off")
  check(approx(caps.unlock_income, 1), "fresh: unlock_income neutral (1)")

  -- Root bought (level 1): photosynthesis on, +PHOTO_INCOME; phagocytosis still off.
  tree.levels.photosynthesis = 1
  caps = endospores.capabilities(tree)
  check(caps.photosynthesis == true, "root bought: photosynthesis capability on")
  check(caps.predation == false, "root bought: phagocytosis still off")
  check(
    approx(caps.unlock_income, 1 + C.PHOTO_INCOME),
    "root bought: unlock_income == 1 + PHOTO_INCOME"
  )

  -- Engulf level 1 (with the root bought): phagocytosis on, +ENGULF_INCOME on top of photo.
  tree.levels.engulf = 1
  caps = endospores.capabilities(tree)
  check(caps.predation == true, "engulf L1: phagocytosis capability on")
  check(
    approx(caps.unlock_income, 1 + C.PHOTO_INCOME + C.ENGULF_INCOME),
    "engulf L1 (root bought): unlock_income == 1 + PHOTO_INCOME + ENGULF_INCOME"
  )
end

-- ============================================================================
-- endospores.fold(): one effect at a time, derived from the per-level magnitude.
-- ============================================================================
do
  -- photo_eff at level 2 -> photo_mult = 1 + 2 * PHOTO_EFF_PER.
  local tree = progression_tree.load(endospores.defs(), endospores.tree_opts(), nil)
  tree.levels.photo_eff = 2
  local f = endospores.fold(tree)
  check(
    approx(f.photo_mult, 1 + 2 * C.ENDOSPORE_PHOTO_EFF_PER),
    "photo_eff level 2 -> photo_mult == 1 + 2 * ENDOSPORE_PHOTO_EFF_PER"
  )

  -- mitosis (a division-cost CUT) drives div_mult below 1 -- exactly 1 - level * MITOSIS_PER.
  local tree2 = progression_tree.load(endospores.defs(), endospores.tree_opts(), nil)
  tree2.levels.mitosis = 3
  local f2 = endospores.fold(tree2)
  check(f2.div_mult < 1, "mitosis makes division cheaper (div_mult < 1)")
  check(
    approx(f2.div_mult, 1 - 3 * C.ENDOSPORE_MITOSIS_PER),
    "mitosis level 3 -> div_mult == 1 - 3 * ENDOSPORE_MITOSIS_PER"
  )
end

-- ============================================================================
-- endospores.fold(): the always-on lifetime bonus raises all_intake by
-- LIFETIME_BONUS * lifetime, independent of any node level.
-- ============================================================================
do
  local tree = progression_tree.load(endospores.defs(), endospores.tree_opts(), nil)
  local base = endospores.fold(tree).all_intake
  tree.lifetime = 200
  local lifted = endospores.fold(tree).all_intake
  check(
    approx(lifted - base, C.ENDOSPORE_LIFETIME_BONUS * 200),
    "lifetime bonus raises all_intake by ENDOSPORE_LIFETIME_BONUS * lifetime"
  )
end

-- ============================================================================
-- ORCHESTRATOR SAVE ROUND-TRIP: exercise the exact call forms cell.lua's persist()
-- and cell.load() use against the REAL phase defs/opts -- tree:serialize() (an
-- instance method) into progression_tree.load(endospores.defs(), endospores.tree_opts(), data) (a
-- module function). This guards the call CONVENTION the core spec can't: serialize
-- is a method and load is a module fn, so a module-style progression_tree.serialize(...)
-- call is nil (the crash this regression locks out).
-- ============================================================================
do
  -- serialize lives ONLY on the instance (the metatable), never on the module -- so
  -- the orchestrator MUST call it as a method. Pin both halves so a future module-style
  -- call is caught here, not at runtime.
  check(
    progression_tree.serialize == nil,
    "serialize is not a module function (instance method only)"
  )
  check(type(progression_tree.load) == "function", "load IS a module function")

  -- Round-trip a non-trivial tree through persist()'s shape: buy a node, bank a peak,
  -- serialize, reload via the real defs/opts, and confirm every mutable field returns.
  local tree = progression_tree.load(endospores.defs(), endospores.tree_opts(), nil)
  tree.currency = 50
  check(tree:buy("photosynthesis"), "can buy the root with currency on hand")
  tree:observe(123.4)
  local data = tree:serialize() -- the exact call persist() makes
  check(type(data) == "table", "serialize() returns a plain table")
  local loaded = progression_tree.load(endospores.defs(), endospores.tree_opts(), data) -- the cell.load() call
  check(loaded:currency_amount() == tree:currency_amount(), "round-trip currency via real opts")
  check(loaded.peak == tree.peak, "round-trip peak via real opts")
  check(
    loaded:level_of("photosynthesis") == tree:level_of("photosynthesis"),
    "round-trip a bought node's level via real defs"
  )
end

print("all tests passed (" .. checks .. " checks)")
