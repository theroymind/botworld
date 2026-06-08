-- Advance a position along a waypoint path by a distance, returning the new
-- position, the next waypoint index (nil when the path is exhausted), and the
-- facing angle. Shipped as a util for a game's prediction step to reuse. Copied
-- from botlands; only the require path changed.
local math_utils = require("lib.engine.net.util.math-utils")

local atan2 = math_utils.atan2
local EPSILON = 1e-6

local walk_waypoints = {}

function walk_waypoints.advance(waypoints, index, x, y, distance)
  local facing_angle = nil
  while distance > EPSILON do
    local waypoint = waypoints[index]
    if not waypoint then
      return x, y, nil, facing_angle
    end

    local dx = waypoint.x - x
    local dy = waypoint.y - y
    local dist = math.sqrt(dx * dx + dy * dy)

    if dist > EPSILON then
      facing_angle = atan2(dy, dx)
    end

    if dist < EPSILON then
      index = index + 1
      if index > #waypoints then
        return x, y, nil, facing_angle
      end
    elseif distance >= dist then
      x = waypoint.x
      y = waypoint.y
      distance = distance - dist
      index = index + 1
      if index > #waypoints then
        return x, y, nil, facing_angle
      end
    else
      x = x + (dx / dist) * distance
      y = y + (dy / dist) * distance
      return x, y, index, facing_angle
    end
  end
  return x, y, index, facing_angle
end

return walk_waypoints
