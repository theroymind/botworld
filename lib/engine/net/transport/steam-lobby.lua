-- Steam matchmaking lobby helpers (create/find/join, host steam-id exchange).
-- Copied from botlands; require paths changed to the net-engine namespace and
-- the lobby's game tag set to "botworld". Steam callbacks (on_lobby_*) are
-- driven by the host application's Steam callback pump.
local steam_availability = require("lib.engine.net.transport.steam-availability")
local net_config = require("lib.engine.net.config.net-config")

local LOBBY_GAME_TAG = "botworld"

local steam_lobby = {}

local current_lobby = nil
local pending_create_callback = nil
local pending_find_callback = nil
local pending_join_callback = nil

function steam_lobby.create_lobby(max_players, callback)
  assert(callback, "steam_lobby.create_lobby requires a callback")
  local steam = steam_availability.get_steam()
  assert(steam, "Steam not available")

  pending_create_callback = callback
  local player_limit = max_players or net_config.defaults.max_players
  steam.matchmaking.createLobby("friendsonly", player_limit)
end

function steam_lobby.on_lobby_created(lobby_id)
  current_lobby = lobby_id

  local steam = steam_availability.get_steam()
  if steam and lobby_id then
    steam.matchmaking.setLobbyData(lobby_id, "game", LOBBY_GAME_TAG)
    steam.matchmaking.setLobbyData(lobby_id, "version", tostring(net_config.version))
    local own_id = steam.user.getSteamID()
    steam.matchmaking.setLobbyData(lobby_id, "host_steam_id", tostring(own_id))
  end

  if pending_create_callback then
    local cb = pending_create_callback
    pending_create_callback = nil
    cb(lobby_id ~= nil, lobby_id)
  end
end

function steam_lobby.find_lobbies(callback)
  assert(callback, "steam_lobby.find_lobbies requires a callback")
  local steam = steam_availability.get_steam()
  assert(steam, "Steam not available")

  pending_find_callback = callback
  steam.matchmaking.addRequestLobbyListStringFilter("game", LOBBY_GAME_TAG, "equal")
  steam.matchmaking.requestLobbyList()
end

function steam_lobby.on_lobby_list(lobby_ids)
  local steam = steam_availability.get_steam()
  local lobbies = {}

  if steam and lobby_ids then
    for _, lobby_id in ipairs(lobby_ids) do
      local host_name = steam.matchmaking.getLobbyData(lobby_id, "host_name") or "Unknown"
      local player_count = steam.matchmaking.getNumLobbyMembers(lobby_id) or 0
      local max_players = steam.matchmaking.getLobbyMemberLimit(lobby_id) or 0
      lobbies[#lobbies + 1] = {
        lobby_id = lobby_id,
        host_name = host_name,
        player_count = player_count,
        max_players = max_players,
      }
    end
  end

  if pending_find_callback then
    local cb = pending_find_callback
    pending_find_callback = nil
    cb(lobbies)
  end
end

function steam_lobby.join_lobby(lobby_id, callback)
  assert(lobby_id, "steam_lobby.join_lobby requires a lobby_id")
  assert(callback, "steam_lobby.join_lobby requires a callback")
  local steam = steam_availability.get_steam()
  assert(steam, "Steam not available")

  pending_join_callback = callback
  steam.matchmaking.joinLobby(lobby_id)
end

function steam_lobby.on_lobby_joined(lobby_id, success)
  if success then
    current_lobby = lobby_id
  end

  local host_steam_id = nil
  if success and lobby_id then
    local steam = steam_availability.get_steam()
    if steam then
      host_steam_id = steam.matchmaking.getLobbyData(lobby_id, "host_steam_id")
    end
  end

  if pending_join_callback then
    local cb = pending_join_callback
    pending_join_callback = nil
    cb(success, host_steam_id)
  end
end

function steam_lobby.get_host_steam_id()
  if not current_lobby then
    return nil
  end
  local steam = steam_availability.get_steam()
  if not steam then
    return nil
  end
  return steam.matchmaking.getLobbyData(current_lobby, "host_steam_id")
end

function steam_lobby.get_current_lobby() return current_lobby end

function steam_lobby.leave_lobby()
  if current_lobby then
    local steam = steam_availability.get_steam()
    if steam then
      steam.matchmaking.leaveLobby(current_lobby)
    end
    current_lobby = nil
  end
end

function steam_lobby.reset()
  current_lobby = nil
  pending_create_callback = nil
  pending_find_callback = nil
  pending_join_callback = nil
end

return steam_lobby
