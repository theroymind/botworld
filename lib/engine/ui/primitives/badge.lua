local fonts = require("lib.engine.ui.fonts")
local colors = require("lib.engine.ui.colors")
local rect_mod = require("lib.engine.ui.primitives.rect")
local text = require("lib.engine.ui.primitives.text")

local PAD_X = 4
local PAD_Y = 2
local RADIUS = 3

local badge = {}

function badge.draw(r, label, config)
  local cfg = config or {}
  local bg_color = cfg.bg_color or colors.ui.bg_panel
  local border_color = cfg.border_color or colors.ui.accent_dim
  local font_name = cfg.font or "hud"
  local font = fonts.get(font_name)
  local text_color = cfg.text_color or colors.ui.text

  love.graphics.setColor(bg_color)
  love.graphics.rectangle("fill", r.x, r.y, r.w, r.h, RADIUS, RADIUS)
  love.graphics.setColor(border_color)
  love.graphics.rectangle("line", r.x, r.y, r.w, r.h, RADIUS, RADIUS)

  text(
    rect_mod(r.x + PAD_X, r.y + PAD_Y, r.w - PAD_X * 2, font:getHeight()),
    label,
    { font = font_name, color = text_color, align = "center", truncate = true }
  )
end

function badge.measure(label, config)
  local cfg = config or {}
  local font_name = cfg.font or "hud"
  local font = fonts.get(font_name)
  local width = font:getWidth(label) + PAD_X * 2
  local height = font:getHeight() + PAD_Y * 2
  return width, height
end

return setmetatable(badge, {
  __call = function(_, r, label, config) badge.draw(r, label, config) end,
})
