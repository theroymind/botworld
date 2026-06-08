-- fx: a generic, reusable effects controller. Any layer can own one (the cell
-- layer does today; the solar layer can later). The design is COMPOSITION-first
-- (see the project's composition pillar): an effect is a self-contained ENTITY
-- you build with a factory and ADD onto a controller -- never a special case
-- baked into a renderer. Each effect carries its own age/life, an
-- update(self, dt) -> done hook, and (optionally) a draw(self) and/or
-- offset(self) hook. The controller just advances them, drops the expired, and
-- routes drawing into the right space:
--   * world-space effects (space == "world") draw INSIDE the camera transform
--     so they track world coordinates (e.g. a feed ripple at a bloom);
--   * overlay effects (space == "overlay") draw in screen space AFTER the
--     transform is popped (e.g. a fullscreen feed flash);
--   * effects with an offset() hook contribute a TRANSIENT camera shake summed
--     by camera_offset() -- applied to the draw transform only, never written
--     into the camera, so inverse hit-testing (screen_to_world) stays exact.
-- The factories return plain entity tables, so callers compose freely:
--   fx.add(ctrl, fx.flash{ ... }); fx.add(ctrl, fx.shake{ ... }).
-- Pure Lua 5.1 at require time -- love.* is touched only inside draw closures,
-- so the controller, update, factories and camera_offset are headless-testable.
-- Default effect colors come from the GLOBAL color tokens (lib/engine/ui/colors):
-- generic ordinals (primary, secondary, ...), never literal RGB.
local colors = require("lib.engine.ui.colors")

local fx = {}

-- Shared lifecycle: advance age, report done once it reaches life. Factories
-- reuse this so every effect ages out the same way (DRY composition).
local function advance(self, dt)
  self.age = self.age + dt
  return self.age >= self.life
end

local function clamp01(v)
  if v < 0 then
    return 0
  elseif v > 1 then
    return 1
  end
  return v
end

function fx.new()
  return { effects = {} }
end

-- Append an effect entity to a controller; returns it so callers can keep a
-- handle or chain. This is THE way to spawn an effect: build with a factory,
-- add onto a controller.
function fx.add(ctrl, effect)
  ctrl.effects[#ctrl.effects + 1] = effect
  return effect
end

-- Advance every effect and drop the expired ones, compacting in place (stable,
-- O(n)). An effect is done when its own update returns truthy.
function fx.update(ctrl, dt)
  local list = ctrl.effects
  local n = 0
  for i = 1, #list do
    local e = list[i]
    if not e:update(dt) then
      n = n + 1
      list[n] = e
    end
  end
  for i = #list, n + 1, -1 do
    list[i] = nil
  end
end

-- Sum the transient (ox, oy) offset of every active shake. Applied to the draw
-- transform only -- NOT stored on the camera -- so clicks still invert cleanly.
function fx.camera_offset(ctrl)
  local ox, oy = 0, 0
  for i = 1, #ctrl.effects do
    local e = ctrl.effects[i]
    if e.offset then
      local x, y = e:offset()
      ox = ox + x
      oy = oy + y
    end
  end
  return ox, oy
end

-- Draw world-space effects (called INSIDE the camera transform).
function fx.draw_world(ctrl)
  for i = 1, #ctrl.effects do
    local e = ctrl.effects[i]
    if e.space == "world" and e.draw then
      e:draw()
    end
  end
end

-- Draw screen-space overlay effects (called AFTER the camera transform is
-- popped) -- fullscreen flashes, vignettes, etc.
function fx.draw_overlay(ctrl)
  for i = 1, #ctrl.effects do
    local e = ctrl.effects[i]
    if e.space == "overlay" and e.draw then
      e:draw()
    end
  end
end

-- ============================================================================
-- Composable effect factories. Each returns a fresh entity table; compose by
-- adding several onto a controller for one beat (e.g. flash + shake + pulse).
-- ============================================================================

-- A fullscreen screen-space flash that fades out over its life. opts:
--   color (default white), alpha (peak, default 0.35), life (default 0.25).
function fx.flash(opts)
  opts = opts or {}
  local color = opts.color or { 1, 1, 1 }
  return {
    age = 0,
    life = opts.life or 0.25,
    space = "overlay",
    color = color,
    alpha = opts.alpha or 0.35,
    update = advance,
    draw = function(self)
      local k = 1 - clamp01(self.age / self.life) -- fade out
      local w, h = love.graphics.getDimensions()
      love.graphics.setColor(self.color[1], self.color[2], self.color[3], self.alpha * k)
      love.graphics.rectangle("fill", 0, 0, w, h)
      love.graphics.setColor(1, 1, 1, 1)
    end,
  }
end

-- A transient camera shake (no draw -- it only contributes a camera offset).
-- The offset oscillates and decays linearly to zero over its life. opts:
--   mag (peak pixels, default 6), freq (oscillation rate, default 40),
--   life (default 0.3), seed (phase, default 0 -- vary it per spawn for variety).
function fx.shake(opts)
  opts = opts or {}
  return {
    age = 0,
    life = opts.life or 0.3,
    mag = opts.mag or 6,
    freq = opts.freq or 40,
    seed = opts.seed or 0,
    update = advance,
    offset = function(self)
      local k = 1 - clamp01(self.age / self.life) -- decay to zero
      local a = self.age * self.freq + self.seed
      return math.cos(a) * self.mag * k, math.sin(a * 1.3) * self.mag * k
    end,
  }
end

-- A world-space death burst: a few small squares fan out from (x, y), shrinking
-- and fading over a short life (~0.4s) -- a cell bursting into recycled particles.
-- The shard directions are precomputed at build time (no rng, allocation-free
-- draw) and varied by the seed, so two deaths don't fan identically. opts:
--   x, y (world position), count (shards, default 5), size (start px, default 4),
--   speed (fan-out, default 60), color (default the secondary token), alpha (peak,
--   default 0.9), life (default 0.4), seed (rotation phase, default 0).
function fx.burst(opts)
  opts = opts or {}
  local n = opts.count or 5
  local seed = opts.seed or 0
  local shards = {}
  for i = 1, n do
    local a = (i / n) * 2 * math.pi + seed
    shards[i] = { dx = math.cos(a), dy = math.sin(a) }
  end
  return {
    age = 0,
    life = opts.life or 0.4,
    space = "world",
    x = opts.x or 0,
    y = opts.y or 0,
    size = opts.size or 4,
    speed = opts.speed or 60,
    color = opts.color or colors.secondary,
    alpha = opts.alpha or 0.9,
    shards = shards,
    update = advance,
    draw = function(self)
      local k = clamp01(self.age / self.life)
      local s = self.size * (1 - k) -- shrink to nothing
      if s <= 0 then
        return
      end
      local half = s * 0.5
      local dist = self.age * self.speed
      love.graphics.setColor(self.color[1], self.color[2], self.color[3], self.alpha * (1 - k))
      for i = 1, #self.shards do
        local sh = self.shards[i]
        local px = self.x + sh.dx * dist
        local py = self.y + sh.dy * dist
        love.graphics.rectangle("fill", px - half, py - half, s, s)
      end
      love.graphics.setColor(1, 1, 1, 1)
    end,
  }
end

-- A world-space REVERSE burst: a few small squares converge INTO (x, y) from a
-- ring around it, growing and brightening as they arrive -- matter being drawn
-- in (a cell absorbing prey), fx.burst played backwards. Same precomputed-shard
-- scheme as fx.burst (no rng, allocation-free draw), varied by the seed. opts:
--   x, y (world position), count (shards, default 5), size (peak px, default 3),
--   speed (fall-in, default 60), color (default the tertiary token), alpha (peak,
--   default 0.9), life (default 0.4), seed (rotation phase, default 0).
function fx.implode(opts)
  opts = opts or {}
  local n = opts.count or 5
  local seed = opts.seed or 0
  local shards = {}
  for i = 1, n do
    local a = (i / n) * 2 * math.pi + seed
    shards[i] = { dx = math.cos(a), dy = math.sin(a) }
  end
  return {
    age = 0,
    life = opts.life or 0.4,
    space = "world",
    x = opts.x or 0,
    y = opts.y or 0,
    size = opts.size or 3,
    speed = opts.speed or 60,
    color = opts.color or colors.tertiary,
    alpha = opts.alpha or 0.9,
    shards = shards,
    update = advance,
    draw = function(self)
      local k = clamp01(self.age / self.life)
      local s = self.size * k -- grow as they arrive
      if s <= 0 then
        return
      end
      local half = s * 0.5
      local dist = (self.life - self.age) * self.speed -- converge to zero
      love.graphics.setColor(self.color[1], self.color[2], self.color[3], self.alpha * k)
      for i = 1, #self.shards do
        local sh = self.shards[i]
        local px = self.x + sh.dx * dist
        local py = self.y + sh.dy * dist
        love.graphics.rectangle("fill", px - half, py - half, s, s)
      end
      love.graphics.setColor(1, 1, 1, 1)
    end,
  }
end

-- A world-space expanding ring (a feed ripple). opts:
--   x, y (world position), r0 (start radius, default 4), speed (default 120),
--   color (default the bright secondary token), alpha (peak, default 0.6),
--   life (default 0.6).
function fx.pulse(opts)
  opts = opts or {}
  local color = opts.color or colors.secondary_bright
  return {
    age = 0,
    life = opts.life or 0.6,
    space = "world",
    x = opts.x or 0,
    y = opts.y or 0,
    r0 = opts.r0 or 4,
    speed = opts.speed or 120,
    color = color,
    alpha = opts.alpha or 0.6,
    update = advance,
    draw = function(self)
      local k = clamp01(self.age / self.life)
      love.graphics.setColor(self.color[1], self.color[2], self.color[3], self.alpha * (1 - k))
      love.graphics.circle("line", self.x, self.y, self.r0 + self.age * self.speed)
      love.graphics.setColor(1, 1, 1, 1)
    end,
  }
end

return fx
