-- GPU procedural swarm field: the COSMETIC OVERFLOW of the visible Phase-1 swarm,
-- computed almost entirely on the GPU. world.lua simulates a small set of REAL boids
-- (the ones that sense motes, chase, engulf and get hunted) and the view draws those
-- 1:1; this field only fills in the teeming mass ABOVE that simulated count once the
-- colony outgrows it. Each instance's position is a closed-form function of
-- (per-instance seed/frequencies, time, and a handful of attractor/repulsor uniforms)
-- evaluated in the vertex shader. The CPU per frame ships only a few scalars + the
-- live bloom/predator positions and raises the instance count; "growth" is just a
-- higher count. Nothing here is read back, so the gameplay couplings (predator kills,
-- engulfs) stay on the small CPU set in world.lua -- this field is pure cosmetic skin.
--
-- The motion model is RUN-AND-TUMBLE, the real microbial gait: each cell swims a
-- straight RUN along a fixed heading for ~RUN_TIME, then TUMBLES to a new random
-- heading and runs again. It never builds a single heading that dashes it across the
-- dish. The per-cell run headings are DE-MEANED so they cancel over one cycle, making
-- the walk a bounded closed loop that returns home -- biologically a confined cell
-- pacing its patch, and computationally a stateless closed form (no per-frame
-- integration, no dispersal that would empty the fixed instance buffer). A small
-- per-cell wobble rides on top for fine organic weave. The part that reads as
-- "they're surviving": cells near a nutrient bloom EASE toward it (a knot gathers at
-- food) and cells near a predator are shoved away (the flee), both from uniform points.
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
-- Fine-weave phase, integrated on the CPU so a mid-run motility change scales the
-- weave RATE without snapping the phase. The shader used to fold the rate in as
-- time * (WEAVE_RATE * swim_scale); when swim_scale changed, that angle jumped by
-- elapsed * Δrate -- a large, effectively random offset that snapped EVERY cell's
-- weave at once (the visible "glitch" on each early Motility upgrade, until the
-- rate saturated). Integrating ∫ rate dt here keeps the phase continuous across
-- rate changes. last_swim is the most recent motility rate scalar (set at draw,
-- applied by the next update); a one-frame lag is irrelevant for a cosmetic weave.
local weave_phase = 0
local last_swim = 1
local loaded = false

cell_field.count = 0
cell_field.max_count = MAX_CELLS

-- Motion bands (tuning knobs -- set by eye). The cell does a RUN-AND-TUMBLE walk:
-- it swims a straight RUN for RUN_TIME, then TUMBLES to a new random heading -- the
-- signature microbial gait (a bacterium runs ~1s, reorients, runs again). The walk
-- is bounded into a closed loop (the per-run headings are de-meaned so they cancel
-- over the cycle), so it disperses locally and returns home rather than dashing off
-- the dish or needing per-frame state. RUN_LEN is the per-run stride as a FIELD-
-- FRACTION (scales with the dish); RUN_COUNT runs make one CYCLE = RUN_COUNT*RUN_TIME.
local RUN_COUNT = 8 -- runs per closed cycle (also the shader's constant loop bound)
local RUN_TIME = 1.4 -- seconds per straight run before a tumble
local RUN_LEN = 0.045 -- per-run stride as a field-fraction (scales with the dish)
local RUN_JIT_MIN, RUN_JIT_MAX = 0.7, 1.3 -- per-cell stride-length variation
local WOBBLE_MIN, WOBBLE_MAX = 3, 11 -- fine weave radius (world units)
local SWIM_RATE = 1.1 -- weave angular speed (rad/sec), shared; phase desyncs cells
local SIZE_JITTER_MIN, SIZE_JITTER_MAX = 0.7, 1.3 -- per-cell size variation
local ALPHA_JITTER_MIN, ALPHA_JITTER_MAX = 0.62, 0.95 -- per-cell brightness variation

-- BLOOM_MAX / PRED_MAX and the run constants are baked into the shader (via a const
-- block) so the loops have constant bounds (required by GLSL ES on the iOS build) and
-- the gait needs no per-cell rate uniform. SWIM_RATE is NOT baked: the weave rate is
-- integrated CPU-side into weave_phase (see the weave_phase note above) so a motility
-- change never snaps the phase.
local VERTEX_SHADER_TEMPLATE = [[
uniform float time;
uniform vec2  field;        // current field extent (world units): run scale + tier
uniform vec3  body_color;    // cell token (body pass) or mito token (mark pass)
uniform float base_half;     // cell body half-size in world units
uniform float pass_mode;     // 0 = cell body, 1 = mito mark
// Trait-driven look. All neutral at their defaults (the field renders exactly as
// before when stats are absent): weave_phase the base-rate weave clock (motility ->
// dart vs drift on the fine weave; the CPU integrates the RATE so a motility change
// bends the phase forward instead of snapping it), size_scale 1 (evasion -> a firmer,
// slightly larger body + mark), sense_halo 0 (chemotaxis -> a faint additive twinkle).
uniform float weave_phase;   // motility: CPU-integrated fine-weave phase (radians), continuous across rate changes
uniform float size_scale;    // evasion: scales the body/mark half-size
uniform float sense_halo;    // chemotaxis: 0..~1 additive alpha shimmer (sense glow)
uniform int   attractor_count;
uniform vec4  attractors[%d]; // .xy world pos, .z radius, .w pull fraction (blooms)
uniform int   repulsor_count;
uniform vec4  repulsors[%d];  // .xy world pos, .z radius, .w push (world units, predators)

attribute vec4 InstanceMove; // home.x (0..1), home.y (0..1), seed (0..1), run jitter
attribute vec4 InstanceJit;  // wobble radius, size jitter, alpha jitter, phase (0..1)

varying vec4 cell_color;
varying vec2 quad_uv;   // local quad coords in [-1,1]^2; |quad_uv| <= 1 is the disc

// Baked motion constants (RUN_COUNT/RUN_TIME/RUN_LEN, MARK_*). const int
// RUN_COUNT is a constant expression so it can bound the loops on GLSL ES (iOS).
%s

// Per-(cell,run) tumble heading: a stable hash of the cell seed and the run index.
float run_angle(float seed, int j) {
  return fract(sin(seed * 97.0 + float(j) * 13.0) * 43758.5453) * 6.2831853;
}

vec4 position(mat4 transform_projection, vec4 vertex_position) {
  float two_pi = 6.2831853;
  float phase = InstanceJit.w;
  float seed = InstanceMove.z;    // per-cell random seed (0..1)
  float run_jit = InstanceMove.w; // per-cell stride-length jitter
  vec2 home = InstanceMove.xy * field;

  // RUN-AND-TUMBLE walk: swim a straight RUN along a fixed heading for RUN_TIME, then
  // TUMBLE to a new random heading -- the microbial gait. The RUN_COUNT per-run
  // headings are DE-MEANED so the runs cancel over CYCLE = RUN_COUNT*RUN_TIME: the
  // path is a closed loop that returns home (no teleport, no dispersal off the dish),
  // bounded and fully stateless. phase offsets each cell's clock so they desync.
  float cycle = float(RUN_COUNT) * RUN_TIME;
  float tl = mod(time + phase * cycle, cycle);
  int run_k = int(floor(tl / RUN_TIME)); // which run we're in now
  float run_f = fract(tl / RUN_TIME);    // progress through the current run

  // Mean heading vector over the cycle, so subtracting it makes the runs sum to zero.
  vec2 mean_dir = vec2(0.0);
  for (int j = 0; j < RUN_COUNT; j++) {
    float a = run_angle(seed, j);
    mean_dir += vec2(cos(a), sin(a));
  }
  mean_dir /= float(RUN_COUNT);

  // Accumulate the completed runs plus the partial current run (each de-meaned).
  vec2 walk = vec2(0.0);
  for (int j = 0; j < RUN_COUNT; j++) {
    float a = run_angle(seed, j);
    vec2 seg = vec2(cos(a), sin(a)) - mean_dir; // de-meaned run vector
    if (j < run_k) {
      walk += seg;
    } else if (j == run_k) {
      walk += seg * run_f;
    }
  }
  vec2 pos = home + walk * (RUN_LEN * run_jit) * field;

  // Gentle fine weave on top so each cell wriggles as it swims. weave_phase is the
  // CPU-integrated weave clock (motility scales its RATE): a leveled, motile colony
  // darts/wriggles faster, a sluggish one drifts. Pre-integrated so a mid-run rate
  // change advances the phase smoothly instead of snapping it -- the old time*rate
  // form jumped by elapsed*Δrate on every Motility upgrade (a whole-field glitch).
  float ang = weave_phase + phase * two_pi;
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
  // Repulsors (predators): a capped push away (world units, modest), so a flee
  // reads as a lean-away rather than a teleport. The push is PER-CELL irregular so
  // the avoided zone is a ragged, living gap instead of a perfect circle stamped
  // out of the swarm: each cell has its OWN flee radius (so the boundary frays),
  // leans away at a slightly rotated, time-wavering angle (so cells scatter rather
  // than all sliding radially outward), and flees with its own strength.
  for (int i = 0; i < %d; i++) {
    if (i >= repulsor_count) break;
    vec2 away = pos - repulsors[i].xy;
    float dist = length(away) + 1e-3;
    // Stable per-(cell,predator) hash drives all three perturbations.
    float jit = fract(sin(seed * 53.7 + float(i) * 19.3) * 43758.5453);
    float rad = repulsors[i].z * (0.68 + 0.64 * jit);    // own flee radius -> frayed edge
    float w = smoothstep(rad, 0.0, dist);
    float ang = (jit - 0.5) * 1.3                         // fixed per-cell skew
              + 0.30 * sin(time * 1.6 + seed * two_pi);   // slow shimmer so the gap breathes
    float ca = cos(ang); float sa = sin(ang);
    vec2 dir = vec2(away.x * ca - away.y * sa, away.x * sa + away.y * ca) / dist;
    float strength = repulsors[i].w * (0.5 + 1.0 * jit);  // own flee strength
    pos += dir * (w * strength);
  }

  bool body = pass_mode < 0.5;
  // size_scale (evasion) firms up the body a touch: a higher-evasion colony reads
  // as slightly larger, sturdier squares (and the mito mark rides the same scale).
  float half_size = base_half * InstanceJit.y * size_scale * (body ? 1.0 : MARK_SCALE);
  // Gentle per-cell twinkle so the field shimmers like living matter, not a flat
  // stipple; the mark pass uses its own constant alpha. sense_halo (chemotaxis)
  // adds a faint, desynced additive shimmer on top -- a "sensing" glow that lifts
  // the body alpha legibly without a separate halo pass. Zero -> the old twinkle.
  float twinkle = 0.85 + 0.15 * sin(time * 2.0 + phase * 10.0);
  float halo = sense_halo * (0.5 + 0.5 * sin(time * 3.0 + phase * two_pi));
  float alpha = body ? (InstanceJit.z * twinkle + halo) : MARK_ALPHA;
  cell_color = vec4(body_color, alpha);
  quad_uv = vertex_position.xy; // unit quad (-1..1); fragment masks it into a disc
  return transform_projection * vec4(vertex_position.xy * half_size + pos, 0.0, 1.0);
}
]]

local FRAGMENT_SHADER = [[
varying vec4 cell_color;
varying vec2 quad_uv;

vec4 effect(vec4 color, Image tex, vec2 texture_coords, vec2 screen_coords) {
  // Mask the unit quad into a disc: cells render as circles, not squares. fwidth
  // gives a ~1px feathered edge so the rim is smooth instead of a jagged stairstep,
  // independent of zoom/cell size. r2 in [0,1] at the inscribed circle's edge.
  float r2 = dot(quad_uv, quad_uv);
  float aa = fwidth(r2) + 1e-5;
  float mask = 1.0 - smoothstep(1.0 - aa, 1.0 + aa, r2);
  if (mask <= 0.0) discard;
  return cell_color * color * vec4(1.0, 1.0, 1.0, mask);
}
]]

-- Fill the whole instance buffer once. Homes are UNIFORM in [0,1]^2, so any prefix
-- drawInstanced draws is uniformly spread and -- because the run-and-tumble walk is a
-- closed loop with no net translation -- the field stays evenly filled for all time (a
-- centre-outward sort would make a disk that drifts apart). Instance 1 is pinned to the
-- centre. Each cell gets a random SEED (its private tumble sequence) and a stride-length
-- jitter, plus weave/size/alpha jitter. Mirrors swarm.lua's FFI fill.
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
    floats[offset] = hx -- InstanceMove.x: home x (0..1)
    floats[offset + 1] = hy -- .y: home y (0..1)
    floats[offset + 2] = random() -- .z: seed (0..1) -- the cell's private tumble sequence
    floats[offset + 3] = lerp(RUN_JIT_MIN, RUN_JIT_MAX) -- .w: per-cell stride-length jitter
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
  -- Bake the motion constants into a GLSL const block. RUN_COUNT is a const int so it
  -- can bound the shader loops (a constant expression, required on GLSL ES / iOS).
  local consts = string.format(
    "const int RUN_COUNT = %d;\n"
      .. "const float RUN_TIME = %f;\n"
      .. "const float RUN_LEN = %f;\n"
      .. "const float MARK_SCALE = %f;\n"
      .. "const float MARK_ALPHA = %f;",
    RUN_COUNT,
    RUN_TIME,
    RUN_LEN,
    MARK_SCALE,
    MARK_ALPHA
  )
  local vertex_shader = string.format(
    VERTEX_SHADER_TEMPLATE,
    MAX_ATTRACTORS,
    MAX_REPULSORS,
    consts,
    MAX_ATTRACTORS,
    MAX_REPULSORS
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
function cell_field.update(dt)
  elapsed = elapsed + dt
  -- Advance the weave clock at the current motility rate (SWIM_RATE * last_swim).
  -- Integrating here -- rather than recomputing time * rate in the shader -- means a
  -- changed rate only bends the phase forward, never snaps it.
  weave_phase = weave_phase + SWIM_RATE * last_swim * dt
end

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
--   field_w / field_h      -- current field extent (meander scale + current tier)
--   base_half              -- cell body half-size in world units
--   color                  -- cell token { r, g, b } (body pass; may be trait-tinted)
--   attractors / repulsors -- arrays of { x, y, radius, strength } (blooms/predators)
--   mito / mark_color      -- when held, a second pass stamps the inner mito mark
--   swim_scale             -- motility: fine-weave rate multiplier (default 1)
--   size_scale             -- evasion: body/mark size multiplier (default 1)
--   sense_halo             -- chemotaxis: additive alpha shimmer 0..~1 (default 0)
--   opacity                -- whole-field alpha multiplier 0..1 (default 1): the vertex
--                             color the fragment multiplies into every cell, so the
--                             end-of-phase-1 dive can FADE the overflow swarm out in
--                             lockstep with the simulated boids (1 = unchanged).
-- The three trait knobs are OPTIONAL and default to the neutral look, so callers
-- (tests, other paths) that omit them get the field exactly as it was before.
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
  -- Trait knobs, nil-safe: omitted -> the neutral look (rate 1 / size 1 / halo 0).
  -- Motility feeds the weave as a pre-integrated PHASE (continuous across rate
  -- changes); record the rate here so the next update integrates at the new motility.
  last_swim = params.swim_scale or 1
  shader:send("weave_phase", weave_phase)
  shader:send("size_scale", params.size_scale or 1)
  shader:send("sense_halo", params.sense_halo or 0)
  shader:send("attractor_count", attractor_count)
  shader:send("attractors", unpack(attractor_uniform, 1, MAX_ATTRACTORS))
  shader:send("repulsor_count", repulsor_count)
  shader:send("repulsors", unpack(repulsor_uniform, 1, MAX_REPULSORS))

  local prev = love.graphics.getShader()
  love.graphics.setShader(shader)
  -- The fragment multiplies cell_color by this vertex color, so an opacity < 1 fades
  -- the WHOLE field uniformly -- the hook the dive uses to dissolve the overflow swarm.
  local opacity = params.opacity or 1
  love.graphics.setColor(1, 1, 1, opacity)

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
