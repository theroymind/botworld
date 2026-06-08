-- In-process transport: a single hub hosts the server and any number of client
-- handles, delivering message tables by reference (no serialization). Ideal for
-- tests and single-process co-op. The factory returns a hub with `.server` and
-- `:create_client(id)`. Copied verbatim from botlands -- zero requires.
local EVENT_MESSAGE = "message"
local EVENT_CONNECT = "connect"
local EVENT_DISCONNECT = "disconnect"

local function loopback_transport()
  local state = {
    clients = {},
    server_events = {},
  }

  local transport = {
    server = {},
  }

  function transport.server:poll()
    local events = state.server_events
    state.server_events = {}
    return events
  end

  function transport.server:send(client_id, channel, payload)
    local client_entry = state.clients[client_id]
    if not client_entry then
      return false
    end

    table.insert(client_entry.inbox, {
      type = EVENT_MESSAGE,
      channel = channel,
      payload = payload,
    })
    return true
  end

  function transport.server:broadcast(channel, payload)
    for client_id in pairs(state.clients) do
      self:send(client_id, channel, payload)
    end
  end

  function transport.server:destroy() end

  function transport:create_client(client_id)
    if state.clients[client_id] then
      return state.clients[client_id].handle
    end

    local client_entry = {
      inbox = {},
    }
    local handle = {}

    function handle:send(channel, payload)
      table.insert(state.server_events, {
        type = EVENT_MESSAGE,
        client_id = client_id,
        channel = channel,
        payload = payload,
      })
    end

    function handle:poll()
      local events = client_entry.inbox
      client_entry.inbox = {}
      return events
    end

    function handle:disconnect()
      if not state.clients[client_id] then
        return false
      end

      state.clients[client_id] = nil
      table.insert(state.server_events, {
        type = EVENT_DISCONNECT,
        client_id = client_id,
      })
      return true
    end

    function handle:get_round_trip_time() return 0 end

    function handle:is_connected() return state.clients[client_id] ~= nil end

    function handle:destroy() end

    client_entry.handle = handle
    state.clients[client_id] = client_entry
    table.insert(state.server_events, {
      type = EVENT_CONNECT,
      client_id = client_id,
    })

    return handle
  end

  return transport
end

return loopback_transport
