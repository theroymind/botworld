-- Agent connector controller: an OPT-IN, localhost-only JSON-over-TCP server an
-- external agent drives to inspect and mutate game state. Mirrors botlands'
-- tools/automation/controller.lua in SHAPE (bind-with-fallback, settimeout(0),
-- accept + receive('*l') per frame, dispatch {command,params} -> {ok,data}/{ok,error},
-- one async slot for the deferred screenshot), with two botworld changes: it binds
-- 127.0.0.1 (NOT 0.0.0.0) and speaks botworld's vendored JSON codec over a botworld
-- game context (layers + layer modules + screenshot + console + clock), not a
-- client/server.
--
-- Wired by main.lua behind --automation: main parses the flag, calls controller:start()
-- (prints the bound port), controller:set_game_context(...), then controller:update(dt)
-- in love.update and controller:post_draw() in love.draw -- all no-op when the flag is
-- absent (the controller is simply never constructed).
local json = require("lib.engine.json")
local command_handlers = require("tools.automation.command-handlers")

-- Localhost ONLY: never expose the connector off the machine. Named so the bind host
-- is a single, auditable constant (the botworld change vs botlands' 0.0.0.0).
local BIND_HOST = "127.0.0.1"
-- Default listen port; the agent CLI defaults to the same. Walk up from here on a clash.
local DEFAULT_PORT = 19840
-- Try DEFAULT_PORT .. DEFAULT_PORT+MAX_BIND_ATTEMPTS-1 before giving up, so a stale prior
-- run (or a second instance) lands on the next free port instead of failing to launch.
local MAX_BIND_ATTEMPTS = 10
-- Connector protocol version the `capabilities` command reports, so an agent can gate on
-- the contract it was built against. Bump on any breaking request/response shape change.
local PROTOCOL_VERSION = 1
-- Built-in commands handled in the controller itself (not the handlers table), per
-- botlands: capabilities (introspection) + the async screenshot. Listed so capabilities
-- can advertise the full command set.
local BUILT_IN_COMMANDS = { "capabilities", "screenshot" }
-- The async-operation tag for a deferred screenshot, so the slot's type is never an
-- inline string.
local ASYNC_SCREENSHOT = "screenshot"

-- The full command list capabilities advertises: the built-ins plus every handler key,
-- sorted for a stable readout.
local function command_list()
  local commands = {}
  for _, name in ipairs(BUILT_IN_COMMANDS) do
    commands[#commands + 1] = name
  end
  for name in pairs(command_handlers) do
    commands[#commands + 1] = name
  end
  table.sort(commands)
  return commands
end

local function controller()
  local socket = require("socket")

  local server_socket = nil
  local active_connection = nil
  local game_context = nil
  -- The single async slot (mirrors botlands): a deferred screenshot whose success
  -- response is sent once the screenshot module reports it is no longer pending.
  local async_operation = nil
  -- The numeric port actually bound, stashed by start() so capabilities reports a
  -- number (getsockname() returns the port as a STRING, which would ship as a JSON
  -- string and break a numeric-equality check on the agent side).
  local bound_port = DEFAULT_PORT

  local instance = {}

  -- Bind localhost on the first free port in [DEFAULT_PORT, +MAX_BIND_ATTEMPTS),
  -- non-blocking (settimeout(0)). Returns the bound port; errors if all are taken.
  function instance:start()
    for attempt = 0, MAX_BIND_ATTEMPTS - 1 do
      local candidate = DEFAULT_PORT + attempt
      local bound = socket.bind(BIND_HOST, candidate)
      if bound then
        server_socket = bound
        bound_port = candidate
        server_socket:settimeout(0)
        return candidate
      end
      if attempt == MAX_BIND_ATTEMPTS - 1 then
        error(
          "automation: failed to bind "
            .. BIND_HOST
            .. " after "
            .. MAX_BIND_ATTEMPTS
            .. " attempts (from port "
            .. DEFAULT_PORT
            .. ")"
        )
      end
    end
  end

  function instance:stop()
    if active_connection then
      active_connection:close()
      active_connection = nil
    end
    if server_socket then
      server_socket:close()
      server_socket = nil
    end
  end

  -- Store the game context (layers, modules, screenshot, console, clock). Dispatch
  -- passes it to every handler.
  function instance:set_game_context(context) game_context = context end

  local function send_response(connection, ok, data)
    local response
    if ok then
      response = json.encode({ ok = true, data = data })
    else
      response = json.encode({ ok = false, error = tostring(data) })
    end
    connection:send(response .. "\n")
  end

  -- capabilities: protocol version, bound port, the active layer, the command list, and
  -- that screenshots are available. The introspection handshake an agent opens with.
  local function handle_capabilities()
    local active = game_context and game_context.layers and game_context.layers.active_name()
    return true,
      {
        protocol_version = PROTOCOL_VERSION,
        port = bound_port,
        active_layer = active,
        commands = command_list(),
        screenshot_available = true,
      }
  end

  -- screenshot: queue a deferred capture (fired in post_draw, off the fully-rendered
  -- frame) and return the async tag, so update() holds the connection open and replies
  -- once the screenshot module reports it is done. params.path (optional) is written
  -- verbatim; otherwise the module builds a default name.
  local function handle_screenshot(params)
    if not game_context or not game_context.screenshot then
      return false, "screenshot not available"
    end
    local queued = game_context.screenshot.request(params.path)
    if not queued then
      return false, "a screenshot is already in flight"
    end
    return "async", ASYNC_SCREENSHOT
  end

  local function dispatch(command_name, params)
    if command_name == "capabilities" then
      return handle_capabilities()
    elseif command_name == ASYNC_SCREENSHOT then
      return handle_screenshot(params)
    end

    local handler = command_handlers[command_name]
    if not handler then
      return false, "unknown command: " .. tostring(command_name)
    end

    -- ping/keypressed/quit need no game context (liveness + raw input + shutdown work
    -- even before the context is wired); everything else does.
    if
      not game_context
      and command_name ~= "ping"
      and command_name ~= "keypressed"
      and command_name ~= "quit"
    then
      return false, "game context not ready"
    end

    return handler(game_context, params)
  end

  -- Per-frame pump: drain the async screenshot slot first (reply once the capture has
  -- fired), else accept a connection, read one line, decode + dispatch, and reply.
  function instance:update(_)
    if async_operation then
      if async_operation.type == ASYNC_SCREENSHOT then
        local busy = game_context
          and game_context.screenshot
          and game_context.screenshot.is_pending()
        if not busy then
          if async_operation.connection then
            send_response(async_operation.connection, true, {
              captured = true,
              path = game_context
                and game_context.screenshot
                and game_context.screenshot.last_path(),
            })
            async_operation.connection:close()
          end
          async_operation = nil
        end
      end
      return
    end

    if not server_socket then
      return
    end

    if not active_connection then
      local new_connection = server_socket:accept()
      if new_connection then
        new_connection:settimeout(0)
        active_connection = new_connection
      end
    end

    if not active_connection then
      return
    end

    local line, receive_error = active_connection:receive("*l")
    if not line then
      if receive_error == "timeout" then
        return
      end
      active_connection:close()
      active_connection = nil
      return
    end

    local parse_ok, message = pcall(json.decode, line)
    if not parse_ok or type(message) ~= "table" then
      send_response(active_connection, false, "invalid JSON")
      active_connection:close()
      active_connection = nil
      return
    end

    local ok, data = dispatch(message.command, message.params or {})

    -- A screenshot defers: hold the connection in the async slot and reply later.
    if ok == "async" then
      async_operation = { type = data, connection = active_connection }
      active_connection = nil
      return
    end

    send_response(active_connection, ok, data)
    active_connection:close()
    active_connection = nil
  end

  -- Fire any queued screenshot AFTER the frame (so the capture is of the rendered
  -- frame). main.lua calls this at the end of love.draw.
  function instance:post_draw()
    if game_context and game_context.screenshot then
      game_context.screenshot.post_draw()
    end
  end

  return instance
end

return controller
