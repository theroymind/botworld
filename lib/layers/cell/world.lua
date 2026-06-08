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
local RENDER_LOG_SLOPE = 900 -- agents added per natural-log e-fold of colony size past the knee. Lowered from 1500: with the field now extending to the millions, a gentler count growth keeps the swarm SPREAD (readable spacing) instead of cramming -- density = drawn cells / field area, and we want it to hold as both rise.
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
-- A daughter BUDS right beside its parent (about a cell-width), then disperses on
-- its own under the normal wander + separation push -- so a division reads as "the
-- cell duplicated in place, then the daughter swam off" rather than the daughter
-- being flung to a distant resting spot. Kept small on purpose; separation fans the
-- colony out afterward, so a tight bud no longer seeds a permanent clump.
local CELL_SPAWN_SPREAD = 8 -- daughter bud offset from the parent (~a cell-width)
local BIRTH_EMERGE = 0.8 -- seconds the daughter eases off the parent (grows in over the view's POP_IN first, then noses clear)

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
-- The thresholds are deliberately HIGH so each tier SATURATES before it steps:
-- the dish should look genuinely full of cells before the camera pulls back, not
-- pull back while it is still sparse. They climb geometrically (~3x), matching the
-- colony's exponential growth, so the zoom-outs feel evenly paced in time rather
-- than bunched into the early game. A pullback then reads as the realm opening up --
-- the colony spacing out, food thinning (see food_target) -- earned by a packed dish.
-- Extended PAST 100k all the way to the millions: the colony climbs to ~1-3M before
-- the endosymbiosis exit, so the field must keep OPENING UP across that whole range --
-- the old top tier (100k/3600) left the entire 100k->millions late game with NO
-- zoom-out, so the swarm crammed into a frozen dish (extreme density; reach traits
-- stopped mattering). Tier WIDTHS now HOLD a readable density as the drawn-cell count
-- grows (see sample_count): area scales ~with drawn cells, so spacing stays around the
-- separation radius and the colony reads as SPREADING into new territory rather than
-- overpopulating. Widths are by-eye -- expect to nudge denser/sparser in playtest.
-- Widths are density-matched: width ~= 60*sqrt(drawn cells at that pop) holds a
-- CONSTANT ~50px average spacing (just above the 42px separation radius) at every
-- tier, so the swarm stays comfortably spread the whole way up instead of cramming
-- (the old table ran ~16-23px spacing -- packed solid -- and froze at 100k). The
-- founder tier stays a cozy 440 on purpose; the first step to ~1360 is the "the
-- colony established, now it spreads" beat.
-- The thresholds double as DIFFICULTY thresholds: each one crossed is a "you've
-- grown more, so more risk" beat (see tier_rank/menace below -- predators thicken
-- as the colony climbs the tiers). Two extra steps were added in the busy mid-late
-- band -- 50k (10s-of-thousands) and 500k (hundreds-of-thousands) -- so the long
-- 30k->100k and 300k->1M stretches each get an intermediate zoom-out + menace bump
-- instead of holding one frozen tier across a 3x population climb. Their widths
-- follow the same density law as their neighbours (width ~= 66.7*sqrt(drawn cells)).
local FIELD_TIERS = {
  { 1, 440 },
  { 300, 1360 },
  { 1000, 2580 },
  { 3000, 3330 },
  { 10000, 3980 },
  { 30000, 4500 },
  { 50000, 4720 },
  { 100000, 5010 },
  { 300000, 5430 },
  { 500000, 5620 },
  { 1000000, 5860 },
  { 3000000, 6220 },
}
local BASE_FIELD = 440 -- starting field side (tier 1); square-root aspect on h.
-- A roomier tier 1 opens the camera a touch wider on the solo founder.
local MAX_FIELD = 6220 -- top tier / hard cap (millions-scale realm)

-- Render components: world tags each entity with a lightweight, color-free
-- descriptor; the view owns the palette/sizes and draws every entity as a flat
-- square. These uniform kinds share one read-only table (cells animate via the
-- per-entity `age`, not per-instance render state); blooms carry a per-instance
-- size, so they build their own.
local RENDER_CELL = { kind = "cell", pop_in = true }
local RENDER_FOOD = { kind = "food" }
local RENDER_PREY = { kind = "prey" }
local RENDER_PREDATOR = { kind = "predator" }
-- Neutral competitor microbes share one frozen, color-free descriptor (mirrors
-- RENDER_PREY): the view binds a rival color/size to this `kind`; world sets none.
local RENDER_COMPETITOR = { kind = "competitor" }

-- Ambient food density expressed as motes per pixel (calibrated to 44 motes on
-- a 1280x720 canvas). The target count is recomputed from the live field area
-- each frame, staying density-constant as the field expands.
local FOOD_DENSITY = 44 / (1280 * 720)
local FOOD_MIN = 8 -- never starve a tiny colony
local FOOD_MAX = 220 -- cap so even a full-sized field stays readable (raised with the millions-scale field so the vast late realm isn't food-barren; the sqrt density-thinning still keeps motes SPARSE per area, so Chemotaxis/reach keeps paying off)

local FOOD_DRIFT = 12 -- mote brownian speed, world units/sec
local CONSUME_RADIUS = 9 -- a cell this close to its target eats it

local CELL_DRIFT = 26 -- wander acceleration when nothing is sensed
local CELL_DAMPING = 1.6 -- velocity bleed per second
local STEER_GAIN = 4.0 -- how hard a cell accelerates toward sensed food
-- Per-cell speed VARIETY: each cell draws a private speed multiplier at birth, so
-- the swarm isn't a uniform shoal moving in lockstep -- some cells are visibly
-- friskier, some sluggish, even at the same motility level. Drawn in [LO, HI]
-- around 1.0, so the colony's MEAN swim speed still tracks the motility stat
-- (the upgrade still reads); only the per-cell spread is randomized.
local SPEED_VAR_LO = 0.6 -- slowest cell is 60% of the trait speed
local SPEED_VAR_HI = 1.4 -- fastest cell is 140% of the trait speed
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

-- Neutral COMPETITOR cells: other-colored microbes that drift through the dish as
-- the visual SKIN of the closed-form nutrient competition (which already throttles
-- the economy in sim.lua/cell.lua). They are PURELY decorative: not eaten by your
-- cells, they eat nothing of yours, predators ignore them, and they feed NOTHING
-- back into world.update's economy-routed returns. They just wander and wrap the
-- toroidal field, selling "a contested, crowded dish."
--
-- The maintained count scales on two axes (mirroring how food/prey targets read):
--   * opts.competition (0..1, the closed-form competition ramp) -- 0 keeps none,
--     1 fills the dish with a meaningful but not overwhelming rival crowd;
--   * field area / sqrt(field scale) -- the SAME density law food_target uses, so
--     a wider realm holds more competitors yet stays consistent per area as it
--     tiers out (rivals don't suddenly vanish or swamp the view at a step).
-- COMPETITOR_DENSITY is the per-pixel rival rate at FULL competition (calibrated to
-- COMPETITOR_FULL motes on a 1280x720 canvas); the live target multiplies it by the
-- competition intensity. COMPETITOR_MAX caps the crowd so even a vast, fully
-- contested field stays readable.
local COMPETITOR_FULL = 110 -- rival microbes on a 1280x720 canvas at competition = 1 (raised from 70: a busier, more contested dish)
local COMPETITOR_DENSITY = COMPETITOR_FULL / (1280 * 720)
local COMPETITOR_MAX = 340 -- readability cap on the rival crowd at any field size (raised from 200 with the denser crowd)
local COMPETITOR_DRIFT = 14 -- rival brownian speed, world units/sec (their own gentle wander)

-- Per-instance SIZE VARIETY for the non-player actors (predators + competitors): each
-- one draws a private size scale at spawn so the dish shows a real spread of body
-- sizes -- from small darting microbes to looming giants -- instead of a uniform stamp.
-- The scale is COLOR/UNIT-free here (just a multiplier); the view multiplies it by its
-- own CELL_SIZE basis, so "0.5x..5x the cell" is honored wherever the view sets that.
local ACTOR_SIZE_MIN = 0.5 -- smallest body: half a cell
local ACTOR_SIZE_MAX = 5.0 -- largest body: five cells (a looming giant)

-- Predators are the visible THREAT, and they are PERSISTENT roaming enemies: once
-- the colony is worth hunting a standing pack is MAINTAINED that prowls the dish
-- indefinitely (they do NOT expire on a life timer -- the scene always has enemies
-- on patrol). Each predator only FEEDS occasionally: between feeds it wanders, and
-- when its feed cooldown elapses it darts at the nearest cell, strikes once, then
-- breaks off and prowls again -- so combat stays an intermittent scare, not a wipe.
-- The pack THICKENS with the difficulty tier (the menace 0..1 from tier_rank below):
-- a founder dish has a small patrol, a millions-scale colony is harried by a denser,
-- hungrier pack -- "you've grown more, more risk." Both the standing count and the
-- feed frequency rise with menace.
local PREDATOR_REPLENISH = 2.0 -- seconds between bringing one more predator in toward the target
local PREDATOR_SPEED = 84 -- chase speed during a feed lunge
local PREDATOR_ROAM_SPEED = 30 -- idle prowl speed (slower, menacing drift)
local PREDATOR_TURN = 2.0 -- prowl heading random-walk rate (rad/s)
local PREDATOR_KILL_RADIUS = 11
local PREDATOR_FEED_COOLDOWN = 6.0 -- base seconds a predator prowls between feeds (shortens with menace)
local PREDATOR_FEED_MENACE = 0.5 -- fraction the feed cooldown shrinks at full menace (=> ~3s at the top tier)
local PREDATOR_HUNT_TIME = 3.5 -- max seconds a predator commits to a lunge before giving up and prowling
local PREDATOR_MAX = 6 -- base standing pack size at tier 1
local PREDATOR_MAX_MENACE = 5 -- extra predators in the pack at full menace (=> 11 at the top tier)
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

-- The DIFFICULTY tier the colony has reached: the index of the largest FIELD_TIERS
-- threshold crossed (1 at the founder, #FIELD_TIERS at the top). The field tiers ARE
-- the difficulty thresholds, so risk steps in lockstep with the zoom-outs.
local function tier_rank(pop)
  local rank = 1
  for i = 1, #FIELD_TIERS do
    if pop >= FIELD_TIERS[i][1] then
      rank = i
    else
      break
    end
  end
  return rank
end

-- The MENACE scalar: tier rank mapped to 0..1 (0 at the founder tier, 1 at the top).
-- Predator density/cadence ramp on this, so "grown more = more risk" reads on screen.
local function menace_for_population(pop)
  return (tier_rank(pop) - 1) / (#FIELD_TIERS - 1)
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

-- How many neutral competitor microbes to keep at the current competition
-- intensity and field size. Mirrors food_target's density law so the rival crowd
-- reads consistent as the realm tiers out: the per-pixel rate (COMPETITOR_DENSITY,
-- the full-competition rate) is scaled by the live competition intensity (0..1) and
-- by field area / sqrt(field scale), then clamped to COMPETITOR_MAX. Competition 0
-- yields a target of 0 (no rivals), and the count rises with a wider field yet
-- stays sparse-per-area on the larger tiers -- so density never swamps the view.
-- Purely cosmetic: this count feeds NOTHING back into the economy.
local function competitor_target(state, competition)
  competition = clamp(competition or 0, 0, 1)
  if competition <= 0 then
    return 0
  end
  local scale = state.field_w / BASE_FIELD
  local target = COMPETITOR_DENSITY * competition * state.field_w * state.field_h / math.sqrt(scale)
  return clamp(math.floor(target + 0.5), 0, COMPETITOR_MAX)
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
    competitors = {}, -- neutral rival microbes (cosmetic skin of nutrient competition)
    bloom_timer = BLOOM_INTERVAL,
    predator_timer = PREDATOR_REPLENISH,
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
  local speed_mult = rand_range(state, SPEED_VAR_LO, SPEED_VAR_HI) -- private swim-speed spread
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
    speed_mult = speed_mult, -- per-cell swim-speed multiplier (the variety; ~[0.6, 1.4])
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
-- zoom onto it without hunting), else a daughter BUDDED off a random existing
-- parent (it emerges from the parent, never a parentless drop). Used by reconcile's
-- founder / fast-catch-up fill; an EARNED split calls new_cell directly beside the
-- dividing cell.
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
  -- Fast-fill regime: an empty world, or the economy leading the swarm by more than
  -- CATCHUP_GAP (e.g. an offline return restoring a grown colony). Fill directly,
  -- rate-limited, and grant no earned births this frame. EVERY spawn buds off a
  -- parent -- the founder first (the only cell with no parent), then each subsequent
  -- one off a random EXISTING cell -- so even a restored colony GROWS OUTWARD by
  -- budding rather than materialising cells at random spots with no parent. There is
  -- no longer a parentless "scattered" placer: nothing ever appears out of nowhere.
  if #state.cells == 0 or target - #state.cells > CATCHUP_GAP then
    local born = 0
    while #state.cells < target and born < MAX_BORN_PER_UPDATE do
      spawn_cell(state)
      born = born + 1
    end
    return 0, deaths
  end
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

-- Top up the neutral-competitor crowd, stamping each new rival with a per-instance
-- `tint` in [0,1) -- a COLOR-FREE species seed (world owns no palette). The view
-- buckets that scalar into one of its vibrant rival colors, so the dish reads as
-- several distinct rival SPECIES jostling for the same food rather than one grey
-- mass. Mirrors ensure_field otherwise (uniform spawn + the shared frozen render
-- component); the tint is the only per-instance addition.
local function ensure_competitors(state, target)
  while #state.competitors < target do
    state.competitors[#state.competitors + 1] = {
      x = rand_range(state, 0, state.field_w),
      y = rand_range(state, 0, state.field_h),
      vx = rsign(state) * COMPETITOR_DRIFT,
      vy = rsign(state) * COMPETITOR_DRIFT,
      tint = rnd(state), -- color-free species seed; the view maps it to a rival hue
      size_scale = rand_range(state, ACTOR_SIZE_MIN, ACTOR_SIZE_MAX), -- private body-size spread (0.5x..5x a cell)
      render = RENDER_COMPETITOR,
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
      -- === emerging: a fresh daughter buds off its parent ===
      -- Ease (SMOOTHSTEP -- slow at both ends, so no initial dash) from the parent's
      -- position to the tight bud offset over BIRTH_EMERGE, while the view's age-driven
      -- pop-in swells it in. The cell barely separates here; it's the duplication beat.
      -- Once birth_t clears it roams normally and the wander/separation carry it away.
      c.birth_t = c.birth_t - dt
      local k = clamp(1 - c.birth_t / BIRTH_EMERGE, 0, 1) -- 0 at birth -> 1 when settled
      local ease = k * k * (3 - 2 * k) -- smoothstep: eases in AND out, no fast start
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

      -- Damp and clamp to the cell's swim speed -- scaled by its PRIVATE speed_mult
      -- so the swarm shows a spread of paces instead of one uniform top speed.
      local damp = math.max(0, 1 - CELL_DAMPING * dt)
      c.vx, c.vy = c.vx * damp, c.vy * damp
      local cell_speed = speed * (c.speed_mult or 1)
      local sp = math.sqrt(c.vx * c.vx + c.vy * c.vy)
      if sp > cell_speed then
        c.vx, c.vy = c.vx / sp * cell_speed, c.vy / sp * cell_speed
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

-- Persistent, live-only predators. Returns (killed, kill_points): the number of
-- cells killed this update so the orchestrator can debit the colony (sim.kill), AND
-- the {x,y} positions of those kills so the view can burst each into RED particles
-- (distinct from the cell-colored starvation burst). Evasion lets a cell flee a
-- strike, so the evasion trait visibly matters.
--
-- The pack is MAINTAINED rather than spawned-then-expired: once the colony is worth
-- hunting, predators drift in from the edges to fill a menace-scaled target and then
-- PROWL the dish indefinitely (random-walking their heading, wrapping the torus) so
-- the scene always has roaming enemies. Each predator only FEEDS occasionally: a
-- per-predator feed cooldown ticks down while it prowls, and when it elapses the
-- predator commits to a brief LUNGE -- chasing the nearest cell at full speed until
-- it strikes once (a kill, or a dodge if the cell evades) or the hunt window lapses
-- -- then breaks off, resets its cooldown, and prowls again. More menace = a bigger
-- pack AND a shorter cooldown (it feeds more often), so threat reads on screen.
local function step_predators(state, dt, evasion, menace)
  menace = clamp(menace or 0, 0, 1)
  local huntable = #state.cells >= PREDATOR_MIN_CELLS
  -- Menace scales the standing pack size and how often each predator feeds.
  local target = PREDATOR_MAX + math.floor(PREDATOR_MAX_MENACE * menace + 0.5)
  local feed_cd = PREDATOR_FEED_COOLDOWN * (1 - PREDATOR_FEED_MENACE * menace)

  -- Replenish the pack toward the target: bring one predator in from a random edge
  -- per replenish tick (gradual, so they don't all pop in at once). No life timer --
  -- predators persist until predation is dropped (world.update clears them then).
  state.predator_timer = state.predator_timer - dt
  if state.predator_timer <= 0 then
    state.predator_timer = PREDATOR_REPLENISH + rand_range(state, -0.5, 0.5)
    if huntable and #state.predators < target then
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
      state.predators[#state.predators + 1] = {
        x = x,
        y = y,
        seed = rnd(state),
        size_scale = rand_range(state, ACTOR_SIZE_MIN, ACTOR_SIZE_MAX), -- private body-size spread (0.5x..5x a cell)
        render = RENDER_PREDATOR,
        heading = rnd(state) * 2 * math.pi, -- prowl direction (random-walked)
        feed_cd = rand_range(state, feed_cd * 0.4, feed_cd), -- desync the first feeds
        hunt_t = 0, -- > 0 while committed to a lunge
      }
    end
  end

  -- Trim if the target dropped below the live pack (menace ratchets up with the
  -- tiers, so this is rare -- it just keeps the count honest). Remove from the tail.
  while #state.predators > target do
    table.remove(state.predators)
  end

  local killed = 0
  local kill_points = {}
  local w, h = state.field_w, state.field_h
  for pi = #state.predators, 1, -1 do
    local p = state.predators[pi]
    p.feed_cd = (p.feed_cd or 0) - dt
    -- Commit to a feed lunge once the cooldown elapses and there's a colony to hit.
    if (not p.hunt_t or p.hunt_t <= 0) and huntable and p.feed_cd <= 0 then
      p.hunt_t = PREDATOR_HUNT_TIME
    end

    if p.hunt_t and p.hunt_t > 0 then
      -- === FEEDING: chase the nearest cell and strike on contact ===
      p.hunt_t = p.hunt_t - dt
      local best, target_ci = math.huge, nil
      for ci = 1, #state.cells do
        local c = state.cells[ci]
        local dx, dy = c.x - p.x, c.y - p.y
        local d2 = dx * dx + dy * dy
        if d2 < best then
          best, target_ci = d2, ci
        end
      end
      if target_ci then
        local c = state.cells[target_ci]
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
            table.remove(state.cells, target_ci)
            killed = killed + 1
          end
          -- A completed strike (hit OR dodge) ends the lunge: break off, reset the
          -- cooldown with jitter, and prowl again -- each predator feeds occasionally
          -- rather than mowing through the colony.
          p.hunt_t = 0
          p.feed_cd = feed_cd + rand_range(state, -1.0, 1.5)
        end
      else
        p.hunt_t = 0 -- nothing to hunt; back to prowling
      end
    else
      -- === PROWLING: random-walk the heading and drift slowly across the dish ===
      p.heading = (p.heading or 0) + rsign(state) * PREDATOR_TURN * dt
      p.x = p.x + math.cos(p.heading) * PREDATOR_ROAM_SPEED * dt
      p.y = p.y + math.sin(p.heading) * PREDATOR_ROAM_SPEED * dt
    end
    -- Toroidal wrap so a prowling predator endlessly roams instead of leaving.
    p.x = p.x % w
    p.y = p.y % h
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
    shift(state.competitors) -- rivals recentre with the realm like every other entity
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

  -- Neutral competitor microbes: maintain a target count that scales with the
  -- closed-form competition ramp (opts.competition, nil-safe -> 0) AND the field
  -- size, then drift them with the shared drift_field wander so they wrap the
  -- toroidal realm like every other entity. They are spawned through the same
  -- ensure_field path (an entity + a frozen render component), NOT fed to
  -- step_cells (cells never forage them) and NOT seen by step_predators (which only
  -- iterates state.cells), so they neither eat nor are eaten nor are hunted. When
  -- competition is 0/absent the target is 0; clear any existing crowd outright, the
  -- way prey is cleared when predation is off -- so dialing competition back to 0
  -- empties the rivals rather than freezing a stale crowd.
  local comp_target = competitor_target(state, opts.competition)
  if comp_target > 0 then
    ensure_competitors(state, comp_target) -- per-instance species tint (the view colors it)
    drift_field(state, state.competitors, dt, COMPETITOR_DRIFT)
  elseif #state.competitors > 0 then
    state.competitors = {}
  end

  local engulfs, engulf_points = step_cells(state, dt, stats, tempo, predation, births)
  -- Keep the ambient field replenished after consumption.
  ensure_field(state, state.foods, food_target(state), FOOD_DRIFT, RENDER_FOOD)
  step_blooms(state, dt, opts.bloom_exclude)

  local killed = 0
  local kill_points
  if opts.threats_enabled and predation then
    killed, kill_points = step_predators(state, dt, stats.evasion or 0, menace_for_population(pop))
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
    competitors = state.competitors, -- neutral rival microbes (cosmetic drift)
    field = { w = state.field_w, h = state.field_h },
    action = { x = ax, y = ay },
  }
end

world.BASE_FIELD = BASE_FIELD
world.MAX_FIELD = MAX_FIELD
world.MAX_AGENTS = MAX_AGENTS

return world
