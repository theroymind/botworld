-- Filesystem reads that work both under LÖVE (love.filesystem) and headless
-- plain Lua (io). Copied verbatim from botlands as a net-engine util so the
-- registry auto-discovery convention runs the same in both worlds.
local function read_file(path)
  if love and love.filesystem and love.filesystem.read then
    local content = love.filesystem.read(path)
    if content then
      return content
    end
  end

  local file = io.open(path, "r")
  if not file then
    error("Failed to read file: " .. path)
  end
  local content = file:read("*a")
  file:close()
  return content
end

local function list_directory(path)
  if love and love.filesystem and love.filesystem.getDirectoryItems then
    return love.filesystem.getDirectoryItems(path)
  end

  local items = {}
  local handle = io.popen('ls "' .. path .. '" 2>/dev/null')
  if handle then
    for line in handle:lines() do
      table.insert(items, line)
    end
    handle:close()
  end
  return items
end

return {
  read_file = read_file,
  list_directory = list_directory,
}
