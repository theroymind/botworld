local theme = require("lib.engine.ui.theme")
local compact_children = require("lib.engine.ui.layout.compact-children")

local function hstack(children, config)
  local cfg = config or {}
  return {
    type = "hstack",
    nav = cfg.nav,
    gap = cfg.gap or theme.spacing.md,
    padding = cfg.padding or 0,
    w = cfg.w or "fill",
    h = cfg.h or "content",
    align_v = cfg.align_v, -- vertical placement of shorter children; see layout/align.lua
    visible = cfg.visible,
    bg = cfg.bg,
    clip = cfg.clip,
    on_click = cfg.on_click,
    on_hover = cfg.on_hover,
    children = compact_children(children),
    resolved_rect = nil,
  }
end

return hstack
