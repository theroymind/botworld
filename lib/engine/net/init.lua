-- The net engine's opt-in seam. A co-op layer composes this; solo botworld never
-- requires it, so main.lua and the default play path stay untouched. Mirrors
-- botworld's economy.new / instance-method composition style: net.new(config)
-- builds one connection wrapping a transport endpoint; the transport table,
-- codec, config, and sync helpers are exposed for a game to assemble its own
-- co-op stack.
--
-- Example (loopback, two in-process sides over one shared hub):
--   local net = require("lib.engine.net")
--   local hub = net.transport.loopback()
--   local server = net.new({ endpoint = hub.server, role = "server",
--                            messages = registry, on_recv = handle })
--   local client = net.new({ endpoint = hub:create_client("c1"), role = "client",
--                            messages = registry, on_recv = handle,
--                            step = function(state, input, dt) ... end })
--   client:send({ type = "presence", x = 3, y = 4 })
--   server:poll(dt)
--
-- enet / steam build their endpoint from the transport + role instead:
--   net.new({ transport = net.transport.enet, role = "server", options = { port = 1234 } })
local net = {}

net.transport = {
  loopback = require("lib.engine.net.transport.loopback"),
  enet = require("lib.engine.net.transport.enet"),
  steam = require("lib.engine.net.transport.steam"),
  steam_lobby = require("lib.engine.net.transport.steam-lobby"),
  steam_availability = require("lib.engine.net.transport.steam-availability"),
}

net.codec = {
  packet = require("lib.engine.net.codec.packet"),
  serializer = require("lib.engine.net.codec.serializer"),
  packet_types = require("lib.engine.net.codec.packet-types"),
}

net.config = {
  net_config = require("lib.engine.net.config.net-config"),
  input_history = require("lib.engine.net.config.input-history"),
}

net.sync = {
  interpolator = require("lib.engine.net.sync.entity-interpolator"),
  reconciliation = require("lib.engine.net.sync.server-reconciliation"),
  prediction = require("lib.engine.net.sync.client-prediction"),
  replica = require("lib.engine.net.sync.replica-entity"),
  stats = require("lib.engine.net.sync.net-stats"),
}

net.channels = net.codec.packet_types.channels

-- Build a transport endpoint from a transport module + role when one is not
-- supplied directly. Loopback is the exception: its single hub hosts both sides
-- in-process, so loopback callers pass a pre-built endpoint (hub.server or
-- hub:create_client(id)) rather than going through here.
local function build_endpoint(config)
  if config.endpoint then
    return config.endpoint
  end
  local transport = assert(config.transport, "net.new requires a `transport` or an `endpoint`")
  if config.role == "server" then
    assert(transport.create_server, "transport has no create_server; pass `endpoint` for loopback")
    return transport.create_server(config.options)
  end
  assert(transport.create_client, "transport has no create_client; pass `endpoint` for loopback")
  return transport.create_client(config.options)
end

function net.new(config)
  config = config or {}
  local role = config.role or "client"
  local registry = config.messages
  local on_recv = config.on_recv or function() end
  local on_connect = config.on_connect or function() end
  local on_disconnect = config.on_disconnect or function() end

  local endpoint = build_endpoint(config)

  -- Channel for a message: the registry's per-message channel, else reliable.
  local function channel_for(message)
    local desc = registry and registry.by_type and registry.by_type[message.type]
    if desc and desc.channel then
      return desc.channel
    end
    return net.channels.reliable_commands
  end

  local conn = { role = role, endpoint = endpoint }

  -- Optional prediction, wired from the injected game step. Exposed as
  -- conn.prediction and advanced once per poll.
  if config.step then
    conn.prediction = net.sync.prediction({
      step = config.step,
      smoothing_rate = config.smoothing_rate,
    })
  end

  -- Drain transport events: validate messages against the registry (if the
  -- message declares a validate), dispatch to on_recv with the sender id (nil on
  -- a client), and fire connect/disconnect. Advances prediction by dt last.
  function conn:poll(dt)
    local events = endpoint:poll()
    for _, ev in ipairs(events) do
      if ev.type == "message" then
        local message = ev.payload
        local desc = registry and registry.by_type and registry.by_type[message.type]
        local ok = true
        if desc and desc.validate then
          ok = desc.validate(message)
        end
        if ok then
          on_recv(message, ev.client_id)
        end
      elseif ev.type == "connect" then
        on_connect(ev.client_id)
      elseif ev.type == "disconnect" then
        on_disconnect(ev.client_id)
      end
    end
    if self.prediction and dt then
      self.prediction.update(dt)
    end
    return events
  end

  -- Client send: (message). Channel is resolved from the registry.
  function conn:send(message)
    assert(role ~= "server", "server connections use conn:send_to / conn:broadcast")
    return endpoint:send(channel_for(message), message)
  end

  -- Server sends.
  function conn:send_to(client_id, message)
    assert(role == "server", "conn:send_to is server-only")
    return endpoint:send(client_id, channel_for(message), message)
  end

  function conn:broadcast(message)
    assert(role == "server", "conn:broadcast is server-only")
    return endpoint:broadcast(channel_for(message), message)
  end

  function conn:is_connected()
    if endpoint.is_connected then
      return endpoint:is_connected()
    end
    return true
  end

  function conn:round_trip_time()
    if endpoint.get_round_trip_time then
      return endpoint:get_round_trip_time()
    end
    return 0
  end

  function conn:disconnect()
    if endpoint.disconnect then
      endpoint:disconnect()
    end
  end

  function conn:destroy()
    if endpoint.destroy then
      endpoint:destroy()
    end
  end

  return conn
end

return net
