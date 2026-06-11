-- State serializer for the agent connector: turns the active layer's debug snapshot
-- into the JSON-able shape the connector ships, and exposes the JSON encoder so a
-- handler never reaches for the codec directly. The layer's debug_serialize() already
-- returns PLAIN tables (number/string/bool/table-of-those, built from the same
-- serialize functions the save system uses), so serialize_active is a thin pass-through
-- keyed by the active layer name -- no safe-copy filter is needed (there is no live
-- agent / love object to drop). Pure: no love.*; the only dependency is the vendored
-- JSON codec.
local json = require("lib.engine.json")

local state_serializer = {}

-- The active layer's plain snapshot, keyed by layer name:
--   { layer = "<active>", state = <module.debug_serialize()> }
-- `context.layers.active_name()` names the active layer; `context.modules` maps that
-- name to the layer module exposing debug_serialize(). Returns nil + a reason when no
-- layer is active, the module is unregistered, or the layer has not been load()ed
-- (debug_serialize() == nil), so the caller can surface a clear error.
function state_serializer.serialize_active(context)
  local name = context.layers.active_name()
  if not name then
    return nil, "no active layer"
  end
  local module = context.modules[name]
  if not module or not module.debug_serialize then
    return nil, "no debug serializer for layer: " .. tostring(name)
  end
  local snapshot = module.debug_serialize()
  if not snapshot then
    return nil, "layer not loaded: " .. tostring(name)
  end
  return { layer = name, state = snapshot }
end

-- Encode any JSON-able table to a wire string via the vendored codec.
function state_serializer.encode(data) return json.encode(data) end

return state_serializer
