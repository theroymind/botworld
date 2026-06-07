-- Layer registry: each scale of the game (cell, solar, ...) is a layer that
-- owns its own state, sim, and rendering. Every registered layer ticks every
-- sim tick so backgrounded scales keep producing; only the active layer gets
-- per-frame updates, drawing, and input. Handlers are all optional — missing
-- ones are skipped.
local layers = {}

local registry = {} -- name -> layer table
local order = {} -- names in registration order
local active
local active_name

function layers.register(name, layer)
  assert(registry[name] == nil, "layer already registered: " .. name)
  registry[name] = layer
  order[#order + 1] = name
end

function layers.load_all()
  for i = 1, #order do
    local layer = registry[order[i]]
    if layer.load then
      layer.load()
    end
  end
end

-- Sim tick for every layer, active or not: backgrounded scales keep living.
function layers.tick_all(tick_dt)
  for i = 1, #order do
    local layer = registry[order[i]]
    if layer.tick then
      layer.tick(tick_dt)
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

function layers.switch(name)
  active = assert(registry[name], "unknown layer: " .. tostring(name))
  active_name = name
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
