-- Standalone spec for the THREE-PRESSURE failure model ported from the lab harness
-- (tools/sim_lab.lua) into the shipped cell economy (lib/layers/cell/sim.lua, folded
-- by lib/layers/cell.lua intake_for). Plain Lua 5.1, no framework. Run from the repo
-- root: lua tests/cell_pressures_spec.lua
--
-- The load-bearing invariant here is OFFLINE DETERMINISM: the economy is a
-- deterministic closed form, and sim.offline replays the same sim.step in sub-steps,
-- so N live sim.steps of dt must equal ONE sim.offline of the same total duration --
-- now even with the AGE-keyed competition + predation ramps and the floorless
-- predation cull active. This guard pins that invariant; if a future change makes
-- offline diverge from live the colony you return to would not match the one you
-- left, which is the whole determinism contract.
local root = (arg and arg[0] or ""):match("^(.*)/tests/[^/]*$") or "."
package.path = root .. "/?.lua;" .. package.path

local sim = require("lib.layers.cell.sim")

local checks = 0
local function check(condition, label)
  checks = checks + 1
  if not condition then
    error("FAILED: " .. label, 2)
  end
end
local function approx(a, b) return math.abs(a - b) < 1e-9 end

-- The lab's locked pressure constants (mirrored in cell.lua). Kept here so the test
-- exercises the SAME age-keyed ramps the real intake fold builds, independent of the
-- love-dependent cell.lua module (which can't load headless).
-- Retuned 2026-06-08 (mirrored from cell.lua + tools/sim_lab.lua): competition ceiling
-- 0.6->0.68 / TAU 50->42, predation ramp 0.008->0.010 / TAU 50->42. The determinism
-- guards below are magnitude-agnostic (they assert live==offline), so these just keep
-- the mirror faithful.
local COMP_FRAC_MAX, COMP_TAU, COMP_COUNTER_GAIN = 0.68, 42, 2.0
local PRED_BASE, PRED_RAMP, PRED_TAU, PRED_MAX = 0.004, 0.010, 42, 0.25
local PRED_EVASION_GAIN, PRED_MIT_CAP, PRED_FEAR, FEAR_FLOOR = 8.0, 0.97, 8.0, 0.0

local function comp_frac(age) return COMP_FRAC_MAX * (1 - math.exp(-(age or 0) / COMP_TAU)) end
local function pred_pressure(age)
  local p = PRED_BASE + PRED_RAMP * (math.max(age or 0, 0) / PRED_TAU)
  if p > PRED_MAX then
    p = PRED_MAX
  end
  return p
end
local function evasion_mit(evasion)
  local m = (evasion or 0) * PRED_EVASION_GAIN
  if m > PRED_MIT_CAP then
    m = PRED_MIT_CAP
  end
  return 1 - m
end

-- An intake PROVIDER mirroring cell.lua intake_for: it reads state.age each call and
-- folds competition + predation-fear into the mult, forwarding pred_cull_frac for the
-- floorless cull. A modest forager (forage_mult) and evasion let us exercise the
-- counter-gates without fully neutralising the pressures. Toxicity is also active
-- (tox_prod > tox_clear) so all THREE pressures bite at once -- the required guard.
local function make_provider(forage_mult, evasion)
  return function(state)
    local age = state.age or 0
    local mult = 1
    local counter = (forage_mult - 1) * COMP_COUNTER_GAIN
    if counter < 0 then
      counter = 0
    elseif counter > 1 then
      counter = 1
    end
    mult = mult * (1 / (1 + comp_frac(age) * (1 - counter)))
    local pred_cull_frac = pred_pressure(age) * evasion_mit(evasion)
    local fear = 1 - PRED_FEAR * pred_cull_frac
    if fear < FEAR_FLOOR then
      fear = FEAR_FLOOR
    elseif fear > 1 then
      fear = 1
    end
    mult = mult * fear
    local upkeep = 2
    return {
      photo = 0,
      forage_per_cell = 6 * forage_mult,
      forage_cap = 6,
      upkeep_per_cell = upkeep,
      growth_per_cell = upkeep / mult + 0.1, -- compounding channel, divided by the THROTTLED mult
      mult = mult,
      div_mult = 1,
      tox_prod = 0.5,
      tox_clear = 0.2, -- production > clearance -> waste climbs past tolerance -> the cull bites
      tox_half = 10,
      tox_tolerance = 26,
      tox_kill_k = 0.005,
      pred_cull_frac = pred_cull_frac,
    }
  end
end

-- AGE clock: fresh state starts at 0; sim.step advances it by dt; serialize/load
-- round-trip it (so the ramps replay from where the live run left off).
do
  local s = sim.new()
  check(s.age == 0, "fresh state.age is 0")
  check(s.net_rate == 0, "fresh state.net_rate is 0")
  sim.step(s, 0.5, { mult = 1, upkeep_per_cell = 0 })
  check(approx(s.age, 0.5), "sim.step advances state.age by dt")
  sim.step(s, 0.5, { mult = 1, upkeep_per_cell = 0 })
  check(approx(s.age, 1.0), "age accumulates across steps")
  local loaded = sim.load(sim.serialize(s))
  check(approx(loaded.age, 1.0), "serialize/load round-trips age")
  check(sim.load({}).age == 0, "load defaults age to 0")
  local n = sim.load({ net_rate = -3.5 })
  check(approx(n.net_rate, -3.5), "load round-trips a negative net_rate (a dying colony)")
end

-- Predation cull: a pred_cull_frac thins the colony with NO floor at 1 (extinction
-- allowed), unlike ordinary starvation. Absent the field the cull is inert.
do
  local inert = sim.new()
  inert.population = 50
  for _ = 1, 200 do
    sim.step(inert, 0.5, { mult = 1, upkeep_per_cell = 0, forage_per_cell = 0, photo = 0 })
  end
  check(inert.population == 50, "no pred_cull_frac -> predation cull is inert (population held)")

  local culled = sim.new()
  culled.population = 50
  -- A pure cull intake: no income, just predation, so it can only fall.
  for _ = 1, 400 do
    sim.step(
      culled,
      0.5,
      { mult = 1, upkeep_per_cell = 0, forage_per_cell = 0, photo = 0, pred_cull_frac = 0.05 }
    )
  end
  check(
    culled.population == 0,
    "a relentless predation cull drives the colony to literal extinction (no floor at 1)"
  )
end

-- net_rate tracks births minus all deaths: positive while a fed colony grows.
do
  local g = sim.new()
  for _ = 1, 400 do
    sim.step(
      g,
      0.5,
      { mult = 1, forage_per_cell = 6, forage_cap = 1000, upkeep_per_cell = 2, growth_per_cell = 2 }
    )
  end
  check(g.net_rate > 0, "net_rate is positive while a growing colony out-births its deaths")
end

-- ============================================================================
-- THE OFFLINE-DETERMINISM GUARD (the load-bearing invariant).
-- Run N live sim.steps of dt vs ONE sim.offline of the same total duration, with
-- ALL THREE pressures active (toxicity + competition + predation). They must land
-- on byte-identical state: population, energy, biomass, age, toxicity.
-- ============================================================================
local function assert_identical(a, b, label)
  check(a.population == b.population, label .. ": population identical")
  check(a.energy == b.energy, label .. ": energy identical")
  check(a.biomass == b.biomass, label .. ": biomass identical")
  check(a.age == b.age, label .. ": age identical")
  check(a.toxicity == b.toxicity, label .. ": toxicity identical")
  check(a.total_divisions == b.total_divisions, label .. ": total_divisions identical")
end

-- sim.offline targets OFFLINE_DT = 2s sub-steps and caps the count. For an exact
-- live/offline match we mirror its sub-step arithmetic: choose a total duration whose
-- ceil(T/2) sub-steps divide T evenly, then drive the live sim with that exact dt.
do
  -- A modest forager + low evasion: pressures bite (the colony is contested) but it
  -- still grows for a while -- a non-trivial, churning trajectory to match on.
  local provider = make_provider(1.2, 0.05)

  -- T = 600s -> ceil(600/2) = 300 sub-steps -> dt = 2.0 exactly.
  local total = 600
  local nsub = math.ceil(total / 2) -- mirrors sim.offline's OFFLINE_DT=2 sub-step count
  local dt = total / nsub

  local live = sim.new()
  live.population = 8 -- seed a small colony so the cull/competition have cells to act on
  for _ = 1, nsub do
    sim.step(live, dt, provider(live))
  end

  local off = sim.new()
  off.population = 8
  sim.offline(off, total, provider)

  assert_identical(live, off, "three-pressure live vs offline (contested)")
  check(live.age > 0 and live.toxicity > 0, "the guard is non-trivial (age + toxicity advanced)")
end

-- A second guard with the UNEVADED death-spiral: zero evasion + weak forage, so the
-- colony actually dies out. Live and offline must agree on the extinction path too.
do
  local provider = make_provider(1.0, 0.0)
  local total = 400
  local nsub = math.ceil(total / 2)
  local dt = total / nsub

  local live = sim.new()
  live.population = 12
  for _ = 1, nsub do
    sim.step(live, dt, provider(live))
  end
  local off = sim.new()
  off.population = 12
  sim.offline(off, total, provider)

  assert_identical(live, off, "three-pressure live vs offline (death-spiral)")
  check(live.population < 12, "the death-spiral guard is non-trivial (the colony declined)")
end

-- Backward-compat: sim.offline still accepts a PLAIN TABLE (the legacy/complexcell
-- form) and replays it statically -- identical to N live steps with the same table.
do
  local I = { mult = 1, forage_per_cell = 6, forage_cap = 6, upkeep_per_cell = 2 }
  local total = 600
  local nsub = math.ceil(total / 2)
  local dt = total / nsub
  local live = sim.new()
  for _ = 1, nsub do
    sim.step(live, dt, I)
  end
  local off = sim.new()
  sim.offline(off, total, I)
  check(
    live.population == off.population,
    "plain-table offline still matches live (backward compatible)"
  )
  check(live.age == off.age, "plain-table offline advances age identically")
end

print("all tests passed (" .. checks .. " checks)")
