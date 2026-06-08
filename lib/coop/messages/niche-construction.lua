-- A durable change a player makes to the shared environment (niche construction)
-- -- terraforming the realm for everyone. Reliable; carries a position and a tag
-- for what changed. Its kebab-case filename maps to the snake_case type
-- "niche_construction" via the discovery convention.
local packet_types = require("lib.engine.net.codec.packet-types")

return {
  type = "niche_construction",
  channel = packet_types.channels.reliable_commands,
  validate = function(message)
    return type(message.x) == "number"
      and type(message.y) == "number"
      and type(message.change) == "string"
  end,
}
