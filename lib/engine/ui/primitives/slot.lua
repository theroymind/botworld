local highlight = require("lib.engine.ui.primitives.highlight")
local highlight_modes = require("lib.engine.ui.highlight-modes")

local slot = {}

function slot.draw(r, config)
  local cfg = config or {}
  local bg_color = cfg.bg_color or { 0, 0, 0, 0.6 }
  local border_color = cfg.border_color or { 0.4, 0.4, 0.4, 0.8 }
  local radius = cfg.radius or 3

  love.graphics.setColor(bg_color[1], bg_color[2], bg_color[3], bg_color[4])
  love.graphics.rectangle("fill", r.x, r.y, r.w, r.w, radius, radius)

  love.graphics.setColor(border_color[1], border_color[2], border_color[3], border_color[4])
  love.graphics.rectangle("line", r.x, r.y, r.w, r.w, radius, radius)

  if cfg.highlight == highlight_modes.SELECTED then
    highlight.selected(r.x, r.y, r.w, r.w)
  elseif cfg.highlight == highlight_modes.FOCUSED then
    highlight.focused(r.x, r.y, r.w, r.w)
  end
end

function slot.hit_test(mx, my, r)
  return mx >= r.x and mx <= r.x + r.w and my >= r.y and my <= r.y + r.w
end

return setmetatable(slot, {
  __call = function(_, r, config) slot.draw(r, config) end,
})
