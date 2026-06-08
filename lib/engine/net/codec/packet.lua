-- Versioned, optionally-compressed packet envelope around a serialized payload.
-- Compression is LÖVE-guarded (love.data.compress), so headless runs encode with
-- compression "none" and still round-trip. Copied from botlands; only require
-- paths changed to the net-engine namespace.
local net_config = require("lib.engine.net.config.net-config")
local serializer = require("lib.engine.net.codec.serializer")

local packet = {}

function packet.encode(payload)
  local serialized = serializer.encode(payload)
  local compression = "none"
  local body = serialized

  if love and love.data and love.data.compress then
    body = love.data.compress("string", net_config.defaults.compression, serialized)
    compression = net_config.defaults.compression
  end

  return {
    version = net_config.version,
    compression = compression,
    body = body,
  }
end

function packet.decode(raw)
  if type(raw) ~= "table" or type(raw.body) ~= "string" then
    return nil, "invalid packet"
  end

  local serialized = raw.body
  if raw.compression and raw.compression ~= "none" then
    if not (love and love.data and love.data.decompress) then
      return nil, "decompression unavailable"
    end
    serialized = love.data.decompress("string", raw.compression, serialized)
  end

  return serializer.decode(serialized)
end

return packet
