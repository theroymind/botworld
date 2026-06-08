-- Thin entry point: a fixed-timestep clock ticks every registered layer (so
-- backgrounded scales keep producing) while only the active layer gets
-- per-frame updates, drawing, and input. Tab cycles layers, esc quits.
local clock = require("lib.engine.clock")
local layers = require("lib.engine.layers")
local touch = require("lib.engine.touch")
local cell = require("lib.layers.cell")
local complexcell = require("lib.layers.complexcell")
local solar = require("lib.layers.solar")

local music

function love.load()
  love.graphics.setBackgroundColor(0, 0, 0)
  music = love.audio.newSource("assets/music/botworld.ogg", "stream")
  music:setLooping(true)
  music:setVolume(0.75)
  music:play()
  layers.register("cell", cell)
  layers.register("complexcell", complexcell)
  layers.register("solar", solar)
  layers.load_all()
  layers.switch("cell")
  -- Pinch-to-zoom on touch screens; taps/drags arrive via mouse emulation.
  touch.init(function(dy) layers.wheelmoved(0, dy) end)
end

function love.update(dt)
  clock.update(dt, layers.tick_all)
  layers.update(dt)
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
