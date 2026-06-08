-- Table <-> Lua-source serializer: deterministic encode (sorted keys) and a
-- sandboxed decode (empty env, no globals reachable). The transports use this to
-- put message tables on the wire. Copied verbatim from botlands.
local serializer = {}

local function serialize_value(value, indent)
  local value_type = type(value)

  if value_type == "string" then
    return string.format("%q", value)
  end

  if value_type == "number" or value_type == "boolean" then
    return tostring(value)
  end

  if value_type == "table" then
    return serializer.encode_table(value, indent)
  end

  return "nil"
end

function serializer.encode_table(tbl, indent)
  indent = indent or 0
  local pad = string.rep("  ", indent + 1)
  local close_pad = string.rep("  ", indent)
  local parts = {}

  local array_len = #tbl
  for i = 1, array_len do
    table.insert(parts, pad .. serialize_value(tbl[i], indent + 1))
  end

  local sorted_keys = {}
  for key in pairs(tbl) do
    if type(key) == "string" then
      table.insert(sorted_keys, key)
    elseif type(key) == "number" and (key < 1 or key > array_len or key ~= math.floor(key)) then
      table.insert(sorted_keys, key)
    end
  end

  table.sort(sorted_keys, function(a, b) return tostring(a) < tostring(b) end)

  for _, key in ipairs(sorted_keys) do
    local key_string
    if type(key) == "string" and key:match("^[%a_][%w_]*$") then
      key_string = key
    else
      key_string = "[" .. serialize_value(key, indent + 1) .. "]"
    end

    table.insert(parts, pad .. key_string .. " = " .. serialize_value(tbl[key], indent + 1))
  end

  if #parts == 0 then
    return "{}"
  end

  return "{\n" .. table.concat(parts, ",\n") .. ",\n" .. close_pad .. "}"
end

function serializer.encode(value) return "return " .. serialize_value(value, 0) .. "\n" end

function serializer.decode(serialized)
  local chunk = (loadstring or load)(serialized)
  if not chunk then
    return nil, "decode failed"
  end

  if setfenv then
    setfenv(chunk, {})
  end

  local ok, data = pcall(chunk)
  if not ok then
    return nil, data
  end

  return data
end

return serializer
