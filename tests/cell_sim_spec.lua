-- Standalone spec for lib/layers/cell/sim.lua.
-- Plain Lua 5.1, no framework. Run from the repo root: lua tests/cell_sim_spec.lua
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

local MIN_SP, MAX_SP = sim.div_bounds()
local POP_TARGET = sim.maturity_pop_target()

-- Helper: population is within the jittered division band for a given lifetime.
local function within_div_bounds(pop, L)
  return pop >= 1 + math.floor(L / MAX_SP) and pop <= 1 + math.ceil(L / MIN_SP)
end

-- Fresh state: founder present, economy at zero.
local s = sim.new()
check(s.biomass == 0, "fresh biomass 0")
check(s.lifetime == 0, "fresh lifetime 0")
check(s.population == 1, "fresh population is 1 (the founder)")
check(approx(s.maturity, 1 / POP_TARGET), "fresh maturity is 1/POP_TARGET")
check(s.evolve_mult == 1, "fresh evolve multiplier 1")
check(s.generation == 0, "fresh generation 0")

-- div_bounds: the floor is the asymptotic base minimum; the ceiling is the
-- founder's slow-started maximum. With the defaults the band is (8, 112).
check(MIN_SP == 8, "div_bounds min is DIV_BASE (8)")
check(approx(MAX_SP, 112), "div_bounds max is the slow-started first-division ceiling (112)")

-- Determinism: spacing is keyed on the cell index (a pure hash), never rng, so
-- two identically-ticked sims reach the exact same population.
do
  local d1, d2 = sim.new(), sim.new()
  for _ = 1, 200 do
    sim.tick(d1, 0.1, 25)
    sim.tick(d2, 0.1, 25)
  end
  check(d1.population == d2.population, "identical ticks -> identical population (deterministic spacing)")
  check(d1.population > 1, "the determinism check is non-trivial (the sims actually grew)")
end

-- Tick accrues net_rate * dt to both biomass and lifetime.
s = sim.new()
sim.tick(s, 0.1, 30) -- 30/sec for 0.1s = 3
check(approx(s.biomass, 3), "tick adds net_rate * dt to biomass")
check(approx(s.lifetime, 3), "tick adds net_rate * dt to lifetime")
sim.tick(s, 0.1, 30)
check(approx(s.biomass, 6), "ticks accumulate")
check(approx(s.lifetime, 6), "lifetime accumulates")

-- Tap injects biomass, scaled by the feed multiplier; lifetime tracks it.
-- Small taps may or may not cross a division boundary, so we check
-- biomass/lifetime only (not exact population).
s = sim.new()
sim.tap(s, 1)
check(approx(s.biomass, 5), "tap adds the base feed")
sim.tap(s, 2)
check(approx(s.biomass, 15), "tap scales by the feed multiplier")
check(approx(s.lifetime, 15), "taps count toward lifetime")

-- feed_burst credits a real biomass gain (a nutrient-bloom click) -- it counts
-- toward lifetime, so it advances the colony, and negatives clamp to zero.
-- Feed past the founder's (slow-started) first-division ceiling so a division is
-- guaranteed regardless of the index jitter.
s = sim.new()
local credited = sim.feed_burst(s, 150)
check(approx(credited, 150), "feed_burst returns the credited amount")
check(approx(s.biomass, 150), "feed_burst adds to biomass")
check(approx(s.lifetime, 150), "feed_burst counts toward lifetime (advances colony)")
check(s.population > 1, "feed_burst(150) advances at least one division")
check(within_div_bounds(s.population, 150), "feed_burst population within jitter band")
check(sim.feed_burst(s, -10) == 0, "feed_burst clamps negatives to zero")
check(approx(s.biomass, 150), "a clamped feed_burst credits nothing")

-- threat_loss debits biomass only; lifetime (and so population/maturity) is
-- left untouched, and the debit clamps so biomass never goes negative.
s = sim.new()
sim.tick(s, 1, 100) -- biomass = lifetime = 100
local pop_before = s.population
local lost = sim.threat_loss(s, 30)
check(approx(lost, 30), "threat_loss returns the biomass lost")
check(approx(s.biomass, 70), "threat_loss debits biomass")
check(approx(s.lifetime, 100), "threat_loss leaves lifetime untouched")
check(s.population == pop_before, "threat_loss never rolls back the colony")
local overkill = sim.threat_loss(s, 1000)
check(approx(overkill, 70), "threat_loss clamps to available biomass")
check(s.biomass == 0, "threat_loss never drives biomass negative")

-- Spending deducts biomass but never lifetime; overspend is rejected.
s = sim.new()
sim.tick(s, 1, 100) -- biomass = lifetime = 100
check(sim.can_spend(s, 40), "can spend within balance")
check(sim.spend(s, 40), "spend succeeds")
check(approx(s.biomass, 60), "spend deducts biomass")
check(approx(s.lifetime, 100), "spend leaves lifetime untouched")
check(not sim.can_spend(s, 1000), "cannot spend beyond balance")
check(not sim.spend(s, 1000), "overspend rejected")
check(approx(s.biomass, 60), "rejected spend deducts nothing")

-- Divisions: jittered spacing, so we use the bounds helper.
-- Tick to a known lifetime and confirm population lands in the band.
s = sim.new()
local L_DIV = 200
sim.tick(s, 1, L_DIV)
check(within_div_bounds(s.population, L_DIV), "population within jitter band at lifetime 200")
-- Population strictly increases with more lifetime.
local pop_at_200 = s.population
sim.tick(s, 1, 400) -- lifetime now 600
check(s.population > pop_at_200, "population increases with more lifetime")
check(within_div_bounds(s.population, 600), "population within jitter band at lifetime 600")

-- take_divisions: returns queued divisions since last call, then zero.
s = sim.new()
sim.tick(s, 1, 400) -- enough to cross several divisions even with the slow start
local pending = sim.take_divisions(s)
check(pending == s.population - 1, "take_divisions returns (population - 1) after first growth")
check(sim.take_divisions(s) == 0, "pending divisions cleared after taking")
-- spending below a threshold does not undo a division
sim.spend(s, 80)
check(s.population == pending + 1, "spending does not undo divisions")
-- more lifetime -> more divisions; only the new ones queue
local pop_snapshot = s.population
sim.tick(s, 1, 400)
local new_pending = sim.take_divisions(s)
check(new_pending == s.population - pop_snapshot, "only newly crossed divisions queue")
check(sim.take_divisions(s) == 0, "take_divisions is cleared after reading")

-- Division rate reacts to the net rate (the dial's downstream effect) and to the
-- colony size (the slow-start factor: early divisions are slow, later accelerate).
check(sim.division_rate(50, 1) > sim.division_rate(20, 1), "higher net rate => faster divisions")
check(sim.division_rate(50, 50) > sim.division_rate(50, 1), "divisions accelerate as the colony grows")

-- Maturity is colony-size driven: fills as population approaches POP_TARGET.
s = sim.new()
-- Tick enough to grow but not fill: use a modest lifetime
sim.tick(s, 1, 80) -- well below POP_TARGET*MIN_SP (400)
check(s.population < POP_TARGET, "population stays below target for small lifetime")
check(s.maturity < 1, "maturity below 1 for small population")
check(not sim.can_evolve(s), "not evolvable below the gate")
-- Now tick enough to exceed POP_TARGET cells (POP_TARGET*MAX_SP = 5600 guarantees it)
sim.tick(s, 1, POP_TARGET * MAX_SP)
check(s.population >= POP_TARGET, "population reaches the colony target after sufficient lifetime")
check(approx(s.maturity, 1) or s.maturity >= 1, "maturity reaches 1 at the colony target")
check(s.maturity <= 1, "maturity is clamped to 1")
check(sim.can_evolve(s), "evolvable once the colony matures")

-- Evolve: banks the carried multiplier, bumps generation, resets the colony.
local before_mult = s.evolve_mult
local returned = sim.evolve(s)
check(returned == before_mult * 1.5, "evolve returns the boosted multiplier")
check(s.evolve_mult == before_mult * 1.5, "evolve banks the carried multiplier")
check(s.generation == 1, "evolve bumps the generation")
check(s.biomass == 0 and s.lifetime == 0, "evolve resets biomass and lifetime")
check(s.population == 1, "evolve resets to 1 (founder)")
check(approx(s.maturity, 1 / POP_TARGET), "evolve maturity is reset to 1/POP_TARGET")
check(sim.take_divisions(s) == 0, "evolve queues no pending divisions")
check(sim.evolve(s) == nil, "evolve is a no-op before the next maturity")

-- Offline lump-sum equals net_rate * seconds, applied to biomass and lifetime.
s = sim.new()
sim.tick(s, 1, 10) -- seed: biomass = lifetime = 10
local gained = sim.offline(s, 30, 4) -- 4/sec for 30s = 120
check(approx(gained, 120), "offline returns net_rate * seconds")
check(approx(s.biomass, 130), "offline applies gains to biomass")
check(approx(s.lifetime, 130), "offline gains count toward lifetime")
check(within_div_bounds(s.population, 130), "offline updates derived divisions (in band)")

-- Serialize -> load round-trip preserves persisted state and rederives the rest.
s = sim.new()
sim.tick(s, 1, 130) -- lifetime 130
sim.spend(s, 30) -- biomass 100, lifetime 130
s.evolve_mult = 2.25
s.generation = 2
local blob = sim.serialize(s)
check(type(blob.population) == "number", "serialize persists population")
check(type(blob.next_div) == "number", "serialize persists next_div")
local loaded = sim.load(blob)
check(approx(loaded.biomass, 100), "round-trip biomass")
check(approx(loaded.lifetime, 130), "round-trip lifetime")
check(loaded.evolve_mult == 2.25, "round-trip evolve multiplier")
check(loaded.generation == 2, "round-trip generation")
check(loaded.population == s.population, "load trusts persisted population (O(1))")
check(approx(loaded.next_div, s.next_div), "load trusts persisted next_div")
check(approx(loaded.maturity, loaded.population / POP_TARGET) or loaded.maturity == 1,
  "load rederives maturity from population")
check(sim.take_divisions(loaded) == 0, "load queues no spurious division pulses")

-- Load tolerates missing, partial, and stale data.
local fresh = sim.load(nil)
check(fresh.biomass == 0, "load nil: fresh biomass")
check(fresh.population == 1, "load nil: fresh population is 1")
check(fresh.evolve_mult == 1, "load nil: fresh multiplier")

-- Legacy save: only {lifetime=200}, no population/next_div -> rebuild from lifetime.
local partial = sim.load({ lifetime = 200 })
check(partial.biomass == 0, "partial load: missing biomass defaults")
check(within_div_bounds(partial.population, 200), "partial load: derived population in band")
check(sim.take_divisions(partial) == 0, "partial load: no spurious pending divisions")

-- Stale save: keeps valid fields, ignores wrong-typed ones.
local stale = sim.load({ biomass = 5, lifetime = 50, junk = true, generation = "oops" })
check(stale.biomass == 5, "stale load: known field kept")
check(stale.generation == 0, "stale load: wrong-typed field ignored")

print("all tests passed (" .. checks .. " checks)")
