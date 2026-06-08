-- Engine-wide networking defaults (tick rate, player cap, compression, port).
-- Copied verbatim from botlands. A game can override these per net.new call.
local net_config = {
  version = 1,
  defaults = {
    tick_rate = 20,
    max_players = 8,
    compression = "zlib",
    port = 1234,
  },
}

return net_config
