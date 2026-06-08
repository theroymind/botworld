-- Server reconciliation: given a fresh server position and the unacknowledged
-- input tail, replay those inputs to recover the predicted "now" position.
-- Supports both per-input and tick-grouped histories. Encodes a keyboard /
-- click-move movement model via movement-math -- a game using a different model
-- predicts via the client-prediction step callback instead. Copied from
-- botlands; only the require path changed.
local movement_math = require("lib.engine.net.util.movement-math")

local server_reconciliation = {}

local POSITION_TOLERANCE = 0.5

server_reconciliation.POSITION_TOLERANCE = POSITION_TOLERANCE

local function has_tick_grouping(inputs)
  return #inputs > 0 and inputs[1].estimated_server_tick ~= nil
end

local function keep_passable_position(prev_x, prev_y, next_x, next_y, is_top_left_passable)
  if is_top_left_passable and not is_top_left_passable(next_x, next_y) then
    return prev_x, prev_y
  end
  return next_x, next_y
end

local function replay_movement_step(
  x,
  y,
  active_target_x,
  active_target_y,
  keyboard_entry,
  speed,
  tick_interval,
  is_top_left_passable
)
  local next_x = x
  local next_y = y

  if keyboard_entry then
    next_x, next_y =
      movement_math.apply_keyboard(x, y, keyboard_entry.dx, keyboard_entry.dy, speed, tick_interval)
    active_target_x = nil
    active_target_y = nil
  elseif active_target_x then
    local arrived
    next_x, next_y, arrived =
      movement_math.apply_click_move(x, y, active_target_x, active_target_y, speed, tick_interval)
    if arrived then
      active_target_x = nil
      active_target_y = nil
    end
  end

  next_x, next_y = keep_passable_position(x, y, next_x, next_y, is_top_left_passable)
  return next_x, next_y, active_target_x, active_target_y
end

local function reconcile_tick_grouped(
  server_x,
  server_y,
  inputs,
  speed,
  tick_interval,
  is_top_left_passable
)
  local x = server_x
  local y = server_y
  local active_target_x = nil
  local active_target_y = nil
  local group_start = 1

  while group_start <= #inputs do
    local current_tick = inputs[group_start].estimated_server_tick
    local group_end = group_start

    while group_end < #inputs and inputs[group_end + 1].estimated_server_tick == current_tick do
      group_end = group_end + 1
    end

    local last_keyboard = nil
    for i = group_start, group_end do
      local entry = inputs[i]
      if entry.type == "keyboard" then
        last_keyboard = entry
      elseif entry.type == "click_move" then
        active_target_x = entry.target_x
        active_target_y = entry.target_y
      end
    end

    x, y, active_target_x, active_target_y = replay_movement_step(
      x,
      y,
      active_target_x,
      active_target_y,
      last_keyboard,
      speed,
      tick_interval,
      is_top_left_passable
    )

    group_start = group_end + 1
  end

  return x, y, active_target_x, active_target_y
end

local function reconcile_per_input(
  server_x,
  server_y,
  inputs,
  speed,
  tick_interval,
  is_top_left_passable
)
  local x = server_x
  local y = server_y
  local active_target_x = nil
  local active_target_y = nil

  for i = 1, #inputs do
    local entry = inputs[i]
    if entry.type == "keyboard" then
      x, y, active_target_x, active_target_y = replay_movement_step(
        x,
        y,
        active_target_x,
        active_target_y,
        entry,
        speed,
        tick_interval,
        is_top_left_passable
      )
    elseif entry.type == "click_move" then
      active_target_x = entry.target_x
      active_target_y = entry.target_y
      x, y, active_target_x, active_target_y = replay_movement_step(
        x,
        y,
        active_target_x,
        active_target_y,
        nil,
        speed,
        tick_interval,
        is_top_left_passable
      )
    end
  end

  return x, y, active_target_x, active_target_y
end

function server_reconciliation.reconcile(
  server_x,
  server_y,
  unacknowledged_inputs,
  speed,
  tick_interval,
  is_top_left_passable,
  current_target_x,
  current_target_y
)
  if #unacknowledged_inputs == 0 then
    return server_x, server_y, current_target_x, current_target_y
  end

  if has_tick_grouping(unacknowledged_inputs) then
    return reconcile_tick_grouped(
      server_x,
      server_y,
      unacknowledged_inputs,
      speed,
      tick_interval,
      is_top_left_passable
    )
  end

  return reconcile_per_input(
    server_x,
    server_y,
    unacknowledged_inputs,
    speed,
    tick_interval,
    is_top_left_passable
  )
end

return server_reconciliation
