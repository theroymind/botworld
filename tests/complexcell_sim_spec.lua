-- Standalone spec for lib/layers/complexcell/sim.lua (the phase-2 economy).
-- Plain Lua 5.1, no framework. Run from the repo root: lua tests/complexcell_sim_spec.lua
--
-- Phase 2 is the eukaryotic sequel to phase 1: instead of banking energy from
-- intake and minting divisions, the cell banks ATP (folded power minus upkeep minus
-- waste) and spends it running an ASSEMBLY LINE whose output mints BUILT, the
-- headline growth number. Output is capped by the slowest unlocked stage
-- (throughput T); a power deficit THROTTLES output and trips brownout, holding back
-- a `brownout_reserve` slice of power so the SAVINGS buffer still banks (a deficit is
-- always recoverable, never a death-spiral). The buffer is a pure savings account:
-- it grows from net ATP and shrinks only on spends, never drained to prop up an
-- over-built line. sim.step consumes ONLY the folded `rates` table (the analogue of phase
-- 1's `intake`) -- it knows nothing of stage levels or stage_rate; the fold is the
-- orchestrator/lab's job. tick and offline share one step(state, dt, rates).
local root = (arg and arg[0] or ""):match("^(.*)/tests/[^/]*$") or "."
package.path = root .. "/?.lua;" .. package.path

local sim = require("lib.layers.complexcell.sim")

local checks = 0

local function check(condition, label)
  checks = checks + 1
  if not condition then
    error("FAILED: " .. label, 2)
  end
end

local function approx(a, b) return math.abs(a - b) < 1e-9 end

-- A folded `rates` table, the analogue of phase 1's intake() helper. Defaults give
-- a TIDY, fully-powered line: power 20, upkeep 2, no excess (waste 0), throughput 5
-- at e=1, so avail = 18, cost_full = 5, surplus = avail - e*T = 13/sec banked.
-- Override any field per test. (Lua treats 0 as truthy, so `o.x or default` still
-- honours an explicit 0.)
local function rates(o)
  o = o or {}
  return {
    power = o.power or 20,
    throughput = o.throughput or 5,
    excess = o.excess or 0,
    upkeep = o.upkeep or 2,
    waste_coef = o.waste_coef or 0.3,
    e_per_output = o.e_per_output or 1,
    buffer_max = o.buffer_max or 200,
    brownout_reserve = o.brownout_reserve or 0,
    stress_rise = o.stress_rise or 0,
    stress_fall = o.stress_fall or 0,
  }
end

-- Fresh state: the engulfed bacterium is the first mitochondrion (mito = 1),
-- nothing built, buffer empty, no stages, no unlocks, output 0, not browning out.
local s = sim.new()
check(s.energy == 0, "fresh energy 0")
check(s.built == 0, "fresh built 0")
check(s.mito == 1, "fresh mito is 1 (the engulfed bacterium)")
check(type(s.stages) == "table" and next(s.stages) == nil, "fresh stages set is empty")
check(type(s.unlocked) == "table" and next(s.unlocked) == nil, "fresh unlocked set is empty")
check(type(s.discovered) == "table" and next(s.discovered) == nil, "fresh discovered set is empty")
check(s.output == 0, "fresh output 0")
check(s.brownout == false, "fresh state is not browning out")
check(s.stress == 0, "fresh state has no oxidative stress")

-- sim.surplus: the bankable surplus at a folded rates, avail - e*T. With the tidy
-- defaults: avail = 20 - 2 - 0.3*0 = 18; e*T = 1*5 = 5; surplus = 13.
check(approx(sim.surplus(rates()), 13), "surplus is avail - e*T (13 at the tidy defaults)")

-- FULLY-POWERED step: avail (18) >= cost_full (5), so the line runs at the
-- bottleneck (O = T = 5), built grows at T, and the surplus (13/sec) banks into the
-- buffer. No brownout. Over 1s: built += 5, energy += (avail - e*O) = 18 - 5 = 13.
s = sim.new()
sim.step(s, 1, rates())
check(approx(s.output, 5), "fully-powered step runs output at the bottleneck T")
check(approx(s.built, 5), "built grows at throughput T over dt")
check(approx(s.energy, 13), "the surplus banks into the buffer (N = avail - e*O = 13)")
check(s.brownout == false, "a fully-powered step never browns out")

-- POWER-LIMITED step: buffer empty (energy 0) and avail < e*T, so output THROTTLES
-- to avail/e and brownout trips. Pick power 8, upkeep 2, no excess -> avail = 6;
-- throughput 10, e = 1 -> cost_full = 10 > avail. With energy 0 the line can only
-- run O = avail/e = 6. N = avail - e*O = 6 - 6 = 0, so the buffer stays empty.
-- built grows at the THROTTLED 6/sec, not the nominal T = 10.
s = sim.new()
local limited = rates({ power = 8, upkeep = 2, throughput = 10, excess = 0 })
sim.step(s, 1, limited)
check(approx(s.output, 6), "power-limited step throttles output to avail/e")
check(s.output < limited.throughput, "throttled output is below the nominal throughput T")
check(s.brownout == true, "a throttled step trips brownout")
check(approx(s.built, 6), "built grows at the throttled rate, not T")
check(approx(s.energy, 0), "an exactly-spent throttle banks nothing")

-- SAVINGS are NOT drained by a mere throttle: a deficit throttles output (brownout)
-- but, unlike the old buffer-drain model, savings are untouched -- so a deficit can
-- always be bought out of. power 8, upkeep 2 -> avail 6 < cost_full 10; reserve 0 ->
-- O = avail/e = 6, N = 0, so the 100 already banked stays put.
s = sim.new()
s.energy = 100
sim.step(s, 1, rates({ power = 8, upkeep = 2, throughput = 10, excess = 0 }))
check(
  approx(s.output, 6),
  "a deficit throttles output to avail/e (does not run full T off savings)"
)
check(s.brownout == true, "a throttled deficit IS a brownout")
check(approx(s.energy, 100), "a throttle leaves savings untouched (pure savings buffer)")

-- BROWNOUT RESERVE: with reserve > 0 a deficit holds back a slice of power for the
-- buffer, so net stays POSITIVE and the cell banks its way back (the recovery
-- guarantee). avail 6, T 10, reserve 0.3 -> O = (6/1)*0.7 = 4.2; N = 6 - 4.2 = 1.8/sec.
s = sim.new()
sim.step(
  s,
  1,
  rates({ power = 8, upkeep = 2, throughput = 10, excess = 0, brownout_reserve = 0.3 })
)
check(approx(s.output, 4.2), "the reserve throttles output further to (avail/e)*(1-reserve)")
check(s.brownout == true, "a reserved throttle still trips brownout")
check(approx(s.energy, 1.8), "a brownout banks the reserved power (positive net -> recoverable)")

-- Power can't even cover upkeep (avail < 0): the line stops (O = 0) and the buffer
-- drains the shortfall, flooring at 0. power 1, upkeep 2 -> avail -1; O = 0, N = -1/sec.
s = sim.new()
s.energy = 5
sim.step(s, 100, rates({ power = 1, upkeep = 2, throughput = 10, excess = 0 }))
check(approx(s.output, 0), "an avail<0 step stops the line entirely")
check(s.energy >= 0, "the buffer never goes negative")
check(approx(s.energy, 0), "an avail<0 deficit drains savings and floors at 0")

-- Buffer CLAMPS at buffer_max: a big surplus over a long dt cannot bank past the
-- ceiling. surplus 13/sec over 100s would be 1300, but buffer_max here is 200.
s = sim.new()
sim.step(s, 100, rates({ buffer_max = 200 }))
check(approx(s.energy, 200), "the buffer clamps at buffer_max")

-- ---------------------------------------------------------------------------
-- OXIDATIVE STRESS -- the failure pressure. A SUSTAINED power deficit drives stress
-- toward 1 (lysis); restoring power decays it back toward 0 (always recoverable).
-- Severity = (cost_full - avail)/max(cost_full,eps) clamped [0,1]; rise = stress_rise
-- * severity, fall = -stress_fall. Derive expected DIRECTION from the constants, not
-- magic timing.
-- ---------------------------------------------------------------------------
do
  -- A FULL deficit: avail <= 0 (power can't even cover upkeep) -> severity = 1 ->
  -- stress rises at stress_rise/sec. Over several steps it must climb monotonically.
  local rise = 0.04
  local def = rates({ power = 0, upkeep = 2, throughput = 10, excess = 0, stress_rise = rise })
  local d = sim.new()
  local last = d.stress
  for _ = 1, 5 do
    sim.step(d, 1, def)
    check(d.stress > last, "stress rises step-over-step under a sustained power deficit")
    last = d.stress
  end
  -- After n seconds at severity 1 the stress is ~ rise*n (until it clamps). Five 1s
  -- steps at rise 0.04 -> ~0.2, well clear of 0 and below the fail clamp.
  check(d.stress > 0, "a sustained deficit accrues stress")
  check(approx(d.stress, rise * 5), "full-deficit (severity 1) stress = stress_rise * seconds")
end

do
  -- A PARTIAL deficit accrues stress SLOWER than a full one (severity < 1). avail 6,
  -- cost_full 10 -> severity = (10-6)/10 = 0.4; rise per sec = stress_rise*0.4.
  local rise = 0.04
  local partial =
    rates({ power = 8, upkeep = 2, throughput = 10, excess = 0, stress_rise = rise })
  local p = sim.new()
  sim.step(p, 1, partial)
  check(approx(p.stress, rise * 0.4), "partial deficit stress scales with severity (0.4 here)")
  check(p.stress > 0 and p.stress < rise, "a partial deficit accrues less stress than a full one")
end

do
  -- HEALTHY surplus (avail >= cost_full): severity 0 -> stress DECAYS at stress_fall.
  -- Pre-load stress, then step a healthy line; it must fall toward 0 and floor there.
  local fall = 0.2
  local good = rates({ power = 20, upkeep = 2, throughput = 5, excess = 0, stress_fall = fall })
  local h = sim.new()
  h.stress = 0.5
  sim.step(h, 1, good)
  check(approx(h.stress, 0.5 - fall), "a healthy surplus decays stress at stress_fall/sec")
  check(h.stress < 0.5, "restoring power lowers stress")
  -- Keep stepping: it floors at 0 (never negative).
  for _ = 1, 10 do
    sim.step(h, 1, good)
  end
  check(h.stress == 0, "stress decays to 0 and clamps (never negative)")
end

do
  -- CLAMP at 1: a long full-deficit step cannot drive stress past 1.
  local hot = rates({ power = 0, upkeep = 2, throughput = 10, excess = 0, stress_rise = 0.04 })
  local c = sim.new()
  sim.step(c, 10000, hot) -- one giant deficit step
  check(c.stress == 1, "stress clamps at 1 (the lysis threshold)")
end

do
  -- RECOVERABLE: a BRIEF deficit then recovery nets BELOW the fail threshold, so a
  -- transient power gap can never lyse the cell on its own. Rise and fall are tuned so
  -- a short deficit (a few seconds) is comfortably cleared. Derive: deficit seconds *
  -- rise must stay under 1, and the subsequent surplus drains it back toward 0.
  local rise, fall = 0.04, 0.2
  local def = rates({ power = 0, upkeep = 2, throughput = 10, excess = 0, stress_rise = rise })
  local good = rates({ power = 20, upkeep = 2, throughput = 5, excess = 0, stress_fall = fall })
  local r = sim.new()
  for _ = 1, 5 do -- 5s of full deficit
    sim.step(r, 1, def)
  end
  local peak = r.stress
  check(peak < 1, "a brief deficit peaks below the fail threshold (recoverable warning window)")
  for _ = 1, 10 do -- power restored
    sim.step(r, 1, good)
  end
  check(r.stress == 0, "recovery clears the transient stress back to 0")
end

-- OVERBUILD: raising `excess` (capacity built above the bottleneck) raises waste
-- (waste_coef * excess), which lowers avail and therefore lowers surplus -- with NO
-- gain to throughput. Two rates differing ONLY in excess: surplus must drop by
-- exactly waste_coef * d_excess.
local lean = rates({ excess = 0 })
local fat = rates({ excess = 20 }) -- same everything, 20 units of idle capacity
check(sim.surplus(fat) < sim.surplus(lean), "more excess lowers the bankable surplus")
check(
  approx(sim.surplus(lean) - sim.surplus(fat), lean.waste_coef * 20),
  "the surplus drop equals waste_coef * excess (self-defeating overbuild)"
)

-- DETERMINISM: no rng anywhere, so two fresh states stepped identically end
-- bit-identical in energy and built.
do
  local d1, d2 = sim.new(), sim.new()
  local R = rates()
  for _ = 1, 2000 do
    sim.step(d1, 0.1, R)
    sim.step(d2, 0.1, R)
  end
  check(approx(d1.energy, d2.energy), "identical steps -> identical energy (deterministic)")
  check(approx(d1.built, d2.built), "identical steps -> identical built")
  check(d1.built > 0, "the determinism check is non-trivial (the cell built something)")
end

-- tick is step: one tick advances exactly like one step of the same dt/rates.
do
  local a, b = sim.new(), sim.new()
  local R = rates()
  sim.tick(a, 0.5, R)
  sim.step(b, 0.5, R)
  check(approx(a.energy, b.energy) and approx(a.built, b.built), "tick is an alias for step")
end

-- offline replays the shared step in capped sub-steps, so a long absence converges
-- and keeps building. It must roughly match the same time stepped live (the buffer
-- clamp makes the integral path-dependent, so allow a small tolerance), and built
-- climbs while surplus is positive.
do
  local live, off = sim.new(), sim.new()
  local R = rates()
  for _ = 1, 600 do
    sim.step(live, 1, R)
  end
  sim.offline(off, 600, R)
  check(off.built > 0, "offline builds structure over a long absence")
  check(approx(live.built, off.built), "live and offline build the same amount (shared step)")
  check(off.energy <= R.buffer_max + 1e-9, "offline respects the buffer ceiling")
end
-- offline with no time is a no-op.
do
  local z = sim.new()
  sim.offline(z, 0, rates())
  check(z.built == 0 and z.energy == 0, "offline(0) is a no-op")
end

-- SERIALIZE -> LOAD round-trip preserves energy/built/mito/stages/unlocked. Copies
-- the stage/unlock tables (no shared references), mirroring phase 1's set copy.
s = sim.new()
s.energy = 42.5
s.built = 137.25
s.mito = 4
s.stages.ribosomes = 3
s.stages.nucleus = 2
s.unlocked.ribosomes = true
s.unlocked.nucleus = true
s.discovered.nucleus = true
s.discovered.er = true
s.output = 5
s.brownout = true
s.stress = 0.4
local blob = sim.serialize(s)
check(approx(blob.energy, 42.5), "serialize persists energy")
check(approx(blob.built, 137.25), "serialize persists built")
check(blob.mito == 4, "serialize persists mito")
check(blob.stages.ribosomes == 3 and blob.stages.nucleus == 2, "serialize persists stage levels")
check(
  blob.unlocked.ribosomes == true and blob.unlocked.nucleus == true,
  "serialize persists unlocks"
)
check(
  blob.discovered.nucleus == true and blob.discovered.er == true,
  "serialize persists the discovered set"
)
check(approx(blob.stress, 0.4), "serialize persists oxidative stress")
check(blob.stages ~= s.stages, "serialize copies the stages table (no shared reference)")
check(blob.unlocked ~= s.unlocked, "serialize copies the unlocked table (no shared reference)")
check(blob.discovered ~= s.discovered, "serialize copies the discovered table (no shared reference)")
local loaded = sim.load(blob)
check(approx(loaded.energy, 42.5), "round-trip energy")
check(approx(loaded.built, 137.25), "round-trip built")
check(loaded.mito == 4, "round-trip mito")
check(loaded.stages.ribosomes == 3 and loaded.stages.nucleus == 2, "round-trip stage levels")
check(loaded.unlocked.ribosomes == true and loaded.unlocked.nucleus == true, "round-trip unlocks")
check(
  loaded.discovered.nucleus == true and loaded.discovered.er == true,
  "round-trip discovered set"
)
check(approx(loaded.stress, 0.4), "round-trip oxidative stress")
check(loaded.brownout == true, "round-trip brownout flag")

-- load tolerates nil, missing fields, and wrong-typed data, falling back to fresh
-- defaults (incl. mito = 1) per field.
local fresh = sim.load(nil)
check(fresh.energy == 0 and fresh.built == 0 and fresh.mito == 1, "load nil -> fresh complex cell")
local partial = sim.load({ built = 500 })
check(approx(partial.built, 500), "partial load: a present field is kept")
check(partial.mito == 1, "partial load: missing mito defaults to 1")
check(partial.energy == 0, "partial load: missing energy defaults to 0")
local stale = sim.load({
  energy = "oops", -- wrong type
  built = -5, -- negative, rejected
  mito = 0, -- below the floor of 1
  stress = -1, -- negative, rejected
  stages = "nope", -- wrong type
  unlocked = 7, -- wrong type
  discovered = "no", -- wrong type
})
check(stale.energy == 0, "stale load: wrong-typed energy ignored")
check(stale.built == 0, "stale load: a negative built falls back to 0")
check(stale.mito == 1, "stale load: a sub-1 mito falls back to the founder mitochondrion")
check(stale.stress == 0, "stale load: a negative stress falls back to 0")
check(next(stale.stages) == nil, "stale load: wrong-typed stages ignored")
check(next(stale.unlocked) == nil, "stale load: wrong-typed unlocked ignored")
check(next(stale.discovered) == nil, "stale load: wrong-typed discovered ignored")

print("all tests passed (" .. checks .. " checks)")
