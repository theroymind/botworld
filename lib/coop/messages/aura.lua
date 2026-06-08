-- A passive influence a player radiates into the shared field -- the ambient
-- co-op synergy. Reliable: a dropped aura change would desync everyone's field.
local packet_types = require("lib.engine.net.codec.packet-types")

return {
  type = "aura",
  channel = packet_types.channels.reliable_commands,
  validate = function(message)
    return type(message.kind) == "string" and type(message.strength) == "number"
  end,
}
