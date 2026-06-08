-- Standalone spec for lib/layers/cell/world.lua (the live agent sim).
-- Plain Lua 5.1, no framework. The sim is pure with an injected rng, so every
-- run here is seeded and deterministic. Run: lua tests/world_spec.lua
local root = (arg and arg[0] or ""):match("^(.*)/tests/[^/]*$") or "."
package.path = root .. "/?.lua;" .. package.path

local world = require("lib.layers.cell.world")

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

-- A small seeded LCG so runs are reproducible without love.math.
local function make_rng(seed)
  local s = seed or 1
  return function()
    s = (s * 1103515245 + 12345) % 2147483648
    return s / 2147483648
  end
end

local FRAME = 1 / 30

-- Fresh world: no cells/foods; field dimensions are initialized.
local w = world.new({ rng = make_rng(1), aspect = 16 / 9 })
check(#w.cells == 0, "new() starts with no cells")
check(#w.foods == 0, "new() starts with no foods")
check(w.field_w ~= nil and w.field_w > 0, "new() initializes field_w")
check(w.field_h ~= nil and w.field_h > 0, "new() initializes field_h")

-- add_food_burst scatters exactly n motes (a fed nutrient bloom).
w = world.new({ rng = make_rng(5), aspect = 16 / 9 })
world.add_food_burst(w, 100, 100, 10)
check(#w.foods == 10, "add_food_burst scatters n motes")

-- Burst motes carry a `settle` field (> 0 during burst phase).
check(w.foods[1].settle ~= nil and w.foods[1].settle > 0, "burst motes carry a settle field > 0")

-- Field growth/clamp: build a world, run one update at a given target_population,
-- then read the snapshot field.
local function field_after_update(pop, aspect)
  local ws = world.new({ rng = make_rng(42), aspect = aspect })
  world.update(ws, FRAME, {
    stats = { speed = 60, sense_range = 70, evasion = 0 },
    target_population = pop,
    aspect = aspect,
    unlocked = {},
    threats_enabled = false,
  })
  return world.snapshot(ws).field
end

local field1 = field_after_update(1, 16 / 9)
local field10 = field_after_update(10, 16 / 9)
local field_huge = field_after_update(100000, 16 / 9)

check(math.abs(field1.w - world.BASE_FIELD) < 1, "pop 1 -> field_w approx BASE_FIELD")
check(math.abs(field1.h - world.BASE_FIELD / (16 / 9)) < 1, "pop 1 -> field_h approx BASE_FIELD/aspect")
check(field10.w > field1.w, "field grows with population (pop 10 > pop 1)")
check(math.abs(field_huge.w - world.MAX_FIELD) < 1, "huge pop clamps at MAX_FIELD")

-- Stepped tiers: the field is a STEP function of population. It HOLDS within a
-- tier and JUMPS exactly at a threshold, instead of climbing continuously.
check(math.abs(field_after_update(1, 16 / 9).w - 440) < 1, "tier 1: pop 1 -> 440")
check(math.abs(field_after_update(5, 16 / 9).w - 440) < 1, "tier 1 holds below the next threshold (pop 5 -> 440)")
check(math.abs(field_after_update(6, 16 / 9).w - 700) < 1, "tier 2: pop 6 steps to 700")
check(math.abs(field_after_update(14, 16 / 9).w - 700) < 1, "tier 2 holds (pop 14 -> 700)")
check(math.abs(field_after_update(15, 16 / 9).w - 1040) < 1, "tier 3: pop 15 -> 1040")
check(math.abs(field_after_update(30, 16 / 9).w - 1520) < 1, "tier 4: pop 30 -> 1520")
check(math.abs(field_after_update(60, 16 / 9).w - 2150) < 1, "tier 5: pop 60 -> 2150")
check(math.abs(field_after_update(120, 16 / 9).w - 2900) < 1, "tier 6: pop 120 -> 2900")
check(math.abs(field_after_update(200, 16 / 9).w - 3600) < 1, "tier 7: pop 200 -> 3600 (max)")

-- RECENTRE on a tier step: the field grows anchored at the origin, so without a
-- shift the old realm's inhabitants would strand in the top-left corner of the
-- wider field. Every entity moves by half the growth, keeping the old centre
-- the new centre (tolerance covers one frame of normal cell drift).
local rcw = world.new({ rng = make_rng(3), aspect = 16 / 9 })
world.update(rcw, FRAME, { target_population = 1, aspect = 16 / 9 }) -- founder, tier 1
local old_w, old_h = rcw.field_w, rcw.field_h
local fx0, fy0 = rcw.cells[1].x, rcw.cells[1].y
world.update(rcw, FRAME, { target_population = 6, aspect = 16 / 9 }) -- steps to tier 2
local grow_x, grow_y = (rcw.field_w - old_w) / 2, (rcw.field_h - old_h) / 2
check(grow_x > 0, "tier step grew the field for the recentre check")
check(
  math.abs(rcw.cells[1].x - (fx0 + grow_x)) < 10 and math.abs(rcw.cells[1].y - (fy0 + grow_y)) < 10,
  "a tier step recentres existing cells by half the growth"
)

-- Ambient motes scale with field area: a larger field keeps more motes.
local function run_world(pop, updates)
  local ws = world.new({ rng = make_rng(7), aspect = 16 / 9 })
  local opts = {
    stats = { speed = 60, sense_range = 70, evasion = 0 },
    target_population = pop,
    aspect = 16 / 9,
    unlocked = {},
    threats_enabled = false,
  }
  for _ = 1, updates do
    world.update(ws, FRAME, opts)
  end
  return ws
end

local small_ws = run_world(1, 60)
local large_ws = run_world(300, 80)
local snap_small = world.snapshot(small_ws)
local snap_large = world.snapshot(large_ws)
check(#snap_large.foods > #snap_small.foods, "larger field keeps more ambient motes")
check(#snap_small.foods >= 8, "ambient motes have an 8-mote floor even at minimum field")

-- Reconcile: births rate-limited, then the colony fills to the target.
w = world.new({ rng = make_rng(2), aspect = 16 / 9 })
local quiet = {
  stats = { speed = 60, sense_range = 80, evasion = 0 },
  target_population = 100,
  aspect = 16 / 9,
  unlocked = {},
  threats_enabled = false,
}
world.update(w, FRAME, quiet)
check(#w.cells <= 40, "births are rate-limited (no flurry on a jump)")
check(#w.cells > 0, "the colony starts filling immediately")
for _ = 1, 60 do
  world.update(w, FRAME, quiet)
end
check(#w.cells == 100, "the visible swarm fills toward the colony size")
check(#w.foods >= 8, "ambient nutrient motes are kept topped up")

-- The visible swarm caps at MAX_AGENTS even for an enormous colony. Filling the
-- whole ceiling by natural growth would take thousands of rate-limited updates, so
-- step the field out to a huge colony, seed the swarm just OVER the cap, and
-- confirm a single reconcile clamps it back down to MAX_AGENTS.
local huge = {
  stats = quiet.stats,
  target_population = 100000,
  aspect = 16 / 9,
  unlocked = {},
  threats_enabled = false,
}
world.update(w, FRAME, huge) -- step the field out to the top tier first
w.cells = {}
for i = 1, world.MAX_AGENTS + 50 do
  w.cells[i] = {
    x = (i * 37) % w.field_w,
    y = (i * 53) % w.field_h,
    dest_x = (i * 37) % w.field_w,
    dest_y = (i * 53) % w.field_h,
    vx = 0,
    vy = 0,
    age = 1,
    hunger = i, -- distinct so the hungriest-first cull is deterministic
    seed = 0.5,
    render = { kind = "cell" },
  }
end
world.update(w, FRAME, huge)
check(#w.cells == world.MAX_AGENTS, "the visible swarm caps at MAX_AGENTS")

-- Evolve drops the colony to zero; the swarm empties (the fusion beat covers it).
world.update(w, FRAME, {
  stats = quiet.stats,
  target_population = 0,
  aspect = 16 / 9,
  unlocked = {},
  threats_enabled = false,
})
check(#w.cells == 0, "a target of zero empties the visible swarm")

-- Chemotaxis: a cell swims toward food it senses. Place the cell on the left of
-- a pop-1 field (360 wide), food cluster on the right at x=230 (within the field).
-- 50 motes exceeds the pop-1 ambient floor of 8, so no ambient motes are added.
w = world.new({ rng = make_rng(7), aspect = 16 / 9 })
w.cells = { { x = 30, y = 73, vx = 0, vy = 0, age = 0, seed = 0.5 } }
w.foods = {}
for i = 1, 50 do
  w.foods[i] = { x = 230, y = 73, vx = 0, vy = 0 }
end
local before_x = w.cells[1].x
world.update(w, 0.1, {
  stats = { speed = 80, sense_range = 2000, evasion = 0 },
  dial_tempo = 0.5,
  target_population = 1,
  aspect = 16 / 9,
  unlocked = {},
  threats_enabled = false,
})
check(w.cells[1].vx > 0, "chemotaxis accelerates toward sensed food")
check(w.cells[1].x > before_x, "a sensing cell swims toward the food")

-- Toroidal wrap (endless realm, no bounce walls): a cell pushed past the field
-- edge re-enters near the OPPOSITE edge. The old soft-wall behavior would have
-- pinned it at field_w - margin; wrap lands it near x=0.
w = world.new({ rng = make_rng(7), aspect = 16 / 9 })
local wrap_opts = {
  stats = { speed = 200, sense_range = 0, evasion = 0 }, -- sense 0: no chasing/eating
  dial_tempo = 0,
  target_population = 1,
  aspect = 16 / 9,
  unlocked = {},
  threats_enabled = false,
}
world.update(w, FRAME, wrap_opts) -- establish the pop-1 field + founder
local wrap_field = world.snapshot(w).field.w
-- Replace the founder with one already past the right edge, moving further right.
w.cells = { { x = wrap_field + 40, y = 50, vx = 180, vy = 0, age = 1, seed = 0.5, render = { kind = "cell" } } }
world.update(w, FRAME, wrap_opts)
local wrapped_x = w.cells[1].x
check(wrapped_x >= 0 and wrapped_x < wrap_field, "a cell stays inside the wrapped field")
check(wrapped_x < wrap_field * 0.3, "a cell past the edge wraps to near 0 (endless realm), not pinned at the margin")

-- Separation: crowded cells push apart (anti-clumping for survivability). With
-- sense_range 0 there's no food chasing to confound it -- two cells almost on
-- top of each other should be farther apart after a few steps.
local sep_opts = {
  stats = { speed = 80, sense_range = 0, evasion = 0 },
  dial_tempo = 0,
  target_population = 2,
  aspect = 16 / 9,
  unlocked = {},
  threats_enabled = false,
}
w = world.new({ rng = make_rng(7), aspect = 16 / 9 })
world.update(w, FRAME, sep_opts) -- establish field + reconcile to 2 cells
w.cells = {
  { x = 200, y = 200, vx = 0, vy = 0, age = 1, seed = 0.2, render = { kind = "cell" } },
  { x = 205, y = 200, vx = 0, vy = 0, age = 1, seed = 0.8, render = { kind = "cell" } },
}
local function cell_dist(a, b)
  local dx, dy = a.x - b.x, a.y - b.y
  return math.sqrt(dx * dx + dy * dy)
end
local sep_before = cell_dist(w.cells[1], w.cells[2])
for _ = 1, 20 do
  world.update(w, FRAME, sep_opts)
end
check(cell_dist(w.cells[1], w.cells[2]) > sep_before, "crowded cells separate (anti-clumping for survivability)")

-- Before predation, no prey and no predators exist.
w = world.new({ rng = make_rng(3), aspect = 16 / 9 })
for _ = 1, 50 do
  world.update(w, FRAME, {
    stats = { speed = 60, sense_range = 80, evasion = 0 },
    target_population = 30,
    aspect = 16 / 9,
    unlocked = {},
    threats_enabled = false,
  })
end
check(#w.prey == 0, "no prey before predation is unlocked")
check(#w.predators == 0, "no predators before predation is unlocked")

-- After predation unlocks: prey populate, predators incur, low-evasion cells die.
local function run_predation(seed, evasion)
  local world_state = world.new({ rng = make_rng(seed), aspect = 16 / 9 })
  local opts = {
    stats = { speed = 70, sense_range = 120, evasion = evasion },
    dial_tempo = 0.5,
    target_population = 100,
    aspect = 16 / 9,
    unlocked = { predation = true },
    threats_enabled = true,
  }
  local total_killed = 0
  local saw_predator = false
  for _ = 1, 600 do -- ~20s: several incursions
    total_killed = total_killed + world.update(world_state, FRAME, opts)
    if #world_state.predators > 0 then
      saw_predator = true
    end
  end
  return world_state, total_killed, saw_predator
end

local hunted, killed_low, saw = run_predation(11, 0)
check(#hunted.prey > 0, "prey populate the world once predation is unlocked")
check(saw, "predators incur once predation is unlocked and threats are live")
check(killed_low > 0, "low-evasion cells get killed by predators")
check(#hunted.cells > 0, "the colony regrows after kills (reconcile heals it)")

-- Full evasion dodges every strike: predators still appear, but kill nothing.
local _, killed_armoured = run_predation(11, 1)
check(killed_armoured == 0, "full evasion dodges every predator strike")

-- Predation off mid-run clears any prey/predators that were present.
world.update(hunted, FRAME, {
  stats = { speed = 70, sense_range = 120, evasion = 0 },
  target_population = 100,
  aspect = 16 / 9,
  unlocked = {},
  threats_enabled = false,
})
check(#hunted.prey == 0, "dropping predation clears prey")
check(#hunted.predators == 0, "dropping predation clears predators")

-- Snapshot exposes every renderable layer AND the field dimensions.
local snap = world.snapshot(hunted)
check(snap.cells and snap.foods and snap.blooms, "snapshot exposes cells, foods, blooms")
check(snap.prey and snap.predators, "snapshot exposes prey and predators")
check(snap.field ~= nil, "snapshot exposes field")
check(snap.field.w ~= nil and snap.field.w > 0, "snapshot field has w")
check(snap.field.h ~= nil and snap.field.h > 0, "snapshot field has h")

-- WIDE BURST: burst motes scatter far from the origin, not bunched in a ~30px clump.
-- Build a max-field world (pop 300), clear foods, add a burst at centre, run ~12
-- updates with sense_range=0 so cells don't chase/eat motes, then measure spread.
local burst_opts = {
  stats = { speed = 60, sense_range = 0, evasion = 0 },
  target_population = 300,
  aspect = 16 / 9,
  unlocked = {},
  threats_enabled = false,
}
local bw = world.new({ rng = make_rng(13), aspect = 16 / 9 })
world.update(bw, FRAME, burst_opts)
local bsnap = world.snapshot(bw)
local bf = bsnap.field
bw.foods = {}
world.add_food_burst(bw, bf.w / 2, bf.h / 2, 24)
-- Tag the burst motes before ambient re-fill (they already carry .settle).
for _ = 1, 12 do
  world.update(bw, FRAME, burst_opts)
end

local function spread(foods, cx, cy)
  local total, count = 0, 0
  for _, fo in ipairs(foods) do
    if fo.settle ~= nil then
      local dx, dy = fo.x - cx, fo.y - cy
      total = total + math.sqrt(dx * dx + dy * dy)
      count = count + 1
    end
  end
  if count == 0 then return 0 end
  return total / count
end

local mean_dist = spread(bw.foods, bf.w / 2, bf.h / 2)
check(mean_dist > 50, "burst motes scatter widely (mean dist > 50) from origin")

-- Determinism: identical seed + identical inputs reproduce trajectories exactly.
local function sequence(seed)
  local world_state = world.new({ rng = make_rng(seed), aspect = 16 / 9 })
  local opts = {
    stats = { speed = 60, sense_range = 90, evasion = 0.2 },
    dial_tempo = 0.4,
    target_population = 40,
    aspect = 16 / 9,
    unlocked = { predation = true },
    threats_enabled = true,
  }
  for _ = 1, 120 do
    world.update(world_state, FRAME, opts)
  end
  return world_state
end
local a = sequence(99)
local b = sequence(99)
check(#a.cells == #b.cells, "same seed -> same cell count")
check(approx(a.cells[1].x, b.cells[1].x), "same seed -> same trajectory")

-- world.update return shape: (killed, engulfs, death_points). With no predation
-- and a steady target there are no kills, no prey engulfs, and no deaths -- but
-- the second and third returns are still a number and a table.
local rw = world.new({ rng = make_rng(4), aspect = 16 / 9 })
local steady = {
  stats = { speed = 60, sense_range = 70, evasion = 0 },
  target_population = 1,
  aspect = 16 / 9,
  unlocked = {},
  threats_enabled = false,
}
local r_killed, r_engulfs, r_deaths = world.update(rw, FRAME, steady)
check(r_killed == 0, "no predators -> zero killed")
check(r_engulfs == 0, "no predation -> zero prey engulfs")
check(type(r_deaths) == "table" and #r_deaths == 0, "a steady colony reports an empty death-points table")

-- Cells track HUNGER (seconds since the last meal), so the view can dim the
-- starving and reconcile can cull them first.
local hw0 = world.new({ rng = make_rng(4), aspect = 16 / 9 })
local grow = {
  stats = { speed = 60, sense_range = 0, evasion = 0 }, -- sense 0: no eating, hunger only climbs
  target_population = 60,
  aspect = 16 / 9,
  unlocked = {},
  threats_enabled = false,
}
for _ = 1, 80 do
  world.update(hw0, FRAME, grow)
end
check(#hw0.cells == 60, "the colony grows to the target")
check(hw0.cells[1].hunger ~= nil and hw0.cells[1].hunger > 0, "cells accumulate hunger while unfed")

-- Death bursts: when the economy-authoritative population FALLS, reconcile culls
-- the surplus cells, bursts each into recycled food motes, and returns the death
-- positions for the view's death-fx.
local foods_before = #hw0.foods
local shrink = {
  stats = grow.stats,
  target_population = 50,
  aspect = 16 / 9,
  unlocked = {},
  threats_enabled = false,
}
local _, _, deaths = world.update(hw0, FRAME, shrink)
check(#deaths == 10, "shrinking the target by 10 reports 10 death positions")
check(deaths[1].x ~= nil and deaths[1].y ~= nil, "death points carry world positions")
check(#hw0.cells == 50, "the swarm shrinks to the new target")
check(#hw0.foods > foods_before, "culled cells burst into recycled food motes")

-- Hungriest-first cull: hand-set hunger so one cell is far hungrier, drop the
-- target by one, and that exact cell is the one removed.
local cw = world.new({ rng = make_rng(8), aspect = 16 / 9 })
for _ = 1, 80 do
  world.update(cw, FRAME, grow)
end
for i = 1, #cw.cells do
  cw.cells[i].hunger = 1
end
cw.cells[7].hunger = 999
cw.cells[7].doomed = true
local _, _, d1 = world.update(cw, FRAME, {
  stats = grow.stats,
  target_population = #cw.cells - 1,
  aspect = 16 / 9,
  unlocked = {},
  threats_enabled = false,
})
check(#d1 == 1, "dropping the target by one culls exactly one cell")
local survived_doomed = false
for i = 1, #cw.cells do
  if cw.cells[i].doomed then
    survived_doomed = true
  end
end
check(not survived_doomed, "the hungriest cell is culled first")

-- Represented starvation (cosmetic, low-cadence): a colony that cannot feed
-- (sense 0 -> hunger only climbs) thins on the fixed starve tick. Once cells pass
-- STARVE_TIME the world retires its hungriest few each tick -- capped, and never
-- below the floor -- and reports them through the same death-points channel with
-- world positions. The target is held constant, so reconcile NEVER culls: every
-- reported death is a starvation death, and the per-update count never exceeds the
-- per-tick cap.
local STARVE_CAP = 3 -- mirrors world.lua's STARVE_MAX_PER_TICK (first-pass tuning)
local sv = world.new({ rng = make_rng(17), aspect = 16 / 9 })
local starve_opts = {
  stats = { speed = 60, sense_range = 0, evasion = 0 }, -- sense 0: cells never eat
  target_population = 30,
  aspect = 16 / 9,
  unlocked = {},
  threats_enabled = false,
}
local starve_total = 0
local capped_ok, positioned_ok = true, true
local starve_min_cells = math.huge
for _ = 1, 600 do -- 20s: well past STARVE_TIME (12s), many starve ticks
  local _, _, d = world.update(sv, FRAME, starve_opts)
  starve_total = starve_total + #d
  if #d > STARVE_CAP then
    capped_ok = false -- never more than the per-tick cap (target constant -> no cull)
  end
  for i = 1, #d do
    if d[i].x == nil or d[i].y == nil then
      positioned_ok = false
    end
  end
  if #sv.cells < starve_min_cells then
    starve_min_cells = #sv.cells
  end
end
check(starve_total > 0, "a starving colony reports starvation deaths over time")
check(capped_ok, "starvation deaths never exceed the per-tick cap")
check(positioned_ok, "starvation death points carry world positions")
check(starve_min_cells >= 1, "starvation keeps the colony above the floor")

-- STARVE_FLOOR: a lone starving cell is never retired -- starvation can thin the
-- colony but never empty it (only the economy can drop the population to zero).
local lone = world.new({ rng = make_rng(19), aspect = 16 / 9 })
local lone_opts = {
  stats = { speed = 60, sense_range = 0, evasion = 0 },
  target_population = 1,
  aspect = 16 / 9,
  unlocked = {},
  threats_enabled = false,
}
local lone_deaths = 0
for _ = 1, 600 do
  local _, _, d = world.update(lone, FRAME, lone_opts)
  lone_deaths = lone_deaths + #d
end
check(#lone.cells == 1, "a lone starving cell survives (STARVE_FLOOR)")
check(lone_deaths == 0, "starvation never retires the last cell")

-- A fed colony reports no starvation: flood the field with food so every cell
-- always senses a mote and resets its hunger clock on each meal, well under
-- STARVE_TIME. Target held constant, so reconcile never culls either -> zero deaths.
local fed = world.new({ rng = make_rng(23), aspect = 16 / 9 })
local fed_opts = {
  stats = { speed = 70, sense_range = 400, evasion = 0 },
  dial_tempo = 0.5,
  target_population = 4,
  aspect = 16 / 9,
  unlocked = {},
  threats_enabled = false,
}
world.update(fed, FRAME, fed_opts) -- establish the field + founders
local fed_field = world.snapshot(fed).field
for gx = 1, 18 do
  for gy = 1, 18 do
    fed.foods[#fed.foods + 1] =
      { x = fed_field.w * gx / 19, y = fed_field.h * gy / 19, vx = 0, vy = 0 }
  end
end
local fed_deaths = 0
for _ = 1, 600 do -- 20s: many starve ticks would have fired had anyone starved
  local _, _, d = world.update(fed, FRAME, fed_opts)
  fed_deaths = fed_deaths + #d
end
check(fed_deaths == 0, "a fed colony (hunger reset by meals) reports no starvation deaths")

-- Prey engulfs are counted and reported (the endosymbiosis trigger). Run a
-- hunting colony (predation unlocked, full evasion so kills don't confound) and
-- confirm at least one prey is fully engulfed.
local ew = world.new({ rng = make_rng(21), aspect = 16 / 9 })
local hunt = {
  stats = { speed = 80, sense_range = 220, evasion = 1 },
  dial_tempo = 0.5,
  target_population = 60,
  aspect = 16 / 9,
  unlocked = { predation = true },
  threats_enabled = false,
}
local total_engulfs = 0
for _ = 1, 600 do
  local _, eng = world.update(ew, FRAME, hunt)
  total_engulfs = total_engulfs + (eng or 0)
end
check(total_engulfs > 0, "prey fully engulfed over a hunting run are counted")

-- swarm_center: the mean cell position (inside the field), and the field centre
-- when the swarm is empty.
local cx, cy = world.swarm_center(ew)
check(cx >= 0 and cx <= ew.field_w and cy >= 0 and cy <= ew.field_h, "swarm_center lands inside the field")
local empty = world.new({ rng = make_rng(1), aspect = 16 / 9 })
local ecx, ecy = world.swarm_center(empty)
check(
  approx(ecx, empty.field_w / 2) and approx(ecy, empty.field_h / 2),
  "swarm_center is the field centre when the swarm is empty"
)

-- action_center: the toroidal weighted centre the view's smart framing pans
-- toward. Empty world -> field centre; a swarm straddling the wrap seam
-- averages to the seam (where a naive mean would wrongly report the centre);
-- a bloom pulls the centre toward itself; snapshot carries the same point.
local acx, acy = world.action_center(empty)
check(
  approx(acx, empty.field_w / 2) and approx(acy, empty.field_h / 2),
  "action_center is the field centre when the world is empty"
)
local seam = world.new({ rng = make_rng(7), aspect = 16 / 9 })
seam.cells = {
  { x = seam.field_w - 10, y = seam.field_h / 2 },
  { x = 10, y = seam.field_h / 2 },
}
local scx, scy = world.action_center(seam)
check(
  math.min(scx, seam.field_w - scx) <= 10 + 1e-6,
  "action_center of a seam-straddling swarm lands at the seam, not the field centre"
)
check(approx(scy, seam.field_h / 2), "action_center y is unaffected by the x-axis straddle")
local pull = world.new({ rng = make_rng(7), aspect = 16 / 9 })
pull.cells = { { x = pull.field_w / 2, y = pull.field_h / 2 } }
pull.blooms = { { x = pull.field_w * 0.75, y = pull.field_h / 2 } }
local pcx = world.action_center(pull)
check(
  pcx > pull.field_w / 2 and pcx < pull.field_w * 0.75,
  "a bloom pulls action_center toward itself, past the lone cell"
)
local snap_action = world.snapshot(pull).action
local sacx, sacy = world.action_center(pull)
check(
  snap_action and approx(snap_action.x, sacx) and approx(snap_action.y, sacy),
  "snapshot carries the action_center as snap.action"
)

-- BLOOM SAFE ZONE: with a bloom_exclude rect (the orchestrator's screen UI
-- projected into world space), spawned blooms never land inside it -- even when
-- the rect covers most of the spawn band (forcing the nudge-left fallback).
local bw = world.new({ rng = make_rng(11), aspect = 16 / 9 })
local excl = { x = bw.field_w * 0.5, y = 0, w = bw.field_w * 0.5, h = bw.field_h }
local bloom_spawns = 0
for _ = 1, 4000 do
  world.update(bw, FRAME, { target_population = 1, bloom_exclude = excl })
  for i = #bw.blooms, 1, -1 do
    local b = bw.blooms[i]
    bloom_spawns = bloom_spawns + 1
    check(
      not (b.x >= excl.x and b.x <= excl.x + excl.w and b.y >= excl.y and b.y <= excl.y + excl.h),
      "bloom never spawns inside the exclusion rect"
    )
    table.remove(bw.blooms, i)
  end
end
check(bloom_spawns >= 10, "bloom safe-zone run observed enough spawns to be meaningful")

-- Without an exclusion rect, blooms still spawn across the interior band.
local bw2 = world.new({ rng = make_rng(11), aspect = 16 / 9 })
local spawned_any = false
for _ = 1, 400 do
  world.update(bw2, FRAME, { target_population = 1 })
  if #bw2.blooms > 0 then
    spawned_any = true
    break
  end
end
check(spawned_any, "blooms spawn normally when no exclusion rect is given")

print("all tests passed (" .. checks .. " checks)")
