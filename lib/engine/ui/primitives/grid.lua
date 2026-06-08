local rect = require("lib.engine.ui.primitives.rect")

local grid = {}

function grid.layout(count, size, gap, config)
  local cfg = config or {}
  local cols = cfg.cols or count
  local origin_x = cfg.origin_x or 0
  local origin_y = cfg.origin_y or 0

  local rects = {}
  for i = 1, count do
    local col = (i - 1) % cols
    local row = math.floor((i - 1) / cols)
    table.insert(
      rects,
      rect(origin_x + col * (size + gap), origin_y + row * (size + gap), size, size)
    )
  end

  return rects
end

function grid.hit_test(mx, my, rects)
  for i, r in ipairs(rects) do
    if mx >= r.x and mx <= r.x + r.w and my >= r.y and my <= r.y + r.w then
      return i
    end
  end
  return nil
end

return grid
