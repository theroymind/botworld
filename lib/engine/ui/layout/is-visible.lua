local function is_visible(node)
  local v = node.visible
  if type(v) == "function" then
    return v()
  end
  return v ~= false
end

return is_visible
