-- A player's ambient presence in the shared realm: just where they are. High
-- rate and lossy-friendly, so it rides the unreliable state-stream channel.
local packet_types = require("lib.engine.net.codec.packet-types")

return {
  type = "presence",
  channel = packet_types.channels.state_stream,
  validate = function(message)
    return type(message.x) == "number" and type(message.y) == "number"
  end,
}
