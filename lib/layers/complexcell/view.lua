-- Complex-cell view: programmatic, asset-free visuals for the INTERIOR of a single
-- eukaryotic cell -- the phase-2 sibling of lib/layers/cell/view.lua. Same discipline:
-- love.* is touched ONLY inside draw-time code (so a bare `require` loads headless),
-- transient beats compose through an fx controller (lib/engine/fx.lua), and every
-- color binds a GLOBAL token from lib/engine/ui/colors -- no literal RGB, no per-layer
-- palette. Where phase 1 framed a dish of flat squares with a stepped fit-camera, this
-- view frames the cytoplasm of ONE cell and aims a swarm INWARD: organelle clusters,
-- and a teeming cloud of vesicles/cargo hauling between them, inside a big wobbling
-- membrane. The orchestrator (complexcell.lua) draws the panel/HUD on top -- this file
-- draws NOTHING of the UI.
--
-- THE SWARM IS GPU-INSTANCED (the upgrade from the first CPU-primitive draft). The
-- interior cloud is lib/layers/complexcell/interior_swarm.lua -- the SOLAR layer's
-- proven instanced-mesh technique (lib/swarm.lua) pointed inward: a fixed, large
-- instance buffer filled ONCE at load with stateless vesicle routes, each vesicle's
-- position a CLOSED-FORM function of (per-instance attributes, time, endpoint uniforms)
-- in the vertex shader. The CPU does ~zero per-instance work; per frame this view ships
-- only a handful of uniforms (the organelle endpoint positions, the per-segment flow
-- readouts, and the global flow scalars) and raises the live instance count. The
-- membrane + nucleus + rim stay CPU primitives FRAMING that instanced cloud.
--
-- READING STATE THROUGH FLOW (the core ask -- docs/PHASE_2.md "Reading state through
-- flow"). Every visual is a CONTINUOUS response to a snapshot field, never a discrete
-- state machine. The mapping is unchanged from the first draft; it now drives UNIFORMS
-- instead of CPU primitives:
--   * MEMBRANE -- a soft circle/blob filling most of the screen with a bright rim,
--     gently wobbling. Its rim brightness eases with `output` (a lively cell glows).
--     [CPU primitive, framing the swarm.]
--   * NUCLEUS -- once the `nucleus` stage is unlocked, a distinct inner compartment
--     near the centre, its detail filling in with that stage's level. [CPU primitive.]
--   * ENDPOINTS = organelle clusters -- each UNLOCKED stage is one endpoint at a STABLE
--     position on a loose pipeline path (ribosomes -> nucleus -> er -> golgi ->
--     transport -> membrane). Mitochondria add extra emitter endpoints scaled by
--     `mito`. Uploaded as the swarm's `endpoints` uniform each frame (cheap, like
--     lib/bodies.lua). Vesicles haul along the SEGMENTS between consecutive endpoints.
--   * LIVE COUNT -- a logarithmic SAMPLE of the cell's scale (`built` + `output`),
--     hard-capped, raised as the swarm's instance count so the interior visibly fills
--     as the cell grows ("growth is detail") -- never the literal `built`, never a CPU
--     per-instance cost.
--   * CONGESTION (per-stage 0..1) -- a backed-up stage's SEGMENT clumps + slows: its
--     vesicles bunch toward the leg middle and crawl (the `segments[].x` readout).
--   * BOTTLENECK (`is_bottleneck` / `bottleneck_id`) -- the pinning stage's segment
--     CONSTRICTS: a tighter lane, vesicles bunch into a thread (`segments[].y`).
--   * VACANCY -- segments DOWNSTREAM of the bottleneck thin out: a fraction of their
--     vesicles are parked off-screen, so the highway runs sparse (`segments[].z`).
--   * OUTPUT -- overall liveliness: it drives the global `speed` + `brightness`
--     uniforms (high output = a busy, bright interior) AND the live vesicle count.
--   * BROWNOUT (`brownout`) -- an energy deficit DIMS + SLOWS the whole swarm via the
--     global `brightness`/`slow` uniforms, eased over time (a fade, not a flick) -- the
--     on-theme tell for "complexity you can't power".
--   * `fuel_factor` -- a subtle whole-interior TINT (the swarm's `tint` uniform): >1
--     (plant) eases toward the green token, <1 (animal) toward the warm token; neutral
--     1.0 = baseline. The hook is wired but barely visible at the neutral value.
-- Red-pulsing is deliberately NOT used here -- it is held in reserve as an
-- accessibility accent only (per the design brief), so the default language stays flow.
--
-- CHEAP SIM, EXPENSIVE-LOOKING VISUALS. update() only advances a clock and eases the
-- brownout dim/slow + fuel tint; there is no per-particle simulation anywhere -- the
-- vesicle motion is closed-form in the GPU vertex shader, and the framing primitives
-- are a handful of circles/polygons. The cost is bounded and legible regardless of how
-- astronomically large `built` grows.
--
-- HEADLESS-SAFE LOAD. Like lib/swarm.lua, ALL GPU work is deferred: this module and
-- interior_swarm bare-`require` without touching love.* or FFI. The swarm lazily
-- initializes its mesh/shader on first draw (interior_swarm.draw calls .load if the
-- host didn't), so a bare require under plain Lua loads clean for the test harness.
local fx = require("lib.engine.fx")
local colors = require("lib.engine.ui.colors")
local interior_swarm = require("lib.layers.complexcell.interior_swarm")

local view = {}

-- ============================================================================
-- Tunables (all cosmetic; none feed the authoritative sim).
-- ============================================================================

-- The cell body fills this fraction of the smaller window dimension (radius).
local CELL_FILL = 0.42
local MEMBRANE_WOBBLE = 0.018 -- rim wobble as a fraction of the cell radius
local MEMBRANE_WOBBLE_FREQ = 0.6 -- wobble cycles/sec (gentle)
local RIM_WIDTH = 3 -- membrane rim line width in screen px

-- Pipeline path: unlocked stages sit at STABLE angles around this fraction of the
-- cell radius, in pipeline order, so leveling never reshuffles the layout. The swarm
-- hauls vesicles along the SEGMENTS connecting consecutive endpoints in this ring.
local RING_FRAC = 0.6 -- endpoint ring radius as a fraction of the cell radius

-- Mitochondria emitters: extra endpoints (power plants) scattered on an inner ring,
-- a logarithmic SAMPLE of `mito` (capped). They append after the stage endpoints so
-- the swarm hauls some cargo to/from them too -- power feeding the line.
local MITO_RING_FRAC = 0.32 -- mito emitter ring radius as a fraction of cell radius
local MITO_BASE = 1
local MITO_SCALE = 2.2
local MAX_MITO_EMITTERS = 6 -- hard cap on mito endpoints (keeps the uniform array sane)

-- Live vesicle count: a logarithmic SAMPLE of the cell's scale, hard-capped well
-- below the swarm's instance ceiling. Built drives the bulk fill ("growth is detail")
-- and output adds liveliness on top. NEVER the literal `built`.
local COUNT_BASE = 400
local COUNT_BUILT_SCALE = 9000 -- multiplies log(1 + built)
local COUNT_OUTPUT_SCALE = 1800 -- multiplies log(1 + output)
local MAX_LIVE_VESICLES = 120000 -- the view's hard cap (the GPU could do far more)

-- Output -> global liveliness. Output is mapped through a soft saturating curve to a
-- speed + brightness multiplier so a busy cell runs faster + brighter without ever
-- blowing out. OUTPUT_REF is the output at which liveliness is ~half-saturated.
local OUTPUT_REF = 40
local SPEED_MIN = 0.55 -- base swarm speed at zero output (still drifts, just calm)
local SPEED_MAX = 1.6 -- speed at full saturation (a teeming, busy interior)
local BRIGHT_MIN = 0.55 -- swarm brightness floor at zero output
local BRIGHT_MAX = 1.15 -- brightness at full saturation

-- Brownout: the whole swarm eases toward this brightness + this speed slowdown.
local BROWNOUT_DIM = 0.42 -- swarm brightness multiplier at full brownout
local BROWNOUT_SLOW = 0.30 -- swarm speed multiplier at full brownout
local DIM_EASE = 2.5 -- per-second lerp rate toward the brownout target

-- fuel_factor tint hook: how far a full plant/animal lean colors the interior.
local FUEL_TINT = 0.18

-- Membrane / nucleus framing alpha (CPU primitives around the swarm).
local CYTOPLASM_ALPHA = 0.5
local NUCLEUS_R_FRAC = 0.30 -- nucleus radius as a fraction of cell radius

-- The fixed pipeline order (matches the sim's stage ids). The view lays endpoints
-- out in THIS order around the ring, and uses the index to judge up/downstream of
-- the bottleneck for the vacancy readout.
local STAGE_ORDER = {
  "ribosomes",
  "nucleus",
  "er",
  "golgi",
  "transport",
  "membrane",
}
local STAGE_INDEX = {}
for i = 1, #STAGE_ORDER do
  STAGE_INDEX[STAGE_ORDER[i]] = i
end

-- ============================================================================
-- Helpers (pure -- no love.*).
-- ============================================================================

local function clamp01(v)
  if v < 0 then
    return 0
  elseif v > 1 then
    return 1
  end
  return v
end

-- A cheap deterministic 0..1 hash from an integer seed -- used only for the framing
-- primitives' nucleus speckles + mito emitter placement (the swarm itself is fully
-- self-contained, its scatter baked into the instance buffer). Stateless by design.
local function hash01(n)
  local s = math.sin(n * 12.9898) * 43758.5453
  return s - math.floor(s)
end

-- Logarithmic sample: BASE + SCALE*log(1+value), capped. The drawn/live count is a
-- READABLE SAMPLE of a sim quantity, never the literal value (scale-of-numbers honesty,
-- as in phase 1's logarithmic swarm sampling).
local function sample_count(value, base, scale, cap)
  value = value or 0
  if value < 0 then
    value = 0
  end
  local n = base + scale * math.log(1 + value)
  n = math.floor(n + 0.5)
  if n > cap then
    n = cap
  end
  return n
end

-- Soft saturating 0..1 curve: value/(value+ref). Maps an unbounded sim quantity onto
-- a bounded liveliness without a hard clip (half-saturated at value == ref).
local function saturate(value, ref)
  value = value or 0
  if value < 0 then
    value = 0
  end
  return value / (value + ref)
end

-- ============================================================================
-- View lifecycle.
-- ============================================================================

function view.new()
  -- dim/speed are EASED cosmetic state (brownout fade, fuel tint), so update() has
  -- continuous values to lerp toward each frame; fx is the shared effects controller
  -- for spawn/animation beats the orchestrator can compose. The swarm itself is
  -- stateless GPU machinery -- the only per-view state is these eased cosmetics.
  return {
    time = 0,
    fx = fx.new(),
    dim = 1, -- 1 = full brightness; eases toward BROWNOUT_DIM under brownout
    drift = 1, -- 1 = full speed; eases toward BROWNOUT_SLOW under brownout
    tint = { 1, 1, 1 }, -- eased fuel tint multiplier (neutral white at fuel 1.0)
    -- Reused scratch arrays so draw allocates nothing per frame for the uniforms.
    endpoints_x = {},
    endpoints_y = {},
    segments = {},
  }
end

-- Cosmetic animation only -- advance the clock, the fx controller, the swarm clock,
-- and ease the brownout dim/slow + fuel tint toward their targets. No game state lives
-- here, and no GPU work: the swarm clock is a single scalar accumulate.
function view.update(state, dt)
  state.time = state.time + dt
  fx.update(state.fx, dt)
  interior_swarm.update(dt)

  -- The brownout target is held on the view between draws (set from the snapshot in
  -- draw); ease toward it so the dimming reads as a smooth fade, not a flick.
  local dim_target = state.dim_target or 1
  local drift_target = state.drift_target or 1
  local k = clamp01(dt * DIM_EASE)
  state.dim = state.dim + (dim_target - state.dim) * k
  state.drift = state.drift + (drift_target - state.drift) * k

  -- Ease the fuel tint the same way (target set in draw from fuel_factor).
  local tt = state.tint_target
  if tt then
    state.tint[1] = state.tint[1] + (tt[1] - state.tint[1]) * k
    state.tint[2] = state.tint[2] + (tt[2] - state.tint[2]) * k
    state.tint[3] = state.tint[3] + (tt[3] - state.tint[3]) * k
  end
end

-- Spawn a composable effect onto this view's fx controller; returns it. The
-- orchestrator builds effects (fx.flash/fx.pulse/...) and adds them here, e.g. an
-- fx.implode on a freshly-bought organelle to read as it "snapping into place".
-- (Kept exactly as the public interface the orchestrator depends on.)
function view.spawn(state, effect) return fx.add(state.fx, effect) end

-- ============================================================================
-- Draw helpers (love.* lives ONLY below this line, inside draw-time code).
-- ============================================================================

-- Resolve the fuel tint target from fuel_factor: >1 leans toward the green token
-- (plant), <1 toward the warm sand token (animal), 1.0 = neutral white. The lean is
-- subtle (FUEL_TINT) and barely visible at the neutral baseline -- just the hook.
local function fuel_tint_target(fuel)
  fuel = fuel or 1
  local lean = clamp01(math.abs(fuel - 1)) * FUEL_TINT
  local token = (fuel >= 1) and colors.secondary or colors.tertiary
  return {
    (1 - lean) + lean * token[1],
    (1 - lean) + lean * token[2],
    (1 - lean) + lean * token[3],
  }
end

-- Apply the eased interior dim + fuel tint on top of a token color, then set it. Used
-- by the framing primitives so the membrane/nucleus dim + tint in lockstep with the
-- swarm (the whole interior reads as one cell under brownout / fuel lean).
local function set_interior_color(state, token, alpha)
  local t = state.tint
  love.graphics.setColor(
    token[1] * t[1],
    token[2] * t[2],
    token[3] * t[3],
    (alpha or 1) * state.dim
  )
end

-- The big membrane: a filled soft body disk under a brighter rim that gently wobbles.
-- The rim brightens with `output` so a lively cell glows; the body is a dim fill that
-- reads as cytoplasm framing the instanced swarm. A many-segment polygon so the wobble
-- is visible without an art pipeline.
local function draw_membrane(state, cx, cy, r, output)
  local t = state.time
  local segs = 64
  -- Soft cytoplasm fill (a plain disk -- the wobble lives in the rim line).
  set_interior_color(state, colors.surface, CYTOPLASM_ALPHA)
  love.graphics.circle("fill", cx, cy, r)
  set_interior_color(state, colors.primary, 0.06)
  love.graphics.circle("fill", cx, cy, r * 0.96)

  -- Wobbling bright rim. A blended sum of two low-frequency sines per vertex gives an
  -- organic, non-circular edge that breathes over time.
  local pts = {}
  for i = 0, segs - 1 do
    local a = (i / segs) * 2 * math.pi
    local w = math.sin(a * 3 + t * MEMBRANE_WOBBLE_FREQ * 2 * math.pi)
      + 0.6 * math.sin(a * 5 - t * MEMBRANE_WOBBLE_FREQ * math.pi)
    local rr = r * (1 + MEMBRANE_WOBBLE * w)
    pts[#pts + 1] = cx + math.cos(a) * rr
    pts[#pts + 1] = cy + math.sin(a) * rr
  end
  local rim_alpha = 0.45 + 0.4 * clamp01((output or 0) / 50)
  love.graphics.setLineWidth(RIM_WIDTH)
  set_interior_color(state, colors.primary, rim_alpha)
  love.graphics.polygon("line", pts)
  love.graphics.setLineWidth(1)
end

-- The nucleus: a distinct inner compartment near the centre, its speckled chromatin
-- detail filling in with the nucleus stage's level. Only drawn once that stage is
-- unlocked (the caller checks).
local function draw_nucleus(state, cx, cy, r, level)
  local nr = r * NUCLEUS_R_FRAC
  set_interior_color(state, colors.primary_dark, 0.55)
  love.graphics.circle("fill", cx, cy, nr)
  love.graphics.setLineWidth(2)
  set_interior_color(state, colors.primary, 0.6)
  love.graphics.circle("line", cx, cy, nr)
  love.graphics.setLineWidth(1)
  -- Chromatin speckles: a logarithmic sample of the level, scattered inside.
  local n = sample_count(level, 4, 7, 40)
  for i = 1, n do
    local a = hash01(i * 1.7) * 2 * math.pi
    local rad = math.sqrt(hash01(i * 2.3)) * nr * 0.82
    local px = cx + math.cos(a) * rad
    local py = cy + math.sin(a) * rad
    set_interior_color(state, colors.primary, 0.5)
    love.graphics.circle("fill", px, py, 1.4)
  end
end

-- Stable angle for a pipeline stage by its FIXED order index (start at top, clockwise).
local function stage_angle(order) return -math.pi / 2 + (order - 1) / #STAGE_ORDER * 2 * math.pi end

-- Build the swarm's endpoint + segment arrays from the snapshot, in place on the
-- view's scratch tables, and return the live endpoint/segment counts. This is the
-- whole bridge from the snapshot CONTRACT to the GPU uniforms:
--   * endpoints = one per UNLOCKED stage at its stable ring position, in pipeline
--     order, then up to MAX_MITO_EMITTERS mitochondria emitters on an inner ring.
--   * segments  = one per gap between consecutive endpoints, carrying the flow
--     readouts { congestion, is_bottleneck, vacancy, density } that the shader reads.
-- All cheap: a few dozen table writes, no per-vesicle work.
local function build_routes(state, snapshot, cx, cy, r)
  local stages = snapshot.stages or {}
  local xs, ys, segs = state.endpoints_x, state.endpoints_y, state.segments
  local ring_r = r * RING_FRAC

  -- Find the bottleneck's pipeline INDEX so segments downstream of it read as vacant.
  -- Prefer the explicit bottleneck_id, else the flagged stage.
  local bn_index
  if snapshot.bottleneck_id and STAGE_INDEX[snapshot.bottleneck_id] then
    bn_index = STAGE_INDEX[snapshot.bottleneck_id]
  else
    for i = 1, #stages do
      if stages[i].is_bottleneck then
        bn_index = STAGE_INDEX[stages[i].id]
      end
    end
  end

  -- Gather the UNLOCKED stages in fixed pipeline order, each as one endpoint. We keep
  -- the per-stage rows alongside so the segment between endpoint k and k+1 can read
  -- the DOWNSTREAM stage's congestion/bottleneck/vacancy (cargo entering a stage feels
  -- that stage's state -- a jam at stage k+1 backs up the segment feeding it).
  local ep_count = 0
  local ordered = {} -- the stage row at each endpoint slot (nil for mito emitters)
  for order = 1, #STAGE_ORDER do
    local id = STAGE_ORDER[order]
    local row
    for i = 1, #stages do
      if stages[i].id == id then
        row = stages[i]
        break
      end
    end
    if row and row.unlocked then
      ep_count = ep_count + 1
      local a = stage_angle(order)
      xs[ep_count] = cx + math.cos(a) * ring_r
      ys[ep_count] = cy + math.sin(a) * ring_r
      ordered[ep_count] = row
    end
  end

  -- Mitochondria emitters: a logarithmic sample of `mito`, appended as extra endpoints
  -- on an inner ring so some vesicles haul to/from the power plants. Scaled by mito so
  -- a more-powered cell visibly grows its emitter network (capped).
  local mito_n = sample_count(snapshot.mito, MITO_BASE, MITO_SCALE, MAX_MITO_EMITTERS)
  local mito_ring = r * MITO_RING_FRAC
  for m = 1, mito_n do
    ep_count = ep_count + 1
    local a = hash01(m * 4.7) * 2 * math.pi
    xs[ep_count] = cx + math.cos(a) * mito_ring
    ys[ep_count] = cy + math.sin(a) * mito_ring
    ordered[ep_count] = nil -- emitter, not a pipeline stage
  end

  -- Segments: one per gap between consecutive endpoints (ep_count - 1). Each carries
  -- the flow readout the shader applies to vesicles hauling along it. The readout is
  -- taken from the DOWNSTREAM endpoint's stage (the segment feeds into it); mito
  -- emitter segments are calm neutral lanes.
  local seg_count = math.max(ep_count - 1, 0)
  for k = 1, seg_count do
    local row = ordered[k + 1]
    local seg = segs[k]
    if not seg then
      seg = { 0, 0, 0, 0 }
      segs[k] = seg
    end
    if row then
      local congestion = clamp01(row.congestion or 0)
      local is_bn = row.is_bottleneck and 1 or 0
      -- Vacancy: how far downstream of the bottleneck the DOWNSTREAM stage is (0 =
      -- at/upstream, 1 = far downstream) -- starved segments thin their highway.
      local vac = 0
      if bn_index then
        local d = (STAGE_INDEX[row.id] or k) - bn_index
        if d > 0 then
          vac = clamp01(d / (#STAGE_ORDER - bn_index + 0.001))
        end
      end
      -- Density: how "full" the segment runs, from the stage's level/cap fill -- a
      -- maxed stage's lane reads a touch brighter (the shader uses .w for brightness).
      local cap = row.cap or 0
      local fill = cap > 0 and clamp01((row.level or 0) / cap) or 0
      seg[1], seg[2], seg[3], seg[4] = congestion, is_bn, vac, 0.4 + 0.6 * fill
    else
      -- Mito emitter lane: calm, neutral, moderately bright (power is flowing).
      seg[1], seg[2], seg[3], seg[4] = 0, 0, 0, 0.6
    end
  end

  return ep_count, seg_count
end

-- Render the cell interior to the screen from a read-only snapshot (the orchestrator
-- builds it fresh each frame; see the EXACT shape in this module's header). Draws
-- nothing of the panel/HUD. Graphics state is reset at the end so the UI inherits clean
-- defaults. Order: membrane fill + rim (CPU) -> nucleus (CPU) -> the GPU-instanced
-- vesicle swarm (additive cloud) -> fx, all framed by the membrane.
function view.draw(state, snapshot)
  snapshot = snapshot or {}
  local win_w, win_h = love.graphics.getDimensions()
  local cx, cy = win_w * 0.5, win_h * 0.5
  local r = math.min(win_w, win_h) * CELL_FILL

  -- Stash the brownout + fuel targets for update()'s easing (continuous, not a flag
  -- flip): a brownout eases the swarm toward dim + slow; fuel sets the tint.
  if snapshot.brownout then
    state.dim_target = BROWNOUT_DIM
    state.drift_target = BROWNOUT_SLOW
  else
    state.dim_target = 1
    state.drift_target = 1
  end
  state.tint_target = fuel_tint_target(snapshot.fuel_factor)

  love.graphics.push()

  -- 1) The membrane frames the interior (cytoplasm fill + wobbling bright rim).
  draw_membrane(state, cx, cy, r, snapshot.output)

  -- 2) The nucleus compartment (only once its stage is unlocked).
  local stages = snapshot.stages or {}
  for i = 1, #stages do
    local s = stages[i]
    if s.id == "nucleus" and s.unlocked then
      draw_nucleus(state, cx, cy, r, s.level)
    end
  end

  -- 3) The GPU-INSTANCED vesicle swarm -- the teeming interior cloud. Build the
  -- endpoint + segment uniforms from the snapshot, set the live count from a log
  -- sample of the cell's scale, map the global flow scalars, and draw the live prefix.
  local ep_count, seg_count = build_routes(state, snapshot, cx, cy, r)

  -- LIVE COUNT: a log sample of built (the bulk fill -- "growth is detail") plus an
  -- output term (extra liveliness), hard-capped. Never the literal built; no per-
  -- instance CPU cost (this is just the prefix length passed to drawInstanced).
  local count = COUNT_BASE
    + COUNT_BUILT_SCALE * math.log(1 + (snapshot.built or 0))
    + COUNT_OUTPUT_SCALE * math.log(1 + (snapshot.output or 0))
  if count > MAX_LIVE_VESICLES then
    count = MAX_LIVE_VESICLES
  end
  interior_swarm.set_count(count)

  -- OUTPUT -> global liveliness: a saturating curve drives both swarm speed and
  -- brightness so a busy cell runs faster + brighter. The eased brownout state then
  -- multiplies in (dim + slow), so the two readouts compose smoothly.
  local live = saturate(snapshot.output, OUTPUT_REF)
  local out_speed = SPEED_MIN + (SPEED_MAX - SPEED_MIN) * live
  local out_bright = BRIGHT_MIN + (BRIGHT_MAX - BRIGHT_MIN) * live

  interior_swarm.draw({
    endpoints_x = state.endpoints_x,
    endpoints_y = state.endpoints_y,
    endpoint_count = ep_count,
    segments = state.segments,
    segment_count = seg_count,
    -- BROWNOUT eases the swarm: `slow` drags speed, the dim multiplies brightness.
    -- (state.drift / state.dim are the eased brownout factors from update().)
    speed = out_speed, -- output liveliness (brownout applied via `slow`)
    slow = state.drift, -- brownout speed multiplier, eased
    brightness = out_bright * state.dim, -- output brightness * eased brownout dim
    tint = state.tint, -- eased fuel_factor tint
  })

  -- 4) World-space fx (spawn beats, organelle implodes) ride above the interior.
  fx.draw_world(state.fx)

  love.graphics.pop()

  -- Screen-space overlay fx (e.g. a brownout vignette flash) draw after the pop.
  fx.draw_overlay(state.fx)

  -- Reset graphics state so the orchestrator's panel/HUD inherits clean defaults.
  love.graphics.setLineWidth(1)
  love.graphics.setColor(1, 1, 1, 1)
end

return view
