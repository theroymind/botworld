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
    stats = { speed = 60, sense_range = 70, defense = 0 },
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
check(math.abs(field_after_update(9, 16 / 9).w - 440) < 1, "tier 1 holds below the next threshold (pop 9 -> 440)")
check(math.abs(field_after_update(10, 16 / 9).w - 600) < 1, "tier 2: pop 10 steps to 600")
check(math.abs(field_after_update(29, 16 / 9).w - 600) < 1, "tier 2 holds (pop 29 -> 600)")
check(math.abs(field_after_update(30, 16 / 9).w - 820) < 1, "tier 3: pop 30 -> 820")
check(math.abs(field_after_update(80, 16 / 9).w - 1120) < 1, "tier 4: pop 80 -> 1120")
check(math.abs(field_after_update(200, 16 / 9).w - 1400) < 1, "tier 5: pop 200 -> 1400 (max)")

-- Ambient motes scale with field area: a larger field keeps more motes.
local function run_world(pop, updates)
  local ws = world.new({ rng = make_rng(7), aspect = 16 / 9 })
  local opts = {
    stats = { speed = 60, sense_range = 70, defense = 0 },
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
  stats = { speed = 60, sense_range = 80, defense = 0 },
  target_population = 100,
  aspect = 16 / 9,
  unlocked = {},
  threats_enabled = false,
}
world.update(w, FRAME, quiet)
check(#w.cells <= 4, "births are rate-limited (no flurry on a jump)")
check(#w.cells > 0, "the colony starts filling immediately")
for _ = 1, 60 do
  world.update(w, FRAME, quiet)
end
check(#w.cells == 100, "the visible swarm fills toward the colony size")
check(#w.foods >= 8, "ambient nutrient motes are kept topped up")

-- The visible swarm caps at MAX_AGENTS even for an enormous colony.
local huge = {
  stats = quiet.stats,
  target_population = 100000,
  aspect = 16 / 9,
  unlocked = {},
  threats_enabled = false,
}
for _ = 1, 400 do
  world.update(w, FRAME, huge)
end
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
  stats = { speed = 80, sense_range = 2000, defense = 0 },
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
  stats = { speed = 200, sense_range = 0, defense = 0 }, -- sense 0: no chasing/eating
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
  stats = { speed = 80, sense_range = 0, defense = 0 },
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
    stats = { speed = 60, sense_range = 80, defense = 0 },
    target_population = 30,
    aspect = 16 / 9,
    unlocked = {},
    threats_enabled = false,
  })
end
check(#w.prey == 0, "no prey before predation is unlocked")
check(#w.predators == 0, "no predators before predation is unlocked")

-- After predation unlocks: prey populate, predators incur, low-defense cells die.
local function run_predation(seed, defense)
  local world_state = world.new({ rng = make_rng(seed), aspect = 16 / 9 })
  local opts = {
    stats = { speed = 70, sense_range = 120, defense = defense },
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
check(killed_low > 0, "low-defense cells get killed by predators")
check(#hunted.cells > 0, "the colony regrows after kills (reconcile heals it)")

-- Full defense dodges every strike: predators still appear, but kill nothing.
local _, killed_armoured = run_predation(11, 1)
check(killed_armoured == 0, "full defense dodges every predator strike")

-- Predation off mid-run clears any prey/predators that were present.
world.update(hunted, FRAME, {
  stats = { speed = 70, sense_range = 120, defense = 0 },
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
  stats = { speed = 60, sense_range = 0, defense = 0 },
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
    stats = { speed = 60, sense_range = 90, defense = 0.2 },
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

print("all tests passed (" .. checks .. " checks)")
