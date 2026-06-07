-- Star + planets on parametric elliptical orbits, plus 3-5 moons per planet.
-- All body positions live in flat arrays (planets first, then moons) so the
-- swarm can ship them to the GPU as one uniform array each frame.
local bodies = {}

local PLANET_COUNT = 5
local STAR_RADIUS = 80
local PLANET_RADIUS_MIN = 30
local PLANET_RADIUS_MAX = 60
local ORBIT_RADIUS_BASE = 1600
local ORBIT_RADIUS_STEP = 1500 -- > 2x max moon orbit so neighboring moon systems never overlap
local ORBIT_FLATTEN = 0.9 -- semi-minor axis = semi-major * this
local ORBIT_SPEED_BASE = 0.5 -- radians/sec for the innermost planet

local MOONS_PER_PLANET_MIN = 3
local MOONS_PER_PLANET_MAX = 5
local MOON_RADIUS_MIN = 8
local MOON_RADIUS_MAX = 14
local MOON_ORBIT_BASE = 250 -- clears the biggest planet with room for the swarm
local MOON_ORBIT_STEP = 100
local MOON_SPEED_MIN = 0.4 -- radians/sec
local MOON_SPEED_MAX = 1.2

-- Flat body arrays: indices 1..planet_count are planets, moons follow.
bodies.count = 0
bodies.planet_count = PLANET_COUNT
bodies.body_x = {}
bodies.body_y = {}
-- moons_of[planet_index] = array of flat body indices for that planet's moons.
bodies.moons_of = {}

local orbit_a = {}
local orbit_b = {}
local planet_angle = {}
local planet_angular_speed = {}
local planet_radius = {}

local moon_parent = {}
local moon_orbit = {}
local moon_angle = {}
local moon_angular_speed = {}
local moon_radius = {}
local moon_count = 0
local planet_color = {}

-- Must match palette() in the swarm vertex shader.
local function planet_palette(planet_index)
  local t = 2 * math.pi * planet_index / PLANET_COUNT
  return 0.55 + 0.45 * math.cos(t),
    0.55 + 0.45 * math.cos(t + 2.1),
    0.55 + 0.45 * math.cos(t + 4.2)
end

local function load_planets()
  for i = 1, PLANET_COUNT do
    orbit_a[i] = ORBIT_RADIUS_BASE + (i - 1) * ORBIT_RADIUS_STEP
    orbit_b[i] = orbit_a[i] * ORBIT_FLATTEN
    planet_angle[i] = love.math.random() * 2 * math.pi
    planet_angular_speed[i] = ORBIT_SPEED_BASE / math.sqrt(i)
    planet_radius[i] = love.math.random(PLANET_RADIUS_MIN, PLANET_RADIUS_MAX)
    -- Zero-based index to match the shader's InstanceRoute.x.
    planet_color[i] = { planet_palette(i - 1) }
  end
end

local function load_moons()
  for planet = 1, PLANET_COUNT do
    bodies.moons_of[planet] = {}
    local count = love.math.random(MOONS_PER_PLANET_MIN, MOONS_PER_PLANET_MAX)
    for slot = 1, count do
      moon_count = moon_count + 1
      local body_index = PLANET_COUNT + moon_count
      moon_parent[moon_count] = planet
      moon_orbit[moon_count] = MOON_ORBIT_BASE + (slot - 1) * MOON_ORBIT_STEP
      moon_angle[moon_count] = love.math.random() * 2 * math.pi
      moon_angular_speed[moon_count] = MOON_SPEED_MIN
        + love.math.random() * (MOON_SPEED_MAX - MOON_SPEED_MIN)
      moon_radius[moon_count] = love.math.random(MOON_RADIUS_MIN, MOON_RADIUS_MAX)
      bodies.moons_of[planet][slot] = body_index
    end
  end
end

function bodies.load()
  load_planets()
  load_moons()
  bodies.count = PLANET_COUNT + moon_count
  bodies.update(0)
end

function bodies.update(dt)
  local body_x = bodies.body_x
  local body_y = bodies.body_y
  for i = 1, PLANET_COUNT do
    planet_angle[i] = planet_angle[i] + planet_angular_speed[i] * dt
    body_x[i] = math.cos(planet_angle[i]) * orbit_a[i]
    body_y[i] = math.sin(planet_angle[i]) * orbit_b[i]
  end
  for m = 1, moon_count do
    moon_angle[m] = moon_angle[m] + moon_angular_speed[m] * dt
    local parent = moon_parent[m]
    local index = PLANET_COUNT + m
    body_x[index] = body_x[parent] + math.cos(moon_angle[m]) * moon_orbit[m]
    body_y[index] = body_y[parent] + math.sin(moon_angle[m]) * moon_orbit[m]
  end
end

function bodies.draw()
  local body_x = bodies.body_x
  local body_y = bodies.body_y
  love.graphics.setColor(1, 1, 1, 0.15)
  for i = 1, PLANET_COUNT do
    love.graphics.ellipse("line", 0, 0, orbit_a[i], orbit_b[i])
  end
  love.graphics.setColor(1, 1, 1, 0.08)
  for m = 1, moon_count do
    local parent = moon_parent[m]
    love.graphics.circle("line", body_x[parent], body_y[parent], moon_orbit[m])
  end
  love.graphics.setColor(1, 0.95, 0.8, 1)
  love.graphics.circle("fill", 0, 0, STAR_RADIUS)
  for i = 1, PLANET_COUNT do
    local color = planet_color[i]
    love.graphics.setColor(color[1], color[2], color[3], 1)
    love.graphics.circle("fill", body_x[i], body_y[i], planet_radius[i])
  end
  love.graphics.setColor(0.55, 0.55, 0.62, 1)
  for m = 1, moon_count do
    local index = PLANET_COUNT + m
    love.graphics.circle("fill", body_x[index], body_y[index], moon_radius[m])
  end
end

return bodies
