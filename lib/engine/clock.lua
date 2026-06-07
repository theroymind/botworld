-- Fixed-timestep sim clock: rendering runs free while game logic advances in
-- whole ticks, keeping production math framerate-independent. Runtime-only —
-- offline catch-up replays elsewhere. A long hitch fires at most
-- MAX_TICKS_PER_FRAME ticks and drops the remainder, so a stall can never
-- snowball into a spiral-of-death.
local clock = {}

local MAX_TICKS_PER_FRAME = 30

clock.tick_rate = 10 -- sim ticks per second
clock.tick_dt = 1 / clock.tick_rate
clock.sim_time = 0 -- accumulated sim seconds (ticks * tick_dt)

local accumulator = 0

-- Accumulate real dt and fire on_tick(tick_dt) once per whole sim tick.
function clock.update(dt, on_tick)
  accumulator = accumulator + dt
  local ticks = math.floor(accumulator / clock.tick_dt)
  if ticks > MAX_TICKS_PER_FRAME then
    ticks = MAX_TICKS_PER_FRAME
    accumulator = 0 -- drop the backlog
  else
    accumulator = accumulator - ticks * clock.tick_dt
  end
  for _ = 1, ticks do
    clock.sim_time = clock.sim_time + clock.tick_dt
    on_tick(clock.tick_dt)
  end
end

return clock
