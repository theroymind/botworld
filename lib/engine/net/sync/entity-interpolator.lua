-- Buffers remote positions and renders them in the past (INTERPOLATION_DELAY) so
-- jittery snapshots play back smoothly; large jumps teleport instead of sliding.
-- Per-entity ring buffer. Copied verbatim from botlands -- zero requires, fully
-- generic (operates on entity ids + x/y only).
local INTERPOLATION_DELAY = 0.1
local TELEPORT_THRESHOLD_SQUARED = 200 * 200
local MAX_BUFFER_SIZE = 6

local function entity_interpolator()
  local interpolator = {}

  local clock = 0
  local states = {}

  function interpolator.push_position(entity_id, x, y)
    local state = states[entity_id]
    if not state then
      return
    end

    local buffer = state.buffer
    local tail = state.tail
    local latest = buffer[tail]
    local dx = x - latest.x
    local dy = y - latest.y
    local distance_squared = dx * dx + dy * dy

    if distance_squared > TELEPORT_THRESHOLD_SQUARED then
      buffer[1] = { x = x, y = y, time = clock }
      state.head = 1
      state.tail = 1
      state.count = 1
    else
      local next_tail = tail % MAX_BUFFER_SIZE + 1
      buffer[next_tail] = { x = x, y = y, time = clock }
      state.tail = next_tail
      if state.count < MAX_BUFFER_SIZE then
        state.count = state.count + 1
      else
        state.head = state.head % MAX_BUFFER_SIZE + 1
      end
    end
  end

  function interpolator.update(dt) clock = clock + dt end

  function interpolator.get_position(entity_id)
    local state = states[entity_id]
    if not state then
      return nil, nil
    end

    local buffer = state.buffer
    local render_time = clock - INTERPOLATION_DELAY
    local head = state.head
    local count = state.count

    while count > 2 do
      local second = head % MAX_BUFFER_SIZE + 1
      if buffer[second].time > render_time then
        break
      end
      head = second
      count = count - 1
    end
    state.head = head
    state.count = count

    if count < 2 then
      return buffer[head].x, buffer[head].y
    end

    local a = buffer[head]
    local b = buffer[head % MAX_BUFFER_SIZE + 1]
    local duration = b.time - a.time

    if duration <= 0 then
      return b.x, b.y
    end

    local t = (render_time - a.time) / duration
    if t < 0 then
      t = 0
    elseif t > 1 then
      t = 1
    end

    local x = a.x + (b.x - a.x) * t
    local y = a.y + (b.y - a.y) * t
    return x, y
  end

  function interpolator.spawn(entity_id, x, y)
    states[entity_id] = {
      buffer = { { x = x, y = y, time = clock } },
      head = 1,
      tail = 1,
      count = 1,
    }
  end

  function interpolator.despawn(entity_id) states[entity_id] = nil end

  function interpolator.get_latest_server_position(entity_id)
    local state = states[entity_id]
    if not state then
      return nil, nil
    end
    local latest = state.buffer[state.tail]
    return latest.x, latest.y
  end

  function interpolator.is_tracking(entity_id) return states[entity_id] ~= nil end

  function interpolator.for_each_tracked(callback)
    for entity_id, _ in pairs(states) do
      callback(entity_id)
    end
  end

  return interpolator
end

return entity_interpolator
