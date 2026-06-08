-- Complex-cell view: programmatic, asset-free visuals for the INTERIOR of a single
-- eukaryotic cell -- the phase-2 sibling of lib/layers/cell/view.lua. Same discipline:
-- love.* is touched ONLY inside draw-time code (so a bare `require` loads headless),
-- there is a single generic entity draw path, transient beats compose through an
-- fx controller (lib/engine/fx.lua), and every color binds a GLOBAL token from
-- lib/engine/ui/colors -- no literal RGB, no per-layer palette. Where phase 1 framed
-- a dish of flat squares with a stepped fit-camera, this view frames the cytoplasm of
-- ONE cell and aims the swarm INWARD: organelle clusters, drifting vesicles, and a big
-- wobbling membrane. The orchestrator (complexcell.lua) draws the panel/HUD on top --
-- this file draws NOTHING of the UI.
--
-- READING STATE THROUGH FLOW (the core ask -- docs/PHASE_2.md "Reading state through
-- flow"). Every visual is a CONTINUOUS response to a snapshot field, never a discrete
-- state machine:
--   * MEMBRANE -- a soft circle/blob filling most of the screen with a bright rim,
--     gently wobbling. Its rim brightness eases with `output` (a lively cell glows).
--   * NUCLEUS -- once the `nucleus` stage is unlocked, a distinct inner compartment
--     near the centre, its detail filling in with that stage's level.
--   * STAGE CLUSTERS -- each UNLOCKED stage gets an organelle cluster at a STABLE
--     position on a loose pipeline ring (ribosomes -> nucleus -> er -> golgi ->
--     transport -> membrane). The element COUNT/DENSITY scales with level/cap, so
--     leveling a stage visibly fills it in ("growth is detail"). Counts are a
--     logarithmic SAMPLE (like phase 1) and hard-capped -- never the literal `built`.
--   * CONGESTION (per-stage 0..1) -- a backed-up stage CLUMPS: its elements pull
--     toward the cluster centre (crowding) and a few stalled cargo motes pile up on
--     it. High congestion = a visible jam.
--   * BOTTLENECK (`is_bottleneck` / `bottleneck_id`) -- the pinning stage reads as a
--     CONSTRICTION: its cluster tightens and a faint pinch ring marks it. Cargo on the
--     pipeline slows as it passes the bottleneck (the choke point).
--   * VACANCY -- stages DOWNSTREAM of the bottleneck are starved: their clusters thin
--     out (fewer elements drawn) and their highways carry less cargo -- sparse, idle.
--   * VESICLES/CARGO -- drifting interior particles hauled along the ring. Their count
--     and liveliness scale with `output` (the teeming swarm): busy when output is high,
--     sparse when low. They slow and dim downstream of the bottleneck.
--   * BROWNOUT (`brownout`) -- an energy deficit DIMS the whole interior and SLOWS the
--     drift (motors walk sluggishly). Eased smoothly via a dim factor so it reads as a
--     fade, not a flick. The on-theme tell for "complexity you can't power."
--   * Balanced (low congestion, not brownout) = calm, even flow.
--   * `fuel_factor` -- a subtle whole-interior TINT hook: >1 (plant) eases toward the
--     green token, <1 (animal) toward the warm token. Neutral 1.0 = baseline now; the
--     hook is wired but barely visible at the neutral value.
-- Red-pulsing is deliberately NOT used here -- it is held in reserve as an
-- accessibility accent only (per the design brief), so the default language stays flow.
--
-- CHEAP SIM, ALIVE VISUALS. This first draft renders the interior on the CPU with
-- love.graphics primitives: organelle elements and cargo are positioned by closed-form
-- drift (a cheap sin/cos hash of a per-element phase + time), so update() only advances
-- a clock and eases the brownout/tint factors -- there is no per-particle simulation.
-- Element and cargo counts are hard-capped (see MAX_*), so the cost is bounded and
-- legible regardless of how astronomically large `built` grows.
--
-- DEFERRED: the GPU-instanced swarm renderer (lib/swarm.lua + lib/bodies.lua, validated
-- at ~millions of stateless instances via a closed-form vertex shader) is the intended
-- LATER upgrade for true teeming density -- pointed INWARD here, with the organelle
-- clusters as the "bodies" (route endpoints) and vesicles as the instanced "drones"
-- hauling between them. This draft keeps a clean programmatic interior instead; the
-- closed-form per-element drift below is deliberately shaped like that shader's route
-- model so the swap stays mechanical. See lib/swarm.lua's VERTEX_SHADER_TEMPLATE.
local fx = require("lib.engine.fx")
local colors = require("lib.engine.ui.colors")

local view = {}

-- ============================================================================
-- Tunables (all cosmetic; none feed the authoritative sim).
-- ============================================================================

-- The cell body fills this fraction of the smaller window dimension (radius).
local CELL_FILL = 0.42
local MEMBRANE_WOBBLE = 0.018 -- rim wobble as a fraction of the cell radius
local MEMBRANE_WOBBLE_FREQ = 0.6 -- wobble cycles/sec (gentle)
local RIM_WIDTH = 3 -- membrane rim line width in screen px

-- Pipeline ring: unlocked stages sit at STABLE angles around this fraction of the
-- cell radius, in pipeline order, so leveling never reshuffles the layout.
local RING_FRAC = 0.6 -- cluster ring radius as a fraction of the cell radius
local CLUSTER_SPREAD = 0.16 -- a cluster's element scatter, as a fraction of cell radius

-- Element-count sampling: logarithmic, like phase 1's swarm sampling -- a stage's
-- drawn element count is BASE + SCALE*log(1+level), hard-capped. Never literal.
local ELEM_BASE = 3
local ELEM_SCALE = 9
local MAX_ELEMENTS = 60 -- per-stage hard cap (keeps it cheap + legible)
local ELEM_SIZE = 3 -- base element size in screen px

-- Cargo (vesicles drifting the ring): count scales with `output`, hard-capped.
local CARGO_BASE = 4
local CARGO_SCALE = 26
local MAX_CARGO = 140
local CARGO_SIZE = 2.4
local CARGO_SPEED = 0.10 -- ring laps/sec at full liveliness (slowed by brownout)

-- Flow-readout shaping.
local CONGEST_PULL = 0.45 -- how far congestion pulls elements toward cluster centre
local CONGEST_PILE = 6 -- max extra stalled cargo motes piled on a jammed stage
local VACANCY_THIN = 0.55 -- max fraction of elements a fully-starved stage sheds
local BOTTLENECK_PINCH = 0.30 -- how much the bottleneck cluster tightens

-- Brownout: the whole interior eases toward this dim and this drift-slowdown.
local BROWNOUT_DIM = 0.42 -- interior alpha multiplier at full brownout
local BROWNOUT_SLOW = 0.30 -- drift-speed multiplier at full brownout
local DIM_EASE = 2.5 -- per-second lerp rate toward the brownout target

-- fuel_factor tint hook: how far a full plant/animal lean colors the interior.
local FUEL_TINT = 0.18

-- The fixed pipeline order (matches the sim's stage ids). The view lays clusters
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

-- A cheap deterministic 0..1 hash from an integer seed -- the per-element "rng"
-- that scatters clusters and phases cargo without storing any per-element state.
-- (Stateless by design, mirroring the swarm shader's per-instance attributes.)
local function hash01(n)
  local s = math.sin(n * 12.9898) * 43758.5453
  return s - math.floor(s)
end

-- Logarithmic element sample: BASE + SCALE*log(1+level), capped. The drawn count is
-- a READABLE SAMPLE of the stage, never the literal level/built (scale-of-numbers
-- honesty, as in phase 1's logarithmic swarm sampling).
local function sample_count(level, base, scale, cap)
  level = level or 0
  if level < 0 then
    level = 0
  end
  local n = base + scale * math.log(1 + level)
  n = math.floor(n + 0.5)
  if n > cap then
    n = cap
  end
  return n
end

-- ============================================================================
-- View lifecycle.
-- ============================================================================

function view.new()
  -- dim/tint are EASED cosmetic state (brownout fade, fuel tint), so update()
  -- has continuous values to lerp toward each frame; fx is the shared effects
  -- controller for spawn/animation beats the orchestrator can compose.
  return {
    time = 0,
    fx = fx.new(),
    dim = 1, -- 1 = full brightness; eases toward BROWNOUT_DIM under brownout
    drift = 1, -- 1 = full drift speed; eases toward BROWNOUT_SLOW under brownout
    tint = { 1, 1, 1 }, -- eased fuel tint multiplier (neutral white at fuel 1.0)
  }
end

-- Cosmetic animation only -- advance the clock, the fx controller, and ease the
-- brownout dim/slow + fuel tint toward their targets. No game state lives here.
function view.update(state, dt)
  state.time = state.time + dt
  fx.update(state.fx, dt)

  -- The brownout target is held on the view between draws (set from the snapshot
  -- in draw); ease toward it so the dimming reads as a smooth fade, not a flick.
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
function view.spawn(state, effect) return fx.add(state.fx, effect) end

-- ============================================================================
-- Draw helpers (love.* lives ONLY below this line, inside draw-time code).
-- ============================================================================

-- Resolve the fuel tint target from fuel_factor: >1 leans toward the green token
-- (plant), <1 toward the warm sand token (animal), 1.0 = neutral white. The lean
-- is subtle (FUEL_TINT) and barely visible at the neutral baseline -- just the hook.
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

-- Apply the eased interior dim + fuel tint on top of a token color, then set it.
local function set_interior_color(state, token, alpha)
  local t = state.tint
  love.graphics.setColor(
    token[1] * t[1],
    token[2] * t[2],
    token[3] * t[3],
    (alpha or 1) * state.dim
  )
end

-- The big membrane: a filled soft body disk under a brighter rim that gently
-- wobbles. The rim brightens with `output` so a lively cell glows; the body is a
-- dim fill that reads as cytoplasm. Drawn as a many-segment polygon so the wobble
-- is visible without an art pipeline (a simple SDF/metaball is the later upgrade).
local function draw_membrane(state, cx, cy, r, output)
  local t = state.time
  local segs = 64
  -- Soft cytoplasm fill (a plain disk -- the wobble lives in the rim line).
  set_interior_color(state, colors.surface, 0.5)
  love.graphics.circle("fill", cx, cy, r)
  set_interior_color(state, colors.primary, 0.06)
  love.graphics.circle("fill", cx, cy, r * 0.96)

  -- Wobbling bright rim. A blended sum of two low-frequency sines per vertex gives
  -- an organic, non-circular edge that breathes over time.
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
-- unlocked (the caller checks). Sits slightly off-centre so clusters can ring it.
local function draw_nucleus(state, cx, cy, r, level)
  local nr = r * 0.30
  local nx, ny = cx, cy
  set_interior_color(state, colors.primary_dark, 0.55)
  love.graphics.circle("fill", nx, ny, nr)
  love.graphics.setLineWidth(2)
  set_interior_color(state, colors.primary, 0.6)
  love.graphics.circle("line", nx, ny, nr)
  love.graphics.setLineWidth(1)
  -- Chromatin speckles: a logarithmic sample of the level, scattered inside.
  local n = sample_count(level, 4, 7, 40)
  for i = 1, n do
    local a = hash01(i * 1.7) * 2 * math.pi
    local rad = math.sqrt(hash01(i * 2.3)) * nr * 0.82
    local px = nx + math.cos(a) * rad
    local py = ny + math.sin(a) * rad
    set_interior_color(state, colors.primary, 0.5)
    love.graphics.circle("fill", px, py, ELEM_SIZE * 0.45)
  end
end

-- One organelle cluster for an UNLOCKED stage. The element count is a log sample of
-- level/cap; CONGESTION pulls elements inward (a jam clumps); the BOTTLENECK tightens
-- the whole cluster (a constriction); VACANCY (being downstream of the bottleneck)
-- sheds elements (starved/sparse). `token` colors the cluster (varied per stage so
-- the pipeline reads), all within the 2-3 color palette via the global tokens.
local function draw_cluster(state, stage, x, y, r, downstream_vac)
  local level = stage.level or 0
  local cap = stage.cap or 0
  -- Fuller clusters near cap: blend the level sample with how close to cap it is, so
  -- a maxed stage visibly "fills in". (cap 0 -> just the level sample.)
  local fill = cap > 0 and clamp01(level / cap) or 0
  local base_n = sample_count(level, ELEM_BASE, ELEM_SCALE, MAX_ELEMENTS)
  local n = math.floor(base_n * (0.6 + 0.4 * fill) + 0.5)

  -- Vacancy: a starved DOWNSTREAM stage sheds elements (thinner cluster).
  n = math.floor(n * (1 - VACANCY_THIN * clamp01(downstream_vac)) + 0.5)
  if n < 1 then
    n = 1
  end

  local congestion = clamp01(stage.congestion or 0)
  local spread = r * CLUSTER_SPREAD
  -- The bottleneck tightens the cluster; congestion pulls each element inward.
  local tighten = stage.is_bottleneck and (1 - BOTTLENECK_PINCH) or 1
  local inward = 1 - CONGEST_PULL * congestion

  local t = state.time
  local token = state.cluster_token or colors.primary
  for i = 1, n do
    local seed = i + (stage.seed or 0)
    local a = hash01(seed * 1.3) * 2 * math.pi
    local rad = math.sqrt(hash01(seed * 2.1)) * spread * tighten * inward
    -- Gentle per-element drift (closed form, slowed by brownout via state.drift).
    local wob = 0.12 * spread * math.sin(t * state.drift * (0.7 + hash01(seed * 3.7)) + seed)
    local px = x + math.cos(a) * rad + math.cos(a + 1.6) * wob
    local py = y + math.sin(a) * rad + math.sin(a + 1.6) * wob
    -- Crowded elements read a touch brighter (the clump catches the eye).
    set_interior_color(state, token, 0.6 + 0.25 * congestion)
    love.graphics.circle("fill", px, py, ELEM_SIZE * (0.8 + 0.4 * fill))
  end

  -- Congestion pile-up: a few stalled cargo motes bunch on a jammed stage.
  local pile = math.floor(CONGEST_PILE * congestion + 0.5)
  for i = 1, pile do
    local a = hash01(i * 5.1 + (stage.seed or 0)) * 2 * math.pi
    local rad = spread * (0.4 + 0.5 * hash01(i * 6.3))
    local px = x + math.cos(a) * rad
    local py = y + math.sin(a) * rad
    set_interior_color(state, colors.secondary, 0.7)
    love.graphics.circle("fill", px, py, CARGO_SIZE)
  end

  -- Bottleneck pinch ring: a faint constriction marker so the choke point reads.
  if stage.is_bottleneck then
    love.graphics.setLineWidth(1)
    set_interior_color(state, colors.tertiary, 0.5)
    love.graphics.circle("line", x, y, spread * tighten * 1.15)
  end
end

-- Drifting cargo (vesicles) hauled around the pipeline ring. Count + liveliness
-- scale with `output` (the teeming swarm). Each mote is closed-form: its angle is a
-- per-mote phase + time*speed (the swarm shader's route model in miniature), so
-- there is zero per-particle state. Brownout slows the lap speed (state.drift). A
-- mote passing the bottleneck arc slows + dims (the choke), and motes downstream of
-- the bottleneck are thinned (vacancy on the highways).
local function draw_cargo(state, cx, cy, ring_r, output, bottleneck_frac)
  local n = sample_count(output, CARGO_BASE, CARGO_SCALE, MAX_CARGO)
  local t = state.time
  for i = 1, n do
    local phase = hash01(i * 7.7)
    local lane = (hash01(i * 9.1) - 0.5) * CLUSTER_SPREAD * 0.8 * ring_r
    -- Base lap progress (0..1) for this mote.
    local prog = (phase + t * CARGO_SPEED * state.drift) % 1
    -- Choke at the bottleneck: motes crawl through a window around bottleneck_frac,
    -- so cargo visibly bunches just before the constriction (and thins after it).
    local slow, dimmed = 1, 1
    if bottleneck_frac then
      local d = math.abs(((prog - bottleneck_frac + 0.5) % 1) - 0.5) -- ring distance
      if d < 0.12 then
        local closeness = 1 - d / 0.12
        slow = 1 - 0.6 * closeness -- crawl through the choke
        prog = prog - 0.04 * closeness * (1 - phase)
      end
      -- Vacancy: just PAST the bottleneck the highway runs sparse -- drop some motes.
      local past = ((prog - bottleneck_frac) % 1)
      if past > 0 and past < 0.4 then
        dimmed = 0.35 + 0.65 * (past / 0.4)
      end
    end
    local a = prog * 2 * math.pi
    local rr = ring_r + lane
    local px = cx + math.cos(a) * rr
    local py = cy + math.sin(a) * rr
    set_interior_color(state, colors.secondary, 0.55 * dimmed * (0.6 + 0.4 * slow))
    love.graphics.circle("fill", px, py, CARGO_SIZE * (0.8 + 0.3 * clamp01((output or 0) / 40)))
  end
end

-- Render the cell interior to the screen from a read-only snapshot (the orchestrator
-- builds it fresh each frame; see the EXACT shape in this module's header). Draws
-- nothing of the panel/HUD -- the orchestrator layers that on top. Graphics state is
-- reset at the end so the UI inherits clean defaults.
function view.draw(state, snapshot)
  snapshot = snapshot or {}
  local win_w, win_h = love.graphics.getDimensions()
  local cx, cy = win_w * 0.5, win_h * 0.5
  local r = math.min(win_w, win_h) * CELL_FILL

  -- Stash the brownout + fuel targets for update()'s easing (continuous, not a flag
  -- flip): a brownout eases the interior toward dim + slow drift; fuel sets the tint.
  if snapshot.brownout then
    state.dim_target = BROWNOUT_DIM
    state.drift_target = BROWNOUT_SLOW
  else
    state.dim_target = 1
    state.drift_target = 1
  end
  state.tint_target = fuel_tint_target(snapshot.fuel_factor)

  local stages = snapshot.stages or {}

  -- Find the bottleneck's pipeline INDEX so clusters/cargo downstream of it can read
  -- as vacant. Prefer the explicit bottleneck_id, else the flagged stage.
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

  love.graphics.push()

  draw_membrane(state, cx, cy, r, snapshot.output)

  -- Nucleus compartment (only once its stage is unlocked).
  for i = 1, #stages do
    local s = stages[i]
    if s.id == "nucleus" and s.unlocked then
      draw_nucleus(state, cx, cy, r, s.level)
    end
  end

  -- Lay unlocked stages out at STABLE angles around the pipeline ring, in fixed
  -- pipeline order, so leveling never reshuffles the layout. Each cluster gets a
  -- per-stage color token (cycling the 2-3 palette tokens) so the line reads.
  local ring_r = r * RING_FRAC
  local cluster_tokens = { colors.primary, colors.tertiary, colors.secondary }
  for i = 1, #stages do
    local s = stages[i]
    if s.unlocked and s.id ~= "nucleus" then
      local order = STAGE_INDEX[s.id] or i
      -- Angle from the FIXED pipeline order (start at top, go clockwise).
      local a = -math.pi / 2 + (order - 1) / #STAGE_ORDER * 2 * math.pi
      local x = cx + math.cos(a) * ring_r
      local y = cy + math.sin(a) * ring_r
      -- Vacancy: how far downstream of the bottleneck this stage is (0 = at/upstream,
      -- 1 = far downstream) -- starved stages thin out.
      local vac = 0
      if bn_index then
        local d = order - bn_index
        if d > 0 then
          vac = clamp01(d / (#STAGE_ORDER - bn_index + 0.001))
        end
      end
      state.cluster_token = cluster_tokens[((order - 1) % #cluster_tokens) + 1]
      s.seed = order * 100 -- stable per-stage scatter seed
      draw_cluster(state, s, x, y, r, vac)
    end
  end

  -- Drifting cargo around the ring (the teeming swarm), scaled by live output. The
  -- bottleneck's ring fraction drives the choke/vacancy window on the highways.
  local bn_frac
  if bn_index then
    bn_frac = (-0.25 + (bn_index - 1) / #STAGE_ORDER) % 1 -- match cluster angle start
  end
  draw_cargo(state, cx, cy, ring_r, snapshot.output, bn_frac)

  -- World-space fx (spawn beats, organelle implodes) ride above the interior.
  fx.draw_world(state.fx)

  love.graphics.pop()

  -- Screen-space overlay fx (e.g. a brownout vignette flash) draw after the pop.
  fx.draw_overlay(state.fx)

  -- Reset graphics state so the orchestrator's panel/HUD inherits clean defaults.
  love.graphics.setLineWidth(1)
  love.graphics.setColor(1, 1, 1, 1)
end

return view
