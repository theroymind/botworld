-- Touch input shim. Single-finger taps and drags already reach the mouse
-- handlers through LÖVE's built-in touch->mouse emulation, so the only gap
-- on mobile is the scroll wheel: this module turns pinch gestures into
-- discrete wheelmoved steps (layers treat any wheel event as one zoom step,
-- so we emit +-1 per STEP_PX of finger-gap change rather than scaling).
local touch = {}

local STEP_PX = 40 -- finger-gap change (px) per emitted zoom step

local points = {} -- id -> {x, y}
local ids = {} -- active touch ids, oldest first
local last_gap -- finger gap at the last emitted step; nil unless pinching
local on_step -- function(dy): dy is +1 (zoom in) or -1 (zoom out)

function touch.init(callback) on_step = callback end

-- Distance between the two oldest touches (the pinch pair).
local function gap()
  local a, b = points[ids[1]], points[ids[2]]
  local dx, dy = a.x - b.x, a.y - b.y
  return math.sqrt(dx * dx + dy * dy)
end

function touch.pressed(id, x, y)
  points[id] = { x = x, y = y }
  ids[#ids + 1] = id
  last_gap = #ids >= 2 and gap() or nil
end

function touch.moved(id, x, y)
  local p = points[id]
  if not p then
    return
  end
  p.x, p.y = x, y
  if not last_gap or not on_step then
    return
  end
  local g = gap()
  while g - last_gap >= STEP_PX do
    last_gap = last_gap + STEP_PX
    on_step(1)
  end
  while last_gap - g >= STEP_PX do
    last_gap = last_gap - STEP_PX
    on_step(-1)
  end
end

function touch.released(id)
  if not points[id] then
    return
  end
  points[id] = nil
  for i = #ids, 1, -1 do
    if ids[i] == id then
      table.remove(ids, i)
    end
  end
  last_gap = #ids >= 2 and gap() or nil
end

return touch
