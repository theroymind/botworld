local fonts = require("lib.engine.ui.fonts")
local colors = require("lib.engine.ui.colors")
local theme = require("lib.engine.ui.theme")

local function count_badge_node(count, options)
  if count == nil or count <= 1 then
    return nil
  end

  local opts = options or {}
  local color = opts.color or colors.ui.text
  local size = opts.size or theme.sizing.slot_size
  local count_str = tostring(count)

  return {
    type = "node",
    w = size,
    h = size,
    draw_fn = function(r)
      local count_font = fonts.get(theme.font.sm)
      love.graphics.setFont(count_font)
      love.graphics.setColor(color[1], color[2], color[3], color[4])
      local tw = count_font:getWidth(count_str)
      love.graphics.print(count_str, r.x + r.w - tw - 1, r.y + r.h - count_font:getHeight())
    end,
    resolved_rect = nil,
  }
end

return count_badge_node
