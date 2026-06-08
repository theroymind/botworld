-- Wire channels plus the message-name discovery convention. Genericized on copy
-- from botlands: the channels stay (they are generic transport lanes), but the
-- hardcoded botlands message directories are dropped -- a game points `discover`
-- at its own message folder (see lib/coop/messages). This keeps the
-- engine/protocol split honest: same channels, game-specific message set.
local auto_discover = require("lib.engine.net.util.auto-discover")

local function kebab_to_snake(name) return (name:gsub("-", "_")) end

local packet_types = {
  channels = {
    unreliable_input = 0,
    reliable_commands = 1,
    state_stream = 2,
  },
}

-- Map a message directory's kebab-case files to SNAKE_CASE ids,
-- e.g. "niche-construction" -> { niche_construction = "NICHE_CONSTRUCTION" }.
function packet_types.discover(directory)
  local names = {}
  for _, entry in ipairs(auto_discover.list_module_names(directory)) do
    local snake_name = kebab_to_snake(entry)
    assert(not names[snake_name], "duplicate packet name discovered: " .. snake_name)
    names[snake_name] = snake_name:upper()
  end
  return names
end

return packet_types
