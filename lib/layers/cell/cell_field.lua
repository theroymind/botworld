-- GPU procedural swarm field: the visible Phase-1 swarm, computed almost entirely
-- on the GPU. The cosmetic agent sim used to run full boids (steer + nearest-food
-- + neighbour separation) over thousands of cells every frame -- which both pinned
-- the CPU and settled into an evenly-spaced LATTICE that merely waved. This
-- replaces the VISIBLE swarm with stateless instances whose position is a
-- closed-form function of (per-instance seed/velocity, time, and a handful of
-- attractor/repulsor uniforms) evaluated in the vertex shader. The CPU per frame
-- ships only a few scalars + the live bloom/predator positions and raises the
-- instance count; "growth" is just a higher count. Nothing here is read back, so
-- the gameplay couplings (predator kills, engulfs) stay on the small CPU set in
-- world.lua -- this field is pure cosmetic skin.
--
-- The motion model is ROAMING, like the original boids: each cell has a constant
-- drift VELOCITY, so it swims ACROSS the dish and wraps seamlessly at the toroidal
-- edge (a constant-velocity point crosses the seam cleanly -- exit one edge, enter
-- the opposite, same heading -- so there is no teleport). A small per-cell wobble
-- rides on top for organic weave. The part that reads as "they're surviving": cells
-- near a nutrient bloom EASE toward it (a knot gathers at food) and cells near a
-- predator are shoved away (the flee), both from a few uniform points.
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

-- Motion bands (tuning knobs -- set by eye). Drift SPEED is in FIELD-FRACTIONS per
-- second, so the roam scales with the field: a cell crosses the dish in roughly
-- 1/SPEED seconds at any tier. Wobble is a small world-unit weave on top.
local SPEED_MIN, SPEED_MAX = 0.012, 0.045 -- drift speed (field-fractions / sec)
local WOBBLE_MIN, WOBBLE_MAX = 3, 11 -- weave radius (world units)
local SWIM_RATE = 1.1 -- weave angular speed (rad/sec), shared; phase desyncs cells
local SIZE_JITTER_MIN, SIZE_JITTER_MAX = 0.7, 1.3 -- per-cell size variation
local ALPHA_JITTER_MIN, ALPHA_JITTER_MAX = 0.62, 0.95 -- per-cell brightness variation

-- BLOOM_MAX / PRED_MAX and SWIM_RATE are baked into the shader so the
-- attractor/repulsor loops have constant bounds (required by GLSL ES on the iOS
-- build) and the weave needs no per-cell rate uniform.
local VERTEX_SHADER_TEMPLATE = [[
uniform float time;
uniform vec2  field;        // current field extent (world units): roam wrap + scale
uniform vec3  body_color;    // cell token (body pass) or mito token (mark pass)
uniform float base_half;     // cell body half-size in world units
uniform float pass_mode;     // 0 = cell body, 1 = mito mark
uniform int   attractor_count;
uniform vec4  attractors[%d]; // .xy world pos, .z radius, .w pull fraction (blooms)
uniform int   repulsor_count;
uniform vec4  repulsors[%d];  // .xy world pos, .z radius, .w push (world units, predators)

attribute vec4 InstanceMove; // home.x (0..1), home.y (0..1), vel.x, vel.y (field-frac/sec)
attribute vec4 InstanceJit;  // wobble radius, size jitter, alpha jitter, phase (0..1)

varying vec4 cell_color;

vec4 position(mat4 transform_projection, vec4 vertex_position) {
  float two_pi = 6.2831853;

  // Roaming drift in NORMALIZED field space, wrapped with fract(): a constant-
  // velocity point wraps seamlessly (no teleport), so cells swim across the dish
  // and re-enter the opposite edge like the old toroidal boids.
  vec2 norm = fract(InstanceMove.xy + InstanceMove.zw * time);
  vec2 pos = norm * field;

  // Gentle weave on top so each cell wriggles as it drifts. Small enough that a
  // cell riding the wrap seam still crosses cleanly (the weave is continuous).
  float phase = InstanceJit.w;
  float ang = time * float(%f) + phase * two_pi;
  pos += vec2(cos(ang), sin(ang * 1.3)) * InstanceJit.x;

  // Attractors (nutrient blooms): EASE toward the food by a fraction of the
  // remaining distance (w * fraction in [0,1]) -- strongest at the bloom, never
  // overshooting, so a knot gathers on the food instead of jittering across it.
  for (int i = 0; i < %d; i++) {
    if (i >= attractor_count) break;
    vec2 to = attractors[i].xy - pos;
    float dist = length(to) + 1e-3;
    float w = smoothstep(attractors[i].z, 0.0, dist);
    pos += to * (w * attractors[i].w);
  }
  // Repulsors (predators): a capped push directly away (world units, modest), so a
  // flee reads as a lean-away rather than a teleport.
  for (int i = 0; i < %d; i++) {
    if (i >= repulsor_count) break;
    vec2 away = pos - repulsors[i].xy;
    float dist = length(away) + 1e-3;
    float w = smoothstep(repulsors[i].z, 0.0, dist);
    pos += (away / dist) * (w * repulsors[i].w);
  }

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

-- Fill the whole instance buffer once. Homes are UNIFORM in [0,1]^2, so any prefix
-- drawInstanced draws is uniformly spread and -- because fract(uniform + drift) is
-- still uniform -- the field stays evenly filled for all time (a centre-outward
-- sort would make a disk that drifts apart). Instance 1 is pinned to the centre so
-- the lone founder sits dead-centre. Each cell gets a random drift heading + speed
-- and weave/size/alpha jitter. Mirrors swarm.lua's FFI byte-data fill.
local function build_instance_data()
  local ffi = require("ffi")
  local random = love.math.random

  local byte_data = love.data.newByteData(MAX_CELLS * INSTANCE_FLOATS * 4)
  local floats = ffi.cast("float*", byte_data:getFFIPointer())
  local function lerp(a, b) return a + random() * (b - a) end
  local offset = 0
  for i = 1, MAX_CELLS do
    local hx, hy = random(), random()
    if i == 1 then
      hx, hy = 0.5, 0.5 -- the founder sits dead-centre
    end
    -- Random drift heading at a random speed (field-fractions/sec).
    local angle = random() * 2 * math.pi
    local speed = lerp(SPEED_MIN, SPEED_MAX)
    floats[offset] = hx -- InstanceMove.x: home x (0..1)
    floats[offset + 1] = hy -- .y: home y (0..1)
    floats[offset + 2] = math.cos(angle) * speed -- .z: vel x
    floats[offset + 3] = math.sin(angle) * speed -- .w: vel y
    floats[offset + 4] = lerp(WOBBLE_MIN, WOBBLE_MAX) -- InstanceJit.x: weave radius
    floats[offset + 5] = lerp(SIZE_JITTER_MIN, SIZE_JITTER_MAX) -- .y: size jitter
    floats[offset + 6] = lerp(ALPHA_JITTER_MIN, ALPHA_JITTER_MAX) -- .z: alpha jitter
    floats[offset + 7] = random() -- .w: weave phase (0..1), desyncs the wobble
    offset = offset + INSTANCE_FLOATS
  end
  return byte_data
end

local function build_meshes()
  local instance_format = {
    { "InstanceMove", "float", 4 },
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
  quad_mesh:attachAttribute("InstanceMove", instance_mesh, "perinstance")
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
    SWIM_RATE,
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
--   field_w / field_h      -- current field extent (roam wrap + current scale)
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
