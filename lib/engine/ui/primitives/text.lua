local fonts = require("lib.engine.ui.fonts")
local colors = require("lib.engine.ui.colors")
local theme = require("lib.engine.ui.theme")
local truncate = require("lib.engine.ui.util.truncate")

local DEFAULT_COLOR = colors.foreground

-- One measure closure per font, built lazily: truncation runs every draw, so
-- allocating the closure inline would churn garbage per frame. Weak keys let a
-- font (and its closure) be collected if the font cache is ever reset.
local measure_fns = setmetatable({}, { __mode = "k" })

local function measure_fn_for(font)
  local measure = measure_fns[font]
  if not measure then
    measure = function(s) return font:getWidth(s) end
    measure_fns[font] = measure
  end
  return measure
end

local text = {}

function text.draw(r, str, config)
  local cfg = config or {}
  local font_name = cfg.font or "hud"
  local color = cfg.color or DEFAULT_COLOR
  local align = cfg.align or "left"

  local font = fonts.get(font_name)
  love.graphics.setFont(font)

  -- WRAPPED PATH: a positive cfg.wrap is the column width the text must stay within.
  -- printf owns horizontal alignment inside [r.x, r.x + wrap] and breaks the string
  -- into lines, so the text adapts to the rect instead of overflowing it. The caller
  -- (text-node) sizes r.h to the wrapped line count, so we draw from the rect top --
  -- the single-line vertical-centering below would mis-place a multi-line block.
  local wrap = cfg.wrap
  if wrap and wrap > 0 then
    if cfg.shadow then
      local shadow_color = cfg.shadow_color or colors.game.name_shadow
      local shadow_offset = theme.world_text.shadow_offset
      local shadow_alpha = (color[4] or 1) * (shadow_color[4] or 1)
      love.graphics.setColor(shadow_color[1], shadow_color[2], shadow_color[3], shadow_alpha)
      love.graphics.printf(str, r.x + shadow_offset, r.y + shadow_offset, wrap, align)
    end
    love.graphics.setColor(color[1], color[2], color[3], color[4])
    love.graphics.printf(str, r.x, r.y, wrap, align)
    return
  end

  -- SINGLE-LINE PATH: with cfg.truncate the string is ellipsized to the rect width,
  -- and draw_x is clamped to the rect's left edge -- centered/right-aligned labels
  -- wider than the rect would otherwise spill out BOTH sides.
  local label = str
  if cfg.truncate and r.w > 0 then
    label = truncate(str, r.w, measure_fn_for(font))
  end

  local draw_x = r.x
  if align == "center" and r.w > 0 then
    draw_x = r.x + (r.w - font:getWidth(label)) / 2
  elseif align == "right" and r.w > 0 then
    draw_x = r.x + r.w - font:getWidth(label)
  end
  if cfg.truncate and draw_x < r.x then
    draw_x = r.x
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
    love.graphics.print(label, draw_x + shadow_offset, draw_y + shadow_offset)
  end

  love.graphics.setColor(color[1], color[2], color[3], color[4])
  love.graphics.print(label, draw_x, draw_y)
end

return setmetatable(text, {
  __call = function(_, r, str, config) text.draw(r, str, config) end,
})
