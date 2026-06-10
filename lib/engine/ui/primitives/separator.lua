local separator = {}

-- Cross-axis size of a separator (the 1px line). The layout solver reserves exactly
-- this much width (hstack) or height (vstack) for separator children.
separator.THICKNESS = 1

function separator.draw(r, config)
  local cfg = config or {}
  local color = cfg.color or { 0.4, 0.4, 0.4, 1 }

  love.graphics.setColor(color[1], color[2], color[3], color[4])
  if r.h >= r.w then
    love.graphics.line(r.x, r.y, r.x, r.y + r.h)
  else
    love.graphics.line(r.x, r.y, r.x + r.w, r.y)
  end
end

function separator.node(config)
  local cfg = config or {}
  return { type = "separator", color = cfg.color, resolved_rect = nil }
end

return setmetatable(separator, {
  __call = function(_, r, config) separator.draw(r, config) end,
})
