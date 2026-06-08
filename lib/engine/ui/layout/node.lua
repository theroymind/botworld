local function node(config)
  local cfg = config or {}
  return {
    type = "node",
    nav = cfg.nav,
    h = cfg.h or 0,
    w = cfg.w or "fill",
    visible = cfg.visible,
    focusable = cfg.focusable,
    draw_fn = cfg.draw_fn,
    on_click = cfg.on_click,
    on_hover = cfg.on_hover,
    resolved_rect = nil,
  }
end

return node
