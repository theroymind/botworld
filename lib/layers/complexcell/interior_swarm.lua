-- GPU-instanced interior swarm for the complex cell -- the solar layer's proven
-- technique (lib/swarm.lua) pointed INWARD. A fixed, large instance buffer is
-- filled ONCE at load with stateless "vesicle" routes; each vesicle's position is
-- a CLOSED-FORM function of (per-instance attributes, time, endpoint uniforms)
-- evaluated entirely in the vertex shader. The CPU does ~zero per-instance work:
-- per frame it ships only a handful of scalar/array uniforms (time, the organelle
-- endpoint positions, and the flow readouts) and raises the live instance count
-- passed to drawInstanced. "Spawning" or "growing" is just raising that count.
--
-- This file is the only sibling of view.lua that owns the GPU machinery. It
-- mirrors lib/swarm.lua's mesh/shader/FFI setup as closely as the cell-interior
-- motion model allows; deviations are limited to (a) the route model (pipeline
-- segments between consecutive organelle endpoints instead of planet->moon hauler
-- loops) and (b) the flow-readout uniforms (brownout/output/fuel/per-segment
-- congestion+vacancy), each commented at its use site. Like swarm.lua, ALL love.*
-- and FFI work is deferred to load/update/draw -- a bare `require` is headless.
local interior_swarm = {}

-- A vesicle is one stateless instance. The buffer is filled once; drawInstanced
-- draws a PREFIX of it (the live count), so the interior fills in as the cell
-- grows without any CPU per-instance churn. The cap is the GPU's problem.
local MAX_VESICLES = 300000
-- Endpoint uniform array size: organelle clusters (one per pipeline stage) plus a
-- block of mitochondria emitters. >= the live endpoint count every frame.
local MAX_ENDPOINTS = 32
-- Per-segment uniform array size: one entry per gap between consecutive endpoints
-- along the pipeline. >= live segment count.
local MAX_SEGMENTS = 32
local INSTANCE_FLOATS = 8 -- two vec4 attributes per vesicle
local VESICLE_HALF_SIZE = 1.4
-- Per-vesicle cycle: how long one full leg (endpoint A -> endpoint B) takes. A
-- spread keeps the stream from pulsing in lockstep.
local CYCLE_SECONDS_MIN = 6
local CYCLE_SECONDS_MAX = 16
local LANE_SPREAD = 26 -- max perpendicular lane offset mid-leg; pinches at endpoints
local WOBBLE_FREQUENCY_MIN = 0.6
local WOBBLE_FREQUENCY_MAX = 2.2

interior_swarm.count = 0
interior_swarm.max_count = MAX_VESICLES

local shader
local quad_mesh
local instance_mesh
local endpoint_uniform = {} -- reused vec2 array (positions) -> "endpoints" uniform
local segment_uniform = {} -- reused vec4 array (flow readouts) -> "segments" uniform
local elapsed = 0
local loaded = false

-- The number of pipeline SEGMENTS a route's segment index can address. Baked into
-- the shader so the per-instance "which segment" attribute can be reduced into the
-- live segment range each frame (see segment_count uniform). Matches MAX_SEGMENTS.
local VERTEX_SHADER_TEMPLATE = [[
uniform float time;
uniform float speed;         // global liveliness: output-driven base speed multiplier
uniform float brightness;    // global brightness (output up, brownout down)
uniform float slow;          // global brownout slowdown (eased 0..1; 1 = full speed)
uniform vec3  tint;          // fuel_factor tint multiplier (neutral white at 1.0)
uniform int   segment_count; // live pipeline segments (gaps between endpoints)
uniform vec2  endpoints[%d]; // organelle cluster positions, screen space
// Per-segment flow readouts, indexed by the segment a vesicle is routed onto:
//   .x congestion 0..1 (clump + slow)   .y is_bottleneck 0/1 (constrict)
//   .z vacancy 0..1 (downstream of the choke -> push instances off / dim)
//   .w density 0..1 (how "full" this segment runs; feeds brightness)
uniform vec4  segments[%d];

attribute vec4 InstanceRoute;  // base segment (slot), phase (s), lane sign, brightness jitter
attribute vec4 InstanceMotion; // cycle (s), lane offset, wobble frequency, wobble phase

varying vec3 vesicle_color;

const float DWELL = 0.16;            // fraction of each leg held at an endpoint
const float WOBBLE_AMPLITUDE = 9.0;  // px of mid-leg jitter
const float ENDPOINT_PINCH = 0.10;   // residual lane width at the endpoints
const float ARC_FAN = 0.90;          // share of the lane offset applied as a mid-leg arc
const float CONGEST_SLOW = 0.55;     // a jammed segment crawls (speed *= 1 - this*congestion)
const float CONGEST_CLUMP = 0.55;    // a jam pulls vesicles toward the leg's middle (bunching)
const float BOTTLENECK_PINCH = 0.55; // the choke segment tightens its lane
const float VACANCY_OFFSCREEN = 0.85;// vacancy this strong parks a vesicle out of view

float travel(float leg_t) {
  // Smoothstep with a dwell at each end: vesicles ease out of an endpoint, glide,
  // then ease into arrival -- the streams leave/arrive as a point.
  float s = clamp((leg_t - DWELL) / (1.0 - 2.0 * DWELL), 0.0, 1.0);
  return s * s * (3.0 - 2.0 * s);
}

vec4 position(mat4 transform_projection, vec4 vertex_position) {
  // Resolve which pipeline segment this vesicle hauls along. The per-instance base
  // slot is reduced into the LIVE segment range, so when fewer stages are unlocked
  // the same buffer just folds onto the segments that exist (no CPU rewrite). A
  // segment connects endpoint[seg] -> endpoint[seg+1] along the pipeline.
  int seg = int(mod(InstanceRoute.x, float(max(segment_count, 1))));
  vec4 flow = segments[seg];
  float congestion = flow.x;
  float is_bottleneck = flow.y;
  float vacancy = flow.z;
  float density = flow.w;

  // VACANCY (downstream of the choke): thin the highway by parking a fraction of
  // its vesicles far off-screen. Deterministic per instance via the lane-sign
  // attribute, so the SAME vesicles drop each frame -- a steady sparse look, not a
  // flicker. This is the "fewer instances routed there" readout done on the GPU.
  if (vacancy > 0.0 && InstanceRoute.z < (vacancy * VACANCY_OFFSCREEN * 2.0 - 1.0)) {
    vesicle_color = vec3(0.0);
    return transform_projection * vec4(1.0e6, 1.0e6, 0.0, 1.0);
  }

  vec2 from = endpoints[seg];
  vec2 to = endpoints[seg + 1];

  // Closed-form leg progress. Global speed (output) and per-segment congestion both
  // scale how fast time advances along the leg; brownout `slow` drags the whole
  // swarm. A jammed segment crawls (CONGEST_SLOW), reading as a backed-up stage.
  float seg_speed = speed * slow * (1.0 - CONGEST_SLOW * congestion);
  float t = fract((time * seg_speed + InstanceRoute.y) / InstanceMotion.x);
  float s = travel(t);

  // CONGESTION CLUMP: bias progress toward the middle of the leg so jammed vesicles
  // bunch up (crowd) instead of spacing evenly -- a visible pile-up.
  s = mix(s, 0.5 + (s - 0.5) * (1.0 - CONGEST_CLUMP * congestion), congestion);

  vec2 direction = normalize(to - from);
  vec2 perpendicular = vec2(-direction.y, direction.x);

  // Parabolic arc: zero at both endpoints, max mid-leg, so each vesicle bows out
  // into its own lane and the stream fans into a curved highway, then converges.
  float arc = 4.0 * s * (1.0 - s);
  float wobble = sin(time * InstanceMotion.z + InstanceMotion.w) * WOBBLE_AMPLITUDE * arc;

  // BOTTLENECK CONSTRICTION: the choke segment squeezes its lane width, so its
  // vesicles bunch into a tight thread (the pinch).
  float lane_scale = 1.0 - BOTTLENECK_PINCH * is_bottleneck;
  float bow = InstanceMotion.y * (ENDPOINT_PINCH + ARC_FAN * arc) * lane_scale;

  vec2 vesicle = mix(from, to, s) + perpendicular * (bow + wobble);

  // Color: the fuel tint, modulated by per-segment density (busy segments read a
  // touch brighter) and a per-instance brightness jitter so the cloud isn't flat.
  // The global `brightness` (output up / brownout down) is applied here too.
  float lively = (0.62 + 0.38 * density) * brightness * InstanceRoute.w;
  vesicle_color = tint * lively;

  return transform_projection * vec4(vertex_position.xy + vesicle, 0.0, 1.0);
}
]]

local FRAGMENT_SHADER = [[
varying vec3 vesicle_color;

vec4 effect(vec4 color, Image tex, vec2 texture_coords, vec2 screen_coords) {
  return vec4(vesicle_color, 1.0) * color;
}
]]

-- Fill the whole instance buffer once with random routes. drawInstanced(count)
-- then draws a prefix. Mirrors swarm.lua's build_instance_data (FFI byte data).
local function build_instance_data()
  local ffi = require("ffi")
  local byte_data = love.data.newByteData(MAX_VESICLES * INSTANCE_FLOATS * 4)
  local floats = ffi.cast("float*", byte_data:getFFIPointer())
  local random = love.math.random
  local two_pi = 2 * math.pi
  local offset = 0
  for _ = 1, MAX_VESICLES do
    -- Base segment slot is reduced into the live segment count in the shader, so a
    -- big constant here spreads vesicles across however many segments exist.
    local slot = random(0, MAX_SEGMENTS - 1)
    local cycle = CYCLE_SECONDS_MIN + random() * (CYCLE_SECONDS_MAX - CYCLE_SECONDS_MIN)
    floats[offset] = slot -- InstanceRoute.x: base segment slot
    floats[offset + 1] = random() * cycle -- .y: phase (s) -- desync the stream
    floats[offset + 2] = random() * 2 - 1 -- .z: lane sign (-1..1) -- vacancy threshold + lane side
    floats[offset + 3] = 0.7 + random() * 0.55 -- .w: per-instance brightness jitter
    floats[offset + 4] = cycle -- InstanceMotion.x: cycle (s)
    floats[offset + 5] = (random() * 2 - 1) * LANE_SPREAD -- .y: lane offset
    floats[offset + 6] = WOBBLE_FREQUENCY_MIN
      + random() * (WOBBLE_FREQUENCY_MAX - WOBBLE_FREQUENCY_MIN) -- .z: wobble freq
    floats[offset + 7] = random() * two_pi -- .w: wobble phase
    offset = offset + INSTANCE_FLOATS
  end
  return byte_data
end

-- Build the per-instance mesh (one vertex per vesicle, "points") and the small
-- quad mesh that is instanced once per vesicle. Mirrors swarm.lua exactly.
local function build_meshes()
  local instance_format = {
    { "InstanceRoute", "float", 4 },
    { "InstanceMotion", "float", 4 },
  }
  instance_mesh = love.graphics.newMesh(instance_format, MAX_VESICLES, "points", "static")
  instance_mesh:setVertices(build_instance_data())

  local half = VESICLE_HALF_SIZE
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

-- Deferred GPU setup. Idempotent (first draw calls it if the host didn't), exactly
-- like swarm.load gating all love.*/FFI work behind an explicit call.
function interior_swarm.load()
  if loaded then
    return
  end
  local vertex_shader = string.format(VERTEX_SHADER_TEMPLATE, MAX_ENDPOINTS, MAX_SEGMENTS)
  shader = love.graphics.newShader(FRAGMENT_SHADER, vertex_shader)
  for i = 1, MAX_ENDPOINTS do
    endpoint_uniform[i] = { 0, 0 }
  end
  for i = 1, MAX_SEGMENTS do
    segment_uniform[i] = { 0, 0, 0, 0 }
  end
  build_meshes()
  loaded = true
end

function interior_swarm.is_loaded() return loaded end

-- Set the live instance count directly (view samples it from the snapshot scale).
function interior_swarm.set_count(n)
  if n < 0 then
    n = 0
  elseif n > MAX_VESICLES then
    n = MAX_VESICLES
  end
  interior_swarm.count = math.floor(n)
end

function interior_swarm.clear() interior_swarm.count = 0 end

-- Advance the swarm clock. Cheap: one scalar accumulate; the time uniform is sent
-- in draw alongside the rest (draw is the only place we touch the shader, so the
-- module stays headless until something actually renders).
function interior_swarm.update(dt) elapsed = elapsed + dt end

-- Upload the organelle endpoint positions. `xs`/`ys` are flat arrays of length
-- `n` (<= MAX_ENDPOINTS), one per cluster along the pipeline, in order. Cheap --
-- a handful of vec2s, mirroring swarm.lua's send_body_positions.
local function send_endpoints(xs, ys, n)
  for i = 1, n do
    local entry = endpoint_uniform[i]
    entry[1] = xs[i]
    entry[2] = ys[i]
  end
  shader:send("endpoints", unpack(endpoint_uniform, 1, MAX_ENDPOINTS))
end

-- Upload the per-segment flow readouts. `segs` is an array of { congestion,
-- is_bottleneck(0/1), vacancy, density }, one per gap between consecutive
-- endpoints (n - 1 of them).
local function send_segments(segs, n)
  for i = 1, MAX_SEGMENTS do
    local entry = segment_uniform[i]
    local src = segs[i]
    if src then
      entry[1], entry[2], entry[3], entry[4] = src[1], src[2], src[3], src[4]
    else
      entry[1], entry[2], entry[3], entry[4] = 0, 0, 0, 0
    end
  end
  shader:send("segment_count", n)
  shader:send("segments", unpack(segment_uniform, 1, MAX_SEGMENTS))
end

-- Draw the live prefix of the swarm. `params` carries the per-frame flow uniforms
-- and the endpoint/segment data; all of it is cheap to push each frame.
--   params.endpoints_x / .endpoints_y / .endpoint_count
--   params.segments / .segment_count
--   params.speed / .brightness / .slow / .tint{3}
function interior_swarm.draw(params)
  interior_swarm.load() -- lazy GPU init if the host didn't call load explicitly
  if interior_swarm.count == 0 or (params.endpoint_count or 0) < 2 then
    return
  end

  shader:send("time", elapsed)
  shader:send("speed", params.speed or 1)
  shader:send("brightness", params.brightness or 1)
  shader:send("slow", params.slow or 1)
  shader:send("tint", params.tint or { 1, 1, 1 })
  send_endpoints(params.endpoints_x, params.endpoints_y, params.endpoint_count)
  send_segments(params.segments or {}, params.segment_count or 0)

  local prev = love.graphics.getShader()
  -- Additive blend: overlapping vesicles brighten, so dense pipelines glow like a
  -- teeming cloud rather than flatly overpainting. Restored after the draw.
  love.graphics.setBlendMode("add")
  love.graphics.setShader(shader)
  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.drawInstanced(quad_mesh, interior_swarm.count)
  love.graphics.setShader(prev)
  love.graphics.setBlendMode("alpha")
end

return interior_swarm
