local function zstack(children, config)
  local cfg = config or {}
  local filtered = {}
  for _, child in ipairs(children or {}) do
    if child ~= nil then
      table.insert(filtered, child)
    end
  end
  return {
    type = "zstack",
    w = cfg.w or "fill",
    h = cfg.h or "content",
    visible = cfg.visible,
    on_click = cfg.on_click,
    on_right_click = cfg.on_right_click,
    on_hover = cfg.on_hover,
    children = filtered,
    resolved_rect = nil,
  }
end

return zstack
