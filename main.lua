-- Thin entry point: a fixed-timestep clock ticks every registered layer (so
-- backgrounded scales keep producing) while only the active layer gets
-- per-frame updates, drawing, and input. Tab cycles layers, esc quits.
local clock = require("lib.engine.clock")
-- Color facade FIRST among UI-touching requires: requiring it runs colors.apply()
-- on the love-ui theme, so every botworld override (colors.game, the teal/green
-- ordinal tokens, ...) is in place before any layer or library module captures a
-- token or draws a frame.
local colors = require("lib.engine.colors")
assert(colors.game, "color facade must expose the game namespace")
local layers = require("lib.engine.layers")
local touch = require("lib.engine.touch")
local music = require("lib.engine.music")
local cell = require("lib.layers.cell")
local complexcell = require("lib.layers.complexcell")
local solar = require("lib.layers.solar")

-- The boot/phase-1 BGM volume. Named here (not buried in the track) because the
-- phase-2 stems match it -- see lib/engine/music.lua + complexcell's layered intro.
local BGM_VOLUME = 0.75

-- Pick the layer to boot into from the command line, so `love . phase2` (or a
-- literal layer name like `love . complexcell`) jumps straight there for debugging.
-- `phaseN` maps to the Nth REGISTERED layer (1-based), so it tracks registration
-- order as phases are added -- no hardcoded phase->name table to keep in sync.
-- Defaults to the first layer (phase 1) when no/unknown arg is given.
local function resolve_start_layer(args)
  local names = layers.names()
  for _, tok in ipairs(args or {}) do
    tok = tostring(tok):lower()
    local n = tok:match("^phase(%d+)$")
    if n and names[tonumber(n)] then
      return names[tonumber(n)]
    end
    for _, name in ipairs(names) do
      if name:lower() == tok then
        return name
      end
    end
  end
  return names[1]
end

function love.load(arg)
  love.graphics.setBackgroundColor(0, 0, 0)
  -- Phase-1 BGM, loaded but NOT yet played: which track sounds depends on the start
  -- layer (the phase-2 stems are loaded by complexcell.load below).
  music.load("bgm", "assets/music/botworld.ogg")
  layers.register("cell", cell)
  layers.register("complexcell", complexcell)
  layers.register("solar", solar)
  layers.load_all()
  local start = resolve_start_layer(arg)
  layers.switch(start)
  -- Score the boot layer. Booting STRAIGHT into phase 2 for debugging (`love . phase2`)
  -- skips the endosymbiosis seam that normally hands off the music, so the phase-1 BGM
  -- must never start (otherwise it blips before any pause) -- bring up the complex-cell
  -- layers directly. Any other start layer plays the phase-1 BGM.
  if start == "complexcell" and complexcell.start_layered_music then
    complexcell.start_layered_music()
  else
    music.play("bgm", BGM_VOLUME)
  end
  -- Pinch-to-zoom on touch screens; taps/drags arrive via mouse emulation.
  touch.init(function(dy) layers.wheelmoved(0, dy) end)
end

function love.update(dt)
  clock.update(dt, layers.tick_all)
  layers.update(dt)
  music.update(dt)
end

function love.draw()
  layers.draw()
  love.graphics.setColor(1, 1, 1, 0.7)
  local hud = string.format("layer  %s   [tab] switch layer   [esc] quit", layers.active_name())
  love.graphics.print(hud, 10, love.graphics.getHeight() - 22)
end

-- The layer after the active one in registration order, wrapping.
local function next_layer_name()
  local names = layers.names()
  for i = 1, #names do
    if names[i] == layers.active_name() then
      return names[i % #names + 1]
    end
  end
  return names[1]
end

function love.keypressed(key)
  if key == "tab" then
    layers.switch(next_layer_name())
  elseif key == "escape" then
    love.event.quit()
  else
    layers.keypressed(key)
  end
end

function love.mousepressed(x, y, button) layers.mousepressed(x, y, button) end

function love.mousemoved(x, y, dx, dy) layers.mousemoved(x, y, dx, dy) end

function love.wheelmoved(dx, dy) layers.wheelmoved(dx, dy) end

function love.touchpressed(id, x, y) touch.pressed(id, x, y) end

function love.touchmoved(id, x, y) touch.moved(id, x, y) end

function love.touchreleased(id) touch.released(id) end
