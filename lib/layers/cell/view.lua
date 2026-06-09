-- Cell view: programmatic, asset-free visuals for the living micro-world. The
-- only cell module besides the orchestrator that touches love.*. Deliberately
-- MINIMAL: every renderable -- cells, food, blooms, prey, predators -- is a flat
-- solid pixel SQUARE drawn through ONE generic path (draw_entity). There is no
-- per-type draw function and no trait-readout ornament (the old greener-bodies/
-- flagella/membrane/speckle "visuals as readout" pillar was dropped here per the
-- design direction): an entity's look comes entirely from its render component
-- (kind -> palette/size, plus data-driven pop_in/pulse flags). Adding a
-- renderable = spawn an entity with a render component + (at most) a palette row,
-- never a new draw function (the composition pillar).
--
-- The camera is a STEPPED fit-camera: it frames world.snapshot's field into the
-- window with an off-screen margin (VIEW_FRAC) that hides the toroidal wrap seam,
-- and -- because the field size is a step function of population -- it holds
-- steady within a tier and glides out one notch at each threshold. Within that
-- margin it pans gently toward snap.action (the world's toroidal action centre)
-- so the action rides near centre without the zoom ever wavering. Transient
-- effects (feed flash, shake, ripple, death bursts, the endosymbiosis beat) are
-- composable entities owned by an fx controller (lib/engine/fx.lua); shake is
-- applied to the draw transform only, never the camera, so screen_to_world stays
-- exact. Starving cells dim (their entity-level `hunger` lowers alpha), and a
-- held mitochondrion stamps a tiny inner mark on every cell.
local fx = require("lib.engine.fx")
local colors = require("lib.engine.ui.colors")
local cell_field = require("lib.layers.cell.cell_field")

local view = {}

-- Flat-square sizes in WORLD units (scaled by the camera zoom at draw time).
local CELL_SIZE = 6 -- the founder is a chunky pixel; pop-in scales young cells up
local FOOD_SIZE = 2 -- a ~1.5-2px nutrient dot
local PREY_SIZE = 4
local PREDATOR_SIZE = 9 -- a distinctly larger, menacing square
local COMPETITOR_SIZE = 5 -- a neutral rival cell: between prey and our own founder
local POP_IN = 0.5 -- mitosis pop-in duration, seconds
local ENDO_LIFE = 1.2 -- endosymbiosis-beat duration, seconds
local HUNGER_DIM = 8 -- seconds of hunger that fully dims a starving cell
local HUNGER_FADE = 0.7 -- how far a fully starved cell fades (alpha *= 1 - this)
local FED_PULSE = 0.6 -- seconds of the post-meal swell (matches the world's `fed` stamp)
local FED_SWELL = 0.35 -- peak extra size of the just-fed pulse (a satisfied gulp)

-- Clamp to [0,1]; defined up here so the trait-fold helper below (and everything
-- after) can share the one definition.
local function clamp01(v)
  if v < 0 then
    return 0
  elseif v > 1 then
    return 1
  end
  return v
end

-- The GPU swarm field's response to the world's actors. Radius is the reach (world
-- units). The bloom pull is a FRACTION of the remaining distance a fully-engaged
-- cell eases toward the food each frame (in [0,1] -- never overshoots); the
-- predator push is a modest world-unit shove away. Tuned by eye for a legible react.
local BLOOM_ATTRACT_R = 280
local BLOOM_ATTRACT_S = 0.6
local PRED_REPEL_R = 190
local PRED_REPEL_S = 54 -- softened (was 70): with the shader's per-cell jitter this
-- averages a gentler lean-away, so cells avoid the predator without carving a clean ring
-- Seconds a bloom's pull eases in after it spawns and out before it expires, so the
-- swarm's rush toward food ramps smoothly instead of popping the instant a bloom
-- appears/vanishes (the attractor turning on/off in one frame).
local BLOOM_FADE = 0.4

-- Trait -> GPU-field response. opts.stats (cell.lua passes traits.stats here) drives
-- a handful of CHEAP GLOBAL uniforms so leveling a trait visibly shifts EVERY cell
-- in the overflow field at once -- no per-cell features, no new art. All knobs sit
-- at their neutral value when stats are absent (tests / other callers), so the look
-- is unchanged. Each is gently saturated/clamped so a deep build reads without the
-- field going garish or jittery.
--
-- Photosynthesis -> pigment: blend the cell token toward a green pigment as
-- photo_mult climbs above 1 (a photosynthetic colony greens up). PHOTO_TINT is the
-- pigment target (the nourishment green token feel); PHOTO_TINT_MAX caps the blend
-- so the protagonist teal is tinted, never fully replaced.
local PHOTO_TINT = colors.secondary -- green pigment target (nourishment hue)
local PHOTO_TINT_MAX = 0.5 -- max blend toward green (keeps the teal identity)
local PHOTO_TINT_K = 0.35 -- blend per unit of (photo_mult - 1)
-- Motility -> swim/weave rate: scale the field's fine-weave rate from stats.speed
-- relative to the founding SPEED_BASE (30 u/s in traits). A motile colony darts;
-- a sluggish one drifts. Clamped so a maxed swimmer stays lively, not frantic.
local SPEED_BASE_REF = 30 -- traits.SPEED_BASE: speed at motility 0 (the neutral 1.0x)
local SWIM_SCALE_MAX = 2.2 -- cap on the weave-rate multiplier
-- Evasion -> firmness: a higher evade chance (stats.evasion, ~0..0.2) firms the
-- body a touch (slightly larger, sturdier squares). Small, legible, not a balloon.
local EVASION_SIZE_K = 1.2 -- size grows by this * evasion (so ~+24% at evasion 0.2)
-- Chemotaxis -> sense halo: a faint additive shimmer scaled by how far stats.
-- sense_range sits above the founding SENSE_BASE (70 in traits). A keen-sensing
-- colony glows faintly as it "feels" the dish. Capped low so it lifts, not blares.
local SENSE_BASE_REF = 70 -- traits.SENSE_BASE: range at sensing 0
local SENSE_HALO_PER = 0.18 -- halo per unit of (sense_range/SENSE_BASE_REF - 1)
local SENSE_HALO_MAX = 0.35 -- cap on the additive shimmer

-- Fold opts.stats into the field's trait knobs: a tinted body color plus the swim/
-- size/halo scalars the shader reads. nil-safe: with no stats it returns the
-- neutral look (base color, 1, 1, 0) so the field renders exactly as before.
local function field_traits(base_color, stats)
  if not stats then
    return base_color, 1, 1, 0
  end
  -- Photosynthesis: blend base -> green pigment by (photo_mult - 1).
  local color = base_color
  local photo = stats.photo_mult
  if photo and photo > 1 then
    local m = clamp01((photo - 1) * PHOTO_TINT_K)
    if m > PHOTO_TINT_MAX then
      m = PHOTO_TINT_MAX
    end
    color = {
      base_color[1] + (PHOTO_TINT[1] - base_color[1]) * m,
      base_color[2] + (PHOTO_TINT[2] - base_color[2]) * m,
      base_color[3] + (PHOTO_TINT[3] - base_color[3]) * m,
    }
  end
  -- Motility: weave-rate multiplier from speed / SPEED_BASE_REF, clamped.
  local swim = 1
  if stats.speed and stats.speed > 0 then
    swim = stats.speed / SPEED_BASE_REF
    if swim > SWIM_SCALE_MAX then
      swim = SWIM_SCALE_MAX
    elseif swim < 0 then
      swim = 0
    end
  end
  -- Evasion: a touch firmer/larger body.
  local size = 1 + EVASION_SIZE_K * (stats.evasion or 0)
  -- Chemotaxis: additive sense shimmer from sense_range above the base, capped.
  local halo = 0
  if stats.sense_range and stats.sense_range > SENSE_BASE_REF then
    halo = SENSE_HALO_PER * (stats.sense_range / SENSE_BASE_REF - 1)
    if halo > SENSE_HALO_MAX then
      halo = SENSE_HALO_MAX
    end
  end
  return color, swim, size, halo
end

local VIEW_FRAC = 0.9 -- field fills this fraction of the window; the rest is the
-- off-screen margin that hides the wrap seam (tz divides by it, so the field
-- slightly OVERFLOWS the viewport and its edges fall outside).
local CAM_SMOOTH = 0.12 -- camera lerp factor (fraction per frame toward target)
-- Tier steps get a much slower glide than the cinematic focus: at CAM_SMOOTH a
-- threshold crossing snapped the zoom out in ~a quarter second, which read as a
-- jolt -- especially when a growth spurt crossed tiers back to back. At this
-- rate a step eases out over a couple of seconds, and consecutive steps just
-- extend the same glide. The focus push-in keeps the snappier CAM_SMOOTH.
local TIER_SMOOTH = 0.03
local SEAM_PAD = 6 -- px the field edge must keep past the window edge when panned
-- The smart-framing pan gets its OWN, far slower lerp (state.pan), decoupled
-- from CAM_SMOOTH: the action centre jumps when a bloom spawns or expires, and
-- at camera speed that jerk moved the world under the player's cursor enough
-- to miss bloom clicks. At this rate the drift is glacial -- near-subliminal --
-- while tier glides and the cinematic focus keep the snappier CAM_SMOOTH.
local PAN_SMOOTH = 0.008
-- Smart framing is an EARLY-GAME affordance: with only a founder and a bloom
-- on a small field, drifting toward the action genuinely helps. Once the frame
-- is already full of cells the pan buys nothing -- the swarm IS the frame --
-- and its centroid wobble just reads as aimless camera drift. So the bias
-- fades from full strength at PAN_FADE_LO cells to zero at PAN_FADE_HI,
-- leaving a grown colony on a rock-steady centred fit.
local PAN_FADE_LO = 10
local PAN_FADE_HI = 50

-- FOUNDER LOCK: before the very first split, the dish holds a single cell on the
-- roomy founder tier -- the whole field fits inside the window, so the stepped
-- fit-camera shows the founder as a lone dot adrift in empty dish and the
-- seam-clamped pan has no slack to follow it. While that one cell is all there
-- is, override the fit and LOCK onto it: centre the founder and push in by
-- LOCK_PUSH past the fit zoom so it reads as the subject and the camera tracks it
-- as it swims. The moment it splits we latch `split_seen` and never lock again --
-- the gentle TIER_SMOOTH glide eases the zoom back out into normal smart framing,
-- and a late-game collapse back to one cell stays in the grown-colony fit rather
-- than lurching back in.
-- Keep the push GENTLE: the lock's real effect is centring + tracking the founder,
-- not a tight close-up. Too much zoom (2.2 was) crops the dish so far that blooms
-- spawn off-screen -- the founder-era affordance the player most needs to see. At
-- 1.0 the founder is centred and tracked at the plain fit zoom, so the whole dish
-- frames as it normally would (see also world.founder_bloom_inset, which keeps the
-- first blooms off the overflowing short-axis edge).
local LOCK_PUSH = 1.0 -- founder-lock zoom as a multiple of the stepped fit zoom

-- The nutrient bloom's on-screen click-target radius, in PIXELS. The bloom is an
-- interactive affordance, so it holds a CONSTANT screen size (like UI) as the
-- stepped camera zooms across field tiers -- not a world-scaled disk that
-- balloons when the camera tucks in tight on a small field. draw_bloom converts
-- this to world units via the zoom; view.bloom_radius hands the same world-space
-- size to the orchestrator's hit-test so clicks line up with the drawn disk.
local BLOOM_SCREEN_R = 24

-- The palette, keyed by render kind: each kind BINDS a global color token (the
-- generic ordinals in lib/engine/ui/colors) to its role here at the view's edge.
-- No literal RGB and no per-layer color exports -- anything that needs "the cell
-- hue" (e.g. the orchestrator's death-burst fx) reads the same global token.
local PALETTE = {
  cell = colors.primary,
  food = colors.secondary,
  bloom = colors.secondary_bright,
  prey = colors.tertiary,
  predator = colors.quaternary,
  -- Competitor cells are OTHER life, not ours -- and now a CONTESTED dish of several
  -- vibrant rival species (see COMPETITOR_SPECIES below). The muted grey is only the
  -- fallback for a tint-less rival (legacy saves / tests); a live competitor carries a
  -- `tint` seed the resolve() path buckets into a bright species hue. Drawn through
  -- the same generic flat path.
  competitor = colors.muted,
}

-- The vibrant rival-species hues (owned by colors.lua). Each competitor's color-free
-- `tint` seed in [0,1) is bucketed into this list, so the rival crowd shows distinct
-- orange/gold/pink/purple/violet microbes rather than one uniform color.
local COMPETITOR_SPECIES = colors.competitor_species

-- Default flat-square size per kind (a render component may override via size).
local SIZE = {
  cell = CELL_SIZE,
  food = FOOD_SIZE,
  prey = PREY_SIZE,
  predator = PREDATOR_SIZE,
  competitor = COMPETITOR_SIZE,
}

-- Per-kind alpha overrides for the flat primitives (none needed currently --
-- the bloom carries its own shape). Overridable per entity via render.alpha.
local ALPHA = {}
local ALPHA_DEFAULT = 0.92

function view.new()
  -- camera: smoothed fit-camera that frames snap.field into the window.
  -- init=false triggers an instant snap on the first draw so there is no
  -- jarring slide from (0,0) at startup. fx: the composable effects controller.
  return {
    time = 0,
    fx = fx.new(),
    camera = { zoom = 1, x = 0, y = 0, init = false },
    pan = { x = 0, y = 0 }, -- smart-framing offset, lerped slowly (PAN_SMOOTH)
    split_seen = false, -- latched once the founder first splits; gates the founder lock
    locked = false, -- true while the camera is locked on the lone founder (gates bloom confine)
  }
end

function view.update(state, dt)
  state.time = state.time + dt
  fx.update(state.fx, dt)
  cell_field.update(dt) -- advance the GPU swarm's shader clock
end

-- Spawn a composable effect entity onto this view's fx controller; returns it.
-- The orchestrator builds effects (fx.flash/fx.shake/fx.pulse) and adds them
-- here, e.g. on a bloom feed.
function view.spawn(state, effect) return fx.add(state.fx, effect) end

-- Inverse of the translate-then-scale transform: world = (screen - cam) / zoom.
-- Uses the STEADY camera (no transient shake offset), so bloom-click hit-testing
-- in the orchestrator stays exact even while the view is shaking.
function view.screen_to_world(state, sx, sy)
  local cam = state.camera
  return (sx - cam.x) / cam.zoom, (sy - cam.y) / cam.zoom
end

-- Forward of the same transform: screen = world * zoom + cam. Uses the STEADY
-- camera (no shake offset) so an overlay anchored to a world point -- the
-- transition's title text riding the cell that evolved -- stays put while the
-- view shakes, matching screen_to_world's basis.
function view.world_to_screen(state, wx, wy)
  local cam = state.camera
  return wx * cam.zoom + cam.x, wy * cam.zoom + cam.y
end

-- Override the fit-camera with a CINEMATIC focus on a world point at an absolute
-- zoom: draw_world drives its lerp toward this target instead of the field fit,
-- so the camera smoothly pans + pushes in (the end-of-phase-1 transition's move
-- onto the cell that triggered). clear_focus returns the camera to the field fit.
function view.focus(state, wx, wy, zoom) state.focus = { x = wx, y = wy, zoom = zoom } end

function view.clear_focus(state) state.focus = nil end

-- The bloom's world-space radius at the current zoom: its constant on-screen UI
-- size (BLOOM_SCREEN_R px) projected back into world units, so the orchestrator's
-- world-space click hit-test matches the disk the view draws. Uses the steady
-- camera zoom (same basis as screen_to_world), so the two stay consistent.
function view.bloom_radius(state) return BLOOM_SCREEN_R / state.camera.zoom end

-- The endosymbiosis beat: an engulfed-prey square SPIRALS inward and shrinks into
-- the host cell, then a bright flash blooms as the organelle is KEPT -- the moment
-- a swallowed microbe becomes a permanent organelle, made literal in flat pixels.
-- A composable, fx-managed world-space effect at (cx, cy).
local function endosymbiosis_effect(cx, cy)
  return {
    age = 0,
    life = ENDO_LIFE,
    space = "world",
    update = function(self, dt)
      self.age = self.age + dt
      return self.age >= self.life
    end,
    draw = function(self)
      local k = clamp01(self.age / self.life)
      local ease = k * k * (3 - 2 * k) -- smoothstep
      -- The prey square spirals in: radius shrinks to 0 over a few turns.
      local prey = PALETTE.prey
      local radius = 42 * (1 - ease)
      local angle = k * 6 * math.pi
      local px = cx + math.cos(angle) * radius
      local py = cy + math.sin(angle) * radius
      local s = PREY_SIZE * (1 - 0.7 * ease)
      local half = s * 0.5
      love.graphics.setColor(prey[1], prey[2], prey[3], 0.95 * (1 - ease * 0.4))
      love.graphics.rectangle("fill", px - half, py - half, s, s)
      -- The keep-flash blooms only in the final stretch, as the prey arrives.
      local fk = clamp01((k - 0.6) / 0.4)
      if fk > 0 then
        local fs = CELL_SIZE + 34 * fk
        local fh = fs * 0.5
        love.graphics.setColor(1, 1, 0.85, 0.55 * (1 - fk))
        love.graphics.rectangle("fill", cx - fh, cy - fh, fs, fs)
      end
      love.graphics.setColor(1, 1, 1, 1)
    end,
  }
end

-- Play the endosymbiosis beat at a world position (pos = { x, y }), composed from
-- the spiral effect plus a warm flash + ripple from the shared fx primitives, so
-- the rare keep is unmistakable.
function view.endosymbiosis_beat(state, pos)
  fx.add(state.fx, endosymbiosis_effect(pos.x, pos.y))
  fx.add(state.fx, fx.flash({ color = { 1, 1, 0.8 }, alpha = 0.2, life = 0.4 }))
  fx.add(
    state.fx,
    fx.pulse({ x = pos.x, y = pos.y, color = { 1, 0.95, 0.6 }, alpha = 0.7, life = 0.7 })
  )
end

-- Resolve the common flat-primitive params (size/color/alpha + the data-driven
-- pop_in/pulse modifiers) from an entity's render component. Shared by the flat
-- primitive shapes so they stay DRY. `amul` (default 1) is a final alpha multiplier
-- the end-of-phase-1 dive uses to FADE everything but the winning cell out.
local function resolve(e, t, amul)
  local rc = e.render
  local size = rc.size or SIZE[rc.kind] or CELL_SIZE
  local color = rc.color or PALETTE[rc.kind] or PALETTE.cell
  local alpha = rc.alpha or ALPHA[rc.kind] or ALPHA_DEFAULT
  -- A competitor microbe picks its vibrant species hue from its color-free `tint`
  -- seed (set at spawn): bucket [0,1) across the species list. Falls back to the
  -- muted competitor token when tint-less (legacy/test entities).
  if rc.kind == "competitor" and e.tint and #COMPETITOR_SPECIES > 0 then
    local idx = math.floor(e.tint * #COMPETITOR_SPECIES) + 1
    if idx > #COMPETITOR_SPECIES then
      idx = #COMPETITOR_SPECIES
    end
    color = COMPETITOR_SPECIES[idx]
  end
  -- Per-instance body-size variety (predators + competitors carry a `size_scale`
  -- in [0.5, 5] from world.lua): size becomes that multiple of the CELL_SIZE basis,
  -- so the non-player actors range from half-a-cell darters to 5x looming giants.
  -- Overrides the kind's default flat size; absent on cells/food/prey/blooms.
  if e.size_scale then
    size = CELL_SIZE * e.size_scale
  end
  if rc.pop_in then
    size = size * clamp01((e.age or POP_IN) / POP_IN) -- mitosis pop-in
  end
  if rc.pulse then
    alpha = alpha * (0.78 + 0.22 * math.sin(t * 4 + (e.x + e.y) * 0.05))
  end
  -- Engulfing pause (entity-level `feeding` flag on a parked cell): swell a touch
  -- and breathe the alpha, so the feed time reads as engulfing -- no new draw path.
  if e.feeding then
    size = size * 1.15
    alpha = alpha * (0.85 + 0.15 * math.sin(t * 8))
  end
  -- Post-meal pulse (entity-level `fed` countdown stamped when a meal completes):
  -- one smooth swell-and-relax -- sin(pi*k) rises from 0 to FED_SWELL and back as
  -- the countdown drains -- so a successful feed reads as a satisfied gulp.
  if e.fed and e.fed > 0 then
    size = size * (1 + FED_SWELL * math.sin(math.pi * clamp01(e.fed / FED_PULSE)))
  end
  -- Starvation tell: a cell that hasn't eaten in a while dims toward HUNGER_FADE,
  -- so the colony visibly pales before the hungriest burst into recycled motes.
  if e.hunger and e.hunger > 0 then
    alpha = alpha * (1 - HUNGER_FADE * clamp01(e.hunger / HUNGER_DIM))
  end
  if amul then
    alpha = alpha * amul
  end
  return size, color, alpha
end

local function draw_square(e, t, zoom, amul)
  local size, color, alpha = resolve(e, t, amul)
  if size <= 0 or alpha <= 0 then
    return
  end
  local half = size * 0.5
  love.graphics.setColor(color[1], color[2], color[3], alpha)
  love.graphics.rectangle("fill", e.x - half, e.y - half, size, size)
end

local function draw_circle(e, t, zoom, amul)
  local size, color, alpha = resolve(e, t, amul)
  if size <= 0 or alpha <= 0 then
    return
  end
  love.graphics.setColor(color[1], color[2], color[3], alpha)
  love.graphics.circle("fill", e.x, e.y, size * 0.5)
end

-- The nutrient bloom: a soft pulsing CIRCLE with a "click me" rim and a little
-- countdown timer bar -- the clickable feed target. Its radius is a CONSTANT
-- on-screen size (BLOOM_SCREEN_R px, divided by zoom into world units here), so
-- the whole affordance -- disk, glow, rim, bar -- holds a steady UI size across
-- field tiers instead of scaling with the in-game zoom. Reads timer/life off the
-- entity for the countdown.
local function draw_bloom(e, t, zoom, amul)
  local col = PALETTE.bloom
  local a = amul or 1
  if a <= 0 then
    return
  end
  local r = BLOOM_SCREEN_R / zoom
  local frac = clamp01((e.timer or 1) / (e.life or 1)) -- countdown remaining
  local pulse = 1 + 0.06 * math.sin(t * 6)
  -- Soft outer glow (the pulse), then the body disk.
  love.graphics.setColor(col[1], col[2], col[3], 0.10 * a)
  love.graphics.circle("fill", e.x, e.y, r * 1.7 * pulse)
  love.graphics.setColor(col[1], col[2], col[3], 0.18 * a)
  love.graphics.circle("fill", e.x, e.y, r)
  -- Bright "click me" rim, a constant screen-pixel width.
  love.graphics.setLineWidth(2 / zoom)
  love.graphics.setColor(col[1], col[2], col[3], 0.85 * a)
  love.graphics.circle("line", e.x, e.y, r * pulse)
  love.graphics.setLineWidth(1 / zoom)
  -- Little countdown timer bar beneath the bloom (depletes over the ~3s window).
  local bw = r * 1.6
  local bh = 3 / zoom
  local bx = e.x - bw * 0.5
  local by = e.y + r * 1.25
  love.graphics.setColor(1, 1, 1, 0.18 * a)
  love.graphics.rectangle("fill", bx, by, bw, bh)
  love.graphics.setColor(col[1], col[2], col[3], 0.9 * a)
  love.graphics.rectangle("fill", bx, by, bw * frac, bh)
  love.graphics.setColor(1, 1, 1, 1)
end

-- Shape registry: THE one generic render path dispatches on the render
-- component's shape (default flat square). Adding a renderable = pick a shape
-- (or register one here once) + attach a render component -- never a bespoke
-- per-type draw call scattered through the renderer.
local SHAPES = {
  square = draw_square,
  circle = draw_circle,
  bloom = draw_bloom,
}

local function draw_entity(e, t, zoom, amul)
  local rc = e.render
  if not rc then
    return
  end
  local drawer = SHAPES[rc.shape or "square"] or draw_square
  drawer(e, t, zoom, amul)
end

local function draw_list(list, t, zoom, amul)
  for i = 1, #list do
    draw_entity(list[i], t, zoom, amul)
  end
end

-- The darker inner square stamped on a cell once the colony holds the
-- mitochondrion -- the organelle that was once a separate cell, made visible. The
-- simulated boids get it from draw_mito_mark below (it rides their mitosis pop-in
-- scale); the overflow field gets the same colour as its mark pass, which the
-- shader sizes from the cell body (MARK_SCALE) so it rides each instance's size.
local MITO_COLOR = colors.primary_dark -- inner-detail shade of the cell's token
local function draw_mito_mark(e, amul)
  local rc = e.render
  if not rc or rc.kind ~= "cell" then
    return
  end
  local a = 0.9 * (amul or 1)
  if a <= 0 then
    return
  end
  local scale = rc.pop_in and clamp01((e.age or POP_IN) / POP_IN) or 1
  local s = (rc.size or SIZE.cell or CELL_SIZE) * 0.34 * scale
  if s <= 0 then
    return
  end
  love.graphics.setColor(MITO_COLOR[1], MITO_COLOR[2], MITO_COLOR[3], a)
  love.graphics.circle("fill", e.x, e.y, s * 0.5)
  love.graphics.setColor(1, 1, 1, 1)
end

-- Render the whole world. The camera fits snap.field into the window (stepped,
-- since the field steps with population) and lerps toward the target each frame.
-- World-space objects are drawn inside a push/translate/scale transform
-- (translate THEN scale, matching lib/layers/solar.lua); after pop the graphics
-- state is reset so the orchestrator's panel UI inherits clean defaults.
function view.draw_world(state, snap, opts)
  local t = state.time
  local mito = opts and opts.mito

  -- Stepped fit-camera. tz divides by VIEW_FRAC so the field slightly overflows
  -- the window -- the off-screen margin that hides the toroidal wrap seam.
  local win_w, win_h = love.graphics.getDimensions()
  local f = snap.field or { w = win_w, h = win_h }

  -- A tier step RECENTRES the world: world.update shifts every entity by half
  -- the field growth so the realm opens up around the colony. The smoothed
  -- camera lags its new target, so without compensation the whole shifted
  -- colony LURCHES across the screen by (shift * zoom) in one frame and the
  -- slow glide drags it back -- the zoom-in-then-out stutter. Absorb the same
  -- half-growth shift into the camera position the moment the field changes:
  -- on-screen nothing moves at the step instant, and the gentle zoom-out
  -- glide is the only visible motion.
  local cam = state.camera
  local lf = state.last_field
  if lf and cam.init and (f.w ~= lf.w or f.h ~= lf.h) then
    cam.x = cam.x - ((f.w - lf.w) / 2) * cam.zoom
    cam.y = cam.y - ((f.h - lf.h) / 2) * cam.zoom
  end
  state.last_field = { w = f.w, h = f.h }

  local tz = math.min(win_w / f.w, win_h / f.h) / VIEW_FRAC
  local tx = win_w / 2 - (f.w / 2) * tz -- target translate: field is centered
  local ty = win_h / 2 - (f.h / 2) * tz
  -- Smart framing: pan the fit toward the ACTION (snap.action, world.lua's
  -- toroidal weighted centre of cells/blooms/predators) instead of always
  -- dead-centring the field. The pan spends the same off-screen margin
  -- VIEW_FRAC already buys, clamped (minus SEAM_PAD) so the field still
  -- overflows the window on every side and the wrap seam stays hidden; an
  -- axis with no slack (window wider than the overflow) stays centred. The
  -- zoom is untouched -- the stepped fit-camera holds steady as designed.
  -- The offset is smoothed by its own glacial PAN_SMOOTH lerp (state.pan),
  -- NOT folded into the CAM_SMOOTH target: the action centre steps when a
  -- bloom spawns/expires, and chasing it at camera speed moved the world
  -- under the cursor mid-click. This drift is slow enough to feel seamless.
  local pan = state.pan
  local want_x, want_y = 0, 0
  if snap.action then
    local function pan_offset(want, win, span, centered)
      local lo, hi = win - span + SEAM_PAD, -SEAM_PAD
      if lo > hi then
        return 0 -- no seam-safe slack on this axis: stay centred
      end
      return math.max(lo, math.min(hi, want)) - centered
    end
    want_x = pan_offset(win_w / 2 - snap.action.x * tz, win_w, f.w * tz, tx)
    want_y = pan_offset(win_h / 2 - snap.action.y * tz, win_h, f.h * tz, ty)
    -- Fade the bias out as the swarm grows (see PAN_FADE_LO/HI above): a frame
    -- already full of cells doesn't need chasing, so the pan target eases back
    -- to the plain centred fit and the slow PAN_SMOOTH lerp glides it home.
    local fade = 1 - clamp01((#snap.cells - PAN_FADE_LO) / (PAN_FADE_HI - PAN_FADE_LO))
    want_x, want_y = want_x * fade, want_y * fade
  end
  pan.x = pan.x + (want_x - pan.x) * PAN_SMOOTH
  pan.y = pan.y + (want_y - pan.y) * PAN_SMOOTH
  tx = tx + pan.x
  ty = ty + pan.y
  -- Founder lock: latch split_seen the instant a second cell exists, then never
  -- lock again. Until that first split, retarget the fit onto the lone founder --
  -- centred and pushed in past the fit zoom -- so the camera locks on and tracks
  -- it. After the split the target reverts to the smart-framing fit above and the
  -- slow TIER_SMOOTH lerp glides the zoom-out home (no lock on a late collapse).
  local cells = snap.cells or {}
  if #cells > 1 then
    state.split_seen = true
  end
  -- `locked` is published for the orchestrator: while it's true, cell.lua confines
  -- bloom spawns to the locked frame (view.screen_to_world of the window corners)
  -- so the founder-era click target never spawns off the tracked view.
  state.locked = (not state.split_seen) and #cells == 1
  if state.locked then
    local c = cells[1]
    tz = tz * LOCK_PUSH
    tx = win_w / 2 - c.x * tz
    ty = win_h / 2 - c.y * tz
  end
  -- Cinematic override: when focused, retarget the lerp onto a world point at an
  -- absolute zoom (the transition's push-in onto the triggering cell). The camera
  -- still eases toward it, so the move reads as a smooth glide, not a cut.
  if state.focus then
    tz = state.focus.zoom
    tx = win_w / 2 - state.focus.x * tz
    ty = win_h / 2 - state.focus.y * tz
  end
  if not cam.init then
    cam.zoom, cam.x, cam.y, cam.init = tz, tx, ty, true
  else
    -- Slow TIER_SMOOTH for the fit camera (tier steps glide gently); the
    -- cinematic focus keeps the snappier CAM_SMOOTH for its push-in.
    local s = state.focus and CAM_SMOOTH or TIER_SMOOTH
    cam.zoom = cam.zoom + (tz - cam.zoom) * s
    cam.x = cam.x + (tx - cam.x) * s
    cam.y = cam.y + (ty - cam.y) * s
  end

  -- Transient shake offset from active fx: applied to the draw transform only,
  -- never written into the camera, so screen_to_world (clicks) stays exact.
  local ox, oy = fx.camera_offset(state.fx)

  love.graphics.push()
  love.graphics.translate(cam.x + ox, cam.y + oy)
  love.graphics.scale(cam.zoom)

  -- ISOLATE (the end-of-phase-1 dive): everything but the winning cell DISSOLVES.
  -- opts.isolate = { x, y, fade } -- as `fade` ramps 0->1 across the cinematic the whole
  -- dish (other cells, the overflow field, food/blooms/prey/rivals/predators) fades to
  -- nothing, leaving only the triggering cell -- the nearest boid to (x, y) -- which
  -- holds full alpha as the camera plunges into it. `world_amul` is the surviving alpha
  -- of everything else; `hero_i` is the boid index spared the fade. Absent -> 1 / nil
  -- (normal play and phase 2 are byte-identical to before).
  local iso = opts and opts.isolate
  local world_amul = 1
  local hero_i = nil
  if iso then
    world_amul = clamp01(1 - (iso.fade or 0))
    local best = math.huge
    for i = 1, #snap.cells do
      local c = snap.cells[i]
      local dx, dy = c.x - iso.x, c.y - iso.y
      local d2 = dx * dx + dy * dy
      if d2 < best then
        best, hero_i = d2, i
      end
    end
  end

  draw_list(snap.foods, t, cam.zoom, world_amul)
  draw_list(snap.blooms, t, cam.zoom, world_amul)
  draw_list(snap.prey, t, cam.zoom, world_amul)
  -- Neutral rival microbes: ambient background life (cosmetic skin of the closed-form
  -- nutrient competition), drawn beneath the player's swarm via the generic flat path.
  draw_list(snap.competitors, t, cam.zoom, world_amul)

  -- HYBRID swarm render. snap.cells is world.lua's small SIMULATED set -- the cells
  -- that actually sense motes, chase, engulf and get hunted -- so drawing them as
  -- real boids restores genuine feeding/consuming behaviour, and the early/mid game
  -- (colony <= the sim cap) is ALL real boids: no procedural dashing, every cell you
  -- see is hunting. The GPU procedural field then fills in only the COSMETIC OVERFLOW
  -- above that simulated count once the colony outgrows it, keeping the teeming-mass
  -- look at scale for a few uniforms of CPU cost. swarm_count is the colony-driven
  -- visible sample; the simulated set draws 1:1 and the field draws the remainder.
  local cells = snap.cells
  local n = #cells
  local swarm_count = (opts and opts.swarm_count) or n
  -- The field draws only the swarm ABOVE the simulated cap -- the real boids cover
  -- everything up to it. Computing overflow against the CAP (not the live count n,
  -- which lags as reconcile buds daughters in) is what stops the field from drawing
  -- PHANTOM cells while the real swarm is still filling in: below the cap, the colony
  -- sample may run ahead of the few real boids on screen, but those missing cells are
  -- still being BUDDED in -- they must not pop in as parentless field instances. So
  -- below the cap the field is empty; only a genuinely larger-than-cap colony spills
  -- into it. Defaults to swarm_count (zero field) when no cap is supplied.
  local sim_cap = (opts and opts.sim_cap) or swarm_count
  local overflow = swarm_count - sim_cap
  if overflow < 0 then
    overflow = 0
  end

  -- The overflow field draws BEHIND the simulated boids: the cells doing the visible
  -- hunting read crisply in front of the ambient mass. Its instances MEANDER in place
  -- and still STREAM toward blooms / FLEE predators via the attractor/repulsor
  -- uniforms built from the live actors. Skipped entirely while there's no overflow.
  cell_field.set_count(overflow)
  if overflow > 0 then
    local attractors = {}
    for i = 1, #snap.blooms do
      local b = snap.blooms[i]
      -- Ease the pull in/out over the bloom's life so the rush ramps smoothly: fade
      -- in for BLOOM_FADE after spawn, fade out for BLOOM_FADE before it expires.
      local age = (b.life or 1) - (b.timer or 0)
      local fade = clamp01(math.min(age, b.timer or 0) / BLOOM_FADE)
      attractors[i] =
        { x = b.x, y = b.y, radius = BLOOM_ATTRACT_R, strength = BLOOM_ATTRACT_S * fade }
    end
    local repulsors = {}
    for i = 1, #snap.predators do
      local p = snap.predators[i]
      repulsors[i] = { x = p.x, y = p.y, radius = PRED_REPEL_R, strength = PRED_REPEL_S }
    end
    -- Fold the colony's trait stats (opts.stats, from cell.lua's traits.stats) into
    -- the field's cheap global knobs so leveling a trait visibly shifts the whole
    -- overflow mass: green pigment (photosynthesis), swim/weave rate (motility),
    -- body firmness (evasion) and a faint sense shimmer (chemotaxis). nil-safe:
    -- with no stats this returns the neutral look and the field is unchanged.
    local body_color, swim_scale, size_scale, sense_halo =
      field_traits(PALETTE.cell, opts and opts.stats)
    cell_field.draw({
      field_w = f.w,
      field_h = f.h,
      base_half = CELL_SIZE * 0.5,
      color = body_color,
      attractors = attractors,
      repulsors = repulsors,
      mito = mito,
      mark_color = MITO_COLOR,
      swim_scale = swim_scale,
      size_scale = size_scale,
      sense_halo = sense_halo,
      -- The overflow swarm dissolves with the rest of the dish under the dive.
      opacity = world_amul,
    })
  end

  -- The simulated boids, drawn on top of the overflow field. A held mitochondrion
  -- stamps the inner mark on each (riding its mitosis pop-in scale). Under the dive
  -- every boid fades with the dish EXCEPT the winner (hero_i), which stays full alpha
  -- so it's the one cell left as the camera plunges in.
  for i = 1, n do
    local amul = (hero_i and i ~= hero_i) and world_amul or 1
    draw_entity(cells[i], t, cam.zoom, amul)
    if mito then
      draw_mito_mark(cells[i], amul)
    end
  end

  draw_list(snap.predators, t, cam.zoom, world_amul)

  -- World-space effects (feed ripples, death bursts, the endosymbiosis beat) sit
  -- above the entities, inside the camera transform so they track world coords.
  fx.draw_world(state.fx)

  love.graphics.pop()

  -- Screen-space overlay effects (the feed flash) draw AFTER the transform pop.
  fx.draw_overlay(state.fx)

  -- Reset graphics state so the panel UI the orchestrator draws afterward
  -- inherits clean defaults (line width, color).
  love.graphics.setLineWidth(1)
  love.graphics.setColor(1, 1, 1, 1)
end

return view
