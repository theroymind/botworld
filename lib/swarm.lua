-- Drone swarm stored as flat parallel arrays (struct-of-arrays). Each drone
-- orbits a planet on a parametric circle; rendering goes through a single
-- SpriteBatch so the whole swarm is one draw call.
local swarm = {}

local DRONE_SPRITE_SIZE = 3
local ORBIT_DISTANCE_MIN = 16
local ORBIT_DISTANCE_MAX = 70
local ORBIT_SPEED_MIN = 0.6 -- radians/sec
local ORBIT_SPEED_MAX = 2.4
local BATCH_INITIAL_CAPACITY = 10000 -- SpriteBatch auto-grows past this

swarm.count = 0

local bodies
local batch
local planet_of = {}
local orbit_distance = {}
local angle = {}
local angular_speed = {}
local drone_x = {}
local drone_y = {}

local function build_drone_image()
  local image_data = love.image.newImageData(DRONE_SPRITE_SIZE, DRONE_SPRITE_SIZE)
  for y = 0, DRONE_SPRITE_SIZE - 1 do
    for x = 0, DRONE_SPRITE_SIZE - 1 do
      image_data:setPixel(x, y, 1, 1, 1, 1)
    end
  end
  return love.graphics.newImage(image_data)
end

function swarm.load(bodies_module)
  bodies = bodies_module
  batch = love.graphics.newSpriteBatch(build_drone_image(), BATCH_INITIAL_CAPACITY, "stream")
end

function swarm.add(n)
  local count = swarm.count
  local two_pi = 2 * math.pi
  for i = count + 1, count + n do
    planet_of[i] = love.math.random(1, bodies.count)
    orbit_distance[i] = ORBIT_DISTANCE_MIN
      + love.math.random() * (ORBIT_DISTANCE_MAX - ORBIT_DISTANCE_MIN)
    angle[i] = love.math.random() * two_pi
    angular_speed[i] = ORBIT_SPEED_MIN + love.math.random() * (ORBIT_SPEED_MAX - ORBIT_SPEED_MIN)
  end
  swarm.count = count + n
end

function swarm.clear()
  swarm.count = 0
end

function swarm.update(dt)
  local cos = math.cos
  local sin = math.sin
  local planet_x = bodies.planet_x
  local planet_y = bodies.planet_y
  for i = 1, swarm.count do
    local theta = angle[i] + angular_speed[i] * dt
    angle[i] = theta
    local p = planet_of[i]
    drone_x[i] = planet_x[p] + cos(theta) * orbit_distance[i]
    drone_y[i] = planet_y[p] + sin(theta) * orbit_distance[i]
  end
end

function swarm.draw()
  batch:clear()
  for i = 1, swarm.count do
    batch:add(drone_x[i], drone_y[i])
  end
  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.draw(batch)
end

return swarm
