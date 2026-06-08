local rect = {}
local rect_mt = { __index = rect }

function rect:pad(v, h)
  if not h then
    h = v
  end
  return setmetatable(
    { x = self.x + h, y = self.y + v, w = self.w - h * 2, h = self.h - v * 2 },
    rect_mt
  )
end

function rect:below(offset)
  return setmetatable({ x = self.x, y = self.y + offset, w = self.w, h = self.h }, rect_mt)
end

function rect:right(offset)
  return setmetatable({ x = self.x + offset, y = self.y, w = self.w, h = self.h }, rect_mt)
end

function rect:height(new_h)
  return setmetatable({ x = self.x, y = self.y, w = self.w, h = new_h }, rect_mt)
end

function rect:width(new_w)
  return setmetatable({ x = self.x, y = self.y, w = new_w, h = self.h }, rect_mt)
end

function rect:contains(px, py)
  return px >= self.x and px <= self.x + self.w and py >= self.y and py <= self.y + self.h
end

return setmetatable(rect, {
  __call = function(_, x, y, w, h) return setmetatable({ x = x, y = y, w = w, h = h }, rect_mt) end,
})
