-- Agent connector CLI: a tiny standalone client that sends ONE JSON command line to
-- the running game's connector and prints the response line. Run with the bare `lua`
-- interpreter (NOT inside love), e.g.:
--
--   lua tools/automation/cli.lua query_state
--   lua tools/automation/cli.lua set_trait --id motility --value 5
--   lua tools/automation/cli.lua step --count 10 --port 19841
--
-- Mirrors botlands' tools/automation/cli.lua: parse a command + --key value params (+
-- --host/--port), connect, send, print, exit. It uses an INLINE JSON encoder (not
-- lib.engine.json) so it never depends on package.path resolving the engine module when
-- launched as a loose script -- the request shapes are trivial, so a self-contained
-- encoder is the simplest thing that works.
local socket = require("socket")

-- Localhost + the controller's DEFAULT_PORT: the connector binds here, so the CLI
-- targets the same by default. Override with --host / --port.
local DEFAULT_HOST = "127.0.0.1"
local DEFAULT_PORT = 19840
-- Seconds to wait for the single response line before giving up (a step/screenshot can
-- take a beat; 30s is generous and matches botlands' CLI).
local RECEIVE_TIMEOUT = 30

local function parse_arguments(arguments)
  local command_name = arguments[1]
  if not command_name then
    io.stderr:write("Usage: lua tools/automation/cli.lua <command> [--key value ...] [--port N]\n")
    os.exit(1)
  end

  local params = {}
  local host = DEFAULT_HOST
  local port = DEFAULT_PORT

  local index = 2
  while index <= #arguments do
    local key = arguments[index]
    if key == "--host" then
      host = arguments[index + 1]
      index = index + 2
    elseif key == "--port" then
      port = tonumber(arguments[index + 1])
      index = index + 2
    elseif key:match("^%-%-") then
      local param_name = key:sub(3)
      local value = arguments[index + 1]
      local numeric_value = tonumber(value)
      if numeric_value then
        params[param_name] = numeric_value
      elseif value == "true" then
        params[param_name] = true
      elseif value == "false" then
        params[param_name] = false
      else
        params[param_name] = value
      end
      index = index + 2
    else
      index = index + 1
    end
  end

  return command_name, params, host, port
end

-- Minimal inline JSON encoder for the request object. Covers exactly the value kinds a
-- CLI param can be (nil/boolean/number/string) plus the nested params table; a table
-- with no positive-integer keys (or empty) encodes as an object, otherwise an array.
local encode_json
encode_json = function(value)
  local kind = type(value)
  if kind == "nil" then
    return "null"
  elseif kind == "boolean" then
    return tostring(value)
  elseif kind == "number" then
    return string.format("%.14g", value)
  elseif kind == "string" then
    return '"'
      .. value:gsub('[\\"]', "\\%0"):gsub("\n", "\\n"):gsub("\r", "\\r"):gsub("\t", "\\t")
      .. '"'
  elseif kind == "table" then
    local is_array = #value > 0
    if is_array then
      local parts = {}
      for _, item in ipairs(value) do
        parts[#parts + 1] = encode_json(item)
      end
      return "[" .. table.concat(parts, ",") .. "]"
    end
    local parts = {}
    for k, item in pairs(value) do
      parts[#parts + 1] = encode_json(tostring(k)) .. ":" .. encode_json(item)
    end
    return "{" .. table.concat(parts, ",") .. "}"
  end
  return "null"
end

local function main()
  local command_name, params, host, port = parse_arguments(arg)

  local connection, connection_error = socket.connect(host, port)
  if not connection then
    io.stderr:write(
      string.format("Failed to connect to %s:%s: %s\n", host, port, tostring(connection_error))
    )
    os.exit(1)
  end

  connection:settimeout(RECEIVE_TIMEOUT)

  local encoded = encode_json({ command = command_name, params = params })
  local _, send_error = connection:send(encoded .. "\n")
  if send_error then
    io.stderr:write("Failed to send command: " .. tostring(send_error) .. "\n")
    connection:close()
    os.exit(1)
  end

  local response, receive_error = connection:receive("*l")
  if not response then
    io.stderr:write("Failed to receive response: " .. tostring(receive_error) .. "\n")
    connection:close()
    os.exit(1)
  end

  print(response)
  connection:close()
end

main()
