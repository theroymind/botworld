local colors = require("lib.engine.ui.colors")
local theme = require("lib.engine.ui.theme")

local border = {}

function border.refined(r, config)
  local cfg = config or {}
  local outer_color = cfg.outer_color or colors.border
  local inner_color = cfg.inner_color or colors.border_inner_highlight
  local inner_alpha = cfg.inner_alpha or 0.15
  local radius = cfg.radius or theme.gradient.panel_radius
  local inset = cfg.inset or theme.border.refined_inset

  love.graphics.setColor(outer_color[1], outer_color[2], outer_color[3], outer_color[4] or 1)
  love.graphics.rectangle("line", r.x, r.y, r.w, r.h, radius, radius)

  love.graphics.setColor(inner_color[1], inner_color[2], inner_color[3], inner_alpha)
  love.graphics.rectangle(
    "line",
    r.x + inset,
    r.y + inset,
    r.w - inset * 2,
    r.h - inset * 2,
    math.max(radius - inset, 0),
    math.max(radius - inset, 0)
  )
end

return border
