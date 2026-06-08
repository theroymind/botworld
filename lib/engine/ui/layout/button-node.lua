local button = require("lib.engine.ui.primitives.button")
local fonts = require("lib.engine.ui.fonts")
local theme = require("lib.engine.ui.theme")

local function button_node(label, config)
  local cfg = config or {}
  local font_name = theme.font[cfg.size or "sm"]
  local font = fonts.get(font_name)
  local padding = theme.spacing.sm * 2
  local content_w = math.max(font:getWidth(label) + padding, theme.sizing.button_min_width)
  return {
    type = "node",
    h = cfg.h or theme.sizing.button_height,
    w = cfg.w or "auto",
    measure_w = content_w,
    visible = cfg.visible,
    draw_fn = function(r)
      button(r, label, {
        font = font_name,
        variant = cfg.variant,
        border_color = cfg.border_color,
        opacity = cfg.opacity,
        text_color = cfg.text_color,
        radius = cfg.radius,
      })
    end,
    focusable = cfg.focusable ~= false,
    on_click = cfg.on_click,
    resolved_rect = nil,
  }
end

return button_node
