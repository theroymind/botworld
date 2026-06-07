-- Benchmark #2: GPU-instanced drone swarm. Drones are stateless — each one's
-- position is a closed-form function of (instance attributes, time) evaluated
-- in the vertex shader. The CPU never touches individual drones: the instance
-- buffer is filled once at load with MAX_DRONES random routes, and "spawning"
-- just raises the instance count passed to drawInstanced. Per frame the CPU
-- sends only the time uniform and the ~30 body positions.
--
-- Route model (matches the planned game's hauler loop "A to B, maybe back to
-- C"): planet -> moon A -> planet -> moon B -> repeat, with dwell easing at
-- every stop. Both moons belong to the drone's planet.
local swarm = {}

local MAX_DRONES = 2000000
local MAX_BODIES = 32 -- shader uniform array size; >= bodies.count
local INSTANCE_FLOATS = 8 -- two vec4 attributes per drone
local DRONE_HALF_SIZE = 1
local CYCLE_SECONDS_MIN = 14
local CYCLE_SECONDS_MAX = 30
local LANE_SPREAD = 70 -- max perpendicular offset mid-leg; paths pinch at endpoints
local WOBBLE_FREQUENCY_MIN = 1
local WOBBLE_FREQUENCY_MAX = 3

swarm.count = 0
swarm.max_count = MAX_DRONES

local bodies
local shader
local quad_mesh
local instance_mesh
local body_uniform = {}
local elapsed = 0

-- Formatted with (MAX_BODIES, planet_count) in swarm.load.
local VERTEX_SHADER_TEMPLATE = [[
uniform float time;
uniform vec2 bodies[%d];

attribute vec4 InstanceRoute; // planet index, moon a index, moon b index, phase (s)
attribute vec4 InstanceMotion; // cycle (s), lane offset, wobble frequency, wobble phase

varying vec3 drone_color;

const float DWELL = 0.18; // fraction of each leg spent holding at an endpoint
const float WOBBLE_AMPLITUDE = 25.0;
const float ENDPOINT_PINCH = 0.12; // residual lane width at the endpoints
const float ARC_FAN = 0.88; // how much of the lane offset is applied as a mid-leg arc
const float TWO_PI = 6.2831853;
const float PLANET_COUNT = %d.0;

float travel(float leg_t) {
  float s = clamp((leg_t - DWELL) / (1.0 - 2.0 * DWELL), 0.0, 1.0);
  return s * s * (3.0 - 2.0 * s); // smoothstep: ease out of dwell, ease into arrival
}

// Must match planet_palette in lib/bodies.lua.
vec3 palette(float planet_index) {
  return 0.55 + 0.45 * cos(TWO_PI * planet_index / PLANET_COUNT + vec3(0.0, 2.1, 4.2));
}

vec4 position(mat4 transform_projection, vec4 vertex_position) {
  vec2 planet = bodies[int(InstanceRoute.x)];
  vec2 moon_a = bodies[int(InstanceRoute.y)];
  vec2 moon_b = bodies[int(InstanceRoute.z)];

  drone_color = palette(InstanceRoute.x);

  // Four equal legs per cycle: P->A, A->P, P->B, B->P.
  float t = fract((time + InstanceRoute.w) / InstanceMotion.x);
  float leg = floor(t * 4.0);
  float leg_t = fract(t * 4.0);

  vec2 from = planet;
  vec2 to = moon_a;
  if (leg > 0.5 && leg < 1.5) {
    from = moon_a;
    to = planet;
  } else if (leg > 1.5 && leg < 2.5) {
    to = moon_b;
  } else if (leg > 2.5) {
    from = moon_b;
    to = planet;
  }

  vec2 direction = normalize(to - from);
  vec2 perpendicular = vec2(-direction.y, direction.x);
  float s = travel(leg_t);
  // Parabolic arc: zero at both endpoints, max mid-leg. Each drone bows out to
  // its own lane, so streams leave as a point, fan into curved arcs, and
  // converge back to a point at arrival.
  float arc = 4.0 * s * (1.0 - s);
  float wobble = sin(time * InstanceMotion.z + InstanceMotion.w) * WOBBLE_AMPLITUDE * arc;
  float bow = InstanceMotion.y * (ENDPOINT_PINCH + ARC_FAN * arc);
  vec2 drone = mix(from, to, s) + perpendicular * (bow + wobble);

  return transform_projection * vec4(vertex_position.xy + drone, 0.0, 1.0);
}
]]

local FRAGMENT_SHADER = [[
varying vec3 drone_color;

vec4 effect(vec4 color, Image tex, vec2 texture_coords, vec2 screen_coords) {
  return vec4(drone_color, 1.0) * color;
}
]]

-- Fill the whole instance buffer once; drawInstanced(count) draws a prefix.
local function build_instance_data()
  local ffi = require("ffi")
  local byte_data = love.data.newByteData(MAX_DRONES * INSTANCE_FLOATS * 4)
  local floats = ffi.cast("float*", byte_data:getFFIPointer())
  local random = love.math.random
  local two_pi = 2 * math.pi
  local offset = 0
  for _ = 1, MAX_DRONES do
    local planet = random(1, bodies.planet_count)
    local moons = bodies.moons_of[planet]
    local slot_a = random(1, #moons)
    local slot_b = random(1, #moons - 1)
    if slot_b >= slot_a then
      slot_b = slot_b + 1
    end
    local cycle = CYCLE_SECONDS_MIN + random() * (CYCLE_SECONDS_MAX - CYCLE_SECONDS_MIN)
    floats[offset] = planet - 1 -- body indices are zero-based in GLSL
    floats[offset + 1] = moons[slot_a] - 1
    floats[offset + 2] = moons[slot_b] - 1
    floats[offset + 3] = random() * cycle
    floats[offset + 4] = cycle
    floats[offset + 5] = (random() * 2 - 1) * LANE_SPREAD
    floats[offset + 6] = WOBBLE_FREQUENCY_MIN
      + random() * (WOBBLE_FREQUENCY_MAX - WOBBLE_FREQUENCY_MIN)
    floats[offset + 7] = random() * two_pi
    offset = offset + INSTANCE_FLOATS
  end
  return byte_data
end

local function build_meshes()
  local instance_format = {
    { "InstanceRoute", "float", 4 },
    { "InstanceMotion", "float", 4 },
  }
  instance_mesh = love.graphics.newMesh(instance_format, MAX_DRONES, "points", "static")
  instance_mesh:setVertices(build_instance_data())

  local half = DRONE_HALF_SIZE
  local quad_vertices = {
    { -half, -half },
    { half, -half },
    { half, half },
    { -half, half },
  }
  local quad_format = { { "VertexPosition", "float", 2 } }
  quad_mesh = love.graphics.newMesh(quad_format, quad_vertices, "fan", "static")
  quad_mesh:attachAttribute("InstanceRoute", instance_mesh, "perinstance")
  quad_mesh:attachAttribute("InstanceMotion", instance_mesh, "perinstance")
end

local function send_body_positions()
  local body_x = bodies.body_x
  local body_y = bodies.body_y
  for i = 1, bodies.count do
    local entry = body_uniform[i]
    entry[1] = body_x[i]
    entry[2] = body_y[i]
  end
  shader:send("bodies", unpack(body_uniform))
end

function swarm.load(bodies_module)
  bodies = bodies_module
  assert(bodies.count <= MAX_BODIES, "body count exceeds shader uniform array")
  local vertex_shader = string.format(VERTEX_SHADER_TEMPLATE, MAX_BODIES, bodies.planet_count)
  shader = love.graphics.newShader(FRAGMENT_SHADER, vertex_shader)
  for i = 1, MAX_BODIES do
    body_uniform[i] = { 0, 0 }
  end
  build_meshes()
end

function swarm.add(n)
  swarm.count = math.min(swarm.count + n, MAX_DRONES)
end

function swarm.clear()
  swarm.count = 0
end

function swarm.update(dt)
  elapsed = elapsed + dt
  shader:send("time", elapsed)
  send_body_positions()
end

function swarm.draw()
  if swarm.count == 0 then
    return
  end
  love.graphics.setShader(shader)
  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.drawInstanced(quad_mesh, swarm.count)
  love.graphics.setShader()
end

return swarm
