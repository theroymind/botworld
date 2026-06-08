local text_input = require("lib.engine.ui.primitives.text-input")
local theme = require("lib.engine.ui.theme")

local function text_input_node(buffer, config)
  local cfg = config or {}
  return {
    type = "node",
    h = cfg.h or theme.sizing.text_input_height,
    w = cfg.w or theme.sizing.text_input_width,
    visible = cfg.visible,
    draw_fn = function(r) text_input(r, buffer) end,
  }
end

return text_input_node
