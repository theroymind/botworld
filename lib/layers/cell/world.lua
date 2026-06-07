-- World: the live agent sim -- a COSMETIC skin over the authoritative closed-form
-- economy in sim.lua. A myriad of cells drift, sense and chase nutrient motes,
-- engulf prey, and (when predation is unlocked) get hunted by drifting predators.
-- None of this feeds the economy: the only economy couplings live in the
-- orchestrator (a nutrient-bloom click -> sim.feed_burst; a predator kill ->
-- sim.threat_loss). world.update just reports how many cells were killed so the
-- orchestrator can debit that; everything else here is for the eye.
--
-- The agent count is reconciled toward the closed-form colony size each update
-- (births rate-limited so a grown colony fills in smoothly, never in a flurry),
-- capped at MAX_AGENTS -- the visible swarm is a bounded SAMPLE of the colony,
-- not its true size, so "a myriad scaling with growth" stays performant. Agents
-- are never persisted; they rebuild from sim.population on load.
--
-- The FIELD is population-driven and TOROIDAL. Its size is a STEP function of
-- colony size (FIELD_TIERS): it holds within a tier and steps out one notch when
-- the population crosses a threshold, so the view's fit-camera is steady between
-- steps and glides out a single notch at each "spread a big step further" beat.
-- The realm WRAPS (no bounce walls): cells and motes that drift off one edge
-- re-enter the opposite edge, and the view frames the field with an off-screen
-- margin so the wrap seam stays hidden -- a seamless endless realm.
-- world.update computes the field size first, before reconcile/ensure/etc., so
-- every spawner and drifter always sees a coherent field extent.
--
-- Agents (cells, food, blooms, prey, predators) are spawned as ENTITIES carrying
-- a lightweight, color-free render component (a `render` table: kind + size +
-- animation flags); the view owns the palette and draws every entity through one
-- generic flat-square path. Adding a renderable = spawn an entity + attach a
-- render component, never a new bespoke draw function (the composition pillar).
--
-- Pure Lua 5.1 (no love.*): rng is injected so the sim is seeded and testable.
-- Nearest-food lookup uses a rebuilt-per-update spatial hash.
local world = {}

local MAX_AGENTS = 300 -- the bounded visual sample of the colony
local MAX_BORN_PER_UPDATE = 4 -- smooth fill-in; no flurry on offline return
local CELL_SPAWN_SPREAD = 16 -- daughter cell offset from a parent

-- Eating-driven division (cosmetic; the closed-form economy stays the ceiling).
-- A cell engulfs a morsel over FEED_TIME -- sped up by the digestion feed_rate, so
-- that trait finally reads visually -- counts morsels eaten, and splits once it
-- has eaten its per-cell quota (a fresh draw in [DIVIDE_FOOD_MIN, DIVIDE_FOOD_MAX]
-- per (re)birth, so splits stagger instead of pulsing in lockstep). Division only
-- fires within the per-frame birth budget reconcile hands out; when the economy
-- leads the swarm by more than CATCHUP_GAP (an offline return), the fast catch-up
-- fills the swarm directly instead of waiting on earned splits.
local FEED_TIME = 2.0 -- base seconds to engulf one morsel (digestion feed_rate divides this)
local FEED_APPROACH = 10 -- rate a latched cell eases onto its morsel (smooth, no teleport-snap)
local DIVIDE_FOOD_MIN, DIVIDE_FOOD_MAX = 3, 6 -- morsels eaten before a cell may split
local CATCHUP_GAP = 1 -- economy lead beyond which fast catch-up fills the swarm

-- Field side steps up in TIERS with colony size: {pop_threshold, field_w},
-- ascending. The field is the largest tier whose threshold the colony has
-- reached -- a step function, so the fit-camera holds steady within a tier and
-- glides out exactly once per crossed threshold.
local FIELD_TIERS = {
  { 1, 440 },
  { 10, 600 },
  { 30, 820 },
  { 80, 1120 },
  { 200, 1400 },
}
local BASE_FIELD = 440 -- starting field side (tier 1); square-root aspect on h.
-- A roomier tier 1 opens the camera a touch wider on the solo founder.
local MAX_FIELD = 1400 -- top tier / hard cap

-- Render components: world tags each entity with a lightweight, color-free
-- descriptor; the view owns the palette/sizes and draws every entity as a flat
-- square. These uniform kinds share one read-only table (cells animate via the
-- per-entity `age`, not per-instance render state); blooms carry a per-instance
-- size, so they build their own.
local RENDER_CELL = { kind = "cell", pop_in = true }
local RENDER_FOOD = { kind = "food" }
local RENDER_PREY = { kind = "prey" }
local RENDER_PREDATOR = { kind = "predator" }

-- Ambient food density expressed as motes per pixel (calibrated to 44 motes on
-- a 1280x720 canvas). The target count is recomputed from the live field area
-- each frame, staying density-constant as the field expands.
local FOOD_DENSITY = 44 / (1280 * 720)
local FOOD_MIN = 8 -- never starve a tiny colony
local FOOD_MAX = 140 -- cap so even a full-sized field stays readable

local FOOD_DRIFT = 12 -- mote brownian speed, world units/sec
local CONSUME_RADIUS = 9 -- a cell this close to its target eats it

local CELL_DRIFT = 26 -- wander acceleration when nothing is sensed
local CELL_DAMPING = 1.6 -- velocity bleed per second
local STEER_GAIN = 4.0 -- how hard a cell accelerates toward sensed food
-- Anti-crowding separation: daughter cells push away from nearby cells so the
-- colony spreads instead of clumping (a clump is easy prey -- spreading is for
-- survivability). Cheap via the cell spatial hash.
local SEPARATION_RADIUS = 24 -- cells nearer than this repel each other
local SEPARATION_GAIN = 70 -- how hard they spread apart

local BLOOM_INTERVAL = 6.5 -- seconds between nutrient-bloom spawns
local BLOOM_LIFE = 3.0 -- ~3s clickable countdown
local BLOOM_MAX = 3 -- simultaneous blooms
local BURST_FOOD = 14 -- motes spawned when a bloom is fed

-- Burst physics: motes spray gently outward then relax into ambient milling --
-- a feed, not a detonation. BURST_SPEED scales with the field size so the spray
-- looks proportional on any canvas. BURST_DAMPING bleeds the launch velocity per
-- second so motes settle into normal drift quickly (higher = gentler).
local BURST_SPEED = 110 -- launch speed (world units/sec) at BASE_FIELD scale
local BURST_SETTLE = 0.7 -- seconds of burst phase before ambient milling resumes
local BURST_JITTER = 4 -- position jitter at spawn centre (world units)
local BURST_DAMPING = 1.6 -- velocity damping coefficient during burst phase (gentler)

local PREY_TARGET = 16 -- prey microbes maintained once predation is unlocked
local PREY_DRIFT = 16

local PREDATOR_INTERVAL = 8.0 -- seconds between predator incursions (live-only)
local PREDATOR_LIFE = 7.0 -- a predator leaves after this long
local PREDATOR_SPEED = 78
local PREDATOR_KILL_RADIUS = 11
local PREDATOR_MAX_KILLS = 4 -- cap kills per incursion -- combat is a scare
local PREDATOR_MAX = 2 -- simultaneous predators
local PREDATOR_MIN_CELLS = 6 -- no predators until the colony is worth hunting

local HASH_CELL = 64 -- spatial-hash bucket size

-- rng helpers (state.rng returns [0,1)).
local function rnd(state)
  return state.rng()
end

local function rand_range(state, a, b)
  return a + state.rng() * (b - a)
end

local function rsign(state)
  return state.rng() * 2 - 1
end

local function rint(state, n)
  return math.floor(state.rng() * n) + 1
end

local function clamp(v, lo, hi)
  return math.max(lo, math.min(hi, v))
end

-- The field side for a given colony size: the largest tier whose population
-- threshold the colony has reached. A step function, so the fit-camera holds
-- steady within a tier and steps out exactly once per crossed threshold.
local function field_for_population(pop)
  local w = FIELD_TIERS[1][2]
  for i = 1, #FIELD_TIERS do
    if pop >= FIELD_TIERS[i][1] then
      w = FIELD_TIERS[i][2]
    else
      break
    end
  end
  return w
end

-- How many ambient food motes to keep at the current field size. Constant
-- density: same motes-per-pixel as a 1280x720 canvas at 44 motes.
local function food_target(state)
  return clamp(math.floor(FOOD_DENSITY * state.field_w * state.field_h + 0.5), FOOD_MIN, FOOD_MAX)
end

-- Initialize a new world state. opts:
--   rng    -- seeded random function returning [0,1); defaults to 0.5
--   aspect -- width/height ratio of the field; defaults to 16/9
-- The field starts at BASE_FIELD × (BASE_FIELD / aspect) and grows with
-- population each update.
function world.new(opts)
  opts = opts or {}
  local aspect = opts.aspect or (16 / 9)
  return {
    rng = opts.rng or function()
      return 0.5
    end,
    field_w = BASE_FIELD,
    field_h = BASE_FIELD / aspect,
    cells = {},
    foods = {},
    blooms = {},
    prey = {},
    predators = {},
    bloom_timer = BLOOM_INTERVAL,
    predator_timer = PREDATOR_INTERVAL,
  }
end

-- Fan motes outward from (x, y) in a wide explosion that fades into ambient
-- milling. Each mote gets a random angle and a speed that scales with the
-- current field size so the burst always looks proportional.
function world.add_food_burst(state, x, y, n)
  local scale = state.field_w / BASE_FIELD
  for _ = 1, (n or BURST_FOOD) do
    local angle = rnd(state) * 2 * math.pi
    local speed = rand_range(state, 0.4, 1.0) * BURST_SPEED * scale
    state.foods[#state.foods + 1] = {
      x = x + rsign(state) * BURST_JITTER,
      y = y + rsign(state) * BURST_JITTER,
      vx = math.cos(angle) * speed,
      vy = math.sin(angle) * speed,
      settle = BURST_SETTLE, -- > 0: burst phase; nil/0: ambient milling
      render = RENDER_FOOD,
    }
  end
end

-- Hit-test the active nutrient blooms; returns the bloom (and removes it) if the
-- point lands within `radius` world units of one, else nil. `radius` comes from
-- the view -- the bloom's UI-constant on-screen size projected to world units at
-- the current zoom -- so clicks line up with the drawn disk regardless of tier;
-- a small fallback keeps a radius-less call working. The orchestrator routes the
-- credit + burst.
function world.hit_bloom(state, x, y, radius)
  local r = radius or 24
  for i = #state.blooms, 1, -1 do
    local b = state.blooms[i]
    local dx, dy = x - b.x, y - b.y
    if dx * dx + dy * dy <= r * r then
      table.remove(state.blooms, i)
      return b
    end
  end
  return nil
end

-- The first active bloom, for keyboard feeding when the mouse isn't on one.
function world.any_bloom(state)
  return state.blooms[1]
end

-- A cell's division quota: how many morsels it must eat before it may split,
-- drawn fresh in [DIVIDE_FOOD_MIN, DIVIDE_FOOD_MAX] for each (re)birth.
local function div_need(state)
  return DIVIDE_FOOD_MIN - 1 + rint(state, DIVIDE_FOOD_MAX - DIVIDE_FOOD_MIN + 1)
end

-- Factory: append a fresh cell at (x, y) with all per-cell state. eaten/need
-- pace eating-fed division; feeding/feed_target are the engulf latch (nil while
-- roaming). These live on the ENTITY -- never on the shared frozen RENDER_CELL.
local function new_cell(state, x, y)
  local seed = rnd(state) -- per-cell wobble phase; drawn before need for determinism
  local need = div_need(state)
  state.cells[#state.cells + 1] = {
    x = x,
    y = y,
    vx = 0,
    vy = 0,
    age = 0, -- drives the mitosis pop-in
    seed = seed,
    eaten = 0, -- morsels engulfed toward `need`
    need = need, -- quota to reach before splitting
    feeding = nil, -- > 0 while engulfing a morsel (remaining seconds)
    feed_target = nil, -- the morsel entity being engulfed
    render = RENDER_CELL,
  }
end

-- Spawn a cell with auto-placement: a founder dead-centre (so the camera can
-- zoom onto it without hunting), else a daughter scattered around a random
-- parent. Used by reconcile's founder / fast-catch-up fill; an EARNED split
-- calls new_cell directly beside the dividing cell.
local function spawn_cell(state)
  local x, y
  if #state.cells > 0 then
    local parent = state.cells[rint(state, #state.cells)]
    x = parent.x + rsign(state) * CELL_SPAWN_SPREAD
    y = parent.y + rsign(state) * CELL_SPAWN_SPREAD
  else
    x = state.field_w / 2
    y = state.field_h / 2
  end
  new_cell(state, x, y)
end

-- Reconcile the swarm toward the colony size and return this frame's budget for
-- EARNED (eating-driven) splits. Three regimes:
--   * shrink   -- over target (evolve to 0, or MAX_AGENTS overflow): prune now;
--                 the view's fusion beat covers an evolve. Free any morsel a
--                 pruned cell was engulfing so it rejoins the drifting field.
--   * founder / fast catch-up -- empty, or the economy leads by more than
--                 CATCHUP_GAP (an offline return): fill directly, rate-limited,
--                 and grant NO earned births this frame (return 0).
--   * trickle  -- within CATCHUP_GAP of target: hand step_cells a budget so the
--                 last cells of the +1 economy trickle are EARNED by eating.
local function reconcile(state, target)
  target = clamp(target, 0, MAX_AGENTS)
  while #state.cells > target do
    local victim = state.cells[#state.cells]
    if victim.feed_target then
      victim.feed_target.claimed = nil
    end
    state.cells[#state.cells] = nil
  end
  if #state.cells == 0 or target - #state.cells > CATCHUP_GAP then
    local born = 0
    while #state.cells < target and born < MAX_BORN_PER_UPDATE do
      spawn_cell(state)
      born = born + 1
    end
    return 0
  end
  return math.min(target - #state.cells, MAX_BORN_PER_UPDATE)
end

-- Drift a list of motes one frame. Burst motes (settle > 0) integrate their
-- launch velocity and damp it, bouncing off field edges; once settle expires they
-- join the ambient-milling branch. Ambient motes (no settle) wrap modulo field
-- and steer gently to keep the field milling without bunching.
local function drift_field(state, list, dt, speed)
  local w, h = state.field_w, state.field_h
  for _, p in ipairs(list) do
    -- A morsel mid-engulf sits still beneath the feeding cell (which snaps onto
    -- it); skip drift so it doesn't squirm out from under the parked cell.
    if not p.claimed then
      if p.settle and p.settle > 0 then
        -- === burst phase: integrate velocity, damp, wrap (no bounce) ===
        p.x = p.x + p.vx * dt
        p.y = p.y + p.vy * dt
        local damp = math.max(0, 1 - BURST_DAMPING * dt)
        p.vx, p.vy = p.vx * damp, p.vy * damp
        p.settle = p.settle - dt
        if p.settle <= 0 then
          p.settle = nil -- graduate to ambient milling next frame
        end
        -- Toroidal wrap: a spray mote that flies past an edge re-enters opposite
        -- (the realm is endless; the off-screen margin hides the seam).
        p.x = p.x % w
        p.y = p.y % h
      else
        -- === ambient milling: wrap modulo field, gentle random re-aim ===
        p.x = (p.x + p.vx * dt) % w
        p.y = (p.y + p.vy * dt) % h
        p.vx = p.vx + rsign(state) * speed * dt
        p.vy = p.vy + rsign(state) * speed * dt
        local sp = math.sqrt(p.vx * p.vx + p.vy * p.vy)
        if sp > speed then
          p.vx, p.vy = p.vx / sp * speed, p.vy / sp * speed
        end
      end
    end
  end
end

-- Top up a list to `target` count, spawning new motes uniformly across the
-- field. Each new mote carries the given render component (food vs. prey).
local function ensure_field(state, list, target, drift, render)
  while #list < target do
    list[#list + 1] = {
      x = rand_range(state, 0, state.field_w),
      y = rand_range(state, 0, state.field_h),
      vx = rsign(state) * drift,
      vy = rsign(state) * drift,
      render = render,
    }
  end
end

-- Compact a list, dropping entries flagged .dead. Stable, O(n).
local function compact(list)
  local n = 0
  for i = 1, #list do
    local item = list[i]
    if not item.dead then
      n = n + 1
      list[n] = item
    end
  end
  for i = #list, n + 1, -1 do
    list[i] = nil
  end
end

-- Build a spatial hash of food indices for nearest-lookup.
local function build_hash(foods)
  local grid = {}
  for i = 1, #foods do
    local f = foods[i]
    local gx = math.floor(f.x / HASH_CELL)
    local gy = math.floor(f.y / HASH_CELL)
    local key = gx * 100003 + gy
    local bucket = grid[key]
    if not bucket then
      bucket = {}
      grid[key] = bucket
    end
    bucket[#bucket + 1] = i
  end
  return grid
end

-- Nearest food index within `range` of (x,y) via the hash, or nil.
local function nearest_food(grid, foods, x, y, range)
  local gx = math.floor(x / HASH_CELL)
  local gy = math.floor(y / HASH_CELL)
  local reach = math.ceil(range / HASH_CELL)
  local best = range * range
  local found
  for ix = gx - reach, gx + reach do
    for iy = gy - reach, gy + reach do
      local bucket = grid[ix * 100003 + iy]
      if bucket then
        for k = 1, #bucket do
          local idx = bucket[k]
          local f = foods[idx]
          local dx, dy = f.x - x, f.y - y
          local d2 = dx * dx + dy * dy
          if not f.claimed and d2 < best then
            best = d2
            found = idx
          end
        end
      end
    end
  end
  return found, best
end

-- Nearest prey index within `range` (linear; the prey set is small), or nil.
local function nearest_prey(prey, x, y, range)
  local best = range * range
  local found
  for i = 1, #prey do
    local p = prey[i]
    local dx, dy = p.x - x, p.y - y
    local d2 = dx * dx + dy * dy
    if not p.claimed and d2 < best then
      best = d2
      found = i
    end
  end
  return found, best
end

-- Accumulate a "push away from crowding neighbors" vector for the cell at
-- (x, y) via the cell spatial hash: sum of unit vectors away from each cell
-- within `radius`, weighted by closeness (nearer => stronger). Self is skipped.
local function separation_push(grid, cells, self_i, x, y, radius)
  local gx = math.floor(x / HASH_CELL)
  local gy = math.floor(y / HASH_CELL)
  local reach = math.ceil(radius / HASH_CELL)
  local r2 = radius * radius
  local px, py = 0, 0
  for ix = gx - reach, gx + reach do
    for iy = gy - reach, gy + reach do
      local bucket = grid[ix * 100003 + iy]
      if bucket then
        for k = 1, #bucket do
          local j = bucket[k]
          if j ~= self_i then
            local o = cells[j]
            local dx, dy = x - o.x, y - o.y
            local d2 = dx * dx + dy * dy
            if d2 < r2 and d2 > 1e-6 then
              local d = math.sqrt(d2)
              local weight = (1 - d / radius) / d -- closer => stronger push
              px = px + dx * weight
              py = py + dy * weight
            end
          end
        end
      end
    end
  end
  return px, py
end

-- Advance every cell one frame. `births` is reconcile's earned-split budget for
-- this frame; a cell that finishes a meal having reached its quota consumes one.
-- Each cell is either ENGULFING (parked on a latched morsel, draining its feed
-- timer) or ROAMING (sense -> steer -> move -> latch a morsel on contact). No
-- `continue` in Lua 5.1, so the two states branch with if/else.
local function step_cells(state, dt, stats, tempo, hunt_prey, births)
  local speed = stats.speed
  local sense = stats.sense_range
  local feed_rate = stats.feed_rate or 1 -- digestion: >1 shortens the feed pause
  local grid = build_hash(state.foods)
  -- Hash the cells too, so each can cheaply repel its crowding neighbors. Built
  -- from this frame's start positions (standard boids); deterministic.
  local cell_grid = build_hash(state.cells)
  local w, h = state.field_w, state.field_h
  -- Fixed limit: daughters appended this frame aren't iterated until next frame.
  for ci = 1, #state.cells do
    local c = state.cells[ci]
    c.age = c.age + dt

    if c.feeding then
      -- === engulfing: park on the morsel and drain the feed timer ===
      local m = c.feed_target
      if not m or m.dead then
        -- The morsel vanished underneath us: drop the latch and roam next frame.
        c.feeding = nil
        c.feed_target = nil
      else
        -- Ease onto the morsel rather than snapping, so latching reads as gently
        -- settling in (no teleport). The claimed morsel sits still -> this converges.
        local k = math.min(1, FEED_APPROACH * dt)
        c.vx, c.vy = 0, 0
        c.x = c.x + (m.x - c.x) * k
        c.y = c.y + (m.y - c.y) * k
        c.feeding = c.feeding - dt
        if c.feeding <= 0 then
          -- Engulfed: consume the morsel, bank a meal, and split if the quota is
          -- met AND this frame's earned-birth budget allows (economy is the cap).
          m.dead = true
          m.claimed = nil
          c.feeding = nil
          c.feed_target = nil
          c.eaten = c.eaten + 1
          if c.eaten >= c.need and births > 0 then
            new_cell(state, c.x + rsign(state) * CELL_SPAWN_SPREAD, c.y + rsign(state) * CELL_SPAWN_SPREAD)
            births = births - 1
            c.eaten = 0
            c.need = div_need(state)
          end
        end
      end
    else
      -- === roaming: pick the nearest target (a food mote, or when hunting the
      -- nearer of food and prey), steer toward it, move, then latch on contact ===
      local food_i, food_d2 = nearest_food(grid, state.foods, c.x, c.y, sense)
      local tx, ty, target_kind, target_idx
      if food_i then
        tx, ty, target_kind, target_idx = state.foods[food_i].x, state.foods[food_i].y, "food", food_i
      end
      if hunt_prey then
        local prey_i, prey_d2 = nearest_prey(state.prey, c.x, c.y, sense)
        if prey_i and (not food_i or prey_d2 < food_d2) then
          tx, ty, target_kind, target_idx = state.prey[prey_i].x, state.prey[prey_i].y, "prey", prey_i
        end
      end

      if tx then
        local dx, dy = tx - c.x, ty - c.y
        local d = math.sqrt(dx * dx + dy * dy) + 1e-6
        c.vx = c.vx + (dx / d) * speed * STEER_GAIN * dt
        c.vy = c.vy + (dy / d) * speed * STEER_GAIN * dt
      else
        local agit = 0.5 + tempo
        c.vx = c.vx + rsign(state) * CELL_DRIFT * agit * dt
        c.vy = c.vy + rsign(state) * CELL_DRIFT * agit * dt
      end

      -- Spread from crowding neighbors (survivability): always on, so the colony
      -- fans out even while everyone chases the same bloom.
      local px, py = separation_push(cell_grid, state.cells, ci, c.x, c.y, SEPARATION_RADIUS)
      c.vx = c.vx + px * SEPARATION_GAIN * dt
      c.vy = c.vy + py * SEPARATION_GAIN * dt

      -- Damp and clamp to the cell's swim speed.
      local damp = math.max(0, 1 - CELL_DAMPING * dt)
      c.vx, c.vy = c.vx * damp, c.vy * damp
      local sp = math.sqrt(c.vx * c.vx + c.vy * c.vy)
      if sp > speed then
        c.vx, c.vy = c.vx / sp * speed, c.vy / sp * speed
      end

      c.x = c.x + c.vx * dt
      c.y = c.y + c.vy * dt
      -- Toroidal wrap (no bounce): a cell that drifts off one edge re-enters the
      -- opposite edge, so the realm is endless and seamless.
      c.x = c.x % w
      c.y = c.y % h

      -- Contact -> latch (cosmetic; income is closed-form elsewhere). Claim the
      -- morsel so no sibling latches it, and begin the engulf pause (shortened by
      -- digestion feed_rate). The morsel is consumed only when feeding completes.
      if target_kind then
        local dx, dy = tx - c.x, ty - c.y
        if dx * dx + dy * dy <= CONSUME_RADIUS * CONSUME_RADIUS then
          local entity = (target_kind == "food") and state.foods[target_idx] or state.prey[target_idx]
          c.feeding = FEED_TIME / feed_rate
          c.feed_target = entity
          entity.claimed = true
        end
      end
    end
  end
  compact(state.foods)
  compact(state.prey)
end

local function step_blooms(state, dt)
  state.bloom_timer = state.bloom_timer - dt
  if state.bloom_timer <= 0 then
    state.bloom_timer = BLOOM_INTERVAL + rand_range(state, -1.5, 1.5)
    if #state.blooms < BLOOM_MAX then
      -- Bloom appears at a world position in the interior of the field; its drawn
      -- size is a constant on-screen UI size owned by the view, not a world scale.
      state.blooms[#state.blooms + 1] = {
        x = rand_range(state, state.field_w * 0.2, state.field_w * 0.85),
        y = rand_range(state, state.field_h * 0.15, state.field_h * 0.85),
        timer = BLOOM_LIFE,
        life = BLOOM_LIFE,
        -- The nutrient bloom renders as a pulsing CIRCLE with a countdown bar
        -- (the view's "bloom" shape; its radius is the view's UI screen size).
        render = { kind = "bloom", shape = "bloom" },
      }
    end
  end
  for i = #state.blooms, 1, -1 do
    local b = state.blooms[i]
    b.timer = b.timer - dt
    if b.timer <= 0 then
      table.remove(state.blooms, i)
    end
  end
end

-- Live-only predators. Returns the number of cells killed this update so the
-- orchestrator can debit biomass (sim.threat_loss). Defense lets a cell shrug
-- off a strike, so membrane visibly matters.
local function step_predators(state, dt, defense)
  state.predator_timer = state.predator_timer - dt
  if state.predator_timer <= 0 then
    state.predator_timer = PREDATOR_INTERVAL + rand_range(state, -2, 2)
    if #state.predators < PREDATOR_MAX and #state.cells >= PREDATOR_MIN_CELLS then
      -- Drift in from a random field edge.
      local edge = rint(state, 4)
      local x, y
      if edge == 1 then
        x, y = 0, rand_range(state, 0, state.field_h)
      elseif edge == 2 then
        x, y = state.field_w, rand_range(state, 0, state.field_h)
      elseif edge == 3 then
        x, y = rand_range(state, 0, state.field_w), 0
      else
        x, y = rand_range(state, 0, state.field_w), state.field_h
      end
      state.predators[#state.predators + 1] =
        { x = x, y = y, life = PREDATOR_LIFE, kills = 0, seed = rnd(state), render = RENDER_PREDATOR }
    end
  end

  local killed = 0
  for pi = #state.predators, 1, -1 do
    local p = state.predators[pi]
    p.life = p.life - dt
    -- Chase the nearest cell.
    local best, target = math.huge, nil
    for ci = 1, #state.cells do
      local c = state.cells[ci]
      local dx, dy = c.x - p.x, c.y - p.y
      local d2 = dx * dx + dy * dy
      if d2 < best then
        best, target = d2, ci
      end
    end
    if target then
      local c = state.cells[target]
      local dx, dy = c.x - p.x, c.y - p.y
      local d = math.sqrt(dx * dx + dy * dy) + 1e-6
      p.x = p.x + (dx / d) * PREDATOR_SPEED * dt
      p.y = p.y + (dy / d) * PREDATOR_SPEED * dt
      if d <= PREDATOR_KILL_RADIUS then
        if rnd(state) >= defense then -- defense is the dodge chance
          -- Free any morsel the victim was engulfing so it rejoins the drifting
          -- field (an orphaned claim would otherwise freeze the mote forever).
          if c.feed_target then
            c.feed_target.claimed = nil
          end
          table.remove(state.cells, target)
          killed = killed + 1
          p.kills = p.kills + 1
        end
      end
    end
    if p.life <= 0 or p.kills >= PREDATOR_MAX_KILLS then
      table.remove(state.predators, pi)
    end
  end
  return killed
end

-- Advance the whole sim one frame. opts:
--   stats             -- folded trait stats (speed, sense_range, defense, ...)
--   dial_tempo        -- the metabolism dial [0,1], live agitation
--   aspect            -- field width/height ratio; defaults to 16/9
--   target_population -- colony size to reconcile toward (capped at MAX_AGENTS)
--   unlocked          -- the unlocked capability set (predation -> prey/predators)
--   threats_enabled   -- whether predators may appear (live-only)
-- Returns killed_count.
function world.update(state, dt, opts)
  opts = opts or {}
  local stats = opts.stats or { speed = 60, sense_range = 70, defense = 0 }
  local tempo = opts.dial_tempo or 0.5
  local unlocked = opts.unlocked or {}
  local predation = unlocked.predation == true
  local aspect = opts.aspect or (16 / 9)

  -- Field size is computed FIRST so every spawner and drifter sees a coherent
  -- field extent. It is a STEP function of colony size (FIELD_TIERS): steady
  -- within a tier, stepping out one notch at each crossed threshold.
  local pop = math.max(opts.target_population or 0, 1)
  state.field_w = field_for_population(pop)
  state.field_h = state.field_w / aspect

  local births = reconcile(state, opts.target_population or 0)
  ensure_field(state, state.foods, food_target(state), FOOD_DRIFT, RENDER_FOOD)
  drift_field(state, state.foods, dt, FOOD_DRIFT)

  if predation then
    ensure_field(state, state.prey, PREY_TARGET, PREY_DRIFT, RENDER_PREY)
    drift_field(state, state.prey, dt, PREY_DRIFT)
  elseif #state.prey > 0 then
    state.prey = {}
  end

  step_cells(state, dt, stats, tempo, predation, births)
  -- Keep the ambient field replenished after consumption.
  ensure_field(state, state.foods, food_target(state), FOOD_DRIFT, RENDER_FOOD)
  step_blooms(state, dt)

  local killed = 0
  if opts.threats_enabled and predation then
    killed = step_predators(state, dt, stats.defense or 0)
  elseif #state.predators > 0 then
    state.predators = {}
  end
  return killed
end

-- Read-only view for the renderer (callers must not mutate).
function world.snapshot(state)
  return {
    cells = state.cells,
    foods = state.foods,
    blooms = state.blooms,
    prey = state.prey,
    predators = state.predators,
    field = { w = state.field_w, h = state.field_h },
  }
end

world.BASE_FIELD = BASE_FIELD
world.MAX_FIELD = MAX_FIELD
world.MAX_AGENTS = MAX_AGENTS

return world
