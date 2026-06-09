-- Complex-cell view: programmatic, asset-free visuals for the INTERIOR of a single
-- eukaryotic cell -- the phase-2 sibling of lib/layers/cell/view.lua. Same discipline:
-- love.* is touched ONLY inside draw-time code (so a bare `require` loads headless),
-- transient beats compose through an fx controller (lib/engine/fx.lua), and every
-- color binds a GLOBAL token from lib/engine/ui/colors -- no literal RGB, no per-layer
-- palette. Where phase 1 framed a dish of flat squares with a stepped fit-camera, this
-- view frames the cytoplasm of ONE cell and aims a swarm INWARD: recognizable
-- organelles at anatomically-anchored positions, and a teeming cloud of vesicles/cargo
-- hauling between them, inside a big wobbling membrane. The orchestrator
-- (complexcell.lua) draws the panel/HUD on top -- this file draws NOTHING of the UI.
--
-- ANATOMICAL ZONES (the phase-2 rework, docs/PHASE_2_INTERIOR.md sections 1-2). The
-- old single endpoint RING is gone. Each pipeline stage now sits at a STABLE,
-- anatomically-inspired position keyed to the reference cross-section: nucleus at the
-- centre hub; ribosomes + rough ER as a band hugging the nucleus on one side; the
-- Golgi offset outward from the ER's face; transport/membrane toward the rim; and the
-- mitochondria at FIXED inner-mid positions. Positions are DETERMINISTIC and never
-- reshuffle on level-up -- leveling only grows an organelle in place (the brief's
-- invariant). The swarm's segment legs connect these zone positions in pipeline order
-- (ribosomes -> nucleus -> er -> golgi -> transport -> membrane), so the factory-flow
-- read survives on a body that now looks like a cell.
--
-- THE SWARM IS GPU-INSTANCED (lib/layers/complexcell/interior_swarm.lua) -- the SOLAR
-- layer's proven instanced-mesh technique pointed inward: a fixed, large instance
-- buffer filled ONCE at load with stateless vesicle routes, each vesicle's position a
-- CLOSED-FORM function of (per-instance attributes, time, endpoint uniforms) in the
-- vertex shader. The CPU does ~zero per-instance work; per frame this view ships only
-- a handful of uniforms (the zone endpoint positions, the per-segment flow readouts,
-- the global flow scalars, and a cargo-type palette) and raises the live instance
-- count. The membrane + nucleus + organelles stay CPU primitives FRAMING that cloud.
--
-- READING STATE THROUGH FLOW (the core ask -- docs/PHASE_2_INTERIOR.md sections 4-5).
-- Every visual is a CONTINUOUS response to a snapshot field, never a discrete state
-- machine:
--   * MEMBRANE -- a soft body disk with a bright wobbling rim. Rim glow eases with
--     `output` (a lively cell glows). [CPU primitive, framing the swarm.]
--   * NUCLEUS -- the centre hub; chromatin speckle detail fills in with its level.
--   * ORGANELLES -- a draw pass between the membrane and the swarm: rough ER ribbons
--     studded with ribosome dots, a Golgi cisternae stack, stationary mitochondria
--     beans with cristae, cytoskeleton filaments. Each is a recipe of splines + simple
--     polygons tinted from color tokens, scaled by its stage level. [CPU primitives.]
--   * ENDPOINTS = zone positions -- one per UNLOCKED stage at its STABLE anatomical
--     position, then FIXED mitochondria emitter points. Uploaded as the swarm's
--     `endpoints` uniform each frame. Vesicles haul along the SEGMENTS between them.
--   * LIVE COUNT -- starts as a HANDFUL and grows with leveling: a base of ~8 plus a
--     `throughput` term (leveling a stage adds vesicles immediately) plus a smaller
--     `built` bulk term, log-scaled and hard-capped. ("Growth is detail.")
--   * EFFICIENCY (`efficiency`, 0..1) -- the DOMINANT liveliness driver: it sets the
--     swarm's global speed + brightness. Optimal (eff ~= 1) = fast + bright; low eff =
--     slow + dim. The eased brownout dim/slow then composes on top.
--   * CONGESTION (per-stage 0..1) -- a backed-up stage's SEGMENT clumps + slows.
--   * BOTTLENECK (`bottleneck_id`) -- the pinning stage's segment CONSTRICTS into a
--     thread, AND its organelle gets a SPOTLIGHT (a pulsing outline halo on the body).
--   * VACANCY -- segments DOWNSTREAM of the bottleneck thin out (parked off-screen).
--   * BROWNOUT (`brownout`) -- an energy deficit DIMS + SLOWS the whole swarm, eased
--     over time; the mitochondria gutter FIRST (drawn dim under brownout).
--   * `fuel_factor` -- a subtle whole-interior TINT (>1 plant/green, <1 animal/warm).
-- Red-pulsing is deliberately NOT used here -- held in reserve as an accessibility
-- accent only (per the design brief), so the default language stays flow.
--
-- CHEAP SIM, EXPENSIVE-LOOKING VISUALS. update() only advances clocks and eases the
-- brownout dim/slow + fuel tint; there is no per-particle simulation anywhere -- the
-- vesicle motion is closed-form in the GPU vertex shader, and the framing primitives
-- are a handful of circles/polygons/splines. Cost is bounded regardless of how large
-- `built` grows.
--
-- HEADLESS-SAFE LOAD. ALL GPU work is deferred: this module and interior_swarm
-- bare-`require` without touching love.* or FFI. The swarm lazily initializes on first
-- draw; the membrane/nucleus/organelle draws live below the "draw-time" line.
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

-- Mitochondria emitters: extra FIXED endpoints (power plants), a logarithmic SAMPLE
-- of `mito` (capped). They append after the stage endpoints so the swarm hauls some
-- cargo to/from them too -- power feeding the line. Positions are DETERMINISTIC (a
-- fixed angle table), so a more-powered cell lights up MORE of the SAME beans rather
-- than reshuffling them.
local MITO_BASE = 1
local MITO_SCALE = 2.2
local MAX_MITO_EMITTERS = 6 -- hard cap on mito endpoints (keeps the uniform array sane)
local MITO_RING_FRAC = 0.5 -- mitochondria sit on this inner-mid annulus fraction

-- Live vesicle count: START as a handful and GROW with leveling (the phase-1 "fills as
-- you grow" feel). Base is a tiny opening crowd; growth is driven by `throughput` (so
-- leveling a stage adds vesicles IMMEDIATELY) plus a smaller `built` bulk term. Both
-- log-scaled, summed, hard-capped well below the GPU ceiling. NEVER the literal value.
--   count = COUNT_BASE + K_FLOW*log(1+throughput) + K_BULK*log(1+built)
-- Tuning intent (with throughput ~ 5..600 and built ~ 0..50000 across the phase):
--   early  (T~5,    built~0)    ->  4 + 15*ln(6)  + 0             -> ~31  (sparse handful)
--   early  (T~5,    built~240)  ->  4 + 15*ln(6)  + 8*ln(241)     -> ~75  (light traffic)
--   mid    (T~80,   built~3000) ->  4 + 15*ln(81) + 8*ln(3001)    -> ~134 (filling in)
--   late   (T~600,  built~50000)->  4 + 15*ln(601)+ 8*ln(50001)   -> ~185 (busy, capped)
-- WHY these values: previous K_FLOW=230 / K_BULK=140 produced 420 vesicles at T=5
-- (before any building), which was far too dense for early play. Dropping K_FLOW to 15
-- and K_BULK to 8 keeps the "growth is detail" arc while opening sparse (docs §5).
local COUNT_BASE = 4 -- the opening handful (was 8; cut to keep early game sparse)
local K_FLOW = 15 -- multiplies log(1 + throughput): leveling adds vesicles at once
local K_BULK = 8 -- multiplies log(1 + built): the slow long-game bulk fill
local MAX_LIVE_VESICLES = 4000 -- the view's hard cap (low-thousands -- stays readable)

-- EFFICIENCY -> global liveliness (the dominant driver). eff in [0,1] lerps the swarm
-- speed + brightness between these floors and ceilings; the eased brownout state then
-- multiplies in (dim + slow), so the two readouts compose. Optimal (eff~1) = fast +
-- bright; low eff = slow + dim.
local SPEED_SLOW = 0.55 -- swarm speed at eff = 0 (still drifts, just sluggish)
local SPEED_FAST = 1.6 -- swarm speed at eff = 1 (a teeming, busy interior)
local BRIGHT_DIM = 0.5 -- swarm brightness at eff = 0
local BRIGHT_BRIGHT = 1.15 -- swarm brightness at eff = 1

-- Output is now only a MINOR secondary liveliness term layered on top of efficiency
-- (a busy cell glows a touch more). Kept small so efficiency dominates.
local OUTPUT_REF = 60 -- output at which the small output bonus is ~half-saturated
local OUTPUT_SPEED_BONUS = 0.18 -- max extra speed from output (added to the eff lerp)
local OUTPUT_BRIGHT_BONUS = 0.12 -- max extra brightness from output

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
-- out in THIS order, and uses the index to judge up/downstream of the bottleneck for
-- the vacancy readout.
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
-- ANATOMICAL ZONE LAYOUT (pure data -- no love.*).
--
-- Each stage's zone is a STABLE position given as a (radius-fraction, angle) polar
-- offset from the cell centre. These are fixed constants: leveling NEVER moves them.
-- The scheme distributes zones AROUND the whole cell so organelles don't cluster:
-- the nucleus-hugging structures (ribosomes, ER) sit upper-left; the Golgi steps
-- below-left; transport and membrane sweep to the right side of the cell, giving
-- each zone clear breathing room. Pipeline order is preserved in the angular sweep
-- (ribosomes -> nucleus -> er -> golgi -> transport -> membrane sweeps clockwise
-- through the cell's interior, ending at the upper-right rim).
--
--   nucleus    -> centre (the hub)                            frac 0.00
--   ribosomes  -> hugging the nucleus, upper-left            frac 0.30, ~135 deg
--   er         -> band hugging the nucleus, left-lower       frac 0.42, ~215 deg
--   golgi      -> offset well out from the ER, below-centre  frac 0.62, ~275 deg
--   transport  -> toward the rim, lower-right                frac 0.76, ~330 deg
--   membrane   -> the rim, upper-right                       frac 0.88, ~55  deg
--
-- WHY these fracs/angles: previous layout crammed ribosomes(150°)/er(195°)/golgi(235°)
-- into a ~85° arc on the left while transport(320°) and membrane(10°) sat nearby,
-- causing visible overlap. The new layout spreads the pipeline from 135° to 55°
-- (going clockwise, ~280° of arc), with each zone at least 55° from its neighbours
-- and with progressively larger frac values so the pipeline visually "travels outward"
-- from the centre to the rim. The nucleus radius (NUCLEUS_R_FRAC=0.30) is unchanged;
-- ribosomes sit just at its surface (frac 0.30) so they read as attached.
--
-- Angles are in RADIANS (screen space: +x right, +y down, so positive angle sweeps
-- clockwise on screen). Stored per-id so build_routes can place only UNLOCKED stages.
-- ============================================================================
local ZONE = {
  nucleus   = { frac = 0.00, angle = 0.0 },
  ribosomes = { frac = 0.30, angle = math.rad(135) },
  er        = { frac = 0.42, angle = math.rad(215) },
  golgi     = { frac = 0.62, angle = math.rad(275) },
  transport = { frac = 0.76, angle = math.rad(330) },
  membrane  = { frac = 0.88, angle = math.rad(55) },
}

-- Resolve a zone's STABLE screen position. Pure: (cx, cy, r) + the fixed polar offset.
local function zone_pos(id, cx, cy, r)
  local z = ZONE[id]
  if not z then
    return cx, cy
  end
  local rr = r * z.frac
  return cx + math.cos(z.angle) * rr, cy + math.sin(z.angle) * rr
end

-- FIXED mitochondria angles on the inner-mid annulus (deterministic, never reshuffled).
-- A more-powered cell lights up MORE of these SAME positions, in order. Angles are
-- chosen to fill the "gaps" between pipeline zones (upper-right, upper, right, and
-- lower-left quadrants) so the beans read as scattered, not piled on the organelles.
local MITO_ANGLES = {
  math.rad(75),  -- upper-right gap (between membrane at 55 and ribosomes at 135)
  math.rad(175), -- left gap (between ribosomes at 135 and ER at 215)
  math.rad(245), -- lower-left gap (between ER at 215 and Golgi at 275)
  math.rad(305), -- lower-right gap (between Golgi at 275 and transport at 330)
  math.rad(20),  -- right gap (between transport at 330 and membrane at 55)
  math.rad(115), -- upper-left (fills the wide upper arc for a 6th bean)
}

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

local function lerp(a, b, t) return a + (b - a) * t end

-- A cheap deterministic 0..1 hash from an integer seed -- used only for the framing
-- primitives' speckles/dot scatter (the swarm itself bakes its own scatter into the
-- instance buffer). Stateless by design.
local function hash01(n)
  local s = math.sin(n * 12.9898) * 43758.5453
  return s - math.floor(s)
end

-- Logarithmic sample: BASE + SCALE*log(1+value), capped. A READABLE SAMPLE of a sim
-- quantity, never the literal value (scale-of-numbers honesty).
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

-- Find a stage row by id in the snapshot's stages list (linear scan -- at most 6).
local function find_stage(stages, id)
  for i = 1, #stages do
    if stages[i].id == id then
      return stages[i]
    end
  end
  return nil
end

-- ============================================================================
-- CARGO PALETTE (pure -- color tokens only, no literal RGB). One colour per pipeline
-- LEG, passed into interior_swarm.draw{ cargo_palette = ... }. Agent C's swarm honors
-- it (and provides a default); we pass ours regardless. The leg->cargo mapping follows
-- the pipeline order so the cloud reads as identifiable typed streams:
--   leg 0 ribosomes->nucleus   transcript      primary (teal)
--   leg 1 nucleus->er          transcript      primary_dark
--   leg 2 er->golgi            folded protein   tertiary (warm sand)
--   leg 3 golgi->transport     secretory        secondary_bright
--   leg 4 transport->membrane  secretory        secondary
--   leg 5 mito->line           ATP              secondary_bright (bright power)
-- Tokens are reused for adjacent legs so the small palette stays legible at pixel-grid
-- resolution. Built once at load (it's static); strip alpha to rgb triples.
-- ============================================================================
local function rgb(token) return { token[1], token[2], token[3] } end

local CARGO_PALETTE = {
  rgb(colors.primary), -- transcript (nucleus inbound)
  rgb(colors.primary_dark), -- transcript (into the ER)
  rgb(colors.tertiary), -- folded protein
  rgb(colors.secondary_bright), -- secretory vesicle
  rgb(colors.secondary), -- secretory vesicle (to the rim)
  rgb(colors.secondary_bright), -- ATP (mito power)
}

-- ============================================================================
-- View lifecycle.
-- ============================================================================

function view.new()
  -- dim/drift are EASED cosmetic state (brownout fade), so update() has continuous
  -- values to lerp toward each frame; fx is the shared effects controller. The swarm
  -- itself is stateless GPU machinery -- the only per-view state is these eased
  -- cosmetics plus reused scratch arrays so draw allocates nothing per frame.
  return {
    time = 0,
    fx = fx.new(),
    dim = 1, -- 1 = full brightness; eases toward BROWNOUT_DIM under brownout
    drift = 1, -- 1 = full speed; eases toward BROWNOUT_SLOW under brownout
    tint = { 1, 1, 1 }, -- eased fuel tint multiplier (neutral white at fuel 1.0)
    endpoints_x = {},
    endpoints_y = {},
    segments = {},
  }
end

-- Cosmetic animation only -- advance the clocks and ease the brownout dim/slow + fuel
-- tint toward their targets. No game state, no GPU work.
function view.update(state, dt)
  state.time = state.time + dt
  fx.update(state.fx, dt)
  interior_swarm.update(dt)

  local dim_target = state.dim_target or 1
  local drift_target = state.drift_target or 1
  local k = clamp01(dt * DIM_EASE)
  state.dim = state.dim + (dim_target - state.dim) * k
  state.drift = state.drift + (drift_target - state.drift) * k

  local tt = state.tint_target
  if tt then
    state.tint[1] = state.tint[1] + (tt[1] - state.tint[1]) * k
    state.tint[2] = state.tint[2] + (tt[2] - state.tint[2]) * k
    state.tint[3] = state.tint[3] + (tt[3] - state.tint[3]) * k
  end
end

-- Spawn a composable effect onto this view's fx controller; returns it. (Kept exactly
-- as the public interface the orchestrator depends on.)
function view.spawn(state, effect) return fx.add(state.fx, effect) end

-- ============================================================================
-- Draw helpers (love.* lives ONLY below this line, inside draw-time code).
-- ============================================================================

-- Resolve the fuel tint target from fuel_factor: >1 leans toward the green token
-- (plant), <1 toward the warm sand token (animal), 1.0 = neutral white.
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
-- by the framing primitives so the membrane/nucleus/organelles dim + tint in lockstep
-- with the swarm (the whole interior reads as one cell under brownout / fuel lean).
local function set_interior_color(state, token, alpha)
  local t = state.tint
  love.graphics.setColor(
    token[1] * t[1],
    token[2] * t[2],
    token[3] * t[3],
    (alpha or 1) * state.dim
  )
end

-- Like set_interior_color but with an EXTRA brightness multiplier baked in (for the
-- mitochondria inner glow, which keys off snapshot scalars directly).
local function set_interior_color_x(state, token, alpha, bright)
  local t = state.tint
  bright = bright or 1
  love.graphics.setColor(
    token[1] * t[1] * bright,
    token[2] * t[2] * bright,
    token[3] * t[3] * bright,
    (alpha or 1) * state.dim
  )
end

-- The big membrane: a filled soft body disk under a brighter rim that gently wobbles.
-- The rim glow eases with `output` so a lively cell glows; the body is a dim fill that
-- reads as cytoplasm framing the instanced swarm.
local function draw_membrane(state, cx, cy, r, output)
  local t = state.time
  local segs = 64
  set_interior_color(state, colors.surface, CYTOPLASM_ALPHA)
  love.graphics.circle("fill", cx, cy, r)
  set_interior_color(state, colors.primary, 0.06)
  love.graphics.circle("fill", cx, cy, r * 0.96)

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

-- The nucleus: the centre hub. A filled compartment with a nucleolus dot and speckled
-- chromatin whose density fills in with the nucleus stage's level.
local function draw_nucleus(state, cx, cy, r, level)
  local nr = r * NUCLEUS_R_FRAC
  set_interior_color(state, colors.primary_dark, 0.55)
  love.graphics.circle("fill", cx, cy, nr)
  love.graphics.setLineWidth(2)
  set_interior_color(state, colors.primary, 0.6)
  love.graphics.circle("line", cx, cy, nr)
  love.graphics.setLineWidth(1)
  -- Nucleolus dot (a denser inner body, slightly off-centre).
  set_interior_color(state, colors.primary, 0.45)
  love.graphics.circle("fill", cx + nr * 0.18, cy - nr * 0.12, nr * 0.22)
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

-- Draw a Catmull-Rom-ish smooth ribbon through a short list of control points using
-- love's built-in spline. `pts` is a flat {x,y,...} list; we feed it as a quadratic
-- bezier-style evenly. Cheap: love.math.newBezierCurve renders the smooth poly for us.
-- Used by the ER ribbons (and reusable for any curved organelle stroke).
local function draw_spline(pts, samples)
  if #pts < 6 then
    -- Fewer than 3 control points: just draw the line as-is.
    if #pts >= 4 then
      love.graphics.line(pts)
    end
    return
  end
  local curve = love.math.newBezierCurve(pts)
  local poly = curve:render(samples or 3)
  love.graphics.line(poly)
end

-- Rough ER: concentric spline ribbons wrapping the nucleus on the ER's side, studded
-- with small ribosome dots. Ribbon COUNT/length scales with the ER level; dot DENSITY
-- scales with the ribosomes level. Drawn around the ER zone position, arcing so the
-- ribbons hug the nucleus.
local function draw_er(state, cx, cy, r, er_level, ribo_level)
  local ribbons = 1 + sample_count(er_level, 0, 1.6, 4) -- 1..5 ribbons
  -- The ER hugs the nucleus on its side; centre the ribbons on the ER zone direction.
  local z = ZONE.er
  local base_a = z.angle
  -- Arc sweep grows a touch with level so a deep ER wraps further around the nucleus.
  local sweep = math.rad(70 + 18 * math.min(er_level, 6))
  love.graphics.setLineWidth(2)
  for b = 1, ribbons do
    -- Each ribbon sits at a slightly larger radius from the nucleus, nested outward.
    local rib_r = r * (0.30 + 0.05 * b)
    local pts = {}
    local steps = 5 -- control points for the bezier
    for s = 0, steps do
      local frac = s / steps
      local a = base_a - sweep * 0.5 + sweep * frac
      -- a gentle radial ripple so the ribbon undulates like a membrane
      local ripple = math.sin(frac * math.pi * 2 + b) * r * 0.012
      local rr = rib_r + ripple
      pts[#pts + 1] = cx + math.cos(a) * rr
      pts[#pts + 1] = cy + math.sin(a) * rr
    end
    set_interior_color(state, colors.primary_dark, 0.55)
    draw_spline(pts, 4)

    -- Ribosome dots studding this ribbon; density scales with the ribosomes level.
    local dots = sample_count(ribo_level, 2, 3.5, 14)
    for d = 1, dots do
      local frac = (d - 0.5) / dots
      local a = base_a - sweep * 0.5 + sweep * frac
      local rr = rib_r + math.sin(frac * math.pi * 2 + b) * r * 0.012
      local px = cx + math.cos(a) * rr
      local py = cy + math.sin(a) * rr
      set_interior_color(state, colors.primary, 0.7)
      love.graphics.circle("fill", px, py, 1.3)
    end
  end
  love.graphics.setLineWidth(1)
end

-- Golgi: a stack of nested curved arcs (cisternae) flattening outward at the Golgi
-- zone, with a few budding vesicle dots at the outer (trans) face. Stack HEIGHT scales
-- with the Golgi level.
local function draw_golgi(state, cx, cy, r, golgi_level)
  local gx, gy = zone_pos("golgi", cx, cy, r)
  local stack = 2 + sample_count(golgi_level, 0, 1.3, 4) -- 2..6 cisternae
  -- Orient the stack so the arcs face outward from the cell centre (the trans face
  -- points to the rim). The "outward" direction is from centre to the Golgi zone.
  local out_a = ZONE.golgi.angle
  local nx, ny = math.cos(out_a), math.sin(out_a) -- outward normal
  local tx, ty = -ny, nx -- tangent (the arc spans this axis)
  local arc_w = r * 0.12 -- half-width of a cisterna arc
  local gap = r * 0.022 -- spacing between stacked cisternae
  love.graphics.setLineWidth(2)
  for c = 1, stack do
    -- Each cisterna is a shallow arc: 3 control points bowing outward, stacked along
    -- the outward normal. Inner cisternae are wider, outer ones flatten (a Golgi look).
    local push = (c - 1) * gap
    local width = arc_w * (1.0 - 0.08 * (c - 1))
    local bow = r * 0.03 * (1.0 - 0.12 * (c - 1))
    local ox = gx + nx * push
    local oy = gy + ny * push
    local pts = {
      ox - tx * width, oy - ty * width,
      ox + nx * bow, oy + ny * bow, -- mid point bows outward
      ox + tx * width, oy + ty * width,
    }
    set_interior_color(state, colors.tertiary, 0.6)
    draw_spline(pts, 4)
  end
  -- Budding vesicle dots at the outer face.
  local buds = sample_count(golgi_level, 1, 1.2, 5)
  local face_x = gx + nx * (stack * gap + r * 0.02)
  local face_y = gy + ny * (stack * gap + r * 0.02)
  for d = 1, buds do
    local jx = (hash01(d * 3.1) - 0.5) * arc_w
    local px = face_x + tx * jx + nx * hash01(d * 5.7) * r * 0.02
    local py = face_y + ty * jx + ny * hash01(d * 5.7) * r * 0.02
    set_interior_color(state, colors.secondary_bright, 0.7)
    love.graphics.circle("fill", px, py, 1.4)
  end
  love.graphics.setLineWidth(1)
end

-- Mitochondria: STATIONARY bean shapes (a squashed capsule) with 2-4 internal cristae
-- arcs, at FIXED inner-mid positions. Count = log sample of `mito`. A more-powered
-- cell shows a brighter inner glow; under brownout they gutter FIRST (the caller passes
-- a `power_bright` already lowered by the brownout state). Drawn from arcs + polygon.
local function draw_mitochondria(state, cx, cy, r, mito, power_bright)
  local n = sample_count(mito, MITO_BASE, MITO_SCALE, MAX_MITO_EMITTERS)
  local ring_r = r * MITO_RING_FRAC
  local bean_len = r * 0.13
  local bean_w = r * 0.055
  for m = 1, n do
    local a = MITO_ANGLES[m] or (m / n * 2 * math.pi)
    local mx = cx + math.cos(a) * ring_r
    local my = cy + math.sin(a) * ring_r
    -- Each bean has a fixed orientation derived from its index (deterministic).
    local rot = a + math.pi * 0.5 + (hash01(m * 9.1) - 0.5) * 0.6
    local cr, sr = math.cos(rot), math.sin(rot)
    -- Build the bean outline as a capsule: sample an ellipse, pinched slightly in the
    -- middle so it reads as a bean rather than a plain oval.
    local pts = {}
    local segs = 18
    for i = 0, segs - 1 do
      local th = (i / segs) * 2 * math.pi
      local ex = math.cos(th) * bean_len
      local ey = math.sin(th) * bean_w * (1 - 0.25 * math.cos(th * 2)) -- pinch
      pts[#pts + 1] = mx + ex * cr - ey * sr
      pts[#pts + 1] = my + ex * sr + ey * cr
    end
    -- Outer membrane fill + rim.
    set_interior_color(state, colors.tertiary, 0.5)
    love.graphics.polygon("fill", pts)
    love.graphics.setLineWidth(1.5)
    set_interior_color_x(state, colors.secondary, 0.7, power_bright)
    love.graphics.polygon("line", pts)
    love.graphics.setLineWidth(1)
    -- Inner glow: a brighter inner ellipse keyed to power (dims first on brownout).
    set_interior_color_x(state, colors.secondary_bright, 0.35, power_bright)
    local gpts = {}
    for i = 0, segs - 1 do
      local th = (i / segs) * 2 * math.pi
      local ex = math.cos(th) * bean_len * 0.6
      local ey = math.sin(th) * bean_w * 0.5
      gpts[#gpts + 1] = mx + ex * cr - ey * sr
      gpts[#gpts + 1] = my + ex * sr + ey * cr
    end
    love.graphics.polygon("fill", gpts)
    -- Cristae: 2-4 internal arcs across the short axis.
    local cristae = 2 + (m % 3)
    love.graphics.setLineWidth(1)
    set_interior_color_x(state, colors.secondary_bright, 0.6, power_bright)
    for k = 1, cristae do
      local along = (k / (cristae + 1) - 0.5) * 2 * bean_len * 0.8
      local x0 = mx + (cr * along) - (sr * bean_w * 0.7)
      local y0 = my + (sr * along) + (cr * bean_w * 0.7)
      local x1 = mx + (cr * along) + (sr * bean_w * 0.7)
      local y1 = my + (sr * along) - (cr * bean_w * 0.7)
      love.graphics.line(x0, y0, x1, y1)
    end
  end
end

-- Cytoskeleton (transport): straight tinted filament line segments radiating between
-- the unlocked zone positions. COUNT scales with the transport level -- these read as
-- the roads the swarm rides. Cheap: a handful of lines between consecutive zones.
local function draw_cytoskeleton(state, cx, cy, r, stages, transport_level)
  if transport_level <= 0 then
    return
  end
  -- Gather unlocked zone positions in pipeline order.
  local zx, zy = {}, {}
  local zn = 0
  for order = 1, #STAGE_ORDER do
    local id = STAGE_ORDER[order]
    local row = find_stage(stages, id)
    if row and row.unlocked then
      zn = zn + 1
      zx[zn], zy[zn] = zone_pos(id, cx, cy, r)
    end
  end
  if zn < 2 then
    return
  end
  -- Filament bundles per leg scale with the transport level; each filament is a faint
  -- line offset perpendicular to the leg (a bundle reads as a microtubule track).
  local per_leg = 1 + sample_count(transport_level, 0, 1.4, 4) -- 1..5 filaments
  love.graphics.setLineWidth(1)
  for k = 1, zn - 1 do
    local ax, ay = zx[k], zy[k]
    local bx, by = zx[k + 1], zy[k + 1]
    local dx, dy = bx - ax, by - ay
    local len = math.sqrt(dx * dx + dy * dy)
    if len > 1 then
      local px, py = -dy / len, dx / len -- perpendicular unit
      for f = 1, per_leg do
        local off = (f - (per_leg + 1) * 0.5) * (r * 0.012)
        set_interior_color(state, colors.border_inner_highlight, 0.28)
        love.graphics.line(ax + px * off, ay + py * off, bx + px * off, by + py * off)
      end
    end
  end
  love.graphics.setLineWidth(1)
end

-- The full organelle pass: drawn BETWEEN the membrane and the swarm, for UNLOCKED
-- stages only. Order: cytoskeleton (under) -> ER -> Golgi -> mitochondria.
-- `power_bright` (0..1-ish) keys the mitochondria glow and dims them first on brownout.
local function draw_organelles(state, snapshot, cx, cy, r, power_bright)
  local stages = snapshot.stages or {}

  local transport = find_stage(stages, "transport")
  if transport and transport.unlocked then
    draw_cytoskeleton(state, cx, cy, r, stages, transport.level or 0)
  end

  local er = find_stage(stages, "er")
  if er and er.unlocked then
    local ribo = find_stage(stages, "ribosomes")
    draw_er(state, cx, cy, r, er.level or 0, ribo and (ribo.level or 0) or 0)
  end

  local golgi = find_stage(stages, "golgi")
  if golgi and golgi.unlocked then
    draw_golgi(state, cx, cy, r, golgi.level or 0)
  end

  -- Mitochondria always drawn if there is any power machinery (mito >= 1).
  draw_mitochondria(state, cx, cy, r, snapshot.mito or 0, power_bright)
  -- No bottleneck spotlight: the player reads the choke from the swarm's own flow
  -- (congestion clumps, the bottleneck lane constricts, downstream lanes thin out),
  -- never from a halo pointing at "feed this one".
end

-- Build the swarm's endpoint + segment arrays from the snapshot, in place on the
-- view's scratch tables, and return the live endpoint/segment counts. The bridge from
-- the snapshot CONTRACT to the GPU uniforms:
--   * endpoints = one per UNLOCKED stage at its STABLE anatomical ZONE position, in
--     pipeline order, then FIXED mitochondria emitters.
--   * segments  = one per gap between consecutive endpoints, carrying the flow
--     readouts { congestion, is_bottleneck, vacancy, density } the shader reads.
-- All cheap: a few dozen table writes, no per-vesicle work.
local function build_routes(state, snapshot, cx, cy, r)
  local stages = snapshot.stages or {}
  local xs, ys, segs = state.endpoints_x, state.endpoints_y, state.segments

  -- Bottleneck pipeline INDEX so segments downstream of it read as vacant.
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

  -- UNLOCKED stages in fixed pipeline order, each at its STABLE zone position. Keep the
  -- per-stage rows alongside so the segment between endpoint k and k+1 reads the
  -- DOWNSTREAM stage's flow state (cargo entering a stage feels that stage's jam).
  local ep_count = 0
  local ordered = {}
  for order = 1, #STAGE_ORDER do
    local id = STAGE_ORDER[order]
    local row = find_stage(stages, id)
    if row and row.unlocked then
      ep_count = ep_count + 1
      xs[ep_count], ys[ep_count] = zone_pos(id, cx, cy, r)
      ordered[ep_count] = row
    end
  end

  -- Mitochondria emitters at FIXED inner-mid positions (a log sample of `mito`).
  local mito_n = sample_count(snapshot.mito, MITO_BASE, MITO_SCALE, MAX_MITO_EMITTERS)
  local mito_ring = r * MITO_RING_FRAC
  for m = 1, mito_n do
    ep_count = ep_count + 1
    local a = MITO_ANGLES[m] or (m / mito_n * 2 * math.pi)
    xs[ep_count] = cx + math.cos(a) * mito_ring
    ys[ep_count] = cy + math.sin(a) * mito_ring
    ordered[ep_count] = nil
  end

  -- Segments: one per gap between consecutive endpoints. Readout from the DOWNSTREAM
  -- endpoint's stage; mito emitter segments are calm neutral lanes.
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
      local vac = 0
      if bn_index then
        local d = (STAGE_INDEX[row.id] or k) - bn_index
        if d > 0 then
          vac = clamp01(d / (#STAGE_ORDER - bn_index + 0.001))
        end
      end
      local cap = row.cap or 0
      local fill = cap > 0 and clamp01((row.level or 0) / cap) or 0
      seg[1], seg[2], seg[3], seg[4] = congestion, is_bn, vac, 0.4 + 0.6 * fill
    else
      seg[1], seg[2], seg[3], seg[4] = 0, 0, 0, 0.6
    end
  end

  return ep_count, seg_count
end

-- Render the cell interior to the screen from a read-only snapshot (the orchestrator
-- builds it fresh each frame; see the EXACT shape in this module's header). Draws
-- nothing of the panel/HUD. Graphics state is reset at the end. Order:
--   membrane (CPU) -> nucleus (CPU) -> organelles (CPU) -> GPU swarm -> fx.
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

  -- Mitochondria gutter FIRST under brownout: a power-brightness scalar that drops
  -- harder/faster than the global dim, so the beans dim before the rest of the cell.
  -- (state.dim is the eased global brownout dim; square it for a steeper mito fade.)
  local power_bright = state.dim * state.dim

  love.graphics.push()

  -- 1) Membrane frames the interior (cytoplasm fill + wobbling bright rim).
  draw_membrane(state, cx, cy, r, snapshot.output)

  -- 2) Nucleus compartment (only once its stage is unlocked).
  local stages = snapshot.stages or {}
  local nuc = find_stage(stages, "nucleus")
  if nuc and nuc.unlocked then
    draw_nucleus(state, cx, cy, r, nuc.level)
  end

  -- 3) Organelle pass -- between the membrane/nucleus and the swarm.
  draw_organelles(state, snapshot, cx, cy, r, power_bright)

  -- 4) The GPU-INSTANCED vesicle swarm. Build the endpoint + segment uniforms from the
  -- snapshot, set the live count, map the global flow scalars, draw the live prefix.
  local ep_count, seg_count = build_routes(state, snapshot, cx, cy, r)

  -- LIVE COUNT: START as a handful and grow with leveling. throughput drives the
  -- immediate "leveling adds vesicles" feel; built is the slow bulk fill. Hard-capped.
  local throughput = snapshot.throughput or 0
  if throughput < 0 then throughput = 0 end
  local built = snapshot.built or 0
  if built < 0 then built = 0 end
  local count = COUNT_BASE
    + K_FLOW * math.log(1 + throughput)
    + K_BULK * math.log(1 + built)
  if count > MAX_LIVE_VESICLES then
    count = MAX_LIVE_VESICLES
  end
  interior_swarm.set_count(count)

  -- EFFICIENCY -> global liveliness (the dominant driver). Optimal = fast + bright;
  -- low eff = slow + dim. A small output term layers on top. The eased brownout state
  -- (state.drift) then multiplies into the motion speed so easing in/out of brownout
  -- produces a smooth deceleration/acceleration with NO teleport or runaway phase jump.
  local eff = snapshot.efficiency
  if eff == nil then eff = 1 end
  eff = clamp01(eff)
  local out_bonus = saturate(snapshot.output, OUTPUT_REF)
  local base_speed = lerp(SPEED_SLOW, SPEED_FAST, eff) + OUTPUT_SPEED_BONUS * out_bonus
  local bright = lerp(BRIGHT_DIM, BRIGHT_BRIGHT, eff) + OUTPUT_BRIGHT_BONUS * out_bonus

  -- FLOW SPEED: efficiency-derived base speed MULTIPLIED BY the eased brownout factor
  -- (state.drift, 1=full speed, BROWNOUT_SLOW at full brownout). By driving the
  -- integrated flow_phase clock at this combined rate, brownout easing changes only
  -- FUTURE accumulation -- vesicles never teleport or race when the factor changes.
  local flow_speed = base_speed * state.drift
  interior_swarm.set_flow_speed(flow_speed)

  interior_swarm.draw({
    endpoints_x = state.endpoints_x,
    endpoints_y = state.endpoints_y,
    endpoint_count = ep_count,
    segments = state.segments,
    segment_count = seg_count,
    -- brightness only: motion rate is owned by set_flow_speed above (speed/slow are
    -- ignored by the swarm's phase-integrated shader; do not pass them).
    brightness = bright * state.dim, -- efficiency/output brightness * eased brownout dim
    tint = state.tint, -- eased fuel_factor tint
    cargo_palette = CARGO_PALETTE, -- typed-cargo colours (Agent C honors / defaults)
  })

  -- 5) World-space fx ride above the interior.
  fx.draw_world(state.fx)

  love.graphics.pop()

  fx.draw_overlay(state.fx)

  -- 6) STRESS VIGNETTE (optional tell for impending lysis). snapshot.stress is 0..1;
  -- defaults to 0 if absent (guard: new field from Agent ECON, not yet on all builds).
  -- A faint creeping warm-red glow at the cell rim that intensifies as stress rises.
  -- Implementation: a wide rim stroke at the cell edge, alpha proportional to stress.
  -- Cheap: one thick-line circle (no per-pixel work). Drawn in screen space (after pop)
  -- so it doesn't inherit any pushed transform.
  local stress = clamp01(snapshot.stress or 0)
  if stress > 0.02 then
    local vx = win_w * 0.5
    local vy = win_h * 0.5
    local vr = math.min(win_w, win_h) * CELL_FILL
    local vc = colors.quaternary
    -- Rim glow: a thick circle stroke whose width grows with stress (up to ~12% of r),
    -- so at full stress the interior reads as visibly "under attack at the membrane".
    local rim_width = vr * (0.04 + 0.08 * stress)
    love.graphics.setLineWidth(rim_width)
    love.graphics.setColor(vc[1], vc[2], vc[3], 0.45 * stress)
    love.graphics.circle("line", vx, vy, vr - rim_width * 0.5)
    love.graphics.setLineWidth(1)
  end

  love.graphics.setLineWidth(1)
  love.graphics.setColor(1, 1, 1, 1)
end

return view
