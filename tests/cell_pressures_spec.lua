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
-- SINGLE-SOURCED through the closed-form cull (the live predator debit was retired --
-- on-screen predators are cosmetic), so the closed form carries the WHOLE predation
-- pressure. A first pass tripled these to compensate for the removed live kill and
-- overshot (feed/digestion builds collapsed in ~99s); retuned 2026-06-11 to a MODERATE
-- bump over the old lab-only floor/ramp: PRED_BASE 0.006 / PRED_RAMP 0.014 (mirrored
-- exactly from cell.lua + tools/sim_lab.lua). The determinism guards below are
-- magnitude-agnostic (they assert live==offline), so these just keep the mirror faithful;
-- the evasion-mitigation guard further down asserts the ramped magnitude behaves.
local COMP_FRAC_MAX, COMP_TAU, COMP_COUNTER_GAIN = 0.68, 42, 2.0
local COMP_MOTILITY_COUNTER = 0.05 -- share restored per Motility level (the dominant counter)
local PRED_BASE, PRED_RAMP, PRED_TAU, PRED_MAX = 0.006, 0.014, 42, 0.25
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

-- Competition counter + your_share, mirroring cell.lua intake_for. Motility is the
-- DOMINANT lever (COMP_MOTILITY_COUNTER restored per level); Chemotaxis and motility's
-- own forage gain help via forage_mult x COMP_COUNTER_GAIN. counter clamps to [0,1].
local function comp_counter(forage_mult, motility)
  local c = COMP_MOTILITY_COUNTER * (motility or 0) + (forage_mult - 1) * COMP_COUNTER_GAIN
  if c < 0 then
    return 0
  elseif c > 1 then
    return 1
  end
  return c
end
local function your_share(forage_mult, motility, age)
  return 1 / (1 + comp_frac(age) * (1 - comp_counter(forage_mult, motility)))
end

-- A bare PREDATION-ONLY intake provider: no income, just the age-keyed cull at the given
-- evasion (so the colony can only fall). Used by the evasion-mitigation guard to compare
-- how fast two builds are thinned by the SAME ramp at different evasion levels.
local function cull_only_provider(evasion)
  return function(state)
    return {
      mult = 1,
      upkeep_per_cell = 0,
      forage_per_cell = 0,
      photo = 0,
      pred_cull_frac = pred_pressure(state.age or 0) * evasion_mit(evasion),
    }
  end
end

-- An intake PROVIDER mirroring cell.lua intake_for: it reads state.age each call and
-- folds competition + predation-fear into the mult, forwarding pred_cull_frac for the
-- floorless cull. A modest forager (forage_mult), motility, and evasion let us exercise
-- the counter-gates without fully neutralising the pressures. Toxicity is also active
-- (tox_prod 0.5 > tox_clear) so all THREE pressures bite at once -- the required guard.
-- tox_clear defaults to 0.2 (waste outruns clearance -> the toxicity cull bites, used by
-- the death-spiral guard); the contested guard passes a higher clearance so toxicity
-- still accrues (stays > 0) but below the lethal tolerance, letting the colony survive
-- the ramped predation while all three pressures remain active.
local function make_provider(forage_mult, evasion, motility, tox_clear)
  tox_clear = tox_clear or 0.2
  return function(state)
    local age = state.age or 0
    local mult = 1
    mult = mult * your_share(forage_mult, motility, age)
    local pred_cull_frac = pred_pressure(age) * evasion_mit(evasion)
    local fear = 1 - PRED_FEAR * pred_cull_frac
    if fear < FEAR_FLOOR then
      fear = FEAR_FLOOR
    elseif fear > 1 then
      fear = 1
    end
    mult = mult * fear
    local upkeep = 2
    -- The compounding channel divides upkeep by the THROTTLED mult (mirroring cell.lua
    -- intake_for). Under the RAMPED predation a neglected build's fear term can drive
    -- mult to 0 (PRED_FEAR * pred_cull_frac >= 1), which would make upkeep/mult blow up
    -- to inf and, multiplied by a zeroed population, produce a NON-DETERMINISTIC nan
    -- (nan ~= nan would defeat the byte-identical guard even though both paths agree).
    -- Floor mult here purely to keep the synthetic income finite -- the colony is already
    -- spiralling to extinction at this point, so the floor changes no survival outcome.
    local mult_for_growth = math.max(mult, 1e-6)
    return {
      photo = 0,
      forage_per_cell = 6 * forage_mult,
      forage_cap = 6,
      upkeep_per_cell = upkeep,
      growth_per_cell = upkeep / mult_for_growth + 0.1, -- compounding channel, divided by the THROTTLED mult
      mult = mult,
      div_mult = 1,
      tox_prod = 0.5,
      tox_clear = tox_clear, -- < 0.5 -> waste still climbs; how far past tolerance is the lever
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

-- EVASION MITIGATES predation (the counter-gate). Derived from the constants, not magic
-- numbers: evasion_mit is the SURVIVING fraction the cull applies to, so more evasion ->
-- a smaller surviving fraction -> a smaller pred_cull_frac. A zero-evasion build takes the
-- full ramp; a maxed build is mitigated to (1 - PRED_MIT_CAP) but never to zero (stays
-- contested). Behaviourally: at the same age, a higher-evasion colony loses fewer cells.
do
  -- evasion_mit is monotonic decreasing in evasion and bounded by the cap.
  check(evasion_mit(0) == 1, "zero evasion takes the full cull (surviving fraction 1)")
  check(
    evasion_mit(0.05) < evasion_mit(0),
    "more evasion lowers the surviving fraction the cull applies to"
  )
  -- A maxed evasion build (shipped stat ~0.20) is capped, never fully immune.
  check(
    approx(evasion_mit(1.0), 1 - PRED_MIT_CAP),
    "max evasion is capped at PRED_MIT_CAP (still contested)"
  )
  check(evasion_mit(1.0) > 0, "even a maxed build stays slightly contested (never immune)")

  -- The cull fraction folds evasion in: at a fixed age, a higher-evasion build's
  -- pred_cull_frac is strictly smaller, so it thins the colony less.
  local age = PRED_TAU * 2 -- deep into the ramp where predation bites hardest
  local low_cull = pred_pressure(age) * evasion_mit(0.0)
  local high_cull = pred_pressure(age) * evasion_mit(0.10)
  check(high_cull < low_cull, "a high-evasion build's cull fraction is smaller at the same age")

  -- Behavioural end-to-end: same start, same age-keyed cull, higher evasion survives more.
  local weak = sim.new()
  weak.population = 400
  local strong = sim.new()
  strong.population = 400
  local weak_provider = cull_only_provider(0.0)
  local strong_provider = cull_only_provider(0.10)
  for _ = 1, 200 do
    sim.step(weak, 0.5, weak_provider(weak))
    sim.step(strong, 0.5, strong_provider(strong))
  end
  check(
    strong.population > weak.population,
    "evasion mitigates: a high-evasion colony outlives a low-evasion one under the same ramp"
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
  -- A countered build (forager + motility + evasion + extra cleanup): all three
  -- pressures bite (the colony is contested -- toxicity accrues, rivals throttle, the
  -- ramped predation culls) but the build is invested enough to SURVIVE rather than
  -- spiral, a non-trivial churning trajectory to match on. Motility > 0 exercises the
  -- competition counter term and evasion > 0 the predation counter-gate, in BOTH the
  -- live and offline paths, proving the age-keyed folds replay deterministically.
  local provider = make_provider(1.3, 0.16, 4, 0.47)

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
  check(
    live.population > 1,
    "the contested colony SURVIVES the ramped pressures (a churning, non-extinct trajectory)"
  )
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

-- ============================================================================
-- MOTILITY as the dominant competition counter. Behaviour, derived from the
-- constants (no magic share values): at the SAME forage_mult a mobile colony keeps
-- more food share than an immobile one, a fully-mobile colony shrugs the tax off
-- entirely, and an UNCOUNTERED colony still pays the full comp_frac crowding tax.
-- ============================================================================
do
  local age = COMP_TAU * 3 -- deep into the saturated ramp, where competition bites hardest

  -- Motility restores share the crowding tax took -- and more of it the more you level.
  local immobile = your_share(1.0, 0, age)
  local some = your_share(1.0, 3, age)
  local more = your_share(1.0, 6, age)
  check(some > immobile, "Motility restores food share the crowding tax took")
  check(more > some, "more Motility restores more share (monotonic in level)")

  -- A zero-counter colony eats the FULL crowding tax (share == 1/(1+comp_frac)).
  check(
    approx(immobile, 1 / (1 + comp_frac(age))),
    "an immobile non-forager pays the full comp_frac crowding tax"
  )

  -- Enough Motility fully neutralises the throttle: counter saturates at 1 -> share -> 1.
  check(comp_counter(1.0, 100) == 1, "high Motility saturates the counter at 1")
  check(approx(your_share(1.0, 100, age), 1), "a fully-mobile colony shrugs the tax off entirely")

  -- Motility is the DOMINANT lever: one level of it (even with no forage gain modeled)
  -- restores more share than a forage-only counter of equal nominal strength would at
  -- the matching forage lift -- i.e. its dedicated term adds on top of forage_mult.
  check(
    comp_counter(1.0, 1) > comp_counter(1.0, 0),
    "a Motility level counters crowding even before its forage gain is counted"
  )
end

print("all tests passed (" .. checks .. " checks)")
