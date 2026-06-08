-- World: the live agent sim -- a COSMETIC skin over the authoritative closed-form
-- economy in sim.lua. A myriad of cells drift, sense and chase nutrient motes,
-- engulf prey, and (when predation is unlocked) get hunted by drifting predators.
-- None of this feeds the economy: the only economy couplings live in the
-- orchestrator (a nutrient-bloom click -> sim.feed_burst; a predator kill ->
-- sim.kill; a rare prey engulf -> keep an organelle). world.update just reports
-- the kills, the prey engulfs, and where starving cells died so the orchestrator
-- can route those; everything else here is for the eye.
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

-- The visible swarm is a bounded SAMPLE of the colony. With the open-ended economy
-- the colony reaches millions, which would render as an unreadable blur -- so the
-- on-screen count keeps RISING with the colony but LOGARITHMICALLY, flattening to a
-- readable ceiling. world.sample_count maps colony size -> drawn agents:
--   * 1:1 up to RENDER_KNEE (early game is honest -- every cell shown);
--   * + RENDER_LOG_SLOPE agents per e-fold of colony size beyond the knee;
--   * hard-capped at MAX_AGENTS (the readability + CPU ceiling).
-- All three are tuning knobs -- expect to set them by eye in play (readability vs.
-- "it keeps growing" vs. frame budget).
local MAX_AGENTS = 15000 -- on-screen ceiling (readability + CPU bound; tune by eye)
local RENDER_KNEE = 250 -- show 1:1 up to here, then go logarithmic
-- The log slope is scaled in lockstep with MAX_AGENTS so the ceiling is actually
-- REACHABLE: with the old 150 slope the curve only crept to ~1500 around a 1M
-- colony, so a 10x cap on its own would never be approached. At 1500 the swarm
-- climbs to the new ceiling on the same colony sizes the old one filled at.
local RENDER_LOG_SLOPE = 1500 -- agents added per natural-log e-fold of colony size past the knee
-- Cosmetic fill rate ONLY (caps how many rendered dots bud in per update so a
-- load/offline catch-up animates over a second or two instead of popping in all at
-- once). NOT an economy/progression limit -- the colony size is whatever the sim
-- says, instantly. Scaled up with the 10x MAX_AGENTS so the larger swarm still
-- fills in roughly the same wall-clock time the old 1500 ceiling did.
local MAX_BORN_PER_UPDATE = 40 -- smooth fill-in; no flurry on offline return

-- Colony size -> number of agents to actually draw. Rises forever (slowly) but
-- saturates at MAX_AGENTS, so a 90-cell dish and a 5-million-cell dish both read.
function world.sample_count(population)
  population = math.max(0, math.floor(population or 0))
  if population <= RENDER_KNEE then
    return population
  end
  local n = RENDER_KNEE + math.floor(RENDER_LOG_SLOPE * math.log(population / RENDER_KNEE) + 0.5)
  if n > MAX_AGENTS then
    return MAX_AGENTS
  end
  return n
end
local CELL_SPAWN_SPREAD = 44 -- daughter cell offset from a parent (wide, so births don't seed clumps)
local BIRTH_EMERGE = 0.5 -- seconds a daughter slides out of its parent (mirrors the view's POP_IN)

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
local FED_PULSE = 0.6 -- post-meal swell countdown stamped on the cell when a meal
-- completes (the view reads the entity-level `fed` and pulses the cell's size)

-- Field side steps up in TIERS with colony size: {pop_threshold, field_w},
-- ascending. The field is the largest tier whose threshold the colony has
-- reached -- a step function, so the fit-camera holds steady within a tier and
-- glides out exactly once per crossed threshold.
-- The tiers step out SOONER and FAR wider than the swarm strictly needs: growth
-- should read as the realm opening up -- the camera pulling back, the colony
-- spacing out, food getting genuinely harder to find (see food_target's
-- thinning density) -- so sense range and speed keep visibly mattering at scale
-- instead of saturating once the screen is comfortably full.
local FIELD_TIERS = {
  { 1, 440 },
  { 6, 700 },
  { 15, 1040 },
  { 30, 1520 },
  { 60, 2150 },
  { 120, 2900 },
  { 200, 3600 },
}
local BASE_FIELD = 440 -- starting field side (tier 1); square-root aspect on h.
-- A roomier tier 1 opens the camera a touch wider on the solo founder.
local MAX_FIELD = 3600 -- top tier / hard cap

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
-- Organic wander: each cell random-walks a PRIVATE heading and is nudged along it
-- every frame -- even while steering toward food. Without it a saturated colony
-- locks into a separation-spaced lattice that just pulses toward the nearest motes
-- (every cell sensing food + repelling neighbours settles into a regular grid).
-- The persistent, per-cell heading (vs. raw per-frame white noise, which damps out)
-- makes cells weave on their own curved paths, breaking the lockstep.
local CELL_WANDER = 24 -- wander acceleration along the cell's private heading (always on)
local WANDER_TURN = 2.6 -- how fast that heading drifts, radians/sec random walk
-- Anti-crowding separation: daughter cells push away from nearby cells so the
-- colony spreads instead of clumping (a clump is easy prey -- spreading is for
-- survivability). Cheap via the cell spatial hash.
local SEPARATION_RADIUS = 42 -- cells nearer than this repel each other
local SEPARATION_GAIN = 140 -- how hard they spread apart (must beat STEER_GAIN convergence)

local BLOOM_INTERVAL = 6.5 -- seconds between nutrient-bloom spawns
local BLOOM_LIFE = 3.0 -- ~3s clickable countdown
local BLOOM_MAX = 3 -- simultaneous blooms
local BURST_FOOD = 14 -- motes spawned when a bloom is fed
local DEATH_BURST_FOOD = 4 -- motes a starving cell bursts into (recycled nutrients)

-- Burst physics: motes spray gently outward then relax into ambient milling --
-- a feed, not a detonation. BURST_SPEED scales with the field size so the spray
-- looks proportional on any canvas. BURST_DAMPING bleeds the launch velocity per
-- second so motes settle into normal drift quickly (higher = gentler).
local BURST_SPEED = 130 -- launch speed (world units/sec) at BASE_FIELD scale
local BURST_SETTLE = 1.1 -- seconds of burst phase before ambient milling resumes
local BURST_JITTER = 12 -- position jitter at spawn centre (world units)
local BURST_DAMPING = 1.6 -- velocity damping coefficient during burst phase (gentler)

local PREY_TARGET = 16 -- prey microbes maintained once predation is unlocked
local PREY_DRIFT = 16

local PREDATOR_INTERVAL = 4.0 -- seconds between predator incursions (live-only)
local PREDATOR_LIFE = 8.0 -- a predator leaves after this long
local PREDATOR_SPEED = 78
local PREDATOR_KILL_RADIUS = 11
local PREDATOR_MAX_KILLS = 6 -- cap kills per incursion -- combat is a scare
local PREDATOR_MAX = 5 -- simultaneous predators
local PREDATOR_MIN_CELLS = 6 -- no predators until the colony is worth hunting

-- Starvation (cosmetic, low-cadence): on a fixed STARVE_TICK timer the swarm
-- retires its hungriest few cells -- the ones whose hunger clock has passed
-- STARVE_TIME without a meal -- so a colony spread thin against scarce food
-- visibly thins. Reconcile refills the retired cells (population stays
-- economy-authoritative), so the net is visible churn, not a population change --
-- NO economy coupling. The cadence is decoupled from frame rate, so the death
-- cost is constant whether the game runs at 60 or 6000 fps. STARVE_TIME sits above
-- the view's HUNGER_DIM (8s) so a dying cell visibly pales ~4s before it bursts --
-- death is telegraphed. STARVE_MAX_PER_TICK is capped low (and the cadence slow)
-- so the death rate stays under reconcile's birth budget (MAX_BORN_PER_UPDATE) and
-- a die-off reads as steady thinning; STARVE_FLOOR never retires the last cell.
local STARVE_TICK = 0.5 -- seconds between starvation evaluations (~2 Hz, FPS-independent)
local STARVE_TIME = 12 -- hunger seconds past which a cell is starving (> view HUNGER_DIM)
local STARVE_MAX_PER_TICK = 3 -- hungriest cells retired per tick (steady thinning, under birth budget)
local STARVE_FLOOR = 1 -- never retire the colony below this many cells

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

-- How many ambient food motes to keep at the current field size. NOT constant
-- density: the base motes-per-pixel rate (44 on a 1280x720 canvas) is divided
-- by sqrt(field scale), so nutrient density THINS as the realm tiers out --
-- the mote count still rises with every tier (the larger-field-keeps-more
-- invariant), but each tier is genuinely sparser per area. Scarcity scales
-- with progression: on a vast field a cell must sense further and swim harder
-- to eat, so chemotaxis and motility keep paying off late.
local function food_target(state)
  local scale = state.field_w / BASE_FIELD
  local target = FOOD_DENSITY * state.field_w * state.field_h / math.sqrt(scale)
  return clamp(math.floor(target + 0.5), FOOD_MIN, FOOD_MAX)
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
    starve_timer = STARVE_TICK,
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
-- When (ox, oy) is given it's the PARENT's position: the daughter spawns ON the
-- parent and slides out to (x, y) over BIRTH_EMERGE, so a division visibly buds
-- off an existing cell instead of materialising at the offset. Founder/origin-less
-- births just appear at (x, y) as before.
local function new_cell(state, x, y, ox, oy)
  local seed = rnd(state) -- per-cell wobble phase; drawn before need for determinism
  local need = div_need(state)
  local birthing = ox ~= nil
  state.cells[#state.cells + 1] = {
    x = birthing and ox or x, -- start on the parent while emerging
    y = birthing and oy or y,
    dest_x = x, -- resting spot the emerge slides toward
    dest_y = y,
    birth_x = birthing and ox or nil, -- parent position the emerge slides FROM
    birth_y = birthing and oy or nil,
    birth_t = birthing and BIRTH_EMERGE or nil, -- emerge countdown; nil once roaming
    vx = 0,
    vy = 0,
    age = 0, -- drives the mitosis pop-in (runs in lockstep with the emerge)
    seed = seed,
    wander = seed * 2 * math.pi, -- private wander heading (random-walks each frame)
    eaten = 0, -- morsels engulfed toward `need`
    need = need, -- quota to reach before splitting
    hunger = 0, -- seconds since the last meal; rises while roaming, resets on a meal
    feeding = nil, -- > 0 while engulfing a morsel (remaining seconds)
    feed_target = nil, -- the morsel entity being engulfed
    feed_kind = nil, -- "food" | "prey": what's latched (prey engulfs gate endosymbiosis)
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
    new_cell(state, x, y, parent.x, parent.y) -- bud off the chosen parent
  else
    new_cell(state, state.field_w / 2, state.field_h / 2) -- founder: no parent to emerge from
  end
end

-- Spawn a cell scattered uniformly across the field. Used by reconcile's
-- REBUILD fill (restoring a saved colony into an empty world): that colony
-- already spread out before we ever saw it, so its agents must reappear
-- scattered across the realm -- budding them all off the founder would
-- materialise the whole swarm as one centre clump.
local function spawn_cell_scattered(state)
  new_cell(state, rand_range(state, 0, state.field_w), rand_range(state, 0, state.field_h))
end

-- Retire the k hungriest cells -- the shared death mechanism behind both
-- reconcile's economy cull and the low-cadence starvation tick (one altitude, not
-- two). Rank by the hunger clock (descending), and for each of the top k: release
-- any morsel it was engulfing (so the claim doesn't freeze that mote forever),
-- record its position, and burst it into DEATH_BURST_FOOD recycled motes (smaller
-- particles other cells can re-eat, so a death reads as visible nutrient
-- recycling). Compact the survivors back into state.cells and return the {x,y}
-- death positions. A k <= 0 is a no-op (returns an empty list).
local function retire_hungriest(state, k)
  local deaths = {}
  if k <= 0 then
    return deaths
  end
  local order = {}
  for i = 1, #state.cells do
    order[i] = i
  end
  table.sort(order, function(a, b)
    return (state.cells[a].hunger or 0) > (state.cells[b].hunger or 0)
  end)
  local doomed = {}
  for i = 1, k do
    doomed[order[i]] = true
  end
  local survivors = {}
  for i = 1, #state.cells do
    local c = state.cells[i]
    if doomed[i] then
      if c.feed_target then
        c.feed_target.claimed = nil -- release the morsel so it rejoins the field
      end
      deaths[#deaths + 1] = { x = c.x, y = c.y }
      world.add_food_burst(state, c.x, c.y, DEATH_BURST_FOOD)
    else
      survivors[#survivors + 1] = c
    end
  end
  state.cells = survivors
  return deaths
end

-- Reconcile the swarm toward the colony size and return this frame's budget for
-- EARNED (eating-driven) splits PLUS the positions where cells died (for fx).
-- Three regimes:
--   * shrink   -- over target (the economy-authoritative population fell): retire
--                 the surplus HUNGRIEST cells via retire_hungriest (the shared
--                 death mechanism) and return their death positions for the fx.
--   * founder / fast catch-up -- empty, or the economy leads by more than
--                 CATCHUP_GAP (an offline return): fill directly, rate-limited,
--                 and grant NO earned births this frame (return 0).
--   * trickle  -- within CATCHUP_GAP of target: hand step_cells a budget so the
--                 last cells of the +1 economy trickle are EARNED by eating.
local function reconcile(state, target)
  target = clamp(target, 0, MAX_AGENTS)
  -- Over target (the economy-authoritative population fell): retire the surplus
  -- hungriest via the shared death mechanism; the death positions feed the fx.
  local deaths = retire_hungriest(state, #state.cells - target)
  -- REBUILD detection: an empty world asked to host a multi-cell colony is a
  -- restore (load / offline return), not growth -- only there does the swarm
  -- start from zero with a grown target. The flag rides state until the fill
  -- completes (it spans several rate-limited updates) and routes those spawns
  -- through the scattered placer; every mid-session path still buds off parents.
  if #state.cells == 0 and target > 1 then
    state.rebuilding = true
  end
  if #state.cells == 0 or target - #state.cells > CATCHUP_GAP then
    local born = 0
    while #state.cells < target and born < MAX_BORN_PER_UPDATE do
      if state.rebuilding then
        spawn_cell_scattered(state)
      else
        spawn_cell(state)
      end
      born = born + 1
    end
    if #state.cells >= target then
      state.rebuilding = nil
    end
    return 0, deaths
  end
  state.rebuilding = nil
  return math.min(target - #state.cells, MAX_BORN_PER_UPDATE), deaths
end

-- One low-cadence starvation pass (driven by world.update's STARVE_TICK timer, not
-- per frame): count the cells whose hunger clock has passed STARVE_TIME and retire
-- up to STARVE_MAX_PER_TICK of the hungriest, never dropping below STARVE_FLOOR.
-- Aggregate, not per-cell -- ranking reuses the existing hunger clock (a meal
-- resets it, so a fed cell is never in the set) and the shared retire_hungriest
-- death mechanism. Returns the {x,y} death positions for the view's death-fx.
local function run_starvation(state)
  local starving = 0
  for i = 1, #state.cells do
    if (state.cells[i].hunger or 0) > STARVE_TIME then
      starving = starving + 1
    end
  end
  local k = math.min(starving, STARVE_MAX_PER_TICK, #state.cells - STARVE_FLOOR)
  return retire_hungriest(state, k)
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
-- `continue` in Lua 5.1, so the two states branch with if/else. Tracks per-cell
-- HUNGER (seconds since the last meal; rises while roaming, resets on a meal) so
-- the view can dim the starving and reconcile can cull them first, plus a FED
-- countdown (a completed meal stamps it) the view turns into a brief size pulse.
-- Returns (engulfs, engulf_points): the count of PREY fully engulfed this frame
-- (the endosymbiosis trigger; food engulfs stay plain feeding) and the {x,y}
-- positions of those prey engulfs for the view's reverse-burst fx.
local function step_cells(state, dt, stats, tempo, hunt_prey, births)
  local speed = stats.speed
  local sense = stats.sense_range
  local feed_rate = stats.feed_rate or 1 -- digestion: >1 shortens the feed pause
  local grid = build_hash(state.foods)
  -- Hash the cells too, so each can cheaply repel its crowding neighbors. Built
  -- from this frame's start positions (standard boids); deterministic.
  local cell_grid = build_hash(state.cells)
  local w, h = state.field_w, state.field_h
  -- Personal space grows with the realm: the separation radius scales with
  -- sqrt(field scale), so a grown colony fans out across its wider field
  -- instead of keeping the same tight base-field spacing forever.
  local sep_radius = SEPARATION_RADIUS * math.sqrt(w / BASE_FIELD)
  local engulfs = 0 -- prey fully engulfed this frame
  local engulf_points = {} -- where those prey engulfs completed (reverse-burst fx)
  -- Fixed limit: daughters appended this frame aren't iterated until next frame.
  for ci = 1, #state.cells do
    local c = state.cells[ci]
    c.age = c.age + dt
    c.hunger = (c.hunger or 0) + dt -- starvation clock; a completed meal resets it
    if c.fed then
      c.fed = c.fed - dt -- drain the post-meal swell countdown the view pulses on
      if c.fed <= 0 then
        c.fed = nil
      end
    end

    if c.birth_t then
      -- === emerging: a fresh daughter slides out of its parent ===
      -- Ease (out-quadratic) from the parent's position to the resting offset over
      -- BIRTH_EMERGE, in lockstep with the view's age-driven pop-in scale, so the
      -- division reads as budding off an existing cell rather than popping in apart.
      c.birth_t = c.birth_t - dt
      local k = clamp(1 - c.birth_t / BIRTH_EMERGE, 0, 1) -- 0 at birth -> 1 when settled
      local ease = 1 - (1 - k) * (1 - k)
      c.x = c.birth_x + (c.dest_x - c.birth_x) * ease
      c.y = c.birth_y + (c.dest_y - c.birth_y) * ease
      c.x, c.y = c.x % w, c.y % h
      if c.birth_t <= 0 then
        c.birth_t = nil -- emerge done: roam normally next frame
        c.x, c.y = c.dest_x % w, c.dest_y % h
      end
    elseif c.feeding then
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
          c.hunger = 0 -- a fed cell resets its starvation clock
          c.fed = FED_PULSE -- stamp the post-meal swell the view pulses on
          if c.feed_kind == "prey" then
            engulfs = engulfs + 1 -- a completed PREY engulf may keep an organelle
            engulf_points[#engulf_points + 1] = { x = c.x, y = c.y }
          end
          c.feed_kind = nil
          c.eaten = c.eaten + 1
          if c.eaten >= c.need and births > 0 then
            new_cell(state, c.x + rsign(state) * CELL_SPAWN_SPREAD, c.y + rsign(state) * CELL_SPAWN_SPREAD, c.x, c.y)
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

      local agit = 0.5 + tempo
      if tx then
        local dx, dy = tx - c.x, ty - c.y
        local d = math.sqrt(dx * dx + dy * dy) + 1e-6
        c.vx = c.vx + (dx / d) * speed * STEER_GAIN * dt
        c.vy = c.vy + (dy / d) * speed * STEER_GAIN * dt
      else
        c.vx = c.vx + rsign(state) * CELL_DRIFT * agit * dt
        c.vy = c.vy + rsign(state) * CELL_DRIFT * agit * dt
      end

      -- Organic wander (always on, even while chasing food): random-walk the cell's
      -- private heading and push gently along it. Breaks the separation-spaced
      -- lattice a saturated colony otherwise settles into -- cells weave instead of
      -- pulsing in lockstep toward the nearest motes.
      c.wander = (c.wander or 0) + rsign(state) * WANDER_TURN * dt
      c.vx = c.vx + math.cos(c.wander) * CELL_WANDER * agit * dt
      c.vy = c.vy + math.sin(c.wander) * CELL_WANDER * agit * dt

      -- Spread from crowding neighbors (survivability): always on, so the colony
      -- fans out even while everyone chases the same bloom.
      local px, py = separation_push(cell_grid, state.cells, ci, c.x, c.y, sep_radius)
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
          c.feed_kind = target_kind -- remember food vs prey for the engulf count
          entity.claimed = true
        end
      end
    end
  end
  compact(state.foods)
  compact(state.prey)
  return engulfs, engulf_points
end

-- True when (x, y) falls inside rect r ({ x, y, w, h }).
local function in_rect(r, x, y)
  return x >= r.x and x <= r.x + r.w and y >= r.y and y <= r.y + r.h
end

local function step_blooms(state, dt, exclude)
  state.bloom_timer = state.bloom_timer - dt
  if state.bloom_timer <= 0 then
    state.bloom_timer = BLOOM_INTERVAL + rand_range(state, -1.5, 1.5)
    if #state.blooms < BLOOM_MAX then
      -- Bloom appears at a world position in the interior of the field; its drawn
      -- size is a constant on-screen UI size owned by the view, not a world scale.
      -- The position must avoid `exclude` -- the SAFE ZONE the orchestrator
      -- projects from its screen UI (the right-edge panel) into world space --
      -- so the clickable never spawns hidden (and unclickable) behind a menu.
      -- Rejection-sample a few tries, then fall back to a point nudged just
      -- outside the rect's left edge so a spawn always lands somewhere legal.
      local x, y
      for _ = 1, 12 do
        x = rand_range(state, state.field_w * 0.2, state.field_w * 0.85)
        y = rand_range(state, state.field_h * 0.15, state.field_h * 0.85)
        if not (exclude and in_rect(exclude, x, y)) then
          break
        end
        x = nil
      end
      if not x then
        x = math.max(state.field_w * 0.2, exclude.x - 1)
        y = rand_range(state, state.field_h * 0.15, state.field_h * 0.85)
      end
      state.blooms[#state.blooms + 1] = {
        x = x,
        y = y,
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

-- Live-only predators. Returns (killed, kill_points): the number of cells killed
-- this update so the orchestrator can debit the colony (sim.kill), AND the {x,y}
-- positions of those kills so the view can burst each into RED particles (distinct
-- from the cell-colored starvation burst). Evasion lets a cell flee a strike, so
-- the evasion trait visibly matters.
local function step_predators(state, dt, evasion)
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
  local kill_points = {}
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
        if rnd(state) >= evasion then -- evasion is the flee/dodge chance
          -- Free any morsel the victim was engulfing so it rejoins the drifting
          -- field (an orphaned claim would otherwise freeze the mote forever).
          if c.feed_target then
            c.feed_target.claimed = nil
          end
          kill_points[#kill_points + 1] = { x = c.x, y = c.y }
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
  return killed, kill_points
end

-- Advance the whole sim one frame. opts:
--   stats             -- folded trait stats (speed, sense_range, evasion, ...)
--   dial_tempo        -- the metabolism dial [0,1], live agitation
--   aspect            -- field width/height ratio; defaults to 16/9
--   target_population -- colony size to reconcile toward (capped at MAX_AGENTS)
--   unlocked          -- the unlocked capability set (predation -> prey/predators)
--   threats_enabled   -- whether predators may appear (live-only)
--   bloom_exclude     -- optional world-space rect { x, y, w, h } blooms must
--                        avoid (screen UI -- the panel -- projected to world)
-- Returns (killed, engulfs, death_points, kill_points, engulf_points): cells
-- killed by predators (debit the colony), prey fully engulfed this frame (roll
-- endosymbiosis), the positions where cells STARVED -- both reconcile's economy
-- cull and the low-cadence starvation turnover -- for the cell-colored death-fx,
-- the positions where cells were KILLED by predators for the red death-fx, and
-- the positions where PREY engulfs completed for the reverse-burst feed-fx
-- (cosmetic; no economy coupling beyond the existing kill debit).
function world.update(state, dt, opts)
  opts = opts or {}
  local stats = opts.stats or { speed = 60, sense_range = 70, evasion = 0 }
  local tempo = opts.dial_tempo or 0.5
  local unlocked = opts.unlocked or {}
  local predation = unlocked.predation == true
  local aspect = opts.aspect or (16 / 9)

  -- Field size is computed FIRST so every spawner and drifter sees a coherent
  -- field extent. It is a STEP function of colony size (FIELD_TIERS): steady
  -- within a tier, stepping out one notch at each crossed threshold. The size
  -- RATCHETS: once a tier is reached it never steps back down, so a transient
  -- population dip doesn't zoom the camera back in.
  local pop = math.max(opts.target_population or 0, 1)
  local new_w = math.max(state.field_w, field_for_population(pop))
  if new_w > state.field_w then
    -- RECENTRE on a tier step: the field grows anchored at the origin, which
    -- would strand the old realm's inhabitants in the top-left corner of the
    -- wider field (the camera centres the FIELD, not them). Shift every
    -- entity by half the growth so the old realm's centre stays the new
    -- realm's centre and the zoom-out reads as the world opening up AROUND
    -- the colony. Uniform shift: all relative geometry (latches, emerges,
    -- chases) is preserved exactly.
    local dx = (new_w - state.field_w) / 2
    local dy = (new_w / aspect - state.field_h) / 2
    local function shift(list)
      for i = 1, #list do
        local e = list[i]
        e.x, e.y = e.x + dx, e.y + dy
      end
    end
    shift(state.foods)
    shift(state.blooms)
    shift(state.prey)
    shift(state.predators)
    for i = 1, #state.cells do
      local c = state.cells[i]
      c.x, c.y = c.x + dx, c.y + dy
      c.dest_x, c.dest_y = c.dest_x + dx, c.dest_y + dy
      if c.birth_x then
        c.birth_x, c.birth_y = c.birth_x + dx, c.birth_y + dy
      end
    end
  end
  state.field_w = new_w
  state.field_h = state.field_w / aspect

  -- Starvation (cosmetic, low-cadence): tick the STARVE_TICK timer -- decoupled
  -- from frame rate, so the death cost is constant at any fps -- and when it fires
  -- (~2 Hz) retire the hungriest starving cells. Runs just BEFORE reconcile so the
  -- same-frame refill backfills the retirements: the swarm holds at the
  -- economy-authoritative size and the player sees turnover (a dimmed cell bursts,
  -- a fresh one pops in elsewhere), not a population drop.
  local starve_deaths
  state.starve_timer = state.starve_timer - dt
  if state.starve_timer <= 0 then
    state.starve_timer = STARVE_TICK
    starve_deaths = run_starvation(state)
  end

  -- The SIMULATED cell set is bounded by sim_cap (the visible swarm is now a GPU
  -- procedural field in the view, decoupled from this set -- world.lua keeps only a
  -- small invisible set to drive the gameplay events: predator kills, prey engulfs,
  -- starvation/feed bursts). Field SIZE still tracks the true colony (pop, above),
  -- so the realm opens up as the colony grows; only the count we step is capped.
  -- Default = MAX_AGENTS, so callers that omit sim_cap (the specs) are unchanged.
  local sim_target = math.min(opts.target_population or 0, opts.sim_cap or MAX_AGENTS)
  local births, deaths = reconcile(state, sim_target)
  -- The starvation retirements ride the same death-points channel as the cull.
  if starve_deaths then
    for i = 1, #starve_deaths do
      deaths[#deaths + 1] = starve_deaths[i]
    end
  end
  ensure_field(state, state.foods, food_target(state), FOOD_DRIFT, RENDER_FOOD)
  drift_field(state, state.foods, dt, FOOD_DRIFT)

  if predation then
    ensure_field(state, state.prey, PREY_TARGET, PREY_DRIFT, RENDER_PREY)
    drift_field(state, state.prey, dt, PREY_DRIFT)
  elseif #state.prey > 0 then
    state.prey = {}
  end

  local engulfs, engulf_points = step_cells(state, dt, stats, tempo, predation, births)
  -- Keep the ambient field replenished after consumption.
  ensure_field(state, state.foods, food_target(state), FOOD_DRIFT, RENDER_FOOD)
  step_blooms(state, dt, opts.bloom_exclude)

  local killed = 0
  local kill_points
  if opts.threats_enabled and predation then
    killed, kill_points = step_predators(state, dt, stats.evasion or 0)
  elseif #state.predators > 0 then
    state.predators = {}
  end
  return killed, engulfs, deaths, kill_points, engulf_points
end

-- The mean position of the live swarm (field centre when empty). Used to place
-- the endosymbiosis beat amid the colony -- a moment the player witnesses.
function world.swarm_center(state)
  local n = #state.cells
  if n == 0 then
    return state.field_w / 2, state.field_h / 2
  end
  local sx, sy = 0, 0
  for i = 1, n do
    sx = sx + state.cells[i].x
    sy = sy + state.cells[i].y
  end
  return sx / n, sy / n
end

-- Smart-framing weights: where the "action" is. A bloom is the player's
-- clickable target and a predator incursion is the drama, so each pulls much
-- harder than a single cell; once the colony is large its mass dominates --
-- the colony IS the action then. Prey/food are ambient and don't pull.
local ACTION_W_CELL = 1
local ACTION_W_BLOOM = 6
local ACTION_W_PREDATOR = 8

-- The weighted centre of the action (cells + blooms + predators), computed as a
-- per-axis CIRCULAR mean so it is toroidal-correct: a swarm straddling the wrap
-- seam (half at x~0, half at x~field_w) averages to the seam, not to the field
-- centre like a naive mean would. Each coordinate maps to an angle around the
-- torus, the weighted unit vectors are summed, and atan2 maps back. An axis
-- whose vector sum is ~zero (action spread evenly around the torus) has no
-- meaningful centre and falls back to the field centre, as does an empty world.
-- The view biases its fit-camera toward this point (within the seam margin).
function world.action_center(state)
  local w, h = state.field_w, state.field_h
  local tau = 2 * math.pi
  local cx, sx, cy, sy, total = 0, 0, 0, 0, 0
  local function add(list, weight)
    for i = 1, #list do
      local e = list[i]
      local ax, ay = e.x / w * tau, e.y / h * tau
      cx = cx + math.cos(ax) * weight
      sx = sx + math.sin(ax) * weight
      cy = cy + math.cos(ay) * weight
      sy = sy + math.sin(ay) * weight
      total = total + weight
    end
  end
  add(state.cells, ACTION_W_CELL)
  add(state.blooms, ACTION_W_BLOOM)
  add(state.predators, ACTION_W_PREDATOR)
  local function resolve(s, c, span)
    if total == 0 or s * s + c * c < 1e-9 then
      return span / 2
    end
    return (math.atan2(s, c) / tau % 1) * span
  end
  return resolve(sx, cx, w), resolve(sy, cy, h)
end

-- Read-only view for the renderer (callers must not mutate). `action` is the
-- toroidal action centre the view's smart framing pans toward.
function world.snapshot(state)
  local ax, ay = world.action_center(state)
  return {
    cells = state.cells,
    foods = state.foods,
    blooms = state.blooms,
    prey = state.prey,
    predators = state.predators,
    field = { w = state.field_w, h = state.field_h },
    action = { x = ax, y = ay },
  }
end

world.BASE_FIELD = BASE_FIELD
world.MAX_FIELD = MAX_FIELD
world.MAX_AGENTS = MAX_AGENTS

return world
