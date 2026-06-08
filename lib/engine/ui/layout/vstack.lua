local theme = require("lib.engine.ui.theme")

local function vstack(children, config)
  local cfg = config or {}
  return {
    type = "vstack",
    nav = cfg.nav,
    cols = cfg.cols,
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

return vstack
