-- Botworld's co-op message registry. This is PROTOCOL (game content), not engine
-- -- it rides on the copied net engine but is botworld's own, proving the
-- engine/protocol split survives the copy: same engine, different message set.
-- Each module under lib/coop/messages/ is auto-discovered (botlands' registry
-- convention, kept via lib.engine.net.util.auto-discover) and indexed by its
-- declared `type`. Pass the result to net.new{ messages = ... }.
local auto_discover = require("lib.engine.net.util.auto-discover")

local messages = {}

function messages.build(directory, package_prefix)
  directory = directory or "lib/coop/messages"
  package_prefix = package_prefix or "lib.coop.messages."
  local modules = auto_discover.load_all_modules(directory, package_prefix)
  local by_type = {}
  for _, module in pairs(modules) do
    assert(module.type, "co-op message module missing a `type` field")
    assert(not by_type[module.type], "duplicate co-op message type: " .. tostring(module.type))
    by_type[module.type] = module
  end
  return { by_type = by_type, modules = modules }
end

return messages
