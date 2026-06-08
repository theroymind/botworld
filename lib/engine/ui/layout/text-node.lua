local fonts = require("lib.engine.ui.fonts")
local text = require("lib.engine.ui.primitives.text")
local theme = require("lib.engine.ui.theme")

local function text_node(str, config)
  local cfg = config or {}
  local font_name = theme.font[cfg.size or "sm"]
  local is_dynamic = type(str) == "function"
  local measure_w = is_dynamic and 0 or fonts.get(font_name):getWidth(str)
  return {
    type = "node",
    h = cfg.h or fonts.get(font_name):getHeight(),
    w = cfg.w or "fill",
    measure_w = measure_w,
    visible = cfg.visible,
    draw_fn = function(r)
      local label = is_dynamic and str() or str
      text(r, label, { font = font_name, color = cfg.color, align = cfg.align })
    end,
    on_click = cfg.on_click,
    resolved_rect = nil,
  }
end

return text_node
