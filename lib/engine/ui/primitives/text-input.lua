local fonts = require("lib.engine.ui.fonts")
local rect = require("lib.engine.ui.primitives.rect")
local container = require("lib.engine.ui.primitives.container")
local text = require("lib.engine.ui.primitives.text")
local colors = require("lib.engine.ui.colors")
local theme = require("lib.engine.ui.theme")

local TEXT_COLOR = colors.ui.white
local SELECTION_COLOR =
  { colors.palette.blue_deep[1], colors.palette.blue_deep[2], colors.palette.blue_deep[3], 0.6 }
local CURSOR_BLINK_RATE = 2

local text_input = {}

function text_input.draw(r, buffer, opts)
  opts = opts or {}
  local font_name = opts.font or theme.font.md
  local pad = opts.padding or theme.sizing.text_input_padding
  local text_color = opts.text_color or TEXT_COLOR
  local selection_color = opts.selection_color or SELECTION_COLOR
  local placeholder = opts.placeholder
  local placeholder_color = opts.placeholder_color or text_color
  local draw_container = opts.draw_container ~= false

  if draw_container then
    container(r, "input")
  end

  local value = buffer:get_value()
  local cursor_pos = buffer:get_cursor_pos()
  local font = fonts.get(font_name)
  local fh = font:getHeight()
  local text_y = r.y + (r.h - fh) / 2
  local text_x = r.x + pad

  if value == "" and placeholder and placeholder ~= "" then
    text(rect(text_x, text_y, r.w - pad * 2, fh), placeholder, {
      font = font_name,
      color = placeholder_color,
    })
  else
    if buffer:has_selection() then
      local sel_start, sel_end = buffer:get_selection_range()
      local sel_x = text_x + font:getWidth(value:sub(1, sel_start))
      local sel_w = font:getWidth(value:sub(sel_start + 1, sel_end))
      love.graphics.setColor(selection_color)
      love.graphics.rectangle("fill", sel_x, text_y, sel_w, fh)
    end
    text(rect(text_x, text_y, r.w - pad * 2, fh), value, {
      font = font_name,
      color = text_color,
    })
  end

  local cursor_visible = math.floor(love.timer.getTime() * CURSOR_BLINK_RATE) % 2 == 0
  if cursor_visible or buffer:has_selection() then
    local cursor_x = text_x + font:getWidth(value:sub(1, cursor_pos))
    love.graphics.setColor(text_color)
    love.graphics.setLineWidth(1)
    love.graphics.line(cursor_x, text_y, cursor_x, text_y + fh)
  end
end

return setmetatable(text_input, {
  __call = function(_, r, buffer, opts) text_input.draw(r, buffer, opts) end,
})
