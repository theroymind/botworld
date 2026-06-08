-- Standalone spec for lib/layers/cell/sim.lua (the INVERTED economy).
-- Plain Lua 5.1, no framework. Run from the repo root: lua tests/cell_sim_spec.lua
--
-- The economy no longer accrues biomass passively. An ENERGY reserve folds from
-- the colony's intake (photosynthesis light + per-cell foraging, saturating at a
-- finite food supply) minus per-cell upkeep; divisions MINT banked biomass and
-- climb the population; a negative reserve STARVES cells (population falls, biomass
-- kept, floored at 1). tick and offline share one step(state, dt, intake).
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

local function approx(a, b)
  return math.abs(a - b) < 1e-9
end

-- A folded intake table. Defaults give a tidy carrying capacity of
-- (photo + forage*cap)*mult / upkeep = (0 + 6*6)*1/2 = 18, with each below-cap
-- cell netting forage*mult - upkeep = 4 energy/sec. Override any field per test.
-- (Lua treats 0 as truthy, so `o.x or default` still honours an explicit 0.)
local function intake(o)
  o = o or {}
  return {
    photo = o.photo or 0,
    forage_per_cell = o.forage_per_cell or 6,
    forage_cap = o.forage_cap or 6,
    upkeep_per_cell = o.upkeep_per_cell or 2,
    mult = o.mult or 1,
    -- Toxicity model fields (optional; absent by default so the pre-toxicity specs
    -- stay inert). Forwarded only when a test supplies them.
    tox_prod = o.tox_prod,
    tox_clear = o.tox_clear,
    tox_half = o.tox_half,
  }
end

-- Fresh state: founder present, reserve empty, banked currency empty, no division
-- history, no organelles, and none of the old evolve/maturity/lifetime fields.
local s = sim.new()
check(s.biomass == 0, "fresh biomass 0")
check(s.energy == 0, "fresh energy 0")
check(s.population == 1, "fresh population is 1 (the founder)")
check(s.total_divisions == 0, "fresh total_divisions 0")
check(s.pending_divisions == 0, "fresh pending_divisions 0")
check(type(s.organelles) == "table" and next(s.organelles) == nil, "fresh organelles set is empty")
check(s.lifetime == nil, "no lifetime field (passive accrual is gone)")
check(s.maturity == nil, "no maturity field (the evolve gate is gone)")
check(s.evolve_mult == nil and s.generation == nil, "no evolve/generation fields")

-- div_bounds: floor is the asymptotic base minimum; ceiling is the founder's
-- slow-started maximum. With the defaults the band is (8, 112).
local MIN_SP, MAX_SP = sim.div_bounds()
check(MIN_SP == 8, "div_bounds min is DIV_BASE (8)")
check(approx(MAX_SP, 112), "div_bounds max is the slow-started first-division ceiling (112)")

-- Determinism: no rng in the economy (division-cost jitter is a pure index hash),
-- so two identically-stepped sims stay bit-identical in population AND biomass.
do
  local d1, d2 = sim.new(), sim.new()
  local I = intake()
  for _ = 1, 3000 do
    sim.step(d1, 0.1, I)
    sim.step(d2, 0.1, I)
  end
  check(d1.population == d2.population, "identical steps -> identical population (deterministic)")
  check(d1.biomass == d2.biomass, "identical steps -> identical biomass")
  check(d1.population > 1, "the determinism check is non-trivial (the sims grew)")
end

-- step folds (photo + forage*min(P,cap))*mult - upkeep*P into the reserve. At the
-- founder this is 6 - 2 = 4/sec; 4 is far below the first division cost (~97), so
-- the reserve just banks energy with no mint yet.
s = sim.new()
sim.step(s, 1, intake())
check(approx(s.energy, 4), "step folds the intake rate into the energy reserve")
check(s.population == 1, "a small reserve mints no divisions")
check(s.biomass == 0, "no division -> no minted biomass")

-- A division MINTS banked biomass and counts toward total_divisions. Force exactly
-- one division from the reserve to read the per-division yield.
local one = sim.new()
one.energy = sim.div_cost(1) + 0.001
sim.step(one, 0, intake())
check(one.population == 2, "the reserve covering one division cost mints exactly one cell")
check(one.total_divisions == 1, "a division counts toward total_divisions")
check(one.pending_divisions == 1, "a division queues a view pulse")
local DIV_YIELD = one.biomass
check(DIV_YIELD > 0, "each division mints a positive chunk of banked biomass")

-- Many divisions from a big reserve: biomass == divisions * DIV_YIELD, the
-- leftover reserve sits below the next cost, and biomass is a PURE bank (no rate).
s = sim.new()
sim.feed_burst(s, 400)
sim.step(s, 0, intake())
check(s.population > 2, "a large reserve mints several divisions")
check(s.total_divisions == s.population - 1, "every division past the founder is counted")
check(approx(s.biomass, s.total_divisions * DIV_YIELD), "minted biomass == divisions * DIV_YIELD")
check(s.energy >= 0 and s.energy < sim.div_cost(s.population), "leftover reserve is below the next division cost")

-- div_mult (the digestion discount) cheapens every division: the cost readout
-- scales by it, the same reserve mints MORE cells, and the rate readout rises.
check(approx(sim.div_cost(1, 0.5), sim.div_cost(1) * 0.5), "div_cost scales by div_mult")
local cheap = sim.new()
sim.feed_burst(cheap, 400)
local cheap_intake = intake()
cheap_intake.div_mult = 0.5
sim.step(cheap, 0, cheap_intake)
local full = sim.new()
sim.feed_burst(full, 400)
sim.step(full, 0, intake())
check(cheap.population > full.population, "a div_mult < 1 mints more cells from the same reserve")
check(
  sim.division_rate(cheap_intake, 10) > sim.division_rate(intake(), 10),
  "division_rate rises with the digestion discount"
)

-- feed_burst credits the energy reserve (a nutrient-bloom click); negatives clamp.
s = sim.new()
local credited = sim.feed_burst(s, 50)
check(approx(credited, 50), "feed_burst returns the credited amount")
check(approx(s.energy, 50), "feed_burst adds to the energy reserve")
check(s.biomass == 0, "feed_burst alone mints no biomass (no step yet)")
check(sim.feed_burst(s, -10) == 0, "feed_burst clamps negatives to zero")
check(approx(s.energy, 50), "a clamped feed credits nothing")

-- feed -> step -> divisions -> banked biomass: the active loop.
s = sim.new()
sim.feed_burst(s, 150)
local pop0, bm0 = s.population, s.biomass
sim.step(s, 1 / 30, intake())
check(s.population > pop0, "fed energy converts into divisions")
check(s.biomass > bm0, "those divisions mint banked biomass")

-- TOXICITY / health (the failure pressure). With NO tox fields the system is inert
-- (toxicity stays 0, health is 1), so the bare intake above behaves exactly as the
-- pre-toxicity economy -- the specs that came before are unaffected.
check(approx(sim.health(0, 14), 1), "health is 1 in a clean dish (toxicity 0)")
check(approx(sim.health(14, 14), 0.5), "health is 0.5 at tox_half")
check(sim.health(100, 14) < 0.2, "health collapses toward 0 as waste piles up")
check(approx(sim.health(50, nil), 1), "no tox_half -> health 1 (model off)")
do
  local inert = sim.new()
  for _ = 1, 50 do
    sim.step(inert, 0.1, intake()) -- intake() has no tox_prod/tox_clear
  end
  check(inert.toxicity == 0, "intake without a tox model never accrues toxicity")
end
-- tox_prod beyond tox_clear makes waste climb; clearance >= production holds at 0.
do
  local fouling = sim.new()
  local I = intake({ tox_prod = 1, tox_clear = 0.2, tox_half = 14 })
  for _ = 1, 50 do
    sim.step(fouling, 0.1, I)
  end
  check(fouling.toxicity > 0, "production above clearance accrues toxicity")
  -- net (prod - clear) = 0.8/s over 5s -> ~4.0.
  check(fouling.toxicity > 3.5 and fouling.toxicity < 4.5, "toxicity tracks net (prod-clear)*t")
  local clean = sim.new()
  local J = intake({ tox_prod = 0.2, tox_clear = 1, tox_half = 14 })
  for _ = 1, 50 do
    sim.step(clean, 0.1, J)
  end
  check(clean.toxicity == 0, "clearance at/above production keeps the dish clean (toxicity 0)")
end
-- A fouled dish chokes a colony that a clean dish would sustain: same intake, but
-- high toxicity throttles the intake side below upkeep and the population collapses.
do
  local choked = sim.new()
  choked.population = 30
  -- forage-only intake (capacity 18) plus relentless fouling, no clearance.
  local foul = intake({ tox_prod = 2, tox_clear = 0, tox_half = 10 })
  for _ = 1, 1500 do
    sim.step(choked, 0.1, foul)
  end
  check(choked.toxicity > 0, "the choked colony accumulated waste")
  check(choked.population == 1, "a fouled, uncleared dish collapses the colony to the founder floor")
end
-- feed_burst's optional tox_clear scrubs waste (the feeding survival lever).
do
  local d = sim.new()
  d.toxicity = 20
  sim.feed_burst(d, 40, 5)
  check(approx(d.toxicity, 15), "a feed with tox_clear flushes that much waste")
  check(approx(d.energy, 40), "the feed still credits energy")
  sim.feed_burst(d, 0, 1000)
  check(d.toxicity == 0, "tox_clear floors waste at 0 (no negative toxicity)")
  local e = sim.new()
  e.toxicity = 8
  sim.feed_burst(e, 40) -- no tox_clear arg
  check(approx(e.toxicity, 8), "a feed without tox_clear leaves waste untouched")
end
-- Toxicity round-trips through serialize/load.
do
  local t = sim.new()
  t.toxicity = 12.5
  local loaded = sim.load(sim.serialize(t))
  check(approx(loaded.toxicity, 12.5), "serialize/load preserves toxicity")
  check(sim.load({}).toxicity == 0, "load defaults toxicity to 0")
end

-- Starvation: a population past carrying capacity STARVES down toward the cap.
-- Biomass is never touched by death (kept, even climbing as the capped colony
-- oscillates and mints), and the population floors at 1.
s = sim.new()
s.population = 40
s.biomass = 100
local cap_intake = intake() -- capacity 18, well below 40
for _ = 1, 600 do
  sim.step(s, 0.1, cap_intake)
end
check(s.population < 40, "a deficit shrinks the population")
check(s.population >= 1, "the population floors at 1")
check(math.abs(s.population - sim.capacity(cap_intake)) <= 2, "the population settles near carrying capacity")
check(s.biomass >= 100, "starvation never spends banked biomass")

-- Floor at 1: even a brutal, unsurvivable intake leaves the founder and its bank.
s = sim.new()
s.population = 12
s.biomass = 7
local brutal = { photo = 0, forage_per_cell = 0, forage_cap = 6, upkeep_per_cell = 5, mult = 1 }
for _ = 1, 600 do
  sim.step(s, 0.1, brutal)
end
check(s.population == 1, "a brutal deficit floors the colony at the founder")
check(s.biomass == 7, "the bank survives total starvation")
check(s.energy >= 0, "the reserve never sticks negative at the floor (gentle idle)")

-- Carrying capacity K = (photo + forage*cap)*mult / upkeep, clamped to [1, cap].
check(approx(sim.capacity(intake()), 18), "capacity from the default intake is 18")
check(sim.capacity(intake({ photo = 12 })) > 18, "light income raises the capacity")
check(sim.capacity(intake({ mult = 2 })) > 18, "the overall multiplier raises the capacity")
check(sim.capacity(intake({ upkeep_per_cell = 0 })) > 1000, "zero upkeep clamps high (no division by zero)")
check(sim.capacity({}) >= 1, "capacity floors at 1 for an empty intake")

-- kill removes cells (a live predator delta): population falls, floored at 1, and
-- the banked biomass is untouched (a kill is a setback the economy regrows).
s = sim.new()
s.population = 10
s.biomass = 50
local lost = sim.kill(s, 3)
check(lost == 3, "kill returns the cells lost")
check(s.population == 7, "kill reduces the population")
check(s.biomass == 50, "kill never touches banked biomass")
local over = sim.kill(s, 100)
check(s.population == 1, "kill floors the population at 1")
check(over == 6, "kill clamps to the cells available above the floor")

-- Spend deducts biomass; overspend is rejected.
s = sim.new()
s.biomass = 100
check(sim.can_spend(s, 40), "can spend within balance")
check(sim.spend(s, 40), "spend succeeds")
check(approx(s.biomass, 60), "spend deducts biomass")
check(not sim.can_spend(s, 1000), "cannot spend beyond balance")
check(not sim.spend(s, 1000), "overspend rejected")
check(approx(s.biomass, 60), "rejected spend deducts nothing")

-- take_divisions: returns queued divisions since last call, then zero.
s = sim.new()
sim.feed_burst(s, 400)
sim.step(s, 0, intake())
local pending = sim.take_divisions(s)
check(pending == s.population - 1, "take_divisions returns the queued divisions")
check(sim.take_divisions(s) == 0, "pending divisions clear after taking")

-- division_rate reacts to the intake and accelerates as the colony grows (below
-- the cap), and reads ZERO once the colony is at or past carrying capacity.
local rich = intake({ forage_per_cell = 20 })
local lean = intake()
check(sim.division_rate(rich, 1) > sim.division_rate(lean, 1), "richer intake => faster divisions")
check(sim.division_rate(lean, 5) > sim.division_rate(lean, 1), "divisions accelerate as the colony grows")
check(sim.division_rate(lean, 100000) == 0, "no divisions at or past carrying capacity")

-- offline replays the shared step in capped sub-steps: it relaxes toward capacity
-- and never crashes below the founder.
s = sim.new()
sim.offline(s, 3600, intake())
check(s.population >= 1, "offline never crashes below the founder")
check(math.abs(s.population - sim.capacity(intake())) <= 3, "offline relaxes toward carrying capacity")
check(s.biomass > 0, "offline mints biomass via divisions")
-- An over-cap colony relaxes DOWN offline, keeping its bank.
s = sim.new()
s.population = 200
s.biomass = 500
sim.offline(s, 3600, intake())
check(s.population < 200 and s.population >= 1, "offline relaxes an over-cap colony down toward the cap")
check(s.biomass >= 500, "offline keeps the banked biomass")
-- A very long absence still resolves (the sub-step loop is capped).
s = sim.new()
sim.offline(s, 8 * 3600, intake())
check(s.population >= 1, "a very long offline still resolves to a sane colony")

-- Live and offline share ONE step, so they converge from the same start.
do
  local live, off = sim.new(), sim.new()
  local I = intake()
  for _ = 1, 1200 do
    sim.step(live, 1, I)
  end
  sim.offline(off, 1200, I)
  check(math.abs(live.population - off.population) <= 3, "live and offline converge (shared step)")
end

-- Serialize -> load round-trip preserves the persisted economy incl. organelles.
s = sim.new()
sim.feed_burst(s, 400)
sim.step(s, 0, intake())
s.organelles.mitochondrion = true
s.energy = 12.5
local blob = sim.serialize(s)
check(blob.population == s.population, "serialize persists population")
check(blob.total_divisions == s.total_divisions, "serialize persists total_divisions")
check(approx(blob.energy, 12.5), "serialize persists energy")
check(blob.organelles.mitochondrion == true, "serialize persists organelles")
check(blob.organelles ~= s.organelles, "serialize copies the organelle set (no shared reference)")
local loaded = sim.load(blob)
check(approx(loaded.biomass, s.biomass), "round-trip biomass")
check(approx(loaded.energy, 12.5), "round-trip energy")
check(loaded.population == s.population, "round-trip population")
check(loaded.total_divisions == s.total_divisions, "round-trip total_divisions")
check(loaded.organelles.mitochondrion == true, "round-trip organelles")
check(sim.take_divisions(loaded) == 0, "load queues no spurious division pulses")

-- Load tolerates nil, legacy keys, and stale/wrong-typed data.
local fresh = sim.load(nil)
check(fresh.biomass == 0 and fresh.population == 1, "load nil -> fresh founder")
local legacy = sim.load({
  biomass = 40,
  lifetime = 500, -- old passive-accrual field
  next_div = 88, -- old division cursor
  evolve_mult = 1.5, -- old prestige multiplier
  generation = 3,
  population = 12,
})
check(legacy.biomass == 40, "legacy load: known field kept")
check(legacy.population == 12, "legacy load: a present population is trusted")
check(legacy.total_divisions == 0, "legacy load: missing total_divisions defaults to 0")
check(legacy.evolve_mult == nil and legacy.lifetime == nil, "legacy load: stale fields are dropped")
check(next(legacy.organelles) == nil, "legacy load: no organelles")
local stale = sim.load({ biomass = 5, energy = "oops", population = 0, organelles = "nope" })
check(stale.biomass == 5, "stale load: known field kept")
check(stale.energy == 0, "stale load: wrong-typed energy ignored")
check(stale.population == 1, "stale load: an invalid population falls back to the fresh founder")
check(next(stale.organelles) == nil, "stale load: wrong-typed organelles ignored")

print("all tests passed (" .. checks .. " checks)")
