local theme = require("lib.engine.ui.theme")
local compact_children = require("lib.engine.ui.layout.compact-children")

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
    align = cfg.align, -- horizontal placement of narrower children; see layout/align.lua
    visible = cfg.visible,
    bg = cfg.bg,
    clip = cfg.clip,
    on_click = cfg.on_click,
    on_hover = cfg.on_hover,
    children = compact_children(children),
    resolved_rect = nil,
  }
end

return vstack
