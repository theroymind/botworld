local bodies = require("lib.bodies")
local swarm = require("lib.swarm")

local SPAWN_SMALL = 10000
local SPAWN_LARGE = 100000
local SPAWN_HUGE = 1000000
local ZOOM_STEP = 1.1
local INITIAL_ZOOM = 0.045 -- the scaled-up system spans ~8200 world units
local TIMING_WINDOW = 60 -- frames in the rolling average

local camera = { x = 0, y = 0, zoom = INITIAL_ZOOM }
local update_samples = {}
local draw_samples = {}
local sample_index = 0

local function rolling_average(samples)
  local sample_count = #samples
  if sample_count == 0 then
    return 0
  end
  local total = 0
  for i = 1, sample_count do
    total = total + samples[i]
  end
  return total / sample_count
end

local function draw_hud()
  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.print(string.format("drones  %d / %d", swarm.count, swarm.max_count), 10, 10)
  love.graphics.print(string.format("fps     %d", love.timer.getFPS()), 10, 26)
  local update_text =
    string.format("update  %.2f ms (bodies + uniforms only)", rolling_average(update_samples))
  local draw_text =
    string.format("draw    %.2f ms (cpu submit; gpu = fps drop)", rolling_average(draw_samples))
  love.graphics.print(update_text, 10, 42)
  love.graphics.print(draw_text, 10, 58)
  love.graphics.print(
    "[space] +10k   [b] +100k   [m] +1M   [c] clear   [wheel] zoom   [drag] pan   [esc] quit",
    10,
    82
  )
end

function love.load()
  love.graphics.setBackgroundColor(0, 0, 0)
  bodies.load()
  swarm.load(bodies)
  swarm.add(SPAWN_SMALL)
  local width, height = love.graphics.getDimensions()
  camera.x = width / 2
  camera.y = height / 2
end

function love.update(dt)
  local started = love.timer.getTime()
  bodies.update(dt)
  swarm.update(dt)
  sample_index = sample_index % TIMING_WINDOW + 1
  update_samples[sample_index] = (love.timer.getTime() - started) * 1000
end

function love.draw()
  local started = love.timer.getTime()
  love.graphics.push()
  love.graphics.translate(camera.x, camera.y)
  love.graphics.scale(camera.zoom)
  bodies.draw()
  swarm.draw()
  love.graphics.pop()
  draw_samples[sample_index] = (love.timer.getTime() - started) * 1000
  draw_hud()
end

function love.keypressed(key)
  if key == "space" then
    swarm.add(SPAWN_SMALL)
  elseif key == "b" then
    swarm.add(SPAWN_LARGE)
  elseif key == "m" then
    swarm.add(SPAWN_HUGE)
  elseif key == "c" then
    swarm.clear()
  elseif key == "escape" then
    love.event.quit()
  end
end

function love.wheelmoved(_, dy)
  if dy == 0 then
    return
  end
  local mouse_x, mouse_y = love.mouse.getPosition()
  local factor = dy > 0 and ZOOM_STEP or 1 / ZOOM_STEP
  -- Keep the world point under the cursor fixed while zooming.
  camera.x = mouse_x - (mouse_x - camera.x) * factor
  camera.y = mouse_y - (mouse_y - camera.y) * factor
  camera.zoom = camera.zoom * factor
end

function love.mousemoved(_, _, dx, dy)
  if love.mouse.isDown(1) then
    camera.x = camera.x + dx
    camera.y = camera.y + dy
  end
end
