-- Ring-ish buffer of recent local inputs, kept so client prediction can replay
-- the unacknowledged tail against a fresh server position (reconciliation).
-- Copied verbatim from botlands -- zero requires, fully generic.
local MAX_ENTRIES = 128

local function input_history()
  local entries = {}

  local history = {}

  function history.record(entry)
    entries[#entries + 1] = entry
    if #entries > MAX_ENTRIES then
      local trimmed = {}
      local start = #entries - MAX_ENTRIES + 1
      for i = start, #entries do
        trimmed[#trimmed + 1] = entries[i]
      end
      entries = trimmed
    end
  end

  function history.discard_through(input_tick)
    local kept = {}
    for i = 1, #entries do
      if entries[i].input_tick > input_tick then
        kept[#kept + 1] = entries[i]
      end
    end
    entries = kept
  end

  function history.get_unacknowledged()
    local result = {}
    for i = 1, #entries do
      result[i] = entries[i]
    end
    return result
  end

  function history.clear() entries = {} end

  function history.count() return #entries end

  return history
end

return input_history
