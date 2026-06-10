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
    -- ROS pendulum + balance-cut inputs (Pillars 2 & 3). Defaults keep the LEGACY
    -- closed-form behaviour intact: min_eff = 1 means efficiency_factor = 1 (no built
    -- cut), so the existing built == O*dt checks hold; ros_* fields default off.
    balance_lo = o.balance_lo or 1,
    balance_hi_eff = o.balance_hi_eff or 1.6,
    ros_ratio_cap = o.ros_ratio_cap or 3,
    ros_rise = o.ros_rise or 0,
    ros_fall = o.ros_fall or 0,
    ros_lethal = o.ros_lethal or 1,
    ros_lethal_rise = o.ros_lethal_rise or 0,
    min_eff = o.min_eff or 1,
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
check(s.ros == 0, "fresh state has no ROS")

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
  local partial = rates({ power = 8, upkeep = 2, throughput = 10, excess = 0, stress_rise = rise })
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

-- tick is step EXCEPT for the live-only lethal-ROS flag: with a benign rates (ros stays
-- 0, no lethal trigger) one tick advances exactly like one step. tick also SETS
-- rates.lethal_ros so the live path can lyse from a sustained surplus -- the forgiveness
-- guard (offline never sets it) is asserted in the divergence block below.
do
  local a, b = sim.new(), sim.new()
  local R = rates()
  sim.tick(a, 0.5, R)
  sim.step(b, 0.5, rates())
  check(
    approx(a.energy, b.energy) and approx(a.built, b.built),
    "tick matches step on a benign line"
  )
  check(R.lethal_ros == true, "tick sets the live-only lethal_ros flag on its rates")
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

-- ===========================================================================
-- THE ROS PENDULUM (Pillar 2) -- symmetric stress: idle OVER-power leaks ROS up; inside
-- the band it decays. ROS drags built (the soft cut) and, sustained past ROS_LETHAL,
-- feeds the lethal stress (LIVE ONLY -- the forgiveness guard).
-- ===========================================================================

-- A fully-powered, far-OVER-band line (ratio = power/demand >> ros_ratio_cap) so the leak
-- severity pins at 1: power 100, throughput 5, upkeep 2 -> demand 7, ratio ~14.3.
local function overpowered(o)
  o = o or {}
  return rates({
    power = 100,
    throughput = 5,
    upkeep = 2,
    excess = 0,
    waste_coef = 0,
    balance_hi_eff = o.balance_hi_eff or 1.6,
    ros_ratio_cap = 3,
    ros_rise = o.ros_rise or 0.1,
    ros_fall = o.ros_fall or 0.25,
    ros_lethal = o.ros_lethal or 0.8,
    ros_lethal_rise = o.ros_lethal_rise or 0.1,
    stress_rise = o.stress_rise or 0.04,
    stress_fall = o.stress_fall or 0.2,
    min_eff = o.min_eff or 0.4,
  })
end

do
  -- RISE: a sustained MAX surplus integrates ros up at ros_rise/sec (severity 1).
  local rise = 0.1
  local hot = overpowered({ ros_rise = rise })
  local h = sim.new()
  local last = h.ros
  for _ = 1, 4 do
    sim.step(h, 1, hot)
    check(h.ros > last, "idle over-power leaks ros up step-over-step")
    last = h.ros
  end
  check(approx(h.ros, rise * 4), "full-surplus (severity 1) ros = ros_rise * seconds")
end

do
  -- DECAY: back inside the band (a balanced line, no surplus), ros decays at ros_fall/sec
  -- and floors at 0. Use a tidy in-band line: power 8, throughput 5, upkeep 2 -> demand 7,
  -- ratio ~1.14 (in [1.0, 1.6]) -> no leak.
  local fall = 0.25
  local calm = rates({
    power = 8,
    throughput = 5,
    upkeep = 2,
    balance_hi_eff = 1.6,
    ros_fall = fall,
  })
  local c = sim.new()
  c.ros = 0.9
  sim.step(c, 1, calm)
  check(approx(c.ros, 0.9 - fall), "an in-band line decays ros at ros_fall/sec")
  for _ = 1, 10 do
    sim.step(c, 1, calm)
  end
  check(c.ros == 0, "ros decays to 0 and clamps (never negative)")
end

do
  -- The safe ceiling is load-bearing: a ratio that leaks ROS at the bare ceiling stops
  -- leaking once balance_hi_eff sits above it. (The ceiling is a fixed constant in the live
  -- economy now -- no antioxidant lever lifts it -- but the sim still honours it as a folded
  -- parameter, which is what this exercises.) Moderate surplus line: power 18, throughput 5,
  -- upkeep 2 -> demand 7, ratio ~2.57. With balance_hi_eff 1.6 (< 2.57) it leaks; with
  -- balance_hi_eff 3.0 (> 2.57) it does not.
  local hot = rates({
    power = 18,
    throughput = 5,
    upkeep = 2,
    balance_hi_eff = 1.6,
    ros_ratio_cap = 3,
    ros_rise = 0.1,
  })
  local cool = rates({
    power = 18,
    throughput = 5,
    upkeep = 2,
    balance_hi_eff = 3.0,
    ros_ratio_cap = 5,
    ros_rise = 0.1,
  })
  local h, c = sim.new(), sim.new()
  sim.step(h, 1, hot)
  sim.step(c, 1, cool)
  check(h.ros > 0, "below the ceiling tolerance, a surplus leaks ros")
  check(c.ros == 0, "a ceiling above the ratio lets the same surplus run clean")
end

-- ===========================================================================
-- PILLAR 3 -- balance cuts real output. built is minted at O * value_mult *
-- efficiency_factor, where efficiency_factor = MIN_EFF + (1-MIN_EFF)*balance_scalar.
-- ===========================================================================
do
  -- A perfectly IN-BAND line mints FULL value (efficiency_factor ~1); an OVER-powered one
  -- (same output O) mints LESS, bottoming near MIN_EFF*O once ros has also climbed. The
  -- ATP cost is identical (e*O); only built bends.
  local min_eff = 0.4
  local in_band = rates({
    power = 8,
    throughput = 5,
    upkeep = 2,
    balance_hi_eff = 1.6,
    min_eff = min_eff,
  })
  local over = overpowered({ min_eff = min_eff })
  local a, b = sim.new(), sim.new()
  sim.step(a, 1, in_band) -- ratio ~1.14, in band, ros 0 -> scalar 1 -> factor 1
  sim.step(b, 1, over) -- ratio huge -> power side 0 -> scalar 0 -> factor MIN_EFF
  check(approx(a.output, b.output), "both lines run the SAME output O (cost side unchanged)")
  check(approx(a.built, a.output * 1), "an in-band line mints full value (efficiency_factor 1)")
  check(
    approx(b.built, b.output * min_eff),
    "an over-powered line mints only MIN_EFF of its output (the load-bearing cut)"
  )
  check(b.built < a.built, "imbalance costs real built")
end

do
  -- The SOFT built cut is IDENTICAL online vs offline (only the LETHAL tail diverges).
  -- Run a hot line both ways for the same time; built must match bit-for-bit.
  local hot = overpowered()
  local live, off = sim.new(), sim.new()
  for _ = 1, 60 do
    sim.tick(live, 1, overpowered()) -- fresh rates each tick (tick mutates lethal_ros)
  end
  sim.offline(off, 60, hot)
  check(approx(live.built, off.built), "the soft ROS built cut is identical online vs offline")
  check(approx(live.ros, off.ros), "ros integrates identically online vs offline")
end

-- ===========================================================================
-- THE FORGIVENESS GUARD -- the surplus-ROS LETHAL coupling accrues LIVE ONLY. A hot cell
-- left running (tick) can drive stress up; the SAME hot cell caught up offline never
-- does (its stress only ever decays, since there is no deficit). Documented divergence.
-- ===========================================================================
do
  -- Drive ros to ~1 first (shared), then keep running hot. LIVE (tick, lethal_ros set):
  -- stress climbs. OFFLINE (no flag): stress stays at 0 (no deficit, no lethal term).
  local live, off = sim.new(), sim.new()
  live.ros, off.ros = 1.0, 1.0 -- both already saturated with ROS
  for _ = 1, 100 do
    sim.tick(live, 1, overpowered()) -- fresh rates each tick
  end
  sim.offline(off, 100, overpowered())
  check(live.stress > 0, "LIVE: a sustained ROS surplus past ROS_LETHAL feeds lethal stress")
  check(off.stress == 0, "OFFLINE: the lethal-ROS coupling NEVER fires (forgiveness guard)")
  check(off.ros == 1, "OFFLINE: ros still saturates (only the LETHAL tail is guarded)")
  -- And the offline built still accrued the soft cut (it dimmed, did not die).
  check(off.built > 0, "OFFLINE: the hot cell keeps building (dimmed, not dead)")
end

do
  -- Below ROS_LETHAL, even LIVE there is no lethal contribution (the generous warning
  -- window): a hot line with ros held under the threshold accrues no stress.
  local r = overpowered({ ros_rise = 0 }) -- pin ros where we set it (no rise)
  local s2 = sim.new()
  s2.ros = 0.7 -- below ROS_LETHAL (0.8)
  for _ = 1, 50 do
    sim.tick(s2, 1, overpowered({ ros_rise = 0 }))
  end
  check(s2.stress == 0, "below ROS_LETHAL the lethal coupling stays quiet (warning window)")
  check(r ~= nil, "guard against an unused-local lint trip")
end

-- ===========================================================================
-- sim.balance_scalar -- the PEAK-IN-BAND scalar shared with catalog.efficiency. Peaks at
-- 1 inside the band, falls off BOTH sides, dragged by ros. Deterministic, pure.
-- ===========================================================================
do
  -- In band (ratio ~1.14), no excess, ros 0 -> scalar 1.
  local band = rates({ power = 8, throughput = 5, upkeep = 2, balance_hi_eff = 1.6 })
  check(approx(sim.balance_scalar(band, 0), 1), "balance_scalar peaks at 1 inside the band")

  -- Deficit (ratio < BALANCE_LO): power 3.5, demand 7 -> ratio 0.5 -> deficit slope 0.5.
  local deficit =
    rates({ power = 3.5, throughput = 5, upkeep = 2, balance_lo = 1, balance_hi_eff = 1.6 })
  check(approx(sim.balance_scalar(deficit, 0), 0.5), "deficit slope = ratio/BALANCE_LO")

  -- Surplus at the midpoint of the surplus span: ratio = (hi_eff + cap)/2 -> severity 0.5
  -- -> power side 0.5. Pick power so ratio = (1.6+3)/2 = 2.3 with demand 7 -> power 16.1.
  local surplus =
    rates({ power = 16.1, throughput = 5, upkeep = 2, balance_hi_eff = 1.6, ros_ratio_cap = 3 })
  check(
    approx(sim.balance_scalar(surplus, 0), 0.5),
    "surplus slope falls toward 0 at ROS_RATIO_CAP"
  )

  -- Past the cap -> power side 0 -> scalar 0.
  local past =
    rates({ power = 100, throughput = 5, upkeep = 2, balance_hi_eff = 1.6, ros_ratio_cap = 3 })
  check(approx(sim.balance_scalar(past, 0), 0), "past ROS_RATIO_CAP the surplus side hits 0")

  -- ros drags the scalar multiplicatively: in-band with ros 0.25 -> scalar 0.75.
  check(approx(sim.balance_scalar(band, 0.25), 0.75), "ros drags the scalar by (1 - ros)")

  -- Excess (flow imbalance) cuts it independently: throughput 5, excess 5 -> flow_balance
  -- 0.5; in band otherwise -> scalar 0.5.
  local excess = rates({ power = 8, throughput = 5, excess = 5, upkeep = 2, balance_hi_eff = 1.6 })
  check(approx(sim.balance_scalar(excess, 0), 0.5), "excess (idle machinery) halves flow_balance")
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
s.ros = 0.6
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
check(approx(blob.ros, 0.6), "serialize persists ros (the ROS pendulum metric)")
check(blob.stages ~= s.stages, "serialize copies the stages table (no shared reference)")
check(blob.unlocked ~= s.unlocked, "serialize copies the unlocked table (no shared reference)")
check(
  blob.discovered ~= s.discovered,
  "serialize copies the discovered table (no shared reference)"
)
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
check(approx(loaded.ros, 0.6), "round-trip ros")
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
