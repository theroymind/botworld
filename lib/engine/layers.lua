-- Layer registry: each scale of the game (cell, solar, ...) is a layer that owns its
-- own state, sim, and rendering. Only the active layer gets per-frame update/draw/input.
-- A layer ticks (keeps producing in the background) only once it has been REACHED --
-- entered via switch(). A phase you've passed keeps living; a phase you haven't reached
-- yet is never loaded OR ticked, so it can't produce or fire UI (toasts) behind the
-- active phase. Handlers are all optional — missing ones are skipped.
local layers = {}

local registry = {} -- name -> layer table
local order = {} -- names in registration order
local reached = {} -- name -> true once the layer has been entered (switched to)
local loaded = {} -- name -> true once its load() has run (or the seam set it up)
local active
local active_name

function layers.register(name, layer)
  assert(registry[name] == nil, "layer already registered: " .. name)
  registry[name] = layer
  order[#order + 1] = name
end

-- Load a SINGLE layer by name (its load() sets up state + resources), at most once.
-- Only the phase you boot/enter is loaded; an unreached phase is never loaded, so it
-- can't produce or surface UI behind the active phase. Idempotent -- a layer the seam
-- (or a prior debug tab) already brought up is not reloaded, so its state is never
-- clobbered by a second load.
function layers.load(name)
  if loaded[name] then
    return
  end
  loaded[name] = true
  local layer = assert(registry[name], "unknown layer: " .. tostring(name))
  if layer.load then
    layer.load()
  end
end

-- Sim tick for every REACHED layer, active or backgrounded: a phase keeps producing
-- once you've entered it. A phase you haven't reached never ticks, so it can't produce
-- or surface UI behind the active phase.
function layers.tick_all(tick_dt)
  for i = 1, #order do
    local name = order[i]
    if reached[name] then
      local layer = registry[name]
      if layer.tick then
        layer.tick(tick_dt)
      end
    end
  end
end

-- Per-frame update for the active layer only (visual sims, not game state).
function layers.update(dt)
  if active and active.update then
    active.update(dt)
  end
end

function layers.draw()
  if active and active.draw then
    active.draw()
  end
end

-- Make `name` the active layer; mark it reached (so it ticks from now on, and never
-- un-reaches -- a passed phase keeps living) and loaded (whoever switched here set it up:
-- boot loaded it, the seam enter_from_seam'd it, or the debug tab loaded it first), so a
-- later layers.load() correctly skips it.
function layers.switch(name)
  active = assert(registry[name], "unknown layer: " .. tostring(name))
  active_name = name
  reached[name] = true
  loaded[name] = true
end

function layers.active_name() return active_name end

-- Registration order; treat as read-only.
function layers.names() return order end

function layers.keypressed(key)
  if active and active.keypressed then
    active.keypressed(key)
  end
end

function layers.mousepressed(x, y, button)
  if active and active.mousepressed then
    active.mousepressed(x, y, button)
  end
end

function layers.mousemoved(x, y, dx, dy)
  if active and active.mousemoved then
    active.mousemoved(x, y, dx, dy)
  end
end

function layers.wheelmoved(dx, dy)
  if active and active.wheelmoved then
    active.wheelmoved(dx, dy)
  end
end

return layers
