-- Child lists may legitimately contain nils: nodes like icon_node and
-- count_badge_node return nil to mean "absent". A raw ipairs over such a list
-- stops at the first hole and silently drops every later sibling, so every stack
-- compacts its children at construction time. The pairs sweep finds the true
-- extent of the list even across holes, where # (and ipairs) is unreliable.
local function compact_children(children)
  local compacted = {}
  if not children then
    return compacted
  end
  local max_index = 0
  for key in pairs(children) do
    if type(key) == "number" and key > max_index then
      max_index = key
    end
  end
  for index = 1, max_index do
    local child = children[index]
    if child ~= nil then
      table.insert(compacted, child)
    end
  end
  return compacted
end

return compact_children
