-- GPU procedural swarm field: the visible Phase-1 swarm, computed almost entirely
-- on the GPU. The cosmetic agent sim used to run full boids (steer + nearest-food
-- + neighbour separation) over thousands of cells every frame -- which both pinned
-- the CPU and settled into an evenly-spaced LATTICE that merely waved. This
-- replaces the VISIBLE swarm with stateless instances whose position is a
-- closed-form function of (per-instance home/seed, time, and a handful of
-- attractor/repulsor uniforms) evaluated in the vertex shader. The CPU per frame
-- ships only a few scalars + the live bloom/predator positions and raises the
-- instance count; "growth" is just a higher count. Nothing here is read back, so
-- the gameplay couplings (predator kills, engulfs) stay on the small CPU set in
-- world.lua -- this field is pure cosmetic skin.
--
-- The look is built to read as LIFE, not noise: each cell has its own swim loop
-- and dart cadence (so they wriggle and lunge instead of drifting in lockstep), a
-- large-scale curl-noise "current" sways the whole field organically, and -- the
-- part that sells "they're surviving" -- cells within range of a nutrient bloom
-- STREAM toward it and cells near a predator FLEE, both done per-instance in the
-- shader from a few uniform points. Homes are random and sorted centre-outward, so
-- the founder sits at the field centre and the colony fills the realm as it grows.
--
-- Mirrors lib/swarm.lua / interior_swarm.lua: a static instance buffer filled ONCE
-- (love.math/FFI), a unit quad instanced per cell, and ALL love.*/FFI work deferred
-- to load/draw so a bare `require` stays headless for the world/sim specs.
local cell_field = {}

-- Instance-buffer capacity (>= world.sample_count's MAX_AGENTS ceiling, with
-- headroom). drawInstanced draws a prefix, so the GPU only ever touches the live
-- count; the cap is just the buffer size.
local MAX_CELLS = 16384
local INSTANCE_FLOATS = 8 -- two vec4 attributes per cell
-- Attractor (nutrient bloom) and repulsor (predator) uniform array sizes. Match
-- world.lua's BLOOM_MAX (3) and PREDATOR_MAX (5), with a little headroom; the live
-- counts are sent each frame so unused slots cost nothing.
local MAX_ATTRACTORS = 4
local MAX_REPULSORS = 6
-- Constant alpha of the darker mito inner mark (matches the old draw_mito_mark),
-- and its size factor relative to the cell body.
local MARK_ALPHA = 0.9
local MARK_SCALE = 0.34

local shader
local quad_mesh
local instance_mesh
local attractor_uniform = {} -- reused vec4 array -> "attractors" uniform
local repulsor_uniform = {} -- reused vec4 array -> "repulsors" uniform
local elapsed = 0
local loaded = false

cell_field.count = 0
cell_field.max_count = MAX_CELLS

-- Per-instance home placement spread/scatter and the swim/dart motion bands. All
-- tuning knobs -- expect to set them by eye (liveliness vs. "it's a calm dish").
local SWIM_RATE_MIN, SWIM_RATE_MAX = 0.35, 1.7 -- personal swim-loop angular speed
local WOBBLE_MIN, WOBBLE_MAX = 5, 20 -- swim-loop radius (world units)
local SIZE_JITTER_MIN, SIZE_JITTER_MAX = 0.7, 1.3 -- per-cell size variation
local ALPHA_JITTER_MIN, ALPHA_JITTER_MAX = 0.62, 0.95 -- per-cell brightness variation

-- BLOOM_MAX / PRED_MAX are baked into the shader so the attractor/repulsor loops
-- have constant bounds (required by GLSL ES on the iOS build) while the live count
-- gates them with a conditional break.
local VERTEX_SHADER_TEMPLATE = [[
uniform float time;
uniform vec2  field;        // current field extent (world units), for wrap + scale
uniform vec3  body_color;    // cell token (body pass) or mito token (mark pass)
uniform float base_half;     // cell body half-size in world units
uniform float pass_mode;     // 0 = cell body, 1 = mito mark
uniform int   attractor_count;
uniform vec4  attractors[%d]; // .xy world pos, .z radius, .w pull strength (blooms)
uniform int   repulsor_count;
uniform vec4  repulsors[%d];  // .xy world pos, .z radius, .w push strength (predators)

attribute vec4 InstanceHome; // home.x (0..1), home.y (0..1), phase (0..1), swim rate
attribute vec4 InstanceJit;  // wobble radius, size jitter, alpha jitter, dart phase

varying vec4 cell_color;

float hash(vec2 p) {
  return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

// Value noise -- smooth, cheap, dependency-free. Two decorrelated samples make a
// 2D flow vector for the large-scale organic "current".
float vnoise(vec2 p) {
  vec2 i = floor(p);
  vec2 f = fract(p);
  vec2 u = f * f * (3.0 - 2.0 * f);
  float a = hash(i);
  float b = hash(i + vec2(1.0, 0.0));
  float c = hash(i + vec2(0.0, 1.0));
  float d = hash(i + vec2(1.0, 1.0));
  return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

vec2 flow(vec2 p, float t) {
  float a = vnoise(p + vec2(t, 0.0));
  float b = vnoise(p + vec2(0.0, t) + 17.3);
  return vec2(a, b) * 2.0 - 1.0;
}

vec4 position(mat4 transform_projection, vec4 vertex_position) {
  vec2 home = InstanceHome.xy * field;
  float phase = InstanceHome.z;
  float swim = InstanceHome.w;
  float two_pi = 6.2831853;

  // Large-scale current: the whole field sways on a slow noise flow, so the swarm
  // drifts as a body instead of jittering in place.
  vec2 sway = flow(InstanceHome.xy * 3.0, time * 0.05) * (min(field.x, field.y) * 0.04);

  // Personal swim loop: each cell traces its own little ellipse (a microbe's
  // wriggle), desynced by its phase so the swarm never pulses in lockstep.
  float ang = time * swim + phase * two_pi;
  vec2 loop = vec2(cos(ang), sin(ang * 1.3)) * InstanceJit.x;
  // Dart: an occasional lunge along the loop tangent -- a sharp pow() spike so
  // most of the time it glides and now and then it shoots, reading as a survival
  // twitch rather than smooth drift.
  float dart = pow(fract(time * 0.5 + InstanceJit.w), 6.0);
  loop += vec2(-sin(ang), cos(ang * 1.3)) * dart * InstanceJit.x * 1.5;

  vec2 pos = home + sway + loop;

  // Attractors (nutrient blooms): cells within radius STREAM toward the food, the
  // pull easing in as they near it -- the swarm visibly rushing a bloom.
  for (int i = 0; i < %d; i++) {
    if (i >= attractor_count) break;
    vec2 d = attractors[i].xy - pos;
    float dist = length(d) + 1e-3;
    float w = smoothstep(attractors[i].z, 0.0, dist);
    pos += (d / dist) * w * attractors[i].w;
  }
  // Repulsors (predators): cells within radius FLEE, sharpest right at the strike.
  for (int i = 0; i < %d; i++) {
    if (i >= repulsor_count) break;
    vec2 d = pos - repulsors[i].xy;
    float dist = length(d) + 1e-3;
    float w = smoothstep(repulsors[i].z, 0.0, dist);
    pos += (d / dist) * w * repulsors[i].w;
  }

  // Toroidal wrap: keep every cell inside the field (the view's margin hides the
  // seam), so drift/flee never walks the swarm off the realm.
  pos = mod(pos, field);

  bool body = pass_mode < 0.5;
  float half_size = base_half * InstanceJit.y * (body ? 1.0 : float(%f));
  // Gentle per-cell twinkle so the field shimmers like living matter, not a flat
  // stipple; the mark pass uses its own constant alpha.
  float twinkle = 0.85 + 0.15 * sin(time * 2.0 + phase * 10.0);
  float alpha = body ? (InstanceJit.z * twinkle) : float(%f);
  cell_color = vec4(body_color, alpha);
  return transform_projection * vec4(vertex_position.xy * half_size + pos, 0.0, 1.0);
}
]]

local FRAGMENT_SHADER = [[
varying vec4 cell_color;

vec4 effect(vec4 color, Image tex, vec2 texture_coords, vec2 screen_coords) {
  return cell_color * color;
}
]]

-- Fill the whole instance buffer once. Homes are random in [0,1]^2 then sorted by
-- distance from centre, so drawInstanced(count) draws a centre-outward prefix: the
-- founder (instance 1, forced to the exact centre) sits dead-centre and the colony
-- fills the realm as the count climbs. Mirrors swarm.lua's FFI byte-data fill.
local function build_instance_data()
  local ffi = require("ffi")
  local random = love.math.random

  -- Generate, then sort centre-outward (instance 1 pinned to the centre).
  local homes = {}
  for i = 1, MAX_CELLS do
    local nx, ny = random(), random()
    if i == 1 then
      nx, ny = 0.5, 0.5
    end
    local dx, dy = nx - 0.5, ny - 0.5
    homes[i] = { nx, ny, dx * dx + dy * dy }
  end
  table.sort(homes, function(a, b) return a[3] < b[3] end)

  local byte_data = love.data.newByteData(MAX_CELLS * INSTANCE_FLOATS * 4)
  local floats = ffi.cast("float*", byte_data:getFFIPointer())
  local function lerp(a, b) return a + random() * (b - a) end
  local offset = 0
  for i = 1, MAX_CELLS do
    local h = homes[i]
    floats[offset] = h[1] -- InstanceHome.x: home x (0..1)
    floats[offset + 1] = h[2] -- .y: home y (0..1)
    floats[offset + 2] = random() -- .z: phase (0..1), desyncs the swim loops
    floats[offset + 3] = lerp(SWIM_RATE_MIN, SWIM_RATE_MAX) -- .w: swim rate
    floats[offset + 4] = lerp(WOBBLE_MIN, WOBBLE_MAX) -- InstanceJit.x: wobble radius
    floats[offset + 5] = lerp(SIZE_JITTER_MIN, SIZE_JITTER_MAX) -- .y: size jitter
    floats[offset + 6] = lerp(ALPHA_JITTER_MIN, ALPHA_JITTER_MAX) -- .z: alpha jitter
    floats[offset + 7] = random() -- .w: dart phase
    offset = offset + INSTANCE_FLOATS
  end
  return byte_data
end

local function build_meshes()
  local instance_format = {
    { "InstanceHome", "float", 4 },
    { "InstanceJit", "float", 4 },
  }
  instance_mesh = love.graphics.newMesh(instance_format, MAX_CELLS, "points", "static")
  instance_mesh:setVertices(build_instance_data())

  -- Unit quad (-1..1) so the shader scales it by the per-instance half-size.
  local quad_vertices = {
    { -1, -1 },
    { 1, -1 },
    { 1, 1 },
    { -1, 1 },
  }
  local quad_format = { { "VertexPosition", "float", 2 } }
  quad_mesh = love.graphics.newMesh(quad_format, quad_vertices, "fan", "static")
  quad_mesh:attachAttribute("InstanceHome", instance_mesh, "perinstance")
  quad_mesh:attachAttribute("InstanceJit", instance_mesh, "perinstance")
end

-- Deferred GPU/FFI setup. Idempotent (the first draw calls it if the host didn't),
-- like swarm.load gating all love.*/FFI work behind an explicit call.
function cell_field.load()
  if loaded then
    return
  end
  local vertex_shader = string.format(
    VERTEX_SHADER_TEMPLATE,
    MAX_ATTRACTORS,
    MAX_REPULSORS,
    MAX_ATTRACTORS,
    MAX_REPULSORS,
    MARK_SCALE,
    MARK_ALPHA
  )
  shader = love.graphics.newShader(FRAGMENT_SHADER, vertex_shader)
  for i = 1, MAX_ATTRACTORS do
    attractor_uniform[i] = { 0, 0, 0, 0 }
  end
  for i = 1, MAX_REPULSORS do
    repulsor_uniform[i] = { 0, 0, 0, 0 }
  end
  build_meshes()
  loaded = true
end

function cell_field.is_loaded() return loaded end

-- Set the live instance count (the view samples it from the colony size). Clamped
-- to the buffer; "growth" is just a higher count.
function cell_field.set_count(n)
  if n < 0 then
    n = 0
  elseif n > MAX_CELLS then
    n = MAX_CELLS
  end
  cell_field.count = math.floor(n)
end

-- Advance the field clock. Cheap: one scalar accumulate (the time uniform is sent
-- in draw, the only place we touch the shader, so the module stays headless until
-- something renders).
function cell_field.update(dt) elapsed = elapsed + dt end

-- Copy a list of { x, y, radius, strength } points into a reused vec4 uniform
-- array, padding the unused tail with zeros, and return the live count.
local function fill_points(uniform, max, points)
  local n = 0
  if points then
    n = math.min(#points, max)
  end
  for i = 1, max do
    local entry = uniform[i]
    local src = points and points[i]
    if src and i <= n then
      entry[1], entry[2], entry[3], entry[4] = src.x, src.y, src.radius, src.strength
    else
      entry[1], entry[2], entry[3], entry[4] = 0, 0, 0, 0
    end
  end
  return n
end

-- Draw the live prefix of the swarm. params:
--   field_w / field_h      -- current field extent (wrap + current scale)
--   base_half              -- cell body half-size in world units
--   color                  -- cell token { r, g, b } (body pass)
--   attractors / repulsors -- arrays of { x, y, radius, strength } (blooms/predators)
--   mito / mark_color      -- when held, a second pass stamps the inner mito mark
-- Drawn inside the view's camera transform; restores the previous shader so the
-- immediate-mode actors after it render normally.
function cell_field.draw(params)
  cell_field.load() -- lazy GPU init if the host didn't call load explicitly
  if cell_field.count == 0 then
    return
  end

  local attractor_count = fill_points(attractor_uniform, MAX_ATTRACTORS, params.attractors)
  local repulsor_count = fill_points(repulsor_uniform, MAX_REPULSORS, params.repulsors)

  shader:send("time", elapsed)
  shader:send("field", { params.field_w, params.field_h })
  shader:send("base_half", params.base_half)
  shader:send("attractor_count", attractor_count)
  shader:send("attractors", unpack(attractor_uniform, 1, MAX_ATTRACTORS))
  shader:send("repulsor_count", repulsor_count)
  shader:send("repulsors", unpack(repulsor_uniform, 1, MAX_REPULSORS))

  local prev = love.graphics.getShader()
  love.graphics.setShader(shader)
  love.graphics.setColor(1, 1, 1, 1)

  shader:send("body_color", params.color)
  shader:send("pass_mode", 0)
  love.graphics.drawInstanced(quad_mesh, cell_field.count)

  if params.mito and params.mark_color then
    shader:send("body_color", params.mark_color)
    shader:send("pass_mode", 1)
    love.graphics.drawInstanced(quad_mesh, cell_field.count)
  end

  love.graphics.setShader(prev)
end

return cell_field
