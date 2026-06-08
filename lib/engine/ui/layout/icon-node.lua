local fonts = require("lib.engine.ui.fonts")
local theme = require("lib.engine.ui.theme")

local function icon_node(sprite, options)
  if sprite == nil then
    return nil
  end

  local opts = options or {}
  local color = opts.color or { 1, 1, 1, 0.9 }
  local size = opts.size or theme.sizing.slot_size

  return {
    type = "node",
    w = size,
    h = size,
    draw_fn = function(r)
      local icon_font = fonts.get_icon_font(theme.font.sm)
      love.graphics.setFont(icon_font)
      love.graphics.setColor(color[1], color[2], color[3], color[4])
      local iw = icon_font:getWidth(sprite)
      local ih = icon_font:getHeight()
      love.graphics.print(sprite, r.x + (r.w - iw) / 2, r.y + (r.h - ih) / 2)
    end,
    resolved_rect = nil,
  }
end

return icon_node
