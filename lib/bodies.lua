-- Star + planets on parametric elliptical orbits. Positions are stored in
-- flat arrays the swarm reads each frame.
local bodies = {}

local PLANET_COUNT = 5
local STAR_RADIUS = 24
local PLANET_RADIUS_MIN = 6
local PLANET_RADIUS_MAX = 12
local ORBIT_RADIUS_BASE = 140
local ORBIT_RADIUS_STEP = 110
local ORBIT_FLATTEN = 0.9 -- semi-minor axis = semi-major * this
local ORBIT_SPEED_BASE = 0.5 -- radians/sec for the innermost planet

bodies.count = PLANET_COUNT
bodies.planet_x = {}
bodies.planet_y = {}

local orbit_a = {}
local orbit_b = {}
local angle = {}
local angular_speed = {}
local planet_radius = {}

function bodies.load()
  for i = 1, PLANET_COUNT do
    orbit_a[i] = ORBIT_RADIUS_BASE + (i - 1) * ORBIT_RADIUS_STEP
    orbit_b[i] = orbit_a[i] * ORBIT_FLATTEN
    angle[i] = love.math.random() * 2 * math.pi
    angular_speed[i] = ORBIT_SPEED_BASE / math.sqrt(i)
    planet_radius[i] = love.math.random(PLANET_RADIUS_MIN, PLANET_RADIUS_MAX)
    bodies.planet_x[i] = math.cos(angle[i]) * orbit_a[i]
    bodies.planet_y[i] = math.sin(angle[i]) * orbit_b[i]
  end
end

function bodies.update(dt)
  for i = 1, PLANET_COUNT do
    angle[i] = angle[i] + angular_speed[i] * dt
    bodies.planet_x[i] = math.cos(angle[i]) * orbit_a[i]
    bodies.planet_y[i] = math.sin(angle[i]) * orbit_b[i]
  end
end

function bodies.draw()
  love.graphics.setColor(1, 1, 1, 0.25)
  for i = 1, PLANET_COUNT do
    love.graphics.ellipse("line", 0, 0, orbit_a[i], orbit_b[i])
  end
  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.circle("fill", 0, 0, STAR_RADIUS)
  for i = 1, PLANET_COUNT do
    love.graphics.circle("fill", bodies.planet_x[i], bodies.planet_y[i], planet_radius[i])
  end
end

return bodies
