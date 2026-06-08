-- Standalone spec for lib/layers/cell/traits.lua.
-- Plain Lua 5.1, no framework. Run from the repo root: lua tests/traits_spec.lua
local root = (arg and arg[0] or ""):match("^(.*)/tests/[^/]*$") or "."
package.path = root .. "/?.lua;" .. package.path

local traits = require("lib.layers.cell.traits")

local checks = 0

local function check(condition, label)
  checks = checks + 1
  if not condition then
    error("FAILED: " .. label, 2)
  end
end

local function approx(a, b)
  return math.abs(a - b) < 1e-9
end

-- Fresh state: every trait at level 0, nothing unlocked.
local t = traits.new()
check(t.levels.photosynthesis == 0, "fresh photosynthesis level 0")
check(t.levels.evasion == 0, "fresh evasion level 0")
check(next(t.unlocked) == nil, "fresh unlocked set empty")

-- Neutral stats at all-zero: multipliers 1, bases at founder values, evasion 0.
local s0 = traits.stats(t)
check(approx(s0.photo_mult, 1), "neutral photo multiplier")
check(approx(s0.forage_mult, 1), "neutral forage multiplier")
check(approx(s0.feed_rate, 1), "neutral feed rate")
check(approx(s0.div_mult, 1), "neutral division-cost multiplier")
check(approx(s0.upkeep_mult, 1), "neutral upkeep multiplier")
check(approx(s0.evasion, 0), "zero evasion at level 0")
check(s0.speed > 0, "founder swim speed positive")
check(s0.sense_range > 0, "founder sense range positive")

-- Each trait moves exactly its own stat.
t = traits.new()
traits.level(t, "photosynthesis")
check(approx(traits.stats(t).photo_mult, 1.18), "one photosynthesis level -> +18% gain")

t = traits.new()
traits.level(t, "motility")
local base_speed = traits.stats(traits.new()).speed
check(approx(traits.stats(t).speed, base_speed * 1.25), "one motility level -> +25% speed")
check(approx(traits.stats(t).forage_mult, 1.08), "one motility level -> +8% forage (now a real economic lever)")

t = traits.new()
traits.level(t, "sensing")
local base_sense = traits.stats(traits.new()).sense_range
check(approx(traits.stats(t).sense_range, base_sense + 14), "one sensing level -> +14 range")

t = traits.new()
traits.level(t, "digestion")
check(approx(traits.stats(t).div_mult, 0.92), "one digestion level -> divisions cost 8% less")
check(traits.stats(t).feed_rate > 1, "digestion also speeds the (cosmetic) engulf")
traits.level(t, "digestion")
check(approx(traits.stats(t).div_mult, 0.92 * 0.92), "the division discount compounds per level")
check(traits.stats(t).div_mult > 0, "the division cost never reaches zero")

-- Evasion: the flee/dodge chance is bounded [0,1) and diminishing; upkeep shrinks.
t = traits.new()
for _ = 1, 5 do
  traits.level(t, "evasion")
end
local m5 = traits.stats(t)
check(approx(m5.evasion, 1 - 1 / (1 + 5 * 0.05)), "evasion uses the diminishing formula")
check(m5.evasion > 0 and m5.evasion < 1, "evasion stays inside [0,1)")
check(m5.upkeep_mult < 1, "evasion shrinks upkeep")
-- More levels never reach full immunity.
for _ = 1, 1000 do
  traits.level(t, "evasion")
end
check(traits.stats(t).evasion < 1, "evasion never reaches full immunity")

-- Waste clearance (cleanup): a bare founder has a positive floor, and the three
-- cleanup traits (digestion, evasion, photosynthesis) each raise it -- this is the
-- survival lever the toxicity failure pressure is balanced against.
t = traits.new()
local clean0 = traits.stats(t).cleanup
check(clean0 > 0, "founder has a positive baseline waste clearance")
t = traits.new()
traits.level(t, "digestion")
check(traits.stats(t).cleanup > clean0, "digestion raises clearance (the primary cleanup trait)")
t = traits.new()
traits.level(t, "evasion")
check(traits.stats(t).cleanup > clean0, "evasion raises clearance (a lean metabolism)")
t = traits.new()
traits.level(t, "photosynthesis")
check(traits.stats(t).cleanup > clean0, "photosynthesis raises clearance (oxygenation)")
-- Digestion is the strongest single cleanup lever.
local dig1 = traits.new()
traits.level(dig1, "digestion")
local eva1 = traits.new()
traits.level(eva1, "evasion")
check(
  traits.stats(dig1).cleanup >= traits.stats(eva1).cleanup,
  "digestion clears at least as much as evasion per level (the primary lever)"
)

-- Per-trait cost is geometric and independent across rows.
t = traits.new()
local photo_base = traits.cost(t, "photosynthesis")
check(photo_base == 10, "photosynthesis base cost")
traits.level(t, "photosynthesis")
check(traits.cost(t, "photosynthesis") == math.ceil(10 * 1.5), "cost rises after a level")
check(traits.cost(t, "motility") == 8, "leveling one trait does not raise another's cost")

-- Unknown id is rejected and costs infinity (unaffordable).
check(not traits.level(t, "nonsense"), "unknown trait rejected")
check(traits.cost(t, "nonsense") == math.huge, "unknown trait costs infinity")

-- Hints are concrete strings.
check(traits.hint("evasion") == "evade +5%, clears waste", "evasion hint reads concretely")

-- Photosynthesis row is locked until its milestone fires; others are free.
t = traits.new()
check(not traits.is_available(t, "photosynthesis"), "photosynthesis locked at start")
check(traits.is_available(t, "motility"), "motility available at start")

-- Unlocks: fire by id, flip is_unlocked, raise income, advance next_unlock.
t = traits.new()
check(not traits.is_unlocked(t, "photosynthesis"), "photosynthesis unlock starts off")
check(approx(traits.income_mult(t), 1), "no income channels before any unlock")
local first = traits.next_unlock(t)
check(first.id == "photosynthesis", "photosynthesis is the first milestone")
check(first.pop > 0, "milestone carries a colony threshold")

local fired = traits.unlock(t, "photosynthesis")
check(fired and fired.id == "photosynthesis", "unlock returns the def on first fire")
check(traits.is_unlocked(t, "photosynthesis"), "unlock flips is_unlocked")
check(traits.is_available(t, "photosynthesis"), "photosynthesis row available after unlock")
check(traits.income_mult(t) > 1, "unlocking opens an income channel")
check(traits.unlock(t, "photosynthesis") == nil, "re-firing a unlock is a no-op")
check(traits.next_unlock(t).id == "predation", "next milestone advances to predation")

-- Predation is the income + world-contents milestone.
traits.unlock(t, "predation")
check(traits.next_unlock(t) == nil, "no milestones left once both fire")
local pred = nil
for _, def in ipairs(traits.unlocks()) do
  if def.id == "predation" then
    pred = def
  end
end
check(pred.spawns_prey and pred.enables_predators, "predation spawns prey and enables predators")

-- Serialize -> load round-trip preserves levels and unlocks.
t = traits.new()
traits.level(t, "photosynthesis")
traits.level(t, "photosynthesis")
traits.level(t, "evasion")
traits.unlock(t, "photosynthesis")
local loaded = traits.load(traits.serialize(t))
check(loaded.levels.photosynthesis == 2, "round-trip trait level")
check(loaded.levels.evasion == 1, "round-trip second trait level")
check(traits.is_unlocked(loaded, "photosynthesis"), "round-trip unlock")
check(approx(traits.stats(loaded).photo_mult, traits.stats(t).photo_mult), "round-trip stats")

-- Legacy migration: an old save's "membrane" level loads as "evasion".
local migrated = traits.load({ levels = { membrane = 3 } })
check(migrated.levels.evasion == 3, "legacy membrane level migrates to evasion")
check(migrated.levels.membrane == nil, "the old membrane key is not retained")

-- Load tolerates missing, partial, and stale data.
local fresh = traits.load(nil)
check(fresh.levels.photosynthesis == 0, "load nil: fresh levels")
check(next(fresh.unlocked) == nil, "load nil: nothing unlocked")
local stale = traits.load({
  levels = { photosynthesis = 3, ghost_trait = 9 },
  unlocked = { predation = true, ghost_unlock = true },
})
check(stale.levels.photosynthesis == 3, "stale load: known level kept")
check(stale.levels.motility == 0, "stale load: missing level defaults to 0")
check(traits.is_unlocked(stale, "predation"), "stale load: known unlock kept")
check(stale.unlocked.ghost_unlock == nil, "stale load: unknown unlock dropped")

print("all tests passed (" .. checks .. " checks)")
