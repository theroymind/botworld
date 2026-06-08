local fonts = require("lib.engine.ui.fonts")
local colors = require("lib.engine.ui.colors")
local theme = require("lib.engine.ui.theme")

local DEFAULT_COLOR = colors.foreground

local text = {}

function text.draw(r, str, config)
  local cfg = config or {}
  local font_name = cfg.font or "hud"
  local color = cfg.color or DEFAULT_COLOR
  local align = cfg.align or "left"

  local font = fonts.get(font_name)
  love.graphics.setFont(font)

  local draw_x = r.x
  if align == "center" and r.w > 0 then
    draw_x = r.x + (r.w - font:getWidth(str)) / 2
  elseif align == "right" and r.w > 0 then
    draw_x = r.x + r.w - font:getWidth(str)
  end

  local font_height = font:getHeight()
  local draw_y = r.y
  if r.h > font_height then
    draw_y = r.y + math.floor((r.h - font_height) / 2)
  end

  if cfg.shadow then
    local shadow_color = cfg.shadow_color or colors.game.name_shadow
    local shadow_offset = theme.world_text.shadow_offset
    local shadow_alpha = (color[4] or 1) * (shadow_color[4] or 1)
    love.graphics.setColor(shadow_color[1], shadow_color[2], shadow_color[3], shadow_alpha)
    love.graphics.print(str, draw_x + shadow_offset, draw_y + shadow_offset)
  end

  love.graphics.setColor(color[1], color[2], color[3], color[4])
  love.graphics.print(str, draw_x, draw_y)
end

return setmetatable(text, {
  __call = function(_, r, str, config) text.draw(r, str, config) end,
})
