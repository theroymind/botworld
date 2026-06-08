-- ENet (UDP) transport for LÖVE. Same server/client event shape as the other
-- transports. Copied from botlands; require paths changed to the net-engine
-- namespace and botlands' client.debug.debug-logging swapped for the generic
-- no-op logger seam (util/logger). `enet` is provided by LÖVE at runtime, so
-- this transport is not headless-testable under plain Lua.
local net_config = require("lib.engine.net.config.net-config")
local serializer = require("lib.engine.net.codec.serializer")
local logger = require("lib.engine.net.util.logger")

local CHANNEL_FLAGS = {
  [0] = "unsequenced",
  [1] = "reliable",
  [2] = "reliable",
}

local enet_transport = {}

function enet_transport.create_server(config)
  config = config or {}
  local enet = require("enet")
  local port = config.port or net_config.defaults.port
  local max_peers = config.max_peers or 8
  local host = enet.host_create("*:" .. port, max_peers, 3)

  local next_id = 0
  local peer_to_id = {}
  local id_to_peer = {}

  local server = {}

  function server:poll()
    local events = {}
    while true do
      local event = host:service(0)
      if not event then
        break
      end

      if event.type == "connect" then
        next_id = next_id + 1
        local client_id = "enet-" .. next_id
        peer_to_id[event.peer] = client_id
        id_to_peer[client_id] = event.peer
        table.insert(events, { type = "connect", client_id = client_id })
      elseif event.type == "disconnect" then
        local client_id = peer_to_id[event.peer]
        if client_id then
          peer_to_id[event.peer] = nil
          id_to_peer[client_id] = nil
          table.insert(events, { type = "disconnect", client_id = client_id })
        end
      elseif event.type == "receive" then
        local client_id = peer_to_id[event.peer]
        if client_id then
          local payload = serializer.decode(event.data)
          if payload then
            table.insert(events, {
              type = "message",
              client_id = client_id,
              channel = event.channel,
              payload = payload,
            })
          end
        end
      end
    end
    return events
  end

  function server:send(client_id, channel, payload)
    local peer = id_to_peer[client_id]
    if not peer then
      return false
    end
    local data = serializer.encode(payload)
    local flag = CHANNEL_FLAGS[channel] or "reliable"
    peer:send(data, channel, flag)
    return true
  end

  function server:broadcast(channel, payload)
    for client_id in pairs(id_to_peer) do
      self:send(client_id, channel, payload)
    end
  end

  function server:destroy() host:destroy() end

  return server
end

function enet_transport.create_client(config)
  config = config or {}
  local enet = require("enet")
  local target_host = config.host or "localhost"
  local port = config.port or net_config.defaults.port
  local address
  if target_host:find(":") then
    address = target_host
  else
    address = target_host .. ":" .. port
  end
  local host = enet.host_create()
  local peer = host:connect(address, 3)
  local connected = false

  local client = {}

  function client:poll()
    local events = {}
    while true do
      local event = host:service(0)
      if not event then
        break
      end

      if event.type == "connect" then
        connected = true
      elseif event.type == "disconnect" then
        connected = false
      elseif event.type == "receive" then
        local raw_bytes = #event.data
        local payload = serializer.decode(event.data)
        if payload then
          logger.debug("enet recv", payload.type, event.channel, raw_bytes)
          table.insert(events, {
            type = "message",
            channel = event.channel,
            payload = payload,
          })
        end
      end
    end
    return events
  end

  function client:send(channel, payload)
    local data = serializer.encode(payload)
    local flag = CHANNEL_FLAGS[channel] or "reliable"
    logger.debug("enet send", payload.type, channel, #data)
    peer:send(data, channel, flag)
  end

  function client:disconnect()
    peer:disconnect()
    host:flush()
  end

  function client:destroy() host:destroy() end

  function client:is_connected() return connected end

  function client:get_round_trip_time() return peer:round_trip_time() end

  return client
end

return enet_transport
