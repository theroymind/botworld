-- Generic client-side prediction skeleton, lifted from botlands and decoupled
-- from its movement/combat/entity model. The game injects `step(state, input,
-- dt)` -- a callback that advances a position-bearing state table (state.x,
-- state.y) by one input over dt. This module owns the reusable parts: an input
-- history (for server reconciliation), a server-tick estimate, the predicted
-- position, and a smoothed correction offset so server corrections ease in
-- instead of snapping the rendered position.
--
-- What was dropped vs botlands: shared.data.skills, shared.systems.
-- arrow-consumption, and all the entity-specific follow/lock-on/cast/walk logic.
-- The math/pathfinding utils that logic used (movement-math, movement-step,
-- walk-waypoints) ship under util/ for a game's step callback to compose; this
-- skeleton stays agnostic to them.
local input_history = require("lib.engine.net.config.input-history")
local net_config = require("lib.engine.net.config.net-config")

local DEFAULT_SMOOTHING_RATE = 15
local CORRECTION_EPSILON = 0.01
local TICK_INTERVAL = 1 / net_config.defaults.tick_rate

local function client_prediction(config)
  config = config or {}
  local step = config.step or function() end
  local smoothing_rate = config.smoothing_rate or DEFAULT_SMOOTHING_RATE

  local prediction = {}

  local history = input_history()
  local state = nil -- { x = , y = } predicted authoritative position
  local current_input = nil -- last recorded input, replayed each update
  local initialized = false
  local correction_offset_x = 0
  local correction_offset_y = 0
  local tick_accumulator = 0
  local estimated_server_tick = 0

  function prediction.initialize(x, y)
    state = { x = x, y = y }
    initialized = true
  end

  function prediction.is_initialized() return initialized end

  function prediction.estimated_tick() return estimated_server_tick end

  function prediction.reset()
    initialized = false
    state = nil
    current_input = nil
    correction_offset_x = 0
    correction_offset_y = 0
    tick_accumulator = 0
    estimated_server_tick = 0
    history.clear()
  end

  function prediction.stop() current_input = nil end

  -- Record a game-defined input. The engine stamps it with the current estimated
  -- server tick (server-reconciliation groups by it) and replays it each update
  -- until the next input is recorded.
  function prediction.record(input)
    input.estimated_server_tick = estimated_server_tick
    history.record(input)
    current_input = input
  end

  function prediction.discard_through(ack_tick) history.discard_through(ack_tick) end

  function prediction.get_unacknowledged() return history.get_unacknowledged() end

  function prediction.update(dt)
    tick_accumulator = tick_accumulator + dt
    while tick_accumulator >= TICK_INTERVAL do
      tick_accumulator = tick_accumulator - TICK_INTERVAL
      estimated_server_tick = estimated_server_tick + 1
    end

    prediction.decay_correction(dt)

    if not state then
      return
    end

    if current_input then
      step(state, current_input, dt)
    end
  end

  -- Apply a server-authoritative correction. The visual offset absorbs the delta
  -- so rendering eases toward truth via decay_correction instead of snapping.
  function prediction.set_corrected_position(x, y)
    if state then
      correction_offset_x = correction_offset_x + (state.x - x)
      correction_offset_y = correction_offset_y + (state.y - y)
      state.x = x
      state.y = y
    else
      state = { x = x, y = y }
      initialized = true
    end
  end

  function prediction.get_predicted_position()
    if not state then
      return nil, nil
    end
    return state.x, state.y
  end

  function prediction.get_visual_position()
    if not state then
      return nil, nil
    end
    return state.x + correction_offset_x, state.y + correction_offset_y
  end

  function prediction.decay_correction(dt)
    if correction_offset_x == 0 and correction_offset_y == 0 then
      return
    end
    local decay = math.exp(-smoothing_rate * dt)
    correction_offset_x = correction_offset_x * decay
    correction_offset_y = correction_offset_y * decay
    if math.abs(correction_offset_x) < CORRECTION_EPSILON then
      correction_offset_x = 0
    end
    if math.abs(correction_offset_y) < CORRECTION_EPSILON then
      correction_offset_y = 0
    end
  end

  return prediction
end

return client_prediction
