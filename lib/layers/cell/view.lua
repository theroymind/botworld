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
local cell_batch = require("lib.layers.cell.cell_batch")

local view = {}

-- Flat-square sizes in WORLD units (scaled by the camera zoom at draw time).
local CELL_SIZE = 6 -- the founder is a chunky pixel; pop-in scales young cells up
local FOOD_SIZE = 2 -- a ~1.5-2px nutrient dot
local PREY_SIZE = 4
local PREDATOR_SIZE = 9 -- a distinctly larger, menacing square
local POP_IN = 0.5 -- mitosis pop-in duration, seconds
local ENDO_LIFE = 1.2 -- endosymbiosis-beat duration, seconds
local HUNGER_DIM = 8 -- seconds of hunger that fully dims a starving cell
local HUNGER_FADE = 0.7 -- how far a fully starved cell fades (alpha *= 1 - this)
local FED_PULSE = 0.6 -- seconds of the post-meal swell (matches the world's `fed` stamp)
local FED_SWELL = 0.35 -- peak extra size of the just-fed pulse (a satisfied gulp)

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
}

-- Default flat-square size per kind (a render component may override via size).
local SIZE = {
  cell = CELL_SIZE,
  food = FOOD_SIZE,
  prey = PREY_SIZE,
  predator = PREDATOR_SIZE,
}

-- Per-kind alpha overrides for the flat primitives (none needed currently --
-- the bloom carries its own shape). Overridable per entity via render.alpha.
local ALPHA = {}
local ALPHA_DEFAULT = 0.92

local function clamp01(v)
  if v < 0 then
    return 0
  elseif v > 1 then
    return 1
  end
  return v
end

function view.new()
  -- camera: smoothed fit-camera that frames snap.field into the window.
  -- init=false triggers an instant snap on the first draw so there is no
  -- jarring slide from (0,0) at startup. fx: the composable effects controller.
  return {
    time = 0,
    fx = fx.new(),
    camera = { zoom = 1, x = 0, y = 0, init = false },
    pan = { x = 0, y = 0 }, -- smart-framing offset, lerped slowly (PAN_SMOOTH)
  }
end

function view.update(state, dt)
  state.time = state.time + dt
  fx.update(state.fx, dt)
end

-- Spawn a composable effect entity onto this view's fx controller; returns it.
-- The orchestrator builds effects (fx.flash/fx.shake/fx.pulse) and adds them
-- here, e.g. on a bloom feed.
function view.spawn(state, effect)
  return fx.add(state.fx, effect)
end

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
function view.focus(state, wx, wy, zoom)
  state.focus = { x = wx, y = wy, zoom = zoom }
end

function view.clear_focus(state)
  state.focus = nil
end

-- The bloom's world-space radius at the current zoom: its constant on-screen UI
-- size (BLOOM_SCREEN_R px) projected back into world units, so the orchestrator's
-- world-space click hit-test matches the disk the view draws. Uses the steady
-- camera zoom (same basis as screen_to_world), so the two stay consistent.
function view.bloom_radius(state)
  return BLOOM_SCREEN_R / state.camera.zoom
end

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
  fx.add(state.fx, fx.pulse({ x = pos.x, y = pos.y, color = { 1, 0.95, 0.6 }, alpha = 0.7, life = 0.7 }))
end

-- Resolve the common flat-primitive params (size/color/alpha + the data-driven
-- pop_in/pulse modifiers) from an entity's render component. Shared by the flat
-- primitive shapes so they stay DRY.
local function resolve(e, t)
  local rc = e.render
  local size = rc.size or SIZE[rc.kind] or CELL_SIZE
  local color = rc.color or PALETTE[rc.kind] or PALETTE.cell
  local alpha = rc.alpha or ALPHA[rc.kind] or ALPHA_DEFAULT
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
  return size, color, alpha
end

local function draw_square(e, t)
  local size, color, alpha = resolve(e, t)
  if size <= 0 then
    return
  end
  local half = size * 0.5
  love.graphics.setColor(color[1], color[2], color[3], alpha)
  love.graphics.rectangle("fill", e.x - half, e.y - half, size, size)
end

local function draw_circle(e, t)
  local size, color, alpha = resolve(e, t)
  if size <= 0 then
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
local function draw_bloom(e, t, zoom)
  local col = PALETTE.bloom
  local r = BLOOM_SCREEN_R / zoom
  local frac = clamp01((e.timer or 1) / (e.life or 1)) -- countdown remaining
  local pulse = 1 + 0.06 * math.sin(t * 6)
  -- Soft outer glow (the pulse), then the body disk.
  love.graphics.setColor(col[1], col[2], col[3], 0.10)
  love.graphics.circle("fill", e.x, e.y, r * 1.7 * pulse)
  love.graphics.setColor(col[1], col[2], col[3], 0.18)
  love.graphics.circle("fill", e.x, e.y, r)
  -- Bright "click me" rim, a constant screen-pixel width.
  love.graphics.setLineWidth(2 / zoom)
  love.graphics.setColor(col[1], col[2], col[3], 0.85)
  love.graphics.circle("line", e.x, e.y, r * pulse)
  love.graphics.setLineWidth(1 / zoom)
  -- Little countdown timer bar beneath the bloom (depletes over the ~3s window).
  local bw = r * 1.6
  local bh = 3 / zoom
  local bx = e.x - bw * 0.5
  local by = e.y + r * 1.25
  love.graphics.setColor(1, 1, 1, 0.18)
  love.graphics.rectangle("fill", bx, by, bw, bh)
  love.graphics.setColor(col[1], col[2], col[3], 0.9)
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

local function draw_entity(e, t, zoom)
  local rc = e.render
  if not rc then
    return
  end
  local drawer = SHAPES[rc.shape or "square"] or draw_square
  drawer(e, t, zoom)
end

local function draw_list(list, t, zoom)
  for i = 1, #list do
    draw_entity(list[i], t, zoom)
  end
end

-- The half-size of the tiny darker inner square stamped on a cell once the colony
-- holds the mitochondrion -- the organelle that was once a separate cell, made
-- visible. It rides the cell's mitosis pop-in scale so it grows in with the
-- daughter. Pushed per cell into the instanced mark pass (cell_batch); 0 collapses
-- the quad to a point (invisible), matching the old draw's size<=0 skip.
local MITO_COLOR = colors.primary_dark -- inner-detail shade of the cell's token
local function mito_half(e)
  local rc = e.render
  local scale = rc.pop_in and clamp01((e.age or POP_IN) / POP_IN) or 1
  return (rc.size or SIZE.cell or CELL_SIZE) * 0.34 * scale * 0.5
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

  draw_list(snap.foods, t, cam.zoom)
  draw_list(snap.blooms, t, cam.zoom)
  draw_list(snap.prey, t, cam.zoom)

  -- Draw every cell through ONE GPU-instanced pass. The swarm is the only list
  -- that grows large (up to world.MAX_AGENTS), and the old per-cell
  -- setColor+rectangle path issued a draw call per cell -- every alpha change
  -- (hunger/fed/pop-in) flushed LÖVE's auto-batch, so a full swarm cost thousands
  -- of draws a frame. Here the CPU only resolves each cell's size/alpha (the same
  -- resolve() the immediate path used, so visuals are identical) and pushes it
  -- into the instance buffer; cell_batch.draw uploads the prefix once and draws
  -- the whole swarm -- body, plus the mito mark when held -- in one (or two) calls.
  -- Order-independent as before: drawing every cell means list mutations (predator
  -- kills, reconcile) can't remap which dots appear and snap the visible swarm.
  local cells = snap.cells
  local n = #cells
  cell_batch.begin()
  for i = 1, n do
    local e = cells[i]
    local size, _, alpha = resolve(e, t)
    cell_batch.push(e.x, e.y, size * 0.5, alpha, mito and mito_half(e) or 0)
  end
  cell_batch.draw(PALETTE.cell, mito and MITO_COLOR or nil)

  draw_list(snap.predators, t, cam.zoom)

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
