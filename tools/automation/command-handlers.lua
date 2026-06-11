-- Command handlers for the agent connector: a table keyed by command name, each a
-- handler(context, params) -> ok, data. `ok` is true/false (data is the payload or an
-- error string); the controller wraps the pair into {ok=true,data=...}/{ok=false,error}.
-- These are botworld's trait/economy ops -- NONE of botlands' RPG verbs. The screenshot
-- command is async and lives in the controller's built-ins (not here), so it can drain
-- on the draw phase.
--
-- `context` is the game context main.lua hands the controller: { layers, modules =
-- { cell, complexcell }, screenshot, console, clock }. The active layer module is
-- resolved from context.layers.active_name() + context.modules; mutations route through
-- that module's debug_* seam (the LAYER owns the clamp/persist, never the connector).
local state_serializer = require("tools.automation.state-serializer")

local handlers = {}

-- Resolve the active layer module (the one the debug_* seams live on). Returns the
-- module + its name, or nil + a reason when no layer is active or it is unregistered.
local function active_module(context)
  local name = context.layers.active_name()
  if not name then
    return nil, "no active layer"
  end
  local module = context.modules[name]
  if not module then
    return nil, "no module for layer: " .. tostring(name)
  end
  return module, name
end

-- Guard: the active layer must be LOADED (its debug_state() table exists) before a
-- read/mutate handler runs. Returns the module + name, or nil + a clear error.
local function loaded_module(context)
  local module, name = active_module(context)
  if not module then
    return nil, name
  end
  if not module.debug_state or not module.debug_state() then
    return nil, "active layer not loaded: " .. tostring(name)
  end
  return module, name
end

-- Liveness probe -- needs no game context, so it answers even before load().
function handlers.ping() return true, { pong = true } end

-- The whole active layer as a plain snapshot: { layer = <name>, state = <serialize> }.
function handlers.query_state(context)
  local data, err = state_serializer.serialize_active(context)
  if not data then
    return false, err
  end
  return true, data
end

-- Read one field (params.id) off the active layer's debug seam.
function handlers.get_trait(context, params)
  local id = params.id
  if not id then
    return false, "id is required"
  end
  local module, err = loaded_module(context)
  if not module then
    return false, err
  end
  local value = module.debug_get(id)
  if value == nil then
    return false, "unknown or unreadable field: " .. tostring(id)
  end
  return true, { id = id, value = value }
end

-- Set one field (params.id = params.value) through the layer's clamping seam, then
-- read it back so the response carries the post-clamp value (e.g. population floored
-- at 1, a trait level floored at 0).
function handlers.set_trait(context, params)
  local id = params.id
  if not id then
    return false, "id is required"
  end
  if params.value == nil then
    return false, "value is required"
  end
  local module, err = loaded_module(context)
  if not module then
    return false, err
  end
  local ok, set_err = module.debug_set(id, params.value)
  if not ok then
    return false, set_err
  end
  return true, { id = id, value = module.debug_get(id) }
end

-- Flip an unlock on for the active layer: cell unlocks a milestone (debug_unlock),
-- complexcell brings a stage online (debug_unlock_stage). Tries whichever seam the
-- active layer exposes.
function handlers.unlock(context, params)
  local id = params.id
  if not id then
    return false, "id is required"
  end
  local module, err = loaded_module(context)
  if not module then
    return false, err
  end
  local seam = module.debug_unlock or module.debug_unlock_stage
  if not seam then
    return false, "active layer exposes no unlock seam"
  end
  local ok, unlock_err = seam(id)
  if not ok then
    return false, unlock_err
  end
  return true, { unlocked = id }
end

-- Advance the active layer's pure sim by params.count authoritative ticks (>= 1).
function handlers.step(context, params)
  local module, err = loaded_module(context)
  if not module then
    return false, err
  end
  local steps = module.debug_step(params.count or 1)
  if steps == false then
    return false, "layer not loaded"
  end
  return true, { steps = steps }
end

-- Run a console line headlessly. The botworld context has no debug console yet, so this
-- degrades to a clear error rather than crashing when context.console is absent.
function handlers.console_exec(context, params)
  local line = params.line
  if not line then
    return false, "line is required"
  end
  if not context.console or not context.console.execute then
    return false, "no console in context"
  end
  context.console.execute(line)
  return true, { executed = line }
end

-- Switch the active layer (loads it if needed, then makes it active). Validates the
-- name is a registered layer first.
function handlers.switch_layer(context, params)
  local target = params.layer
  if not target then
    return false, "layer is required"
  end
  local names = context.layers.names()
  local valid = false
  for _, name in ipairs(names) do
    if name == target then
      valid = true
      break
    end
  end
  if not valid then
    return false, "unknown layer: " .. tostring(target)
  end
  context.layers.load(target)
  context.layers.switch(target)
  return true, { layer = target }
end

-- Forward a key to the game (works even pre-load, no game context needed).
function handlers.keypressed(_, params)
  local key = params.key
  if not key then
    return false, "key is required"
  end
  love.keypressed(key)
  return true, { key = key }
end

-- Quit the app.
function handlers.quit()
  love.event.quit()
  return true, { quitting = true }
end

return handlers
