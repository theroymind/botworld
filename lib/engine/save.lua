-- Tiny save persistence: plain tables (string/number keys; number, string,
-- boolean, table values) serialize to a Lua literal and back. Files go
-- through love.filesystem so saves land in the platform save directory
-- (conf.lua's t.identity). Reads sandbox the chunk (empty env + pcall) and
-- return nil on any failure, so a corrupt save reads as "no save".
local save = {}

local function serialize(value, out)
  local kind = type(value)
  if kind == "number" then
    out[#out + 1] = string.format("%.17g", value)
  elseif kind == "string" then
    out[#out + 1] = string.format("%q", value)
  elseif kind == "boolean" then
    out[#out + 1] = tostring(value)
  elseif kind == "table" then
    out[#out + 1] = "{"
    for key, item in pairs(value) do
      local key_kind = type(key)
      if key_kind == "string" then
        out[#out + 1] = "[" .. string.format("%q", key) .. "]="
      elseif key_kind == "number" then
        out[#out + 1] = "[" .. string.format("%.17g", key) .. "]="
      else
        error("unsupported key type: " .. key_kind)
      end
      serialize(item, out)
      out[#out + 1] = ","
    end
    out[#out + 1] = "}"
  else
    error("unsupported value type: " .. kind)
  end
end

local function filename(name) return name .. ".lua" end

-- Serialize tbl and write it to <name>.lua in the save directory.
function save.write(name, tbl)
  local out = { "return " }
  serialize(tbl, out)
  return love.filesystem.write(filename(name), table.concat(out))
end

-- Read <name>.lua back into a table, or nil if missing/corrupt.
function save.read(name)
  local contents = love.filesystem.read(filename(name))
  if not contents then
    return nil
  end
  local chunk = loadstring(contents)
  if not chunk then
    return nil
  end
  setfenv(chunk, {})
  local ok, result = pcall(chunk)
  if ok and type(result) == "table" then
    return result
  end
  return nil
end

-- Delete <name>.lua; returns true if a file was removed.
function save.remove(name) return love.filesystem.remove(filename(name)) end

return save
