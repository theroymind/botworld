-- Steam P2P transport (luasteam networking sockets). Same server/client event
-- shape as the other transports. Copied from botlands; only require paths
-- changed to the net-engine namespace.
local serializer = require("lib.engine.net.codec.serializer")
local steam_availability = require("lib.engine.net.transport.steam-availability")

local SEND_UNRELIABLE = 0
local SEND_RELIABLE = 8

local steam_transport = {}

function steam_transport.create_server(_config)
  _config = _config or {}
  local steam = steam_availability.get_steam()
  assert(steam, "Steam not available")

  local listen_socket = steam.networkingSockets.createListenSocketP2P(0, {})
  local poll_group = steam.networkingSockets.createPollGroup()

  local next_id = 0
  local conn_to_id = {}
  local id_to_conn = {}

  local pending_events = {}

  steam.networkingSockets.setStatusCallback(function(info)
    if info.new_state == "connected" then
      next_id = next_id + 1
      local client_id = "steam-" .. next_id
      conn_to_id[info.connection] = client_id
      id_to_conn[client_id] = info.connection
      steam.networkingSockets.setConnectionPollGroup(info.connection, poll_group)
      table.insert(pending_events, { type = "connect", client_id = client_id })
    elseif info.new_state == "closed_by_peer" or info.new_state == "problem_detected" then
      local client_id = conn_to_id[info.connection]
      if client_id then
        conn_to_id[info.connection] = nil
        id_to_conn[client_id] = nil
        table.insert(pending_events, { type = "disconnect", client_id = client_id })
      end
      steam.networkingSockets.closeConnection(info.connection, 0, "", false)
    end
  end)

  local server = {}

  function server:poll()
    local events = {}
    for _, event in ipairs(pending_events) do
      table.insert(events, event)
    end
    pending_events = {}

    local messages = steam.networkingSockets.receiveMessagesOnPollGroup(poll_group, 64)
    for _, msg in ipairs(messages or {}) do
      local client_id = conn_to_id[msg.connection]
      if client_id then
        local payload = serializer.decode(msg.data)
        if payload then
          table.insert(events, {
            type = "message",
            client_id = client_id,
            channel = msg.channel,
            payload = payload,
          })
        end
      end
    end
    return events
  end

  function server:send(client_id, channel, payload)
    assert(client_id, "server:send requires client_id")
    assert(channel, "server:send requires channel")
    assert(payload ~= nil, "server:send requires payload")
    local conn = id_to_conn[client_id]
    if not conn then
      return false
    end
    local data = serializer.encode(payload)
    local flags = channel == 0 and SEND_UNRELIABLE or SEND_RELIABLE
    steam.networkingSockets.sendMessageToConnection(conn, data, flags, channel)
    return true
  end

  function server:broadcast(channel, payload)
    assert(channel, "server:broadcast requires channel")
    assert(payload ~= nil, "server:broadcast requires payload")
    local data = serializer.encode(payload)
    local flags = channel == 0 and SEND_UNRELIABLE or SEND_RELIABLE
    for _, conn in pairs(id_to_conn) do
      steam.networkingSockets.sendMessageToConnection(conn, data, flags, channel)
    end
  end

  function server:destroy()
    for _, conn in pairs(id_to_conn) do
      steam.networkingSockets.closeConnection(conn, 0, "", false)
    end
    conn_to_id = {}
    id_to_conn = {}
    steam.networkingSockets.destroyPollGroup(poll_group)
    steam.networkingSockets.closeListenSocket(listen_socket)
  end

  return server
end

function steam_transport.create_client(config)
  config = config or {}
  local steam = steam_availability.get_steam()
  assert(steam, "Steam not available")

  local host_steam_id = config.steam_id
  assert(host_steam_id, "steam_id is required to connect")

  local connection = steam.networkingSockets.connectP2P(host_steam_id, 0, {})
  local connected = false

  local pending_events = {}

  steam.networkingSockets.setStatusCallback(function(info)
    if info.connection == connection then
      if info.new_state == "connected" then
        connected = true
      elseif info.new_state == "closed_by_peer" or info.new_state == "problem_detected" then
        connected = false
      end
    end
  end)

  local client = {}

  function client:poll()
    local events = {}
    for _, event in ipairs(pending_events) do
      table.insert(events, event)
    end
    pending_events = {}

    local messages = steam.networkingSockets.receiveMessagesOnConnection(connection, 64)
    for _, msg in ipairs(messages or {}) do
      local payload = serializer.decode(msg.data)
      if payload then
        table.insert(events, {
          type = "message",
          channel = msg.channel,
          payload = payload,
        })
      end
    end
    return events
  end

  function client:send(channel, payload)
    assert(channel, "client:send requires channel")
    assert(payload ~= nil, "client:send requires payload")
    local data = serializer.encode(payload)
    local flags = channel == 0 and SEND_UNRELIABLE or SEND_RELIABLE
    steam.networkingSockets.sendMessageToConnection(connection, data, flags, channel)
  end

  function client:disconnect()
    if connected then
      steam.networkingSockets.closeConnection(connection, 0, "", false)
      connected = false
    end
  end

  function client:destroy() self:disconnect() end

  function client:is_connected() return connected end

  function client:get_round_trip_time()
    local info = steam.networkingSockets.getConnectionRealTimeStatus(connection)
    if info and info.ping then
      return info.ping
    end
    return 0
  end

  return client
end

return steam_transport
