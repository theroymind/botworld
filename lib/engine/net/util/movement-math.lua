-- Pure movement math: directional speed (lock-on cones), keyboard steps, and
-- click-to-move steps. Used by server-reconciliation so the client replay agrees
-- with whatever movement model a game applies. Copied from botlands; only the
-- require path changed.
local movement_constants = require("lib.engine.net.util.movement-constants")

local movement_math = {}

-- Speed multiplier for moving direction (dx, dy) while facing `facing_angle`.
-- Forward (within the forward cone) keeps full speed, strafing is reduced, and
-- backpedalling is reduced most. Used by lock-on movement on both the server
-- and client prediction so they agree. Returns 1.0 when there is no input.
function movement_math.directional_speed_multiplier(facing_angle, dx, dy)
  local length = math.sqrt(dx * dx + dy * dy)
  if length == 0 then
    return 1.0
  end

  local dot = (dx / length) * math.cos(facing_angle) + (dy / length) * math.sin(facing_angle)
  if dot >= movement_constants.LOCK_ON_FORWARD_DOT then
    return 1.0
  elseif dot <= movement_constants.LOCK_ON_BACKWARD_DOT then
    return movement_constants.LOCK_ON_BACKWARD_SPEED_MULTIPLIER
  end
  return movement_constants.LOCK_ON_STRAFE_SPEED_MULTIPLIER
end

function movement_math.apply_keyboard(x, y, dx, dy, speed, dt)
  if dx == 0 and dy == 0 then
    return x, y
  end

  local length = math.sqrt(dx * dx + dy * dy)
  local nx = dx / length
  local ny = dy / length
  local move = speed * dt

  return x + nx * move, y + ny * move
end

function movement_math.apply_click_move(x, y, target_x, target_y, speed, dt)
  local dx = target_x - x
  local dy = target_y - y
  local dist = math.sqrt(dx * dx + dy * dy)
  local move = speed * dt

  if dist < 1 or move >= dist then
    return target_x, target_y, true
  end

  return x + (dx / dist) * move, y + (dy / dist) * move, false
end

return movement_math
