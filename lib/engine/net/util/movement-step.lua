-- One movement step from an input snapshot (keyboard / click-move / idle).
-- Shipped as a net-engine util so a game's prediction step callback can reuse
-- it; the generic client-prediction skeleton does not depend on it. Copied from
-- botlands; only the require path changed.
local movement_math = require("lib.engine.net.util.movement-math")

local MOTION_KEYBOARD = "keyboard"
local MOTION_CLICK_MOVE = "click_move"
local MOTION_IDLE = "idle"

local movement_step = {}

movement_step.MOTION_KEYBOARD = MOTION_KEYBOARD
movement_step.MOTION_CLICK_MOVE = MOTION_CLICK_MOVE
movement_step.MOTION_IDLE = MOTION_IDLE

local function idle_result(snapshot, target_x, target_y)
  return {
    x = snapshot.x,
    y = snapshot.y,
    target_x = target_x,
    target_y = target_y,
    input_dx = 0,
    input_dy = 0,
    arrived = false,
    motion_kind = MOTION_IDLE,
  }
end

function movement_step.compute(snapshot)
  local input_dx = snapshot.input_dx or 0
  local input_dy = snapshot.input_dy or 0

  if snapshot.is_casting or snapshot.is_sitting then
    return idle_result(snapshot, nil, nil)
  end

  if snapshot.swing_paused then
    return idle_result(snapshot, snapshot.target_x, snapshot.target_y)
  end

  if input_dx ~= 0 or input_dy ~= 0 then
    local new_x, new_y = movement_math.apply_keyboard(
      snapshot.x,
      snapshot.y,
      input_dx,
      input_dy,
      snapshot.speed,
      snapshot.dt
    )
    return {
      x = new_x,
      y = new_y,
      target_x = nil,
      target_y = nil,
      input_dx = 0,
      input_dy = 0,
      arrived = false,
      motion_kind = MOTION_KEYBOARD,
    }
  end

  if snapshot.target_x then
    local new_x, new_y, arrived = movement_math.apply_click_move(
      snapshot.x,
      snapshot.y,
      snapshot.target_x,
      snapshot.target_y,
      snapshot.speed,
      snapshot.dt
    )
    local next_target_x = snapshot.target_x
    local next_target_y = snapshot.target_y
    if arrived then
      next_target_x = nil
      next_target_y = nil
    end
    return {
      x = new_x,
      y = new_y,
      target_x = next_target_x,
      target_y = next_target_y,
      input_dx = 0,
      input_dy = 0,
      arrived = arrived,
      motion_kind = MOTION_CLICK_MOVE,
    }
  end

  return idle_result(snapshot, snapshot.target_x, snapshot.target_y)
end

return movement_step
