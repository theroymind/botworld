local bar = require("lib.engine.ui.primitives.bar")
local rect = require("lib.engine.ui.primitives.rect")
local theme = require("lib.engine.ui.theme")

local function bar_node(ratio, config)
  local cfg = config or {}
  return {
    type = "node",
    h = cfg.h or theme.sizing.bar_height,
    w = cfg.w or "fill",
    draw_fn = function(r)
      bar.draw(rect(r.x, r.y, r.w, r.h), ratio, {
        color = cfg.color,
        bg_color = cfg.bg_color,
        radius = cfg.radius or 2,
      })
    end,
  }
end

return bar_node
