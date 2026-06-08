local theme = require("lib.engine.ui.theme")

local function hstack(children, config)
  local cfg = config or {}
  return {
    type = "hstack",
    nav = cfg.nav,
    gap = cfg.gap or theme.spacing.md,
    padding = cfg.padding or 0,
    w = cfg.w or "fill",
    h = cfg.h or "content",
    visible = cfg.visible,
    bg = cfg.bg,
    on_click = cfg.on_click,
    on_hover = cfg.on_hover,
    children = children or {},
    resolved_rect = nil,
  }
end

return hstack
