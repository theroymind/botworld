local compact_children = require("lib.engine.ui.layout.compact-children")

local function zstack(children, config)
  local cfg = config or {}
  return {
    type = "zstack",
    w = cfg.w or "fill",
    h = cfg.h or "content",
    visible = cfg.visible,
    clip = cfg.clip,
    on_click = cfg.on_click,
    on_right_click = cfg.on_right_click,
    on_hover = cfg.on_hover,
    children = compact_children(children),
    resolved_rect = nil,
  }
end

return zstack
