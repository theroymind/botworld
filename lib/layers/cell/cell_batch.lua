-- GPU-instanced cell renderer: the solar layer's instancing technique
-- (lib/swarm.lua) applied to the Phase-1 swarm, but DYNAMIC rather than stateless.
-- The benchmark and the complex-cell interior swarm fill their instance buffer
-- ONCE and let the vertex shader compute every position from time -- they can,
-- because that motion is closed-form and the agents never interact. The Phase-1
-- cells CANNOT: their positions come from a live CPU boids sim (world.lua) with
-- neighbour separation, predator chasing, eating latches, and click hit-testing,
-- none of which a vertex shader can express (an instance can't read its
-- neighbours, keep state, or be read back on the CPU). So the SIM stays
-- authoritative on the CPU; this module only collapses the RENDER.
--
-- Each frame the view walks the live cells and pushes (x, y, half-size, alpha)
-- plus the mitochondrion mark's half-size per cell into a reused FFI buffer; one
-- prefix upload + one drawInstanced replaces the ~15k setColor+rectangle
-- immediate-mode calls the old path issued (every per-cell setColor flushed
-- LÖVE's auto-batch, so the body alone cost thousands of draw calls a frame).
-- Two passes share the one buffer: the cell body (per-instance alpha, the cell
-- colour as a uniform) and -- only when the colony holds the organelle -- the
-- darker inner mito mark (its own per-instance half-size, a uniform colour/alpha).
--
-- Like lib/swarm.lua, ALL love.* and FFI work is deferred to load/draw -- a bare
-- `require` is headless, so the headless world/sim specs stay love-free. load is
-- idempotent and lazily called by the first draw if the host didn't call it.
local cell_batch = {}

-- Instance-buffer capacity. Kept >= world.MAX_AGENTS (the on-screen ceiling) with
-- headroom; if the colony's drawn sample ever exceeds this, draw clamps to the
-- prefix (a graceful cap, never a crash). Decoupled from world on purpose so the
-- GPU module doesn't depend on the sim module.
local MAX_CELLS = 16384
-- Per instance: InstanceBody (vec4: x, y, half, alpha) + InstanceMark (float:
-- the mito mark's half-size). Five floats, 20 bytes.
local INSTANCE_FLOATS = 5
-- Constant alpha of the darker mito inner mark (matches the old draw_mito_mark).
local MARK_ALPHA = 0.9

local shader
local quad_mesh
local instance_mesh
local byte_data -- reused FFI buffer (filled to the live prefix each frame)
local floats -- ffi float* into byte_data
local count = 0 -- instances pushed this frame
local loaded = false

-- One quad per instance, scaled by the per-instance half-size and translated to
-- the cell's world position. transform_projection already carries the camera
-- push/translate/scale the view set up, so feeding WORLD coords here lands the
-- square exactly where the old immediate-mode rectangle did.
local VERTEX_SHADER = [[
uniform vec3  body_color; // the cell token (body pass) or the mito token (mark pass)
uniform float pass_mode;  // 0 = cell body, 1 = mito mark
uniform float mark_alpha; // constant alpha for the mark pass (body uses per-instance)

attribute vec4  InstanceBody; // x, y, half-size, alpha
attribute float InstanceMark; // mito-mark half-size

varying vec4 cell_color;

vec4 position(mat4 transform_projection, vec4 vertex_position) {
  bool body = pass_mode < 0.5;
  float half_size = body ? InstanceBody.z : InstanceMark;
  float alpha = body ? InstanceBody.w : mark_alpha;
  cell_color = vec4(body_color, alpha);
  return transform_projection * vec4(vertex_position.xy * half_size + InstanceBody.xy, 0.0, 1.0);
}
]]

local FRAGMENT_SHADER = [[
varying vec4 cell_color;

vec4 effect(vec4 color, Image tex, vec2 texture_coords, vec2 screen_coords) {
  return cell_color * color;
}
]]

-- Build the dynamic per-instance mesh (one point per cell, refilled each frame)
-- and the small unit quad instanced once per cell. Mirrors swarm.lua's mesh setup;
-- the quad is UNIT (-1..1) so the shader can scale it by the per-instance size.
local function build_meshes()
  local instance_format = {
    { "InstanceBody", "float", 4 },
    { "InstanceMark", "float", 1 },
  }
  instance_mesh = love.graphics.newMesh(instance_format, MAX_CELLS, "points", "dynamic")

  local quad_vertices = {
    { -1, -1 },
    { 1, -1 },
    { 1, 1 },
    { -1, 1 },
  }
  local quad_format = { { "VertexPosition", "float", 2 } }
  quad_mesh = love.graphics.newMesh(quad_format, quad_vertices, "fan", "static")
  quad_mesh:attachAttribute("InstanceBody", instance_mesh, "perinstance")
  quad_mesh:attachAttribute("InstanceMark", instance_mesh, "perinstance")
end

-- Deferred GPU/FFI setup. Idempotent (the first draw calls it if the host didn't),
-- exactly like swarm.load gating all love.*/FFI work behind an explicit call.
function cell_batch.load()
  if loaded then
    return
  end
  local ffi = require("ffi")
  shader = love.graphics.newShader(FRAGMENT_SHADER, VERTEX_SHADER)
  byte_data = love.data.newByteData(MAX_CELLS * INSTANCE_FLOATS * 4)
  floats = ffi.cast("float*", byte_data:getFFIPointer())
  build_meshes()
  loaded = true
end

function cell_batch.is_loaded() return loaded end

-- Start a frame's batch: lazily init the GPU/FFI resources (so the first push()
-- can write the buffer -- begin runs before any push or draw) and reset the write
-- cursor. load is idempotent, so this is a single branch after the first frame.
function cell_batch.begin()
  cell_batch.load()
  count = 0
end

-- Append one cell. half/alpha drive the body square; mark_half drives the mito
-- inner square (0 when the organelle isn't held -- the mark pass is skipped then
-- anyway). Silently drops past MAX_CELLS (the prefix cap). The view computes these
-- from its existing resolve(), so the body keeps exact visual parity.
function cell_batch.push(x, y, half, alpha, mark_half)
  if count >= MAX_CELLS then
    return
  end
  local o = count * INSTANCE_FLOATS
  floats[o] = x
  floats[o + 1] = y
  floats[o + 2] = half
  floats[o + 3] = alpha
  floats[o + 4] = mark_half or 0
  count = count + 1
end

-- Upload the live prefix once and draw it: the cell body pass always, then -- if
-- mark_color is given (the colony holds the mitochondrion) -- the mito mark pass
-- over the SAME buffer with the mark's colour/alpha. body_color/mark_color are
-- {r, g, b}. Drawn inside the view's camera transform; restores the previous
-- shader so the immediate-mode predators after it render normally.
function cell_batch.draw(body_color, mark_color)
  cell_batch.load() -- lazy GPU init if the host didn't call load explicitly
  if count == 0 then
    return
  end
  -- Push only the live prefix to the GPU (stale tail is never drawn).
  instance_mesh:setVertices(byte_data, 1, count)

  local prev = love.graphics.getShader()
  love.graphics.setShader(shader)
  love.graphics.setColor(1, 1, 1, 1)

  shader:send("body_color", body_color)
  shader:send("pass_mode", 0)
  shader:send("mark_alpha", 0)
  love.graphics.drawInstanced(quad_mesh, count)

  if mark_color then
    shader:send("body_color", mark_color)
    shader:send("pass_mode", 1)
    shader:send("mark_alpha", MARK_ALPHA)
    love.graphics.drawInstanced(quad_mesh, count)
  end

  love.graphics.setShader(prev)
end

return cell_batch
