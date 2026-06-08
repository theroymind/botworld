-- Lazy, optional Steam (luasteam) probe. Everything degrades gracefully when
-- Steam is absent, so the engine stays usable without it. Copied verbatim from
-- botlands -- zero requires.
local steam_availability = {}

local steam = nil
local initialized = false

function steam_availability.try_init()
  if initialized then
    return
  end
  initialized = true

  local ok, luasteam = pcall(require, "luasteam")
  if not ok then
    return
  end

  local init_ok = luasteam.init()
  if not init_ok then
    return
  end

  steam = luasteam
end

function steam_availability.is_available() return steam ~= nil end

function steam_availability.get_steam() return steam end

function steam_availability.run_callbacks()
  if steam then
    steam.runCallbacks()
  end
end

function steam_availability.shutdown()
  if steam then
    steam.shutdown()
    steam = nil
  end
end

function steam_availability.reset()
  steam = nil
  initialized = false
end

return steam_availability
