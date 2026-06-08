local gradient = require("lib.engine.ui.primitives.gradient")

local bar = {}

function bar.draw(r, ratio, config)
  local cfg = config or {}
  local color = cfg.color or { 1, 1, 1 }
  local bg_color = cfg.bg_color
  local radius = cfg.radius or 0
  local grad = cfg.gradient

  if bg_color then
    love.graphics.setColor(bg_color[1], bg_color[2], bg_color[3], bg_color[4] or 1)
    love.graphics.rectangle("fill", r.x, r.y, r.w, r.h, radius, radius)
  end

  local fill_w = ratio * r.w
  if fill_w > 0 then
    if grad then
      gradient.fill({ x = r.x, y = r.y, w = fill_w, h = r.h }, grad.top, grad.bottom, radius)
    else
      love.graphics.setColor(color[1], color[2], color[3], color[4] or 1)
      love.graphics.rectangle("fill", r.x, r.y, fill_w, r.h, radius, radius)
    end
  end
end

return setmetatable(bar, {
  __call = function(_, r, ratio, config) bar.draw(r, ratio, config) end,
})
