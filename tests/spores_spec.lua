-- Standalone spec for the PHASE-1 spore dataset (lib/layers/cell/spores.lua) over the generic
-- prestige kernel (lib/engine/spore_tree.lua). Plain Lua 5.1, no framework. Run from the repo
-- root: lua tests/spores_spec.lua
--
-- Guards the two PURE folds the orchestrator depends on: spores.value() (the health x growth
-- value the kernel observes -- must be deterministic and monotonic so the banked peak means
-- something) and spores.fold() (node levels -> economy modifiers -- must be neutral until
-- spores are spent, so the prestige tree never silently buffs a fresh colony). Expectations
-- are derived from the source constants, never magic outputs.
local root = (arg and arg[0] or ""):match("^(.*)/tests/[^/]*$") or "."
package.path = root .. "/?.lua;" .. package.path

local spores = require("lib.layers.cell.spores")
local spore_tree = require("lib.engine.spore_tree")

local checks = 0
local function check(condition, label)
  checks = checks + 1
  if not condition then
    error("FAILED: " .. label, 2)
  end
end
local function approx(a, b) return math.abs(a - b) < 1e-9 end

local C = spores.constants

-- ============================================================================
-- spores.value(): determinism + monotonicity. Expectations come from the formula
-- value = EARN_K * pop^GROWTH_EXP * health * (1 + VITALITY_WEIGHT * max(net/pop, 0)),
-- with health = tox_half / (tox_half + toxicity) -- never from a baked number.
-- ============================================================================
do
  local consts = { tox_half = 10 }

  -- Deterministic: the same state yields an identical value twice (pure, no mutation).
  local s = { population = 100, toxicity = 5, net_rate = 20 }
  local v1 = spores.value(s, consts)
  local v2 = spores.value(s, consts)
  check(v1 == v2, "value() is deterministic for the same state")
  check(
    s.population == 100 and s.toxicity == 5 and s.net_rate == 20,
    "value() does not mutate state"
  )

  -- Higher population -> higher value (pop^GROWTH_EXP rises, GROWTH_EXP > 0).
  local small = spores.value({ population = 50, toxicity = 0, net_rate = 0 }, consts)
  local big = spores.value({ population = 500, toxicity = 0, net_rate = 0 }, consts)
  check(big > small, "more population -> higher value")

  -- Higher toxicity -> lower health -> lower value (all else equal).
  local clean = spores.value({ population = 100, toxicity = 0, net_rate = 0 }, consts)
  local fouled = spores.value({ population = 100, toxicity = 40, net_rate = 0 }, consts)
  check(fouled < clean, "more toxicity (lower health) -> lower value")

  -- A clean, still colony reduces to EARN_K * pop^GROWTH_EXP (health 1, vit 1).
  check(
    approx(clean, C.SPORE_EARN_K * 100 ^ C.SPORE_GROWTH_EXP),
    "clean, still colony equals EARN_K * pop^GROWTH_EXP"
  )

  -- A growing colony (positive net_rate) is worth strictly more than a still one of the
  -- same size, and a death-spiral (negative net_rate) is clamped to the still value (the
  -- vitality term can never DROP the value below the no-growth baseline).
  local still = spores.value({ population = 100, toxicity = 0, net_rate = 0 }, consts)
  local growing = spores.value({ population = 100, toxicity = 0, net_rate = 30 }, consts)
  local dying = spores.value({ population = 100, toxicity = 0, net_rate = -30 }, consts)
  check(growing > still, "positive net_rate raises value (vitality bonus)")
  check(approx(dying, still), "negative net_rate is clamped -- a death-spiral can't lower value")
  -- Exact vitality magnitude: vit = 1 + WEIGHT * net/pop -> value scales by that factor.
  check(
    approx(growing, still * (1 + C.SPORE_VITALITY_WEIGHT * (30 / 100))),
    "vitality factor is 1 + VITALITY_WEIGHT * net/pop"
  )
end

-- ============================================================================
-- spores.fold(): neutral at level 0. A fresh tree must leave the economy untouched.
-- ============================================================================
do
  local tree = spore_tree.load(spores.defs(), spores.tree_opts(), nil)
  local f = spores.fold(tree)
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
end

-- ============================================================================
-- spores.fold(): one effect at a time, derived from the per-level magnitude.
-- ============================================================================
do
  -- photo_eff at level 2 -> photo_mult = 1 + 2 * PHOTO_EFF_PER.
  local tree = spore_tree.load(spores.defs(), spores.tree_opts(), nil)
  tree.levels.photo_eff = 2
  local f = spores.fold(tree)
  check(
    approx(f.photo_mult, 1 + 2 * C.SPORE_PHOTO_EFF_PER),
    "photo_eff level 2 -> photo_mult == 1 + 2 * SPORE_PHOTO_EFF_PER"
  )

  -- mitosis (a division-cost CUT) drives div_mult below 1 -- exactly 1 - level * MITOSIS_PER.
  local tree2 = spore_tree.load(spores.defs(), spores.tree_opts(), nil)
  tree2.levels.mitosis = 3
  local f2 = spores.fold(tree2)
  check(f2.div_mult < 1, "mitosis makes division cheaper (div_mult < 1)")
  check(
    approx(f2.div_mult, 1 - 3 * C.SPORE_MITOSIS_PER),
    "mitosis level 3 -> div_mult == 1 - 3 * SPORE_MITOSIS_PER"
  )
end

-- ============================================================================
-- spores.fold(): the always-on lifetime bonus raises all_intake by
-- LIFETIME_BONUS * lifetime, independent of any node level.
-- ============================================================================
do
  local tree = spore_tree.load(spores.defs(), spores.tree_opts(), nil)
  local base = spores.fold(tree).all_intake
  tree.lifetime = 200
  local lifted = spores.fold(tree).all_intake
  check(
    approx(lifted - base, C.SPORE_LIFETIME_BONUS * 200),
    "lifetime bonus raises all_intake by SPORE_LIFETIME_BONUS * lifetime"
  )
end

print("all tests passed (" .. checks .. " checks)")
