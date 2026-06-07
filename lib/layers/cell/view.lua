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
-- steady within a tier and glides out one notch at each threshold. Transient
-- effects (feed flash, shake, ripple, the evolve fusion beat) are composable
-- entities owned by an fx controller (lib/engine/fx.lua); shake is applied to
-- the draw transform only, never the camera, so screen_to_world stays exact.
local fx = require("lib.engine.fx")

local view = {}

-- Flat-square sizes in WORLD units (scaled by the camera zoom at draw time).
local CELL_SIZE = 6 -- the founder is a chunky pixel; pop-in scales young cells up
local FOOD_SIZE = 2 -- a ~1.5-2px nutrient dot
local PREY_SIZE = 4
local PREDATOR_SIZE = 9 -- a distinctly larger, menacing square
local POP_IN = 0.5 -- mitosis pop-in duration, seconds
local FUSION_LIFE = 1.1 -- evolve fusion-beat duration, seconds

local VIEW_FRAC = 0.9 -- field fills this fraction of the window; the rest is the
-- off-screen margin that hides the wrap seam (tz divides by it, so the field
-- slightly OVERFLOWS the viewport and its edges fall outside).
local CAM_SMOOTH = 0.12 -- camera lerp factor (fraction per frame toward target)
local RENDER_BUDGET = 180 -- max cells drawn; stride-samples when over budget

-- The palette, keyed by render kind. The liked teal/green/warm/red family.
local PALETTE = {
  cell = { 0.30, 0.74, 0.70 },
  food = { 0.46, 0.92, 0.42 },
  bloom = { 0.42, 1.0, 0.55 },
  prey = { 0.95, 0.86, 0.55 },
  predator = { 0.96, 0.34, 0.30 },
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

local function lerp(a, b, t)
  return a + (b - a) * t
end

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

-- The evolve "fusion" beat as a composable, fx-managed world-space effect: every
-- captured cell eases to (cx, cy) as a shrinking flat square, then a square
-- blooms at the center -- multicellularity made literal, in flat pixels. Driven
-- off a snapshot so the live world is free to empty underneath it.
local function fuse_effect(points, cx, cy)
  return {
    age = 0,
    life = FUSION_LIFE,
    space = "world",
    update = function(self, dt)
      self.age = self.age + dt
      return self.age >= self.life
    end,
    draw = function(self)
      local k = clamp01(self.age / self.life)
      local ease = k * k * (3 - 2 * k) -- smoothstep
      local body = PALETTE.cell
      for i = 1, #points do
        local p = points[i]
        local x = lerp(p.x, cx, ease)
        local y = lerp(p.y, cy, ease)
        local s = CELL_SIZE * (1 - 0.6 * ease)
        local half = s * 0.5
        love.graphics.setColor(body[1], body[2], body[3], 0.9 * (1 - ease * 0.5))
        love.graphics.rectangle("fill", x - half, y - half, s, s)
      end
      -- The unified body: a square swelling at the center, fading as it peaks.
      local cs = CELL_SIZE + 64 * ease
      local ch = cs * 0.5
      love.graphics.setColor(body[1], body[2], body[3], 0.5 * (1 - ease))
      love.graphics.rectangle("fill", cx - ch, cy - ch, cs, cs)
      love.graphics.setColor(1, 1, 1, 1)
    end,
  }
end

function view.fuse(state, snapshot, cx, cy)
  local points = {}
  for i = 1, #snapshot.cells do
    local c = snapshot.cells[i]
    points[i] = { x = c.x, y = c.y }
  end
  fx.add(state.fx, fuse_effect(points, cx, cy))
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
-- countdown timer bar -- the clickable feed target. Reads radius + timer/life
-- off the entity; zoom keeps strokes and the bar a constant screen size.
local function draw_bloom(e, t, zoom)
  local col = PALETTE.bloom
  local r = e.radius or 26
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

-- Render the whole world. The camera fits snap.field into the window (stepped,
-- since the field steps with population) and lerps toward the target each frame.
-- World-space objects are drawn inside a push/translate/scale transform
-- (translate THEN scale, matching lib/layers/solar.lua); after pop the graphics
-- state is reset so the orchestrator's panel UI inherits clean defaults.
function view.draw_world(state, snap)
  local t = state.time

  -- Stepped fit-camera. tz divides by VIEW_FRAC so the field slightly overflows
  -- the window -- the off-screen margin that hides the toroidal wrap seam.
  local win_w, win_h = love.graphics.getDimensions()
  local f = snap.field or { w = win_w, h = win_h }
  local tz = math.min(win_w / f.w, win_h / f.h) / VIEW_FRAC
  local tx = win_w / 2 - (f.w / 2) * tz -- target translate: field is centered
  local ty = win_h / 2 - (f.h / 2) * tz
  local cam = state.camera
  if not cam.init then
    cam.zoom, cam.x, cam.y, cam.init = tz, tx, ty, true
  else
    cam.zoom = cam.zoom + (tz - cam.zoom) * CAM_SMOOTH
    cam.x = cam.x + (tx - cam.x) * CAM_SMOOTH
    cam.y = cam.y + (ty - cam.y) * CAM_SMOOTH
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

  -- Render budget: stride-sample the cell list when the colony is huge so we
  -- never blow frame time on a myriad of draw calls.
  local cells = snap.cells
  local n = #cells
  local stride = (n > RENDER_BUDGET) and math.ceil(n / RENDER_BUDGET) or 1
  for i = 1, n, stride do
    draw_entity(cells[i], t, cam.zoom)
  end

  draw_list(snap.predators, t, cam.zoom)

  -- World-space effects (feed ripples, the evolve fusion beat) sit above the
  -- entities, inside the camera transform so they track world coordinates.
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
